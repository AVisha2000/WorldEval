"""Credential-free projection of the local embodiment pilot readiness artifact."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable, Mapping

from ..config import REPOSITORY_ROOT
from .source_fingerprint import (
    SOURCE_FINGERPRINT_V1,
    SOURCE_FINGERPRINT_V2,
    source_fingerprint_for_version,
)

READINESS_VIEW_FORMAT = "llm-controller/embodiment-readiness-view/1.1.0"
READINESS_REPORT_FORMAT = "llm-controller/embodiment-pilot-readiness/1.1.0"
READINESS_REPORT_FORMAT_V2 = "llm-controller/embodiment-pilot-readiness/1.2.0"
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
        current_source_fingerprints: Mapping[str, Callable[[], str]] | None = None,
    ) -> None:
        self._path = Path(path).resolve()
        if (
            current_source_fingerprint is not None
            and current_source_fingerprints is not None
        ):
            raise ValueError("provide one source-fingerprint resolver form")
        if current_source_fingerprints is not None:
            self._current_source_fingerprints = dict(current_source_fingerprints)
        elif current_source_fingerprint is not None:
            self._current_source_fingerprints = {
                SOURCE_FINGERPRINT_V1: current_source_fingerprint,
                SOURCE_FINGERPRINT_V2: current_source_fingerprint,
            }
        else:
            self._current_source_fingerprints = {
                version: (
                    lambda selected=version: source_fingerprint_for_version(
                        REPOSITORY_ROOT, selected
                    )
                )
                for version in (SOURCE_FINGERPRINT_V1, SOURCE_FINGERPRINT_V2)
            }

    def read(self) -> Mapping[str, Any]:
        try:
            payload = self._path.read_bytes()
            if not payload or len(payload) > _MAX_REPORT_BYTES:
                raise ValueError
            value = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_object)
            version = _fingerprint_version(value)
            resolver = self._current_source_fingerprints.get(version)
            if resolver is None:
                raise ValueError
            current_fingerprint = resolver()
            if _SHA256.fullmatch(current_fingerprint) is None:
                raise ValueError
            return _project(
                value,
                current_fingerprint=current_fingerprint,
                fingerprint_version=version,
            )
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            return _unavailable()


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for key, value in pairs:
        if key in output:
            raise ValueError("duplicate readiness key")
        output[key] = value
    return output


def _fingerprint_version(value: object) -> str:
    if not isinstance(value, dict):
        raise ValueError("readiness report must be an object")
    if (
        value.get("format") == READINESS_REPORT_FORMAT
        and "source_fingerprint_version" not in value
    ):
        return SOURCE_FINGERPRINT_V1
    if (
        value.get("format") == READINESS_REPORT_FORMAT_V2
        and value.get("source_fingerprint_version") == SOURCE_FINGERPRINT_V2
    ):
        return SOURCE_FINGERPRINT_V2
    raise ValueError("readiness fingerprint version is unsupported")


def _project(
    value: object,
    *,
    current_fingerprint: str,
    fingerprint_version: str,
) -> Mapping[str, Any]:
    expected_fields = {
        "format",
        "gates",
        "ready_for_promotion",
        "runtime_capabilities",
        "source_fingerprint",
    }
    if fingerprint_version == SOURCE_FINGERPRINT_V2:
        expected_fields.add("source_fingerprint_version")
    if not isinstance(value, dict) or set(value) != expected_fields:
        raise ValueError("readiness report shape differs")
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
        "source_fingerprint_version": fingerprint_version,
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
        "source_fingerprint_version": None,
    }


__all__ = [
    "PilotReadinessStore",
    "READINESS_REPORT_FORMAT",
    "READINESS_REPORT_FORMAT_V2",
    "READINESS_VIEW_FORMAT",
]
