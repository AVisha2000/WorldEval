#!/usr/bin/env python3
"""Render one verified WorldArena replay as a participant-only release MP4."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from genesis_arena.embodiment.native_media import (
    NativeMediaError,
    render_verified_participant_video,
)
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
DEFAULT_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
Y_BOT_MANIFEST = ROOT / "godot/assets/external/mixamo/approved-y-bot.manifest.json"


def _default_ffmpeg() -> Path:
    try:
        import imageio_ffmpeg

        return Path(imageio_ffmpeg.get_ffmpeg_exe())
    except (ImportError, RuntimeError):
        discovered = shutil.which("ffmpeg")
        return Path(discovered) if discovered else ROOT / ".video-tools/ffmpeg"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--participant", default="participant_0")
    parser.add_argument("--showcase", choices=("solo", "duo", "trio"), required=True)
    parser.add_argument("--scenario-id")
    parser.add_argument("--godot", type=Path, default=DEFAULT_GODOT)
    parser.add_argument("--ffmpeg", type=Path, default=_default_ffmpeg())
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        try:
            from scripts.run_embodiment_mvp_certification import validate_y_bot_intake
        except ModuleNotFoundError:
            from run_embodiment_mvp_certification import validate_y_bot_intake

        y_bot = validate_y_bot_intake(Y_BOT_MANIFEST, repository_root=ROOT)
        if y_bot.get("passed") is not True:
            raise NativeMediaError("approved Y Bot intake gate failed")
        result = render_verified_participant_video(
            repository_root=ROOT,
            replay_path=arguments.replay,
            output_path=arguments.output,
            participant_id=arguments.participant,
            godot_executable=arguments.godot,
            ffmpeg_executable=arguments.ffmpeg,
            y_bot_manifest_sha256=str(y_bot["manifest_sha256"]),
            showcase=arguments.showcase,
            scenario_id=arguments.scenario_id,
        )
    except (NativeMediaError, OSError) as error:
        print(f"WORLDARENA_NATIVE_MEDIA_FAILED: {error}")
        return 2
    print(
        "WORLDARENA_NATIVE_MEDIA_OK "
        f"video={result.video_path} evidence={result.evidence_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
