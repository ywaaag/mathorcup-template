"""Matplotlib style helpers for Chinese MathorCup figures.

Use this module before creating figures that contain Chinese labels:

    from common.plot_style import use_chinese_fonts
    use_chinese_fonts()

The helper prefers fonts shipped by the template runtime image and falls back
gracefully when a host/container has only part of the baseline.
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterable

import matplotlib.pyplot as plt
from matplotlib import font_manager


FONT_FILES = [
    Path("/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"),
    Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
    Path("/usr/share/fonts/truetype/arphic/uming.ttc"),
    Path("/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf"),
]

SANS_SERIF_CANDIDATES = [
    "WenQuanYi Micro Hei",
    "Noto Sans CJK JP",
    "Noto Sans CJK SC",
    "AR PL UMing CN",
    "Droid Sans Fallback",
]


def _add_existing_fonts(paths: Iterable[Path]) -> None:
    for path in paths:
        if not path.exists():
            continue
        try:
            font_manager.fontManager.addfont(str(path))
        except Exception:
            # Font loading should never stop modeling scripts from producing
            # numeric results; matplotlib will fall back to its own defaults.
            continue


def use_chinese_fonts() -> None:
    """Configure matplotlib for Chinese labels and minus signs."""

    _add_existing_fonts(FONT_FILES)
    plt.rcParams["font.sans-serif"] = SANS_SERIF_CANDIDATES
    plt.rcParams["axes.unicode_minus"] = False


def savefig(path: str | Path, *args, **kwargs) -> None:
    """Save a figure with template defaults useful for paper-ready outputs."""

    kwargs.setdefault("bbox_inches", "tight")
    kwargs.setdefault("dpi", 200)
    plt.savefig(path, *args, **kwargs)
