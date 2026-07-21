"""Process-local lifecycle owner for live solo embodiment episodes."""

from __future__ import annotations

import asyncio
import re
import secrets
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, Mapping

from .artifacts import EpisodeArtifactBundle
from .credentials import InMemoryCredentialStore, SessionCredential
from .live_solo import LiveSoloOutcome
from .presentation import ParticipantFrameSnapshot, ParticipantFrameStore
from .protocol import strict_json_loads

_PROVIDERS = frozenset(("openai", "anthropic", "gemini"))
_SAFE_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_SAFE_TASK = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")


class EpisodeServiceError(RuntimeError):
    code = "embodiment_episode_service_error"

    def __init__(self, code: str | None = None) -> None:
        super().__init__(code or self.code)
        self.code = code or self.code


class EpisodeNotFoundError(EpisodeServiceError):
    code = "embodiment_episode_not_found"


class EpisodeResultNotReadyError(EpisodeServiceError):
    code = "embodiment_episode_result_not_ready"


class EpisodeReplayNotReadyError(EpisodeServiceError):
    code = "embodiment_episode_replay_not_ready"


@dataclass(frozen=True)
class EpisodeRunSpec:
    episode_id: str
    provider: str
    model: str
    task_id: str
    seed: int
    maximum_episode_ticks: int = 1800
    observation_profile: str = "hybrid-visible-v1"

    def __post_init__(self) -> None:
        if not self.episode_id.startswith("ep_"):
            raise ValueError("episode_id is invalid")
        if self.provider not in _PROVIDERS:
            raise ValueError("provider is unsupported")
        if self.observation_profile != "hybrid-visible-v1":
            raise ValueError("only hybrid-visible-v1 is selectable for live episodes")
        if _SAFE_MODEL.fullmatch(self.model) is None or _SAFE_TASK.fullmatch(self.task_id) is None:
            raise ValueError("model or task is invalid")
        if isinstance(self.seed, bool) or not isinstance(self.seed, int) or self.seed < 0:
            raise ValueError("seed is invalid")
        if (
            isinstance(self.maximum_episode_ticks, bool)
            or not isinstance(self.maximum_episode_ticks, int)
            or not 1 <= self.maximum_episode_ticks <= 18_000
        ):
            raise ValueError("maximum_episode_ticks is invalid")

    def public_dict(self) -> Mapping[str, Any]:
        return {
            "episode_id": self.episode_id,
            "maximum_episode_ticks": self.maximum_episode_ticks,
            "model": self.model,
            "observation_profile": self.observation_profile,
            "provider": self.provider,
            "seed": self.seed,
            "task_id": self.task_id,
        }


EpisodeExecutor = Callable[
    [
        EpisodeRunSpec,
        SessionCredential,
        asyncio.Event,
        Callable[[str, int, bytes], Awaitable[None]],
    ],
    Awaitable[LiveSoloOutcome],
]


@dataclass(frozen=True)
class EpisodeFrameView:
    state: str
    snapshot: ParticipantFrameSnapshot | None


@dataclass
class _EpisodeRecord:
    spec: EpisodeRunSpec
    state: str = "queued"
    failure: str | None = None
    outcome: LiveSoloOutcome | None = None
    public_bundle: EpisodeArtifactBundle | None = None
    protected_bundle: EpisodeArtifactBundle | None = None
    cancel_event: asyncio.Event = field(default_factory=asyncio.Event)
    task: asyncio.Task[None] | None = None
    timeline: list[Mapping[str, Any]] = field(default_factory=list)
    frames: ParticipantFrameStore = field(default_factory=ParticipantFrameStore)


class EpisodeService:
    """Run injected episode executors and expose only sanitized public projections."""

    def __init__(
        self,
        executor: EpisodeExecutor,
        *,
        credentials: InMemoryCredentialStore | None = None,
    ) -> None:
        self._executor = executor
        self._credentials = credentials or InMemoryCredentialStore()
        self._records: Dict[str, _EpisodeRecord] = {}
        self._lock = asyncio.Lock()

    async def create(
        self,
        *,
        provider: str,
        model: str,
        task_id: str,
        seed: int,
        api_key: str,
        maximum_episode_ticks: int = 1800,
        observation_profile: str = "hybrid-visible-v1",
    ) -> Mapping[str, Any]:
        episode_id = f"ep_live_{secrets.token_hex(12)}"
        spec = EpisodeRunSpec(
            episode_id,
            provider,
            model,
            task_id,
            seed,
            maximum_episode_ticks,
            observation_profile,
        )
        ref = self._credentials.put(episode_id, provider, api_key)
        record = _EpisodeRecord(spec=spec)
        record.timeline.append({"kind": "episode_queued", "sequence": 0})
        async with self._lock:
            self._records[episode_id] = record
            record.task = asyncio.create_task(
                self._execute(record, self._credentials.get(ref)),
                name=f"embodiment-episode-{episode_id}",
            )
        return self._status(record)

    async def _execute(self, record: _EpisodeRecord, credential: SessionCredential) -> None:
        record.state = "running"
        record.timeline.append({"kind": "episode_started", "sequence": 1})

        async def publish_frame(participant_id: str, observation_seq: int, png: bytes) -> None:
            record.frames.publish(participant_id, observation_seq, png)

        try:
            outcome = await self._executor(
                record.spec, credential, record.cancel_event, publish_frame
            )
            if not isinstance(outcome, LiveSoloOutcome):
                raise TypeError("episode executor returned an invalid outcome")
            if outcome.bundles is None:
                raise RuntimeError("episode evidence was not sealed")
            record.outcome = outcome
            record.public_bundle = outcome.bundles.public
            record.protected_bundle = outcome.bundles.protected
            self._append_public_evidence(record, outcome.bundles.public)
            record.state = "completed"
            record.timeline.append(
                {
                    "kind": "episode_completed",
                    "outcome": outcome.terminal["outcome"],
                    "sequence": len(record.timeline),
                }
            )
        except asyncio.CancelledError:
            record.state = "cancelled"
            record.timeline.append({"kind": "episode_cancelled", "sequence": len(record.timeline)})
        except Exception:
            record.state = "failed"
            record.failure = "embodiment_episode_execution_failed"
            record.timeline.append(
                {
                    "code": record.failure,
                    "kind": "episode_failed",
                    "sequence": len(record.timeline),
                }
            )
        finally:
            self._credentials.discard_episode(record.spec.episode_id)

    async def status(self, episode_id: str) -> Mapping[str, Any]:
        return self._status(await self._record(episode_id))

    async def timeline(self, episode_id: str) -> tuple[Mapping[str, Any], ...]:
        record = await self._record(episode_id)
        return tuple(dict(event) for event in record.timeline)

    async def result(self, episode_id: str) -> Mapping[str, Any]:
        record = await self._record(episode_id)
        if record.state not in ("completed", "cancelled", "failed"):
            raise EpisodeResultNotReadyError()
        value: dict[str, Any] = dict(self._status(record))
        value["result"] = None if record.outcome is None else record.outcome.public_result()
        return value

    async def frame(self, episode_id: str) -> EpisodeFrameView:
        record = await self._record(episode_id)
        snapshot = record.frames.snapshot()
        if record.state in ("completed", "cancelled", "failed"):
            state = "finished"
        elif snapshot is None:
            state = "loading"
        else:
            state = "live"
        return EpisodeFrameView(state, snapshot)

    async def replay(self, episode_id: str) -> EpisodeArtifactBundle:
        record = await self._record(episode_id)
        if record.public_bundle is None:
            raise EpisodeReplayNotReadyError()
        return record.public_bundle

    async def protected_bundle(self, episode_id: str) -> EpisodeArtifactBundle:
        """Return protected evidence to trusted local certification code, never the API router."""

        record = await self._record(episode_id)
        if record.protected_bundle is None:
            raise EpisodeReplayNotReadyError()
        return record.protected_bundle

    async def cancel(self, episode_id: str) -> Mapping[str, Any]:
        record = await self._record(episode_id)
        if record.state in ("queued", "running"):
            record.cancel_event.set()
            if record.task is not None:
                record.task.cancel()
                try:
                    await record.task
                except asyncio.CancelledError:
                    pass
        return self._status(record)

    async def aclose(self) -> None:
        async with self._lock:
            records = tuple(self._records.values())
        for record in records:
            if record.task is not None and not record.task.done():
                record.cancel_event.set()
                record.task.cancel()
        await asyncio.gather(
            *(record.task for record in records if record.task is not None),
            return_exceptions=True,
        )
        for record in records:
            record.frames.close()
        self._credentials.close()

    async def _record(self, episode_id: str) -> _EpisodeRecord:
        async with self._lock:
            record = self._records.get(episode_id)
        if record is None:
            raise EpisodeNotFoundError()
        return record

    @staticmethod
    def _status(record: _EpisodeRecord) -> Mapping[str, Any]:
        return {
            "config": record.spec.public_dict(),
            "episode_id": record.spec.episode_id,
            "failure": record.failure,
            "state": record.state,
        }

    @staticmethod
    def _append_public_evidence(record: _EpisodeRecord, bundle: EpisodeArtifactBundle) -> None:
        for role, kind in (("receipts", "action_receipts"), ("public_events", "authority_event")):
            try:
                values = strict_json_loads(bundle.read(role))
            except Exception:
                continue
            if not isinstance(values, list):
                continue
            for value in values:
                if isinstance(value, Mapping):
                    record.timeline.append(
                        {"kind": kind, "sequence": len(record.timeline), "value": dict(value)}
                    )


__all__ = [
    "EpisodeExecutor",
    "EpisodeFrameView",
    "EpisodeNotFoundError",
    "EpisodeReplayNotReadyError",
    "EpisodeResultNotReadyError",
    "EpisodeRunSpec",
    "EpisodeService",
    "EpisodeServiceError",
]
