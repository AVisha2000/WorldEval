"""Repository layout discovery without fragile parent-count assumptions."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

MARKER = "worldeval.workspace.json"


class WorkspaceError(RuntimeError):
    """The WorldEval workspace marker is missing or invalid."""


@dataclass(frozen=True)
class Workspace:
    root: Path
    paths: Mapping[str, str]

    def path(self, key: str) -> Path:
        try:
            relative = self.paths[key]
        except KeyError as error:
            raise WorkspaceError(f"unknown workspace path: {key}") from error
        candidate = (self.root / relative).resolve()
        try:
            candidate.relative_to(self.root)
        except ValueError as error:
            raise WorkspaceError(f"workspace path escapes root: {key}") from error
        return candidate


def find_workspace(start: Path | str | None = None) -> Workspace:
    override = os.environ.get("WORLDEVAL_WORKSPACE")
    current = Path(override or start or Path.cwd()).expanduser().resolve()
    if current.is_file():
        current = current.parent
    for directory in (current, *current.parents):
        marker = directory / MARKER
        if not marker.is_file():
            continue
        try:
            value = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise WorkspaceError("workspace marker is invalid") from error
        if (
            not isinstance(value, dict)
            or value.get("schema_version") != 1
            or not isinstance(value.get("paths"), dict)
            or not all(
                isinstance(key, str) and isinstance(path, str) and path
                for key, path in value["paths"].items()
            )
        ):
            raise WorkspaceError("workspace marker fields are invalid")
        workspace = Workspace(root=directory.resolve(), paths=dict(value["paths"]))
        for key in workspace.paths:
            workspace.path(key)
        return workspace
    raise WorkspaceError(f"{MARKER} was not found from {current}")
