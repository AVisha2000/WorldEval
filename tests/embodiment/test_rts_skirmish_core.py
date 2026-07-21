from __future__ import annotations

from pathlib import Path

import pytest
from genesis_arena.embodiment.duo_games.rts_skirmish import (
    build_rts_skirmish_demo_provider,
    evaluate_rts_skirmish,
)
from genesis_arena.embodiment.live_solo import parse_controller_action
from genesis_arena.embodiment.protocol import canonical_json_bytes
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.providers.contracts import ProviderRequest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = EmbodimentProtocolRegistry.from_repository(ROOT).package("llm-controller/0.2.0")


def _request(
    entities: list[dict[str, object]], *, status: list[str] | None = None
) -> ProviderRequest:
    observation = {
        "protocol_version": "llm-controller/0.2.0",
        "episode_id": "ep_rts_test",
        "observation_seq": 4,
        "profile": "text-visible-v1",
        "self": {"inventory": [], "status": status or []},
        "visible_entities": entities,
    }
    return ProviderRequest(
        episode_id="ep_rts_test",
        participant_id="participant_0",
        observation_seq=4,
        deadline_monotonic_ns=1,
        model="rts-harvester-alpha-v1",
        system_prompt="participant visible only",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes(PACKAGE.schema("controller-action")),
    )


@pytest.mark.asyncio
async def test_rts_policy_uses_visible_gather_and_milestone_controller_actions() -> None:
    provider = build_rts_skirmish_demo_provider(
        model="rts-harvester-alpha-v1", participant_id="participant_0", seed=9, decision_budget=3
    )
    request = _request(
        [
            {
                "id": "v_wood_0",
                "kind": "resource_wood",
                "state": "available",
                "bearing": "front",
                "distance": "touching",
                "affordances": ["gather"],
            }
        ]
    )
    action = parse_controller_action(
        (await provider.request(request)).raw_output or b"", package=PACKAGE
    )
    assert action.control.duration_ticks == 10
    assert action.control.buttons.interact is True
    assert "gather" in action.intent_label


def test_rts_evaluation_projects_only_trusted_public_totals() -> None:
    value = evaluate_rts_skirmish(
        {
            "completion_tick": 600,
            "terminal_outcome": "win",
            "terminal_reason": "central_objective",
            "participants": {
                "participant_0": {
                    "outcome": "win",
                    "decision_windows": 60,
                    "fallback_windows": 0,
                    "materials_gathered": 4,
                    "deposits": 4,
                    "barracks_built": 1,
                    "towers_built": 1,
                    "units_trained": 2,
                    "central_hold_ticks": 60,
                    "town_hall_damage_dealt": 0,
                    "town_hall_damage_received": 0,
                    "hits_landed": 0,
                    "hits_received": 0,
                    "knockouts": 0,
                },
                "participant_1": {
                    "outcome": "loss",
                    "decision_windows": 60,
                    "fallback_windows": 1,
                    "materials_gathered": 3,
                    "deposits": 3,
                    "barracks_built": 1,
                    "towers_built": 0,
                    "units_trained": 1,
                    "central_hold_ticks": 0,
                    "town_hall_damage_dealt": 0,
                    "town_hall_damage_received": 0,
                    "hits_landed": 0,
                    "hits_received": 0,
                    "knockouts": 0,
                },
            },
        }
    )
    assert value["completion"]["reason"] == "central_objective"
    assert value["participants"]["participant_0"]["units_trained"] == 2
    assert "position" not in repr(value).casefold()
