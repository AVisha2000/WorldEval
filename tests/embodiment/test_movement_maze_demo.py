from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from genesis_arena.embodiment.control_games.movement_maze_demo import (
    MOVEMENT_MAZE_DEMO_MODEL,
    MOVEMENT_MAZE_POLICY_ID,
    MOVEMENT_MAZE_SCENARIO_ID,
    movement_maze_demo_behavior,
)
from genesis_arena.embodiment.demo_provider import DemoPolicyLock, DemoProvider
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.providers.contracts import ProviderFailureKind, ProviderRequest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = b"movement-maze-visible-v1\n"


def _lock() -> DemoPolicyLock:
    return DemoPolicyLock(
        scenario_id=MOVEMENT_MAZE_SCENARIO_ID,
        policy_id=MOVEMENT_MAZE_POLICY_ID,
        fixture_sha256=hashlib.sha256(FIXTURE).hexdigest(),
        seed=20240520,
        participant_id="participant_0",
        model=MOVEMENT_MAZE_DEMO_MODEL,
        total_decision_budget=100,
    )


def _observation(
    *,
    bearing: str = "front",
    distance: str = "far",
    contact: str = "clear",
    target_id: str = "v_checkpoint_1",
) -> dict:
    return {
        "protocol_version": "llm-controller/0.2.0",
        "episode_id": "ep_movement_maze_policy",
        "observation_seq": 7,
        "tick": 12,
        "profile": "text-visible-v1",
        "goal": "Reach visible checkpoints in order.",
        "remaining_ticks": 188,
        "self": {
            "health_percent": 100,
            "energy_percent": 100,
            "facing": "north",
            "contact": contact,
            "inventory": [],
            "status": [],
        },
        "visible_entities": [
            {
                "id": target_id,
                "kind": "beacon" if target_id == "v_final_beacon" else "checkpoint",
                "bearing": bearing,
                "distance": distance,
                "affordances": ["approach"],
                "state": "next_in_order",
            }
        ],
        "recent_events": [],
        "memory": "",
        "previous_receipt": None,
        "terminal": {"ended": False, "outcome": "running", "reason": "in_progress"},
    }


def _request(observation: dict | None = None) -> ProviderRequest:
    return ProviderRequest(
        episode_id="ep_movement_maze_policy",
        participant_id="participant_0",
        observation_seq=7,
        deadline_monotonic_ns=1,
        model=MOVEMENT_MAZE_DEMO_MODEL,
        system_prompt="Use only participant-visible maze semantics.",
        observation_json=canonical_json_bytes(observation or _observation()),
        action_schema_json=b"{}",
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("bearing", "distance", "contact", "move_y", "look_x"),
    (
        ("front", "far", "clear", 1000, 0),
        ("right", "medium", "clear", 0, 1000),
        ("back_left", "near", "clear", 0, -1000),
        ("front", "near", "blocked_front", 0, 1000),
        ("front", "touching", "clear", 0, 0),
    ),
)
async def test_demo_policy_emits_v2_actions_from_visible_relations_only(
    bearing: str, distance: str, contact: str, move_y: int, look_x: int
) -> None:
    provider = DemoProvider(
        _lock(), behavior=movement_maze_demo_behavior, fixture_bytes=FIXTURE
    )
    result = await provider.request(
        _request(_observation(bearing=bearing, distance=distance, contact=contact))
    )

    assert result.failure is None
    assert result.raw_output is not None
    action = strict_json_loads(result.raw_output)
    EmbodimentProtocolRegistry.from_repository(ROOT).validate(
        "llm-controller/0.2.0", "controller-action", action
    )
    assert action["control"]["move_y"] == move_y
    assert action["control"]["look_x"] == look_x
    assert b"position" not in result.raw_output
    assert b"route" not in result.raw_output
    assert b"coordinate" not in result.raw_output


@pytest.mark.asyncio
async def test_demo_policy_accepts_final_visible_beacon_identity() -> None:
    result = await DemoProvider(
        _lock(), behavior=movement_maze_demo_behavior, fixture_bytes=FIXTURE
    ).request(_request(_observation(target_id="v_final_beacon", distance="near")))

    assert result.failure is None
    assert result.raw_output is not None
    assert strict_json_loads(result.raw_output)["intent_label"] == "Navigate to final_beacon"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "mutation",
    (
        lambda value: value.update({"position_mt": {"x": 1, "y": 5}}),
        lambda value: value.update({"hidden_route": ["north", "east"]}),
        lambda value: value["visible_entities"].append(value["visible_entities"][0].copy()),
        lambda value: value["visible_entities"][0].update({"id": "v_checkpoint_9"}),
        lambda value: value["visible_entities"][0].update({"state": "already_complete"}),
    ),
)
async def test_demo_policy_fails_closed_on_hidden_or_invalid_target_semantics(mutation) -> None:
    observation = _observation()
    mutation(observation)
    provider = DemoProvider(
        _lock(), behavior=movement_maze_demo_behavior, fixture_bytes=FIXTURE
    )

    result = await provider.request(_request(observation))

    assert result.raw_output is None
    assert result.failure == ProviderFailureKind.INTERNAL


def test_policy_has_no_map_or_route_fixture() -> None:
    source = (
        ROOT / "backend/genesis_arena/embodiment/control_games/movement_maze_demo.py"
    ).read_text()

    assert "movement_maze_map" not in source
    assert "CHECKPOINT_TILES" not in source
    assert "SHORTEST_LEGAL_ROUTE" not in source
