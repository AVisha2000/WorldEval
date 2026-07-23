from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from genesis_arena.arena.simulation_jobs import (
    LaunchResult,
    SimulationJobManager,
    SimulationRequest,
)
from genesis_arena.config import Settings
from genesis_arena.main import app
from pydantic import ValidationError


def _bundle(run_id: str) -> dict[str, object]:
    return {
        "protocol": "world-arena-replay/1",
        "run_id": run_id,
        "created_at": "2026-07-19T12:00:00Z",
        "source": "godot-headless",
        "seed": 7,
        "policy": "deterministic_demo",
        "max_rounds": 24,
        "completed_rounds": 1,
        "simulated_seconds": 2.5,
        "runtime_seconds": 0.1,
        "duration_seconds": 2.5,
        "initial_snapshot": {"round": 0},
        "frames": [
            {
                "index": 0,
                "round": 1,
                "at_seconds": 2.5,
                "snapshot": {"round": 1},
                "events": [],
            }
        ],
        "result": {"winner": "sol"},
    }


def _settings(tmp_path: Path) -> Settings:
    executable = tmp_path / "godot"
    executable.touch()
    project = tmp_path / "project"
    runner = project / "scripts/arena/simulation/arena_batch_runner.gd"
    runner.parent.mkdir(parents=True)
    runner.touch()
    return Settings(
        runs_dir=tmp_path / "runs", godot_executable=executable, godot_project_path=project
    )


async def _wait(manager: SimulationJobManager, job_id: str):
    for _ in range(40):
        job = manager.get(job_id)
        assert job is not None
        if job.state in {"completed", "failed"}:
            return job
        await asyncio.sleep(0.01)
    raise AssertionError("simulation job did not finish")


def test_simulation_request_parses_safe_decimal_seed_only() -> None:
    numeric = SimulationRequest.model_validate({"seed": "0007"})
    assert numeric.seed == "0007"
    assert numeric.numeric_seed == 7
    labelled = SimulationRequest.model_validate({"seed": "ARENA-2407"})
    assert (
        labelled.numeric_seed
        == SimulationRequest.model_validate({"seed": "ARENA-2407"}).numeric_seed
    )
    with pytest.raises(ValidationError):
        SimulationRequest.model_validate({"seed": "7; rm -rf /"})
    with pytest.raises(ValidationError):
        SimulationRequest.model_validate({"max_rounds": 201})


@pytest.mark.asyncio
async def test_job_lifecycle_indexes_completed_replay(tmp_path: Path) -> None:
    async def launcher(argv: list[str], _cwd: Path) -> LaunchResult:
        output = Path(argv[argv.index("--output") + 1])
        assert argv[argv.index("--run-id") + 1] == output.parent.name
        output.write_text(json.dumps(_bundle(output.parent.name)), encoding="utf-8")
        return LaunchResult(returncode=0, stdout="ok")

    manager = SimulationJobManager(_settings(tmp_path), launcher=launcher)
    queued = manager.create(SimulationRequest(seed="7"))
    assert queued.state == "queued"
    completed = await _wait(manager, queued.job_id)
    assert completed.state == "completed"
    assert completed.replay_id == queued.job_id
    assert manager.list_replays(10)[0].replay_id == queued.job_id
    bundle = manager.get_replay(queued.job_id, full=True)
    assert bundle is not None and bundle.frame_count == 1


@pytest.mark.asyncio
async def test_missing_executable_becomes_failed_job(tmp_path: Path) -> None:
    settings = _settings(tmp_path)
    settings.godot_executable = tmp_path / "missing-godot"
    manager = SimulationJobManager(settings)
    queued = manager.create(SimulationRequest())
    failed = await _wait(manager, queued.job_id)
    assert failed.state == "failed"
    assert failed.error == "configured Godot executable was not found"


def test_replay_lookup_rejects_traversal_and_skips_invalid_bundle(tmp_path: Path) -> None:
    manager = SimulationJobManager(_settings(tmp_path))
    invalid = manager.simulations_dir / "sim-invalid" / "bundle.json"
    invalid.parent.mkdir(parents=True)
    invalid.write_text('{"protocol":"not-a-replay"}', encoding="utf-8")
    assert manager.list_replays(10) == []
    with pytest.raises(ValueError, match="unknown simulation"):
        manager.get_replay("../sim-invalid", full=False)


def test_cli_style_summary_without_replay_id_is_indexed(tmp_path: Path) -> None:
    manager = SimulationJobManager(_settings(tmp_path))
    replay_dir = manager.simulations_dir / "sim-cli-summary"
    replay_dir.mkdir(parents=True)
    summary = _bundle("sim-cli-summary")
    summary.pop("initial_snapshot")
    summary.pop("frames")
    summary["frame_count"] = 1
    (replay_dir / "summary.json").write_text(json.dumps(summary), encoding="utf-8")

    indexed = manager.list_replays(10)
    assert indexed[0].replay_id == "sim-cli-summary"
    assert indexed[0].duration_seconds == 2.5


def test_simulation_routes_validate_and_bound_lists() -> None:
    with TestClient(app) as client:
        assert client.get("/api/simulations?limit=101").status_code == 422
        invalid = client.post("/api/simulations", json={"policy": "request_controlled_shell"})
        assert invalid.status_code == 422
        assert client.get("/api/replays/not-a-real-replay").status_code == 404
