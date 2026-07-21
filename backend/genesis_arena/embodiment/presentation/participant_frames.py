"""In-memory, pixel-only participant camera frames for the local dashboard."""

from __future__ import annotations

import asyncio
import hashlib
import struct
import zlib
from dataclasses import dataclass

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
FRAME_WIDTH = 1280
FRAME_HEIGHT = 720
_RGBA_SCANLINE_BYTES = FRAME_WIDTH * 4 + 1
_MAX_SOURCE_BYTES = 8 * 1024 * 1024


@dataclass(frozen=True)
class ParticipantFrameSnapshot:
    observation_seq: int
    png: bytes
    sha256: str


class ParticipantFrameStore:
    """Retain only the newest sanitized active-participant frame in memory."""

    def __init__(self) -> None:
        self._snapshot: ParticipantFrameSnapshot | None = None

    def publish(self, participant_id: str, observation_seq: int, png: bytes) -> None:
        self.publish_sanitized(participant_id, observation_seq, sanitize_participant_png(png))

    def publish_sanitized(self, participant_id: str, observation_seq: int, png: bytes) -> None:
        """Publish pixels already sanitized off the authority event loop."""
        if participant_id != "participant_0":
            raise ValueError("only the active solo participant frame may be published")
        if (
            isinstance(observation_seq, bool)
            or not isinstance(observation_seq, int)
            or observation_seq < 0
        ):
            raise ValueError("observation sequence is invalid")
        if self._snapshot is not None and observation_seq < self._snapshot.observation_seq:
            raise ValueError("participant frame sequence moved backwards")
        if not isinstance(png, bytes):
            raise TypeError("participant frame pixels must be immutable bytes")
        self._snapshot = ParticipantFrameSnapshot(
            observation_seq=observation_seq,
            png=png,
            sha256=hashlib.sha256(png).hexdigest(),
        )

    def snapshot(self) -> ParticipantFrameSnapshot | None:
        return self._snapshot

    def close(self) -> None:
        self._snapshot = None


class ParticipantPreviewHub:
    """Newest-frame-only local fan-out; it carries participant pixels only."""

    def __init__(self) -> None:
        self._subscribers: dict[int, asyncio.Queue[ParticipantFrameSnapshot]] = {}
        self._next_id = 0

    def publish(self, snapshot: ParticipantFrameSnapshot) -> None:
        for queue in tuple(self._subscribers.values()):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            queue.put_nowait(snapshot)

    def subscribe(self) -> tuple[int, asyncio.Queue[ParticipantFrameSnapshot]]:
        token = self._next_id
        self._next_id += 1
        queue: asyncio.Queue[ParticipantFrameSnapshot] = asyncio.Queue(maxsize=1)
        self._subscribers[token] = queue
        return token, queue

    def unsubscribe(self, token: int) -> None:
        self._subscribers.pop(token, None)

    def close(self) -> None:
        self._subscribers.clear()


def sanitize_participant_png(value: bytes) -> bytes:
    """Rebuild a Godot RGBA PNG from decoded scanlines, discarding all metadata."""

    if not isinstance(value, bytes) or not 32 <= len(value) <= _MAX_SOURCE_BYTES:
        raise ValueError("participant frame PNG size is invalid")
    if not value.startswith(PNG_SIGNATURE):
        raise ValueError("participant frame is not a PNG")

    offset = len(PNG_SIGNATURE)
    ihdr: bytes | None = None
    compressed_parts: list[bytes] = []
    ended = False
    while offset < len(value):
        if offset + 12 > len(value):
            raise ValueError("participant frame PNG is truncated")
        length = struct.unpack(">I", value[offset : offset + 4])[0]
        chunk_type = value[offset + 4 : offset + 8]
        chunk_end = offset + 12 + length
        if chunk_end > len(value):
            raise ValueError("participant frame PNG chunk is truncated")
        data = value[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", value[offset + 8 + length : chunk_end])[0]
        if zlib.crc32(chunk_type + data) & 0xFFFFFFFF != expected_crc:
            raise ValueError("participant frame PNG checksum is invalid")
        if chunk_type == b"IHDR":
            if ihdr is not None or offset != len(PNG_SIGNATURE) or length != 13:
                raise ValueError("participant frame PNG header is invalid")
            ihdr = data
        elif chunk_type == b"IDAT":
            if ihdr is None or ended:
                raise ValueError("participant frame PNG data order is invalid")
            compressed_parts.append(data)
        elif chunk_type == b"IEND":
            if length != 0 or ihdr is None or not compressed_parts:
                raise ValueError("participant frame PNG ending is invalid")
            ended = True
            offset = chunk_end
            break
        elif chunk_type[:1].isupper():
            raise ValueError("participant frame PNG contains an unsupported critical chunk")
        offset = chunk_end

    if not ended or offset != len(value) or ihdr is None:
        raise ValueError("participant frame PNG has trailing or incomplete data")
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", ihdr
    )
    if (
        (width, height) != (FRAME_WIDTH, FRAME_HEIGHT)
        or bit_depth != 8
        or color_type != 6
        or compression != 0
        or filtering != 0
        or interlace != 0
    ):
        raise ValueError("participant frame PNG format is unsupported")

    decompressor = zlib.decompressobj()
    # Verify the compressed pixel stream, but retain its validated IDAT data instead of
    # recompressing 3.5 MiB of scanlines for every presentation frame.  Rebuilding the PNG from
    # only IHDR/IDAT/IEND still strips every source metadata chunk, while avoiding a synchronous
    # zlib deflate on the real-time preview path.
    compressed = b"".join(compressed_parts)
    scanlines = decompressor.decompress(compressed, _RGBA_SCANLINE_BYTES * FRAME_HEIGHT + 1)
    if (
        not decompressor.eof
        or decompressor.unused_data
        or decompressor.unconsumed_tail
        or len(scanlines) != _RGBA_SCANLINE_BYTES * FRAME_HEIGHT
    ):
        raise ValueError("participant frame PNG pixel stream is invalid")

    return b"".join(
        (
            PNG_SIGNATURE,
            _chunk(b"IHDR", ihdr),
            _chunk(b"IDAT", compressed),
            _chunk(b"IEND", b""),
        )
    )


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


__all__ = [
    "FRAME_HEIGHT",
    "FRAME_WIDTH",
    "PNG_SIGNATURE",
    "ParticipantFrameSnapshot",
    "ParticipantFrameStore",
    "sanitize_participant_png",
]
