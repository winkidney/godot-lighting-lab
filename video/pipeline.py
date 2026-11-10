#!/usr/bin/env python3
"""Tutorial video pipeline for Godot Lighting Lab.

    python3 video/pipeline.py check              # validate plan.json against the lab (headless)
    python3 video/pipeline.py tts                # narration via AW audio.tts (see aw_tts.py)
    python3 video/pipeline.py assemble           # timeline, narration.wav, subtitles, chapters, script.md
    python3 video/pipeline.py assemble --estimate  # same timeline from estimated speech length (no audio)
    python3 video/pipeline.py preview --chapter c1 [--from c1s4]   # real-time run, no sound
    python3 video/pipeline.py stills [--chapter c1]                # one screenshot per shot (framing review)
    python3 video/pipeline.py render [--chapter c1,c2] [--jobs 4]  # Movie Maker, one process per chapter
    python3 video/pipeline.py encode             # concat chapters + subtitles + narration -> mp4
    python3 video/pipeline.py verify             # durations, black frames, loudness, contact sheets
    python3 video/pipeline.py records            # copy production records into video/records/ (tracked)
    python3 video/pipeline.py all                # check, tts, assemble, render, encode, verify

Everything is written under video/build/ (git-ignored, contains .gdignore).
Timing: each chapter = title card + shots; each shot = pre + lines (with gaps)
+ post, or `hold` seconds; all times are quantized to whole frames so the
narration, subtitles and the director's frame clock agree exactly.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import wave

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
BUILD = HERE / "build"
AUDIO = BUILD / "audio"
OUT = BUILD / "out"
EVIDENCE = BUILD / "evidence"
SR = 24000  # Higgs raw output rate; 24000 / 30 fps = 800 samples per frame
VIDEO_NAME = "godot-lighting-lab-tutorial.mp4"

sys.path.insert(0, str(ROOT / "tools"))
from run import display_args, godot_binary, run_checked  # noqa: E402
sys.path.insert(0, str(HERE))
from aw_tts import CHARS_PER_SECOND, gpu_state  # noqa: E402


def load_plan() -> dict:
    return json.loads((HERE / "plan.json").read_text())


def frames(seconds: float, fps: int) -> int:
    return int(round(seconds * fps))


# --- Audio helpers -----------------------------------------------------------------

def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def write_wav(path: Path, signal: np.ndarray, rate: int = SR) -> None:
    pcm = np.clip(np.round(signal * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())


def trim(signal: np.ndarray) -> tuple[np.ndarray, float, float]:
    """Cut leading/trailing near-silence only (-48 dBFS on 20 ms windows),
    keeping 80 ms before speech and 140 ms after; pauses inside are kept."""
    n = 480
    pad = np.pad(signal, (0, (-len(signal)) % n))
    rms = np.sqrt(np.mean(pad.reshape(-1, n) ** 2, axis=1))
    active = np.flatnonzero(rms > 10 ** (-48 / 20))
    if len(active) == 0:
        raise ValueError("silent narration line")
    begin = max(0, int(active[0] * n) - int(0.08 * SR))
    end = min(len(signal), int((active[-1] + 1) * n) + int(0.14 * SR))
    return signal[begin:end], begin / SR, (len(signal) - end) / SR


# --- Timeline -------------------------------------------------------------------------

AT_RE = re.compile(r"^(?:L(\d+)|end)([+-]\d+(?:\.\d+)?)?$")


def resolve_at(at, shot: dict) -> float:
    if isinstance(at, (int, float)):
        return float(at)
    m = AT_RE.match(at)
    if not m:
        raise ValueError(f"{shot['id']}: bad at {at!r}")
    offset = float(m.group(2) or 0.0)
    if m.group(1) is not None:
        return shot["lines"][int(m.group(1))]["start"] + offset
    return shot["duration"] + offset


def build_timeline(plan: dict, durations: dict, estimated: bool) -> dict:
    fps = plan["fps"]
    q = lambda x: round(x * fps) / fps  # noqa: E731
    timing = plan["timing"]
    chapters = []
    cursor_global = 0.0
    for c in plan["chapters"]:
        t = q(timing["card"])
        shots = []
        for s in c["shots"]:
            lines = []
            cur = timing["pre"]
            for i, line in enumerate(s.get("lines", [])):
                start = q(cur)
                dur = durations[f'{s["id"]}-{i}']
                lines.append({"id": f'{s["id"]}-{i}', "sub": line["sub"], "start": start, "end": start + dur})
                cur = start + dur + timing["gap"]
            content = (lines[-1]["end"] + s.get("post", timing["post"])) if lines else 0.0
            duration = math.ceil(max(content, s.get("hold", 0.0)) * fps - 1e-6) / fps
            shot = {"id": s["id"], "label": s.get("label", ""), "start": t, "duration": duration,
                    "sub_top": bool(s.get("sub_top", False)), "lines": lines}
            for k in ("preset", "camera", "orbit", "labels"):
                if k in s:
                    shot[k] = s[k]
            events = []
            for a in s.get("actions", []):
                e = {k: v for k, v in a.items() if k != "at"}
                e["t"] = q(t + resolve_at(a.get("at", 0), shot))
                events.append(e)
            shot["events"] = events
            shots.append(shot)
            t = q(t + duration)
        chapters.append({"id": c["id"], "module": c["module"], "short": c.get("short", c["card"]["title"]),
                         "card": c["card"], "card_duration": q(timing["card"]),
                         "start": q(cursor_global), "start_frame": frames(cursor_global, fps),
                         "duration": t, "frames": frames(t, fps), "shots": shots})
        cursor_global = q(cursor_global + t)
    return {"title": plan["title"], "fps": fps, "size": plan["size"], "estimated": estimated,
            "total": cursor_global, "total_frames": frames(cursor_global, fps), "chapters": chapters}


# --- Subtitles ---------------------------------------------------------------------------

def text_width(s: str) -> float:
    return sum(0.55 if ord(ch) < 0x2E80 else 1.0 for ch in s)


def wrap(text: str, max_width: float) -> list[str]:
    text = text.rstrip("，。；、 ")
    if text_width(text) <= max_width:
        return [text]
    half = text_width(text) / 2
    best, best_cost = None, None
    acc = 0.0
    for i, ch in enumerate(text[:-1]):
        acc += text_width(ch)
        nxt = text[i + 1]
        if ch in "，、；：。！？":
            cost = abs(acc - half)
        elif ord(ch) >= 0x2E80 and ord(nxt) >= 0x2E80:
            cost = abs(acc - half) + 5.0  # mid-phrase break: only if nothing better
        else:
            continue  # never split inside a latin word
        if best_cost is None or cost < best_cost:
            best, best_cost = i + 1, cost
    if best is None:
        return [text]
    return [text[:best].strip().rstrip("，、；："), text[best:].strip()]


def ass_time(t: float) -> str:
    cs = int(round(t * 100))
    return f"{cs // 360000}:{cs // 6000 % 60:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}"


def srt_time(t: float) -> str:
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def subtitle_cues(timeline: dict) -> list[dict]:
    cues = []
    for c in timeline["chapters"]:
        for s in c["shots"]:
            for line in s["lines"]:
                cues.append({"start": c["start"] + s["start"] + line["start"], "end": c["start"] + s["start"] + line["end"],
                             "text": line["sub"], "top": s["sub_top"]})
    for i, cue in enumerate(cues):
        limit = cues[i + 1]["start"] - 0.04 if i + 1 < len(cues) else timeline["total"]
        cue["end"] = min(cue["end"] + 0.25, limit)
    return cues


def write_subtitles(timeline: dict) -> None:
    cues = subtitle_cues(timeline)
    w, h = timeline["size"]
    head = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {w}
PlayResY: {h}
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Bottom,Noto Sans CJK SC,48,&H00FFFFFF,&H00FFFFFF,&H00121212,&H78000000,0,0,0,0,100,100,0,0,1,3.2,1.4,2,140,140,{BAR_H + 50},1
Style: Top,Noto Sans CJK SC,42,&H00FFFFFF,&H00FFFFFF,&H00121212,&H78000000,0,0,0,0,100,100,0,0,1,3.0,1.2,8,300,476,74,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    ass, srt = [head], []
    for i, cue in enumerate(cues, 1):
        rows = wrap(cue["text"], 21 if cue["top"] else 24)
        style = "Top" if cue["top"] else "Bottom"
        body = "\\N".join(rows)
        ass.append(f"Dialogue: 0,{ass_time(cue['start'])},{ass_time(cue['end'])},{style},,0,0,0,,{body}\n")
        srt.append(f"{i}\n{srt_time(cue['start'])} --> {srt_time(cue['end'])}\n" + "\n".join(rows) + "\n")
    (BUILD / "subtitles.ass").write_text("".join(ass), encoding="utf-8")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "subtitles.srt").write_text("\n".join(srt), encoding="utf-8")


def chapter_title(c: dict) -> str:
    card = c["card"]
    return f'{card["num"]} {card["title"]}'.strip() if card.get("num") else "片头"


def write_chapters_and_script(plan: dict, timeline: dict) -> None:
    def stamp(t: float) -> str:
        return f"{int(t) // 60:02d}:{int(t) % 60:02d}"
    lines = [f"{stamp(c['start'])} {chapter_title(c)}" for c in timeline["chapters"]]
    (OUT / "chapters.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    meta = [";FFMETADATA1", f"title={timeline['title']}"]
    for c in timeline["chapters"]:
        meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={int(c['start'] * 1000)}",
                 f"END={int((c['start'] + c['duration']) * 1000)}", f"title={chapter_title(c)}"]
    (BUILD / "chapters.ffmeta").write_text("\n".join(meta) + "\n", encoding="utf-8")
    md = [f"# {timeline['title']}", "", f"总长 {stamp(timeline['total'])}，{len(lines)} 章。时间为成片中的位置。", ""]
    for c in timeline["chapters"]:
        md += [f"## {stamp(c['start'])} {chapter_title(c)}", "", f"> {c['card'].get('subtitle', '')}", ""]
        for s in c["shots"]:
            if s["label"]:
                md.append(f"**{s['label']}**")
                md.append("")
            for line in s["lines"]:
                md.append(f"- `{stamp(c['start'] + s['start'] + line['start'])}` {line['sub']}")
            md.append("")
    (OUT / "script.md").write_text("\n".join(md), encoding="utf-8")
    desc = [
        "This audio was created with Boson AI's Higgs Audio: https://www.boson.ai/higgs-audio",
        "",
        timeline["title"],
        "",
        "用 Godot 4.7 (Forward+) 搭的交互式光照实验室，按 5 个模块由浅入深：法线与法线贴图、光照模型、"
        "光源与阴影、全局光照与后处理、场景氛围配方。画面全部由实验室实时渲染 (Movie Maker 逐帧输出)，"
        "场景、贴图与 LUT 均由代码生成。",
        "",
        "章节：",
        *lines,
        "",
        "配音：Higgs TTS 3 Q8_0 本地合成 (audio.cpp)，参考音色为 Kokoro zf_001 合成女声，非真人录音。",
    ]
    bgm = HERE / "bgm.json"
    if bgm.exists():
        cfg = json.loads(bgm.read_text())
        desc.append(f"背景音乐：《{Path(cfg['source']).stem}》，由 Suno 生成。")
    (OUT / "publish-description.txt").write_text("\n".join(desc) + "\n", encoding="utf-8")


# --- Stages --------------------------------------------------------------------------------

def stage_check() -> int:
    env = os.environ.copy()
    return run_checked([godot_binary(), "--path", str(ROOT), "--audio-driver", "Dummy", "--headless",
                        "--script", "res://tools/tutorial_director.gd", "--", "--check"], env, "video-check")


def stage_tts() -> int:
    return subprocess.call([sys.executable, str(HERE / "aw_tts.py")])


def stage_assemble(estimate: bool) -> int:
    plan = load_plan()
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / ".gdignore").touch()
    durations, signals, trims = {}, {}, {}
    for c in plan["chapters"]:
        for s in c["shots"]:
            for i, line in enumerate(s.get("lines", [])):
                lid = f'{s["id"]}-{i}'
                if estimate:
                    durations[lid] = len(line.get("say", line["sub"])) / CHARS_PER_SECOND
                    continue
                raw = AUDIO / "raw" / f"{lid}.wav"
                if not raw.exists():
                    print(f"missing narration {raw}; run `pipeline.py tts` (or use --estimate)")
                    return 1
                sig, lead, tail = trim(read_wav(raw))
                signals[lid], durations[lid] = sig, len(sig) / SR
                trims[lid] = {"lead_trim": round(lead, 3), "tail_trim": round(tail, 3), "seconds": round(len(sig) / SR, 3)}
    timeline = build_timeline(plan, durations, estimate)
    (BUILD / "timeline.json").write_text(json.dumps(timeline, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    write_subtitles(timeline)
    write_chapters_and_script(plan, timeline)
    total = timeline["total"]
    print(f"timeline: {len(timeline['chapters'])} chapters, {total:.1f} s ({int(total) // 60}:{int(total) % 60:02d}), "
          f"{timeline['total_frames']} frames{' (ESTIMATED)' if estimate else ''}")
    for c in timeline["chapters"]:
        print(f"  {c['id']}  start {c['start']:7.2f}  dur {c['duration']:6.2f}  {chapter_title(c)}")
    if estimate:
        return 0
    narration = np.zeros(int(round(total * SR)), dtype=np.float32)
    for c in timeline["chapters"]:
        for s in c["shots"]:
            for line in s["lines"]:
                at = int(round((c["start"] + s["start"] + line["start"]) * SR))
                sig = signals[line["id"]]
                narration[at:at + len(sig)] += sig
    write_wav(AUDIO / "narration-24k.wav", narration)
    (AUDIO / "trim-report.json").write_text(json.dumps(trims, indent=1) + "\n")
    return loudnorm(AUDIO / "narration-24k.wav", AUDIO / "narration.wav")


def loudnorm(src: Path, dst: Path) -> int:
    """Two-pass EBU R128 to -16 LUFS / -1.5 dBTP, resampled to 48 kHz."""
    target = "I=-16:TP=-1.5:LRA=11"
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(src), "-af", f"loudnorm={target}:print_format=json",
                        "-f", "null", "-"], capture_output=True, text=True)
    m = json.loads(p.stderr[p.stderr.rfind("{"):p.stderr.rfind("}") + 1])
    flt = (f"loudnorm={target}:measured_I={m['input_i']}:measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}"
           f":measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true")
    code = subprocess.call(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src), "-af", flt,
                            "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(dst)])
    (AUDIO / "loudnorm-pass1.json").write_text(json.dumps(m, indent=1) + "\n")
    print(f"narration: {dst} (measured {m['input_i']} LUFS -> -16)")
    return code


def godot_cmd(chapter: dict, extra: list[str], env: dict) -> list[str]:
    """display_args() may add WAYLAND_DISPLAY to env: run the command with that env."""
    cmd = [godot_binary(), "--path", str(ROOT), "--audio-driver", "Dummy"] + display_args(env)
    return cmd + extra + ["--script", "res://tools/tutorial_director.gd", "--",
                          f"--chapter={chapter['id']}", f"--module={chapter['module'] + 1}"]


class render_resolution:
    """Movie Maker records at the project's viewport size (1600x900 here), not
    the window size, so a temporary override.cfg sets 1920x1080 for the run."""

    def __init__(self, size):
        self.path = ROOT / "override.cfg"
        self.text = f"[display]\n\nwindow/size/viewport_width={size[0]}\nwindow/size/viewport_height={size[1]}\n"

    def __enter__(self):
        if self.path.exists():
            raise SystemExit(f"{self.path} already exists; remove it (left by an interrupted render?)")
        self.path.write_text(self.text)

    def __exit__(self, *exc):
        self.path.unlink(missing_ok=True)


def run_godot(cmd: list[str], env: dict, label: str, grace: float = 20.0) -> int:
    """Like run_checked, plus a watchdog: once the director printed DIRECTOR
    DONE every frame is on disk, so a process that then hangs on exit is
    terminated instead of blocking the pipeline."""
    import threading
    import time
    from run import ERROR_RE
    errors, done_at = [], []
    proc = subprocess.Popen(cmd, env=env, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def watchdog():
        while proc.poll() is None:
            if done_at and time.monotonic() - done_at[0] > grace:
                print(f"[{label}] still running {grace:.0f}s after DIRECTOR DONE; terminating", flush=True)
                proc.terminate()
                return
            time.sleep(1)
    threading.Thread(target=watchdog, daemon=True).start()
    for line in proc.stdout:
        sys.stdout.write(line)
        if ERROR_RE.search(line) or "DIRECTOR FAILED" in line:
            errors.append(line.rstrip())
        if "DIRECTOR DONE" in line:
            done_at.append(time.monotonic())
    code = proc.wait()
    if errors or not done_at or (code != 0 and not done_at):
        print(f"\n[{label}] FAILED (exit={code}, {len(errors)} error line(s))")
        for line in errors[:40]:
            print("   ", line)
        return 1
    print(f"\n[{label}] OK (exit={code})")
    return 0


def load_timeline() -> dict:
    return json.loads((BUILD / "timeline.json").read_text())


def wait_for_gpu(min_free_mb: float = 4000) -> None:
    import time
    announced = False
    while True:
        free, util = gpu_state()
        if free is None or (free >= min_free_mb and util < 40):
            return
        if not announced:
            print(f"GPU busy (free {free:.0f} MB, util {util:.0f}%), waiting before rendering...", flush=True)
            announced = True
        time.sleep(30)


def stage_preview(chapter_id: str, from_shot: str | None) -> int:
    tl = load_timeline()
    chapter = next(c for c in tl["chapters"] if c["id"] == chapter_id)
    env = os.environ.copy()
    cmd = godot_cmd(chapter, [], env)
    if from_shot:
        cmd.append(f"--from={from_shot}")
    with render_resolution(tl["size"]):
        return subprocess.call(cmd, cwd=ROOT, env=env)


def stage_stills(only: list[str] | None) -> int:
    """One settled screenshot per shot, to review framing before a render."""
    tl = load_timeline()
    env = os.environ.copy()
    for chapter in tl["chapters"]:
        if only and chapter["id"] not in only:
            continue
        wait_for_gpu()
        out = BUILD / "stills" / chapter["id"]
        cmd = godot_cmd(chapter, [], env) + [f"--stills={out}"]
        with render_resolution(tl["size"]):
            if run_godot(cmd, env, f"stills-{chapter['id']}") != 0:
                return 1
    return 0


def render_chapter(tl: dict, chapter: dict, env: dict, keep_frames: bool) -> int:
    """Movie Maker render of one chapter, then encode its frames to chunks/<id>.mp4."""
    chunks = BUILD / "chunks"
    fdir = BUILD / "frames" / chapter["id"]
    if fdir.exists():
        shutil.rmtree(fdir)
    fdir.mkdir(parents=True)
    report = fdir / "director.json"
    cmd = godot_cmd(chapter, ["--fixed-fps", str(tl["fps"]), "--disable-vsync",
                              "--write-movie", str(fdir / "f.png")], env) + [f"--report={report}"]
    print(f"== render {chapter['id']}: {chapter['frames']} frames", flush=True)
    if run_godot(cmd, env, f"render-{chapter['id']}") != 0:
        return 1
    pngs = sorted(fdir.glob("f*.png"))
    info = json.loads(report.read_text())
    expected = chapter["frames"]
    # Movie Maker writes one image per drawn frame from engine start; the
    # director's frame 0 is the frame drawn right after its first tick.
    first = int(info["first_frame_drawn"])
    usable = pngs[first:first + expected]
    if len(usable) != expected:
        print(f"render {chapter['id']}: {len(pngs)} images, first={first}, need {expected}")
        return 1
    start_number = int(re.search(r"(\d+)\.png$", usable[0].name).group(1))
    digits = len(re.search(r"(\d+)\.png$", usable[0].name).group(1))
    out = chunks / f"{chapter['id']}.mp4"
    code = subprocess.call(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", str(tl["fps"]),
                            "-start_number", str(start_number), "-i", str(fdir / f"f%0{digits}d.png"),
                            "-frames:v", str(expected), "-c:v", "libx264", "-preset", "slow", "-crf", "12",
                            "-pix_fmt", "yuv420p", str(out)])
    if code != 0:
        return code
    got = probe_frames(out)
    if got != expected:
        print(f"chunk {out.name}: {got} frames, expected {expected}")
        return 1
    (chunks / f"{chapter['id']}.json").write_text(json.dumps({**info, "pngs": len(pngs), "start_number": start_number,
                                                              "encoded_frames": got}, indent=1) + "\n")
    if not keep_frames:
        shutil.rmtree(fdir)
    print(f"   {out.name}: {got} frames OK", flush=True)
    return 0


def stage_render(only: list[str] | None, keep_frames: bool, jobs: int = 1, job_vram_mb: float = 1500) -> int:
    """Render chapters. Movie Maker encodes PNGs on Godot's main thread (one CPU
    core), so independent chapters are rendered in parallel processes when
    jobs > 1; a new one starts only while enough VRAM is free."""
    import threading
    import time
    tl = load_timeline()
    if tl.get("estimated"):
        print("timeline.json is an estimate; run `pipeline.py assemble` with real narration first")
        return 1
    (BUILD / "chunks").mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    pending = [c for c in tl["chapters"] if not only or c["id"] in only]
    # Longest chapters first so the parallel tail is short.
    pending.sort(key=lambda c: -c["frames"])
    results: dict[str, int] = {}
    running: list[threading.Thread] = []
    if jobs <= 1:
        wait_for_gpu()
    with render_resolution(tl["size"]):
        while pending or running:
            running = [t for t in running if t.is_alive()]
            if any(code != 0 for code in results.values()):
                pending.clear()
            if pending and len(running) < jobs:
                free, _ = gpu_state()
                if not running or free is None or free >= job_vram_mb:
                    chapter = pending.pop(0)
                    t = threading.Thread(target=lambda c=chapter: results.__setitem__(c["id"], render_chapter(tl, c, env, keep_frames)))
                    t.start()
                    running.append(t)
                    time.sleep(25)  # let it allocate VRAM before measuring again
                    continue
            time.sleep(3)
    failed = [k for k, v in results.items() if v != 0]
    if failed:
        print(f"render failed: {failed}")
        return 1
    return 0


def probe_frames(path: Path) -> int:
    p = subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries",
                        "stream=nb_read_packets", "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    return int(p.stdout.strip() or 0)


BAR_H = 44  # chapter bar height at the bottom of the frame (covers the overlay's thin bar)


def build_chapter_bar(tl: dict):
    """Bottom chapter bar as pixel-font PNGs: a base (all chapters, dim), one
    highlighted segment per chapter (shown while that chapter plays) and a
    gold fill strip that ffmpeg slides in with time."""
    from PIL import Image, ImageDraw
    from pixel_text import audit, text, width
    w = tl["size"][0]
    total = tl["total"]
    out = BUILD / "bar"
    out.mkdir(parents=True, exist_ok=True)
    audit([c["short"] for c in tl["chapters"]])
    colors = {"bg": (11, 28, 38, 236), "seg": (17, 42, 52, 255), "active": (30, 66, 78, 255), "track": (36, 65, 75, 255),
              "label": (139, 169, 166, 255), "label_active": (238, 237, 222, 255), "gold": (231, 187, 114, 255),
              "edge": (28, 53, 64, 255)}
    strip = 5
    segs = []
    for c in tl["chapters"]:
        x0 = round(w * c["start"] / total)
        x1 = round(w * (c["start"] + c["duration"]) / total)
        segs.append((c, x0, x1))

    def segment(d, im, c, x0, x1, active):
        d.rectangle((x0 + 1, strip, x1 - 2, BAR_H - 1), fill=colors["active" if active else "seg"])
        if active:
            d.rectangle((x0 + 1, BAR_H - 4, x1 - 2, BAR_H - 1), fill=colors["gold"])
        label = c["short"]
        if width(label, 24) <= x1 - x0 - 12:
            lx = x0 + (x1 - x0 - width(label, 24)) // 2
            text(im, (lx, strip + 8), label, 24, colors["label_active" if active else "label"])

    base = Image.new("RGBA", (w, BAR_H), colors["bg"])
    d = ImageDraw.Draw(base)
    d.rectangle((0, 0, w - 1, strip - 1), fill=colors["track"])
    for c, x0, x1 in segs:
        segment(d, base, c, x0, x1, False)
        d.rectangle((x0 - 1, 0, x0, BAR_H - 1), fill=colors["edge"])
    base.save(out / "base.png")
    actives = []
    for c, x0, x1 in segs:
        im = Image.new("RGBA", (w, BAR_H), (0, 0, 0, 0))
        segment(ImageDraw.Draw(im), im, c, x0, x1, True)
        path = out / f"active-{c['id']}.png"
        im.save(path)
        actives.append((path, c["start"], c["start"] + c["duration"]))
    fill = Image.new("RGBA", (w, strip), colors["gold"])
    fill.save(out / "fill.png")
    return out / "base.png", out / "fill.png", actives


def stage_encode() -> int:
    tl = load_timeline()
    chunks = [BUILD / "chunks" / f"{c['id']}.mp4" for c in tl["chapters"]]
    missing = [p.name for p in chunks if not p.exists()]
    if missing:
        print(f"missing chapter renders: {missing}")
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    lst = BUILD / "chunks.txt"
    lst.write_text("".join(f"file '{p}'\n" for p in chunks))
    out = OUT / VIDEO_NAME
    ass = str(BUILD / "subtitles.ass").replace("\\", "/").replace(":", r"\:")
    base, fill, actives = build_chapter_bar(tl)
    inputs = ["-i", str(base), "-i", str(fill)]
    graph = [f"[0:v][3:v]overlay=0:H-{BAR_H}[b0]"]
    for i, (png, start, end) in enumerate(actives):
        inputs += ["-i", str(png)]
        graph.append(f"[b{i}][{5 + i}:v]overlay=0:H-{BAR_H}:enable='between(t,{start:.3f},{end:.3f})'[b{i + 1}]")
    n = len(actives)
    # The fill strip slides in from the left: visible width = W * t / total.
    graph.append(f"[b{n}][4:v]overlay=x='W*t/{tl['total']:.4f}-W':y=H-{BAR_H}[b{n + 1}]")
    graph.append(f"[b{n + 1}]ass='{ass}'[vout]")
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-stats", "-y",
           "-f", "concat", "-safe", "0", "-i", str(lst), "-i", str(AUDIO / "narration.wav"), "-i", str(BUILD / "chapters.ffmeta"),
           *inputs, "-filter_complex", ";".join(graph),
           "-map", "[vout]", "-map", "1:a", "-map_metadata", "2", "-map_chapters", "2",
           "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high",
           "-pix_fmt", "yuv420p", "-r", str(tl["fps"]), "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
           "-metadata:s:a:0", "language=chi", "-movflags", "+faststart", str(out)]
    code = subprocess.call(cmd)
    if code == 0:
        write_provenance(tl, cmd)
        print(f"video: {out}")
    return code


def write_provenance(tl: dict, encode_cmd: list[str]) -> None:
    from aw_tts import REF_SHA256
    manifest = json.loads((AUDIO / "tts-manifest.json").read_text()) if (AUDIO / "tts-manifest.json").exists() else {}
    plan = load_plan()
    renders = {}
    for c in tl["chapters"]:
        info = BUILD / "chunks" / f"{c['id']}.json"
        if info.exists():
            renders[c["id"]] = json.loads(info.read_text())
    prov = {
        "video": VIDEO_NAME, "seconds": tl["total"], "frames": tl["total_frames"], "fps": tl["fps"], "size": tl["size"],
        "render": {"engine": subprocess.run([godot_binary(), "--version"], capture_output=True, text=True).stdout.strip(),
                   "method": "Movie Maker (--write-movie PNG, --fixed-fps), one process per chapter, tools/tutorial_director.gd",
                   "chapters": renders},
        "voice": {**plan["voice"], "reference_sha256": REF_SHA256, "runtime": "audio.cpp v0.9.3 CUDA via Asset Workbench",
                  "credit": "This audio was created with Boson AI's Higgs Audio: https://www.boson.ai/higgs-audio",
                  "lines": {k: {kk: v.get(kk) for kk in ("text", "seed", "aw_output", "raw_sha256", "raw_seconds", "quality_status")}
                            for k, v in manifest.items()}},
        "narration_loudness": json.loads((AUDIO / "loudnorm-pass1.json").read_text()) if (AUDIO / "loudnorm-pass1.json").exists() else None,
        "encode_command": encode_cmd,
    }
    (OUT / "provenance.json").write_text(json.dumps(prov, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def stage_verify() -> int:
    tl = load_timeline()
    out = OUT / VIDEO_NAME
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    def probe(stream: str) -> float:
        p = subprocess.run(["ffprobe", "-v", "error", "-select_streams", stream, "-show_entries", "stream=duration",
                            "-of", "csv=p=0", str(out)], capture_output=True, text=True)
        return float(p.stdout.strip())
    vdur, adur = probe("v:0"), probe("a:0")
    nframes = probe_frames(out)
    black = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(out), "-vf", "blackdetect=d=0.4:pix_th=0.06", "-an", "-f", "null", "-"],
                           capture_output=True, text=True).stderr
    blacks = re.findall(r"black_start:([\d.]+) black_end:([\d.]+)", black)
    loud = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(out), "-vn", "-af", "ebur128=peak=true", "-f", "null", "-"],
                          capture_output=True, text=True).stderr
    summary = loud[loud.rfind("Summary:"):]
    integrated = float(re.search(r"I:\s+(-?[\d.]+) LUFS", summary).group(1))
    peak = float(re.search(r"Peak:\s+(-?[\d.]+) dBFS", summary).group(1))
    report = {"video_seconds": vdur, "audio_seconds": adur, "frames": nframes, "expected_frames": tl["total_frames"],
              "av_diff_frames": round(abs(vdur - adur) * tl["fps"], 2), "integrated_lufs": integrated, "true_peak_dbfs": peak,
              "black_segments": [[float(a), float(b)] for a, b in blacks],
              "chapter_boundaries": [c["start"] for c in tl["chapters"]]}
    contact_sheets(tl, out)
    (EVIDENCE / "verify.json").write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps(report, indent=1))
    ok = nframes == tl["total_frames"] and report["av_diff_frames"] <= 1.0 and abs(integrated + 16) <= 1.0
    print("VERIFY OK" if ok else "VERIFY: check the values above")
    return 0 if ok else 1


def contact_sheets(tl: dict, video: Path) -> None:
    """One thumbnail per shot midpoint and per line start (to check subtitles)."""
    from PIL import Image, ImageDraw, ImageFont
    font_file = subprocess.run(["fc-match", "-f", "%{file}", "Noto Sans CJK SC"], capture_output=True, text=True).stdout.strip()
    font = ImageFont.truetype(font_file, 22) if font_file and Path(font_file).exists() else ImageFont.load_default()
    tmp = EVIDENCE / "frames"
    tmp.mkdir(exist_ok=True)
    for c in tl["chapters"]:
        shots = []
        for s in c["shots"]:
            t0 = c["start"] + s["start"]
            times = [("mid", t0 + s["duration"] * 0.5)] + [(ln["id"], t0 + ln["start"] + 0.6) for ln in s["lines"]]
            for e in s["events"]:
                if e["do"] in ("set", "preset", "debug", "sweep"):
                    times.append((f"{e['do']}+", c["start"] + e["t"] + min(float(e.get("dur", 0.0)), 3.0) + 0.5))
            shots.append((s, times))
        thumbs = []
        for s, times in shots:
            for tag, t in times:
                path = tmp / f"{s['id']}-{tag}-{t:.2f}.jpg"
                subprocess.call(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{t:.3f}", "-i", str(video),
                                 "-frames:v", "1", "-vf", "scale=480:-1", "-q:v", "4", str(path)])
                if path.exists():
                    thumbs.append((f"{s['id']} {tag} {t:.1f}s", Image.open(path).convert("RGB")))
        cols = 4
        rows = max(1, math.ceil(len(thumbs) / cols))
        sheet = Image.new("RGB", (cols * 480, rows * 300), (18, 18, 22))
        draw = ImageDraw.Draw(sheet)
        for i, (label, im) in enumerate(thumbs):
            x, y = (i % cols) * 480, (i // cols) * 300
            sheet.paste(im, (x, y))
            draw.text((x + 6, y + 272), label, fill=(230, 230, 230), font=font)
        sheet.save(EVIDENCE / f"contact-{c['id']}.jpg", quality=88)


RECORDS = HERE / "records"


def stage_records() -> int:
    """Copy the production records worth keeping in git (small, not cheaply
    reproducible or useful for publishing) out of the ignored build dir."""
    RECORDS.mkdir(exist_ok=True)
    picks = [AUDIO / "tts-manifest.json", OUT / "provenance.json", EVIDENCE / "verify.json",
             EVIDENCE / "asr-check.json", EVIDENCE / "bgm-mix.json", OUT / "cover-receipt.json", OUT / "chapters.txt",
             OUT / "publish-description.txt"]
    for src in picks:
        if src.exists():
            (RECORDS / src.name).write_text(sanitize(src.read_text(encoding="utf-8")), encoding="utf-8")
            print(f"record: {src.name}")
        else:
            print(f"record missing (skipped): {src}")
    return 0


def sanitize(text: str) -> str:
    """Records are published: replace machine-specific paths with placeholders."""
    text = re.sub(r"/[^\s\"',]*?/(art/(?:derived|inputs)/narration/)", r"<aw-project>/\1", text)
    text = text.replace(str(ROOT), "<repo>")
    text = text.replace(str(Path.home()), "~")
    if re.search(r"/home/|/Users/|[A-Za-z]:\\\\Users", text):
        raise SystemExit("unsanitized local path left in a record")
    return text


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=["check", "tts", "assemble", "preview", "stills", "render", "encode", "verify", "records", "all"])
    ap.add_argument("--estimate", action="store_true", help="assemble: estimate speech length instead of real audio")
    ap.add_argument("--chapter", help="preview: chapter id; render: comma separated ids")
    ap.add_argument("--from", dest="from_shot", help="preview: start at this shot id")
    ap.add_argument("--keep-frames", action="store_true", help="render: keep the PNG frames")
    ap.add_argument("--jobs", type=int, default=1, help="render: chapters rendered in parallel (VRAM permitting)")
    a = ap.parse_args()
    if a.stage == "check":
        return stage_check()
    if a.stage == "tts":
        return stage_tts()
    if a.stage == "assemble":
        return stage_assemble(a.estimate)
    if a.stage == "preview":
        return stage_preview(a.chapter or "c0", a.from_shot)
    if a.stage == "stills":
        return stage_stills(a.chapter.split(",") if a.chapter else None)
    if a.stage == "render":
        return stage_render(a.chapter.split(",") if a.chapter else None, a.keep_frames, a.jobs)
    if a.stage == "encode":
        return stage_encode()
    if a.stage == "verify":
        return stage_verify()
    if a.stage == "records":
        return stage_records()
    for step in (stage_check, stage_tts, lambda: stage_assemble(False), lambda: stage_render(None, False), stage_encode, stage_verify):
        code = step()
        if code != 0:
            return code
    return 0


if __name__ == "__main__":
    sys.exit(main())
