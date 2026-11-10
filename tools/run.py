#!/usr/bin/env python3
"""Run Godot Lighting Lab with an existing Godot 4.7 install; installs nothing.

Modes:
  run       open the lab window (optionally --module N to start on module N)
  editor    open the project in the Godot editor
  import    headless editor import (only needed after adding imported assets)
  validate  headless logic check: every module, parameter and preset,
            the UI smoke test and the tutorial video plan
  capture   windowed screenshots of every module x preset into captures/
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ERROR_RE = re.compile(
    r"(SCRIPT ERROR|Parse Error|SHADER ERROR|Failed to compile|^\s*ERROR:|VALIDATION FAILED)"
)


def godot_binary():
    candidates = [os.environ.get("GODOT"), os.environ.get("GODOT_BIN"), shutil.which("godot"), shutil.which("godot4")]
    candidates.append(str(Path.home() / ".local/bin/godot"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise SystemExit("Godot 4.7 is required. Put it on PATH or set GODOT=/path/to/godot.")


def display_args(env):
    """Reuse the desktop's Wayland session when launched from a bare shell."""
    if not sys.platform.startswith("linux"):
        return []
    if not env.get("DISPLAY") and not env.get("WAYLAND_DISPLAY"):
        runtime = Path(env.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
        if (runtime / "wayland-0").exists():
            env["XDG_RUNTIME_DIR"] = str(runtime)
            env["WAYLAND_DISPLAY"] = "wayland-0"
    if env.get("WAYLAND_DISPLAY"):
        return ["--display-driver", "wayland"]
    return []


def run_checked(cmd, env, label):
    """Stream Godot output and fail on any engine/script/shader error line."""
    errors = []
    proc = subprocess.Popen(cmd, env=env, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        if ERROR_RE.search(line):
            errors.append(line.rstrip())
    code = proc.wait()
    if errors or code != 0:
        print(f"\n[{label}] FAILED (exit={code}, {len(errors)} error line(s))")
        for line in errors[:60]:
            print("   ", line)
        return 1
    print(f"\n[{label}] OK")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", nargs="?", default="run", choices=["run", "editor", "import", "validate", "capture"])
    parser.add_argument("--module", type=int, help="run: module number to open first (1-5)")
    parser.add_argument("--only", help="capture: module id(s), comma separated, e.g. 03 or 01,05")
    parser.add_argument("--out", default="res://captures", help="capture: output directory")
    args = parser.parse_args()

    env = os.environ.copy()
    godot = godot_binary()
    base = [godot, "--path", str(ROOT), "--audio-driver", "Dummy"]

    if args.mode == "import":
        raise SystemExit(subprocess.call([godot, "--headless", "--editor", "--path", str(ROOT), "--quit"], env=env, cwd=ROOT))
    if args.mode == "validate":
        code = run_checked(base + ["--headless", "--script", "res://tools/validate_runtime.gd"], env, "validate")
        code |= run_checked(base + ["--headless", "--script", "res://tools/ui_smoke_test.gd"], env, "ui-smoke")
        code |= run_checked(base + ["--headless", "--script", "res://tools/tutorial_director.gd", "--", "--check"], env, "video-plan")
        raise SystemExit(code)

    cmd = base + display_args(env)
    if args.mode == "editor":
        cmd.append("--editor")
        raise SystemExit(subprocess.call(cmd, env=env, cwd=ROOT))
    if args.mode == "capture":
        cmd += ["--script", "res://tools/capture_runtime.gd", "--", f"--out={args.out}"]
        if args.only:
            cmd.append(f"--only={args.only}")
        raise SystemExit(run_checked(cmd, env, "capture"))
    if args.module:
        cmd += ["--", f"--module={args.module}"]
    raise SystemExit(subprocess.call(cmd, env=env, cwd=ROOT))


if __name__ == "__main__":
    main()
