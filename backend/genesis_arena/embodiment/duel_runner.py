"""Concurrent, participant-isolated model dispatch for scored duel windows."""

from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import dataclass
from typing import Any, Mapping, Protocol, Tuple, runtime_checkable

from .contracts import DecisionWindow, EpisodeConfig, MultiParticipantStepResult, NoInputReason
from .live_solo import parse_controller_action
from .protocol import EmbodimentProtocolPackage, canonical_json_bytes
from .providers.contracts import (
    ProviderAdapter,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)
from .scratchpad import EpisodeScratchpad


@runtime_checkable
class AsyncDuelSession(Protocol):
    """Minimal authority boundary required by a future managed Godot duel session."""

    async def reset(self) -> Mapping[str, Mapping[str, Any]]: ...

    async def step(self, window: DecisionWindow) -> MultiParticipantStepResult: ...

    async def render(
        self,
        participant_id: str,
        sensor_id: str,
        transport_ref: str,
        observation_seq: int,
    ) -> bytes: ...

    async def close(self) -> None: ...


@dataclass(frozen=True)
class DuelParticipantAudit:
    """Credential-free protected evidence for one participant provider call."""

    participant_id: str
    provider: str
    observation_seq: int
    observation_sha256: str
    action_schema_sha256: str
    deadline_monotonic_ns: int
    max_output_bytes: int
    result: ProviderCallResult | None
    raw_output_sha256: str | None
    started_monotonic_ns: int | None
    completed_monotonic_ns: int | None


@dataclass(frozen=True)
class DuelDispatchResult:
    """One canonical joint decision plus participant-sorted protected evidence."""

    window: DecisionWindow
    audits: Tuple[DuelParticipantAudit, ...]


class DuelDecisionDispatcher:
    """Issue two equal-budget calls concurrently and finalize one deterministic window."""

    def __init__(
        self,
        *,
        config: EpisodeConfig,
        providers: Mapping[str, ProviderAdapter],
        models: Mapping[str, str],
        system_prompt: str,
        protocol_package: EmbodimentProtocolPackage,
        provider_timeout_s: float = 45.0,
        max_output_bytes: int = 4_096,
    ) -> None:
        if config.mode != "model-duel-v0" or len(config.participant_ids) != 2:
            raise ValueError("DuelDecisionDispatcher requires a two-participant model duel")
        participant_ids = tuple(sorted(config.participant_ids))
        if set(providers) != set(participant_ids):
            raise ValueError("providers must contain exactly the configured participants")
        if set(models) != set(participant_ids):
            raise ValueError("models must contain exactly the configured participants")
        if not isinstance(provider_timeout_s, (int, float)) or provider_timeout_s <= 0:
            raise ValueError("provider_timeout_s must be positive")
        if (
            isinstance(max_output_bytes, bool)
            or not isinstance(max_output_bytes, int)
            or not 1 <= max_output_bytes <= 1_048_576
        ):
            raise ValueError("max_output_bytes must be from 1 to 1048576")
        self.config = config
        self.participant_ids = participant_ids
        self.providers = {
            participant_id: providers[participant_id] for participant_id in participant_ids
        }
        self.models = {participant_id: models[participant_id] for participant_id in participant_ids}
        self.system_prompt = system_prompt
        self.package = protocol_package
        self.provider_timeout_s = float(provider_timeout_s)
        self.max_output_bytes = max_output_bytes
        self._scratchpads = {
            participant_id: EpisodeScratchpad() for participant_id in participant_ids
        }
        self._closed = False

    def reset_leg(self) -> None:
        """Erase both participant scratchpads before the next symmetric leg."""

        self._ensure_open()
        for scratchpad in self._scratchpads.values():
            scratchpad.reset()

    def scratchpad_utf8(self, participant_id: str) -> bytes:
        """Return one participant's episode-only memory without exposing its opponent's."""

        self._ensure_open()
        return self._scratchpads[participant_id].utf8

    def close(self) -> None:
        if self._closed:
            return
        for scratchpad in self._scratchpads.values():
            scratchpad.close()
        self._closed = True

    async def dispatch(
        self,
        *,
        observations: Mapping[str, Mapping[str, Any]],
        observation_seq: int,
        start_tick: int,
        session: AsyncDuelSession | None = None,
    ) -> DuelDispatchResult:
        """Dispatch one simultaneous decision boundary.

        Missing observations never trigger a provider call. Every other call receives only its
        own observation, frame, and scratchpad. Completion order is discarded before the joint
        ``DecisionWindow`` is constructed.
        """

        self._ensure_open()
        if not isinstance(observations, Mapping):
            raise TypeError("observations must be a participant mapping")

        action_schema = canonical_json_bytes(self.package.schema("controller-action"))
        shared_deadline = time.monotonic_ns() + int(self.provider_timeout_s * 1_000_000_000)
        requests: dict[str, ProviderRequest] = {}
        preflight_failures: dict[str, NoInputReason] = {}
        for participant_id in self.participant_ids:
            observation = observations.get(participant_id)
            if not isinstance(observation, Mapping):
                preflight_failures[participant_id] = "missing"
                continue
            if observation.get("observation_seq") != observation_seq:
                preflight_failures[participant_id] = "stale_observation"
                continue
            if (
                observation.get("episode_id") != self.config.episode_id
                or observation.get("tick") != start_tick
            ):
                preflight_failures[participant_id] = "invalid"
                continue
            frame = await self._participant_frame(participant_id, observation, session)
            provider_observation = dict(observation)
            provider_observation["memory"] = self._scratchpads[participant_id].text
            requests[participant_id] = ProviderRequest(
                episode_id=self.config.episode_id,
                participant_id=participant_id,
                observation_seq=observation_seq,
                deadline_monotonic_ns=shared_deadline,
                model=self.models[participant_id],
                system_prompt=self.system_prompt,
                observation_json=canonical_json_bytes(provider_observation),
                action_schema_json=action_schema,
                scratchpad_utf8=self._scratchpads[participant_id].utf8,
                frame_png=frame,
                max_output_bytes=self.max_output_bytes,
            )

        tasks = {
            participant_id: asyncio.create_task(
                self._call_provider(participant_id, request),
                name=f"duel-provider-{participant_id}",
            )
            for participant_id, request in requests.items()
        }
        try:
            call_results = await asyncio.gather(*tasks.values())
        except asyncio.CancelledError:
            for task in tasks.values():
                task.cancel()
            await asyncio.gather(*tasks.values(), return_exceptions=True)
            raise

        completed = {participant_id: result for participant_id, result in zip(tasks, call_results)}
        actions: dict[str, object] = {}
        failure_reasons = dict(preflight_failures)
        audits: list[DuelParticipantAudit] = []
        for participant_id in self.participant_ids:
            request = requests.get(participant_id)
            if request is None:
                audits.append(
                    DuelParticipantAudit(
                        participant_id=participant_id,
                        provider=self.providers[participant_id].provider_name,
                        observation_seq=observation_seq,
                        observation_sha256="",
                        action_schema_sha256=hashlib.sha256(action_schema).hexdigest(),
                        deadline_monotonic_ns=shared_deadline,
                        max_output_bytes=self.max_output_bytes,
                        result=None,
                        raw_output_sha256=None,
                        started_monotonic_ns=None,
                        completed_monotonic_ns=None,
                    )
                )
                continue
            result, started, completed_ns = completed[participant_id]
            raw_output = result.raw_output
            action = None
            if raw_output is not None and len(raw_output) > self.max_output_bytes:
                result = ProviderCallResult.failed(
                    ProviderFailureKind.OUTPUT_TOO_LARGE, result.telemetry
                )
            elif raw_output is not None:
                try:
                    action = parse_controller_action(raw_output, package=self.package)
                    if (
                        action.episode_id != self.config.episode_id
                        or action.observation_seq != observation_seq
                    ):
                        action = None
                except (KeyError, TypeError, ValueError):
                    action = None
            if action is None:
                failure_reasons[participant_id] = (
                    "timeout" if result.failure == ProviderFailureKind.TIMEOUT else "invalid"
                )
            else:
                actions[participant_id] = action
            audits.append(
                DuelParticipantAudit(
                    participant_id=participant_id,
                    provider=self.providers[participant_id].provider_name,
                    observation_seq=observation_seq,
                    observation_sha256=hashlib.sha256(request.observation_json).hexdigest(),
                    action_schema_sha256=hashlib.sha256(action_schema).hexdigest(),
                    deadline_monotonic_ns=shared_deadline,
                    max_output_bytes=self.max_output_bytes,
                    result=result,
                    raw_output_sha256=(
                        None if raw_output is None else hashlib.sha256(raw_output).hexdigest()
                    ),
                    started_monotonic_ns=started,
                    completed_monotonic_ns=completed_ns,
                )
            )

        window = DecisionWindow.finalize(
            episode_id=self.config.episode_id,
            observation_seq=observation_seq,
            mode=self.config.mode,
            start_tick=start_tick,
            participant_ids=self.participant_ids,
            actions=actions,
            failure_reasons=failure_reasons,
            duration_ticks=10,
        )
        for participant_id, decision in window.decisions.items():
            if decision.action is not None:
                self._scratchpads[participant_id].set(decision.action.memory_update)
        return DuelDispatchResult(window, tuple(audits))

    async def dispatch_and_step(
        self,
        *,
        session: AsyncDuelSession,
        observations: Mapping[str, Mapping[str, Any]],
        observation_seq: int,
        start_tick: int,
    ) -> tuple[DuelDispatchResult, MultiParticipantStepResult]:
        """Dispatch and advance authority exactly once, including neutral invalid windows."""

        dispatch = await self.dispatch(
            observations=observations,
            observation_seq=observation_seq,
            start_tick=start_tick,
            session=session,
        )
        return dispatch, await session.step(dispatch.window)

    async def _call_provider(
        self, participant_id: str, request: ProviderRequest
    ) -> tuple[ProviderCallResult, int, int]:
        started = time.monotonic_ns()
        try:
            result = await asyncio.wait_for(
                self.providers[participant_id].request(request),
                timeout=max(0.0, (request.deadline_monotonic_ns - started) / 1_000_000_000),
            )
            if not isinstance(result, ProviderCallResult):
                raise TypeError("provider returned an invalid result type")
        except asyncio.TimeoutError:
            result = ProviderCallResult.failed(
                ProviderFailureKind.TIMEOUT,
                ProviderTelemetry(latency_ms=(time.monotonic_ns() - started) // 1_000_000),
            )
        except asyncio.CancelledError:
            raise
        except Exception:
            result = ProviderCallResult.failed(
                ProviderFailureKind.INTERNAL,
                ProviderTelemetry(latency_ms=(time.monotonic_ns() - started) // 1_000_000),
            )
        return result, started, time.monotonic_ns()

    async def _participant_frame(
        self,
        participant_id: str,
        observation: Mapping[str, Any],
        session: AsyncDuelSession | None,
    ) -> bytes | None:
        metadata = observation.get("frame")
        if not isinstance(metadata, Mapping):
            return None
        if session is None:
            raise ValueError("hybrid duel observations require an authority session")
        return await session.render(
            participant_id,
            str(metadata["sensor_id"]),
            str(metadata["transport_ref"]),
            int(observation["observation_seq"]),
        )

    def _ensure_open(self) -> None:
        if self._closed:
            raise RuntimeError("duel dispatcher is closed")


__all__ = [
    "AsyncDuelSession",
    "DuelDecisionDispatcher",
    "DuelDispatchResult",
    "DuelParticipantAudit",
]
