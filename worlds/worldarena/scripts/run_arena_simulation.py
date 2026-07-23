#!/usr/bin/env python3
"""Run the authoritative Godot ArenaSimulation headlessly and save a replay bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from worldarena.paths import RUNS_ROOT as WORKSPACE_RUNS_ROOT
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT_PROJECT = ROOT / "godot"
RUNS_ROOT = WORKSPACE_RUNS_ROOT / "simulations"
RUNNER_SCRIPT = "res://scripts/arena/simulation/arena_batch_runner.gd"
SAFE_RUN_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
SAFE_SEED = re.compile(r"^[A-Za-z0-9._:-]{1,96}$")
POLICIES = ("deterministic_demo",)


def find_godot() -> Path | None:
    configured = Path(value).expanduser() if (value := os.environ.get("GODOT_BIN")) else None
    candidates = [configured] if configured else []
    for command in ("godot4", "godot"):
        if path := shutil.which(command):
            candidates.append(Path(path))
    candidates.extend(
        [
            Path("/Applications/Godot.app/Contents/MacOS/Godot"),
            Path("/Applications/Godot_mono.app/Contents/MacOS/Godot"),
        ]
    )
    return next(
        (path for path in candidates if path and path.is_file() and path.stat().st_mode & 0o111),
        None,
    )


def generated_run_id() -> str:
    return "arena-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def numeric_seed(label: str) -> int:
    """Match the backend seed-label mapping exactly."""
    return int.from_bytes(hashlib.sha256(label.encode("utf-8")).digest()[:4], "big") & 0x7FFFFFFF


def validate_run_options(args: argparse.Namespace) -> None:
    if not SAFE_RUN_ID.fullmatch(args.run_id):
        raise ValueError("--run-id must match [a-z0-9][a-z0-9_-]{0,63}")
    if not SAFE_SEED.fullmatch(args.seed):
        raise ValueError("--seed may contain only letters, digits, '.', '_', ':', or '-'")
    if not 1 <= args.max_rounds <= 200:
        raise ValueError("--max-rounds must be from 1 to 200")
    if args.policy not in POLICIES:
        raise ValueError("--policy must be one of: " + ", ".join(POLICIES))


def list_bundles() -> int:
    if not RUNS_ROOT.exists():
        print("No saved simulations.")
        return 0
    bundles = sorted(
        RUNS_ROOT.glob("*/bundle.json"), key=lambda path: path.stat().st_mtime, reverse=True
    )
    if not bundles:
        print("No saved simulations.")
        return 0
    for bundle in bundles:
        stat = bundle.stat()
        modified = datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(timespec="seconds")
        print(f"{bundle.parent.name}\t{stat.st_size} bytes\t{modified}\t{bundle.resolve()}")
    return 0


def run(args: argparse.Namespace) -> int:
    validate_run_options(args)
    godot = find_godot()
    if godot is None:
        print(
            "Godot 4 was not found. Set GODOT_BIN or install Godot in /Applications.",
            file=sys.stderr,
        )
        return 1
    output_dir = RUNS_ROOT / args.run_id
    output = output_dir / "bundle.json"
    if output.exists():
        print(f"Refusing to overwrite existing replay: {output}", file=sys.stderr)
        return 1
    output_dir.mkdir(parents=True, exist_ok=True)
    derived_seed = numeric_seed(args.seed)
    command: Sequence[str] = [
        str(godot), "--headless", "--path", str(GODOT_PROJECT), "--script", RUNNER_SCRIPT, "--",
        f"--output={output.resolve()}", f"--run-id={args.run_id}", f"--seed={derived_seed}",
        f"--seed-label={args.seed}", f"--max-rounds={args.max_rounds}", f"--policy={args.policy}",
    ]
    started = time.monotonic()
    completed = subprocess.run(command, cwd=ROOT, check=False, text=True)
    elapsed = time.monotonic() - started
    if completed.returncode != 0:
        print(f"Godot batch runner failed with exit code {completed.returncode}.", file=sys.stderr)
        return completed.returncode or 1
    if not output.is_file():
        print("Godot completed without writing a replay bundle.", file=sys.stderr)
        return 1
    with output.open(encoding="utf-8") as handle:
        bundle = json.load(handle)
    result = bundle.get("result", {})
    print(f"run id: {args.run_id}")
    reported_runtime = float(bundle.get("runtime_seconds", 0.0))
    simulated_seconds = float(bundle.get("simulated_seconds", 0.0))
    completed_rounds = int(bundle.get("completed_rounds", 0))
    winner = result.get("winner", "") or "pending"
    print(f"runtime: {elapsed:.3f}s (simulation reported {reported_runtime:.3f}s)")
    print(f"simulated: {simulated_seconds:.1f}s across {completed_rounds} rounds")
    print(f"result: {result.get('reason', 'unknown')}; winner={winner}")
    print(f"replay: {output.resolve()}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--list", action="store_true", help="List saved bundles without loading replay frames."
    )
    parser.add_argument("--run-id", default=generated_run_id())
    parser.add_argument("--seed", default="ARENA-2407")
    parser.add_argument("--max-rounds", type=int, default=24)
    parser.add_argument("--policy", default="deterministic_demo", choices=POLICIES)
    args = parser.parse_args()
    if args.list:
        return list_bundles()
    try:
        return run(args)
    except ValueError as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
