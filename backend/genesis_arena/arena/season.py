from __future__ import annotations

import hashlib
import math
from typing import Dict, List, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .canonical import canonical_json
from .evaluation import (
    FORMULA_VERSION,
    CognitionTrack,
    FactionEvaluation,
    FormulaVersion,
    MatchEvaluationResult,
)
from .models import FactionId, HashHex, Identifier


class FrozenArenaModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class SeasonCompetitor(FrozenArenaModel):
    competitor_id: Identifier
    model_id: str = Field(min_length=1, max_length=120)
    reasoning_effort: Literal["none", "low", "medium", "high", "xhigh", "max"]
    prompt_hash: HashHex


class SeasonSpec(FrozenArenaModel):
    schema_version: Literal[1] = 1
    formula_version: FormulaVersion = FORMULA_VERSION
    season_id: Identifier
    track: CognitionTrack
    base_seed: int = Field(ge=0)
    competitors: List[SeasonCompetitor] = Field(min_length=3, max_length=3)
    rules_hash: HashHex
    map_hash: HashHex
    tool_hash: HashHex
    cognition_units: int = Field(ge=0)
    decision_timeout_ms: int = Field(gt=0)
    specialist_timeout_ms: int = Field(gt=0)

    @model_validator(mode="after")
    def validate_competitors(self) -> SeasonSpec:
        if len({item.competitor_id for item in self.competitors}) != 3:
            raise ValueError("season requires three unique competitor IDs")
        if self.track == "standard" and self.cognition_units < 80:
            raise ValueError("standard track must reserve 40 commander calls")
        if self.track == "agentic" and self.cognition_units < 120:
            raise ValueError("agentic track requires its 120-unit cognition budget")
        return self


class SeatAssignment(FrozenArenaModel):
    faction_id: FactionId
    competitor_id: Identifier


class ScheduledMatch(FrozenArenaModel):
    match_number: int = Field(ge=1, le=100)
    match_id: Identifier
    seed_triplet: int = Field(ge=0, le=33)
    seat_rotation: int = Field(ge=0, le=2)
    seed: int = Field(ge=0)
    phase: Literal["adaptation", "validation", "hidden_evaluation", "championship"]
    memory_policy: Literal["update", "read_only", "frozen"]
    hidden_seed: bool
    scored: bool
    seats: List[SeatAssignment] = Field(min_length=3, max_length=3)

    @model_validator(mode="after")
    def validate_seats(self) -> ScheduledMatch:
        if {seat.faction_id for seat in self.seats} != {"sol", "terra", "luna"}:
            raise ValueError("scheduled match requires every faction seat")
        if len({seat.competitor_id for seat in self.seats}) != 3:
            raise ValueError("scheduled match requires every competitor exactly once")
        if self.phase == "championship" and self.scored:
            raise ValueError("championship showcase is not scored")
        if self.phase != "championship" and not self.scored:
            raise ValueError("the first 99 scheduled matches must be scored")
        return self


class SeasonSchedule(FrozenArenaModel):
    schema_version: Literal[1] = 1
    schedule_algorithm: Literal["world-arena-seat-rotation-v1"] = (
        "world-arena-seat-rotation-v1"
    )
    schedule_hash: HashHex
    spec: SeasonSpec
    matches: List[ScheduledMatch] = Field(min_length=100, max_length=100)

    @model_validator(mode="after")
    def validate_schedule_shape(self) -> SeasonSchedule:
        if [match.match_number for match in self.matches] != list(range(1, 101)):
            raise ValueError("season match numbers must be contiguous from 1 to 100")
        if sum(match.scored for match in self.matches) != 99:
            raise ValueError("season must contain exactly 99 scored matches")
        phases = [match.phase for match in self.matches]
        if phases[:60] != ["adaptation"] * 60:
            raise ValueError("matches 1-60 must be adaptation matches")
        if phases[60:81] != ["validation"] * 21:
            raise ValueError("matches 61-81 must be validation matches")
        if phases[81:99] != ["hidden_evaluation"] * 18:
            raise ValueError("matches 82-99 must be hidden evaluation")
        if phases[99] != "championship":
            raise ValueError("match 100 must be the championship showcase")
        expected = {item.competitor_id for item in self.spec.competitors}
        for match in self.matches:
            if {seat.competitor_id for seat in match.seats} != expected:
                raise ValueError("scheduled match competitor set differs from season spec")
        return self


def _derived_seed(spec: SeasonSpec, triplet: int) -> int:
    material = f"{spec.season_id}:{spec.base_seed}:seed:{triplet}".encode()
    return int.from_bytes(hashlib.sha256(material).digest()[:8], "big") & ((1 << 63) - 1)


def _schedule_digest(schedule: SeasonSchedule) -> str:
    payload = schedule.model_dump(mode="json", exclude={"schedule_hash"})
    return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()


def verify_schedule_hash(schedule: SeasonSchedule) -> bool:
    return _schedule_digest(schedule) == schedule.schedule_hash


def build_season_schedule(spec: SeasonSpec) -> SeasonSchedule:
    """Create the immutable 99-scored-plus-championship Arena schedule."""

    faction_ids = ("sol", "terra", "luna")
    competitor_ids = [item.competitor_id for item in spec.competitors]
    matches: List[ScheduledMatch] = []
    for triplet in range(33):
        seed = _derived_seed(spec, triplet)
        for rotation in range(3):
            match_number = triplet * 3 + rotation + 1
            if match_number <= 60:
                phase = "adaptation"
                memory_policy = "update"
                hidden_seed = False
            elif match_number <= 81:
                phase = "validation"
                memory_policy = "read_only"
                hidden_seed = False
            else:
                phase = "hidden_evaluation"
                memory_policy = "frozen"
                hidden_seed = True
            seats = [
                SeatAssignment(
                    faction_id=faction,
                    competitor_id=competitor_ids[(index + rotation) % 3],
                )
                for index, faction in enumerate(faction_ids)
            ]
            matches.append(
                ScheduledMatch(
                    match_number=match_number,
                    match_id=f"{spec.season_id}-m{match_number:03d}",
                    seed_triplet=triplet,
                    seat_rotation=rotation,
                    seed=seed,
                    phase=phase,
                    memory_policy=memory_policy,
                    hidden_seed=hidden_seed,
                    scored=True,
                    seats=seats,
                )
            )

    championship_seed = _derived_seed(spec, 33)
    championship_rotation = championship_seed % 3
    championship_seats = [
        SeatAssignment(
            faction_id=faction,
            competitor_id=competitor_ids[(index + championship_rotation) % 3],
        )
        for index, faction in enumerate(faction_ids)
    ]
    matches.append(
        ScheduledMatch(
            match_number=100,
            match_id=f"{spec.season_id}-m100",
            seed_triplet=33,
            seat_rotation=championship_rotation,
            seed=championship_seed,
            phase="championship",
            memory_policy="frozen",
            hidden_seed=True,
            scored=False,
            seats=championship_seats,
        )
    )
    provisional = SeasonSchedule(schedule_hash="0" * 64, spec=spec, matches=matches)
    return provisional.model_copy(update={"schedule_hash": _schedule_digest(provisional)})


class ConfidenceInterval(FrozenArenaModel):
    level: Literal[0.95] = 0.95
    lower: float = Field(ge=0, le=1)
    upper: float = Field(ge=0, le=1)


class PairwiseAggregate(FrozenArenaModel):
    opponent_id: Identifier
    matches: int = Field(ge=0)
    wins: int = Field(ge=0)
    losses: int = Field(ge=0)
    ties: int = Field(ge=0)


class CompetitorSeasonAggregate(FrozenArenaModel):
    competitor_id: Identifier
    model_id: str
    matches: int = Field(gt=0)
    wins: int = Field(ge=0)
    draws: int = Field(ge=0)
    win_rate: float = Field(ge=0, le=1)
    win_rate_ci: ConfidenceInterval
    average_placement: float = Field(ge=1, le=3)
    formula_version: FormulaVersion
    average_worldarena_score: float = Field(ge=0, le=100)
    average_category_scores: Dict[str, float]
    average_weighted_contributions: Dict[str, float]
    weighted_tokens: float = Field(ge=0)
    estimated_cost_usd: float = Field(ge=0)
    invalid_order_rate: float = Field(ge=0, le=1)
    timeout_rate: float = Field(ge=0, le=1)
    fallback_rate: float = Field(ge=0, le=1)
    pairwise: List[PairwiseAggregate]


class TripleAggregate(FrozenArenaModel):
    competitor_ids: List[Identifier] = Field(min_length=3, max_length=3)
    matches: int = Field(ge=0)
    winner_counts: Dict[str, int]
    draw_matches: int = Field(ge=0)


class SeasonAggregateResult(FrozenArenaModel):
    schema_version: Literal[2] = 2
    formula_version: FormulaVersion
    season_id: Identifier
    schedule_hash: HashHex
    track: CognitionTrack
    scored_matches: int = Field(ge=0)
    competitors: List[CompetitorSeasonAggregate] = Field(min_length=3, max_length=3)
    triple: TripleAggregate
    ranking: List[Identifier] = Field(min_length=3, max_length=3)


def _wilson(wins: int, matches: int) -> ConfidenceInterval:
    if matches <= 0:
        raise ValueError("confidence interval requires completed matches")
    z = 1.959963984540054
    proportion = wins / matches
    denominator = 1 + (z * z / matches)
    center = (proportion + (z * z / (2 * matches))) / denominator
    margin = (
        z
        * math.sqrt(
            (proportion * (1 - proportion) / matches) + (z * z / (4 * matches * matches))
        )
        / denominator
    )
    return ConfidenceInterval(lower=max(0, center - margin), upper=min(1, center + margin))


def aggregate_season(
    schedule: SeasonSchedule, results: List[MatchEvaluationResult]
) -> SeasonAggregateResult:
    """Aggregate only a complete, schedule-matching, single-track scored bracket."""

    if not verify_schedule_hash(schedule):
        raise ValueError("season schedule hash is invalid")
    by_id = {result.match_id: result for result in results}
    if len(by_id) != len(results):
        raise ValueError("duplicate match results")
    scored = [match for match in schedule.matches if match.scored]
    expected_ids = {match.match_id for match in scored}
    allowed_ids = {match.match_id for match in schedule.matches}
    if not expected_ids.issubset(by_id):
        missing = len(expected_ids - set(by_id))
        raise ValueError(f"season results are incomplete: {missing} scored matches missing")
    if set(by_id) - allowed_ids:
        raise ValueError("season results contain unscheduled matches")

    competitor_specs = {item.competitor_id: item for item in schedule.spec.competitors}
    scheduled_by_id = {match.match_id: match for match in schedule.matches}
    for result in results:
        scheduled = scheduled_by_id[result.match_id]
        if (
            result.schedule_match_number != scheduled.match_number
            or result.seed != scheduled.seed
            or result.track != schedule.spec.track
            or result.rules_hash != schedule.spec.rules_hash
            or result.map_hash != schedule.spec.map_hash
            or result.tool_hash != schedule.spec.tool_hash
            or result.scored != scheduled.scored
            or result.formula_version != schedule.spec.formula_version
        ):
            raise ValueError(f"result metadata differs from schedule: {scheduled.match_id}")
        expected_seats = {seat.faction_id: seat.competitor_id for seat in scheduled.seats}
        actual_seats = {item.faction_id: item.competitor_id for item in result.factions}
        if actual_seats != expected_seats:
            raise ValueError(f"result seat assignment differs from schedule: {scheduled.match_id}")
        for item in result.factions:
            spec = competitor_specs[item.competitor_id]
            if (
                item.model_id != spec.model_id
                or item.reasoning_effort != spec.reasoning_effort
                or item.prompt_hash != spec.prompt_hash
            ):
                raise ValueError("result model configuration differs from frozen metadata")

    evaluations: Dict[str, List[FactionEvaluation]] = {key: [] for key in competitor_specs}
    pairwise: Dict[str, Dict[str, List[int]]] = {
        key: {other: [0, 0, 0] for other in competitor_specs if other != key}
        for key in competitor_specs
    }
    winner_counts = {key: 0 for key in competitor_specs}
    draw_matches = 0

    for scheduled in scored:
        result = by_id[scheduled.match_id]
        for item in result.factions:
            evaluations[item.competitor_id].append(item)
            if item.won:
                winner_counts[item.competitor_id] += 1
        if any(item.draw for item in result.factions):
            draw_matches += 1
        placement = {item.competitor_id: item.placement for item in result.factions}
        for competitor in competitor_specs:
            for opponent in pairwise[competitor]:
                if placement[competitor] < placement[opponent]:
                    pairwise[competitor][opponent][0] += 1
                elif placement[competitor] > placement[opponent]:
                    pairwise[competitor][opponent][1] += 1
                else:
                    pairwise[competitor][opponent][2] += 1

    aggregates: List[CompetitorSeasonAggregate] = []
    for competitor_id, spec in competitor_specs.items():
        items = evaluations[competitor_id]
        count = len(items)
        wins = sum(item.won for item in items)
        draws = sum(item.draw for item in items)
        category_names = [category.category for category in items[0].categories]
        category_scores = {
            name: sum(
                next(category.score for category in item.categories if category.category == name)
                for item in items
            )
            / count
            for name in category_names
        }
        contributions = {
            name: sum(
                next(
                    category.weighted_contribution
                    for category in item.categories
                    if category.category == name
                )
                for item in items
            )
            / count
            for name in category_names
        }
        total_decisions = sum(item.decisions for item in items)
        total_orders = sum(item.submitted_orders for item in items)
        pair_rows = [
            PairwiseAggregate(
                opponent_id=opponent,
                matches=sum(counts),
                wins=counts[0],
                losses=counts[1],
                ties=counts[2],
            )
            for opponent, counts in sorted(pairwise[competitor_id].items())
        ]
        aggregates.append(
            CompetitorSeasonAggregate(
                competitor_id=competitor_id,
                model_id=spec.model_id,
                matches=count,
                wins=wins,
                draws=draws,
                win_rate=wins / count,
                win_rate_ci=_wilson(wins, count),
                average_placement=sum(item.placement for item in items) / count,
                formula_version=schedule.spec.formula_version,
                average_worldarena_score=sum(item.worldarena_score for item in items) / count,
                average_category_scores=category_scores,
                average_weighted_contributions=contributions,
                weighted_tokens=sum(item.weighted_tokens for item in items),
                estimated_cost_usd=sum(item.usage.estimated_cost_usd for item in items),
                invalid_order_rate=(
                    sum(item.invalid_orders for item in items) / total_orders
                    if total_orders
                    else 0
                ),
                timeout_rate=sum(item.timeout_decisions for item in items) / total_decisions,
                fallback_rate=sum(item.fallback_decisions for item in items) / total_decisions,
                pairwise=pair_rows,
            )
        )
    ranking = [
        item.competitor_id
        for item in sorted(
            aggregates,
            key=lambda item: (
                -item.win_rate,
                item.average_placement,
                -item.average_worldarena_score,
                item.competitor_id,
            ),
        )
    ]
    return SeasonAggregateResult(
        formula_version=schedule.spec.formula_version,
        season_id=schedule.spec.season_id,
        schedule_hash=schedule.schedule_hash,
        track=schedule.spec.track,
        scored_matches=len(scored),
        competitors=aggregates,
        triple=TripleAggregate(
            competitor_ids=sorted(competitor_specs),
            matches=len(scored),
            winner_counts=winner_counts,
            draw_matches=draw_matches,
        ),
        ranking=ranking,
    )
