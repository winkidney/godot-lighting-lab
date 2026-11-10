#!/usr/bin/env python3
"""Offline ASR spot-check of the synthesized narration (auxiliary only).

Transcribes every line with faster-whisper and compares the pinyin of the
Chinese characters with the spoken text from plan.json, so traditional /
simplified output and homophones don't count as errors. English terms are
ignored in the score (Whisper often writes them as Chinese sound-alikes).
A low score means "listen to this line", not proof that it is wrong; a high
score does not replace listening.

Needs a Python with faster-whisper and pypinyin, e.g.
    VIDEO_ASR_PYTHON=/path/to/venv/bin/python HF_HUB_OFFLINE=1 \
    $VIDEO_ASR_PYTHON video/asr_check.py --cache /path/to/whisper/cache
"""
import argparse
from difflib import SequenceMatcher
import json
from pathlib import Path
import re

from faster_whisper import WhisperModel
from pypinyin import lazy_pinyin

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"


def syllables(text: str) -> list[str]:
    return lazy_pinyin("".join(ch for ch in text if "一" <= ch <= "鿿"))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", help="faster-whisper download_root (models already present)")
    ap.add_argument("--model", default="small")
    ap.add_argument("--threshold", type=float, default=0.8)
    a = ap.parse_args()
    plan = json.loads((HERE / "plan.json").read_text())
    manifest = json.loads((BUILD / "audio/tts-manifest.json").read_text())
    report_path = BUILD / "evidence/asr-check.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    previous = {r["line"]: r for r in json.loads(report_path.read_text())} if report_path.exists() else {}
    model = WhisperModel(a.model, device="cpu", compute_type="int8", cpu_threads=8, download_root=a.cache)
    rows = []
    for chapter in plan["chapters"]:
        for shot in chapter["shots"]:
            for i, line in enumerate(shot.get("lines", [])):
                lid = f'{shot["id"]}-{i}'
                said = line.get("say", line["sub"])
                sha = manifest.get(lid, {}).get("raw_sha256")
                if lid in previous and previous[lid].get("raw_sha256") == sha and previous[lid]["expected"] == said:
                    rows.append(previous[lid])
                    continue
                segments, _ = model.transcribe(str(BUILD / "audio/raw" / f"{lid}.wav"), language="zh", beam_size=3,
                                               vad_filter=False, condition_on_previous_text=False)
                heard = "".join(s.text for s in segments)
                score = SequenceMatcher(None, syllables(said), syllables(heard)).ratio()
                row = {"line": lid, "expected": said, "recognized": heard, "pinyin_similarity": round(score, 3),
                       "latin_heard": re.findall(r"[A-Za-z]+", heard), "raw_sha256": sha,
                       "flag": score < a.threshold}
                rows.append(row)
                print(("FLAG " if row["flag"] else "ok   ") + f"{lid} {score:.2f}  {heard}", flush=True)
    report_path.write_text(json.dumps(rows, ensure_ascii=False, indent=1) + "\n")
    flagged = [r["line"] for r in rows if r["flag"]]
    print(f"ASR: {len(rows)} lines, {len(flagged)} flagged {flagged}")


if __name__ == "__main__":
    main()
