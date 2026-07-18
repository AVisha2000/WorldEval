from __future__ import annotations

import pytest
from genesis_arena.arena import (
    AdaptationMetrics,
    CategoryEvidence,
    CognitionMetrics,
    CombatMetrics,
    DecisionEvidence,
    DiplomacyMetrics,
    EconomyMetrics,
    FactionEvaluation,
    FactionMatchMetrics,
    MatchEvaluationInput,
    OutcomeMetrics,
    PlanningMetrics,
    ReliabilityMetrics,
    TerritoryMetrics,
    UsageRecord,
    evaluate_match,
)
from pydantic import ValidationError

CATEGORIES = (
    "objective_control",
    "planning_adaptation",
    "resource_combat_efficiency",
    "social_intelligence",
    "delegation_cognition",
    "reliability_safety",
)


def faction_metrics(
    faction_id: str,
    competitor_id: str,
    placement: int,
    *,
    track: str = "agentic",
    diplomacy_enabled: bool = True,
    prompt_hash: str = "c" * 64,
    include_decision_evidence: bool = True,
) -> FactionMatchMetrics:
    strength = 4 - placement
    core_health = {1: 900, 2: 500, 3: 0}[placement]
    event_ids = {category: f"evt-{faction_id}-{category}" for category in CATEGORIES}
    plan_ids = [f"{faction_id}-plan-best-a", f"{faction_id}-plan-best-b", f"{faction_id}-plan-fail"]
    evidence = [
        CategoryEvidence(
            category=category,
            event_ids=[event_ids[category]],
            action_ids=plan_ids if category == "objective_control" else [],
            measurement_count=strength + 1,
        )
        for category in CATEGORIES
    ]
    decisions = []
    if include_decision_evidence:
        decisions = [
            DecisionEvidence(
                plan_id=f"{faction_id}-plan-best-b",
                round=5,
                three_round_objective_value_delta=float(strength * 10),
                summary="Expanded supplied territory after a committed plan.",
                event_ids=[event_ids["objective_control"]],
            ),
            DecisionEvidence(
                plan_id=f"{faction_id}-plan-best-a",
                round=5,
                three_round_objective_value_delta=float(strength * 10),
                summary="Matched the largest positive objective delta.",
                event_ids=[event_ids["objective_control"]],
            ),
            DecisionEvidence(
                plan_id=f"{faction_id}-plan-fail",
                round=9,
                three_round_objective_value_delta=float(-placement * 8),
                summary="Lost supplied territory after an overextended order.",
                event_ids=[event_ids["objective_control"]],
            ),
        ]
    return FactionMatchMetrics(
        competitor_id=competitor_id,
        model_id=f"model-{competitor_id}",
        reasoning_effort="medium",
        prompt_hash=prompt_hash,
        faction_id=faction_id,
        track=track,
        outcome=OutcomeMetrics(
            placement=placement,
            won=placement == 1,
            core_survived=core_health > 0,
            core_health=core_health,
            completed_structure_value=strength * 200,
        ),
        territory=TerritoryMetrics(
            final_supplied_points=strength * 3,
            max_supplied_points=15,
            territory_time=strength * 150,
            max_territory_time=600,
            crown_hold_rounds=strength * 3,
            scoring_rounds=40,
            supply_cuts_inflicted=strength,
        ),
        planning=PlanningMetrics(
            objectives_declared=10,
            objectives_completed=strength * 3,
            planned_rounds=40,
            coherent_plan_rounds=strength * 10,
            disclosed_threats=6,
            prepared_threats=strength * 2,
            repeated_failed_orders=placement - 1,
        ),
        economy=EconomyMetrics(
            resources_gathered=strength * 300,
            resources_productively_spent=strength * 220,
            resources_wasted=(4 - strength) * 30,
            mine_active_rounds=strength * 8,
            mine_available_rounds=32,
            supply_active_rounds=strength * 10,
            supply_possible_rounds=40,
            structures_started=8,
            structures_completed=strength * 2,
            starvation_unit_rounds=(4 - strength) * 3,
            total_unit_rounds=40,
            idle_stockpile_rounds=(4 - strength) * 4,
            stockpile_observation_rounds=40,
        ),
        combat=CombatMetrics(
            enemy_value_destroyed=strength * 250,
            own_value_lost=(4 - strength) * 180,
            damage_dealt=strength * 500,
            damage_taken=(4 - strength) * 400,
            units_killed=strength * 4,
            units_lost=4 - strength,
            retreats=4,
            successful_retreats=strength,
        ),
        adaptation=AdaptationMetrics(
            setbacks=3,
            recovered_setbacks=strength - 1,
            exploitation_opportunities=4,
            successful_exploitations=strength,
            territory_regained=strength * 2,
            territory_lost_in_setbacks=8,
        ),
        diplomacy=DiplomacyMetrics(
            enabled=diplomacy_enabled,
            offers_made=4,
            offers_accepted=strength,
            trades_executed=max(0, strength - 1),
            offered_trade_value=100,
            executed_trade_value=strength * 25,
            pacts_accepted=2,
            pacts_honored=1,
            coordination_attempts=4,
            coordinations_with_physical_gain=strength,
            useful_messages=strength * 2,
            total_messages=8,
            trust_predictions=4,
            trust_brier_sum=float(4 - strength) / 2,
        ),
        cognition=CognitionMetrics(
            track=track,
            budget_units=120 if track == "agentic" else 80,
            spent_units=100 if track == "agentic" else 80,
            weighted_token_budget=100_000,
            objective_progress_points=strength * 25,
            objective_progress_capacity=100,
            specialist_calls=20 if track == "agentic" else 0,
            advice_received=18 if track == "agentic" else 0,
            advice_accepted=strength * 5 if track == "agentic" else 0,
            accepted_advice_with_progress=strength * 4 if track == "agentic" else 0,
            specialist_contradictions=placement - 1 if track == "agentic" else 0,
            wasted_specialist_calls=placement if track == "agentic" else 0,
            specialist_management_actions=6 if track == "agentic" else 0,
            effective_management_actions=strength * 2 if track == "agentic" else 0,
            usage=UsageRecord(
                input_tokens=40_000,
                cached_input_tokens=10_000,
                output_tokens=5_000,
                reasoning_tokens=2_000,
                estimated_cost_usd=0.25,
            ),
        ),
        reliability=ReliabilityMetrics(
            decisions=40,
            submitted_orders=80,
            invalid_orders=placement - 1,
            contradictory_orders=placement - 1,
            repeated_impossible_orders=placement - 1,
            fallback_decisions=placement - 1,
            successful_fallback_decisions=max(0, placement - 2),
            timeout_decisions=0,
            api_error_decisions=0,
        ),
        evidence=evidence,
        decision_evidence=decisions,
    )


def match_input(*, diplomacy_enabled: bool = True) -> MatchEvaluationInput:
    return MatchEvaluationInput(
        match_id="season-test-m001",
        schedule_match_number=1,
        track="agentic",
        seed=42,
        scored=True,
        round_limit=40,
        completed_rounds=40,
        rules_hash="a" * 64,
        map_hash="b" * 64,
        tool_hash="d" * 64,
        factions=[
            faction_metrics("sol", "alpha", 1, diplomacy_enabled=diplomacy_enabled),
            faction_metrics("terra", "beta", 2, diplomacy_enabled=diplomacy_enabled),
            faction_metrics("luna", "gamma", 3, diplomacy_enabled=diplomacy_enabled),
        ],
    )


def test_exact_six_category_formula_is_auditable_and_does_not_change_winner() -> None:
    source = match_input()
    result = evaluate_match(source)
    by_competitor = {item.competitor_id: item for item in result.factions}

    assert result.formula_version == "worldarena-score/1.0.0"
    assert result.outcome_authority == "godot"
    assert result.llm_judge_used is False
    assert result.weights == {
        "objective_control": 0.35,
        "planning_adaptation": 0.20,
        "resource_combat_efficiency": 0.15,
        "social_intelligence": 0.15,
        "delegation_cognition": 0.10,
        "reliability_safety": 0.05,
    }
    alpha = by_competitor["alpha"]
    assert alpha.placement == source.factions[0].outcome.placement
    assert alpha.won is source.factions[0].outcome.won
    assert {category.category for category in alpha.categories} == set(CATEGORIES)
    assert alpha.worldarena_score == pytest.approx(
        sum(category.weighted_contribution for category in alpha.categories)
    )
    assert alpha.raw_metrics == source.factions[0]
    assert alpha.worldarena_score > by_competitor["beta"].worldarena_score
    assert by_competitor["beta"].worldarena_score > by_competitor["gamma"].worldarena_score


def test_social_and_cognition_affect_behavioral_score_not_world_placement() -> None:
    enabled = evaluate_match(match_input(diplomacy_enabled=True))
    disabled = evaluate_match(match_input(diplomacy_enabled=False))
    enabled_alpha = enabled.factions[0]
    disabled_alpha = disabled.factions[0]
    enabled_social = next(
        item for item in enabled_alpha.categories if item.category == "social_intelligence"
    )
    disabled_social = next(
        item for item in disabled_alpha.categories if item.category == "social_intelligence"
    )

    assert disabled_social.score == 50
    assert enabled_social.score != disabled_social.score
    assert enabled_alpha.worldarena_score != disabled_alpha.worldarena_score
    assert enabled_alpha.placement == disabled_alpha.placement == 1
    assert enabled_alpha.won is disabled_alpha.won is True


def test_highlights_use_deterministic_evidence_delta_rules() -> None:
    evaluation = evaluate_match(match_input()).factions[0]

    assert evaluation.best_decision is not None
    assert evaluation.best_decision.plan_id == "sol-plan-best-a"
    assert evaluation.biggest_failure is not None
    assert evaluation.biggest_failure.plan_id == "sol-plan-fail"
    assert evaluation.best_decision.three_round_objective_value_delta > 0
    assert evaluation.biggest_failure.three_round_objective_value_delta < 0


def test_missing_or_unlinked_required_evidence_fails_closed() -> None:
    payload = faction_metrics("sol", "alpha", 1).model_dump(mode="python")
    payload["evidence"] = payload["evidence"][:5]
    with pytest.raises(ValidationError, match="at least 6 items"):
        FactionMatchMetrics.model_validate(payload)

    payload = faction_metrics("sol", "alpha", 1).model_dump(mode="python")
    payload["decision_evidence"][0]["plan_id"] = "unsupported-plan"
    with pytest.raises(ValidationError, match="supporting committed plan"):
        FactionMatchMetrics.model_validate(payload)

    payload = faction_metrics("sol", "alpha", 1).model_dump(mode="python")
    payload["decision_evidence"][0]["event_ids"] = ["unsupported-event"]
    with pytest.raises(ValidationError, match="unsupported event"):
        FactionMatchMetrics.model_validate(payload)

    evaluation_payload = evaluate_match(match_input()).factions[0].model_dump(mode="python")
    evaluation_payload["categories"][0]["weight"] = 0.34
    with pytest.raises(ValidationError, match="versioned formula"):
        FactionEvaluation.model_validate(evaluation_payload)


def test_cross_track_incomplete_and_impossible_metrics_are_rejected() -> None:
    factions = list(match_input().factions)
    factions[2] = faction_metrics("luna", "gamma", 3, track="standard")
    with pytest.raises(ValidationError, match="cross-track"):
        MatchEvaluationInput(
            **{**match_input().model_dump(mode="python"), "factions": factions}
        )

    with pytest.raises(ValidationError, match="at least 3 items"):
        MatchEvaluationInput(
            **{
                **match_input().model_dump(mode="python"),
                "factions": match_input().factions[:2],
            }
        )

    with pytest.raises(ValidationError, match="active rounds"):
        EconomyMetrics(mine_active_rounds=5, mine_available_rounds=4)
    with pytest.raises(ValidationError, match="exceed their denominator"):
        ReliabilityMetrics(decisions=1, submitted_orders=1, invalid_orders=2)
    with pytest.raises(ValidationError, match="track budget"):
        CognitionMetrics(
            track="agentic",
            budget_units=120,
            spent_units=121,
            weighted_token_budget=100,
            objective_progress_points=1,
            objective_progress_capacity=1,
        )


def test_non_draw_match_requires_one_world_winner_and_unique_placements() -> None:
    factions = list(match_input().factions)
    factions[1] = faction_metrics("terra", "beta", 1)
    with pytest.raises(ValidationError, match="unique placements"):
        MatchEvaluationInput(
            **{**match_input().model_dump(mode="python"), "factions": factions}
        )
