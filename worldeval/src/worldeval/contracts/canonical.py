"""Canonical JSON used for protocol identities and state acknowledgements.

WorldEval deliberately uses the same integer-only, NFC-normalized subset of
RFC 8785 as the existing WorldArena protocols.  Rejecting floats avoids engine
and language-specific representations entering hashes.
"""

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


class CanonicalJSONError(ValueError):
    """A value is outside the canonical WorldEval JSON domain."""


def _reject_float(value: str) -> None:
    raise CanonicalJSONError(f"floating-point JSON number is forbidden: {value}")


def _reject_constant(value: str) -> None:
    raise CanonicalJSONError(f"non-finite JSON constant is forbidden: {value}")


def _unique_object(pairs: Iterable[Tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CanonicalJSONError(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def strict_json_loads(payload: str | bytes | bytearray) -> Any:
    if isinstance(payload, (bytes, bytearray)):
        raw = bytes(payload)
        if raw.startswith(b"\xef\xbb\xbf"):
            raise CanonicalJSONError("UTF-8 BOM is forbidden")
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            raise CanonicalJSONError("payload is not valid UTF-8") from exc
    elif isinstance(payload, str):
        text = payload
        if text.startswith("\ufeff"):
            raise CanonicalJSONError("UTF-8 BOM is forbidden")
    else:
        raise CanonicalJSONError("JSON payload must be text or bytes")
    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_float=_reject_float,
            parse_constant=_reject_constant,
        )
    except CanonicalJSONError:
        raise
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise CanonicalJSONError(f"invalid JSON: {exc}") from exc


def _utf16_sort_key(value: str) -> bytes:
    try:
        return value.encode("utf-16-be", errors="strict")
    except UnicodeEncodeError as exc:
        raise CanonicalJSONError("unpaired Unicode surrogate is forbidden") from exc


def _canonical_value(value: Any, *, path: str = "$") -> Any:
    if isinstance(value, BaseModel):
        value = value.model_dump(mode="json", by_alias=True)
    elif isinstance(value, Enum):
        value = value.value

    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        if not MIN_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER:
            raise CanonicalJSONError(f"integer outside interoperable range at {path}")
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise CanonicalJSONError(f"non-finite float at {path}")
        raise CanonicalJSONError(f"floating-point value is forbidden at {path}")
    if isinstance(value, str):
        if unicodedata.normalize("NFC", value) != value:
            raise CanonicalJSONError(f"string is not NFC-normalized at {path}")
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeEncodeError as exc:
            raise CanonicalJSONError(f"invalid Unicode at {path}") from exc
        return value
    if isinstance(value, (list, tuple)):
        return [
            _canonical_value(child, path=f"{path}[{index}]")
            for index, child in enumerate(value)
        ]
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise CanonicalJSONError(f"non-string object key at {path}")
        ordered: OrderedDict[str, Any] = OrderedDict()
        for key in sorted(value, key=_utf16_sort_key):
            if unicodedata.normalize("NFC", key) != key:
                raise CanonicalJSONError(f"object key is not NFC-normalized at {path}")
            ordered[key] = _canonical_value(value[key], path=f"{path}.{key}")
        return ordered
    raise CanonicalJSONError(f"unsupported value at {path}: {type(value).__name__}")


def canonical_json_text(value: Any) -> str:
    return json.dumps(
        _canonical_value(value),
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=False,
    )


def canonical_json_bytes(value: Any) -> bytes:
    return canonical_json_text(value).encode("utf-8")


def canonical_sha256(value: Any) -> str:
    return f"sha256:{hashlib.sha256(canonical_json_bytes(value)).hexdigest()}"
