"""Pack a local MangaJaNaiConverterGui install into a Breeze engine archive.

Produces ``mangajanai-win.7z`` containing::

    python/    embedded Python 3.13 + PyTorch CUDA + deps (~4.9 GB on disk)
    models/    MangaJaNai / IllustrationJaNai weights (~1.2 GB)
    backend/   chaiNNer Python backend used by run_upscale.py (~1.5 MB)
    LICENSES.md

The archive layout mirrors the GUI install (``python/python``,
``backend/src``, ``models``), so Breeze unpacks it into ``<files>/mangajanai/``
and :class:`MangaJaNaiEngine` can fall back to it when the GUI is not
installed - no GUI install required on the target machine.

Usage (any Python 3.10+; the GUI-bundled interpreter works)::

    "%APPDATA%\\MangaJaNaiConverterGui\\python\\python\\python.exe" \\
        pack_mangajanai_windows.py [--out mangajanai-win.7z] [--smoke]

``--smoke`` packs only ``backend/`` for a fast dry run of the pipeline.

Notes
-----
* 7z compression of the full runtime takes roughly 10-20 minutes and yields
  a ~3 GB archive; keep that in mind before uploading anywhere.
* The models are CC BY-NC 4.0 (non-commercial). LICENSES.md is included
  automatically; keep it inside the archive when redistributing.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

APP_DATA = Path(os.environ.get("APPDATA", "") or ".")
LOCAL_APP_DATA = Path(os.environ.get("LOCALAPPDATA", "") or ".")

GUI_DATA_ROOT = APP_DATA / "MangaJaNaiConverterGui"
GUI_LOCAL_ROOT = LOCAL_APP_DATA / "MangaJaNaiConverterGui" / "current"

SOURCES: list[tuple[str, Path]] = [
    ("python", GUI_DATA_ROOT / "python"),
    ("models", GUI_DATA_ROOT / "models"),
    ("backend", GUI_LOCAL_ROOT / "backend"),
]

LICENSES_MD = """\
# Licenses / 许可

This archive bundles third-party software and models for use with the Breeze
manga reader. Review these terms before redistributing the archive.

## MangaJaNai / IllustrationJaNai models (`models/`)

- Copyright (c) the-database - https://github.com/the-database/MangaJaNai
- License: CC BY-NC 4.0 (Attribution-NonCommercial), per the upstream
  repository LICENSE - https://creativecommons.org/licenses/by-nc/4.0/
- **Non-commercial use only.** Sharing and adaptation are allowed with
  attribution; commercial use (including paid apps whose value comes from
  the models) is not permitted by the model license.

## MangaJaNaiConverterGui backend (`backend/`)

- Copyright (c) the-database
  https://github.com/the-database/MangaJaNaiConverterGui
- The backend sources are included unmodified; consult the upstream
  repository for its current license terms before redistribution.

## Embedded Python runtime (`python/`)

- CPython: Python Software Foundation License (PSF-2.0)
- PyTorch / torchvision: BSD-style (github.com/pytorch/pytorch)
- numpy: BSD - Pillow: HPND - opencv-python: Apache-2.0
- pyvips (ships libvips): LGPL-2.1, dynamically linked and unmodified

Keep this file inside the archive when redistributing.
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Pack the local MangaJaNaiConverterGui runtime for Breeze.",
    )
    parser.add_argument(
        "--out",
        default="mangajanai-win.7z",
        help="output archive path (default: ./mangajanai-win.7z)",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="pack only backend/ for a quick dry run",
    )
    parser.add_argument(
        "--7zr",
        dest="seven_zip",
        default=None,
        help="path to 7zr.exe (default: <script>/bin/7zr.exe)",
    )
    return parser.parse_args()


def find_seven_zip(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
        if not path.exists():
            sys.exit(f"7zr not found: {path}")
        return path
    here = Path(__file__).resolve().parent
    for candidate in (here / "bin" / "7zr.exe", here.parent / "script" / "bin" / "7zr.exe"):
        if candidate.exists():
            return candidate
    sys.exit(
        "7zr.exe not found. It ships with Breeze at script/bin/7zr.exe; "
        "pass --7zr explicitly if it lives elsewhere.",
    )


def collect_sources(smoke: bool) -> list[tuple[str, Path]]:
    sources = SOURCES[-1:] if smoke else SOURCES
    missing = [name for name, path in sources if not path.exists()]
    if missing:
        sys.exit(
            "missing source directories (install MangaJaNaiConverterGui and run "
            f"one task first): {missing}",
        )
    return sources


def find_license_files() -> list[Path]:
    found: list[Path] = []
    for root in (GUI_LOCAL_ROOT, GUI_LOCAL_ROOT.parent, GUI_DATA_ROOT):
        if not root.exists():
            continue
        for pattern in ("LICENSE*", "COPYING*"):
            found.extend(root.glob(pattern))
    return found[:4]


def write_licenses(work: Path) -> Path:
    target = work / "LICENSES.md"
    lines = [LICENSES_MD, ""]
    upstream = find_license_files()
    if upstream:
        lines.append("Bundled upstream license files:")
        for item in upstream:
            lines.append(f"- `{item.name}`")
    else:
        lines.append("No upstream LICENSE file was found in the local install.")
    target.write_text("\n".join(lines), encoding="utf-8")
    return target


def main() -> int:
    args = parse_args()
    seven_zip = find_seven_zip(args.seven_zip)
    sources = collect_sources(args.smoke)

    work = Path(tempfile.mkdtemp(prefix="mangajanai_pack_"))
    licenses_file = write_licenses(work)

    inputs = [path for _, path in sources] + [licenses_file]
    cmd = [str(seven_zip), "a", "-t7z", "-mx=5", "-xr!__pycache__", str(args.out)]
    cmd.extend(str(item) for item in inputs)

    print(f"packing {len(sources)} source dir(s) -> {args.out}")
    for item in inputs:
        print(f"  + {item}")

    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        print("retrying without the -xr switch (older 7zr builds may not support it)")
        retry = [item for item in cmd if not item.startswith("-xr!")]
        proc = subprocess.run(retry)
    if proc.returncode != 0:
        return proc.returncode

    size = Path(args.out).stat().st_size
    print()
    print(f"OK: {args.out} ({size / 1024**3:.2f} GB)")
    print("Breeze unpacks this into <files>/mangajanai/; the Dart-side path")
    print("fallback in MangaJaNaiEngine picks it up automatically.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
