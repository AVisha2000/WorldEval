from __future__ import annotations

import json

import pytest

from scripts.run_embodiment_release_soak import (
    EVIDENCE_PREFIX,
    ReleaseSoakError,
    parse_godot_evidence,
    scan_public_output,
    validate_release_evidence,
)


def _evidence(*, executions: int = 1_012) -> dict[str, object]:
    cases = {
        f"case_{index}": {"authority_ticks": 2, "executions": 44, "privacy_scans": 2}
        for index in range(23)
    }
    return {
        "case_counts": cases,
        "execution_count": executions,
        "invalid_neutral_windows": 704,
        "memory": {"growth_bytes": 1024},
        "variant_count": 23,
    }


def test_release_soak_evidence_parser_and_gate() -> None:
    evidence = _evidence()
    parsed = parse_godot_evidence(EVIDENCE_PREFIX + json.dumps(evidence) + "\n")
    validate_release_evidence(parsed)


@pytest.mark.parametrize(
    ("mutation", "code"),
    [
        ({"execution_count": 999}, "execution_count_insufficient"),
        ({"variant_count": 22}, "case_matrix_incomplete"),
        ({"invalid_neutral_windows": 0}, "neutral_fallback_missing"),
        ({"memory": {"growth_bytes": 70 * 1024 * 1024}}, "memory_growth_unbounded"),
    ],
)
def test_release_soak_gate_fails_closed(mutation: dict[str, object], code: str) -> None:
    evidence = _evidence()
    evidence.update(mutation)
    with pytest.raises(ReleaseSoakError, match=code):
        validate_release_evidence(evidence)


def test_release_soak_public_scan_rejects_protected_data() -> None:
    scan_public_output('{"outcome":"success","participant":"participant_0"}')
    with pytest.raises(ReleaseSoakError, match="public_output_leak"):
        scan_public_output('{"session_secret":"not-allowed"}')


def test_release_soak_parser_rejects_missing_or_duplicate_evidence() -> None:
    with pytest.raises(ReleaseSoakError, match="evidence_line_invalid"):
        parse_godot_evidence("EMBODIMENT_RELEASE_SOAK_OK\n")
    line = EVIDENCE_PREFIX + "{}\n"
    with pytest.raises(ReleaseSoakError, match="evidence_line_invalid"):
        parse_godot_evidence(line + line)
