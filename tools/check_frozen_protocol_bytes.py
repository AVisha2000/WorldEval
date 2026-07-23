#!/usr/bin/env python3
"""Compare moved frozen protocol bytes with the immutable cutover base revision."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any

from worldeval.workspace import find_workspace


class FrozenProtocolError(RuntimeError):
    """A frozen protocol differs from its cutover baseline."""


def _git(*arguments: str, cwd: Path, binary: bool = False) -> bytes | str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=not binary,
    )
    return result.stdout


def _baseline_files(root: Path, revision: str, source: str) -> dict[str, bytes]:
    output = _git("ls-tree", "-r", "--name-only", revision, "--", source, cwd=root)
    assert isinstance(output, str)
    values: dict[str, bytes] = {}
    for name in output.splitlines():
        relative = name.removeprefix(f"{source}/")
        payload = _git("show", f"{revision}:{name}", cwd=root, binary=True)
        assert isinstance(payload, bytes)
        values[relative] = payload
    return values


def _working_files(root: Path) -> dict[str, bytes]:
    values: dict[str, bytes] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise FrozenProtocolError(f"frozen protocol contains a symlink: {path}")
        if path.is_file():
            values[path.relative_to(root).as_posix()] = path.read_bytes()
    return values


def _logical_sha256(files: dict[str, bytes]) -> str:
    digest = hashlib.sha256()
    for relative, payload in sorted(files.items()):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(payload)
        digest.update(b"\0")
    return digest.hexdigest()


def check(root: Path | str | None = None) -> list[str]:
    workspace = find_workspace(root)
    evidence_path = (
        workspace.path("features")
        / "in-progress/wev-0001-repository-cutover/evidence/cutover-baseline.json"
    )
    document: dict[str, Any] = json.loads(evidence_path.read_text(encoding="utf-8"))
    revision = str(document["base_revision"])
    destinations = {
        "embodiment_protocol": workspace.path("worldarena_game") / "embodiment_protocol",
        "duel_protocol": workspace.path("worldarena_game") / "duel_protocol",
    }
    errors: list[str] = []
    for name, destination in destinations.items():
        record = document["frozen_protocols"][name]
        expected_files = _baseline_files(workspace.root, revision, record["baseline_path"])
        actual_files = _working_files(destination)
        missing = sorted(set(expected_files) - set(actual_files))
        extra = sorted(set(actual_files) - set(expected_files))
        changed = sorted(
            relative
            for relative in set(expected_files) & set(actual_files)
            if expected_files[relative] != actual_files[relative]
        )
        measured = _logical_sha256(actual_files)
        expected_hash = record["logical_tree_sha256"]
        if missing or extra or changed or measured != expected_hash:
            errors.append(
                f"{name} differs: missing={missing}, extra={extra}, "
                f"changed={changed}, measured={measured}, expected={expected_hash}"
            )
    return errors


def main() -> int:
    try:
        errors = check()
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FROZEN_PROTOCOL_ERROR {error}")
        return 1
    if errors:
        for error in errors:
            print(f"FROZEN_PROTOCOL_ERROR {error}")
        return 1
    print("FROZEN_PROTOCOL_BYTES_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
