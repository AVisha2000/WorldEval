from __future__ import annotations

import json
from pathlib import Path

import pytest
from worldeval.workspace import WorkspaceError, find_workspace

from tools.check_workspace_layout import brittle_parent_count_paths


def _marker(root: Path, paths: dict[str, str]) -> None:
    (root / "worldeval.workspace.json").write_text(
        json.dumps({"schema_version": 1, "paths": paths}), encoding="utf-8"
    )


def test_workspace_is_discovered_from_a_nested_path(tmp_path: Path) -> None:
    nested = tmp_path / "worlds/example"
    nested.mkdir(parents=True)
    target = tmp_path / "packages/core"
    target.mkdir(parents=True)
    _marker(tmp_path, {"core": "packages/core"})

    workspace = find_workspace(nested)

    assert workspace.root == tmp_path
    assert workspace.path("core") == target


def test_workspace_rejects_escape_paths(tmp_path: Path) -> None:
    _marker(tmp_path, {"unsafe": "../outside"})

    with pytest.raises(WorkspaceError, match="escapes root"):
        find_workspace(tmp_path)


def test_workspace_rejects_unknown_keys(tmp_path: Path) -> None:
    _marker(tmp_path, {"known": "inside"})
    workspace = find_workspace(tmp_path)

    with pytest.raises(WorkspaceError, match="unknown workspace path"):
        workspace.path("unknown")


def test_layout_gate_rejects_parent_count_workspace_discovery(tmp_path: Path) -> None:
    source = tmp_path / "tools" / "brittle.py"
    source.parent.mkdir(parents=True)
    source.write_text(
        "from pathlib import Path\nROOT = Path(__file__).resolve()." + "parents[3]\n",
        encoding="utf-8",
    )

    assert brittle_parent_count_paths(tmp_path) == [source]


def test_layout_gate_allows_only_the_byte_locked_historical_generator(
    tmp_path: Path,
) -> None:
    repository = find_workspace(Path(__file__)).root
    relative = Path("worlds/worldarena/scripts/build_duel_map.py")
    source = repository / relative
    copied = tmp_path / relative
    copied.parent.mkdir(parents=True)
    copied.write_bytes(source.read_bytes())

    assert brittle_parent_count_paths(tmp_path) == []

    copied.write_bytes(source.read_bytes() + b"\n")
    assert brittle_parent_count_paths(tmp_path) == [copied]
