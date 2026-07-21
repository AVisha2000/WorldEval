#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path
from typing import Any


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _raw_record(package_root: Path, relative_path: str) -> dict[str, Any]:
    payload = (package_root / relative_path).read_bytes()
    return {
        "path": relative_path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _expand_palette_indices(manifest: dict[str, Any]) -> list[list[int]]:
    rows: list[list[int]] = []
    for encoded_row in manifest["grid"]["rows"]:
        row: list[int] = []
        for offset in range(0, len(encoded_row), 2):
            palette_index, count = encoded_row[offset : offset + 2]
            row.extend([palette_index] * count)
        rows.append(row)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate or verify WorldArena Duel conformance golden hashes."
    )
    parser.add_argument("--check", action="store_true", help="verify without writing")
    parser.add_argument(
        "--package",
        type=Path,
        default=_repository_root() / "game" / "duel_protocol",
        help="protocol package root",
    )
    args = parser.parse_args()

    sys.path.insert(0, str(_repository_root() / "backend"))
    from genesis_arena.duel.canonical import canonical_json_bytes
    from genesis_arena.duel.protocol import ProtocolPackage

    package_root = args.package.resolve()
    package = ProtocolPackage(package_root)
    excluded = {
        "README.md",
        "conformance/golden-hashes.json",
        "protocol-lock.json",
    }
    artifact_paths = sorted(
        path.relative_to(package_root).as_posix()
        for path in package_root.rglob("*")
        if path.is_file() and path.relative_to(package_root).as_posix() not in excluded
    )
    canonical_fixture_paths = [
        "fixtures/action-batch.valid.json",
        "fixtures/match-init.valid.json",
        "fixtures/observation.maximal.valid.json",
        "maps/crossroads-duel-v1.json",
    ]
    canonical_fixtures = []
    for relative_path in canonical_fixture_paths:
        encoded = canonical_json_bytes(package.read_json(relative_path))
        canonical_fixtures.append(
            {
                "canonical_sha256": hashlib.sha256(encoded).hexdigest(),
                "canonical_size_bytes": len(encoded),
                "path": relative_path,
            }
        )

    manifest = package.read_json("maps/crossroads-duel-v1.json")
    palette_rows = _expand_palette_indices(manifest)
    cell_rows = [
        [manifest["cell_palette"][palette_index] for palette_index in row]
        for row in palette_rows
    ]
    palette_bytes = canonical_json_bytes(palette_rows)
    cell_bytes = canonical_json_bytes(cell_rows)
    body = {
        "artifact_hash_scope": "raw_artifact_bytes",
        "artifacts": [_raw_record(package_root, path) for path in artifact_paths],
        "canonical_fixtures": canonical_fixtures,
        "canonicalization": "rfc8785-integer-nfc-subset-v1",
        "conformance_id": "golden-hashes.duel-v1",
        "expanded_grid": {
            "cell_count": sum(len(row) for row in palette_rows),
            "encoding": "row-major-256-rows-by-384-columns",
            "palette_index_grid_canonical_sha256": hashlib.sha256(
                palette_bytes
            ).hexdigest(),
            "palette_index_grid_canonical_size_bytes": len(palette_bytes),
            "positional_cell_grid_canonical_sha256": hashlib.sha256(
                cell_bytes
            ).hexdigest(),
            "positional_cell_grid_canonical_size_bytes": len(cell_bytes),
        },
        "hash_algorithm": "sha256",
        "protocol_version": package.version,
    }
    encoded = canonical_json_bytes(body) + b"\n"
    destination = package_root / "conformance" / "golden-hashes.json"
    if args.check:
        if not destination.is_file() or destination.read_bytes() != encoded:
            print("error: conformance golden hashes differ", file=sys.stderr)
            return 2
        print(f"verified {len(artifact_paths)} conformance artifact hashes")
        return 0
    destination.write_bytes(encoded)
    print(f"wrote {destination} ({len(artifact_paths)} artifact hashes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
