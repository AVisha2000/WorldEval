"""Credential-free, participant-visible controllers for the solo curriculum demos.

The local demo path deliberately has a much narrower role than a live model adapter.  It reads
only the same visible observation a participant receives and emits ordinary one-tick controller
actions.  There are no credentials, prompts, hidden coordinates, spectator observations, or
semantic world commands in this module.

Construction keeps its separate task-plan executor because that is the approved managed-model
contract.  Stages A, B, and D use direct controller actions so the frozen live-provider schema
and protocol lock remain unchanged.
"""

from __future__ import annotations

from typing import Any, Mapping

from .protocol import canonical_json_bytes, strict_json_loads
from .providers.contracts import (
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)
from .scripted_construction_demo import (
    SCRIPTED_CONSTRUCTION_MODEL,
    SCRIPTED_CONSTRUCTION_PROVIDER,
    SCRIPTED_CONSTRUCTION_TASK,
)

SCRIPTED_SOLO_PROVIDER = SCRIPTED_CONSTRUCTION_PROVIDER

SCRIPTED_SOLO_MODELS: Mapping[str, str] = {
    "orientation-v0": "orientation-demo-v1",
    "interaction-v0": "interaction-demo-v1",
    SCRIPTED_CONSTRUCTION_TASK: SCRIPTED_CONSTRUCTION_MODEL,
    "neutral-encounter-v0": "neutral-encounter-demo-v1",
}
SCRIPTED_SOLO_TASKS = frozenset(SCRIPTED_SOLO_MODELS)
SCRIPTED_DIRECT_TASKS = SCRIPTED_SOLO_TASKS - {SCRIPTED_CONSTRUCTION_TASK}

_BUTTON_NAMES = (
    "interact",
    "primary",
    "guard",
    "dash",
    "ability_1",
    "ability_2",
    "cycle_item",
    "cancel",
)
_TURN_RIGHT = frozenset(("front_right", "right", "back_right", "back"))
_TURN_LEFT = frozenset(("front_left", "left", "back_left"))
_SAFE_NEUTRAL_STATES = ("retreat", "recovery", "defeated")


def scripted_demo_model(task_id: str) -> str:
    """Return the one public model label reserved for a scripted solo task."""

    try:
        return SCRIPTED_SOLO_MODELS[task_id]
    except KeyError as error:
        raise ValueError("scripted demo task is unsupported") from error


def is_scripted_solo_demo(*, provider: str, model: str, task_id: str) -> bool:
    """True only for the dedicated credential-free solo demonstration route."""

    return provider == SCRIPTED_SOLO_PROVIDER and SCRIPTED_SOLO_MODELS.get(task_id) == model


class ScriptedSoloDemoProvider:
    """One-tick deterministic controller for Stages A, B, and D.

    Calls are intentionally local and synchronous in effect (the async method simply satisfies
    the shared provider boundary).  The live runner paces the accepted one-tick windows at 10 Hz,
    which keeps Godot authority and participant pixels moving smoothly without invoking a model.
    """

    provider_name = SCRIPTED_SOLO_PROVIDER

    def __init__(self, task_id: str) -> None:
        if task_id not in SCRIPTED_DIRECT_TASKS:
            raise ValueError("scripted direct demo task is unsupported")
        self.task_id = task_id
        self.model = scripted_demo_model(task_id)

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        if request.model != self.model:
            return _invalid()
        try:
            observation = strict_json_loads(request.observation_json)
            if not isinstance(observation, Mapping):
                raise ValueError("observation is not an object")
            control, intent_label = _next_control(self.task_id, observation)
        except (KeyError, TypeError, ValueError):
            # The normal runner turns this into a recorded neutral window.  Never repair a
            # malformed observation or invent hidden target information.
            return _invalid()
        action = {
            "protocol_version": "llm-controller/0.1.0",
            "episode_id": request.episode_id,
            "observation_seq": request.observation_seq,
            "action_id": f"demo_{self.task_id.removesuffix('-v0')}_{request.observation_seq}",
            "control": control,
            "intent_label": intent_label,
            "memory_update": "",
        }
        return ProviderCallResult.success(canonical_json_bytes(action), ProviderTelemetry(0))


def _next_control(task_id: str, observation: Mapping[str, Any]) -> tuple[dict[str, Any], str]:
    _require_boundary(observation)
    entities = _visible_entities(observation)
    if task_id == "orientation-v0":
        return _orientation_control(_entity(entities, "v_beacon_1"))
    if task_id == "interaction-v0":
        carrying = _carrying_material(observation)
        target = "v_relay_1" if carrying else "v_resource_1"
        return _interaction_control(_entity(entities, target), carrying)
    if task_id == "neutral-encounter-v0":
        return _neutral_encounter_control(observation, entities)
    raise ValueError("scripted direct demo task is unsupported")


def _orientation_control(target: Mapping[str, Any]) -> tuple[dict[str, Any], str]:
    if _distance(target) == "touching":
        return _control(), "Demo: hold the visible beacon"
    return _approach(target, "Demo: approach the visible beacon")


def _interaction_control(
    target: Mapping[str, Any], carrying: bool
) -> tuple[dict[str, Any], str]:
    if _distance(target) == "touching" and _bearing(target) == "front":
        label = "Demo: deposit carried material" if carrying else "Demo: gather marked material"
        return _control(interact=True), label
    label = "Demo: return to the visible relay" if carrying else "Demo: approach marked material"
    return _approach(target, label)


def _neutral_encounter_control(
    observation: Mapping[str, Any], entities: Mapping[str, Mapping[str, Any]]
) -> tuple[dict[str, Any], str]:
    neutral = _entity(entities, "v_neutral_1")
    relay = _entity(entities, "v_relay_1")
    neutral_state = _neutral_state(neutral)
    if neutral_state in _SAFE_NEUTRAL_STATES:
        if _distance(relay) == "touching" and _bearing(relay) == "front":
            return _control(interact=True), "Demo: activate the now-safe relay"
        return _approach(relay, "Demo: move to the now-safe relay", guard=True)

    if _distance(neutral) == "touching" and _bearing(neutral) == "front":
        if "primary_cooldown" not in _status(observation):
            return _control(primary=True, guard=True), "Demo: defend and strike the neutral"
        return _control(guard=True), "Demo: guard during primary cooldown"
    return _approach(neutral, "Demo: approach the defending neutral", guard=True)


def _approach(
    target: Mapping[str, Any], label: str, *, guard: bool = False
) -> tuple[dict[str, Any], str]:
    bearing = _bearing(target)
    if bearing in _TURN_RIGHT:
        return _control(look_x=1000, guard=guard), label
    if bearing in _TURN_LEFT:
        return _control(look_x=-1000, guard=guard), label
    if bearing == "front":
        return _control(move_y=1000, guard=guard), label
    # A target must use one of the public relative-bearing enum values.  Explicitly rejecting
    # anything else keeps a corrupted semantic observation from yielding a controller action.
    raise ValueError("visible entity bearing is invalid")


def _require_boundary(observation: Mapping[str, Any]) -> None:
    if observation.get("terminal") is not None:
        terminal = observation["terminal"]
        if not isinstance(terminal, Mapping) or not isinstance(terminal.get("ended"), bool):
            raise ValueError("terminal is invalid")
    for field in ("episode_id", "observation_seq", "tick"):
        value = observation.get(field)
        if field == "episode_id":
            if not isinstance(value, str) or not value:
                raise ValueError("episode identity is invalid")
        elif isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError("observation boundary is invalid")


def _visible_entities(observation: Mapping[str, Any]) -> Mapping[str, Mapping[str, Any]]:
    value = observation.get("visible_entities")
    if not isinstance(value, list):
        raise ValueError("visible entities are absent")
    entities: dict[str, Mapping[str, Any]] = {}
    for item in value:
        if not isinstance(item, Mapping):
            raise ValueError("visible entity is invalid")
        entity_id = item.get("id")
        if not isinstance(entity_id, str) or not entity_id:
            raise ValueError("visible entity id is invalid")
        entities[entity_id] = item
    return entities


def _entity(
    entities: Mapping[str, Mapping[str, Any]], entity_id: str
) -> Mapping[str, Any]:
    try:
        entity = entities[entity_id]
    except KeyError as error:
        raise ValueError("required visible entity is absent") from error
    _bearing(entity)
    _distance(entity)
    state = entity.get("state")
    if not isinstance(state, str) or not state:
        raise ValueError("visible entity state is invalid")
    return entity


def _bearing(entity: Mapping[str, Any]) -> str:
    value = entity.get("bearing")
    if value not in _TURN_RIGHT | _TURN_LEFT | {"front"}:
        raise ValueError("visible entity bearing is invalid")
    return str(value)


def _distance(entity: Mapping[str, Any]) -> str:
    value = entity.get("distance")
    if value not in {"touching", "near", "medium", "far"}:
        raise ValueError("visible entity distance is invalid")
    return str(value)


def _carrying_material(observation: Mapping[str, Any]) -> bool:
    self_state = observation.get("self")
    if not isinstance(self_state, Mapping):
        raise ValueError("self state is absent")
    inventory = self_state.get("inventory")
    if not isinstance(inventory, list):
        raise ValueError("inventory is absent")
    for item in inventory:
        if not isinstance(item, Mapping):
            raise ValueError("inventory item is invalid")
        count = item.get("count")
        if (
            item.get("kind") == "material"
            and not isinstance(count, bool)
            and isinstance(count, int)
            and count > 0
        ):
            return True
    return False


def _status(observation: Mapping[str, Any]) -> frozenset[str]:
    self_state = observation.get("self")
    if not isinstance(self_state, Mapping):
        raise ValueError("self state is absent")
    values = self_state.get("status")
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        raise ValueError("self status is invalid")
    return frozenset(values)


def _neutral_state(neutral: Mapping[str, Any]) -> str:
    value = neutral.get("state")
    if not isinstance(value, str):
        raise ValueError("neutral state is invalid")
    for state in ("idle", "chase", "telegraph", "attack", "retreat", "recovery", "defeated"):
        if value == state or value.startswith(f"{state}_"):
            return state
    raise ValueError("neutral state is invalid")


def _control(
    *,
    move_y: int = 0,
    look_x: int = 0,
    interact: bool = False,
    primary: bool = False,
    guard: bool = False,
) -> dict[str, Any]:
    buttons = {name: False for name in _BUTTON_NAMES}
    buttons.update({"interact": interact, "primary": primary, "guard": guard})
    return {
        "move_x": 0,
        "move_y": move_y,
        "look_x": look_x,
        "look_y": 0,
        "duration_ticks": 1,
        "buttons": buttons,
    }


def _invalid() -> ProviderCallResult:
    return ProviderCallResult.failed(ProviderFailureKind.INVALID_RESPONSE, ProviderTelemetry(0))


__all__ = [
    "SCRIPTED_DIRECT_TASKS",
    "SCRIPTED_SOLO_MODELS",
    "SCRIPTED_SOLO_PROVIDER",
    "SCRIPTED_SOLO_TASKS",
    "ScriptedSoloDemoProvider",
    "is_scripted_solo_demo",
    "scripted_demo_model",
]
