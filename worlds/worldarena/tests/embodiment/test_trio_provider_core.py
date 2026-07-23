from __future__ import annotations

import json

import pytest
from backend.genesis_arena.embodiment.protocol import canonical_json_bytes
from backend.genesis_arena.embodiment.providers.contracts import ProviderRequest
from backend.genesis_arena.embodiment.trio_games.common import (
    PROTOCOL_VERSION,
    TRIO_ACTION_SCHEMA_JSON,
    parse_trio_action,
    parse_visible_observation,
)
from backend.genesis_arena.embodiment.trio_games.demo_provider import (
    build_trio_demo_controller,
)


def _request(
    *,
    model: str,
    participant_id: str = "participant_0",
    seq: int = 0,
    entities: list[dict[str, object]] | None = None,
    extra: dict[str, object] | None = None,
) -> ProviderRequest:
    observation = {
        "episode_id": "ep_trio_test",
        "observation_seq": seq,
        "participant_id": participant_id,
        "profile": "text-visible-v1",
        "protocol_version": PROTOCOL_VERSION,
        "visible_entities": entities or [],
        **(extra or {}),
    }
    return ProviderRequest(
        episode_id="ep_trio_test",
        participant_id=participant_id,
        observation_seq=seq,
        deadline_monotonic_ns=10_000,
        model=model,
        system_prompt="WorldArena trio controller",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=TRIO_ACTION_SCHEMA_JSON,
        max_output_bytes=4096,
    )


def _entities() -> list[dict[str, object]]:
    return [
        {
            "id": "v_relay_b",
            "kind": "relay",
            "bearing": "front",
            "distance": "touching",
            "affordances": ["capture"],
        },
        {
            "id": "v_enemy_a",
            "kind": "operator",
            "bearing": "front",
            "distance": "near",
            "affordances": ["attack"],
        },
        {
            "id": "v_relay_a",
            "kind": "relay",
            "bearing": "left",
            "distance": "medium",
            "affordances": ["capture"],
        },
    ]


@pytest.mark.asyncio
@pytest.mark.parametrize("task_id", ["trio-relay-v0", "trio-free-for-all-v0"])
@pytest.mark.parametrize(
    ("model", "expected_button"),
    [
        ("demo-sol-v1", "interact"),
        ("demo-luna-v1", "guard"),
        ("demo-terra-v1", "primary"),
    ],
)
async def test_demo_policies_emit_strict_v3_fixed_windows_deterministically(
    task_id: str, model: str, expected_button: str
) -> None:
    first = build_trio_demo_controller(
        task_id=task_id,
        model=model,
        participant_id="participant_0",
        seed=44,
        decision_budget=4,
    )
    second = build_trio_demo_controller(
        task_id=task_id,
        model=model,
        participant_id="participant_0",
        seed=44,
        decision_budget=4,
    )
    first_result = await first.decide(_request(model=model, entities=_entities()))
    second_result = await second.decide(
        _request(model=model, entities=list(reversed(_entities())))
    )

    assert first.policy_lock.sha256 == second.policy_lock.sha256
    assert first.provider_name == "demo"
    assert first.requires_credential is False
    assert first.is_networked is False
    assert first_result == second_result
    assert first_result.disposition == "accepted"
    assert first_result.action.protocol_version == PROTOCOL_VERSION
    assert first_result.action.control.duration_ticks == 10
    assert getattr(first_result.action.control.buttons, expected_button) is True
    encoded = canonical_json_bytes(first_result.action.as_dict())
    assert parse_trio_action(encoded, _request(model=model, entities=_entities())) == (
        first_result.action
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("fixture_mode", "reason"),
    [
        ("invalid", "invalid_response"),
        ("malformed", "invalid_response"),
        ("stale", "stale_observation"),
        ("oversized", "output_too_large"),
        ("refused", "provider_refusal"),
        ("timeout", "timeout"),
    ],
)
async def test_each_invalid_provider_fixture_becomes_a_ten_tick_neutral_window(
    fixture_mode: str, reason: str
) -> None:
    controller = build_trio_demo_controller(
        task_id="trio-relay-v0",
        model="demo-sol-v1",
        participant_id="participant_0",
        seed=9,
        decision_budget=2,
        fixture_mode=fixture_mode,  # type: ignore[arg-type]
    )
    result = await controller.decide(
        _request(model="demo-sol-v1", entities=_entities())
    )
    assert result.disposition == "no_input"
    assert result.reason == reason
    assert result.provider_called is True
    assert result.action.control.duration_ticks == 10
    assert result.action.control == result.action.control.neutral(10)


@pytest.mark.asyncio
async def test_budget_exhaustion_is_neutral_and_does_not_increment_call_count() -> None:
    controller = build_trio_demo_controller(
        task_id="trio-free-for-all-v0",
        model="demo-terra-v1",
        participant_id="participant_2",
        seed=8,
        decision_budget=1,
    )
    accepted = await controller.decide(
        _request(model="demo-terra-v1", participant_id="participant_2", entities=_entities())
    )
    exhausted = await controller.decide(
        _request(
            model="demo-terra-v1",
            participant_id="participant_2",
            seq=1,
            entities=_entities(),
        )
    )
    assert accepted.disposition == "accepted"
    assert exhausted.disposition == "no_input"
    assert exhausted.reason == "invalid_response"
    assert controller.decision_count == 1
    assert controller.provider_calls == 2


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("participant_id", "model"),
    [
        ("participant_0", "demo-sol-v1"),
        ("participant_1", "demo-luna-v1"),
        ("participant_2", "demo-terra-v1"),
    ],
)
async def test_invalid_input_falls_back_independently_for_each_of_three_seats(
    participant_id: str, model: str
) -> None:
    controller = build_trio_demo_controller(
        task_id="trio-relay-v0",
        model=model,
        participant_id=participant_id,
        seed=3,
        decision_budget=2,
        fixture_mode="malformed",
    )
    result = await controller.decide(
        _request(model=model, participant_id=participant_id, entities=_entities())
    )
    assert result.disposition == "no_input"
    assert result.action.control.duration_ticks == 10
    assert result.action.control == result.action.control.neutral(10)


@pytest.mark.asyncio
async def test_elimination_permanently_stops_calls_with_deterministic_dispositions() -> None:
    controller = build_trio_demo_controller(
        task_id="trio-free-for-all-v0",
        model="demo-luna-v1",
        participant_id="participant_1",
        seed=1,
        decision_budget=8,
    )
    live = await controller.decide(
        _request(model="demo-luna-v1", participant_id="participant_1", entities=_entities())
    )
    eliminated = await controller.decide(
        _request(model="demo-luna-v1", participant_id="participant_1", seq=1),
        eliminated=True,
    )
    remains_eliminated = await controller.decide(
        _request(model="demo-luna-v1", participant_id="participant_1", seq=2),
        eliminated=False,
    )
    assert live.disposition == "accepted"
    assert eliminated.disposition == remains_eliminated.disposition == "eliminated"
    assert eliminated.action.control == eliminated.action.control.neutral(10)
    assert remains_eliminated.action.action_id == "neutral_2_eliminated"
    assert controller.decision_count == 1
    assert controller.provider_calls == 1
    assert controller.suppressed_eliminated_calls == 2


def test_visible_parser_rejects_private_or_protected_semantics_at_any_depth() -> None:
    request = _request(
        model="demo-sol-v1",
        extra={"recent_events": [{"summary": {"coordinates": [1, 2]}}]},
    )
    with pytest.raises(ValueError, match="protected trio semantics"):
        parse_visible_observation(request)


def test_action_parser_rejects_wrong_duration_extra_fields_and_boolean_integers() -> None:
    request = _request(model="demo-sol-v1")
    action = {
        "protocol_version": PROTOCOL_VERSION,
        "episode_id": request.episode_id,
        "observation_seq": 0,
        "action_id": "bad",
        "control": {
            "move_x": 0,
            "move_y": 0,
            "look_x": 0,
            "look_y": 0,
            "duration_ticks": 9,
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
        "intent_label": "",
        "memory_update": "",
    }
    with pytest.raises(ValueError, match="duration_ticks"):
        parse_trio_action(canonical_json_bytes(action), request)
    action["control"]["duration_ticks"] = 10  # type: ignore[index]
    action["control"]["move_x"] = True  # type: ignore[index]
    with pytest.raises(ValueError, match="move_x"):
        parse_trio_action(canonical_json_bytes(action), request)
    action["control"]["move_x"] = 0  # type: ignore[index]
    action["credential"] = "never"
    with pytest.raises(ValueError, match="invalid fields"):
        parse_trio_action(canonical_json_bytes(action), request)

    serialized = json.dumps(action)
    assert "raw_model_output" not in serialized
