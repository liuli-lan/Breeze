"""模型链配置。

与 Breeze `lib/page/setting/real_sr/service/mangajanai_engine.dart` 的
`_buildChains()` 一一对应，保证远程后端与本机后端输出一致。

链匹配规则（后端 `should_chain_activate_for_image`，按数组顺序取第一条命中）：
  1. 图像灰度/彩色判定与 `IsGrayscale` / `IsColor` 一致；
  2. 原图宽高落在 `MinResolution` / `MaxResolution` 区间（`0` = 不限制）；
  3. 目标倍率落在 `MinScaleFactor` / `MaxScaleFactor` 区间。

后端 `MinScaleFactor < target <= MaxScaleFactor`，因此：
  - `MaxScaleFactor = 2` 的链命中 0~2 倍率（用 2x 模型）
  - `MinScaleFactor = 2` 的链命中 >2 倍率（用 4x 模型）
"""

from __future__ import annotations

# ---- 彩色页模型（IllustrationJaNai V3 denoise，与 GUI 默认工作流一致）----
COLOR_MODEL_2X = "2x_IllustrationJaNai_V3denoise_FDAT_M_unshuffle_30k_fp16.safetensors"
COLOR_MODEL_4X = "4x_IllustrationJaNai_V3denoise_FDAT_M_47k_fp16.safetensors"

# ---- 黑白页模型：按原图高度分档（1.5.x 分发的是 V1 ESRGAN .pth 全系列）----
# (最小高度, 最大高度, 档位名, 2x 迭代数, 4x 迭代数)
# 注意 2x / 4x 的迭代数后缀并不一一对应，照表写。
GRAY_BUCKETS: list[tuple[str, str, str, str, str]] = [
    ("0x0",    "0x1250", "1200p", "70k",  "70k"),
    ("0x1251", "0x1350", "1300p", "75k",  "75k"),
    ("0x1351", "0x1450", "1400p", "70k",  "105k"),
    ("0x1451", "0x1550", "1500p", "90k",  "105k"),
    ("0x1551", "0x1760", "1600p", "90k",  "70k"),
    ("0x1761", "0x1984", "1920p", "70k",  "105k"),
    ("0x1985", "0x0",    "2048p", "95k",  "70k"),
]

# 日漫单行本数字版高度多在 1271~1280 → 命中 1300p 档。
DEFAULT_TILE = "512"


def _chain(
    number: str,
    min_resolution: str,
    max_resolution: str,
    is_grayscale: bool,
    min_scale_factor: int,
    max_scale_factor: int,
    model_file_path: str,
    tile: str = DEFAULT_TILE,
    auto_adjust_levels: bool | None = None,
) -> dict:
    """构造单条链。字段名必须与后端 `UpscaleChain` 模型严格一致，不可增删。"""
    return {
        "ChainNumber": number,
        "MinResolution": min_resolution,
        "MaxResolution": max_resolution,
        "IsGrayscale": is_grayscale,
        "IsColor": not is_grayscale,
        "MinScaleFactor": min_scale_factor,
        "MaxScaleFactor": max_scale_factor,
        "ModelFilePath": model_file_path,
        "ModelTileSize": tile,
        "AutoAdjustLevels": is_grayscale if auto_adjust_levels is None else auto_adjust_levels,
        "ResizeHeightBeforeUpscale": 0,
        "ResizeWidthBeforeUpscale": 0,
        "ResizeFactorBeforeUpscale": 100.0,
    }


def build_chains(tile: str = DEFAULT_TILE) -> list[dict]:
    """构建 16 条链：2 条彩色 + 7 档黑白 × 2 个倍率。"""
    chains: list[dict] = [
        _chain("1", "0x0", "0x0", False, 0, 2, COLOR_MODEL_2X, tile),
        _chain("2", "0x0", "0x0", False, 2, 0, COLOR_MODEL_4X, tile),
    ]
    n = 3
    for min_h, max_h, bucket, it2x, it4x in GRAY_BUCKETS:
        chains.append(
            _chain(f"{n}", min_h, max_h, True, 0, 2,
                   f"2x_MangaJaNai_{bucket}_V1_ESRGAN_{it2x}.pth", tile)
        )
        n += 1
        chains.append(
            _chain(f"{n}", min_h, max_h, True, 2, 0,
                   f"4x_MangaJaNai_{bucket}_V1_ESRGAN_{it4x}.pth", tile)
        )
        n += 1
    return chains


def required_model_files() -> list[str]:
    """本配置引用的全部模型文件名。"""
    files = [COLOR_MODEL_2X, COLOR_MODEL_4X]
    for _min_h, _max_h, bucket, it2x, it4x in GRAY_BUCKETS:
        files.append(f"2x_MangaJaNai_{bucket}_V1_ESRGAN_{it2x}.pth")
        files.append(f"4x_MangaJaNai_{bucket}_V1_ESRGAN_{it4x}.pth")
    return files
