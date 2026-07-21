from __future__ import annotations

import json
from pathlib import Path

import pytest
from genesis_arena.duel import DuelSchemaValidator, ProtocolPackage, ProtocolSchemaError


def test_draft_202012_validator_returns_stable_paths(tmp_path: Path) -> None:
    root = tmp_path / "duel_protocol"
    schema_dir = root / "schemas"
    schema_dir.mkdir(parents=True)
    (schema_dir / "sample.schema.json").write_text(
        json.dumps(
            {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "$id": "schema://worldeval/sample.schema.json",
                "type": "object",
                "additionalProperties": False,
                "required": ["values"],
                "properties": {
                    "values": {
                        "type": "array",
                        "items": {"type": "integer", "minimum": 0},
                    }
                },
            }
        ),
        encoding="utf-8",
    )
    validator = DuelSchemaValidator(ProtocolPackage(root))
    validator.check_schemas()
    validator.validate("sample.schema.json", {"values": [0, 1, 2]})
    violations = validator.violations("sample.schema.json", {"values": [0, -1]})
    assert violations[0].instance_path == "$/values[1]"
    assert violations[0].validator == "minimum"

    with pytest.raises(ProtocolSchemaError, match=r"\$/values\[1\]"):
        validator.validate_bytes("sample.schema.json", b'{"values":[0,-1]}')
