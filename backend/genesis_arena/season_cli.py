from __future__ import annotations

import argparse
import json
from pathlib import Path

from .arena import SeasonSpec, build_season_schedule, canonical_json


def generate(spec_path: Path, output_path: Path) -> str:
    """Validate a frozen season spec and write its deterministic 99+1 schedule."""

    raw = json.loads(spec_path.read_text(encoding="utf-8"))
    spec = SeasonSpec.model_validate(raw)
    schedule = build_season_schedule(spec)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(canonical_json(schedule) + "\n", encoding="utf-8")
    return schedule.schedule_hash


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate an immutable WorldArena 99-scored-plus-showcase schedule."
    )
    parser.add_argument("spec", type=Path, help="Path to a validated SeasonSpec JSON file")
    parser.add_argument("output", type=Path, help="Where to write the canonical schedule JSON")
    args = parser.parse_args()
    schedule_hash = generate(args.spec, args.output)
    print(f"WorldArena schedule written: {args.output}")
    print(f"SHA-256: {schedule_hash}")


if __name__ == "__main__":
    main()
