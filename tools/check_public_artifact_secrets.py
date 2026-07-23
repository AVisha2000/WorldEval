#!/usr/bin/env python3
"""Fail closed when promoted replay or feature evidence contains secret-shaped data."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

from worldeval.workspace import find_workspace

_TEXT_SUFFIXES = frozenset({".json", ".jsonl", ".md", ".txt", ".yaml", ".yml"})
_PROTECTED_KEYS = re.compile(
    r"^(?:api_?key|authorization|bearer|chain_?of_?thought|credential(?:s)?|"
    r"private_?authority_?state|prompt|provider_?output|raw_?output|secret)$",
    re.IGNORECASE,
)
_SECRET_VALUES = (
    re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\bAuthorization\s*:\s*Bearer\s+[A-Za-z0-9._~-]{8,}", re.IGNORECASE),
)


@dataclass(frozen=True)
class SecretFinding:
    path: Path
    location: str
    reason: str


def scan_file(path: Path) -> list[SecretFinding]:
    """Inspect one public text artifact without returning its sensitive value."""

    selected = Path(path)
    if selected.suffix.lower() not in _TEXT_SUFFIXES:
        return []
    try:
        text = selected.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return [SecretFinding(selected, "$", "public artifact is not readable UTF-8 text")]
    findings = [
        SecretFinding(selected, "$", "secret-shaped value")
        for pattern in _SECRET_VALUES
        if pattern.search(text)
    ]
    if selected.suffix.lower() == ".json":
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            return [*findings, SecretFinding(selected, "$", "invalid JSON artifact")]
        findings.extend(_scan_json_keys(value, selected))
    return findings


def scan_roots(roots: Iterable[Path]) -> tuple[list[Path], list[SecretFinding]]:
    files: list[Path] = []
    findings: list[SecretFinding] = []
    for root in roots:
        selected = Path(root)
        if not selected.exists():
            continue
        candidates = (selected,) if selected.is_file() else selected.rglob("*")
        for path in sorted(candidates):
            if not path.is_file() or path.suffix.lower() not in _TEXT_SUFFIXES:
                continue
            files.append(path)
            findings.extend(scan_file(path))
    return files, findings


def _scan_json_keys(
    value: Any,
    path: Path,
    location: str = "$",
) -> list[SecretFinding]:
    findings: list[SecretFinding] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}/{key}"
            if isinstance(key, str) and _PROTECTED_KEYS.fullmatch(key):
                # The key name is enough to fail; never include its value in diagnostics.
                findings.append(
                    SecretFinding(path, child_location, "protected field name")
                )
            findings.extend(_scan_json_keys(child, path, child_location))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            findings.extend(_scan_json_keys(child, path, f"{location}/{index}"))
    return findings


def main(argv: Sequence[str] | None = None) -> int:
    workspace = find_workspace(Path.cwd())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path)
    arguments = parser.parse_args(argv)
    roots = arguments.paths or [
        workspace.path("worldarena") / "demos",
        workspace.path("features"),
    ]
    files, findings = scan_roots(roots)
    if findings:
        for finding in findings:
            try:
                display = finding.path.resolve().relative_to(workspace.root)
            except ValueError:
                display = finding.path
            print(
                "PUBLIC_ARTIFACT_SECRET_SCAN_ERROR "
                f"{display}:{finding.location} {finding.reason}"
            )
        return 1
    print(f"PUBLIC_ARTIFACT_SECRET_SCAN_OK files={len(files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
