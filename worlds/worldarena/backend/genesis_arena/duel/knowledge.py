from __future__ import annotations

import base64
import hashlib
import hmac
from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, Iterable, Mapping


class KnowledgeError(ValueError):
    """A caller attempted to violate the per-player knowledge boundary."""


class KnowledgeStatus(str, Enum):
    OWNED = "owned"
    VISIBLE = "visible"
    REMEMBERED = "remembered"
    UNLOCATED = "unlocated"
    DESTROYED = "destroyed"


@dataclass(frozen=True)
class ProjectedEvent:
    audience: str
    event_seq: int
    tick: int
    kind: str
    payload: Mapping[str, Any]


class OpaqueAliasBook:
    """Stable, observer-specific aliases that never expose internal entity IDs."""

    def __init__(self, match_alias_secret: bytes, observer_slot: int) -> None:
        if len(match_alias_secret) < 32:
            raise KnowledgeError("match alias secret must contain at least 32 bytes")
        if observer_slot not in {0, 1}:
            raise KnowledgeError("observer slot must be 0 or 1")
        self._observer_key = hmac.new(
            match_alias_secret,
            f"worldeval-rts/alias/v1/observer/{observer_slot}".encode("ascii"),
            hashlib.sha256,
        ).digest()
        self._internal_to_alias: Dict[str, str] = {}
        self._alias_to_internal: Dict[str, str] = {}
        self._tombstones: set[str] = set()

    def observe(self, internal_id: str) -> str:
        if not internal_id:
            raise KnowledgeError("internal entity ID cannot be empty")
        if internal_id in self._internal_to_alias:
            return self._internal_to_alias[internal_id]
        digest = hmac.new(self._observer_key, internal_id.encode("utf-8"), hashlib.sha256).digest()
        token = base64.b32encode(digest).decode("ascii").rstrip("=").lower()
        alias = f"e_{token}"
        existing = self._alias_to_internal.get(alias)
        if existing is not None and existing != internal_id:
            # Full 256-bit aliases make this practically unreachable; failing closed avoids an
            # order-dependent collision suffix that could break deterministic projection.
            raise KnowledgeError("opaque entity alias collision")
        self._internal_to_alias[internal_id] = alias
        self._alias_to_internal[alias] = internal_id
        return alias

    def known_alias(self, internal_id: str) -> str | None:
        return self._internal_to_alias.get(internal_id)

    def resolve_known(self, alias: str) -> str | None:
        return self._alias_to_internal.get(alias)

    def tombstone(self, internal_id: str) -> str:
        alias = self.observe(internal_id)
        self._tombstones.add(alias)
        return alias

    def is_tombstoned(self, alias: str) -> bool:
        return alias in self._tombstones


class AudienceEventSequencer:
    """Issue contiguous sequence numbers independently for each legal audience."""

    def __init__(self, audiences: Iterable[str] = ("player_0", "player_1", "omniscient")) -> None:
        audience_set = set(audiences)
        if not audience_set:
            raise KnowledgeError("at least one event audience is required")
        self._next: Dict[str, int] = {audience: 1 for audience in sorted(audience_set)}

    def emit(
        self, audience: str, *, tick: int, kind: str, payload: Mapping[str, Any]
    ) -> ProjectedEvent:
        if audience not in self._next:
            raise KnowledgeError(f"unknown event audience: {audience}")
        if tick < 0:
            raise KnowledgeError("event tick must be non-negative")
        sequence = self._next[audience]
        self._next[audience] += 1
        return ProjectedEvent(audience, sequence, tick, kind, dict(payload))

    def next_sequence(self, audience: str) -> int:
        if audience not in self._next:
            raise KnowledgeError(f"unknown event audience: {audience}")
        return self._next[audience]
