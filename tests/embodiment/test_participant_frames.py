import struct
import zlib

import pytest
from genesis_arena.embodiment.presentation.participant_frames import (
    ParticipantFrameStore,
    sanitize_participant_png,
)

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
