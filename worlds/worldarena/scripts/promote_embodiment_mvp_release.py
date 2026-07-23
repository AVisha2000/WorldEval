#!/usr/bin/env python3
"""Promote certified embodiment capabilities only after every pilot artifact verifies."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path

from genesis_arena.embodiment.protocol import canonical_json_bytes

try:
    from scripts.run_embodiment_mvp_certification import (
        READINESS_REPORT_FORMAT,
        RELEASE_CAPABILITIES,
        RELEASE_ENVIRONMENT_ID,
        RELEASE_FORMAT,
        RELEASE_MANIFEST,
        RELEASE_PROTOCOL_VERSION,
        ROOT,
        SOURCE_FINGERPRINT_V2,
        Y_BOT_MANIFEST,
        _certification_source_fingerprint,
        validate_browser_qa_report,
        validate_final_video,
        validate_live_duel_report,
        validate_live_provider_report,
        validate_offline_certification_report,
        validate_release_capabilities,
        validate_y_bot_intake,
    )
except ModuleNotFoundError:  # Direct `python scripts/...` execution.
    from run_embodiment_mvp_certification import (  # type: ignore[no-redef]
        READINESS_REPORT_FORMAT,
        RELEASE_CAPABILITIES,
        RELEASE_ENVIRONMENT_ID,
        RELEASE_FORMAT,
        RELEASE_MANIFEST,
        RELEASE_PROTOCOL_VERSION,
        ROOT,
        SOURCE_FINGERPRINT_V2,
        Y_BOT_MANIFEST,
        _certification_source_fingerprint,
        validate_browser_qa_report,
        validate_final_video,
        validate_live_duel_report,
        validate_live_provider_report,
        validate_offline_certification_report,
        validate_release_capabilities,
        validate_y_bot_intake,
    )


def _offline_gate(path: Path) -> dict[str, object]:
    return validate_offline_certification_report(path)


def pilot_gates(arguments: argparse.Namespace) -> dict[str, dict[str, object]]:
    y_bot = validate_y_bot_intake(Y_BOT_MANIFEST)
    return {
        "offline": _offline_gate(arguments.offline_report),
        "approved_mixamo_y_bot": y_bot,
        "browser_visual_qa": validate_browser_qa_report(arguments.browser_qa_report),
        "live_provider_managed_solo": validate_live_provider_report(
            arguments.live_provider_report
        ),
        "live_model_paired_duel": validate_live_duel_report(arguments.live_duel_report),
        "final_native_video": validate_final_video(arguments.final_video, y_bot),
    }


def readiness_report(gates: dict[str, dict[str, object]]) -> dict[str, object]:
    return {
        "format": READINESS_REPORT_FORMAT,
        "gates": gates,
        "ready_for_promotion": bool(gates)
        and all(gate.get("passed") is True for gate in gates.values()),
        "runtime_capabilities": validate_release_capabilities(RELEASE_MANIFEST),
        "source_fingerprint": _certification_source_fingerprint(),
        "source_fingerprint_version": SOURCE_FINGERPRINT_V2,
    }


def _promote() -> None:
    from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage

    value = {
        "capabilities": RELEASE_CAPABILITIES,
        "environment_id": RELEASE_ENVIRONMENT_ID,
        "format": RELEASE_FORMAT,
        "protocol_package_sha256": EmbodimentProtocolPackage.from_repository(
            ROOT
        ).package_sha256,
        "protocol_version": RELEASE_PROTOCOL_VERSION,
    }
    expected = canonical_json_bytes(value) + b"\n"
    if RELEASE_MANIFEST.is_file():
        if RELEASE_MANIFEST.read_bytes() != expected:
            raise ValueError("an incompatible release overlay already exists")
        return
    RELEASE_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=RELEASE_MANIFEST.parent,
            prefix=".worldarena.release.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(expected)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, RELEASE_MANIFEST)
        temporary = None
        gate = validate_release_capabilities(RELEASE_MANIFEST)
        if gate.get("passed") is not True:
            RELEASE_MANIFEST.unlink(missing_ok=True)
            raise ValueError("promoted release overlay did not validate")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline-report", type=Path, required=True)
    parser.add_argument("--browser-qa-report", type=Path, required=True)
    parser.add_argument("--live-provider-report", type=Path, required=True)
    parser.add_argument("--live-duel-report", type=Path, required=True)
    parser.add_argument("--final-video", type=Path, required=True)
    parser.add_argument("--status-report", type=Path)
    parser.add_argument("--apply", action="store_true")
    arguments = parser.parse_args()
    gates = pilot_gates(arguments)
    status = readiness_report(gates)
    if arguments.status_report is not None:
        arguments.status_report.parent.mkdir(parents=True, exist_ok=True)
        arguments.status_report.write_bytes(canonical_json_bytes(status) + b"\n")
    failed = {
        name: gate.get("code", "failed")
        for name, gate in gates.items()
        if not gate["passed"]
    }
    if failed:
        print(json.dumps({"passed": False, "failed_gates": failed}, sort_keys=True))
        return 2
    if not arguments.apply:
        print("EMBODIMENT_PROMOTION_READY rerun with --apply after reviewing all evidence")
        return 0
    try:
        _promote()
    except (OSError, TypeError, ValueError) as error:
        parser.error(str(error))
    if arguments.status_report is not None:
        post_status = readiness_report(pilot_gates(arguments))
        arguments.status_report.write_bytes(canonical_json_bytes(post_status) + b"\n")
    print(
        "EMBODIMENT_CAPABILITIES_PROMOTED rerun offline certification, then reuse the same "
        "package-bound external evidence to seal the release"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
