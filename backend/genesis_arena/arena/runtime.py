from __future__ import annotations

# ruff: noqa: UP045 -- Pydantic-compatible Python 3.9 annotations are intentional.
import asyncio
import inspect
import secrets
from dataclasses import dataclass, field
from typing import Awaitable, Callable, Dict, List, Mapping, Optional, Protocol, Union

from .artifacts import CommittedPlanArtifact, RoundArtifact
from .canonical import plan_commit_hash
from .models import (
    CognitionView,
    CreateSpecialist,
    DecisionDiagnostic,
    FactionId,
    FactionObservation,
    FactionPlan,
    PhysicalAction,
    PhysicalOrder,
    PlanCommit,
    RevealedPlan,
    RoundCommitHashes,
    RoundCommitsLocked,
    RoundPlanReveal,
    RoundReceipt,
    RoundRequest,
    SpecialistOperation,
    SpecialistRecommendation,
    SpecialistRole,
    SpecialistStateChange,
    UpdateSpecialist,
    UsageRecord,
)


class ArenaRuntimeError(RuntimeError):
    pass


@dataclass(frozen=True)
class CommanderOutput:
    plan: FactionPlan
    usage: UsageRecord = field(default_factory=UsageRecord)


@dataclass(frozen=True)
class SpecialistOutput:
    recommendation: SpecialistRecommendation
    usage: UsageRecord = field(default_factory=UsageRecord)


class Commander(Protocol):
    async def plan(
        self,
        observation: FactionObservation,
        recommendations: List[SpecialistRecommendation],
    ) -> Union[FactionPlan, CommanderOutput]: ...


class SpecialistAdvisor(Protocol):
    async def advise(
        self,
        observation: FactionObservation,
        specialist_id: str,
        role: SpecialistRole,
        brief: str,
    ) -> Union[SpecialistRecommendation, SpecialistOutput]: ...


@dataclass
class CognitionBudget:
    track: str = "agentic"
    total_units: int = 360
    total_rounds: int = 120
    commander_cost: int = 2
    specialist_cost: int = 1
    remaining_units: int = field(init=False)
    commander_calls: int = 0
    specialist_calls: int = 0

    def __post_init__(self) -> None:
        if self.track not in {"standard", "agentic", "open"}:
            raise ValueError("unknown cognition track")
        if min(self.total_units, self.total_rounds, self.commander_cost) <= 0:
            raise ValueError("cognition budget values must be positive")
        if self.specialist_cost <= 0:
            raise ValueError("specialist cost must be positive")
        required = self.total_rounds * self.commander_cost
        if self.track != "open" and self.total_units < required:
            raise ValueError("budget must reserve every commander call")
        self.remaining_units = self.total_units

    @property
    def remaining_commander_reserve(self) -> int:
        rounds_left = max(0, self.total_rounds - self.commander_calls)
        return rounds_left * self.commander_cost

    def can_call_specialist(self) -> bool:
        if self.track == "open":
            return True
        if self.track != "agentic":
            return False
        return self.remaining_units - self.specialist_cost >= self.remaining_commander_reserve

    def spend_specialist(self) -> None:
        if not self.can_call_specialist():
            raise ArenaRuntimeError("specialist call would consume commander reserve")
        if self.track != "open":
            self.remaining_units -= self.specialist_cost
        self.specialist_calls += 1

    def spend_commander(self) -> None:
        if self.track == "open":
            self.commander_calls += 1
            return
        if self.commander_calls < self.total_rounds:
            if self.remaining_units < self.commander_cost:
                raise ArenaRuntimeError("commander cognition budget exhausted")
            self.remaining_units -= self.commander_cost
        else:
            raise ArenaRuntimeError("commander round limit exhausted")
        self.commander_calls += 1

    def view(
        self, active_specialist_ids: List[str], *, round_number: Optional[int] = None
    ) -> CognitionView:
        if self.track == "open":
            remaining = 2_147_483_647
        else:
            remaining = self.remaining_units
        return CognitionView(
            track=self.track,
            remaining_units=remaining,
            commander_cost=self.commander_cost,
            specialist_cost=self.specialist_cost,
            active_specialist_ids=active_specialist_ids,
        )


@dataclass
class SpecialistSlot:
    specialist_id: str
    role: SpecialistRole
    brief: str
    priority: int
    advisor: SpecialistAdvisor
    active: bool = True


SpecialistFactory = Callable[
    [FactionId, CreateSpecialist], Union[SpecialistAdvisor, Awaitable[SpecialistAdvisor]]
]


@dataclass
class FactionRuntime:
    faction_id: FactionId
    commander: Commander
    budget: CognitionBudget = field(default_factory=CognitionBudget)
    specialists: Dict[str, SpecialistSlot] = field(default_factory=dict)
    specialist_factory: Optional[SpecialistFactory] = None
    max_specialists: int = 3

    def __post_init__(self) -> None:
        if self.max_specialists < 0 or self.max_specialists > 3:
            raise ValueError("max_specialists must be between zero and three")
        if len(self.specialists) > self.max_specialists:
            raise ValueError("configured specialists exceed max_specialists")

    def active_slots(self) -> List[SpecialistSlot]:
        return sorted(
            (slot for slot in self.specialists.values() if slot.active),
            key=lambda slot: (slot.priority, slot.specialist_id),
        )


class DemoSpecialist:
    async def advise(
        self,
        observation: FactionObservation,
        specialist_id: str,
        role: SpecialistRole,
        brief: str,
    ) -> SpecialistRecommendation:
        visible_threats = len(observation.enemy_contacts)
        return SpecialistRecommendation(
            specialist_id=specialist_id,
            role=role,
            assessment=f"{visible_threats} visible enemy contacts; brief: {brief[:120]}",
            risks=["Unknown districts may conceal hostile movement."],
            recommended_orders=["Preserve supply while contesting one reachable objective."],
            recommendation_summary="Prefer a supplied objective and retain a defensive group.",
        )


class DemoCommander:
    """Deterministic credential-free policy for protocol and replay testing."""

    async def plan(
        self,
        observation: FactionObservation,
        recommendations: List[SpecialistRecommendation],
    ) -> FactionPlan:
        orders: List[PhysicalOrder] = []
        workers = next(
            (group for group in observation.groups if group.unit_kind == "worker"),
            None,
        )
        resource_district = next(
            (district for district in observation.districts if district.resources),
            None,
        )
        if workers is not None and resource_district is not None:
            orders.append(
                PhysicalOrder(
                    order_id=f"{observation.faction_id}-r{observation.round}-gather",
                    action=PhysicalAction.GATHER,
                    actor_ids=[workers.group_id],
                    target_id=resource_district.district_id,
                    resource="wood",
                )
            )
        return FactionPlan(
            match_id=observation.match_id,
            round=observation.round,
            faction_id=observation.faction_id,
            public_intent=(
                "Gather locally, reveal uncertain approaches, and protect the stronghold."
            ),
            orders=orders,
        )


class ScriptedCommander:
    """Deterministic fake used by integration tests and offline simulations."""

    def __init__(
        self,
        result: Union[
            FactionPlan,
            CommanderOutput,
            Callable[
                [FactionObservation, List[SpecialistRecommendation]],
                Union[FactionPlan, CommanderOutput],
            ],
        ],
        *,
        delay_seconds: float = 0,
        error: Optional[Exception] = None,
    ):
        self.result = result
        self.delay_seconds = delay_seconds
        self.error = error
        self.calls = 0

    async def plan(
        self,
        observation: FactionObservation,
        recommendations: List[SpecialistRecommendation],
    ) -> Union[FactionPlan, CommanderOutput]:
        self.calls += 1
        if self.delay_seconds:
            await asyncio.sleep(self.delay_seconds)
        if self.error is not None:
            raise self.error
        if callable(self.result):
            return self.result(observation, recommendations)
        return self.result


@dataclass
class _FactionDecision:
    plan: FactionPlan
    status: str
    error: str
    specialist_calls: int
    usage: UsageRecord


def _aggregate_usage(*records: UsageRecord) -> UsageRecord:
    normalized: List[UsageRecord] = []
    for record in records:
        try:
            normalized.append(UsageRecord.model_validate(record))
        except Exception:
            normalized.append(UsageRecord())
    return UsageRecord(
        input_tokens=sum(record.input_tokens for record in normalized),
        cached_input_tokens=sum(record.cached_input_tokens for record in normalized),
        output_tokens=sum(record.output_tokens for record in normalized),
        reasoning_tokens=sum(record.reasoning_tokens for record in normalized),
        latency_ms=sum(record.latency_ms for record in normalized),
        estimated_cost_usd=sum(record.estimated_cost_usd for record in normalized),
    )


@dataclass
class _PendingRound:
    request: RoundRequest
    plans: Dict[str, FactionPlan]
    salts: Dict[str, str]
    hashes: Dict[str, str]
    diagnostics: Dict[str, DecisionDiagnostic]
    locked: bool = False
    revealed: bool = False


class ArenaOrchestrator:
    """Concurrent, latency-neutral planner for one authoritative Godot round."""

    def __init__(
        self,
        runtimes: Mapping[str, FactionRuntime],
        *,
        decision_timeout_seconds: float = 45.0,
        specialist_timeout_seconds: float = 12.0,
        specialist_factory_timeout_seconds: float = 12.0,
        salt_factory: Callable[[], str] = lambda: secrets.token_hex(16),
    ):
        if set(runtimes) != {"sol", "terra", "luna"}:
            raise ValueError("ArenaOrchestrator requires sol, terra, and luna runtimes")
        if (
            min(
                decision_timeout_seconds,
                specialist_timeout_seconds,
                specialist_factory_timeout_seconds,
            )
            <= 0
        ):
            raise ValueError("timeouts must be positive")
        self.runtimes = dict(runtimes)
        self.decision_timeout_seconds = decision_timeout_seconds
        self.specialist_timeout_seconds = specialist_timeout_seconds
        self.specialist_factory_timeout_seconds = specialist_factory_timeout_seconds
        self.salt_factory = salt_factory
        self._pending: Dict[tuple, _PendingRound] = {}
        self._phases: Dict[tuple, str] = {}
        self._next_round: Dict[str, int] = {}
        self._next_snapshot_hash: Dict[str, str] = {}

    async def commit_round(self, request: RoundRequest) -> RoundCommitHashes:
        key = (request.match_id, request.round)
        expected_round = self._next_round.get(request.match_id, 1)
        if request.round != expected_round:
            raise ArenaRuntimeError(
                f"round {request.round} is out of order; expected round {expected_round}"
            )
        expected_snapshot = self._next_snapshot_hash.get(request.match_id)
        if expected_snapshot is not None and request.snapshot_hash != expected_snapshot:
            raise ArenaRuntimeError("round request does not continue the authoritative state hash")
        if key in self._phases:
            raise ArenaRuntimeError("round has already been committed")
        # Reserve synchronously before the first await so a concurrent duplicate cannot start
        # model calls or spend cognition for the same authoritative round.
        self._phases[key] = "planning"
        observations = {item.faction_id: item for item in request.observations}
        try:
            decisions = await asyncio.gather(
                *(
                    self._decide(self.runtimes[faction], observations[faction])
                    for faction in sorted(observations)
                )
            )
        except BaseException:
            self._phases.pop(key, None)
            raise
        try:
            plans: Dict[str, FactionPlan] = {}
            salts: Dict[str, str] = {}
            hashes: Dict[str, str] = {}
            diagnostics: Dict[str, DecisionDiagnostic] = {}
            commits: List[PlanCommit] = []
            for faction, decision in zip(sorted(observations), decisions):
                salt = self.salt_factory()
                if len(salt) != 32 or any(
                    character not in "0123456789abcdef" for character in salt
                ):
                    raise ArenaRuntimeError("salt_factory must return 16-byte lowercase hex")
                commit_hash = plan_commit_hash(decision.plan, salt)
                plans[faction] = decision.plan
                salts[faction] = salt
                hashes[faction] = commit_hash
                diagnostic = DecisionDiagnostic(
                    faction_id=faction,
                    status=decision.status,
                    error=decision.error,
                    specialist_calls=decision.specialist_calls,
                    cognition_remaining=self.runtimes[faction]
                    .budget.view([], round_number=request.round)
                    .remaining_units,
                    usage=decision.usage,
                )
                diagnostics[faction] = diagnostic
                commits.append(
                    PlanCommit(
                        faction_id=faction,
                        commit_hash=commit_hash,
                        status=decision.status,
                        specialist_calls=decision.specialist_calls,
                    )
                )
            self._pending[key] = _PendingRound(
                request=request,
                plans=plans,
                salts=salts,
                hashes=hashes,
                diagnostics=diagnostics,
            )
            self._phases[key] = "committed"
            return RoundCommitHashes(
                protocol=request.protocol,
                match_id=request.match_id,
                round=request.round,
                snapshot_hash=request.snapshot_hash,
                commits=commits,
            )
        except BaseException:
            self._pending.pop(key, None)
            self._phases.pop(key, None)
            raise

    async def _decide(
        self, runtime: FactionRuntime, observation: FactionObservation
    ) -> _FactionDecision:
        recommendations, specialist_attempts, specialist_usage = await self._run_specialists(
            runtime, observation
        )
        try:
            runtime.budget.spend_commander()
        except ArenaRuntimeError:
            fallback_observation = self._with_authoritative_cognition(runtime, observation)
            fallback = await DemoCommander().plan(fallback_observation, recommendations)
            return _FactionDecision(
                plan=fallback,
                status="fallback",
                error="cognition_exhausted",
                specialist_calls=specialist_attempts,
                usage=specialist_usage,
            )
        commander_observation = self._with_authoritative_cognition(runtime, observation)
        try:
            raw = await asyncio.wait_for(
                runtime.commander.plan(commander_observation, recommendations),
                timeout=self.decision_timeout_seconds,
            )
            output = raw if isinstance(raw, CommanderOutput) else CommanderOutput(plan=raw)
            plan = FactionPlan.model_validate(output.plan.model_dump(mode="json"))
            if (
                plan.match_id != observation.match_id
                or plan.round != observation.round
                or plan.faction_id != observation.faction_id
            ):
                raise ValueError("commander plan envelope does not match its observation")
            return _FactionDecision(
                plan=plan,
                status="planned",
                error="",
                specialist_calls=specialist_attempts,
                usage=_aggregate_usage(specialist_usage, output.usage),
            )
        except Exception as exc:
            fallback = await DemoCommander().plan(commander_observation, recommendations)
            failed_usage = getattr(exc, "usage", UsageRecord())
            return _FactionDecision(
                plan=fallback,
                status="fallback",
                error=self._safe_error(exc),
                specialist_calls=specialist_attempts,
                usage=_aggregate_usage(specialist_usage, failed_usage),
            )

    async def _run_specialists(
        self, runtime: FactionRuntime, observation: FactionObservation
    ) -> tuple[List[SpecialistRecommendation], int, UsageRecord]:
        selected: List[SpecialistSlot] = []
        for slot in runtime.active_slots():
            if len(selected) >= 2 or not runtime.budget.can_call_specialist():
                break
            runtime.budget.spend_specialist()
            selected.append(slot)
        if not selected:
            return [], 0, UsageRecord()

        specialist_observation = self._with_authoritative_cognition(runtime, observation)

        async def call(
            slot: SpecialistSlot,
        ) -> tuple[Optional[SpecialistRecommendation], UsageRecord]:
            try:
                raw = await asyncio.wait_for(
                    slot.advisor.advise(
                        specialist_observation,
                        slot.specialist_id,
                        slot.role,
                        slot.brief,
                    ),
                    timeout=self.specialist_timeout_seconds,
                )
                output = raw if isinstance(raw, SpecialistOutput) else SpecialistOutput(raw)
                recommendation = SpecialistRecommendation.model_validate(
                    output.recommendation.model_dump(mode="json")
                )
                if (
                    recommendation.specialist_id != slot.specialist_id
                    or recommendation.role != slot.role
                ):
                    return None, output.usage
                return recommendation, output.usage
            except Exception as exc:
                return None, getattr(exc, "usage", UsageRecord())

        results = await asyncio.gather(*(call(slot) for slot in selected))
        return (
            [recommendation for recommendation, _ in results if recommendation is not None],
            len(selected),
            _aggregate_usage(*(usage for _, usage in results)),
        )

    @staticmethod
    def _with_authoritative_cognition(
        runtime: FactionRuntime, observation: FactionObservation
    ) -> FactionObservation:
        return observation.model_copy(
            update={
                "cognition": runtime.budget.view(
                    [slot.specialist_id for slot in runtime.active_slots()],
                    round_number=observation.round,
                )
            },
            deep=True,
        )

    def lock_commits(self, acknowledgement: RoundCommitsLocked) -> None:
        key = (acknowledgement.match_id, acknowledgement.round)
        pending = self._pending.get(key)
        if pending is None:
            raise ArenaRuntimeError("no pending commits for this round")
        if self._phases.get(key) != "committed":
            raise ArenaRuntimeError("round commits are not awaiting a lock")
        if dict(acknowledgement.commit_hashes) != pending.hashes:
            raise ArenaRuntimeError("Godot acknowledgement does not match sealed commits")
        pending.locked = True
        self._phases[key] = "locked"

    async def reveal_round(self, match_id: str, round_number: int) -> RoundPlanReveal:
        key = (match_id, round_number)
        pending = self._pending.get(key)
        if pending is None:
            raise ArenaRuntimeError("no pending commits for this round")
        if not pending.locked or self._phases.get(key) != "locked":
            raise ArenaRuntimeError("plans cannot be revealed before Godot locks commits")
        if pending.revealed:
            raise ArenaRuntimeError("round has already been revealed")
        revealed = [
            RevealedPlan(
                faction_id=faction,
                plan=pending.plans[faction],
                salt=pending.salts[faction],
                commit_hash=pending.hashes[faction],
            )
            for faction in sorted(pending.plans)
        ]
        pending.revealed = True
        self._phases[key] = "revealed"
        return RoundPlanReveal(
            protocol=pending.request.protocol,
            match_id=match_id,
            round=round_number,
            plans=revealed,
        )

    async def finalize_round(self, receipt: RoundReceipt) -> None:
        """Apply Python-owned effects only after Godot acknowledges authoritative resolution.

        WebSocket integration must call this once for every revealed round before requesting
        the next round. Specialist changes therefore cannot take effect from an unvalidated or
        disconnected reveal.
        """

        key = (receipt.match_id, receipt.round)
        pending = self._pending.get(key)
        if pending is None:
            raise ArenaRuntimeError("no pending round for receipt")
        if self._phases.get(key) != "revealed":
            raise ArenaRuntimeError("round receipt is not awaiting finalization")
        if receipt.previous_state_hash != pending.request.snapshot_hash:
            raise ArenaRuntimeError("round receipt does not continue the committed snapshot")
        self._phases[key] = "finalizing"
        try:
            for faction in sorted(pending.plans):
                await self._apply_specialist_operations(
                    self.runtimes[faction], pending.plans[faction].specialist_ops
                )
        except BaseException:
            self._phases[key] = "revealed"
            raise
        self._phases[key] = "finalized"
        self._next_round[receipt.match_id] = receipt.round + 1
        self._next_snapshot_hash[receipt.match_id] = receipt.state_hash

    def diagnostics(self, match_id: str, round_number: int) -> Dict[str, DecisionDiagnostic]:
        pending = self._pending.get((match_id, round_number))
        if pending is None:
            raise ArenaRuntimeError("unknown round")
        return dict(pending.diagnostics)

    def finalized_round_data(
        self, match_id: str, round_number: int
    ) -> tuple[Dict[str, FactionPlan], Dict[str, DecisionDiagnostic]]:
        """Expose sealed plan/diagnostic evidence after authoritative finalization only."""

        key = (match_id, round_number)
        pending = self._pending.get(key)
        if pending is None or self._phases.get(key) != "finalized":
            raise ArenaRuntimeError("round is not finalized authoritative evidence")
        return (
            {faction: plan.model_copy(deep=True) for faction, plan in pending.plans.items()},
            {
                faction: diagnostic.model_copy(deep=True)
                for faction, diagnostic in pending.diagnostics.items()
            },
        )

    def finalized_round_artifact(self, receipt: RoundReceipt) -> RoundArtifact:
        """Build replay evidence only after an authoritative receipt finalized the round."""

        key = (receipt.match_id, receipt.round)
        pending = self._pending.get(key)
        if pending is None or self._phases.get(key) != "finalized":
            raise ArenaRuntimeError("round is not finalized authoritative evidence")
        observations = {item.faction_id: item for item in pending.request.observations}
        return RoundArtifact(
            match_id=receipt.match_id,
            round=receipt.round,
            previous_state_hash=receipt.previous_state_hash,
            state_hash=receipt.state_hash,
            plans=[
                CommittedPlanArtifact(
                    faction_id=faction,
                    observation=observations[faction],
                    plan=pending.plans[faction],
                    salt=pending.salts[faction],
                    commit_hash=pending.hashes[faction],
                    diagnostic=pending.diagnostics[faction],
                )
                for faction in sorted(pending.plans)
            ],
            events=list(receipt.events),
        )

    async def _apply_specialist_operations(
        self, runtime: FactionRuntime, operations: List[SpecialistOperation]
    ) -> None:
        for operation in operations:
            if isinstance(operation, CreateSpecialist):
                if (
                    operation.specialist_id in runtime.specialists
                    or len(runtime.specialists) >= runtime.max_specialists
                ):
                    continue
                factory = runtime.specialist_factory
                advisor: SpecialistAdvisor
                if factory is None:
                    advisor = DemoSpecialist()
                else:
                    try:
                        created = factory(runtime.faction_id, operation)
                        advisor = (
                            await asyncio.wait_for(
                                created, timeout=self.specialist_factory_timeout_seconds
                            )
                            if inspect.isawaitable(created)
                            else created
                        )
                    except Exception:
                        continue
                runtime.specialists[operation.specialist_id] = SpecialistSlot(
                    specialist_id=operation.specialist_id,
                    role=operation.role,
                    brief=operation.brief,
                    priority=operation.priority,
                    advisor=advisor,
                )
            elif isinstance(operation, UpdateSpecialist):
                slot = runtime.specialists.get(operation.specialist_id)
                if slot is not None:
                    slot.brief = operation.brief
                    slot.priority = operation.priority
            elif isinstance(operation, SpecialistStateChange):
                slot = runtime.specialists.get(operation.specialist_id)
                if slot is None:
                    continue
                if operation.operation == "dismiss":
                    del runtime.specialists[operation.specialist_id]
                else:
                    slot.active = operation.operation == "resume"

    @staticmethod
    def _safe_error(error: BaseException) -> str:
        if isinstance(error, asyncio.TimeoutError):
            return "decision_timeout"
        return "decision_failed"
