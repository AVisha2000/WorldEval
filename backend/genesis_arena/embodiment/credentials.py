"""Process-local, explicitly erasable provider credentials.

Credentials deliberately have no JSON representation and their repr never includes their value.
The store is an episode-scoped hand-off between the local API and provider construction only.
"""

from __future__ import annotations

import re
import threading
from dataclasses import dataclass
from typing import Dict, Tuple

_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$")


class CredentialError(ValueError):
    """Stable credential lifecycle failure with no secret material."""


class SessionCredential:
    """An in-memory UTF-8 secret that can be overwritten when its episode ends."""

    __slots__ = ("_closed", "_secret", "_lock")

    def __init__(self, secret: str) -> None:
        if not isinstance(secret, str) or not secret or "\x00" in secret:
            raise CredentialError("provider credential is invalid")
        encoded = secret.encode("utf-8")
        if len(encoded) > 16_384:
            raise CredentialError("provider credential is too large")
        self._secret = bytearray(encoded)
        self._closed = False
        self._lock = threading.Lock()

    def __repr__(self) -> str:
        return "SessionCredential(<redacted>)"

    def __reduce__(self) -> object:
        raise TypeError("SessionCredential cannot be serialized")

    def __copy__(self) -> object:
        raise TypeError("SessionCredential cannot be copied")

    def __deepcopy__(self, memo: object) -> object:
        del memo
        raise TypeError("SessionCredential cannot be copied")

    def reveal(self) -> str:
        """Return a short-lived string for constructing one provider request header."""

        with self._lock:
            if self._closed:
                raise CredentialError("provider credential is unavailable")
            return self._secret.decode("utf-8", errors="strict")

    def close(self) -> None:
        with self._lock:
            for index in range(len(self._secret)):
                self._secret[index] = 0
            self._secret.clear()
            self._closed = True

    @property
    def closed(self) -> bool:
        with self._lock:
            return self._closed

    def __enter__(self) -> SessionCredential:
        if self.closed:
            raise CredentialError("provider credential is unavailable")
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


@dataclass(frozen=True)
class CredentialRef:
    """Non-secret identifier safe to retain in protected orchestration state."""

    episode_id: str
    provider: str

    def __post_init__(self) -> None:
        if not _SAFE_ID.fullmatch(self.episode_id) or not _SAFE_ID.fullmatch(self.provider):
            raise CredentialError("credential reference is invalid")


class InMemoryCredentialStore:
    """Thread-safe provider-key storage that owns and erases every inserted value."""

    def __init__(self) -> None:
        self._values: Dict[Tuple[str, str], SessionCredential] = {}
        self._lock = threading.Lock()

    def __repr__(self) -> str:
        return f"InMemoryCredentialStore(entries={len(self)})"

    def put(self, episode_id: str, provider: str, secret: str) -> CredentialRef:
        ref = CredentialRef(episode_id, provider)
        credential = SessionCredential(secret)
        key = (ref.episode_id, ref.provider)
        with self._lock:
            previous = self._values.pop(key, None)
            self._values[key] = credential
        if previous is not None:
            previous.close()
        return ref

    def get(self, ref: CredentialRef) -> SessionCredential:
        if not isinstance(ref, CredentialRef):
            raise TypeError("ref must be CredentialRef")
        with self._lock:
            credential = self._values.get((ref.episode_id, ref.provider))
        if credential is None or credential.closed:
            raise CredentialError("provider credential is unavailable")
        return credential

    def discard_episode(self, episode_id: str) -> None:
        if not isinstance(episode_id, str):
            raise TypeError("episode_id must be a string")
        with self._lock:
            selected = [key for key in self._values if key[0] == episode_id]
            credentials = [self._values.pop(key) for key in selected]
        for credential in credentials:
            credential.close()

    def close(self) -> None:
        with self._lock:
            credentials = list(self._values.values())
            self._values.clear()
        for credential in credentials:
            credential.close()

    def __len__(self) -> int:
        with self._lock:
            return len(self._values)


__all__ = [
    "CredentialError",
    "CredentialRef",
    "InMemoryCredentialStore",
    "SessionCredential",
]
