# MangaJaNai 离线运行环境包（Windows）

把 Breeze 的 MangaJaNai 本机引擎所需的一切打包好了，**装完不需要联网下载 4 GB**。

## 包含什么

| 目录 | 内容 | 解压后约 |
|---|---|---|
| `python/` | CPython 3.12.10（embeddable）+ torch 2.9.1 / torchvision 0.24.1（cu128）+ 全部依赖 | 4.6 GB |
| `backend/` | chaiNNer 后端源码（`run_upscale.py` + ImageMagick ICC profile） | 几 MB |
| `models/` | 16 个 MangaJaNai / IllustrationJaNai 链模型 | 0.47 GB |
| `LICENSES.md` | 许可与署名 | — |

## 怎么用

1. 把 **所有** `mangajanai-win.7z.00N` 分卷和 `join-volumes.bat` 下载到**同一个文件夹**；
2. 双击 `join-volumes.bat` → 得到单一的 `mangajanai-win.7z`（约 2.x GB）；
3. 用 `SHA256SUMS.txt` 里的哈希核对合并结果；
4. 打开 Breeze：**设定 → 超分 → 超分引擎 → MangaJaNai（本地）→ 运行环境 → 导入运行环境压缩包**，选择合并出来的 `mangajanai-win.7z`；
5. 导入完点「检测 / 启动」拉起常驻服务。

> 为什么分卷：GitHub Release 单个文件上限 2 GB，而这个包解压后约 5 GB、压缩后也超过 2 GB。
> 合并必须是**字节拼接**（`join-volumes.bat` 做的就是这件事），不能用 7-Zip 直接解压 `.001`
> —— 那样得到的是文件夹，而 Breeze 的导入通道只接受单个压缩包文件。
> 也可以手写：`copy /b mangajanai-win.7z.001+mangajanai-win.7z.002 mangajanai-win.7z`
## 环境要求

- **必须是 NVIDIA 独立显卡**（无卡时 CPU 模式慢 20~27 倍，基本不可用）；
- Windows 10/11 x64；
- 解压后约 5 GB、安装峰值建议留 10 GB 空闲磁盘；
- 若用手机连本机超分，PC 与手机需在同一局域网。

## 许可

模型为 **CC BY-NC 4.0（禁止商业用途）**，其余组件各自沿用上游许可。
详见包内 `LICENSES.md` —— 再分发时请务必保留署名与非商业声明。
