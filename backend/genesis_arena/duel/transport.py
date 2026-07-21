"""Fail-closed local WebSocket framing for the Duel Godot/Gateway boundary.

The actual WebSocket server is deliberately outside this module.  This layer supplies canonical
one-object frames, strict per-direction sequence state, boundary-hash policy, and single-attach
authentication so FastAPI or another local host cannot accidentally accept a stale reconnect.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep public annotations compatible with the Python 3.9 floor.
import hashlib
import hmac
from enum import Enum
from typing import Dict, Literal, Optional

from pydantic import Field, JsonValue, model_validator

from .canonical import DuelCanonicalError, canonical_json_bytes, strict_json_loads
from .models import DuelModel, HashHex, MatchId, ProtocolVersion

MAX_TRANSPORT_FRAME_BYTES = 1_048_576

TransportMessageType = Literal[
    "configure_duel",
    "duel_ready",
    "match_init",
    "observation_pair",
    "observation",
    "thinking_status",
    "batch_commit_hashes",
    "batch_commits_locked",
    "batch_reveal",
    "action_receipts",
    "tick_events",
    "checkpoint",
    "match_result",
]
BoundaryHashKind = Literal["config", "protocol", "observation", "checkpoint", "result"]

_BOUNDARY_KIND_BY_TYPE: Dict[str, str] = {
    "configure_duel": "config",
    "duel_ready": "config",
    "match_init": "protocol",
    "observation_pair": "checkpoint",
    "observation": "observation",
    "thinking_status": "observation",
    "batch_commit_hashes": "checkpoint",
    "batch_commits_locked": "checkpoint",
    "batch_reveal": "checkpoint",
    "action_receipts": "checkpoint",
    "tick_events": "checkpoint",
    "checkpoint": "checkpoint",
    "match_result": "result",
}
_PROVIDER_VISIBLE_TYPES = frozenset({"match_init", "observation", "thinking_status"})
_OMNISCIENT_HASH_KEYS = frozenset(
    {"checkpoint_hash", "omniscient_state_hash", "state_hash", "world_hash"}
)


class DuelTransportError(RuntimeError):
    """Base transport contract error."""


class DuelTransportAuthenticationError(DuelTransportError):
    """A local connection did not prove its ephemeral session token."""


class DuelTransportSequenceError(DuelTransportError):
    """A frame was duplicated, skipped, reordered, or received after failure."""


class DuelTransportPolicyError(DuelTransportError):
    """A frame crossed a boundary with the wrong hash or hidden data."""


class LocalConnectionState(str, Enum):
    WAITING = "waiting"
    ATTACHED = "attached"
    CLOSED = "closed"


class DuelTransportFrame(DuelModel):
    protocol_version: ProtocolVersion = "worldeval-rts/1.0.0"
    match_id: MatchId
    sequence: int = Field(ge=0, le=9_007_199_254_740_991)
    message_type: TransportMessageType
    boundary_hash_kind: BoundaryHashKind
    boundary_hash: HashHex
    body: Dict[str, JsonValue]

    @model_validator(mode="after")
    def validate_boundary_policy(self) -> DuelTransportFrame:
        expected_kind = _BOUNDARY_KIND_BY_TYPE[self.message_type]
        if self.boundary_hash_kind != expected_kind:
            raise ValueError(
                f"{self.message_type} requires {expected_kind} boundary hash"
            )
        if self.message_type in _PROVIDER_VISIBLE_TYPES and _contains_hidden_hash(self.body):
            raise ValueError("provider-visible frame contains an omniscient hash")
        return self


class LocalSessionAuthenticator:
    """One ephemeral bearer token that can attach exactly one local connection once."""

    def __init__(self, token: bytes) -> None:
        if not isinstance(token, bytes) or len(token) < 32:
            raise ValueError("local session token must contain at least 32 random bytes")
        self._token_digest = hashlib.sha256(token).digest()
        self._state = LocalConnectionState.WAITING
        self._connection_id: Optional[str] = None

    @property
    def state(self) -> LocalConnectionState:
        return self._state

    @property
    def connection_id(self) -> Optional[str]:
        return self._connection_id

    def attach(self, *, token: bytes, connection_id: str) -> None:
        if self._state is not LocalConnectionState.WAITING:
            raise DuelTransportAuthenticationError(
                "local Duel session token cannot be reused or reattached"
            )
        if not connection_id or len(connection_id) > 128:
            raise DuelTransportAuthenticationError("connection_id is invalid")
        candidate = hashlib.sha256(token).digest() if isinstance(token, bytes) else b""
        if not hmac.compare_digest(candidate, self._token_digest):
            self._state = LocalConnectionState.CLOSED
            raise DuelTransportAuthenticationError("local Duel authentication failed")
        self._connection_id = connection_id
        self._state = LocalConnectionState.ATTACHED

    def close(self, *, connection_id: str) -> None:
        if (
            self._state is not LocalConnectionState.ATTACHED
            or connection_id != self._connection_id
        ):
            raise DuelTransportAuthenticationError("connection close identity is ambiguous")
        self._state = LocalConnectionState.CLOSED

    def __repr__(self) -> str:
        return f"LocalSessionAuthenticator(state={self._state.value!r})"


class DuelTransportSession:
    """Strict canonical sequence state for one authenticated, non-reconnectable socket."""

    def __init__(self, match_id: str) -> None:
        # Reuse the wire model to validate MatchId without maintaining a second regex.
        probe = DuelTransportFrame(
            match_id=match_id,
            sequence=0,
            message_type="configure_duel",
            boundary_hash_kind="config",
            boundary_hash="0" * 64,
            body={},
        )
        self.match_id = probe.match_id
        self._outbound_sequence = 0
        self._inbound_sequence = 0
        self._failed = False
        self._closed = False

    @property
    def outbound_sequence(self) -> int:
        return self._outbound_sequence

    @property
    def inbound_sequence(self) -> int:
        return self._inbound_sequence

    @property
    def failed(self) -> bool:
        return self._failed

    def encode(
        self,
        message_type: TransportMessageType,
        *,
        boundary_hash: str,
        body: Dict[str, JsonValue],
    ) -> bytes:
        self._require_open()
        kind = _BOUNDARY_KIND_BY_TYPE.get(message_type)
        if kind is None:
            self._failed = True
            raise DuelTransportPolicyError("outbound Duel message type is unsupported")
        try:
            frame = DuelTransportFrame(
                match_id=self.match_id,
                sequence=self._outbound_sequence,
                message_type=message_type,
                boundary_hash_kind=kind,
                boundary_hash=boundary_hash,
                body=body,
            )
            payload = canonical_json_bytes(frame)
        except (DuelCanonicalError, TypeError, ValueError) as exc:
            self._failed = True
            raise DuelTransportPolicyError("outbound Duel frame violates policy") from exc
        if len(payload) > MAX_TRANSPORT_FRAME_BYTES:
            self._failed = True
            raise DuelTransportPolicyError("outbound Duel frame exceeds byte limit")
        self._outbound_sequence += 1
        return payload

    def decode(
        self,
        payload: bytes,
        *,
        expected_message_type: Optional[TransportMessageType] = None,
        expected_boundary_hash: Optional[str] = None,
    ) -> DuelTransportFrame:
        self._require_open()
        if not isinstance(payload, bytes) or len(payload) > MAX_TRANSPORT_FRAME_BYTES:
            return self._fail_policy("inbound Duel frame exceeds byte limit")
        try:
            value = strict_json_loads(payload)
            if not isinstance(value, dict):
                raise ValueError("frame root is not an object")
            if canonical_json_bytes(value) != payload:
                raise ValueError("frame bytes are not canonical")
            frame = DuelTransportFrame.model_validate(value)
        except (DuelCanonicalError, TypeError, ValueError) as exc:
            self._failed = True
            raise DuelTransportPolicyError("inbound Duel frame is invalid") from exc
        if frame.match_id != self.match_id:
            return self._fail_policy("inbound Duel frame has wrong match")
        if frame.sequence != self._inbound_sequence:
            self._failed = True
            raise DuelTransportSequenceError(
                f"expected inbound sequence {self._inbound_sequence}, got {frame.sequence}"
            )
        if expected_message_type is not None and frame.message_type != expected_message_type:
            return self._fail_policy("inbound Duel frame has wrong message type")
        if expected_boundary_hash is not None and frame.boundary_hash != expected_boundary_hash:
            return self._fail_policy("inbound Duel frame has wrong boundary hash")
        self._inbound_sequence += 1
        return frame

    def close(self) -> None:
        self._closed = True

    def _require_open(self) -> None:
        if self._failed:
            raise DuelTransportSequenceError("Duel transport already failed closed")
        if self._closed:
            raise DuelTransportSequenceError("Duel transport is closed")

    def _fail_policy(self, message: str):
        self._failed = True
        raise DuelTransportPolicyError(message)


def _contains_hidden_hash(value: object) -> bool:
    if isinstance(value, dict):
        if any(key in _OMNISCIENT_HASH_KEYS for key in value):
            return True
        return any(_contains_hidden_hash(child) for child in value.values())
    if isinstance(value, list):
        return any(_contains_hidden_hash(child) for child in value)
    return False
