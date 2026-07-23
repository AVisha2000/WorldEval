"""Deterministic, provider-neutral artifact bundles for WorldArena Duel.

The bundle format is deliberately simpler than ZIP or TAR.  It is canonical JSON containing an
index and base64 payloads; consequently it has no timestamps, host permissions, file ordering, or
compression implementation details that can vary between machines.  A bundle may also be
materialized as an immutable directory for streaming replay clients.

This module does not authenticate a bundle.  Callers that receive a bundle from another trust
domain must retain and pass its externally committed ``content_sha256``.  The hashes here make
every internal byte fail closed on corruption and provide the value that should be committed.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep annotations importable on the project's Python 3.9 floor.
import base64
import binascii
import hashlib
import os
import re
import shutil
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, Optional, Sequence, Tuple

from .canonical import (
    MAX_SAFE_INTEGER,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)

BUNDLE_SCHEMA_VERSION = "worldeval-rts/artifact-bundle/1.0.0"
PUBLISHABLE_LAYER = "publishable"
PROTECTED_AUDIT_LAYER = "protected_audit"

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_ROLE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_MEDIA_TYPES = frozenset({"application/json", "application/x-ndjson", "application/octet-stream"})
_PUBLIC_ROLES = frozenset(
    {
        "accepted_actions",
        "compiled_orders",
        "public_events",
        "spectator_events",
        "state_checkpoints",
        "omniscient_snapshots",
        "player_0_knowledge",
        "player_1_knowledge",
        "usage_timing",
    }
)
_TRANSCRIPT_ROLES = frozenset({"accepted_actions", "compiled_orders"})
_REPLAY_MANIFEST_SCHEMA = "replay-manifest.v1.schema.json"

# Keys normalize to lower-case ASCII alphanumerics before comparison, catching snake, kebab,
# camel, and case variants.  Protected bundles intentionally do not use this deny-list: those
# fields are precisely what an authorized audit may need to retain.
_FORBIDDEN_CREDENTIAL_KEYS = frozenset(
    {
        "accesskey",
        "accesstoken",
        "apikey",
        "authorization",
        "bearertoken",
        "clientsecret",
        "credential",
        "credentials",
        "idtoken",
        "openaiapikey",
        "password",
        "privatekey",
        "refreshtoken",
        "secret",
        "xapikey",
    }
)
_FORBIDDEN_PUBLIC_PRIVATE_KEYS = frozenset(
    {
        "chainofthought",
        "detailedtiming",
        "hiddenscratchpad",
        "modelresponse",
        "observation",
        "observationbytes",
        "observations",
        "parsedbatch",
        "parsedbatches",
        "providerresponse",
        "providerrequestid",
        "rawrequest",
        "rawoutput",
        "rawresponse",
        "rawresponsebytes",
        "reasoningtrace",
        "requestbody",
        "requesttiming",
        "responsebody",
        "scratchpad",
        "validationtrace",
        "workingmemory",
    }
)
_SECRET_TEXT_PATTERNS = (
    re.compile(r"(?i)\bbearer\s+[a-z0-9._~+/=-]{10,}"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{10,}"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
)


class DuelArtifactError(ValueError):
    """Base error for malformed or policy-invalid Duel artifact bundles."""


class ArtifactPolicyError(DuelArtifactError):
    """The requested artifact would violate a publication or immutability policy."""


class ArtifactIntegrityError(DuelArtifactError):
    """A hash, size, canonical byte, path, or manifest binding did not verify."""


@dataclass(frozen=True)
class ArtifactPayload:
    """One immutable logical artifact before it is placed in a content-addressed bundle."""

    role: str
    data: bytes
    media_type: str

    def __post_init__(self) -> None:
        _validate_role(self.role)
        if self.media_type not in _MEDIA_TYPES:
            raise ArtifactPolicyError(f"unsupported artifact media type: {self.media_type!r}")
        if not isinstance(self.data, bytes):
            raise ArtifactPolicyError("artifact data must be immutable bytes")

    @classmethod
    def canonical_json(cls, role: str, value: Any) -> ArtifactPayload:
        return cls(role=role, data=canonical_json_bytes(value), media_type="application/json")

    @classmethod
    def canonical_jsonl(cls, role: str, values: Iterable[Any]) -> ArtifactPayload:
        rows = [canonical_json_bytes(value) for value in values]
        data = b"" if not rows else b"\n".join(rows) + b"\n"
        return cls(role=role, data=data, media_type="application/x-ndjson")

    @classmethod
    def transcript(
        cls,
        role: str,
        values: Iterable[Mapping[str, Any]],
        *,
        tick_field: str = "application_tick",
    ) -> ArtifactPayload:
        if role not in _TRANSCRIPT_ROLES:
            raise ArtifactPolicyError(f"role is not an application transcript: {role!r}")
        return cls(
            role=role,
            data=canonical_transcript_bytes(values, tick_field=tick_field),
            media_type="application/x-ndjson",
        )


@dataclass(frozen=True)
class ArtifactFile:
    role: str
    path: str
    sha256: str
    bytes: int
    media_type: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "bytes": self.bytes,
            "media_type": self.media_type,
            "path": self.path,
            "role": self.role,
            "sha256": self.sha256,
        }


@dataclass(frozen=True)
class BundleVerification:
    content_sha256: str
    index_sha256: str
    layer: str
    manifest_sha256: str
    artifact_count: int


class ImmutableArtifactBundle:
    """A sealed bundle represented exclusively by already-verified immutable bytes."""

    def __init__(
        self,
        bundle_bytes: bytes,
        *,
        index: Mapping[str, Any],
        payloads: Mapping[str, bytes],
        manifest: Mapping[str, Any],
    ) -> None:
        self._bundle_bytes = bytes(bundle_bytes)
        self._index_bytes = canonical_json_bytes(index)
        self._manifest_bytes = bytes(payloads[str(index["manifest"]["path"])])
        self._payloads = tuple(sorted(payloads.items()))
        self._manifest_value = canonical_json_bytes(manifest)

    @classmethod
    def create(
        cls,
        *,
        layer: str,
        manifest: Mapping[str, Any],
        artifacts: Iterable[ArtifactPayload],
    ) -> ImmutableArtifactBundle:
        _validate_layer(layer)
        artifact_values = tuple(artifacts)
        files, object_payloads = _build_artifact_files(layer, artifact_values)

        # Round-trip through canonical bytes to make a detached copy and reject floats, unsafe
        # integers, non-NFC text, and other values outside the protocol domain.
        detached_manifest = strict_json_loads(canonical_json_bytes(manifest))
        if not isinstance(detached_manifest, dict):
            raise ArtifactPolicyError("bundle manifest must be a JSON object")
        existing_files = detached_manifest.get("files")
        file_values = [item.as_dict() for item in files]
        if existing_files is not None and existing_files != file_values:
            raise ArtifactPolicyError(
                "caller-supplied manifest files do not match sealed artifacts"
            )
        detached_manifest["files"] = file_values
        _assert_credential_free_value(detached_manifest, path="$.manifest")
        if layer == PUBLISHABLE_LAYER:
            _assert_public_value(detached_manifest, path="$.manifest")
            _validate_publishable_manifest(detached_manifest, creating=True)

        manifest_bytes = canonical_json_bytes(detached_manifest)
        manifest_path = (
            "replay-manifest.json"
            if layer == PUBLISHABLE_LAYER
            else "protected-audit-manifest.json"
        )
        manifest_descriptor = {
            "bytes": len(manifest_bytes),
            "media_type": "application/json",
            "path": manifest_path,
            "sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        }
        body = {
            "artifacts": file_values,
            "layer": layer,
            "manifest": manifest_descriptor,
            "schema_version": BUNDLE_SCHEMA_VERSION,
        }
        index = {**body, "index_sha256": canonical_sha256(body)}
        payloads = {manifest_path: manifest_bytes, **object_payloads}
        wire = _wire_value(index, payloads)
        return cls.from_bytes(canonical_json_bytes(wire))

    @classmethod
    def from_bytes(
        cls,
        payload: bytes,
        *,
        expected_content_sha256: Optional[str] = None,
        expected_layer: Optional[str] = None,
    ) -> ImmutableArtifactBundle:
        if not isinstance(payload, bytes):
            raise ArtifactIntegrityError("bundle must be supplied as immutable bytes")
        actual_content_sha256 = hashlib.sha256(payload).hexdigest()
        if expected_content_sha256 is not None:
            _validate_sha256(expected_content_sha256, "expected content hash")
            if actual_content_sha256 != expected_content_sha256:
                raise ArtifactIntegrityError("bundle content SHA-256 mismatch")

        try:
            wire = strict_json_loads(payload)
        except ValueError as exc:
            raise ArtifactIntegrityError(f"invalid bundle JSON: {exc}") from exc
        if not isinstance(wire, dict) or set(wire) != {"index", "payloads"}:
            raise ArtifactIntegrityError("bundle envelope must contain exactly index and payloads")
        if canonical_json_bytes(wire) != payload:
            raise ArtifactIntegrityError("bundle envelope is not in canonical byte form")

        index = wire["index"]
        if not isinstance(index, dict):
            raise ArtifactIntegrityError("bundle index must be an object")
        _verify_index(index, expected_layer=expected_layer)
        decoded_payloads = _decode_payloads(wire["payloads"])
        manifest, files = _verify_payload_bindings(index, decoded_payloads)
        layer = str(index["layer"])
        _verify_credential_policy(manifest, files, decoded_payloads)
        if layer == PUBLISHABLE_LAYER:
            _verify_publishable_policy(manifest, files, decoded_payloads)
            _validate_publishable_manifest(manifest, creating=False)
        return cls(payload, index=index, payloads=decoded_payloads, manifest=manifest)

    @classmethod
    def load_directory(
        cls,
        directory: Path,
        *,
        expected_content_sha256: Optional[str] = None,
        expected_layer: Optional[str] = None,
    ) -> ImmutableArtifactBundle:
        root = Path(directory)
        if not root.is_dir() or root.is_symlink():
            raise ArtifactIntegrityError(f"bundle directory is absent or unsafe: {root}")
        index_path = root / "bundle-index.json"
        _require_regular_file(index_path)
        index_bytes = index_path.read_bytes()
        try:
            index = strict_json_loads(index_bytes)
        except ValueError as exc:
            raise ArtifactIntegrityError(f"invalid bundle index JSON: {exc}") from exc
        if not isinstance(index, dict) or canonical_json_bytes(index) != index_bytes:
            raise ArtifactIntegrityError("bundle index is not canonical JSON")
        _verify_index(index, expected_layer=expected_layer)

        descriptors = [index["manifest"], *index["artifacts"]]
        expected_paths = {"bundle-index.json"}
        payloads: dict[str, bytes] = {}
        for descriptor in descriptors:
            relative = str(descriptor["path"])
            _validate_relative_path(relative)
            expected_paths.add(relative)
            if relative in payloads:
                continue
            path = _safe_child(root, relative)
            _require_regular_file(path)
            payloads[relative] = path.read_bytes()

        actual_paths: set[str] = set()
        for candidate in root.rglob("*"):
            if candidate.is_symlink():
                raise ArtifactIntegrityError("symlinks are forbidden in a materialized bundle")
            if candidate.is_file():
                actual_paths.add(candidate.relative_to(root).as_posix())
        if actual_paths != expected_paths:
            unexpected = sorted(actual_paths - expected_paths)
            missing = sorted(expected_paths - actual_paths)
            raise ArtifactIntegrityError(
                f"materialized bundle file set mismatch; unexpected={unexpected}, missing={missing}"
            )

        wire = _wire_value(index, payloads)
        return cls.from_bytes(
            canonical_json_bytes(wire),
            expected_content_sha256=expected_content_sha256,
            expected_layer=expected_layer,
        )

    @property
    def layer(self) -> str:
        return str(self.index["layer"])

    @property
    def bundle_bytes(self) -> bytes:
        return self._bundle_bytes

    @property
    def content_sha256(self) -> str:
        return hashlib.sha256(self._bundle_bytes).hexdigest()

    @property
    def index(self) -> dict[str, Any]:
        value = strict_json_loads(self._index_bytes)
        assert isinstance(value, dict)
        return value

    @property
    def manifest(self) -> dict[str, Any]:
        value = strict_json_loads(self._manifest_value)
        assert isinstance(value, dict)
        return value

    @property
    def files(self) -> Tuple[ArtifactFile, ...]:
        return tuple(_artifact_file(value) for value in self.index["artifacts"])

    def artifact_bytes(self, *, role: str) -> bytes:
        matches = [artifact for artifact in self.files if artifact.role == role]
        if len(matches) != 1:
            raise ArtifactIntegrityError(
                f"expected exactly one artifact for role {role!r}; found {len(matches)}"
            )
        payload_map = dict(self._payloads)
        return payload_map[matches[0].path]

    def verify(
        self,
        *,
        expected_content_sha256: Optional[str] = None,
        expected_layer: Optional[str] = None,
    ) -> BundleVerification:
        verified = self.from_bytes(
            self._bundle_bytes,
            expected_content_sha256=expected_content_sha256,
            expected_layer=expected_layer,
        )
        index = verified.index
        return BundleVerification(
            content_sha256=verified.content_sha256,
            index_sha256=str(index["index_sha256"]),
            layer=str(index["layer"]),
            manifest_sha256=str(index["manifest"]["sha256"]),
            artifact_count=len(index["artifacts"]),
        )

    def write_directory(self, directory: Path) -> Path:
        """Atomically create a new materialized bundle; existing paths are never overwritten."""

        destination = Path(directory)
        destination_parent = destination.parent
        destination_parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            raise FileExistsError(f"immutable bundle destination already exists: {destination}")

        temporary = Path(
            tempfile.mkdtemp(prefix=f".{destination.name}.tmp-", dir=str(destination_parent))
        )
        try:
            _write_new_file(temporary / "bundle-index.json", self._index_bytes)
            for relative, data in self._payloads:
                target = _safe_child(temporary, relative)
                target.parent.mkdir(parents=True, exist_ok=True)
                _write_new_file(target, data)
            os.rename(temporary, destination)
        except BaseException:
            if temporary.exists():
                shutil.rmtree(temporary)
            raise
        return destination


def canonical_transcript_bytes(
    records: Iterable[Mapping[str, Any]], *, tick_field: str = "application_tick"
) -> bytes:
    """Encode an application transcript without sorting away semantically meaningful order."""

    encoded: list[bytes] = []
    last_tick = -1
    for index, record in enumerate(records):
        if not isinstance(record, Mapping):
            raise ArtifactPolicyError(f"transcript row {index} must be an object")
        detached = strict_json_loads(canonical_json_bytes(dict(record)))
        if not isinstance(detached, dict):
            raise ArtifactPolicyError(f"transcript row {index} must be an object")
        tick = detached.get(tick_field)
        if not isinstance(tick, int) or isinstance(tick, bool) or not 0 <= tick <= MAX_SAFE_INTEGER:
            raise ArtifactPolicyError(
                f"transcript row {index} requires non-negative integer {tick_field!r}"
            )
        if tick < last_tick:
            raise ArtifactPolicyError(
                f"transcript application ticks are out of order at row {index}: "
                f"{tick} < {last_tick}"
            )
        if "transcript_index" in detached and detached["transcript_index"] != index:
            raise ArtifactPolicyError(f"transcript_index must be contiguous and equal to {index}")
        last_tick = tick
        encoded.append(canonical_json_bytes(detached))
    return b"" if not encoded else b"\n".join(encoded) + b"\n"


def decode_canonical_transcript(
    payload: bytes, *, tick_field: str = "application_tick"
) -> Tuple[dict[str, Any], ...]:
    if not payload:
        return ()
    if not payload.endswith(b"\n") or b"\r" in payload:
        raise ArtifactIntegrityError("canonical transcript must use LF-terminated records")
    lines = payload[:-1].split(b"\n")
    if any(not line for line in lines):
        raise ArtifactIntegrityError("canonical transcript contains an empty record")
    records: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        try:
            value = strict_json_loads(line)
        except ValueError as exc:
            raise ArtifactIntegrityError(f"invalid transcript row {index}: {exc}") from exc
        if not isinstance(value, dict) or canonical_json_bytes(value) != line:
            raise ArtifactIntegrityError(f"transcript row {index} is not a canonical JSON object")
        records.append(value)
    try:
        expected = canonical_transcript_bytes(records, tick_field=tick_field)
    except ArtifactPolicyError as exc:
        raise ArtifactIntegrityError(str(exc)) from exc
    if expected != payload:
        raise ArtifactIntegrityError("transcript bytes are not canonical")
    return tuple(records)


def decode_canonical_jsonl(payload: bytes) -> Tuple[Any, ...]:
    """Decode canonical LF-terminated JSON records without imposing transcript fields."""

    if not isinstance(payload, bytes):
        raise ArtifactIntegrityError("canonical JSONL must be supplied as immutable bytes")
    if not payload:
        return ()
    if not payload.endswith(b"\n") or b"\r" in payload:
        raise ArtifactIntegrityError("canonical JSONL must use LF-terminated records")
    lines = payload[:-1].split(b"\n")
    if any(not line for line in lines):
        raise ArtifactIntegrityError("canonical JSONL contains an empty record")
    result: list[Any] = []
    for index, line in enumerate(lines):
        try:
            value = strict_json_loads(line)
        except ValueError as exc:
            raise ArtifactIntegrityError(f"invalid canonical JSONL row {index}: {exc}") from exc
        if canonical_json_bytes(value) != line:
            raise ArtifactIntegrityError(f"canonical JSONL row {index} is not canonical")
        result.append(value)
    return tuple(result)


def _build_artifact_files(
    layer: str, artifacts: Sequence[ArtifactPayload]
) -> tuple[Tuple[ArtifactFile, ...], dict[str, bytes]]:
    files: list[ArtifactFile] = []
    payloads: dict[str, bytes] = {}
    media_by_path: dict[str, str] = {}
    seen_roles: set[str] = set()
    for artifact in artifacts:
        if artifact.role in seen_roles:
            raise ArtifactPolicyError(f"artifact role may appear only once: {artifact.role!r}")
        seen_roles.add(artifact.role)
        _assert_credential_free_payload(artifact)
        if layer == PUBLISHABLE_LAYER:
            if artifact.role not in _PUBLIC_ROLES:
                raise ArtifactPolicyError(
                    f"protected or unknown role cannot enter publishable bundle: {artifact.role!r}"
                )
            _assert_public_payload(artifact)
        if artifact.role in _TRANSCRIPT_ROLES:
            if artifact.media_type != "application/x-ndjson":
                raise ArtifactPolicyError(
                    f"{artifact.role} must use canonical application/x-ndjson"
                )
            decode_canonical_transcript(artifact.data)

        digest = hashlib.sha256(artifact.data).hexdigest()
        path = f"objects/sha256/{digest}"
        previous_media = media_by_path.get(path)
        if previous_media is not None and previous_media != artifact.media_type:
            raise ArtifactPolicyError("identical object bytes cannot claim conflicting media types")
        media_by_path[path] = artifact.media_type
        payloads[path] = artifact.data
        files.append(
            ArtifactFile(
                role=artifact.role,
                path=path,
                sha256=digest,
                bytes=len(artifact.data),
                media_type=artifact.media_type,
            )
        )
    files.sort(key=lambda item: (item.role, item.path))
    return tuple(files), payloads


def _wire_value(index: Mapping[str, Any], payloads: Mapping[str, bytes]) -> dict[str, Any]:
    return {
        "index": dict(index),
        "payloads": [
            {
                "data_base64": base64.b64encode(data).decode("ascii"),
                "path": path,
            }
            for path, data in sorted(payloads.items())
        ],
    }


def _verify_index(index: Mapping[str, Any], *, expected_layer: Optional[str]) -> None:
    required = {
        "artifacts",
        "index_sha256",
        "layer",
        "manifest",
        "schema_version",
    }
    if set(index) != required:
        raise ArtifactIntegrityError("bundle index fields are incomplete or unknown")
    if index["schema_version"] != BUNDLE_SCHEMA_VERSION:
        raise ArtifactIntegrityError("unsupported artifact bundle schema version")
    layer = index["layer"]
    if not isinstance(layer, str):
        raise ArtifactIntegrityError("bundle layer must be a string")
    try:
        _validate_layer(layer)
    except ArtifactPolicyError as exc:
        raise ArtifactIntegrityError(str(exc)) from exc
    if expected_layer is not None and layer != expected_layer:
        raise ArtifactIntegrityError(
            f"bundle layer mismatch: expected {expected_layer!r}, received {layer!r}"
        )

    claimed_index_sha256 = index["index_sha256"]
    if not isinstance(claimed_index_sha256, str):
        raise ArtifactIntegrityError("index SHA-256 must be a string")
    _validate_sha256(claimed_index_sha256, "index SHA-256")
    body = {key: value for key, value in index.items() if key != "index_sha256"}
    if canonical_sha256(body) != claimed_index_sha256:
        raise ArtifactIntegrityError("bundle index SHA-256 mismatch")

    manifest_descriptor = _manifest_descriptor(index["manifest"])
    expected_manifest_path = (
        "replay-manifest.json" if layer == PUBLISHABLE_LAYER else "protected-audit-manifest.json"
    )
    if manifest_descriptor["path"] != expected_manifest_path:
        raise ArtifactIntegrityError("bundle layer and manifest path disagree")
    artifacts = index["artifacts"]
    if not isinstance(artifacts, list):
        raise ArtifactIntegrityError("bundle artifact index must be an array")
    parsed = [_artifact_file(value) for value in artifacts]
    if parsed != sorted(parsed, key=lambda item: (item.role, item.path)):
        raise ArtifactIntegrityError("bundle artifacts are not in canonical role/path order")
    identities = [(item.role, item.path) for item in parsed]
    if len(identities) != len(set(identities)):
        raise ArtifactIntegrityError("bundle artifact descriptors are duplicated")
    roles = [item.role for item in parsed]
    if len(roles) != len(set(roles)):
        raise ArtifactIntegrityError("bundle artifact roles must be unique")


def _decode_payloads(value: Any) -> dict[str, bytes]:
    if not isinstance(value, list):
        raise ArtifactIntegrityError("bundle payloads must be an array")
    result: dict[str, bytes] = {}
    observed_paths: list[str] = []
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != {"data_base64", "path"}:
            raise ArtifactIntegrityError("bundle payload entry fields are invalid")
        path = entry["path"]
        encoded = entry["data_base64"]
        if not isinstance(path, str) or not isinstance(encoded, str):
            raise ArtifactIntegrityError("bundle payload path and data must be strings")
        _validate_relative_path(path)
        if path in result:
            raise ArtifactIntegrityError(f"duplicate bundle payload path: {path}")
        try:
            data = base64.b64decode(encoded.encode("ascii"), validate=True)
        except (UnicodeEncodeError, binascii.Error) as exc:
            raise ArtifactIntegrityError(f"invalid base64 payload for {path}") from exc
        if base64.b64encode(data).decode("ascii") != encoded:
            raise ArtifactIntegrityError(f"non-canonical base64 payload for {path}")
        result[path] = data
        observed_paths.append(path)
    if observed_paths != sorted(observed_paths):
        raise ArtifactIntegrityError("bundle payloads are not in canonical path order")
    return result


def _verify_payload_bindings(
    index: Mapping[str, Any], payloads: Mapping[str, bytes]
) -> tuple[dict[str, Any], Tuple[ArtifactFile, ...]]:
    manifest_descriptor = _manifest_descriptor(index["manifest"])
    files = tuple(_artifact_file(value) for value in index["artifacts"])
    expected_paths = {manifest_descriptor["path"], *(item.path for item in files)}
    if set(payloads) != expected_paths:
        raise ArtifactIntegrityError("bundle payload set does not match its hash index")

    _verify_descriptor_payload(manifest_descriptor, payloads[manifest_descriptor["path"]])
    manifest_bytes = payloads[manifest_descriptor["path"]]
    try:
        manifest = strict_json_loads(manifest_bytes)
    except ValueError as exc:
        raise ArtifactIntegrityError(f"invalid replay manifest JSON: {exc}") from exc
    if not isinstance(manifest, dict) or canonical_json_bytes(manifest) != manifest_bytes:
        raise ArtifactIntegrityError("replay manifest is not a canonical JSON object")
    expected_file_values = [item.as_dict() for item in files]
    if manifest.get("files") != expected_file_values:
        raise ArtifactIntegrityError("replay manifest file list is not bound to bundle index")

    for artifact in files:
        expected_path = f"objects/sha256/{artifact.sha256}"
        if artifact.path != expected_path:
            raise ArtifactIntegrityError(
                f"artifact path is not content-addressed by its SHA-256: {artifact.path}"
            )
        _verify_descriptor_payload(artifact.as_dict(), payloads[artifact.path])
        if artifact.role in _TRANSCRIPT_ROLES:
            if artifact.media_type != "application/x-ndjson":
                raise ArtifactIntegrityError(
                    f"{artifact.role} is not a canonical application/x-ndjson transcript"
                )
            decode_canonical_transcript(payloads[artifact.path])
    return manifest, files


def _verify_publishable_policy(
    manifest: Mapping[str, Any],
    files: Sequence[ArtifactFile],
    payloads: Mapping[str, bytes],
) -> None:
    _assert_public_value(manifest, path="$.manifest")
    for artifact in files:
        if artifact.role not in _PUBLIC_ROLES:
            raise ArtifactIntegrityError(
                f"non-publishable artifact role found in public bundle: {artifact.role}"
            )
        if artifact.media_type == "application/octet-stream":
            raise ArtifactIntegrityError(
                f"opaque binary artifact cannot be proven publication-safe: {artifact.role}"
            )
        try:
            _assert_public_payload(
                ArtifactPayload(
                    role=artifact.role,
                    data=payloads[artifact.path],
                    media_type=artifact.media_type,
                )
            )
        except ArtifactPolicyError as exc:
            raise ArtifactIntegrityError(str(exc)) from exc


def _verify_credential_policy(
    manifest: Mapping[str, Any],
    files: Sequence[ArtifactFile],
    payloads: Mapping[str, bytes],
) -> None:
    try:
        _assert_credential_free_value(manifest, path="$.manifest")
        for artifact in files:
            _assert_credential_free_payload(
                ArtifactPayload(
                    role=artifact.role,
                    data=payloads[artifact.path],
                    media_type=artifact.media_type,
                )
            )
    except ArtifactPolicyError as exc:
        raise ArtifactIntegrityError(str(exc)) from exc


def _assert_public_payload(artifact: ArtifactPayload) -> None:
    if artifact.media_type == "application/json":
        try:
            value = strict_json_loads(artifact.data)
        except ValueError as exc:
            raise ArtifactPolicyError(
                f"publishable JSON artifact {artifact.role!r} is invalid: {exc}"
            ) from exc
        if canonical_json_bytes(value) != artifact.data:
            raise ArtifactPolicyError(
                f"publishable JSON artifact {artifact.role!r} must be canonical"
            )
        _assert_public_value(value, path=f"$.artifacts.{artifact.role}")
        return
    if artifact.media_type == "application/x-ndjson":
        if not artifact.data:
            return
        if not artifact.data.endswith(b"\n") or b"\r" in artifact.data:
            raise ArtifactPolicyError(
                f"publishable NDJSON artifact {artifact.role!r} must use canonical LF records"
            )
        for index, line in enumerate(artifact.data[:-1].split(b"\n")):
            if not line:
                raise ArtifactPolicyError("publishable NDJSON cannot contain blank records")
            try:
                value = strict_json_loads(line)
            except ValueError as exc:
                raise ArtifactPolicyError(
                    f"publishable NDJSON {artifact.role!r} row {index} is invalid: {exc}"
                ) from exc
            if canonical_json_bytes(value) != line:
                raise ArtifactPolicyError(
                    f"publishable NDJSON {artifact.role!r} row {index} is not canonical"
                )
            _assert_public_value(value, path=f"$.artifacts.{artifact.role}[{index}]")
        return
    raise ArtifactPolicyError(
        f"opaque binary artifact cannot be proven publication-safe: {artifact.role!r}"
    )


def _validate_publishable_manifest(manifest: Mapping[str, Any], *, creating: bool) -> None:
    """Validate the frozen public replay schema at the artifact trust boundary."""

    # Import lazily so the low-level canonical and protocol modules stay acyclic.
    from .schema_validation import DuelSchemaValidator, ProtocolSchemaError

    try:
        DuelSchemaValidator().validate(_REPLAY_MANIFEST_SCHEMA, manifest)
    except (ProtocolSchemaError, ValueError) as exc:
        error_type = ArtifactPolicyError if creating else ArtifactIntegrityError
        raise error_type(f"publishable replay manifest violates frozen schema: {exc}") from exc


def _assert_credential_free_payload(artifact: ArtifactPayload) -> None:
    if artifact.media_type == "application/json":
        try:
            value = strict_json_loads(artifact.data)
        except ValueError as exc:
            raise ArtifactPolicyError(f"JSON artifact {artifact.role!r} is invalid: {exc}") from exc
        _assert_credential_free_value(value, path=f"$.artifacts.{artifact.role}")
        return
    if artifact.media_type == "application/x-ndjson":
        if not artifact.data:
            return
        if not artifact.data.endswith(b"\n") or b"\r" in artifact.data:
            raise ArtifactPolicyError(
                f"NDJSON artifact {artifact.role!r} must use LF-terminated records"
            )
        for index, line in enumerate(artifact.data[:-1].split(b"\n")):
            if not line:
                raise ArtifactPolicyError("NDJSON cannot contain blank records")
            try:
                value = strict_json_loads(line)
            except ValueError as exc:
                raise ArtifactPolicyError(
                    f"NDJSON {artifact.role!r} row {index} is invalid: {exc}"
                ) from exc
            _assert_credential_free_value(value, path=f"$.artifacts.{artifact.role}[{index}]")
        return
    _assert_no_secret_text(artifact.data, context=f"binary artifact {artifact.role!r}")


def _assert_public_value(value: Any, *, path: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = re.sub(r"[^a-z0-9]", "", str(key).casefold())
            if normalized in _FORBIDDEN_PUBLIC_PRIVATE_KEYS:
                raise ArtifactPolicyError(f"private field cannot be published at {path}.{key}")
            _assert_public_value(child, path=f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, child in enumerate(value):
            _assert_public_value(child, path=f"{path}[{index}]")
    elif isinstance(value, str):
        _assert_no_secret_text(value.encode("utf-8"), context=path)


def _assert_credential_free_value(value: Any, *, path: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = re.sub(r"[^a-z0-9]", "", str(key).casefold())
            if normalized in _FORBIDDEN_CREDENTIAL_KEYS or normalized.endswith(
                ("apikey", "password", "privatekey", "secret", "token")
            ):
                raise ArtifactPolicyError(f"credential field cannot enter artifact at {path}.{key}")
            _assert_credential_free_value(child, path=f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, child in enumerate(value):
            _assert_credential_free_value(child, path=f"{path}[{index}]")
    elif isinstance(value, str):
        _assert_no_secret_text(value.encode("utf-8"), context=path)


def _assert_no_secret_text(value: bytes, *, context: str) -> None:
    text = value.decode("utf-8", errors="ignore")
    if any(pattern.search(text) for pattern in _SECRET_TEXT_PATTERNS):
        raise ArtifactPolicyError(f"secret-like value cannot be published in {context}")


def _manifest_descriptor(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "bytes",
        "media_type",
        "path",
        "sha256",
    }:
        raise ArtifactIntegrityError("manifest descriptor fields are invalid")
    if value["media_type"] != "application/json":
        raise ArtifactIntegrityError("bundle manifest media type must be application/json")
    if not isinstance(value["path"], str):
        raise ArtifactIntegrityError("bundle manifest path must be a string")
    _validate_relative_path(value["path"])
    if value["path"] not in {"replay-manifest.json", "protected-audit-manifest.json"}:
        raise ArtifactIntegrityError("bundle manifest path is not recognized")
    _descriptor_scalars(value)
    return dict(value)


def _artifact_file(value: Any) -> ArtifactFile:
    if not isinstance(value, dict) or set(value) != {
        "bytes",
        "media_type",
        "path",
        "role",
        "sha256",
    }:
        raise ArtifactIntegrityError("artifact descriptor fields are invalid")
    role = value["role"]
    path = value["path"]
    media_type = value["media_type"]
    if not isinstance(role, str) or not isinstance(path, str) or not isinstance(media_type, str):
        raise ArtifactIntegrityError("artifact descriptor strings are invalid")
    try:
        _validate_role(role)
        _validate_relative_path(path)
    except ArtifactPolicyError as exc:
        raise ArtifactIntegrityError(str(exc)) from exc
    if media_type not in _MEDIA_TYPES:
        raise ArtifactIntegrityError(f"unsupported artifact media type: {media_type!r}")
    _descriptor_scalars(value)
    return ArtifactFile(
        role=role,
        path=path,
        sha256=str(value["sha256"]),
        bytes=int(value["bytes"]),
        media_type=media_type,
    )


def _descriptor_scalars(value: Mapping[str, Any]) -> None:
    size = value["bytes"]
    sha256 = value["sha256"]
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        raise ArtifactIntegrityError("artifact byte size must be a non-negative integer")
    if not isinstance(sha256, str):
        raise ArtifactIntegrityError("artifact SHA-256 must be a string")
    _validate_sha256(sha256, "artifact SHA-256")


def _verify_descriptor_payload(descriptor: Mapping[str, Any], payload: bytes) -> None:
    if len(payload) != descriptor["bytes"]:
        raise ArtifactIntegrityError(f"artifact byte-size mismatch: {descriptor['path']}")
    if hashlib.sha256(payload).hexdigest() != descriptor["sha256"]:
        raise ArtifactIntegrityError(f"artifact SHA-256 mismatch: {descriptor['path']}")


def _validate_layer(layer: str) -> None:
    if layer not in {PUBLISHABLE_LAYER, PROTECTED_AUDIT_LAYER}:
        raise ArtifactPolicyError(f"unsupported artifact layer: {layer!r}")


def _validate_role(role: str) -> None:
    if not isinstance(role, str) or _ROLE_RE.fullmatch(role) is None:
        raise ArtifactPolicyError(f"unsafe artifact role: {role!r}")


def _validate_sha256(value: str, context: str) -> None:
    if _SHA256_RE.fullmatch(value) is None:
        raise ArtifactIntegrityError(f"{context} must be 64 lower-case hexadecimal characters")


def _validate_relative_path(value: str) -> None:
    if not value or "\\" in value or "\x00" in value:
        raise ArtifactIntegrityError(f"unsafe bundle-relative path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ArtifactIntegrityError(f"unsafe bundle-relative path: {value!r}")
    if path.as_posix() != value:
        raise ArtifactIntegrityError(f"non-canonical bundle-relative path: {value!r}")
    has_control = any(
        any(ord(character) < 32 or ord(character) == 127 for character in part)
        for part in path.parts
    )
    if has_control:
        raise ArtifactIntegrityError(f"control character in bundle-relative path: {value!r}")


def _safe_child(root: Path, relative: str) -> Path:
    _validate_relative_path(relative)
    resolved_root = root.resolve()
    candidate = (resolved_root / PurePosixPath(relative)).resolve()
    try:
        candidate.relative_to(resolved_root)
    except ValueError as exc:
        raise ArtifactIntegrityError(f"bundle path escapes destination: {relative!r}") from exc
    return candidate


def _require_regular_file(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as exc:
        raise ArtifactIntegrityError(f"bundle file is missing: {path}") from exc
    if not stat.S_ISREG(mode):
        raise ArtifactIntegrityError(f"bundle entry is not a regular file: {path}")


def _write_new_file(path: Path, data: bytes) -> None:
    with path.open("xb") as handle:
        handle.write(data)
