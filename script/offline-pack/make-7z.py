"""用 py7zr 打 7z 离线包（CI 用）。

为什么不用 7-Zip：在 windows-2025-vs2026 镜像上，7-Zip 26.03 对
「5.4 GB / 2.3 万个文件」的输入会在建归档的一瞬间报
    System ERROR: The parameter is incorrect.   (exit 2)
同一个二进制对只有两个小文件的目录完全正常，本机 7-Zip 26.01 对同样的
目录也正常 —— 是镜像 + 该版本在大输入下的问题，不是参数写法问题。
py7zr 是纯 Python 实现，不受影响；产出经本机 7-Zip 26.01 `t` 验证为标准 7z。

用法：
    python make-7z.py <源目录> <输出.7z> [压缩级别 0-9]

注意：源目录里的内容会成为归档内的**顶层条目**（例如 `python/`、`models/`），
这正是 Breeze 的导入校验器期望的布局。
"""

import os
import sys
import time

import py7zr


def _force_utf8_streams() -> None:
    """把 stdout/stderr 强推到 UTF-8。

    Windows 上 Python 默认用系统 ANSI 代码页（en-US 的 runner 是 cp1252），
    中文 print 会直接抛 UnicodeEncodeError: 'charmap' codec can't encode。
    与服务端 mjn_service.py 里的同类处理保持一致。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def main() -> int:
    _force_utf8_streams()
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src = os.path.abspath(sys.argv[1])
    out = os.path.abspath(sys.argv[2])
    preset = int(sys.argv[3]) if len(sys.argv) > 3 else 5

    if not os.path.isdir(src):
        print(f"源目录不存在：{src}")
        return 1

    filters = [{"id": py7zr.FILTER_LZMA2, "preset": preset}]
    total = sum(len(files) for _, _, files in os.walk(src))
    print(f"源：{src}\n输出：{out}\n级别：{preset}\n文件数：{total}", flush=True)

    started = time.time()
    count = 0
    with py7zr.SevenZipFile(out, "w", filters=filters) as archive:
        for root, _dirs, files in os.walk(src):
            for name in sorted(files):
                full = os.path.join(root, name)
                arcname = os.path.relpath(full, src)
                archive.write(full, arcname)
                count += 1
                if count % 2000 == 0:
                    print(
                        f"  已写入 {count}/{total}，用时 {time.time() - started:.0f}s",
                        flush=True,
                    )

    size = os.path.getsize(out)
    print(
        f"完成：{count} 个文件 -> {out}\n"
        f"归档大小：{size} 字节（{size / 1024 / 1024:.1f} MB），"
        f"用时 {time.time() - started:.0f}s",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
