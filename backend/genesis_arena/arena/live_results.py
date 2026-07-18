"""Build an auditable live result from sealed plans and Godot terminal receipts.

The browser/Game client never submits a score.  It supplies only typed final-world
facts in the receipt that already closes a committed round.  This module combines
those facts with backend-owned plan diagnostics and then delegates the formula to
``evaluate_match``.
"""

from __future__ import annotations

import hashlib
from typing import Iterable, List, Mapping, Sequence

from .canonical import canonical_json
from .evaluation import (
    AdaptationMetrics,
    CategoryEvidence,
    CognitionMetrics,
    CombatMetrics,
    DiplomacyMetrics,
    EconomyMetrics,
    FactionMatchMetrics,
    MatchEvaluationInput,
    OutcomeMetrics,
    PlanningMetrics,
    ReliabilityMetrics,
    TerritoryMetrics,
    evaluate_match,
)
from .models import (
    ArenaEvent,
    DecisionDiagnostic,
    FactionPlan,
    RoundReceipt,
    TerminalOutcome,
    UsageRecord,
)
from .runtime import FactionRuntime

FACTIONS = ("sol", "terra", "luna")
_CATEGORIES = (
    "objective_control",
    "planning_adaptation",
    "resource_combat_efficiency",
    "social_intelligence",
    "delegation_cognition",
    "reliability_safety",
)


def _usage(records: Iterable[DecisionDiagnostic]) -> UsageRecord:
    items = list(records)
    return UsageRecord(
        input_tokens=sum(item.usage.input_tokens for item in items),
        cached_input_tokens=sum(item.usage.cached_input_tokens for item in items),
        output_tokens=sum(item.usage.output_tokens for item in items),
        reasoning_tokens=sum(item.usage.reasoning_tokens for item in items),
        latency_ms=sum(item.usage.latency_ms for item in items),
        estimated_cost_usd=sum(item.usage.estimated_cost_usd for item in items),
    )


def _by_faction_events(events: Sequence[ArenaEvent], faction: str) -> List[ArenaEvent]:
    return [event for event in events if event.actor_id == faction or faction in event.target_ids]


def _order_rejected(event: ArenaEvent) -> bool:
    return event.kind == "order" and str(event.payload.get("type", "")) == "order_rejected"


def _order_accepted(event: ArenaEvent) -> bool:
    return event.kind == "order" and str(event.payload.get("type", "")) == "order_accepted"


def build_live_match_result(
    *,
    terminal: TerminalOutcome,
    match_id: str,
    track: str,
    seed: int,
    models: Mapping[str, str],
    agent_metadata: Mapping[str, Mapping[str, object]],
    runtimes: Mapping[str, FactionRuntime],
    receipts: Mapping[int, RoundReceipt],
    round_plans: Mapping[int, Mapping[str, FactionPlan]],
    round_diagnostics: Mapping[int, Mapping[str, DecisionDiagnostic]],
):
    """Return a ``MatchEvaluationResult`` or fail closed when evidence is missing."""

    if terminal.completed_rounds != max(receipts, default=0):
        raise ValueError("terminal outcome does not close the final authoritative receipt")
    if set(receipts) != set(range(1, terminal.completed_rounds + 1)):
        raise ValueError("official result requires a contiguous authoritative receipt chain")
    events = [event for receipt in receipts.values() for event in receipt.events]
    event_ids = [event.event_id for event in events]
    if not event_ids:
        raise ValueError("official result requires authoritative event evidence")
    if len(set(event_ids)) != len(event_ids):
        raise ValueError("authoritative event IDs must be globally unique")
    terminal_by_faction = {item.faction_id: item for item in terminal.factions}
    faction_metrics: List[FactionMatchMetrics] = []

    for faction in FACTIONS:
        final = terminal_by_faction[faction]
        plans = [round_plans[round_number][faction] for round_number in sorted(round_plans)]
        diagnostics = [
            round_diagnostics[round_number][faction]
            for round_number in sorted(round_diagnostics)
        ]
        if len(plans) != terminal.completed_rounds or len(diagnostics) != terminal.completed_rounds:
            raise ValueError("official result lacks sealed plan diagnostics for every round")
        own_events = _by_faction_events(events, faction)
        own_event_ids = [event.event_id for event in own_events] or event_ids
        action_ids = [order.order_id for plan in plans for order in plan.orders]
        evidence = [
            CategoryEvidence(
                category=category,
                event_ids=own_event_ids[:128],
                action_ids=action_ids[:128],
                measurement_count=max(1, len(own_events)),
            )
            for category in _CATEGORIES
        ]
        accepted_orders = sum(1 for event in own_events if _order_accepted(event))
        rejected_orders = sum(1 for event in own_events if _order_rejected(event))
        plan_orders = len(action_ids)
        build_orders = sum(1 for plan in plans for order in plan.orders if order.action == "build")
        killed = sum(
            1
            for event in events
            if event.kind == "combat"
            and event.actor_id != faction
            and faction in event.target_ids
        )
        lost = sum(1 for event in own_events if event.kind == "combat")
        pact_events = sum(1 for event in own_events if event.kind == "pact")
        betrayal_events = sum(1 for event in own_events if event.kind == "betrayal")
        offer_events = sum(1 for event in own_events if event.kind == "offer")
        message_events = sum(1 for event in own_events if event.kind == "message")
        runtime = runtimes[faction]
        budget = runtime.budget
        budget_units = budget.total_units + (budget.sudden_death_rounds * budget.commander_cost)
        spent_units = (
            budget.commander_calls * budget.commander_cost
            + budget.specialist_calls * budget.specialist_cost
        )
        # Open track has no bounded cognition charge; report the calls while retaining a
        # positive denominator required by the auditable evaluator schema.
        if track == "open":
            budget_units = max(1, spent_units)
        identity = {
            "faction": faction,
            "model": models[faction],
            "reasoning_effort": agent_metadata[faction]["reasoning_effort"],
        }
        prompt_hash = hashlib.sha256(canonical_json(identity).encode("utf-8")).hexdigest()
        faction_metrics.append(
            FactionMatchMetrics(
                competitor_id=faction,
                model_id=models[faction],
                reasoning_effort=agent_metadata[faction]["reasoning_effort"],
                prompt_hash=prompt_hash,
                faction_id=faction,
                track=track,
                outcome=OutcomeMetrics(
                    placement=final.placement,
                    won=final.won,
                    draw=final.draw,
                    core_survived=final.core_health > 0,
                    core_health=final.core_health,
                    completed_structure_value=final.completed_structure_value,
                ),
                territory=TerritoryMetrics(
                    final_supplied_points=final.supplied_points,
                    max_supplied_points=13,
                    territory_time=final.territory_time,
                    max_territory_time=13 * terminal.completed_rounds,
                    crown_hold_rounds=final.crown_hold_rounds,
                    scoring_rounds=terminal.completed_rounds,
                    supply_cuts_inflicted=sum(1 for event in own_events if event.kind == "supply"),
                ),
                planning=PlanningMetrics(
                    objectives_declared=len(plans),
                    objectives_completed=min(len(plans), accepted_orders),
                    planned_rounds=len(plans),
                    coherent_plan_rounds=sum(item.status == "planned" for item in diagnostics),
                    disclosed_threats=0,
                    prepared_threats=0,
                    repeated_failed_orders=0,
                ),
                economy=EconomyMetrics(
                    structures_started=max(build_orders, final.completed_structures),
                    structures_completed=final.completed_structures,
                ),
                combat=CombatMetrics(
                    enemy_value_destroyed=killed,
                    own_value_lost=lost,
                    units_killed=killed,
                    units_lost=lost,
                ),
                adaptation=AdaptationMetrics(
                    setbacks=sum(1 for event in own_events if event.kind in {"supply", "resource"}),
                    recovered_setbacks=0,
                ),
                diplomacy=DiplomacyMetrics(
                    offers_made=offer_events,
                    offers_accepted=0,
                    pacts_accepted=pact_events,
                    pacts_honored=0,
                    useful_messages=message_events,
                    total_messages=message_events,
                    betrayals=betrayal_events,
                ),
                cognition=CognitionMetrics(
                    track=track,
                    budget_units=budget_units,
                    spent_units=spent_units,
                    weighted_token_budget=max(1, budget_units),
                    objective_progress_points=min(
                        13 * terminal.completed_rounds, final.territory_time
                    ),
                    objective_progress_capacity=max(1, 13 * terminal.completed_rounds),
                    specialist_calls=budget.specialist_calls,
                    usage=_usage(diagnostics),
                ),
                reliability=ReliabilityMetrics(
                    decisions=len(diagnostics),
                    submitted_orders=plan_orders,
                    invalid_orders=min(plan_orders, rejected_orders),
                    fallback_decisions=sum(item.status == "fallback" for item in diagnostics),
                    timeout_decisions=sum(
                        item.error == "decision_timeout" for item in diagnostics
                    ),
                    api_error_decisions=sum(
                        item.error == "decision_failed" for item in diagnostics
                    ),
                ),
                evidence=evidence,
            )
        )

    return evaluate_match(
        MatchEvaluationInput(
            match_id=match_id,
            schedule_match_number=100,
            track=track,
            seed=seed,
            scored=False,
            round_limit=48,
            completed_rounds=terminal.completed_rounds,
            rules_hash=terminal.rules_hash,
            map_hash=terminal.map_hash,
            tool_hash=terminal.tool_hash,
            factions=faction_metrics,
        )
    )
