"""Process-local lifecycle owner for live solo embodiment episodes."""

from __future__ import annotations

import asyncio
import re
import secrets
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, Mapping, Optional

from .artifacts import EpisodeArtifactBundle, EpisodeBundles
from .credentials import InMemoryCredentialStore, SessionCredential
from .live_solo import LiveSoloError, LiveSoloOutcome
from .presentation import (
    ParticipantFrameSnapshot,
    ParticipantFrameStore,
    ParticipantPreviewHub,
    sanitize_participant_png,
)
from .protocol import strict_json_loads
from .replay_archive import SavedReplay, SavedReplayArchive
from .scripted_construction_demo import (
    DEMO_MINIMUM_EPISODE_TICKS,
    SCRIPTED_CONSTRUCTION_PROVIDER,
    SCRIPTED_CONSTRUCTION_TASK,
)
from .scripted_solo_demo import is_scripted_solo_demo

_PROVIDERS = frozenset(("openai", "anthropic", "gemini", SCRIPTED_CONSTRUCTION_PROVIDER))
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
        if self.provider == SCRIPTED_CONSTRUCTION_PROVIDER and not is_scripted_solo_demo(
            provider=self.provider, model=self.model, task_id=self.task_id
        ):
            raise ValueError("scripted provider is reserved for the solo curriculum demos")
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
        Optional[SessionCredential],
        asyncio.Event,
        Callable[[str, int, bytes], Awaitable[None]],
        Callable[[int, int], Awaitable[None]],
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
    preview: ParticipantPreviewHub = field(default_factory=ParticipantPreviewHub)
    # Direct Godot ingress is intentionally isolated from the canonical snapshot/replay preview
    # path above.  It carries only best-effort participant pixels for the live dashboard.
    live_preview_frames: ParticipantFrameStore = field(default_factory=ParticipantFrameStore)
    live_preview: ParticipantPreviewHub = field(default_factory=ParticipantPreviewHub)
    live_preview_pump: _ParticipantFramePump | None = None
    progress_observation_seq: int | None = None
    progress_tick: int | None = None
    replay_state: str | None = None
    saved_replay: SavedReplay | None = None
    replay_task: asyncio.Task[None] | None = None


@dataclass(frozen=True)
class _QueuedParticipantFrame:
    participant_id: str
    observation_seq: int
    png: bytes


class _ParticipantFramePump:
    """Move expensive browser-only PNG sanitation off the authority runner.

    A single newest-only slot is intentional: presentation frames cannot influence authority,
    provider inputs, scores, or replay verification.  Under load it is always better to discard a
    stale preview than to delay the next deterministic authority tick.
    """

    def __init__(
        self,
        record: _EpisodeRecord,
        *,
        frames: ParticipantFrameStore,
        preview: ParticipantPreviewHub,
        channel: str,
    ) -> None:
        self._record = record
        self._frames = frames
        self._preview = preview
        self._queue: asyncio.Queue[_QueuedParticipantFrame | None] = asyncio.Queue(maxsize=1)
        self._closed = False
        self._worker = asyncio.create_task(
            self._run(), name=f"{channel}-{record.spec.episode_id}"
        )

    async def publish(self, participant_id: str, observation_seq: int, png: bytes) -> bool:
        if self._closed:
            return False
        item = _QueuedParticipantFrame(participant_id, observation_seq, png)
        if self._queue.full():
            try:
                self._queue.get_nowait()
                self._queue.task_done()
            except asyncio.QueueEmpty:
                pass
        self._queue.put_nowait(item)
        return True

    async def finish(self) -> None:
        if self._closed:
            await self._worker
            return
        self._closed = True
        await self._queue.join()
        await self._queue.put(None)
        await self._worker

    async def _run(self) -> None:
        while True:
            item = await self._queue.get()
            try:
                if item is None:
                    return
                sanitized = await asyncio.to_thread(sanitize_participant_png, item.png)
                self._frames.publish_sanitized(item.participant_id, item.observation_seq, sanitized)
                snapshot = self._frames.snapshot()
                if snapshot is not None:
                    self._preview.publish(snapshot)
            except Exception:
                # Presentation is strictly an unscored, local projection.  A malformed frame is
                # never forwarded, but its failure must not alter authority/replay outcomes.
                pass
            finally:
                self._queue.task_done()


class EpisodeService:
    """Run injected episode executors and expose only sanitized public projections."""

    def __init__(
        self,
        executor: EpisodeExecutor,
        *,
        credentials: InMemoryCredentialStore | None = None,
        replay_archive: SavedReplayArchive | None = None,
    ) -> None:
        self._executor = executor
        self._credentials = credentials or InMemoryCredentialStore()
        self._replay_archive = replay_archive
        self._records: Dict[str, _EpisodeRecord] = {}
        self._lock = asyncio.Lock()

    async def create(
        self,
        *,
        provider: str,
        model: str,
        task_id: str,
        seed: int,
        api_key: str | None = None,
        maximum_episode_ticks: int = 1800,
        observation_profile: str = "hybrid-visible-v1",
    ) -> Mapping[str, Any]:
        episode_id = f"ep_live_{secrets.token_hex(12)}"
        if (
            is_scripted_solo_demo(provider=provider, model=model, task_id=task_id)
            and task_id == SCRIPTED_CONSTRUCTION_TASK
            and isinstance(maximum_episode_ticks, int)
            and not isinstance(maximum_episode_ticks, bool)
        ):
            # Keep the dedicated presentation demo alive long enough for its deterministic
            # construction finale even if an older dashboard supplies the prior 600-tick limit.
            maximum_episode_ticks = max(maximum_episode_ticks, DEMO_MINIMUM_EPISODE_TICKS)
        spec = EpisodeRunSpec(
            episode_id,
            provider,
            model,
            task_id,
            seed,
            maximum_episode_ticks,
            observation_profile,
        )
        credential: SessionCredential | None = None
        if provider == SCRIPTED_CONSTRUCTION_PROVIDER:
            if api_key is not None:
                raise ValueError("scripted demo does not accept an API key")
        else:
            if not isinstance(api_key, str) or not api_key:
                raise ValueError("provider API key is required")
            ref = self._credentials.put(episode_id, provider, api_key)
            credential = self._credentials.get(ref)
        record = _EpisodeRecord(spec=spec)
        record.timeline.append({"kind": "episode_queued", "sequence": 0})
        async with self._lock:
            self._records[episode_id] = record
            record.task = asyncio.create_task(
                self._execute(record, credential),
                name=f"embodiment-episode-{episode_id}",
            )
        return self._status(record)

    async def _execute(
        self, record: _EpisodeRecord, credential: SessionCredential | None
    ) -> None:
        record.state = "running"
        record.timeline.append({"kind": "episode_started", "sequence": 1})
        frame_pump = _ParticipantFramePump(
            record,
            frames=record.frames,
            preview=record.preview,
            channel="participant-frame",
        )
        live_preview_pump = _ParticipantFramePump(
            record,
            frames=record.live_preview_frames,
            preview=record.live_preview,
            channel="live-participant-preview",
        )
        record.live_preview_pump = live_preview_pump

        async def publish_frame(participant_id: str, observation_seq: int, png: bytes) -> None:
            await frame_pump.publish(participant_id, observation_seq, png)

        async def publish_progress(observation_seq: int, tick: int) -> None:
            # This is an allow-listed lifecycle projection only.  It is not evidence, a replay
            # input, a participant observation, or a source of authority.  Ignore malformed or
            # non-monotonic reports so presentation code cannot make dashboard time go backwards.
            if (
                isinstance(observation_seq, bool)
                or isinstance(tick, bool)
                or not isinstance(observation_seq, int)
                or not isinstance(tick, int)
                or observation_seq < 0
                or tick < 0
            ):
                return
            if (
                record.progress_observation_seq is not None
                and observation_seq < record.progress_observation_seq
            ):
                return
            if record.progress_tick is not None and tick < record.progress_tick:
                return
            record.progress_observation_seq = observation_seq
            record.progress_tick = tick

        try:
            outcome = await self._executor(
                record.spec, credential, record.cancel_event, publish_frame, publish_progress
            )
            if not isinstance(outcome, LiveSoloOutcome):
                raise TypeError("episode executor returned an invalid outcome")
            if outcome.bundles is None:
                raise RuntimeError("episode evidence was not sealed")
            await frame_pump.finish()
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
            self._start_replay_archive(record, outcome.bundles)
        except asyncio.CancelledError:
            record.state = "cancelled"
            record.timeline.append({"kind": "episode_cancelled", "sequence": len(record.timeline)})
        except LiveSoloError as error:
            record.state = "failed"
            record.failure = error.code
            record.timeline.append(
                {
                    "code": record.failure,
                    "kind": "episode_failed",
                    "sequence": len(record.timeline),
                }
            )
        except Exception as error:
            record.state = "failed"
            candidate = getattr(error, "code", None)
            record.failure = (
                candidate
                if isinstance(candidate, str)
                and re.fullmatch(r"embodiment_[a-z0-9_]{1,95}", candidate)
                else "embodiment_episode_execution_failed"
            )
            record.timeline.append(
                {
                    "code": record.failure,
                    "kind": "episode_failed",
                    "sequence": len(record.timeline),
                }
            )
        finally:
            await frame_pump.finish()
            await live_preview_pump.finish()
            record.live_preview_pump = None
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

    async def preview_subscription(
        self, episode_id: str
    ) -> tuple[int, asyncio.Queue[ParticipantFrameSnapshot], ParticipantFrameSnapshot | None]:
        record = await self._record(episode_id)
        token, queue = record.preview.subscribe()
        return token, queue, record.frames.snapshot()

    async def unsubscribe_preview(self, episode_id: str, token: int) -> None:
        record = await self._record(episode_id)
        record.preview.unsubscribe(token)

    async def publish_live_preview(
        self, episode_id: str, participant_id: str, observation_seq: int, png: bytes
    ) -> bool:
        """Queue a signed Godot ingress frame without touching canonical frame/replay state."""

        record = await self._record(episode_id)
        pump = record.live_preview_pump
        if pump is None:
            return False
        return await pump.publish(participant_id, observation_seq, png)

    async def live_preview_subscription(
        self, episode_id: str
    ) -> tuple[int, asyncio.Queue[ParticipantFrameSnapshot], ParticipantFrameSnapshot | None]:
        """Subscribe to direct Godot presentation pixels only, never canonical frame traffic."""

        record = await self._record(episode_id)
        token, queue = record.live_preview.subscribe()
        return token, queue, record.live_preview_frames.snapshot()

    async def unsubscribe_live_preview(self, episode_id: str, token: int) -> None:
        record = await self._record(episode_id)
        record.live_preview.unsubscribe(token)

    async def replay(self, episode_id: str) -> EpisodeArtifactBundle:
        record = await self._record(episode_id)
        if record.public_bundle is None:
            raise EpisodeReplayNotReadyError()
        return record.public_bundle

    async def saved_replays(self, *, limit: int = 50) -> tuple[SavedReplay, ...]:
        """List only completed participant-video replays from the local archive."""

        if self._replay_archive is None:
            return ()
        return await asyncio.to_thread(self._replay_archive.list, limit=limit)

    async def saved_replay(self, replay_id: str) -> SavedReplay | None:
        if self._replay_archive is None:
            return None
        return await asyncio.to_thread(self._replay_archive.get, replay_id)

    async def saved_replay_video_path(self, replay_id: str):
        """Trusted router helper; raw replays are deliberately not available here."""

        if self._replay_archive is None:
            return None
        return await asyncio.to_thread(self._replay_archive.video_path, replay_id)

    async def saved_replay_public_bundle_path(self, replay_id: str):
        if self._replay_archive is None:
            return None
        return await asyncio.to_thread(self._replay_archive.public_bundle_path, replay_id)

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
        # Let a completed user-visible replay finish rendering during graceful shutdown instead
        # of leaving a durable partial archive.  The archive writes only through a private staging
        # directory and finalizes atomically.
        await asyncio.gather(
            *(record.replay_task for record in records if record.replay_task is not None),
            return_exceptions=True,
        )
        for record in records:
            record.frames.close()
            record.preview.close()
            record.live_preview_frames.close()
            record.live_preview.close()
        self._credentials.close()

    async def _record(self, episode_id: str) -> _EpisodeRecord:
        async with self._lock:
            record = self._records.get(episode_id)
        if record is None:
            raise EpisodeNotFoundError()
        return record

    @staticmethod
    def _status(record: _EpisodeRecord) -> Mapping[str, Any]:
        value: dict[str, Any] = {
            "config": record.spec.public_dict(),
            "episode_id": record.spec.episode_id,
            "failure": record.failure,
            "state": record.state,
        }
        if record.progress_observation_seq is not None and record.progress_tick is not None:
            value["progress"] = {
                "authority_tick": record.progress_tick,
                "observation_seq": record.progress_observation_seq,
            }
        if record.replay_state is not None:
            replay: dict[str, str] = {"state": record.replay_state}
            if record.saved_replay is not None:
                replay["replay_id"] = record.saved_replay.replay_id
            value["replay"] = replay
        return value

    def _start_replay_archive(self, record: _EpisodeRecord, bundles: EpisodeBundles) -> None:
        """Start presentation-only archival after the authority outcome has sealed."""

        if self._replay_archive is None or not is_scripted_solo_demo(
            provider=record.spec.provider,
            model=record.spec.model,
            task_id=record.spec.task_id,
        ):
            return
        record.replay_state = "saving"
        record.replay_task = asyncio.create_task(
            self._archive_completed(record, bundles),
            name=f"embodiment-replay-archive-{record.spec.episode_id}",
        )

    async def _archive_completed(self, record: _EpisodeRecord, bundles: EpisodeBundles) -> None:
        archive = self._replay_archive
        if archive is None:
            return
        try:
            saved = await archive.save(record.spec, bundles)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Never allow optional local presentation output to change a sealed authority result,
            # and never reflect renderer/process output to a browser route.
            record.replay_state = "unavailable"
            return
        record.saved_replay = saved
        record.replay_state = "ready"

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
