"""Retry-free live-model orchestration for one solo embodiment episode."""

from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Mapping, Tuple

from .artifacts import EpisodeArtifactRecorder, EpisodeBundles
from .contracts import (
    AsyncEnvironmentSession,
    ControllerAction,
    ControllerButtons,
    ControllerState,
    DecisionWindow,
    EpisodeConfig,
)
from .protocol import (
    EmbodimentProtocolPackage,
    ProtocolValidationError,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)
from .providers.contracts import (
    ProviderAdapter,
    ProviderAuditRecord,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)
from .scratchpad import EpisodeScratchpad

_MAX_INPUT_BYTES = 8_388_608
_MAX_OUTPUT_BYTES = 4_096


class LiveSoloError(RuntimeError):
    """Stable live-runner failure that contains no provider payload."""


@dataclass(frozen=True)
class LiveSoloOutcome:
    episode_id: str
    terminal: Mapping[str, Any]
    final_state_hash: str
    windows: int
    provider_failures: int
    bundles: EpisodeBundles | None

    def public_result(self) -> Mapping[str, Any]:
        return {
            "episode_id": self.episode_id,
            "final_state_hash": self.final_state_hash,
            "provider_failures": self.provider_failures,
            "terminal": dict(self.terminal),
            "windows": self.windows,
        }


@dataclass(frozen=True)
class _ActionAttempt:
    action: ControllerAction | None
    result: ProviderCallResult
    frame: bytes | None
    raw_output: bytes | None
    request: ProviderRequest
    adapter_audits: Tuple[ProviderAuditRecord, ...]
    parsing_disposition: str


class LiveSoloRunner:
    """Drive an async authority session through exactly one provider call per boundary."""

    def __init__(
        self,
        *,
        config: EpisodeConfig,
        session: AsyncEnvironmentSession,
        provider: ProviderAdapter,
        model: str,
        system_prompt: str,
        protocol_package: EmbodimentProtocolPackage,
        provider_timeout_s: float = 45.0,
        fallback_duration_ticks: int = 10,
        frame_publisher: Callable[[str, int, bytes], Awaitable[None]] | None = None,
    ) -> None:
        if config.mode != "solo-curriculum-v0" or len(config.participant_ids) != 1:
            raise ValueError("LiveSoloRunner requires a solo episode")
        if not isinstance(provider_timeout_s, (int, float)) or provider_timeout_s <= 0:
            raise ValueError("provider_timeout_s must be positive")
        if (
            isinstance(fallback_duration_ticks, bool)
            or not isinstance(fallback_duration_ticks, int)
            or not 1 <= fallback_duration_ticks <= 20
        ):
            raise ValueError("fallback_duration_ticks must be from 1 to 20")
        self.config = config
        self.session = session
        self.provider = provider
        self.model = model
        self.system_prompt = system_prompt
        self.package = protocol_package
        self.provider_timeout_s = float(provider_timeout_s)
        self.fallback_duration_ticks = fallback_duration_ticks
        self.frame_publisher = frame_publisher

    async def run(self, *, cancel_event: asyncio.Event | None = None) -> LiveSoloOutcome:
        cancel = cancel_event or asyncio.Event()
        participant_id = self.config.participant_ids[0]
        scratchpad = EpisodeScratchpad()
        recorder = EpisodeArtifactRecorder(self.config.episode_id, protocol_package=self.package)
        recorder.freeze_run_configuration(
            provider=self.provider.provider_name,
            model=self.model,
            settings={
                "action_schema_sha256": hashlib.sha256(
                    canonical_json_bytes(self.package.schema("controller-action"))
                ).hexdigest(),
                "fallback_duration_ticks": self.fallback_duration_ticks,
                "max_input_bytes": _MAX_INPUT_BYTES,
                "max_output_bytes": _MAX_OUTPUT_BYTES,
                "observation_profile": self.config.observation_profile,
                "provider_timeout_ms": _deadline_budget_ms(self.provider_timeout_s),
                "system_prompt_sha256": hashlib.sha256(
                    self.system_prompt.encode("utf-8")
                ).hexdigest(),
            },
        )
        windows = 0
        failures = 0
        try:
            observations = await self.session.reset()
            observation = observations[participant_id]
            state = await self.session.state()
            state_hash = _state_hash(state)
            recorder.record_boundary(
                observation_seq=0,
                state_hash=state_hash,
                observations=observations,
                terminal=observation["terminal"],
            )
            while not observation["terminal"]["ended"]:
                if cancel.is_set():
                    raise asyncio.CancelledError
                request_scratchpad = scratchpad.utf8
                attempt = await self._request_action(
                    participant_id=participant_id,
                    observation=observation,
                    scratchpad=scratchpad,
                )
                action = attempt.action
                result = attempt.result
                if result.failure is not None:
                    failures += 1
                reason = None
                if action is None:
                    reason = (
                        "timeout" if result.failure == ProviderFailureKind.TIMEOUT else "invalid"
                    )
                window = DecisionWindow.finalize(
                    episode_id=self.config.episode_id,
                    observation_seq=observation["observation_seq"],
                    mode=self.config.mode,
                    start_tick=observation["tick"],
                    participant_ids=self.config.participant_ids,
                    actions={participant_id: action} if action is not None else {},
                    failure_reasons={} if reason is None else {participant_id: reason},
                    duration_ticks=(
                        action.control.duration_ticks
                        if action is not None
                        else self.fallback_duration_ticks
                    ),
                )
                step = await self.session.step(window)
                windows += 1
                if action is not None:
                    scratchpad.set(action.memory_update)
                recorder.record_provider_call(
                    observation_seq=observation["observation_seq"],
                    prompt=self.system_prompt,
                    raw_output=attempt.raw_output,
                    scratchpad_utf8=request_scratchpad,
                    scratchpad_after_utf8=scratchpad.utf8,
                    telemetry={
                        **result.telemetry.as_dict(),
                        "failure": None if result.failure is None else result.failure.value,
                        "provider": self.provider.provider_name,
                    },
                    frame_png=attempt.frame,
                    frame_metadata=(
                        dict(observation["frame"])
                        if isinstance(observation.get("frame"), Mapping)
                        else None
                    ),
                    participant_id=participant_id,
                    provider_evidence=self._provider_evidence(attempt),
                )
                recorder.record_boundary(
                    observation_seq=observation["observation_seq"] + 1,
                    state_hash=step.state_hash,
                    observations=step.observations,
                    receipts={key: value.as_dict() for key, value in step.receipts.items()},
                    public_events=(event.as_dict() for event in step.public_events),
                    terminal=step.terminal.as_dict(),
                )
                observation = step.observations[participant_id]
                state_hash = step.state_hash

            terminal = dict(observation["terminal"])
            terminal_frame = observation.get("frame")
            if isinstance(terminal_frame, Mapping):
                terminal_png = await self.session.render(
                    participant_id,
                    str(terminal_frame["sensor_id"]),
                    str(terminal_frame["transport_ref"]),
                    int(observation["observation_seq"]),
                )
                recorder.record_frame(
                    observation_seq=int(observation["observation_seq"]),
                    participant_id=participant_id,
                    frame_metadata=terminal_frame,
                    frame_png=terminal_png,
                )
                await self._publish_frame(
                    participant_id,
                    int(observation["observation_seq"]),
                    terminal_png,
                )
            bundles = self._seal_if_replay_available(
                recorder,
                evaluation={
                    "episode_id": self.config.episode_id,
                    "provider_failures": failures,
                    "terminal": terminal,
                    "windows": windows,
                },
            )
            return LiveSoloOutcome(
                self.config.episode_id, terminal, state_hash, windows, failures, bundles
            )
        finally:
            scratchpad.close()
            await self.session.close()

    async def _request_action(
        self,
        *,
        participant_id: str,
        observation: Mapping[str, Any],
        scratchpad: EpisodeScratchpad,
    ) -> _ActionAttempt:
        frame = None
        frame_metadata = observation.get("frame")
        if isinstance(frame_metadata, Mapping):
            frame = await self.session.render(
                participant_id,
                str(frame_metadata["sensor_id"]),
                str(frame_metadata["transport_ref"]),
                int(observation["observation_seq"]),
            )
            await self._publish_frame(participant_id, int(observation["observation_seq"]), frame)
        provider_observation = dict(observation)
        # Scratchpad state is Python-owned. Godot receives memory_update only as protocol input
        # and never owns or persists the episode scratchpad.
        provider_observation["memory"] = scratchpad.text
        deadline = time.monotonic_ns() + int(self.provider_timeout_s * 1_000_000_000)
        request = ProviderRequest(
            episode_id=self.config.episode_id,
            participant_id=participant_id,
            observation_seq=observation["observation_seq"],
            deadline_monotonic_ns=deadline,
            model=self.model,
            system_prompt=self.system_prompt,
            observation_json=canonical_json_bytes(provider_observation),
            action_schema_json=canonical_json_bytes(self.package.schema("controller-action")),
            scratchpad_utf8=scratchpad.utf8,
            frame_png=frame,
            max_input_bytes=_MAX_INPUT_BYTES,
            max_output_bytes=_MAX_OUTPUT_BYTES,
        )
        started = time.monotonic_ns()
        try:
            result = await asyncio.wait_for(
                self.provider.request(request), timeout=self.provider_timeout_s
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
        adapter_audits = self._drain_adapter_audits(request)
        raw_output = result.raw_output
        if raw_output is None:
            return _ActionAttempt(
                None, result, frame, None, request, adapter_audits, "not_attempted"
            )
        if len(raw_output) > request.max_output_bytes:
            return _ActionAttempt(
                None,
                ProviderCallResult.failed(ProviderFailureKind.OUTPUT_TOO_LARGE, result.telemetry),
                frame,
                raw_output,
                request,
                adapter_audits,
                "output_too_large",
            )
        try:
            action = parse_controller_action(raw_output, package=self.package)
            if action.episode_id != self.config.episode_id:
                raise ValueError("controller action episode differs")
            if action.observation_seq != observation["observation_seq"]:
                raise ValueError("controller action observation sequence differs")
        except (ProtocolValidationError, TypeError, ValueError, KeyError):
            result = ProviderCallResult.failed(
                ProviderFailureKind.INVALID_RESPONSE, result.telemetry
            )
            action = None
        return _ActionAttempt(
            action,
            result,
            frame,
            raw_output,
            request,
            adapter_audits,
            "accepted" if action is not None else "rejected",
        )

    async def _publish_frame(self, participant_id: str, observation_seq: int, frame: bytes) -> None:
        if self.frame_publisher is not None:
            await self.frame_publisher(participant_id, observation_seq, frame)

    def _drain_adapter_audits(self, request: ProviderRequest) -> Tuple[ProviderAuditRecord, ...]:
        audit_log = getattr(self.provider, "audit_log", None)
        drain = getattr(audit_log, "drain_episode", None)
        if not callable(drain):
            return ()
        records = drain(self.config.episode_id)
        if not isinstance(records, tuple) or any(
            not isinstance(record, ProviderAuditRecord) for record in records
        ):
            raise LiveSoloError("embodiment_provider_audit_invalid")
        if len(records) > 1 or any(
            record.request != request or record.provider != self.provider.provider_name
            for record in records
        ):
            raise LiveSoloError("embodiment_provider_audit_mismatch")
        return records

    def _provider_evidence(self, attempt: _ActionAttempt) -> Mapping[str, Any]:
        request = attempt.request
        observation = strict_json_loads(request.observation_json)
        if not isinstance(observation, dict):
            raise LiveSoloError("embodiment_provider_observation_invalid")
        visible_payload = {
            key: value for key, value in observation.items() if key not in ("frame", "memory")
        }
        frame_metadata = observation.get("frame")
        frame_metadata_sha256 = (
            canonical_sha256(frame_metadata) if isinstance(frame_metadata, Mapping) else None
        )
        frame_sha256 = (
            hashlib.sha256(request.frame_png).hexdigest() if request.frame_png is not None else None
        )
        bound = (
            frame_metadata_sha256 is None
            and frame_sha256 is None
            or isinstance(frame_metadata, Mapping)
            and frame_metadata.get("sha256") == frame_sha256
        )
        adapter = attempt.adapter_audits[0] if attempt.adapter_audits else None
        adapter_disposition = None
        adapter_duration_ms = None
        if adapter is not None:
            adapter_disposition = (
                "output" if adapter.result.failure is None else adapter.result.failure.value
            )
            adapter_duration_ms = (
                adapter.completed_monotonic_ns - adapter.started_monotonic_ns
            ) // 1_000_000
        return {
            "provider": self.provider.provider_name,
            "model": request.model,
            "schema_sha256": hashlib.sha256(request.action_schema_json).hexdigest(),
            "max_input_bytes": request.max_input_bytes,
            "max_output_bytes": request.max_output_bytes,
            "deadline_budget_ms": _deadline_budget_ms(self.provider_timeout_s),
            "request_material_sha256": _request_material_sha256(request),
            "parsing_disposition": attempt.parsing_disposition,
            "adapter_audit": {
                "recorded": adapter is not None,
                "duration_ms": adapter_duration_ms,
                "disposition": adapter_disposition,
            },
            "visibility_frame_binding": {
                "bound": bound,
                "participant_id": request.participant_id,
                "profile": observation.get("profile"),
                "observation_sha256": hashlib.sha256(request.observation_json).hexdigest(),
                "visible_payload_sha256": canonical_sha256(visible_payload),
                "frame_metadata_sha256": frame_metadata_sha256,
                "frame_sha256": frame_sha256,
            },
        }

    def _seal_if_replay_available(
        self, recorder: EpisodeArtifactRecorder, *, evaluation: Mapping[str, Any]
    ) -> EpisodeBundles | None:
        try:
            replay = self.session.replay_bytes  # type: ignore[attr-defined]
        except (AttributeError, RuntimeError, ValueError):
            return None
        return recorder.seal(authority_replay=replay, evaluation=evaluation)


def parse_controller_action(
    payload: bytes, *, package: EmbodimentProtocolPackage
) -> ControllerAction:
    """Strictly parse one action; never repair or coerce provider output."""

    value = strict_json_loads(payload)
    if not isinstance(value, dict):
        raise ValueError("controller action must be an object")
    package.validate("controller-action", value)
    control = value["control"]
    buttons = control["buttons"]
    return ControllerAction(
        protocol_version=value["protocol_version"],
        episode_id=value["episode_id"],
        observation_seq=value["observation_seq"],
        action_id=value["action_id"],
        control=ControllerState(
            move_x=control["move_x"],
            move_y=control["move_y"],
            look_x=control["look_x"],
            look_y=control["look_y"],
            duration_ticks=control["duration_ticks"],
            buttons=ControllerButtons(**buttons),
        ),
        intent_label=value["intent_label"],
        memory_update=value["memory_update"],
    )


def _state_hash(value: Mapping[str, Any]) -> str:
    state_hash = value.get("state_hash")
    if not isinstance(state_hash, str):
        raise LiveSoloError("embodiment_live_state_invalid")
    return state_hash


def _deadline_budget_ms(provider_timeout_s: float) -> int:
    return max(1, int(provider_timeout_s * 1_000))


def _request_material_sha256(request: ProviderRequest) -> str:
    return canonical_sha256(
        {
            "action_schema_sha256": hashlib.sha256(request.action_schema_json).hexdigest(),
            "frame_sha256": (
                None if request.frame_png is None else hashlib.sha256(request.frame_png).hexdigest()
            ),
            "observation_sha256": hashlib.sha256(request.observation_json).hexdigest(),
            "scratchpad_sha256": hashlib.sha256(request.scratchpad_utf8).hexdigest(),
            "system_prompt_sha256": hashlib.sha256(
                request.system_prompt.encode("utf-8")
            ).hexdigest(),
        }
    )


__all__ = ["LiveSoloError", "LiveSoloOutcome", "LiveSoloRunner", "parse_controller_action"]
