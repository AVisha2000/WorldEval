from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
SCRIPT_PATH = ROOT / "scripts" / "validate_duel_dedicated_export.py"
SPEC = importlib.util.spec_from_file_location("duel_dedicated_export", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
dedicated_export = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = dedicated_export
SPEC.loader.exec_module(dedicated_export)


def _mutated_preset(tmp_path: Path, before: str, after: str) -> Path:
    source = (ROOT / "godot" / "export_presets.cfg").read_text(encoding="utf-8")
    assert before in source
    path = tmp_path / "export_presets.cfg"
    path.write_text(source.replace(before, after, 1), encoding="utf-8")
    return path


def _write_export_zip(path: Path, extra_names: tuple[str, ...] = ()) -> None:
    policy = dedicated_export._load_policy(ROOT / "godot" / "duel_dedicated_export_policy.json")
    _, authority_paths = dedicated_export._authority_paths(ROOT, policy)
    _, protocol_paths = dedicated_export._protocol_paths(ROOT, policy)
    entrypoint_paths = set(policy["nonvisual_entrypoint_files"])
    rewrites = policy["source_path_rewrites"]
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("project.binary", b"test-project")
        archive.writestr(".godot/global_script_class_cache.cfg", b"test-classes")
        archive.writestr(".godot/uid_cache.bin", b"test-uids")
        for name in sorted(authority_paths):
            text = (ROOT / "godot" / name).read_text(encoding="utf-8")
            for before, after in rewrites.items():
                text = text.replace(before, after)
            archive.writestr(name, text.encode("utf-8"))
        for name in sorted(entrypoint_paths):
            archive.writestr(name, (ROOT / "godot" / name).read_bytes())
        for name, source in sorted(protocol_paths.items()):
            archive.writestr(name, source.read_bytes())
        for name in extra_names:
            archive.writestr(name, b"forbidden")


def test_repository_dedicated_policy_is_complete_and_frozen() -> None:
    summary = dedicated_export.validate_repository(ROOT)

    assert summary.engine_build == "4.5.stable.official.876b29033"
    assert summary.authority_script_count == 68
    assert summary.protocol_file_count == 35
    assert len(summary.authority_inventory_hash) == 64
    assert len(summary.protocol_inventory_hash) == 64


def test_stage_contains_only_authority_and_byte_exact_protocol(tmp_path: Path) -> None:
    stage = tmp_path / "stage"
    dedicated_export.prepare_stage(stage, ROOT)

    assert not (stage / "addons").exists()
    assert not (stage / "assets").exists()
    assert not (stage / "scripts" / "duel" / "app").exists()
    assert not (stage / "scripts" / "duel" / "presentation").exists()
    source_loader = ROOT / "godot" / "scripts" / "duel" / "protocol" / "duel_catalog_loader.gd"
    staged_loader = stage / "scripts" / "duel" / "protocol" / "duel_catalog_loader.gd"
    assert "res://../game/duel_protocol" in source_loader.read_text(encoding="utf-8")
    assert "res://../game/duel_protocol" not in staged_loader.read_text(encoding="utf-8")
    assert "res://data/duel_protocol" in staged_loader.read_text(encoding="utf-8")
    staged_project = (stage / "project.godot").read_text(encoding="utf-8")
    assert (
        'run/main_scene="res://scripts/duel/match/duel_headless_cli.tscn"'
        in staged_project
    )
    assert "export/convert_text_resources_to_binary=false" in staged_project
    assert staged_project.count("file_logging/enable_file_logging") == 2
    assert "file_logging/enable_file_logging=false" in staged_project
    assert "file_logging/enable_file_logging.pc=false" in staged_project

    source_protocol = ROOT / "game" / "duel_protocol"
    staged_protocol = stage / "data" / "duel_protocol"
    for source in source_protocol.rglob("*"):
        if source.is_file() and source.name != "README.md":
            target = staged_protocol / source.relative_to(source_protocol)
            assert target.read_bytes() == source.read_bytes()
    manifest = json.loads(
        (stage / "DUEL_DEDICATED_STAGE_MANIFEST.json").read_text(encoding="utf-8")
    )
    assert manifest["kind"] == "worldarena_duel_dedicated_source_stage"


def test_staged_project_directly_boots_fail_closed_headless_cli(tmp_path: Path) -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    stage = tmp_path / "stage"
    dedicated_export.prepare_stage(stage, ROOT)
    imported = subprocess.run(
        [str(GODOT), "--headless", "--path", str(stage), "--import"],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert imported.returncode == 0, imported.stdout + imported.stderr
    launched = subprocess.run(
        [str(GODOT), "--headless", "--path", str(stage)],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert launched.returncode == 2
    assert "worldarena_duel_headless_error" in launched.stdout


def test_actual_godot_resource_pack_remains_text_and_auditable(tmp_path: Path) -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    stage = tmp_path / "stage"
    archive = tmp_path / "duel-dedicated.zip"
    dedicated_export.prepare_stage(stage, ROOT)
    imported = subprocess.run(
        [str(GODOT), "--headless", "--path", str(stage), "--import"],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert imported.returncode == 0, imported.stdout + imported.stderr
    exported = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--path",
            str(stage),
            "--export-pack",
            "WorldArena Duel Dedicated Server",
            str(archive),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert exported.returncode == 0, exported.stdout + exported.stderr
    result = dedicated_export.inspect_export_zip(archive, ROOT)
    assert result["authority_script_count"] == 68
    with zipfile.ZipFile(archive) as bundle:
        names = set(bundle.namelist())
    assert "scripts/duel/match/duel_headless_cli.tscn" in names
    assert not any(name.endswith((".scn", ".tscn.remap")) for name in names)
    launched = subprocess.run(
        [str(GODOT), "--headless", "--main-pack", str(archive)],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert launched.returncode == 2
    assert "worldarena_duel_headless_error" in launched.stdout


def test_preset_fails_closed_when_dedicated_headless_mode_is_disabled(tmp_path: Path) -> None:
    preset = _mutated_preset(tmp_path, "dedicated_server=true", "dedicated_server=false")

    with pytest.raises(
        dedicated_export.DedicatedExportError, match="dedicated_server feature must be enabled"
    ):
        dedicated_export.validate_repository(ROOT, preset_path=preset)


@pytest.mark.parametrize(
    ("leaked_path", "message"),
    [
        (
            "res://scripts/duel/presentation/duel_hud.gd",
            "authority allowlist mismatch",
        ),
        (
            "res://scripts/duel/app/duel_http_json_transport.gd",
            "authority allowlist mismatch",
        ),
        (
            "res://addons/limboai/bin/limboai.gdextension",
            "authority allowlist mismatch",
        ),
        (
            "res://assets/server-icon.png",
            "authority allowlist mismatch",
        ),
    ],
)
def test_preset_rejects_presentation_native_or_visual_selected_resources(
    tmp_path: Path, leaked_path: str, message: str
) -> None:
    preset = _mutated_preset(
        tmp_path,
        '"res://scripts/duel/simulation/duel_tick_ledger.gd")',
        f'"res://scripts/duel/simulation/duel_tick_ledger.gd", "{leaked_path}")',
    )

    with pytest.raises(dedicated_export.DedicatedExportError, match=message):
        dedicated_export.validate_repository(ROOT, preset_path=preset)


def test_preset_rejects_missing_authority_script(tmp_path: Path) -> None:
    preset = _mutated_preset(
        tmp_path,
        '"res://scripts/duel/simulation/duel_replay.gd", ',
        "",
    )

    with pytest.raises(dedicated_export.DedicatedExportError, match="authority allowlist mismatch"):
        dedicated_export.validate_repository(ROOT, preset_path=preset)


def test_actual_export_zip_inventory_is_inspectable_and_fail_closed(tmp_path: Path) -> None:
    valid_archive = tmp_path / "duel-dedicated-valid.zip"
    _write_export_zip(valid_archive)
    result = dedicated_export.inspect_export_zip(valid_archive, ROOT)
    assert result["authority_script_count"] == 68
    assert result["protocol_file_count"] == 35

    leaking_archive = tmp_path / "duel-dedicated-leak.zip"
    _write_export_zip(
        leaking_archive,
        extra_names=("addons/limboai/bin/liblimboai.linux.template_release.x86_64.so",),
    )
    with pytest.raises(dedicated_export.DedicatedExportError, match="forbidden"):
        dedicated_export.inspect_export_zip(leaking_archive, ROOT)
