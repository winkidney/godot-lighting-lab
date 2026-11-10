#!/usr/bin/env python3
"""Bilibili covers (16:9 1920x1080 and 4:3 1600x1200) for the tutorial video.

All pictures are clean Godot captures of the lab itself (overlay hidden,
rendered by tools/tutorial_director.gd --stills --clean); all text uses the
Z Labs 12px pixel font (SIL OFL, video/fonts/) rendered from its native 12px
bitmap and enlarged by whole-number factors only, so every glyph stays crisp.

    python3 video/build_covers.py            # capture (if missing) + compose
    python3 video/build_covers.py --recapture
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pipeline import BUILD, OUT, godot_cmd, load_timeline, render_resolution, run_godot, wait_for_gpu  # noqa: E402
import pixel_text  # noqa: E402
from pixel_text import FONT, audit, width  # noqa: E402
SRC = BUILD / "cover-src"
C = {"bg": "#0b1c26", "panel": "#112a34", "mint": "#a6d3b8", "gold": "#e7bb72", "white": "#eeedde",
     "muted": "#8ba9a6", "grid": "#1c3540", "frame": "#5c8f91", "shadow": "#07131a"}

# Shot captures: chapter -> {shot id: seconds after the shot start}.
PICKS = {
    "c1": {"c1s1": 2.5},             # world-space normals as colours
    "c2": {"c2s4": 3.0},             # N/L/V/H/R arrows
    "c3": {"c3s3": 2.0},             # spot light + window cookie
    "c4": {"c4s2": 4.0},             # SDFGI colour bleeding
    "c5": {"c5s4": 3.0, "c5s5": 2.5},  # neon rain night, god rays
}

# The title, split by reading order into headline / subline / tag / subline.
HEAD = ["让 AI 10 分钟内", "教会我 Godot", "光照系统"]
SUB1 = "做游戏遇到瓶颈学习一下"
TAG = "学无止尽啊，还得学！"
SUB2 = "学了才知道怎么命令 AI！"
BADGE = "Godot 4.7 · 光照实验室"
LABELS = {"c1s1": "法线", "c2s4": "光照模型", "c3s3": "阴影", "c4s2": "全局光照", "c5s4": "霓虹雨夜", "c5s5": "丁达尔光"}
RIGHT_HEAD = "Godot 实机画面"
NOTE = "画面全部由实验室实时渲染"


def text(im: Image.Image, xy, value: str, size: int, color: str, shadow: bool = False):
    return pixel_text.text(im, xy, value, size, color, C["shadow"] if shadow else None)


def capture(force: bool) -> None:
    tl = load_timeline()
    env = os.environ.copy()
    for chapter in tl["chapters"]:
        shots = PICKS.get(chapter["id"])
        if not shots:
            continue
        out = SRC / chapter["id"]
        if not force and all((out / f"{s}.png").exists() for s in shots):
            continue
        wait_for_gpu()
        at = ",".join(f"{k}:{v}" for k, v in shots.items())
        cmd = godot_cmd(chapter, [], env) + [f"--stills={out}", "--clean", f"--at={at}"]
        with render_resolution(tl["size"]):
            if run_godot(cmd, env, f"cover-{chapter['id']}") != 0:
                raise SystemExit("capture failed")


def shot(name: str) -> Image.Image:
    chapter = name[:2]
    return Image.open(SRC / chapter / f"{name}.png").convert("RGB")


def fit(im: Image.Image, w: int, h: int) -> Image.Image:
    """Centre-crop to the target aspect, then downscale (photographic 3D renders)."""
    sw, sh = im.size
    scale = max(w / sw, h / sh)
    cw, ch = round(w / scale), round(h / scale)
    x, y = (sw - cw) // 2, (sh - ch) // 2
    return im.crop((x, y, x + cw, y + ch)).resize((w, h), Image.Resampling.LANCZOS)


def badge_icon(d: ImageDraw.ImageDraw, x: int, y: int) -> None:
    """52 px gold tile with a pixel 'light' (sun) glyph."""
    d.rectangle((x, y, x + 52, y + 52), fill=C["gold"])
    px = 4
    pattern = ["..#..#..#..", "...........", "....###....", "#..#####..#", "...#####...",
               "#..#####..#", "....###....", "...........", "..#..#..#.."]
    ox, oy = x + (52 - 11 * px) // 2, y + (52 - 9 * px) // 2
    for r, row in enumerate(pattern):
        for c, ch in enumerate(row):
            if ch == "#":
                d.rectangle((ox + c * px, oy + r * px, ox + c * px + px - 1, oy + r * px + px - 1), fill=C["bg"])


def labelled(im: Image.Image, d: ImageDraw.ImageDraw, pic: Image.Image, x: int, y: int, label: str, accent: str, frame=True):
    im.paste(pic, (x, y))
    if frame:
        d.rectangle((x - 3, y - 3, x + pic.width + 2, y + pic.height + 2), outline=C["frame"], width=3)
    lw = width(label, 24) + 20
    d.rectangle((x, y, x + lw, y + 40), fill=C["bg"])
    d.rectangle((x, y, x + 5, y + 40), fill=accent)
    text(im, (x + 13, y + 8), label, 24, C["white"])


def compose(w: int, h: int) -> Image.Image:
    split = 940 if w == 1920 else 800
    im = Image.new("RGB", (w, h), C["bg"])
    d = ImageDraw.Draw(im)
    d.rectangle((split, 0, w, h), fill=C["panel"])
    for x in range(split, w, 48):
        d.line((x, 0, x, h), fill=C["grid"])
    for y in range(0, h, 48):
        d.line((split, y, w, y), fill=C["grid"])
    d.rectangle((0, 0, w - 1, 7), fill=C["mint"])
    d.rectangle((0, h - 8, w - 1, h - 1), fill=C["gold"])

    # Left: the title, in reading order.
    x = 68
    badge_icon(d, x, 66)
    text(im, (x + 72, 80), BADGE, 36, C["gold"])
    text(im, (x, 160), HEAD[0], 72, C["white"], True)
    text(im, (x, 254), HEAD[1], 96, C["white"], True)
    text(im, (x, 372), HEAD[2], 144, C["gold"], True)
    y = 552 if w == 1920 else 576
    text(im, (x, y), SUB1, 48, C["mint"], True)
    tagw = width(TAG, 48) + 44
    d.rectangle((x, y + 72, x + tagw, y + 72 + 76), fill=C["gold"])
    text(im, (x + 22, y + 72 + 14), TAG, 48, C["bg"])
    text(im, (x, y + 172), SUB2, 48, C["mint"], True)

    # Left bottom: one card per basic module.
    cards = [("c1s1", C["mint"]), ("c2s4", "#91a7d6"), ("c3s3", C["gold"])]
    gap = 18
    cardw = (split - 2 * x - 2 * gap) // 3
    pich = round(cardw * 9 / 16)
    card_y = h - 72 - pich - 46 if w == 1920 else h - 150 - pich - 46
    for i, (name, accent) in enumerate(cards):
        cx = x + i * (cardw + gap)
        d.rectangle((cx, card_y, cx + cardw, card_y + pich + 46), outline="#547e83", width=2)
        d.rectangle((cx, card_y, cx + 6, card_y + pich + 46), fill=accent)
        pic = fit(shot(name), cardw - 14, pich)
        im.paste(pic, (cx + 10, card_y + 6))
        lab = LABELS[name]
        text(im, (cx + 10 + (cardw - 14 - width(lab, 24)) // 2, card_y + pich + 14), lab, 24, C["white"])
    if w == 1600:
        text(im, (x, h - 96), NOTE, 24, C["muted"])

    # Right: hero capture + two more chapters.
    rx = split + 24
    rw = w - split - 48
    text(im, (rx + 8, 80), RIGHT_HEAD, 36, C["mint"])
    if w == 1920:
        hero = fit(shot("c5s4"), rw, round(rw * 9 / 16))
        hy = 160
    else:
        hero = fit(shot("c5s4"), rw, 620)
        hy = 160
    labelled(im, d, hero, rx, hy, LABELS["c5s4"], "#91a7d6")
    strip_y = hy + hero.height + 30
    sw = (rw - 24) // 2
    sh = min(round(sw * (9 / 16 if w == 1920 else 3 / 4)), h - 40 - strip_y)
    for i, (name, accent) in enumerate([("c4s2", C["mint"]), ("c5s5", C["gold"])]):
        labelled(im, d, fit(shot(name), sw, sh), rx + i * (sw + 24), strip_y, LABELS[name], accent)
    return im


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--recapture", action="store_true")
    a = ap.parse_args()
    glyphs = audit([*HEAD, SUB1, TAG, SUB2, BADGE, RIGHT_HEAD, NOTE, *LABELS.values()])
    capture(a.recapture)
    OUT.mkdir(parents=True, exist_ok=True)
    font_sha = hashlib.sha256(FONT.read_bytes()).hexdigest()
    receipts = []
    for w, h, aspect in [(1920, 1080, "16x9"), (1600, 1200, "4x3")]:
        im = compose(w, h)
        png = OUT / f"cover-{aspect}.png"
        im.save(png, optimize=True)
        jpg = png.with_suffix(".jpg")
        im.save(jpg, quality=93, subsampling=0)
        receipts.append({"file": png.name, "jpg": jpg.name, "size": [w, h], "png_bytes": png.stat().st_size,
                         "jpg_bytes": jpg.stat().st_size, "source": "clean Godot captures (tutorial_director --stills --clean)",
                         "shots": sorted(k for v in PICKS.values() for k in v), "font": FONT.name, "font_sha256": font_sha,
                         "glyphs_checked": glyphs})
    (OUT / "cover-receipt.json").write_text(json.dumps(receipts, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(receipts, ensure_ascii=False))


if __name__ == "__main__":
    main()
