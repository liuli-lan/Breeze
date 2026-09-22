# 许可与署名 · MangaJaNai 离线运行环境包

本包由个人 fork（liuli-lan/Breeze）在 GitHub Actions 上组装，**仅供非商业用途**。

## 模型（`models/`）

- **MangaJaNai / IllustrationJaNai 模型** —— 作者 **the-database**，
  许可 **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)**。
- 上游仓库：<https://github.com/the-database/MangaJaNai>
- 本包使用的原始发布物：
  - `MangaJaNai_V1_ModelsOnly.zip`（release 1.0.0）
  - `IllustrationJaNai_V3denoise.zip`（release 3.0.0）
- 许可全文：<https://creativecommons.org/licenses/by-nc/4.0/legalcode>

本包**未修改模型权重**，仅做原样再分发。若你要继续分发本包，必须保留本段署名与
许可声明；**不得用于商业目的**。

## Python 运行时（`python/`）

- CPython 3.12.10 embeddable —— Python Software Foundation License 2.0，
  <https://www.python.org/downloads/release/python-31210/>
- PyTorch / torchvision（cu128）—— BSD-3-Clause，<https://github.com/pytorch/pytorch>
- 其余 pip 依赖（numpy / opencv-python / spandrel / sanic / pyvips / pynvml / psutil 等）
  各自沿用其上游许可，详见 `python/python/Lib/site-packages/*.dist-info/` 下的 LICENSE。

## chaiNNer 后端（`backend/`）

- 来自 **MangaJaNaiConverterGui** 仓库 main 分支的源码（作者 the-database），
  许可 **GPL-3.0**，本包以「随包提供源码」的形式满足其源码开放义务。
  上游：<https://github.com/the-database/MangaJaNaiConverterGui>
- `backend/ImageMagick/*.icc` 随该后端源码一同分发。

## 免责声明

本包按「现状」提供，不附带任何明示或暗示的担保。超分需要 NVIDIA 独立显卡与对应驱动；
无显卡时速度可能慢一到两个数量级。
