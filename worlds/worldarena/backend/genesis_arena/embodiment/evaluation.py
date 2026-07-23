"""Deterministic evaluation derived only from replay authority and provider telemetry."""

from __future__ import annotations

from collections import defaultdict
from typing import Any, Iterable, Mapping, Sequence, Tuple

from .protocol import canonical_json_bytes
from .providers.contracts import ProviderAuditRecord

EVALUATION_SCHEMA_VERSION = "llm-controller/evaluation/1.0.0"

_SOLO_PROGRESS_EVENTS = frozenset(
    {
        "beacon_entered",
        "resource_gathered",
        "material_deposited",
        "barricade_completed",
        "neutral_damaged",
        "relay_activated",
    }
)
_INEFFECTIVE_CODES = frozenset(
    {
        "construction_insufficient_material",
        "construction_misaligned",
        "construction_out_of_range",
        "dash_rejected",
        "decision_invalid",
        "guard_failed",
        "interaction_misaligned",
        "interaction_out_of_range",
        "movement_blocked",
        "no_input",
        "nothing_to_deposit",
        "primary_cooldown",
        "primary_missed",
        "primary_rejected",
        "relay_out_of_range",
    }
)


def evaluate_solo_replay(
    replay: Mapping[str, Any],
    telemetry_records: Sequence[Mapping[str, Any]] = (),
    *,
    replay_verified: bool,
    scenario_id: str | None = None,
    evaluation_profile_id: str | None = None,
) -> Mapping[str, Any]:
    """Evaluate one verified solo replay without consulting prompts, prose, or UI state."""

    if (scenario_id is None) != (evaluation_profile_id is None):
        raise ValueError("solo evaluation identity is incomplete")
    if scenario_id == "multi-action-demo-v0":
        if evaluation_profile_id != "solo-multi-action-showcase-v1":
            raise ValueError("multi-action evaluation profile differs")
        validate_multi_action_showcase_replay(replay)

    receipts = _participant_receipts(replay)
    events = _events(replay)
    decisions = _participant_decisions(replay)
    accepted = sum(1 for receipt in receipts if receipt.get("accepted") is True)
    total = len(receipts)
    progress = [event for event in events if event.get("kind") in _SOLO_PROGRESS_EVENTS]
    controls = [_control_fingerprint(decision) for decision in decisions]
    controller_changes = sum(
        1 for previous, current in zip(controls, controls[1:]) if previous != current
    )
    ineffective = [
        receipt.get("accepted") is not True
        or bool(_codes(receipt).intersection(_INEFFECTIVE_CODES))
        for receipt in receipts
    ]
    repeated_windows, longest_run = _repeated_true_runs(ineffective)
    latency, tokens = _provider_efficiency(telemetry_records)
    terminal = replay["final_terminal"]
    value: dict[str, Any] = {
        "schema_version": EVALUATION_SCHEMA_VERSION,
        "scope": "solo",
        "metrics": {
            "task_success": _supported(terminal.get("outcome") == "success"),
            "completion_tick": _supported(_completion_tick(replay)),
            "progress_checkpoints_reached": _supported(
                {
                    "count": len(progress),
                    "event_kinds": [str(event["kind"]) for event in progress],
                }
            ),
            "valid_action_rate": _supported(_ratio(accepted, total)),
            "controller_changes": _supported(controller_changes),
            "total_held_ticks": _supported(
                sum(int(receipt.get("applied_ticks", 0)) for receipt in receipts)
            ),
            "path_efficiency": _unsupported("shortest_legal_route_not_recorded"),
            "unnecessary_collisions": _supported(
                sum("movement_blocked" in _codes(receipt) for receipt in receipts)
            ),
            "interaction_alignment_failures": _supported(
                sum(
                    bool(
                        _codes(receipt).intersection(
                            {"interaction_misaligned", "construction_misaligned"}
                        )
                    )
                    for receipt in receipts
                )
            ),
            "damage_taken": _supported(_effect_total(receipts, "damage_taken")),
            "recovery_quality": _unsupported("normative_recovery_baseline_not_recorded"),
            "repeated_ineffective_windows": _supported(
                {
                    "longest_run": longest_run,
                    "windows_in_repeated_runs": repeated_windows,
                }
            ),
            "memory_consistency": _unsupported("runner_memory_not_in_authority_replay"),
            "provider_token_efficiency": tokens,
            "provider_latency_efficiency": latency,
            "deterministic_replay_verification": _supported(replay_verified),
        },
    }
    if scenario_id is not None and evaluation_profile_id is not None:
        value["scenario_id"] = scenario_id
        value["evaluation_profile_id"] = evaluation_profile_id
    return value


def validate_multi_action_showcase_replay(replay: Mapping[str, Any]) -> None:
    """Reject a showcase claim unless sealed authority proves its full visible sequence."""

    completion_tick = _completion_tick(replay)
    terminal = replay.get("final_terminal")
    if not 900 <= completion_tick <= 1_200:
        raise ValueError("multi-action completion tick is outside the profile")
    if not isinstance(terminal, Mapping) or terminal.get("outcome") != "success":
        raise ValueError("multi-action terminal outcome is not success")

    turn_step: int | None = None
    walk_step: int | None = None
    milestones: dict[str, int] = {}
    required = (
        "resource_gathered",
        "material_deposited",
        "barricade_completed",
        "episode_succeeded",
    )
    participant_id = str(replay["config"]["participant_ids"][0])
    for step_index, step in enumerate(replay["steps"]):
        receipt = step["result"]["receipts"][participant_id]
        decision = step["decision_window"]["decisions"][participant_id]
        if receipt.get("accepted") is True:
            effects = receipt.get("effects")
            if isinstance(effects, list):
                if turn_step is None and any(
                    effect.get("kind") == "heading_steps"
                    and _integer(effect.get("value"))
                    and int(effect["value"]) > 0
                    for effect in effects
                    if isinstance(effect, Mapping)
                ):
                    turn_step = step_index
                if walk_step is None and any(
                    effect.get("kind") == "distance_moved_mt"
                    and _integer(effect.get("value"))
                    and int(effect["value"]) > 0
                    for effect in effects
                    if isinstance(effect, Mapping)
                ):
                    walk_step = step_index
            control = _decision_control(decision)
            if (
                turn_step is None
                and control is not None
                and _integer(control.get("look_x"))
                and int(control["look_x"]) != 0
            ):
                turn_step = step_index
            if walk_step is None and control is not None and any(
                _integer(control.get(axis)) and int(control[axis]) != 0
                for axis in ("move_x", "move_y")
            ):
                walk_step = step_index
        for event in step["result"]["public_events"]:
            kind = event.get("kind") if isinstance(event, Mapping) else None
            if isinstance(kind, str) and kind in required and kind not in milestones:
                milestones[kind] = step_index

    if turn_step is None or walk_step is None:
        raise ValueError("multi-action turn/walk evidence is missing")
    if any(kind not in milestones for kind in required):
        raise ValueError("multi-action milestone evidence is incomplete")
    ordered = [milestones[kind] for kind in required]
    # Construction authority emits `barricade_completed` and terminal `episode_succeeded` from
    # the same final authoritative step. Gather and deposit must still precede completion, while
    # success may be co-ticked with (or follow) the completed barricade. The fixed map begins with
    # the resource already ahead, so its first required turn occurs while carrying the gathered
    # load toward the relay; walking must nevertheless begin before that first gather.
    if not (
        ordered[0] < ordered[1] < ordered[2] <= ordered[3]
        and turn_step <= ordered[1]
        and walk_step <= ordered[0]
    ):
        raise ValueError("multi-action milestone evidence is out of order")


def evaluate_paired_duel_replays(
    *,
    replays: Tuple[Mapping[str, Any], Mapping[str, Any]],
    provider_audits: Tuple[Tuple[ProviderAuditRecord, ...], Tuple[ProviderAuditRecord, ...]],
    participant_to_entrant: Tuple[Mapping[str, str], Mapping[str, str]],
    entrant_ids: Tuple[str, str],
    entrant_wins: Tuple[int, int],
    draws: int,
    winner_entrant_id: str | None,
    replay_verified: Tuple[bool, bool],
) -> Tuple[Mapping[str, Any], Mapping[str, Any]]:
    """Return two leg evaluations with one identical side-normalized pair aggregate."""

    leg_values = tuple(
        _duel_leg_metrics(
            replay=replays[index],
            audits=provider_audits[index],
            participant_to_entrant=participant_to_entrant[index],
            entrant_ids=entrant_ids,
            replay_verified=replay_verified[index],
        )
        for index in (0, 1)
    )
    side_normalized: dict[str, Any] = {}
    for entrant_index, entrant_id in enumerate(entrant_ids):
        other_index = 1 - entrant_index
        aggregate = {
            "wins": entrant_wins[entrant_index],
            "draws": draws,
            "losses": entrant_wins[other_index],
            "objective_control_ticks": 0,
            "damage_dealt": 0,
            "damage_taken": 0,
            "idle_ticks": 0,
            "valid_actions": 0,
            "total_actions": 0,
        }
        for leg in leg_values:
            entrant = leg["entrants"][entrant_id]
            aggregate["objective_control_ticks"] += entrant["objective_control_ticks"]
            aggregate["damage_dealt"] += entrant["damage_dealt"]
            aggregate["damage_taken"] += entrant["damage_taken"]
            aggregate["idle_ticks"] += entrant["idle_ticks"]
            aggregate["valid_actions"] += entrant["valid_actions"]
            aggregate["total_actions"] += entrant["total_actions"]
        aggregate["valid_action_rate"] = _ratio(
            aggregate.pop("valid_actions"), aggregate.pop("total_actions")
        )
        side_normalized[entrant_id] = aggregate
    pair_metrics = {
        "series_result": _supported(
            {
                "draws": draws,
                "entrant_wins": {
                    entrant_ids[0]: entrant_wins[0],
                    entrant_ids[1]: entrant_wins[1],
                },
                "winner_entrant_id": winner_entrant_id,
            }
        ),
        "side_normalized_performance": _supported(side_normalized),
        "deterministic_replay_verification": _supported(all(replay_verified)),
    }
    return tuple(
        {
            "schema_version": EVALUATION_SCHEMA_VERSION,
            "scope": "paired_duel_leg",
            "leg_index": index,
            "metrics": leg_values[index]["metrics"],
            "entrants": leg_values[index]["entrants"],
            "pair_metrics": pair_metrics,
        }
        for index in (0, 1)
    )  # type: ignore[return-value]


def _duel_leg_metrics(
    *,
    replay: Mapping[str, Any],
    audits: Tuple[ProviderAuditRecord, ...],
    participant_to_entrant: Mapping[str, str],
    entrant_ids: Tuple[str, str],
    replay_verified: bool,
) -> Mapping[str, Any]:
    receipts_by_participant = _receipts_by_participant(replay)
    decisions_by_participant = _decisions_by_participant(replay)
    events = _events(replay)
    final_tick = _completion_tick(replay)
    control_ticks = _objective_control_ticks(events, final_tick)
    incoming_raw: dict[str, int] = defaultdict(int)
    damage_taken: dict[str, int] = defaultdict(int)
    for event in events:
        data = event.get("data")
        if not isinstance(data, Mapping):
            continue
        if event.get("kind") == "primary_hit":
            target = data.get("target")
            damage = data.get("damage")
            if isinstance(target, str) and _integer(damage):
                incoming_raw[target] += int(damage)
        elif event.get("kind") == "operator_damaged":
            target = data.get("participant_id")
            damage = data.get("damage")
            if isinstance(target, str) and _integer(damage):
                damage_taken[target] += int(damage)

    telemetry_by_entrant: dict[str, list[Mapping[str, Any]]] = {
        entrant_id: [] for entrant_id in entrant_ids
    }
    for audit in audits:
        entrant_id = participant_to_entrant[audit.request.participant_id]
        telemetry_by_entrant[entrant_id].append(audit.result.telemetry.as_dict())

    entrants: dict[str, Any] = {}
    for participant_id, entrant_id in participant_to_entrant.items():
        receipts = receipts_by_participant[participant_id]
        decisions = decisions_by_participant[participant_id]
        accepted = sum(receipt.get("accepted") is True for receipt in receipts)
        idle_ticks = sum(
            int(receipt.get("applied_ticks", 0))
            for receipt, decision in zip(receipts, decisions)
            if _idle_decision(decision)
        )
        prevented = max(0, incoming_raw[participant_id] - damage_taken[participant_id])
        latency, tokens = _provider_efficiency(telemetry_by_entrant[entrant_id])
        entrants[entrant_id] = {
            "participant_id": participant_id,
            "objective_control_ticks": control_ticks.get(participant_id, 0),
            "damage_dealt": sum(
                damage_taken[other] for other in participant_to_entrant if other != participant_id
            ),
            "damage_taken": damage_taken[participant_id],
            "guard_efficiency": _ratio(prevented, incoming_raw[participant_id]),
            "valid_actions": accepted,
            "total_actions": len(receipts),
            "action_validity": _ratio(accepted, len(receipts)),
            "idle_ticks": idle_ticks,
            "oscillation": _oscillation_count(decisions),
            "provider_token_efficiency": tokens,
            "provider_latency_efficiency": latency,
        }
    return {
        "entrants": entrants,
        "metrics": {
            "positional_advantage": _unsupported("exact_positions_not_in_public_replay"),
            "disengagement_success": _unsupported("disengagement_outcome_not_typed"),
            "adaptation_after_losing_exchange": _unsupported("exchange_loss_boundary_not_typed"),
            "deterministic_replay_verification": _supported(replay_verified),
        },
    }


def _provider_efficiency(
    values: Sequence[Mapping[str, Any]],
) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
    if not values:
        unavailable = _unsupported("provider_telemetry_not_recorded")
        return unavailable, unavailable
    latencies = [value.get("latency_ms") for value in values]
    if any(not _integer(value) or int(value) < 0 for value in latencies):
        latency = _unsupported("provider_latency_not_recorded")
    else:
        latency_values = [int(value) for value in latencies]
        latency = _supported(
            {
                "calls": len(latency_values),
                "maximum_ms": max(latency_values),
                "mean_ms": sum(latency_values) // len(latency_values),
                "total_ms": sum(latency_values),
            }
        )
    input_tokens = [value.get("input_tokens") for value in values]
    output_tokens = [value.get("output_tokens") for value in values]
    if any(not _integer(value) or int(value) < 0 for value in (*input_tokens, *output_tokens)):
        tokens = _unsupported("provider_token_usage_not_recorded")
    else:
        cached = [value.get("cached_input_tokens") for value in values]
        tokens = _supported(
            {
                "calls": len(values),
                "cached_input_tokens": sum(
                    int(value) for value in cached if _integer(value) and int(value) >= 0
                ),
                "input_tokens": sum(int(value) for value in input_tokens),
                "output_tokens": sum(int(value) for value in output_tokens),
            }
        )
    return latency, tokens


def _participant_receipts(replay: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    participant_id = str(replay["config"]["participant_ids"][0])
    return _receipts_by_participant(replay)[participant_id]


def _participant_decisions(replay: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    participant_id = str(replay["config"]["participant_ids"][0])
    return _decisions_by_participant(replay)[participant_id]


def _receipts_by_participant(
    replay: Mapping[str, Any],
) -> dict[str, list[Mapping[str, Any]]]:
    values: dict[str, list[Mapping[str, Any]]] = {
        str(participant_id): [] for participant_id in replay["config"]["participant_ids"]
    }
    for step in replay["steps"]:
        for participant_id, receipt in step["result"]["receipts"].items():
            values[str(participant_id)].append(receipt)
    return values


def _decisions_by_participant(
    replay: Mapping[str, Any],
) -> dict[str, list[Mapping[str, Any]]]:
    values: dict[str, list[Mapping[str, Any]]] = {
        str(participant_id): [] for participant_id in replay["config"]["participant_ids"]
    }
    for step in replay["steps"]:
        for participant_id, decision in step["decision_window"]["decisions"].items():
            values[str(participant_id)].append(decision)
    return values


def _events(replay: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    return [event for step in replay["steps"] for event in step["result"]["public_events"]]


def _completion_tick(replay: Mapping[str, Any]) -> int:
    final_receipts = replay["steps"][-1]["result"]["receipts"].values()
    return max(int(receipt["end_tick"]) for receipt in final_receipts)


def _effect_total(receipts: Iterable[Mapping[str, Any]], kind: str) -> int:
    return sum(
        int(effect.get("value", 0))
        for receipt in receipts
        for effect in receipt.get("effects", [])
        if effect.get("kind") == kind and _integer(effect.get("value"))
    )


def _codes(receipt: Mapping[str, Any]) -> set[str]:
    return {str(value) for value in receipt.get("codes", [])}


def _control_fingerprint(decision: Mapping[str, Any]) -> bytes:
    control = _decision_control(decision)
    if control is None:
        return b"no_input"
    return canonical_json_bytes(control)


def _decision_control(decision: Mapping[str, Any]) -> Mapping[str, Any] | None:
    action = decision.get("action")
    if not isinstance(action, Mapping):
        return None
    control = action.get("control")
    return control if isinstance(control, Mapping) else None


def _idle_decision(decision: Mapping[str, Any]) -> bool:
    action = decision.get("action")
    if not isinstance(action, Mapping):
        return True
    control = action.get("control")
    if not isinstance(control, Mapping):
        return True
    buttons = control.get("buttons")
    return (
        all(control.get(axis) == 0 for axis in ("move_x", "move_y", "look_x", "look_y"))
        and isinstance(buttons, Mapping)
        and not any(buttons.values())
    )


def _oscillation_count(decisions: Sequence[Mapping[str, Any]]) -> int:
    directions = [_direction(decision) for decision in decisions]
    return sum(
        previous != (0, 0, 0) and current == tuple(-value for value in previous)
        for previous, current in zip(directions, directions[1:])
    )


def _direction(decision: Mapping[str, Any]) -> tuple[int, int, int]:
    action = decision.get("action")
    control = action.get("control") if isinstance(action, Mapping) else None
    if not isinstance(control, Mapping):
        return (0, 0, 0)
    return tuple(_sign(control.get(axis)) for axis in ("move_x", "move_y", "look_x"))  # type: ignore[return-value]


def _objective_control_ticks(
    events: Sequence[Mapping[str, Any]], final_tick: int
) -> Mapping[str, int]:
    totals: dict[str, int] = defaultdict(int)
    controller: str | None = None
    started = 0
    for event in events:
        kind = event.get("kind")
        tick = event.get("tick")
        if not _integer(tick):
            continue
        if kind == "relay_control_changed":
            if controller is not None:
                totals[controller] += max(0, int(tick) - started)
            data = event.get("data")
            candidate = data.get("controller") if isinstance(data, Mapping) else None
            controller = candidate if isinstance(candidate, str) else None
            started = int(tick)
        elif kind == "relay_hold_reset" and controller is not None:
            totals[controller] += max(0, int(tick) - started)
            controller = None
    if controller is not None:
        totals[controller] += max(0, final_tick - started)
    return totals


def _repeated_true_runs(values: Sequence[bool]) -> tuple[int, int]:
    repeated = 0
    longest = 0
    current = 0
    for value in (*values, False):
        if value:
            current += 1
            continue
        if current >= 2:
            repeated += current
            longest = max(longest, current)
        current = 0
    return repeated, longest


def _ratio(numerator: int, denominator: int) -> Mapping[str, int]:
    return {
        "basis_points": 0 if denominator == 0 else numerator * 10_000 // denominator,
        "denominator": denominator,
        "numerator": numerator,
    }


def _supported(value: Any) -> Mapping[str, Any]:
    return {"status": "supported", "value": value}


def _unsupported(reason: str) -> Mapping[str, Any]:
    return {"reason": reason, "status": "unsupported"}


def _integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _sign(value: Any) -> int:
    if not _integer(value):
        return 0
    return (int(value) > 0) - (int(value) < 0)


__all__ = [
    "EVALUATION_SCHEMA_VERSION",
    "evaluate_paired_duel_replays",
    "evaluate_solo_replay",
]
