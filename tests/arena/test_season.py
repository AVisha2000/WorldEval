from __future__ import annotations

from collections import Counter

import pytest
from genesis_arena.arena.evaluation import (
    MatchEvaluationInput,
    MatchEvaluationResult,
    evaluate_match,
)
from genesis_arena.arena.season import (
    SeasonCompetitor,
    SeasonSpec,
    aggregate_season,
    build_season_schedule,
    verify_schedule_hash,
)
from pydantic import ValidationError

from .test_evaluation import faction_metrics


def season_spec() -> SeasonSpec:
    return SeasonSpec(
        season_id="season-test",
        track="agentic",
        base_seed=20260718,
        competitors=[
            SeasonCompetitor(
                competitor_id=competitor,
                model_id=f"model-{competitor}",
                reasoning_effort="medium",
                prompt_hash=hash_character * 64,
            )
            for competitor, hash_character in (
                ("alpha", "a"),
                ("beta", "b"),
                ("gamma", "c"),
            )
        ],
        rules_hash="d" * 64,
        map_hash="e" * 64,
        tool_hash="f" * 64,
        cognition_units=360,
        decision_timeout_ms=45_000,
        specialist_timeout_ms=12_000,
    )


def scheduled_result(schedule, scheduled_match) -> MatchEvaluationResult:
    placements = {"alpha": 1, "beta": 2, "gamma": 3}
    specs = {item.competitor_id: item for item in schedule.spec.competitors}
    factions = []
    for seat in scheduled_match.seats:
        placement = placements[seat.competitor_id]
        factions.append(
            faction_metrics(
                seat.faction_id,
                seat.competitor_id,
                placement,
                prompt_hash=specs[seat.competitor_id].prompt_hash,
            )
        )
    return evaluate_match(
        MatchEvaluationInput(
            match_id=scheduled_match.match_id,
            schedule_match_number=scheduled_match.match_number,
            track=schedule.spec.track,
            seed=scheduled_match.seed,
            scored=scheduled_match.scored,
            rules_hash=schedule.spec.rules_hash,
            map_hash=schedule.spec.map_hash,
            tool_hash=schedule.spec.tool_hash,
            round_limit=120,
            completed_rounds=120,
            factions=factions,
        )
    )


def test_schedule_is_deterministic_balanced_and_phase_locked() -> None:
    first = build_season_schedule(season_spec())
    second = build_season_schedule(season_spec())

    assert first == second
    assert verify_schedule_hash(first)
    assert first.spec.formula_version == "worldarena-score/1.1.0"
    assert len(first.matches) == 100
    assert sum(match.scored for match in first.matches) == 99
    assert first.matches[59].phase == "adaptation"
    assert first.matches[60].phase == "validation"
    assert first.matches[81].phase == "hidden_evaluation"
    assert first.matches[99].phase == "championship"
    assert first.matches[99].scored is False

    for triplet in range(33):
        triplet_matches = first.matches[triplet * 3 : triplet * 3 + 3]
        assert len({match.seed for match in triplet_matches}) == 1
        assert {match.seat_rotation for match in triplet_matches} == {0, 1, 2}

    seats = Counter(
        (seat.competitor_id, seat.faction_id)
        for match in first.matches[:99]
        for seat in match.seats
    )
    assert set(seats.values()) == {33}


def test_schedule_metadata_is_frozen_and_track_budget_is_validated() -> None:
    schedule = build_season_schedule(season_spec())
    with pytest.raises(ValidationError):
        schedule.schedule_hash = "0" * 64

    payload = season_spec().model_dump(mode="python")
    payload["cognition_units"] = 359
    with pytest.raises(ValidationError, match="360-unit"):
        SeasonSpec.model_validate(payload)

    standard_payload = season_spec().model_dump(mode="python")
    standard_payload.update(track="standard", cognition_units=240)
    assert SeasonSpec.model_validate(standard_payload).cognition_units == 240

    standard_payload["cognition_units"] = 239
    with pytest.raises(ValidationError, match="reserve 120 commander calls"):
        SeasonSpec.model_validate(standard_payload)

    tampered_match = schedule.matches[0].model_copy(update={"seed": 1})
    tampered_schedule = schedule.model_copy(
        update={"matches": [tampered_match, *schedule.matches[1:]]}
    )
    assert verify_schedule_hash(tampered_schedule) is False


def test_complete_season_aggregation_reports_pair_and_triple_results() -> None:
    schedule = build_season_schedule(season_spec())
    results = [scheduled_result(schedule, match) for match in schedule.matches if match.scored]

    aggregate = aggregate_season(schedule, results)
    by_competitor = {item.competitor_id: item for item in aggregate.competitors}

    assert aggregate.scored_matches == 99
    assert aggregate.ranking == ["alpha", "beta", "gamma"]
    assert by_competitor["alpha"].matches == 99
    assert by_competitor["alpha"].wins == 99
    assert by_competitor["alpha"].win_rate == 1
    assert by_competitor["alpha"].win_rate_ci.lower > 0.95
    assert aggregate.formula_version == "worldarena-score/1.1.0"
    assert set(by_competitor["alpha"].average_category_scores) == set(
        (
            "objective_control",
            "planning_adaptation",
            "resource_combat_efficiency",
            "social_intelligence",
            "delegation_cognition",
            "reliability_safety",
        )
    )
    assert by_competitor["alpha"].average_worldarena_score > by_competitor[
        "beta"
    ].average_worldarena_score
    alpha_vs_beta = next(
        row for row in by_competitor["alpha"].pairwise if row.opponent_id == "beta"
    )
    assert alpha_vs_beta.matches == 99
    assert alpha_vs_beta.wins == 99
    assert aggregate.triple.matches == 99
    assert aggregate.triple.winner_counts == {"alpha": 99, "beta": 0, "gamma": 0}


def test_aggregation_rejects_incomplete_cross_track_and_wrong_seat_data() -> None:
    schedule = build_season_schedule(season_spec())
    results = [scheduled_result(schedule, match) for match in schedule.matches if match.scored]

    with pytest.raises(ValueError, match="incomplete"):
        aggregate_season(schedule, results[:-1])

    cross_track = list(results)
    cross_track[0] = cross_track[0].model_copy(update={"track": "standard"})
    with pytest.raises(ValueError, match="metadata differs"):
        aggregate_season(schedule, cross_track)

    wrong_seat = list(results)
    first = wrong_seat[0]
    altered_factions = list(first.factions)
    altered_factions[0] = altered_factions[0].model_copy(update={"competitor_id": "gamma"})
    wrong_seat[0] = first.model_copy(update={"factions": altered_factions})
    with pytest.raises(ValueError, match="seat assignment"):
        aggregate_season(schedule, wrong_seat)

    wrong_prompt = list(results)
    first = wrong_prompt[0]
    altered_factions = list(first.factions)
    altered_factions[0] = altered_factions[0].model_copy(update={"prompt_hash": "0" * 64})
    wrong_prompt[0] = first.model_copy(update={"factions": altered_factions})
    with pytest.raises(ValueError, match="model configuration"):
        aggregate_season(schedule, wrong_prompt)

    bad_championship = scheduled_result(schedule, schedule.matches[99]).model_copy(
        update={"track": "standard"}
    )
    with pytest.raises(ValueError, match="metadata differs"):
        aggregate_season(schedule, [*results, bad_championship])
