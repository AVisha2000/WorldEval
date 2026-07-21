"""Concurrent fixed-window execution for three cyclic Demo-agent legs."""

from __future__ import annotations

import asyncio
import hashlib
import time
from typing import Any, Awaitable, Callable, Mapping, Protocol

from ..contracts import ControllerAction, DecisionWindow, MultiParticipantStepResult
from ..protocol import EmbodimentProtocolPackage, canonical_json_bytes
from ..providers.contracts import ProviderRequest
from ..replay import verify_replay_bytes
from .common import TRIO_PARTICIPANT_IDS
from .demo_provider import TrioDemoSeatController
from .evaluation import evaluate_trio_series
from .evidence import (
    TrioSeriesExecution,
    TrioVerifiedLegMaterial,
    build_trio_series_evidence,
)
from .scheduling import TRIO_DEMO_ENTRANTS, TrioEntrant, TrioLegPlan, TrioSeriesPlan
from .series import TrioLegExecutionResult, TrioSeriesResult

TRIO_SYSTEM_PROMPT = (
    "Choose one strict controller action from only the participant-visible WorldArena observation."
)
MAX_TRIO_WINDOWS_PER_LEG = 120


class AsyncTrioSession(Protocol):
    async def reset(self) -> Mapping[str, Mapping[str, Any]]: ...

    async def step(self, window: DecisionWindow) -> MultiParticipantStepResult: ...

    async def render(
        self,
        participant_id: str,
        sensor_id: str,
        transport_ref: str,
        observation_seq: int,
    ) -> bytes: ...

    @property
    def replay_bytes(self) -> bytes: ...

    async def close(self) -> None: ...


TrioSessionFactory = Callable[[TrioLegPlan], Awaitable[AsyncTrioSession]]
TrioControllerFactory = Callable[
    [TrioEntrant, TrioLegPlan, str], Awaitable[TrioDemoSeatController]
]
TrioFrameSink = Callable[[int, str, int, bytes], Awaitable[None]]


class TrioSeriesScheduler:
    """Run all three cyclic rotations; every active seat is queried concurrently."""

    def __init__(
        self,
        *,
        plan: TrioSeriesPlan,
        session_factory: TrioSessionFactory,
        controller_factory: TrioControllerFactory,
        protocol_package: EmbodimentProtocolPackage,
        provider_timeout_s: float = 45.0,
        monotonic_ns: Callable[[], int] = time.monotonic_ns,
        participant_frame_sink: TrioFrameSink | None = None,
        max_provider_calls: int = 1080,
        cancel_event: asyncio.Event | None = None,
    ) -> None:
        if not isinstance(plan, TrioSeriesPlan):
            raise TypeError("plan must be TrioSeriesPlan")
        if protocol_package.PROTOCOL_VERSION != "llm-controller/0.3.0":
            raise ValueError("trio scheduler requires protocol v3")
        if not callable(session_factory) or not callable(controller_factory):
            raise TypeError("trio scheduler factories must be callable")
        if isinstance(provider_timeout_s, bool) or provider_timeout_s <= 0:
            raise ValueError("provider_timeout_s must be positive")
        if (
            isinstance(max_provider_calls, bool)
            or not isinstance(max_provider_calls, int)
            or not 1 <= max_provider_calls <= 1080
        ):
            raise ValueError("max_provider_calls must be from 1 to 1080")
        self.plan = plan
        self._session_factory = session_factory
        self._controller_factory = controller_factory
        self._package = protocol_package
        self._timeout_s = float(provider_timeout_s)
        self._monotonic_ns = monotonic_ns
        self._frame_sink = participant_frame_sink
        self._max_provider_calls = max_provider_calls
        self._used_provider_calls = 0
        self._cancel_event = cancel_event or asyncio.Event()

    async def run(self) -> TrioSeriesExecution:
        results: list[TrioLegExecutionResult] = []
        materials: list[TrioVerifiedLegMaterial] = []
        for leg in self.plan.legs:
            if self._cancel_event.is_set():
                raise asyncio.CancelledError
            result, material = await self._run_leg(leg)
            results.append(result)
            materials.append(material)
        series = TrioSeriesResult(self.plan, tuple(results))  # type: ignore[arg-type]
        typed_materials = tuple(materials)  # type: ignore[assignment]
        evidence = build_trio_series_evidence(
            plan=self.plan,
            result=series,
            materials=typed_materials,  # type: ignore[arg-type]
            protocol_package=self._package,
        )
        evaluation = evaluate_trio_series(
            self.plan, [value.authority_aggregates for value in materials]
        )
        return TrioSeriesExecution(series, evidence, evaluation)

    async def _run_leg(
        self, leg: TrioLegPlan
    ) -> tuple[TrioLegExecutionResult, TrioVerifiedLegMaterial]:
        session = await self._session_factory(leg)
        controllers: dict[str, TrioDemoSeatController] = {}
        fallback_windows = 0
        windows = 0
        try:
            controllers = await self._controllers(leg)
            observations = await session.reset()
            while not _observations_ended(observations):
                if self._cancel_event.is_set():
                    raise asyncio.CancelledError
                if windows >= MAX_TRIO_WINDOWS_PER_LEG:
                    raise RuntimeError("trio authority exceeded its fixed 120-window horizon")
                observation_seq, start_tick = _joint_boundary(observations, leg.episode_id)
                window = await self._window(
                    leg, session, controllers, observations, observation_seq, start_tick
                )
                fallback_windows += sum(
                    decision.disposition == "no_input"
                    for decision in window.decisions.values()
                )
                try:
                    step = await session.step(window)
                except Exception as error:
                    cause = error.__cause__
                    detail = str(cause) if cause is not None else str(error)
                    raise RuntimeError(
                        f"trio leg {leg.leg_index} window {windows} step failed: {detail}"
                    ) from error
                windows += 1
                observations = step.observations

            replay_bytes = session.replay_bytes
            replay = verify_replay_bytes(replay_bytes, package=self._package)
            if replay["config"]["episode_id"] != leg.episode_id:
                raise ValueError("verified trio replay belongs to another leg")
            terminal_result = replay.get("final_result")
            if not isinstance(terminal_result, Mapping):
                raise ValueError("verified trio replay has no terminal result")
            typed_terminal = _typed_terminal(step)
            if typed_terminal.as_dict() != terminal_result:
                raise ValueError("managed trio terminal result differs from sealed replay")
            audits = tuple(
                audit
                for participant_id in TRIO_PARTICIPANT_IDS
                for audit in controllers[participant_id].drain_audits(leg.episode_id)
            )
            provider_calls = sum(value.provider_calls for value in controllers.values())
            suppressed = sum(
                value.suppressed_eliminated_calls for value in controllers.values()
            )
            aggregates = _authority_aggregates(
                replay, controllers=controllers, terminal_result=typed_terminal
            )
            material = TrioVerifiedLegMaterial(replay_bytes, audits, aggregates)
            result = TrioLegExecutionResult(
                plan=leg,
                terminal_result=typed_terminal,
                replay_sha256=hashlib.sha256(replay_bytes).hexdigest(),
                final_state_hash=replay["final_state_hash"],
                decision_windows=windows,
                fallback_windows=fallback_windows,
                provider_calls=provider_calls,
                suppressed_eliminated_calls=suppressed,
            )
            return result, material
        finally:
            await asyncio.gather(
                *(value.aclose() for value in controllers.values()),
                return_exceptions=True,
            )
            await session.close()

    async def _controllers(
        self, leg: TrioLegPlan
    ) -> dict[str, TrioDemoSeatController]:
        entrants = {value.entrant_id: value for value in TRIO_DEMO_ENTRANTS}
        ordered = sorted(leg.assignments, key=lambda value: value.dispatch_precedence)
        tasks = [
            asyncio.create_task(
                self._controller_factory(
                    entrants[assignment.entrant_id], leg, assignment.participant_id
                )
            )
            for assignment in ordered
        ]
        try:
            values = await asyncio.gather(*tasks)
        except BaseException:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            raise
        controllers = {
            assignment.participant_id: value
            for assignment, value in zip(ordered, values)
        }
        if set(controllers) != set(TRIO_PARTICIPANT_IDS) or any(
            not isinstance(value, TrioDemoSeatController) for value in controllers.values()
        ):
            await asyncio.gather(
                *(value.aclose() for value in controllers.values()), return_exceptions=True
            )
            raise TypeError("trio controller factory returned an invalid set")
        return controllers

    async def _window(
        self,
        leg: TrioLegPlan,
        session: AsyncTrioSession,
        controllers: Mapping[str, TrioDemoSeatController],
        observations: Mapping[str, Mapping[str, Any]],
        observation_seq: int,
        start_tick: int,
    ) -> DecisionWindow:
        frames = []
        for participant_id in TRIO_PARTICIPANT_IDS:
            frames.append(await _frame(session, participant_id, observations[participant_id]))
        if self._frame_sink is not None:
            await asyncio.gather(
                *(
                    self._frame_sink(leg.leg_index, participant_id, observation_seq, frame)
                    for participant_id, frame in zip(TRIO_PARTICIPANT_IDS, frames)
                    if frame is not None
                )
            )
        deadline = self._monotonic_ns() + int(self._timeout_s * 1_000_000_000)
        requests = {
            participant_id: ProviderRequest(
                episode_id=leg.episode_id,
                participant_id=participant_id,
                observation_seq=observation_seq,
                deadline_monotonic_ns=deadline,
                model=controllers[participant_id].policy_lock.model,
                system_prompt=TRIO_SYSTEM_PROMPT,
                observation_json=canonical_json_bytes(observations[participant_id]),
                action_schema_json=canonical_json_bytes(
                    self._package.schema("controller-action")
                ),
                frame_png=frame,
                max_output_bytes=4096,
            )
            for participant_id, frame in zip(TRIO_PARTICIPANT_IDS, frames)
        }
        tasks: list[asyncio.Task[Any] | None] = []
        budget_exhausted: set[str] = set()
        for participant_id in TRIO_PARTICIPANT_IDS:
            eliminated = _eliminated(observations[participant_id])
            if not eliminated and self._used_provider_calls >= self._max_provider_calls:
                tasks.append(None)
                budget_exhausted.add(participant_id)
                continue
            if not eliminated:
                self._used_provider_calls += 1
            tasks.append(
                asyncio.create_task(
                    controllers[participant_id].decide(
                        requests[participant_id], eliminated=eliminated
                    )
                )
            )
        remaining = max(0.0, (deadline - self._monotonic_ns()) / 1_000_000_000)
        active_tasks = [task for task in tasks if task is not None]
        _done, pending = await asyncio.wait(active_tasks, timeout=remaining)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        decisions = []
        for task in tasks:
            if task is None or task in pending:
                decisions.append(None)
                continue
            try:
                decisions.append(task.result())
            except Exception:
                # Provider/controller faults are isolated to their participant. The other
                # concurrently completed decisions remain authoritative for this window.
                decisions.append(None)

        actions: dict[str, ControllerAction] = {}
        reasons: dict[str, str] = {}
        for participant_id, resolved in zip(TRIO_PARTICIPANT_IDS, decisions):
            if resolved is None:
                reasons[participant_id] = (
                    "budget_exhausted"
                    if participant_id in budget_exhausted
                    else "timeout"
                )
            elif resolved.disposition == "eliminated":
                reasons[participant_id] = "eliminated"
            elif resolved.disposition == "no_input":
                reasons[participant_id] = _fallback_reason(resolved.reason)
            else:
                value = resolved.action
                actions[participant_id] = ControllerAction(
                    episode_id=value.episode_id,
                    observation_seq=value.observation_seq,
                    action_id=value.action_id,
                    control=value.control,
                    intent_label=value.intent_label,
                    memory_update=value.memory_update,
                    protocol_version="llm-controller/0.3.0",
                )
        return DecisionWindow.finalize(
            episode_id=leg.episode_id,
            observation_seq=observation_seq,
            mode="trio-game-v0",
            start_tick=start_tick,
            participant_ids=TRIO_PARTICIPANT_IDS,
            actions=actions,
            failure_reasons=reasons,  # type: ignore[arg-type]
            duration_ticks=10,
        )


def _typed_terminal(step: MultiParticipantStepResult):
    if step.trio_result is None:
        raise ValueError("terminal trio step lacks a typed result")
    return step.trio_result


def _joint_boundary(
    observations: Mapping[str, Mapping[str, Any]], episode_id: str
) -> tuple[int, int]:
    if set(observations) != set(TRIO_PARTICIPANT_IDS):
        raise ValueError("trio observations must contain exactly three participants")
    boundaries = []
    for participant_id in TRIO_PARTICIPANT_IDS:
        observation = observations[participant_id]
        if not isinstance(observation, Mapping) or observation.get("episode_id") != episode_id:
            raise ValueError("trio observation belongs to another episode")
        seq, tick = observation.get("observation_seq"), observation.get("tick")
        if isinstance(seq, bool) or not isinstance(seq, int):
            raise TypeError("trio observation sequence is invalid")
        if isinstance(tick, bool) or not isinstance(tick, int):
            raise TypeError("trio observation tick is invalid")
        boundaries.append((seq, tick))
    if len(set(boundaries)) != 1:
        raise ValueError("trio participants do not share one decision boundary")
    return boundaries[0]


def _observations_ended(observations: Mapping[str, Mapping[str, Any]]) -> bool:
    ended = []
    for participant_id in TRIO_PARTICIPANT_IDS:
        terminal = observations[participant_id].get("terminal")
        if not isinstance(terminal, Mapping) or not isinstance(terminal.get("ended"), bool):
            raise TypeError("trio participant terminal state is invalid")
        ended.append(terminal["ended"])
    if len(set(ended)) != 1:
        raise ValueError("trio participant terminal states disagree")
    return ended[0]


def _eliminated(observation: Mapping[str, Any]) -> bool:
    self_value = observation.get("self")
    status = self_value.get("status") if isinstance(self_value, Mapping) else None
    return isinstance(status, list) and "eliminated" in status


async def _frame(
    session: AsyncTrioSession,
    participant_id: str,
    observation: Mapping[str, Any],
) -> bytes | None:
    metadata = observation.get("frame")
    if not isinstance(metadata, Mapping):
        return None
    return await session.render(
        participant_id,
        str(metadata["sensor_id"]),
        str(metadata["transport_ref"]),
        int(observation["observation_seq"]),
    )


def _fallback_reason(reason: str) -> str:
    return {
        "timeout": "timeout",
        "stale_observation": "stale_observation",
        "budget_exhausted": "budget_exhausted",
    }.get(reason, "invalid")


def _authority_aggregates(
    replay: Mapping[str, Any],
    *,
    controllers: Mapping[str, TrioDemoSeatController],
    terminal_result: Any,
) -> Mapping[str, Any]:
    damage_dealt = {participant_id: 0 for participant_id in TRIO_PARTICIPANT_IDS}
    damage_taken = {participant_id: 0 for participant_id in TRIO_PARTICIPANT_IDS}
    objective = {participant_id: 0 for participant_id in TRIO_PARTICIPANT_IDS}
    fallback = {participant_id: 0 for participant_id in TRIO_PARTICIPANT_IDS}
    for step in replay["steps"]:
        for participant_id, decision in step["decision_window"]["decisions"].items():
            if decision["disposition"] == "no_input":
                fallback[participant_id] += 1
        for event in step["result"]["public_events"]:
            data = event.get("data", {})
            if event.get("kind") == "primary_hit" and data.get("attacker") in damage_dealt:
                damage_dealt[data["attacker"]] += int(data.get("damage", 0))
            elif event.get("kind") == "operator_damaged" and data.get(
                "participant_id"
            ) in damage_taken:
                damage_taken[data["participant_id"]] += int(data.get("damage", 0))
            elif event.get("kind") == "relay_secured" and data.get("controller") in objective:
                objective[data["controller"]] += 60
    participants = {}
    for participant_id in TRIO_PARTICIPANT_IDS:
        outcome = terminal_result.participant_outcomes[participant_id]
        controller = controllers[participant_id]
        # Placement points keep time-limit and combat objectives comparable without exposing the
        # authority's protected map/checkpoint state. Relay completion adds its public 60-tick mark.
        participants[participant_id] = {
            "placement": outcome.place,
            "objective_points": objective[participant_id] + (4 - outcome.place) * 100,
            "damage_dealt": damage_dealt[participant_id],
            "damage_taken": damage_taken[participant_id],
            "decision_windows": len(replay["steps"]),
            "fallback_windows": fallback[participant_id],
            "provider_calls": controller.provider_calls,
            "suppressed_eliminated_calls": controller.suppressed_eliminated_calls,
            "eliminated_tick": outcome.eliminated_tick,
        }
    return {
        "leg_index": replay["config"]["seat_rotation"],
        "completion_tick": replay["steps"][-1]["result"]["observations"][
            "participant_0"
        ]["tick"],
        "terminal_reason": terminal_result.reason,
        "participants": participants,
    }


__all__ = [
    "AsyncTrioSession",
    "MAX_TRIO_WINDOWS_PER_LEG",
    "TRIO_SYSTEM_PROMPT",
    "TrioControllerFactory",
    "TrioFrameSink",
    "TrioSeriesScheduler",
    "TrioSessionFactory",
]
