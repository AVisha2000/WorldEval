from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass
from enum import Enum
from typing import Dict, Iterable, Set

from .canonical import canonical_json_bytes
from .models import ActionBatch

COMMIT_DOMAIN = b"worldeval-rts/action-batch-commit/v1\x00"


class CommitRevealError(RuntimeError):
    """The fixed-simultaneous commit/reveal state machine was used out of order."""


def action_batch_commit_hash(batch: ActionBatch, salt_hex: str) -> str:
    try:
        salt = bytes.fromhex(salt_hex)
    except ValueError as exc:
        raise CommitRevealError("commit salt must be lowercase hexadecimal") from exc
    if len(salt) != 32 or salt.hex() != salt_hex:
        raise CommitRevealError("commit salt must encode exactly 32 lowercase bytes")
    # Commit the exact schema-valid wire object. Pydantic's default dump adds
    # implicit ``None`` optionals even when the provider omitted those fields;
    # action-batch.v1 does not permit null there, and Godot receives the
    # exclude-none representation.
    wire_batch = batch.model_dump(mode="json", exclude_none=True)
    payload = canonical_json_bytes(wire_batch) + b"\x00" + salt
    return hashlib.sha256(COMMIT_DOMAIN + payload).hexdigest()


def verify_action_batch_commit(batch: ActionBatch, salt_hex: str, expected_hash: str) -> bool:
    try:
        actual = action_batch_commit_hash(batch, salt_hex)
    except CommitRevealError:
        return False
    return hmac.compare_digest(actual, expected_hash)


@dataclass(frozen=True)
class BatchReveal:
    player_slot: int
    batch: ActionBatch
    salt_hex: str


class WindowPhase(str, Enum):
    COLLECTING = "collecting"
    LOCKED = "locked"
    REVEALED = "revealed"


class FixedCommitRevealWindow:
    """Hold both model batches privately until every commit is locked."""

    def __init__(self, match_id: str, observation_seq: int, player_slots: Iterable[int] = (0, 1)):
        slots = set(player_slots)
        if slots != {0, 1}:
            raise CommitRevealError("official Duel windows require player slots 0 and 1")
        self.match_id = match_id
        self.observation_seq = observation_seq
        self._slots: Set[int] = slots
        self._phase = WindowPhase.COLLECTING
        self._commits: Dict[int, str] = {}
        self._reveals: Dict[int, BatchReveal] = {}

    @property
    def phase(self) -> WindowPhase:
        return self._phase

    def add_private_batch(self, player_slot: int, batch: ActionBatch, salt_hex: str) -> str:
        if self._phase is not WindowPhase.COLLECTING:
            raise CommitRevealError("cannot add a batch after commits are locked")
        self._check_slot(player_slot)
        if player_slot in self._commits:
            raise CommitRevealError(f"player slot {player_slot} already committed")
        if batch.match_id != self.match_id or batch.observation_seq != self.observation_seq:
            raise CommitRevealError("batch does not match this decision window")
        commit = action_batch_commit_hash(batch, salt_hex)
        self._commits[player_slot] = commit
        self._reveals[player_slot] = BatchReveal(player_slot, batch, salt_hex)
        return commit

    def lock_commits(self) -> Dict[int, str]:
        if self._phase is not WindowPhase.COLLECTING:
            raise CommitRevealError("commit window is not collecting")
        missing = self._slots - self._commits.keys()
        if missing:
            raise CommitRevealError(f"cannot lock before all slots commit: {sorted(missing)}")
        self._phase = WindowPhase.LOCKED
        return dict(sorted(self._commits.items()))

    def reveal_all(self) -> Dict[int, BatchReveal]:
        if self._phase is not WindowPhase.LOCKED:
            raise CommitRevealError("batches may be revealed only after commits are locked")
        for slot, reveal in self._reveals.items():
            if not verify_action_batch_commit(reveal.batch, reveal.salt_hex, self._commits[slot]):
                raise CommitRevealError(f"commit verification failed for player slot {slot}")
        self._phase = WindowPhase.REVEALED
        return dict(sorted(self._reveals.items()))

    def commit_for_slot(self, player_slot: int) -> str | None:
        self._check_slot(player_slot)
        return self._commits.get(player_slot)

    def _check_slot(self, player_slot: int) -> None:
        if player_slot not in self._slots:
            raise CommitRevealError(f"unknown player slot: {player_slot}")
