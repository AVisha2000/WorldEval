from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from genesis_arena.embodiment.duo_games.resource_relay import (
    RESOURCE_RELAY_OBJECTIVE_TARGET,
    build_resource_relay_demo_provider,
    evaluate_resource_relay,
)
from genesis_arena.embodiment.live_solo import parse_controller_action
from genesis_arena.embodiment.protocol import canonical_json_bytes
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.providers.contracts import ProviderFailureKind, ProviderRequest

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PACKAGE = EmbodimentProtocolRegistry.from_repository(ROOT).package("llm-controller/0.2.0")


def _observation(*, reverse: bool = False, carrying: bool = False) -> dict[str, object]:
    entities: list[dict[str, object]] = [
        {
            "id": "v_resource_alpha",
            "kind": "resource",
            "state": "available",
            "bearing": "front",
            "distance": "touching",
            "affordances": ["gather"],
        },
        {
            "id": "v_friendly_relay",
            "kind": "relay",
            "state": "active",
            "bearing": "front_left",
            "distance": "medium",
            "affordances": ["deposit"],
        },
    ]
    if reverse:
        entities = [dict(reversed(tuple(entity.items()))) for entity in reversed(entities)]
    return {
        "protocol_version": "llm-controller/0.2.0",
        "episode_id": "ep_resource_relay",
        "observation_seq": 4,
        "profile": "text-visible-v1",
        "self": {
            "inventory": [{"kind": "material", "count": 1, "selected": True}]
            if carrying
            else [],
            "status": ["carrying"] if carrying else [],
        },
        "visible_entities": entities,
    }


def _request(
    observation: dict[str, object],
    *,
    model: str = "resource-relay-alpha-v1",
    participant_id: str = "participant_0",
) -> ProviderRequest:
    return ProviderRequest(
        episode_id="ep_resource_relay",
        participant_id=participant_id,
        observation_seq=4,
        deadline_monotonic_ns=1,
        model=model,
        system_prompt="Use only participant-visible resource-relay semantics and strict JSON.",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes(PACKAGE.schema("controller-action")),
    )


@pytest.mark.asyncio
async def test_resource_relay_policy_is_repeatable_order_invariant_and_uses_visible_state() -> None:
    first = build_resource_relay_demo_provider(
        model="resource-relay-alpha-v1",
        participant_id="participant_0",
        seed=31,
        decision_budget=2,
    )
    repeat = build_resource_relay_demo_provider(
        model="resource-relay-alpha-v1",
        participant_id="participant_0",
        seed=31,
        decision_budget=2,
    )
    first_result = await first.request(_request(_observation()))
    repeat_result = await repeat.request(_request(_observation(reverse=True)))
    assert first.policy_lock == repeat.policy_lock
    assert first_result.raw_output == repeat_result.raw_output
    gather = parse_controller_action(first_result.raw_output or b"", package=PACKAGE)
    assert gather.control.duration_ticks == 10
    assert gather.control.buttons.interact is True

    carrier_result = await first.request(_request(_observation(carrying=True)))
    carrier = parse_controller_action(carrier_result.raw_output or b"", package=PACKAGE)
    assert carrier.control.buttons.interact is False
    assert carrier.control.look_x == -100
    raw = (carrier_result.raw_output or b"").decode("utf-8")
    assert "v_friendly_relay" not in raw


@pytest.mark.asyncio
async def test_resource_relay_policy_selects_mirrored_resources_in_participant_local_space(
) -> None:
    left = _observation()
    left["visible_entities"] = [
        {
            "id": "v_resource_0",
            "kind": "resource",
            "state": "available",
            "bearing": "front_left",
            "distance": "far",
            "affordances": ["gather"],
        },
        {
            "id": "v_resource_1",
            "kind": "resource",
            "state": "available",
            "bearing": "front_right",
            "distance": "far",
            "affordances": ["gather"],
        },
    ]
    mirrored = _observation()
    mirrored["visible_entities"] = [
        {
            "id": "v_resource_0",
            "kind": "resource",
            "state": "available",
            "bearing": "front_right",
            "distance": "far",
            "affordances": ["gather"],
        },
        {
            "id": "v_resource_1",
            "kind": "resource",
            "state": "available",
            "bearing": "front_left",
            "distance": "far",
            "affordances": ["gather"],
        },
    ]
    first = build_resource_relay_demo_provider(
        model="resource-relay-alpha-v1",
        participant_id="participant_0",
        seed=31,
        decision_budget=1,
    )
    second = build_resource_relay_demo_provider(
        model="resource-relay-alpha-v1",
        participant_id="participant_1",
        seed=31,
        decision_budget=1,
    )
    first_action = parse_controller_action(
        (await first.request(_request(left))).raw_output or b"", package=PACKAGE
    )
    second_action = parse_controller_action(
        (
            await second.request(
                _request(mirrored, participant_id="participant_1")
            )
        ).raw_output
        or b"",
        package=PACKAGE,
    )
    assert first_action.control == second_action.control
    assert first_action.control.look_x == -100


@pytest.mark.asyncio
async def test_resource_relay_warden_uses_only_visible_combat_build_and_defense_affordances(
) -> None:
    provider = build_resource_relay_demo_provider(
        model="resource-relay-bravo-v1",
        participant_id="participant_1",
        seed=32,
        decision_budget=30,
    )
    base = _observation()
    base["self"] = {"inventory": [], "status": []}
    base["visible_entities"] = [
        {
            "id": "v_rival",
            "kind": "operator",
            "state": "carrying",
            "bearing": "front",
            "distance": "near",
            "affordances": ["hostile"],
        }
    ]
    request = _request(
        base, model="resource-relay-bravo-v1", participant_id="participant_1"
    )
    # The warden completes its deterministic opening before combat is enabled, even when a
    # rival happens to appear early in its participant-visible camera.
    for _ in range(21):
        await provider.request(request)
    strike = parse_controller_action(
        (await provider.request(request)).raw_output or b"", package=PACKAGE
    )
    assert strike.control.buttons.primary is True
    assert strike.control.duration_ticks == 10

    # A visible fortified relay is sufficient for one bounded guard window.  No score,
    # transform, opponent observation, or hidden barricade health reaches the policy.
    fortified = _observation()
    fortified["self"] = {"inventory": [], "status": []}
    fortified["visible_entities"] = [
        {
            "id": "v_friendly_relay",
            "kind": "relay",
            "state": "fortified",
            "bearing": "front",
            "distance": "touching",
            "affordances": ["deposit"],
        }
    ]
    # The policy uses zero-based call indices; consume visible decisions until the bounded
    # post-opening sentinel window (index 21).
    guard_provider = build_resource_relay_demo_provider(
        model="resource-relay-bravo-v1",
        participant_id="participant_1",
        seed=32,
        decision_budget=30,
    )
    fortified_request = _request(
        fortified, model="resource-relay-bravo-v1", participant_id="participant_1"
    )
    for _ in range(21):
        await guard_provider.request(fortified_request)
    defend = parse_controller_action(
        (await guard_provider.request(fortified_request)).raw_output or b"",
        package=PACKAGE,
    )
    assert defend.control.buttons.guard is True


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("fixture_mode", "failure"),
    (
        ("timeout", ProviderFailureKind.TIMEOUT),
        ("refused", ProviderFailureKind.REFUSAL),
        ("oversized", ProviderFailureKind.OUTPUT_TOO_LARGE),
    ),
)
async def test_resource_relay_failure_fixtures_are_strict_and_budget_bounded(
    fixture_mode: str, failure: ProviderFailureKind
) -> None:
    provider = build_resource_relay_demo_provider(
        model="resource-relay-bravo-v1",
        participant_id="participant_1",
        seed=32,
        decision_budget=1,
        fixture_mode=fixture_mode,  # type: ignore[arg-type]
    )
    request = _request(
        _observation(), model="resource-relay-bravo-v1", participant_id="participant_1"
    )
    assert (await provider.request(request)).failure is failure
    assert (await provider.request(request)).failure is ProviderFailureKind.INVALID_RESPONSE


@pytest.mark.asyncio
async def test_resource_relay_policy_rejects_protected_or_malformed_visible_state() -> None:
    provider = build_resource_relay_demo_provider(
        model="resource-relay-alpha-v1",
        participant_id="participant_0",
        seed=31,
        decision_budget=2,
    )
    protected = _observation()
    protected["hidden_state"] = {"position_mt": [0, 0]}
    result = await provider.request(_request(protected))
    assert result.failure is ProviderFailureKind.INTERNAL
    malformed = _observation()
    malformed["self"] = {"inventory": "material", "status": []}
    result = await provider.request(_request(malformed))
    assert result.failure is ProviderFailureKind.INTERNAL


def _evaluation(**updates: object) -> dict[str, object]:
    value: dict[str, object] = {
        "completion_tick": 870,
        "terminal_outcome": "win",
        "terminal_reason": "objective_target",
        "objective_target": RESOURCE_RELAY_OBJECTIVE_TARGET,
        "participants": {
            "participant_0": {
                "outcome": "win",
                "decision_windows": 87,
                "fallback_windows": 1,
                "resources_gathered": 3,
                "deposits": 3,
                "objective_score": 300,
                "builds_completed": 1,
                "defend_ticks": 20,
                "hits_landed": 2,
                "hits_received": 1,
                "knockouts": 0,
                "resources_dropped": 0,
                "dash_uses": 3,
                "guard_ticks": 20,
            },
            "participant_1": {
                "outcome": "loss",
                "decision_windows": 87,
                "fallback_windows": 2,
                "resources_gathered": 2,
                "deposits": 2,
                "objective_score": 200,
                "builds_completed": 1,
                "defend_ticks": 10,
                "hits_landed": 1,
                "hits_received": 2,
                "knockouts": 0,
                "resources_dropped": 1,
                "dash_uses": 2,
                "guard_ticks": 10,
            },
        },
    }
    value.update(updates)
    return value


def test_resource_relay_evaluation_is_allowlisted_symmetric_and_coordinate_free() -> None:
    result = evaluate_resource_relay(_evaluation())
    assert result["symmetry"] == {
        "decision_window_delta": 0,
        "fallback_window_delta": 1,
        "equal_decision_windows": True,
        "objective_score_delta": 100,
        "deposit_delta": 1,
        "hit_delta": 1,
    }
    assert result["participants"]["participant_0"]["fallback_ratio_per_mille"] == 11
    serialized = repr(result).casefold()
    for forbidden in (
        "position",
        "coordinate",
        "health",
        "energy",
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
        _evaluation(private_state={}),
        _evaluation(objective_target=True),
        _evaluation(terminal_reason="time_limit_draw"),
        _evaluation(completion_tick=None),
        _evaluation(
            participants={
                **_evaluation()["participants"],  # type: ignore[dict-item]
                "participant_0": {
                    **_evaluation()["participants"]["participant_0"],  # type: ignore[index]
                    "objective_score": 299,
                },
            }
        ),
    ),
)
def test_resource_relay_evaluation_rejects_protected_or_inconsistent_values(value: object) -> None:
    with pytest.raises(ValueError):
        evaluate_resource_relay(value)  # type: ignore[arg-type]


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_resource_relay_direct_godot_core() -> None:
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/duo_games/resource_relay_headless_runner.gd",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, output
    assert "DUO_RESOURCE_RELAY_OK" in output
