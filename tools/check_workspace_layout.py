#!/usr/bin/env python3
"""Fail closed when the WorldEval cutover layout or path map drifts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Sequence

from worldeval.workspace import MARKER, WorkspaceError, find_workspace

REQUIRED_PATHS = {
    "worldeval": "worldeval",
    "worldarena": "worlds/worldarena",
    "worldarena_backend": "worlds/worldarena/backend",
    "worldarena_game": "worlds/worldarena/game",
    "worldarena_godot": "worlds/worldarena/godot",
    "worldarena_games": "worlds/worldarena/games",
    "worldeval_web": "apps/worldeval-web",
    "features": "features",
    "runs": "runs",
    "exports": "exports",
    "operations": "ops",
    "media": "media",
}

FORBIDDEN_OLD_ROOTS = (
    "backend",
    "dashboard",
    "deploy",
    "game",
    "godot",
    "remotion",
    "scripts",
    "tests",
)

REQUIRED_FILES = (
    "AGENTS.md",
    "README.md",
    "pyproject.toml",
    "worldeval.workspace.json",
    "worldeval/AGENTS.md",
    "worlds/worldarena/AGENTS.md",
    "apps/worldeval-web/AGENTS.md",
    "worlds/worldarena/godot/project.godot",
)

_BRITTLE_PARENT_COUNT = re.compile(
    r"Path\(__file__\)\.resolve\(\)\.parents\[[0-9]+\]"
)

# The released Crossroads map embeds the raw SHA-256 of its generator.  Moving the
# unchanged generator preserves both its old source-fingerprint-v1 identity and its
# generated package bytes; changing it merely to call the workspace resolver would
# invalidate that historical binding.  This is the sole depth-based compatibility
# shim, and it remains acceptable only while every source byte matches this lock.
_HASH_LOCKED_PARENT_SHIMS = {
    "worlds/worldarena/scripts/build_duel_map.py": (
        "7ad26a25cd52de630c0dcd53abbb4fd5f26eaa278d60854a78ef1b69d4c44f35"
    )
}


def brittle_parent_count_paths(root: Path) -> list[Path]:
    """Return maintained Python files that infer workspace roots by depth."""

    results: list[Path] = []
    for source_root in (
        root / "worldeval",
        root / "worlds" / "worldarena" / "backend",
        root / "worlds" / "worldarena" / "scripts",
        root / "worlds" / "worldarena" / "tests",
        root / "tools",
    ):
        if not source_root.is_dir():
            continue
        for path in source_root.rglob("*.py"):
            try:
                content = path.read_text(encoding="utf-8")
            except OSError:
                continue
            if _BRITTLE_PARENT_COUNT.search(content):
                relative = path.relative_to(root).as_posix()
                expected = _HASH_LOCKED_PARENT_SHIMS.get(relative)
                actual = hashlib.sha256(path.read_bytes()).hexdigest()
                if expected is not None and actual == expected:
                    continue
                results.append(path)
    return sorted(results)


def check_layout(start: Path | str | None = None) -> list[str]:
    errors: list[str] = []
    try:
        workspace = find_workspace(start)
    except WorkspaceError as error:
        return [str(error)]
    root = workspace.root
    marker = root / MARKER
    try:
        document = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"cannot load {MARKER}: {error}"]

    paths = document.get("paths", {})
    for key, expected in REQUIRED_PATHS.items():
        actual = paths.get(key)
        if actual != expected:
            errors.append(f"workspace path {key!r} must be {expected!r}, got {actual!r}")
            continue
        resolved = workspace.path(key)
        if key not in {"runs", "exports"} and not resolved.is_dir():
            errors.append(f"workspace directory is missing: {expected}")

    for relative in FORBIDDEN_OLD_ROOTS:
        if (root / relative).exists():
            errors.append(f"old subsystem root still exists: {relative}")
    for relative in REQUIRED_FILES:
        if not (root / relative).is_file():
            errors.append(f"required cutover file is missing: {relative}")
    for path in brittle_parent_count_paths(root):
        errors.append(
            "brittle Path.parents workspace assumption remains: "
            f"{path.relative_to(root)}"
        )
    return errors


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    arguments = parser.parse_args(argv)
    errors = check_layout(arguments.root)
    if errors:
        for error in errors:
            print(f"WORKSPACE_LAYOUT_ERROR {error}")
        return 1
    workspace = find_workspace(arguments.root)
    print(f"WORKSPACE_LAYOUT_OK root={workspace.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
