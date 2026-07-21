"""Concrete, content-addressed artifact finalization for one live Duel match.

The live runner deliberately records authenticated authority frames without interpreting them.
This module performs the one permitted normalization at the artifact boundary: action-receipt
commands that Godot says were applied become public accepted-action rows, and the corresponding
authority-compiled primitive intents receive stable ``source_action_index`` links.  Rejected model
commands, observations, raw outputs, and detailed timings remain in the protected audit layer.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep annotations importable on the project's Python 3.9 floor.
import asyncio
import base64
import dataclasses
import enum
import hashlib
import os
import re
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Optional, Protocol, Sequence, Tuple

from pydantic import JsonValue

from .artifacts import (
    PROTECTED_AUDIT_LAYER,
    PUBLISHABLE_LAYER,
    ArtifactPayload,
    ImmutableArtifactBundle,
)
from .canonical import canonical_json_bytes, canonical_sha256, strict_json_loads
from .godot_bridge import AcknowledgedActionBatch
from .live_match import LiveArtifactSeal, LiveMatchTrace
from .models import ActionBatch
from .provider_adapters import ProviderTelemetry
from .replay import (
    AuthoritativeReplayRecorder,
    MatchArtifactBundles,
    seal_match_artifact_layers,
)

LIVE_ARTIFACT_SEAL_SCHEMA = "worldeval-rts/live-artifact-seal/1.0.0"
ACKNOWLEDGED_ACTION_BATCH_SCHEMA = "worldeval-rts/acknowledged-action-batch/1.0.0"
ACKNOWLEDGED_ACTION_BATCH_ROLE = "acknowledged_action_batches"
DEFAULT_AUDIT_RETENTION_CLASS = "authorized_benchmark_audit"

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_SAFE_TIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$")
_APPLIED_COMMAND_STATUSES = frozenset({"applied", "partially_applied"})
_REPLAY_AUTHORITY_KEYS = frozenset({"alias_salt_seat_0", "alias_salt_seat_1", "tie_key"})


class LiveArtifactFinalizationError(RuntimeError):
    """Authenticated evidence cannot be normalized, verified, or persisted safely."""


class ProviderAuditSource(Protocol):
    """Read-only source of protected provider records retained for one match."""

    def records_for_match(self, match_id: str) -> Sequence[object]: ...


class DuelLiveArtifactFinalizer:
    """Seal, verify, and atomically materialize both official artifact layers.

    ``provider_tiers`` is optional because local baseline adapters have no hosted service tier.
    When omitted, a consistent provider-reported tier is used; otherwise the frozen adapter ID is
    recorded.  Provider audit sources are read only after authority reaches terminal and are never
    drained before the content-addressed layers have been persisted successfully.
    """

    def __init__(
        self,
        storage_root: Path,
        *,
        provider_tiers: Optional[Mapping[int, str]] = None,
        provider_audit_sources: Sequence[ProviderAuditSource] = (),
        replay_authority_material: Optional[Mapping[str, bytes]] = None,
        display_assets: Sequence[Mapping[str, str]] = (),
        audit_retention_class: str = DEFAULT_AUDIT_RETENTION_CLASS,
    ) -> None:
        self.storage_root = Path(storage_root)
        self.provider_tiers = _validate_provider_tiers(provider_tiers or {})
        self.provider_audit_sources = tuple(provider_audit_sources)
        if any(
            not callable(getattr(source, "records_for_match", None))
            for source in self.provider_audit_sources
        ):
            raise ValueError("provider audit sources must expose records_for_match(match_id)")
        self.display_assets = _validate_hash_refs(display_assets, context="display assets")
        self.replay_authority_material = _validate_replay_authority_material(
            replay_authority_material
        )
        if _SAFE_TIER_RE.fullmatch(audit_retention_class) is None:
            raise ValueError("audit_retention_class must be a short safe label")
        self.audit_retention_class = audit_retention_class

    async def seal(self, trace: LiveMatchTrace) -> LiveArtifactSeal:
        """Finalize off the event loop because canonical bundle hashing may be substantial."""

        if not isinstance(trace, LiveMatchTrace):
            raise TypeError("trace must be a LiveMatchTrace")
        return await asyncio.to_thread(self._seal_sync, trace)

    def _seal_sync(self, trace: LiveMatchTrace) -> LiveArtifactSeal:
        try:
            match_init = _canonical_object(trace.match_init_json, context="MATCH_INIT")
            if match_init.get("match_id") != trace.match_id:
                raise LiveArtifactFinalizationError("MATCH_INIT and trace match IDs differ")

            recorder = AuthoritativeReplayRecorder(
                _replay_header(
                    trace,
                    match_init,
                    provider_tiers=self.provider_tiers,
                    display_assets=self.display_assets,
                )
            )
            applications = _normalized_applications(trace.action_receipts, trace.match_id)
            acknowledged_action_batches = _verified_acknowledged_action_batches(trace)
            events = _normalized_public_events(trace.tick_events, trace.match_id)
            checkpoints = _normalized_checkpoints(trace.checkpoints, trace.terminal.terminal_tick)
            _record_authoritative_timeline(
                recorder,
                applications=applications,
                events=events,
                checkpoints=checkpoints,
            )

            final_tick, final_state_sha256 = checkpoints[-1]
            if final_tick != trace.terminal.terminal_tick:
                raise LiveArtifactFinalizationError(
                    "the final authenticated checkpoint must be at the terminal tick"
                )
            publishable = recorder.seal_publishable(
                terminal=_terminal_manifest(trace),
                final_state_sha256=final_state_sha256,
                aggregate_usage=_aggregate_usage(trace),
            )
            layers = seal_match_artifact_layers(
                publishable,
                audit_metadata=_audit_metadata(
                    trace,
                    final_state_sha256,
                    retention_class=self.audit_retention_class,
                ),
                protected_artifacts=_protected_artifacts(
                    trace,
                    provider_records=self._provider_records(trace.match_id),
                    replay_authority_material=self.replay_authority_material,
                    acknowledged_action_batches=acknowledged_action_batches,
                ),
            )
            verification = layers.verify(
                expected_publishable_sha256=layers.publishable.content_sha256,
                expected_protected_audit_sha256=layers.protected_audit.content_sha256,
            )
            self._persist_layers(layers)
            completion = {
                "final_state_sha256": verification.replay.final_state_sha256,
                "match_id": trace.match_id,
                "protected_audit_bundle_sha256": layers.protected_audit.content_sha256,
                "publishable_bundle_sha256": layers.publishable.content_sha256,
                "replay_manifest_sha256": verification.replay.manifest_sha256,
                "schema_version": LIVE_ARTIFACT_SEAL_SCHEMA,
                "terminal_tick": verification.replay.terminal_tick,
            }
            artifact_hash = canonical_sha256(completion)
            self._persist_completion(artifact_hash, completion)
            return LiveArtifactSeal(artifact_hash=artifact_hash, manifest=completion)
        except LiveArtifactFinalizationError:
            raise
        except Exception as exc:
            raise LiveArtifactFinalizationError("live Duel artifact finalization failed") from exc

    def _provider_records(self, match_id: str) -> Tuple[object, ...]:
        result: list[object] = []
        for source in self.provider_audit_sources:
            records = source.records_for_match(match_id)
            if not isinstance(records, Sequence):
                raise LiveArtifactFinalizationError("provider audit source returned a non-sequence")
            result.extend(records)
        return tuple(result)

    def _persist_layers(self, layers: MatchArtifactBundles) -> None:
        for layer, bundle in (
            (PUBLISHABLE_LAYER, layers.publishable),
            (PROTECTED_AUDIT_LAYER, layers.protected_audit),
        ):
            destination = self.storage_root / layer / "sha256" / bundle.content_sha256
            if destination.exists():
                loaded = ImmutableArtifactBundle.load_directory(
                    destination,
                    expected_content_sha256=bundle.content_sha256,
                    expected_layer=layer,
                )
                if loaded.bundle_bytes != bundle.bundle_bytes:
                    raise LiveArtifactFinalizationError(
                        "an existing content-addressed bundle has different bytes"
                    )
                continue
            bundle.write_directory(destination)

    def _persist_completion(self, artifact_hash: str, completion: Mapping[str, JsonValue]) -> None:
        payload = canonical_json_bytes(completion)
        destination = self.storage_root / "seals" / "sha256" / f"{artifact_hash}.json"
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            descriptor = os.open(
                destination,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o444,
            )
        except FileExistsError as exc:
            if destination.is_symlink() or destination.read_bytes() != payload:
                raise LiveArtifactFinalizationError(
                    "an existing content-addressed completion seal has different bytes"
                ) from exc
            return
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
        except BaseException:
            destination.unlink(missing_ok=True)
            raise


def _replay_header(
    trace: LiveMatchTrace,
    match_init: Mapping[str, Any],
    *,
    provider_tiers: Mapping[int, str],
    display_assets: Sequence[Mapping[str, str]],
) -> Dict[str, Any]:
    artifacts = _mapping(match_init, "artifacts")
    config = trace.config
    return {
        "artifacts": {
            "display_assets": [dict(value) for value in display_assets],
            "engine": _hash_ref(artifacts, "engine_build"),
            "faction": _hash_ref(match_init, "faction"),
            "helper": _hash_ref(artifacts, "helper"),
            "items": _hash_ref(artifacts, "items"),
            "map": _hash_ref(match_init, "map"),
            "neutrals": _hash_ref(artifacts, "neutrals"),
            "prompt": _hash_ref(artifacts, "prompt"),
            "protocol": _hash_ref(artifacts, "protocol"),
            "rules": _hash_ref(match_init, "ruleset"),
        },
        "decision": {
            "control_profile": config.control_profile,
            "decision_period_ticks": config.decision_period_ticks,
            "mode": config.decision_mode,
            "observation_profile": config.observation_profile,
            "response_deadline_ms": config.response_deadline_ms,
            "simulation_hz": config.simulation_hz,
        },
        "match_id": trace.match_id,
        "players": [
            {
                "model_snapshot": config.players[slot].model,
                "player_id": _player_id(slot),
                "provider_tier": _provider_tier(trace, slot, provider_tiers),
                "reasoning": config.players[slot].reasoning,
            }
            for slot in (0, 1)
        ],
        "replay_guarantees": {
            "checkpoint_interval_ticks": 300,
            "orders_use_recorded_application_ticks": True,
            "provider_calls": 0,
            "stop_on_hash_mismatch": True,
            "supports_omniscient": True,
            "supports_player_perspectives": True,
        },
        "schema_version": "worldeval-rts/replay-manifest/1.0.0",
        "seat_mapping": [
            {"player_id": "player_a", "seat": 0, "world_side": "south"},
            {"player_id": "player_b", "seat": 1, "world_side": "north"},
        ],
        "seed": config.seed,
    }


def _normalized_applications(
    frames: Sequence[Mapping[str, JsonValue]], match_id: str
) -> Tuple[Tuple[int, Tuple[Dict[str, Any], ...], Tuple[Dict[str, Any], ...]], ...]:
    result: list[tuple[int, tuple[dict[str, Any], ...], tuple[dict[str, Any], ...]]] = []
    next_sequence = 0
    global_action_index = 0
    last_tick = -1
    for frame_index, raw_frame in enumerate(frames):
        frame = _detached_mapping(raw_frame, context=f"action receipt frame {frame_index}")
        if frame.get("application_seq") != next_sequence:
            raise LiveArtifactFinalizationError("action application sequence is not contiguous")
        next_sequence += 1
        if frame.get("match_id") != match_id:
            raise LiveArtifactFinalizationError("action receipt frame has the wrong match ID")
        tick = _non_negative_integer(frame.get("application_tick"), "application tick")
        if tick < last_tick:
            raise LiveArtifactFinalizationError("action application ticks move backwards")
        last_tick = tick
        records = frame.get("records")
        if not isinstance(records, list):
            raise LiveArtifactFinalizationError("action receipt records must be an array")

        accepted: list[dict[str, Any]] = []
        compiled: list[dict[str, Any]] = []
        seen_slots: list[int] = []
        for record_index, record_value in enumerate(records):
            record = _detached_mapping(
                record_value,
                context=f"action receipt frame {frame_index} record {record_index}",
            )
            slot = _slot(record.get("player_slot"))
            seen_slots.append(slot)
            batch_id = _required_string(record, "batch_id")
            batch_digest = _required_hash(record, "batch_digest")
            receipt = _mapping(record, "receipt")
            commands = receipt.get("commands")
            intents = record.get("compiled_intents")
            if not isinstance(commands, list) or not isinstance(intents, list):
                raise LiveArtifactFinalizationError(
                    "action receipt commands and compiled intents must be arrays"
                )

            source_by_command: dict[str, int] = {}
            for command_index, command_value in enumerate(commands):
                command = _detached_mapping(
                    command_value,
                    context=f"receipt command {frame_index}:{record_index}:{command_index}",
                )
                status = command.get("status")
                if status not in _APPLIED_COMMAND_STATUSES:
                    continue
                command_id = _required_string(command, "command_id")
                if command_id in source_by_command:
                    raise LiveArtifactFinalizationError(
                        "one receipt contains duplicate accepted command IDs"
                    )
                row: Dict[str, Any] = {
                    "batch_digest": batch_digest,
                    "batch_id": batch_id,
                    "code": command.get("code"),
                    "command_id": command_id,
                    "observation_seq": _non_negative_integer(
                        receipt.get("observation_seq"), "receipt observation sequence"
                    ),
                    "player_slot": slot,
                    "status": status,
                }
                for optional in (
                    "accepted_quantity",
                    "atomic_cost",
                    "compiled_order_ids",
                    "requested_quantity",
                ):
                    if optional in command:
                        row[optional] = command[optional]
                source_by_command[command_id] = global_action_index + len(accepted)
                accepted.append(row)

            for intent_index, intent_value in enumerate(intents):
                intent = _detached_mapping(
                    intent_value,
                    context=f"compiled intent {frame_index}:{record_index}:{intent_index}",
                )
                source = _mapping(intent, "source")
                command_id = _required_string(source, "command_id")
                source_action_index = source_by_command.get(command_id)
                if source_action_index is None:
                    raise LiveArtifactFinalizationError(
                        "compiled intent does not reference an applied receipt command"
                    )
                if intent.get("apply_tick") != tick:
                    raise LiveArtifactFinalizationError(
                        "compiled intent apply_tick differs from its authority frame"
                    )
                intent["source_action_index"] = source_action_index
                compiled.append(intent)
        if seen_slots != sorted(set(seen_slots)):
            raise LiveArtifactFinalizationError(
                "action receipt records are not in canonical unique slot order"
            )
        result.append((tick, tuple(accepted), tuple(compiled)))
        global_action_index += len(accepted)
    return tuple(result)


def _verified_acknowledged_action_batches(
    trace: LiveMatchTrace,
) -> Tuple[Dict[str, Any], ...]:
    """Bind every protected canonical batch to observations and authority receipts.

    The bridge captures these bytes only after the corresponding authenticated ``action_pair``
    acknowledgement.  This second, independent join prevents an omitted, duplicated, reordered,
    or locally fabricated record from acquiring replay authority merely by entering the trace.
    """

    observation_index: dict[tuple[int, int], tuple[int, str]] = {}
    for pair in trace.observations:
        if pair.observation_seq < 0 or pair.tick < 0:
            raise LiveArtifactFinalizationError("protected observation identity is invalid")
        for observation in pair.observations:
            if observation.observation_seq != pair.observation_seq or observation.tick != pair.tick:
                raise LiveArtifactFinalizationError(
                    "protected observation differs from its pair identity"
                )
            key = (observation.player_slot, observation.observation_seq)
            if key in observation_index:
                raise LiveArtifactFinalizationError("protected observation identity is duplicated")
            if _SHA256_RE.fullmatch(observation.observation_hash) is None:
                raise LiveArtifactFinalizationError("protected observation hash is invalid")
            observation_index[key] = (observation.tick, observation.observation_hash)

    receipt_index: dict[tuple[int, int], tuple[int, str, str, int]] = {}
    for frame_index, raw_frame in enumerate(trace.action_receipts):
        frame = _detached_mapping(raw_frame, context=f"action receipt frame {frame_index}")
        application_seq = _non_negative_integer(
            frame.get("application_seq"), "action application sequence"
        )
        application_tick = _non_negative_integer(frame.get("application_tick"), "application tick")
        if frame.get("match_id") != trace.match_id:
            raise LiveArtifactFinalizationError("action receipt frame has the wrong match ID")
        if frame.get("decision_mode") != trace.config.decision_mode:
            raise LiveArtifactFinalizationError("action receipt frame has the wrong decision mode")
        records = frame.get("records")
        if not isinstance(records, list):
            raise LiveArtifactFinalizationError("action receipt records must be an array")
        for record_index, record_value in enumerate(records):
            record = _detached_mapping(
                record_value,
                context=f"action receipt frame {frame_index} record {record_index}",
            )
            slot = _slot(record.get("player_slot"))
            key = (application_seq, slot)
            if key in receipt_index:
                raise LiveArtifactFinalizationError(
                    "authenticated authority action receipt identity is duplicated"
                )
            batch_id = _required_string(record, "batch_id")
            batch_digest = _required_hash(record, "batch_digest")
            receipt = _mapping(record, "receipt")
            if receipt.get("batch_id") != batch_id:
                raise LiveArtifactFinalizationError(
                    "authority receipt batch ID differs from its record"
                )
            if receipt.get("apply_tick") != application_tick:
                raise LiveArtifactFinalizationError(
                    "authority receipt application tick differs from its frame"
                )
            observation_seq = _non_negative_integer(
                receipt.get("observation_seq"), "receipt observation sequence"
            )
            receipt_index[key] = (
                application_tick,
                batch_id,
                batch_digest,
                observation_seq,
            )

    evidence_index: dict[tuple[int, int], AcknowledgedActionBatch] = {}
    seen_batch_ids: set[tuple[int, str]] = set()
    for evidence in trace.acknowledged_action_batches:
        if not isinstance(evidence, AcknowledgedActionBatch):
            raise LiveArtifactFinalizationError(
                "acknowledged action batch evidence has an invalid type"
            )
        key = (evidence.application_seq, evidence.player_slot)
        if key in evidence_index:
            raise LiveArtifactFinalizationError(
                "acknowledged action batch evidence identity is duplicated"
            )
        batch_identity = (evidence.player_slot, evidence.batch_id)
        if batch_identity in seen_batch_ids:
            raise LiveArtifactFinalizationError(
                "acknowledged action batch ID is duplicated for one player"
            )
        seen_batch_ids.add(batch_identity)
        if evidence.match_id != trace.match_id:
            raise LiveArtifactFinalizationError("acknowledged action batch has the wrong match ID")
        if evidence.decision_mode != trace.config.decision_mode:
            raise LiveArtifactFinalizationError(
                "acknowledged action batch has the wrong decision mode"
            )
        observation = observation_index.get((evidence.player_slot, evidence.observation_seq))
        if observation is None:
            raise LiveArtifactFinalizationError(
                "acknowledged action batch has no protected observation"
            )
        if observation != (evidence.observation_tick, evidence.observation_hash):
            raise LiveArtifactFinalizationError(
                "acknowledged action batch observation identity is mismatched"
            )
        authority = receipt_index.get(key)
        if authority is None:
            raise LiveArtifactFinalizationError(
                "acknowledged action batch has no authenticated authority receipt"
            )
        if authority != (
            evidence.application_tick,
            evidence.batch_id,
            evidence.batch_digest,
            evidence.observation_seq,
        ):
            raise LiveArtifactFinalizationError(
                "acknowledged action batch differs from its authenticated authority receipt"
            )
        try:
            batch_value = strict_json_loads(evidence.canonical_batch_bytes)
            batch = ActionBatch.model_validate(batch_value)
        except (TypeError, ValueError) as exc:
            raise LiveArtifactFinalizationError(
                "acknowledged action batch body is invalid"
            ) from exc
        if (
            not isinstance(batch_value, dict)
            or canonical_json_bytes(batch_value) != evidence.canonical_batch_bytes
            or batch.model_dump(mode="json", exclude_none=True) != batch_value
            or hashlib.sha256(evidence.canonical_batch_bytes).hexdigest() != evidence.batch_digest
        ):
            raise LiveArtifactFinalizationError(
                "acknowledged action batch body is not the committed canonical batch"
            )
        evidence_index[key] = evidence

    missing = sorted(set(receipt_index) - set(evidence_index))
    if missing:
        raise LiveArtifactFinalizationError(
            "authenticated authority receipt has no acknowledged action batch"
        )
    unexpected = sorted(set(evidence_index) - set(receipt_index))
    if unexpected:
        raise LiveArtifactFinalizationError(
            "acknowledged action batch has no authenticated authority receipt"
        )

    rows: list[dict[str, Any]] = []
    for key in sorted(evidence_index):
        evidence = evidence_index[key]
        batch_value = strict_json_loads(evidence.canonical_batch_bytes)
        rows.append(
            {
                "action_batch": batch_value,
                "application_seq": evidence.application_seq,
                "application_tick": evidence.application_tick,
                "batch_digest": evidence.batch_digest,
                "batch_id": evidence.batch_id,
                "decision_mode": evidence.decision_mode,
                "match_id": evidence.match_id,
                "observation_hash": evidence.observation_hash,
                "observation_seq": evidence.observation_seq,
                "observation_tick": evidence.observation_tick,
                "opportunity_id": evidence.opportunity_id,
                "player_slot": evidence.player_slot,
                "schema_version": ACKNOWLEDGED_ACTION_BATCH_SCHEMA,
            }
        )
    return tuple(rows)


def _normalized_public_events(
    frames: Sequence[Mapping[str, JsonValue]], match_id: str
) -> Tuple[Dict[str, Any], ...]:
    result: list[dict[str, Any]] = []
    for frame_index, raw_frame in enumerate(frames):
        frame = _detached_mapping(raw_frame, context=f"tick event frame {frame_index}")
        if frame.get("match_id") != match_id:
            raise LiveArtifactFinalizationError("tick event frame has the wrong match ID")
        events = frame.get("events")
        if not isinstance(events, list) or not events:
            raise LiveArtifactFinalizationError("tick event frame must contain events")
        for event_value in events:
            event = _detached_mapping(event_value, context="public event")
            if event.get("event_seq") != len(result) + 1:
                raise LiveArtifactFinalizationError("public event sequence is not contiguous")
            result.append(event)
    return tuple(result)


def _normalized_checkpoints(
    frames: Sequence[Mapping[str, JsonValue]], terminal_tick: int
) -> Tuple[Tuple[int, str], ...]:
    result: list[tuple[int, str]] = []
    last_tick = -1
    for frame_index, raw_frame in enumerate(frames):
        frame = _detached_mapping(raw_frame, context=f"checkpoint frame {frame_index}")
        tick = _non_negative_integer(frame.get("tick"), "checkpoint tick")
        state_hash = frame.get("checkpoint_hash", frame.get("state_hash"))
        if not isinstance(state_hash, str) or _SHA256_RE.fullmatch(state_hash) is None:
            raise LiveArtifactFinalizationError("checkpoint frame has an invalid state hash")
        if tick <= last_tick:
            raise LiveArtifactFinalizationError(
                "checkpoint ticks must be unique and strictly ascending"
            )
        if tick > terminal_tick:
            raise LiveArtifactFinalizationError("checkpoint occurs after terminal")
        result.append((tick, state_hash))
        last_tick = tick
    if not result:
        raise LiveArtifactFinalizationError("live trace contains no authenticated checkpoints")
    return tuple(result)


def _record_authoritative_timeline(
    recorder: AuthoritativeReplayRecorder,
    *,
    applications: Sequence[Tuple[int, Tuple[Dict[str, Any], ...], Tuple[Dict[str, Any], ...]]],
    events: Sequence[Mapping[str, Any]],
    checkpoints: Sequence[Tuple[int, str]],
) -> None:
    ApplicationRows = tuple[Tuple[Dict[str, Any], ...], Tuple[Dict[str, Any], ...]]
    applications_by_tick: Dict[int, list[ApplicationRows]] = {}
    for tick, accepted, compiled in applications:
        applications_by_tick.setdefault(tick, []).append((accepted, compiled))
    events_by_tick: Dict[int, list[Mapping[str, Any]]] = {}
    for event in events:
        tick = _non_negative_integer(event.get("tick"), "public event tick")
        events_by_tick.setdefault(tick, []).append(event)
    checkpoints_by_tick = dict(checkpoints)
    ticks = sorted({*applications_by_tick, *events_by_tick, *checkpoints_by_tick})
    for tick in ticks:
        for accepted, compiled in applications_by_tick.get(tick, []):
            recorder.record_application(
                tick,
                accepted_actions=accepted,
                compiled_orders=compiled,
            )
        if tick in events_by_tick:
            recorder.record_public_events(events_by_tick[tick])
        if tick in checkpoints_by_tick:
            recorder.record_checkpoint(tick, checkpoints_by_tick[tick])


def _terminal_manifest(trace: LiveMatchTrace) -> Dict[str, Any]:
    disposition_to_result = {
        "victory": "normal",
        "draw": "draw",
        "technical_forfeit": "technical_forfeit",
        "infrastructure_void": "infrastructure_void",
    }
    result = disposition_to_result.get(trace.terminal.disposition)
    if result is None:
        raise LiveArtifactFinalizationError("terminal disposition is unsupported")
    reason = trace.terminal.body.get("reason")
    if not isinstance(reason, str) or not reason:
        raise LiveArtifactFinalizationError("terminal result has no public reason")
    return {
        "reason": reason,
        "result": result,
        "tick": trace.terminal.terminal_tick,
        "winner_player_id": (
            None if trace.terminal.winner_slot is None else _player_id(trace.terminal.winner_slot)
        ),
    }


def _aggregate_usage(trace: LiveMatchTrace) -> Dict[str, Any]:
    values = {
        slot: {
            "failed_opportunities": 0,
            "input_tokens": 0,
            "latency_ns_total": 0,
            "output_tokens": 0,
            "requests": 0,
        }
        for slot in (0, 1)
    }
    for opportunity in trace.fixed_opportunities:
        for outcome in opportunity.player_results:
            usage = values[outcome.player_slot]
            usage["requests"] += 1
            _add_tokens(usage, outcome.provider_telemetry)
            completion = outcome.arrival_monotonic_ns or outcome.deadline_monotonic_ns
            usage["latency_ns_total"] += max(0, completion - outcome.dispatch_monotonic_ns)
            if outcome.failure is not None or outcome.used_fallback:
                usage["failed_opportunities"] += 1
    for gate in trace.continuous_gates:
        for evaluation in gate.evaluations:
            for outcome in evaluation.player_outcomes:
                if outcome.timing is None:
                    continue
                usage = values[outcome.player_slot]
                usage["requests"] += 1
                _add_tokens(usage, outcome.provider_telemetry)
                timing = outcome.timing
                completion = timing.completion_monotonic_ns or timing.deadline_monotonic_ns
                usage["latency_ns_total"] += max(0, completion - timing.dispatch_monotonic_ns)
                if outcome.failure is not None or outcome.used_no_op:
                    usage["failed_opportunities"] += 1
    return {"player_a": values[0], "player_b": values[1]}


def _add_tokens(usage: Dict[str, int], telemetry: ProviderTelemetry) -> None:
    usage["input_tokens"] += telemetry.input_tokens or 0
    usage["output_tokens"] += telemetry.output_tokens or 0


def _provider_tier(trace: LiveMatchTrace, slot: int, configured: Mapping[int, str]) -> str:
    if slot in configured:
        return configured[slot]
    reported: set[str] = set()
    for opportunity in trace.fixed_opportunities:
        value = opportunity.player_results[slot].provider_telemetry.service_tier
        if value:
            reported.add(value)
    for gate in trace.continuous_gates:
        for evaluation in gate.evaluations:
            for outcome in evaluation.player_outcomes:
                if outcome.player_slot == slot and outcome.provider_telemetry.service_tier:
                    reported.add(outcome.provider_telemetry.service_tier)
    if len(reported) > 1:
        raise LiveArtifactFinalizationError("provider service tier changed within one match")
    if reported:
        result = next(iter(reported))
    else:
        result = trace.config.players[slot].provider_adapter or "provider-default"
    if _SAFE_TIER_RE.fullmatch(result) is None:
        raise LiveArtifactFinalizationError("provider tier is not a safe manifest value")
    return result


def _protected_artifacts(
    trace: LiveMatchTrace,
    *,
    provider_records: Sequence[object],
    replay_authority_material: Mapping[str, bytes],
    acknowledged_action_batches: Sequence[Mapping[str, Any]],
) -> Tuple[ArtifactPayload, ...]:
    observations = []
    for pair in trace.observations:
        for observation in pair.observations:
            observations.append(
                {
                    "canonical_bytes_base64": base64.b64encode(observation.canonical_bytes).decode(
                        "ascii"
                    ),
                    "observation_hash": observation.observation_hash,
                    "observation_seq": observation.observation_seq,
                    "player_slot": observation.player_slot,
                    "tick": observation.tick,
                }
            )
    scheduler = {
        "continuous_dispatches": _json_safe(trace.continuous_dispatches),
        "continuous_gates": _json_safe(trace.continuous_gates),
        "fixed_opportunities": _json_safe(trace.fixed_opportunities),
        "match_start_monotonic_ns": trace.match_start_monotonic_ns,
        "terminal": _json_safe(trace.terminal),
    }
    provider_values = [_json_safe(value) for value in provider_records]
    replay_authority = {
        "alias_salt_seat_0_base64": base64.b64encode(
            replay_authority_material.get("alias_salt_seat_0", b"")
        ).decode("ascii"),
        "alias_salt_seat_1_base64": base64.b64encode(
            replay_authority_material.get("alias_salt_seat_1", b"")
        ).decode("ascii"),
        "available": bool(replay_authority_material),
        "tie_key_base64": base64.b64encode(replay_authority_material.get("tie_key", b"")).decode(
            "ascii"
        ),
        "tie_key_sha256": (
            hashlib.sha256(replay_authority_material["tie_key"]).hexdigest()
            if replay_authority_material
            else None
        ),
    }
    return (
        ArtifactPayload(
            role="match_init",
            data=trace.match_init_json,
            media_type="application/json",
        ),
        ArtifactPayload.canonical_jsonl("observations", observations),
        ArtifactPayload.canonical_jsonl("action_receipts", trace.action_receipts),
        ArtifactPayload.canonical_jsonl(
            ACKNOWLEDGED_ACTION_BATCH_ROLE, acknowledged_action_batches
        ),
        ArtifactPayload.canonical_json("scheduler_trace", scheduler),
        ArtifactPayload.canonical_json("provider_calls", {"records": provider_values}),
        ArtifactPayload.canonical_json("replay_authority", replay_authority),
    )


def _audit_metadata(
    trace: LiveMatchTrace,
    final_state_sha256: str,
    *,
    retention_class: str,
) -> Dict[str, Any]:
    return {
        "decision_mode": trace.config.decision_mode,
        "final_state_sha256": final_state_sha256,
        "match_init_sha256": hashlib.sha256(trace.match_init_json).hexdigest(),
        "provider_adapters": [
            trace.config.players[slot].provider_adapter or "unspecified" for slot in (0, 1)
        ],
        "retention_class": retention_class,
    }


def _json_safe(value: Any) -> JsonValue:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return _json_safe(dataclasses.asdict(value))
    if isinstance(value, enum.Enum):
        return _json_safe(value.value)
    if isinstance(value, bytes):
        return {"base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, Mapping):
        return {str(key): _json_safe(child) for key, child in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(child) for child in value]
    if value is None or isinstance(value, (str, int, bool)):
        return value
    raise LiveArtifactFinalizationError(
        f"protected audit value has unsupported type {type(value).__name__}"
    )


def _canonical_object(payload: bytes, *, context: str) -> Dict[str, Any]:
    try:
        value = strict_json_loads(payload)
    except ValueError as exc:
        raise LiveArtifactFinalizationError(f"{context} is invalid JSON") from exc
    if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
        raise LiveArtifactFinalizationError(f"{context} is not a canonical JSON object")
    return value


def _detached_mapping(value: object, *, context: str) -> Dict[str, Any]:
    if not isinstance(value, Mapping):
        raise LiveArtifactFinalizationError(f"{context} must be an object")
    try:
        detached = strict_json_loads(canonical_json_bytes(dict(value)))
    except (TypeError, ValueError) as exc:
        raise LiveArtifactFinalizationError(f"{context} is outside canonical JSON") from exc
    if not isinstance(detached, dict):
        raise LiveArtifactFinalizationError(f"{context} must be an object")
    return detached


def _mapping(value: Mapping[str, Any], field: str) -> Dict[str, Any]:
    child = value.get(field)
    if not isinstance(child, dict):
        raise LiveArtifactFinalizationError(f"{field} must be an object")
    return child


def _required_string(value: Mapping[str, Any], field: str) -> str:
    child = value.get(field)
    if not isinstance(child, str) or not child:
        raise LiveArtifactFinalizationError(f"{field} must be a non-empty string")
    return child


def _required_hash(value: Mapping[str, Any], field: str) -> str:
    child = _required_string(value, field)
    if _SHA256_RE.fullmatch(child) is None:
        raise LiveArtifactFinalizationError(f"{field} must be lowercase SHA-256")
    return child


def _hash_ref(value: Mapping[str, Any], field: str) -> Dict[str, str]:
    reference = _mapping(value, field)
    identifier = _required_string(reference, "id")
    digest = _required_hash(reference, "sha256")
    return {"id": identifier, "sha256": digest}


def _non_negative_integer(value: object, context: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise LiveArtifactFinalizationError(f"{context} must be a non-negative integer")
    return value


def _slot(value: object) -> int:
    if value not in {0, 1}:
        raise LiveArtifactFinalizationError("player slot must be 0 or 1")
    return int(value)


def _player_id(slot: int) -> str:
    if slot == 0:
        return "player_a"
    if slot == 1:
        return "player_b"
    raise LiveArtifactFinalizationError("winner slot must be 0, 1, or null")


def _validate_provider_tiers(values: Mapping[int, str]) -> Dict[int, str]:
    result: Dict[int, str] = {}
    for slot, tier in values.items():
        if slot not in {0, 1} or not isinstance(tier, str) or _SAFE_TIER_RE.fullmatch(tier) is None:
            raise ValueError("provider_tiers must map slots 0/1 to short safe labels")
        result[slot] = tier
    return result


def _validate_hash_refs(
    values: Iterable[Mapping[str, str]], *, context: str
) -> Tuple[Dict[str, str], ...]:
    result: list[dict[str, str]] = []
    for index, value in enumerate(values):
        if not isinstance(value, Mapping):
            raise ValueError(f"{context} entry {index} must be an object")
        reference = dict(value)
        if set(reference) != {"id", "sha256"}:
            raise ValueError(f"{context} entry {index} fields are invalid")
        identifier = reference["id"]
        digest = reference["sha256"]
        if not isinstance(identifier, str) or not identifier or len(identifier) > 160:
            raise ValueError(f"{context} entry {index} id is invalid")
        if not isinstance(digest, str) or _SHA256_RE.fullmatch(digest) is None:
            raise ValueError(f"{context} entry {index} hash is invalid")
        result.append({"id": identifier, "sha256": digest})
    if [value["id"] for value in result] != sorted(value["id"] for value in result):
        raise ValueError(f"{context} must be sorted by id")
    return tuple(result)


def _validate_replay_authority_material(
    value: Optional[Mapping[str, bytes]],
) -> Dict[str, bytes]:
    if value is None:
        return {}
    if not isinstance(value, Mapping) or set(value) != _REPLAY_AUTHORITY_KEYS:
        raise ValueError(
            "replay_authority_material must contain exact tie-key and alias-salt fields"
        )
    result: Dict[str, bytes] = {}
    for field in sorted(_REPLAY_AUTHORITY_KEYS):
        payload = value[field]
        if not isinstance(payload, bytes) or len(payload) != 32:
            raise ValueError(f"replay authority {field} must contain exactly 32 bytes")
        result[field] = bytes(payload)
    if result["alias_salt_seat_0"] == result["alias_salt_seat_1"]:
        raise ValueError("replay authority alias salts must differ")
    return result


__all__ = [
    "DEFAULT_AUDIT_RETENTION_CLASS",
    "LIVE_ARTIFACT_SEAL_SCHEMA",
    "DuelLiveArtifactFinalizer",
    "LiveArtifactFinalizationError",
    "ProviderAuditSource",
]
