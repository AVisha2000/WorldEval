#!/usr/bin/env python3
"""Generate or check the embodiment golden fixtures from the real Godot authority."""

from __future__ import annotations

import argparse
import base64
import subprocess
from pathlib import Path

from genesis_arena.embodiment.golden import verify_golden_bytes

ROOT = Path(__file__).resolve().parents[1]
GODOT_PROJECT = ROOT / "godot"
GOLDEN_ROOT = ROOT / "game" / "embodiment_protocol" / "golden"
GENERATOR = "res://tests/embodiment/embodiment_golden_fixture_generator.gd"
PREFIX = "EMBODIMENT_GOLDEN_TRANSCRIPT_BASE64:"
TRANSCRIPT_IDS = (
    "stage-a-orientation-forward-v1",
    "stage-b-interaction-v1",
    "stage-c-construction-v1",
    "stage-d-neutral-encounter-v1",
)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if checked-in fixtures differ")
    parser.add_argument(
        "--godot",
        default="/Applications/Godot.app/Contents/MacOS/Godot",
        help="Godot executable",
    )
    return parser.parse_args()


def _generate(godot: str) -> dict[str, bytes]:
    completed = subprocess.run(
        [godot, "--headless", "--path", str(GODOT_PROJECT), "--script", GENERATOR],
        check=True,
        capture_output=True,
        text=True,
    )
    generated: dict[str, bytes] = {}
    for line in completed.stdout.splitlines():
        if not line.startswith(PREFIX):
            continue
        name, encoded = line.removeprefix(PREFIX).split("=", 1)
        if name in generated:
            raise SystemExit(f"duplicate generated golden transcript: {name}")
        try:
            payload = base64.b64decode(encoded, validate=True) + b"\n"
        except ValueError as error:
            raise SystemExit(f"invalid generated base64 for {name}") from error
        transcript = verify_golden_bytes(payload)
        if transcript["transcript_id"] != name:
            raise SystemExit(f"generated transcript identity differs for {name}")
        generated[name] = payload
    if set(generated) != set(TRANSCRIPT_IDS):
        raise SystemExit("Godot did not emit the exact expected golden transcript set")
    return generated


def main() -> int:
    args = _arguments()
    generated = _generate(args.godot)
    differences: list[str] = []
    for transcript_id in TRANSCRIPT_IDS:
        target = GOLDEN_ROOT / f"{transcript_id}.json"
        payload = generated[transcript_id]
        if args.check:
            if not target.is_file() or target.read_bytes() != payload:
                differences.append(transcript_id)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
    if differences:
        raise SystemExit("golden fixtures differ: " + ", ".join(differences))
    print("EMBODIMENT_GOLDEN_FIXTURES_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
