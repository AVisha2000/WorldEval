from __future__ import annotations

import copy

import pytest
from genesis_arena.embodiment.golden import (
    GoldenTranscriptError,
    load_golden_transcript,
    seal_golden_body,
    verify_golden_bytes,
    verify_runtime_output,
)
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_json_bytes
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GOLDEN_ROOT = ROOT / "game" / "embodiment_protocol" / "golden"
GOLDEN = GOLDEN_ROOT / "stage-a-orientation-forward-v1.json"
EXPECTED = {
    "stage-a-orientation-forward-v1": {
        "steps": 4,
        "tick": 73,
        "reason": "beacon_held",
        "state_hash": "b688ad7bebc14fccd6e6a6fbe433a466982d2c443c04be9b91ebef6b51291ed2",
        "seal": "651a4758951f10889ce3da2da7a0b637b0c476e0eb337f82a340a55bfc1eeac0",
        "events": ("beacon_entered", "episode_succeeded"),
    },
    "stage-b-interaction-v1": {
        "steps": 9,
        "tick": 95,
        "reason": "resource_deposited",
        "state_hash": "1fef6dd88c409e411b66fff930298a42b2cdf2852e2dcf4fe5b50663f3bf8b7a",
        "seal": "ff62941364a3a0182cfa51fd8be4e1858e912a90153841b1231d7f98aac6181c",
        "events": (
            "gathering_progressed",
            "gathering_progressed",
            "gathering_progressed",
            "gathering_progressed",
            "resource_gathered",
            "material_deposited",
            "episode_succeeded",
        ),
    },
    "stage-c-construction-v1": {
        "steps": 19,
        "tick": 125,
        "reason": "barricade_built",
        "state_hash": "5fb0bf0ab8cd3740867b1f5c1b0c7c1e7a43ee17c36a3d0a4324d5adccc79cbc",
        "seal": "42de7307ba50369124149687b372a279028d50465296a1f8327ec1e50b38e480",
        "events": (
            "interaction_misaligned",
            *("gathering_progressed",) * 4,
            "resource_gathered",
            *("gathering_progressed",) * 4,
            "resource_gathered",
            "material_deposited",
            *("construction_progressed",) * 3,
            "construction_interrupted",
            *("construction_progressed",) * 3,
            "barricade_completed",
            "episode_succeeded",
        ),
    },
    "stage-d-neutral-encounter-v1": {
        "steps": 9,
        "tick": 50,
        "reason": "relay_activated",
        "state_hash": "0069801cdfc4a468fef07ebea6388deabd1e9e376897d5346d382a1cd9e225ce",
        "seal": "637787ffc62fd7ff30c14f4c147ad2f17ac49d9dd091f23c0e4de6fc620ac559",
        "events": (
            "neutral_state_changed",
            "neutral_state_changed",
            "primary_hit",
            "neutral_damaged",
            "neutral_state_changed",
            "operator_damaged",
            "neutral_state_changed",
            "primary_hit",
            "neutral_damaged",
            "neutral_state_changed",
            "primary_hit",
            "neutral_damaged",
            "neutral_state_changed",
            "relay_activated",
            "episode_succeeded",
        ),
    },
}


def _package() -> EmbodimentProtocolPackage:
    # The fixture itself becomes a locked package artifact when the package lock is regenerated.
    return EmbodimentProtocolPackage.from_repository(ROOT, verify_lock=False)


@pytest.mark.parametrize("transcript_id", EXPECTED)
def test_curriculum_golden_is_canonical_schema_valid_and_complete(transcript_id: str) -> None:
    transcript = load_golden_transcript(GOLDEN_ROOT / f"{transcript_id}.json", package=_package())
    expected = EXPECTED[transcript_id]

    assert transcript["transcript_id"] == transcript_id
    assert len(transcript["steps"]) == expected["steps"]
    assert transcript["terminal_boundary"]["terminal"]["reason"] == expected["reason"]
    assert transcript["terminal_boundary"]["state_hash"] == expected["state_hash"]
    assert transcript["transcript_sha256"] == expected["seal"]
    final_observation = transcript["steps"][-1]["result"]["observations"]["participant_0"]
    assert final_observation["tick"] == expected["tick"]
    assert [
        event["kind"]
        for step in transcript["steps"]
        for event in step["result"]["public_events"]
    ] == list(expected["events"])

    forbidden = {
        "beacon_position_mt",
        "checkpoint",
        "health",
        "operator_position_mt",
        "progress_ticks",
        "relay_activation_ticks",
        "required_ticks",
        "resource_units_remaining",
        "spectator",
        "target_health",
    }
    observations = [transcript["initial_boundary"]["observations"]]
    observations.extend(step["result"]["observations"] for step in transcript["steps"])
    public_events = [
        event
        for step in transcript["steps"]
        for event in step["result"]["public_events"]
    ]
    assert all(
        not (forbidden & _nested_keys(payload))
        for group in observations
        for payload in group.values()
    )
    assert all(not (forbidden & _nested_keys(event)) for event in public_events)
    assert all(
        not any(character.isdigit() for character in entity["state"])
        for group in observations
        for observation in group.values()
        for entity in observation["visible_entities"]
    )


def test_golden_seal_and_nested_event_digest_are_independently_tamper_evident() -> None:
    original = load_golden_transcript(GOLDEN, package=_package())
    changed = copy.deepcopy(original)
    changed["steps"][-1]["result"]["public_events"][0]["summary"] = "Changed."
    with pytest.raises(GoldenTranscriptError, match="seal"):
        verify_golden_bytes(canonical_json_bytes(changed) + b"\n", package=_package())

    body = {key: value for key, value in changed.items() if key != "transcript_sha256"}
    resealed = seal_golden_body(body)
    with pytest.raises(GoldenTranscriptError, match="event-sequence digest"):
        verify_golden_bytes(canonical_json_bytes(resealed) + b"\n", package=_package())


def test_golden_exact_shapes_reject_hidden_authority_state_even_when_resealed() -> None:
    original = load_golden_transcript(GOLDEN, package=_package())
    changed = copy.deepcopy(original)
    changed["steps"][0]["result"]["checkpoint"] = {"operator_position_mt": [0, 3000]}
    body = {key: value for key, value in changed.items() if key != "transcript_sha256"}

    with pytest.raises(GoldenTranscriptError, match="step-result schema validation"):
        verify_golden_bytes(
            canonical_json_bytes(seal_golden_body(body)) + b"\n", package=_package()
        )


def test_runtime_comparison_binds_every_window_and_exact_result() -> None:
    transcript = load_golden_transcript(GOLDEN, package=_package())
    initial = transcript["initial_boundary"]
    runtime_steps = [
        {"decision_window": step["decision_window"], "result": step["result"]}
        for step in transcript["steps"]
    ]
    verify_runtime_output(
        transcript,
        config=transcript["config"],
        initial_observations=initial["observations"],
        initial_state_hash=initial["state_hash"],
        steps=runtime_steps,
    )

    changed_steps = copy.deepcopy(runtime_steps)
    changed_steps[1]["result"]["state_hash"] = "0" * 64
    with pytest.raises(GoldenTranscriptError, match="runtime result 1 differs"):
        verify_runtime_output(
            transcript,
            config=transcript["config"],
            initial_observations=initial["observations"],
            initial_state_hash=initial["state_hash"],
            steps=changed_steps,
        )


def _nested_keys(value: object) -> set[str]:
    if isinstance(value, dict):
        output = set(value)
        for child in value.values():
            output.update(_nested_keys(child))
        return output
    if isinstance(value, list):
        output: set[str] = set()
        for child in value:
            output.update(_nested_keys(child))
        return output
    return set()
