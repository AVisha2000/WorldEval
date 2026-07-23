#!/usr/bin/env python3
"""Run the provider-free WorldArena Duel Godot certification runners.

The suite is intentionally sequential: several runners exercise fresh-process
determinism and performance, so overlapping Godot processes would contaminate
their timing and make failures harder to attribute.  Socket/export/capture
runners have dedicated harnesses and are excluded here.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence

ROOT = Path(__file__).resolve().parents[1]
GODOT_PROJECT = ROOT / "godot"
RUNNER_DIRECTORY = GODOT_PROJECT / "tests" / "duel"
EXCLUDED_RUNNERS = frozenset(
    {
        "duel_dedicated_stage_smoke_runner.gd",
        "duel_gateway_websocket_integration_runner.gd",
        "duel_presentation_capture_runner.gd",
    }
)


@dataclass(frozen=True)
class RunnerResult:
    runner: str
    status: str
    duration_ms: int
    returncode: int
    output_tail: str


def discover_runners() -> tuple[Path, ...]:
    return tuple(
        path
        for path in sorted(RUNNER_DIRECTORY.glob("*_headless_runner.gd"))
        if path.name not in EXCLUDED_RUNNERS
    )


def resolve_godot(explicit: str | None) -> Path:
    candidates = [
        explicit,
        os.environ.get("GODOT_BIN"),
        "/Applications/Godot.app/Contents/MacOS/Godot",
        shutil.which("godot4"),
        shutil.which("godot"),
    ]
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser().resolve()
            if path.is_file() and os.access(path, os.X_OK):
                return path
    raise RuntimeError("Godot 4 executable was not found; pass --godot or set GODOT_BIN")


def run_runner(godot: Path, runner: Path, timeout_s: float) -> RunnerResult:
    resource_path = f"res://tests/duel/{runner.name}"
    started = time.monotonic_ns()
    try:
        completed = subprocess.run(
            [
                str(godot),
                "--headless",
                "--path",
                str(GODOT_PROJECT),
                "--script",
                resource_path,
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            env=os.environ.copy(),
        )
        output = completed.stdout + completed.stderr
        returncode = completed.returncode
        status = "passed" if returncode == 0 else "failed"
    except subprocess.TimeoutExpired as exc:
        stdout = (
            exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else exc.stdout
        )
        stderr = (
            exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else exc.stderr
        )
        output = (stdout or "") + (stderr or "")
        returncode = 124
        status = "timed_out"
    duration_ms = (time.monotonic_ns() - started) // 1_000_000
    return RunnerResult(
        runner=runner.name,
        status=status,
        duration_ms=duration_ms,
        returncode=returncode,
        output_tail=_bounded_tail(output),
    )


def _bounded_tail(output: str, *, lines: int = 24, characters: int = 8_000) -> str:
    tail = "\n".join(output.splitlines()[-lines:])
    return tail[-characters:]


def _select_runners(all_runners: Sequence[Path], requested: Sequence[str]) -> tuple[Path, ...]:
    if not requested:
        return tuple(all_runners)
    indexed = {runner.name: runner for runner in all_runners}
    selected: list[Path] = []
    for name in requested:
        normalized = name if name.endswith(".gd") else f"{name}.gd"
        runner = indexed.get(normalized)
        if runner is None:
            raise ValueError(f"unknown or dedicated-harness runner: {name}")
        if runner not in selected:
            selected.append(runner)
    return tuple(selected)


def _write_report(path: Path, godot: Path, results: Sequence[RunnerResult]) -> None:
    payload = {
        "format": "worldeval-duel-headless-certification/1.0.0",
        "godot_executable": str(godot),
        "project": str(GODOT_PROJECT),
        "results": [asdict(result) for result in results],
        "summary": {
            "failed": sum(result.status != "passed" for result in results),
            "passed": sum(result.status == "passed" for result in results),
            "total": len(results),
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help="Exact Godot 4 executable")
    parser.add_argument(
        "--runner",
        action="append",
        default=[],
        help="Run one discovered runner by basename; repeat to select several",
    )
    parser.add_argument(
        "--timeout", type=float, default=300.0, help="Per-runner timeout in seconds"
    )
    parser.add_argument("--report", type=Path, help="Optional JSON certification report path")
    parser.add_argument("--list", action="store_true", help="List included runners and exit")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.timeout <= 0:
        print("--timeout must be positive", file=sys.stderr)
        return 2
    try:
        runners = _select_runners(discover_runners(), args.runner)
        if args.list:
            for runner in runners:
                print(runner.name)
            return 0
        godot = resolve_godot(args.godot)
    except (RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if not runners:
        print("No Duel headless runners were discovered", file=sys.stderr)
        return 2

    results: list[RunnerResult] = []
    for index, runner in enumerate(runners, start=1):
        print(f"[{index}/{len(runners)}] {runner.name}", flush=True)
        result = run_runner(godot, runner, args.timeout)
        results.append(result)
        print(f"  {result.status} ({result.duration_ms} ms)", flush=True)
        if result.status != "passed" and result.output_tail:
            print(result.output_tail, file=sys.stderr, flush=True)

    if args.report is not None:
        _write_report(args.report.resolve(), godot, results)
    failed = [result for result in results if result.status != "passed"]
    print(
        f"DUEL_HEADLESS_SUITE total={len(results)} "
        f"passed={len(results) - len(failed)} failed={len(failed)}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
