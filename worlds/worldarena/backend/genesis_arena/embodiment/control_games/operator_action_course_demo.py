"""Participant-visible Demo behavior for the protocol-v2 operator action course."""

from __future__ import annotations

from typing import Any, Mapping

from ..demo_provider import DemoPolicyLock
from ..protocol import canonical_json_bytes, strict_json_loads
from ..providers.contracts import ProviderRequest

PROTOCOL_VERSION = "llm-controller/0.2.0"
OPERATOR_ACTION_COURSE_SCENARIO_ID = "operator-action-course-v0"
OPERATOR_ACTION_COURSE_POLICY_ID = "operator-action-visible-v1"
OPERATOR_ACTION_COURSE_DEMO_MODEL = "operator-action-course-demo-v1"

_STATION_AFFORDANCES = {
    "v_station_walk": "move_forward",
    "v_station_turn": "turn_right",
    "v_station_gather": "gather",
    "v_station_carry": "carry_forward",
    "v_station_deposit": "deposit",
    "v_station_build": "build",
    "v_station_dash": "dash",
    "v_station_guard": "guard",
    "v_station_primary": "primary",
    "v_station_cancel": "cancel_interaction",
    "v_station_hazard": "wait_for_hazard",
    "v_station_celebrate": "celebrate",
}
_STATION_STATES = {
    station_id: frozenset(
        {"awaiting_input", "gather_in_progress"}
        if station_id == "v_station_gather"
        else {"awaiting_input", "build_in_progress"}
        if station_id == "v_station_build"
        else {"awaiting_input", "hold_active"}
        if station_id == "v_station_cancel"
        else {"hazard_armed"}
        if station_id == "v_station_hazard"
        else {"awaiting_input"}
    )
    for station_id in _STATION_AFFORDANCES
}
_FORBIDDEN_KEYS = frozenset(
    {
        "active_interaction",
        "authority_state",
        "coordinate",
        "coordinates",
        "hidden_state",
        "position",
        "position_mt",
        "spectator",
        "spectator_state",
        "station_results",
    }
)
_BUTTONS = (
    "interact",
    "primary",
    "guard",
    "dash",
    "ability_1",
    "ability_2",
    "cycle_item",
    "cancel",
)


def operator_action_course_demo_behavior(
    request: ProviderRequest, policy_lock: DemoPolicyLock, call_index: int
) -> bytes:
    """Emit one direct-controller action from the single current visible station."""

    if (
        policy_lock.scenario_id != OPERATOR_ACTION_COURSE_SCENARIO_ID
        or policy_lock.policy_id != OPERATOR_ACTION_COURSE_POLICY_ID
        or request.model != OPERATOR_ACTION_COURSE_DEMO_MODEL
    ):
        raise ValueError("operator-action Demo policy lock is incompatible")
    observation = strict_json_loads(request.observation_json)
    if not isinstance(observation, Mapping):
        raise ValueError("observation must be an object")
    _reject_protected_semantics(observation)
    if observation.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("operator-action observation must use protocol v2")
    entities = observation.get("visible_entities")
    self_state = observation.get("self")
    if (
        not isinstance(entities, list)
        or len(entities) != 1
        or not isinstance(entities[0], Mapping)
        or not isinstance(self_state, Mapping)
    ):
        raise ValueError("exactly one participant-visible station is required")
    station = entities[0]
    station_id = station.get("id")
    affordances = station.get("affordances")
    state = station.get("state")
    if (
        not isinstance(station_id, str)
        or station_id not in _STATION_AFFORDANCES
        or station.get("kind") != "control_station"
        or affordances != [_STATION_AFFORDANCES[station_id]]
        or state not in _STATION_STATES[station_id]
    ):
        raise ValueError("visible control station is invalid")
    if station.get("bearing") != "front" or station.get("distance") not in {
        "touching",
        "near",
    }:
        raise ValueError("visible station relation is invalid")

    control = _neutral_control()
    station_name = station_id.removeprefix("v_station_")
    if station_name in {"walk", "carry"}:
        control["move_y"] = 1000
    elif station_name == "turn":
        control["look_x"] = 1000
    elif station_name in {"gather", "deposit", "build"}:
        control["buttons"]["interact"] = True
    elif station_name == "dash":
        control["buttons"]["dash"] = True
    elif station_name == "guard":
        control["buttons"]["guard"] = True
    elif station_name == "primary":
        control["buttons"]["primary"] = True
    elif station_name == "cancel":
        if state == "hold_active":
            control["buttons"]["cancel"] = True
        elif state == "awaiting_input":
            control["buttons"]["interact"] = True
        else:
            raise ValueError("cancel station state is invalid")
    elif station_name == "hazard":
        if state != "hazard_armed":
            raise ValueError("hazard station state is invalid")
    elif station_name == "celebrate":
        control["buttons"]["ability_1"] = True

    return canonical_json_bytes(
        {
            "protocol_version": PROTOCOL_VERSION,
            "episode_id": request.episode_id,
            "observation_seq": request.observation_seq,
            "action_id": f"course_{call_index}_{request.observation_seq}",
            "control": control,
            "intent_label": f"Complete visible {station_name} station",
            "memory_update": "",
        }
    )


def _neutral_control() -> dict[str, Any]:
    return {
        "move_x": 0,
        "move_y": 0,
        "look_x": 0,
        "look_y": 0,
        "duration_ticks": 1,
        "buttons": {name: False for name in _BUTTONS},
    }


def _reject_protected_semantics(value: Any) -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            if not isinstance(key, str) or key.casefold() in _FORBIDDEN_KEYS:
                raise ValueError("observation contains protected course semantics")
            _reject_protected_semantics(child)
    elif isinstance(value, list):
        for child in value:
            _reject_protected_semantics(child)


__all__ = [
    "OPERATOR_ACTION_COURSE_DEMO_MODEL",
    "OPERATOR_ACTION_COURSE_POLICY_ID",
    "OPERATOR_ACTION_COURSE_SCENARIO_ID",
    "operator_action_course_demo_behavior",
]
