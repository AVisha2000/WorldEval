from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from genesis_arena.embodiment.control_games.operator_action_course_demo import (
    OPERATOR_ACTION_COURSE_DEMO_MODEL,
    OPERATOR_ACTION_COURSE_POLICY_ID,
    OPERATOR_ACTION_COURSE_SCENARIO_ID,
    operator_action_course_demo_behavior,
)
from genesis_arena.embodiment.demo_provider import DemoPolicyLock, DemoProvider
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.providers.contracts import ProviderFailureKind, ProviderRequest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = b"operator-action-visible-v1\n"
AFFORDANCES = {
    "walk": "move_forward",
    "turn": "turn_right",
    "gather": "gather",
    "carry": "carry_forward",
    "deposit": "deposit",
    "build": "build",
    "dash": "dash",
    "guard": "guard",
    "primary": "primary",
    "cancel": "cancel_interaction",
    "hazard": "wait_for_hazard",
    "celebrate": "celebrate",
}


def _lock() -> DemoPolicyLock:
    return DemoPolicyLock(
        scenario_id=OPERATOR_ACTION_COURSE_SCENARIO_ID,
        policy_id=OPERATOR_ACTION_COURSE_POLICY_ID,
        fixture_sha256=hashlib.sha256(FIXTURE).hexdigest(),
        seed=20240521,
        participant_id="participant_0",
        model=OPERATOR_ACTION_COURSE_DEMO_MODEL,
        total_decision_budget=100,
    )


def _observation(station: str, *, state: str = "awaiting_input") -> dict:
    return {
        "protocol_version": "llm-controller/0.2.0",
        "episode_id": "ep_operator_action_policy",
        "observation_seq": 4,
        "tick": 9,
        "profile": "text-visible-v1",
        "goal": "Complete each visible control station.",
        "remaining_ticks": 291,
        "self": {
            "health_percent": 100,
            "energy_percent": 100,
            "facing": "north",
            "contact": "clear",
            "inventory": [],
            "status": ["idle"],
        },
        "visible_entities": [
            {
                "id": f"v_station_{station}",
                "kind": "control_station",
                "bearing": "front",
                "distance": "near" if station in {"walk", "carry", "dash"} else "touching",
                "affordances": [AFFORDANCES[station]],
                "state": state,
            }
        ],
        "recent_events": [],
        "memory": "",
        "previous_receipt": None,
        "terminal": {"ended": False, "outcome": "running", "reason": "in_progress"},
    }


def _request(observation: dict) -> ProviderRequest:
    return ProviderRequest(
        episode_id="ep_operator_action_policy",
        participant_id="participant_0",
        observation_seq=4,
        deadline_monotonic_ns=1,
        model=OPERATOR_ACTION_COURSE_DEMO_MODEL,
        system_prompt="Use the current participant-visible control station.",
        observation_json=canonical_json_bytes(observation),
        action_schema_json=b"{}",
    )


def _expected_control(station: str, state: str) -> tuple[str, int | bool]:
    if station in {"walk", "carry"}:
        return "move_y", 1000
    if station == "turn":
        return "look_x", 1000
    if station in {"gather", "deposit", "build"}:
        return "interact", True
    if station == "cancel":
        return ("cancel", True) if state == "hold_active" else ("interact", True)
    if station == "hazard":
        return "move_y", 0
    return ("ability_1", True) if station == "celebrate" else (station, True)


@pytest.mark.asyncio
@pytest.mark.parametrize("station", tuple(AFFORDANCES))
async def test_demo_policy_covers_every_visible_control_station(station: str) -> None:
    state = "hazard_armed" if station == "hazard" else "awaiting_input"
    provider = DemoProvider(
        _lock(), behavior=operator_action_course_demo_behavior, fixture_bytes=FIXTURE
    )
    result = await provider.request(_request(_observation(station, state=state)))

    assert result.failure is None
    assert result.raw_output is not None
    action = strict_json_loads(result.raw_output)
    EmbodimentProtocolRegistry.from_repository(ROOT).validate(
        "llm-controller/0.2.0", "controller-action", action
    )
    field, expected = _expected_control(station, state)
    actual = action["control"].get(field, action["control"]["buttons"].get(field))
    assert actual == expected
    assert b"position" not in result.raw_output
    assert b"authority" not in result.raw_output


@pytest.mark.asyncio
async def test_cancel_policy_uses_visible_hold_state_before_cancel_edge() -> None:
    provider = DemoProvider(
        _lock(), behavior=operator_action_course_demo_behavior, fixture_bytes=FIXTURE
    )
    result = await provider.request(
        _request(_observation("cancel", state="hold_active"))
    )

    action = strict_json_loads(result.raw_output or b"{}")
    assert action["control"]["buttons"]["cancel"] is True
    assert action["control"]["buttons"]["interact"] is False


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "mutation",
    (
        lambda value: value.update({"position_mt": {"x": 0, "y": 0}}),
        lambda value: value.update({"station_results": {"walk": True}}),
        lambda value: value["visible_entities"][0].update({"affordances": ["primary"]}),
        lambda value: value["visible_entities"][0].update({"state": "hidden_complete"}),
        lambda value: value["visible_entities"].append(value["visible_entities"][0].copy()),
    ),
)
async def test_demo_policy_fails_closed_on_private_or_inconsistent_semantics(mutation) -> None:
    observation = _observation("walk")
    mutation(observation)
    result = await DemoProvider(
        _lock(), behavior=operator_action_course_demo_behavior, fixture_bytes=FIXTURE
    ).request(_request(observation))

    assert result.raw_output is None
    assert result.failure == ProviderFailureKind.INTERNAL


def test_demo_policy_has_no_authority_or_map_dependency() -> None:
    source = (
        ROOT
        / "backend/genesis_arena/embodiment/control_games/operator_action_course_demo.py"
    ).read_text()

    assert "operator_action_course_map" not in source
    assert "operator_action_course_authority" not in source
