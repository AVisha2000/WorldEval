from __future__ import annotations

import asyncio
from dataclasses import replace
from pathlib import Path

import pytest
from genesis_arena.embodiment.artifacts import (
    PROTECTED_LAYER,
    PUBLIC_LAYER,
    EpisodeArtifact,
    EpisodeArtifactBundle,
)
from genesis_arena.embodiment.contracts import (
    ActionReceipt,
    MultiParticipantStepResult,
    TerminalState,
)
from genesis_arena.embodiment.duel import (
    DuelCallSettings,
    DuelEntrant,
    DuelLegResult,
    DuelLegVerification,
    DuelSeriesEvidenceBundle,
    LiveProviderCallBudgetExceeded,
    PairedDuelEvidence,
    PairedDuelPlan,
    PairedDuelScheduler,
    RepeatedInvalidPairError,
    aggregate_verified_pair,
    run_paired_duel_with_reruns,
)
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_json_bytes
from genesis_arena.embodiment.providers.contracts import ProviderCallResult, ProviderTelemetry
from genesis_arena.embodiment.series import ModelLock, SeriesLock

ROOT = Path(__file__).resolve().parents[2]
PARTICIPANTS = ("participant_0", "participant_1")


def _package() -> EmbodimentProtocolPackage:
    return EmbodimentProtocolPackage.from_repository(ROOT)


def _plan(*, timeout_ms: int = 200) -> PairedDuelPlan:
    package = _package()
    entrants = (
        DuelEntrant("model_a", "provider_a", "model-a-v1"),
        DuelEntrant("model_b", "provider_b", "model-b-v1"),
    )
    fairness_lock = SeriesLock(
        protocol_version=package.PROTOCOL_VERSION,
        protocol_sha256=package.package_sha256,
        rules_sha256="1" * 64,
        map_sha256="2" * 64,
        body_sha256="3" * 64,
        controller_sha256="4" * 64,
        projector_sha256="5" * 64,
        evaluator_sha256="6" * 64,
        entrants=(
            ModelLock("model_a", "provider_a", "7" * 64, "model-a-v1", "medium"),
            ModelLock("model_b", "provider_b", "8" * 64, "model-b-v1", "medium"),
        ),
        max_input_bytes=8_388_608,
        max_output_bytes=4096,
        deadline_ms=timeout_ms,
        observation_profile="hybrid-visible-v1",
        timing_track="step-locked-v1",
        seed=41,
        schedule_nonce="nonce_1",
    )
    return PairedDuelPlan(
        series_id="paired_case",
        episode_ids=("ep_paired_leg_a", "ep_paired_leg_b"),
        entrants=entrants,
        seed=41,
        schedule_nonce="nonce_1",
        settings=DuelCallSettings(
            system_prompt="Return exactly one strict controller action.",
            action_schema_json=canonical_json_bytes(package.schema("controller-action")),
            timeout_ms=timeout_ms,
            max_input_bytes=8_388_608,
            max_output_bytes=4096,
        ),
        fairness_lock=fairness_lock,
    )


def _observation(episode_id: str, participant_id: str, *, seq: int, tick: int, ended: bool):
    terminal = (
        {"ended": True, "outcome": "draw", "reason": "time_limit"}
        if ended
        else {"ended": False, "outcome": "running", "reason": "running"}
    )
    return {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": episode_id,
        "observation_seq": seq,
        "tick": tick,
        "profile": "text-visible-v1",
        "goal": f"private:{participant_id}",
        "remaining_ticks": max(0, 20 - tick),
        "self": {
            "health_percent": 100,
            "energy_percent": 100,
            "facing": "north",
            "contact": "clear",
            "inventory": [],
            "status": [],
        },
        "visible_entities": [],
        "recent_events": [],
        "previous_receipt": None,
        "memory": "",
        "terminal": terminal,
    }


def _action(request, entrant_id: str) -> bytes:
    return canonical_json_bytes(
        {
            "protocol_version": "llm-controller/0.1.0",
            "episode_id": request.episode_id,
            "observation_seq": request.observation_seq,
            "action_id": f"act_{entrant_id}_{request.observation_seq}",
            "control": {
                "move_x": 0,
                "move_y": 1000,
                "look_x": 0,
                "look_y": 0,
                "duration_ticks": 10,
                "buttons": {
                    "interact": False,
                    "primary": False,
                    "guard": False,
                    "dash": False,
                    "ability_1": False,
                    "ability_2": False,
                    "cycle_item": False,
                    "cancel": False,
                },
            },
            "intent_label": "advance",
            "memory_update": f"memory:{entrant_id}:{request.observation_seq}",
        }
    )


class _Provider:
    def __init__(self, entrant, harness, *, invalid=False, delay=0.0):
        self.provider_name = entrant.provider
        self.entrant = entrant
        self.harness = harness
        self.invalid = invalid
        self.delay = delay
        self.requests = []
        self.closed = False

    async def request(self, request):
        self.requests.append(request)
        self.harness.requests.append((self.entrant.entrant_id, request))
        key = (request.episode_id, request.observation_seq)
        started, release = self.harness.barriers.setdefault(key, (set(), asyncio.Event()))
        started.add(self.entrant.entrant_id)
        if len(started) == 2:
            release.set()
        await release.wait()
        if self.delay:
            await asyncio.sleep(self.delay)
        output = b'{"invalid":true}' if self.invalid else _action(request, self.entrant.entrant_id)
        return ProviderCallResult.success(output, ProviderTelemetry(latency_ms=1))

    async def aclose(self):
        self.closed = True


class _Session:
    def __init__(self, plan, harness, verification, *, windows=2):
        self.plan = plan
        self.harness = harness
        self.verification = verification
        self.expected_windows = windows
        self.windows = []
        self.closed = False

    async def reset(self):
        return {
            participant_id: _observation(
                self.plan.episode_id, participant_id, seq=0, tick=0, ended=False
            )
            for participant_id in PARTICIPANTS
        }

    async def step(self, window):
        self.windows.append(window)
        seq = len(self.windows)
        ended = seq == self.expected_windows
        observations = {
            participant_id: _observation(
                self.plan.episode_id,
                participant_id,
                seq=seq,
                tick=seq * 10,
                ended=ended,
            )
            for participant_id in PARTICIPANTS
        }
        receipts = {}
        for participant_id, decision in window.decisions.items():
            receipts[participant_id] = ActionReceipt(
                action_id=(
                    decision.action.action_id
                    if decision.action is not None
                    else f"no_input_{participant_id}_{seq}"
                ),
                observation_seq=window.observation_seq,
                accepted=decision.action is not None,
                start_tick=window.start_tick,
                end_tick=window.start_tick + 10,
                applied_ticks=10,
                codes=() if decision.action is not None else ("no_input",),
                disposition=decision.disposition,
                fallback=decision.fallback,
                no_input_reason=decision.no_input_reason,
            )
        return MultiParticipantStepResult(
            observations=observations,
            receipts=receipts,
            public_events=(),
            state_hash=f"{seq + self.plan.leg_index + 1:064x}",
            terminal=TerminalState(
                ended,
                "draw" if ended else "running",
                "time_limit" if ended else "running",
            ),
        )

    async def render(self, participant_id, sensor_id, transport_ref, observation_seq):
        raise AssertionError((participant_id, sensor_id, transport_ref, observation_seq))

    async def verify_leg(self, plan):
        return self.verification(plan)

    async def close(self):
        self.closed = True


class _Harness:
    def __init__(self, *, invalid=(), delays=None, verification=None, windows=2):
        self.invalid = set(invalid)
        self.delays = delays or {}
        self.verification = verification or self._verified
        self.expected_windows = windows
        self.factory_order = []
        self.providers = []
        self.sessions = []
        self.requests = []
        self.barriers = {}

    async def provider_factory(self, entrant, plan):
        self.factory_order.append((plan.leg_index, entrant.entrant_id))
        provider = _Provider(
            entrant,
            self,
            invalid=(plan.leg_index, entrant.entrant_id) in self.invalid,
            delay=self.delays.get((plan.leg_index, entrant.entrant_id), 0.0),
        )
        self.providers.append(provider)
        return provider

    async def session_factory(self, plan):
        session = _Session(
            plan,
            self,
            self.verification,
            windows=self.expected_windows,
        )
        self.sessions.append(session)
        return session

    @staticmethod
    def _verified(plan):
        winner = "participant_0" if plan.leg_index == 0 else "participant_1"
        return DuelLegVerification(
            plan_sha256=plan.plan_sha256,
            replay_sha256=f"{plan.leg_index + 10:064x}",
            terminal_state_sha256=f"{plan.leg_index + 20:064x}",
            complete=True,
            verified=True,
            outcome="win",
            winner_participant_id=winner,
        )


def _scheduler(plan, harness):
    return PairedDuelScheduler(
        plan=plan,
        session_factory=harness.session_factory,
        provider_factory=harness.provider_factory,
        protocol_package=_package(),
    )


def _attempt_result(plan: PairedDuelPlan, *, valid: bool):
    legs = []
    for index, leg in enumerate(plan.legs):
        outcome = "void" if not valid and index == 0 else "draw"
        verification = DuelLegVerification(
            plan_sha256=leg.plan_sha256,
            replay_sha256=f"{index + 50:064x}",
            terminal_state_sha256=f"{index + 60:064x}",
            complete=True,
            verified=True,
            outcome=outcome,
        )
        legs.append(DuelLegResult(leg, verification, None, 1, 0))
    return aggregate_verified_pair(plan, (legs[0], legs[1]))


def _attempt_evidence(plan: PairedDuelPlan) -> PairedDuelEvidence:
    public_legs = tuple(
        EpisodeArtifactBundle.create(
            PUBLIC_LAYER,
            (EpisodeArtifact.json("evaluation", {"episode_id": episode_id}),),
        )
        for episode_id in plan.episode_ids
    )
    protected_legs = tuple(
        EpisodeArtifactBundle.create(
            PROTECTED_LAYER,
            (EpisodeArtifact.json("observations", []),),
        )
        for _ in plan.episode_ids
    )
    public = DuelSeriesEvidenceBundle.create(
        layer=PUBLIC_LAYER,
        series_id=plan.series_id,
        plan_sha256=plan.plan_sha256,
        fairness_lock_sha256=plan.fairness_lock.lock_sha256,
        legs=(public_legs[0], public_legs[1]),
    )
    protected = DuelSeriesEvidenceBundle.create(
        layer=PROTECTED_LAYER,
        series_id=plan.series_id,
        plan_sha256=plan.plan_sha256,
        fairness_lock_sha256=plan.fairness_lock.lock_sha256,
        legs=(protected_legs[0], protected_legs[1]),
    )
    return PairedDuelEvidence(public, protected)


class _AttemptScheduler(PairedDuelScheduler):
    def __init__(self, plan, *, valid, cancel_event=None):
        self.plan = plan
        self._result = _attempt_result(plan, valid=valid)
        self._evidence = _attempt_evidence(plan) if valid else None
        self._cancel_event = cancel_event

    async def run(self):
        if self._cancel_event is not None:
            self._cancel_event.set()
        return self._result


@pytest.mark.asyncio
async def test_pair_swaps_all_seat_dimensions_and_aggregates_verified_legs():
    plan = _plan()
    leg_a, leg_b = plan.legs
    assert [value.entrant_id for value in leg_a.assignments] == ["model_a", "model_b"]
    assert [value.entrant_id for value in leg_b.assignments] == ["model_b", "model_a"]
    for entrant_id in ("model_a", "model_b"):
        first = next(value for value in leg_a.assignments if value.entrant_id == entrant_id)
        second = next(value for value in leg_b.assignments if value.entrant_id == entrant_id)
        assert first.participant_id != second.participant_id
        assert first.spawn_side != second.spawn_side
        assert first.dispatch_precedence != second.dispatch_precedence

    harness = _Harness()
    result = await _scheduler(plan, harness).run()

    assert result.status == "complete"
    assert result.entrant_wins == (2, 0)
    assert result.winner_entrant_id == "model_a"
    assert result.draws == 0
    assert harness.factory_order == [
        (0, "model_a"),
        (0, "model_b"),
        (1, "model_b"),
        (1, "model_a"),
    ]
    assert all(session.closed for session in harness.sessions)
    assert all(provider.closed for provider in harness.providers)


@pytest.mark.asyncio
async def test_each_boundary_is_concurrent_and_uses_one_equal_immutable_envelope():
    plan = _plan()
    harness = _Harness(delays={(0, "model_a"): 0.02, (1, "model_b"): 0.02})
    await asyncio.wait_for(_scheduler(plan, harness).run(), timeout=2)

    assert len(harness.requests) == 8
    for episode_id in plan.episode_ids:
        for observation_seq in (0, 1):
            matching = [
                request
                for _, request in harness.requests
                if request.episode_id == episode_id and request.observation_seq == observation_seq
            ]
            assert len(matching) == 2
            assert matching[0].deadline_monotonic_ns == matching[1].deadline_monotonic_ns
            assert matching[0].system_prompt == matching[1].system_prompt
            assert matching[0].action_schema_json == matching[1].action_schema_json
            assert matching[0].max_output_bytes == matching[1].max_output_bytes == 4096
            assert {request.participant_id for request in matching} == set(PARTICIPANTS)
            assert all(request.frame_png is None for request in matching)
    assert all(len(started) == 2 for started, _ in harness.barriers.values())
    assert all(
        window.duration_ticks == 10 for session in harness.sessions for window in session.windows
    )


@pytest.mark.asyncio
async def test_post_factory_identity_failure_closes_every_created_adapter():
    plan = _plan()
    harness = _Harness(windows=1)

    async def wrong_provider_factory(entrant, leg):
        provider = await harness.provider_factory(entrant, leg)
        if entrant.entrant_id == "model_b":
            provider.provider_name = "wrong-provider"
        return provider

    scheduler = PairedDuelScheduler(
        plan=plan,
        session_factory=harness.session_factory,
        provider_factory=wrong_provider_factory,
        protocol_package=_package(),
    )
    with pytest.raises(ValueError, match="wrong provider"):
        await scheduler.run()

    assert len(harness.providers) == 2
    assert all(provider.closed for provider in harness.providers)
    assert harness.sessions[0].closed


@pytest.mark.asyncio
async def test_live_provider_call_budget_stops_before_an_over_budget_boundary():
    plan = replace(_plan(), max_live_provider_calls=1)
    harness = _Harness(windows=1)

    with pytest.raises(LiveProviderCallBudgetExceeded, match="budget exhausted"):
        await _scheduler(plan, harness).run()

    assert harness.requests == []
    assert all(provider.closed for provider in harness.providers)
    assert harness.sessions[0].closed


@pytest.mark.asyncio
async def test_scratchpads_are_participant_isolated_and_reset_between_legs():
    plan = _plan()
    harness = _Harness()
    await _scheduler(plan, harness).run()

    requests = {
        (entrant_id, request.episode_id, request.observation_seq): request
        for entrant_id, request in harness.requests
    }
    assert requests[("model_a", "ep_paired_leg_a", 0)].scratchpad_utf8 == b""
    assert requests[("model_b", "ep_paired_leg_a", 0)].scratchpad_utf8 == b""
    assert requests[("model_a", "ep_paired_leg_a", 1)].scratchpad_utf8 == b"memory:model_a:0"
    assert requests[("model_b", "ep_paired_leg_a", 1)].scratchpad_utf8 == b"memory:model_b:0"
    assert requests[("model_a", "ep_paired_leg_b", 0)].scratchpad_utf8 == b""
    assert requests[("model_b", "ep_paired_leg_b", 0)].scratchpad_utf8 == b""


@pytest.mark.asyncio
async def test_invalid_participant_output_is_recorded_as_neutral_without_blocking_peer():
    plan = _plan()
    harness = _Harness(invalid={(0, "model_b")}, windows=1)
    result = await _scheduler(plan, harness).run()

    first_window = harness.sessions[0].windows[0]
    failed = first_window.decisions["participant_1"]
    peer = first_window.decisions["participant_0"]
    assert failed.disposition == "no_input"
    assert failed.fallback == "neutral"
    assert failed.no_input_reason == "invalid"
    assert first_window.controller_states()["participant_1"].move_y == 0
    assert peer.disposition == "accepted"
    assert result.legs[0].provider_failures == 1


@pytest.mark.asyncio
async def test_timed_out_participant_is_neutral_and_pair_still_advances():
    plan = _plan(timeout_ms=10)
    harness = _Harness(delays={(0, "model_b"): 0.1}, windows=1)
    result = await _scheduler(plan, harness).run()

    failed = harness.sessions[0].windows[0].decisions["participant_1"]
    assert failed.disposition == "no_input"
    assert failed.fallback == "neutral"
    assert failed.no_input_reason == "timeout"
    assert harness.sessions[0].windows[0].duration_ticks == 10
    assert result.legs[0].provider_failures == 1


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", ["void", "unverified", "incomplete"])
async def test_void_or_unverified_leg_invalidates_pair_and_suppresses_scores(kind):
    def verification(plan):
        affected = plan.leg_index == 0
        outcome = "void" if affected and kind == "void" else "draw"
        return DuelLegVerification(
            plan_sha256=plan.plan_sha256,
            replay_sha256=f"{plan.leg_index + 30:064x}",
            terminal_state_sha256=f"{plan.leg_index + 40:064x}",
            complete=not (affected and kind == "incomplete"),
            verified=not (affected and kind == "unverified"),
            outcome=outcome,
        )

    plan = _plan()
    harness = _Harness(verification=verification, windows=1)
    result = await _scheduler(plan, harness).run()

    assert len(result.legs) == 2
    assert result.status == "invalid"
    assert result.rerun_required
    assert result.entrant_wins == (0, 0)
    assert result.draws == 0
    assert result.winner_entrant_id is None


@pytest.mark.asyncio
async def test_invalid_attempt_reruns_both_legs_under_a_fresh_lock_and_keeps_only_final_evidence():
    initial = _plan()
    attempts = []
    cancel_event = asyncio.Event()

    def factory(plan):
        attempts.append(plan)
        return _AttemptScheduler(plan, valid=len(attempts) == 2)

    execution = await run_paired_duel_with_reruns(
        initial_plan=initial,
        scheduler_factory=factory,
        cancel_event=cancel_event,
    )

    assert len(attempts) == 2
    first, rerun = attempts
    assert first == initial
    assert set(first.episode_ids).isdisjoint(rerun.episode_ids)
    assert rerun.schedule_nonce != first.schedule_nonce
    assert rerun.fairness_lock.lock_sha256 != first.fairness_lock.lock_sha256
    assert rerun.plan_sha256 != first.plan_sha256
    first_lock = first.fairness_lock.as_dict()
    rerun_lock = rerun.fairness_lock.as_dict()
    first_lock.pop("schedule_nonce")
    rerun_lock.pop("schedule_nonce")
    assert rerun_lock == first_lock
    assert tuple(leg.assignments for leg in rerun.legs) == tuple(
        leg.assignments for leg in first.legs
    )
    assert all(leg.schedule_nonce == rerun.schedule_nonce for leg in rerun.legs)
    assert execution.result.status == "complete"
    assert execution.result.plan_sha256 == rerun.plan_sha256
    assert execution.evidence is not None
    assert execution.evidence.public.plan_sha256 == rerun.plan_sha256
    assert first.plan_sha256.encode("ascii") not in execution.evidence.public.bundle_bytes


@pytest.mark.asyncio
async def test_pair_rerun_observes_cancellation_before_recreating_either_leg():
    attempts = []
    cancel_event = asyncio.Event()

    def factory(plan):
        attempts.append(plan)
        return _AttemptScheduler(plan, valid=False, cancel_event=cancel_event)

    with pytest.raises(asyncio.CancelledError):
        await run_paired_duel_with_reruns(
            initial_plan=_plan(),
            scheduler_factory=factory,
            cancel_event=cancel_event,
        )
    assert len(attempts) == 1


@pytest.mark.asyncio
async def test_repeated_invalid_pairs_stop_at_the_fixed_attempt_limit():
    attempts = []

    def factory(plan):
        attempts.append(plan)
        return _AttemptScheduler(plan, valid=False)

    with pytest.raises(RepeatedInvalidPairError, match="rerun limit exhausted"):
        await run_paired_duel_with_reruns(
            initial_plan=_plan(),
            scheduler_factory=factory,
            cancel_event=asyncio.Event(),
        )
    assert len(attempts) == 3
    assert len({plan.plan_sha256 for plan in attempts}) == 3
    assert len({episode_id for plan in attempts for episode_id in plan.episode_ids}) == 6
