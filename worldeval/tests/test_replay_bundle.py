from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any, Mapping

import pytest
from jsonschema import Draft202012Validator
from worldeval.replay import (
    BUNDLE_SCHEMA,
    INCOMPLETE_RUN_SCHEMA,
    PUBLIC,
    ArtifactInput,
    BundleExistsError,
    BundleVerificationError,
    NativeReplayClaims,
    NativeVerificationResult,
    NativeVerifierRegistry,
    ProtectedArtifactError,
    ReplayBundleError,
    UnsafeBundlePathError,
    canonical_json_bytes,
    canonical_sha256,
    incomplete_run_schema_path,
    load_incomplete_run,
    manifest_schema_path,
    public_artifacts,
    resolve_artifact,
    strict_json_loads,
    verify_replay_bundle,
    write_incomplete_run,
    write_terminal_demo_bundle,
)

HASH_A = "a" * 64
HASH_B = "b" * 64
INITIALIZATION_HASH = f"sha256:{'c' * 64}"


def _metadata(run_id: str) -> dict[str, Any]:
    return {
        "run_id": run_id,
        "game": {"id": "worldarena-primitive-sandbox-v0"},
        "scenario": {"id": "tree-chop-nominal-v0"},
        "task": {"id": "destroy-tree-v0"},
        "subject": {"kind": "agent", "id": "participant-0"},
        "protocol": {
            "id": "worldeval-agent",
            "version": "0.1.0",
            "package_hash": HASH_A,
        },
        "engine": {"id": "godot", "build_hash": HASH_B},
        "seed": 7,
        "profiles": {
            "action": "semantic-grid-actions-v1",
            "observation": "semantic-grid-visible-v1",
            "decision": "dynamic-step-locked-v1",
        },
        "terminal": {"outcome": "success", "tick_count": 42},
        "offline_verification": {
            "verified": True,
            "provider_calls": 0,
            "verifier": "primitive-sandbox-native-v1",
        },
    }


def _native_replay(*, value: str = "won") -> ArtifactInput:
    return ArtifactInput.json(
        path="replays/primary.replay.json",
        role="primary",
        kind="replay",
        value={"final": value, "ticks": [1, 2, 3]},
        native_schema="primitive-sandbox/replay/1.0.0",
        verifier="primitive-sandbox-native-v1",
        final_state_hash=HASH_A,
        participants=("participant-0",),
    )


def _native_verifier(payload: bytes, descriptor: Mapping[str, Any]) -> str:
    value = strict_json_loads(payload)
    if not isinstance(value, dict) or value.get("final") not in {"won", "retreated"}:
        raise ValueError("native replay did not reach a terminal outcome")
    assert descriptor["native_schema"] == "primitive-sandbox/replay/1.0.0"
    return HASH_A


def _write(
    root: Path,
    run_id: str,
    *,
    artifacts: tuple[ArtifactInput, ...] | None = None,
) -> Path:
    return write_terminal_demo_bundle(
        root,
        metadata=_metadata(run_id),
        artifacts=(_native_replay(),) if artifacts is None else artifacts,
        native_verifiers={"primitive-sandbox-native-v1": _native_verifier},
    )


def _bound_documents(run_id: str) -> dict[str, dict[str, Any]]:
    objective = {
        "objective_id": "destroy-tree-v0",
        "protocol": "worldeval-agent/0.1.0",
    }
    initialization = {
        "protocol": "worldeval-agent/0.1.0",
        "game_id": "worldarena-primitive-sandbox-v0",
        "environment_id": "worldarena-primitive-sandbox-v0",
        "initialization_hash": INITIALIZATION_HASH,
        "profiles": {
            "action": "semantic-grid-actions-v1",
            "observation": "semantic-grid-visible-v1",
            "decision": "dynamic-step-locked-v1",
        },
        "active_objective": objective,
    }
    evaluation = {
        "objective_id": "destroy-tree-v0",
        "outcome": "success",
        "terminal_tick": 42,
        "passed": True,
        "replay_saved": True,
        "replay_offline_verified": True,
    }
    result = {
        "run_id": run_id,
        "scenario_id": "tree-chop-nominal-v0",
        "outcome": "success",
        "terminal_tick": 42,
        "terminal_state_hash": HASH_A,
        "passed": True,
    }
    return {
        "environment_init": initialization,
        "objective": objective,
        "evaluation": evaluation,
        "result": result,
    }


def _bound_native_verifier(
    payload: bytes,
    descriptor: Mapping[str, Any],
) -> NativeVerificationResult:
    replay = strict_json_loads(payload)
    assert descriptor["native_schema"] == "primitive-sandbox/replay/1.0.0"
    documents = _bound_documents(replay["run_id"])
    return NativeVerificationResult(
        final_state_hash=HASH_A,
        provider_calls=0,
        claims=NativeReplayClaims(
            protocol_id="worldeval-agent",
            protocol_version="0.1.0",
            protocol_package_hash=HASH_A,
            game_id="worldarena-primitive-sandbox-v0",
            environment_id="worldarena-primitive-sandbox-v0",
            engine_id="godot",
            engine_build_hash=HASH_B,
            run_id=replay["run_id"],
            scenario_id=replay["scenario_id"],
            objective_id="destroy-tree-v0",
            action_profile="semantic-grid-actions-v1",
            observation_profile="semantic-grid-visible-v1",
            decision_profile="dynamic-step-locked-v1",
            initialization_hash=replay["initialization_hash"],
            terminal_outcome=replay["terminal_outcome"],
            terminal_tick=replay["terminal_tick"],
            evidence_sha256={
                role: canonical_sha256(documents[role])
                for role in ("environment_init", "objective", "evaluation")
            },
        ),
    )


def _write_bound(root: Path, run_id: str = "run-bound") -> Path:
    documents = _bound_documents(run_id)
    return write_terminal_demo_bundle(
        root,
        metadata=_metadata(run_id),
        artifacts=(
            ArtifactInput.json(
                path="evidence/environment-init.json",
                role="environment_init",
                kind="evidence",
                value=documents["environment_init"],
            ),
            ArtifactInput.json(
                path="evidence/evaluation.json",
                role="evaluation",
                kind="evidence",
                value=documents["evaluation"],
            ),
            ArtifactInput.json(
                path="evidence/objective.json",
                role="objective",
                kind="evidence",
                value=documents["objective"],
            ),
            ArtifactInput.json(
                path="evidence/result.json",
                role="result",
                kind="evidence",
                value=documents["result"],
            ),
            ArtifactInput.json(
                path="replays/primary.replay.json",
                role="primary",
                kind="replay",
                value={
                    "initialization_hash": INITIALIZATION_HASH,
                    "provider_calls": 0,
                    "run_id": run_id,
                    "scenario_id": "tree-chop-nominal-v0",
                    "terminal_outcome": "success",
                    "terminal_tick": 42,
                },
                native_schema="primitive-sandbox/replay/1.0.0",
                verifier="primitive-sandbox-native-v1",
                final_state_hash=HASH_A,
            ),
        ),
        native_verifiers={"primitive-sandbox-native-v1": _bound_native_verifier},
        require_claim_binding=True,
    )


def _reseal_manifest(bundle: Path, mutation: Any) -> None:
    manifest_path = bundle / "manifest.json"
    manifest = strict_json_loads(manifest_path.read_bytes())
    mutation(manifest)
    body = {key: value for key, value in manifest.items() if key != "seal"}
    manifest["seal"] = {"algorithm": "sha256", "value": canonical_sha256(body)}
    manifest_path.write_bytes(canonical_json_bytes(manifest))


def test_checked_in_manifest_schema_is_draft_2020_12() -> None:
    schema = strict_json_loads(manifest_schema_path().read_bytes())
    Draft202012Validator.check_schema(schema)
    assert schema["properties"]["schema"]["const"] == BUNDLE_SCHEMA
    incomplete_schema = strict_json_loads(incomplete_run_schema_path().read_bytes())
    Draft202012Validator.check_schema(incomplete_schema)
    assert incomplete_schema["properties"]["schema"]["const"] == INCOMPLETE_RUN_SCHEMA


def test_terminal_bundle_is_canonical_deterministic_and_independently_verified(
    tmp_path: Path,
) -> None:
    public_evidence = ArtifactInput.json(
        path="evidence/evaluation.json",
        role="evaluation",
        kind="evidence",
        value={"passed": True, "score_milli": 1000},
        visibility=PUBLIC,
    )
    first = _write(
        tmp_path / "one",
        "run-deterministic",
        artifacts=(public_evidence, _native_replay()),
    )
    second_metadata = dict(reversed(tuple(_metadata("run-deterministic").items())))
    second = write_terminal_demo_bundle(
        tmp_path / "two",
        metadata=second_metadata,
        artifacts=(_native_replay(), public_evidence),
        native_verifiers={"primitive-sandbox-native-v1": _native_verifier},
    )

    assert (first / "manifest.json").read_bytes() == (second / "manifest.json").read_bytes()
    manifest_bytes = (first / "manifest.json").read_bytes()
    assert canonical_json_bytes(strict_json_loads(manifest_bytes)) == manifest_bytes
    report = verify_replay_bundle(
        first,
        native_verifiers={"primitive-sandbox-native-v1": _native_verifier},
        require_native_verification=True,
    )
    assert report.manifest["schema"] == BUNDLE_SCHEMA
    assert report.manifest["offline_verification"]["provider_calls"] == 0
    assert report.verified_paths == (
        "evidence/evaluation.json",
        "replays/primary.replay.json",
    )


def test_writer_requires_a_native_verifier_before_publishing(tmp_path: Path) -> None:
    with pytest.raises(BundleVerificationError, match="verifier is unavailable"):
        write_terminal_demo_bundle(
            tmp_path,
            metadata=_metadata("run-unverified"),
            artifacts=(_native_replay(),),
            native_verifiers={},
        )

    assert not (tmp_path / "run-unverified").exists()
    assert not tuple(tmp_path.glob(".run-unverified.*"))


def test_exact_registry_dispatches_by_verifier_and_native_schema(
    tmp_path: Path,
) -> None:
    bundle = _write(tmp_path, "run-exact-registry")
    registry = NativeVerifierRegistry(
        {
            (
                "primitive-sandbox-native-v1",
                "primitive-sandbox/replay/1.0.0",
            ): lambda payload, descriptor: NativeVerificationResult(
                final_state_hash=_native_verifier(payload, descriptor),
                provider_calls=0,
            )
        }
    )

    report = verify_replay_bundle(
        bundle,
        native_verifiers=registry,
        require_native_verification=True,
        require_provider_calls_zero=True,
    )

    assert report.independent_offline_verification == {
        "provider_calls": 0,
        "verified": True,
        "verifier": "primitive-sandbox-native-v1",
    }


def test_exact_registry_rejects_unsupported_verifier_schema_pair(
    tmp_path: Path,
) -> None:
    bundle = _write(tmp_path, "run-unsupported-native-schema")
    wrong_schema_registry = NativeVerifierRegistry(
        {
            (
                "primitive-sandbox-native-v1",
                "primitive-sandbox/replay/2.0.0",
            ): _native_verifier
        }
    )

    with pytest.raises(BundleVerificationError, match="verifier is unavailable"):
        verify_replay_bundle(
            bundle,
            native_verifiers=wrong_schema_registry,
            require_native_verification=True,
        )


def test_provider_free_gate_requires_independently_measured_zero_calls(
    tmp_path: Path,
) -> None:
    bundle = _write(tmp_path, "run-forged-provider-claim")
    registry = NativeVerifierRegistry(
        {
            (
                "primitive-sandbox-native-v1",
                "primitive-sandbox/replay/1.0.0",
            ): lambda payload, descriptor: NativeVerificationResult(
                final_state_hash=_native_verifier(payload, descriptor),
                provider_calls=1,
            )
        }
    )

    with pytest.raises(BundleVerificationError, match="independently zero"):
        verify_replay_bundle(
            bundle,
            native_verifiers=registry,
            require_native_verification=True,
            require_provider_calls_zero=True,
        )


def test_authority_claim_binding_requires_recomputed_native_claims(
    tmp_path: Path,
) -> None:
    unbound = _write(tmp_path, "run-unbound")
    with pytest.raises(
        BundleVerificationError,
        match="requires authority-confirmed outer claims",
    ):
        verify_replay_bundle(
            unbound,
            native_verifiers={"primitive-sandbox-native-v1": _native_verifier},
            require_native_verification=True,
            require_claim_binding=True,
        )

    bound = _write_bound(tmp_path)
    report = verify_replay_bundle(
        bound,
        native_verifiers={
            "primitive-sandbox-native-v1": _bound_native_verifier
        },
        require_native_verification=True,
        require_provider_calls_zero=True,
        require_claim_binding=True,
    )
    assert report.manifest["run_id"] == "run-bound"


@pytest.mark.parametrize(
    ("field_name", "mutation"),
    (
        (
            "run_id",
            lambda value: value.__setitem__("run_id", "forged-run"),
        ),
        (
            "scenario",
            lambda value: value["scenario"].__setitem__("id", "forged-scenario"),
        ),
        (
            "protocol_id",
            lambda value: value["protocol"].__setitem__("id", "forged-agent"),
        ),
        (
            "protocol_version",
            lambda value: value["protocol"].__setitem__("version", "9.9.9"),
        ),
        (
            "protocol_package_hash",
            lambda value: value["protocol"].__setitem__(
                "package_hash", HASH_B
            ),
        ),
        (
            "engine_id",
            lambda value: value["engine"].__setitem__("id", "forged-engine"),
        ),
        (
            "engine_build_hash",
            lambda value: value["engine"].__setitem__(
                "build_hash", "d" * 64
            ),
        ),
        (
            "terminal_outcome",
            lambda value: value["terminal"].__setitem__(
                "outcome", "forged-outcome"
            ),
        ),
        (
            "terminal_tick",
            lambda value: value["terminal"].__setitem__("tick_count", 99),
        ),
    ),
)
def test_authority_claim_binding_rejects_resealed_outer_identity_forgery(
    tmp_path: Path,
    field_name: str,
    mutation: Any,
) -> None:
    bundle = _write_bound(tmp_path, run_id=f"run-forged-{field_name}")
    _reseal_manifest(bundle, mutation)

    with pytest.raises(
        BundleVerificationError,
        match=rf"outer {field_name} differs",
    ):
        verify_replay_bundle(
            bundle,
            native_verifiers={
                "primitive-sandbox-native-v1": _bound_native_verifier
            },
            require_native_verification=True,
            require_claim_binding=True,
        )


@pytest.mark.parametrize(
    ("role", "field_name", "forged_value"),
    (
        ("environment_init", "initialization_hash", f"sha256:{'d' * 64}"),
        ("objective", "objective_id", "forged-objective"),
        ("evaluation", "terminal_tick", 99),
    ),
)
def test_authority_claim_binding_rejects_resealed_evidence_forgery(
    tmp_path: Path,
    role: str,
    field_name: str,
    forged_value: Any,
) -> None:
    bundle = _write_bound(tmp_path, run_id=f"run-forged-{role}")
    artifact_path = {
        "environment_init": bundle / "evidence/environment-init.json",
        "objective": bundle / "evidence/objective.json",
        "evaluation": bundle / "evidence/evaluation.json",
    }[role]
    artifact = strict_json_loads(artifact_path.read_bytes())
    artifact[field_name] = forged_value
    payload = canonical_json_bytes(artifact)
    artifact_path.write_bytes(payload)

    def update_descriptor(manifest: dict[str, Any]) -> None:
        descriptor = next(
            value for value in manifest["artifacts"] if value["role"] == role
        )
        descriptor["sha256"] = hashlib.sha256(payload).hexdigest()
        descriptor["size_bytes"] = len(payload)

    _reseal_manifest(bundle, update_descriptor)
    with pytest.raises(
        BundleVerificationError,
        match=rf"{role} evidence differs",
    ):
        verify_replay_bundle(
            bundle,
            native_verifiers={
                "primitive-sandbox-native-v1": _bound_native_verifier
            },
            require_native_verification=True,
            require_claim_binding=True,
        )


def test_tampered_artifact_and_manifest_seal_fail_closed(tmp_path: Path) -> None:
    bundle = _write(tmp_path, "run-tampered-artifact")
    replay = bundle / "replays" / "primary.replay.json"
    replay.write_bytes(canonical_json_bytes({"final": "retreated", "ticks": [1]}))
    with pytest.raises(BundleVerificationError, match="size differs|digest differs"):
        verify_replay_bundle(bundle)

    second = _write(tmp_path, "run-tampered-manifest")
    manifest_path = second / "manifest.json"
    manifest = strict_json_loads(manifest_path.read_bytes())
    manifest["terminal"]["tick_count"] = 99
    manifest_path.write_bytes(canonical_json_bytes(manifest))
    with pytest.raises(BundleVerificationError, match="content seal differs"):
        verify_replay_bundle(second)


def test_noncanonical_json_artifact_is_rejected_before_staging(tmp_path: Path) -> None:
    with pytest.raises(ReplayBundleError, match="must be canonical"):
        ArtifactInput(
            path="replays/primary.replay.json",
            role="primary",
            kind="replay",
            data=b'{"z": 1, "a": 2}',
            media_type="application/json",
            native_schema="primitive-sandbox/replay/1.0.0",
            verifier="primitive-sandbox-native-v1",
            final_state_hash=HASH_A,
        )
    assert not tuple(tmp_path.iterdir())


@pytest.mark.parametrize(
    "path",
    (
        "../manifest.json",
        "replays/../../outside.json",
        "/tmp/replay.json",
        "replays\\primary.replay.json",
        "replays//primary.replay.json",
        "evidence/primary.replay.json",
    ),
)
def test_artifact_paths_cannot_traverse_or_mismatch_kind(path: str) -> None:
    with pytest.raises(UnsafeBundlePathError):
        ArtifactInput.json(
            path=path,
            role="primary",
            kind="replay",
            value={"final": "won"},
            native_schema="primitive-sandbox/replay/1.0.0",
            verifier="primitive-sandbox-native-v1",
            final_state_hash=HASH_A,
        )


def test_symlinked_artifact_and_symlinked_source_fail_closed(tmp_path: Path) -> None:
    bundle = _write(tmp_path, "run-symlink")
    replay = bundle / "replays" / "primary.replay.json"
    original = replay.read_bytes()
    external = tmp_path / "external.replay.json"
    external.write_bytes(original)
    replay.unlink()
    replay.symlink_to(external)
    with pytest.raises(BundleVerificationError, match="symlinked"):
        verify_replay_bundle(bundle)

    source = tmp_path / "source.replay.json"
    source.write_bytes(canonical_json_bytes({"final": "won", "ticks": []}))
    source_link = tmp_path / "source-link.replay.json"
    source_link.symlink_to(source)
    artifact = ArtifactInput(
        path="replays/primary.replay.json",
        role="primary",
        kind="replay",
        data=source_link,
        media_type="application/json",
        native_schema="primitive-sandbox/replay/1.0.0",
        verifier="primitive-sandbox-native-v1",
        final_state_hash=HASH_A,
    )
    with pytest.raises(UnsafeBundlePathError, match="source must not be a symlink"):
        _write(tmp_path, "run-source-symlink", artifacts=(artifact,))
    assert not (tmp_path / "run-source-symlink").exists()


def test_atomic_publication_cleans_staging_and_never_overwrites(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from worldeval.replay import bundle as module

    original_rename = os.rename

    def fail_rename(_source: object, _destination: object) -> None:
        raise OSError("simulated publication interruption")

    monkeypatch.setattr(module.os, "rename", fail_rename)
    with pytest.raises(OSError, match="publication interruption"):
        _write(tmp_path, "run-interrupted")
    assert not (tmp_path / "run-interrupted").exists()
    assert not tuple(tmp_path.glob(".run-interrupted.*"))

    monkeypatch.setattr(module.os, "rename", original_rename)
    bundle = _write(tmp_path, "run-immutable")
    manifest_before = (bundle / "manifest.json").read_bytes()
    with pytest.raises(BundleExistsError, match="immutable record"):
        _write(tmp_path, "run-immutable")
    assert (bundle / "manifest.json").read_bytes() == manifest_before
    assert not tuple(tmp_path.glob(".run-immutable.*"))


def test_incomplete_run_is_canonical_authenticated_and_never_a_replay(tmp_path: Path) -> None:
    path = write_incomplete_run(
        tmp_path,
        run_id="run-crashed",
        phase="authority-startup",
        reason="engine process exited before terminal state",
        recoverable=True,
        last_tick=4,
        details={"exit_code": 70},
    )
    assert not (path / "manifest.json").exists()
    diagnostic = load_incomplete_run(path)
    assert diagnostic["schema"] == INCOMPLETE_RUN_SCHEMA
    assert diagnostic["last_tick"] == 4
    with pytest.raises(BundleVerificationError, match="manifest"):
        verify_replay_bundle(path)
    with pytest.raises(BundleExistsError):
        _write(tmp_path, "run-crashed")

    diagnostic_path = path / "incomplete-run.json"
    value = strict_json_loads(diagnostic_path.read_bytes())
    value["reason"] = "rewritten"
    diagnostic_path.write_bytes(canonical_json_bytes(value))
    with pytest.raises(BundleVerificationError, match="seal differs"):
        load_incomplete_run(path)


def test_public_and_protected_artifacts_have_distinct_access_paths(tmp_path: Path) -> None:
    evaluation = ArtifactInput.json(
        path="evidence/evaluation.json",
        role="evaluation",
        kind="evidence",
        value={"passed": True},
        visibility=PUBLIC,
    )
    bundle = _write(tmp_path, "run-disclosure", artifacts=(_native_replay(), evaluation))

    assert resolve_artifact(bundle, "evaluation").name == "evaluation.json"
    with pytest.raises(ProtectedArtifactError):
        resolve_artifact(bundle, "primary")
    assert resolve_artifact(bundle, "primary", allow_protected=True).name == "primary.replay.json"
    assert [item["role"] for item in public_artifacts(bundle)] == ["evaluation"]


def test_optional_media_can_be_deleted_without_invalidating_replay(tmp_path: Path) -> None:
    media = ArtifactInput(
        path="media/broadcast.mp4",
        role="broadcast",
        kind="media",
        data=b"derived-media",
        visibility=PUBLIC,
        media_type="video/mp4",
    )
    bundle = _write(tmp_path, "run-media", artifacts=(media, _native_replay()))
    media_path = bundle / "media" / "broadcast.mp4"
    media_path.unlink()

    report = verify_replay_bundle(bundle)
    assert report.missing_optional_media == ("media/broadcast.mp4",)
    assert "replays/primary.replay.json" in report.verified_paths
    with pytest.raises(BundleVerificationError, match="required but missing"):
        verify_replay_bundle(bundle, require_media=True)


def test_undeclared_file_and_mismatched_native_final_hash_fail_closed(tmp_path: Path) -> None:
    bundle = _write(tmp_path, "run-extra")
    (bundle / "evidence").mkdir()
    (bundle / "evidence" / "surprise.json").write_bytes(b"{}")
    with pytest.raises(BundleVerificationError, match="undeclared"):
        verify_replay_bundle(bundle)

    second = _write(tmp_path, "run-native-mismatch")

    def wrong_final_hash(_payload: bytes, _descriptor: Mapping[str, Any]) -> str:
        return hashlib.sha256(b"wrong-state").hexdigest()

    with pytest.raises(BundleVerificationError, match="final-state hash differs"):
        verify_replay_bundle(
            second,
            native_verifiers={"primitive-sandbox-native-v1": wrong_final_hash},
            require_native_verification=True,
        )
