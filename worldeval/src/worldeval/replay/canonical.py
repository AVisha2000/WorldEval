"""Strict, portable canonical JSON used by WorldEval replay bundles."""

from __future__ import annotations

import hashlib
import json
import unicodedata
from collections import OrderedDict
from collections.abc import Iterable, Mapping
from typing import Any, Dict, Tuple

MAX_SAFE_INTEGER = 9_007_199_254_740_991
MIN_SAFE_INTEGER = -MAX_SAFE_INTEGER
CANONICAL_JSON_PROFILE = "rfc8785-integer-nfc-subset-v1"


class CanonicalJSONError(ValueError):
    """A value or byte stream is outside WorldEval's canonical JSON domain."""


def _reject_float(_: str) -> None:
    raise CanonicalJSONError("floating-point JSON numbers are forbidden")


def _reject_constant(value: str) -> None:
    raise CanonicalJSONError(f"non-finite JSON constant is forbidden: {value}")


def _unique_object(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CanonicalJSONError(f"duplicate key in JSON object: {key!r}")
        result[key] = value
    return result


def strict_json_loads(payload: object) -> Any:
    """Decode exactly one UTF-8 JSON value in the integer-only protocol domain."""

    if isinstance(payload, (bytes, bytearray)):
        raw = bytes(payload)
        if raw.startswith(b"\xef\xbb\xbf"):
            raise CanonicalJSONError("UTF-8 BOM is forbidden")
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise CanonicalJSONError("JSON input is not UTF-8") from error
    elif isinstance(payload, str):
        text = payload
        if text.startswith("\ufeff"):
            raise CanonicalJSONError("UTF-8 BOM is forbidden")
    else:
        raise TypeError("JSON input must be str or bytes")

    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_float=_reject_float,
            parse_constant=_reject_constant,
        )
    except CanonicalJSONError:
        raise
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CanonicalJSONError("JSON input is not one exact JSON value") from error


def _utf16_sort_key(value: str) -> bytes:
    try:
        return value.encode("utf-16-be", errors="strict")
    except UnicodeEncodeError as error:
        raise CanonicalJSONError("unpaired Unicode surrogate is forbidden") from error


def _canonical_value(value: Any, *, path: str = "$") -> Any:
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        if not MIN_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER:
            raise CanonicalJSONError(f"integer outside interoperable range at {path}")
        return value
    if isinstance(value, float):
        raise CanonicalJSONError(f"floating-point values are forbidden at {path}")
    if isinstance(value, str):
        if unicodedata.normalize("NFC", value) != value:
            raise CanonicalJSONError(f"string is not NFC-normalized at {path}")
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeEncodeError as error:
            raise CanonicalJSONError(f"string is not valid Unicode at {path}") from error
        return value
    if isinstance(value, (list, tuple)):
        return [
            _canonical_value(child, path=f"{path}[{index}]")
            for index, child in enumerate(value)
        ]
    if isinstance(value, Mapping):
        if any(not isinstance(key, str) for key in value):
            raise CanonicalJSONError(f"non-string object key at {path}")
        ordered: OrderedDict[str, Any] = OrderedDict()
        for key in sorted(value, key=_utf16_sort_key):
            canonical_key = _canonical_value(key, path=f"{path}.<key>")
            ordered[canonical_key] = _canonical_value(
                value[key], path=f"{path}.{canonical_key}"
            )
        return ordered
    raise CanonicalJSONError(
        f"unsupported canonical JSON type at {path}: {type(value).__name__}"
    )


def canonical_json_bytes(value: Any) -> bytes:
    """Encode a value using WorldEval's restricted RFC 8785/JCS profile."""

    return json.dumps(
        _canonical_value(value),
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=False,
    ).encode("utf-8")


def canonical_sha256(value: Any) -> str:
    """Return the lowercase SHA-256 digest of a canonical JSON value."""

    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def require_canonical_json_bytes(payload: bytes) -> Any:
    """Parse canonical JSON bytes and reject alternate encodings of the same value."""

    value = strict_json_loads(payload)
    if canonical_json_bytes(value) != payload:
        raise CanonicalJSONError("JSON bytes are not canonical")
    return value
