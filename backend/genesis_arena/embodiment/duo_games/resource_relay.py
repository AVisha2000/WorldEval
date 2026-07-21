"""Visible-only Demo policies and safe evaluation for the richer resource-relay game.

This module is deliberately additive.  It does not register the game with the product catalog;
the versioned protocol and managed-runtime integration own that later boundary.
"""

from __future__ import annotations

from typing import Any, Mapping

from ..contracts import ControllerButtons, ControllerState
from ..demo_provider import DemoPolicyLock, DemoProvider
from ..protocol import strict_json_loads
from ..providers.contracts import ProviderRequest
from .common import (
    FIXED_DUO_WINDOW_TICKS,
    DuoFixtureMode,
    DuoPolicySpec,
    build_demo_provider,
    direct_action,
    frozen_specs,
    interact_control,
    parse_visible_observation,
    participant_window_projection,
    select_visible_entity,
    validate_completion_tick,
    validate_match_outcomes,
    validate_two_participant_summaries,
)

RESOURCE_RELAY_SCENARIO_ID = "duo-resource-relay-v0"
RESOURCE_RELAY_OBJECTIVE_TARGET = 300
# The bounded patrol begins after the first resource-to-relay-to-barricade loop.  It is an
# evidence-locked Demo-policy rhythm, not a world coordinate or hidden authority signal.
_WARDEN_PATROL_FIRST_CALL = 21
_WARDEN_PATROL_LAST_CALL = 38
RESOURCE_RELAY_MODELS = frozen_specs(
    {
        "resource-relay-alpha-v1": DuoPolicySpec(
            RESOURCE_RELAY_SCENARIO_ID,
            "resource-relay-alpha-visible-v1",
            "resource-relay-alpha-v1",
            "harvester",
        ),
        "resource-relay-bravo-v1": DuoPolicySpec(
            RESOURCE_RELAY_SCENARIO_ID,
            "resource-relay-bravo-visible-v1",
            "resource-relay-bravo-v1",
            "warden",
        ),
    }
)

_RESOURCE_RELAY_FIELDS = frozenset(
    ("completion_tick", "terminal_outcome", "terminal_reason", "objective_target", "participants")
)
_PARTICIPANT_FIELDS = frozenset(
    (
        "resources_gathered",
        "deposits",
        "objective_score",
        "builds_completed",
        "defend_ticks",
        "hits_landed",
        "hits_received",
        "knockouts",
        "resources_dropped",
        "dash_uses",
        "guard_ticks",
    )
)


def build_resource_relay_demo_provider(
    *,
    model: str,
    participant_id: str,
    seed: int,
    decision_budget: int,
    fixture_mode: DuoFixtureMode = "valid",
) -> DemoProvider:
    """Build a deterministic, keyless policy that sees participant-local semantics only."""

    try:
        spec = RESOURCE_RELAY_MODELS[model]
    except KeyError as error:
        raise ValueError("unsupported resource-relay Demo model") from error
    return build_demo_provider(
        spec=spec,
        participant_id=participant_id,
        seed=seed,
        decision_budget=decision_budget,
        behavior=_resource_relay_behavior,
        fixture_mode=fixture_mode,
    )


def _resource_relay_behavior(
    request: ProviderRequest, lock: DemoPolicyLock, call_index: int
) -> bytes:
    spec = RESOURCE_RELAY_MODELS.get(request.model)
    if (
        spec is None
        or lock.scenario_id != RESOURCE_RELAY_SCENARIO_ID
        or lock.policy_id != spec.policy_id
    ):
        raise ValueError("resource-relay policy lock is incompatible")
    entities = parse_visible_observation(request)
    root = strict_json_loads(request.observation_json)
    if not isinstance(root, Mapping):
        raise ValueError("resource-relay observation must be an object")
    self_state = root.get("self")
    if not isinstance(self_state, Mapping):
        raise ValueError("resource-relay observation requires visible self state")
    inventory = self_state.get("inventory")
    status = self_state.get("status")
    if (
        not isinstance(inventory, list)
        or any(
            not isinstance(item, Mapping)
            or set(item) != {"kind", "count", "selected"}
            or not isinstance(item["kind"], str)
            or isinstance(item["count"], bool)
            or not isinstance(item["count"], int)
            or not isinstance(item["selected"], bool)
            for item in inventory
        )
        or not isinstance(status, list)
        or any(not isinstance(item, str) for item in status)
    ):
        raise ValueError("resource-relay visible self state is malformed")

    rival = select_visible_entity(
        entities,
        kinds=("operator",),
        required_affordance="hostile",
        states=frozenset(("ready", "wounded", "critical", "guarding", "carrying")),
    )
    own_relay = select_visible_entity(
        entities,
        kinds=("relay",),
        required_affordance="deposit",
        states=frozenset(("empty", "active", "fortified")),
    )
    barricade = select_visible_entity(
        entities,
        kinds=("barricade",),
        required_affordance="build",
        states=frozenset(("unbuilt", "building", "damaged")),
    )
    resource = _select_visible_resource(entities)

    carrying = any(
        item["kind"] == "material" and item["count"] > 0 and item["selected"]
        for item in inventory
    )
    if carrying:
        control, intent = _approach_or_use(
            own_relay,
            use_button="interact",
            absent_intent="Demo: seek the visible friendly relay",
            approach_intent="Demo: carry material to the visible friendly relay",
            use_intent="Demo: deposit material at the visible friendly relay",
        )
    elif (
        spec.variant == "warden"
        and call_index >= _WARDEN_PATROL_FIRST_CALL
        and rival is not None
    ):
        # The warden only commits to combat when the rival is actually participant-visible.
        # It may never navigate to an authority coordinate or inferred opponent transform.
        if rival["bearing"] != "front":
            control = _turn_or_move_toward(rival)
            intent = "Demo: face the visible nearby rival"
        elif rival["distance"] in {"medium", "far"}:
            control = _turn_or_move_toward(rival)
            intent = "Demo: approach the visible rival"
        elif rival["state"] in {"carrying", "wounded", "critical"}:
            control = ControllerState(
                0,
                150,
                0,
                0,
                FIXED_DUO_WINDOW_TICKS,
                ControllerButtons(primary=True),
            )
            intent = "Demo: contest the visible nearby rival"
        else:
            control = ControllerState(
                0,
                0,
                0,
                0,
                FIXED_DUO_WINDOW_TICKS,
                ControllerButtons(guard=True),
            )
            intent = "Demo: guard the friendly relay"
    elif (
        own_relay is not None
        and own_relay["distance"] == "touching"
        and own_relay["state"] == "fortified"
        # A bounded sentinel window makes the fortification and guard mechanic legible in every
        # deterministic run.  The counter is private policy memory, not world knowledge.
        and _WARDEN_PATROL_FIRST_CALL <= call_index <= _WARDEN_PATROL_FIRST_CALL + 2
    ):
        control = ControllerState(
            0,
            0,
            0,
            0,
            FIXED_DUO_WINDOW_TICKS,
            ControllerButtons(guard=True),
        )
        intent = "Demo: defend the fortified friendly relay"
    elif (
        spec.variant == "warden"
        and _WARDEN_PATROL_FIRST_CALL + 1 <= call_index <= _WARDEN_PATROL_LAST_CALL
    ):
        # The two roles deliberately diverge after their shared opening economy loop.  The
        # harvester keeps collecting, while the warden patrols through ordinary controller input
        # and can only engage after its camera reacquires a rival.
        control = ControllerState(
            0,
            1000,
            -100,
            0,
            FIXED_DUO_WINDOW_TICKS,
        )
        intent = "Demo: patrol to reacquire a participant-visible rival"
    elif barricade is not None and barricade["distance"] == "touching":
        control = ControllerState(
            0,
            0,
            0,
            0,
            FIXED_DUO_WINDOW_TICKS,
            ControllerButtons(ability_1=True),
        )
        intent = "Demo: build the visible friendly barricade"
    elif resource is not None:
        control, intent = _approach_or_use(
            resource,
            use_button="interact",
            absent_intent="Demo: seek a visible material resource",
            approach_intent="Demo: approach the visible material resource",
            use_intent="Demo: gather the visible material resource",
        )
    elif barricade is not None:
        control, intent = _approach_or_use(
            barricade,
            use_button="ability_1",
            absent_intent="Demo: seek the visible friendly barricade",
            approach_intent="Demo: approach the visible friendly barricade",
            use_intent="Demo: build the visible friendly barricade",
        )
    else:
        # Targets may leave the forward camera cone without ceasing to exist.  Search using a
        # bounded visible-only scan rather than silently freezing or relying on hidden map
        # coordinates.  A full 45-degree turn per window makes this recover the resource behind
        # a newly built relay without drifting the operator away from an interaction radius.
        control = ControllerState(0, 0, -100, 0, FIXED_DUO_WINDOW_TICKS)
        intent = "Demo: scan for a participant-visible objective"
    return direct_action(
        request,
        call_index=call_index,
        action_prefix="resource_relay",
        control=control,
        intent=intent,
    )


def _approach_or_use(
    entity: Mapping[str, Any] | None,
    *,
    use_button: str,
    absent_intent: str,
    approach_intent: str,
    use_intent: str,
) -> tuple[ControllerState, str]:
    if entity is None:
        # A target can leave the participant camera without ceasing to exist. Search by turning;
        # never infer a hidden bearing or coordinate from prior authority state.
        return (
            ControllerState(0, 0, 100, 0, FIXED_DUO_WINDOW_TICKS),
            absent_intent,
        )
    if entity["bearing"] != "front":
        return _turn_or_move_toward(entity), approach_intent
    if entity["distance"] != "touching":
        return _turn_or_move_toward(entity), approach_intent
    if use_button == "interact":
        return interact_control(), use_intent
    return (
        ControllerState(
            0,
            0,
            0,
            0,
            FIXED_DUO_WINDOW_TICKS,
            ControllerButtons(ability_1=True),
        ),
        use_intent,
    )


def _turn_or_move_toward(entity: Mapping[str, Any]) -> ControllerState:
    """Scale a single visible correction across the fixed ten-tick authority window."""

    bearing = entity["bearing"]
    if bearing in {"front_left", "left", "back_left"}:
        return ControllerState(0, 0, -100, 0, FIXED_DUO_WINDOW_TICKS)
    if bearing in {"front_right", "right", "back_right", "back"}:
        return ControllerState(0, 0, 100, 0, FIXED_DUO_WINDOW_TICKS)
    speed = {"far": 1000, "medium": 700, "near": 300, "touching": 0}[entity["distance"]]
    return ControllerState(0, speed, 0, 0, FIXED_DUO_WINDOW_TICKS)


def _select_visible_resource(
    entities: tuple[Mapping[str, Any], ...],
) -> Mapping[str, Any] | None:
    """Choose a gather target in participant-local space so mirrored seats stay equivalent."""

    distance_rank = {"touching": 0, "near": 1, "medium": 2, "far": 3}
    bearing_rank = {
        "front": 0,
        "front_left": 1,
        "front_right": 2,
        "left": 3,
        "right": 4,
        "back_left": 5,
        "back_right": 6,
        "back": 7,
    }
    for kind, state in (("dropped_resource", "dropped"), ("resource", "available")):
        candidates = [
            entity
            for entity in entities
            if entity.get("kind") == kind
            and entity.get("state") == state
            and "gather" in entity.get("affordances", ())
        ]
        if candidates:
            return min(
                candidates,
                key=lambda entity: (
                    distance_rank[str(entity["distance"])],
                    bearing_rank[str(entity["bearing"])],
                    str(entity["id"]),
                ),
            )
    return None


def evaluate_resource_relay(authority_aggregates: Mapping[str, Any]) -> dict[str, Any]:
    """Return public match totals, rejecting transforms and private authority state by shape."""

    if (
        not isinstance(authority_aggregates, Mapping)
        or set(authority_aggregates) != _RESOURCE_RELAY_FIELDS
    ):
        raise ValueError("resource-relay authority aggregates have invalid fields")
    completion_tick = validate_completion_tick(authority_aggregates["completion_tick"])
    objective_target = authority_aggregates["objective_target"]
    if (
        isinstance(objective_target, bool)
        or not isinstance(objective_target, int)
        or objective_target != RESOURCE_RELAY_OBJECTIVE_TARGET
    ):
        raise ValueError("resource-relay objective target is invalid")
    summaries = validate_two_participant_summaries(
        authority_aggregates["participants"], extra_fields=_PARTICIPANT_FIELDS
    )
    terminal_outcome = authority_aggregates["terminal_outcome"]
    terminal_reason = authority_aggregates["terminal_reason"]
    validate_match_outcomes(summaries, terminal_outcome)
    if terminal_reason not in {
        "objective_target",
        "knockout",
        "time_limit_score",
        "time_limit_draw",
        "simultaneous_knockout",
        "simultaneous_objective",
        "void",
    }:
        raise ValueError("resource-relay terminal reason is invalid")
    if terminal_outcome != "void" and completion_tick is None:
        raise ValueError("finished resource-relay evaluation requires completion tick")
    if terminal_outcome == "void" and terminal_reason != "void":
        raise ValueError("void resource-relay completion is inconsistent")
    if terminal_outcome == "win" and terminal_reason not in {
        "objective_target",
        "knockout",
        "time_limit_score",
    }:
        raise ValueError("winning resource-relay completion is inconsistent")
    if terminal_outcome == "draw" and terminal_reason not in {
        "time_limit_draw",
        "simultaneous_knockout",
        "simultaneous_objective",
    }:
        raise ValueError("drawn resource-relay completion is inconsistent")

    first = summaries[0][1]
    second = summaries[1][1]
    for _, summary in summaries:
        if summary["deposits"] > summary["resources_gathered"]:
            raise ValueError("resource-relay deposits exceed gathered resources")
        if summary["resources_dropped"] > summary["resources_gathered"]:
            raise ValueError("resource-relay drops exceed gathered resources")
        if summary["objective_score"] != summary["deposits"] * 100:
            raise ValueError("resource-relay score differs from deposits")
        if summary["builds_completed"] > summary["deposits"]:
            raise ValueError("resource-relay builds exceed deposited material")
        maximum_action_ticks = summary["decision_windows"] * FIXED_DUO_WINDOW_TICKS
        if (
            summary["defend_ticks"] > maximum_action_ticks
            or summary["guard_ticks"] > maximum_action_ticks
        ):
            raise ValueError("resource-relay action ticks exceed decision horizon")
        if summary["dash_uses"] > summary["decision_windows"]:
            raise ValueError("resource-relay dashes exceed decision windows")
    if first["hits_landed"] != second["hits_received"] or second["hits_landed"] != first[
        "hits_received"
    ]:
        raise ValueError("resource-relay hit totals are not authority-symmetric")
    if any(summary["knockouts"] > 1 for _, summary in summaries):
        raise ValueError("resource-relay knockout count exceeds one")
    if terminal_reason == "knockout":
        winner = next(summary for _, summary in summaries if summary["outcome"] == "win")
        if winner["knockouts"] != 1 or sum(summary["knockouts"] for _, summary in summaries) != 1:
            raise ValueError("resource-relay knockout is not assigned to the winner")
    elif terminal_reason == "simultaneous_knockout":
        if any(summary["knockouts"] != 1 for _, summary in summaries):
            raise ValueError("simultaneous knockout totals are inconsistent")
    elif any(summary["knockouts"] != 0 for _, summary in summaries):
        raise ValueError("non-knockout result contains knockout totals")
    if terminal_reason == "objective_target":
        winner = next(summary for _, summary in summaries if summary["outcome"] == "win")
        loser = next(summary for _, summary in summaries if summary["outcome"] == "loss")
        if (
            winner["objective_score"] < objective_target
            or loser["objective_score"] >= objective_target
        ):
            raise ValueError("resource-relay winner did not reach objective target")
    if terminal_reason == "time_limit_score":
        winner = next(summary for _, summary in summaries if summary["outcome"] == "win")
        loser = next(summary for _, summary in summaries if summary["outcome"] == "loss")
        if winner["objective_score"] <= loser["objective_score"]:
            raise ValueError("time-limit score win requires unequal scores")
    if terminal_reason in {"time_limit_draw", "simultaneous_objective"} and first[
        "objective_score"
    ] != second["objective_score"]:
        raise ValueError("drawn objective result requires equal scores")
    if terminal_reason in {"time_limit_score", "time_limit_draw"} and completion_tick != 1200:
        raise ValueError("resource-relay time-limit completion tick is inconsistent")

    extra_fields = tuple(sorted(_PARTICIPANT_FIELDS))
    participants, symmetry = participant_window_projection(summaries, extra_fields=extra_fields)
    symmetry.update(
        {
            "objective_score_delta": abs(first["objective_score"] - second["objective_score"]),
            "deposit_delta": abs(first["deposits"] - second["deposits"]),
            "hit_delta": abs(first["hits_landed"] - second["hits_landed"]),
        }
    )
    return {
        "schema_version": "duo-resource-relay-evaluation/1",
        "scope": "duo_game",
        "task_id": RESOURCE_RELAY_SCENARIO_ID,
        "completion": {
            "tick": completion_tick,
            "outcome": terminal_outcome,
            "reason": terminal_reason,
        },
        "objective_target": objective_target,
        "participants": participants,
        "symmetry": symmetry,
    }


__all__ = [
    "RESOURCE_RELAY_MODELS",
    "RESOURCE_RELAY_OBJECTIVE_TARGET",
    "RESOURCE_RELAY_SCENARIO_ID",
    "build_resource_relay_demo_provider",
    "evaluate_resource_relay",
]
