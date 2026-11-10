"""Crisp pixel-font text for covers and the chapter bar.

Glyphs come from the Z Labs 12px font's native bitmap and are enlarged by
whole-number factors only (nearest neighbour), so every pixel stays square.
"""
from functools import lru_cache
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT = Path(__file__).resolve().parent / "fonts/zlabs-pixel-12px-m-cn.ttf"
NATIVE = ImageFont.truetype(str(FONT), 12)


@lru_cache(maxsize=4096)
def mask(value: str, size: int) -> Image.Image:
    assert size % 12 == 0, "pixel typography uses whole multiples of the native 12px"
    box = NATIVE.getbbox(value)
    im = Image.new("1", (max(1, math.ceil(NATIVE.getlength(value))), max(1, box[3] - box[1])))
    ImageDraw.Draw(im).text((0, -box[1]), value, font=NATIVE, fill=1)
    return im.convert("L").resize((im.width * (size // 12), im.height * (size // 12)), Image.Resampling.NEAREST)


def width(value: str, size: int) -> int:
    return mask(value, size).width


def text(im: Image.Image, xy, value: str, size: int, color, shadow=None):
    m = mask(value, size)
    if shadow is not None:
        im.paste(shadow, (xy[0] + size // 12, xy[1] + size // 12), m)
    im.paste(color, xy, m)
    return m.size


def audit(strings) -> int:
    """Fail on any character the pixel font does not contain (no fallback font)."""
    unknown = NATIVE.getmask(chr(0x10FFFF))
    sig = (unknown.size, bytes(unknown))
    missing = [ch for ch in sorted(set("".join(strings))) if not ch.isspace()
               and (NATIVE.getmask(ch).size, bytes(NATIVE.getmask(ch))) == sig]
    if missing:
        raise SystemExit(f"pixel font lacks glyphs: {missing!r}")
    return len(set("".join(strings)))
