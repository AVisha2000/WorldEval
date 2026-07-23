from __future__ import annotations

import hashlib
import json
import math
import unicodedata
from collections import OrderedDict
from enum import Enum
from typing import Any, Iterable, Tuple

from pydantic import BaseModel

MAX_SAFE_INTEGER = 9_007_199_254_740_991
MIN_SAFE_INTEGER = -MAX_SAFE_INTEGER


class DuelCanonicalError(ValueError):
    """Raised when a value cannot enter the restricted Duel canonical JSON domain."""


def _reject_float(_: str) -> None:
    raise DuelCanonicalError("floating-point JSON numbers are forbidden by the Duel protocol")


def _reject_constant(value: str) -> None:
    raise DuelCanonicalError(f"non-finite JSON constant is forbidden: {value}")


def _unique_object(pairs: Iterable[Tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuelCanonicalError(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def strict_json_loads(payload: str | bytes | bytearray) -> Any:
    """Decode one strict Duel JSON value.

    The decoder rejects BOMs, invalid UTF-8, duplicate keys, floats, NaN/infinity, and trailing
    objects. Structural/schema validation intentionally happens in the protocol layer.
    """

    if isinstance(payload, (bytes, bytearray)):
        raw = bytes(payload)
        if raw.startswith(b"\xef\xbb\xbf"):
            raise DuelCanonicalError("UTF-8 BOM is forbidden")
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            raise DuelCanonicalError("payload is not valid UTF-8") from exc
    elif isinstance(payload, str):
        text = payload
        if text.startswith("\ufeff"):
            raise DuelCanonicalError("UTF-8 BOM is forbidden")
    else:
        raise DuelCanonicalError("JSON payload must be str or bytes")

    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_float=_reject_float,
            parse_constant=_reject_constant,
        )
    except DuelCanonicalError:
        raise
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise DuelCanonicalError(f"invalid JSON: {exc}") from exc


def _utf16_sort_key(value: str) -> bytes:
    # RFC 8785/JCS orders object property names as UTF-16 code units.
    try:
        return value.encode("utf-16-be", errors="strict")
    except UnicodeEncodeError as exc:
        raise DuelCanonicalError("unpaired Unicode surrogate is forbidden") from exc


def _validate_string(value: str, *, path: str) -> str:
    if unicodedata.normalize("NFC", value) != value:
        raise DuelCanonicalError(f"string is not NFC-normalized at {path}")
    try:
        value.encode("utf-8", errors="strict")
    except UnicodeEncodeError as exc:
        raise DuelCanonicalError(f"string is not valid Unicode at {path}") from exc
    return value


def _canonical_value(value: Any, *, path: str = "$") -> Any:
    if isinstance(value, BaseModel):
        value = value.model_dump(mode="json")
    elif isinstance(value, Enum):
        value = value.value

    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        if not MIN_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER:
            raise DuelCanonicalError(f"integer outside interoperable range at {path}")
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise DuelCanonicalError(f"non-finite float at {path}")
        raise DuelCanonicalError(f"floating-point values are forbidden at {path}")
    if isinstance(value, str):
        return _validate_string(value, path=path)
    if isinstance(value, (list, tuple)):
        return [
            _canonical_value(child, path=f"{path}[{index}]")
            for index, child in enumerate(value)
        ]
    if isinstance(value, dict):
        ordered: OrderedDict[str, Any] = OrderedDict()
        if any(not isinstance(key, str) for key in value):
            raise DuelCanonicalError(f"non-string object key at {path}")
        for key in sorted(value, key=_utf16_sort_key):
            canonical_key = _validate_string(key, path=f"{path}.<key>")
            ordered[canonical_key] = _canonical_value(value[key], path=f"{path}.{canonical_key}")
        return ordered
    raise DuelCanonicalError(f"unsupported canonical JSON type at {path}: {type(value).__name__}")


def canonical_json_text(value: Any) -> str:
    """Serialize the integer-only Duel subset of RFC 8785/JCS."""

    canonical = _canonical_value(value)
    return json.dumps(
        canonical,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=False,
    )


def canonical_json_bytes(value: Any) -> bytes:
    return canonical_json_text(value).encode("utf-8")


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()
