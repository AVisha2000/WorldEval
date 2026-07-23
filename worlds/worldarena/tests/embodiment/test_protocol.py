from __future__ import annotations

import json

import pytest
from genesis_arena.embodiment import (
    CapabilityStatus,
    ControllerAction,
    ControllerButtons,
    ControllerState,
    EmbodimentProtocolPackage,
    EpisodeConfig,
    ProtocolValidationError,
    canonical_hmac_sha256,
    canonical_json_bytes,
    canonical_sha256,
)
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


@pytest.fixture(scope="module")
def package() -> EmbodimentProtocolPackage:
    return EmbodimentProtocolPackage.from_repository(ROOT)


def valid_action() -> dict:
    return {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": "ep_orientation_001",
        "observation_seq": 0,
        "action_id": "turn_toward_beacon",
        "control": {
            "move_x": 0,
            "move_y": 600,
            "look_x": -250,
            "look_y": 0,
            "duration_ticks": 10,
            "buttons": {
                "interact": False,
                "primary": False,
                "guard": False,
                "dash": False,
                "ability_1": False,
                "ability_2": False,
                "cycle_item": False,
                "cancel": False,
            },
        },
        "intent_label": "Turn left while approaching the beacon.",
        "memory_update": "The beacon was ahead-left and near.",
    }


def test_manifest_is_valid_and_declares_the_staged_scope(
    package: EmbodimentProtocolPackage,
) -> None:
    manifest = package.manifest
    assert manifest["environment_id"] == "worldarena-embodiment-v0"
    assert [mode["participants"] for mode in manifest["modes"]] == [1, 2, 2]
    assert manifest["controller"]["profile"] == "direct-controller-v1"
    assert manifest["constraints"]["semantic_world_commands_exposed"] is False
    assert manifest["timing"]["scored_duel_window_ticks"] == 10
    assert manifest["capabilities"] == CapabilityStatus(
        implemented_modes=("solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0"),
        implemented_observation_profiles=("hybrid-visible-v1",),
        implemented_tasks=(
            "orientation-v0",
            "interaction-v0",
            "construction-v0",
            "neutral-encounter-v0",
            "central-relay-v0",
        ),
        certified_modes=(),
        certified_observation_profiles=(),
        scored_observation_profiles=(),
    ).as_dict()
    package.validate("capability-status", CapabilityStatus().as_dict())
    package.validate(
        "episode-config",
        EpisodeConfig(
            episode_id="ep_manifest_config",
            mode="solo-curriculum-v0",
            task_id="orientation-v0",
            seed=17,
        ).as_dict(),
    )
    assert package.verify_lock()["package_sha256"] == package.package_sha256


def test_direct_controller_action_accepts_only_physical_input(
    package: EmbodimentProtocolPackage,
) -> None:
    action = valid_action()
    package.validate("controller-action", action)
    action["move_to"] = {"x": 12, "y": 9}
    with pytest.raises(ProtocolValidationError):
        package.validate("controller-action", action)


def test_action_parser_rejects_duplicate_keys(package: EmbodimentProtocolPackage) -> None:
    raw = json.dumps(valid_action(), separators=(",", ":")).encode()
    duplicate = raw[:-1] + b',"action_id":"replacement"}'
    with pytest.raises(ProtocolValidationError, match="duplicate key"):
        package.parse_and_validate("controller-action", duplicate, byte_limit=4096)


def test_integer_only_canonical_json_hashing_and_hmac_are_stable() -> None:
    first = {"z": 1, "a": {"enabled": True, "items": [3, 2, 1]}}
    second = {"a": {"items": [3, 2, 1], "enabled": True}, "z": 1}
    expected = b'{"a":{"enabled":true,"items":[3,2,1]},"z":1}'
    assert canonical_json_bytes(first) == canonical_json_bytes(second) == expected
    assert canonical_sha256(first) == canonical_sha256(second)
    assert canonical_hmac_sha256(b"phase-zero-test-key", "checkpoint", first) == (
        canonical_hmac_sha256(b"phase-zero-test-key", "checkpoint", second)
    )
    assert canonical_hmac_sha256(b"phase-zero-test-key", "checkpoint", first) != (
        canonical_hmac_sha256(b"phase-zero-test-key", "event", first)
    )
    with pytest.raises(ProtocolValidationError, match="floating-point"):
        canonical_json_bytes({"bad": 1.0})
    with pytest.raises(ProtocolValidationError, match="interoperable range"):
        canonical_json_bytes({"bad": 9_007_199_254_740_992})
    with pytest.raises(ProtocolValidationError, match="NFC"):
        canonical_json_bytes({"bad": "Cafe\u0301"})


def test_python_and_godot_checkpoint_fixture_hash_match() -> None:
    checkpoint = {
        "beacon_hold_ticks": 0,
        "beacon_position_mt": [0, -7000],
        "contact": "clear",
        "episode_id": "ep_hash_fixture",
        "event_seq": 0,
        "look_accumulator": 0,
        "maximum_episode_ticks": 600,
        "mode": "solo-curriculum-v0",
        "observation_profile": "text-visible-v1",
        "observation_seq": 0,
        "operator_heading": 0,
        "operator_position_mt": [0, 7000],
        "participant_ids": ["participant_0"],
        "task_id": "orientation-v0",
        "terminal": {"ended": False, "outcome": "running", "reason": "running"},
        "tick": 0,
    }
    assert canonical_sha256(checkpoint) == (
        "252bf04813da94df02986249451b1c334aaa7741b83868f7273e2459854cf8bf"
    )


def test_controller_types_match_the_wire_contract(package: EmbodimentProtocolPackage) -> None:
    control = ControllerState(
        move_x=0,
        move_y=600,
        look_x=-250,
        look_y=0,
        duration_ticks=10,
        buttons=ControllerButtons(),
    )
    action = ControllerAction(
        episode_id="ep_orientation_001",
        observation_seq=0,
        action_id="turn_toward_beacon",
        control=control,
        intent_label="Turn left while approaching the beacon.",
        memory_update="The beacon was ahead-left and near.",
    )
    package.validate("controller-action", action.as_dict())
    with pytest.raises(ValueError, match="move_x"):
        ControllerState(1001, 0, 0, 0, 10)
    multibyte = valid_action()
    multibyte["memory_update"] = "é" * 1025
    with pytest.raises(ProtocolValidationError, match="2048 UTF-8 bytes"):
        package.validate("controller-action", multibyte)


def test_episode_participant_count_is_mode_specific() -> None:
    EpisodeConfig(
        episode_id="ep_solo_001",
        mode="solo-curriculum-v0",
        task_id="orientation-v0",
        seed=7,
    )
    with pytest.raises(ValueError, match="requires 2"):
        EpisodeConfig(
            episode_id="ep_duel_001",
            mode="model-duel-v0",
            task_id="central-relay-v0",
            seed=7,
            participant_ids=("participant_0",),
        )


def test_minimal_text_observation_validates(package: EmbodimentProtocolPackage) -> None:
    observation = {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": "ep_orientation_001",
        "observation_seq": 0,
        "tick": 0,
        "profile": "text-visible-v1",
        "goal": "Reach and hold the visible beacon.",
        "remaining_ticks": 600,
        "self": {
            "health_percent": 100,
            "energy_percent": 100,
            "facing": "north",
            "contact": "clear",
            "inventory": [],
            "status": [],
        },
        "visible_entities": [
            {
                "id": "v_beacon_1",
                "kind": "beacon",
                "bearing": "front_left",
                "distance": "medium",
                "affordances": ["goal"],
                "state": "active",
            }
        ],
        "recent_events": [],
        "previous_receipt": None,
        "memory": "",
        "terminal": {"ended": False, "outcome": "running", "reason": "episode_active"},
    }
    package.validate("observation", observation)
