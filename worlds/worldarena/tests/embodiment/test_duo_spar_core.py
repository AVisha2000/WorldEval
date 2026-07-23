from __future__ import annotations

from pathlib import Path

import pytest
from genesis_arena.embodiment.duo_games.spar import build_spar_demo_provider, evaluate_spar
from genesis_arena.embodiment.live_solo import parse_controller_action
from genesis_arena.embodiment.protocol import canonical_json_bytes
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.providers.contracts import ProviderFailureKind, ProviderRequest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = EmbodimentProtocolRegistry.from_repository(ROOT).package("llm-controller/0.2.0")


def _observation(*, reverse: bool = False) -> dict[str, object]:
    entity = {
        "id": "v_spar_rival",
        "kind": "operator",
        "state": "attacking",
        "bearing": "front",
        "distance": "near",
        "affordances": ["hostile"],
    }
    if reverse:
        entity = dict(reversed(tuple(entity.items())))
    return {
        "protocol_version": "llm-controller/0.2.0",
        "episode_id": "ep_duo_spar",
        "observation_seq": 12,
        "profile": "text-visible-v1",
        "visible_entities": [entity],
    }


def _request(observation: dict[str, object]) -> ProviderRequest:
    return ProviderRequest(
        episode_id="ep_duo_spar",
        participant_id="participant_1",
        observation_seq=12,
        deadline_monotonic_ns=1,
        model="sparring-bravo-v1",
        system_prompt="Use participant-visible spar semantics and return strict JSON.",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes(PACKAGE.schema("controller-action")),
    )


@pytest.mark.asyncio
async def test_spar_policy_is_repeatable_dict_order_invariant_and_guards_visible_attack() -> None:
    first = build_spar_demo_provider(
        model="sparring-bravo-v1",
        participant_id="participant_1",
        seed=5,
        decision_budget=1,
    )
    repeat = build_spar_demo_provider(
        model="sparring-bravo-v1",
        participant_id="participant_1",
        seed=5,
        decision_budget=1,
    )
    first_result = await first.request(_request(_observation()))
    repeat_result = await repeat.request(_request(_observation(reverse=True)))

    assert first.policy_lock == repeat.policy_lock
    assert first_result.raw_output == repeat_result.raw_output
    action = parse_controller_action(first_result.raw_output or b"", package=PACKAGE)
    assert action.control.duration_ticks == 10
    assert action.control.buttons.guard is True
    assert action.control.buttons.primary is False
    assert "v_spar_rival" not in (first_result.raw_output or b"").decode("utf-8")


@pytest.mark.asyncio
async def test_spar_stale_and_oversized_fixtures_use_normal_provider_boundary() -> None:
    stale = build_spar_demo_provider(
        model="sparring-bravo-v1",
        participant_id="participant_1",
        seed=5,
        decision_budget=1,
        fixture_mode="stale",
    )
    stale_result = await stale.request(_request(_observation()))
    stale_action = parse_controller_action(stale_result.raw_output or b"", package=PACKAGE)
    assert stale_action.observation_seq == 11

    oversized = build_spar_demo_provider(
        model="sparring-bravo-v1",
        participant_id="participant_1",
        seed=5,
        decision_budget=1,
        fixture_mode="oversized",
    )
    assert (await oversized.request(_request(_observation()))).failure is (
        ProviderFailureKind.OUTPUT_TOO_LARGE
    )


def _evaluation(**updates: object) -> dict[str, object]:
    value: dict[str, object] = {
        "completion_tick": 330,
        "terminal_outcome": "win",
        "terminal_reason": "knockout",
        "participants": {
            "participant_0": {
                "outcome": "win",
                "decision_windows": 33,
                "fallback_windows": 0,
                "hits_landed": 5,
                "hits_received": 2,
                "knockouts": 1,
            },
            "participant_1": {
                "outcome": "loss",
                "decision_windows": 33,
                "fallback_windows": 1,
                "hits_landed": 2,
                "hits_received": 5,
                "knockouts": 0,
            },
        },
    }
    value.update(updates)
    return value


def test_spar_evaluation_exposes_only_public_totals_and_symmetry_checks() -> None:
    result = evaluate_spar(_evaluation())
    assert result["symmetry"] == {
        "decision_window_delta": 0,
        "fallback_window_delta": 1,
        "equal_decision_windows": True,
        "hit_delta": 3,
    }
    serialized = repr(result).casefold()
    for forbidden in (
        "health",
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
        _evaluation(private_state={}),
        _evaluation(completion_tick=False),
        _evaluation(terminal_reason="time_limit"),
        _evaluation(
            participants={
                "participant_0": {
                    "outcome": "win",
                    "decision_windows": 1,
                    "fallback_windows": 0,
                    "hits_landed": 4,
                    "hits_received": 1,
                    "knockouts": 1,
                },
                "participant_1": {
                    "outcome": "loss",
                    "decision_windows": 1,
                    "fallback_windows": 0,
                    "hits_landed": 2,
                    "hits_received": 4,
                    "knockouts": 0,
                },
            }
        ),
    ),
)
def test_spar_evaluation_rejects_protected_or_asymmetric_authority_values(value: object) -> None:
    with pytest.raises(ValueError):
        evaluate_spar(value)  # type: ignore[arg-type]
