import asyncio
import struct
import zlib
from io import BytesIO

import pytest
from genesis_arena.embodiment.presentation.participant_frames import (
    ParticipantFrameStore,
    ParticipantLivePreviewHub,
    ParticipantLivePreviewStore,
    ParticipantPreviewHub,
    sanitize_participant_jpeg,
    sanitize_participant_png,
)
from PIL import Image

_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def _png(*, ancillary: bytes = b"", compressed_suffix: bytes = b"") -> bytes:
    ihdr = struct.pack(">IIBBBBB", 1280, 720, 8, 6, 0, 0, 0)
    scanlines = b"".join(b"\x00" + b"\x00" * (1280 * 4) for _ in range(720))
    chunks = [_chunk(b"IHDR", ihdr)]
    if ancillary:
        chunks.append(_chunk(b"tEXt", b"private\x00" + ancillary))
    chunks.extend(
        (
            _chunk(b"IDAT", zlib.compress(scanlines) + compressed_suffix),
            _chunk(b"IEND", b""),
        )
    )
    return _SIGNATURE + b"".join(chunks)


def _jpeg(
    *,
    metadata: bytes = b"",
    extension: bytes = b"",
    dqt_secret: bytes = b"",
    width: int = 1280,
    height: int = 720,
) -> bytes:
    def segment(marker: int, data: bytes) -> bytes:
        return b"\xff" + bytes((marker,)) + (len(data) + 2).to_bytes(2, "big") + data

    image = Image.new("RGB", (width, height), (37, 91, 143))
    encoded = BytesIO()
    image.save(
        encoded,
        format="JPEG",
        quality=82,
        subsampling="4:2:0",
        optimize=False,
        progressive=False,
    )
    injected = b""
    if metadata:
        injected += segment(0xE1, metadata)
    if extension:
        injected += segment(0xF0, extension)
    if dqt_secret:
        assert len(dqt_secret) <= 64 and b"\x00" not in dqt_secret
        table = dqt_secret + b"\x01" * (64 - len(dqt_secret))
        injected += segment(0xDB, b"\x00" + table)
    value = encoded.getvalue()
    return value[:2] + injected + value[2:]


def _malformed_entropy_jpeg() -> bytes:
    value = _jpeg()
    scan = value.index(b"\xff\xda")
    scan_length = int.from_bytes(value[scan + 2 : scan + 4], "big")
    entropy = scan + 2 + scan_length
    # An unstuffed reserved marker in entropy-coded bytes is not pixel data and must not be
    # recovered or copied through by the sanitizer.
    return value[:entropy] + b"\xff\xf0\x00\x08broken" + b"\xff\xd9"


def test_participant_frame_removes_all_non_pixel_chunks() -> None:
    secret = b"prompt raw-output credential spectator-state"
    sanitized = sanitize_participant_png(_png(ancillary=secret))

    assert sanitized.startswith(_SIGNATURE)
    assert secret not in sanitized
    assert b"tEXt" not in sanitized
    assert sanitized.count(b"IHDR") == sanitized.count(b"IDAT") == sanitized.count(b"IEND") == 1


def test_participant_frame_rejects_hidden_trailing_compressed_payload() -> None:
    with pytest.raises(ValueError, match="pixel stream"):
        sanitize_participant_png(_png(compressed_suffix=b"hidden-after-zlib-stream"))


def test_participant_frame_store_is_solo_scoped_and_monotonic() -> None:
    store = ParticipantFrameStore()
    store.publish("participant_0", 2, _png())

    with pytest.raises(ValueError, match="active solo participant"):
        store.publish("spectator", 3, _png())
    with pytest.raises(ValueError, match="backwards"):
        store.publish("participant_0", 1, _png())

    assert store.snapshot() is not None
    assert store.snapshot().observation_seq == 2


def test_preview_hub_keeps_only_the_newest_sanitized_participant_frame() -> None:
    store = ParticipantFrameStore()
    hub = ParticipantPreviewHub()
    _, queue = hub.subscribe()
    store.publish("participant_0", 1, _png())
    assert store.snapshot() is not None
    hub.publish(store.snapshot())
    store.publish("participant_0", 2, _png())
    hub.publish(store.snapshot())

    received = queue.get_nowait()
    assert received.observation_seq == 2
    with pytest.raises(asyncio.QueueEmpty):
        queue.get_nowait()


def test_live_preview_strips_all_jpeg_metadata_and_checks_dimensions() -> None:
    private = b"prompt raw-output credential spectator-state"
    sanitized = sanitize_participant_jpeg(_jpeg(metadata=private))

    assert sanitized.startswith(b"\xff\xd8") and sanitized.endswith(b"\xff\xd9")
    assert private not in sanitized
    assert b"\xff\xe1" not in sanitized
    with pytest.raises(ValueError, match="dimensions"):
        sanitize_participant_jpeg(_jpeg(width=640, height=360))
    with pytest.raises(ValueError, match="ending"):
        sanitize_participant_jpeg(_jpeg() + b"hidden-trailing-data")


def test_live_preview_rejects_reserved_jpeg_extension_payloads() -> None:
    secret = b"credential prompt raw-model-output hidden-spectator-state"
    encoded = _jpeg(extension=secret)

    with pytest.raises(ValueError, match="coding marker is unsupported"):
        sanitize_participant_jpeg(encoded)
    # Regression guard: unlike APP/COM metadata, an unknown extension is never copied through to
    # a rebuilt browser frame where its arbitrary payload could survive byte-for-byte.
    assert secret in encoded


def test_live_preview_rebuild_does_not_copy_dqt_payload_or_malformed_entropy() -> None:
    secret = b"DQT-credential-prompt-hidden-state"
    encoded = _jpeg(dqt_secret=secret)
    sanitized = sanitize_participant_jpeg(encoded)

    assert secret in encoded
    assert secret not in sanitized
    with Image.open(BytesIO(sanitized)) as decoded:
        decoded.load()
        assert decoded.size == (1280, 720)
        assert decoded.mode == "RGB"
    with pytest.raises(ValueError):
        sanitize_participant_jpeg(_malformed_entropy_jpeg())


def test_live_preview_store_and_hub_keep_only_newest_jpeg() -> None:
    store = ParticipantLivePreviewStore()
    hub = ParticipantLivePreviewHub()
    _, queue = hub.subscribe()
    store.publish("participant_0", 1, _jpeg())
    assert store.snapshot() is not None
    hub.publish(store.snapshot())
    store.publish("participant_0", 2, _jpeg())
    hub.publish(store.snapshot())

    received = queue.get_nowait()
    assert received.sequence == 2
    assert received.jpeg.startswith(b"\xff\xd8")
    assert queue.maxsize == 1
    with pytest.raises(asyncio.QueueEmpty):
        queue.get_nowait()
    with pytest.raises(ValueError, match="not newer"):
        store.publish("participant_0", 2, _jpeg())
