#!/usr/bin/env python3
"""Synthesize every narration line of video/plan.json with Asset Workbench.

Each line is one `audio.tts` clone job (Higgs TTS 3 Q8_0) run through the
installed `aw` CLI against a dedicated AW project. The voice reference is the
synthetic Kokoro zf_001 recording bundled with AW (not a real person).

Results are cached by sha256(text + method), so re-running only synthesizes
lines whose spoken text, seed or reference changed. Before every job the
script waits until the GPU has room (another service may be using it).

    AW_TTS_PROJECT=/path/to/aw-project AW_TTS_REFERENCE=/path/to/aw/audio-example \
    python3 video/aw_tts.py              # synthesize missing lines
    python3 video/aw_tts.py --dry-run    # list lines, character counts, estimate
    python3 video/aw_tts.py --only c1s2-0,c1s2-1
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import wave

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
BUILD = HERE / "build"
# Both locations are machine specific and must be given explicitly:
#   AW_TTS_PROJECT    an AW project with an audio domain (`aw init`, then
#                     `aw project init --runtime ""` so `aw up` starts no GPU runtime)
#   AW_TTS_REFERENCE  folder holding AW's bundled audio example
#                     (reference.wav / reference.txt / reference-provenance.json)
REF_DIR = Path(os.environ["AW_TTS_REFERENCE"]) if os.environ.get("AW_TTS_REFERENCE") else None
REF_FILES = ("reference.wav", "reference.txt", "reference-provenance.json")
REF_SHA256 = "556b1ec85a1be292ac30b25552767f3505f3895c23dd3292f5dfc100b29ae976"
CHARS_PER_SECOND = 5.3  # measured on the trial line (31 chars -> 5.7 s raw)
MIN_FREE_MB = 7000


def sha256(path: Path) -> str:
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()


def plan_lines(plan: dict):
    """Yield (line_id, spoken_text, seed) in timeline order."""
    voice = plan["voice"]
    for chapter in plan["chapters"]:
        for shot in chapter["shots"]:
            for i, line in enumerate(shot.get("lines", [])):
                yield f'{shot["id"]}-{i}', line.get("say", line["sub"]), int(line.get("seed", voice["seed"]))


def cache_key(text: str, seed: int, voice: dict) -> str:
    method = {"text": text, "seed": seed, "model": voice["model"], "mode": voice["mode"],
              "text_chunk_size": voice["text_chunk_size"], "reference_sha256": REF_SHA256}
    return hashlib.sha256(json.dumps(method, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def gpu_state():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.total,memory.used,utilization.gpu",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, check=True).stdout
        total, used, util = (float(x) for x in out.strip().splitlines()[0].split(","))
        return total - used, util
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None, None


def wait_for_gpu():
    """Block while another process occupies the GPU (free VRAM or utilization)."""
    announced = False
    while True:
        free, util = gpu_state()
        if free is None or (free >= MIN_FREE_MB and util < 40):
            if announced:
                print("GPU idle again, continuing", flush=True)
            return
        if not announced:
            print(f"GPU busy (free {free:.0f} MB, util {util:.0f}%), waiting...", flush=True)
            announced = True
        time.sleep(30)


def wav_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / w.getframerate()


def synthesize(awroot: Path, line_id: str, text: str, seed: int, key: str, voice: dict) -> dict:
    tag = f"{line_id}-{key[:12]}"
    recipe_dir = awroot / "art/inputs/narration" / tag
    out_dir = awroot / "art/derived/narration" / tag
    marker = out_dir / "aw-result.json"
    if marker.exists():
        return json.loads(marker.read_text())
    if out_dir.exists():
        # Incomplete earlier attempt: keep it for inspection, never overwrite.
        out_dir.rename(out_dir.with_name(f"{tag}.incomplete-{int(time.time())}"))
    recipe_dir.mkdir(parents=True, exist_ok=True)
    for name in REF_FILES:
        target = recipe_dir / name
        if not target.exists():
            shutil.copy2(REF_DIR / name, target)
    recipe = {
        "schema_version": 1,
        "mode": voice["mode"],
        "text": text,
        "reference": {"audio": "reference.wav", "transcript": "reference.txt", "provenance": "reference-provenance.json"},
        "generation": {"seed": seed, "text_chunk_size": voice["text_chunk_size"]},
        "delivery": {"formats": ["wav"], "sample_rate": 48000, "channels": 1, "loudness": {"enabled": False}},
    }
    # JSON is valid YAML; it avoids any quoting ambiguity in the narration text.
    (recipe_dir / "recipe.yaml").write_text(json.dumps(recipe, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    wait_for_gpu()
    started = time.monotonic()
    proc = subprocess.run(["aw", "--project", str(awroot), "workflow", "run", "audio.tts",
                           "--input", str(recipe_dir / "recipe.yaml"), "--output", str(out_dir), "--json"],
                          capture_output=True, text=True, timeout=900)
    elapsed = time.monotonic() - started
    try:
        result = json.loads(proc.stdout[proc.stdout.find("{"):])
    except ValueError:
        result = {"status": "failed", "stdout": proc.stdout[-2000:]}
    if proc.returncode != 0 or result.get("status") != "completed":
        raise RuntimeError(f"{line_id}: AW audio.tts failed (exit {proc.returncode}): {proc.stderr[-1500:]} {result}")
    quality = json.loads((out_dir / result["quality"]).read_text())
    record = {"line": line_id, "text": text, "seed": seed, "cache_key": key, "aw_output": str(out_dir),
              "raw": str(out_dir / result["raw"]), "quality_status": quality.get("status"),
              "warnings": quality.get("raw", {}).get("warnings", []), "elapsed_seconds": round(elapsed, 2)}
    marker.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    return record


def restart_manager(awroot: Path) -> None:
    """The global AW install was updated under a running manager: AW refuses
    to run audio with a mismatched implementation, so restart only this
    project's manager (it owns no other work)."""
    print("AW implementation changed; restarting this project's manager", flush=True)
    subprocess.run(["aw", "--project", str(awroot), "down"], capture_output=True, text=True, timeout=300)
    subprocess.run(["aw", "--project", str(awroot), "up"], capture_output=True, text=True, timeout=300)


def synthesize_with_retry(awroot: Path, line_id: str, text: str, seed: int, key: str, voice: dict, attempts: int = 5) -> dict:
    for attempt in range(1, attempts + 1):
        try:
            return synthesize(awroot, line_id, text, seed, key, voice)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            message = str(error)
            print(f"    attempt {attempt} failed: {message[-300:]}", flush=True)
            if attempt == attempts:
                raise
            if "implementation changed" in message:
                restart_manager(awroot)
            else:
                # Typically another GPU job grabbed VRAM mid-request (HTTP 500
                # "failed to allocate"); wait until the GPU is free again.
                time.sleep(60)
                wait_for_gpu()
    raise AssertionError("unreachable")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--awroot", type=Path, default=Path(os.environ["AW_TTS_PROJECT"]) if os.environ.get("AW_TTS_PROJECT") else None,
                    help="AW project root (default: $AW_TTS_PROJECT)")
    ap.add_argument("--only", help="comma separated line ids")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    plan = json.loads((HERE / "plan.json").read_text())
    voice = plan["voice"]
    rows = list(plan_lines(plan))
    if args.dry_run:
        total = 0
        for line_id, text, seed in rows:
            total += len(text)
            print(f"{line_id:8s} {len(text):3d}  {text}")
        print(f"{len(rows)} lines, {total} chars, ~{total / CHARS_PER_SECOND:.0f} s of speech")
        return
    if args.awroot is None or REF_DIR is None:
        raise SystemExit("set AW_TTS_PROJECT (AW project root) and AW_TTS_REFERENCE (AW audio example folder)")
    if sha256(REF_DIR / "reference.wav") != REF_SHA256:
        raise SystemExit("AW reference recording changed; refusing to clone from an unexpected voice")
    only = set(args.only.split(",")) if args.only else None
    raw_dir = BUILD / "audio" / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = BUILD / "audio" / "tts-manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    todo = [r for r in rows if only is None or r[0] in only]
    for n, (line_id, text, seed) in enumerate(todo, 1):
        key = cache_key(text, seed, voice)
        if manifest.get(line_id, {}).get("cache_key") == key and (raw_dir / f"{line_id}.wav").exists():
            continue
        print(f"[{n}/{len(todo)}] {line_id}: {text}", flush=True)
        record = synthesize_with_retry(args.awroot, line_id, text, seed, key, voice)
        shutil.copy2(record["raw"], raw_dir / f"{line_id}.wav")
        record["raw_sha256"] = sha256(raw_dir / f"{line_id}.wav")
        record["raw_seconds"] = round(wav_seconds(raw_dir / f"{line_id}.wav"), 3)
        manifest[line_id] = record
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        print(f"    -> {record['raw_seconds']} s, {record['quality_status']}, {record.get('elapsed_seconds', 0)} s wall", flush=True)
    missing = [r[0] for r in rows if not (raw_dir / f"{r[0]}.wav").exists()]
    print("TTS DONE" if not missing else f"TTS INCOMPLETE: missing {missing}", flush=True)
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
