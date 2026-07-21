from __future__ import annotations

import hashlib
from typing import Any, Mapping, Sequence

import pytest
from genesis_arena.duel.artifacts import ImmutableArtifactBundle
from genesis_arena.duel.evaluation import (
    CompetitorSnapshot,
    EnvironmentHashes,
    EvaluationError,
    FrozenSeriesManifest,
    GameDisposition,
    PairedSeriesSpec,
    ReplayEvidence,
    ScoredGameResult,
    build_paired_manifest,
    score_paired_series,
    scored_result_from_verified_replay,
)
from genesis_arena.duel.provider_adapters import EndpointOwnership
from genesis_arena.duel.replay import (
    AuthoritativeReplayRecorder,
    ReplayVerificationHooks,
    replay_and_verify,
)
from pydantic import ValidationError

EXPECTED_SERIES_MANIFEST_SHA256 = "bb55a574666108ce8eb22b26a946fcfe03a66a9b311c702d1c83854fad8658e0"


def _series_spec(
    *,
    mode: str = "continuous_realtime",
    seeds: list[int] | None = None,
) -> PairedSeriesSpec:
    return PairedSeriesSpec(
        series_id="series-alpha-vs-beta",
        decision_mode=mode,
        faction_preset_id="vanguard-v1",
        decision_period_ticks=50 if mode == "continuous_realtime" else 100,
        response_deadline_ms=8_000 if mode == "continuous_realtime" else 45_000,
        seeds=seeds or [41, 97],
        competitors=(
            CompetitorSnapshot(
                competitor_id="alpha",
                model="provider/model-alpha-2026-07-01",
                reasoning="frozen-medium",
                provider_adapter="provider-a-v1",
                service_tier="priority",
                endpoint_ownership=EndpointOwnership.ORGANIZER_HOSTED,
                inference_settings={"temperature": "provider-default-frozen"},
            ),
            CompetitorSnapshot(
                competitor_id="beta",
                model="provider/model-beta-2026-07-01",
                reasoning="frozen-medium",
                provider_adapter="provider-b-v1",
                service_tier="priority",
                endpoint_ownership=EndpointOwnership.ORGANIZER_HOSTED,
                inference_settings={"temperature": "provider-default-frozen"},
            ),
        ),
        inference_workers=("worker-a", "worker-b"),
        environment=EnvironmentHashes(
            protocol="1" * 64,
            engine_build="2" * 64,
            rules="3" * 64,
            map="4" * 64,
            faction="5" * 64,
            items="6" * 64,
            neutrals="7" * 64,
            helper="8" * 64,
            prompt="9" * 64,
            display_assets=("e" * 64,),
        ),
        schedule_nonce="a" * 64,
    )


def _pair_games(manifest: FrozenSeriesManifest, pair_id: str):
    return sorted(
        (game for game in manifest.games if game.pair_id == pair_id),
        key=lambda game: game.leg,
    )


def _replay_evidence(match_id: str) -> ReplayEvidence:
    digest = hashlib.sha256(match_id.encode("utf-8")).hexdigest()
    return ReplayEvidence(
        bundle_content_sha256=digest,
        manifest_sha256="b" * 64,
        final_state_sha256="c" * 64,
        terminal_tick=100,
        checkpoints_verified=1,
        public_events_verified=0,
        compiled_orders_verified=0,
    )


def test_manifest_freezes_two_side_worker_and_dispatch_swapped_legs_per_seed() -> None:
    manifest = build_paired_manifest(_series_spec())
    assert len(manifest.games) == 4
    assert len({game.match_id for game in manifest.games}) == 4

    for pair_id in {game.pair_id for game in manifest.games}:
        first, second = _pair_games(manifest, pair_id)
        assert first.seed == second.seed
        assert first.seat_competitor_ids == ("alpha", "beta")
        assert second.seat_competitor_ids == ("beta", "alpha")
        assert (
            first.inference_workers_by_seat
            == second.inference_workers_by_seat
            == (
                "worker-a",
                "worker-b",
            )
        )
        # Alpha moves from worker A to worker B when it changes seats.
        assert first.inference_workers_by_seat[0] == "worker-a"
        assert second.inference_workers_by_seat[1] == "worker-b"
        assert first.dispatch_order == (0, 1)
        assert second.dispatch_order == (1, 0)
        assert first.match_config.faction_preset_id == second.match_config.faction_preset_id
        assert first.match_config.mirror_faction is second.match_config.mirror_faction is True


def test_manifest_hash_is_canonical_stable_and_mode_specific() -> None:
    first = build_paired_manifest(_series_spec(mode="continuous_realtime"))
    second = build_paired_manifest(_series_spec(mode="continuous_realtime"))
    fixed = build_paired_manifest(_series_spec(mode="fixed_simultaneous"))
    assert first.model_dump(mode="json") == second.model_dump(mode="json")
    assert first.manifest_hash == EXPECTED_SERIES_MANIFEST_SHA256
    assert first.manifest_hash != fixed.manifest_hash

    payload = first.model_dump(mode="json")
    payload["games"][0]["seed"] += 1
    with pytest.raises(ValidationError, match="seed and match-config seed differ|hash mismatch"):
        FrozenSeriesManifest.model_validate(payload)

    long_payload = _series_spec(seeds=[1]).model_dump(mode="python")
    long_payload["series_id"] = "series-" + "x" * 89
    long_manifest = build_paired_manifest(PairedSeriesSpec.model_validate(long_payload))
    assert all(len(game.match_id) <= 122 for game in long_manifest.games)


def test_series_spec_rejects_unpaired_inputs_and_wrong_track_profile() -> None:
    payload = _series_spec().model_dump(mode="python")
    payload["seeds"] = [41, 41]
    with pytest.raises(ValidationError, match="seeds must be unique"):
        PairedSeriesSpec.model_validate(payload)

    payload = _series_spec().model_dump(mode="python")
    payload["inference_workers"] = ("same", "same")
    with pytest.raises(ValidationError, match="distinct inference workers"):
        PairedSeriesSpec.model_validate(payload)

    payload = _series_spec().model_dump(mode="python")
    payload["decision_period_ticks"] = 100
    with pytest.raises(ValidationError, match="cadence must be 50"):
        PairedSeriesSpec.model_validate(payload)

    payload = _series_spec().model_dump(mode="python")
    payload["competitors"][1]["service_tier"] = "different-tier"
    with pytest.raises(ValidationError, match="identical service_tier"):
        PairedSeriesSpec.model_validate(payload)

    payload = _series_spec().model_dump(mode="python")
    payload["environment"]["display_assets"] = ("f" * 64, "e" * 64)
    with pytest.raises(ValidationError, match="canonically sorted"):
        PairedSeriesSpec.model_validate(payload)


def test_outcomes_score_only_godot_win_draw_and_failure_dispositions() -> None:
    manifest = build_paired_manifest(_series_spec())
    pair_ids = sorted({game.pair_id for game in manifest.games})
    first_a, first_b = _pair_games(manifest, pair_ids[0])
    second_a, second_b = _pair_games(manifest, pair_ids[1])
    results = [
        ScoredGameResult(
            match_id=first_a.match_id,
            pair_id=first_a.pair_id,
            leg="A",
            disposition=GameDisposition.NORMAL_WIN,
            winner_slot=0,
            replay_evidence=_replay_evidence(first_a.match_id),
        ),
        ScoredGameResult(
            match_id=first_b.match_id,
            pair_id=first_b.pair_id,
            leg="B",
            disposition=GameDisposition.TECHNICAL_WIN,
            winner_slot=1,
            replay_evidence=_replay_evidence(first_b.match_id),
        ),
        ScoredGameResult(
            match_id=second_a.match_id,
            pair_id=second_a.pair_id,
            leg="A",
            disposition=GameDisposition.DRAW,
            replay_evidence=_replay_evidence(second_a.match_id),
        ),
        ScoredGameResult(
            match_id=second_b.match_id,
            pair_id=second_b.pair_id,
            leg="B",
            disposition=GameDisposition.DRAW,
            replay_evidence=_replay_evidence(second_b.match_id),
        ),
    ]
    score = score_paired_series(manifest, results, bootstrap_replicates=500, bootstrap_seed=17)
    alpha, beta = score.competitors
    assert score.completed_pairs == 2
    assert score.excluded_pairs == 0
    assert score.rerun_match_ids == []
    assert alpha.points_half_units == 6  # 3.0 points without using binary floats.
    assert beta.points_half_units == 2
    assert alpha.normal_wins == 1 and alpha.technical_wins == 1
    assert alpha.draws == beta.draws == 2
    assert alpha.losses == 0 and beta.losses == 2
    assert score.competitor_0_share_bp == 7_500
    assert score.bootstrap_95_ci_bp is not None
    assert score.bootstrap_95_ci_bp[0] <= 7_500 <= score.bootstrap_95_ci_bp[1]


def test_void_or_missing_leg_excludes_whole_pair_and_requires_same_pair_rerun() -> None:
    manifest = build_paired_manifest(_series_spec(seeds=[41]))
    first, second = _pair_games(manifest, manifest.games[0].pair_id)
    results = [
        ScoredGameResult(
            match_id=first.match_id,
            pair_id=first.pair_id,
            leg=first.leg,
            disposition=GameDisposition.NORMAL_WIN,
            winner_slot=0,
            replay_evidence=_replay_evidence(first.match_id),
        ),
        ScoredGameResult(
            match_id=second.match_id,
            pair_id=second.pair_id,
            leg=second.leg,
            disposition=GameDisposition.VOID_INFRASTRUCTURE,
        ),
    ]
    score = score_paired_series(manifest, results, bootstrap_replicates=100)
    assert score.completed_pairs == 0
    assert score.excluded_pairs == 1
    assert score.rerun_match_ids == sorted([first.match_id, second.match_id])
    assert score.competitor_0_share_bp is None
    assert all(value.points_half_units == 0 for value in score.competitors)


def test_double_forfeit_is_zero_zero_and_not_a_draw() -> None:
    manifest = build_paired_manifest(_series_spec(seeds=[41]))
    games = _pair_games(manifest, manifest.games[0].pair_id)
    results = [
        ScoredGameResult(
            match_id=game.match_id,
            pair_id=game.pair_id,
            leg=game.leg,
            disposition=GameDisposition.DOUBLE_FORFEIT,
            replay_evidence=_replay_evidence(game.match_id),
        )
        for game in games
    ]
    score = score_paired_series(manifest, results, bootstrap_replicates=100)
    assert score.completed_pairs == 1
    assert score.competitor_0_share_bp == 0
    for value in score.competitors:
        assert value.points_half_units == 0
        assert value.draws == 0
        assert value.double_forfeits == 2


def test_unscheduled_duplicate_and_misidentified_results_fail_closed() -> None:
    manifest = build_paired_manifest(_series_spec(seeds=[41]))
    game = manifest.games[0]
    valid = ScoredGameResult(
        match_id=game.match_id,
        pair_id=game.pair_id,
        leg=game.leg,
        disposition=GameDisposition.DRAW,
        replay_evidence=_replay_evidence(game.match_id),
    )
    with pytest.raises(EvaluationError, match="duplicate result"):
        score_paired_series(manifest, [valid, valid], bootstrap_replicates=100)

    wrong = ScoredGameResult(
        match_id=game.match_id,
        pair_id="wrong-pair",
        leg=game.leg,
        disposition=GameDisposition.DRAW,
        replay_evidence=_replay_evidence(game.match_id),
    )
    with pytest.raises(EvaluationError, match="identity mismatch"):
        score_paired_series(manifest, [wrong], bootstrap_replicates=100)

    unscheduled = ScoredGameResult(
        match_id="m_not_scheduled",
        pair_id=game.pair_id,
        leg=game.leg,
        disposition=GameDisposition.DRAW,
        replay_evidence=_replay_evidence("m_not_scheduled"),
    )
    with pytest.raises(EvaluationError, match="unscheduled"):
        score_paired_series(manifest, [unscheduled], bootstrap_replicates=100)


def test_win_result_requires_exactly_one_winner_and_draw_forbids_one() -> None:
    with pytest.raises(ValidationError, match="require winner_slot"):
        ScoredGameResult(
            match_id="m_x",
            pair_id="pair-x",
            leg="A",
            disposition=GameDisposition.NORMAL_WIN,
            replay_evidence=_replay_evidence("m_x"),
        )
    with pytest.raises(ValidationError, match="requires verified replay evidence"):
        ScoredGameResult(
            match_id="m_x",
            pair_id="pair-x",
            leg="A",
            disposition=GameDisposition.DRAW,
        )
    with pytest.raises(ValidationError, match="require winner_slot"):
        ScoredGameResult(
            match_id="m_x",
            pair_id="pair-x",
            leg="A",
            disposition=GameDisposition.DRAW,
            winner_slot=0,
            replay_evidence=_replay_evidence("m_x"),
        )


def _verified_replay_for_game(
    series: FrozenSeriesManifest,
    game_index: int = 0,
) -> tuple[ImmutableArtifactBundle, Any]:
    game = series.games[game_index]
    competitors = {value.competitor_id: value for value in series.competitors}
    environment = series.environment
    header = {
        "artifacts": {
            "display_assets": [
                {"id": f"display-{index}", "sha256": sha256}
                for index, sha256 in enumerate(environment.display_assets)
            ],
            "engine": {"id": "godot-4.5", "sha256": environment.engine_build},
            "faction": {
                "id": game.match_config.faction_preset_id,
                "sha256": environment.faction,
            },
            "helper": {"id": "hybrid-v1", "sha256": environment.helper},
            "items": {"id": "items-v1", "sha256": environment.items},
            "map": {"id": game.match_config.map_id, "sha256": environment.map},
            "neutrals": {"id": "neutrals-v1", "sha256": environment.neutrals},
            "prompt": {"id": "prompt-v1", "sha256": environment.prompt},
            "protocol": {"id": "worldeval-rts/1.0.0", "sha256": environment.protocol},
            "rules": {"id": "duel-rules-v1", "sha256": environment.rules},
        },
        "decision": {
            "control_profile": game.match_config.control_profile,
            "decision_period_ticks": game.match_config.decision_period_ticks,
            "mode": game.match_config.decision_mode,
            "observation_profile": game.match_config.observation_profile,
            "response_deadline_ms": game.match_config.response_deadline_ms,
            "simulation_hz": game.match_config.simulation_hz,
        },
        "match_id": game.match_id,
        "players": [
            {
                "model_snapshot": game.match_config.players[slot].model,
                "player_id": f"player_{'a' if slot == 0 else 'b'}",
                "provider_tier": competitors[game.seat_competitor_ids[slot]].service_tier,
                "reasoning": game.match_config.players[slot].reasoning,
            }
            for slot in (0, 1)
        ],
        "replay_guarantees": {
            "checkpoint_interval_ticks": 300,
            "orders_use_recorded_application_ticks": True,
            "provider_calls": 0,
            "stop_on_hash_mismatch": True,
            "supports_omniscient": True,
            "supports_player_perspectives": True,
        },
        "schema_version": "worldeval-rts/replay-manifest/1.0.0",
        "seat_mapping": [
            {"player_id": "player_a", "seat": 0, "world_side": "south"},
            {"player_id": "player_b", "seat": 1, "world_side": "north"},
        ],
        "seed": game.seed,
    }
    recorder = AuthoritativeReplayRecorder(header)
    recorder.record_application(
        1,
        accepted_actions=({"batch_id": "batch-1", "command_id": "command-1", "player_slot": 0},),
        compiled_orders=({"op": "move", "source_action_index": 0},),
    )
    event = {
        "audience": "omniscient",
        "event_seq": 1,
        "kind": "order_started",
        "payload": {"compiled_order_id": "order-1"},
        "tick": 1,
    }
    recorder.record_public_events((event,))
    recorder.record_checkpoint(1, "c" * 64)
    bundle = recorder.seal_publishable(
        terminal={
            "reason": "stronghold_destroyed",
            "result": "normal",
            "tick": 2,
            "winner_player_id": "player_a",
        },
        final_state_sha256="f" * 64,
        aggregate_usage={
            player: {
                "failed_opportunities": 0,
                "input_tokens": 100,
                "latency_ns_total": 1000,
                "output_tokens": 20,
                "requests": 1,
            }
            for player in ("player_a", "player_b")
        },
    )
    state_hash = "0" * 64
    events: list[Mapping[str, Any]] = []

    def advance(tick: int, _orders: Sequence[Mapping[str, Any]]) -> None:
        nonlocal state_hash
        state_hash = "c" * 64 if tick == 1 else "f" * 64
        if tick == 1:
            events.append(event)

    verification = replay_and_verify(
        bundle,
        ReplayVerificationHooks(
            advance_and_apply=advance,
            checkpoint_sha256=lambda: state_hash,
            canonical_events=lambda: events,
        ),
    )
    return bundle, verification


def test_scored_result_is_derived_from_complete_schedule_bound_replay_evidence() -> None:
    series = build_paired_manifest(_series_spec(seeds=[41]))
    game = series.games[0]
    bundle, verification = _verified_replay_for_game(series)
    result = scored_result_from_verified_replay(series, game, bundle, verification)
    assert result.match_id == game.match_id
    assert result.disposition is GameDisposition.NORMAL_WIN
    assert result.winner_slot == 0
    assert result.replay_evidence.bundle_content_sha256 == bundle.content_sha256
    assert result.replay_evidence.checkpoints_verified == 1
    assert result.replay_evidence.public_events_verified == 1

    wrong_game = series.games[1]
    with pytest.raises(EvaluationError, match="match ID|outside the frozen series"):
        scored_result_from_verified_replay(series, wrong_game, bundle, verification)

    changed_spec = _series_spec(seeds=[41]).model_dump(mode="python")
    changed_spec["environment"]["rules"] = "d" * 64
    changed_series = build_paired_manifest(PairedSeriesSpec.model_validate(changed_spec))
    changed_game = next(value for value in changed_series.games if value.match_id == game.match_id)
    with pytest.raises(EvaluationError, match="rules hash"):
        scored_result_from_verified_replay(changed_series, changed_game, bundle, verification)


def test_one_replay_commitment_cannot_be_reused_for_two_scheduled_games() -> None:
    manifest = build_paired_manifest(_series_spec(seeds=[41]))
    first, second = _pair_games(manifest, manifest.games[0].pair_id)
    evidence = _replay_evidence(first.match_id)
    results = [
        ScoredGameResult(
            match_id=game.match_id,
            pair_id=game.pair_id,
            leg=game.leg,
            disposition=GameDisposition.DRAW,
            replay_evidence=evidence,
        )
        for game in (first, second)
    ]
    with pytest.raises(EvaluationError, match="cannot evidence multiple"):
        score_paired_series(manifest, results, bootstrap_replicates=100)
