import asyncio
import struct
import zlib

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.presentation.preview_ingress import (
    PREVIEW_SEQUENCE_HEADER,
    PREVIEW_SIGNATURE_HEADER,
    InternalParticipantPreviewIngress,
    derive_preview_key,
    internal_preview_router,
    preview_auth_tag,
)

_TICKET = "T" * 43
_EPISODE_ID = "ep_preview_ingress"


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def _png(*, metadata: bytes = b"") -> bytes:
    ihdr = struct.pack(">IIBBBBB", 1280, 720, 8, 6, 0, 0, 0)
    scanlines = b"".join(b"\x00" + b"\x00" * (1280 * 4) for _ in range(720))
    chunks = [_chunk(b"IHDR", ihdr)]
    if metadata:
        chunks.append(_chunk(b"tEXt", b"private\x00" + metadata))
    chunks.extend((_chunk(b"IDAT", zlib.compress(scanlines)), _chunk(b"IEND", b"")))
    return b"\x89PNG\r\n\x1a\n" + b"".join(chunks)


async def test_ingress_authenticates_frames_and_drops_stale_sequences() -> None:
    ingress = InternalParticipantPreviewIngress()
    session_secret = bytearray(range(32))
    received: list[tuple[str, int, bytes]] = []

    async def sink(participant_id: str, observation_seq: int, png: bytes) -> bool:
        received.append((participant_id, observation_seq, png))
        return True

    ingress.register(
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        task_id="construction-v0",
        session_secret=session_secret,
        sink=sink,
    )
    frame = _png(metadata=b"still-sanitized-by-the-separate-frame-pump")
    key = derive_preview_key(session_secret)
    signature = preview_auth_tag(
        key,
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        sequence=7,
        png=frame,
    )

    assert await ingress.publish(
        ticket=_TICKET,
        content_type="image/png",
        sequence="7",
        signature=signature,
        png=frame,
    )
    assert received == [("participant_0", 7, frame)]
    assert not await ingress.publish(
        ticket=_TICKET,
        content_type="image/png",
        sequence="7",
        signature=signature,
        png=frame,
    )
    assert not await ingress.publish(
        ticket=_TICKET,
        content_type="image/png",
        sequence="8",
        signature="0" * 64,
        png=frame,
    )
    assert ingress.diagnostics() == {"registrations": 1}

    ingress.unregister(_TICKET)
    key[:] = b"\x00" * len(key)
    assert ingress.diagnostics() == {"registrations": 0}


def test_internal_endpoint_returns_no_diagnostics_or_secret_reflection() -> None:
    ingress = InternalParticipantPreviewIngress()
    app = FastAPI()
    app.state.embodiment_preview_ingress = ingress
    app.include_router(internal_preview_router)
    received: list[tuple[str, int, bytes]] = []
    session_secret = bytearray(range(32))
    private_marker = b"credential-and-hidden-state-must-not-leak"

    async def sink(participant_id: str, observation_seq: int, png: bytes) -> bool:
        received.append((participant_id, observation_seq, png))
        return True

    ingress.register(
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        task_id="construction-v0",
        session_secret=session_secret,
        sink=sink,
    )
    frame = _png(metadata=private_marker)
    key = derive_preview_key(session_secret)
    signature = preview_auth_tag(
        key,
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        sequence=1,
        png=frame,
    )
    headers = {
        "content-type": "image/png",
        PREVIEW_SEQUENCE_HEADER: "1",
        PREVIEW_SIGNATURE_HEADER: signature,
    }

    with TestClient(app) as client:
        accepted = client.post(
            f"/internal/embodiment/preview/{_TICKET}", content=frame, headers=headers
        )
        rejected = client.post(
            f"/internal/embodiment/preview/{_TICKET}",
            content=frame,
            headers={**headers, PREVIEW_SEQUENCE_HEADER: "2", PREVIEW_SIGNATURE_HEADER: "0" * 64},
        )

    assert accepted.status_code == rejected.status_code == 204
    assert accepted.content == rejected.content == b""
    assert accepted.headers["cache-control"] == rejected.headers["cache-control"] == "no-store"
    assert private_marker.decode("ascii") not in accepted.text + rejected.text
    assert signature not in accepted.text + rejected.text
    assert received == [("participant_0", 1, frame)]
    key[:] = b"\x00" * len(key)


async def test_ingress_rejects_non_png_payload_without_calling_sink() -> None:
    ingress = InternalParticipantPreviewIngress()
    session_secret = bytearray(range(32))
    called = asyncio.Event()

    async def sink(_participant_id: str, _observation_seq: int, _png: bytes) -> bool:
        called.set()
        return True

    ingress.register(
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        task_id="construction-v0",
        session_secret=session_secret,
        sink=sink,
    )
    payload = b"not-a-png"
    key = derive_preview_key(session_secret)
    signature = preview_auth_tag(
        key,
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        sequence=0,
        png=payload,
    )

    assert not await ingress.publish(
        ticket=_TICKET,
        content_type="image/png",
        sequence="0",
        signature=signature,
        png=payload,
    )
    assert not called.is_set()
    key[:] = b"\x00" * len(key)


@pytest.mark.parametrize(
    "task_id", ("orientation-v0", "interaction-v0", "construction-v0", "neutral-encounter-v0")
)
def test_ingress_accepts_every_solo_curriculum_task(task_id: str) -> None:
    ingress = InternalParticipantPreviewIngress()

    async def sink(_participant_id: str, _observation_seq: int, _png: bytes) -> bool:
        return True

    ingress.register(
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        task_id=task_id,
        session_secret=bytearray(range(32)),
        sink=sink,
    )
    ingress.unregister(_TICKET)


def test_ingress_rejects_unknown_task() -> None:
    ingress = InternalParticipantPreviewIngress()

    async def sink(_participant_id: str, _observation_seq: int, _png: bytes) -> bool:
        return True

    with pytest.raises(ValueError, match="task is unsupported"):
        ingress.register(
            ticket=_TICKET,
            episode_id=_EPISODE_ID,
            task_id="unsupported-v0",
            session_secret=bytearray(range(32)),
            sink=sink,
        )
