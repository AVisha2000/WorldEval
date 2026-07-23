#!/usr/bin/env python3
"""Fail-closed certification for the WorldArena Duel dedicated export.

The repository keeps the canonical protocol package outside the Godot project.  A release export
therefore uses a temporary, allowlisted project stage: authority scripts are copied unchanged apart
from the resource-root relocation, and protocol bytes are copied byte-for-byte under ``res://data``.
The source project is never modified.
"""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import re
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = REPOSITORY_ROOT / "godot" / "duel_dedicated_export_policy.json"
DEFAULT_PRESET = REPOSITORY_ROOT / "godot" / "export_presets.cfg"
PRESET_SECTION = "preset.0"
OPTIONS_SECTION = "preset.0.options"


class DedicatedExportError(RuntimeError):
    """Raised when the dedicated export boundary is not provably safe."""


@dataclass(frozen=True)
class CertificationSummary:
    engine_build: str
    preset_name: str
    authority_script_count: int
    protocol_file_count: int
    authority_inventory_hash: str
    protocol_inventory_hash: str
    policy_hash: str
    preset_hash: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "authority_inventory_hash": self.authority_inventory_hash,
            "authority_script_count": self.authority_script_count,
            "engine_build": self.engine_build,
            "policy_hash": self.policy_hash,
            "preset_hash": self.preset_hash,
            "preset_name": self.preset_name,
            "protocol_file_count": self.protocol_file_count,
            "protocol_inventory_hash": self.protocol_inventory_hash,
        }


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _inventory_hash(paths: Iterable[str]) -> str:
    payload = json.dumps(sorted(paths), ensure_ascii=True, separators=(",", ":")).encode()
    return _sha256_bytes(payload)


def _load_policy(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise DedicatedExportError(f"cannot read dedicated export policy {path}: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise DedicatedExportError("dedicated export policy must be a schema_version 1 object")
    return value


def _load_config(path: Path) -> configparser.RawConfigParser:
    parser = configparser.RawConfigParser(
        delimiters=("=",),
        comment_prefixes=(";", "#"),
        interpolation=None,
        strict=True,
    )
    parser.optionxform = str
    try:
        source = path.read_text(encoding="utf-8")
        first_content = next(
            (
                line.strip()
                for line in source.splitlines()
                if line.strip() and not line.startswith(";")
            ),
            "",
        )
        if first_content and not first_content.startswith("["):
            source = "[__root__]\n" + source
        parser.read_string(source, source=str(path))
    except (OSError, UnicodeDecodeError, configparser.Error) as exc:
        raise DedicatedExportError(f"cannot parse Godot config {path}: {exc}") from exc
    return parser


def _quoted(value: str, label: str) -> str:
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError as exc:
        raise DedicatedExportError(f"{label} must be a quoted Godot string") from exc
    if not isinstance(decoded, str):
        raise DedicatedExportError(f"{label} must be a string")
    return decoded


def _boolean(value: str, label: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise DedicatedExportError(f"{label} must be true or false")


def _packed_strings(value: str, label: str) -> list[str]:
    match = re.fullmatch(r"PackedStringArray\((.*)\)", value.strip(), flags=re.DOTALL)
    if match is None:
        raise DedicatedExportError(f"{label} must be a PackedStringArray")
    body = match.group(1).strip()
    if not body:
        return []
    try:
        decoded = json.loads(f"[{body}]")
    except json.JSONDecodeError as exc:
        raise DedicatedExportError(f"{label} contains invalid string entries") from exc
    if not isinstance(decoded, list) or not all(isinstance(item, str) for item in decoded):
        raise DedicatedExportError(f"{label} must contain only strings")
    return decoded


def _csv_string(value: str, label: str) -> list[str]:
    decoded = _quoted(value, label)
    if not decoded:
        return []
    entries = decoded.split(",")
    if any(not entry or entry != entry.strip() for entry in entries):
        raise DedicatedExportError(f"{label} must be a compact comma-separated list")
    if len(entries) != len(set(entries)):
        raise DedicatedExportError(f"{label} contains duplicate entries")
    return entries


def _repository_path(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as exc:
        raise DedicatedExportError(f"policy path escapes the repository: {relative}") from exc
    return path


def _authority_paths(root: Path, policy: dict[str, Any]) -> tuple[Path, set[str]]:
    source_root = _repository_path(root, str(policy["authority_source_root"]))
    excluded = tuple(
        _repository_path(root, str(relative))
        for relative in policy["authority_excluded_subtrees"]
    )
    if not source_root.is_dir() or not excluded or any(not path.is_dir() for path in excluded):
        raise DedicatedExportError("authority or excluded source root is missing")
    paths: set[str] = set()
    for source in source_root.rglob("*.gd"):
        if source.is_symlink():
            raise DedicatedExportError(f"authority scripts must not be symlinks: {source}")
        resolved = source.resolve()
        if any(path == resolved or path in resolved.parents for path in excluded):
            continue
        paths.add(source.relative_to(root / "godot").as_posix())
    if not paths:
        raise DedicatedExportError("no Duel authority scripts were discovered")
    return source_root, paths


def _protocol_paths(root: Path, policy: dict[str, Any]) -> tuple[Path, dict[str, Path]]:
    source_root = _repository_path(root, str(policy["protocol_source_root"]))
    if not source_root.is_dir():
        raise DedicatedExportError("canonical Duel protocol package is missing")
    ignored = set(policy["protocol_ignored_files"])
    stage_root = PurePosixPath(str(policy["protocol_stage_root"]))
    paths: dict[str, Path] = {}
    observed_ignored: set[str] = set()
    for source in sorted(source_root.rglob("*")):
        if not source.is_file():
            continue
        if source.is_symlink():
            raise DedicatedExportError(f"protocol files must not be symlinks: {source}")
        relative = source.relative_to(source_root).as_posix()
        if relative in ignored:
            observed_ignored.add(relative)
            continue
        if source.name != "VERSION" and source.suffix not in {".json", ".txt"}:
            raise DedicatedExportError(
                f"protocol file {relative} has no declared dedicated export treatment"
            )
        paths[(stage_root / relative).as_posix()] = source
    if observed_ignored != ignored:
        missing = sorted(ignored - observed_ignored)
        raise DedicatedExportError(f"ignored protocol files are missing: {missing}")
    if not paths:
        raise DedicatedExportError("no canonical Duel protocol files were discovered")
    return source_root, paths


def _validate_project_settings(root: Path, policy: dict[str, Any]) -> None:
    project_path = root / "godot" / "project.godot"
    project = _load_config(project_path)
    renderer = str(policy["renderer"])
    for key in ("renderer/rendering_method", "renderer/rendering_method.mobile"):
        actual = _quoted(project.get("rendering", key), f"project.godot rendering/{key}")
        if actual != renderer:
            raise DedicatedExportError(f"project renderer {key} must remain {renderer}")
    actual_plugins = _packed_strings(
        project.get("editor_plugins", "enabled"), "project.godot editor_plugins/enabled"
    )
    expected_plugins = list(policy["editor_only_plugins"])
    if actual_plugins != expected_plugins:
        raise DedicatedExportError(
            "the visual-editor plugin policy changed; update and re-certify it explicitly"
        )
    for key in ("file_logging/enable_file_logging", "file_logging/enable_file_logging.pc"):
        if _boolean(project.get("debug", key), f"project.godot debug/{key}"):
            raise DedicatedExportError("Godot file logging must remain disabled for Duel secrets")


def _validate_preset(
    root: Path,
    policy: dict[str, Any],
    preset_path: Path,
    authority_paths: set[str],
    protocol_paths: dict[str, Path],
) -> None:
    preset = _load_config(preset_path)
    if set(preset.sections()) != {PRESET_SECTION, OPTIONS_SECTION}:
        raise DedicatedExportError("the dedicated export file must contain exactly one preset")
    values = preset[PRESET_SECTION]
    options = preset[OPTIONS_SECTION]

    expected_scalars = {
        "name": str(policy["preset_name"]),
        "platform": str(policy["platform"]),
        "export_filter": "resources",
    }
    for key, expected in expected_scalars.items():
        actual = _quoted(values[key], f"{PRESET_SECTION}/{key}")
        if actual != expected:
            raise DedicatedExportError(f"{key} must be {expected!r}, got {actual!r}")
    if not _boolean(values["runnable"], "runnable"):
        raise DedicatedExportError("the dedicated preset must be runnable")
    if not _boolean(values["dedicated_server"], "dedicated_server"):
        raise DedicatedExportError("the dedicated_server feature must be enabled")
    if _boolean(values["advanced_options"], "advanced_options"):
        raise DedicatedExportError("advanced export options must remain disabled")
    if _boolean(values["encrypt_pck"], "encrypt_pck") or _boolean(
        values["encrypt_directory"], "encrypt_directory"
    ):
        raise DedicatedExportError("dedicated export encryption/signing is outside this preset")
    if values["script_export_mode"] != "0":
        raise DedicatedExportError("scripts must remain text so package contents are auditable")

    features = _csv_string(values["custom_features"], "custom_features")
    if features != list(policy["custom_features"]):
        raise DedicatedExportError("dedicated custom feature tags do not match the frozen policy")
    selected = _packed_strings(values["export_files"], "export_files")
    if len(selected) != len(set(selected)):
        raise DedicatedExportError("export_files contains duplicates")
    selected_paths = {
        path.removeprefix("res://") if path.startswith("res://") else path for path in selected
    }
    entrypoint_paths = set(str(path) for path in policy["nonvisual_entrypoint_files"])
    expected_selected = authority_paths | entrypoint_paths
    if selected_paths != expected_selected:
        missing = sorted(expected_selected - selected_paths)
        unexpected = sorted(selected_paths - expected_selected)
        raise DedicatedExportError(
            f"authority allowlist mismatch; missing={missing}, unexpected={unexpected}"
        )
    for relative in entrypoint_paths:
        source = root / "godot" / relative
        if not source.is_file() or source.is_symlink():
            raise DedicatedExportError(f"nonvisual dedicated entrypoint is missing: {relative}")
        text = source.read_text(encoding="utf-8")
        if "type=\"Node\"" not in text or "duel_headless_cli_node.gd" not in text:
            raise DedicatedExportError("dedicated entrypoint is not the frozen nonvisual CLI scene")

    include_paths = set(_csv_string(values["include_filter"], "include_filter"))
    expected_protocol = set(protocol_paths)
    if include_paths != expected_protocol:
        missing = sorted(expected_protocol - include_paths)
        unexpected = sorted(include_paths - expected_protocol)
        raise DedicatedExportError(
            f"protocol include list mismatch; missing={missing}, unexpected={unexpected}"
        )
    if any("*" in path or "?" in path for path in include_paths):
        raise DedicatedExportError("protocol includes must remain exact paths, not wildcards")

    expected_excludes = {
        f"{prefix.rstrip('/')}/*" for prefix in policy["forbidden_export_prefixes"]
    }
    expected_excludes.update(f"*{suffix}" for suffix in policy["forbidden_export_suffixes"])
    actual_excludes = set(_csv_string(values["exclude_filter"], "exclude_filter"))
    if actual_excludes != expected_excludes:
        missing = sorted(expected_excludes - actual_excludes)
        unexpected = sorted(actual_excludes - expected_excludes)
        raise DedicatedExportError(
            f"explicit exclusion list mismatch; missing={missing}, unexpected={unexpected}"
        )

    export_path = _quoted(values["export_path"], "export_path")
    if not export_path.startswith("../exports/duel-dedicated/") or not export_path.endswith(
        ".x86_64"
    ):
        raise DedicatedExportError("export_path must target the ignored dedicated export folder")
    if _quoted(options["binary_format/architecture"], "binary_format/architecture") != str(
        policy["architecture"]
    ):
        raise DedicatedExportError("Linux dedicated architecture changed from the frozen policy")
    if _boolean(options["binary_format/embed_pck"], "binary_format/embed_pck"):
        raise DedicatedExportError("the auditable server PCK must remain separate from the binary")
    for key in ("custom_template/debug", "custom_template/release"):
        if _quoted(options[key], key):
            raise DedicatedExportError("custom executable templates require separate certification")
    if _boolean(options["ssh_remote_deploy/enabled"], "ssh_remote_deploy/enabled"):
        raise DedicatedExportError("publishing/deployment must not be enabled in the frozen preset")

    lower_selected = [path.lower() for path in selected_paths]
    _reject_forbidden_paths(lower_selected, policy, context="selected resource")
    for path in authority_paths:
        source = root / "godot" / path
        text = source.read_text(encoding="utf-8")
        lowered = text.lower()
        for forbidden in policy["forbidden_path_fragments"]:
            token = str(forbidden).lower()
            if token in lowered:
                raise DedicatedExportError(
                    f"authority script {path} references forbidden presentation/native path {token}"
                )


def _reject_forbidden_paths(paths: Iterable[str], policy: dict[str, Any], *, context: str) -> None:
    prefixes = tuple(str(value).lower() for value in policy["forbidden_export_prefixes"])
    fragments = tuple(str(value).lower() for value in policy["forbidden_path_fragments"])
    suffixes = tuple(str(value).lower() for value in policy["forbidden_export_suffixes"])
    for raw_path in paths:
        path = raw_path.replace("\\", "/").removeprefix("./").lower()
        padded = f"/{path}"
        if path.startswith(prefixes) or any(fragment in padded for fragment in fragments):
            raise DedicatedExportError(f"{context} leaks forbidden path {raw_path}")
        if path.endswith(suffixes):
            raise DedicatedExportError(f"{context} leaks forbidden resource type {raw_path}")


def _check_engine(godot_binary: Path, expected: str) -> None:
    try:
        result = subprocess.run(
            [str(godot_binary), "--version"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DedicatedExportError(f"cannot execute frozen Godot binary: {exc}") from exc
    actual = result.stdout.strip()
    if result.returncode != 0 or actual != expected:
        raise DedicatedExportError(f"Godot build mismatch: expected {expected!r}, got {actual!r}")


def validate_repository(
    root: Path = REPOSITORY_ROOT,
    *,
    policy_path: Path | None = None,
    preset_path: Path | None = None,
    godot_binary: Path | None = None,
) -> CertificationSummary:
    root = root.resolve()
    policy_path = (policy_path or root / "godot" / "duel_dedicated_export_policy.json").resolve()
    preset_path = (preset_path or root / "godot" / "export_presets.cfg").resolve()
    policy = _load_policy(policy_path)
    _validate_project_settings(root, policy)
    _, authority_paths = _authority_paths(root, policy)
    _, protocol_paths = _protocol_paths(root, policy)
    _validate_preset(root, policy, preset_path, authority_paths, protocol_paths)
    for sentinel in policy["required_authority_sentinels"]:
        if sentinel not in authority_paths:
            raise DedicatedExportError(f"required authority file is absent: {sentinel}")
    for sentinel in policy["required_protocol_sentinels"]:
        if sentinel not in protocol_paths:
            raise DedicatedExportError(f"required protocol file is absent: {sentinel}")
    if godot_binary is not None:
        _check_engine(godot_binary.resolve(), str(policy["engine_build"]))
    return CertificationSummary(
        engine_build=str(policy["engine_build"]),
        preset_name=str(policy["preset_name"]),
        authority_script_count=len(authority_paths),
        protocol_file_count=len(protocol_paths),
        authority_inventory_hash=_inventory_hash(authority_paths),
        protocol_inventory_hash=_inventory_hash(protocol_paths),
        policy_hash=_sha256_bytes(policy_path.read_bytes()),
        preset_hash=_sha256_bytes(preset_path.read_bytes()),
    )


def _copy_authority_stage(
    root: Path, stage: Path, policy: dict[str, Any], authority_paths: set[str]
) -> None:
    rewrites = {str(key): str(value) for key, value in policy["source_path_rewrites"].items()}
    for relative in sorted(authority_paths):
        source = root / "godot" / relative
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        text = source.read_text(encoding="utf-8")
        for before, after in rewrites.items():
            text = text.replace(before, after)
        target.write_text(text, encoding="utf-8")
        uid_source = source.with_name(source.name + ".uid")
        if uid_source.is_file():
            shutil.copyfile(uid_source, target.with_name(target.name + ".uid"))


def _stage_project_text(source: str) -> str:
    main_scene_pattern = re.compile(r'(?m)^run/main_scene="[^"]*"$')
    plugin_pattern = re.compile(r"(?m)^enabled=PackedStringArray\([^\n]*\)$")
    source, main_count = main_scene_pattern.subn(
        'run/main_scene="res://scripts/duel/match/duel_headless_cli.tscn"', source
    )
    source, plugin_count = plugin_pattern.subn("enabled=PackedStringArray()", source)
    if main_count != 1 or plugin_count != 1:
        raise DedicatedExportError("cannot apply frozen headless project overrides safely")
    if re.search(r"(?m)^\[editor\]$", source):
        raise DedicatedExportError("source project unexpectedly defines an editor section")
    return (
        source.rstrip()
        + "\n\n[editor]\n\nexport/convert_text_resources_to_binary=false\n"
    )


def prepare_stage(
    destination: Path,
    root: Path = REPOSITORY_ROOT,
    *,
    policy_path: Path | None = None,
    preset_path: Path | None = None,
) -> CertificationSummary:
    root = root.resolve()
    destination = destination.resolve()
    policy_path = (policy_path or root / "godot" / "duel_dedicated_export_policy.json").resolve()
    preset_path = (preset_path or root / "godot" / "export_presets.cfg").resolve()
    summary = validate_repository(root, policy_path=policy_path, preset_path=preset_path)
    policy = _load_policy(policy_path)
    _, authority_paths = _authority_paths(root, policy)
    _, protocol_paths = _protocol_paths(root, policy)
    try:
        destination.relative_to(root)
    except ValueError:
        pass
    else:
        raise DedicatedExportError("stage destination must be outside the source repository")
    if destination.exists():
        if not destination.is_dir():
            raise DedicatedExportError("stage destination exists and is not a directory")
        if any(destination.iterdir()):
            raise DedicatedExportError("stage destination must not already contain files")
    destination.mkdir(parents=True, exist_ok=True)

    project_text = (root / "godot" / "project.godot").read_text(encoding="utf-8")
    (destination / "project.godot").write_text(_stage_project_text(project_text), encoding="utf-8")
    shutil.copyfile(preset_path, destination / "export_presets.cfg")
    shutil.copyfile(policy_path, destination / "duel_dedicated_export_policy.json")
    smoke_source = root / "godot" / "tests" / "duel" / "duel_dedicated_stage_smoke_runner.gd"
    smoke_target = destination / "certification" / "duel_dedicated_stage_smoke_runner.gd"
    smoke_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(smoke_source, smoke_target)
    _copy_authority_stage(root, destination, policy, authority_paths)
    for relative in policy["nonvisual_entrypoint_files"]:
        source = root / "godot" / str(relative)
        target = destination / str(relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for staged_relative, source in sorted(protocol_paths.items()):
        target = destination / staged_relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

    validate_stage(
        destination,
        policy=policy,
        authority_paths=authority_paths,
        protocol_paths=set(protocol_paths),
    )
    manifest = {
        **summary.as_dict(),
        "kind": "worldarena_duel_dedicated_source_stage",
        "stage_file_hashes": {
            path.relative_to(destination).as_posix(): _sha256_bytes(path.read_bytes())
            for path in sorted(destination.rglob("*"))
            if path.is_file() and path.name != "DUEL_DEDICATED_STAGE_MANIFEST.json"
        },
    }
    (destination / "DUEL_DEDICATED_STAGE_MANIFEST.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return summary


def validate_stage(
    stage: Path,
    *,
    policy: dict[str, Any],
    authority_paths: set[str],
    protocol_paths: set[str],
) -> None:
    files = {path.relative_to(stage).as_posix() for path in stage.rglob("*") if path.is_file()}
    forbidden_candidates = [
        path
        for path in files
        if path not in {"project.godot", "export_presets.cfg", "duel_dedicated_export_policy.json"}
        and not path.endswith(".uid")
    ]
    _reject_forbidden_paths(forbidden_candidates, policy, context="dedicated source stage")
    missing_authority = authority_paths - files
    missing_entrypoints = set(policy["nonvisual_entrypoint_files"]) - files
    missing_protocol = protocol_paths - files
    if missing_authority or missing_entrypoints or missing_protocol:
        raise DedicatedExportError(
            "dedicated stage is incomplete; "
            f"missing_authority={sorted(missing_authority)}, "
            f"missing_entrypoints={sorted(missing_entrypoints)}, "
            f"missing_protocol={sorted(missing_protocol)}"
        )
    for relative in authority_paths:
        text = (stage / relative).read_text(encoding="utf-8")
        for source_path in policy["source_path_rewrites"]:
            if source_path in text:
                raise DedicatedExportError(
                    f"staged authority path was not relocated in {relative}: {source_path}"
                )
    project = _load_config(stage / "project.godot")
    if _quoted(project.get("application", "run/main_scene"), "staged run/main_scene") != (
        "res://scripts/duel/match/duel_headless_cli.tscn"
    ):
        raise DedicatedExportError(
            "staged dedicated project must boot the nonvisual Duel CLI scene"
        )
    if _packed_strings(project.get("editor_plugins", "enabled"), "staged editor_plugins/enabled"):
        raise DedicatedExportError("staged dedicated project must not load editor plugins")
    if _boolean(
        project.get("editor", "export/convert_text_resources_to_binary"),
        "staged editor/export/convert_text_resources_to_binary",
    ):
        raise DedicatedExportError("staged dedicated scene must remain text for byte inspection")
    for key in ("file_logging/enable_file_logging", "file_logging/enable_file_logging.pc"):
        if _boolean(project.get("debug", key), f"staged debug/{key}"):
            raise DedicatedExportError("staged Godot file logging must remain disabled")


def inspect_export_zip(
    archive_path: Path,
    root: Path = REPOSITORY_ROOT,
    *,
    policy_path: Path | None = None,
) -> dict[str, Any]:
    root = root.resolve()
    policy_path = (policy_path or root / "godot" / "duel_dedicated_export_policy.json").resolve()
    policy = _load_policy(policy_path)
    _, authority_paths = _authority_paths(root, policy)
    entrypoint_paths = set(str(path) for path in policy["nonvisual_entrypoint_files"])
    _, protocol_source_paths = _protocol_paths(root, policy)
    archive_bytes: dict[str, bytes] = {}
    try:
        with zipfile.ZipFile(archive_path) as archive:
            names = [
                name.removeprefix("./") for name in archive.namelist() if not name.endswith("/")
            ]
            archive_bytes = {name: archive.read(name) for name in names}
    except (OSError, zipfile.BadZipFile) as exc:
        raise DedicatedExportError(f"cannot inspect exported ZIP {archive_path}: {exc}") from exc
    if len(names) != len(set(names)):
        raise DedicatedExportError("exported ZIP contains duplicate member names")
    for name in names:
        pure = PurePosixPath(name)
        if pure.is_absolute() or ".." in pure.parts or "\\" in name:
            raise DedicatedExportError(f"exported ZIP contains unsafe path {name!r}")
    _reject_forbidden_paths(names, policy, context="exported ZIP")

    allowed_prefixes = tuple(str(value) for value in policy["allowed_export_prefixes"])
    allowed_files = set(str(value) for value in policy["allowed_export_files"])
    for name in names:
        if name in allowed_files or name.startswith(allowed_prefixes):
            continue
        raise DedicatedExportError(f"exported ZIP contains non-allowlisted file {name}")
    missing_authority = authority_paths - set(names)
    missing_entrypoints = entrypoint_paths - set(names)
    missing_protocol = set(protocol_source_paths) - set(names)
    if missing_authority or missing_entrypoints or missing_protocol:
        raise DedicatedExportError(
            "exported ZIP is incomplete; "
            f"missing_authority={sorted(missing_authority)}, "
            f"missing_entrypoints={sorted(missing_entrypoints)}, "
            f"missing_protocol={sorted(missing_protocol)}"
        )
    required_archive_files = set(str(value) for value in policy["required_archive_files"])
    missing_archive_files = required_archive_files - set(names)
    if missing_archive_files:
        raise DedicatedExportError(
            f"exported ZIP lacks required Godot metadata: {sorted(missing_archive_files)}"
        )
    expected_names = (
        authority_paths | entrypoint_paths | set(protocol_source_paths) | required_archive_files
    )
    unexpected_names = set(names) - expected_names
    if unexpected_names:
        raise DedicatedExportError(
            f"exported ZIP contains unexpected files: {sorted(unexpected_names)}"
        )
    rewrites = {str(key): str(value) for key, value in policy["source_path_rewrites"].items()}
    for relative in authority_paths:
        expected_text = (root / "godot" / relative).read_text(encoding="utf-8")
        for before, after in rewrites.items():
            expected_text = expected_text.replace(before, after)
        if archive_bytes[relative] != expected_text.encode("utf-8"):
            raise DedicatedExportError(
                f"exported authority script differs from the certified staged source: {relative}"
            )
    for relative in entrypoint_paths:
        if archive_bytes[relative] != (root / "godot" / relative).read_bytes():
            raise DedicatedExportError(
                f"exported nonvisual entrypoint differs from source bytes: {relative}"
            )
    for relative, source in protocol_source_paths.items():
        if archive_bytes[relative] != source.read_bytes():
            raise DedicatedExportError(
                f"exported protocol data differs from canonical source bytes: {relative}"
            )
    return {
        "archive_sha256": _sha256_bytes(archive_path.read_bytes()),
        "authority_script_count": len(authority_paths),
        "file_count": len(names),
        "protocol_file_count": len(protocol_source_paths),
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--preset", type=Path)
    parser.add_argument("--godot", type=Path, help="also verify the installed Godot build")
    parser.add_argument("--stage", type=Path, help="prepare an empty, allowlisted export project")
    parser.add_argument("--inspect-zip", type=Path, help="certify an actual Godot export ZIP")
    parser.add_argument("--json", action="store_true", help="emit a machine-readable summary")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    root = args.root.resolve()
    policy = args.policy.resolve() if args.policy else None
    preset = args.preset.resolve() if args.preset else None
    try:
        if args.stage:
            summary = prepare_stage(args.stage, root, policy_path=policy, preset_path=preset)
            if args.godot:
                _check_engine(args.godot.resolve(), summary.engine_build)
        else:
            summary = validate_repository(
                root,
                policy_path=policy,
                preset_path=preset,
                godot_binary=args.godot,
            )
        result: dict[str, Any] = {"repository": summary.as_dict()}
        if args.inspect_zip:
            result["archive"] = inspect_export_zip(
                args.inspect_zip.resolve(), root, policy_path=policy
            )
    except DedicatedExportError as exc:
        print(f"DUEL_DEDICATED_EXPORT_INVALID: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(
            "DUEL_DEDICATED_EXPORT_OK "
            f"engine={summary.engine_build} "
            f"authority_scripts={summary.authority_script_count} "
            f"protocol_files={summary.protocol_file_count}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
