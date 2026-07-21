"""Loader and strict validators for the versioned embodiment protocol package."""

from __future__ import annotations

import hashlib
import hmac
import json
import unicodedata
from collections import OrderedDict
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Tuple

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


class ProtocolValidationError(ValueError):
    """Stable public failure for invalid protocol bytes or instances."""


MAX_SAFE_INTEGER = 9_007_199_254_740_991
MIN_SAFE_INTEGER = -MAX_SAFE_INTEGER
CHECKPOINT_HASH_ALGORITHM = "sha256"
CANONICAL_JSON_PROFILE = "rfc8785-integer-nfc-subset-v1"
HMAC_ALGORITHM = "hmac-sha256"


def _reject_float(_: str) -> None:
    raise ProtocolValidationError("floating-point JSON numbers are forbidden")


def _reject_constant(value: str) -> None:
    raise ProtocolValidationError(f"non-finite JSON constant is forbidden: {value}")


def _unique_object(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolValidationError(f"duplicate key in JSON object: {key!r}")
        result[key] = value
    return result


def strict_json_loads(payload: str | bytes | bytearray) -> Any:
    """Decode the protocol's UTF-8, integer-only JSON domain."""

    if isinstance(payload, (bytes, bytearray)):
        raw = bytes(payload)
        if raw.startswith(b"\xef\xbb\xbf"):
            raise ProtocolValidationError("UTF-8 BOM is forbidden")
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise ProtocolValidationError("protocol input is not UTF-8") from error
    elif isinstance(payload, str):
        text = payload
        if text.startswith("\ufeff"):
            raise ProtocolValidationError("UTF-8 BOM is forbidden")
    else:
        raise TypeError("JSON input must be str or bytes")
    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_float=_reject_float,
            parse_constant=_reject_constant,
        )
    except ProtocolValidationError:
        raise
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ProtocolValidationError("protocol input is not one exact JSON value") from error


def _utf16_sort_key(value: str) -> bytes:
    try:
        return value.encode("utf-16-be", errors="strict")
    except UnicodeEncodeError as error:
        raise ProtocolValidationError("unpaired Unicode surrogate is forbidden") from error


def _canonical_value(value: Any, *, path: str = "$") -> Any:
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        if not MIN_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER:
            raise ProtocolValidationError(f"integer outside interoperable range at {path}")
        return value
    if isinstance(value, float):
        raise ProtocolValidationError(f"floating-point values are forbidden at {path}")
    if isinstance(value, str):
        if unicodedata.normalize("NFC", value) != value:
            raise ProtocolValidationError(f"string is not NFC-normalized at {path}")
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeEncodeError as error:
            raise ProtocolValidationError(f"string is not valid Unicode at {path}") from error
        return value
    if isinstance(value, (list, tuple)):
        return [
            _canonical_value(child, path=f"{path}[{index}]") for index, child in enumerate(value)
        ]
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise ProtocolValidationError(f"non-string object key at {path}")
        ordered: OrderedDict[str, Any] = OrderedDict()
        for key in sorted(value, key=_utf16_sort_key):
            canonical_key = _canonical_value(key, path=f"{path}.<key>")
            ordered[canonical_key] = _canonical_value(value[key], path=f"{path}.{canonical_key}")
        return ordered
    raise ProtocolValidationError(
        f"unsupported canonical JSON type at {path}: {type(value).__name__}"
    )


def canonical_json_bytes(value: Any) -> bytes:
    """Serialize the restricted integer/NFC subset of RFC 8785/JCS."""

    return json.dumps(
        _canonical_value(value),
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=False,
    ).encode("utf-8")


def canonical_sha256(value: Any) -> str:
    """Hash an authority checkpoint's canonical UTF-8 bytes."""

    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def canonical_hmac_sha256(key: bytes, domain: str, value: Any) -> str:
    """Authenticate a canonical value with explicit domain separation."""

    if not isinstance(key, bytes) or not key:
        raise ValueError("HMAC key must be non-empty bytes")
    if not isinstance(domain, str) or not domain or "\x00" in domain:
        raise ValueError("HMAC domain must be a non-empty string without NUL")
    material = domain.encode("utf-8") + b"\x00" + canonical_json_bytes(value)
    return hmac.new(key, material, hashlib.sha256).hexdigest()


class EmbodimentProtocolPackage:
    """Read-only access to the checked-in LLM Controller protocol package."""

    PROTOCOL_VERSION = "llm-controller/0.1.0"
    MANIFEST_NAME = "worldarena.environment.json"
    LOCK_NAME = "protocol-lock.json"
    SCHEMA_FILES = {
        "environment-manifest": "environment-manifest.v1.schema.json",
        "controller-action": "controller-action.v1.schema.json",
        "observation": "observation.v1.schema.json",
        "action-receipt": "action-receipt.v1.schema.json",
        "authority-event": "authority-event.v1.schema.json",
        "capability-status": "capability-status.v1.schema.json",
        "decision-window": "decision-window.v1.schema.json",
        "episode-config": "episode-config.v1.schema.json",
        "episode-replay": "episode-replay.v1.schema.json",
        "managed-authority-launch": "managed-authority-launch.v1.schema.json",
        "multi-participant-step-result": "multi-participant-step-result.v1.schema.json",
        "transport-frame": "transport-frame.v1.schema.json",
    }

    def __init__(self, root: Path, *, verify_lock: bool = True) -> None:
        self.root = root.resolve()
        self.schema_root = self.root / "schemas"
        self._schemas: Dict[str, Mapping[str, Any]] = {}
        resources = []
        for name, filename in self.SCHEMA_FILES.items():
            schema = self._load_json(self.schema_root / filename)
            if not isinstance(schema, dict):
                raise ProtocolValidationError(f"schema {filename} is not an object")
            schema_id = schema.get("$id")
            if not isinstance(schema_id, str) or not schema_id:
                raise ProtocolValidationError(f"schema {filename} has no $id")
            self._schemas[name] = schema
            resources.append((schema_id, Resource.from_contents(schema)))
        self._registry = Registry().with_resources(resources)

        version = (self.root / "VERSION").read_text(encoding="utf-8").strip()
        if version != self.PROTOCOL_VERSION:
            raise ProtocolValidationError("embodiment protocol VERSION is unsupported")
        manifest = self._load_json(self.root / self.MANIFEST_NAME)
        if not isinstance(manifest, dict):
            raise ProtocolValidationError("environment manifest is not an object")
        self.validate("environment-manifest", manifest)
        self._manifest = manifest
        if verify_lock and (self.root / self.LOCK_NAME).is_file():
            self.verify_lock()

    @classmethod
    def from_repository(
        cls, repository_root: Path, *, verify_lock: bool = True
    ) -> EmbodimentProtocolPackage:
        return cls(
            repository_root / "game" / "embodiment_protocol",
            verify_lock=verify_lock,
        )

    @property
    def manifest(self) -> Mapping[str, Any]:
        return json.loads(json.dumps(self._manifest))

    def schema(self, name: str) -> Mapping[str, Any]:
        if name not in self._schemas:
            raise KeyError(name)
        return json.loads(json.dumps(self._schemas[name]))

    def artifact_paths(self) -> Tuple[Path, ...]:
        """Return package artifacts in stable path order, excluding the self-referential lock."""

        return tuple(
            sorted(
                (
                    path
                    for path in self.root.rglob("*")
                    if path.is_file()
                    and path.name != self.LOCK_NAME
                    and not any(part.startswith(".") for part in path.relative_to(self.root).parts)
                ),
                key=lambda path: path.relative_to(self.root).as_posix(),
            )
        )

    def build_lock(self) -> Mapping[str, Any]:
        artifacts = []
        for path in self.artifact_paths():
            payload = path.read_bytes()
            artifacts.append(
                {
                    "path": path.relative_to(self.root).as_posix(),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
        body = {
            "artifacts": artifacts,
            "canonical_json": CANONICAL_JSON_PROFILE,
            "hash_algorithm": CHECKPOINT_HASH_ALGORITHM,
            "protocol_version": self.PROTOCOL_VERSION,
        }
        return {**body, "package_sha256": canonical_sha256(body)}

    def verify_lock(self) -> Mapping[str, Any]:
        locked = self._load_json(self.root / self.LOCK_NAME)
        actual = self.build_lock()
        if not isinstance(locked, dict) or locked != actual:
            raise ProtocolValidationError("embodiment protocol lock mismatch")
        return actual

    @property
    def package_sha256(self) -> str:
        lock = self.verify_lock() if (self.root / self.LOCK_NAME).is_file() else self.build_lock()
        return str(lock["package_sha256"])

    def validate(self, schema_name: str, instance: Any) -> None:
        if schema_name not in self._schemas:
            raise KeyError(schema_name)
        canonical_json_bytes(instance)
        validator = Draft202012Validator(
            self._schemas[schema_name],
            registry=self._registry,
        )
        errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
        if errors:
            first = errors[0]
            location = "/" + "/".join(str(part) for part in first.absolute_path)
            raise ProtocolValidationError(f"{schema_name}{location}: {first.message}")
        self._validate_utf8_limits(schema_name, instance)

    @staticmethod
    def _validate_utf8_limits(schema_name: str, instance: Any) -> None:
        """Enforce byte ceilings JSON Schema's character-count keywords cannot express."""

        if not isinstance(instance, dict):
            return
        limits: Tuple[Tuple[str, int], ...]
        if schema_name == "controller-action":
            limits = (("intent_label", 160), ("memory_update", 2048))
        elif schema_name == "observation":
            limits = (("memory", 2048),)
        else:
            return
        for field, limit in limits:
            value = instance.get(field)
            if isinstance(value, str) and len(value.encode("utf-8")) > limit:
                raise ProtocolValidationError(f"{schema_name}/{field}: exceeds {limit} UTF-8 bytes")

    def parse_and_validate(self, schema_name: str, raw: bytes, *, byte_limit: int) -> Any:
        if not isinstance(raw, bytes):
            raise TypeError("raw protocol input must be bytes")
        if len(raw) > byte_limit:
            raise ProtocolValidationError(f"{schema_name} exceeds {byte_limit} bytes")
        try:
            instance = strict_json_loads(raw)
            # Canonical-domain validation is separate from accepting non-canonical whitespace or
            # object order on input. Checkpoints and authenticated frames always use the encoder.
            canonical_json_bytes(instance)
        except ProtocolValidationError as error:
            raise ProtocolValidationError(f"{schema_name}: {error}") from error
        self.validate(schema_name, instance)
        return instance

    @staticmethod
    def _load_json(path: Path) -> Any:
        try:
            return strict_json_loads(path.read_bytes())
        except (OSError, ProtocolValidationError) as error:
            raise ProtocolValidationError(f"cannot load protocol file {path.name}") from error
