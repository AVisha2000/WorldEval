"""Newest-only participant-isolated decision-boundary frames for paired runs."""

from __future__ import annotations

import asyncio
import hashlib
from dataclasses import dataclass

from ..presentation.participant_frames import sanitize_participant_jpeg, sanitize_participant_png


@dataclass(frozen=True)
class DuelParticipantFrameSnapshot:
    leg_index: int
    participant_id: str
    observation_seq: int
    png: bytes
    sha256: str


class DuelParticipantFrameStore:
    """Keep one sanitized PNG per current seat; never retain a spectator frame."""

    def __init__(self) -> None:
        self._snapshots: dict[str, DuelParticipantFrameSnapshot] = {}

    def publish(
        self,
        leg_index: int,
        participant_id: str,
        observation_seq: int,
        png: bytes,
    ) -> None:
        if leg_index not in (0, 1):
            raise ValueError("duel frame leg index is invalid")
        if participant_id not in ("participant_0", "participant_1"):
            raise ValueError("duel frame participant is invalid")
        if (
            isinstance(observation_seq, bool)
            or not isinstance(observation_seq, int)
            or observation_seq < 0
        ):
            raise ValueError("duel frame observation sequence is invalid")
        sanitized = sanitize_participant_png(png)
        current = self._snapshots.get(participant_id)
        if current is not None and (leg_index, observation_seq) < (
            current.leg_index,
            current.observation_seq,
        ):
            raise ValueError("duel participant frame moved backwards")
        self._snapshots[participant_id] = DuelParticipantFrameSnapshot(
            leg_index=leg_index,
            participant_id=participant_id,
            observation_seq=observation_seq,
            png=sanitized,
            sha256=hashlib.sha256(sanitized).hexdigest(),
        )

    def snapshot(self, participant_id: str) -> DuelParticipantFrameSnapshot | None:
        if participant_id not in ("participant_0", "participant_1"):
            raise ValueError("duel frame participant is invalid")
        return self._snapshots.get(participant_id)

    def close(self) -> None:
        self._snapshots.clear()


@dataclass(frozen=True)
class DuelParticipantPreviewSnapshot:
    leg_index: int
    participant_id: str
    sequence: int
    jpeg: bytes


class DuelParticipantPreviewChannel:
    """Per-seat newest-only 30 FPS JPEG fan-out with no semantic payload."""

    def __init__(self) -> None:
        self._snapshots: dict[str, DuelParticipantPreviewSnapshot] = {}
        self._subscribers: dict[str, dict[int, asyncio.Queue[DuelParticipantPreviewSnapshot]]] = {
            participant_id: {} for participant_id in ("participant_0", "participant_1")
        }
        self._next_id = 0

    async def publish(
        self, leg_index: int, participant_id: str, sequence: int, jpeg: bytes
    ) -> bool:
        if leg_index not in (0, 1) or participant_id not in self._subscribers:
            return False
        if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
            return False
        try:
            sanitized = await asyncio.to_thread(sanitize_participant_jpeg, jpeg)
        except Exception:
            return False
        current = self._snapshots.get(participant_id)
        if current is not None and (leg_index, sequence) <= (current.leg_index, current.sequence):
            return False
        snapshot = DuelParticipantPreviewSnapshot(
            leg_index, participant_id, sequence, sanitized
        )
        self._snapshots[participant_id] = snapshot
        for queue in tuple(self._subscribers[participant_id].values()):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            queue.put_nowait(snapshot)
        return True

    def subscribe(
        self, participant_id: str
    ) -> tuple[
        int,
        asyncio.Queue[DuelParticipantPreviewSnapshot],
        DuelParticipantPreviewSnapshot | None,
    ]:
        if participant_id not in self._subscribers:
            raise ValueError("duel preview participant is invalid")
        token = self._next_id
        self._next_id += 1
        queue: asyncio.Queue[DuelParticipantPreviewSnapshot] = asyncio.Queue(maxsize=1)
        self._subscribers[participant_id][token] = queue
        return token, queue, self._snapshots.get(participant_id)

    def unsubscribe(self, participant_id: str, token: int) -> None:
        if participant_id in self._subscribers:
            self._subscribers[participant_id].pop(token, None)

    def close(self) -> None:
        self._snapshots.clear()
        for subscribers in self._subscribers.values():
            subscribers.clear()


@dataclass(frozen=True)
class DuelBroadcastPreviewSnapshot:
    """A separately authored public tactical-camera JPEG, never a participant observation."""

    leg_index: int
    sequence: int
    jpeg: bytes


class DuelBroadcastPreviewChannel:
    """One newest-only, presentation-only public broadcast channel for an approved game mode.

    This is intentionally distinct from :class:`DuelParticipantPreviewChannel`: callers cannot
    select a player seat or use this stream as a participant-frame substitute.
    """

    def __init__(self) -> None:
        self._snapshot: DuelBroadcastPreviewSnapshot | None = None
        self._subscribers: dict[int, asyncio.Queue[DuelBroadcastPreviewSnapshot]] = {}
        self._next_id = 0

    async def publish(self, leg_index: int, sequence: int, jpeg: bytes) -> bool:
        if (
            leg_index not in (0, 1)
            or isinstance(sequence, bool)
            or not isinstance(sequence, int)
            or sequence < 0
        ):
            return False
        try:
            sanitized = await asyncio.to_thread(sanitize_participant_jpeg, jpeg)
        except Exception:
            return False
        current = self._snapshot
        if current is not None and (leg_index, sequence) <= (current.leg_index, current.sequence):
            return False
        snapshot = DuelBroadcastPreviewSnapshot(leg_index, sequence, sanitized)
        self._snapshot = snapshot
        for queue in tuple(self._subscribers.values()):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            queue.put_nowait(snapshot)
        return True

    def subscribe(
        self,
    ) -> tuple[
        int,
        asyncio.Queue[DuelBroadcastPreviewSnapshot],
        DuelBroadcastPreviewSnapshot | None,
    ]:
        token = self._next_id
        self._next_id += 1
        queue: asyncio.Queue[DuelBroadcastPreviewSnapshot] = asyncio.Queue(maxsize=1)
        self._subscribers[token] = queue
        return token, queue, self._snapshot

    def unsubscribe(self, token: int) -> None:
        self._subscribers.pop(token, None)

    def close(self) -> None:
        self._snapshot = None
        self._subscribers.clear()


__all__ = [
    "DuelParticipantFrameSnapshot",
    "DuelParticipantFrameStore",
    "DuelBroadcastPreviewChannel",
    "DuelBroadcastPreviewSnapshot",
    "DuelParticipantPreviewChannel",
    "DuelParticipantPreviewSnapshot",
]
