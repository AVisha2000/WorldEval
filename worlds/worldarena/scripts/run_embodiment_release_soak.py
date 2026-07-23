#!/usr/bin/env python3
"""Run the credential-free 1,000-execution Godot release soak and frozen-package audit."""

from __future__ import annotations

import argparse
import json
import os
import resource
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
DEFAULT_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
EVIDENCE_PREFIX = "EMBODIMENT_RELEASE_SOAK_EVIDENCE="
MINIMUM_RELEASE_EXECUTIONS = 1_000
PUBLIC_FORBIDDEN_TOKENS = (
    "sk-proj-",
    "sk-ant-",
    "aiza",
    "api_key",
    "authorization",
    "attachment_ticket",
    "checkpoint_hash",
    "credential",
    "hidden_state",
    "position_axial",
    "position_mt",
    "prompt",
    "raw_model_output",
    "raw_output",
    "session_secret",
    "spectator",
)


class ReleaseSoakError(RuntimeError):
    """Stable failure raised when the release soak cannot prove its gate."""


def parse_godot_evidence(stdout: str) -> Mapping[str, Any]:
    """Parse exactly one final canonical evidence line from the headless runner."""

    lines = [line for line in stdout.splitlines() if line.startswith(EVIDENCE_PREFIX)]
    if len(lines) != 1:
        raise ReleaseSoakError("release_soak_evidence_line_invalid")
    try:
        value = json.loads(lines[0][len(EVIDENCE_PREFIX) :])
    except json.JSONDecodeError as error:
        raise ReleaseSoakError("release_soak_evidence_json_invalid") from error
    if not isinstance(value, dict):
        raise ReleaseSoakError("release_soak_evidence_shape_invalid")
    return value


def validate_release_evidence(
    evidence: Mapping[str, Any], *, minimum_executions: int = MINIMUM_RELEASE_EXECUTIONS
) -> None:
    """Fail closed when the matrix or bounded-resource evidence is incomplete."""

    executions = evidence.get("execution_count")
    variants = evidence.get("variant_count")
    invalid_windows = evidence.get("invalid_neutral_windows")
    memory = evidence.get("memory")
    case_counts = evidence.get("case_counts")
    if isinstance(executions, bool) or not isinstance(executions, int):
        raise ReleaseSoakError("release_soak_execution_count_invalid")
    if executions < minimum_executions:
        raise ReleaseSoakError("release_soak_execution_count_insufficient")
    if variants != 23 or not isinstance(case_counts, dict) or len(case_counts) != variants:
        raise ReleaseSoakError("release_soak_case_matrix_incomplete")
    if not isinstance(invalid_windows, int) or invalid_windows < 1:
        raise ReleaseSoakError("release_soak_neutral_fallback_missing")
    if not isinstance(memory, dict):
        raise ReleaseSoakError("release_soak_memory_metrics_missing")
    growth = memory.get("growth_bytes")
    if not isinstance(growth, int) or growth > 64 * 1024 * 1024:
        raise ReleaseSoakError("release_soak_memory_growth_unbounded")
    for key, value in case_counts.items():
        if not isinstance(key, str) or not isinstance(value, dict):
            raise ReleaseSoakError("release_soak_case_shape_invalid")
        if value.get("executions", 0) < 2 or value.get("authority_ticks", 0) < 1:
            raise ReleaseSoakError("release_soak_case_not_executed")


def scan_public_output(text: str) -> None:
    """Reject credential signatures and protected field names in emitted public evidence."""

    lowered = text.lower()
    for token in PUBLIC_FORBIDDEN_TOKENS:
        if token in lowered:
            raise ReleaseSoakError(f"release_soak_public_output_leak:{token}")


def _run_checked(command: Sequence[str], *, label: str) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        suffix = detail[-1] if detail else "no diagnostic"
        raise ReleaseSoakError(f"{label}_failed:{suffix}")
    return completed.stdout


def verify_frozen_packages() -> Mapping[str, str]:
    """Prove both frozen protocol trees match HEAD and their canonical locks."""

    _run_checked(
        [sys.executable, "scripts/build_embodiment_protocol_lock.py", "--check"],
        label="embodiment_v1_lock_check",
    )
    duel_output = _run_checked(
        [sys.executable, "scripts/build_duel_protocol_lock.py", "--check"],
        label="duel_lock_check",
    )
    _run_checked(
        [
            "git",
            "diff",
            "--quiet",
            "HEAD",
            "--",
            "game/embodiment_protocol",
            "game/duel_protocol",
        ],
        label="frozen_protocol_byte_check",
    )
    frozen_status = _run_checked(
        [
            "git",
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--",
            "game/embodiment_protocol",
            "game/duel_protocol",
        ],
        label="frozen_protocol_status_check",
    )
    if frozen_status.strip():
        raise ReleaseSoakError("frozen_protocol_tree_changed")
    duel_line = duel_output.strip().splitlines()[-1]
    return {
        "duel": duel_line,
        "embodiment_v1": "canonical lock and Godot identity verified; zero bytes changed",
    }


def run_native_replay_verifiers(godot: Path) -> Mapping[str, str]:
    """Exercise the native verifier for every immutable controller protocol generation."""

    runners = {
        "llm-controller/0.1.0": "res://tests/embodiment/embodiment_replay_headless_runner.gd",
        "llm-controller/0.2.0": (
            "res://tests/embodiment/duo_games/duo_v2_managed_replay_headless_runner.gd"
        ),
        "llm-controller/0.3.0": "res://tests/embodiment/trio_protocol_v3_headless_runner.gd",
    }
    results: dict[str, str] = {}
    for protocol_version, runner in runners.items():
        output = _run_checked(
            [
                str(godot),
                "--headless",
                "--path",
                str(ROOT / "godot"),
                "--script",
                runner,
            ],
            label=f"native_replay_verifier_{protocol_version.replace('/', '_')}",
        )
        ok_lines = [line for line in output.splitlines() if line.endswith("_OK")]
        if not ok_lines:
            raise ReleaseSoakError("native_replay_verifier_success_marker_missing")
        results[protocol_version] = ok_lines[-1]
    return results


def _owned_group_processes(process_group_id: int) -> tuple[int, ...]:
    """Return any remaining process IDs from the private soak process group."""

    completed = subprocess.run(
        ["ps", "-axo", "pid=,pgid="],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    remaining: list[int] = []
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and int(fields[1]) == process_group_id:
            remaining.append(int(fields[0]))
    return tuple(remaining)


def _child_peak_rss_bytes(before: int, after: int) -> int:
    peak = max(before, after)
    # Darwin reports bytes; Linux and most BSD libc implementations report KiB.
    return peak if sys.platform == "darwin" else peak * 1024


def run_release_soak(
    *, godot: Path, rounds: int, timeout_seconds: int, require_release_minimum: bool = True
) -> Mapping[str, Any]:
    if not godot.is_file():
        raise ReleaseSoakError("release_soak_godot_missing")
    if rounds < 1 or rounds > 1_000:
        raise ReleaseSoakError("release_soak_rounds_invalid")
    minimum = MINIMUM_RELEASE_EXECUTIONS if require_release_minimum else 1
    if require_release_minimum and rounds < 22:
        raise ReleaseSoakError("release_soak_rounds_below_release_gate")

    frozen = verify_frozen_packages()
    verifier_results = run_native_replay_verifiers(godot)
    command = [
        str(godot),
        "--headless",
        "--path",
        str(ROOT / "godot"),
        "--script",
        "res://tests/embodiment/embodiment_release_soak_headless_runner.gd",
        "--",
        f"--rounds={rounds}",
    ]
    rss_before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        os.killpg(process.pid, 15)
        process.communicate(timeout=10)
        raise ReleaseSoakError("release_soak_timeout") from error
    duration_seconds = time.monotonic() - started
    rss_after = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if process.returncode != 0 or "EMBODIMENT_RELEASE_SOAK_OK" not in stdout:
        diagnostic = (stderr or stdout).strip().splitlines()
        suffix = diagnostic[-1] if diagnostic else "no diagnostic"
        raise ReleaseSoakError(f"release_soak_godot_failed:{suffix}")
    if process.poll() is None:
        raise ReleaseSoakError("release_soak_process_not_reaped")
    remaining = _owned_group_processes(process.pid)
    if remaining:
        raise ReleaseSoakError(f"release_soak_descendant_process_leak:{remaining}")

    evidence = parse_godot_evidence(stdout)
    validate_release_evidence(evidence, minimum_executions=minimum)
    # Scan the public JSON payload, not Godot's engine banner or protected internal diagnostics.
    scan_public_output(json.dumps(evidence, sort_keys=True, separators=(",", ":")))
    return {
        "authority": evidence,
        "credential_network_mode": "credential-free; direct local authorities; zero provider calls",
        "frozen_packages": frozen,
        "godot_processes_reaped": 4,
        "native_replay_verifier_failures": 0,
        "native_replay_verifiers": verifier_results,
        "owned_descendant_processes": 0,
        "peak_child_rss_bytes": _child_peak_rss_bytes(rss_before, rss_after),
        "wall_time_seconds": round(duration_seconds, 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=DEFAULT_GODOT)
    parser.add_argument("--rounds", type=int, default=22)
    parser.add_argument("--timeout-seconds", type=int, default=600)
    parser.add_argument(
        "--allow-short",
        action="store_true",
        help="developer-only smoke mode; does not satisfy the 1,000-execution release gate",
    )
    arguments = parser.parse_args()
    try:
        summary = run_release_soak(
            godot=arguments.godot,
            rounds=arguments.rounds,
            timeout_seconds=arguments.timeout_seconds,
            require_release_minimum=not arguments.allow_short,
        )
    except (OSError, ReleaseSoakError, subprocess.SubprocessError, ValueError) as error:
        print(f"EMBODIMENT_RELEASE_SOAK_FAILED {error}")
        return 2
    summary_json = json.dumps(summary, sort_keys=True, separators=(",", ":"))
    print("EMBODIMENT_RELEASE_SOAK_OK " + summary_json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
