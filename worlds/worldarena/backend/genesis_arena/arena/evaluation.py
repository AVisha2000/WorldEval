from __future__ import annotations

# ruff: noqa: UP045 -- Pydantic evaluates annotations on the supported Python 3.9 runtime.
from typing import Dict, List, Literal, Optional

from pydantic import Field, model_validator

from .models import ArenaModel, FactionId, HashHex, Identifier, UsageRecord, MAX_CONQUEST_ROUNDS

CognitionTrack = Literal["standard", "agentic", "open"]
FormulaVersion = Literal["worldarena-score/1.1.0"]
EvidenceCategory = Literal[
    "objective_control",
    "planning_adaptation",
    "resource_combat_efficiency",
    "social_intelligence",
    "delegation_cognition",
    "reliability_safety",
]

FORMULA_VERSION: FormulaVersion = "worldarena-score/1.1.0"
CATEGORY_WEIGHTS: Dict[str, float] = {
    "objective_control": 0.35,
    "planning_adaptation": 0.20,
    "resource_combat_efficiency": 0.15,
    "social_intelligence": 0.15,
    "delegation_cognition": 0.10,
    "reliability_safety": 0.05,
}
REQUIRED_CATEGORIES = frozenset(CATEGORY_WEIGHTS)


def _ratio(numerator: float, denominator: float, *, neutral: float = 0.5) -> float:
    if denominator <= 0:
        return neutral
    return max(0.0, min(1.0, numerator / denominator))


def _avoid(count: float, denominator: float) -> float:
    return 1 - _ratio(count, denominator, neutral=0)


class OutcomeMetrics(ArenaModel):
    placement: int = Field(ge=1, le=3)
    won: bool = False
    draw: bool = False
    core_survived: bool = True
    core_health: int = Field(ge=0, le=1_000)
    completed_structure_value: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_outcome(self) -> OutcomeMetrics:
        if self.won and (self.placement != 1 or self.draw):
            raise ValueError("a winner must be sole first place, not a draw")
        if self.core_survived != (self.core_health > 0):
            raise ValueError("core_survived must agree with core_health")
        return self


class TerritoryMetrics(ArenaModel):
    final_supplied_points: int = Field(ge=0)
    max_supplied_points: int = Field(gt=0)
    territory_time: int = Field(ge=0)
    max_territory_time: int = Field(gt=0)
    enemy_strongholds_destroyed: int = Field(default=0, ge=0, le=2)
    districts_discovered: int = Field(default=0, ge=0)
    max_districts: int = Field(default=13, gt=0)
    tech_tier: int = Field(default=0, ge=0, le=3)
    max_tech_tier: int = Field(default=3, gt=0, le=3)
    scoring_rounds: int = Field(gt=0, le=MAX_CONQUEST_ROUNDS)
    supply_cuts_inflicted: int = Field(default=0, ge=0)

    @model_validator(mode="before")
    @classmethod
    def discard_legacy_center_score(cls, value: object) -> object:
        if isinstance(value, dict) and "crown_hold_rounds" in value:
            value = dict(value)
            value.pop("crown_hold_rounds", None)
        return value

    @model_validator(mode="after")
    def validate_caps(self) -> TerritoryMetrics:
        if self.final_supplied_points > self.max_supplied_points:
            raise ValueError("final supplied points exceed the map maximum")
        if self.territory_time > self.max_territory_time:
            raise ValueError("territory time exceeds the match maximum")
        if self.districts_discovered > self.max_districts:
            raise ValueError("discovered districts exceed the map maximum")
        if self.tech_tier > self.max_tech_tier:
            raise ValueError("technology tier exceeds the scenario maximum")
        return self


class PlanningMetrics(ArenaModel):
    objectives_declared: int = Field(ge=0)
    objectives_completed: int = Field(ge=0)
    planned_rounds: int = Field(ge=0)
    coherent_plan_rounds: int = Field(ge=0)
    disclosed_threats: int = Field(ge=0)
    prepared_threats: int = Field(ge=0)
    repeated_failed_orders: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_counts(self) -> PlanningMetrics:
        if self.objectives_completed > self.objectives_declared:
            raise ValueError("completed objectives exceed declared objectives")
        if self.coherent_plan_rounds > self.planned_rounds:
            raise ValueError("coherent rounds exceed planned rounds")
        if self.prepared_threats > self.disclosed_threats:
            raise ValueError("prepared threats exceed disclosed threats")
        return self


class EconomyMetrics(ArenaModel):
    resources_gathered: int = Field(default=0, ge=0)
    resources_productively_spent: int = Field(default=0, ge=0)
    resources_wasted: int = Field(default=0, ge=0)
    mine_active_rounds: int = Field(default=0, ge=0)
    mine_available_rounds: int = Field(default=0, ge=0)
    supply_active_rounds: int = Field(default=0, ge=0)
    supply_possible_rounds: int = Field(default=0, ge=0)
    structures_started: int = Field(default=0, ge=0)
    structures_completed: int = Field(default=0, ge=0)
    starvation_unit_rounds: int = Field(default=0, ge=0)
    total_unit_rounds: int = Field(default=0, ge=0)
    idle_stockpile_rounds: int = Field(default=0, ge=0)
    stockpile_observation_rounds: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_counts(self) -> EconomyMetrics:
        for numerator, denominator, label in (
            (self.mine_active_rounds, self.mine_available_rounds, "mine active rounds"),
            (self.supply_active_rounds, self.supply_possible_rounds, "supply active rounds"),
            (self.structures_completed, self.structures_started, "completed structures"),
            (self.starvation_unit_rounds, self.total_unit_rounds, "starvation unit rounds"),
            (
                self.idle_stockpile_rounds,
                self.stockpile_observation_rounds,
                "idle stockpile rounds",
            ),
        ):
            if numerator > denominator:
                raise ValueError(f"{label} exceed their denominator")
        return self


class CombatMetrics(ArenaModel):
    enemy_value_destroyed: int = Field(default=0, ge=0)
    own_value_lost: int = Field(default=0, ge=0)
    damage_dealt: int = Field(default=0, ge=0)
    damage_taken: int = Field(default=0, ge=0)
    units_killed: int = Field(default=0, ge=0)
    units_lost: int = Field(default=0, ge=0)
    retreats: int = Field(default=0, ge=0)
    successful_retreats: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_retreats(self) -> CombatMetrics:
        if self.successful_retreats > self.retreats:
            raise ValueError("successful retreats exceed attempted retreats")
        return self


class AdaptationMetrics(ArenaModel):
    setbacks: int = Field(default=0, ge=0)
    recovered_setbacks: int = Field(default=0, ge=0)
    exploitation_opportunities: int = Field(default=0, ge=0)
    successful_exploitations: int = Field(default=0, ge=0)
    territory_regained: int = Field(default=0, ge=0)
    territory_lost_in_setbacks: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_counts(self) -> AdaptationMetrics:
        if self.recovered_setbacks > self.setbacks:
            raise ValueError("recoveries exceed setbacks")
        if self.successful_exploitations > self.exploitation_opportunities:
            raise ValueError("successful exploitations exceed opportunities")
        return self


class DiplomacyMetrics(ArenaModel):
    enabled: bool = True
    offers_made: int = Field(default=0, ge=0)
    offers_accepted: int = Field(default=0, ge=0)
    trades_executed: int = Field(default=0, ge=0)
    offered_trade_value: int = Field(default=0, ge=0)
    executed_trade_value: int = Field(default=0, ge=0)
    pacts_accepted: int = Field(default=0, ge=0)
    pacts_honored: int = Field(default=0, ge=0)
    coordination_attempts: int = Field(default=0, ge=0)
    coordinations_with_physical_gain: int = Field(default=0, ge=0)
    useful_messages: int = Field(default=0, ge=0)
    total_messages: int = Field(default=0, ge=0)
    betrayals: int = Field(default=0, ge=0)
    territory_gain_after_betrayal: int = Field(default=0, ge=0)
    trust_predictions: int = Field(default=0, ge=0)
    trust_brier_sum: float = Field(default=0, ge=0)
    coalition_rounds: int = Field(default=0, ge=0)
    communication_cognition_units: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_counts(self) -> DiplomacyMetrics:
        for numerator, denominator, label in (
            (self.offers_accepted, self.offers_made, "accepted offers"),
            (self.trades_executed, self.offers_accepted, "executed trades"),
            (self.executed_trade_value, self.offered_trade_value, "executed trade value"),
            (self.pacts_honored, self.pacts_accepted, "honored pacts"),
            (
                self.coordinations_with_physical_gain,
                self.coordination_attempts,
                "coordinations with physical gain",
            ),
            (self.useful_messages, self.total_messages, "useful messages"),
        ):
            if numerator > denominator:
                raise ValueError(f"{label} exceed their denominator")
        if self.trust_brier_sum > self.trust_predictions:
            raise ValueError("Brier sum exceeds its maximum possible total")
        return self


class CognitionMetrics(ArenaModel):
    track: CognitionTrack
    budget_units: int = Field(ge=0)
    spent_units: int = Field(ge=0)
    weighted_token_budget: int = Field(gt=0)
    objective_progress_points: float = Field(ge=0)
    objective_progress_capacity: float = Field(gt=0)
    specialist_calls: int = Field(default=0, ge=0)
    advice_received: int = Field(default=0, ge=0)
    advice_accepted: int = Field(default=0, ge=0)
    accepted_advice_with_progress: int = Field(default=0, ge=0)
    specialist_contradictions: int = Field(default=0, ge=0)
    wasted_specialist_calls: int = Field(default=0, ge=0)
    specialist_management_actions: int = Field(default=0, ge=0)
    effective_management_actions: int = Field(default=0, ge=0)
    usage: UsageRecord = Field(default_factory=UsageRecord)

    @model_validator(mode="after")
    def validate_budget(self) -> CognitionMetrics:
        if self.track != "open" and self.spent_units > self.budget_units:
            raise ValueError("cognition spending exceeds the configured track budget")
        if self.track == "standard" and self.specialist_calls:
            raise ValueError("standard track cannot contain specialist calls")
        if self.objective_progress_points > self.objective_progress_capacity:
            raise ValueError("objective progress exceeds its configured capacity")
        for numerator, denominator, label in (
            (self.advice_received, self.specialist_calls, "received advice"),
            (self.advice_accepted, self.advice_received, "accepted advice"),
            (
                self.accepted_advice_with_progress,
                self.advice_accepted,
                "progress-linked advice",
            ),
            (
                self.specialist_contradictions,
                self.specialist_calls,
                "specialist contradictions",
            ),
            (self.wasted_specialist_calls, self.specialist_calls, "wasted specialist calls"),
            (
                self.effective_management_actions,
                self.specialist_management_actions,
                "effective specialist management actions",
            ),
        ):
            if numerator > denominator:
                raise ValueError(f"{label} exceed their denominator")
        return self

    @property
    def weighted_tokens(self) -> float:
        uncached = max(0, self.usage.input_tokens - self.usage.cached_input_tokens)
        return uncached + (0.25 * self.usage.cached_input_tokens) + (4 * self.usage.output_tokens)


class ReliabilityMetrics(ArenaModel):
    decisions: int = Field(gt=0)
    submitted_orders: int = Field(default=0, ge=0)
    invalid_orders: int = Field(default=0, ge=0)
    contradictory_orders: int = Field(default=0, ge=0)
    repeated_impossible_orders: int = Field(default=0, ge=0)
    visibility_violations: int = Field(default=0, ge=0)
    resource_violations: int = Field(default=0, ge=0)
    protocol_violations: int = Field(default=0, ge=0)
    fallback_decisions: int = Field(default=0, ge=0)
    successful_fallback_decisions: int = Field(default=0, ge=0)
    timeout_decisions: int = Field(default=0, ge=0)
    api_error_decisions: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_counts(self) -> ReliabilityMetrics:
        for numerator, denominator, label in (
            (self.invalid_orders, self.submitted_orders, "invalid orders"),
            (self.contradictory_orders, self.submitted_orders, "contradictory orders"),
            (
                self.repeated_impossible_orders,
                self.submitted_orders,
                "repeated impossible orders",
            ),
            (self.visibility_violations, self.submitted_orders, "visibility violations"),
            (self.resource_violations, self.submitted_orders, "resource violations"),
            (self.protocol_violations, self.decisions, "protocol violations"),
            (self.fallback_decisions, self.decisions, "fallback decisions"),
            (
                self.successful_fallback_decisions,
                self.fallback_decisions,
                "successful fallback decisions",
            ),
            (self.timeout_decisions, self.decisions, "timeout decisions"),
            (self.api_error_decisions, self.decisions, "API error decisions"),
        ):
            if numerator > denominator:
                raise ValueError(f"{label} exceed their denominator")
        return self


class CategoryEvidence(ArenaModel):
    category: EvidenceCategory
    event_ids: List[Identifier] = Field(min_length=1, max_length=128)
    action_ids: List[Identifier] = Field(default_factory=list, max_length=128)
    measurement_count: int = Field(ge=1)

    @model_validator(mode="after")
    def validate_ids(self) -> CategoryEvidence:
        if len(set(self.event_ids)) != len(self.event_ids):
            raise ValueError("category evidence event IDs must be unique")
        if len(set(self.action_ids)) != len(self.action_ids):
            raise ValueError("category evidence action IDs must be unique")
        return self


class DecisionEvidence(ArenaModel):
    plan_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    three_round_objective_value_delta: float = Field(ge=-100, le=100)
    summary: str = Field(min_length=3, max_length=240)
    event_ids: List[Identifier] = Field(min_length=1, max_length=32)

    @model_validator(mode="after")
    def validate_event_ids(self) -> DecisionEvidence:
        if len(set(self.event_ids)) != len(self.event_ids):
            raise ValueError("decision evidence event IDs must be unique")
        return self


class FactionMatchMetrics(ArenaModel):
    competitor_id: Identifier
    model_id: str = Field(min_length=1, max_length=120)
    reasoning_effort: Literal["none", "low", "medium", "high", "xhigh", "max"]
    prompt_hash: HashHex
    faction_id: FactionId
    track: CognitionTrack
    outcome: OutcomeMetrics
    territory: TerritoryMetrics
    planning: PlanningMetrics
    economy: EconomyMetrics
    combat: CombatMetrics
    adaptation: AdaptationMetrics
    diplomacy: DiplomacyMetrics
    cognition: CognitionMetrics
    reliability: ReliabilityMetrics
    evidence: List[CategoryEvidence] = Field(min_length=6, max_length=6)
    decision_evidence: List[DecisionEvidence] = Field(
        default_factory=list, max_length=MAX_CONQUEST_ROUNDS
    )

    @model_validator(mode="after")
    def validate_evidence(self) -> FactionMatchMetrics:
        if self.cognition.track != self.track:
            raise ValueError("faction and cognition tracks differ")
        if {item.category for item in self.evidence} != REQUIRED_CATEGORIES:
            raise ValueError("one evidence record is required for every score category")
        if len({item.category for item in self.evidence}) != 6:
            raise ValueError("score category evidence must not be duplicated")
        supported_events = {event_id for item in self.evidence for event_id in item.event_ids}
        supported_actions = {action_id for item in self.evidence for action_id in item.action_ids}
        if len({item.plan_id for item in self.decision_evidence}) != len(self.decision_evidence):
            raise ValueError("decision evidence plan IDs must be unique")
        for item in self.decision_evidence:
            if item.plan_id not in supported_actions:
                raise ValueError("decision delta lacks a supporting committed plan ID")
            if not set(item.event_ids).issubset(supported_events):
                raise ValueError("decision delta references unsupported event evidence")
        return self


class MatchEvaluationInput(ArenaModel):
    outcome_authority: Literal["godot"] = "godot"
    match_id: Identifier
    schedule_match_number: int = Field(ge=1, le=100)
    track: CognitionTrack
    seed: int = Field(ge=0)
    scored: bool = True
    round_limit: int = Field(default=120, ge=1, le=MAX_CONQUEST_ROUNDS)
    completed_rounds: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    rules_hash: HashHex
    map_hash: HashHex
    tool_hash: HashHex
    factions: List[FactionMatchMetrics] = Field(min_length=3, max_length=3)

    @model_validator(mode="after")
    def validate_match(self) -> MatchEvaluationInput:
        if self.completed_rounds > self.round_limit:
            raise ValueError("completed rounds exceed the configured round limit")
        if {item.faction_id for item in self.factions} != {"sol", "terra", "luna"}:
            raise ValueError("match requires one complete record per faction")
        if len({item.competitor_id for item in self.factions}) != 3:
            raise ValueError("match requires three unique competitor IDs")
        if {item.track for item in self.factions} != {self.track}:
            raise ValueError("cross-track faction data cannot be evaluated together")
        placements = sorted(item.outcome.placement for item in self.factions)
        winners = [item for item in self.factions if item.outcome.won]
        draws = [item for item in self.factions if item.outcome.draw]
        if draws:
            if winners or len(draws) < 2 or sum(item.outcome.placement == 1 for item in draws) < 2:
                raise ValueError("draws require at least two tied first-place factions")
        elif placements != [1, 2, 3] or len(winners) != 1:
            raise ValueError("non-draw matches require unique placements and one winner")
        return self


class CategoryScore(ArenaModel):
    category: EvidenceCategory
    score: float = Field(ge=0, le=100)
    weight: float = Field(gt=0, le=1)
    weighted_contribution: float = Field(ge=0, le=100)
    event_ids: List[Identifier]
    action_ids: List[Identifier]
    measurement_count: int = Field(ge=1)


class DecisionHighlight(ArenaModel):
    plan_id: Identifier
    round: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    three_round_objective_value_delta: float = Field(ge=-100, le=100)
    summary: str
    event_ids: List[Identifier]


class FactionEvaluation(ArenaModel):
    competitor_id: Identifier
    model_id: str
    reasoning_effort: Literal["none", "low", "medium", "high", "xhigh", "max"]
    prompt_hash: HashHex
    faction_id: FactionId
    placement: int = Field(ge=1, le=3)
    won: bool
    draw: bool
    formula_version: FormulaVersion
    worldarena_score: float = Field(ge=0, le=100)
    categories: List[CategoryScore] = Field(min_length=6, max_length=6)
    best_decision: Optional[DecisionHighlight] = None
    biggest_failure: Optional[DecisionHighlight] = None
    weighted_tokens: float = Field(ge=0)
    score_per_100k_weighted_tokens: Optional[float] = Field(default=None, ge=0)
    invalid_order_rate: float = Field(ge=0, le=1)
    timeout_rate: float = Field(ge=0, le=1)
    fallback_rate: float = Field(ge=0, le=1)
    decisions: int = Field(gt=0)
    submitted_orders: int = Field(ge=0)
    invalid_orders: int = Field(ge=0)
    contradictory_orders: int = Field(ge=0)
    fallback_decisions: int = Field(ge=0)
    timeout_decisions: int = Field(ge=0)
    api_error_decisions: int = Field(ge=0)
    usage: UsageRecord
    raw_metrics: FactionMatchMetrics

    @model_validator(mode="after")
    def validate_categories(self) -> FactionEvaluation:
        if {item.category for item in self.categories} != REQUIRED_CATEGORIES:
            raise ValueError("evaluation requires all six score categories")
        evidence = {item.category: item for item in self.raw_metrics.evidence}
        for item in self.categories:
            if item.weight != CATEGORY_WEIGHTS[item.category]:
                raise ValueError("category weight differs from the versioned formula")
            if abs(item.weighted_contribution - round(item.score * item.weight, 4)) > 0.001:
                raise ValueError("category contribution differs from score times weight")
            source = evidence[item.category]
            if (
                item.event_ids != source.event_ids
                or item.action_ids != source.action_ids
                or item.measurement_count != source.measurement_count
            ):
                raise ValueError("category evidence differs from the raw evidence record")
        total = sum(item.weighted_contribution for item in self.categories)
        if abs(total - self.worldarena_score) > 0.001:
            raise ValueError("WorldEval score differs from weighted category contributions")
        raw = self.raw_metrics
        if (
            self.competitor_id != raw.competitor_id
            or self.model_id != raw.model_id
            or self.reasoning_effort != raw.reasoning_effort
            or self.prompt_hash != raw.prompt_hash
            or self.faction_id != raw.faction_id
            or self.placement != raw.outcome.placement
            or self.won != raw.outcome.won
            or self.draw != raw.outcome.draw
        ):
            raise ValueError("derived identity or outcome differs from raw world metrics")
        positives = [
            item
            for item in raw.decision_evidence
            if item.three_round_objective_value_delta > 0
        ]
        negatives = [
            item
            for item in raw.decision_evidence
            if item.three_round_objective_value_delta < 0
        ]
        expected_best = min(
            positives,
            key=lambda item: (-item.three_round_objective_value_delta, item.round, item.plan_id),
            default=None,
        )
        expected_failure = min(
            negatives,
            key=lambda item: (item.three_round_objective_value_delta, item.round, item.plan_id),
            default=None,
        )
        if (self.best_decision.plan_id if self.best_decision else None) != (
            expected_best.plan_id if expected_best else None
        ):
            raise ValueError("best decision does not match deterministic evidence selection")
        if (self.biggest_failure.plan_id if self.biggest_failure else None) != (
            expected_failure.plan_id if expected_failure else None
        ):
            raise ValueError("biggest failure does not match deterministic evidence selection")
        return self


class MatchEvaluationResult(ArenaModel):
    schema_version: Literal[2] = 2
    formula_version: FormulaVersion
    outcome_authority: Literal["godot"] = "godot"
    llm_judge_used: Literal[False] = False
    match_id: Identifier
    schedule_match_number: int = Field(ge=1, le=100)
    track: CognitionTrack
    seed: int = Field(ge=0)
    scored: bool
    rules_hash: HashHex
    map_hash: HashHex
    tool_hash: HashHex
    completed_rounds: int = Field(ge=1, le=MAX_CONQUEST_ROUNDS)
    factions: List[FactionEvaluation] = Field(min_length=3, max_length=3)
    weights: Dict[str, float]

    @model_validator(mode="after")
    def validate_result(self) -> MatchEvaluationResult:
        if {item.faction_id for item in self.factions} != {"sol", "terra", "luna"}:
            raise ValueError("result requires one complete record per faction")
        if len({item.competitor_id for item in self.factions}) != 3:
            raise ValueError("result requires three unique competitors")
        if self.weights != CATEGORY_WEIGHTS:
            raise ValueError("result weights differ from the versioned WorldArena formula")
        if {item.formula_version for item in self.factions} != {self.formula_version}:
            raise ValueError("faction and match formula versions differ")
        if {item.raw_metrics.track for item in self.factions} != {self.track}:
            raise ValueError("result contains cross-track raw metrics")
        placements = sorted(item.placement for item in self.factions)
        winners = [item for item in self.factions if item.won]
        draws = [item for item in self.factions if item.draw]
        if draws:
            if winners or len(draws) < 2 or sum(item.placement == 1 for item in draws) < 2:
                raise ValueError("result draw conflicts with world-derived placement")
        elif placements != [1, 2, 3] or len(winners) != 1:
            raise ValueError("result placement conflicts with the authoritative world outcome")
        return self


def _planning_adaptation(metrics: FactionMatchMetrics) -> float:
    planning = metrics.planning
    adaptation = metrics.adaptation
    return (
        0.25 * _ratio(planning.objectives_completed, planning.objectives_declared)
        + 0.20 * _ratio(planning.coherent_plan_rounds, planning.planned_rounds)
        + 0.15 * _ratio(planning.prepared_threats, planning.disclosed_threats)
        + 0.20 * _ratio(adaptation.recovered_setbacks, adaptation.setbacks)
        + 0.10
        * _ratio(
            adaptation.successful_exploitations,
            adaptation.exploitation_opportunities,
        )
        + 0.10 * _avoid(planning.repeated_failed_orders, metrics.reliability.submitted_orders)
    )


def _resource_combat(metrics: FactionMatchMetrics) -> float:
    economy = metrics.economy
    combat = metrics.combat
    handled = economy.resources_productively_spent + economy.resources_wasted
    return (
        0.18 * _ratio(economy.resources_productively_spent, handled)
        + 0.10 * _ratio(economy.mine_active_rounds, economy.mine_available_rounds)
        + 0.10 * _ratio(economy.supply_active_rounds, economy.supply_possible_rounds)
        + 0.08 * _avoid(economy.starvation_unit_rounds, economy.total_unit_rounds)
        + 0.06
        * _avoid(economy.idle_stockpile_rounds, economy.stockpile_observation_rounds)
        + 0.22
        * _ratio(
            combat.enemy_value_destroyed,
            combat.enemy_value_destroyed + combat.own_value_lost,
        )
        + 0.16 * _ratio(combat.damage_dealt, combat.damage_dealt + combat.damage_taken)
        + 0.10 * _ratio(combat.successful_retreats, combat.retreats)
    )


def _social(metrics: FactionMatchMetrics) -> float:
    diplomacy = metrics.diplomacy
    if not diplomacy.enabled:
        return 0.5
    trust_calibration = 1 - _ratio(
        diplomacy.trust_brier_sum,
        diplomacy.trust_predictions,
        neutral=0.5,
    )
    return (
        0.25 * _ratio(diplomacy.executed_trade_value, diplomacy.offered_trade_value)
        + 0.20 * _ratio(diplomacy.pacts_honored, diplomacy.pacts_accepted)
        + 0.25
        * _ratio(
            diplomacy.coordinations_with_physical_gain,
            diplomacy.coordination_attempts,
        )
        + 0.20 * trust_calibration
        + 0.10 * _ratio(diplomacy.useful_messages, diplomacy.total_messages)
    )


def _delegation_cognition(metrics: FactionMatchMetrics) -> float:
    cognition = metrics.cognition
    progress = _ratio(
        cognition.objective_progress_points,
        cognition.objective_progress_capacity,
    )
    token_ratio = cognition.weighted_tokens / cognition.weighted_token_budget
    progress_per_token = min(1.0, progress / max(0.25, token_ratio))
    return (
        0.30 * progress_per_token
        + 0.25
        * _ratio(
            cognition.accepted_advice_with_progress,
            cognition.advice_accepted,
        )
        + 0.15 * _avoid(cognition.specialist_contradictions, cognition.specialist_calls)
        + 0.15 * _avoid(cognition.wasted_specialist_calls, cognition.specialist_calls)
        + 0.15
        * _ratio(
            cognition.effective_management_actions,
            cognition.specialist_management_actions,
        )
    )


def _reliability_safety(metrics: FactionMatchMetrics) -> float:
    reliability = metrics.reliability
    compliance_failures = reliability.visibility_violations + reliability.resource_violations
    service_failures = reliability.timeout_decisions + reliability.api_error_decisions
    return (
        0.35 * _avoid(reliability.invalid_orders, reliability.submitted_orders)
        + 0.15 * _avoid(compliance_failures, 2 * reliability.submitted_orders)
        + 0.10
        * _avoid(reliability.contradictory_orders, reliability.submitted_orders)
        + 0.10
        * _avoid(reliability.repeated_impossible_orders, reliability.submitted_orders)
        + 0.10 * _avoid(service_failures, 2 * reliability.decisions)
        + 0.10
        * _ratio(
            reliability.successful_fallback_decisions,
            reliability.fallback_decisions,
            neutral=1,
        )
        + 0.10 * _avoid(reliability.protocol_violations, reliability.decisions)
    )


def _category_values(metrics: FactionMatchMetrics) -> Dict[str, float]:
    outcome = metrics.outcome
    territory = metrics.territory
    placement = (3 - outcome.placement) / 2
    core = 0.5 * float(outcome.core_survived) + 0.5 * _ratio(outcome.core_health, 1_000)
    objective_control = (
        0.35 * placement
        + 0.20 * core
        + 0.20 * _ratio(territory.enemy_strongholds_destroyed, 2, neutral=0)
        + 0.10 * _ratio(territory.territory_time, territory.max_territory_time)
        + 0.05 * _ratio(territory.final_supplied_points, territory.max_supplied_points)
        + 0.05 * _ratio(territory.districts_discovered, territory.max_districts)
        + 0.05 * _ratio(territory.tech_tier, territory.max_tech_tier)
    )
    return {
        "objective_control": objective_control,
        "planning_adaptation": _planning_adaptation(metrics),
        "resource_combat_efficiency": _resource_combat(metrics),
        "social_intelligence": _social(metrics),
        "delegation_cognition": _delegation_cognition(metrics),
        "reliability_safety": _reliability_safety(metrics),
    }


def _highlight(evidence: DecisionEvidence) -> DecisionHighlight:
    return DecisionHighlight(**evidence.model_dump(mode="python"))


def _score_faction(metrics: FactionMatchMetrics) -> FactionEvaluation:
    values = _category_values(metrics)
    evidence_by_category = {item.category: item for item in metrics.evidence}
    categories: List[CategoryScore] = []
    for category in CATEGORY_WEIGHTS:
        score = round(values[category] * 100, 4)
        weight = CATEGORY_WEIGHTS[category]
        contribution = round(score * weight, 4)
        evidence = evidence_by_category[category]
        categories.append(
            CategoryScore(
                category=category,
                score=score,
                weight=weight,
                weighted_contribution=contribution,
                event_ids=evidence.event_ids,
                action_ids=evidence.action_ids,
                measurement_count=evidence.measurement_count,
            )
        )
    worldarena_score = round(sum(item.weighted_contribution for item in categories), 4)
    positives = [
        item for item in metrics.decision_evidence if item.three_round_objective_value_delta > 0
    ]
    negatives = [
        item for item in metrics.decision_evidence if item.three_round_objective_value_delta < 0
    ]
    best = min(
        positives,
        key=lambda item: (-item.three_round_objective_value_delta, item.round, item.plan_id),
        default=None,
    )
    failure = min(
        negatives,
        key=lambda item: (item.three_round_objective_value_delta, item.round, item.plan_id),
        default=None,
    )
    weighted_tokens = metrics.cognition.weighted_tokens
    score_per_tokens = (
        worldarena_score * 100_000 / weighted_tokens if weighted_tokens > 0 else None
    )
    reliability = metrics.reliability
    return FactionEvaluation(
        competitor_id=metrics.competitor_id,
        model_id=metrics.model_id,
        reasoning_effort=metrics.reasoning_effort,
        prompt_hash=metrics.prompt_hash,
        faction_id=metrics.faction_id,
        placement=metrics.outcome.placement,
        won=metrics.outcome.won,
        draw=metrics.outcome.draw,
        formula_version=FORMULA_VERSION,
        worldarena_score=worldarena_score,
        categories=categories,
        best_decision=_highlight(best) if best is not None else None,
        biggest_failure=_highlight(failure) if failure is not None else None,
        weighted_tokens=round(weighted_tokens, 4),
        score_per_100k_weighted_tokens=round(score_per_tokens, 4)
        if score_per_tokens is not None
        else None,
        invalid_order_rate=_ratio(
            reliability.invalid_orders, reliability.submitted_orders, neutral=0
        ),
        timeout_rate=_ratio(reliability.timeout_decisions, reliability.decisions, neutral=0),
        fallback_rate=_ratio(reliability.fallback_decisions, reliability.decisions, neutral=0),
        decisions=reliability.decisions,
        submitted_orders=reliability.submitted_orders,
        invalid_orders=reliability.invalid_orders,
        contradictory_orders=reliability.contradictory_orders,
        fallback_decisions=reliability.fallback_decisions,
        timeout_decisions=reliability.timeout_decisions,
        api_error_decisions=reliability.api_error_decisions,
        usage=metrics.cognition.usage,
        raw_metrics=metrics,
    )


def evaluate_match(match: MatchEvaluationInput) -> MatchEvaluationResult:
    """Explain behavior without changing Godot-derived placement or victory."""

    return MatchEvaluationResult(
        formula_version=FORMULA_VERSION,
        outcome_authority=match.outcome_authority,
        match_id=match.match_id,
        schedule_match_number=match.schedule_match_number,
        track=match.track,
        seed=match.seed,
        scored=match.scored,
        rules_hash=match.rules_hash,
        map_hash=match.map_hash,
        tool_hash=match.tool_hash,
        completed_rounds=match.completed_rounds,
        factions=[_score_faction(item) for item in match.factions],
        weights=dict(CATEGORY_WEIGHTS),
    )
