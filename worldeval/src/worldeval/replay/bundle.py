"""Immutable outer replay bundles for demos and evaluation evidence.

Native replay formats remain owned by their games.  This module provides a small,
game-neutral integrity envelope around those bytes and deliberately does not interpret
authority state itself.
"""

from __future__ import annotations

import hashlib
import hmac
import importlib.resources
import os
import re
import shutil
import stat
import tempfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from types import MappingProxyType
from typing import Any, Callable, Dict, Iterable, Mapping, Sequence, Tuple, Union

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError, ValidationError

from worldeval.workspace import WorkspaceError, find_workspace

from .canonical import (
    CANONICAL_JSON_PROFILE,
    CanonicalJSONError,
    canonical_json_bytes,
    canonical_sha256,
    require_canonical_json_bytes,
    strict_json_loads,
)

BUNDLE_SCHEMA = "worldeval/replay-bundle/1.0.0"
INCOMPLETE_RUN_SCHEMA = "worldeval/incomplete-run/1.0.0"
MANIFEST_FILENAME = "manifest.json"
INCOMPLETE_RUN_FILENAME = "incomplete-run.json"
PUBLIC = "public"
PROTECTED = "protected"

_RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_ROLE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}$")
_HASH_ID = re.compile(r"^(?:sha256:)?[0-9a-f]{64}$")
_KINDS = frozenset({"replay", "evidence", "media"})
_VISIBILITIES = frozenset({PUBLIC, PROTECTED})
_KIND_DIRECTORIES = {"replay": "replays", "evidence": "evidence", "media": "media"}
_RESERVED_MANIFEST_FIELDS = frozenset({"schema", "canonical_json", "artifacts", "seal"})

ArtifactData = Union[bytes, bytearray, memoryview, Path]


@dataclass(frozen=True)
class NativeReplayClaims:
    """Authority-confirmed identities used to bind an outer manifest.

    Native verifiers populate this only after deterministic replay execution.
    The game-neutral bundle layer then compares these facts with the manifest
    and with recomputed evidence digests.
    """

    protocol_id: str
    protocol_version: str
    protocol_package_hash: str
    game_id: str
    environment_id: str
    engine_id: str
    engine_build_hash: str
    run_id: str
    scenario_id: str
    objective_id: str
    action_profile: str
    observation_profile: str
    decision_profile: str
    initialization_hash: str
    terminal_outcome: str
    terminal_tick: int
    evidence_sha256: Mapping[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for field_name in (
            "protocol_id",
            "protocol_version",
            "game_id",
            "environment_id",
            "engine_id",
            "run_id",
            "scenario_id",
            "objective_id",
            "action_profile",
            "observation_profile",
            "decision_profile",
            "terminal_outcome",
        ):
            _validate_identifier(getattr(self, field_name), field_name)
        if _HASH_ID.fullmatch(self.protocol_package_hash) is None:
            raise ValueError("native claims protocol package hash is invalid")
        if _HASH_ID.fullmatch(self.engine_build_hash) is None:
            raise ValueError("native claims engine build hash is invalid")
        if _HASH_ID.fullmatch(self.initialization_hash) is None:
            raise ValueError("native claims initialization hash is invalid")
        if (
            isinstance(self.terminal_tick, bool)
            or not isinstance(self.terminal_tick, int)
            or self.terminal_tick < 0
        ):
            raise ValueError("native claims terminal tick is invalid")
        normalized: Dict[str, str] = {}
        for role, digest in self.evidence_sha256.items():
            if not isinstance(role, str) or _ROLE.fullmatch(role) is None:
                raise ValueError("native claims evidence role is invalid")
            if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                raise ValueError("native claims evidence digest is invalid")
            normalized[role] = digest
        object.__setattr__(
            self,
            "evidence_sha256",
            MappingProxyType(dict(sorted(normalized.items()))),
        )


@dataclass(frozen=True)
class NativeVerificationResult:
    """Facts measured by re-executing one native replay offline.

    ``provider_calls`` is deliberately measured by the native verifier rather than
    copied from the outer manifest.  Older verifier callbacks may continue to
    return only a final-state hash, but they cannot satisfy provider-free public
    verification gates until they return this result.
    """

    final_state_hash: str
    provider_calls: int | None = None
    claims: NativeReplayClaims | None = None

    def __post_init__(self) -> None:
        if (
            not isinstance(self.final_state_hash, str)
            or _HASH_ID.fullmatch(self.final_state_hash) is None
        ):
            raise ValueError("native verification final_state_hash is invalid")
        if self.provider_calls is not None and (
            isinstance(self.provider_calls, bool)
            or not isinstance(self.provider_calls, int)
            or self.provider_calls < 0
        ):
            raise ValueError("native verification provider_calls is invalid")
        if self.claims is not None and not isinstance(
            self.claims, NativeReplayClaims
        ):
            raise TypeError("native verification claims are invalid")


NativeVerifierOutput = Union[str, NativeVerificationResult]
NativeVerifier = Callable[[bytes, Mapping[str, Any]], NativeVerifierOutput]
NativeVerifierKey = Tuple[str, str]
NativeVerifierMappingKey = Union[str, NativeVerifierKey]


class NativeVerifierRegistry:
    """Immutable exact dispatch keyed by ``(verifier, native_schema)``.

    Exact pairs prevent a verifier written for one native replay schema from
    being silently reused for another.  The legacy ``Mapping[str, callback]``
    accepted by :func:`verify_replay_bundle` remains supported for compatibility,
    but public catalogs should use this registry.
    """

    def __init__(self, verifiers: Mapping[NativeVerifierKey, NativeVerifier]) -> None:
        callbacks: Dict[NativeVerifierKey, NativeVerifier] = {}
        for key, callback in verifiers.items():
            if (
                not isinstance(key, tuple)
                or len(key) != 2
                or not callable(callback)
            ):
                raise TypeError(
                    "native verifier registry entries must map "
                    "(verifier, native_schema) pairs to callables"
                )
            verifier_id, native_schema = key
            _validate_identifier(verifier_id, "native replay verifier")
            _validate_identifier(native_schema, "native replay schema")
            callbacks[(verifier_id, native_schema)] = callback
        self._callbacks = MappingProxyType(callbacks)

    def resolve(self, verifier: str, native_schema: str) -> NativeVerifier | None:
        """Return only an exact verifier/schema registration."""

        return self._callbacks.get((verifier, native_schema))

    @property
    def keys(self) -> Tuple[NativeVerifierKey, ...]:
        return tuple(sorted(self._callbacks))


NativeVerifierSource = Union[
    NativeVerifierRegistry,
    Mapping[NativeVerifierMappingKey, NativeVerifier],
]


class ReplayBundleError(ValueError):
    """A replay bundle could not be constructed or interpreted safely."""


class UnsafeBundlePathError(ReplayBundleError):
    """A bundle path could escape its immutable bundle directory."""


class BundleExistsError(ReplayBundleError):
    """The requested run identifier already has an immutable record."""


class BundleVerificationError(ReplayBundleError):
    """Replay bundle structure, encoding, or content integrity differs."""


class ProtectedArtifactError(PermissionError, ReplayBundleError):
    """A protected artifact was requested through the public access path."""


@dataclass(frozen=True)
class ArtifactInput:
    """One native replay, evidence file, or optional derived-media input."""

    path: str
    role: str
    kind: str
    data: ArtifactData
    visibility: str = PROTECTED
    media_type: str = "application/octet-stream"
    native_schema: str | None = None
    verifier: str | None = None
    final_state_hash: str | None = None
    leg: int | None = None
    participants: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _validate_artifact_identity(self)
        if isinstance(self.data, memoryview):
            object.__setattr__(self, "data", self.data.tobytes())
        elif isinstance(self.data, bytearray):
            object.__setattr__(self, "data", bytes(self.data))
        elif not isinstance(self.data, (bytes, Path)):
            raise TypeError("artifact data must be immutable bytes or a Path")
        if not isinstance(self.participants, tuple):
            object.__setattr__(self, "participants", tuple(self.participants))
        if self.media_type == "application/json" and isinstance(self.data, bytes):
            try:
                require_canonical_json_bytes(self.data)
            except CanonicalJSONError as error:
                raise ReplayBundleError("JSON artifact bytes must be canonical") from error

    @classmethod
    def json(
        cls,
        *,
        path: str,
        role: str,
        kind: str,
        value: Any,
        visibility: str = PROTECTED,
        native_schema: str | None = None,
        verifier: str | None = None,
        final_state_hash: str | None = None,
        leg: int | None = None,
        participants: Sequence[str] = (),
    ) -> ArtifactInput:
        """Create an artifact whose JSON encoding is canonical by construction."""

        return cls(
            path=path,
            role=role,
            kind=kind,
            data=canonical_json_bytes(value),
            visibility=visibility,
            media_type="application/json",
            native_schema=native_schema,
            verifier=verifier,
            final_state_hash=final_state_hash,
            leg=leg,
            participants=tuple(participants),
        )


@dataclass(frozen=True)
class VerificationReport:
    """Verified public facts about an immutable replay bundle."""

    bundle_path: Path
    manifest: Mapping[str, Any]
    verified_paths: Tuple[str, ...]
    missing_optional_media: Tuple[str, ...]
    native_verifications: Mapping[str, NativeVerificationResult] = field(
        default_factory=lambda: MappingProxyType({})
    )

    @property
    def media_complete(self) -> bool:
        return not self.missing_optional_media

    @property
    def independent_offline_verification(self) -> Mapping[str, Any] | None:
        """Return independently measured replay facts, never manifest claims."""

        if not self.native_verifications:
            return None
        descriptors = {
            descriptor["path"]: descriptor
            for descriptor in self.manifest["artifacts"]
            if descriptor["kind"] == "replay"
        }
        verifier_ids = {
            descriptors[path]["verifier"] for path in self.native_verifications
        }
        provider_calls = [
            result.provider_calls for result in self.native_verifications.values()
        ]
        if any(value is None for value in provider_calls):
            measured_calls: int | None = None
        else:
            measured_calls = sum(int(value) for value in provider_calls)
        return MappingProxyType(
            {
                "verified": True,
                "provider_calls": measured_calls,
                "verifier": (
                    next(iter(verifier_ids))
                    if len(verifier_ids) == 1
                    else "+".join(sorted(verifier_ids))
                ),
            }
        )


def manifest_schema_path() -> Path:
    """Return the checked-in JSON Schema path for the outer manifest."""

    return _protocol_schema_path("replay-bundle.v1.schema.json")


def incomplete_run_schema_path() -> Path:
    """Return the checked-in JSON Schema path for incomplete-run diagnostics."""

    return _protocol_schema_path("incomplete-run.v1.schema.json")


def _protocol_schema_path(filename: str) -> Path:
    try:
        workspace_path = (
            find_workspace(__file__).path("worldeval")
            / "protocols"
            / "replay"
            / "1.0.0"
            / filename
        )
    except WorkspaceError:
        workspace_path = None
    if workspace_path is not None and workspace_path.is_file():
        return workspace_path
    installed_path = (
        Path(str(importlib.resources.files("worldeval")))
        / "protocols"
        / "replay"
        / "1.0.0"
        / filename
    )
    return installed_path


def write_terminal_demo_bundle(
    replay_root: Path,
    *,
    metadata: Mapping[str, Any],
    artifacts: Iterable[ArtifactInput],
    native_verifiers: NativeVerifierSource,
    require_claim_binding: bool = False,
) -> Path:
    """Seal, independently verify, and atomically publish one terminal demo.

    ``metadata`` supplies the run/game/protocol/profile/terminal identity.  The framework
    derives all artifact hashes and the outer seal.  A native verifier is mandatory for
    every replay descriptor, ensuring that a terminal demo cannot be persisted merely
    because its outer files happen to hash correctly.
    """

    if not isinstance(metadata, Mapping):
        raise TypeError("metadata must be a mapping")
    body = dict(metadata)
    if _RESERVED_MANIFEST_FIELDS.intersection(body):
        raise ReplayBundleError("metadata contains framework-owned manifest fields")
    run_id = body.get("run_id")
    _validate_run_id(run_id)
    selected = tuple(artifacts)
    if any(not isinstance(item, ArtifactInput) for item in selected):
        raise TypeError("artifacts must contain only ArtifactInput values")
    _validate_artifact_set(selected)

    def populate(staging: Path) -> None:
        descriptors = tuple(_write_artifact(staging, item) for item in sorted(selected, key=_key))
        manifest_body = {
            **body,
            "schema": BUNDLE_SCHEMA,
            "canonical_json": CANONICAL_JSON_PROFILE,
            "artifacts": list(descriptors),
        }
        manifest = {
            **manifest_body,
            "seal": {"algorithm": "sha256", "value": canonical_sha256(manifest_body)},
        }
        _validate_manifest(manifest)
        _write_new_file(staging / MANIFEST_FILENAME, canonical_json_bytes(manifest))
        verify_replay_bundle(
            staging,
            native_verifiers=native_verifiers,
            require_native_verification=True,
            require_claim_binding=require_claim_binding,
        )

    return _atomic_publish(Path(replay_root), run_id, populate)


def write_incomplete_run(
    replay_root: Path,
    *,
    run_id: str,
    phase: str,
    reason: str,
    recoverable: bool,
    last_tick: int | None = None,
    details: Mapping[str, Any] | None = None,
) -> Path:
    """Atomically persist a non-replay diagnostic for an unsealable run."""

    _validate_run_id(run_id)
    if not isinstance(phase, str) or not phase:
        raise ReplayBundleError("incomplete-run phase must be non-empty")
    if not isinstance(reason, str) or not reason:
        raise ReplayBundleError("incomplete-run reason must be non-empty")
    if not isinstance(recoverable, bool):
        raise ReplayBundleError("incomplete-run recoverable must be boolean")
    if last_tick is not None and (
        isinstance(last_tick, bool) or not isinstance(last_tick, int) or last_tick < 0
    ):
        raise ReplayBundleError("incomplete-run last_tick must be a non-negative integer")
    if details is not None and not isinstance(details, Mapping):
        raise ReplayBundleError("incomplete-run details must be an object")
    body: Dict[str, Any] = {
        "schema": INCOMPLETE_RUN_SCHEMA,
        "canonical_json": CANONICAL_JSON_PROFILE,
        "run_id": run_id,
        "phase": phase,
        "reason": reason,
        "recoverable": recoverable,
    }
    if last_tick is not None:
        body["last_tick"] = last_tick
    if details is not None:
        body["details"] = dict(details)
    diagnostic = {
        **body,
        "seal": {"algorithm": "sha256", "value": canonical_sha256(body)},
    }

    def populate(staging: Path) -> None:
        _write_new_file(staging / INCOMPLETE_RUN_FILENAME, canonical_json_bytes(diagnostic))

    return _atomic_publish(Path(replay_root), run_id, populate)


def load_incomplete_run(path: Path) -> Mapping[str, Any]:
    """Load and authenticate a diagnostic, never treating it as a replay."""

    selected = Path(path)
    if selected.is_symlink():
        raise BundleVerificationError("incomplete-run diagnostic is symlinked")
    if selected.is_dir():
        selected = selected / INCOMPLETE_RUN_FILENAME
    if selected.is_symlink() or not selected.is_file():
        raise BundleVerificationError("incomplete-run diagnostic is unavailable")
    try:
        value = require_canonical_json_bytes(selected.read_bytes())
    except (OSError, CanonicalJSONError) as error:
        raise BundleVerificationError("incomplete-run diagnostic is invalid") from error
    if not isinstance(value, dict):
        raise BundleVerificationError("incomplete-run diagnostic must be an object")
    _validate_schema_instance(
        value,
        schema_path=incomplete_run_schema_path(),
        label="incomplete-run diagnostic",
    )
    seal = value.get("seal")
    body = {key: child for key, child in value.items() if key != "seal"}
    expected = canonical_sha256(body)
    if (
        not isinstance(seal, dict)
        or set(seal) != {"algorithm", "value"}
        or seal.get("algorithm") != "sha256"
        or not isinstance(seal.get("value"), str)
        or not hmac.compare_digest(seal["value"], expected)
    ):
        raise BundleVerificationError("incomplete-run seal differs")
    _validate_run_id(value.get("run_id"))
    return MappingProxyType(value)


def verify_replay_bundle(
    bundle_path: Path,
    *,
    native_verifiers: NativeVerifierSource | None = None,
    require_native_verification: bool = False,
    require_provider_calls_zero: bool = False,
    require_claim_binding: bool = False,
    require_media: bool = False,
) -> VerificationReport:
    """Verify the outer bundle and, when requested, native replay execution.

    ``require_provider_calls_zero`` is stronger than checking the signed
    manifest: each native verifier must return a measured provider-call count of
    zero, and the declared outer verifier must match the exact verifier selected
    from the registry.
    """

    bundle = Path(bundle_path)
    if bundle.is_symlink() or not bundle.is_dir():
        raise BundleVerificationError("replay bundle directory is unavailable or symlinked")
    manifest_path = bundle / MANIFEST_FILENAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise BundleVerificationError("replay bundle manifest is unavailable or symlinked")
    try:
        manifest = require_canonical_json_bytes(manifest_path.read_bytes())
    except (OSError, CanonicalJSONError) as error:
        raise BundleVerificationError("replay bundle manifest is not canonical JSON") from error
    if not isinstance(manifest, dict):
        raise BundleVerificationError("replay bundle manifest must be an object")
    _validate_manifest(manifest)
    _verify_manifest_seal(manifest)

    descriptors = manifest["artifacts"]
    paths = tuple(descriptor["path"] for descriptor in descriptors)
    _validate_inventory(bundle, descriptors)
    verified: list[str] = []
    missing_media: list[str] = []
    native_results: Dict[str, NativeVerificationResult] = {}
    json_artifacts: Dict[str, Any] = {}
    for descriptor in descriptors:
        relative = descriptor["path"]
        target = _safe_child(bundle, relative)
        if not os.path.lexists(target):
            if descriptor["kind"] == "media" and descriptor.get("optional") is True:
                if require_media:
                    raise BundleVerificationError(
                        f"optional media is required but missing: {relative}"
                    )
                missing_media.append(relative)
                continue
            raise BundleVerificationError(f"declared artifact is missing: {relative}")
        _assert_regular_unsymlinked_file(target, relative)
        try:
            payload = target.read_bytes()
        except OSError as error:
            raise BundleVerificationError(f"artifact cannot be read: {relative}") from error
        if len(payload) != descriptor["size_bytes"]:
            raise BundleVerificationError(f"artifact size differs: {relative}")
        digest = hashlib.sha256(payload).hexdigest()
        if not hmac.compare_digest(digest, descriptor["sha256"]):
            raise BundleVerificationError(f"artifact digest differs: {relative}")
        if descriptor["media_type"] == "application/json":
            try:
                json_value = require_canonical_json_bytes(payload)
            except CanonicalJSONError as error:
                raise BundleVerificationError(
                    f"JSON artifact is not canonical: {relative}"
                ) from error
            json_artifacts[descriptor["role"]] = json_value
        if descriptor["kind"] == "replay":
            verifier_id = descriptor["verifier"]
            native_schema = descriptor["native_schema"]
            callback = _resolve_native_verifier(
                native_verifiers,
                verifier_id=verifier_id,
                native_schema=native_schema,
            )
            if callback is None:
                if require_native_verification or require_provider_calls_zero:
                    raise BundleVerificationError(
                        "native replay verifier is unavailable: "
                        f"{verifier_id} for {native_schema}"
                    )
            else:
                try:
                    result = _normalize_native_verification(
                        callback(payload, MappingProxyType(dict(descriptor)))
                    )
                except Exception as error:
                    raise BundleVerificationError(
                        f"native replay verification failed: {relative}"
                    ) from error
                if not hmac.compare_digest(
                    result.final_state_hash, descriptor["final_state_hash"]
                ):
                    raise BundleVerificationError(
                        f"native replay final-state hash differs: {relative}"
                    )
                if require_provider_calls_zero and result.provider_calls != 0:
                    raise BundleVerificationError(
                        "native replay provider calls are not independently zero: "
                        f"{relative}"
                    )
                native_results[relative] = result
        verified.append(relative)

    if tuple(sorted(paths)) != paths:
        raise BundleVerificationError("artifact descriptors are not path-sorted")
    if require_provider_calls_zero:
        replay_paths = {
            descriptor["path"]
            for descriptor in descriptors
            if descriptor["kind"] == "replay"
        }
        if set(native_results) != replay_paths:
            raise BundleVerificationError(
                "every replay requires independent provider-free verification"
            )
        verifier_ids = {
            descriptor["verifier"]
            for descriptor in descriptors
            if descriptor["kind"] == "replay"
        }
        declared = manifest["offline_verification"]["verifier"]
        if verifier_ids != {declared}:
            raise BundleVerificationError(
                "declared offline verifier differs from native verifier dispatch"
            )
    claims_present = any(
        result.claims is not None for result in native_results.values()
    )
    if require_claim_binding and (
        not native_results
        or any(result.claims is None for result in native_results.values())
    ):
        raise BundleVerificationError(
            "every native replay requires authority-confirmed outer claims"
        )
    if claims_present:
        _verify_authority_claim_binding(
            manifest,
            descriptors,
            json_artifacts,
            native_results,
        )
    return VerificationReport(
        bundle_path=bundle,
        manifest=MappingProxyType(manifest),
        verified_paths=tuple(verified),
        missing_optional_media=tuple(missing_media),
        native_verifications=MappingProxyType(native_results),
    )


def _verify_authority_claim_binding(
    manifest: Mapping[str, Any],
    descriptors: Sequence[Mapping[str, Any]],
    json_artifacts: Mapping[str, Any],
    native_results: Mapping[str, NativeVerificationResult],
) -> None:
    """Bind outer and evidence identities to facts confirmed by authority."""

    descriptor_by_path = {value["path"]: value for value in descriptors}
    descriptors_by_role: Dict[str, list[Mapping[str, Any]]] = {}
    for descriptor in descriptors:
        descriptors_by_role.setdefault(descriptor["role"], []).append(descriptor)

    for replay_path, result in native_results.items():
        claims = result.claims
        if claims is None:
            continue
        replay_descriptor = descriptor_by_path[replay_path]
        expected_outer = {
            "run_id": (manifest["run_id"], claims.run_id),
            "game": (manifest["game"]["id"], claims.game_id),
            "scenario": (manifest["scenario"]["id"], claims.scenario_id),
            "task": (manifest["task"]["id"], claims.objective_id),
            "protocol_id": (manifest["protocol"]["id"], claims.protocol_id),
            "protocol_version": (
                manifest["protocol"]["version"],
                claims.protocol_version,
            ),
            "protocol_package_hash": (
                manifest["protocol"]["package_hash"],
                claims.protocol_package_hash,
            ),
            "engine_id": (
                manifest["engine"]["id"],
                claims.engine_id,
            ),
            "engine_build_hash": (
                manifest["engine"]["build_hash"],
                claims.engine_build_hash,
            ),
            "action_profile": (
                manifest["profiles"]["action"],
                claims.action_profile,
            ),
            "observation_profile": (
                manifest["profiles"]["observation"],
                claims.observation_profile,
            ),
            "decision_profile": (
                manifest["profiles"]["decision"],
                claims.decision_profile,
            ),
            "terminal_outcome": (
                manifest["terminal"]["outcome"],
                claims.terminal_outcome,
            ),
            "terminal_tick": (
                manifest["terminal"]["tick_count"],
                claims.terminal_tick,
            ),
            "offline_verifier": (
                manifest["offline_verification"]["verifier"],
                replay_descriptor["verifier"],
            ),
        }
        for field_name, (declared, authoritative) in expected_outer.items():
            if declared != authoritative:
                raise BundleVerificationError(
                    f"outer {field_name} differs from authority-confirmed replay"
                )

        required_roles = {"environment_init", "objective", "evaluation"}
        if not required_roles.issubset(claims.evidence_sha256):
            raise BundleVerificationError(
                "native claims lack required recomputed evidence digests"
            )
        for role, expected_digest in claims.evidence_sha256.items():
            matches = descriptors_by_role.get(role, [])
            if len(matches) != 1:
                raise BundleVerificationError(
                    f"authority-bound evidence role is unavailable or ambiguous: {role}"
                )
            if not hmac.compare_digest(matches[0]["sha256"], expected_digest):
                raise BundleVerificationError(
                    f"{role} evidence differs from authority-derived content"
                )

        initialization = json_artifacts.get("environment_init")
        objective = json_artifacts.get("objective")
        evaluation = json_artifacts.get("evaluation")
        result_evidence = json_artifacts.get("result")
        if not all(
            isinstance(value, dict)
            for value in (initialization, objective, evaluation, result_evidence)
        ):
            raise BundleVerificationError(
                "authority-bound JSON evidence is incomplete"
            )
        expected_protocol = f"{claims.protocol_id}/{claims.protocol_version}"
        expected_initialization = {
            "protocol": expected_protocol,
            "game_id": claims.game_id,
            "environment_id": claims.environment_id,
            "initialization_hash": claims.initialization_hash,
            "profiles": {
                "action": claims.action_profile,
                "observation": claims.observation_profile,
                "decision": claims.decision_profile,
            },
        }
        for field_name, expected in expected_initialization.items():
            if initialization.get(field_name) != expected:
                raise BundleVerificationError(
                    f"environment_init {field_name} differs from authority claims"
                )
        if initialization.get("active_objective") != objective:
            raise BundleVerificationError(
                "environment_init active objective differs from objective evidence"
            )
        if objective.get("objective_id") != claims.objective_id:
            raise BundleVerificationError(
                "objective evidence differs from authority-confirmed task"
            )
        expected_evaluation = {
            "objective_id": claims.objective_id,
            "outcome": claims.terminal_outcome,
            "terminal_tick": claims.terminal_tick,
            "replay_saved": True,
            "replay_offline_verified": True,
        }
        for field_name, expected in expected_evaluation.items():
            if evaluation.get(field_name) != expected:
                raise BundleVerificationError(
                    f"evaluation {field_name} differs from authority claims"
                )
        expected_result = {
            "run_id": claims.run_id,
            "scenario_id": claims.scenario_id,
            "outcome": claims.terminal_outcome,
            "terminal_tick": claims.terminal_tick,
            "terminal_state_hash": result.final_state_hash,
            "passed": evaluation.get("passed"),
        }
        for field_name, expected in expected_result.items():
            if result_evidence.get(field_name) != expected:
                raise BundleVerificationError(
                    f"result {field_name} differs from authority claims"
                )


def resolve_artifact(
    bundle_path: Path,
    role: str,
    *,
    leg: int | None = None,
    allow_protected: bool = False,
    native_verifiers: NativeVerifierSource | None = None,
    require_native_verification: bool = False,
    require_provider_calls_zero: bool = False,
    require_claim_binding: bool = False,
) -> Path:
    """Resolve an integrity-checked artifact while enforcing its disclosure layer."""

    report = verify_replay_bundle(
        bundle_path,
        native_verifiers=native_verifiers,
        require_native_verification=require_native_verification,
        require_provider_calls_zero=require_provider_calls_zero,
        require_claim_binding=require_claim_binding,
    )
    matches = [
        descriptor
        for descriptor in report.manifest["artifacts"]
        if descriptor["role"] == role and (leg is None or descriptor.get("leg") == leg)
    ]
    if not matches:
        raise ReplayBundleError("artifact role is unavailable")
    if len(matches) != 1:
        raise ReplayBundleError("artifact role is ambiguous; provide its leg")
    descriptor = matches[0]
    if descriptor["visibility"] == PROTECTED and not allow_protected:
        raise ProtectedArtifactError("protected artifact is not publicly accessible")
    target = _safe_child(report.bundle_path, descriptor["path"])
    if not target.is_file():
        raise ReplayBundleError("optional artifact is not currently materialized")
    return target


def public_artifacts(
    bundle_path: Path,
    *,
    native_verifiers: NativeVerifierSource | None = None,
    require_native_verification: bool = False,
    require_provider_calls_zero: bool = False,
    require_claim_binding: bool = False,
) -> Tuple[Mapping[str, Any], ...]:
    """Return only integrity-checked descriptors that are safe for public projection."""

    report = verify_replay_bundle(
        bundle_path,
        native_verifiers=native_verifiers,
        require_native_verification=require_native_verification,
        require_provider_calls_zero=require_provider_calls_zero,
        require_claim_binding=require_claim_binding,
    )
    return tuple(
        MappingProxyType(dict(descriptor))
        for descriptor in report.manifest["artifacts"]
        if descriptor["visibility"] == PUBLIC
    )


def _resolve_native_verifier(
    source: NativeVerifierSource | None,
    *,
    verifier_id: str,
    native_schema: str,
) -> NativeVerifier | None:
    if source is None:
        return None
    if isinstance(source, NativeVerifierRegistry):
        return source.resolve(verifier_id, native_schema)
    callback = source.get((verifier_id, native_schema))
    if callback is None:
        # Compatibility for existing writers.  New public read paths use the
        # exact registry above so a schema change cannot inherit old authority.
        callback = source.get(verifier_id)
    if callback is not None and not callable(callback):
        raise TypeError("native verifier mapping values must be callable")
    return callback


def _normalize_native_verification(
    value: NativeVerifierOutput,
) -> NativeVerificationResult:
    if isinstance(value, NativeVerificationResult):
        return value
    if isinstance(value, str):
        return NativeVerificationResult(final_state_hash=value)
    raise TypeError(
        "native verifier must return a final-state hash or NativeVerificationResult"
    )


def _validate_run_id(value: object) -> None:
    if not isinstance(value, str) or _RUN_ID.fullmatch(value) is None or value in {".", ".."}:
        raise ReplayBundleError("run_id is invalid")


def _validate_identifier(value: object, field: str) -> None:
    if not isinstance(value, str) or _IDENTIFIER.fullmatch(value) is None:
        raise ReplayBundleError(f"{field} is invalid")


def _validate_artifact_identity(item: ArtifactInput) -> None:
    _validate_relative_path(item.path, expected_kind=item.kind)
    if _ROLE.fullmatch(item.role) is None:
        raise ReplayBundleError("artifact role is invalid")
    if item.kind not in _KINDS:
        raise ReplayBundleError("artifact kind is invalid")
    if item.visibility not in _VISIBILITIES:
        raise ReplayBundleError("artifact visibility is invalid")
    if not isinstance(item.media_type, str) or not item.media_type or len(item.media_type) > 255:
        raise ReplayBundleError("artifact media_type is invalid")
    if item.leg is not None and (
        isinstance(item.leg, bool) or not isinstance(item.leg, int) or item.leg < 0
    ):
        raise ReplayBundleError("artifact leg is invalid")
    for participant in item.participants:
        _validate_identifier(participant, "artifact participant")
    if len(item.participants) != len(set(item.participants)):
        raise ReplayBundleError("artifact participants must be unique")
    if item.kind == "replay":
        _validate_identifier(item.native_schema, "native replay schema")
        _validate_identifier(item.verifier, "native replay verifier")
        if not isinstance(item.final_state_hash, str) or _HASH_ID.fullmatch(
            item.final_state_hash
        ) is None:
            raise ReplayBundleError("native replay final_state_hash is invalid")
    elif any(
        value is not None for value in (item.native_schema, item.verifier, item.final_state_hash)
    ):
        raise ReplayBundleError("native replay fields are forbidden for non-replay artifacts")


def _validate_artifact_set(artifacts: Sequence[ArtifactInput]) -> None:
    if not artifacts:
        raise ReplayBundleError("terminal replay bundle requires artifacts")
    paths = [item.path for item in artifacts]
    identities = [(item.role, item.leg) for item in artifacts]
    if len(paths) != len(set(paths)):
        raise ReplayBundleError("artifact paths must be unique")
    if len(identities) != len(set(identities)):
        raise ReplayBundleError("artifact role/leg identities must be unique")
    primary = [item for item in artifacts if item.kind == "replay" and item.role == "primary"]
    if len(primary) != 1:
        raise ReplayBundleError("terminal replay bundle requires exactly one primary replay")


def _key(item: ArtifactInput) -> str:
    return item.path


def _validate_relative_path(value: object, *, expected_kind: str | None = None) -> str:
    if not isinstance(value, str) or not value or len(value) > 512:
        raise UnsafeBundlePathError("artifact path is invalid")
    if "\\" in value or "\x00" in value or value.startswith("/"):
        raise UnsafeBundlePathError("artifact path must be a safe POSIX-relative path")
    pure = PurePosixPath(value)
    if pure.is_absolute() or pure.as_posix() != value:
        raise UnsafeBundlePathError("artifact path is not normalized")
    if any(part in {"", ".", ".."} for part in pure.parts) or len(pure.parts) < 2:
        raise UnsafeBundlePathError("artifact path contains an unsafe segment")
    if expected_kind not in _KINDS:
        raise ReplayBundleError("artifact kind is invalid")
    if pure.parts[0] != _KIND_DIRECTORIES[expected_kind]:
        raise UnsafeBundlePathError("artifact path does not match its kind directory")
    return value


def _safe_child(root: Path, relative: str) -> Path:
    _validate_relative_path(relative, expected_kind=_kind_for_relative(relative))
    target = root.joinpath(*PurePosixPath(relative).parts)
    try:
        target.relative_to(root)
    except ValueError as error:
        raise UnsafeBundlePathError("artifact path escapes bundle root") from error
    return target


def _kind_for_relative(relative: str) -> str:
    first = PurePosixPath(relative).parts[0] if relative else ""
    for kind, directory in _KIND_DIRECTORIES.items():
        if first == directory:
            return kind
    raise UnsafeBundlePathError("artifact path has an unknown root directory")


def _write_artifact(staging: Path, item: ArtifactInput) -> Mapping[str, Any]:
    target = _safe_child(staging, item.path)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256()
    size = 0
    try:
        with target.open("xb") as output:
            if isinstance(item.data, bytes):
                output.write(item.data)
                digest.update(item.data)
                size = len(item.data)
            else:
                for chunk in _read_regular_file(item.data):
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
            output.flush()
            os.fsync(output.fileno())
    except FileExistsError as error:
        raise ReplayBundleError(f"duplicate staged artifact path: {item.path}") from error
    if item.media_type == "application/json":
        try:
            require_canonical_json_bytes(target.read_bytes())
        except (OSError, CanonicalJSONError) as error:
            raise ReplayBundleError(f"JSON artifact is not canonical: {item.path}") from error
    descriptor: Dict[str, Any] = {
        "kind": item.kind,
        "role": item.role,
        "path": item.path,
        "media_type": item.media_type,
        "sha256": digest.hexdigest(),
        "size_bytes": size,
        "visibility": item.visibility,
    }
    if item.kind == "replay":
        descriptor.update(
            {
                "native_schema": item.native_schema,
                "verifier": item.verifier,
                "final_state_hash": item.final_state_hash,
            }
        )
    if item.kind == "media":
        descriptor["optional"] = True
    if item.leg is not None:
        descriptor["leg"] = item.leg
    if item.participants:
        descriptor["participants"] = list(item.participants)
    return descriptor


def _read_regular_file(source: Path) -> Iterable[bytes]:
    selected = Path(source)
    if selected.is_symlink():
        raise UnsafeBundlePathError("artifact source must not be a symlink")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(str(selected), flags)
    except OSError as error:
        raise ReplayBundleError("artifact source cannot be opened safely") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ReplayBundleError("artifact source must be a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as source_file:
            while True:
                chunk = source_file.read(1024 * 1024)
                if not chunk:
                    break
                yield chunk
    finally:
        os.close(descriptor)


def _write_new_file(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        with path.open("xb") as target:
            target.write(payload)
            target.flush()
            os.fsync(target.fileno())
    except FileExistsError as error:
        raise ReplayBundleError(f"staged path already exists: {path.name}") from error


def _atomic_publish(root: Path, run_id: str, populate: Callable[[Path], None]) -> Path:
    _validate_run_id(run_id)
    if os.path.lexists(root) and (root.is_symlink() or not root.is_dir()):
        raise UnsafeBundlePathError("replay root must be an unsymlinked directory")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    final = root / run_id
    lock = root / f".{run_id}.lock"
    try:
        lock_fd = os.open(str(lock), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as error:
        raise BundleExistsError("another writer owns this immutable run identifier") from error
    staging: Path | None = None
    try:
        os.close(lock_fd)
        if os.path.lexists(final):
            raise BundleExistsError("run identifier already has an immutable record")
        staging = Path(tempfile.mkdtemp(prefix=f".{run_id}.staging-", dir=str(root)))
        os.chmod(staging, 0o700)
        populate(staging)
        _fsync_directory(staging)
        if os.path.lexists(final):
            raise BundleExistsError("run identifier already has an immutable record")
        os.rename(staging, final)
        staging = None
        _fsync_directory(root)
        return final
    finally:
        if staging is not None and os.path.lexists(staging):
            shutil.rmtree(staging)
        try:
            lock.unlink()
        except FileNotFoundError:
            pass


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        descriptor = os.open(str(path), flags)
    except OSError:
        return
    try:
        try:
            os.fsync(descriptor)
        except OSError:
            pass
    finally:
        os.close(descriptor)


def _load_json_schema(path: Path, *, label: str) -> Mapping[str, Any]:
    try:
        value = strict_json_loads(path.read_bytes())
    except (OSError, CanonicalJSONError) as error:
        raise ReplayBundleError(f"checked-in {label} schema is unavailable") from error
    if not isinstance(value, dict):
        raise ReplayBundleError(f"checked-in {label} schema is invalid")
    return value


def _validate_manifest(manifest: Mapping[str, Any]) -> None:
    _validate_schema_instance(
        manifest,
        schema_path=manifest_schema_path(),
        label="replay bundle manifest",
    )
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise BundleVerificationError("replay bundle artifacts are invalid")
    paths: list[str] = []
    identities: list[Tuple[str, int | None]] = []
    primary_count = 0
    for descriptor in artifacts:
        if not isinstance(descriptor, dict):
            raise BundleVerificationError("artifact descriptor must be an object")
        _validate_relative_path(descriptor.get("path"), expected_kind=descriptor.get("kind"))
        paths.append(descriptor["path"])
        identities.append((descriptor["role"], descriptor.get("leg")))
        if descriptor["kind"] == "replay" and descriptor["role"] == "primary":
            primary_count += 1
    if len(paths) != len(set(paths)) or paths != sorted(paths):
        raise BundleVerificationError("artifact paths must be unique and sorted")
    if len(identities) != len(set(identities)):
        raise BundleVerificationError("artifact role/leg identities must be unique")
    if primary_count != 1:
        raise BundleVerificationError("bundle must contain exactly one primary replay")


def _validate_schema_instance(
    value: Mapping[str, Any], *, schema_path: Path, label: str
) -> None:
    try:
        schema = _load_json_schema(schema_path, label=label)
        Draft202012Validator.check_schema(schema)
        Draft202012Validator(schema).validate(value)
    except (SchemaError, ValidationError) as error:
        path = "/".join(str(item) for item in getattr(error, "absolute_path", ()))
        suffix = f" at {path}" if path else ""
        raise BundleVerificationError(f"{label} violates schema{suffix}") from error


def _verify_manifest_seal(manifest: Mapping[str, Any]) -> None:
    seal = manifest.get("seal")
    if not isinstance(seal, dict):
        raise BundleVerificationError("manifest seal is invalid")
    body = {key: value for key, value in manifest.items() if key != "seal"}
    expected = canonical_sha256(body)
    supplied = seal.get("value")
    if not isinstance(supplied, str) or not hmac.compare_digest(supplied, expected):
        raise BundleVerificationError("manifest content seal differs")


def _validate_inventory(bundle: Path, descriptors: Sequence[Mapping[str, Any]]) -> None:
    expected_files = {MANIFEST_FILENAME}
    expected_directories: set[str] = set()
    for descriptor in descriptors:
        relative = descriptor["path"]
        expected_files.add(relative)
        parent = PurePosixPath(relative).parent
        while parent.parts:
            expected_directories.add(parent.as_posix())
            parent = parent.parent
    for directory, names, files in os.walk(bundle, topdown=True, followlinks=False):
        current = Path(directory)
        for name in names:
            child = current / name
            relative = child.relative_to(bundle).as_posix()
            if child.is_symlink():
                raise BundleVerificationError(f"bundle directory is symlinked: {relative}")
            if relative not in expected_directories:
                raise BundleVerificationError(f"undeclared bundle directory exists: {relative}")
        for name in files:
            child = current / name
            relative = child.relative_to(bundle).as_posix()
            if child.is_symlink():
                raise BundleVerificationError(f"bundle file is symlinked: {relative}")
            if relative not in expected_files:
                raise BundleVerificationError(f"undeclared bundle file exists: {relative}")
            _assert_regular_unsymlinked_file(child, relative)


def _assert_regular_unsymlinked_file(path: Path, relative: str) -> None:
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        raise BundleVerificationError(f"bundle file cannot be inspected: {relative}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise BundleVerificationError(f"bundle path is not a regular unsymlinked file: {relative}")
