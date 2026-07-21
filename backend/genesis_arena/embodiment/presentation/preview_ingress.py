"""Authenticated, best-effort ingress for local participant-preview pixels.

This module deliberately lives outside the managed authority transport.  Frames accepted here are
presentation-only: they cannot influence a decision window, checkpoint hash, score, provider
request, or replay.  The browser-facing websocket continues to receive only sanitized PNG bytes
from :class:`EpisodeService`'s newest-frame pump.
"""

from __future__ import annotations

import hashlib
import hmac
import re
from dataclasses import dataclass, field
from typing import Awaitable, Callable, Optional

from fastapi import APIRouter, Request, Response

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PREVIEW_KEY_DOMAIN = b"llm-controller/preview-key/v1\x00"
PREVIEW_FRAME_DOMAIN = b"llm-controller/preview-frame/v1\x00"
PREVIEW_SEQUENCE_HEADER = "x-worldarena-preview-sequence"
PREVIEW_SIGNATURE_HEADER = "x-worldarena-preview-auth"
MAX_PREVIEW_PNG_BYTES = 8 * 1024 * 1024
SUPPORTED_PREVIEW_TASKS = frozenset(
    ("orientation-v0", "interaction-v0", "construction-v0", "neutral-encounter-v0")
)

_TICKET = re.compile(r"^[A-Za-z0-9_-]{43}$")
_EPISODE = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_SEQUENCE = re.compile(r"^(?:0|[1-9][0-9]{0,15})$")
_HEX_TAG = re.compile(r"^[0-9a-f]{64}$")

PreviewSink = Callable[[str, int, bytes], Awaitable[Optional[bool]]]


@dataclass
class _PreviewRegistration:
    episode_id: str
    key: bytearray = field(repr=False)
    sink: PreviewSink = field(repr=False)
    last_sequence: int = -1


class InternalParticipantPreviewIngress:
    """One-process, ticket-scoped ingress for unscored solo camera pixels.

    A domain-separated key is retained instead of the transport secret.  The endpoint returns
    the same empty response for acceptance and rejection so it does not become an episode or
    credential oracle.  Full PNG sanitization occurs in the existing asynchronous frame pump;
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
    ) -> None:
        if _TICKET.fullmatch(ticket) is None or _EPISODE.fullmatch(episode_id) is None:
            raise ValueError("preview registration identity is invalid")
        if task_id not in SUPPORTED_PREVIEW_TASKS:
            raise ValueError("preview registration task is unsupported")
        if not callable(sink):
            raise TypeError("preview registration sink is invalid")
        key = derive_preview_key(session_secret)
        if ticket in self._registrations:
            _zero(key)
            raise ValueError("preview registration ticket is already used")
        self._registrations[ticket] = _PreviewRegistration(
            episode_id=episode_id,
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
        png: bytes,
    ) -> bool:
        """Accept one signed, newest-only frame without surfacing an error to its caller."""

        registration = self._registrations.get(ticket)
        parsed_sequence = _parse_sequence(sequence)
        if (
            registration is None
            or content_type != "image/png"
            or parsed_sequence is None
            or not _valid_preview_png(png)
            or not _valid_signature(signature)
        ):
            return False
        expected = preview_auth_tag(
            registration.key,
            ticket=ticket,
            episode_id=registration.episode_id,
            sequence=parsed_sequence,
            png=png,
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
            delivered = await registration.sink("participant_0", parsed_sequence, png)
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


def preview_auth_tag(
    preview_key: bytes | bytearray,
    *,
    ticket: str,
    episode_id: str,
    sequence: int,
    png: bytes,
) -> str:
    """Return the wire HMAC for a preview byte payload.

    The matching Godot publisher must sign exactly
    ``domain || ticket || NUL || episode_id || NUL || decimal-sequence || NUL || sha256(png)``.
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
        or not isinstance(png, bytes)
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
            hashlib.sha256(png).digest(),
        )
    )
    return hmac.new(bytes(preview_key), material, hashlib.sha256).hexdigest()


internal_preview_router = APIRouter(include_in_schema=False)


@internal_preview_router.post("/internal/embodiment/preview/{ticket}", status_code=204)
async def receive_internal_preview(request: Request, ticket: str) -> Response:
    """Accept a local Godot preview frame without exposing ingress diagnostics."""

    content_length = request.headers.get("content-length")
    if _content_length_exceeds_limit(content_length):
        return _empty_response()
    try:
        png = await request.body()
    except Exception:
        return _empty_response()
    ingress = getattr(request.app.state, "embodiment_preview_ingress", None)
    if isinstance(ingress, InternalParticipantPreviewIngress):
        await ingress.publish(
            ticket=ticket,
            content_type=request.headers.get("content-type"),
            sequence=request.headers.get(PREVIEW_SEQUENCE_HEADER),
            signature=request.headers.get(PREVIEW_SIGNATURE_HEADER),
            png=png,
        )
    return _empty_response()


def _valid_preview_png(value: object) -> bool:
    if not isinstance(value, bytes) or not 24 <= len(value) <= MAX_PREVIEW_PNG_BYTES:
        return False
    if value[:8] != PNG_SIGNATURE or value[12:16] != b"IHDR":
        return False
    return (
        int.from_bytes(value[16:20], "big") == 1280
        and int.from_bytes(value[20:24], "big") == 720
    )


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
    return int(value) > MAX_PREVIEW_PNG_BYTES


def _empty_response() -> Response:
    return Response(status_code=204, headers={"Cache-Control": "no-store"})


def _zero(value: bytearray) -> None:
    if value:
        value[:] = b"\x00" * len(value)
        value.clear()


__all__ = [
    "InternalParticipantPreviewIngress",
    "MAX_PREVIEW_PNG_BYTES",
    "PREVIEW_FRAME_DOMAIN",
    "PREVIEW_KEY_DOMAIN",
    "PREVIEW_SEQUENCE_HEADER",
    "PREVIEW_SIGNATURE_HEADER",
    "SUPPORTED_PREVIEW_TASKS",
    "derive_preview_key",
    "internal_preview_router",
    "preview_auth_tag",
]
