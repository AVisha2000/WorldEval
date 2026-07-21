from io import BytesIO

import pytest
from genesis_arena.embodiment.duel.participant_frames import (
    DuelBroadcastPreviewChannel,
    DuelParticipantFrameStore,
    DuelParticipantPreviewChannel,
)
from PIL import Image, PngImagePlugin


def _png(secret: str) -> bytes:
    image = Image.new("RGBA", (1280, 720), (31, 67, 101, 255))
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text("private", secret)
    output = BytesIO()
    image.save(output, format="PNG", pnginfo=metadata)
    return output.getvalue()


def _jpeg(secret: str) -> bytes:
    image = Image.new("RGB", (1280, 720), (31, 67, 101))
    output = BytesIO()
    image.save(output, format="JPEG", quality=82, comment=secret.encode())
    return output.getvalue()


def test_duel_frame_store_keeps_separate_pixel_only_participant_snapshots() -> None:
    store = DuelParticipantFrameStore()
    store.publish(0, "participant_0", 2, _png("prompt-alpha"))
    store.publish(0, "participant_1", 2, _png("credential-bravo"))

    alpha = store.snapshot("participant_0")
    bravo = store.snapshot("participant_1")
    assert alpha is not None and bravo is not None
    assert alpha.participant_id == "participant_0"
    assert bravo.participant_id == "participant_1"
    assert b"prompt-alpha" not in alpha.png
    assert b"credential-bravo" not in bravo.png
    assert alpha.sha256 == bravo.sha256
    with Image.open(BytesIO(alpha.png)) as image:
        assert image.size == (1280, 720)
        assert image.info == {}


def test_duel_frame_store_accepts_leg_reset_but_rejects_stale_or_unknown_identity() -> None:
    store = DuelParticipantFrameStore()
    pixels = _png("removed")
    store.publish(0, "participant_0", 8, pixels)
    store.publish(1, "participant_0", 0, pixels)
    assert store.snapshot("participant_0").leg_index == 1
    with pytest.raises(ValueError):
        store.publish(0, "participant_0", 9, pixels)
    with pytest.raises(ValueError):
        store.publish(1, "spectator", 1, pixels)


@pytest.mark.asyncio
async def test_duel_live_preview_is_pixel_sanitized_and_newest_only_per_participant() -> None:
    channel = DuelParticipantPreviewChannel()
    token, queue, initial = channel.subscribe("participant_1")
    assert initial is None and queue.maxsize == 1
    assert await channel.publish(0, "participant_1", 1, _jpeg("private-one"))
    assert await channel.publish(0, "participant_1", 2, _jpeg("private-two"))
    newest = queue.get_nowait()
    assert newest.participant_id == "participant_1"
    assert newest.sequence == 2
    assert b"private-two" not in newest.jpeg
    assert not await channel.publish(0, "participant_1", 2, _jpeg("stale"))
    channel.unsubscribe("participant_1", token)


@pytest.mark.asyncio
async def test_rts_broadcast_preview_is_separate_sanitized_and_newest_only() -> None:
    channel = DuelBroadcastPreviewChannel()
    token, queue, initial = channel.subscribe()
    assert initial is None and queue.maxsize == 1
    assert await channel.publish(0, 1, _jpeg("private-player-observation"))
    assert await channel.publish(0, 2, _jpeg("credential-never-in-broadcast"))
    newest = queue.get_nowait()
    assert newest.leg_index == 0 and newest.sequence == 2
    assert b"credential-never-in-broadcast" not in newest.jpeg
    assert not hasattr(newest, "participant_id")
    assert not await channel.publish(0, 2, _jpeg("stale"))
    channel.unsubscribe(token)
