"""Paired-seed scheduling and outcome scoring for WorldArena Duel.

The authoritative winner always comes from Godot.  This module freezes the fair two-leg schedule,
checks that sides and continuous-mode infrastructure were swapped, and aggregates only complete
paired seeds.  It deliberately has no strategy judge or material-score tiebreak.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep public models compatible with the Python 3.9 floor.
import hashlib
from enum import Enum
from typing import Dict, List, Literal, Optional, Tuple

from pydantic import Field, model_validator

from .artifacts import ImmutableArtifactBundle
from .canonical import canonical_sha256
from .models import (
    DecisionMode,
    DuelModel,
    HashHex,
    Identifier,
    MatchConfig,
    PlayerConfig,
)
from .provider_adapters import EndpointOwnership
from .replay import ReplayVerificationResult, verify_replay_bundle


class EvaluationError(ValueError):
    """A series cannot be scored without violating its frozen paired design."""


class GameDisposition(str, Enum):
    NORMAL_WIN = "normal_win"
    TECHNICAL_WIN = "technical_win"
    DRAW = "draw"
    DOUBLE_FORFEIT = "double_forfeit"
    VOID_INFRASTRUCTURE = "void_infrastructure"


class EnvironmentHashes(DuelModel):
    protocol: HashHex
    engine_build: HashHex
    rules: HashHex
    map: HashHex
    faction: HashHex
    items: HashHex
    neutrals: HashHex
    helper: HashHex
    prompt: HashHex
    display_assets: Tuple[HashHex, ...] = ()

    @model_validator(mode="after")
    def validate_display_assets(self) -> EnvironmentHashes:
        if self.display_assets != tuple(sorted(set(self.display_assets))):
            raise ValueError("display asset hashes must be unique and canonically sorted")
        return self


class CompetitorSnapshot(DuelModel):
    competitor_id: Identifier
    model: str = Field(min_length=1, max_length=200)
    reasoning: str = Field(min_length=1, max_length=80)
    provider_adapter: Identifier
    service_tier: Identifier
    endpoint_ownership: EndpointOwnership
    inference_settings: Dict[str, str] = Field(default_factory=dict, max_length=32)


class PairedSeriesSpec(DuelModel):
    series_id: Identifier
    decision_mode: DecisionMode
    control_profile: Literal["hybrid-v1"] = "hybrid-v1"
    observation_profile: Literal["full-belief-v1"] = "full-belief-v1"
    faction_preset_id: Literal["vanguard-v1", "warhost-v1", "grove-v1", "crypt-v1"]
    map_id: Literal["crossroads-duel-v1"] = "crossroads-duel-v1"
    decision_period_ticks: int = Field(ge=1, le=10_000)
    response_deadline_ms: int = Field(ge=1, le=45_000)
    maximum_match_ticks: int = Field(default=18_000, ge=1, le=18_000)
    seeds: List[int] = Field(min_length=1, max_length=10_000)
    competitors: Tuple[CompetitorSnapshot, CompetitorSnapshot]
    inference_workers: Tuple[Identifier, Identifier]
    environment: EnvironmentHashes
    schedule_nonce: HashHex

    @model_validator(mode="after")
    def validate_pair_and_track(self) -> PairedSeriesSpec:
        if len(set(self.seeds)) != len(self.seeds):
            raise ValueError("paired-series seeds must be unique")
        if any(seed < 0 or seed > 9_007_199_254_740_991 for seed in self.seeds):
            raise ValueError("paired-series seeds must be interoperable non-negative integers")
        if self.competitors[0].competitor_id == self.competitors[1].competitor_id:
            raise ValueError("the two competitor IDs must differ")
        for field in (
            "reasoning",
            "service_tier",
            "endpoint_ownership",
            "inference_settings",
        ):
            if getattr(self.competitors[0], field) != getattr(self.competitors[1], field):
                raise ValueError(f"competitors must use identical {field}")
        if self.inference_workers[0] == self.inference_workers[1]:
            raise ValueError("two distinct inference workers are required for a fair swap")
        if self.decision_mode == "fixed_simultaneous":
            if self.decision_period_ticks not in {50, 100, 150}:
                raise ValueError("fixed_simultaneous cadence must be 50, 100, or 150 ticks")
        else:
            if self.decision_period_ticks != 50:
                raise ValueError("continuous_realtime cadence must be 50 ticks")
            if self.response_deadline_ms > 8_000:
                raise ValueError("continuous_realtime deadline cannot exceed 8000 ms")
        return self


class ScheduledGame(DuelModel):
    match_id: str = Field(pattern=r"^m_[A-Za-z0-9._-]{1,120}$")
    pair_id: Identifier
    leg: Literal["A", "B"]
    seed: int = Field(ge=0, le=9_007_199_254_740_991)
    match_config: MatchConfig
    seat_competitor_ids: Tuple[Identifier, Identifier]
    inference_workers_by_seat: Tuple[Identifier, Identifier]
    dispatch_order: Tuple[Literal[0, 1], Literal[0, 1]]

    @model_validator(mode="after")
    def validate_seat_contract(self) -> ScheduledGame:
        if self.dispatch_order not in ((0, 1), (1, 0)):
            raise ValueError("dispatch_order must contain both seats exactly once")
        if self.match_config.seed != self.seed:
            raise ValueError("scheduled seed and match-config seed differ")
        return self


class FrozenSeriesManifest(DuelModel):
    manifest_version: Literal["worldeval-duel-series/1.0.0"] = "worldeval-duel-series/1.0.0"
    series_id: Identifier
    environment: EnvironmentHashes
    competitors: Tuple[CompetitorSnapshot, CompetitorSnapshot]
    games: List[ScheduledGame] = Field(min_length=2)
    manifest_hash: HashHex

    @model_validator(mode="after")
    def verify_manifest_hash(self) -> FrozenSeriesManifest:
        payload = self.model_dump(mode="json", exclude={"manifest_hash"})
        if canonical_sha256(payload) != self.manifest_hash:
            raise ValueError("series manifest hash mismatch")
        return self


class ReplayEvidence(DuelModel):
    """Content commitments proving that one result completed an offline replay audit."""

    verification_version: Literal["worldeval-duel-replay-evidence/1.0.0"] = (
        "worldeval-duel-replay-evidence/1.0.0"
    )
    bundle_content_sha256: HashHex
    manifest_sha256: HashHex
    final_state_sha256: HashHex
    terminal_tick: int = Field(ge=0, le=9_007_199_254_740_991)
    checkpoints_verified: int = Field(ge=1)
    public_events_verified: int = Field(ge=0)
    compiled_orders_verified: int = Field(ge=0)


class ScoredGameResult(DuelModel):
    match_id: str = Field(pattern=r"^m_[A-Za-z0-9._-]{1,120}$")
    pair_id: Identifier
    leg: Literal["A", "B"]
    disposition: GameDisposition
    winner_slot: Optional[int] = Field(default=None, ge=0, le=1)
    replay_evidence: Optional[ReplayEvidence] = None

    @model_validator(mode="after")
    def validate_winner(self) -> ScoredGameResult:
        needs_winner = self.disposition in {
            GameDisposition.NORMAL_WIN,
            GameDisposition.TECHNICAL_WIN,
        }
        if needs_winner != (self.winner_slot is not None):
            raise ValueError("only normal and technical wins require winner_slot")
        if (
            self.disposition is not GameDisposition.VOID_INFRASTRUCTURE
            and self.replay_evidence is None
        ):
            raise ValueError("every scored game requires verified replay evidence")
        return self


class CompetitorSeriesScore(DuelModel):
    competitor_id: Identifier
    points_half_units: int = Field(ge=0)
    normal_wins: int = Field(ge=0)
    technical_wins: int = Field(ge=0)
    draws: int = Field(ge=0)
    losses: int = Field(ge=0)
    double_forfeits: int = Field(ge=0)


class SeriesScore(DuelModel):
    series_id: Identifier
    manifest_hash: HashHex
    completed_pairs: int = Field(ge=0)
    excluded_pairs: int = Field(ge=0)
    rerun_match_ids: List[str]
    competitors: Tuple[CompetitorSeriesScore, CompetitorSeriesScore]
    competitor_0_share_bp: Optional[int] = Field(default=None, ge=0, le=10_000)
    bootstrap_95_ci_bp: Optional[Tuple[int, int]] = None


def build_paired_manifest(spec: PairedSeriesSpec) -> FrozenSeriesManifest:
    """Freeze two side/worker-swapped games per seed in deterministic random order."""

    competitor_x, competitor_y = spec.competitors
    worker_0, worker_1 = spec.inference_workers
    series_match_token = spec.series_id
    if len(series_match_token) > 80:
        suffix = hashlib.sha256(series_match_token.encode("utf-8")).hexdigest()[:12]
        series_match_token = f"{series_match_token[:63]}-{suffix}"
    games: List[ScheduledGame] = []
    for seed_index, seed in enumerate(spec.seeds):
        pair_id = f"pair-{seed_index:05d}-{seed}"
        legs = (
            (
                "A",
                (competitor_x, competitor_y),
                (worker_0, worker_1),
                (0, 1),
            ),
            (
                "B",
                (competitor_y, competitor_x),
                (worker_0, worker_1),
                (1, 0),
            ),
        )
        for leg, seated, workers, dispatch_order in legs:
            match_id = f"m_{series_match_token}_{seed_index:05d}_{leg.lower()}"
            players = [
                PlayerConfig(
                    slot=slot,
                    model=seated[slot].model,
                    reasoning=seated[slot].reasoning,
                    provider_adapter=seated[slot].provider_adapter,
                )
                for slot in (0, 1)
            ]
            config = MatchConfig(
                decision_mode=spec.decision_mode,
                faction_preset_id=spec.faction_preset_id,
                seed=seed,
                decision_period_ticks=spec.decision_period_ticks,
                response_deadline_ms=spec.response_deadline_ms,
                maximum_match_ticks=spec.maximum_match_ticks,
                players=players,
            )
            games.append(
                ScheduledGame(
                    match_id=match_id,
                    pair_id=pair_id,
                    leg=leg,
                    seed=seed,
                    match_config=config,
                    seat_competitor_ids=(
                        seated[0].competitor_id,
                        seated[1].competitor_id,
                    ),
                    inference_workers_by_seat=workers,
                    dispatch_order=dispatch_order,
                )
            )

    # Randomization is committed up front but never relies on mutable process PRNG state.
    games.sort(
        key=lambda game: hashlib.sha256(
            ("worldeval-duel/schedule/v1\0" + spec.schedule_nonce + "\0" + game.match_id).encode(
                "utf-8"
            )
        ).digest()
    )
    payload = {
        "manifest_version": "worldeval-duel-series/1.0.0",
        "series_id": spec.series_id,
        "environment": spec.environment.model_dump(mode="json"),
        "competitors": [value.model_dump(mode="json") for value in spec.competitors],
        "games": [value.model_dump(mode="json") for value in games],
    }
    return FrozenSeriesManifest(
        **payload,
        manifest_hash=canonical_sha256(payload),
    )


def scored_result_from_verified_replay(
    series: FrozenSeriesManifest,
    game: ScheduledGame,
    bundle: ImmutableArtifactBundle,
    verification: ReplayVerificationResult,
) -> ScoredGameResult:
    """Derive an evaluation result only from a scheduled, fully reproduced public replay."""

    scheduled = [value for value in series.games if value.match_id == game.match_id]
    if len(scheduled) != 1 or scheduled[0] != game:
        raise EvaluationError("verified replay references a game outside the frozen series")
    contract = verify_replay_bundle(
        bundle, expected_content_sha256=verification.bundle_content_sha256
    )
    if (
        verification.match_id != contract.match_id
        or verification.manifest_sha256 != contract.manifest_sha256
        or verification.final_tick != contract.terminal_tick
        or verification.final_state_sha256 != contract.final_state_sha256
        or verification.checkpoints_verified != contract.checkpoints
        or verification.events_verified != contract.public_events
        or verification.transcript_entries != contract.compiled_orders
    ):
        raise EvaluationError("offline replay evidence does not cover the complete sealed bundle")
    manifest = bundle.manifest
    _verify_replay_matches_schedule(series, game, manifest)

    terminal = manifest["terminal"]
    result = terminal["result"]
    winner_player_id = terminal["winner_player_id"]
    seat_by_player = {value["player_id"]: value["seat"] for value in manifest["seat_mapping"]}
    winner_slot = None if winner_player_id is None else int(seat_by_player[winner_player_id])
    if result == "normal":
        disposition = GameDisposition.NORMAL_WIN
    elif result == "draw":
        disposition = GameDisposition.DRAW
    elif result == "technical_forfeit":
        disposition = (
            GameDisposition.DOUBLE_FORFEIT if winner_slot is None else GameDisposition.TECHNICAL_WIN
        )
    elif result == "infrastructure_void":
        disposition = GameDisposition.VOID_INFRASTRUCTURE
    else:  # The replay schema and verifier should already make this unreachable.
        raise EvaluationError(f"unsupported terminal result: {result!r}")
    return ScoredGameResult(
        match_id=game.match_id,
        pair_id=game.pair_id,
        leg=game.leg,
        disposition=disposition,
        winner_slot=winner_slot,
        replay_evidence=ReplayEvidence(
            bundle_content_sha256=contract.content_sha256,
            manifest_sha256=contract.manifest_sha256,
            final_state_sha256=contract.final_state_sha256,
            terminal_tick=contract.terminal_tick,
            checkpoints_verified=contract.checkpoints,
            public_events_verified=contract.public_events,
            compiled_orders_verified=contract.compiled_orders,
        ),
    )


def score_paired_series(
    manifest: FrozenSeriesManifest,
    results: List[ScoredGameResult],
    *,
    bootstrap_replicates: int = 2_000,
    bootstrap_seed: int = 0,
) -> SeriesScore:
    """Score complete pairs and bootstrap paired seeds, never individual games."""

    if bootstrap_replicates < 100 or bootstrap_replicates > 100_000:
        raise EvaluationError("bootstrap_replicates must be in [100, 100000]")
    if bootstrap_seed < 0:
        raise EvaluationError("bootstrap_seed must be non-negative")
    scheduled = {game.match_id: game for game in manifest.games}
    if len(scheduled) != len(manifest.games):
        raise EvaluationError("manifest contains duplicate match IDs")
    by_match: Dict[str, ScoredGameResult] = {}
    replay_hashes: set[str] = set()
    for result in results:
        if result.match_id not in scheduled:
            raise EvaluationError(f"result references unscheduled match {result.match_id}")
        if result.match_id in by_match:
            raise EvaluationError(f"duplicate result for {result.match_id}")
        game = scheduled[result.match_id]
        if result.pair_id != game.pair_id or result.leg != game.leg:
            raise EvaluationError(f"result identity mismatch for {result.match_id}")
        if result.replay_evidence is not None:
            replay_hash = result.replay_evidence.bundle_content_sha256
            if replay_hash in replay_hashes:
                raise EvaluationError(
                    "one replay artifact cannot evidence multiple scheduled games"
                )
            replay_hashes.add(replay_hash)
        by_match[result.match_id] = result

    pair_games: Dict[str, List[ScheduledGame]] = {}
    for game in manifest.games:
        pair_games.setdefault(game.pair_id, []).append(game)

    competitor_ids = tuple(value.competitor_id for value in manifest.competitors)
    counters = {
        competitor_id: {
            "points_half_units": 0,
            "normal_wins": 0,
            "technical_wins": 0,
            "draws": 0,
            "losses": 0,
            "double_forfeits": 0,
        }
        for competitor_id in competitor_ids
    }
    rerun_ids: List[str] = []
    completed_pair_points: List[Tuple[int, int]] = []
    excluded_pairs = 0

    for pair_id in sorted(pair_games):
        games = sorted(pair_games[pair_id], key=lambda value: value.leg)
        if len(games) != 2 or [game.leg for game in games] != ["A", "B"]:
            raise EvaluationError(f"pair {pair_id} does not contain exactly legs A and B")
        _validate_pair_swap(games, manifest.competitors)
        pair_results = [by_match.get(game.match_id) for game in games]
        if any(result is None for result in pair_results) or any(
            result is not None and result.disposition is GameDisposition.VOID_INFRASTRUCTURE
            for result in pair_results
        ):
            excluded_pairs += 1
            rerun_ids.extend(game.match_id for game in games)
            continue

        before = {
            competitor_id: int(counters[competitor_id]["points_half_units"])
            for competitor_id in competitor_ids
        }
        for game, result in zip(games, pair_results):
            assert result is not None
            _apply_game_score(game, result, counters)
        completed_pair_points.append(
            tuple(
                int(counters[competitor_id]["points_half_units"]) - before[competitor_id]
                for competitor_id in competitor_ids
            )
        )

    scores = tuple(
        CompetitorSeriesScore(competitor_id=competitor_id, **counters[competitor_id])
        for competitor_id in competitor_ids
    )
    share: Optional[int] = None
    interval: Optional[Tuple[int, int]] = None
    if completed_pair_points:
        maximum_half_points = 4 * len(completed_pair_points)
        share = _round_ratio_bp(
            sum(points[0] for points in completed_pair_points), maximum_half_points
        )
        interval = _bootstrap_pair_share_interval(
            completed_pair_points,
            replicates=bootstrap_replicates,
            seed=bootstrap_seed,
            manifest_hash=manifest.manifest_hash,
        )
    return SeriesScore(
        series_id=manifest.series_id,
        manifest_hash=manifest.manifest_hash,
        completed_pairs=len(completed_pair_points),
        excluded_pairs=excluded_pairs,
        rerun_match_ids=sorted(set(rerun_ids)),
        competitors=scores,
        competitor_0_share_bp=share,
        bootstrap_95_ci_bp=interval,
    )


def _verify_replay_matches_schedule(
    series: FrozenSeriesManifest,
    game: ScheduledGame,
    manifest: Dict[str, object],
) -> None:
    if manifest.get("match_id") != game.match_id:
        raise EvaluationError("replay match ID differs from its scheduled game")
    if manifest.get("seed") != game.seed:
        raise EvaluationError("replay seed differs from its scheduled game")
    terminal = manifest.get("terminal")
    if (
        not isinstance(terminal, dict)
        or terminal.get("tick", 0) > game.match_config.maximum_match_ticks
    ):
        raise EvaluationError("replay terminal tick exceeds the frozen match limit")
    decision = manifest.get("decision")
    if not isinstance(decision, dict):
        raise EvaluationError("replay decision profile is absent")
    expected_decision = {
        "control_profile": game.match_config.control_profile,
        "decision_period_ticks": game.match_config.decision_period_ticks,
        "mode": game.match_config.decision_mode,
        "observation_profile": game.match_config.observation_profile,
        "response_deadline_ms": game.match_config.response_deadline_ms,
        "simulation_hz": game.match_config.simulation_hz,
    }
    if decision != expected_decision:
        raise EvaluationError("replay decision profile differs from its scheduled game")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict):
        raise EvaluationError("replay artifact hashes are absent")
    expected_hashes = {
        "protocol": series.environment.protocol,
        "engine": series.environment.engine_build,
        "rules": series.environment.rules,
        "map": series.environment.map,
        "faction": series.environment.faction,
        "items": series.environment.items,
        "neutrals": series.environment.neutrals,
        "helper": series.environment.helper,
        "prompt": series.environment.prompt,
    }
    for name, expected_hash in expected_hashes.items():
        reference = artifacts.get(name)
        if not isinstance(reference, dict) or reference.get("sha256") != expected_hash:
            raise EvaluationError(f"replay {name} hash differs from the frozen environment")
    if artifacts["map"].get("id") != game.match_config.map_id:
        raise EvaluationError("replay map ID differs from its scheduled game")
    if artifacts["faction"].get("id") != game.match_config.faction_preset_id:
        raise EvaluationError("replay faction ID differs from its scheduled game")
    display_assets = artifacts.get("display_assets")
    if (
        not isinstance(display_assets, list)
        or tuple(value.get("sha256") for value in display_assets)
        != series.environment.display_assets
    ):
        raise EvaluationError("replay display asset hashes differ from the frozen environment")

    player_by_id = {
        value["player_id"]: value
        for value in manifest.get("players", [])  # type: ignore[index]
    }
    seat_mapping = manifest.get("seat_mapping")
    if not isinstance(seat_mapping, list):
        raise EvaluationError("replay seat mapping is absent")
    competitor_by_id = {value.competitor_id: value for value in series.competitors}
    for seat in seat_mapping:
        slot = seat["seat"]
        player_id = seat["player_id"]
        public_player = player_by_id[player_id]
        scheduled_player = game.match_config.players[slot]
        competitor = competitor_by_id[game.seat_competitor_ids[slot]]
        if (
            public_player["model_snapshot"] != scheduled_player.model
            or public_player["reasoning"] != scheduled_player.reasoning
            or public_player["provider_tier"] != competitor.service_tier
        ):
            raise EvaluationError("replay player snapshot differs from the frozen schedule")


def _validate_pair_swap(
    games: List[ScheduledGame], competitors: Tuple[CompetitorSnapshot, CompetitorSnapshot]
) -> None:
    competitor_ids = tuple(value.competitor_id for value in competitors)
    competitor_by_id = {value.competitor_id: value for value in competitors}
    first, second = games
    if first.seed != second.seed:
        raise EvaluationError(f"pair {first.pair_id} changed seed between legs")
    if first.seat_competitor_ids != competitor_ids:
        raise EvaluationError(f"pair {first.pair_id} leg A has the wrong seat assignment")
    if second.seat_competitor_ids != (competitor_ids[1], competitor_ids[0]):
        raise EvaluationError(f"pair {first.pair_id} leg B did not swap seats")
    if first.inference_workers_by_seat != second.inference_workers_by_seat:
        raise EvaluationError(f"pair {first.pair_id} changed the worker-by-seat pool")
    # Because competitors change seats while workers stay attached to seats, each competitor uses
    # the other worker in leg B. Dispatch precedence is explicitly reversed as well.
    if first.dispatch_order != (0, 1) or second.dispatch_order != (1, 0):
        raise EvaluationError(f"pair {first.pair_id} did not reverse dispatch order")
    for game in games:
        for slot, competitor_id in enumerate(game.seat_competitor_ids):
            expected = competitor_by_id[competitor_id]
            player = game.match_config.players[slot]
            if (
                player.slot != slot
                or player.model != expected.model
                or player.reasoning != expected.reasoning
                or player.provider_adapter != expected.provider_adapter
            ):
                raise EvaluationError(
                    f"pair {first.pair_id} player configuration does not match seat {slot}"
                )
    comparable = (
        "decision_mode",
        "control_profile",
        "observation_profile",
        "faction_preset_id",
        "map_id",
        "seed",
        "simulation_hz",
        "decision_period_ticks",
        "response_deadline_ms",
        "maximum_match_ticks",
        "memory_policy",
    )
    for field in comparable:
        if getattr(first.match_config, field) != getattr(second.match_config, field):
            raise EvaluationError(f"pair {first.pair_id} changed {field} between legs")


def _apply_game_score(
    game: ScheduledGame,
    result: ScoredGameResult,
    counters: Dict[str, Dict[str, int]],
) -> None:
    seat_ids = game.seat_competitor_ids
    if result.disposition in {GameDisposition.NORMAL_WIN, GameDisposition.TECHNICAL_WIN}:
        assert result.winner_slot is not None
        winner = seat_ids[result.winner_slot]
        loser = seat_ids[1 - result.winner_slot]
        counters[winner]["points_half_units"] += 2
        counters[winner][
            "normal_wins" if result.disposition is GameDisposition.NORMAL_WIN else "technical_wins"
        ] += 1
        counters[loser]["losses"] += 1
    elif result.disposition is GameDisposition.DRAW:
        for competitor_id in seat_ids:
            counters[competitor_id]["points_half_units"] += 1
            counters[competitor_id]["draws"] += 1
    elif result.disposition is GameDisposition.DOUBLE_FORFEIT:
        for competitor_id in seat_ids:
            counters[competitor_id]["double_forfeits"] += 1
    else:
        raise EvaluationError("infrastructure void reached the scoring path")


def _bootstrap_pair_share_interval(
    pair_points: List[Tuple[int, int]],
    *,
    replicates: int,
    seed: int,
    manifest_hash: str,
) -> Tuple[int, int]:
    count = len(pair_points)
    maximum_half_points = 4 * count
    estimates: List[int] = []
    for replicate in range(replicates):
        points = 0
        for draw in range(count):
            digest = hashlib.sha256(
                (
                    "worldeval-duel/paired-bootstrap/v1\0"
                    f"{manifest_hash}\0{seed}\0{replicate}\0{draw}"
                ).encode("ascii")
            ).digest()
            index = int.from_bytes(digest[:8], "big") % count
            points += pair_points[index][0]
        estimates.append(_round_ratio_bp(points, maximum_half_points))
    estimates.sort()
    lower_index = (25 * (replicates - 1)) // 1_000
    upper_index = (975 * (replicates - 1) + 999) // 1_000
    return estimates[lower_index], estimates[upper_index]


def _round_ratio_bp(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise EvaluationError("score denominator must be positive")
    return (numerator * 10_000 + denominator // 2) // denominator
