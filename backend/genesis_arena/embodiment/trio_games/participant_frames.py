"""Newest-only participant-isolated pixels for three-participant series."""

from __future__ import annotations

import asyncio
import hashlib
from dataclasses import dataclass

from ..presentation.participant_frames import sanitize_participant_jpeg, sanitize_participant_png
from .common import TRIO_PARTICIPANT_IDS


@dataclass(frozen=True)
class TrioParticipantFrameSnapshot:
    leg_index: int
    participant_id: str
    observation_seq: int
    png: bytes
    sha256: str


class TrioParticipantFrameStore:
    def __init__(self) -> None:
        self._snapshots: dict[str, TrioParticipantFrameSnapshot] = {}

    def publish(
        self, leg_index: int, participant_id: str, observation_seq: int, png: bytes
    ) -> None:
        _identity(leg_index, participant_id, observation_seq)
        sanitized = sanitize_participant_png(png)
        current = self._snapshots.get(participant_id)
        if current is not None and (leg_index, observation_seq) < (
            current.leg_index,
            current.observation_seq,
        ):
            raise ValueError("trio participant frame moved backwards")
        self._snapshots[participant_id] = TrioParticipantFrameSnapshot(
            leg_index,
            participant_id,
            observation_seq,
            sanitized,
            hashlib.sha256(sanitized).hexdigest(),
        )

    def snapshot(self, participant_id: str) -> TrioParticipantFrameSnapshot | None:
        if participant_id not in TRIO_PARTICIPANT_IDS:
            raise ValueError("trio frame participant is invalid")
        return self._snapshots.get(participant_id)

    def close(self) -> None:
        self._snapshots.clear()


@dataclass(frozen=True)
class TrioParticipantPreviewSnapshot:
    leg_index: int
    participant_id: str
    sequence: int
    jpeg: bytes


class TrioParticipantPreviewChannel:
    """Per-seat newest-only JPEG fan-out; queues can never accumulate latency."""

    def __init__(self) -> None:
        self._snapshots: dict[str, TrioParticipantPreviewSnapshot] = {}
        self._subscribers: dict[
            str, dict[int, asyncio.Queue[TrioParticipantPreviewSnapshot]]
        ] = {participant_id: {} for participant_id in TRIO_PARTICIPANT_IDS}
        self._next_id = 0

    async def publish(
        self, leg_index: int, participant_id: str, sequence: int, jpeg: bytes
    ) -> bool:
        try:
            _identity(leg_index, participant_id, sequence)
            sanitized = await asyncio.to_thread(sanitize_participant_jpeg, jpeg)
        except (TypeError, ValueError):
            return False
        current = self._snapshots.get(participant_id)
        if current is not None and (leg_index, sequence) <= (
            current.leg_index,
            current.sequence,
        ):
            return False
        snapshot = TrioParticipantPreviewSnapshot(
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
        asyncio.Queue[TrioParticipantPreviewSnapshot],
        TrioParticipantPreviewSnapshot | None,
    ]:
        if participant_id not in TRIO_PARTICIPANT_IDS:
            raise ValueError("trio preview participant is invalid")
        token = self._next_id
        self._next_id += 1
        queue: asyncio.Queue[TrioParticipantPreviewSnapshot] = asyncio.Queue(maxsize=1)
        self._subscribers[participant_id][token] = queue
        return token, queue, self._snapshots.get(participant_id)

    def unsubscribe(self, participant_id: str, token: int) -> None:
        if participant_id in self._subscribers:
            self._subscribers[participant_id].pop(token, None)

    def close(self) -> None:
        self._snapshots.clear()
        for subscribers in self._subscribers.values():
            subscribers.clear()


def _identity(leg_index: object, participant_id: object, sequence: object) -> None:
    if isinstance(leg_index, bool) or not isinstance(leg_index, int) or leg_index not in (0, 1, 2):
        raise ValueError("trio frame leg index is invalid")
    if participant_id not in TRIO_PARTICIPANT_IDS:
        raise ValueError("trio frame participant is invalid")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
        raise ValueError("trio frame sequence is invalid")


__all__ = [
    "TrioParticipantFrameSnapshot",
    "TrioParticipantFrameStore",
    "TrioParticipantPreviewChannel",
    "TrioParticipantPreviewSnapshot",
]
