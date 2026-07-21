"""Episode-only controller scratchpad with an exact UTF-8 byte budget."""

from __future__ import annotations

import unicodedata

MAX_SCRATCHPAD_BYTES = 2048


class ScratchpadError(ValueError):
    """Scratchpad content or lifecycle is invalid."""


class EpisodeScratchpad:
    """Mutable working memory owned by Python and erased at the episode boundary."""

    __slots__ = ("_closed", "_value")

    def __init__(self) -> None:
        self._value = bytearray()
        self._closed = False

    def __repr__(self) -> str:
        return f"EpisodeScratchpad(bytes={len(self._value)}, closed={self._closed})"

    def set(self, value: str) -> None:
        if self._closed:
            raise ScratchpadError("scratchpad is closed")
        if not isinstance(value, str):
            raise TypeError("scratchpad value must be a string")
        if unicodedata.normalize("NFC", value) != value:
            raise ScratchpadError("scratchpad must be NFC-normalized")
        encoded = value.encode("utf-8")
        if len(encoded) > MAX_SCRATCHPAD_BYTES:
            raise ScratchpadError("scratchpad exceeds 2048 UTF-8 bytes")
        self._erase()
        self._value.extend(encoded)

    @property
    def text(self) -> str:
        if self._closed:
            raise ScratchpadError("scratchpad is closed")
        return self._value.decode("utf-8", errors="strict")

    @property
    def utf8(self) -> bytes:
        if self._closed:
            raise ScratchpadError("scratchpad is closed")
        return bytes(self._value)

    def reset(self) -> None:
        if self._closed:
            raise ScratchpadError("scratchpad is closed")
        self._erase()

    def close(self) -> None:
        self._erase()
        self._closed = True

    def _erase(self) -> None:
        for index in range(len(self._value)):
            self._value[index] = 0
        self._value.clear()


__all__ = ["EpisodeScratchpad", "MAX_SCRATCHPAD_BYTES", "ScratchpadError"]
