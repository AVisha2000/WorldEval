"""Authenticated, best-effort ingress for local participant-preview pixels.

This module deliberately lives outside the managed authority transport.  Frames accepted here are
presentation-only: they cannot influence a decision window, checkpoint hash, score, provider
request, or replay.  The browser-facing websocket receives only sanitized JPEG bytes from
:class:`EpisodeService`'s newest-frame pump. Canonical decision/evidence frames remain PNG.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import re
from dataclasses import dataclass, field
from typing import Awaitable, Callable, Optional

from fastapi import APIRouter, Request, Response, WebSocket, WebSocketDisconnect

JPEG_SIGNATURE = b"\xff\xd8"
PREVIEW_KEY_DOMAIN = b"llm-controller/preview-key/v2\x00"
PREVIEW_FRAME_DOMAIN = b"llm-controller/preview-frame/v2\x00"
PREVIEW_SEQUENCE_HEADER = "x-worldarena-preview-sequence"
PREVIEW_SIGNATURE_HEADER = "x-worldarena-preview-auth"
MAX_PREVIEW_JPEG_BYTES = 4 * 1024 * 1024
SUPPORTED_PREVIEW_TASKS = frozenset(
    (
        "orientation-v0",
        "interaction-v0",
        "construction-v0",
        "neutral-encounter-v0",
        "movement-maze-v0",
        "operator-action-course-v0",
        "central-relay-v0",
        "duo-checkpoint-race-v0",
        "duo-relay-control-v0",
        "duo-spar-v0",
        "duo-resource-relay-v0",
        "rts-skirmish-v0",
        "trio-relay-v0",
        "trio-free-for-all-v0",
    )
)
_DUO_PREVIEW_TASKS = frozenset(
    (
        "central-relay-v0",
        "duo-checkpoint-race-v0",
        "duo-relay-control-v0",
        "duo-spar-v0",
        "duo-resource-relay-v0",
        "rts-skirmish-v0",
    )
)
_TRIO_PREVIEW_TASKS = frozenset(("trio-relay-v0", "trio-free-for-all-v0"))

_TICKET = re.compile(r"^[A-Za-z0-9_-]{43}$")
_EPISODE = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_SEQUENCE = re.compile(r"^(?:0|[1-9][0-9]{0,15})$")
_HEX_TAG = re.compile(r"^[0-9a-f]{64}$")

PreviewSink = Callable[[str, int, bytes], Awaitable[Optional[bool]]]


@dataclass
class _PreviewRegistration:
    episode_id: str
    participant_id: str
    key: bytearray = field(repr=False)
    sink: PreviewSink = field(repr=False)
    last_sequence: int = -1


class InternalParticipantPreviewIngress:
    """One-process, ticket-scoped ingress for unscored solo camera pixels.

    A domain-separated key is retained instead of the transport secret.  The endpoint returns
    the same empty response for acceptance and rejection so it does not become an episode or
    credential oracle. Full JPEG metadata stripping occurs in the asynchronous live-preview pump;
    this ingress only performs a constant-cost structural gate before invoking that pump.
    """

    def __init__(self) -> None:
        self._registrations: dict[str, _PreviewRegistration] = {}

    def register(
        self,
        *,
        ticket: str,
        episode_id: str,
        task_id: str,
        session_secret: bytes | bytearray,
        sink: PreviewSink,
        participant_id: str = "participant_0",
    ) -> None:
        if _TICKET.fullmatch(ticket) is None or _EPISODE.fullmatch(episode_id) is None:
            raise ValueError("preview registration identity is invalid")
        if task_id not in SUPPORTED_PREVIEW_TASKS:
            raise ValueError("preview registration task is unsupported")
        allowed_participants = (
            ("participant_0", "participant_1", "participant_2")
            if task_id in _TRIO_PREVIEW_TASKS
            else ("participant_0", "participant_1")
            if task_id in _DUO_PREVIEW_TASKS
            else ("participant_0",)
        )
        # Broadcast is a separate, explicitly public camera channel restricted to the RTS
        # vertical slice. It is never a valid participant id for a player observation.
        if task_id == "rts-skirmish-v0":
            allowed_participants = (*allowed_participants, "broadcast")
        if participant_id not in allowed_participants:
            raise ValueError("preview registration participant is invalid")
        if not callable(sink):
            raise TypeError("preview registration sink is invalid")
        key = derive_preview_key(session_secret)
        if ticket in self._registrations:
            _zero(key)
            raise ValueError("preview registration ticket is already used")
        self._registrations[ticket] = _PreviewRegistration(
            episode_id=episode_id,
            participant_id=participant_id,
            key=bytearray(key),
            sink=sink,
        )
        _zero(key)

    def unregister(self, ticket: str) -> None:
        registration = self._registrations.pop(ticket, None)
        if registration is not None:
            _zero(registration.key)

    def close(self) -> None:
        for ticket in tuple(self._registrations):
            self.unregister(ticket)

    async def publish(
        self,
        *,
        ticket: str,
        content_type: str | None,
        sequence: str | None,
        signature: str | None,
        jpeg: bytes,
    ) -> bool:
        """Accept one signed, newest-only frame without surfacing an error to its caller."""

        registration = self._registrations.get(ticket)
        parsed_sequence = _parse_sequence(sequence)
        if (
            registration is None
            or content_type != "image/jpeg"
            or parsed_sequence is None
            or not _valid_preview_jpeg(jpeg)
            or not _valid_signature(signature)
        ):
            return False
        expected = preview_auth_tag(
            registration.key,
            ticket=ticket,
            episode_id=registration.episode_id,
            sequence=parsed_sequence,
            jpeg=jpeg,
        )
        if (
            not hmac.compare_digest(signature, expected)
            or parsed_sequence <= registration.last_sequence
        ):
            return False

        # Advance before awaiting the browser-only sink.  This makes replays/stale packets a
        # no-op even when two local HTTP requests race.  Sink failures stay isolated from the
        # authority process and are intentionally indistinguishable from a dropped frame.
        registration.last_sequence = parsed_sequence
        try:
            delivered = await registration.sink(
                registration.participant_id, parsed_sequence, jpeg
            )
        except Exception:
            return False
        return delivered is not False

    def diagnostics(self) -> dict[str, int]:
        """Allow-listed counts only; tickets, keys, and image bytes never leave this object."""

        return {"registrations": len(self._registrations)}


def derive_preview_key(session_secret: bytes | bytearray) -> bytearray:
    """Derive the least-privilege preview key without retaining a transport secret."""

    if not isinstance(session_secret, (bytes, bytearray)) or len(session_secret) != 32:
        raise ValueError("preview session secret is invalid")
    return bytearray(hmac.new(bytes(session_secret), PREVIEW_KEY_DOMAIN, hashlib.sha256).digest())


def derive_duel_preview_ticket(
    session_secret: bytes | bytearray,
    *,
    attachment_ticket: str,
    participant_id: str,
) -> str:
    """Derive a distinct 43-character ingress ticket for one duel participant viewport."""

    if (
        not isinstance(session_secret, (bytes, bytearray))
        or len(session_secret) != 32
        or _TICKET.fullmatch(attachment_ticket) is None
        or participant_id not in ("participant_0", "participant_1")
    ):
        raise ValueError("duel preview ticket material is invalid")
    material = b"llm-controller/duel-preview-ticket/v1\x00" + attachment_ticket.encode(
        "ascii"
    ) + b"\x00" + participant_id.encode("ascii")
    digest = hmac.new(bytes(session_secret), material, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def derive_duel_broadcast_preview_ticket(
    session_secret: bytes | bytearray, *, attachment_ticket: str
) -> str:
    """Derive a one-leg RTS public-broadcast ticket distinct from both participant tickets."""

    if (
        not isinstance(session_secret, (bytes, bytearray))
        or len(session_secret) != 32
        or _TICKET.fullmatch(attachment_ticket) is None
    ):
        raise ValueError("broadcast preview ticket material is invalid")
    material = b"llm-controller/duel-broadcast-preview-ticket/v1\x00" + attachment_ticket.encode(
        "ascii"
    )
    digest = hmac.new(bytes(session_secret), material, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def derive_trio_preview_ticket(
    session_secret: bytes | bytearray,
    *,
    attachment_ticket: str,
    participant_id: str,
) -> str:
    """Derive one least-privilege ingress ticket for a scoped trio participant viewport."""

    if (
        not isinstance(session_secret, (bytes, bytearray))
        or len(session_secret) != 32
        or _TICKET.fullmatch(attachment_ticket) is None
        or participant_id not in ("participant_0", "participant_1", "participant_2")
    ):
        raise ValueError("trio preview ticket material is invalid")
    material = b"llm-controller/trio-preview-ticket/v1\x00" + attachment_ticket.encode(
        "ascii"
    ) + b"\x00" + participant_id.encode("ascii")
    digest = hmac.new(bytes(session_secret), material, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def preview_auth_tag(
    preview_key: bytes | bytearray,
    *,
    ticket: str,
    episode_id: str,
    sequence: int,
    jpeg: bytes,
) -> str:
    """Return the wire HMAC for a preview byte payload.

    The matching Godot publisher must sign exactly
    ``domain || ticket || NUL || episode_id || NUL || decimal-sequence || NUL || sha256(jpeg)``.
    No observation JSON, checkpoint, prompt, model output, or credential enters this material.
    """

    if (
        not isinstance(preview_key, (bytes, bytearray))
        or len(preview_key) != 32
        or _TICKET.fullmatch(ticket) is None
        or _EPISODE.fullmatch(episode_id) is None
        or isinstance(sequence, bool)
        or not isinstance(sequence, int)
        or sequence < 0
        or sequence > 9_007_199_254_740_991
        or not isinstance(jpeg, bytes)
    ):
        raise ValueError("preview authentication material is invalid")
    material = b"".join(
        (
            PREVIEW_FRAME_DOMAIN,
            ticket.encode("ascii"),
            b"\x00",
            episode_id.encode("ascii"),
            b"\x00",
            str(sequence).encode("ascii"),
            b"\x00",
            hashlib.sha256(jpeg).digest(),
        )
    )
    return hmac.new(bytes(preview_key), material, hashlib.sha256).hexdigest()


internal_preview_router = APIRouter(include_in_schema=False)


@internal_preview_router.websocket("/internal/embodiment/preview/{ticket}/stream")
async def stream_internal_preview(websocket: WebSocket, ticket: str) -> None:
    """Persistent signed Godot ingress; messages are sequence + HMAC + JPEG pixels only."""

    await websocket.accept()
    try:
        while True:
            payload = await websocket.receive_bytes()
            # Eight-byte unsigned sequence and raw SHA-256 HMAC precede the JPEG. This framing has
            # no room for prompts, observations, provider output, credentials, or hidden state.
            if len(payload) < 8 + 32 + 128 or len(payload) > 8 + 32 + MAX_PREVIEW_JPEG_BYTES:
                continue
            sequence = int.from_bytes(payload[:8], "big")
            ingress = getattr(websocket.app.state, "embodiment_preview_ingress", None)
            if isinstance(ingress, InternalParticipantPreviewIngress):
                await ingress.publish(
                    ticket=ticket,
                    content_type="image/jpeg",
                    sequence=str(sequence),
                    signature=payload[8:40].hex(),
                    jpeg=payload[40:],
                )
    except WebSocketDisconnect:
        pass


@internal_preview_router.post("/internal/embodiment/preview/{ticket}", status_code=204)
async def receive_internal_preview(request: Request, ticket: str) -> Response:
    """Accept a local Godot preview frame without exposing ingress diagnostics."""

    content_length = request.headers.get("content-length")
    if _content_length_exceeds_limit(content_length):
        return _empty_response()
    try:
        jpeg = await request.body()
    except Exception:
        return _empty_response()
    ingress = getattr(request.app.state, "embodiment_preview_ingress", None)
    if isinstance(ingress, InternalParticipantPreviewIngress):
        await ingress.publish(
            ticket=ticket,
            content_type=request.headers.get("content-type"),
            sequence=request.headers.get(PREVIEW_SEQUENCE_HEADER),
            signature=request.headers.get(PREVIEW_SIGNATURE_HEADER),
            jpeg=jpeg,
        )
    return _empty_response()


def _valid_preview_jpeg(value: object) -> bool:
    if not isinstance(value, bytes) or not 128 <= len(value) <= MAX_PREVIEW_JPEG_BYTES:
        return False
    return value.startswith(JPEG_SIGNATURE) and value.endswith(b"\xff\xd9")


def _parse_sequence(value: str | None) -> int | None:
    if not isinstance(value, str) or _SEQUENCE.fullmatch(value) is None:
        return None
    parsed = int(value)
    return parsed if parsed <= 9_007_199_254_740_991 else None


def _valid_signature(value: str | None) -> bool:
    return isinstance(value, str) and _HEX_TAG.fullmatch(value) is not None


def _content_length_exceeds_limit(value: str | None) -> bool:
    if value is None:
        return False
    if not value.isdecimal():
        return True
    return int(value) > MAX_PREVIEW_JPEG_BYTES


def _empty_response() -> Response:
    return Response(status_code=204, headers={"Cache-Control": "no-store"})


def _zero(value: bytearray) -> None:
    if value:
        value[:] = b"\x00" * len(value)
        value.clear()


__all__ = [
    "InternalParticipantPreviewIngress",
    "MAX_PREVIEW_JPEG_BYTES",
    "PREVIEW_FRAME_DOMAIN",
    "PREVIEW_KEY_DOMAIN",
    "PREVIEW_SEQUENCE_HEADER",
    "PREVIEW_SIGNATURE_HEADER",
    "SUPPORTED_PREVIEW_TASKS",
    "derive_preview_key",
    "derive_duel_preview_ticket",
    "derive_duel_broadcast_preview_ticket",
    "derive_trio_preview_ticket",
    "internal_preview_router",
    "preview_auth_tag",
]
