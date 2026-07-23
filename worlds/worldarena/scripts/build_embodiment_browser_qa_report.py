#!/usr/bin/env python3
"""Build browser-QA evidence after a human-observed local pilot run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import zlib
from pathlib import Path

from genesis_arena.embodiment.source_fingerprint import browser_runtime_source_fingerprint
from worldeval.workspace import find_workspace

WORKSPACE = find_workspace(__file__)
ROOT = WORKSPACE.path("worldarena")
REPORT_FORMAT = "llm-controller/browser-qa/1.1.0"
CHECKS = (
    "console_health",
    "credential_leak_scan",
    "framework_overlay_absent",
    "interaction_proof",
    "not_blank",
    "page_identity",
)


def _png_dimensions(payload: bytes) -> tuple[int, int]:
    if len(payload) < 57 or payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("browser evidence is not a complete PNG")
    offset = 8
    dimensions: tuple[int, int] | None = None
    saw_idat = False
    saw_iend = False
    chunk_index = 0
    while offset + 12 <= len(payload):
        length = int.from_bytes(payload[offset : offset + 4], "big")
        chunk_type = payload[offset + 4 : offset + 8]
        data_start = offset + 8
        data_end = data_start + length
        crc_end = data_end + 4
        if length > 20 * 1024 * 1024 or crc_end > len(payload):
            raise ValueError("browser evidence PNG chunk is invalid")
        expected_crc = int.from_bytes(payload[data_end:crc_end], "big")
        if zlib.crc32(chunk_type + payload[data_start:data_end]) & 0xFFFFFFFF != expected_crc:
            raise ValueError("browser evidence PNG checksum is invalid")
        if chunk_index == 0:
            if chunk_type != b"IHDR" or length != 13:
                raise ValueError("browser evidence PNG header is invalid")
            dimensions = (
                int.from_bytes(payload[data_start : data_start + 4], "big"),
                int.from_bytes(payload[data_start + 4 : data_start + 8], "big"),
            )
            if dimensions[0] < 1 or dimensions[1] < 1:
                raise ValueError("browser evidence PNG dimensions are invalid")
        elif chunk_type == b"IHDR":
            raise ValueError("browser evidence PNG contains duplicate headers")
        if chunk_type == b"IDAT":
            saw_idat = True
        if chunk_type == b"IEND":
            if length != 0 or crc_end != len(payload):
                raise ValueError("browser evidence PNG ending is invalid")
            saw_iend = True
            break
        offset = crc_end
        chunk_index += 1
    if dimensions is None or not saw_idat or not saw_iend:
        raise ValueError("browser evidence is not a complete PNG")
    return dimensions


def _png(path: Path, report_dir: Path) -> dict[str, object]:
    resolved = path.expanduser().resolve()
    payload = resolved.read_bytes()
    width, height = _png_dimensions(payload)
    return {
        "height": height,
        "path": os.path.relpath(resolved, report_dir),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "width": width,
    }


def build_report(
    arguments: argparse.Namespace, *, source_fingerprint: str | None = None
) -> dict[str, object]:
    output = arguments.output.resolve()
    if not arguments.confirm_hybrid_solo or not arguments.confirm_symmetric_duel:
        raise ValueError("both launched workflows must have been observed through completion")
    confirmations = {
        name: bool(getattr(arguments, f"confirm_{name}")) for name in CHECKS
    }
    if not all(confirmations.values()):
        raise ValueError("every browser QA check requires explicit reviewer confirmation")
    desktop = _png(arguments.desktop, output.parent)
    mobile = _png(arguments.mobile, output.parent)
    if desktop["width"] < 1024 or desktop["height"] < 720:
        raise ValueError("desktop evidence must be at least 1024x720")
    if not 320 <= mobile["width"] <= 768 or mobile["height"] < 568:
        raise ValueError("mobile evidence must be 320–768 pixels wide and at least 568 high")
    return {
        "base_url": arguments.base_url,
        "browser_backend": "in-app-browser",
        "checks": confirmations,
        "format": REPORT_FORMAT,
        "source_fingerprint": source_fingerprint
        or browser_runtime_source_fingerprint(ROOT),
        "screenshots": {
            "desktop": desktop,
            "mobile": mobile,
        },
        "workflows": {
            "hybrid_solo": {"launched": True, "lifecycle_observed": True},
            "symmetric_two_leg_1v1": {"launched": True, "lifecycle_observed": True},
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop", type=Path, required=True)
    parser.add_argument("--mobile", type=Path, required=True)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000/")
    parser.add_argument(
        "--output",
        type=Path,
        default=WORKSPACE.path("exports") / "embodiment-pilot/browser-qa-report.json",
    )
    parser.add_argument("--confirm-hybrid-solo", action="store_true")
    parser.add_argument("--confirm-symmetric-duel", action="store_true")
    for name in CHECKS:
        parser.add_argument(f"--confirm-{name.replace('_', '-')}", action="store_true")
    arguments = parser.parse_args()
    try:
        report = build_report(arguments)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(
            json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"BROWSER_QA_REPORT_OK report={arguments.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
