import json
from pathlib import Path

import pytest
from genesis_arena.embodiment.artifacts import (
    PROTECTED_LAYER,
    PUBLIC_LAYER,
    EpisodeArtifact,
    EpisodeArtifactBundle,
    EpisodeArtifactError,
    EpisodeArtifactRecorder,
    verify_offline_replay,
)
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_sha256
from genesis_arena.embodiment.replay import ReplayLedger, verify_replay_bytes

ROOT = Path(__file__).resolve().parents[2]


def _stage_a_replay() -> tuple[bytes, EmbodimentProtocolPackage]:
    transcript = json.loads(
        (ROOT / "game/embodiment_protocol/golden/stage-a-orientation-forward-v1.json").read_text()
    )
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    ledger = ReplayLedger(
        transcript["config"], transcript["config_sha256"], package.package_sha256
    )
    ledger.record_initial(
        observations=transcript["initial_boundary"]["observations"],
        state_hash=transcript["initial_boundary"]["state_hash"],
    )
    for step in transcript["steps"]:
        ledger.record_step(decision_window=step["decision_window"], result=step["result"])
    return (
        ledger.seal(
            final_terminal=transcript["terminal_boundary"]["terminal"],
            final_state_hash=transcript["terminal_boundary"]["state_hash"],
        ),
        package,
    )


def test_public_and_protected_episode_evidence_are_separate_and_verifiable() -> None:
    replay, package = _stage_a_replay()
    replay_value = verify_replay_bytes(replay, package=package)
    recorder = EpisodeArtifactRecorder(
        "ep_golden_stage_a_orientation_forward_v1", protocol_package=package
    )
    recorder.freeze_run_configuration(
        provider="scripted",
        model="golden-stage-a",
        settings={"deadline_budget_ms": 1000, "max_output_bytes": 4096},
    )
    recorder.record_boundary(
        observation_seq=0,
        state_hash=replay_value["initial_state_hash"],
        observations=replay_value["initial_observations"],
        terminal=next(iter(replay_value["initial_observations"].values()))["terminal"],
    )
    recorder.record_provider_call(
        observation_seq=0,
        prompt="Return one controller action.",
        raw_output=b"{}",
        scratchpad_utf8=b"remember",
        telemetry={"latency_ms": 1},
    )
    for index, step in enumerate(replay_value["steps"]):
        result = step["result"]
        recorder.record_boundary(
            observation_seq=index + 1,
            state_hash=result["state_hash"],
            observations=result["observations"],
            receipts=result["receipts"],
            public_events=result["public_events"],
            terminal=result["terminal"],
        )
    bundles = recorder.seal(authority_replay=replay, evaluation={"score": 1})
    assert bundles.public.layer == PUBLIC_LAYER
    assert bundles.protected.layer == PROTECTED_LAYER
    public_text = bundles.public.bundle_bytes.decode()
    assert "operator_position_mt" not in public_text
    assert "Return one controller action" not in public_text
    assert EpisodeArtifactBundle.verify(bundles.public.bundle_bytes).content_sha256 == (
        bundles.public.content_sha256
    )
    summary = json.loads(bundles.public.read("replay_summary"))
    assert summary["frozen_configuration"] == {
        "config_sha256": replay_value["config_sha256"],
        "protocol_package_sha256": package.package_sha256,
        "provider_sha256": canonical_sha256({"provider": "scripted"}),
        "model_sha256": canonical_sha256({"model": "golden-stage-a"}),
        "settings_sha256": canonical_sha256(
            {"deadline_budget_ms": 1000, "max_output_bytes": 4096}
        ),
    }
    evaluation = json.loads(bundles.public.read("evaluation"))
    assert evaluation["schema_version"] == "llm-controller/evaluation/1.0.0"
    assert evaluation["scope"] == "solo"
    assert evaluation["metrics"]["task_success"]["value"] is True
    assert evaluation["metrics"]["deterministic_replay_verification"]["value"] is True
    verified = verify_offline_replay(bundles.protected.bundle_bytes, package=package)
    assert verified["final_terminal"]["outcome"] == "success"


def test_demo_identity_is_bound_into_sealed_public_evaluation() -> None:
    replay, package = _stage_a_replay()
    replay_value = verify_replay_bytes(replay, package=package)
    recorder = EpisodeArtifactRecorder(
        "ep_golden_stage_a_orientation_forward_v1", protocol_package=package
    )
    recorder.freeze_run_configuration(
        provider="demo",
        model="orientation-demo-v1",
        settings={"demo_policy_lock": {"scenario_id": "orientation-v0"}},
    )
    recorder.record_boundary(
        observation_seq=0,
        state_hash=replay_value["initial_state_hash"],
        observations=replay_value["initial_observations"],
        terminal=next(iter(replay_value["initial_observations"].values()))["terminal"],
    )
    for index, step in enumerate(replay_value["steps"]):
        result = step["result"]
        recorder.record_boundary(
            observation_seq=index + 1,
            state_hash=result["state_hash"],
            observations=result["observations"],
            receipts=result["receipts"],
            public_events=result["public_events"],
            terminal=result["terminal"],
        )
    bundles = recorder.seal(authority_replay=replay, evaluation={})
    evaluation = json.loads(bundles.public.read("evaluation"))
    assert evaluation["scenario_id"] == "orientation-v0"
    assert evaluation["evaluation_profile_id"] == "solo-orientation-v1"


def test_short_replay_cannot_be_sealed_as_multi_action_showcase() -> None:
    replay, package = _stage_a_replay()
    replay_value = verify_replay_bytes(replay, package=package)
    recorder = EpisodeArtifactRecorder(
        "ep_golden_stage_a_orientation_forward_v1", protocol_package=package
    )
    recorder.freeze_run_configuration(
        provider="demo",
        model="construction-demo-v1",
        settings={"demo_policy_lock": {"scenario_id": "multi-action-demo-v0"}},
    )
    recorder.record_boundary(
        observation_seq=0,
        state_hash=replay_value["initial_state_hash"],
        observations=replay_value["initial_observations"],
        terminal=next(iter(replay_value["initial_observations"].values()))["terminal"],
    )
    for index, step in enumerate(replay_value["steps"]):
        result = step["result"]
        recorder.record_boundary(
            observation_seq=index + 1,
            state_hash=result["state_hash"],
            observations=result["observations"],
            receipts=result["receipts"],
            public_events=result["public_events"],
            terminal=result["terminal"],
        )
    with pytest.raises(ValueError, match="multi-action"):
        recorder.seal(authority_replay=replay, evaluation={})


def test_artifacts_reject_credential_keys_and_secret_like_bytes() -> None:
    with pytest.raises(EpisodeArtifactError, match="credential"):
        EpisodeArtifact.json("evaluation", {"api_key": "not-allowed"})
    with pytest.raises(EpisodeArtifactError, match="credential-like"):
        EpisodeArtifact("provider_outputs", "application/json", b'"sk-secret-value"')


@pytest.mark.parametrize(
    "key",
    [
        "x-goog-api-key",
        "openai_api_key",
        "provider_key",
        "content-type",
        "request_headers",
    ],
)
def test_artifacts_reject_provider_credential_and_header_aliases(key: str) -> None:
    with pytest.raises(EpisodeArtifactError, match="credential/header"):
        EpisodeArtifact.json("telemetry", {key: "opaque-session-value"})


def test_raw_json_artifacts_apply_the_same_nested_key_policy() -> None:
    with pytest.raises(EpisodeArtifactError, match="credential/header"):
        EpisodeArtifact(
            "provider_outputs",
            "application/json",
            b'{"nested":{"x-goog-api-key":"opaque-session-value"}}',
        )
