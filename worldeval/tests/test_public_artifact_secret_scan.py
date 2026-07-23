from __future__ import annotations

import json
from pathlib import Path

from tools.check_public_artifact_secrets import scan_file


def test_public_artifact_secret_scan_allows_provider_call_metrics(tmp_path: Path) -> None:
    path = tmp_path / "evaluation.json"
    path.write_text(
        json.dumps({"offline_verification": {"provider_calls": 0}}),
        encoding="utf-8",
    )
    assert scan_file(path) == []


def test_public_artifact_secret_scan_rejects_protected_keys_without_values(
    tmp_path: Path,
) -> None:
    path = tmp_path / "replay.json"
    path.write_text(json.dumps({"nested": {"api_key": "not-disclosed"}}), encoding="utf-8")
    findings = scan_file(path)
    assert [(finding.location, finding.reason) for finding in findings] == [
        ("$/nested/api_key", "protected field name")
    ]
    assert "not-disclosed" not in repr(findings)
