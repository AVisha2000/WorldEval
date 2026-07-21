"""Credential-free movement-maze policy over participant-visible semantics only.

The policy intentionally has no map import and no route table.  Its complete world input is the
ordinary player-scoped observation contained in :class:`ProviderRequest`: current visible marker
identity, relative bearing, qualitative distance, and the operator's contact state.
"""

from __future__ import annotations

import re
from typing import Any, Mapping

from ..demo_provider import DemoPolicyLock
from ..protocol import canonical_json_bytes, strict_json_loads
from ..providers.contracts import ProviderRequest

PROTOCOL_VERSION = "llm-controller/0.2.0"
MOVEMENT_MAZE_SCENARIO_ID = "movement-maze-v0"
MOVEMENT_MAZE_POLICY_ID = "movement-maze-visible-v1"
MOVEMENT_MAZE_DEMO_MODEL = "movement-maze-demo-v1"

_CHECKPOINT_ID = re.compile(r"^v_checkpoint_[1-4]$")
_TARGET_IDS = frozenset({"v_final_beacon"})
_RIGHT = frozenset({"front_right", "right", "back_right", "back"})
_LEFT = frozenset({"front_left", "left", "back_left"})
_DISTANCES = frozenset({"touching", "near", "medium", "far"})
_CONTACTS = frozenset(
    {"clear", "blocked_front", "blocked_left", "blocked_right", "blocked_multiple"}
)
_FORBIDDEN_KEYS = frozenset(
    {
        "coordinate",
        "coordinates",
        "hidden_route",
        "legal_tiles",
        "position",
        "position_mt",
        "route",
        "shortest_legal_route_mt",
        "spectator",
        "spectator_state",
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


def movement_maze_demo_behavior(
    request: ProviderRequest, policy_lock: DemoPolicyLock, call_index: int
) -> bytes:
    """Return one strict v2 controller action or raise for the normal neutral fallback.

    ``call_index`` only names the action; it is never used as a hidden route cursor.  A missing or
    malformed current visible marker therefore fails closed instead of guessing from fixture time.
    """

    if policy_lock.scenario_id != MOVEMENT_MAZE_SCENARIO_ID:
        raise ValueError("movement-maze policy requires its scenario lock")
    if policy_lock.policy_id != MOVEMENT_MAZE_POLICY_ID:
        raise ValueError("movement-maze policy lock is incompatible")
    if request.model != MOVEMENT_MAZE_DEMO_MODEL:
        raise ValueError("movement-maze model identity is incompatible")
    observation = strict_json_loads(request.observation_json)
    if not isinstance(observation, Mapping):
        raise ValueError("observation must be an object")
    _reject_protected_semantics(observation)
    if observation.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("movement-maze observation must use protocol v2")

    self_state = observation.get("self")
    entities = observation.get("visible_entities")
    if not isinstance(self_state, Mapping) or not isinstance(entities, list):
        raise ValueError("visible maze semantics are absent")
    contact = self_state.get("contact")
    if contact not in _CONTACTS:
        raise ValueError("operator contact is invalid")
    if len(entities) != 1 or not isinstance(entities[0], Mapping):
        raise ValueError("exactly one current visible maze marker is required")
    target = entities[0]
    target_id = target.get("id")
    if not isinstance(target_id, str) or not (
        _CHECKPOINT_ID.fullmatch(target_id) or target_id in _TARGET_IDS
    ):
        raise ValueError("visible marker identity is invalid")
    expected_kind = "beacon" if target_id == "v_final_beacon" else "checkpoint"
    if target.get("kind") != expected_kind or target.get("state") != "next_in_order":
        raise ValueError("visible marker is not the current ordered target")
    bearing = target.get("bearing")
    distance = target.get("distance")
    if bearing not in _RIGHT | _LEFT | {"front"} or distance not in _DISTANCES:
        raise ValueError("visible marker relation is invalid")

    move_y = 0
    look_x = 0
    if bearing in _RIGHT:
        look_x = 1000
    elif bearing in _LEFT:
        look_x = -1000
    elif contact in {"blocked_front", "blocked_multiple"}:
        # The marker is still player-visible but the last forward attempt met a narrow wall.
        # A deterministic right correction uses only the public contact result.
        look_x = 1000
    elif distance != "touching":
        move_y = 1000

    buttons = {name: False for name in _BUTTONS}
    action = {
        "protocol_version": PROTOCOL_VERSION,
        "episode_id": request.episode_id,
        "observation_seq": request.observation_seq,
        "action_id": f"maze_{call_index}_{request.observation_seq}",
        "control": {
            "move_x": 0,
            "move_y": move_y,
            "look_x": look_x,
            "look_y": 0,
            "duration_ticks": 1,
            "buttons": buttons,
        },
        "intent_label": f"Navigate to {target_id.removeprefix('v_')}",
        "memory_update": "",
    }
    return canonical_json_bytes(action)


def _reject_protected_semantics(value: Any) -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            if not isinstance(key, str) or key.casefold() in _FORBIDDEN_KEYS:
                raise ValueError("observation contains protected maze semantics")
            _reject_protected_semantics(child)
    elif isinstance(value, list):
        for child in value:
            _reject_protected_semantics(child)


__all__ = [
    "MOVEMENT_MAZE_DEMO_MODEL",
    "MOVEMENT_MAZE_POLICY_ID",
    "MOVEMENT_MAZE_SCENARIO_ID",
    "movement_maze_demo_behavior",
]
