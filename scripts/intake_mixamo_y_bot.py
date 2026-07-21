#!/usr/bin/env python3
"""Create a reviewed, content-addressed Mixamo Y Bot intake manifest.

This command never downloads or copies Adobe-hosted content. The reviewer must first place the
approved base FBX, animation-only clips, and integrated Godot scene inside the repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

try:
    from scripts.run_embodiment_mvp_certification import (
        REQUIRED_Y_BOT_CLIPS,
        ROOT,
        Y_BOT_FORMAT,
        Y_BOT_MANIFEST,
        validate_y_bot_intake,
    )
except ModuleNotFoundError:  # Direct `python scripts/...` execution.
    from run_embodiment_mvp_certification import (  # type: ignore[no-redef]
        REQUIRED_Y_BOT_CLIPS,
        ROOT,
        Y_BOT_FORMAT,
        Y_BOT_MANIFEST,
        validate_y_bot_intake,
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _repository_file(value: str, *, suffix: str | None = None) -> Path:
    path = Path(value).expanduser().resolve()
    root = ROOT.resolve()
    if not path.is_file():
        raise ValueError(f"reviewed file is unavailable: {path}")
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise ValueError("reviewed files must already be inside the repository") from error
    if suffix is not None and path.suffix.lower() != suffix:
        raise ValueError(f"reviewed file must use the {suffix} suffix")
    if "\x00" in relative.as_posix():
        raise ValueError("reviewed file path is invalid")
    return path


def _clips(values: list[str]) -> dict[str, Path]:
    output: dict[str, Path] = {}
    for value in values:
        name, separator, raw_path = value.partition("=")
        if not separator or name not in REQUIRED_Y_BOT_CLIPS or name in output:
            raise ValueError("each --clip must be one unique required name=path pair")
        output[name] = _repository_file(raw_path, suffix=".fbx")
    missing = sorted(REQUIRED_Y_BOT_CLIPS - set(output))
    if missing:
        raise ValueError(f"missing required clips: {', '.join(missing)}")
    return output


def build_manifest(arguments: argparse.Namespace) -> dict:
    base = _repository_file(arguments.base, suffix=".fbx")
    scene = _repository_file(arguments.presentation_scene, suffix=".tscn")
    clip_paths = _clips(arguments.clip)
    for path in (base, *clip_paths.values()):
        relative = path.relative_to(ROOT.resolve()).as_posix()
        if not relative.startswith("godot/assets/external/mixamo/"):
            raise ValueError("Y Bot FBX files must be under godot/assets/external/mixamo/")
    return {
        "asset_identity": "mixamo-y-bot",
        "base": {
            "path": base.relative_to(ROOT.resolve()).as_posix(),
            "sha256": _sha256(base),
        },
        "clips": {
            name: {
                "animation_only": True,
                "path": path.relative_to(ROOT.resolve()).as_posix(),
                "sha256": _sha256(path),
            }
            for name, path in sorted(clip_paths.items())
        },
        "format": Y_BOT_FORMAT,
        "human_approved": True,
        "presentation_scene": {
            "path": scene.relative_to(ROOT.resolve()).as_posix(),
            "sha256": _sha256(scene),
        },
        "review": {
            "downloaded_at": arguments.downloaded_at,
            "export_settings": {
                "character": "Y Bot",
                "clips_without_skin": True,
                "format": "FBX Binary",
                "pose": "T-pose",
                "with_skin": True,
            },
            "license_terms": arguments.license_terms,
            "reviewed_at": arguments.reviewed_at,
            "reviewer": arguments.reviewer,
            "source_url": arguments.source_url,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--clip", action="append", default=[], metavar="NAME=PATH")
    parser.add_argument("--presentation-scene", required=True)
    parser.add_argument("--reviewer", required=True)
    parser.add_argument("--downloaded-at", required=True, help="UTC timestamp ending in Z")
    parser.add_argument("--reviewed-at", required=True, help="UTC timestamp ending in Z")
    parser.add_argument("--source-url", required=True, help="Reviewed HTTPS mixamo.com URL")
    parser.add_argument("--license-terms", required=True)
    parser.add_argument("--output", type=Path, default=Y_BOT_MANIFEST)
    arguments = parser.parse_args()
    try:
        manifest = build_manifest(arguments)
        output = arguments.output.resolve()
        if output != Y_BOT_MANIFEST.resolve():
            raise ValueError("the approved manifest must use the canonical repository path")
        if output.exists():
            raise ValueError("refusing to overwrite an existing approved intake manifest")
        encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
        output.write_text(encoded, encoding="utf-8")
        gate = validate_y_bot_intake(output)
        if gate.get("passed") is not True:
            output.unlink(missing_ok=True)
            raise ValueError(f"intake validation failed: {gate.get('code', 'unknown')}")
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))
    print(f"Y_BOT_INTAKE_OK manifest_sha256={gate['manifest_sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
