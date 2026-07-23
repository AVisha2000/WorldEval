"""Stable source fingerprint shared by certification and readiness projection."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Iterable

SOURCE_ROOTS = (
    "backend/genesis_arena/embodiment",
    "backend/genesis_arena/duel",
    "game/embodiment_protocol",
    "game/embodiment_release",
    "game/duel_protocol",
    "godot/scenes/embodiment",
    "godot/scripts/embodiment",
    "godot/scripts/duel",
    "godot/tests/embodiment",
    "godot/tests/duel",
    "tests/embodiment",
    "tests/duel",
    "dashboard/src",
)
SOURCE_FILES = (
    "dashboard/package.json",
    "dashboard/pnpm-lock.yaml",
    "dashboard/vite.config.ts",
    "backend/genesis_arena/config.py",
    "backend/genesis_arena/main.py",
    "godot/export_presets.cfg",
    "godot/project.godot",
    "pyproject.toml",
    "scripts/build_embodiment_demo_replays.py",
    "scripts/build_embodiment_browser_qa_report.py",
    "scripts/build_embodiment_golden_fixtures.py",
    "scripts/build_embodiment_protocol_lock.py",
    "scripts/intake_mixamo_y_bot.py",
    "scripts/promote_embodiment_mvp_release.py",
    "scripts/render_embodiment_mvp_demo.py",
    "scripts/run_embodiment_live_provider_pilot.py",
    "scripts/run_embodiment_live_duel_pilot.py",
    "scripts/run_embodiment_openai_round_robin.py",
    "scripts/run_embodiment_managed_soak.py",
    "scripts/run_embodiment_mvp_certification.py",
)

BROWSER_SOURCE_ROOTS = (
    "backend/genesis_arena/embodiment",
    "backend/genesis_arena/duel",
    "dashboard/src/components",
    "dashboard/src/hooks",
    "dashboard/src/lib",
    "game/embodiment_protocol",
    "godot/scenes/embodiment",
    "godot/scripts/embodiment",
)
BROWSER_SOURCE_FILES = (
    "backend/genesis_arena/config.py",
    "backend/genesis_arena/main.py",
    "dashboard/package.json",
    "dashboard/pnpm-lock.yaml",
    "dashboard/vite.config.ts",
    "dashboard/src/App.tsx",
    "dashboard/src/api.ts",
    "dashboard/src/data.ts",
    "dashboard/src/index.css",
    "dashboard/src/main.tsx",
    "godot/project.godot",
    "pyproject.toml",
)


def certification_source_fingerprint(
    repository_root: Path,
    *,
    source_roots: Iterable[str] = SOURCE_ROOTS,
    source_files: Iterable[str] = SOURCE_FILES,
) -> str:
    """Hash every source file that can affect the certified MVP."""
    root = Path(repository_root).resolve()
    files: set[Path] = set()
    for relative in source_roots:
        source_root = root / relative
        if source_root.is_dir():
            files.update(
                path
                for path in source_root.rglob("*")
                if path.is_file()
                and "__pycache__" not in path.parts
                and ".pytest_cache" not in path.parts
                and ".mypy_cache" not in path.parts
                and ".ruff_cache" not in path.parts
                and path.suffix not in {".pyc", ".pyo", ".uid"}
                and path.name != ".DS_Store"
            )
    files.update(path for relative in source_files if (path := root / relative).is_file())
    digest = hashlib.sha256()
    for path in sorted(files, key=lambda value: value.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).hexdigest().encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def browser_runtime_source_fingerprint(repository_root: Path) -> str:
    """Hash browser/runtime sources while excluding mutable release-policy evidence."""

    return certification_source_fingerprint(
        repository_root,
        source_roots=BROWSER_SOURCE_ROOTS,
        source_files=BROWSER_SOURCE_FILES,
    )


__all__ = [
    "BROWSER_SOURCE_FILES",
    "BROWSER_SOURCE_ROOTS",
    "SOURCE_FILES",
    "SOURCE_ROOTS",
    "browser_runtime_source_fingerprint",
    "certification_source_fingerprint",
]
