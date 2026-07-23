from __future__ import annotations

import base64
import subprocess
from pathlib import Path

import pytest
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, strict_json_loads
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PREFIX = "EMBODIMENT_HYBRID_OBSERVATION_BASE64="


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_real_stage_c_hybrid_observation_is_schema_valid_and_player_scoped() -> None:
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/embodiment_hybrid_presentation_headless_runner.gd",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )
    encoded = next(
        line.removeprefix(PREFIX)
        for line in completed.stdout.splitlines()
        if line.startswith(PREFIX)
    )
    observation = strict_json_loads(base64.b64decode(encoded, validate=True))
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    package.validate("observation", observation)

    assert observation["profile"] == "hybrid-visible-v1"
    assert observation["frame"]["mime_type"] == "image/png"
    assert (observation["frame"]["width"], observation["frame"]["height"]) == (1280, 720)
    forbidden = {
        "operator_position_mt",
        "neutral_position_mt",
        "resource_position_mt",
        "relay_position_mt",
        "build_pad_position_mt",
        "authority_checkpoint_hash",
        "spectator",
    }
    assert not (_all_keys(observation) & forbidden)


def _all_keys(value: object) -> set[str]:
    if isinstance(value, dict):
        keys = set(value)
        for child in value.values():
            keys.update(_all_keys(child))
        return keys
    if isinstance(value, list):
        keys: set[str] = set()
        for child in value:
            keys.update(_all_keys(child))
        return keys
    return set()
