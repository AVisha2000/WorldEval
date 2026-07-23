from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any, Mapping, Sequence

import pytest
from genesis_arena.duel.artifacts import (
    PROTECTED_AUDIT_LAYER,
    PUBLISHABLE_LAYER,
    ArtifactIntegrityError,
    ArtifactPayload,
    ArtifactPolicyError,
    ImmutableArtifactBundle,
    canonical_transcript_bytes,
    decode_canonical_jsonl,
    decode_canonical_transcript,
)
from genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from genesis_arena.duel.replay import (
    AuthoritativeReplayRecorder,
    MatchArtifactBundles,
    ReplayCorruptionError,
    ReplayVerificationHooks,
    replay_and_verify,
    seal_match_artifact_layers,
    verify_replay_bundle,
)
from genesis_arena.duel.schema_validation import DuelSchemaValidator

EXPECTED_PUBLIC_BUNDLE_SHA256 = "d9efabec29da51274a5ca7f80dd3faf8cde66f0fb33524d996d58f20ccace5d1"


def _manifest(*, checkpoint_hash: str = "c" * 64, final_hash: str = "f" * 64) -> dict[str, Any]:
    # The artifact layer intentionally accepts a mapping so the replay schema may evolve without
    # coupling storage mechanics to a duplicate model.  This fixture uses its current v1 shape.
    return {
        "aggregate_usage": {
            player: {
                "failed_opportunities": 0,
                "input_tokens": 100,
                "latency_ns_total": 1000,
                "output_tokens": 20,
                "requests": 1,
            }
            for player in ("player_a", "player_b")
        },
        "artifacts": {
            name: {"id": f"{name}-v1", "sha256": "a" * 64}
            for name in (
                "engine",
                "faction",
                "helper",
                "items",
                "map",
                "neutrals",
                "prompt",
                "protocol",
                "rules",
            )
        }
        | {"display_assets": []},
        "checkpoints": [
            {
                "actions_through_index": 0,
                "events_through_index": 0,
                "state_sha256": checkpoint_hash,
                "tick": 10,
            }
        ],
        "decision": {
            "control_profile": "hybrid-v1",
            "decision_period_ticks": 50,
            "mode": "fixed_simultaneous",
            "observation_profile": "full-belief-v1",
            "response_deadline_ms": 8000,
            "simulation_hz": 10,
        },
        "final_state_sha256": final_hash,
        "match_id": "m_artifact-test",
        "players": [
            {
                "model_snapshot": "model-a",
                "player_id": "player_a",
                "provider_tier": "benchmark",
                "reasoning": "low",
            },
            {
                "model_snapshot": "model-b",
                "player_id": "player_b",
                "provider_tier": "benchmark",
                "reasoning": "low",
            },
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
        "seed": 42,
        "terminal": {
            "reason": "stronghold_destroyed",
            "result": "normal",
            "tick": 20,
            "winner_player_id": "player_a",
        },
    }


def _event(tick: int) -> dict[str, Any]:
    return {
        "audience": "omniscient",
        "event_seq": 1,
        "kind": "order_started",
        "payload": {"compiled_order_id": "order-1"},
        "tick": tick,
    }


def _public_artifacts(manifest: Mapping[str, Any] | None = None) -> tuple[ArtifactPayload, ...]:
    replay_manifest = dict(manifest or _manifest())
    action = {
        "application_tick": 10,
        "batch_id": "batch-1",
        "command_id": "command-1",
        "player_slot": 0,
        "transcript_index": 0,
    }
    order = {
        "application_tick": 10,
        "op": "move",
        "source_action_index": 0,
        "transcript_index": 0,
    }
    return (
        ArtifactPayload.transcript("accepted_actions", [action]),
        ArtifactPayload.transcript("compiled_orders", [order]),
        ArtifactPayload.canonical_jsonl("public_events", [_event(10)]),
        ArtifactPayload.canonical_json(
            "state_checkpoints",
            {
                "checkpoints": replay_manifest["checkpoints"],
                "final_state_sha256": replay_manifest["final_state_sha256"],
                "terminal_tick": replay_manifest["terminal"]["tick"],
            },
        ),
    )


def _public_bundle(**manifest_overrides: Any) -> ImmutableArtifactBundle:
    manifest = _manifest()
    manifest.update(manifest_overrides)
    return ImmutableArtifactBundle.create(
        layer=PUBLISHABLE_LAYER,
        manifest=manifest,
        artifacts=_public_artifacts(manifest),
    )


def test_publishable_bundle_is_deterministic_content_addressed_and_round_trips(
    tmp_path: Path,
) -> None:
    first = _public_bundle()
    second = _public_bundle()

    assert first.bundle_bytes == second.bundle_bytes
    assert first.content_sha256 == second.content_sha256
    assert first.content_sha256 == EXPECTED_PUBLIC_BUNDLE_SHA256
    assert all(item.path == f"objects/sha256/{item.sha256}" for item in first.files)
    assert [item.role for item in first.files] == sorted(item.role for item in first.files)

    loaded = ImmutableArtifactBundle.from_bytes(
        first.bundle_bytes,
        expected_content_sha256=first.content_sha256,
        expected_layer=PUBLISHABLE_LAYER,
    )
    assert loaded.bundle_bytes == first.bundle_bytes
    assert loaded.manifest == first.manifest
    DuelSchemaValidator().validate("replay-manifest.v1.schema.json", loaded.manifest)
    verification = verify_replay_bundle(loaded)
    assert verification.accepted_actions == verification.compiled_orders == 1
    assert verification.public_events == verification.checkpoints == 1

    directory = first.write_directory(tmp_path / "replay")
    reloaded = ImmutableArtifactBundle.load_directory(
        directory,
        expected_content_sha256=first.content_sha256,
        expected_layer=PUBLISHABLE_LAYER,
    )
    assert reloaded.bundle_bytes == first.bundle_bytes
    with pytest.raises(FileExistsError, match="already exists"):
        first.write_directory(directory)


def test_bundle_fails_closed_on_payload_or_external_hash_tamper() -> None:
    bundle = _public_bundle()
    wire = strict_json_loads(bundle.bundle_bytes)
    assert isinstance(wire, dict)
    wire["payloads"][0]["data_base64"] = "AA=="
    with pytest.raises(ArtifactIntegrityError, match="mismatch"):
        ImmutableArtifactBundle.from_bytes(canonical_json_bytes(wire))

    with pytest.raises(ArtifactIntegrityError, match="content SHA-256 mismatch"):
        ImmutableArtifactBundle.from_bytes(bundle.bundle_bytes, expected_content_sha256="0" * 64)


def test_malicious_index_paths_and_materialized_symlinks_are_rejected(tmp_path: Path) -> None:
    bundle = _public_bundle()
    wire = strict_json_loads(bundle.bundle_bytes)
    assert isinstance(wire, dict)
    wire["index"]["manifest"]["path"] = "../../outside.json"
    body = {key: value for key, value in wire["index"].items() if key != "index_sha256"}
    wire["index"]["index_sha256"] = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
    with pytest.raises(ArtifactIntegrityError, match="unsafe bundle-relative path"):
        ImmutableArtifactBundle.from_bytes(canonical_json_bytes(wire))

    directory = bundle.write_directory(tmp_path / "safe")
    event_file = next(item for item in bundle.files if item.role == "public_events")
    target = directory / event_file.path
    target.unlink()
    target.symlink_to(tmp_path / "outside")
    with pytest.raises(ArtifactIntegrityError, match="regular file|symlinks|escapes destination"):
        ImmutableArtifactBundle.load_directory(directory)


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ({"nested": {"apiKey": "not-even-needed"}}, "credential field"),
        ({"diagnostic": "Bearer abcdefghijklmnopqrstuvwxyz"}, "secret-like value"),
        ({"working_memory": "private chain"}, "private field"),
        ({"provider_request_id": "request-123"}, "private field"),
        ({"parsed_batches": [{"commands": []}]}, "private field"),
        ({"observations": [{"tick": 10}]}, "private field"),
    ],
)
def test_publishable_bundle_rejects_secret_or_private_content(
    value: dict[str, Any], message: str
) -> None:
    artifacts = (*_public_artifacts(), ArtifactPayload.canonical_json("usage_timing", value))
    with pytest.raises(ArtifactPolicyError, match=message):
        ImmutableArtifactBundle.create(
            layer=PUBLISHABLE_LAYER,
            manifest=_manifest(),
            artifacts=artifacts,
        )


def test_publishable_manifest_schema_and_opaque_binary_fail_at_seal_boundary() -> None:
    manifest = _manifest()
    manifest["unknown_field"] = True
    with pytest.raises(ArtifactPolicyError, match="frozen schema"):
        ImmutableArtifactBundle.create(
            layer=PUBLISHABLE_LAYER,
            manifest=manifest,
            artifacts=_public_artifacts(manifest),
        )

    with pytest.raises(ArtifactPolicyError, match="cannot be proven publication-safe"):
        ImmutableArtifactBundle.create(
            layer=PUBLISHABLE_LAYER,
            manifest=_manifest(),
            artifacts=(
                *_public_artifacts(),
                ArtifactPayload("omniscient_snapshots", b"opaque", "application/octet-stream"),
            ),
        )


def test_protected_audit_accepts_private_evidence_but_cannot_be_read_as_public() -> None:
    audit = ImmutableArtifactBundle.create(
        layer=PROTECTED_AUDIT_LAYER,
        manifest={"match_id": "m_artifact-test", "schema_version": "audit-v1"},
        artifacts=(
            ArtifactPayload.canonical_json(
                "raw_response",
                {
                    "provider_request_id": "request-private",
                    "raw_response": "private model output retained for audit",
                    "working_memory": "authorized only",
                },
            ),
        ),
    )
    assert "raw_response" in audit.manifest["files"][0]["role"]
    with pytest.raises(ArtifactIntegrityError, match="layer mismatch"):
        ImmutableArtifactBundle.from_bytes(audit.bundle_bytes, expected_layer=PUBLISHABLE_LAYER)
    with pytest.raises(ArtifactPolicyError, match="protected or unknown role"):
        ImmutableArtifactBundle.create(
            layer=PUBLISHABLE_LAYER,
            manifest=_manifest(),
            artifacts=(ArtifactPayload.canonical_json("raw_response", {"raw": "value"}),),
        )
    with pytest.raises(ArtifactPolicyError, match="credential field"):
        ImmutableArtifactBundle.create(
            layer=PROTECTED_AUDIT_LAYER,
            manifest={"match_id": "m_artifact-test", "schema_version": "audit-v1"},
            artifacts=(
                ArtifactPayload.canonical_json(
                    "raw_response", {"raw_response": "ok", "client_secret": "forbidden"}
                ),
            ),
        )


def test_transcript_codec_preserves_same_tick_order_and_rejects_time_reversal() -> None:
    rows = [
        {"application_tick": 5, "order": "first", "transcript_index": 0},
        {"application_tick": 5, "order": "second", "transcript_index": 1},
        {"application_tick": 9, "order": "third", "transcript_index": 2},
    ]
    encoded = canonical_transcript_bytes(rows)
    decoded = decode_canonical_transcript(encoded)
    assert [item["order"] for item in decoded] == ["first", "second", "third"]
    with pytest.raises(ArtifactPolicyError, match="out of order"):
        canonical_transcript_bytes([{"application_tick": 9}, {"application_tick": 8}])
    assert decode_canonical_jsonl(b'{"a":1}\n{"a":2}\n') == ({"a": 1}, {"a": 2})
    with pytest.raises(ArtifactIntegrityError, match="LF-terminated"):
        decode_canonical_jsonl(b'{"a":1}')


def test_authoritative_recorder_seals_deterministic_cross_linked_layers() -> None:
    header = _manifest()
    for dynamic in (
        "aggregate_usage",
        "checkpoints",
        "final_state_sha256",
        "terminal",
    ):
        del header[dynamic]

    def build_public() -> ImmutableArtifactBundle:
        recorder = AuthoritativeReplayRecorder(header)
        recorder.record_application(
            10,
            accepted_actions=(
                {
                    "batch_id": "batch-1",
                    "command_id": "command-1",
                    "player_slot": 0,
                },
            ),
            compiled_orders=({"op": "move", "source_action_index": 0},),
        )
        recorder.record_public_events((_event(10),))
        recorder.record_checkpoint(10, "c" * 64)
        return recorder.seal_publishable(
            terminal=_manifest()["terminal"],
            final_state_sha256="f" * 64,
            aggregate_usage=_manifest()["aggregate_usage"],
        )

    first = build_public()
    second = build_public()
    assert first.bundle_bytes == second.bundle_bytes
    assert verify_replay_bundle(first).final_state_sha256 == "f" * 64

    layers = seal_match_artifact_layers(
        first,
        audit_metadata={
            "retention_class": "authorized_benchmark_audit",
            "run_id": "run-private-1",
        },
        protected_artifacts=(
            ArtifactPayload.canonical_jsonl(
                "raw_responses",
                (
                    {
                        "provider_request_id": "request-private",
                        "raw_response": "private model output",
                        "working_memory": "audit only",
                    },
                ),
            ),
        ),
    )
    verification = layers.verify(
        expected_publishable_sha256=first.content_sha256,
        expected_protected_audit_sha256=layers.protected_audit.content_sha256,
    )
    assert verification.replay.match_id == "m_artifact-test"
    assert (
        layers.protected_audit.manifest["publishable_bundle"]["content_sha256"]
        == first.content_sha256
    )

    bad_manifest = layers.protected_audit.manifest
    del bad_manifest["files"]
    bad_manifest["publishable_bundle"]["content_sha256"] = "0" * 64
    rebound = ImmutableArtifactBundle.create(
        layer=PROTECTED_AUDIT_LAYER,
        manifest=bad_manifest,
        artifacts=(
            ArtifactPayload.canonical_jsonl("raw_responses", ({"raw_response": "still private"},)),
        ),
    )
    with pytest.raises(ArtifactIntegrityError, match="does not bind"):
        MatchArtifactBundles(first, rebound).verify()


def test_replay_contract_rejects_cursor_source_and_checkpoint_schedule_forgery() -> None:
    manifest = _manifest()
    manifest["checkpoints"][0]["actions_through_index"] = -1
    forged_cursor = ImmutableArtifactBundle.create(
        layer=PUBLISHABLE_LAYER,
        manifest=manifest,
        artifacts=_public_artifacts(manifest),
    )
    with pytest.raises(ReplayCorruptionError, match="action cursor"):
        verify_replay_bundle(forged_cursor)

    artifacts = list(_public_artifacts())
    artifacts[1] = ArtifactPayload.transcript(
        "compiled_orders",
        (
            {
                "application_tick": 10,
                "op": "move",
                "source_action_index": 7,
                "transcript_index": 0,
            },
        ),
    )
    forged_source = ImmutableArtifactBundle.create(
        layer=PUBLISHABLE_LAYER,
        manifest=_manifest(),
        artifacts=artifacts,
    )
    with pytest.raises(ReplayCorruptionError, match="source_action_index"):
        verify_replay_bundle(forged_source)

    invalid_event_artifacts = list(_public_artifacts())
    invalid_event_artifacts[2] = ArtifactPayload.canonical_jsonl(
        "public_events", ({"event_seq": 1, "tick": 10},)
    )
    invalid_event = ImmutableArtifactBundle.create(
        layer=PUBLISHABLE_LAYER,
        manifest=_manifest(),
        artifacts=invalid_event_artifacts,
    )
    with pytest.raises(ReplayCorruptionError, match="frozen event schema"):
        verify_replay_bundle(invalid_event)

    late_manifest = _manifest(final_hash="c" * 64)
    late_manifest["terminal"]["tick"] = 301
    late_bundle = ImmutableArtifactBundle.create(
        layer=PUBLISHABLE_LAYER,
        manifest=late_manifest,
        artifacts=_public_artifacts(late_manifest),
    )
    with pytest.raises(ReplayCorruptionError, match="300-tick"):
        verify_replay_bundle(late_bundle)


def test_offline_replay_applies_recorded_ticks_and_verifies_every_hash() -> None:
    current_hash = "0" * 64
    calls: list[tuple[int, tuple[str, ...]]] = []
    events: list[dict[str, Any]] = []

    def advance_and_apply(tick: int, entries: Sequence[Mapping[str, Any]]) -> None:
        nonlocal current_hash
        calls.append((tick, tuple(str(entry["op"]) for entry in entries)))
        current_hash = "c" * 64 if tick == 10 else "f" * 64
        if tick == 10:
            events.append(_event(10))

    result = replay_and_verify(
        _public_bundle(),
        ReplayVerificationHooks(
            advance_and_apply=advance_and_apply,
            checkpoint_sha256=lambda: current_hash,
            canonical_events=lambda: events,
        ),
    )
    assert calls == [(10, ("move",)), (20, ())]
    assert result.checkpoints_verified == 1
    assert result.final_state_sha256 == "f" * 64

    with pytest.raises(ReplayCorruptionError, match="checkpoint mismatch"):
        replay_and_verify(
            _public_bundle(),
            ReplayVerificationHooks(
                advance_and_apply=lambda _tick, _entries: None,
                checkpoint_sha256=lambda: "0" * 64,
                canonical_events=lambda: (_event(10),),
            ),
        )

    with pytest.raises(ReplayCorruptionError, match="public event mismatch"):
        replay_and_verify(
            _public_bundle(),
            ReplayVerificationHooks(
                advance_and_apply=lambda _tick, _entries: None,
                checkpoint_sha256=lambda: "c" * 64,
                canonical_events=lambda: (),
            ),
        )


def test_artifact_and_replay_modules_have_no_provider_or_network_imports() -> None:
    import genesis_arena.duel.artifacts as artifacts_module
    import genesis_arena.duel.replay as replay_module

    forbidden = {"httpx", "openai", "requests", "socket", "urllib"}
    for module in (artifacts_module, replay_module):
        source = Path(module.__file__).read_text(encoding="utf-8")
        assert all(f"import {name}" not in source for name in forbidden)
