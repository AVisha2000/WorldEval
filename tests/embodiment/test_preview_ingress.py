import asyncio
from io import BytesIO

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.presentation.preview_ingress import (
    PREVIEW_SEQUENCE_HEADER,
    PREVIEW_SIGNATURE_HEADER,
    InternalParticipantPreviewIngress,
    derive_duel_broadcast_preview_ticket,
    derive_duel_preview_ticket,
    derive_preview_key,
    derive_trio_preview_ticket,
    internal_preview_router,
    preview_auth_tag,
)
from PIL import Image

_TICKET = "T" * 43
_EPISODE_ID = "ep_preview_ingress"


def _segment(marker: int, data: bytes) -> bytes:
    return b"\xff" + bytes((marker,)) + (len(data) + 2).to_bytes(2, "big") + data


def _jpeg(*, metadata: bytes = b"") -> bytes:
    image = Image.new("RGB", (1280, 720), (19, 73, 131))
    encoded = BytesIO()
    image.save(encoded, format="JPEG", quality=82, subsampling="4:2:0")
    value = encoded.getvalue()
    app = _segment(0xE1, metadata) if metadata else b""
    return value[:2] + app + value[2:]


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
    frame = _jpeg(metadata=b"still-sanitized-by-the-separate-frame-pump")
    key = derive_preview_key(session_secret)
    signature = preview_auth_tag(
        key,
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        sequence=7,
        jpeg=frame,
    )

    assert await ingress.publish(
        ticket=_TICKET,
        content_type="image/jpeg",
        sequence="7",
        signature=signature,
        jpeg=frame,
    )
    assert received == [("participant_0", 7, frame)]
    assert not await ingress.publish(
        ticket=_TICKET,
        content_type="image/jpeg",
        sequence="7",
        signature=signature,
        jpeg=frame,
    )
    assert not await ingress.publish(
        ticket=_TICKET,
        content_type="image/jpeg",
        sequence="8",
        signature="0" * 64,
        jpeg=frame,
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
    frame = _jpeg(metadata=private_marker)
    key = derive_preview_key(session_secret)
    signature = preview_auth_tag(
        key,
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        sequence=1,
        jpeg=frame,
    )
    headers = {
        "content-type": "image/jpeg",
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


def test_persistent_internal_websocket_accepts_signed_binary_pixels_only() -> None:
    ingress = InternalParticipantPreviewIngress()
    app = FastAPI()
    app.state.embodiment_preview_ingress = ingress
    app.include_router(internal_preview_router)
    received: list[tuple[str, int, bytes]] = []
    secret = bytearray(range(32))

    async def sink(participant_id: str, sequence: int, jpeg: bytes) -> bool:
        received.append((participant_id, sequence, jpeg))
        return True

    ingress.register(
        ticket=_TICKET,
        episode_id=_EPISODE_ID,
        task_id="construction-v0",
        session_secret=secret,
        sink=sink,
    )
    key = derive_preview_key(secret)
    with TestClient(app) as client:
        with client.websocket_connect(
            f"/internal/embodiment/preview/{_TICKET}/stream"
        ) as websocket:
            for sequence in (1, 2):
                frame = _jpeg(metadata=f"stripped-{sequence}".encode())
                tag = preview_auth_tag(
                    key,
                    ticket=_TICKET,
                    episode_id=_EPISODE_ID,
                    sequence=sequence,
                    jpeg=frame,
                )
                websocket.send_bytes(
                    sequence.to_bytes(8, "big") + bytes.fromhex(tag) + frame
                )

    assert [item[1] for item in received] == [1, 2]
    assert all(item[0] == "participant_0" and item[2].startswith(b"\xff\xd8") for item in received)
    key[:] = b"\x00" * len(key)


async def test_ingress_rejects_non_jpeg_payload_without_calling_sink() -> None:
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
        jpeg=payload,
    )

    assert not await ingress.publish(
        ticket=_TICKET,
        content_type="image/jpeg",
        sequence="0",
        signature=signature,
        jpeg=payload,
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


async def test_duel_preview_tickets_and_participant_binding_are_separate() -> None:
    secret = bytearray(range(32))
    alpha = derive_duel_preview_ticket(
        secret, attachment_ticket="A" * 43, participant_id="participant_0"
    )
    bravo = derive_duel_preview_ticket(
        secret, attachment_ticket="A" * 43, participant_id="participant_1"
    )
    assert alpha == "vwRjO9yau5Bv8wOwgsBf1Mv_XX0dJaCYnfZ7HhtZJ2s"
    assert bravo == "gictFg52fKzb6rlc8AdqTQ-aW8wMOfnfsygu_LbYGs4"
    assert alpha != bravo

    ingress = InternalParticipantPreviewIngress()
    received = []

    async def sink(participant_id, sequence, jpeg):
        received.append((participant_id, sequence, jpeg))
        return True

    ingress.register(
        ticket=bravo,
        episode_id=_EPISODE_ID,
        task_id="central-relay-v0",
        session_secret=secret,
        sink=sink,
        participant_id="participant_1",
    )
    frame = _jpeg()
    key = derive_preview_key(secret)
    signature = preview_auth_tag(
        key, ticket=bravo, episode_id=_EPISODE_ID, sequence=1, jpeg=frame
    )
    assert await ingress.publish(
        ticket=bravo,
        content_type="image/jpeg",
        sequence="1",
        signature=signature,
        jpeg=frame,
    )
    assert received == [("participant_1", 1, frame)]


async def test_rts_broadcast_ticket_is_distinct_and_cannot_register_for_other_tasks() -> None:
    secret = bytearray(range(32))
    ticket = derive_duel_broadcast_preview_ticket(secret, attachment_ticket="A" * 43)
    assert ticket != derive_duel_preview_ticket(
        secret, attachment_ticket="A" * 43, participant_id="participant_0"
    )
    ingress = InternalParticipantPreviewIngress()
    received: list[str] = []

    async def sink(participant_id: str, _sequence: int, _jpeg: bytes) -> bool:
        received.append(participant_id)
        return True

    ingress.register(
        ticket=ticket,
        episode_id=_EPISODE_ID,
        task_id="rts-skirmish-v0",
        session_secret=secret,
        sink=sink,
        participant_id="broadcast",
    )
    frame = _jpeg()
    signature = preview_auth_tag(
        derive_preview_key(secret), ticket=ticket, episode_id=_EPISODE_ID, sequence=1, jpeg=frame
    )
    assert await ingress.publish(
        ticket=ticket, content_type="image/jpeg", sequence="1", signature=signature, jpeg=frame
    )
    assert received == ["broadcast"]
    with pytest.raises(ValueError, match="participant"):
        ingress.register(
            ticket="C" * 43,
            episode_id=_EPISODE_ID,
            task_id="duo-resource-relay-v0",
            session_secret=secret,
            sink=sink,
            participant_id="broadcast",
        )


async def test_trio_preview_tickets_bind_all_three_participants() -> None:
    secret = bytearray(range(32))
    attachment = "B" * 43
    tickets = [
        derive_trio_preview_ticket(
            secret, attachment_ticket=attachment, participant_id=participant_id
        )
        for participant_id in ("participant_0", "participant_1", "participant_2")
    ]
    assert len(set(tickets)) == 3

    ingress = InternalParticipantPreviewIngress()
    received: list[tuple[str, int]] = []

    async def sink(participant_id: str, sequence: int, _jpeg: bytes) -> bool:
        received.append((participant_id, sequence))
        return True

    for participant_id, ticket in zip(
        ("participant_0", "participant_1", "participant_2"), tickets
    ):
        ingress.register(
            ticket=ticket,
            episode_id=_EPISODE_ID,
            task_id="trio-free-for-all-v0",
            session_secret=secret,
            sink=sink,
            participant_id=participant_id,
        )
        frame = _jpeg()
        signature = preview_auth_tag(
            derive_preview_key(secret),
            ticket=ticket,
            episode_id=_EPISODE_ID,
            sequence=2,
            jpeg=frame,
        )
        assert await ingress.publish(
            ticket=ticket,
            content_type="image/jpeg",
            sequence="2",
            signature=signature,
            jpeg=frame,
        )
    assert received == [
        ("participant_0", 2),
        ("participant_1", 2),
        ("participant_2", 2),
    ]


@pytest.mark.parametrize(
    ("task_id", "participant_id"),
    (
        ("construction-v0", "participant_1"),
        ("construction-v0", "participant_2"),
        ("central-relay-v0", "participant_2"),
        ("duo-checkpoint-race-v0", "participant_2"),
    ),
)
def test_preview_registration_rejects_participants_outside_task_arity(
    task_id: str, participant_id: str
) -> None:
    ingress = InternalParticipantPreviewIngress()

    async def sink(_participant_id: str, _sequence: int, _jpeg: bytes) -> bool:
        return True

    with pytest.raises(ValueError, match="participant is invalid"):
        ingress.register(
            ticket=_TICKET,
            episode_id=_EPISODE_ID,
            task_id=task_id,
            session_secret=bytearray(range(32)),
            sink=sink,
            participant_id=participant_id,
        )
