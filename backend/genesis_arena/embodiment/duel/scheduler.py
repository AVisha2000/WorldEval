"""Concurrent fixed-window execution for a verified paired model duel."""

from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import replace
from typing import Any, Awaitable, Callable, Mapping, Protocol, runtime_checkable

from ..contracts import DecisionWindow, MultiParticipantStepResult
from ..live_solo import parse_controller_action
from ..protocol import EmbodimentProtocolPackage, ProtocolValidationError, canonical_json_bytes
from ..providers.contracts import (
    ProviderAdapter,
    ProviderAuditRecord,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)
from ..scratchpad import EpisodeScratchpad
from .contracts import (
    DuelEntrant,
    DuelLegPlan,
    DuelLegResult,
    DuelLegVerification,
    PairedDuelPlan,
    PairedDuelResult,
    SeatAssignment,
    aggregate_verified_pair,
)
from .evidence import (
    DuelSeriesExecution,
    PairedDuelEvidence,
    VerifiedLegMaterial,
    build_paired_duel_evidence,
)

MAX_PAIR_ATTEMPTS = 3


class RepeatedInvalidPairError(RuntimeError):
    """The bounded whole-pair rerun policy exhausted without a valid pair."""


class LiveProviderCallBudgetExceeded(RuntimeError):
    """A live series reached its explicit provider-call safety boundary."""


class LiveProviderCallBudget:
    def __init__(self, maximum: int) -> None:
        if isinstance(maximum, bool) or not isinstance(maximum, int) or not 1 <= maximum <= 2160:
            raise ValueError("maximum live provider calls must be from 1 to 2160")
        self.maximum = maximum
        self.used = 0

    def reserve(self, count: int) -> None:
        if isinstance(count, bool) or not isinstance(count, int) or count < 0:
            raise ValueError("live provider call reservation is invalid")
        if self.used + count > self.maximum:
            raise LiveProviderCallBudgetExceeded("live provider call budget exhausted")
        self.used += count


@runtime_checkable
class AsyncDuelSession(Protocol):
    """Authority surface injected into the provider-neutral paired scheduler."""

    async def reset(self) -> Mapping[str, Mapping[str, Any]]: ...

    async def step(self, window: DecisionWindow) -> MultiParticipantStepResult: ...

    async def render(
        self,
        participant_id: str,
        sensor_id: str,
        transport_ref: str,
        observation_seq: int,
    ) -> bytes: ...

    async def verify_leg(self, plan: DuelLegPlan) -> DuelLegVerification: ...

    async def close(self) -> None: ...


SessionFactory = Callable[[DuelLegPlan], Awaitable[AsyncDuelSession]]
ProviderFactory = Callable[[DuelEntrant, DuelLegPlan], Awaitable[ProviderAdapter]]
ParticipantFrameSink = Callable[[int, str, int, bytes], Awaitable[None]]


class PairedDuelScheduler:
    """Run both symmetric legs and expose a score only for a verified complete pair."""

    def __init__(
        self,
        *,
        plan: PairedDuelPlan,
        session_factory: SessionFactory,
        provider_factory: ProviderFactory,
        protocol_package: EmbodimentProtocolPackage,
        monotonic_ns: Callable[[], int] = time.monotonic_ns,
        require_verified_evidence: bool = False,
        live_provider_call_budget: LiveProviderCallBudget | None = None,
        participant_frame_sink: ParticipantFrameSink | None = None,
    ) -> None:
        if not isinstance(plan, PairedDuelPlan):
            raise TypeError("plan must be PairedDuelPlan")
        if not callable(session_factory) or not callable(provider_factory):
            raise TypeError("session_factory and provider_factory must be callable")
        if not isinstance(protocol_package, EmbodimentProtocolPackage):
            raise TypeError("protocol_package must be EmbodimentProtocolPackage")
        if not callable(monotonic_ns):
            raise TypeError("monotonic_ns must be callable")
        if not isinstance(require_verified_evidence, bool):
            raise TypeError("require_verified_evidence must be a boolean")
        if participant_frame_sink is not None and not callable(participant_frame_sink):
            raise TypeError("participant_frame_sink must be callable")
        self.plan = plan
        self._session_factory = session_factory
        self._provider_factory = provider_factory
        self._package = protocol_package
        self._monotonic_ns = monotonic_ns
        self._require_verified_evidence = require_verified_evidence
        self._live_provider_call_budget = live_provider_call_budget or LiveProviderCallBudget(
            plan.max_live_provider_calls
        )
        self._evidence: PairedDuelEvidence | None = None
        self._participant_frame_sink = participant_frame_sink

    @property
    def evidence(self) -> PairedDuelEvidence | None:
        return self._evidence

    async def run(self) -> PairedDuelResult:
        """Execute both scheduled legs; a void/incomplete leg invalidates the entire pair."""

        self._evidence = None
        results = []
        materials = []
        for leg in self.plan.legs:
            result, material = await self._run_leg(leg)
            results.append(result)
            materials.append(material)
        pair = aggregate_verified_pair(self.plan, (results[0], results[1]))
        if pair.status == "complete":
            if all(isinstance(value, VerifiedLegMaterial) for value in materials):
                self._evidence = build_paired_duel_evidence(
                    plan=self.plan,
                    result=pair,
                    materials=(materials[0], materials[1]),  # type: ignore[arg-type]
                    protocol_package=self._package,
                )
            elif self._require_verified_evidence:
                raise RuntimeError("complete duel pair did not retain verified replay evidence")
        return pair

    async def _run_leg(self, plan: DuelLegPlan) -> tuple[DuelLegResult, VerifiedLegMaterial | None]:
        session = await self._session_factory(plan)
        if not isinstance(session, AsyncDuelSession):
            raise TypeError("session_factory returned an invalid duel session")
        providers: dict[str, ProviderAdapter] = {}
        scratchpads: dict[str, EpisodeScratchpad] = {}
        windows = 0
        failures = 0
        provider_audits: list[ProviderAuditRecord] = []
        try:
            providers = await self._create_providers(plan)
            scratchpads = {
                assignment.participant_id: EpisodeScratchpad() for assignment in plan.assignments
            }
            observations = await session.reset()
            while not _observations_ended(observations):
                observation_seq, start_tick = _joint_boundary(observations, plan.episode_id)
                window, boundary_failures, boundary_audits = await self._dispatch_boundary(
                    plan=plan,
                    session=session,
                    providers=providers,
                    scratchpads=scratchpads,
                    observations=observations,
                    observation_seq=observation_seq,
                    start_tick=start_tick,
                )
                step = await session.step(window)
                windows += 1
                failures += boundary_failures
                provider_audits.extend(boundary_audits)
                if windows > 180:
                    raise RuntimeError("duel authority exceeded the 180-window horizon")
                for participant_id, decision in window.decisions.items():
                    if decision.action is not None:
                        scratchpads[participant_id].set(decision.action.memory_update)
                observations = step.observations
            verification = await session.verify_leg(plan)
            if not isinstance(verification, DuelLegVerification):
                raise TypeError("verify_leg returned an invalid result")
            winner = _winner_entrant(plan, verification)
            result = DuelLegResult(plan, verification, winner, windows, failures)
            material = _take_verified_material(session, verification, provider_audits)
            return result, material
        finally:
            for scratchpad in scratchpads.values():
                scratchpad.close()
            await _close_providers(providers)
            await session.close()

    async def _create_providers(self, plan: DuelLegPlan) -> dict[str, ProviderAdapter]:
        entrants = {entrant.entrant_id: entrant for entrant in self.plan.entrants}
        ordered = sorted(plan.assignments, key=lambda value: value.dispatch_precedence)
        pending = [
            asyncio.create_task(
                self._provider_factory(entrants[assignment.entrant_id], plan),
                name=f"duel-provider-factory-leg-{plan.leg_index}-{assignment.entrant_id}",
            )
            for assignment in ordered
        ]
        try:
            created = await asyncio.gather(*pending)
        except BaseException:
            for task in pending:
                task.cancel()
            settled = await asyncio.gather(*pending, return_exceptions=True)
            await _close_providers(
                {
                    f"partial_{index}": value
                    for index, value in enumerate(settled)
                    if isinstance(value, ProviderAdapter)
                }
            )
            raise
        providers: dict[str, ProviderAdapter] = {}
        try:
            for assignment, provider in zip(ordered, created):
                if not isinstance(provider, ProviderAdapter):
                    raise TypeError("provider_factory returned an invalid provider")
                entrant = entrants[assignment.entrant_id]
                if provider.provider_name != entrant.provider:
                    raise ValueError("provider_factory returned the wrong provider")
                providers[assignment.participant_id] = provider
        except BaseException:
            await _close_providers(
                {
                    f"created_{index}": value
                    for index, value in enumerate(created)
                    if isinstance(value, ProviderAdapter)
                }
            )
            raise
        return providers

    async def _dispatch_boundary(
        self,
        *,
        plan: DuelLegPlan,
        session: AsyncDuelSession,
        providers: Mapping[str, ProviderAdapter],
        scratchpads: Mapping[str, EpisodeScratchpad],
        observations: Mapping[str, Mapping[str, Any]],
        observation_seq: int,
        start_tick: int,
    ) -> tuple[DecisionWindow, int, tuple[ProviderAuditRecord, ProviderAuditRecord]]:
        ordered = sorted(plan.assignments, key=lambda value: value.dispatch_precedence)
        # A managed authority uses one authenticated request/response transport. Fetch both
        # participant-bound frames at the shared boundary before starting either provider call;
        # the model calls below remain concurrent and receive one identical deadline.
        frames = []
        for assignment in ordered:
            frames.append(
                await self._frame(session, assignment, observations[assignment.participant_id])
            )
        if self._participant_frame_sink is not None:
            await asyncio.gather(
                *(
                    self._participant_frame_sink(
                        plan.leg_index,
                        assignment.participant_id,
                        observation_seq,
                        frame,
                    )
                    for assignment, frame in zip(ordered, frames)
                    if frame is not None
                )
            )
        shared_deadline = self._monotonic_ns() + self.plan.settings.timeout_ms * 1_000_000
        entrants = {entrant.entrant_id: entrant for entrant in self.plan.entrants}
        requests: dict[str, ProviderRequest] = {}
        for assignment, frame in zip(ordered, frames):
            participant_id = assignment.participant_id
            observation = dict(observations[participant_id])
            observation["memory"] = scratchpads[participant_id].text
            entrant = entrants[assignment.entrant_id]
            requests[participant_id] = ProviderRequest(
                episode_id=plan.episode_id,
                participant_id=participant_id,
                observation_seq=observation_seq,
                deadline_monotonic_ns=shared_deadline,
                model=entrant.model,
                system_prompt=self.plan.settings.system_prompt,
                observation_json=canonical_json_bytes(observation),
                action_schema_json=self.plan.settings.action_schema_json,
                scratchpad_utf8=scratchpads[participant_id].utf8,
                frame_png=frame,
                max_input_bytes=self.plan.settings.max_input_bytes,
                max_output_bytes=self.plan.settings.max_output_bytes,
            )

        self._live_provider_call_budget.reserve(
            sum(
                providers[assignment.participant_id].provider_name not in ("scripted", "demo")
                for assignment in ordered
            )
        )
        pending = [
            asyncio.create_task(
                self._call_provider(
                    providers[assignment.participant_id], requests[assignment.participant_id]
                ),
                name=f"duel-call-leg-{plan.leg_index}-{assignment.entrant_id}",
            )
            for assignment in ordered
        ]
        try:
            returned = await asyncio.gather(*pending)
        except BaseException:
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            raise
        results = {
            assignment.participant_id: returned_value[0]
            for assignment, returned_value in zip(ordered, returned)
        }
        audits = tuple(returned_value[1] for returned_value in returned)

        actions = {}
        reasons = {}
        failures = 0
        for assignment in sorted(plan.assignments, key=lambda value: value.participant_id):
            participant_id = assignment.participant_id
            result = results[participant_id]
            action = _validated_action(
                result,
                episode_id=plan.episode_id,
                observation_seq=observation_seq,
                max_output_bytes=self.plan.settings.max_output_bytes,
                package=self._package,
            )
            if action is None:
                failures += 1
                reasons[participant_id] = (
                    "timeout" if result.failure == ProviderFailureKind.TIMEOUT else "invalid"
                )
            else:
                actions[participant_id] = action
        return (
            DecisionWindow.finalize(
                episode_id=plan.episode_id,
                observation_seq=observation_seq,
                mode=plan.mode,
                start_tick=start_tick,
                participant_ids=("participant_0", "participant_1"),
                actions=actions,
                failure_reasons=reasons,  # type: ignore[arg-type]
                duration_ticks=10,
            ),
            failures,
            (audits[0], audits[1]),
        )

    async def _call_provider(
        self, provider: ProviderAdapter, request: ProviderRequest
    ) -> tuple[ProviderCallResult, ProviderAuditRecord]:
        started = self._monotonic_ns()
        remaining = max(0.0, (request.deadline_monotonic_ns - started) / 1_000_000_000)
        try:
            result = await asyncio.wait_for(provider.request(request), timeout=remaining)
            if not isinstance(result, ProviderCallResult):
                raise TypeError("provider returned an invalid result")
            return result, self._audit(provider, request, result, started)
        except asyncio.TimeoutError:
            latency_ms = max(0, self._monotonic_ns() - started) // 1_000_000
            result = ProviderCallResult.failed(
                ProviderFailureKind.TIMEOUT, ProviderTelemetry(latency_ms=latency_ms)
            )
            return result, self._audit(provider, request, result, started)
        except asyncio.CancelledError:
            raise
        except Exception:
            latency_ms = max(0, self._monotonic_ns() - started) // 1_000_000
            result = ProviderCallResult.failed(
                ProviderFailureKind.INTERNAL, ProviderTelemetry(latency_ms=latency_ms)
            )
            return result, self._audit(provider, request, result, started)

    def _audit(
        self,
        provider: ProviderAdapter,
        request: ProviderRequest,
        result: ProviderCallResult,
        started: int,
    ) -> ProviderAuditRecord:
        return ProviderAuditRecord(
            provider=provider.provider_name,
            request=request,
            result=result,
            started_monotonic_ns=started,
            completed_monotonic_ns=max(started, self._monotonic_ns()),
        )

    @staticmethod
    async def _frame(
        session: AsyncDuelSession,
        assignment: SeatAssignment,
        observation: Mapping[str, Any],
    ) -> bytes | None:
        metadata = observation.get("frame")
        if not isinstance(metadata, Mapping):
            return None
        return await session.render(
            assignment.participant_id,
            str(metadata["sensor_id"]),
            str(metadata["transport_ref"]),
            int(observation["observation_seq"]),
        )


def derive_paired_duel_rerun_plan(plan: PairedDuelPlan, *, rerun_index: int) -> PairedDuelPlan:
    """Create a fresh whole-pair identity while preserving every non-schedule lock."""

    if not isinstance(plan, PairedDuelPlan):
        raise TypeError("plan must be PairedDuelPlan")
    if isinstance(rerun_index, bool) or not isinstance(rerun_index, int) or rerun_index < 1:
        raise ValueError("rerun_index must be a positive integer")
    identity = canonical_json_bytes(
        {
            "previous_plan_sha256": plan.plan_sha256,
            "previous_schedule_nonce": plan.schedule_nonce,
            "rerun_index": rerun_index,
            "series_id": plan.series_id,
        }
    )
    derived = hashlib.sha256(identity).hexdigest()
    schedule_nonce = f"rerun_{derived[:40]}"
    episode_identity = derived[40:]
    fairness_lock = replace(plan.fairness_lock, schedule_nonce=schedule_nonce)
    return replace(
        plan,
        episode_ids=(
            f"ep_rerun_{episode_identity}_a",
            f"ep_rerun_{episode_identity}_b",
        ),
        schedule_nonce=schedule_nonce,
        fairness_lock=fairness_lock,
    )


async def run_paired_duel_with_reruns(
    *,
    initial_plan: PairedDuelPlan,
    scheduler_factory: Callable[[PairedDuelPlan], PairedDuelScheduler],
    cancel_event: asyncio.Event,
    max_pair_attempts: int = MAX_PAIR_ATTEMPTS,
) -> DuelSeriesExecution:
    """Run a bounded sequence of fresh whole pairs and return only complete evidence."""

    if not isinstance(initial_plan, PairedDuelPlan):
        raise TypeError("initial_plan must be PairedDuelPlan")
    if not callable(scheduler_factory):
        raise TypeError("scheduler_factory must be callable")
    if not isinstance(cancel_event, asyncio.Event):
        raise TypeError("cancel_event must be asyncio.Event")
    if (
        isinstance(max_pair_attempts, bool)
        or not isinstance(max_pair_attempts, int)
        or not 1 <= max_pair_attempts <= 10
    ):
        raise ValueError("max_pair_attempts must be an integer from 1 to 10")

    plan = initial_plan
    for attempt_index in range(max_pair_attempts):
        if cancel_event.is_set():
            raise asyncio.CancelledError
        scheduler = scheduler_factory(plan)
        if not isinstance(scheduler, PairedDuelScheduler):
            raise TypeError("scheduler_factory returned an invalid scheduler")
        result = await scheduler.run()
        if result.status == "complete":
            return DuelSeriesExecution(result, scheduler.evidence)
        if scheduler.evidence is not None:
            raise RuntimeError("invalid pair retained aggregate evidence")
        if attempt_index + 1 == max_pair_attempts:
            raise RepeatedInvalidPairError("duel pair rerun limit exhausted")
        plan = derive_paired_duel_rerun_plan(plan, rerun_index=attempt_index + 1)
    raise AssertionError("bounded pair rerun loop did not terminate")


def _validated_action(
    result: ProviderCallResult,
    *,
    episode_id: str,
    observation_seq: int,
    max_output_bytes: int,
    package: EmbodimentProtocolPackage,
):
    raw_output = result.raw_output
    if raw_output is None or len(raw_output) > max_output_bytes:
        return None
    try:
        action = parse_controller_action(raw_output, package=package)
    except (ProtocolValidationError, KeyError, TypeError, ValueError):
        return None
    if (
        action.episode_id != episode_id
        or action.observation_seq != observation_seq
        or action.control.duration_ticks != 10
    ):
        return None
    return action


def _joint_boundary(
    observations: Mapping[str, Mapping[str, Any]], episode_id: str
) -> tuple[int, int]:
    if set(observations) != {"participant_0", "participant_1"}:
        raise ValueError("duel observations must contain exactly both participants")
    values = []
    for participant_id in ("participant_0", "participant_1"):
        observation = observations[participant_id]
        if not isinstance(observation, Mapping) or observation.get("episode_id") != episode_id:
            raise ValueError("duel observation belongs to the wrong episode")
        seq = observation.get("observation_seq")
        tick = observation.get("tick")
        if isinstance(seq, bool) or not isinstance(seq, int):
            raise TypeError("observation_seq must be an integer")
        if isinstance(tick, bool) or not isinstance(tick, int):
            raise TypeError("tick must be an integer")
        values.append((seq, tick))
    if values[0] != values[1]:
        raise ValueError("participant observations must share one decision boundary")
    return values[0]


def _observations_ended(observations: Mapping[str, Mapping[str, Any]]) -> bool:
    if set(observations) != {"participant_0", "participant_1"}:
        raise ValueError("duel observations must contain exactly both participants")
    ended = []
    for participant_id in ("participant_0", "participant_1"):
        terminal = observations[participant_id].get("terminal")
        if not isinstance(terminal, Mapping) or not isinstance(terminal.get("ended"), bool):
            raise TypeError("participant terminal state is invalid")
        ended.append(terminal["ended"])
    if ended[0] != ended[1]:
        raise ValueError("participant terminal states disagree")
    return ended[0]


def _winner_entrant(plan: DuelLegPlan, verification: DuelLegVerification) -> str | None:
    if verification.outcome != "win":
        return None
    for assignment in plan.assignments:
        if assignment.participant_id == verification.winner_participant_id:
            return assignment.entrant_id
    raise ValueError("verified winner is not assigned to the leg")


def _take_verified_material(
    session: AsyncDuelSession,
    verification: DuelLegVerification,
    provider_audits: list[ProviderAuditRecord],
) -> VerifiedLegMaterial | None:
    take = getattr(session, "take_verified_replay_bytes", None)
    if not callable(take):
        return None
    replay_bytes = take()
    if replay_bytes is None:
        return None
    if not isinstance(replay_bytes, bytes):
        raise TypeError("verified replay evidence must be immutable bytes")
    if hashlib.sha256(replay_bytes).hexdigest() != verification.replay_sha256:
        raise ValueError("retained replay differs from independent verification")
    return VerifiedLegMaterial(replay_bytes, tuple(provider_audits))


async def _close_providers(providers: Mapping[str, ProviderAdapter]) -> None:
    pending = []
    seen = set()
    for provider in providers.values():
        if id(provider) in seen:
            continue
        seen.add(id(provider))
        close = getattr(provider, "aclose", None)
        if callable(close):
            pending.append(close())
    if pending:
        await asyncio.gather(*pending)


__all__ = [
    "AsyncDuelSession",
    "LiveProviderCallBudget",
    "LiveProviderCallBudgetExceeded",
    "MAX_PAIR_ATTEMPTS",
    "PairedDuelScheduler",
    "ProviderFactory",
    "ParticipantFrameSink",
    "RepeatedInvalidPairError",
    "SessionFactory",
    "derive_paired_duel_rerun_plan",
    "run_paired_duel_with_reruns",
]
