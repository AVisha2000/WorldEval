"""Fail-closed WorldArena Duel recording, artifact binding, and offline replay.

The public replay layer is deliberately provider-free.  It accepts only canonical authoritative
rows, binds transcript cursors to every state checkpoint, and is schema-validated before it can be
sealed.  The protected layer is content-addressed separately and commits back to the exact public
bundle, so publishing the replay cannot accidentally publish raw model material.

This module never performs provider or network calls.  A Gateway may feed it records only after
the local Godot frame has passed authentication; the recorder then preserves the authoritative
application ticks and hashes without interpreting game mechanics.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep annotations importable on the project's Python 3.9 floor.
import re
from dataclasses import dataclass
from typing import Any, Callable, Iterable, Mapping, Optional, Sequence, Tuple

from .artifacts import (
    PROTECTED_AUDIT_LAYER,
    PUBLISHABLE_LAYER,
    ArtifactIntegrityError,
    ArtifactPayload,
    ArtifactPolicyError,
    BundleVerification,
    ImmutableArtifactBundle,
    decode_canonical_jsonl,
    decode_canonical_transcript,
)
from .canonical import MAX_SAFE_INTEGER, canonical_json_bytes, strict_json_loads

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_REPLAY_HEADER_FIELDS = frozenset(
    {
        "artifacts",
        "decision",
        "match_id",
        "players",
        "replay_guarantees",
        "schema_version",
        "seat_mapping",
        "seed",
    }
)
_REQUIRED_PUBLIC_ROLES = frozenset(
    {"accepted_actions", "compiled_orders", "public_events", "state_checkpoints"}
)
_PROTECTED_MANIFEST_VERSION = "worldeval-rts/protected-audit-manifest/1.0.0"


class ReplayCorruptionError(RuntimeError):
    """Replay verification stopped because recorded and reproduced state diverged."""


@dataclass(frozen=True)
class ReplayVerificationHooks:
    """Render-free simulation callbacks used by :func:`replay_and_verify`.

    ``advance_and_apply`` receives every interesting tick in ascending order and the primitive
    orders recorded for that exact application tick.  It advances and completes that tick.
    ``checkpoint_sha256`` returns the resulting canonical authoritative state hash.
    ``canonical_events`` returns all authoritative public/spectator events generated through the
    current cursor.  Event bytes are compared at every recorded event/checkpoint and at terminal.
    """

    advance_and_apply: Callable[[int, Sequence[Mapping[str, Any]]], None]
    checkpoint_sha256: Callable[[], str]
    canonical_events: Callable[[], Sequence[Mapping[str, Any]]]


@dataclass(frozen=True)
class ReplayBundleVerification:
    content_sha256: str
    manifest_sha256: str
    match_id: str
    accepted_actions: int
    compiled_orders: int
    public_events: int
    checkpoints: int
    terminal_tick: int
    final_state_sha256: str


@dataclass(frozen=True)
class ReplayVerificationResult:
    bundle_content_sha256: str
    manifest_sha256: str
    match_id: str
    transcript_entries: int
    checkpoints_verified: int
    events_verified: int
    final_tick: int
    final_state_sha256: str


@dataclass(frozen=True)
class MatchArtifactVerification:
    replay: ReplayBundleVerification
    publishable_bundle: BundleVerification
    protected_audit_bundle: BundleVerification


@dataclass(frozen=True)
class MatchArtifactBundles:
    """The separately distributable public replay and access-controlled audit layers."""

    publishable: ImmutableArtifactBundle
    protected_audit: ImmutableArtifactBundle

    def verify(
        self,
        *,
        expected_publishable_sha256: Optional[str] = None,
        expected_protected_audit_sha256: Optional[str] = None,
    ) -> MatchArtifactVerification:
        replay = verify_replay_bundle(
            self.publishable, expected_content_sha256=expected_publishable_sha256
        )
        public_verification = self.publishable.verify(
            expected_content_sha256=expected_publishable_sha256,
            expected_layer=PUBLISHABLE_LAYER,
        )
        audit_verification = self.protected_audit.verify(
            expected_content_sha256=expected_protected_audit_sha256,
            expected_layer=PROTECTED_AUDIT_LAYER,
        )
        _verify_protected_binding(self.publishable, self.protected_audit)
        return MatchArtifactVerification(
            replay=replay,
            publishable_bundle=public_verification,
            protected_audit_bundle=audit_verification,
        )


class AuthoritativeReplayRecorder:
    """Append-only recorder for already-authenticated authoritative Godot outputs.

    The header contains the immutable replay-manifest fields other than ``files``, checkpoints,
    terminal, final hash, and aggregate usage.  Rows may carry additional canonical fields, but the
    recorder owns ``application_tick`` and ``transcript_index``.  A checkpoint must be recorded
    after all same-tick applications/events; later back-filling is rejected.
    """

    def __init__(self, manifest_header: Mapping[str, Any]) -> None:
        header = _detached_object(manifest_header, context="replay manifest header")
        if set(header) != _REPLAY_HEADER_FIELDS:
            unknown = sorted(set(header) - _REPLAY_HEADER_FIELDS)
            missing = sorted(_REPLAY_HEADER_FIELDS - set(header))
            raise ArtifactPolicyError(
                f"replay manifest header fields are invalid; unknown={unknown}, missing={missing}"
            )
        self._header = header
        self._accepted_actions: list[dict[str, Any]] = []
        self._compiled_orders: list[dict[str, Any]] = []
        self._public_events: list[dict[str, Any]] = []
        self._checkpoints: list[dict[str, Any]] = []
        self._last_application_tick = -1
        self._last_event_tick = -1
        self._sealed = False

    @property
    def match_id(self) -> str:
        return str(self._header.get("match_id", ""))

    def record_application(
        self,
        application_tick: int,
        *,
        accepted_actions: Iterable[Mapping[str, Any]],
        compiled_orders: Iterable[Mapping[str, Any]],
    ) -> None:
        self._require_open()
        _require_record_tick(application_tick, context="application")
        if application_tick < self._last_application_tick:
            raise ArtifactPolicyError("authoritative application ticks cannot move backwards")
        if self._checkpoints and application_tick <= self._checkpoints[-1]["tick"]:
            raise ArtifactPolicyError(
                "application cannot be back-filled at or before a sealed checkpoint"
            )
        accepted_start = len(self._accepted_actions)
        new_actions = _indexed_rows(
            accepted_actions,
            application_tick=application_tick,
            starting_index=accepted_start,
            context="accepted action",
        )
        new_orders = _indexed_rows(
            compiled_orders,
            application_tick=application_tick,
            starting_index=len(self._compiled_orders),
            context="compiled order",
        )
        for index, order in enumerate(new_orders):
            source_index = order.get("source_action_index")
            if (
                not isinstance(source_index, int)
                or isinstance(source_index, bool)
                or source_index < accepted_start
                or source_index >= accepted_start + len(new_actions)
            ):
                raise ArtifactPolicyError(
                    f"compiled order {index} must reference an accepted action in its application"
                )
        self._accepted_actions.extend(new_actions)
        self._compiled_orders.extend(new_orders)
        self._last_application_tick = application_tick

    def record_public_events(self, events: Iterable[Mapping[str, Any]]) -> None:
        self._require_open()
        for event in events:
            detached = _detached_object(event, context="public event")
            expected_sequence = len(self._public_events) + 1
            if detached.get("event_seq") != expected_sequence:
                raise ArtifactPolicyError(
                    f"public event sequence must be contiguous at {expected_sequence}"
                )
            tick = detached.get("tick")
            _require_record_tick(tick, context=f"public event {expected_sequence}")
            if tick < self._last_event_tick:
                raise ArtifactPolicyError("public event ticks cannot move backwards")
            if self._checkpoints and tick <= self._checkpoints[-1]["tick"]:
                raise ArtifactPolicyError(
                    "public event cannot be back-filled at or before a sealed checkpoint"
                )
            self._public_events.append(detached)
            self._last_event_tick = tick

    def record_checkpoint(self, tick: int, state_sha256: str) -> None:
        self._require_open()
        _require_record_tick(tick, context="checkpoint")
        _require_record_hash(state_sha256, context="checkpoint")
        if self._checkpoints and tick <= self._checkpoints[-1]["tick"]:
            raise ArtifactPolicyError("checkpoint ticks must be unique and strictly ascending")
        if tick < max(self._last_application_tick, self._last_event_tick):
            raise ArtifactPolicyError("checkpoint cannot precede an already-recorded row")
        self._checkpoints.append(
            {
                "actions_through_index": _latest_index_at_tick(
                    self._accepted_actions, tick, "application_tick"
                ),
                "events_through_index": _latest_index_at_tick(self._public_events, tick, "tick"),
                "state_sha256": state_sha256,
                "tick": tick,
            }
        )

    def seal_publishable(
        self,
        *,
        terminal: Mapping[str, Any],
        final_state_sha256: str,
        aggregate_usage: Mapping[str, Any],
        additional_artifacts: Iterable[ArtifactPayload] = (),
    ) -> ImmutableArtifactBundle:
        self._require_open()
        terminal_value = _detached_object(terminal, context="terminal record")
        terminal_tick = terminal_value.get("tick")
        _require_record_tick(terminal_tick, context="terminal")
        _require_record_hash(final_state_sha256, context="final state")
        if not self._checkpoints:
            raise ArtifactPolicyError("a publishable replay requires at least one checkpoint")
        if terminal_tick < max(
            self._last_application_tick,
            self._last_event_tick,
            self._checkpoints[-1]["tick"],
        ):
            raise ArtifactPolicyError("terminal tick precedes recorded authoritative data")
        usage = _detached_object(aggregate_usage, context="aggregate usage")
        state_checkpoints = {
            "checkpoints": self._checkpoints,
            "final_state_sha256": final_state_sha256,
            "terminal_tick": terminal_tick,
        }
        generated = (
            ArtifactPayload.transcript("accepted_actions", self._accepted_actions),
            ArtifactPayload.transcript("compiled_orders", self._compiled_orders),
            ArtifactPayload.canonical_jsonl("public_events", self._public_events),
            ArtifactPayload.canonical_json("state_checkpoints", state_checkpoints),
        )
        extra = tuple(additional_artifacts)
        if _REQUIRED_PUBLIC_ROLES.intersection(artifact.role for artifact in extra):
            raise ArtifactPolicyError(
                "additional artifacts cannot replace authoritative replay roles"
            )
        manifest = {
            **self._header,
            "aggregate_usage": usage,
            "checkpoints": self._checkpoints,
            "final_state_sha256": final_state_sha256,
            "terminal": terminal_value,
        }
        bundle = ImmutableArtifactBundle.create(
            layer=PUBLISHABLE_LAYER,
            manifest=manifest,
            artifacts=(*generated, *extra),
        )
        verify_replay_bundle(bundle)
        self._sealed = True
        return bundle

    def _require_open(self) -> None:
        if self._sealed:
            raise ArtifactPolicyError("authoritative replay recorder is already sealed")


def seal_match_artifact_layers(
    publishable: ImmutableArtifactBundle,
    *,
    audit_metadata: Mapping[str, Any],
    protected_artifacts: Iterable[ArtifactPayload],
) -> MatchArtifactBundles:
    """Seal a protected audit bundle that cryptographically commits to one valid public replay."""

    replay = verify_replay_bundle(publishable)
    metadata = _detached_object(audit_metadata, context="protected audit metadata")
    protected_values = tuple(protected_artifacts)
    if not protected_values:
        raise ArtifactPolicyError("protected audit layer must contain retained evidence")
    public_index = publishable.index
    manifest = {
        "audit_metadata": metadata,
        "match_id": replay.match_id,
        "publishable_bundle": {
            "content_sha256": publishable.content_sha256,
            "index_sha256": public_index["index_sha256"],
            "manifest_sha256": public_index["manifest"]["sha256"],
        },
        "schema_version": _PROTECTED_MANIFEST_VERSION,
    }
    protected = ImmutableArtifactBundle.create(
        layer=PROTECTED_AUDIT_LAYER,
        manifest=manifest,
        artifacts=protected_values,
    )
    result = MatchArtifactBundles(publishable=publishable, protected_audit=protected)
    result.verify()
    return result


def verify_replay_bundle(
    bundle: ImmutableArtifactBundle,
    *,
    expected_content_sha256: Optional[str] = None,
) -> ReplayBundleVerification:
    """Verify manifest, transcripts, checkpoint cursors, terminal, and publication policy."""

    try:
        storage = bundle.verify(
            expected_content_sha256=expected_content_sha256,
            expected_layer=PUBLISHABLE_LAYER,
        )
        manifest = bundle.manifest
        files = {item.role: item for item in bundle.files}
        missing = sorted(_REQUIRED_PUBLIC_ROLES - set(files))
        if missing:
            raise ReplayCorruptionError(f"publishable replay is missing roles: {missing}")
        expected_media = {
            "accepted_actions": "application/x-ndjson",
            "compiled_orders": "application/x-ndjson",
            "public_events": "application/x-ndjson",
            "state_checkpoints": "application/json",
        }
        for role, media_type in expected_media.items():
            if files[role].media_type != media_type:
                raise ReplayCorruptionError(
                    f"replay role {role!r} requires media type {media_type}"
                )

        accepted = decode_canonical_transcript(bundle.artifact_bytes(role="accepted_actions"))
        compiled = decode_canonical_transcript(bundle.artifact_bytes(role="compiled_orders"))
        _require_explicit_transcript_indexes(accepted, context="accepted action")
        _require_explicit_transcript_indexes(compiled, context="compiled order")
        _verify_compiled_sources(accepted, compiled)
        events = _public_events(bundle.artifact_bytes(role="public_events"))
        checkpoints = _checkpoints(manifest)
        terminal_tick, expected_final_hash = _terminal_commitment(manifest)
        _verify_manifest_semantics(manifest)
        _verify_checkpoint_contract(
            checkpoints=checkpoints,
            accepted=accepted,
            compiled=compiled,
            events=events,
            terminal_tick=terminal_tick,
            final_state_sha256=expected_final_hash,
        )
        state_checkpoint_value = _canonical_json_object(
            bundle.artifact_bytes(role="state_checkpoints"),
            context="state checkpoint artifact",
        )
        expected_state_checkpoint_value = {
            "checkpoints": list(checkpoints),
            "final_state_sha256": expected_final_hash,
            "terminal_tick": terminal_tick,
        }
        if state_checkpoint_value != expected_state_checkpoint_value:
            raise ReplayCorruptionError(
                "state checkpoint artifact does not exactly mirror the replay manifest"
            )
        return ReplayBundleVerification(
            content_sha256=storage.content_sha256,
            manifest_sha256=storage.manifest_sha256,
            match_id=str(manifest["match_id"]),
            accepted_actions=len(accepted),
            compiled_orders=len(compiled),
            public_events=len(events),
            checkpoints=len(checkpoints),
            terminal_tick=terminal_tick,
            final_state_sha256=expected_final_hash,
        )
    except ReplayCorruptionError:
        raise
    except (ArtifactIntegrityError, ArtifactPolicyError, KeyError, TypeError, ValueError) as exc:
        raise ReplayCorruptionError(f"publishable replay failed verification: {exc}") from exc


def replay_transcript(
    bundle: ImmutableArtifactBundle,
    *,
    role: str = "compiled_orders",
    tick_field: str = "application_tick",
) -> Tuple[dict[str, Any], ...]:
    """Return a verified, application-tick ordered transcript without external I/O."""

    verify_replay_bundle(bundle)
    return decode_canonical_transcript(bundle.artifact_bytes(role=role), tick_field=tick_field)


def replay_and_verify(
    bundle: ImmutableArtifactBundle,
    hooks: ReplayVerificationHooks,
    *,
    role: str = "compiled_orders",
    tick_field: str = "application_tick",
) -> ReplayVerificationResult:
    """Replay recorded ticks and stop immediately on an event or state-hash mismatch."""

    contract = verify_replay_bundle(bundle)
    transcript = decode_canonical_transcript(
        bundle.artifact_bytes(role=role), tick_field=tick_field
    )
    manifest = bundle.manifest
    checkpoints = _checkpoints(manifest)
    events = _public_events(bundle.artifact_bytes(role="public_events"))
    final_tick, expected_final_hash = _terminal_commitment(manifest)

    entries_by_tick: dict[int, list[Mapping[str, Any]]] = {}
    for entry in transcript:
        entries_by_tick.setdefault(entry[tick_field], []).append(entry)
    checkpoints_by_tick = {item["tick"]: item["state_sha256"] for item in checkpoints}
    events_by_tick: dict[int, int] = {}
    for index, event in enumerate(events):
        events_by_tick[event["tick"]] = index
    interesting_ticks = sorted(
        {*entries_by_tick, *checkpoints_by_tick, *events_by_tick, final_tick}
    )
    verified_count = 0
    for tick in interesting_ticks:
        hooks.advance_and_apply(tick, tuple(entries_by_tick.get(tick, ())))
        expected_event_index = events_by_tick.get(tick)
        if expected_event_index is not None:
            _verify_generated_events(
                hooks.canonical_events(), events[: expected_event_index + 1], tick=tick
            )
        expected_checkpoint = checkpoints_by_tick.get(tick)
        if expected_checkpoint is not None:
            actual = hooks.checkpoint_sha256()
            _require_hash(actual, context=f"simulation state at tick {tick}")
            if actual != expected_checkpoint:
                raise ReplayCorruptionError(
                    f"checkpoint mismatch at tick {tick}: expected "
                    f"{expected_checkpoint}, reproduced {actual}"
                )
            checkpoint = next(item for item in checkpoints if item["tick"] == tick)
            expected_prefix = events[: checkpoint["events_through_index"] + 1]
            _verify_generated_events(hooks.canonical_events(), expected_prefix, tick=tick)
            verified_count += 1
        if tick == final_tick:
            actual = hooks.checkpoint_sha256()
            _require_hash(actual, context=f"simulation final state at tick {tick}")
            if actual != expected_final_hash:
                raise ReplayCorruptionError(
                    f"final state mismatch at tick {tick}: expected "
                    f"{expected_final_hash}, reproduced {actual}"
                )
            _verify_generated_events(hooks.canonical_events(), events, tick=tick)

    return ReplayVerificationResult(
        bundle_content_sha256=contract.content_sha256,
        manifest_sha256=contract.manifest_sha256,
        match_id=contract.match_id,
        transcript_entries=len(transcript),
        checkpoints_verified=verified_count,
        events_verified=len(events),
        final_tick=final_tick,
        final_state_sha256=expected_final_hash,
    )


def _verify_protected_binding(
    publishable: ImmutableArtifactBundle, protected: ImmutableArtifactBundle
) -> None:
    manifest = protected.manifest
    expected_fields = {
        "audit_metadata",
        "files",
        "match_id",
        "publishable_bundle",
        "schema_version",
    }
    if set(manifest) != expected_fields:
        raise ArtifactIntegrityError("protected audit manifest fields are invalid")
    if manifest["schema_version"] != _PROTECTED_MANIFEST_VERSION:
        raise ArtifactIntegrityError("protected audit manifest version is unsupported")
    if manifest["match_id"] != publishable.manifest.get("match_id"):
        raise ArtifactIntegrityError("public and protected artifact match IDs differ")
    binding = manifest["publishable_bundle"]
    if not isinstance(binding, dict) or set(binding) != {
        "content_sha256",
        "index_sha256",
        "manifest_sha256",
    }:
        raise ArtifactIntegrityError("protected audit public-bundle binding is invalid")
    public_index = publishable.index
    expected = {
        "content_sha256": publishable.content_sha256,
        "index_sha256": public_index["index_sha256"],
        "manifest_sha256": public_index["manifest"]["sha256"],
    }
    if binding != expected:
        raise ArtifactIntegrityError("protected audit does not bind the exact public replay")


def _indexed_rows(
    values: Iterable[Mapping[str, Any]],
    *,
    application_tick: int,
    starting_index: int,
    context: str,
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for offset, value in enumerate(values):
        detached = _detached_object(value, context=f"{context} {offset}")
        expected_index = starting_index + offset
        if "application_tick" in detached and detached["application_tick"] != application_tick:
            raise ArtifactPolicyError(f"{context} {offset} has the wrong application tick")
        if "transcript_index" in detached and detached["transcript_index"] != expected_index:
            raise ArtifactPolicyError(f"{context} {offset} has the wrong transcript index")
        detached["application_tick"] = application_tick
        detached["transcript_index"] = expected_index
        result.append(detached)
    return result


def _detached_object(value: Mapping[str, Any], *, context: str) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise ArtifactPolicyError(f"{context} must be a JSON object")
    try:
        detached = strict_json_loads(canonical_json_bytes(dict(value)))
    except (TypeError, ValueError) as exc:
        raise ArtifactPolicyError(f"{context} is outside the canonical JSON domain: {exc}") from exc
    if not isinstance(detached, dict):
        raise ArtifactPolicyError(f"{context} must be a JSON object")
    return detached


def _canonical_json_object(payload: bytes, *, context: str) -> dict[str, Any]:
    try:
        value = strict_json_loads(payload)
    except ValueError as exc:
        raise ReplayCorruptionError(f"{context} is invalid JSON: {exc}") from exc
    if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
        raise ReplayCorruptionError(f"{context} is not a canonical JSON object")
    return value


def _require_explicit_transcript_indexes(
    values: Sequence[Mapping[str, Any]], *, context: str
) -> None:
    for index, value in enumerate(values):
        if value.get("transcript_index") != index:
            raise ReplayCorruptionError(
                f"{context} transcript_index must be present, contiguous, and equal to {index}"
            )


def _verify_compiled_sources(
    accepted: Sequence[Mapping[str, Any]], compiled: Sequence[Mapping[str, Any]]
) -> None:
    for index, order in enumerate(compiled):
        source_index = order.get("source_action_index")
        if (
            not isinstance(source_index, int)
            or isinstance(source_index, bool)
            or source_index < 0
            or source_index >= len(accepted)
        ):
            raise ReplayCorruptionError(
                f"compiled order {index} has an invalid source_action_index"
            )
        if order["application_tick"] != accepted[source_index]["application_tick"]:
            raise ReplayCorruptionError(
                f"compiled order {index} and its accepted action have different application ticks"
            )


def _public_events(payload: bytes) -> Tuple[dict[str, Any], ...]:
    values = decode_canonical_jsonl(payload)
    result: list[dict[str, Any]] = []
    last_tick = -1
    # Import lazily so replay storage remains acyclic with the protocol package loader.
    from .schema_validation import DuelSchemaValidator, ProtocolSchemaError

    validator = DuelSchemaValidator()
    for index, value in enumerate(values):
        if not isinstance(value, dict):
            raise ReplayCorruptionError(f"public event {index} is not an object")
        try:
            validator.validate("event.v1.schema.json", value)
        except ProtocolSchemaError as exc:
            raise ReplayCorruptionError(
                f"public event {index + 1} violates the frozen event schema: {exc}"
            ) from exc
        if value.get("audience") != "omniscient":
            raise ReplayCorruptionError(
                "public replay event log must use the single omniscient sequence"
            )
        if value.get("event_seq") != index + 1:
            raise ReplayCorruptionError("public event sequence must be contiguous from 1")
        tick = value.get("tick")
        _require_tick(tick, context=f"public event {index + 1}")
        if tick < last_tick:
            raise ReplayCorruptionError("public event ticks cannot move backwards")
        last_tick = tick
        result.append(value)
    return tuple(result)


def _checkpoints(manifest: Mapping[str, Any]) -> Tuple[dict[str, Any], ...]:
    value = manifest.get("checkpoints")
    if not isinstance(value, list) or not value:
        raise ReplayCorruptionError("replay manifest has no checkpoints")
    result: list[dict[str, Any]] = []
    last_tick = -1
    last_action_index = -1
    last_event_index = -1
    for index, item in enumerate(value):
        if not isinstance(item, dict) or set(item) != {
            "actions_through_index",
            "events_through_index",
            "state_sha256",
            "tick",
        }:
            raise ReplayCorruptionError(f"checkpoint {index} fields are invalid")
        tick = item["tick"]
        action_index = item["actions_through_index"]
        event_index = item["events_through_index"]
        _require_tick(tick, context=f"checkpoint {index}")
        if (
            not isinstance(action_index, int)
            or isinstance(action_index, bool)
            or action_index < -1
            or not isinstance(event_index, int)
            or isinstance(event_index, bool)
            or event_index < -1
        ):
            raise ReplayCorruptionError(f"checkpoint {index} counters are invalid")
        if tick <= last_tick:
            raise ReplayCorruptionError("checkpoint ticks must be unique and strictly ascending")
        if action_index < last_action_index or event_index < last_event_index:
            raise ReplayCorruptionError("checkpoint transcript indexes must be monotonic")
        _require_hash(item["state_sha256"], context=f"checkpoint {index}")
        result.append(dict(item))
        last_tick = tick
        last_action_index = action_index
        last_event_index = event_index
    return tuple(result)


def _verify_checkpoint_contract(
    *,
    checkpoints: Sequence[Mapping[str, Any]],
    accepted: Sequence[Mapping[str, Any]],
    compiled: Sequence[Mapping[str, Any]],
    events: Sequence[Mapping[str, Any]],
    terminal_tick: int,
    final_state_sha256: str,
) -> None:
    if checkpoints[-1]["tick"] > terminal_tick:
        raise ReplayCorruptionError("checkpoint occurs after the terminal tick")
    for label, values, tick_field in (
        ("accepted action", accepted, "application_tick"),
        ("compiled order", compiled, "application_tick"),
        ("public event", events, "tick"),
    ):
        if values and values[-1][tick_field] > terminal_tick:
            raise ReplayCorruptionError(f"{label} occurs after the terminal tick")
    for index, checkpoint in enumerate(checkpoints):
        tick = checkpoint["tick"]
        expected_action = _latest_index_at_tick(accepted, tick, "application_tick")
        expected_event = _latest_index_at_tick(events, tick, "tick")
        if checkpoint["actions_through_index"] != expected_action:
            raise ReplayCorruptionError(
                f"checkpoint {index} action cursor does not match the accepted transcript"
            )
        if checkpoint["events_through_index"] != expected_event:
            raise ReplayCorruptionError(
                f"checkpoint {index} event cursor does not match the public event transcript"
            )
    checkpoint_ticks = {item["tick"] for item in checkpoints}
    application_ticks = {
        *(item["application_tick"] for item in accepted),
        *(item["application_tick"] for item in compiled),
    }
    missing_boundaries = sorted(application_ticks - checkpoint_ticks)
    if missing_boundaries:
        raise ReplayCorruptionError(
            f"application boundaries are missing checkpoints: {missing_boundaries}"
        )
    missing_periodic = [
        tick for tick in range(300, terminal_tick + 1, 300) if tick not in checkpoint_ticks
    ]
    if missing_periodic:
        raise ReplayCorruptionError(
            f"replay is missing mandatory 300-tick checkpoints: {missing_periodic}"
        )
    if checkpoints[-1]["tick"] == terminal_tick:
        if checkpoints[-1]["state_sha256"] != final_state_sha256:
            raise ReplayCorruptionError("terminal checkpoint and final state hashes differ")


def _verify_manifest_semantics(manifest: Mapping[str, Any]) -> None:
    players = manifest.get("players")
    if not isinstance(players, list) or [item.get("player_id") for item in players] != [
        "player_a",
        "player_b",
    ]:
        raise ReplayCorruptionError("replay players must be ordered player_a, player_b")
    seats = manifest.get("seat_mapping")
    if not isinstance(seats, list) or [item.get("seat") for item in seats] != [0, 1]:
        raise ReplayCorruptionError("replay seat mapping must be ordered seat 0, seat 1")
    if {item.get("player_id") for item in seats} != {"player_a", "player_b"}:
        raise ReplayCorruptionError("replay seat mapping must contain both players exactly once")
    if {item.get("world_side") for item in seats} != {"south", "north"}:
        raise ReplayCorruptionError(
            "replay seat mapping must contain both world sides exactly once"
        )
    display_assets = manifest.get("artifacts", {}).get("display_assets")
    if not isinstance(display_assets, list) or display_assets != sorted(
        display_assets, key=lambda item: (item["id"], item["sha256"])
    ):
        raise ReplayCorruptionError("display assets are not in canonical ID/hash order")
    decision = manifest.get("decision", {})
    mode = decision.get("mode")
    cadence = decision.get("decision_period_ticks")
    deadline = decision.get("response_deadline_ms")
    if mode == "continuous_realtime" and (cadence != 50 or deadline > 8_000):
        raise ReplayCorruptionError("continuous replay declares an invalid cadence/deadline")
    if mode == "fixed_simultaneous" and cadence not in {50, 100, 150}:
        raise ReplayCorruptionError("fixed replay declares an invalid cadence")
    terminal = manifest.get("terminal", {})
    result = terminal.get("result")
    winner = terminal.get("winner_player_id")
    if result == "normal" and winner not in {"player_a", "player_b"}:
        raise ReplayCorruptionError("normal terminal requires one public winner")
    if result in {"draw", "infrastructure_void"} and winner is not None:
        raise ReplayCorruptionError(f"{result} terminal cannot declare a winner")


def _terminal_commitment(manifest: Mapping[str, Any]) -> tuple[int, str]:
    terminal = manifest.get("terminal")
    final_hash = manifest.get("final_state_sha256")
    if not isinstance(terminal, dict):
        raise ReplayCorruptionError("replay terminal record is absent")
    tick = terminal.get("tick")
    _require_tick(tick, context="terminal")
    _require_hash(final_hash, context="final state")
    return tick, final_hash


def _latest_index_at_tick(values: Sequence[Mapping[str, Any]], tick: int, tick_field: str) -> int:
    result = -1
    for index, value in enumerate(values):
        if value[tick_field] > tick:
            break
        result = index
    return result


def _verify_generated_events(
    actual_values: Sequence[Mapping[str, Any]],
    expected_values: Sequence[Mapping[str, Any]],
    *,
    tick: int,
) -> None:
    try:
        actual = strict_json_loads(canonical_json_bytes(list(actual_values)))
    except (TypeError, ValueError) as exc:
        raise ReplayCorruptionError(
            f"simulation events at tick {tick} are outside the canonical domain"
        ) from exc
    expected = strict_json_loads(canonical_json_bytes(list(expected_values)))
    if actual != expected:
        raise ReplayCorruptionError(f"public event mismatch through tick {tick}")


def _require_tick(value: Any, *, context: str) -> None:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < 0
        or value > MAX_SAFE_INTEGER
    ):
        raise ReplayCorruptionError(f"{context} tick is invalid")


def _require_hash(value: Any, *, context: str) -> None:
    if not isinstance(value, str) or _SHA256_RE.fullmatch(value) is None:
        raise ReplayCorruptionError(f"{context} SHA-256 is invalid")


def _require_record_tick(value: Any, *, context: str) -> None:
    try:
        _require_tick(value, context=context)
    except ReplayCorruptionError as exc:
        raise ArtifactPolicyError(str(exc)) from exc


def _require_record_hash(value: Any, *, context: str) -> None:
    try:
        _require_hash(value, context=context)
    except ReplayCorruptionError as exc:
        raise ArtifactPolicyError(str(exc)) from exc
