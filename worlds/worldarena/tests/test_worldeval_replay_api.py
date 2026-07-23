from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Mapping

from fastapi import FastAPI
from fastapi.testclient import TestClient
from worldarena.replay_api import ReplayCatalog, router
from worldarena.replay_verifiers import (
    PRIMITIVE_SANDBOX_NATIVE_SCHEMA,
    PRIMITIVE_SANDBOX_NATIVE_VERIFIER,
    WAYPOINT_MAZE_NATIVE_SCHEMA,
    WAYPOINT_MAZE_NATIVE_VERIFIER,
    default_native_verifiers,
)
from worldeval.features.cli import _repository_native_verifiers
from worldeval.replay import (
    PUBLIC,
    ArtifactInput,
    NativeReplayClaims,
    NativeVerificationResult,
    NativeVerifierRegistry,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
    verify_replay_bundle,
    write_terminal_demo_bundle,
)

HASH_A = "a" * 64
HASH_B = "b" * 64
INITIALIZATION_HASH = f"sha256:{'c' * 64}"


def _bound_documents(run_id: str) -> dict[str, dict[str, Any]]:
    objective = {
        "objective_id": "tree-safety-v0",
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
        "objective_id": "tree-safety-v0",
        "outcome": "safe_return",
        "terminal_tick": 44,
        "passed": True,
        "replay_saved": True,
        "replay_offline_verified": True,
    }
    result = {
        "run_id": run_id,
        "scenario_id": "tree-chop-interrupted-v0",
        "outcome": "safe_return",
        "terminal_tick": 44,
        "terminal_state_hash": HASH_A,
        "passed": True,
    }
    return {
        "environment_init": initialization,
        "objective": objective,
        "evaluation": evaluation,
        "result": result,
    }


def _metadata(run_id: str) -> dict[str, Any]:
    return {
        "run_id": run_id,
        "game": {"id": "worldarena-primitive-sandbox-v0"},
        "scenario": {"id": "tree-chop-interrupted-v0"},
        "task": {"id": "tree-safety-v0"},
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
        "terminal": {"outcome": "safe_return", "tick_count": 44},
        "offline_verification": {
            "verified": True,
            "provider_calls": 0,
            "verifier": "primitive-sandbox-native-v1",
        },
    }


def _verifier(
    payload: bytes,
    _descriptor: Mapping[str, Any],
) -> NativeVerificationResult:
    value = strict_json_loads(payload)
    assert value["outcome"] == "safe_return"
    documents = _bound_documents(value["run_id"])
    return NativeVerificationResult(
        final_state_hash=HASH_A,
        provider_calls=value["provider_calls"],
        claims=NativeReplayClaims(
            protocol_id="worldeval-agent",
            protocol_version="0.1.0",
            protocol_package_hash=HASH_A,
            game_id="worldarena-primitive-sandbox-v0",
            environment_id="worldarena-primitive-sandbox-v0",
            engine_id="godot",
            engine_build_hash=HASH_B,
            run_id=value["run_id"],
            scenario_id="tree-chop-interrupted-v0",
            objective_id="tree-safety-v0",
            action_profile="semantic-grid-actions-v1",
            observation_profile="semantic-grid-visible-v1",
            decision_profile="dynamic-step-locked-v1",
            initialization_hash=value["initialization_hash"],
            terminal_outcome=value["outcome"],
            terminal_tick=44,
            evidence_sha256={
                role: canonical_sha256(documents[role])
                for role in ("environment_init", "objective", "evaluation")
            },
        ),
    )


def _bundle(
    root: Path,
    run_id: str = "sandbox-interrupted-001",
    *,
    provider_calls: int = 0,
) -> Path:
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
                visibility=PUBLIC,
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
                    "outcome": "safe_return",
                    "provider_calls": provider_calls,
                    "run_id": run_id,
                    "initialization_hash": INITIALIZATION_HASH,
                },
                native_schema="primitive-sandbox/replay/1.0.0",
                verifier="primitive-sandbox-native-v1",
                final_state_hash=HASH_A,
            ),
        ),
        native_verifiers={"primitive-sandbox-native-v1": _verifier},
        require_claim_binding=True,
    )


def _client(
    root: Path,
    *,
    native_verifier: Callable[
        [bytes, Mapping[str, Any]], NativeVerificationResult
    ] = _verifier,
) -> TestClient:
    app = FastAPI()
    app.state.worldeval_replays = ReplayCatalog(
        (root,),
        native_verifiers=NativeVerifierRegistry(
            {
                (
                    "primitive-sandbox-native-v1",
                    "primitive-sandbox/replay/1.0.0",
                ): native_verifier
            }
        ),
    )
    app.include_router(router)
    return TestClient(app)


def _rewrite_manifest(bundle: Path, mutation: Any) -> None:
    path = bundle / "manifest.json"
    manifest = strict_json_loads(path.read_bytes())
    mutation(manifest)
    body = {key: value for key, value in manifest.items() if key != "seal"}
    manifest["seal"] = {
        "algorithm": "sha256",
        "value": canonical_sha256(body),
    }
    path.write_bytes(canonical_json_bytes(manifest))


def test_public_catalog_omits_protected_descriptors(tmp_path: Path) -> None:
    _bundle(tmp_path)
    with _client(tmp_path) as client:
        response = client.get("/api/worldeval/replays")

    assert response.status_code == 200
    [entry] = response.json()
    assert entry["run_id"] == "sandbox-interrupted-001"
    assert entry["offline_verification"] == {
        "provider_calls": 0,
        "verified": True,
        "verifier": "primitive-sandbox-native-v1",
    }
    assert [artifact["role"] for artifact in entry["artifacts"]] == ["evaluation"]
    assert "seal" not in entry


def test_only_allowlisted_public_files_can_be_downloaded(tmp_path: Path) -> None:
    _bundle(tmp_path)
    with _client(tmp_path) as client:
        public = client.get(
            "/api/worldeval/replays/sandbox-interrupted-001/files/evaluation"
        )
        protected = client.get(
            "/api/worldeval/replays/sandbox-interrupted-001/files/primary"
        )

    assert public.status_code == 200
    assert public.json() == _bound_documents("sandbox-interrupted-001")["evaluation"]
    assert public.headers["x-content-type-options"] == "nosniff"
    assert protected.status_code == 404


def test_list_detail_and_download_each_rerun_native_verification(
    tmp_path: Path,
) -> None:
    _bundle(tmp_path)
    calls: list[str] = []

    def counting_verifier(
        payload: bytes,
        descriptor: Mapping[str, Any],
    ) -> NativeVerificationResult:
        calls.append(str(descriptor["path"]))
        return _verifier(payload, descriptor)

    with _client(tmp_path, native_verifier=counting_verifier) as client:
        listed = client.get("/api/worldeval/replays")
        after_list = len(calls)
        detail = client.get("/api/worldeval/replays/sandbox-interrupted-001")
        after_detail = len(calls)
        download = client.get(
            "/api/worldeval/replays/sandbox-interrupted-001/files/evaluation"
        )
        after_download = len(calls)

    assert listed.status_code == detail.status_code == download.status_code == 200
    assert after_list > 0
    assert after_detail > after_list
    assert after_download > after_detail


def test_tampered_bundles_are_not_listed(tmp_path: Path) -> None:
    bundle = _bundle(tmp_path)
    (bundle / "evidence/evaluation.json").write_text('{"passed":false}', encoding="utf-8")

    with _client(tmp_path) as client:
        response = client.get("/api/worldeval/replays")

    assert response.status_code == 200
    assert response.json() == []


def test_forged_offline_verification_claim_is_not_echoed_or_accepted(
    tmp_path: Path,
) -> None:
    bundle = _bundle(tmp_path)

    def forge(manifest: dict[str, Any]) -> None:
        manifest["offline_verification"]["verifier"] = "forged-offline-v1"

    _rewrite_manifest(bundle, forge)
    assert (
        verify_replay_bundle(bundle).manifest["offline_verification"]["verifier"]
        == "forged-offline-v1"
    )

    with _client(tmp_path) as client:
        listed = client.get("/api/worldeval/replays")
        detail = client.get("/api/worldeval/replays/sandbox-interrupted-001")

    assert listed.status_code == 200
    assert listed.json() == []
    assert detail.status_code == 404


def test_unsupported_native_verifier_fails_closed_for_all_public_routes(
    tmp_path: Path,
) -> None:
    bundle = _bundle(tmp_path)

    def replace_verifier(manifest: dict[str, Any]) -> None:
        replay = next(
            value for value in manifest["artifacts"] if value["kind"] == "replay"
        )
        replay["verifier"] = "unsupported-native-v1"
        manifest["offline_verification"]["verifier"] = "unsupported-native-v1"

    _rewrite_manifest(bundle, replace_verifier)

    with _client(tmp_path) as client:
        listed = client.get("/api/worldeval/replays")
        detail = client.get("/api/worldeval/replays/sandbox-interrupted-001")
        download = client.get(
            "/api/worldeval/replays/sandbox-interrupted-001/files/evaluation"
        )

    assert listed.status_code == 200
    assert listed.json() == []
    assert detail.status_code == 404
    assert download.status_code == 404


def test_manifest_zero_provider_claim_cannot_hide_native_provider_calls(
    tmp_path: Path,
) -> None:
    _bundle(tmp_path, provider_calls=1)

    with _client(tmp_path) as client:
        listed = client.get("/api/worldeval/replays")
        detail = client.get("/api/worldeval/replays/sandbox-interrupted-001")

    assert listed.status_code == 200
    assert listed.json() == []
    assert detail.status_code == 404


def test_repository_and_feature_cli_share_the_exact_worldarena_registry() -> None:
    expected = (
        (
            PRIMITIVE_SANDBOX_NATIVE_VERIFIER,
            PRIMITIVE_SANDBOX_NATIVE_SCHEMA,
        ),
        (
            WAYPOINT_MAZE_NATIVE_VERIFIER,
            WAYPOINT_MAZE_NATIVE_SCHEMA,
        ),
    )

    assert default_native_verifiers().keys == expected
    loaded = _repository_native_verifiers()
    assert isinstance(loaded, NativeVerifierRegistry)
    assert loaded.keys == expected
