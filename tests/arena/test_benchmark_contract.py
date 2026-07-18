from __future__ import annotations

import hashlib
import json
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = REPOSITORY_ROOT / "godot" / "data" / "arena" / "benchmark_contract.json"


def test_benchmark_contract_hashes_match_frozen_sources() -> None:
    contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))

    assert contract["schema_version"] == 1
    assert contract["rules"]["id"] == "arena-v1"
    assert contract["map"]["id"] == "tri_13_v1"
    assert contract["tools"]["id"] == "arena-actions-v0.2"

    for section in ("rules", "map", "tools"):
        record = contract[section]
        source = REPOSITORY_ROOT / record["source_path"]
        assert source.is_file()
        assert hashlib.sha256(source.read_bytes()).hexdigest() == record["hash"]
