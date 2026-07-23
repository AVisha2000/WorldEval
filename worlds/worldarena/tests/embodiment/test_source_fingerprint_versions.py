from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from genesis_arena.embodiment.source_fingerprint import (
    SOURCE_FINGERPRINT_V1,
    SOURCE_FINGERPRINT_V2,
    SourceComponent,
    certification_source_fingerprint,
    component_source_fingerprint,
    source_fingerprint_for_version,
)


def _legacy_digest(files: dict[str, bytes]) -> str:
    digest = hashlib.sha256()
    for logical, payload in sorted(files.items()):
        digest.update(logical.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(payload).hexdigest().encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def test_v1_preserves_historical_logical_paths_after_cutover(tmp_path: Path) -> None:
    (tmp_path / "worldeval.workspace.json").write_text("{}\n", encoding="utf-8")
    backend = tmp_path / "worlds/worldarena/backend/example.py"
    dashboard = tmp_path / "apps/worldeval-web/package.json"
    backend.parent.mkdir(parents=True)
    dashboard.parent.mkdir(parents=True)
    backend.write_bytes(b"backend")
    dashboard.write_bytes(b"web")

    actual = certification_source_fingerprint(
        tmp_path,
        source_roots=(),
        source_files=("backend/example.py", "dashboard/package.json"),
    )
    actual_from_worldarena = certification_source_fingerprint(
        tmp_path / "worlds/worldarena",
        source_roots=(),
        source_files=("backend/example.py", "dashboard/package.json"),
    )

    assert actual == _legacy_digest(
        {"backend/example.py": b"backend", "dashboard/package.json": b"web"}
    )
    assert actual_from_worldarena == actual


def test_v2_is_unchanged_when_a_complete_component_moves(tmp_path: Path) -> None:
    first = tmp_path / "first/component"
    second = tmp_path / "second/moved-component"
    first.mkdir(parents=True)
    second.mkdir(parents=True)
    (first / "nested.py").write_bytes(b"same implementation")
    (second / "nested.py").write_bytes(b"same implementation")

    before = component_source_fingerprint(
        tmp_path,
        components=(SourceComponent("example.runtime", "first/component", "tree"),),
    )
    after = component_source_fingerprint(
        tmp_path,
        components=(
            SourceComponent("example.runtime", "second/moved-component", "tree"),
        ),
    )

    assert before == after


def test_v2_changes_when_component_bytes_change(tmp_path: Path) -> None:
    component = tmp_path / "component"
    component.mkdir()
    source = component / "runtime.py"
    source.write_bytes(b"before")
    definition = (SourceComponent("example.runtime", "component", "tree"),)
    before = component_source_fingerprint(tmp_path, components=definition)

    source.write_bytes(b"after")

    assert component_source_fingerprint(tmp_path, components=definition) != before


def test_v2_binds_bytes_to_the_stable_component_identity(tmp_path: Path) -> None:
    component = tmp_path / "component"
    component.mkdir()
    (component / "runtime.py").write_bytes(b"same implementation")

    first = component_source_fingerprint(
        tmp_path,
        components=(SourceComponent("example.first", "component", "tree"),),
    )
    second = component_source_fingerprint(
        tmp_path,
        components=(SourceComponent("example.second", "component", "tree"),),
    )

    assert first != second


def test_explicit_version_dispatch_never_silently_falls_back(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    legacy = "a" * 64
    current = "b" * 64
    monkeypatch.setattr(
        "genesis_arena.embodiment.source_fingerprint.certification_source_fingerprint",
        lambda _: legacy,
    )
    monkeypatch.setattr(
        "genesis_arena.embodiment.source_fingerprint.component_source_fingerprint",
        lambda _: current,
    )

    assert source_fingerprint_for_version(tmp_path, SOURCE_FINGERPRINT_V1) == legacy
    assert source_fingerprint_for_version(tmp_path, SOURCE_FINGERPRINT_V2) == current
    with pytest.raises(ValueError, match="unsupported source fingerprint version"):
        source_fingerprint_for_version(tmp_path, "source-fingerprint-v3")
