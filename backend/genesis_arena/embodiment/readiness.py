"""Credential-free projection of the local embodiment pilot readiness artifact."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable, Mapping

from ..config import REPOSITORY_ROOT
from .source_fingerprint import certification_source_fingerprint

READINESS_VIEW_FORMAT = "llm-controller/embodiment-readiness-view/1.1.0"
READINESS_REPORT_FORMAT = "llm-controller/embodiment-pilot-readiness/1.1.0"
_MAX_REPORT_BYTES = 1_048_576
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_CODE = re.compile(r"^[a-z][a-z0-9_]{0,95}$")
_GATES = (
    ("offline", "Offline certification"),
    ("approved_mixamo_y_bot", "Approved Y Bot"),
    ("live_provider_managed_solo", "Live providers"),
    ("live_model_paired_duel", "Live two-model duel"),
    ("browser_visual_qa", "Browser lifecycle"),
    ("final_native_video", "Final native video"),
)


class PilotReadinessStore:
    """Read one bounded report and expose only a stable public status projection."""

    def __init__(
        self,
        path: Path,
        *,
        current_source_fingerprint: Callable[[], str] | None = None,
    ) -> None:
        self._path = Path(path).resolve()
        self._current_source_fingerprint = current_source_fingerprint or (
            lambda: certification_source_fingerprint(REPOSITORY_ROOT)
        )

    def read(self) -> Mapping[str, Any]:
        try:
            payload = self._path.read_bytes()
            if not payload or len(payload) > _MAX_REPORT_BYTES:
                raise ValueError
            value = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_object)
            current_fingerprint = self._current_source_fingerprint()
            if _SHA256.fullmatch(current_fingerprint) is None:
                raise ValueError
            return _project(value, current_fingerprint=current_fingerprint)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            return _unavailable()


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for key, value in pairs:
        if key in output:
            raise ValueError("duplicate readiness key")
        output[key] = value
    return output


def _project(value: object, *, current_fingerprint: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "format",
        "gates",
        "ready_for_promotion",
        "runtime_capabilities",
        "source_fingerprint",
    }:
        raise ValueError("readiness report shape differs")
    if value["format"] != READINESS_REPORT_FORMAT:
        raise ValueError("readiness report format differs")
    fingerprint = value["source_fingerprint"]
    if not isinstance(fingerprint, str) or _SHA256.fullmatch(fingerprint) is None:
        raise ValueError("readiness fingerprint is invalid")
    gates = value["gates"]
    if not isinstance(gates, dict) or set(gates) != {name for name, _ in _GATES}:
        raise ValueError("readiness gate coverage differs")
    projected = [_gate(name, label, gates[name]) for name, label in _GATES]
    ready = value["ready_for_promotion"]
    if not isinstance(ready, bool) or ready != all(gate["passed"] for gate in projected):
        raise ValueError("readiness promotion state differs")
    runtime = _status(value["runtime_capabilities"])
    if fingerprint != current_fingerprint:
        projected[0] = {
            "id": "offline",
            "label": "Offline certification",
            "passed": False,
            "code": "source_fingerprint_mismatch",
        }
        ready = False
        runtime = {"passed": False, "code": "source_fingerprint_mismatch"}
    return {
        "format": READINESS_VIEW_FORMAT,
        "gates": projected,
        "ready_for_promotion": ready,
        "report_available": True,
        "runtime_capabilities": runtime,
        "source_fingerprint": current_fingerprint,
    }


def _gate(identifier: str, label: str, value: object) -> dict[str, object]:
    status = _status(value)
    return {"id": identifier, "label": label, **status}


def _status(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not isinstance(value.get("passed"), bool):
        raise ValueError("readiness status is invalid")
    passed = value["passed"]
    code = value.get("code")
    if passed:
        code = None
    elif not isinstance(code, str) or _CODE.fullmatch(code) is None:
        raise ValueError("readiness failure code is invalid")
    return {"passed": passed, "code": code}


def _unavailable() -> Mapping[str, Any]:
    return {
        "format": READINESS_VIEW_FORMAT,
        "gates": [
            {
                "code": "readiness_report_unavailable",
                "id": identifier,
                "label": label,
                "passed": False,
            }
            for identifier, label in _GATES
        ],
        "ready_for_promotion": False,
        "report_available": False,
        "runtime_capabilities": {
            "code": "readiness_report_unavailable",
            "passed": False,
        },
        "source_fingerprint": None,
    }


__all__ = ["PilotReadinessStore", "READINESS_VIEW_FORMAT"]
