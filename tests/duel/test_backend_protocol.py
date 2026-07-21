from __future__ import annotations

import json
from pathlib import Path

import pytest
from genesis_arena.duel import (
    DuelCanonicalError,
    ProtocolLockMismatch,
    ProtocolPackage,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)


def test_restricted_jcs_is_stable_and_integer_only() -> None:
    first = {"z": 1, "a": {"items": [3, 2, 1], "enabled": True}, "empty": None}
    second = {"empty": None, "a": {"enabled": True, "items": [3, 2, 1]}, "z": 1}
    expected = b'{"a":{"enabled":true,"items":[3,2,1]},"empty":null,"z":1}'

    assert canonical_json_bytes(first) == expected
    assert canonical_json_bytes(second) == expected
    assert canonical_sha256(first) == canonical_sha256(second)

    with pytest.raises(DuelCanonicalError, match="floating-point"):
        canonical_json_bytes({"bad": 1.25})
    with pytest.raises(DuelCanonicalError, match="interoperable range"):
        canonical_json_bytes({"bad": 9_007_199_254_740_992})
    with pytest.raises(DuelCanonicalError, match="NFC"):
        canonical_json_bytes({"text": "Cafe\u0301"})
    with pytest.raises(DuelCanonicalError, match="non-string object key"):
        canonical_json_bytes({1: "bad"})


def test_strict_json_rejects_duplicate_keys_floats_constants_and_bom() -> None:
    assert strict_json_loads(b'{"ok":1}') == {"ok": 1}
    with pytest.raises(DuelCanonicalError, match="duplicate"):
        strict_json_loads(b'{"same":1,"same":2}')
    with pytest.raises(DuelCanonicalError, match="floating-point"):
        strict_json_loads(b'{"float":1.0}')
    with pytest.raises(DuelCanonicalError, match="constant"):
        strict_json_loads(b'{"bad":NaN}')
    with pytest.raises(DuelCanonicalError, match="BOM"):
        strict_json_loads(b'\xef\xbb\xbf{"bad":1}')


def test_protocol_lock_detects_changed_artifact(tmp_path: Path) -> None:
    package_root = tmp_path / "duel_protocol"
    _write_minimal_required_package(package_root)
    package = ProtocolPackage(package_root)
    (package_root / "protocol-lock.json").write_bytes(package.lock_bytes())
    package.verify_lock()

    prompt = package_root / "prompts" / "commander-system.v1.txt"
    prompt.write_text("changed\n", encoding="utf-8")
    with pytest.raises(ProtocolLockMismatch, match="changed prompts/commander-system"):
        package.verify_lock()


def _write_minimal_required_package(root: Path) -> None:
    for relative in ProtocolPackage.REQUIRED_PATHS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if relative == "VERSION":
            path.write_text("worldeval-rts/1.0.0\n", encoding="utf-8")
        elif relative.endswith(".json"):
            path.write_text(json.dumps({"id": relative}, sort_keys=True) + "\n", encoding="utf-8")
        else:
            path.write_text(f"fixture for {relative}\n", encoding="utf-8")
