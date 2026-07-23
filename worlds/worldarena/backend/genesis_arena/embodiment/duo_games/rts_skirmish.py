"""Visible-only deterministic Demo policy and evaluator for the RTS skirmish vertical slice.

The game uses the ordinary v2 fixed-ten-tick controller contract.  Milestones are intent labels,
not a protocol extension: Godot remains sole authority for gathering, construction, training,
combat and victory.
"""

from __future__ import annotations

from typing import Any, Mapping

from ..contracts import ControllerButtons, ControllerState
from ..demo_provider import DemoPolicyLock, DemoProvider
from ..providers.contracts import ProviderRequest
from .common import (
    FIXED_DUO_WINDOW_TICKS,
    DuoFixtureMode,
    DuoPolicySpec,
    build_demo_provider,
    direct_action,
    frozen_specs,
    parse_visible_observation,
    participant_window_projection,
    select_visible_entity,
    validate_completion_tick,
    validate_match_outcomes,
    validate_two_participant_summaries,
)

RTS_SKIRMISH_SCENARIO_ID = "rts-skirmish-v0"
RTS_SKIRMISH_MODELS = frozen_specs(
    {
        "rts-harvester-alpha-v1": DuoPolicySpec(
            RTS_SKIRMISH_SCENARIO_ID,
            "rts-harvester-alpha-visible-v1",
            "rts-harvester-alpha-v1",
            "economy",
        ),
        "rts-commander-bravo-v1": DuoPolicySpec(
            RTS_SKIRMISH_SCENARIO_ID,
            "rts-commander-bravo-visible-v1",
            "rts-commander-bravo-v1",
            "commander",
        ),
    }
)

_FIELDS = frozenset(("completion_tick", "terminal_outcome", "terminal_reason", "participants"))
_EXTRA = frozenset(
    (
        "materials_gathered",
        "deposits",
        "barracks_built",
        "towers_built",
        "units_trained",
        "central_hold_ticks",
        "town_hall_damage_dealt",
        "town_hall_damage_received",
        "hits_landed",
        "hits_received",
        "knockouts",
    )
)


def build_rts_skirmish_demo_provider(
    *,
    model: str,
    participant_id: str,
    seed: int,
    decision_budget: int,
    fixture_mode: DuoFixtureMode = "valid",
) -> DemoProvider:
    try:
        spec = RTS_SKIRMISH_MODELS[model]
    except KeyError as error:
        raise ValueError("unsupported RTS skirmish Demo model") from error
    return build_demo_provider(
        spec=spec,
        participant_id=participant_id,
        seed=seed,
        decision_budget=decision_budget,
        behavior=_behavior,
        fixture_mode=fixture_mode,
    )


def _behavior(request: ProviderRequest, lock: DemoPolicyLock, call_index: int) -> bytes:
    spec = RTS_SKIRMISH_MODELS.get(request.model)
    if (
        spec is None
        or lock.scenario_id != RTS_SKIRMISH_SCENARIO_ID
        or lock.policy_id != spec.policy_id
    ):
        raise ValueError("RTS skirmish policy lock is incompatible")
    entities = parse_visible_observation(request)
    town = select_visible_entity(entities, kinds=("town_hall",), required_affordance="deposit")
    barracks = select_visible_entity(entities, kinds=("barracks",), required_affordance="build")
    tower = select_visible_entity(entities, kinds=("tower",), required_affordance="build")
    central = select_visible_entity(
        entities, kinds=("central_beacon",), required_affordance="capture"
    )
    rival = select_visible_entity(entities, kinds=("operator",), required_affordance="hostile")
    root = _self(request)
    carrying = bool(root["carrying"])
    squad_ready = bool(root["squad_ready"])
    can_build = bool(root["stored_wood"]) and bool(root["stored_ore"])
    resource = _resource(
        entities,
        need_wood=not bool(root["stored_wood"]),
        need_ore=not bool(root["stored_ore"]),
    )

    if carrying:
        control, intent = _toward_or_button(
            town, "interact", "deposit material at the visible Town Hall"
        )
    elif can_build and barracks is not None and barracks["state"] in {"unbuilt", "building"}:
        control, intent = _toward_or_button(barracks, "ability_1", "construct the visible barracks")
    elif (
        can_build
        and tower is not None
        and tower["state"] in {"unbuilt", "building"}
        and call_index >= 10
    ):
        control, intent = _toward_or_button(tower, "ability_1", "construct the visible tower")
    elif (
        bool(root["stored_wood"])
        and barracks is not None
        and barracks["state"] == "active"
        and not squad_ready
    ):
        control, intent = _toward_or_button(barracks, "ability_2", "train a visible barracks unit")
    elif (
        spec.variant == "commander"
        and rival is not None
        and rival["distance"] in {"touching", "near"}
    ):
        control, intent = _toward_or_button(
            rival, "primary", "attack the participant-visible rival"
        )
    elif central is not None and squad_ready:
        control, intent = _toward_or_button(
            central, "guard", "rally and hold the visible central objective"
        )
    elif resource is not None:
        control, intent = _toward_or_button(resource, "interact", "gather visible RTS material")
    elif spec.variant == "commander" and rival is not None:
        control, intent = _toward_or_button(rival, None, "rally toward the visible rival")
    else:
        # A bounded scan is valid controller input and cannot leak a target transform.
        control = ControllerState(0, 0, -100, 0, FIXED_DUO_WINDOW_TICKS)
        intent = "scan for a participant-visible RTS objective"
    return direct_action(
        request,
        call_index=call_index,
        action_prefix="rts_skirmish",
        control=control,
        intent=f"Demo: {intent}",
    )


def _self(request: ProviderRequest) -> Mapping[str, bool]:
    from ..protocol import strict_json_loads

    value = strict_json_loads(request.observation_json)
    if not isinstance(value, Mapping) or not isinstance(value.get("self"), Mapping):
        raise ValueError("RTS skirmish requires visible self state")
    self_state = value["self"]
    status = self_state.get("status")
    inventory = self_state.get("inventory")
    if not isinstance(status, list) or any(not isinstance(item, str) for item in status):
        raise ValueError("RTS status is malformed")
    if not isinstance(inventory, list):
        raise ValueError("RTS inventory is malformed")
    return {
        "carrying": "carrying" in status,
        "squad_ready": "squad_ready" in status,
        "stored_wood": "stored_wood" in status,
        "stored_ore": "stored_ore" in status,
    }


def _resource(
    entities: tuple[Mapping[str, Any], ...], *, need_wood: bool, need_ore: bool
) -> Mapping[str, Any] | None:
    kinds: tuple[str, ...] = ()
    if need_wood:
        kinds += ("resource_wood",)
    if need_ore:
        kinds += ("resource_ore",)
    if not kinds:
        kinds = ("resource_wood", "resource_ore")
    for kind in kinds:
        value = select_visible_entity(
            entities, kinds=(kind,), required_affordance="gather", states=frozenset(("available",))
        )
        if value is not None:
            return value
    return None


def _toward_or_button(
    entity: Mapping[str, Any] | None, button: str | None, intent: str
) -> tuple[ControllerState, str]:
    if entity is None:
        return ControllerState(0, 0, -100, 0, FIXED_DUO_WINDOW_TICKS), intent
    if entity["bearing"] != "front":
        direction = -100 if entity["bearing"] in {"front_left", "left", "back_left"} else 100
        return ControllerState(0, 0, direction, 0, FIXED_DUO_WINDOW_TICKS), intent
    if entity["distance"] != "touching":
        return ControllerState(0, 1000, 0, 0, FIXED_DUO_WINDOW_TICKS), intent
    buttons = ControllerButtons(**{button: True}) if button is not None else ControllerButtons()
    return ControllerState(0, 0, 0, 0, FIXED_DUO_WINDOW_TICKS, buttons), intent


def evaluate_rts_skirmish(authority_aggregates: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(authority_aggregates, Mapping) or set(authority_aggregates) != _FIELDS:
        raise ValueError("RTS skirmish authority aggregates have invalid fields")
    completion_tick = validate_completion_tick(authority_aggregates["completion_tick"])
    summaries = validate_two_participant_summaries(
        authority_aggregates["participants"], extra_fields=_EXTRA
    )
    outcome = authority_aggregates["terminal_outcome"]
    reason = authority_aggregates["terminal_reason"]
    validate_match_outcomes(summaries, outcome)
    if reason not in {
        "town_hall_destroyed",
        "central_objective",
        "time_limit_score",
        "time_limit_draw",
        "void",
    }:
        raise ValueError("RTS skirmish terminal reason is invalid")
    if outcome != "void" and completion_tick is None:
        raise ValueError("finished RTS skirmish requires completion tick")
    for _, summary in summaries:
        if summary["deposits"] > summary["materials_gathered"]:
            raise ValueError("RTS deposits exceed gathered materials")
    participants, symmetry = participant_window_projection(
        summaries, extra_fields=tuple(sorted(_EXTRA))
    )
    return {
        "schema_version": "rts-skirmish-evaluation/1",
        "scope": "duo_game",
        "task_id": RTS_SKIRMISH_SCENARIO_ID,
        "completion": {"tick": completion_tick, "outcome": outcome, "reason": reason},
        "participants": participants,
        "symmetry": symmetry,
    }


__all__ = [
    "RTS_SKIRMISH_MODELS",
    "RTS_SKIRMISH_SCENARIO_ID",
    "build_rts_skirmish_demo_provider",
    "evaluate_rts_skirmish",
]
