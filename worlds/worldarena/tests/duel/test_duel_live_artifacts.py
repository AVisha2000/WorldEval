from __future__ import annotations

import dataclasses
import hashlib
from pathlib import Path
from typing import Any

import pytest
from genesis_arena.duel.artifacts import (
    PROTECTED_AUDIT_LAYER,
    PUBLISHABLE_LAYER,
    ImmutableArtifactBundle,
    decode_canonical_jsonl,
    decode_canonical_transcript,
)
from genesis_arena.duel.canonical import canonical_json_bytes
from genesis_arena.duel.godot_bridge import (
    AcknowledgedActionBatch,
    ProviderObservation,
    ProviderObservationPair,
    TerminalReport,
)
from genesis_arena.duel.live_artifacts import (
    DuelLiveArtifactFinalizer,
    LiveArtifactFinalizationError,
)
from genesis_arena.duel.live_match import LiveMatchTrace
from genesis_arena.duel.match_init import MatchInitAssembler
from genesis_arena.duel.models import ActionBatch, MatchConfig
from genesis_arena.duel.protocol import ProtocolPackage
from genesis_arena.duel.replay import verify_replay_bundle
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
MATCH_ID = "m_live-artifact"
ENGINE_BUILD_ID = "godot-4.5.stable.official.876b29033"
ENGINE_BUILD_SHA256 = "39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719"


def _config(mode: str = "fixed_simultaneous") -> MatchConfig:
    return MatchConfig(
        decision_mode=mode,
        faction_preset_id="vanguard-v1",
        seed=42,
        decision_period_ticks=100 if mode == "fixed_simultaneous" else 50,
        response_deadline_ms=45_000 if mode == "fixed_simultaneous" else 8_000,
        players=[
            {
                "slot": 0,
                "model": "baseline-noop-v1",
                "reasoning": "none",
                "provider_adapter": "baseline-noop-v1",
            },
            {
                "slot": 1,
                "model": "baseline-rush-v1",
                "reasoning": "none",
                "provider_adapter": "baseline-rush-v1",
            },
        ],
    )


def _trace(
    *,
    checkpoint_tick: int = 1,
    command_status: str = "applied",
    mode: str = "fixed_simultaneous",
) -> LiveMatchTrace:
    config = _config(mode)
    assembly = MatchInitAssembler(ProtocolPackage(ROOT / "game" / "duel_protocol")).assemble(
        config,
        match_id=MATCH_ID,
        engine_build_id=ENGINE_BUILD_ID,
        engine_build_sha256=ENGINE_BUILD_SHA256,
    )
    intent_id = "ci_" + "1" * 64
    receipt_command = {
        "atomic_cost": 1,
        "code": None if command_status == "applied" else "target_unavailable",
        "command_id": "move-one",
        "compiled_order_ids": [intent_id],
        "status": command_status,
    }
    intent = {
        "apply_tick": 1,
        "intent_digest": "1" * 64,
        "intent_id": intent_id,
        "intent_type": "order",
        "operation": "move",
        "owner_seat": 0,
        "parameters": {},
        "queue_policy": "replace",
        "source": {
            "batch_id": "batch-one",
            "command_digest": "2" * 64,
            "command_id": "move-one",
            "command_index": 0,
            "expansion_index": 0,
            "match_id": MATCH_ID,
            "observation_seq": 0,
        },
        "subject": {"internal_id": 1, "kind": "entity", "public_id": "e_worker"},
        "target": {"kind": "point", "xy_mt": [1000, 2000]},
    }
    observation_hashes = ("a" * 64, "b" * 64)
    batches = (
        ActionBatch(
            match_id=MATCH_ID,
            observation_seq=0,
            based_on_observation_hash=observation_hashes[0],
            client_batch_id="batch-one",
            valid_until_tick=1 if mode == "fixed_simultaneous" else 100,
            working_memory="protected replay memory sentinel",
            commands=[
                {
                    "actor_ids": ["e_worker"],
                    "command_id": "move-one",
                    "op": "move",
                    "queue": "replace",
                    "target": {"kind": "point", "xy_mt": [1000, 2000]},
                }
            ],
        ),
        ActionBatch(
            match_id=MATCH_ID,
            observation_seq=0,
            based_on_observation_hash=observation_hashes[1],
            client_batch_id="batch-two",
            valid_until_tick=1 if mode == "fixed_simultaneous" else 100,
            commands=[],
        ),
    )
    batch_bytes = tuple(
        canonical_json_bytes(value.model_dump(mode="json", exclude_none=True)) for value in batches
    )
    batch_digests = tuple(hashlib.sha256(value).hexdigest() for value in batch_bytes)
    action_receipts: tuple[dict[str, Any], ...] = (
        {
            "application_seq": 0,
            "application_tick": 1,
            "checkpoint_hash": "0" * 64,
            "checkpoint_tick": 0,
            "decision_mode": mode,
            "kind": "fixed_pair" if mode == "fixed_simultaneous" else "continuous_gate",
            "match_id": MATCH_ID,
            "records": [
                {
                    "batch_digest": batch_digests[0],
                    "batch_id": "batch-one",
                    "compiled_intents": [intent],
                    "player_slot": 0,
                    "receipt": {
                        "apply_tick": 1,
                        "batch_id": "batch-one",
                        "batch_status": command_status,
                        "code": None,
                        "commands": [receipt_command],
                        "observation_seq": 0,
                        "received_tick": 0,
                    },
                },
                {
                    "batch_digest": batch_digests[1],
                    "batch_id": "batch-two",
                    "compiled_intents": [],
                    "player_slot": 1,
                    "receipt": {
                        "apply_tick": 1,
                        "batch_id": "batch-two",
                        "batch_status": "no_op",
                        "code": None,
                        "commands": [],
                        "observation_seq": 0,
                        "received_tick": 0,
                    },
                },
            ],
        },
    )
    tick_events = (
        {
            "checkpoint_hash": "c" * 64,
            "events": [
                {
                    "audience": "omniscient",
                    "event_seq": 1,
                    "kind": "command_applied",
                    "payload": {
                        "batch_id": "batch-one",
                        "command_id": "move-one",
                        "compiled_order_id": intent_id,
                    },
                    "tick": 1,
                }
            ],
            "first_event_seq": 1,
            "last_event_seq": 1,
            "match_id": MATCH_ID,
            "tick_from": 1,
            "tick_through": 1,
        },
    )
    terminal = TerminalReport(
        disposition="victory",
        terminal_tick=1,
        result_hash="f" * 64,
        winner_slot=0,
        failure=None,
        body={
            "disposition": "victory",
            "reason": "stronghold_destroyed",
            "result_hash": "f" * 64,
            "terminal_tick": 1,
            "winner_slot": 0,
        },
    )
    observation_pair = ProviderObservationPair(
        observation_seq=0,
        tick=0,
        observations=tuple(
            ProviderObservation(
                player_slot=slot,
                observation_seq=0,
                tick=0,
                observation_hash=observation_hashes[slot],
                canonical_bytes=canonical_json_bytes(
                    {
                        "match_id": MATCH_ID,
                        "observation_hash": observation_hashes[slot],
                        "observation_seq": 0,
                        "player_slot": slot,
                        "tick": 0,
                    }
                ),
            )
            for slot in (0, 1)
        ),  # type: ignore[arg-type]
    )
    acknowledged = tuple(
        AcknowledgedActionBatch(
            application_seq=0,
            application_tick=1,
            batch_digest=batch_digests[slot],
            batch_id=batches[slot].client_batch_id,
            canonical_batch_bytes=batch_bytes[slot],
            decision_mode=mode,
            match_id=MATCH_ID,
            observation_hash=observation_hashes[slot],
            observation_seq=0,
            observation_tick=0,
            opportunity_id=("fixed-0" if mode == "fixed_simultaneous" else "continuous-0"),
            player_slot=slot,
        )
        for slot in (0, 1)
    )
    return LiveMatchTrace(
        match_id=MATCH_ID,
        config=config,
        match_init_json=assembly.canonical_bytes,
        match_start_monotonic_ns=None,
        observations=(observation_pair,),
        action_receipts=action_receipts,
        acknowledged_action_batches=acknowledged,
        fixed_opportunities=(),
        continuous_dispatches=(),
        continuous_gates=(),
        tick_events=tick_events,
        checkpoints=(
            {
                "checkpoint_hash": "c" * 64,
                "reason": "terminal",
                "tick": checkpoint_tick,
            },
        ),
        terminal=terminal,
    )


@pytest.mark.asyncio
async def test_live_finalizer_seals_verifies_and_materializes_both_layers(
    tmp_path: Path,
) -> None:
    finalizer = DuelLiveArtifactFinalizer(tmp_path, provider_tiers={0: "local", 1: "local"})
    trace = _trace()

    first = await finalizer.seal(trace)
    second = await finalizer.seal(trace)

    assert first == second
    public_hash = first.manifest["publishable_bundle_sha256"]
    protected_hash = first.manifest["protected_audit_bundle_sha256"]
    assert isinstance(public_hash, str) and isinstance(protected_hash, str)
    public = ImmutableArtifactBundle.load_directory(
        tmp_path / PUBLISHABLE_LAYER / "sha256" / public_hash,
        expected_content_sha256=public_hash,
        expected_layer=PUBLISHABLE_LAYER,
    )
    protected = ImmutableArtifactBundle.load_directory(
        tmp_path / PROTECTED_AUDIT_LAYER / "sha256" / protected_hash,
        expected_content_sha256=protected_hash,
        expected_layer=PROTECTED_AUDIT_LAYER,
    )
    verification = verify_replay_bundle(public)
    accepted = decode_canonical_transcript(public.artifact_bytes(role="accepted_actions"))
    orders = decode_canonical_transcript(public.artifact_bytes(role="compiled_orders"))
    acknowledged = decode_canonical_jsonl(
        protected.artifact_bytes(role="acknowledged_action_batches")
    )
    assert verification.final_state_sha256 == "c" * 64
    assert accepted[0]["command_id"] == "move-one"
    assert orders[0]["source_action_index"] == 0
    assert len(acknowledged) == 2
    assert acknowledged[0]["schema_version"] == ("worldeval-rts/acknowledged-action-batch/1.0.0")
    assert acknowledged[0]["action_batch"]["working_memory"] == ("protected replay memory sentinel")
    assert (
        acknowledged[0]["batch_digest"]
        == hashlib.sha256(canonical_json_bytes(acknowledged[0]["action_batch"])).hexdigest()
    )
    assert b"protected replay memory sentinel" not in public.bundle_bytes
    assert "protected replay memory sentinel" not in repr(trace)
    assert "protected replay memory sentinel" not in repr(first.manifest)
    assert all(
        descriptor["role"] != "acknowledged_action_batches"
        for descriptor in public.manifest["files"]
    )
    assert protected.manifest["publishable_bundle"]["content_sha256"] == public_hash
    assert (tmp_path / "seals" / "sha256" / f"{first.artifact_hash}.json").is_file()


@pytest.mark.asyncio
async def test_live_finalizer_rejects_compiled_intent_for_rejected_command(
    tmp_path: Path,
) -> None:
    with pytest.raises(
        LiveArtifactFinalizationError,
        match="compiled intent does not reference an applied receipt command",
    ):
        await DuelLiveArtifactFinalizer(tmp_path).seal(_trace(command_status="rejected"))


@pytest.mark.asyncio
async def test_live_finalizer_requires_authoritative_terminal_checkpoint(
    tmp_path: Path,
) -> None:
    with pytest.raises(
        LiveArtifactFinalizationError,
        match="final authenticated checkpoint must be at the terminal tick",
    ):
        await DuelLiveArtifactFinalizer(tmp_path).seal(_trace(checkpoint_tick=0))


@pytest.mark.asyncio
async def test_live_finalizer_seals_continuous_acknowledged_batches(
    tmp_path: Path,
) -> None:
    result = await DuelLiveArtifactFinalizer(tmp_path).seal(_trace(mode="continuous_realtime"))
    protected_hash = result.manifest["protected_audit_bundle_sha256"]
    assert isinstance(protected_hash, str)
    protected = ImmutableArtifactBundle.load_directory(
        tmp_path / PROTECTED_AUDIT_LAYER / "sha256" / protected_hash,
        expected_content_sha256=protected_hash,
        expected_layer=PROTECTED_AUDIT_LAYER,
    )
    rows = decode_canonical_jsonl(protected.artifact_bytes(role="acknowledged_action_batches"))
    assert [row["decision_mode"] for row in rows] == [
        "continuous_realtime",
        "continuous_realtime",
    ]
    assert [row["player_slot"] for row in rows] == [0, 1]


@pytest.mark.asyncio
async def test_live_finalizer_rejects_missing_acknowledged_batch_evidence(
    tmp_path: Path,
) -> None:
    trace = _trace()
    missing = dataclasses.replace(
        trace,
        acknowledged_action_batches=trace.acknowledged_action_batches[:1],
    )
    with pytest.raises(
        LiveArtifactFinalizationError,
        match="authority receipt has no acknowledged action batch",
    ):
        await DuelLiveArtifactFinalizer(tmp_path).seal(missing)


@pytest.mark.asyncio
async def test_live_finalizer_rejects_duplicate_acknowledged_batch_evidence(
    tmp_path: Path,
) -> None:
    trace = _trace()
    duplicate = dataclasses.replace(
        trace,
        acknowledged_action_batches=(
            *trace.acknowledged_action_batches,
            trace.acknowledged_action_batches[0],
        ),
    )
    with pytest.raises(
        LiveArtifactFinalizationError,
        match="evidence identity is duplicated",
    ):
        await DuelLiveArtifactFinalizer(tmp_path).seal(duplicate)


@pytest.mark.asyncio
async def test_live_finalizer_rejects_receipt_mismatched_batch_body(
    tmp_path: Path,
) -> None:
    trace = _trace()
    original = trace.acknowledged_action_batches[0]
    body = dict(__import__("json").loads(original.canonical_batch_bytes))
    body["working_memory"] = "different protected replay memory"
    canonical = canonical_json_bytes(body)
    mismatched = dataclasses.replace(
        original,
        canonical_batch_bytes=canonical,
        batch_digest=hashlib.sha256(canonical).hexdigest(),
    )
    changed = dataclasses.replace(
        trace,
        acknowledged_action_batches=(
            mismatched,
            trace.acknowledged_action_batches[1],
        ),
    )
    with pytest.raises(
        LiveArtifactFinalizationError,
        match="differs from its authenticated authority receipt",
    ):
        await DuelLiveArtifactFinalizer(tmp_path).seal(changed)


@pytest.mark.asyncio
async def test_live_finalizer_rejects_unacknowledged_extra_batch_material(
    tmp_path: Path,
) -> None:
    trace = _trace()
    original = trace.acknowledged_action_batches[0]
    body = dict(__import__("json").loads(original.canonical_batch_bytes))
    body["client_batch_id"] = "unacknowledged-batch"
    canonical = canonical_json_bytes(body)
    extra = dataclasses.replace(
        original,
        application_seq=1,
        batch_id="unacknowledged-batch",
        canonical_batch_bytes=canonical,
        batch_digest=hashlib.sha256(canonical).hexdigest(),
    )
    changed = dataclasses.replace(
        trace,
        acknowledged_action_batches=(*trace.acknowledged_action_batches, extra),
    )
    with pytest.raises(
        LiveArtifactFinalizationError,
        match="has no authenticated authority receipt",
    ):
        await DuelLiveArtifactFinalizer(tmp_path).seal(changed)
