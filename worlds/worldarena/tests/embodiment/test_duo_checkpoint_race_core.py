from __future__ import annotations

import pytest
from genesis_arena.embodiment.duo_games.checkpoint_race import (
    build_checkpoint_race_demo_provider,
    evaluate_checkpoint_race,
)
from genesis_arena.embodiment.live_solo import parse_controller_action
from genesis_arena.embodiment.protocol import ProtocolValidationError, canonical_json_bytes
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.providers.contracts import ProviderFailureKind, ProviderRequest
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
PACKAGE = EmbodimentProtocolRegistry.from_repository(ROOT).package("llm-controller/0.2.0")


def _observation(*, reverse: bool = False, protected: bool = False) -> dict[str, object]:
    entities = [
        {
            "id": "v_checkpoint_2",
            "kind": "checkpoint",
            "state": "next_in_order",
            "bearing": "front_right",
            "distance": "medium",
            "affordances": ["race_target"],
        },
        {
            "id": "v_rival_0",
            "kind": "operator",
            "state": "active",
            "bearing": "left",
            "distance": "far",
            "affordances": ["hostile"],
        },
    ]
    if reverse:
        entities.reverse()
        entities = [dict(reversed(tuple(entity.items()))) for entity in entities]
    value: dict[str, object] = {
        "protocol_version": "llm-controller/0.2.0",
        "episode_id": "ep_duo_race",
        "observation_seq": 4,
        "profile": "text-visible-v1",
        "visible_entities": entities,
    }
    if protected:
        value["spectator_state"] = {"position_mt": [0, 0]}
    return value


def _request(observation: dict[str, object]) -> ProviderRequest:
    return ProviderRequest(
        episode_id="ep_duo_race",
        participant_id="participant_0",
        observation_seq=4,
        deadline_monotonic_ns=1,
        model="checkpoint-racer-alpha-v1",
        system_prompt="Use only participant-visible race semantics and return strict JSON.",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes(PACKAGE.schema("controller-action")),
    )


@pytest.mark.asyncio
async def test_race_policy_is_repeatable_arrival_order_invariant_and_v2_strict() -> None:
    first = build_checkpoint_race_demo_provider(
        model="checkpoint-racer-alpha-v1",
        participant_id="participant_0",
        seed=71,
        decision_budget=2,
    )
    repeat = build_checkpoint_race_demo_provider(
        model="checkpoint-racer-alpha-v1",
        participant_id="participant_0",
        seed=71,
        decision_budget=2,
    )

    first_result = await first.request(_request(_observation()))
    repeat_result = await repeat.request(_request(_observation(reverse=True)))

    assert first.policy_lock == repeat.policy_lock
    assert first_result.raw_output == repeat_result.raw_output
    action = parse_controller_action(first_result.raw_output or b"", package=PACKAGE)
    assert action.protocol_version == "llm-controller/0.2.0"
    assert action.control.duration_ticks == 10
    assert action.control.look_x == 1000
    serialized = (first_result.raw_output or b"").decode("utf-8")
    assert "v_checkpoint_2" not in serialized
    assert "v_rival_0" not in serialized


@pytest.mark.asyncio
async def test_race_invalid_fixture_budget_and_protected_observation_fail_closed() -> None:
    invalid = build_checkpoint_race_demo_provider(
        model="checkpoint-racer-alpha-v1",
        participant_id="participant_0",
        seed=2,
        decision_budget=1,
        fixture_mode="invalid",
    )
    result = await invalid.request(_request(_observation()))
    with pytest.raises(ProtocolValidationError):
        parse_controller_action(result.raw_output or b"", package=PACKAGE)
    exhausted = await invalid.request(_request(_observation()))
    assert exhausted.failure is ProviderFailureKind.INVALID_RESPONSE

    protected = build_checkpoint_race_demo_provider(
        model="checkpoint-racer-alpha-v1",
        participant_id="participant_0",
        seed=2,
        decision_budget=1,
    )
    assert (await protected.request(_request(_observation(protected=True)))).failure is (
        ProviderFailureKind.INTERNAL
    )


def _evaluation(**updates: object) -> dict[str, object]:
    value: dict[str, object] = {
        "completion_tick": 420,
        "terminal_outcome": "win",
        "terminal_reason": "finish",
        "checkpoint_total": 5,
        "participants": {
            "participant_0": {
                "outcome": "win",
                "decision_windows": 42,
                "fallback_windows": 1,
                "checkpoints_reached": 5,
            },
            "participant_1": {
                "outcome": "loss",
                "decision_windows": 42,
                "fallback_windows": 2,
                "checkpoints_reached": 4,
            },
        },
    }
    value.update(updates)
    return value


def test_race_evaluation_is_allowlisted_private_free_and_mapping_order_invariant() -> None:
    value = _evaluation()
    result = evaluate_checkpoint_race(value)
    reversed_value = dict(reversed(tuple(value.items())))
    participants = value["participants"]
    assert isinstance(participants, dict)
    reversed_value["participants"] = dict(reversed(tuple(participants.items())))

    assert evaluate_checkpoint_race(reversed_value) == result
    assert result["completion"] == {"tick": 420, "outcome": "win", "reason": "finish"}
    assert result["symmetry"] == {
        "decision_window_delta": 0,
        "fallback_window_delta": 1,
        "equal_decision_windows": True,
        "checkpoint_progress_delta": 1,
    }
    serialized = repr(result).casefold()
    for forbidden in (
        "coordinate",
        "position",
        "spectator",
        "prompt",
        "raw_output",
        "credential",
        "opponent_observation",
    ):
        assert forbidden not in serialized


@pytest.mark.parametrize(
    "value",
    (
        _evaluation(position_mt={"x": 0, "y": 0}),
        _evaluation(checkpoint_total=True),
        _evaluation(terminal_outcome="draw"),
        _evaluation(
            participants={
                "participant_0": {
                    "outcome": "win",
                    "decision_windows": 1,
                    "fallback_windows": 2,
                    "checkpoints_reached": 5,
                },
                "participant_1": {
                    "outcome": "loss",
                    "decision_windows": 1,
                    "fallback_windows": 0,
                    "checkpoints_reached": 4,
                },
            }
        ),
    ),
)
def test_race_evaluation_rejects_protected_or_inconsistent_aggregates(value: object) -> None:
    with pytest.raises(ValueError):
        evaluate_checkpoint_race(value)  # type: ignore[arg-type]
