"""Versioned source fingerprints shared by certification and readiness.

``source-fingerprint-v1`` deliberately hashes the historical repository paths.
That lets evidence produced before the WorldEval workspace cutover remain
verifiable even though those files now live below ``worlds/worldarena`` and
``apps/worldeval-web``.  ``source-fingerprint-v2`` hashes stable component IDs
and paths *inside* each component, so moving a complete component does not
pretend that its implementation changed.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Iterable, Literal, NamedTuple

SOURCE_FINGERPRINT_V1 = "source-fingerprint-v1"
SOURCE_FINGERPRINT_V2 = "source-fingerprint-v2"

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


class SourceComponent(NamedTuple):
    """A stable logical component and its current workspace-relative path."""

    component_id: str
    path: str
    kind: Literal["tree", "file"]


SOURCE_COMPONENTS_V2 = (
    SourceComponent(
        "worldarena.backend.embodiment",
        "worlds/worldarena/backend/genesis_arena/embodiment",
        "tree",
    ),
    SourceComponent(
        "worldarena.backend.duel",
        "worlds/worldarena/backend/genesis_arena/duel",
        "tree",
    ),
    SourceComponent(
        "worldarena.protocol.embodiment",
        "worlds/worldarena/game/embodiment_protocol",
        "tree",
    ),
    SourceComponent(
        "worldarena.release.embodiment",
        "worlds/worldarena/game/embodiment_release",
        "tree",
    ),
    SourceComponent(
        "worldarena.protocol.duel",
        "worlds/worldarena/game/duel_protocol",
        "tree",
    ),
    SourceComponent(
        "worldarena.godot.scenes.embodiment",
        "worlds/worldarena/godot/scenes/embodiment",
        "tree",
    ),
    SourceComponent(
        "worldarena.godot.runtime.embodiment",
        "worlds/worldarena/godot/scripts/embodiment",
        "tree",
    ),
    SourceComponent(
        "worldarena.godot.runtime.duel",
        "worlds/worldarena/godot/scripts/duel",
        "tree",
    ),
    SourceComponent(
        "worldarena.godot.tests.embodiment",
        "worlds/worldarena/godot/tests/embodiment",
        "tree",
    ),
    SourceComponent(
        "worldarena.godot.tests.duel",
        "worlds/worldarena/godot/tests/duel",
        "tree",
    ),
    SourceComponent(
        "worldarena.python.tests.embodiment",
        "worlds/worldarena/tests/embodiment",
        "tree",
    ),
    SourceComponent(
        "worldarena.python.tests.duel",
        "worlds/worldarena/tests/duel",
        "tree",
    ),
    SourceComponent("worldeval.web.source", "apps/worldeval-web/src", "tree"),
    SourceComponent(
        "worldeval.web.package", "apps/worldeval-web/package.json", "file"
    ),
    SourceComponent(
        "worldeval.web.lock", "apps/worldeval-web/pnpm-lock.yaml", "file"
    ),
    SourceComponent(
        "worldeval.web.build", "apps/worldeval-web/vite.config.ts", "file"
    ),
    SourceComponent(
        "worldarena.backend.config",
        "worlds/worldarena/backend/genesis_arena/config.py",
        "file",
    ),
    SourceComponent(
        "worldarena.backend.application",
        "worlds/worldarena/backend/genesis_arena/main.py",
        "file",
    ),
    SourceComponent(
        "worldarena.godot.export-policy",
        "worlds/worldarena/godot/export_presets.cfg",
        "file",
    ),
    SourceComponent(
        "worldarena.godot.project",
        "worlds/worldarena/godot/project.godot",
        "file",
    ),
    SourceComponent("worldeval.python-workspace", "pyproject.toml", "file"),
    *(
        SourceComponent(
            f"worldarena.tool.{Path(relative).stem.replace('_', '-')}",
            f"worlds/worldarena/{relative}",
            "file",
        )
        for relative in SOURCE_FILES
        if relative.startswith("scripts/")
    ),
)


_LEGACY_PREFIXES = (
    ("backend/", "worlds/worldarena/backend/"),
    ("game/", "worlds/worldarena/game/"),
    ("godot/", "worlds/worldarena/godot/"),
    ("tests/", "worlds/worldarena/tests/"),
    ("dashboard/", "apps/worldeval-web/"),
    ("scripts/", "worlds/worldarena/scripts/"),
)


def _is_source_file(path: Path) -> bool:
    return (
        path.is_file()
        and "__pycache__" not in path.parts
        and ".pytest_cache" not in path.parts
        and ".mypy_cache" not in path.parts
        and ".ruff_cache" not in path.parts
        and path.suffix not in {".pyc", ".pyo", ".uid"}
        and path.name != ".DS_Store"
    )


def _workspace_root(root: Path) -> Path | None:
    """Find the cutover workspace without importing the new package facade."""

    for candidate in (root, *root.parents):
        if (candidate / "worldeval.workspace.json").is_file():
            return candidate
    return None


def _legacy_physical_path(root: Path, relative: str) -> Path:
    """Resolve one v1 logical path before or after the workspace cutover."""

    direct = root / relative
    if direct.exists():
        return direct
    workspace = _workspace_root(root)
    if workspace is None:
        return direct
    for legacy_prefix, current_prefix in _LEGACY_PREFIXES:
        if relative.startswith(legacy_prefix):
            return workspace / current_prefix / relative.removeprefix(legacy_prefix)
    return workspace / relative


def certification_source_fingerprint(
    repository_root: Path,
    *,
    source_roots: Iterable[str] = SOURCE_ROOTS,
    source_files: Iterable[str] = SOURCE_FILES,
) -> str:
    """Return a v1 hash using historical logical paths.

    The optional roots/files remain useful for isolated fixture tests.  Logical
    names, not cutover-era physical names, are always fed into the digest.
    """

    root = Path(repository_root).resolve()
    files: dict[str, Path] = {}
    for relative in source_roots:
        source_root = _legacy_physical_path(root, relative)
        if source_root.is_dir():
            for path in source_root.rglob("*"):
                if _is_source_file(path):
                    logical = (Path(relative) / path.relative_to(source_root)).as_posix()
                    files[logical] = path
    for relative in source_files:
        path = _legacy_physical_path(root, relative)
        if path.is_file():
            files[Path(relative).as_posix()] = path
    digest = hashlib.sha256()
    for logical, path in sorted(files.items()):
        digest.update(logical.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).hexdigest().encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def component_source_fingerprint(
    repository_root: Path,
    *,
    components: Iterable[SourceComponent] = SOURCE_COMPONENTS_V2,
) -> str:
    """Return a v2 hash keyed by stable logical component identities."""

    root = Path(repository_root).resolve()
    workspace = _workspace_root(root) or root
    files: dict[str, Path] = {}
    for component in components:
        path = workspace / component.path
        if component.kind == "file":
            if path.is_file():
                files[component.component_id] = path
            continue
        if not path.is_dir():
            continue
        for candidate in path.rglob("*"):
            if _is_source_file(candidate):
                logical = (
                    f"{component.component_id}/"
                    f"{candidate.relative_to(path).as_posix()}"
                )
                files[logical] = candidate

    digest = hashlib.sha256()
    digest.update(SOURCE_FINGERPRINT_V2.encode("ascii"))
    digest.update(b"\0")
    for logical, path in sorted(files.items()):
        digest.update(logical.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
        digest.update(b"\0")
    return digest.hexdigest()


def source_fingerprint_for_version(repository_root: Path, version: str) -> str:
    """Resolve an explicitly versioned fingerprint without silent fallback."""

    if version == SOURCE_FINGERPRINT_V1:
        return certification_source_fingerprint(repository_root)
    if version == SOURCE_FINGERPRINT_V2:
        return component_source_fingerprint(repository_root)
    raise ValueError(f"unsupported source fingerprint version: {version}")


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
    "SOURCE_COMPONENTS_V2",
    "SOURCE_FINGERPRINT_V1",
    "SOURCE_FINGERPRINT_V2",
    "SOURCE_ROOTS",
    "SourceComponent",
    "browser_runtime_source_fingerprint",
    "certification_source_fingerprint",
    "component_source_fingerprint",
    "source_fingerprint_for_version",
]
