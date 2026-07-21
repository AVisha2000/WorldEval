from __future__ import annotations

import json
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.readiness import (
    READINESS_VIEW_FORMAT,
    PilotReadinessStore,
)


def _report(path: Path, *, fingerprint: str = "b" * 64) -> Path:
    value = {
        "format": "llm-controller/embodiment-pilot-readiness/1.1.0",
        "gates": {
            "offline": {"passed": True},
            "approved_mixamo_y_bot": {
                "passed": False,
                "code": "evidence_file_invalid",
            },
            "live_provider_managed_solo": {
                "passed": False,
                "code": "live_provider_report_missing",
                "report_sha256": "a" * 64,
            },
            "live_model_paired_duel": {
                "passed": False,
                "code": "live_duel_report_missing",
            },
            "browser_visual_qa": {
                "passed": False,
                "code": "browser_report_missing",
            },
            "final_native_video": {
                "passed": False,
                "code": "final_video_missing",
            },
        },
        "ready_for_promotion": False,
        "runtime_capabilities": {
            "passed": False,
            "code": "runtime_capabilities_not_released",
        },
        "source_fingerprint": fingerprint,
    }
    path.write_text(json.dumps(value), encoding="utf-8")
    return path


def test_missing_or_malformed_readiness_is_fail_closed(tmp_path: Path) -> None:
    def fingerprint() -> str:
        return "b" * 64

    missing = PilotReadinessStore(
        tmp_path / "missing.json", current_source_fingerprint=fingerprint
    ).read()
    assert missing["report_available"] is False
    assert missing["ready_for_promotion"] is False
    assert all(gate["passed"] is False for gate in missing["gates"])

    malformed = tmp_path / "malformed.json"
    malformed.write_text('{"format":"first","format":"second"}', encoding="utf-8")
    assert PilotReadinessStore(malformed, current_source_fingerprint=fingerprint).read() == missing


def test_readiness_projection_is_allow_listed_and_credential_free(tmp_path: Path) -> None:
    path = _report(tmp_path / "readiness.json")
    value = json.loads(path.read_text())
    value["gates"]["offline"]["api_key"] = "must-never-leave-the-store"
    path.write_text(json.dumps(value), encoding="utf-8")

    projected = PilotReadinessStore(path, current_source_fingerprint=lambda: "b" * 64).read()
    encoded = json.dumps(projected)
    assert projected["format"] == READINESS_VIEW_FORMAT
    assert projected["report_available"] is True
    assert projected["source_fingerprint"] == "b" * 64
    assert "must-never-leave-the-store" not in encoded
    assert "report_sha256" not in encoded


def test_readiness_endpoint_is_no_store(tmp_path: Path) -> None:
    app = FastAPI()
    app.state.embodiment_readiness = PilotReadinessStore(
        _report(tmp_path / "readiness.json"),
        current_source_fingerprint=lambda: "b" * 64,
    )
    app.include_router(router)
    with TestClient(app) as client:
        response = client.get("/api/embodiment/certification/readiness")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["gates"][0] == {
        "id": "offline",
        "label": "Offline certification",
        "passed": True,
        "code": None,
    }


def test_stale_readiness_fails_closed_but_preserves_independent_gates(
    tmp_path: Path,
) -> None:
    path = _report(tmp_path / "readiness.json", fingerprint="a" * 64)
    value = json.loads(path.read_text())
    value["gates"]["approved_mixamo_y_bot"] = {"passed": True}
    value["runtime_capabilities"] = {"passed": True}
    path.write_text(json.dumps(value), encoding="utf-8")

    projected = PilotReadinessStore(path, current_source_fingerprint=lambda: "b" * 64).read()

    assert projected["report_available"] is True
    assert projected["ready_for_promotion"] is False
    assert projected["source_fingerprint"] == "b" * 64
    assert projected["gates"][0]["code"] == "source_fingerprint_mismatch"
    assert projected["gates"][1]["passed"] is True
    assert projected["runtime_capabilities"] == {
        "passed": False,
        "code": "source_fingerprint_mismatch",
    }


def test_invalid_current_fingerprint_fails_closed(tmp_path: Path) -> None:
    projected = PilotReadinessStore(
        _report(tmp_path / "readiness.json"),
        current_source_fingerprint=lambda: "not-a-fingerprint",
    ).read()
    assert projected["report_available"] is False
    assert projected["ready_for_promotion"] is False
