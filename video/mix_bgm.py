#!/usr/bin/env python3
"""Lay a background-music track under the finished tutorial.

Reads video/bgm.json. The track is extended (if needed) by jumping back a
whole musical phrase inside a steady section with an equal-power crossfade,
refined to the sample by waveform correlation; then trimmed to the video
length with fades, normalised to a quiet music level, ducked under the
narration with a sidechain compressor, mixed and limited. The picture,
burned-in subtitles and chapters are copied untouched from the narration-only
render into a second MP4.

    python3 video/mix_bgm.py --source "/path/to/track.m4a"   # first time (copies it into the build)
    python3 video/mix_bgm.py                                  # re-mix from video/build/audio/bgm/source.m4a
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pipeline import AUDIO, BUILD, EVIDENCE, OUT, VIDEO_NAME, load_timeline  # noqa: E402

SR = 48000
WORK = AUDIO / "bgm"


def decode(path: Path) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()


def write_wav(path: Path, x: np.ndarray) -> None:
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", str(x.shape[1]), "-i", "-",
                    "-c:a", "pcm_s24le", str(path)], input=x.astype(np.float32).tobytes(), check=True)


def refine_jump(x: np.ndarray, out_t: float, jump: float, ms: float) -> float:
    """Shift the jump by up to +/-ms so the two waveforms line up at the splice."""
    mono = x.mean(axis=1)
    a0, n = int(out_t * SR), int(1.5 * SR)
    ref = mono[a0:a0 + n]
    best, best_c = jump, -2.0
    span = int(ms / 1000 * SR)
    b_nominal = int((out_t - jump) * SR)
    for off in range(-span, span + 1, 4):
        seg = mono[b_nominal + off:b_nominal + off + n]
        c = float(np.dot(ref, seg) / (np.linalg.norm(ref) * np.linalg.norm(seg) + 1e-9))
        if c > best_c:
            best, best_c = jump - off / SR, c
    print(f"splice: jump {jump:.3f}s -> {best:.4f}s (waveform corr {best_c:.3f})")
    return best


def extend(x: np.ndarray, out_t: float, jump: float, xfade: float) -> np.ndarray:
    a, b, f = int(out_t * SR), int((out_t - jump) * SR), int(xfade * SR)
    t = np.linspace(0, np.pi / 2, f, dtype=np.float32)[:, None]
    mixed = x[a:a + f] * np.cos(t) + x[b:b + f] * np.sin(t)  # equal power
    return np.concatenate([x[:a], mixed, x[b + f:]])


def lufs(path: Path) -> float:
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "ebur128", "-f", "null", "-"],
                       capture_output=True, text=True)
    return float(re.search(r"I:\s+(-?[\d.]+) LUFS", p.stderr[p.stderr.rfind("Summary:"):]).group(1))


def segment_lufs(path: Path, ranges) -> float:
    """Integrated loudness of the concatenation of time ranges (to compare speech vs pauses)."""
    parts = [decode(path)[int(s * SR):int(e * SR)] for s, e in ranges if e - s > 0.4]
    tmp = WORK / "_segments.wav"
    write_wav(tmp, np.concatenate(parts))
    v = lufs(tmp)
    tmp.unlink()
    return v


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=Path, help="music file to copy into the build (first run)")
    a = ap.parse_args()
    cfg = json.loads((HERE / "bgm.json").read_text())
    WORK.mkdir(parents=True, exist_ok=True)
    src = WORK / "source.m4a"
    if a.source:
        shutil.copy2(a.source, src)
    if hashlib.sha256(src.read_bytes()).hexdigest() != cfg["source_sha256"]:
        raise SystemExit("music file differs from video/bgm.json (source_sha256); re-analyse before mixing")
    tl = load_timeline()
    total = tl["total"]

    x = decode(src)
    ex = cfg["extend"]
    jump = refine_jump(x, ex["splice_out"], ex["jump_back"], ex["refine_ms"])
    if len(x) / SR < total:
        x = extend(x, ex["splice_out"], jump, ex["crossfade"])
    n = int(round(total * SR))
    x = x[:n] if len(x) >= n else np.concatenate([x, np.zeros((n - len(x), 2), np.float32)])
    fi, fo = int(cfg["fade_in"] * SR), int(cfg["fade_out"] * SR)
    x[:fi] *= np.linspace(0, 1, fi, dtype=np.float32)[:, None]
    x[-fo:] *= np.linspace(1, 0, fo, dtype=np.float32)[:, None] ** 2
    write_wav(WORK / "music-fit.wav", x)
    gain = cfg["music_lufs"] - lufs(WORK / "music-fit.wav")
    print(f"music: {len(x) / SR:.3f}s, gain {gain:+.1f} dB to {cfg['music_lufs']} LUFS")

    d = cfg["duck"]
    limit = 10 ** (cfg["limit_dbfs"] / 20)
    graph = (f"[1:a]volume={gain:.2f}dB[music];"
             # Mono voice on both channels at -3 dB keeps its -16 LUFS (EBU sums channel energy).
             f"[0:a]pan=stereo|c0=0.7071*c0|c1=0.7071*c0,asplit=2[voice][key];"
             f"[music][key]sidechaincompress=threshold={d['threshold']}:ratio={d['ratio']}:attack={d['attack_ms']}"
             f":release={d['release_ms']}:knee={d['knee']}[ducked];"
             f"[ducked]asplit=2[ducked_mix][ducked_out];"
             f"[voice][ducked_mix]amix=inputs=2:normalize=0:duration=first,alimiter=limit={limit:.4f}:level=disabled[mix]")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(AUDIO / "narration.wav"), "-i", str(WORK / "music-fit.wav"),
                    "-filter_complex", graph, "-map", "[mix]", "-c:a", "pcm_s24le", "-ar", str(SR), str(WORK / "mix.wav"),
                    "-map", "[ducked_out]", "-c:a", "pcm_s24le", "-ar", str(SR), str(WORK / "music-ducked.wav")], check=True)

    video = OUT / VIDEO_NAME
    out = OUT / cfg["output"]
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-i", str(WORK / "mix.wav"),
                    "-map", "0:v", "-map", "1:a", "-map_metadata", "0", "-map_chapters", "0",
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-ar", str(SR), "-ac", "2",
                    "-metadata:s:a:0", "language=chi", "-movflags", "+faststart", str(out)], check=True)

    # Report: overall loudness, and how loud the music sits under speech vs in pauses.
    speech = [(c["start"] + s["start"] + ln["start"], c["start"] + s["start"] + ln["end"])
              for c in tl["chapters"] for s in c["shots"] for ln in s["lines"]]
    gaps, prev = [], 0.0
    for s, e in speech:
        if s - prev > 0.8:
            gaps.append((prev + 0.3, s - 0.1))
        prev = e
    report = {"output": out.name, "seconds": total, "jump_back_refined": round(jump, 4),
              "mix_lufs": lufs(WORK / "mix.wav"),
              "music_under_speech_lufs": segment_lufs(WORK / "music-ducked.wav", speech),
              "music_in_pauses_lufs": segment_lufs(WORK / "music-ducked.wav", gaps),
              "config": cfg}
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / "bgm-mix.json").write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "config"}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
