"""Authenticated, fail-closed transport for one managed embodiment episode."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import re
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, Literal, Mapping, Protocol

from .protocol import ProtocolValidationError, canonical_json_bytes, strict_json_loads

PROTOCOL_VERSION = "llm-controller/0.1.0"
SUPPORTED_PROTOCOL_VERSIONS = frozenset(
    (PROTOCOL_VERSION, "llm-controller/0.2.0", "llm-controller/0.3.0")
)
TRANSPORT_SCHEMA_VERSION = "llm-controller/transport-frame/1.0.0"
ZERO_HASH = "0" * 64
MAX_TRANSPORT_FRAME_BYTES = 16 * 1024 * 1024
TransportMessageType = Literal[
    "hello",
    "auth",
    "episode_ready",
    "decision_window",
    "step_result",
    "frame_request",
    "frame_response",
    "close_episode",
    "episode_closed",
    "episode_error",
]
Sender = Literal["python", "godot"]
BoundaryHashKind = Literal["session", "config", "checkpoint"]

_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_EPISODE = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_CONNECTION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_TICKET = re.compile(r"^[A-Za-z0-9_-]{43}$")
_BOUNDARY_KIND: Dict[str, str] = {
    "hello": "session",
    "auth": "session",
    "episode_ready": "config",
    "decision_window": "checkpoint",
    "step_result": "checkpoint",
    "frame_request": "checkpoint",
    "frame_response": "checkpoint",
    "close_episode": "checkpoint",
    "episode_closed": "checkpoint",
    "episode_error": "checkpoint",
}
_ALLOWED_BY_SENDER = {
    "python": frozenset(("auth", "decision_window", "frame_request", "close_episode")),
    "godot": frozenset(
        (
            "hello",
            "episode_ready",
            "step_result",
            "frame_response",
            "episode_closed",
            "episode_error",
        )
    ),
}


class EmbodimentTransportError(RuntimeError):
    """Stable, secret-free transport failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class TransportState(str, Enum):
    OPEN = "open"
    FAILED = "failed"
    CLOSED = "closed"


@dataclass(frozen=True)
class TransportFrame:
    schema_version: str
    protocol_version: str
    episode_id: str
    sender: Sender
    sequence: int
    message_type: TransportMessageType
    boundary_hash_kind: BoundaryHashKind
    boundary_hash: str
    body: Mapping[str, Any]
    auth_tag: str

    def as_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "protocol_version": self.protocol_version,
            "episode_id": self.episode_id,
            "sender": self.sender,
            "sequence": self.sequence,
            "message_type": self.message_type,
            "boundary_hash_kind": self.boundary_hash_kind,
            "boundary_hash": self.boundary_hash,
            "body": dict(self.body),
            "auth_tag": self.auth_tag,
        }


def derive_role_key(session_secret: bytes | bytearray, sender: Sender) -> bytes:
    """Derive a direction-specific key without retaining the caller's mutable secret."""

    if not isinstance(session_secret, (bytes, bytearray)) or len(session_secret) != 32:
        raise ValueError("session secret must contain exactly 32 bytes")
    if sender not in ("python", "godot"):
        raise ValueError("sender is unsupported")
    return hmac.new(
        bytes(session_secret),
        b"llm-controller/gateway-key/v1\x00" + sender.encode("ascii"),
        hashlib.sha256,
    ).digest()


def _unsigned_frame(
    *,
    protocol_version: str = PROTOCOL_VERSION,
    episode_id: str,
    sender: Sender,
    sequence: int,
    message_type: TransportMessageType,
    boundary_hash: str,
    body: Mapping[str, Any],
) -> Dict[str, Any]:
    if protocol_version not in SUPPORTED_PROTOCOL_VERSIONS:
        raise EmbodimentTransportError("embodiment_transport_protocol_invalid")
    if _EPISODE.fullmatch(episode_id) is None:
        raise EmbodimentTransportError("embodiment_transport_episode_invalid")
    if (
        isinstance(sequence, bool)
        or not isinstance(sequence, int)
        or not 0 <= sequence <= 9_007_199_254_740_991
    ):
        raise EmbodimentTransportError("embodiment_transport_sequence_invalid")
    kind = _BOUNDARY_KIND.get(message_type)
    if kind is None or message_type not in _ALLOWED_BY_SENDER[sender]:
        raise EmbodimentTransportError("embodiment_transport_message_invalid")
    if not isinstance(boundary_hash, str) or _SHA256.fullmatch(boundary_hash) is None:
        raise EmbodimentTransportError("embodiment_transport_boundary_invalid")
    if kind == "session" and boundary_hash != ZERO_HASH:
        raise EmbodimentTransportError("embodiment_transport_boundary_invalid")
    if message_type in ("hello", "auth") and boundary_hash != ZERO_HASH:
        raise EmbodimentTransportError("embodiment_transport_boundary_invalid")
    if not isinstance(body, Mapping):
        raise EmbodimentTransportError("embodiment_transport_body_invalid")
    value = {
        "schema_version": TRANSPORT_SCHEMA_VERSION,
        "protocol_version": protocol_version,
        "episode_id": episode_id,
        "sender": sender,
        "sequence": sequence,
        "message_type": message_type,
        "boundary_hash_kind": kind,
        "boundary_hash": boundary_hash,
        "body": dict(body),
    }
    try:
        canonical_json_bytes(value)
    except ProtocolValidationError as error:
        raise EmbodimentTransportError("embodiment_transport_body_invalid") from error
    return value


class TransportSession:
    """Canonical per-direction framing for one non-reconnectable episode socket."""

    def __init__(
        self,
        *,
        episode_id: str,
        local_sender: Sender,
        session_secret: bytes | bytearray,
        protocol_version: str = PROTOCOL_VERSION,
    ) -> None:
        if local_sender not in ("python", "godot"):
            raise ValueError("local_sender is unsupported")
        if _EPISODE.fullmatch(episode_id) is None:
            raise ValueError("episode_id is invalid")
        if protocol_version not in SUPPORTED_PROTOCOL_VERSIONS:
            raise ValueError("protocol_version is unsupported")
        self.episode_id = episode_id
        self.protocol_version = protocol_version
        self.local_sender = local_sender
        self.remote_sender: Sender = "godot" if local_sender == "python" else "python"
        self._local_key = derive_role_key(session_secret, local_sender)
        self._remote_key = derive_role_key(session_secret, self.remote_sender)
        self._outbound_sequence = 0
        self._inbound_sequence = 0
        self._state = TransportState.OPEN

    @property
    def state(self) -> TransportState:
        return self._state

    @property
    def inbound_sequence(self) -> int:
        return self._inbound_sequence

    @property
    def outbound_sequence(self) -> int:
        return self._outbound_sequence

    def encode(
        self, message_type: TransportMessageType, *, boundary_hash: str, body: Mapping[str, Any]
    ) -> bytes:
        self._require_open()
        try:
            unsigned = _unsigned_frame(
                protocol_version=self.protocol_version,
                episode_id=self.episode_id,
                sender=self.local_sender,
                sequence=self._outbound_sequence,
                message_type=message_type,
                boundary_hash=boundary_hash,
                body=body,
            )
            tag = hmac.new(
                self._local_key,
                b"llm-controller/gateway-frame/v1\x00" + canonical_json_bytes(unsigned),
                hashlib.sha256,
            ).hexdigest()
            payload = canonical_json_bytes({**unsigned, "auth_tag": tag})
        except (EmbodimentTransportError, ProtocolValidationError, TypeError, ValueError) as error:
            self._state = TransportState.FAILED
            if isinstance(error, EmbodimentTransportError):
                raise
            raise EmbodimentTransportError("embodiment_transport_encode_failed") from error
        if len(payload) > MAX_TRANSPORT_FRAME_BYTES:
            return self._fail("embodiment_transport_frame_too_large")
        self._outbound_sequence += 1
        return payload

    def decode(
        self,
        payload: bytes,
        *,
        expected_message_type: TransportMessageType | None = None,
        expected_boundary_hash: str | None = None,
    ) -> TransportFrame:
        self._require_open()
        if (
            not isinstance(payload, bytes)
            or not payload
            or len(payload) > MAX_TRANSPORT_FRAME_BYTES
        ):
            return self._fail("embodiment_transport_frame_too_large")
        try:
            value = strict_json_loads(payload)
            if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
                raise ValueError("frame is not one canonical object")
            required = {
                "schema_version",
                "protocol_version",
                "episode_id",
                "sender",
                "sequence",
                "message_type",
                "boundary_hash_kind",
                "boundary_hash",
                "body",
                "auth_tag",
            }
            if set(value) != required:
                raise ValueError("frame fields differ")
            tag = value.pop("auth_tag")
            unsigned = _unsigned_frame(
                protocol_version=value["protocol_version"],
                episode_id=value["episode_id"],
                sender=value["sender"],
                sequence=value["sequence"],
                message_type=value["message_type"],
                boundary_hash=value["boundary_hash"],
                body=value["body"],
            )
            if (
                value != unsigned
                or value["boundary_hash_kind"] != _BOUNDARY_KIND[value["message_type"]]
            ):
                raise ValueError("frame policy differs")
            expected_tag = hmac.new(
                self._remote_key,
                b"llm-controller/gateway-frame/v1\x00" + canonical_json_bytes(unsigned),
                hashlib.sha256,
            ).hexdigest()
            if (
                not isinstance(tag, str)
                or _SHA256.fullmatch(tag) is None
                or not hmac.compare_digest(tag, expected_tag)
            ):
                return self._fail("embodiment_transport_authentication_failed")
            frame = TransportFrame(auth_tag=tag, **unsigned)
        except EmbodimentTransportError:
            self._state = TransportState.FAILED
            raise
        except (KeyError, ProtocolValidationError, TypeError, ValueError):
            return self._fail("embodiment_transport_frame_invalid")
        if (
            frame.protocol_version != self.protocol_version
            or frame.episode_id != self.episode_id
            or frame.sender != self.remote_sender
        ):
            return self._fail("embodiment_transport_identity_mismatch")
        if frame.sequence != self._inbound_sequence:
            return self._fail("embodiment_transport_sequence_mismatch")
        if expected_message_type is not None and frame.message_type != expected_message_type:
            return self._fail("embodiment_transport_message_mismatch")
        if expected_boundary_hash is not None and frame.boundary_hash != expected_boundary_hash:
            return self._fail("embodiment_transport_boundary_mismatch")
        self._inbound_sequence += 1
        return frame

    def close(self) -> None:
        self._state = TransportState.CLOSED

    def _require_open(self) -> None:
        if self._state != TransportState.OPEN:
            raise EmbodimentTransportError("embodiment_transport_not_open")

    def _fail(self, code: str):
        self._state = TransportState.FAILED
        raise EmbodimentTransportError(code)


class WebSocketLike(Protocol):
    async def accept(self) -> None: ...
    async def receive_text(self) -> str: ...
    async def send_text(self, data: str) -> None: ...
    async def close(self, code: int = 1000) -> None: ...


class ManagedSocket:
    """Typed frame I/O over a FastAPI-compatible text WebSocket."""

    def __init__(self, websocket: WebSocketLike, transport: TransportSession) -> None:
        self._websocket = websocket
        self.transport = transport
        self._closed = False
        self._closed_event = asyncio.Event()

    async def send(
        self,
        message_type: TransportMessageType,
        *,
        boundary_hash: str,
        body: Mapping[str, Any],
    ) -> None:
        payload = self.transport.encode(message_type, boundary_hash=boundary_hash, body=body)
        await self._websocket.send_text(payload.decode("utf-8"))

    async def receive(
        self,
        *,
        expected_message_type: TransportMessageType | None = None,
        expected_boundary_hash: str | None = None,
    ) -> TransportFrame:
        text = await self._websocket.receive_text()
        if not isinstance(text, str):
            raise EmbodimentTransportError("embodiment_transport_frame_invalid")
        payload = text.encode("utf-8")
        return self.transport.decode(
            payload,
            expected_message_type=expected_message_type,
            expected_boundary_hash=expected_boundary_hash,
        )

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.transport.close()
        try:
            try:
                await self._websocket.close(code=1000)
            except Exception:
                # The peer may already have completed the ASGI close handshake after an
                # authority-side rejection. Local transport state is still scrubbed above.
                pass
        finally:
            self._closed_event.set()

    async def wait_closed(self) -> None:
        await self._closed_event.wait()


class SingleAttachmentRegistry:
    """One-use in-memory attachment tickets; failed attempts consume the ticket."""

    def __init__(self) -> None:
        self._waiting: Dict[str, tuple[str, str]] = {}
        self._attached: set[str] = set()

    def register(self, *, ticket: str, episode_id: str, connection_id: str) -> None:
        if not isinstance(ticket, str) or _TICKET.fullmatch(ticket) is None:
            raise ValueError("ticket is invalid")
        if _EPISODE.fullmatch(episode_id) is None or _CONNECTION.fullmatch(connection_id) is None:
            raise ValueError("attachment identity is invalid")
        if ticket in self._waiting or ticket in self._attached:
            raise ValueError("ticket is already registered")
        self._waiting[ticket] = (episode_id, connection_id)

    def attach(self, *, ticket: str, episode_id: str, connection_id: str) -> None:
        expected = self._waiting.pop(ticket, None)
        self._attached.add(ticket)
        if expected is None or expected != (episode_id, connection_id):
            raise EmbodimentTransportError("embodiment_transport_attachment_rejected")

    def close(self, ticket: str) -> None:
        self._waiting.pop(ticket, None)
        self._attached.add(ticket)

    def __repr__(self) -> str:
        return (
            "SingleAttachmentRegistry("
            f"waiting={len(self._waiting)}, attached={len(self._attached)})"
        )


@dataclass
class _PendingAttachment:
    episode_id: str
    connection_id: str
    protocol_version: str
    session_secret: bytearray = field(repr=False)
    future: asyncio.Future[ManagedSocket]


class ManagedWebSocketEndpoint:
    """Minimal route-independent one-shot WebSocket attachment manager."""

    def __init__(self, *, consumed_ticket_capacity: int = 4096) -> None:
        if consumed_ticket_capacity < 1:
            raise ValueError("consumed ticket capacity must be positive")
        self._pending: Dict[str, _PendingAttachment] = {}
        self._consumed: set[str] = set()
        self._consumed_order: deque[str] = deque()
        self._consumed_ticket_capacity = consumed_ticket_capacity

    def register(
        self,
        *,
        ticket: str,
        episode_id: str,
        connection_id: str,
        session_secret: bytearray,
        protocol_version: str = PROTOCOL_VERSION,
    ) -> asyncio.Future[ManagedSocket]:
        if _TICKET.fullmatch(ticket) is None or _CONNECTION.fullmatch(connection_id) is None:
            raise ValueError("attachment identity is invalid")
        if _EPISODE.fullmatch(episode_id) is None or len(session_secret) != 32:
            raise ValueError("attachment material is invalid")
        if protocol_version not in SUPPORTED_PROTOCOL_VERSIONS:
            raise ValueError("attachment protocol version is unsupported")
        if ticket in self._pending or ticket in self._consumed:
            raise ValueError("attachment ticket is already used")
        future: asyncio.Future[ManagedSocket] = asyncio.get_running_loop().create_future()
        self._pending[ticket] = _PendingAttachment(
            episode_id,
            connection_id,
            protocol_version,
            bytearray(session_secret),
            future,
        )
        future.add_done_callback(
            lambda completed: self.cancel(ticket) if completed.cancelled() else None
        )
        return future

    async def handle(self, ticket: str, websocket: WebSocketLike) -> None:
        pending = self._pending.pop(ticket, None)
        self._mark_consumed(ticket)
        await websocket.accept()
        if pending is None:
            await websocket.close(code=1008)
            return
        socket: ManagedSocket | None = None
        try:
            transport = TransportSession(
                episode_id=pending.episode_id,
                local_sender="python",
                session_secret=pending.session_secret,
                protocol_version=pending.protocol_version,
            )
            socket = ManagedSocket(websocket, transport)
            pending.session_secret[:] = b"\x00" * len(pending.session_secret)
            pending.session_secret.clear()
            hello = await socket.receive(
                expected_message_type="hello", expected_boundary_hash=ZERO_HASH
            )
            if hello.body != {"connection_id": pending.connection_id}:
                raise EmbodimentTransportError("embodiment_transport_attachment_rejected")
            await socket.send(
                "auth",
                boundary_hash=ZERO_HASH,
                body={"attachment_ticket": ticket},
            )
            if not pending.future.done():
                pending.future.set_result(socket)
            await socket.wait_closed()
        except asyncio.CancelledError:
            if not pending.future.done():
                pending.future.cancel()
            if socket is not None:
                await asyncio.shield(socket.close())
            else:
                await asyncio.shield(websocket.close(code=1008))
            raise
        except Exception as error:
            if not pending.future.done():
                pending.future.set_exception(error)
            if socket is not None:
                await socket.close()
            else:
                await websocket.close(code=1008)
        finally:
            pending.session_secret[:] = b"\x00" * len(pending.session_secret)
            pending.session_secret.clear()

    def cancel(self, ticket: str) -> None:
        pending = self._pending.pop(ticket, None)
        self._mark_consumed(ticket)
        if pending is not None:
            pending.session_secret[:] = b"\x00" * len(pending.session_secret)
            pending.session_secret.clear()
            if not pending.future.done():
                pending.future.cancel()

    def diagnostics(self) -> Mapping[str, int]:
        """Return allow-listed lifecycle counts without ticket or secret material."""

        return {"pending": len(self._pending), "consumed": len(self._consumed)}

    def _mark_consumed(self, ticket: str) -> None:
        if ticket in self._consumed:
            return
        self._consumed.add(ticket)
        self._consumed_order.append(ticket)
        while len(self._consumed_order) > self._consumed_ticket_capacity:
            expired = self._consumed_order.popleft()
            self._consumed.discard(expired)


__all__ = [
    "EmbodimentTransportError",
    "MAX_TRANSPORT_FRAME_BYTES",
    "PROTOCOL_VERSION",
    "SUPPORTED_PROTOCOL_VERSIONS",
    "TRANSPORT_SCHEMA_VERSION",
    "ZERO_HASH",
    "ManagedSocket",
    "ManagedWebSocketEndpoint",
    "SingleAttachmentRegistry",
    "TransportFrame",
    "TransportMessageType",
    "TransportSession",
    "TransportState",
    "WebSocketLike",
    "derive_role_key",
]
