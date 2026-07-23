"""Interactive and replay-first service for authoritative Primitive Sandbox runs."""

from __future__ import annotations

import re
import threading
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from worldeval.contracts import (
    ActionReceipt,
    AgentProtocolValidator,
    Observation,
    ProtocolSchemaError,
    canonical_json_bytes,
    strict_json_loads,
)
from worldeval.evaluation import EvaluationInput, evaluate_agent_episode
from worldeval.replay import (
    PUBLIC,
    ArtifactInput,
    BundleExistsError,
    resolve_artifact,
    verify_replay_bundle,
    write_incomplete_run,
    write_terminal_demo_bundle,
)

from ..replay_verifiers import (
    PRIMITIVE_SANDBOX_NATIVE_SCHEMA,
    PRIMITIVE_SANDBOX_NATIVE_VERIFIER,
    default_native_verifiers,
)
from .configuration import PrimitiveSandboxConfiguration
from .demo import PrimitiveSandboxDemoAgent
from .godot import (
    GodotPrimitiveSandboxRunner,
    GodotSandboxResult,
    GodotSandboxSnapshot,
)

NATIVE_SCHEMA = PRIMITIVE_SANDBOX_NATIVE_SCHEMA
NATIVE_VERIFIER = PRIMITIVE_SANDBOX_NATIVE_VERIFIER


class PrimitiveSandboxServiceError(RuntimeError):
    """A sandbox run could not become a verified replay-first result."""


class PrimitiveSandboxSessionNotFound(PrimitiveSandboxServiceError):
    """The requested interactive session does not exist."""


class PrimitiveSandboxSessionConflict(PrimitiveSandboxServiceError):
    """The requested session transition is not currently legal."""


@dataclass(frozen=True)
class PrimitiveSandboxRun:
    run_id: str
    bundle_path: Path
    projection: Mapping[str, Any]


@dataclass(frozen=True)
class PrimitiveSandboxSession:
    session_id: str
    projection: Mapping[str, Any]


@dataclass
class _SessionState:
    session_id: str
    run_id: str
    scenario_id: str
    replay_root: Path
    configuration: PrimitiveSandboxConfiguration
    snapshot: GodotSandboxSnapshot
    acknowledged: bool
    history: list[Mapping[str, Any]]
    status: str
    ready_run: PrimitiveSandboxRun | None = None
    failure_code: str | None = None


_IDENTIFIER = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")


class PrimitiveSandboxService:
    def __init__(
        self,
        *,
        runner: GodotPrimitiveSandboxRunner,
        replay_root: Path,
    ) -> None:
        self.runner = runner
        self.replay_root = Path(replay_root).resolve()
        self._sessions: dict[str, _SessionState] = {}
        self._lock = threading.RLock()
        self._protocol = AgentProtocolValidator()

    def run(
        self,
        scenario_id: str,
        *,
        run_id: str | None = None,
        replay_root: Path | None = None,
    ) -> PrimitiveSandboxRun:
        selected_run_id = run_id or f"sandbox-{scenario_id}-{uuid.uuid4().hex[:12]}"
        session = self.create_session(
            scenario_id,
            run_id=selected_run_id,
            replay_root=replay_root,
        )
        session = self.acknowledge_session(
            session.session_id,
            str(session.projection["acknowledgement"]["initializationHash"]),
        )
        policy = PrimitiveSandboxDemoAgent()
        try:
            for _boundary in range(100):
                if session.projection["status"] == "ready":
                    with self._lock:
                        ready = self._sessions[session.session_id].ready_run
                    if ready is None:
                        raise PrimitiveSandboxServiceError(
                            "terminal sandbox session has no verified replay"
                        )
                    return ready
                decision = policy.decide(session.projection["observation"])
                session = self.submit_decision(
                    session.session_id,
                    decision=decision,
                    input_present=True,
                )
                if session.projection["status"] == "ready":
                    with self._lock:
                        ready = self._sessions[session.session_id].ready_run
                    if ready is None:
                        raise PrimitiveSandboxServiceError(
                            "terminal sandbox session has no verified replay"
                        )
                    return ready
        except PrimitiveSandboxServiceError:
            raise
        except Exception as error:
            self._fail_session(
                session.session_id,
                phase="demo_policy",
                error=error,
            )
            raise PrimitiveSandboxServiceError(
                "deterministic sandbox agent failed before a terminal boundary"
            ) from error
        self._fail_session(
            session.session_id,
            phase="decision_limit",
            error=RuntimeError("decision limit exceeded"),
        )
        raise PrimitiveSandboxServiceError(
            "deterministic sandbox agent exceeded its decision limit"
        )

    def create_session(
        self,
        scenario_id: str,
        *,
        session_id: str | None = None,
        run_id: str | None = None,
        replay_root: Path | None = None,
    ) -> PrimitiveSandboxSession:
        selected_session_id = session_id or f"sandbox-session-{uuid.uuid4().hex[:16]}"
        selected_run_id = run_id or f"sandbox-{scenario_id}-{uuid.uuid4().hex[:12]}"
        if not _IDENTIFIER.fullmatch(selected_session_id):
            raise ValueError("invalid Primitive Sandbox session ID")
        if not _IDENTIFIER.fullmatch(selected_run_id):
            raise ValueError("invalid Primitive Sandbox run ID")
        destination = Path(replay_root or self.replay_root).resolve()
        with self._lock:
            if selected_session_id in self._sessions:
                raise PrimitiveSandboxSessionConflict("sandbox session already exists")
            try:
                snapshot = self.runner.advance(
                    scenario_id,
                    run_id=selected_run_id,
                    history=(),
                )
            except Exception as error:
                _write_incomplete_run(
                    destination,
                    run_id=selected_run_id,
                    scenario_id=scenario_id,
                    phase="authority_initialization",
                    error=error,
                    last_tick=None,
                )
                raise PrimitiveSandboxServiceError(
                    "Godot could not initialize the sandbox session"
                ) from error
            state = _SessionState(
                session_id=selected_session_id,
                run_id=selected_run_id,
                scenario_id=scenario_id,
                replay_root=destination,
                configuration=snapshot.configuration,
                snapshot=snapshot,
                acknowledged=False,
                history=[],
                status="awaiting_acknowledgement",
            )
            self._sessions[selected_session_id] = state
            return PrimitiveSandboxSession(
                selected_session_id,
                self._session_projection(state),
            )

    def acknowledge_session(
        self,
        session_id: str,
        initialization_hash: str,
    ) -> PrimitiveSandboxSession:
        with self._lock:
            state = self._session_state(session_id)
            if state.status == "failed":
                raise PrimitiveSandboxSessionConflict("sandbox session has failed")
            expected = state.configuration.initialization.initialization_hash
            if initialization_hash != expected:
                raise PrimitiveSandboxSessionConflict(
                    "environment initialization hash acknowledgement differs"
                )
            state.acknowledged = True
            if state.status == "awaiting_acknowledgement":
                state.status = "decision_required"
            return PrimitiveSandboxSession(session_id, self._session_projection(state))

    def submit_decision(
        self,
        session_id: str,
        *,
        decision: Any = None,
        input_present: bool = True,
    ) -> PrimitiveSandboxSession:
        with self._lock:
            state = self._session_state(session_id)
            if not state.acknowledged:
                raise PrimitiveSandboxSessionConflict(
                    "environment initialization must be acknowledged first"
                )
            if state.status == "ready":
                raise PrimitiveSandboxSessionConflict("sandbox session is terminal")
            if state.status == "failed":
                raise PrimitiveSandboxSessionConflict("sandbox session has failed")
            entry = self._normalize_decision(
                decision,
                input_present=input_present,
            )
            history = [*state.history, entry]
            try:
                snapshot = self.runner.advance(
                    state.scenario_id,
                    run_id=state.run_id,
                    history=history,
                )
            except Exception as error:
                self._mark_failed(
                    state,
                    phase="authority_boundary",
                    error=error,
                )
                raise PrimitiveSandboxServiceError(
                    "Godot could not execute the sandbox decision boundary"
                ) from error
            state.snapshot = snapshot
            state.configuration = snapshot.configuration
            state.history = history
            if snapshot.terminal:
                authority = GodotSandboxResult(
                    configuration=snapshot.configuration,
                    replay=snapshot.replay,
                    stdout=snapshot.stdout,
                    engine_build_hash=snapshot.engine_build_hash,
                )
                try:
                    state.ready_run = self._seal_authority(
                        authority,
                        replay_root=state.replay_root,
                    )
                except Exception as error:
                    self._mark_failed(
                        state,
                        phase="replay_seal",
                        error=error,
                    )
                    raise
                state.status = "ready"
            else:
                state.status = "decision_required"
            return PrimitiveSandboxSession(session_id, self._session_projection(state))

    def get_session(self, session_id: str) -> PrimitiveSandboxSession:
        with self._lock:
            state = self._session_state(session_id)
            return PrimitiveSandboxSession(session_id, self._session_projection(state))

    def _seal_authority(
        self,
        authority: GodotSandboxResult,
        *,
        replay_root: Path,
    ) -> PrimitiveSandboxRun:
        selected_run_id = str(authority.replay["run_id"])
        scenario_id = str(authority.replay["scenario_id"])
        replay = dict(authority.replay)
        evaluation = _evaluation(authority)
        timeline = _timeline(replay)
        result = {
            "schema_version": "primitive-sandbox-result.v1",
            "run_id": selected_run_id,
            "scenario_id": scenario_id,
            "outcome": replay["terminal_outcome"],
            "terminal_tick": replay["terminal_tick"],
            "terminal_state_hash": replay["terminal_state_hash"],
            "passed": evaluation["passed"],
            "authority": "godot",
        }
        configuration = authority.configuration
        metadata = {
            "run_id": selected_run_id,
            "game": {"id": "worldarena-primitive-sandbox-v0"},
            "scenario": {"id": scenario_id},
            "task": {"id": configuration.objective.objective_id},
            "subject": {"kind": "agent", "id": "worker-1"},
            "protocol": {
                "id": "worldeval-agent",
                "version": "0.1.0",
                "package_hash": self._protocol.package_sha256,
            },
            "engine": {"id": "godot", "build_hash": authority.engine_build_hash},
            "seed": 0,
            "profiles": {
                "action": "semantic-grid-actions-v1",
                "observation": "semantic-grid-visible-v1",
                "decision": "dynamic-step-locked-v1",
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
                participants=("worker-1",),
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
        native_verifiers = default_native_verifiers(
            godot_executable=self.runner.executable,
            godot_project_path=self.runner.project_path,
            sandbox_root=configuration.root,
            timeout_seconds=self.runner.timeout_seconds,
            require_network_isolation=self.runner.require_network_isolation,
        )
        try:
            bundle = write_terminal_demo_bundle(
                replay_root,
                metadata=metadata,
                artifacts=artifacts,
                native_verifiers=native_verifiers,
                require_claim_binding=True,
            )
            verify_replay_bundle(
                bundle,
                native_verifiers=native_verifiers,
                require_native_verification=True,
                require_provider_calls_zero=True,
                require_claim_binding=True,
            )
        except Exception as error:
            raise PrimitiveSandboxServiceError(
                "sandbox replay could not be sealed and independently verified"
            ) from error
        projection = self._projection(
            bundle,
            initialization=configuration.initialization.model_dump(mode="json"),
            objective=configuration.objective.model_dump(mode="json"),
            replay=replay,
            evaluation=evaluation,
            timeline=timeline,
        )
        return PrimitiveSandboxRun(selected_run_id, bundle, projection)

    def _normalize_decision(
        self,
        decision: Any,
        *,
        input_present: bool,
    ) -> Mapping[str, Any]:
        if not input_present or decision is None:
            return {"decision": None, "no_input_reason": "missing"}
        try:
            value = self._protocol.validate(
                "decision-response.v1.schema.json",
                decision,
            )
        except (ProtocolSchemaError, TypeError, ValueError):
            return {"decision": None, "no_input_reason": "invalid"}
        normalized = value.model_dump(mode="json")
        try:
            canonical_json_bytes(normalized)
        except ValueError:
            return {"decision": None, "no_input_reason": "invalid"}
        return {
            "decision": normalized,
            "no_input_reason": None,
        }

    def _session_state(self, session_id: str) -> _SessionState:
        state = self._sessions.get(session_id)
        if state is None:
            raise PrimitiveSandboxSessionNotFound("sandbox session not found")
        return state

    def _session_projection(self, state: _SessionState) -> Mapping[str, Any]:
        initialization = state.configuration.initialization.model_dump(mode="json")
        replay = state.snapshot.replay
        value: dict[str, Any] = {
            "sessionId": state.session_id,
            "runId": state.run_id,
            "scenarioId": state.scenario_id,
            "status": state.status,
            "onboarding": initialization,
            "objective": state.configuration.objective.model_dump(mode="json"),
            "acknowledgement": {
                "required": True,
                "initializationHash": initialization["initialization_hash"],
                "acknowledged": state.acknowledged,
            },
            "observation": state.snapshot.observation,
            "receipt": state.snapshot.receipt,
            "decisionCount": len(state.history),
            "terminal": state.snapshot.terminal,
            "activeLease": {
                "minimumTicks": 1,
                "maximumTicks": 5,
                "defaultTicks": 3,
                "executionPolicy": "confirm_each_boundary",
                "simulatedTimePausedDuringInference": True,
            },
            "replay": {
                "status": "pending",
                "verified": False,
                "bundleUrl": None,
                "primaryUrl": None,
            },
        }
        if state.status == "ready":
            value["replay"] = {
                "status": "ready",
                "verified": True,
                "bundleUrl": f"/api/worldeval/replays/{state.run_id}",
                "primaryUrl": (
                    f"/api/worldeval/replays/{state.run_id}/files/primary"
                ),
            }
            if state.ready_run is not None:
                value["evaluation"] = state.ready_run.projection["evaluation"]
                value["timeline"] = state.ready_run.projection["timeline"]
        elif state.status == "failed":
            value["replay"] = {
                "status": "unavailable",
                "verified": False,
                "bundleUrl": None,
                "primaryUrl": None,
            }
            value["failure"] = {"code": state.failure_code}
        if replay.get("terminal_outcome") != "incomplete":
            value["outcome"] = replay["terminal_outcome"]
        return value

    def _mark_failed(
        self,
        state: _SessionState,
        *,
        phase: str,
        error: BaseException,
    ) -> None:
        state.status = "failed"
        state.failure_code = phase
        _write_incomplete_run(
            state.replay_root,
            run_id=state.run_id,
            scenario_id=state.scenario_id,
            phase=phase,
            error=error,
            terminal_boundary_reached=state.snapshot.terminal,
            last_tick=int(state.snapshot.observation["tick"]),
        )

    def _fail_session(
        self,
        session_id: str,
        *,
        phase: str,
        error: BaseException,
    ) -> None:
        with self._lock:
            state = self._session_state(session_id)
            self._mark_failed(state, phase=phase, error=error)

    def get(self, run_id: str) -> PrimitiveSandboxRun | None:
        bundle = self.replay_root / run_id
        if not bundle.is_dir():
            return None
        if (bundle / "incomplete-run.json").is_file():
            return None
        try:
            initialization = _artifact_json(bundle, "environment_init")
            objective = _artifact_json(bundle, "objective")
            replay = _artifact_json(bundle, "primary")
            evaluation = _artifact_json(bundle, "evaluation")
            timeline = _artifact_json(bundle, "timeline")
            native_verifiers = default_native_verifiers(
                godot_executable=self.runner.executable,
                godot_project_path=self.runner.project_path,
                sandbox_root=self.runner.sandbox_root,
                timeout_seconds=self.runner.timeout_seconds,
                require_network_isolation=self.runner.require_network_isolation,
            )
            verify_replay_bundle(
                bundle,
                native_verifiers=native_verifiers,
                require_native_verification=True,
                require_provider_calls_zero=True,
                require_claim_binding=True,
            )
            projection = self._projection(
                bundle,
                initialization=initialization,
                objective=objective,
                replay=replay,
                evaluation=evaluation,
                timeline=timeline,
            )
        except Exception as error:
            raise PrimitiveSandboxServiceError(
                "saved sandbox replay failed verification"
            ) from error
        return PrimitiveSandboxRun(run_id, bundle, projection)

    @staticmethod
    def _projection(
        bundle: Path,
        *,
        initialization: Mapping[str, Any],
        objective: Mapping[str, Any],
        replay: Mapping[str, Any],
        evaluation: Mapping[str, Any],
        timeline: list[Mapping[str, Any]],
    ) -> Mapping[str, Any]:
        final_observation = replay["observations"][-1]
        positions = {
            value["object_id"]: value["position"]
            for value in final_observation["visible_objects"]
        }
        initial_positions = {
            value["object_id"]: value["position"]
            for value in replay["observations"][0]["visible_objects"]
        }
        initial_plan = next(
            (
                decision["plan"]
                for decision in replay["decisions"]
                if isinstance(decision, dict) and decision.get("type") == "plan.replace"
            ),
            {},
        )
        run_id = str(replay["run_id"])
        return {
            "runId": run_id,
            "status": "ready",
            "scenarioId": replay["scenario_id"],
            "onboarding": initialization,
            "objective": objective,
            "grid": {
                "width": 30,
                "height": 25,
                "base": initial_positions["base-1"],
                "agent": final_observation["controlled_assets"][0]["position"],
                "tree": initial_positions["tree-7"],
                "barrier": positions.get("barrier-3"),
                "enemy": positions.get("enemy-1"),
            },
            "observationSeq": final_observation["observation_seq"],
            "tick": final_observation["tick"],
            "activeLease": {
                "maximumTicks": 3,
                "executionPolicy": "confirm_each_boundary",
                "simulatedTimePausedDuringInference": True,
            },
            "plan": initial_plan,
            "timeline": timeline,
            "evaluation": evaluation,
            "replay": {
                "verified": True,
                "bundleUrl": f"/api/worldeval/replays/{run_id}",
                "primaryUrl": f"/api/worldeval/replays/{run_id}/files/primary",
            },
        }


def _evaluation(authority: GodotSandboxResult) -> dict[str, Any]:
    return evaluate_primitive_sandbox_replay(
        authority.configuration,
        authority.replay,
    )


def evaluate_primitive_sandbox_replay(
    configuration: PrimitiveSandboxConfiguration,
    replay: Mapping[str, Any],
) -> dict[str, Any]:
    """Recompute the complete evaluation from authored inputs and replay evidence."""

    authority_metrics = replay["authority_metrics"]
    receipts = [ActionReceipt.model_validate(value) for value in replay["receipts"]]
    observations = [Observation.model_validate(value) for value in replay["observations"]]
    path_distance = sum(
        1
        for receipt in receipts
        for effect in receipt.effects
        if effect.kind == "agent_moved"
    )
    visible_ids = {item.object_id for item in observations[-1].visible_objects}
    evaluation = evaluate_agent_episode(
        EvaluationInput(
            objective_id=configuration.objective.objective_id,
            expected_outcome=configuration.scenario.expected_outcome,
            terminal_outcome=str(replay["terminal_outcome"]),
            terminal_tick=int(replay["terminal_tick"]),
            receipts=receipts,
            observations=observations,
            start_position=configuration.scenario.base_position,
            target_position=next(
                value.position
                for value in configuration.scenario.objects
                if value.object_id == "tree-7"
            ),
            path_distance=path_distance,
            forbidden_autonomy_count=int(
                authority_metrics["forbidden_autonomy_count"]
            ),
            hostile_attacks=int(authority_metrics["hostile_attacks"]),
            tree_exists="tree-7" in visible_ids,
            replay_saved=True,
            replay_offline_verified=True,
        )
    )
    return evaluation.model_dump(mode="json")


def _timeline(replay: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    rows: list[Mapping[str, Any]] = []
    for index, (decision, receipt) in enumerate(
        zip(replay["decisions"], replay["receipts"])
    ):
        observation = replay["observations"][index + 1]
        rows.append(
            {
                "observationSeq": observation["observation_seq"],
                "tick": observation["tick"],
                "responseType": None if decision is None else decision.get("type"),
                "receiptCodes": receipt["codes"],
                "accepted": receipt["accepted"],
                "events": [event["kind"] for event in observation["events"]],
                "agent": observation["controlled_assets"][0]["position"],
                "activePlan": observation["active_plan"],
            }
        )
    return rows


def _artifact_json(bundle: Path, role: str) -> Any:
    path = resolve_artifact(bundle, role, allow_protected=False)
    return strict_json_loads(path.read_bytes())


def _write_incomplete_run(
    root: Path,
    *,
    run_id: str,
    scenario_id: str,
    phase: str,
    error: BaseException,
    terminal_boundary_reached: bool = False,
    last_tick: int | None = None,
) -> Path | None:
    """Persist the universal sealed diagnostic without exposing error text."""

    try:
        return write_incomplete_run(
            Path(root).resolve(),
            run_id=run_id,
            phase=phase,
            reason="authority did not produce a durable verified replay",
            recoverable=terminal_boundary_reached,
            last_tick=last_tick,
            details={
                "authority": "godot",
                "failure_type": type(error).__name__,
                "game_id": "worldarena-primitive-sandbox-v0",
                "replay_saved": False,
                "scenario_id": scenario_id,
                "terminal_boundary_reached": terminal_boundary_reached,
            },
        )
    except BundleExistsError:
        # The first immutable diagnostic wins. A later error must not rewrite it.
        return None


__all__ = [
    "NATIVE_SCHEMA",
    "NATIVE_VERIFIER",
    "PrimitiveSandboxRun",
    "PrimitiveSandboxSession",
    "PrimitiveSandboxSessionConflict",
    "PrimitiveSandboxSessionNotFound",
    "PrimitiveSandboxService",
    "PrimitiveSandboxServiceError",
    "evaluate_primitive_sandbox_replay",
]
