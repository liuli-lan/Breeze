#!/usr/bin/env python3
"""MangaJaNai 局域网超分服务（单进程：HTTP + 调度 + 引擎 + 看门狗）。

设计要点见同目录 PLAN.md：

1. **单进程常驻。** 引擎以模块方式 import 后端的 ``run_upscale.py``，
   ``torch`` / CUDA / 模型权重只初始化一次，消除「逐请求 spawn」带来的约 14 s 冷启动
   （实测：spawn 模式单张端到端 ~15 s，常驻后 ~0.7 s）。

2. **不复用后端的 multiprocessing 流水线。** 后端 ``upscale_folder()`` 用
   ``multiprocessing.Process`` fork，且在「已初始化 CUDA context 的进程里反复 fork」不安全；
   更关键的是它对损坏图片没有容错——预处理线程抛异常时不投结束哨兵，超分线程永久阻塞在队列上。
   这里用三个 ``threading.Thread`` + ``Queue(maxsize=1)`` 复刻同样的三段流水线
   （保住实测 1.74 张/秒的吞吐），但每张图独立 try/except、哨兵放 ``finally``。

3. **两通道优先级 + 时间预算切片。** 交互式（单张翻页）永远优先于批量；
   批量任务每片最多连续跑 ``MJN_SLICE_BUDGET`` 秒就让出。翻页排队延迟因此被硬性封顶，
   与同时跑了多大的批量任务无关（PLAN.md §5.3）。

4. **看门狗 + systemd。** 作业超过 deadline 直接 ``os._exit(1)``，绕开一切挂死的线程 /
   CUDA 状态，由 systemd ``Restart=always`` 拉起（PLAN.md §4.1）。
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import inspect
import io
import json
import logging
import logging.handlers
import os
import shutil
import sys
import tempfile
import threading
import time
import uuid
import zipfile
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from queue import Queue
from typing import Any, Callable

# =============================================================================
# Windows 宿主适配 —— 必须在 `from chains import` 之前完成
# =============================================================================
#
# GUI 的 embeddable Python（`python313._pth`）会**完整替换 sys.path，并且不再自动把
# 脚本所在目录加进去**，于是下面 `from chains import` 直接
# `ModuleNotFoundError: No module named 'chains'`（P0 实测踩到）。
# Docker / systemd 里的常规 CPython 会自动加入脚本目录，所以那边**不复现**。
#
# 显式插入本文件所在目录，让两种宿主都成立；在 Docker 中这只是重复一项，无副作用。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from chains import DEFAULT_TILE, build_chains, required_model_files

# =============================================================================
# 配置（全部可由环境变量覆盖）
# =============================================================================

SRC_DIR = os.environ.get("MJN_SRC", "/opt/mjn/backend/src")
MODELS_DIR = os.environ.get("MJN_MODELS", "/models")
WORK_DIR = Path(os.environ.get("MJN_WORK", "/work"))
SERVICE_DIR = os.environ.get("MJN_SERVICE", "/opt/mjn/service")

HOST = os.environ.get("MJN_HOST", "0.0.0.0")
PORT = int(os.environ.get("MJN_PORT", "8765"))
API_KEY = os.environ.get("MJN_API_KEY", "").strip()
LOG_LEVEL = os.environ.get("MJN_LOG_LEVEL", "INFO").upper()

DEVICE_INDEX = int(os.environ.get("MJN_DEVICE_INDEX", "1"))  # 0 = CPU，非 0 = GPU
USE_FP16 = os.environ.get("MJN_FP16", "1") not in ("0", "false", "False", "no")
TILE = os.environ.get("MJN_TILE", DEFAULT_TILE)
PRELOAD = os.environ.get("MJN_PRELOAD", "1") not in ("0", "false", "False", "no")

SLICE_BUDGET = float(os.environ.get("MJN_SLICE_BUDGET", "1.2"))  # 批量每片秒数
QUEUE_MAX = int(os.environ.get("MJN_QUEUE_MAX", "64"))
JOB_TTL_S = int(os.environ.get("MJN_JOB_TTL_S", str(24 * 3600)))
DEFAULT_SCALE = int(os.environ.get("MJN_DEFAULT_SCALE", "2"))
DEFAULT_THRESHOLD = int(os.environ.get("MJN_DEFAULT_THRESHOLD", "12"))
DEFAULT_FORMAT = os.environ.get("MJN_DEFAULT_FORMAT", "webp")
DEFAULT_QUALITY = int(os.environ.get("MJN_DEFAULT_QUALITY", "90"))
ALLOWED_SCALES = {
    int(x) for x in os.environ.get("MJN_ALLOWED_SCALES", "2,4").split(",") if x.strip()
}

FORMATS: dict[str, tuple[str, str]] = {
    "webp": ("webp", "image/webp"),
    "png": ("png", "image/png"),
    "jpeg": ("jpg", "image/jpeg"),
    "jpg": ("jpg", "image/jpeg"),
    "avif": ("avif", "image/avif"),
}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".avif"}

# 单张引擎耗时的**种子值**，只用于启动初期还没有实测数据时。
#
# ⚠️ 这不是指南里的 0.57 s/张 —— 那个数字是「黑白批次里 2x 的均值」，
# 而本服务单张请求的真实成本差别极大（本机容器内实测：彩色 2x ≈ 2.1 s、彩色 4x ≈ 5.3 s，
# 黑白页则便宜得多）。用错这个数字会让切片过大 → 交互式请求排队过久。
# 所以这里用实测种子启动，之后由 RateEstimator 用真实观测值自动修正。
EST_SEED = {2: 2.1, 4: 5.3}


class RateEstimator:
    """按倍率维护「单张引擎耗时」的指数滑动平均。

    硬编码常量在这个场景下必然失准：2x 与 4x 成本差 4.5 倍，彩色与黑白又差数倍。
    每跑完一个切片就用真实观测值修正，切片张数因此自动适配当前素材。
    """

    def __init__(self, seeds: dict[int, float], alpha: float = 0.35) -> None:
        self._ema = dict(seeds)
        self._alpha = alpha
        self._lock = threading.Lock()

    def get(self, scale: int) -> float:
        with self._lock:
            return self._ema.get(scale, max(self._ema.values(), default=2.5))

    def observe(self, scale: int, per_image_s: float) -> None:
        if per_image_s <= 0:
            return
        with self._lock:
            prev = self._ema.get(scale, per_image_s)
            self._ema[scale] = prev * (1 - self._alpha) + per_image_s * self._alpha

    def snapshot(self) -> dict:
        with self._lock:
            return {f"{k}x": round(v, 3) for k, v in sorted(self._ema.items())}


RATES = RateEstimator(EST_SEED)


def est_seconds(scale: int) -> float:
    """单张预计引擎耗时（秒）。由 RateEstimator 自适应，不用硬编码常量。"""
    return RATES.get(scale)

START_TS = time.time()

def _force_utf8_streams() -> None:
    """把 stdout / stderr 的编码强制为 UTF-8。

    Windows 控制台与重定向管道默认走 locale 编码（中文环境是 GBK / cp936）。本服务日志
    含中文，以及 `→` / `≈` / `★` 一类非 GBK 字符；一旦宿主把输出接进管道，Python 会按
    locale 去 encode，遇到这类字符直接 `UnicodeEncodeError` —— **崩在写日志这一步**，
    而报错本身也写不出来，表现为"进程静默消失"（P0 实测踩到过这种零输出退出）。

    `errors='replace'` 兜底：即使仍有个别字符不被支持，也只是显示成 `?`，不会中断服务。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError, OSError):
            # 被替换成非 TextIOWrapper（pytest 捕获、已关闭的流等）时忽略
            pass


_force_utf8_streams()

_log_handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]

# 宿主托管时（尤其 Windows 桌面端）额外落盘：进程被强杀 / 看门狗 os._exit 之后，
# stdout 会随管道一起丢失，只有文件里还留着上一次的死因。
_log_file = os.environ.get("MJN_LOG_FILE", "").strip()
if _log_file:
    try:
        Path(_log_file).parent.mkdir(parents=True, exist_ok=True)
        _log_handlers.append(
            logging.handlers.RotatingFileHandler(
                _log_file,
                maxBytes=4 * 1024 * 1024,
                backupCount=3,
                encoding="utf-8",
            )
        )
    except OSError as exc:
        print(f"warn: 日志文件 {_log_file} 不可用，仅输出到 stdout：{exc}",
              file=sys.stderr)

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    handlers=_log_handlers,
    force=True,
)
log = logging.getLogger("mjn")


BULK_SLICE_MAX = int(os.environ.get("MJN_BULK_SLICE_MAX", "8"))
# 交互式请求「最近出现过」的时间窗：窗内的批量切片会缩到 1 张，保证翻页不被压住。
INTERACTIVE_WINDOW_S = float(os.environ.get("MJN_INTERACTIVE_WINDOW_S", "10"))


# =============================================================================
# 引导 chaiNNer 后端（必须在 import run_upscale 之前完成）
# =============================================================================


def _bootstrap_backend():
    """写 bootstrap settings、设置 sys.argv、切 cwd，然后 import 后端模块。

    后端 ``run_upscale.py`` 在 **模块级** 就调用 ``parse_settings_from_cli()``
    读取 ``sys.argv`` 里的 ``--settings``，所以这些准备工作必须先做完。
    """
    models_dir = MODELS_DIR
    boot_dir = Path(tempfile.mkdtemp(prefix="mjn-boot-"))
    boot_file = boot_dir / "bootstrap.json"
    boot_file.write_text(
        json.dumps(
            {
                "SelectedDeviceIndex": DEVICE_INDEX,
                "UseFp16": USE_FP16,
                "ModelsDirectory": models_dir,
                "SelectedWorkflowIndex": 0,
                "Workflows": {
                    "$values": [
                        {
                            "SelectedTabIndex": 1,
                            "GrayscaleDetectionThreshold": DEFAULT_THRESHOLD,
                            "Chains": {"$values": []},
                        }
                    ]
                },
            }
        ),
        encoding="utf-8",
    )

    if not os.path.isdir(SRC_DIR):
        raise SystemExit(f"后端目录不存在：{SRC_DIR}")
    os.chdir(SRC_DIR)
    sys.path.insert(0, SRC_DIR)
    sys.argv = ["run_upscale.py", "--settings", str(boot_file)]

    import run_upscale as ru  # noqa: E402  （必须在前面的准备之后）

    # 后端的 spandrel_custom.install() 只在 __main__ 分支里执行；
    # 作为模块导入时不会跑，必须自己调 —— 否则自定义架构无法识别。
    ru.spandrel_custom.install()
    return ru


log.info("引导 chaiNNer 后端：src=%s models=%s", SRC_DIR, MODELS_DIR)
_t0 = time.time()
ru = _bootstrap_backend()
log.info("后端引导完成，用时 %.1f s", time.time() - _t0)

try:
    import torch

    GPU_NAME = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU"
    CUDA_OK = bool(torch.cuda.is_available())
except Exception as _e:  # pragma: no cover
    torch = None  # type: ignore[assignment]
    GPU_NAME = f"unknown ({_e})"
    CUDA_OK = False

log.info("设备：%s（cuda_available=%s, fp16=%s, tile=%s）", GPU_NAME, CUDA_OK, USE_FP16, TILE)


# =============================================================================
# 引擎
# =============================================================================


class Engine:
    """常驻超分引擎：模型缓存复用后端模块级的 ``loaded_models``。"""

    def __init__(self) -> None:
        self.ru = ru
        self.chains = build_chains(TILE)
        # 直接复用后端的模块级缓存，保证「每个模型每进程只从磁盘读一次」的既有语义
        self.loaded: dict[str, Any] = ru.loaded_models
        self._model_lock = threading.Lock()
        self.stats = {"images": 0, "errors": 0, "last_total_ms": None}
        self.warmup_state = "pending" if PRELOAD else "disabled"

    # ---- 模型 ----

    def missing_models(self) -> list[str]:
        return [m for m in required_model_files() if not (Path(MODELS_DIR) / m).exists()]

    def _get_model(self, model_path: str):
        model = self.loaded.get(model_path)
        if model is not None:
            return model
        with self._model_lock:
            model = self.loaded.get(model_path)
            if model is None:
                t0 = time.time()
                model, _, _ = self.ru.load_model_node(self.ru.context, Path(model_path))
                self.loaded[model_path] = model
                log.info("载入模型 %s（%.2f s）", Path(model_path).name, time.time() - t0)
        return model

    def warmup(self) -> None:
        """预加载白名单模型，避免首个请求付模型加载开销。"""
        self.warmup_state = "running"
        t0 = time.time()
        ok = 0
        for name in required_model_files():
            path = str(Path(MODELS_DIR) / name)
            if not os.path.exists(path):
                continue
            try:
                self._get_model(path)
                ok += 1
            except Exception as e:
                log.warning("预热失败 %s: %s", name, e)
        self.warmup_state = "done"
        log.info("预热完成：%d 个模型，用时 %.1f s", ok, time.time() - t0)

    # ---- 流水线 ----

    def _apply_pre_resize(self, image, chain: dict):
        """链上配置的「放大前缩放」。本项目所有链均为 no-op（0/0/100），
        这里保持与后端 ``preprocess_worker_image`` 完全一致的语义。"""
        rh = chain["ResizeHeightBeforeUpscale"]
        rw = chain["ResizeWidthBeforeUpscale"]
        rf = chain["ResizeFactorBeforeUpscale"]
        if rh == 0 and rw == 0 and rf == 100:
            return image
        h, w, _ = self.ru.get_h_w_c(image)
        if rh != 0 and rw != 0:
            size = (rw, rh)
        elif rh != 0:
            size = (round(w * rh / h), rh)
        elif rw != 0:
            size = (rw, round(h * rw / w))
        else:
            size = (round(w * rf / 100), round(h * rf / 100))
        return self.ru.standard_resize(image, size)

    def _preprocess(self, src: str, dst: str, scale: int, threshold: int, fmt: str) -> dict:
        r = self.ru
        image = r._read_image_from_path(src)
        chain, is_gray, ow, oh = r.get_chain_for_image(
            image, scale, 0, 0, self.chains, threshold
        )

        if is_gray:
            image = r.convert_image_to_grayscale(image)

        model = None
        tile_str = ""
        if chain is not None:
            image = self._apply_pre_resize(image, chain)
            if is_gray and chain["AutoAdjustLevels"]:
                image = r.enhance_contrast(image)
            else:
                image = r.normalize(image)
            model_path = r.get_model_abs_path(chain["ModelFilePath"])
            if not os.path.exists(model_path):
                raise FileNotFoundError(model_path)
            model = self._get_model(model_path)
            tile_str = chain["ModelTileSize"]
        else:
            # 无链命中 = 不放大，按 normalize 原样保存（与后端行为一致）
            log.warning("无链命中，将不放大：%s", src)
            image = r.normalize(image)

        return {
            "image": image,
            "dst": dst,
            "is_gray": is_gray,
            "ow": ow,
            "oh": oh,
            "tile": r.get_tile_size(tile_str),
            "model": model,
            "fmt": fmt,
        }

    def _save(self, p: dict, scale: int, quality: int, lossless: bool) -> None:
        self.ru.save_image(
            p["image"], p["dst"], p["fmt"], quality, lossless,
            p["ow"], p["oh"], scale, 0, 0, p["is_gray"],
        )

    def run(
        self,
        jobs: list[tuple[str, str]],
        *,
        scale: int,
        threshold: int,
        fmt: str,
        quality: int,
        lossless: bool,
        on_progress: Callable[[int, int], None] | None = None,
    ) -> dict:
        """串行跑一批 (src, dst)。返回 {total, done, failed[], timings}。

        三段流水线：preprocess(线程) → upscale(线程，吃 GPU) → postprocess(线程，编码落盘)。
        队列深度都是 1，和原来的多进程版本一致；区别只在于**不 fork**、且每张图独立容错。
        """
        total = len(jobs)
        result: dict[str, Any] = {"total": total, "done": 0, "failed": []}
        timings = {"gpu_ms": 0.0, "encode_ms": 0.0}
        q_pre: Queue = Queue(maxsize=1)
        q_up: Queue = Queue(maxsize=1)

        def pre() -> None:
            try:
                for src, dst in jobs:
                    try:
                        q_pre.put(("ok", self._preprocess(src, dst, scale, threshold, fmt)))
                    except Exception as e:
                        log.warning("预处理失败 %s: %s", src, e)
                        q_pre.put(("err", {"src": src, "error": f"{type(e).__name__}: {e}"}))
            finally:
                q_pre.put(None)

        def up() -> None:
            try:
                while True:
                    item = q_pre.get()
                    if item is None:
                        break
                    kind, payload = item
                    if kind == "err":
                        q_up.put(("err", payload))
                        continue
                    try:
                        t0 = time.time()
                        img = self.ru.ai_upscale_image(
                            payload["image"], payload["tile"], payload["model"]
                        )
                        if payload["is_gray"]:
                            img = self.ru.convert_image_to_grayscale(img)
                        payload["image"] = img
                        timings["gpu_ms"] += (time.time() - t0) * 1000.0
                        q_up.put(("ok", payload))
                    except Exception as e:
                        log.warning("推理失败 %s: %s", payload.get("dst"), e)
                        q_up.put(("err", {"src": payload.get("dst"),
                                          "error": f"{type(e).__name__}: {e}"}))
            finally:
                q_up.put(None)

        def post() -> None:
            while True:
                item = q_up.get()
                if item is None:
                    break
                kind, payload = item
                if kind == "err":
                    result["failed"].append(payload)
                else:
                    try:
                        t0 = time.time()
                        self._save(payload, scale, quality, lossless)
                        timings["encode_ms"] += (time.time() - t0) * 1000.0
                        result["done"] += 1
                    except Exception as e:
                        log.warning("保存失败 %s: %s", payload.get("dst"), e)
                        result["failed"].append({"src": payload.get("dst"),
                                                 "error": f"{type(e).__name__}: {e}"})
                if on_progress is not None:
                    try:
                        on_progress(result["done"] + len(result["failed"]), total)
                    except Exception:
                        pass

        threads = [
            threading.Thread(target=pre, name="mjn-pre", daemon=True),
            threading.Thread(target=up, name="mjn-up", daemon=True),
            threading.Thread(target=post, name="mjn-post", daemon=True),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        result["timings"] = timings
        self.stats["images"] += result["done"]
        self.stats["errors"] += len(result["failed"])
        return result


# =============================================================================
# 看门狗
# =============================================================================


class Watchdog(threading.Thread):
    """盯当前作业的 deadline；超时直接退出进程，交给 systemd 重启。

    为什么用 os._exit 而不是抛异常：作业楔住时，挂死的是线程或 CUDA 状态，
    在同一个进程里「往上报错然后继续用」是不可靠的。整进程退出 + systemd 拉起
    是唯一能保证清干净的手段（代价是重启期间 HTTP 也不可用，单人自用可接受）。
    """

    def __init__(self, poll: float = 2.0) -> None:
        super().__init__(name="mjn-watchdog", daemon=True)
        self._poll = poll
        self._lock = threading.Lock()
        self._deadline: float | None = None
        self._label = ""

    def arm(self, label: str, seconds: float) -> None:
        with self._lock:
            self._label = label
            self._deadline = time.time() + seconds

    def disarm(self) -> None:
        with self._lock:
            self._deadline = None
            self._label = ""

    def run(self) -> None:
        while True:
            time.sleep(self._poll)
            with self._lock:
                deadline, label = self._deadline, self._label
            if deadline is not None and time.time() > deadline:
                log.critical("作业超过 deadline，强制退出进程交由 systemd 重启：%s", label)
                sys.stdout.flush()
                sys.stderr.flush()
                os._exit(1)


WATCHDOG = Watchdog()
WATCHDOG.start()


# =============================================================================
# 调度器
# =============================================================================


class QueueFull(Exception):
    pass


@dataclass
class Task:
    kind: str  # "interactive" | "bulk"
    jobs: list[tuple[str, str]]
    scale: int
    threshold: int
    fmt: str
    quality: int
    lossless: bool
    future: concurrent.futures.Future
    on_progress: Callable[[int, int], None] | None = None
    label: str = ""
    # 用 monotonic 而不是 time.time()：WSL 的挂钟会被宿主同步而发生跳变，
    # 实测出现过 queue_ms = -854.7 这种负值。monotonic 只单调递增，不受影响。
    enqueued_at: float = field(default_factory=time.monotonic)
    total: int = 0
    acc: dict = field(default_factory=lambda: {"done": 0, "failed": []})
    queue_ms: float = 0.0
    canceled: bool = False
    job_id: str = ""

    def __post_init__(self) -> None:
        self.total = self.total or len(self.jobs)


class Scheduler:
    """两通道优先级 + 时间预算切片。

    - 引擎空闲时**永远优先**取交互式队列。
    - 批量任务每片最多连续跑 ``slice_budget`` 秒，到点把剩余工作插回队首再让出。
      切片按**时间预算**而非张数：2x 单张 0.57 s、4x 单张 2.56 s 差 4.5 倍，
      按张数切会让延迟上限随模型浮动。
    - 单消费线程 ⇒ 物理上同一时刻只有一个推理在跑（实测多进程并行反而慢 20%）。
    """

    def __init__(self, engine: Engine, slice_budget: float, queue_max: int) -> None:
        self.engine = engine
        self.slice_budget = slice_budget
        self.queue_max = queue_max
        self._q_int: deque[Task] = deque()
        self._q_bulk: deque[Task] = deque()
        self._cv = threading.Condition()
        self.depth = 0
        self.current_label = ""
        self.current_kind = ""
        self._last_interactive = -1e9
        threading.Thread(target=self._loop, name="mjn-sched", daemon=True).start()

    def submit(self, task: Task) -> concurrent.futures.Future:
        with self._cv:
            if self.depth >= self.queue_max:
                raise QueueFull(f"队列已满（{self.depth}/{self.queue_max}）")
            self.depth += 1
            if task.kind == "interactive":
                self._last_interactive = time.monotonic()
                self._q_int.append(task)
            else:
                self._q_bulk.append(task)
            self._cv.notify()
        return task.future

    def cancel(self, job_id: str) -> bool:
        """标记取消。已入队的直接丢弃，正在跑的等当前切片结束自然收尾。

        注意：**不能直接删作业目录** —— 正在跑的切片还在往里写，
        删了会让 pyvips 刷一屏 `file does not exist`（实测过）。
        """
        found = False
        with self._cv:
            for q in (self._q_int, self._q_bulk):
                for t in list(q):
                    if t.job_id == job_id:
                        t.canceled = True
                        t.jobs = []
                        found = True
        return found

    def snapshot(self) -> dict:
        with self._cv:
            return {
                "depth": self.depth,
                "max": self.queue_max,
                "interactive_waiting": len(self._q_int),
                "bulk_waiting": len(self._q_bulk),
                "current": self.current_label,
                "current_kind": self.current_kind,
                "slice_budget_s": self.slice_budget,
                "bulk_slice_max": BULK_SLICE_MAX,
                "per_image_est_s": RATES.snapshot(),
            }

    # ---- 内部 ----

    def _loop(self) -> None:
        while True:
            with self._cv:
                while not self._q_int and not self._q_bulk:
                    self._cv.wait()
            self._run_one()

    def _bulk_slice_size(self, scale: int) -> int:
        """批量任务一次连续处理多少张。

        **交互式请求的排队上限完全由这个值决定**（它必须等当前切片跑完才能上 GPU）。
        所以策略是：
          - 最近有交互式请求 → 切片缩到 1 张，翻页最多等一张的时间；
          - 一直没人看图 → 用满时间预算，让三段流水线有重叠、保住批量吞吐。
        切片太小会丢掉 preprocess/upscale/encode 的重叠，批量吞吐会明显下降，
        所以不能无脑取 1。
        """
        if time.monotonic() - self._last_interactive < INTERACTIVE_WINDOW_S:
            return 1
        per = est_seconds(scale)
        return max(1, min(BULK_SLICE_MAX, int(round(self.slice_budget / per))))

    def _take(self) -> tuple[Task, list[tuple[str, str]], bool] | None:
        """取下一个执行单元。返回 (task, jobs_slice, finished)。"""
        with self._cv:
            if self._q_int:
                task = self._q_int.popleft()
                return task, task.jobs, True
            if not self._q_bulk:
                return None
            task = self._q_bulk.popleft()
            n = self._bulk_slice_size(task.scale)
            jobs, rest = task.jobs[:n], task.jobs[n:]
            task.jobs = rest
            finished = not rest
            if not finished:
                self._q_bulk.appendleft(task)  # 保序：剩余工作回到队首
            return task, jobs, finished

    def _run_one(self) -> None:
        taken = self._take()
        if taken is None:
            return
        task, jobs, finished = taken

        if task.canceled:
            log.info("作业已取消，跳过剩余 %d 张：%s", len(jobs), task.label)
            jobs = []

        # monotonic + 下限钳 0：挂钟跳变曾产生过负值
        task.queue_ms = max(0.0, (time.monotonic() - task.enqueued_at) * 1000.0)
        self.current_label = task.label
        self.current_kind = task.kind

        # deadline：切片本身的预计耗时 ×10 + 60 s 余量（覆盖模型首次加载）
        budget_s = len(jobs) * est_seconds(task.scale) * 10.0 + 60.0
        WATCHDOG.arm(f"{task.label} ({len(jobs)} 张)", budget_s)
        t_start = time.monotonic()
        try:
            res = self.engine.run(
                jobs,
                scale=task.scale,
                threshold=task.threshold,
                fmt=task.fmt,
                quality=task.quality,
                lossless=task.lossless,
                on_progress=self._progress_cb(task),
            )
        except BaseException as e:  # noqa: BLE001
            log.exception("作业异常：%s", task.label)
            if not task.future.done():
                task.future.set_exception(e)
            with self._cv:
                self.depth -= 1
            WATCHDOG.disarm()
            self.current_label = ""
            self.current_kind = ""
            return
        finally:
            WATCHDOG.disarm()

        # 用真实观测修正「单张耗时」估计，切片张数下一轮就自动适配当前素材
        if jobs:
            RATES.observe(task.scale, (time.monotonic() - t_start) / len(jobs))

        task.acc["done"] += res["done"]
        task.acc["failed"].extend(res["failed"])
        task.acc.setdefault("timings", {"gpu_ms": 0.0, "encode_ms": 0.0})
        task.acc["timings"]["gpu_ms"] += res["timings"]["gpu_ms"]
        task.acc["timings"]["encode_ms"] += res["timings"]["encode_ms"]

        if finished:
            with self._cv:
                self.depth -= 1
                notify = True
            self.current_label = ""
            self.current_kind = ""
            if not task.future.done():
                task.future.set_result(
                    {
                        "total": task.total,
                        "done": task.acc["done"],
                        "failed": task.acc["failed"],
                        "queue_ms": round(task.queue_ms, 1),
                        "gpu_ms": round(task.acc["timings"]["gpu_ms"], 1),
                        "encode_ms": round(task.acc["timings"]["encode_ms"], 1),
                    }
                )
            if notify:
                with self._cv:
                    self._cv.notify_all()

    @staticmethod
    def _progress_cb(task: Task) -> Callable[[int, int], None]:
        def cb(slice_done: int, _slice_total: int) -> None:
            if task.on_progress is not None:
                task.on_progress(task.acc["done"] + slice_done, task.total)
        return cb


# =============================================================================
# 作业存储
# =============================================================================


class JobStore:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._jobs: dict[str, dict] = {}

    def create(self, job_id: str, kind: str, total: int) -> dict:
        d = self.root / job_id
        (d / "in").mkdir(parents=True, exist_ok=True)
        (d / "out").mkdir(parents=True, exist_ok=True)
        rec = {
            "id": job_id,
            "kind": kind,
            "status": "queued",
            "total": total,
            "done": 0,
            "failed": [],
            "error": None,
            "created": time.time(),
            "started": None,
            "finished": None,
            "dir": d,
            "zip": None,
        }
        with self._lock:
            self._jobs[job_id] = rec
        return rec

    def get(self, job_id: str) -> dict | None:
        with self._lock:
            return self._jobs.get(job_id)

    def update(self, job_id: str, **kw) -> None:
        with self._lock:
            rec = self._jobs.get(job_id)
            if rec:
                rec.update(kw)

    def info(self, rec: dict) -> dict:
        return {
            "id": rec["id"],
            "kind": rec["kind"],
            "status": rec["status"],
            "total": rec["total"],
            "done": rec["done"],
            "failed": rec["failed"],
            "error": rec["error"],
            "created": rec["created"],
            "finished": rec["finished"],
        }

    def pack_zip(self, rec: dict) -> Path:
        """把 out/ 里的结果打成 ZIP（缓存）。ZIP_STORED：WebP 本身已压缩。"""
        with self._lock:
            if rec["zip"] is not None and Path(rec["zip"]).exists():
                return Path(rec["zip"])
        out_dir: Path = rec["dir"] / "out"
        zip_path = rec["dir"] / "result.zip"
        tmp = rec["dir"] / "result.zip.part"
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
            for f in sorted(out_dir.iterdir(), key=lambda p: p.name):
                if f.is_file():
                    z.write(f, f.name)
        tmp.replace(zip_path)
        self.update(rec["id"], zip=str(zip_path))
        return zip_path

    def sweep(self, ttl_s: int) -> None:
        now = time.time()
        with self._lock:
            stale = [
                k for k, r in self._jobs.items()
                if r["finished"] and now - r["finished"] > ttl_s
            ]
            for k in stale:
                rec = self._jobs.pop(k)
                shutil.rmtree(rec["dir"], ignore_errors=True)
        if stale:
            log.info("清理过期作业 %d 个", len(stale))


# =============================================================================
# 服务装配
# =============================================================================

WORK_DIR.mkdir(parents=True, exist_ok=True)
ENGINE = Engine()
SCHED = Scheduler(ENGINE, SLICE_BUDGET, QUEUE_MAX)
JOBS = JobStore(WORK_DIR / "jobs")


def _janitor() -> None:
    while True:
        time.sleep(600)
        try:
            JOBS.sweep(JOB_TTL_S)
        except Exception:
            log.exception("清理任务异常")


if PRELOAD:
    threading.Thread(target=ENGINE.warmup, name="mjn-warmup", daemon=True).start()
threading.Thread(target=_janitor, name="mjn-janitor", daemon=True).start()


def _gpu_info() -> dict:
    if torch is None or not CUDA_OK:
        return {"available": False, "name": GPU_NAME}
    try:
        free, total = torch.cuda.mem_get_info()
        return {
            "available": True,
            "name": GPU_NAME,
            "mem_free_mb": round(free / 2**20),
            "mem_total_mb": round(total / 2**20),
        }
    except Exception as e:  # pragma: no cover
        return {"available": True, "name": GPU_NAME, "error": str(e)}


def _run_param(request, name: str, default, cast):
    raw = request.args.get(name)
    if raw is None or raw == "":
        return default
    try:
        return cast(raw)
    except (TypeError, ValueError):
        raise ValueError(f"参数 {name} 非法：{raw!r}") from None


def _validate(request) -> tuple[int, int, str, int, bool]:
    scale = _run_param(request, "scale", DEFAULT_SCALE, int)
    if scale not in ALLOWED_SCALES:
        raise ValueError(f"scale 只允许 {sorted(ALLOWED_SCALES)}，收到 {scale}")
    threshold = _run_param(request, "threshold", DEFAULT_THRESHOLD, int)
    fmt = str(_run_param(request, "format", DEFAULT_FORMAT, str)).lower()
    if fmt not in FORMATS:
        raise ValueError(f"format 只允许 {sorted(FORMATS)}，收到 {fmt}")
    quality = _run_param(request, "quality", DEFAULT_QUALITY, int)
    quality = max(1, min(100, quality))
    lossless = str(_run_param(request, "lossless", "0", str)).lower() in ("1", "true", "yes")
    return scale, threshold, fmt, quality, lossless


def _timing_headers(res: dict, t0: float) -> dict:
    return {
        "X-Mjn-Queue-Ms": str(res.get("queue_ms", 0)),
        "X-Mjn-Gpu-Ms": str(res.get("gpu_ms", 0)),
        "X-Mjn-Encode-Ms": str(res.get("encode_ms", 0)),
        "X-Mjn-Total-Ms": str(round((time.time() - t0) * 1000.0, 1)),
    }


async def _read_body(request) -> bytes:
    """读取原始请求体。

    Sanic 各版本对 ``request.body`` 的形态不一致：24.6 里它已经是解析好的 ``bytes``
    （直接 ``await`` 会报 ``TypeError: object bytes can't be used in 'await' expression``），
    而更早的版本返回 awaitable。这里两种都兼容。
    """
    body = request.body
    if inspect.isawaitable(body):
        body = await body
    return bytes(body or b"")


try:
    from sanic import Sanic, response
    from sanic.request import Request

    # Sanic 24.6 已删除 `response.stream`，流式响应用 ResponseStream。
    # （踩过：写 response.stream(...) 会 AttributeError，批量结果下载整个接口 500。）
    from sanic.response import ResponseStream
except ImportError as e:  # pragma: no cover
    raise SystemExit(f"sanic 未安装：{e}") from e

app = Sanic("mjn-upscale")
app.config.REQUEST_MAX_SIZE = 512 * 1024 * 1024  # 整本 CBZ 上传
app.config.REQUEST_TIMEOUT = 300
app.config.RESPONSE_TIMEOUT = 3600
app.config.KEEP_ALIVE = 30


@app.middleware("request")
async def _auth(request: Request):
    """除 /v1/health 外都要求 X-Api-Key（或 Bearer）。未配置 key 时全放开。"""
    if not API_KEY or request.path == "/v1/health":
        return None
    supplied = request.headers.get("x-api-key", "")
    if not supplied:
        auth = request.headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            supplied = auth[7:].strip()
    if supplied != API_KEY:
        return response.json({"error": "unauthorized"}, status=401)
    return None


@app.get("/v1/health")
async def health(request: Request):
    return response.json(
        {
            "ok": True,
            "service": "mjn-upscale",
            "uptime_s": round(time.time() - START_TS, 1),
            "engine": {
                "cuda": CUDA_OK,
                "device": GPU_NAME,
                "fp16": USE_FP16,
                "tile": TILE,
                "warmup": ENGINE.warmup_state,
                "loaded_models": len(ENGINE.loaded),
                "stats": ENGINE.stats,
            },
            "gpu": _gpu_info(),
            "queue": SCHED.snapshot(),
            "models": {
                "dir": MODELS_DIR,
                "missing": ENGINE.missing_models(),
            },
            "config": {
                "allowed_scales": sorted(ALLOWED_SCALES),
                "default_format": DEFAULT_FORMAT,
                "auth_required": bool(API_KEY),
            },
        }
    )


@app.get("/v1/models")
async def list_models(request: Request):
    missing = set(ENGINE.missing_models())
    return response.json(
        {
            "dir": MODELS_DIR,
            "ready": [m for m in required_model_files() if m not in missing],
            "missing": sorted(missing),
            "loaded_in_memory": len(ENGINE.loaded),
        }
    )


@app.post("/v1/upscale")
async def upscale(request: Request):
    """单图超分（交互式通道）。body = 裸图片字节。"""
    t0 = time.time()
    try:
        scale, threshold, fmt, quality, lossless = _validate(request)
    except ValueError as e:
        return response.json({"error": str(e)}, status=400)

    body = await _read_body(request)
    if not body:
        return response.json({"error": "空请求体"}, status=400)

    job_id = uuid.uuid4().hex
    rec = JOBS.create(job_id, "interactive", 1)
    src = rec["dir"] / "in" / "input"
    src.write_bytes(body)
    ext, mime = FORMATS[fmt]
    dst = rec["dir"] / "out" / f"result.{ext}"

    fut: concurrent.futures.Future = concurrent.futures.Future()
    task = Task(
        kind="interactive",
        jobs=[(str(src), str(dst))],
        scale=scale,
        threshold=threshold,
        fmt=fmt,
        quality=quality,
        lossless=lossless,
        future=fut,
        label=f"single {scale}x {len(body) // 1024}KB",
    )
    JOBS.update(job_id, status="running", started=time.time())
    try:
        SCHED.submit(task)
    except QueueFull as e:
        JOBS.update(job_id, status="error", error=str(e), finished=time.time())
        return response.json({"error": str(e)}, status=503)

    try:
        res = await asyncio.wrap_future(fut)
    except Exception as e:
        log.exception("单图超分失败")
        JOBS.update(job_id, status="error", error=str(e), finished=time.time())
        return response.json({"error": f"{type(e).__name__}: {e}"}, status=500)

    if res["failed"] or not dst.exists():
        err = res["failed"][0]["error"] if res["failed"] else "输出文件未生成"
        JOBS.update(job_id, status="error", error=err, finished=time.time())
        shutil.rmtree(rec["dir"], ignore_errors=True)
        return response.json({"error": err}, status=500)

    data = dst.read_bytes()
    JOBS.update(job_id, status="done", done=1, finished=time.time())
    shutil.rmtree(rec["dir"], ignore_errors=True)
    with __import__("contextlib").suppress(Exception):
        pass
    return response.raw(data, content_type=mime, headers=_timing_headers(res, t0))


@app.post("/v1/jobs")
async def create_job(request: Request):
    """批量超分（批量通道）。body = 内含多张图片的 ZIP，按条目名排序。"""
    try:
        scale, threshold, fmt, quality, lossless = _validate(request)
    except ValueError as e:
        return response.json({"error": str(e)}, status=400)

    body = await _read_body(request)
    if not body:
        return response.json({"error": "空请求体"}, status=400)

    job_id = uuid.uuid4().hex
    rec = JOBS.create(job_id, "bulk", 0)
    in_dir: Path = rec["dir"] / "in"
    out_dir: Path = rec["dir"] / "out"
    ext, _mime = FORMATS[fmt]

    jobs: list[tuple[str, str]] = []
    try:
        with zipfile.ZipFile(io.BytesIO(body)) as z:
            names = sorted(
                (i for i in z.infolist() if not i.is_dir()),
                key=lambda i: i.filename,
            )
            seen: dict[str, int] = {}
            for info in names:
                if Path(info.filename).suffix.lower() not in IMAGE_EXTS:
                    continue
                base = Path(info.filename).name
                if base in seen:
                    seen[base] += 1
                    stem = Path(base).stem
                    base = f"{stem}__{seen[base]}{Path(base).suffix}"
                else:
                    seen[base] = 0
                (in_dir / base).write_bytes(z.read(info))
                jobs.append((str(in_dir / base),
                             str(out_dir / f"{Path(base).stem}.{ext}")))
    except zipfile.BadZipFile:
        JOBS.update(job_id, status="error", error="不是合法的 ZIP", finished=time.time())
        return response.json({"error": "请求体不是合法的 ZIP"}, status=400)

    if not jobs:
        JOBS.update(job_id, status="error", error="ZIP 里没有图片", finished=time.time())
        return response.json({"error": "ZIP 里没有可识别的图片"}, status=400)

    JOBS.update(job_id, total=len(jobs))

    def on_progress(done: int, total: int) -> None:
        JOBS.update(job_id, done=done, total=total)

    fut: concurrent.futures.Future = concurrent.futures.Future()
    task = Task(
        kind="bulk",
        jobs=jobs,
        scale=scale,
        threshold=threshold,
        fmt=fmt,
        quality=quality,
        lossless=lossless,
        future=fut,
        on_progress=on_progress,
        label=f"bulk {len(jobs)} 张 {scale}x",
        job_id=job_id,
    )
    JOBS.update(job_id, status="running", started=time.time(), task=task)
    try:
        SCHED.submit(task)
    except QueueFull as e:
        JOBS.update(job_id, status="error", error=str(e), finished=time.time())
        return response.json({"error": str(e)}, status=503)

    def _finish(f: concurrent.futures.Future) -> None:
        # 取消是异步生效的（等当前切片结束），别让完成回调把 canceled 覆盖成 done
        if (JOBS.get(job_id) or {}).get("status") == "canceled":
            JOBS.update(job_id, finished=time.time())
            return
        if f.cancelled():
            JOBS.update(job_id, status="canceled", finished=time.time())
        elif f.exception() is not None:
            JOBS.update(job_id, status="error",
                        error=f"{type(f.exception()).__name__}: {f.exception()}",
                        finished=time.time())
        else:
            r = f.result()
            JOBS.update(job_id, status="done", done=r["done"], failed=r["failed"],
                        finished=time.time())

    fut.add_done_callback(_finish)
    return response.json({"job_id": job_id, "total": len(jobs),
                          "scale": scale, "format": fmt})


@app.get("/v1/jobs/<job_id:str>")
async def job_status(request: Request, job_id: str):
    rec = JOBS.get(job_id)
    if rec is None:
        return response.json({"error": "job 不存在"}, status=404)
    return response.json(JOBS.info(rec))


@app.get("/v1/jobs/<job_id:str>/result")
async def job_result(request: Request, job_id: str):
    rec = JOBS.get(job_id)
    if rec is None:
        return response.json({"error": "job 不存在"}, status=404)
    if rec["status"] != "done":
        return response.json({"error": f"job 尚未完成（{rec['status']}）"}, status=409)

    def _pack() -> Path:
        return JOBS.pack_zip(rec)

    path = await asyncio.to_thread(_pack)
    headers = {
        "Content-Disposition": f'attachment; filename="mjn-{job_id[:8]}.zip"',
    }

    async def _gen(stream) -> None:
        with path.open("rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                await stream.write(chunk)

    # ⚠️ 必须**直接返回** ResponseStream，绝不能 await 它。
    #
    # ResponseStream 实现了 __await__，所以 isinstance 检查 / inspect.isawaitable 都会说它可等待；
    # 但它的 stream() 第一件事就是 `if not self.request: raise ServerError(...)`,
    # 而 self.request 是由 Sanic 在 handle_request 里通过 __call__(request) 注入的。
    # 提前 await 会直接抛 "Attempted response to unknown request"（实测踩过，整个批量接口 500）。
    return ResponseStream(_gen, content_type="application/zip", headers=headers)


@app.delete("/v1/jobs/<job_id:str>")
async def job_delete(request: Request, job_id: str):
    rec = JOBS.get(job_id)
    if rec is None:
        return response.json({"error": "job 不存在"}, status=404)

    if rec["status"] in ("queued", "running"):
        # ⚠️ 运行中绝不能直接 rmtree 作业目录：当前切片还在往里写结果，
        # 删掉会让 pyvips 连刷 `VipsForeignLoad: file ... does not exist`（实测踩过）。
        # 正确做法是交给调度器在切片边界收尾，目录等作业真正结束后再删。
        SCHED.cancel(job_id)
        JOBS.update(job_id, status="canceled")
        return response.json({
            "canceled": job_id,
            "note": "运行中的作业已标记取消，目录会在当前切片结束后清理",
        })

    shutil.rmtree(rec["dir"], ignore_errors=True)
    with JOBS._lock:  # noqa: SLF001
        JOBS._jobs.pop(job_id, None)  # noqa: SLF001
    return response.json({"deleted": job_id})


@app.post("/v1/admin/restart")
async def admin_restart(request: Request):
    """主动重启（正常路径是 os._exit + systemd）。"""
    log.warning("收到 /v1/admin/restart，3 秒后退出进程")
    threading.Timer(3.0, lambda: os._exit(1)).start()
    return response.json({"restarting": True})


# =============================================================================
# 启动前的宿主守卫（Windows 托管模式）
# =============================================================================


def _guard_parent_death() -> None:
    """父进程退出时自我了结 —— 托管模式的必须处理项。

    背景：Windows 没有 systemd，服务由 Breeze 作为子进程托管。父进程被强杀
    （任务管理器结束进程、宿主崩溃）时 **Windows 不会回收子进程**，会留下一个占着
    端口、握着数 GB 显存的孤儿 Python。这是托管模型唯一的硬伤。

    做法（不依赖任何 Windows API）：宿主启动子进程时持有 stdin 的**写端**且不关闭，
    本进程阻塞读 stdin。父进程一死，写端被 OS 关闭 → 读端立刻 EOF → 这里立即退出。
    比轮询父进程 PID 更即时，也不额外占资源。

    ⚠️ 必须显式开启（`MJN_PARENT_STDIN=1`）：Docker / systemd 下 stdin 可能是
    /dev/null 或已关闭，无条件启用会让服务在启动瞬间自杀。
    """
    if os.environ.get("MJN_PARENT_STDIN", "").strip() not in (
        "1", "true", "True", "yes",
    ):
        return

    def _watch() -> None:
        try:
            # 宿主只要持有写端，read 就永远阻塞在这里
            while sys.stdin.read(1) != "":
                pass
        except Exception:  # noqa: BLE001  流被关闭等一律视为父进程已走
            pass
        log.warning("父进程已退出（stdin EOF），跟随退出以免留下孤儿进程")
        os._exit(0)

    threading.Thread(target=_watch, name="parent-watch", daemon=True).start()
    log.info("已启用父进程守护：stdin 关闭即退出")


def _check_port_available() -> None:
    """端口被占用时给出可读结论，而不是让 app.run 抛裸的 bind 异常。

    两种占用要区分开，因为处置方式完全不同：

    - **同类服务**（能应答 /v1/health 且 `service == mjn-upscale`）→ 多半是上一次的
      实例没退干净，或本机已有别的宿主在跑（例如 WSL 侧的 8765 经 portproxy 暴露到
      宿主 127.0.0.1:8765）。退出码 **3**，交给宿主判断「要不要直接复用现有的它」。
    - **其他程序占用** → 退出码 **4**，提示换端口。
    """
    import urllib.error
    import urllib.request

    url = f"http://127.0.0.1:{PORT}/v1/health"
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
    except SystemExit:
        raise
    except (urllib.error.URLError, OSError, ValueError):
        return  # 无人应答 → 端口空闲，正常启动

    if payload.get("service") == "mjn-upscale":
        log.error(
            "端口 %s 上已有一个 mjn-upscale 实例在运行（uptime=%s s，设备=%s）。"
            "若是上一个实例留下的孤儿进程，先结束它；否则直接复用现有实例即可。",
            PORT,
            payload.get("uptime_s"),
            (payload.get("engine") or {}).get("device"),
        )
        raise SystemExit(3)

    log.error(
        "端口 %s 被其他程序占用（/v1/health 有响应但不是本服务）。请改用其他端口。",
        PORT,
    )
    raise SystemExit(4)


if __name__ == "__main__":
    _check_port_available()
    _guard_parent_death()
    log.info("监听 %s:%s（auth=%s）", HOST, PORT, "on" if API_KEY else "off")
    # single_process=True 是**必须**的，不是可选优化：
    # Sanic 默认用 WorkerManager 再起一个工作进程，而它有 worker 会**重新 import 本模块**，
    # 于是 torch 导入 / CUDA 初始化 / 模型预热会在多个进程里各做一遍。
    # 更致命的是模型缓存 `loaded_models` 是进程内的 —— 预热加载的模型留在父进程，
    # 真正干活的 work 进程里一个都没有，等于把"常驻"这个核心设计整个废掉。
    # （实测：不加这个参数时日志里能看到 3 次"引导 chaiNNer 后端"。）
    # 代价是丢掉 Sanic 自身的 worker 崩溃重启，交给容器的 restart 策略兜底。
    app.run(
        host=HOST,
        port=PORT,
        single_process=True,
        access_log=False,
        auto_reload=False,
    )
