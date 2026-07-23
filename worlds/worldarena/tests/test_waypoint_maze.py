from __future__ import annotations

import json
from pathlib import Path

import pytest
from worldarena.paths import WORLDARENA_GAMES_ROOT, WORLDARENA_GODOT_ROOT
from worldarena.replay_verifiers import default_godot_executable
from worldarena.waypoint_maze import (
    GodotWaypointMazeRunner,
    WaypointMazeService,
    load_configuration,
)
from worldarena.waypoint_maze.godot import (
    NATIVE_SCHEMA,
    NATIVE_VERIFIER,
    WaypointMazeAuthorityError,
    native_replay_verifier,
    network_isolation_available,
)
from worldeval.contracts import (
    AgentProtocolValidator,
    canonical_json_bytes,
    strict_json_loads,
)
from worldeval.replay import load_incomplete_run, verify_replay_bundle

GODOT = default_godot_executable()
MAZE_ROOT = WORLDARENA_GAMES_ROOT / "waypoint-maze"
SHARED_SKILL = (
    WORLDARENA_GAMES_ROOT
    / "shared"
    / "skills"
    / "navigation.follow-visible-waypoints-v1.json"
)


def _read(path: Path) -> object:
    return strict_json_loads(path.read_bytes())


def test_second_game_adopts_locked_contract_and_portable_visible_skill() -> None:
    validator = AgentProtocolValidator()
    lock = json.loads(
        (Path(validator.root) / "protocol-lock.json").read_text(encoding="utf-8")
    )
    assert validator.package_sha256 == lock["package_sha256"]
    for relative, schema in (
        ("environment-manifest.json", "environment-manifest.v1.schema.json"),
        ("catalogs/object-catalog.json", "object-catalog.v1.schema.json"),
        ("catalogs/action-catalog.json", "action-catalog.v1.schema.json"),
        (
            "decision-profiles/static-event-gated-v1.json",
            "decision-profile.v1.schema.json",
        ),
        ("objectives/beacon-route-v0.json", "objective.v1.schema.json"),
        ("examples/beacon-route-plan.json", "action-plan.v1.schema.json"),
    ):
        validator.validate(schema, _read(MAZE_ROOT / relative))
    skill = validator.validate(
        "skill-manifest.v1.schema.json",
        _read(SHARED_SKILL),
    )
    maze_actions = _read(MAZE_ROOT / "catalogs" / "action-catalog.json")
    primitive_actions = _read(
        WORLDARENA_GAMES_ROOT
        / "primitive-sandbox"
        / "catalogs"
        / "action-catalog.json"
    )
    assert skill.execution == "agent_expands_to_visible_actions"
    assert skill.compatible_action_profiles == ["semantic-grid-actions-v1"]
    assert maze_actions["action_profile"] in skill.compatible_action_profiles
    assert primitive_actions["action_profile"] in skill.compatible_action_profiles
    for catalog in (maze_actions, primitive_actions):
        action_ids = {action["action_id"] for action in catalog["actions"]}
        assert set(skill.suggested_actions).issubset(action_ids)
        assert "execute_skill" not in action_ids
    for game_root in (
        MAZE_ROOT,
        WORLDARENA_GAMES_ROOT / "primitive-sandbox",
    ):
        object_catalog = _read(game_root / "catalogs" / "object-catalog.json")
        assert any(
            set(skill.required_target_affordances).issubset(
                object_type["affordances"]
            )
            for object_type in object_catalog["object_types"]
        )


def test_waypoint_initialization_uses_static_profile_and_visible_inputs() -> None:
    configuration = load_configuration()
    initialization = configuration.initialization
    assert initialization.protocol == "worldeval-agent/0.1.0"
    assert initialization.game_id == "worldarena-waypoint-maze-v0"
    assert initialization.profiles.decision == "static-event-gated-v1"
    assert initialization.decision_profile.kind == "static-event-gated"
    assert initialization.decision_profile.maximum_ticks == 50
    assert initialization.initialization_hash.startswith("sha256:")
    assert configuration.skill.execution == "agent_expands_to_visible_actions"
    assert configuration.action_catalog.action_profile == "semantic-grid-actions-v1"


def test_waypoint_native_verifier_rejects_unanchored_initialization_hash() -> None:
    replay_path = (
        WORLDARENA_GODOT_ROOT.parent
        / "demos"
        / "waypoint-maze-beacon-route"
        / "1.0.0"
        / "replays"
        / "primary.replay.json"
    )
    replay = dict(_read(replay_path))
    replay["initialization_hash"] = f"sha256:{'f' * 64}"

    with pytest.raises(
        WaypointMazeAuthorityError,
        match="initialization hash differs from authored inputs",
    ):
        native_replay_verifier(
            canonical_json_bytes(replay),
            {
                "native_schema": NATIVE_SCHEMA,
                "verifier": NATIVE_VERIFIER,
            },
            executable=GODOT,
            project_path=WORLDARENA_GODOT_ROOT,
        )


def test_waypoint_preterminal_failure_persists_sealed_incomplete_run(
    tmp_path: Path,
) -> None:
    class FailingRunner:
        def run(self, _scenario_id: str, *, run_id: str) -> None:
            raise WaypointMazeAuthorityError(
                f"simulated preterminal failure for {run_id}"
            )

    service = WaypointMazeService(
        runner=FailingRunner(),  # type: ignore[arg-type]
        replay_root=tmp_path,
    )
    with pytest.raises(
        WaypointMazeAuthorityError,
        match="simulated preterminal failure",
    ):
        service.run("beacon-route-v0", run_id="waypoint-incomplete")

    record = tmp_path / "waypoint-incomplete"
    assert not (record / "manifest.json").exists()
    diagnostic = load_incomplete_run(record)
    assert diagnostic["phase"] == "authority_execution"
    assert diagnostic["recoverable"] is False
    assert diagnostic["details"] == {
        "authority": "godot",
        "failure_type": "WaypointMazeAuthorityError",
        "game_id": "worldarena-waypoint-maze-v0",
        "replay_saved": False,
        "scenario_id": "beacon-route-v0",
        "terminal_boundary_reached": False,
    }


@pytest.mark.skipif(not GODOT.is_file(), reason="Godot 4.5 is unavailable")
def test_godot_waypoint_replay_is_deterministic_sparse_and_independent(
    tmp_path: Path,
) -> None:
    runner = GodotWaypointMazeRunner(
        executable=GODOT,
        project_path=WORLDARENA_GODOT_ROOT,
        require_network_isolation=network_isolation_available(),
    )
    first = runner.run(
        "beacon-route-v0",
        run_id="waypoint-maze-determinism",
    )
    second = runner.run(
        "beacon-route-v0",
        run_id="waypoint-maze-determinism",
    )
    assert first.replay == second.replay
    replay = first.replay
    assert replay["terminal_outcome"] == "route_complete"
    assert replay["terminal_tick"] == 23
    assert len(replay["decisions"]) == 5
    assert replay["provider_calls"] == 0
    assert replay["authority_metrics"] == {
        "forbidden_autonomy_count": 0,
        "hostile_attacks": 0,
    }
    plans = [
        decision["plan"]
        for decision in replay["decisions"]
        if decision["type"] == "plan.replace"
    ]
    assert len(plans) == 1
    assert [step["action"]["action"] for step in plans[0]["steps"]] == [
        "move_to"
    ] * 5
    service = WaypointMazeService(runner=runner, replay_root=tmp_path)
    result = service.run(
        "beacon-route-v0",
        run_id="waypoint-maze-bundle-test",
    )
    verification = verify_replay_bundle(
        result.bundle_path,
        native_verifiers=runner.native_verifiers(),
        require_native_verification=True,
        require_provider_calls_zero=True,
        require_claim_binding=True,
    )
    assert (
        verification.independent_offline_verification["provider_calls"] == 0
    )
    assert result.evaluation["passed"] is True
    assert result.evaluation["route_order_correct"] is True
    assert result.evaluation["adaptation_success"] is True
    assert result.evaluation["route_efficiency_numerator"] == 23
    assert result.evaluation["route_efficiency_denominator"] == 23
    assert result.evaluation["opaque_skill_commands"] == 0
    assert result.evaluation["forbidden_autonomy_count"] == 0
    assert result.evaluation["model_calls"] == 5


@pytest.mark.skipif(not GODOT.is_file(), reason="Godot 4.5 is unavailable")
def test_promoted_waypoint_demo_is_restart_verifiable() -> None:
    bundle = (
        WORLDARENA_GODOT_ROOT.parent
        / "demos"
        / "waypoint-maze-beacon-route"
        / "1.0.0"
    )
    runner = GodotWaypointMazeRunner(
        executable=GODOT,
        project_path=WORLDARENA_GODOT_ROOT,
        require_network_isolation=network_isolation_available(),
    )
    report = verify_replay_bundle(
        bundle,
        native_verifiers=runner.native_verifiers(),
        require_native_verification=True,
        require_provider_calls_zero=True,
        require_claim_binding=True,
    )
    assert report.manifest["game"]["id"] == "worldarena-waypoint-maze-v0"
    assert report.manifest["protocol"]["version"] == "0.1.0"
    assert report.manifest["profiles"]["decision"] == "static-event-gated-v1"
