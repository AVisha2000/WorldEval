"""Replay-first service and authority-derived evaluation for Waypoint Maze."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from worldeval.contracts import (
    ActionPlan,
    ActionReceipt,
    AgentProtocolValidator,
    Observation,
)
from worldeval.evaluation import (
    PortableSkillEvaluationInput,
    evaluate_portable_skill,
)
from worldeval.replay import (
    PUBLIC,
    ArtifactInput,
    BundleExistsError,
    verify_replay_bundle,
    write_incomplete_run,
    write_terminal_demo_bundle,
)

from .configuration import WaypointMazeConfiguration
from .godot import (
    NATIVE_SCHEMA,
    NATIVE_VERIFIER,
    GodotWaypointMazeResult,
    GodotWaypointMazeRunner,
)


@dataclass(frozen=True)
class WaypointMazeRun:
    run_id: str
    bundle_path: Path
    evaluation: Mapping[str, Any]
    replay: Mapping[str, Any]


class WaypointMazeService:
    def __init__(
        self,
        *,
        runner: GodotWaypointMazeRunner,
        replay_root: Path,
    ) -> None:
        self.runner = runner
        self.replay_root = Path(replay_root).resolve()
        self.protocol = AgentProtocolValidator()

    def run(
        self,
        scenario_id: str,
        *,
        run_id: str,
        replay_root: Path | None = None,
    ) -> WaypointMazeRun:
        destination = Path(replay_root or self.replay_root).resolve()
        try:
            authority = self.runner.run(scenario_id, run_id=run_id)
        except Exception as error:
            self._write_incomplete(
                destination,
                run_id=run_id,
                scenario_id=scenario_id,
                phase="authority_execution",
                error=error,
                terminal_boundary_reached=False,
            )
            raise
        replay = dict(authority.replay)
        try:
            evaluation = _evaluation(authority)
            timeline = _timeline(replay)
        except Exception as error:
            self._write_incomplete(
                destination,
                run_id=run_id,
                scenario_id=scenario_id,
                phase="evaluation",
                error=error,
                terminal_boundary_reached=True,
                last_tick=int(replay["terminal_tick"]),
            )
            raise
        result = {
            "schema_version": "waypoint-maze-result.v1",
            "run_id": run_id,
            "scenario_id": scenario_id,
            "outcome": replay["terminal_outcome"],
            "terminal_tick": replay["terminal_tick"],
            "terminal_state_hash": replay["terminal_state_hash"],
            "passed": evaluation["passed"],
            "authority": "godot",
        }
        configuration = authority.configuration
        metadata = {
            "run_id": run_id,
            "game": {"id": "worldarena-waypoint-maze-v0"},
            "scenario": {"id": scenario_id},
            "task": {"id": configuration.objective.objective_id},
            "subject": {"kind": "agent", "id": "navigator-1"},
            "protocol": {
                "id": "worldeval-agent",
                "version": "0.1.0",
                "package_hash": self.protocol.package_sha256,
            },
            "engine": {
                "id": "godot",
                "build_hash": authority.engine_build_hash,
            },
            "seed": 0,
            "profiles": {
                "action": configuration.action_catalog.action_profile,
                "observation": "semantic-grid-visible-v1",
                "decision": configuration.decision_profile.profile_id,
            },
            "terminal": {
                "outcome": replay["terminal_outcome"],
                "reason": "authority_terminal_state",
                "tick_count": replay["terminal_tick"],
            },
            "offline_verification": {
                "verified": True,
                "provider_calls": 0,
                "verifier": NATIVE_VERIFIER,
            },
        }
        artifacts = (
            ArtifactInput.json(
                path="replays/primary.replay.json",
                role="primary",
                kind="replay",
                value=replay,
                visibility=PUBLIC,
                native_schema=NATIVE_SCHEMA,
                verifier=NATIVE_VERIFIER,
                final_state_hash=replay["terminal_state_hash"],
                participants=("navigator-1",),
            ),
            ArtifactInput.json(
                path="evidence/environment-init.json",
                role="environment_init",
                kind="evidence",
                value=configuration.initialization.model_dump(mode="json"),
                visibility=PUBLIC,
            ),
            ArtifactInput.json(
                path="evidence/objective.json",
                role="objective",
                kind="evidence",
                value=configuration.objective.model_dump(mode="json"),
                visibility=PUBLIC,
            ),
            ArtifactInput.json(
                path="evidence/skill-manifest.json",
                role="skill_manifest",
                kind="evidence",
                value=configuration.skill.model_dump(mode="json"),
                visibility=PUBLIC,
            ),
            ArtifactInput.json(
                path="evidence/skill-expansion.json",
                role="skill_expansion",
                kind="evidence",
                value=authority.skill_expansion,
                visibility=PUBLIC,
            ),
            ArtifactInput.json(
                path="evidence/evaluation.json",
                role="evaluation",
                kind="evidence",
                value=evaluation,
                visibility=PUBLIC,
            ),
            ArtifactInput.json(
                path="evidence/timeline.json",
                role="timeline",
                kind="evidence",
                value=timeline,
                visibility=PUBLIC,
            ),
            ArtifactInput.json(
                path="evidence/result.json",
                role="result",
                kind="evidence",
                value=result,
                visibility=PUBLIC,
            ),
        )
        verifiers = self.runner.native_verifiers()
        try:
            bundle = write_terminal_demo_bundle(
                destination,
                metadata=metadata,
                artifacts=artifacts,
                native_verifiers=verifiers,
                require_claim_binding=True,
            )
            verify_replay_bundle(
                bundle,
                native_verifiers=verifiers,
                require_native_verification=True,
                require_provider_calls_zero=True,
                require_claim_binding=True,
            )
        except Exception as error:
            self._write_incomplete(
                destination,
                run_id=run_id,
                scenario_id=scenario_id,
                phase="replay_seal",
                error=error,
                terminal_boundary_reached=True,
                last_tick=int(replay["terminal_tick"]),
            )
            raise
        return WaypointMazeRun(
            run_id=run_id,
            bundle_path=bundle,
            evaluation=evaluation,
            replay=replay,
        )

    @staticmethod
    def _write_incomplete(
        root: Path,
        *,
        run_id: str,
        scenario_id: str,
        phase: str,
        error: BaseException,
        terminal_boundary_reached: bool,
        last_tick: int | None = None,
    ) -> Path | None:
        try:
            return write_incomplete_run(
                root,
                run_id=run_id,
                phase=phase,
                reason="authority did not produce a durable verified replay",
                recoverable=terminal_boundary_reached,
                last_tick=last_tick,
                details={
                    "authority": "godot",
                    "failure_type": type(error).__name__,
                    "game_id": "worldarena-waypoint-maze-v0",
                    "replay_saved": False,
                    "scenario_id": scenario_id,
                    "terminal_boundary_reached": terminal_boundary_reached,
                },
            )
        except BundleExistsError:
            return None


def _evaluation(authority: GodotWaypointMazeResult) -> Mapping[str, Any]:
    return evaluate_waypoint_maze_replay(
        authority.configuration,
        authority.replay,
        authority.skill_expansion,
    )


def expected_skill_expansion(
    configuration: WaypointMazeConfiguration,
    replay: Mapping[str, Any],
) -> Mapping[str, Any]:
    """Derive the visible skill expansion evidence from the recorded plan."""

    plan_decisions = [
        decision
        for decision in replay["decisions"]
        if isinstance(decision, dict) and decision["type"] == "plan.replace"
    ]
    if len(plan_decisions) != 1:
        raise ValueError(
            "Waypoint Maze replay must contain exactly one expanded plan"
        )
    plan = ActionPlan.model_validate(plan_decisions[0]["plan"])
    plan_value = plan.model_dump(mode="json")
    return {
        "schema_version": "skill-expansion-evidence.v1",
        "skill_id": configuration.skill.skill_id,
        "execution": configuration.skill.execution,
        "source_observation_seq": plan.source.observation_seq,
        "source_state_hash": plan.source.state_hash,
        "expanded_plan_id": plan.plan_id,
        "expanded_steps": plan_value["steps"],
        "decision_calls": len(replay["decisions"]),
    }


def evaluate_waypoint_maze_replay(
    configuration: WaypointMazeConfiguration,
    replay: Mapping[str, Any],
    expansion: Mapping[str, Any] | None = None,
) -> Mapping[str, Any]:
    """Recompute the complete evaluation from authored and authority evidence."""

    selected_expansion = (
        expected_skill_expansion(configuration, replay)
        if expansion is None
        else expansion
    )
    scenario = configuration.scenario
    receipts = [
        ActionReceipt.model_validate(receipt) for receipt in replay["receipts"]
    ]
    observations = [
        Observation.model_validate(observation)
        for observation in replay["observations"]
    ]
    waypoint_events = [
        event
        for observation in observations
        for event in observation.events
        if event.kind == "waypoint_reached"
    ]
    visited_route = [event.object_id for event in waypoint_events]
    expected_route = list(scenario["route"])
    moved_cells = sum(
        1
        for receipt in receipts
        for effect in receipt.effects
        if effect.kind == "agent_moved"
    )
    plan_decisions = [
        decision
        for decision in replay["decisions"]
        if isinstance(decision, dict) and decision["type"] == "plan.replace"
    ]
    if len(plan_decisions) != 1:
        raise ValueError(
            "Waypoint Maze replay must contain exactly one expanded plan"
        )
    expanded_plan = ActionPlan.model_validate(plan_decisions[0]["plan"])
    generic = evaluate_portable_skill(
        PortableSkillEvaluationInput(
            objective_id=configuration.objective.objective_id,
            expected_outcome="route_complete",
            terminal_outcome=str(replay["terminal_outcome"]),
            skill=configuration.skill,
            action_profile=configuration.action_catalog.action_profile,
            action_catalog_ids=[
                action.action_id
                for action in configuration.action_catalog.actions
            ],
            expanded_plan=expanded_plan,
            receipts=receipts,
            observations=observations,
            material_event_kinds=["waypoint_reached"],
            optimal_path_distance=int(scenario["optimal_route_distance"]),
            path_distance=moved_cells,
            forbidden_autonomy_count=int(
                replay["authority_metrics"]["forbidden_autonomy_count"]
            ),
            replay_saved=True,
            replay_offline_verified=bool(replay["offline_verified"]),
        )
    )
    expansion_evidence_matches_plan = (
        selected_expansion.get("execution") == generic.skill_execution
        and selected_expansion.get("skill_id") == generic.skill_id
        and selected_expansion.get("expanded_plan_id") == expanded_plan.plan_id
        and selected_expansion.get("expanded_steps")
        == expanded_plan.model_dump(mode="json")["steps"]
    )
    metrics = replay["authority_metrics"]
    passed = (
        generic.passed
        and visited_route == expected_route
        and expansion_evidence_matches_plan
    )
    return {
        **generic.model_dump(mode="json"),
        "passed": passed,
        "terminal_tick": replay["terminal_tick"],
        "event_gate_count": len(waypoint_events),
        "event_gate_adaptations": generic.successful_adaptations,
        "expansion_evidence_matches_plan": expansion_evidence_matches_plan,
        "visited_route": visited_route,
        "expected_route": expected_route,
        "route_order_correct": visited_route == expected_route,
        "optimal_route_distance": scenario["optimal_route_distance"],
        "route_efficiency_numerator": scenario["optimal_route_distance"],
        "route_efficiency_denominator": moved_cells,
        "simulated_ticks_per_call_numerator": replay["terminal_tick"],
        "simulated_ticks_per_call_denominator": len(receipts),
        "hostile_attacks": metrics["hostile_attacks"],
    }


def _timeline(replay: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    rows: list[Mapping[str, Any]] = []
    for index, receipt in enumerate(replay["receipts"]):
        observation = replay["observations"][index + 1]
        rows.append(
            {
                "boundary": index + 1,
                "response_type": receipt["response_type"],
                "step_id": receipt["step_id"],
                "start_tick": receipt["start_tick"],
                "end_tick": receipt["end_tick"],
                "applied_ticks": receipt["applied_ticks"],
                "accepted": receipt["accepted"],
                "codes": receipt["codes"],
                "events": [
                    {
                        "kind": event["kind"],
                        "object_id": event["object_id"],
                    }
                    for event in observation["events"]
                ],
            }
        )
    return rows


__all__ = [
    "WaypointMazeRun",
    "WaypointMazeService",
    "evaluate_waypoint_maze_replay",
    "expected_skill_expansion",
]
