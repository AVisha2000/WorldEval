from __future__ import annotations

import hashlib
import json
import os
import socket
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import pytest
from worldeval.features import FeatureWorkflowError, FeatureWorkspace
from worldeval.features.cli import main as feature_main
from worldeval.replay import (
    ArtifactInput,
    NativeReplayClaims,
    NativeVerificationResult,
    NativeVerifierRegistry,
    canonical_sha256,
    strict_json_loads,
    write_terminal_demo_bundle,
)

FEATURE_REPLAY_VERIFIER = "feature-test-native-v1"
FEATURE_REPLAY_SCHEMA = "feature-test/replay/1.0.0"
FEATURE_FINAL_HASH = "f" * 64


def _feature_replay_verifier(payload: bytes, _descriptor) -> NativeVerificationResult:
    replay = strict_json_loads(payload)
    objective = {
        "objective_id": "verify-feature",
        "protocol": "test/1.0.0",
    }
    initialization = {
        "protocol": "test/1.0.0",
        "game_id": "feature-workflow-test",
        "environment_id": "feature-workflow-test",
        "initialization_hash": replay["initialization_hash"],
        "profiles": {
            "action": "test",
            "observation": "test",
            "decision": "test",
        },
        "active_objective": objective,
    }
    evaluation = {
        "objective_id": "verify-feature",
        "outcome": "success",
        "terminal_tick": 1,
        "passed": True,
        "replay_saved": True,
        "replay_offline_verified": True,
    }
    return NativeVerificationResult(
        FEATURE_FINAL_HASH,
        provider_calls=0,
        claims=NativeReplayClaims(
            protocol_id="test",
            protocol_version="1.0.0",
            protocol_package_hash="a" * 64,
            game_id="feature-workflow-test",
            environment_id="feature-workflow-test",
            engine_id="test",
            engine_build_hash="b" * 64,
            run_id=replay["run_id"],
            scenario_id="completion-gate",
            objective_id="verify-feature",
            action_profile="test",
            observation_profile="test",
            decision_profile="test",
            initialization_hash=replay["initialization_hash"],
            terminal_outcome="success",
            terminal_tick=1,
            evidence_sha256={
                "environment_init": canonical_sha256(initialization),
                "objective": canonical_sha256(objective),
                "evaluation": canonical_sha256(evaluation),
            },
        ),
    )


def _feature_replay_registry() -> NativeVerifierRegistry:
    return NativeVerifierRegistry(
        {(FEATURE_REPLAY_VERIFIER, FEATURE_REPLAY_SCHEMA): _feature_replay_verifier}
    )


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _repository(tmp_path: Path, *, now=None) -> FeatureWorkspace:
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q")
    _git(root, "config", "user.name", "WorldEval Test")
    _git(root, "config", "user.email", "worldeval-test@example.invalid")
    (root / "worldeval.workspace.json").write_text(
        json.dumps({"schema_version": 1, "paths": {"features": "features"}}),
        encoding="utf-8",
    )
    (root / "README.md").write_text("# test repository\n", encoding="utf-8")
    _git(root, "add", ".")
    _git(root, "commit", "-qm", "test baseline")
    workspace = FeatureWorkspace(
        root,
        now=now,
        native_replay_verifiers=_feature_replay_registry(),
    )
    workspace.ensure_layout()
    return workspace


def _criterion(feature_id: str, *, replay: bool = False, demo: bool = False):
    proof_types = ["test"]
    if replay:
        proof_types.append("replay")
    if demo:
        proof_types.append("demo")
    return [
        {
            "id": f"{feature_id}-AC-01",
            "description": "The feature produces independently verifiable evidence.",
            "proof_types": proof_types,
            "demo_required": demo,
            "replay_required": replay,
        }
    ]


def _create(workspace: FeatureWorkspace, feature_id: str, **kwargs):
    return workspace.create(
        feature_id,
        title=kwargs.pop("title", f"Feature {feature_id}"),
        summary=kwargs.pop("summary", "A repository workflow test feature."),
        affected_paths=kwargs.pop("affected_paths", (f"src/{feature_id.lower()}",)),
        acceptance_criteria=kwargs.pop("acceptance_criteria", _criterion(feature_id)),
        **kwargs,
    )


def _evidence(
    workspace: FeatureWorkspace,
    feature_id: str,
    artifact: Path,
    *,
    replay: bool = False,
    demo: bool = False,
    approval_types=(),
) -> None:
    record = workspace.get(feature_id, state="in-progress")
    relative = artifact.relative_to(workspace.root).as_posix()
    sha256 = hashlib.sha256(artifact.read_bytes()).hexdigest()
    entries = [{"type": "test", "path": relative, "sha256": sha256, "verified": True}]
    replay_relative = relative
    replay_sha256 = sha256
    if replay:
        initialization_hash = f"sha256:{'1' * 64}"
        objective = {
            "objective_id": "verify-feature",
            "protocol": "test/1.0.0",
        }
        initialization = {
            "protocol": "test/1.0.0",
            "game_id": "feature-workflow-test",
            "environment_id": "feature-workflow-test",
            "initialization_hash": initialization_hash,
            "profiles": {
                "action": "test",
                "observation": "test",
                "decision": "test",
            },
            "active_objective": objective,
        }
        evaluation = {
            "objective_id": "verify-feature",
            "outcome": "success",
            "terminal_tick": 1,
            "passed": True,
            "replay_saved": True,
            "replay_offline_verified": True,
        }
        result = {
            "run_id": feature_id.lower(),
            "scenario_id": "completion-gate",
            "outcome": "success",
            "terminal_tick": 1,
            "terminal_state_hash": FEATURE_FINAL_HASH,
            "passed": True,
        }
        replay_bundle = write_terminal_demo_bundle(
            workspace.root / "accepted-replays",
            metadata={
                "run_id": feature_id.lower(),
                "game": {"id": "feature-workflow-test"},
                "scenario": {"id": "completion-gate"},
                "task": {"id": "verify-feature"},
                "subject": {"kind": "agent", "id": "test-agent"},
                "protocol": {"id": "test", "version": "1.0.0", "package_hash": "a" * 64},
                "engine": {"id": "test", "build_hash": "b" * 64},
                "seed": 0,
                "profiles": {"action": "test", "observation": "test", "decision": "test"},
                "terminal": {"outcome": "success", "tick_count": 1},
                "offline_verification": {
                    "verified": True,
                    "provider_calls": 0,
                    "verifier": FEATURE_REPLAY_VERIFIER,
                },
            },
            artifacts=(
                ArtifactInput.json(
                    path="evidence/environment-init.json",
                    role="environment_init",
                    kind="evidence",
                    value=initialization,
                ),
                ArtifactInput.json(
                    path="evidence/evaluation.json",
                    role="evaluation",
                    kind="evidence",
                    value=evaluation,
                ),
                ArtifactInput.json(
                    path="evidence/objective.json",
                    role="objective",
                    kind="evidence",
                    value=objective,
                ),
                ArtifactInput.json(
                    path="evidence/result.json",
                    role="result",
                    kind="evidence",
                    value=result,
                ),
                ArtifactInput.json(
                    path="replays/primary.replay.json",
                    role="primary",
                    kind="replay",
                    value={
                        "run_id": feature_id.lower(),
                        "initialization_hash": initialization_hash,
                        "provider_calls": 0,
                        "terminal": True,
                    },
                    native_schema=FEATURE_REPLAY_SCHEMA,
                    verifier=FEATURE_REPLAY_VERIFIER,
                    final_state_hash=FEATURE_FINAL_HASH,
                ),
            ),
            native_verifiers=_feature_replay_registry(),
            require_claim_binding=True,
        )
        replay_relative = replay_bundle.relative_to(workspace.root).as_posix()
        replay_sha256 = hashlib.sha256((replay_bundle / "manifest.json").read_bytes()).hexdigest()
        entries.append(
            {
                "type": "replay",
                "path": replay_relative,
                "sha256": replay_sha256,
                "verified": True,
            }
        )
    if demo:
        entries.append({"type": "demo", "path": relative, "sha256": sha256, "verified": True})
    report = workspace.root / "evidence-reports" / f"{feature_id.lower()}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text('{"passed":true}\n', encoding="utf-8")
    report_relative = report.relative_to(workspace.root).as_posix()
    report_sha256 = hashlib.sha256(report.read_bytes()).hexdigest()
    value = {
        "schema_version": "worldeval/feature-evidence/1.0.0",
        "feature_id": feature_id,
        "criteria": {f"{feature_id}-AC-01": entries},
        "tests": [
            {
                "command": "pytest -q",
                "exit_code": 0,
                "timestamp": "2026-07-23T00:00:00Z",
                "report_path": report_relative,
                "report_sha256": report_sha256,
            }
        ],
        "replays": (
            [{"path": replay_relative, "sha256": replay_sha256, "verified": True}]
            if replay
            else []
        ),
        "checks": {
            name: {
                "passed": True,
                "checked_at": "2026-07-23T00:00:00Z",
                "evidence": "verified in isolated test repository",
            }
            for name in ("privacy", "secrets", "migration", "compatibility")
        },
        "human_approvals": [
            {
                "type": approval_type,
                "approved": True,
                "by": "human-reviewer",
                "at": "2026-07-23T00:00:00Z",
                "notes": "accepted",
            }
            for approval_type in approval_types
        ],
    }
    (record.path / "evidence" / "manifest.json").write_text(
        json.dumps(value, indent=2) + "\n", encoding="utf-8"
    )


def test_directory_is_the_only_lifecycle_authority(tmp_path: Path) -> None:
    workspace = _repository(tmp_path)
    record = _create(workspace, "WEV-1000")

    assert record.state == "backlog"
    assert "status" not in record.metadata
    assert workspace.validate() == []

    claimed = workspace.claim("WEV-1000", owner="agent-one")

    assert claimed.state == "in-progress"
    assert not record.path.exists()
    assert claimed.path.exists()
    assert claimed.claim["branch"] == "codex/wev-1000-feature-wev-1000"
    assert claimed.claim["expires_at"]
    assert not (workspace.lock_directory / "workspace.lock").exists()


def test_validate_reports_a_manually_malformed_lifecycle_directory(tmp_path: Path) -> None:
    workspace = _repository(tmp_path)
    malformed = workspace.features_root / "backlog" / "manually-moved-directory"
    malformed.mkdir()

    issues = workspace.validate()

    assert any(issue.code == "missing-feature-json" for issue in issues)
    with pytest.raises(FeatureWorkflowError, match="does not contain feature.json"):
        workspace.list_features()


def test_claim_requires_dependencies_and_rejects_path_and_surface_collisions(
    tmp_path: Path,
) -> None:
    workspace = _repository(tmp_path)
    _create(workspace, "WEV-1001", affected_paths=("src/shared",), shared_surfaces=("api",))
    _create(
        workspace,
        "WEV-1002",
        affected_paths=("src/shared/child",),
        shared_surfaces=("different",),
    )
    _create(
        workspace,
        "WEV-1003",
        affected_paths=("src/independent",),
        shared_surfaces=("api",),
    )
    _create(workspace, "WEV-1004", dependencies=("WEV-1001",))

    with pytest.raises(FeatureWorkflowError, match="implemented dependency"):
        workspace.claim("WEV-1004", owner="agent-four")

    workspace.claim("WEV-1001", owner="agent-one")
    with pytest.raises(FeatureWorkflowError, match="overlaps"):
        workspace.claim("WEV-1002", owner="agent-two")
    with pytest.raises(FeatureWorkflowError, match="shared surface collision"):
        workspace.claim("WEV-1003", owner="agent-three")


def test_block_renew_and_release_preserve_progress_and_claim_history(tmp_path: Path) -> None:
    workspace = _repository(tmp_path)
    _create(workspace, "WEV-1010")
    workspace.claim("WEV-1010", owner="agent")

    blocked = workspace.block(
        "WEV-1010",
        actor="agent",
        reason="waiting for an external fixture",
        next_action="rerun conformance after the fixture lands",
    )
    assert blocked.claim["work_state"] == "blocked"
    assert blocked.claim["blockers"][0]["resolved_at"] is None

    renewed = workspace.renew("WEV-1010", actor="agent", lease_hours=48)
    assert renewed.claim["work_state"] == "blocked"

    released = workspace.release("WEV-1010", actor="agent", reason="dependency changed")
    assert released.state == "backlog"
    assert not (released.path / "claim.json").exists()
    assert list((released.path / "decisions").glob("lifecycle-release-*.claim.json"))
    progress = (released.path / "progress.md").read_text(encoding="utf-8")
    assert "waiting for an external fixture" in progress
    assert "dependency changed" in progress


def test_reclaim_requires_expiry_and_records_the_inspected_revision(tmp_path: Path) -> None:
    clock = [datetime(2026, 7, 23, tzinfo=timezone.utc)]
    workspace = _repository(tmp_path, now=lambda: clock[0])
    _create(workspace, "WEV-1020")
    workspace.claim("WEV-1020", owner="original", lease_hours=24)

    with pytest.raises(FeatureWorkflowError, match="has not expired"):
        workspace.reclaim("WEV-1020", owner="replacement", inspected_revision="abc123")

    clock[0] += timedelta(hours=25)
    warnings = workspace.validate("WEV-1020")
    assert any(issue.code == "expired-claim" and issue.level == "warning" for issue in warnings)
    reclaimed = workspace.reclaim(
        "WEV-1020",
        owner="replacement",
        inspected_revision="preserved-revision-123",
    )

    assert reclaimed.claim["owner"] == "replacement"
    assert reclaimed.claim["reclaim_history"][0]["previous_owner"] == "original"
    assert reclaimed.claim["reclaim_history"][0]["inspected_revision"] == "preserved-revision-123"


def test_ready_can_resolve_recorded_blockers_after_evidence_is_committed(tmp_path: Path) -> None:
    workspace = _repository(tmp_path)
    _create(workspace, "WEV-1025")
    claim = workspace.claim("WEV-1025", owner="agent")
    _git(workspace.root, "switch", "-q", "-c", claim.claim["branch"])
    workspace.block(
        "WEV-1025",
        actor="agent",
        reason="temporary fixture gap",
        next_action="add and verify fixture",
    )
    artifact = workspace.root / "src" / "wev-1025" / "result.txt"
    artifact.parent.mkdir(parents=True)
    artifact.write_text("verified\n", encoding="utf-8")
    _evidence(workspace, "WEV-1025", artifact)
    _git(workspace.root, "add", ".")
    _git(workspace.root, "commit", "-qm", "implement WEV-1025")

    ready = workspace.ready("WEV-1025", actor="agent", resolve_blockers=True)

    assert ready.claim["work_state"] == "ready"
    assert ready.claim["ready_at"]
    assert all(blocker["resolved_at"] for blocker in ready.claim["blockers"])

    completed = workspace.complete("WEV-1025", actor="agent")
    assert completed.state == "implemented"


def test_completion_fails_closed_then_creates_a_separate_lifecycle_receipt(
    tmp_path: Path,
) -> None:
    workspace = _repository(tmp_path)
    _create(
        workspace,
        "WEV-1030",
        kind="visual",
        required_approvals=("visual",),
        acceptance_criteria=_criterion("WEV-1030", replay=True, demo=True),
    )
    claim = workspace.claim("WEV-1030", owner="agent")
    _git(workspace.root, "switch", "-q", "-c", claim.claim["branch"])

    with pytest.raises(FeatureWorkflowError, match="no evidence"):
        workspace.complete("WEV-1030", actor="agent")

    artifact = workspace.root / "src" / "wev-1030" / "accepted.replay.json"
    artifact.parent.mkdir(parents=True)
    artifact.write_text('{"terminal":true}\n', encoding="utf-8")
    _evidence(
        workspace,
        "WEV-1030",
        artifact,
        replay=True,
        demo=True,
        approval_types=("behavioral", "visual"),
    )
    _git(workspace.root, "add", ".")
    _git(workspace.root, "commit", "-qm", "implement WEV-1030")

    completed = workspace.complete("WEV-1030", actor="agent")

    assert completed.state == "implemented"
    assert not (completed.path / "claim.json").exists()
    completion = json.loads((completed.path / "completion.json").read_text(encoding="utf-8"))
    assert completion["feature_id"] == "WEV-1030"
    assert completion["verified_replay_count"] == 1
    assert completion["implementation_revision"] != completion["base_revision"]
    assert list((completed.path / "decisions").glob("lifecycle-complete-*.claim.json"))


def test_completion_rejects_uncommitted_implementation(tmp_path: Path) -> None:
    workspace = _repository(tmp_path)
    _create(workspace, "WEV-1040")
    workspace.claim("WEV-1040", owner="agent")
    artifact = workspace.root / "src" / "wev-1040" / "result.txt"
    artifact.parent.mkdir(parents=True)
    artifact.write_text("done\n", encoding="utf-8")
    _evidence(workspace, "WEV-1040", artifact)

    with pytest.raises(FeatureWorkflowError, match="committed"):
        workspace.complete("WEV-1040", actor="agent")


def test_doctor_finishes_an_interrupted_atomic_claim_without_deleting_work(
    tmp_path: Path,
) -> None:
    workspace = _repository(tmp_path)
    created = _create(workspace, "WEV-1050")
    sentinel = created.path / "progress.md"
    original_progress = sentinel.read_text(encoding="utf-8")

    with patch("worldeval.features.workflow.os.rename", side_effect=OSError("interrupted")):
        with pytest.raises(OSError, match="interrupted"):
            workspace.claim("WEV-1050", owner="agent")

    assert (created.path / ".lifecycle-transaction.json").exists()
    assert (created.path / "claim.json").exists()
    report = workspace.doctor(repair=True)
    repaired = workspace.get("WEV-1050", state="in-progress")

    assert any(item["code"] == "completed-transition" for item in report["repaired"])
    assert not (repaired.path / ".lifecycle-transaction.json").exists()
    assert (repaired.path / "progress.md").read_text(encoding="utf-8") == original_progress
    assert workspace.validate("WEV-1050") == []


def test_checkout_lock_rejects_concurrent_lifecycle_mutation(tmp_path: Path) -> None:
    workspace = _repository(tmp_path)
    _create(workspace, "WEV-1060")
    workspace.lock_directory.mkdir(parents=True, exist_ok=True)
    lock_path = workspace.lock_directory / "workspace.lock"
    lock_path.write_text(
        json.dumps(
            {
                "token": "another-operation",
                "pid": os.getpid(),
                "host": socket.gethostname(),
                "acquired_at": "2026-07-23T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(FeatureWorkflowError, match="is locked"):
        workspace.claim("WEV-1060", owner="agent")
    report = workspace.doctor()
    assert any(issue["code"] == "active-lock" for issue in report["issues"])


def test_cli_new_list_validate_and_claim(tmp_path: Path, capsys) -> None:
    workspace = _repository(tmp_path)
    root = workspace.root

    assert (
        feature_main(
            [
                "--root",
                str(root),
                "new",
                "WEV-1070",
                "--title",
                "CLI lifecycle",
                "--summary",
                "Exercise the public argparse interface.",
                "--affected-path",
                "src/cli",
            ]
        )
        == 0
    )
    assert feature_main(["--root", str(root), "validate", "WEV-1070"]) == 0
    assert feature_main(["--root", str(root), "claim", "WEV-1070", "--owner", "cli-agent"]) == 0
    assert feature_main(["--root", str(root), "list", "--json"]) == 0
    output = capsys.readouterr().out
    assert "WEV-1070" in output
    assert "in-progress" in output
