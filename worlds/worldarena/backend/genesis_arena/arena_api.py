from __future__ import annotations

import hashlib

# ruff: noqa: UP045 -- Python 3.9-compatible annotations are intentional.
import json
from typing import Dict, List, Literal, Optional

from fastapi import WebSocket, WebSocketDisconnect
from pydantic import BaseModel, ConfigDict, Field, SecretStr, ValidationError, model_validator

from .arena.artifacts import ModelSnapshot, RunArtifactStore, RunManifest, RunMetadata, RunResult
from .arena.demo_policy import ArenaDemoCommander
from .arena.live_results import build_live_match_result
from .arena.models import (
    DecisionDiagnostic,
    FactionId,
    FactionPlan,
    Identifier,
    ObservationMode,
    RoundCommitsLocked,
    RoundReceipt,
    RoundRequest,
)
from .arena.runtime import (
    ArenaOrchestrator,
    ArenaRuntimeError,
    CognitionBudget,
    FactionRuntime,
)
from .config import Settings


class ArenaWireModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ArenaFactionConfig(ArenaWireModel):
    agent_id: FactionId
    model: str = Field(min_length=1, max_length=120)
    reasoning_effort: Literal["none", "low", "medium", "high", "xhigh", "max"] = "medium"
    max_specialists: int = Field(default=2, ge=0, le=3)
    # ``advisor_count`` is the v0.3 name.  Keep the established field so older setup
    # clients do not need a migration release.
    advisor_count: Optional[int] = Field(default=None, ge=0, le=3)

    @model_validator(mode="after")
    def validate_advisor_limit(self) -> ArenaFactionConfig:
        # ``max_specialists=2`` is the conquest default, so an advisor-only request
        # may intentionally override it. Non-default dual values must agree.
        if (
            self.advisor_count is not None
            and self.max_specialists != 2
            and self.advisor_count != self.max_specialists
        ):
            raise ValueError("advisor_count must match max_specialists when both are provided")
        return self

    @property
    def specialist_limit(self) -> int:
        return self.max_specialists if self.advisor_count is None else self.advisor_count


class ArenaMatchConfigure(ArenaWireModel):
    type: Literal["configure_match", "configure_arena"] = "configure_match"
    protocol: Literal["world-arena/0.2", "world-arena/0.3", "world-arena/0.4"] = (
        "world-arena/0.4"
    )
    match_id: Optional[Identifier] = None
    api_key: Optional[SecretStr] = None
    brain_mode: Optional[Literal["demo", "openai"]] = None
    mode: Literal["demo", "benchmark", "openai"] = "demo"
    track: Literal["standard", "agentic", "open"] = "agentic"
    map_id: Literal["tri_13_v1"] = "tri_13_v1"
    seed: int = Field(default=1, ge=1, le=2_147_483_646)
    max_rounds: int = Field(default=120, ge=1, le=120)
    observation_mode: ObservationMode = "semantic"
    agents: List[ArenaFactionConfig] = Field(min_length=3, max_length=3)

    @model_validator(mode="after")
    def validate_competitors(self) -> ArenaMatchConfigure:
        if {agent.agent_id for agent in self.agents} != {"sol", "terra", "luna"}:
            raise ValueError("configuration requires sol, terra, and luna exactly once")
        if self.selected_brain_mode == "openai":
            key = self.api_key.get_secret_value() if self.api_key is not None else ""
            if len(key.strip()) < 8:
                raise ValueError("an API key is required for OpenAI mode")
        return self

    @property
    def selected_brain_mode(self) -> Literal["demo", "openai"]:
        if self.brain_mode is not None:
            return self.brain_mode
        if self.api_key is not None and self.api_key.get_secret_value().strip():
            return "openai"
        return "openai" if self.mode == "openai" else "demo"


class ArenaSession:
    """One isolated, secret-in-memory Arena connection."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self.orchestrator: Optional[ArenaOrchestrator] = None
        self.match_id = ""
        self.models: Dict[str, str] = {}
        self.agent_metadata: Dict[str, Dict[str, object]] = {}
        self.receipts: Dict[int, RoundReceipt] = {}
        self.round_plans: Dict[int, Dict[str, FactionPlan]] = {}
        self.round_diagnostics: Dict[int, Dict[str, DecisionDiagnostic]] = {}
        self.track = "agentic"
        self.max_rounds = 120
        self.seed = 1
        self.brain_mode = "demo"
        self.map_id = "tri_13_v1"
        self.protocol = "world-arena/0.4"
        self.observation_mode: ObservationMode = "semantic"
        self.artifact_store = RunArtifactStore(settings.runs_dir)
        self.round_artifacts = []
        self.artifact_directory = None

    def configure(self, config: ArenaMatchConfigure) -> Dict[str, object]:
        raw_key = config.api_key.get_secret_value() if config.api_key is not None else None
        brain_mode = config.selected_brain_mode
        runtimes: Dict[str, FactionRuntime] = {}

        for competitor in config.agents:
            if config.track == "standard":
                budget = CognitionBudget(
                    track="standard",
                    total_units=config.max_rounds * 2,
                    total_rounds=config.max_rounds,
                )
            elif config.track == "open":
                budget = CognitionBudget(
                    track="open",
                    total_units=config.max_rounds * 2,
                    total_rounds=config.max_rounds,
                )
            else:
                budget = CognitionBudget(
                    track="agentic",
                    total_units=config.max_rounds * 3,
                    total_rounds=config.max_rounds,
                )

            if brain_mode == "openai":
                # Imported only after a validated configuration so a demo match is fully
                # credential-free and startup never creates a provider client.
                from .arena.openai_runtime import ArenaOpenAICommander, ArenaOpenAISpecialist

                commander = ArenaOpenAICommander(
                    model=competitor.model,
                    reasoning_effort=competitor.reasoning_effort,
                    api_key=raw_key,
                    identity=(
                        f"You command faction {competitor.agent_id} in WorldArena. "
                        "Be the last surviving stronghold: build an economy, scout, fortify, "
                        "research, field an army, attack rival keeps, and negotiate "
                        "strategically with two independent opponents."
                    ),
                )

                def specialist_factory(
                    _faction: FactionId,
                    _operation: object,
                    *,
                    model: str = competitor.model,
                    effort: str = competitor.reasoning_effort,
                    key: Optional[str] = raw_key,
                ) -> ArenaOpenAISpecialist:
                    specialist_effort = "low" if effort == "none" else effort
                    return ArenaOpenAISpecialist(
                        model=model,
                        reasoning_effort=specialist_effort,
                        api_key=key,
                    )

                factory = specialist_factory if competitor.specialist_limit else None
            else:
                commander = ArenaDemoCommander()
                factory = None

            runtimes[competitor.agent_id] = FactionRuntime(
                faction_id=competitor.agent_id,
                commander=commander,
                budget=budget,
                specialist_factory=factory,
                max_specialists=competitor.specialist_limit,
            )

        # The raw key is deliberately not retained on this session. In provider mode it exists
        # only inside the three local OpenAI clients and any specialist clients they create.
        raw_key = None
        self.orchestrator = ArenaOrchestrator(
            runtimes,
            decision_timeout_seconds=self.settings.decision_timeout_seconds,
        )
        self.models = {agent.agent_id: agent.model for agent in config.agents}
        self.agent_metadata = {
            agent.agent_id: {
                "model": agent.model,
                "reasoning_effort": agent.reasoning_effort,
                "max_specialists": agent.specialist_limit,
                "advisor_count": agent.specialist_limit,
            }
            for agent in config.agents
        }
        self.track = config.track
        self.max_rounds = config.max_rounds
        self.seed = config.seed
        self.brain_mode = brain_mode
        self.map_id = config.map_id
        self.protocol = config.protocol
        self.observation_mode = config.observation_mode
        self.receipts.clear()
        self.round_plans.clear()
        self.round_diagnostics.clear()
        self.round_artifacts.clear()
        self.artifact_directory = None
        response: Dict[str, object] = {
            "type": "configured",
            "protocol": config.protocol,
            "brain_mode": brain_mode,
            "track": config.track,
            "map_id": config.map_id,
            "seed": config.seed,
            "max_rounds": config.max_rounds,
            "observation_mode": config.observation_mode,
            "models": dict(self.models),
            "agents": dict(self.agent_metadata),
        }
        if config.match_id is not None:
            response["match_id"] = config.match_id
        return response

    def require_orchestrator(self) -> ArenaOrchestrator:
        if self.orchestrator is None:
            raise ArenaRuntimeError("configure_match must be sent before round_request")
        return self.orchestrator

    def official_terminal_result(self, receipt: RoundReceipt) -> Dict[str, object]:
        """Produce a score only from a contiguous chain of Godot receipts."""

        if receipt.terminal_outcome is None:
            raise ArenaRuntimeError("receipt is not terminal")
        orchestrator = self.require_orchestrator()
        result = build_live_match_result(
            terminal=receipt.terminal_outcome,
            match_id=receipt.match_id,
            track=self.track,
            seed=self.seed,
            models=self.models,
            agent_metadata=self.agent_metadata,
            runtimes=orchestrator.runtimes,
            receipts=self.receipts,
            round_plans=self.round_plans,
            round_diagnostics=self.round_diagnostics,
        )
        payload = result.model_dump(mode="json")
        payload.update(
            {
                "verified": True,
                "verification_label": "VERIFIED GODOT RECEIPTS",
                "verification_detail": (
                    "Terminal outcome, sealed plans, and contiguous authoritative "
                    "receipts passed deterministic scoring."
                ),
                "evidence_mode": "authoritative_receipts",
            }
        )
        return payload

    def record_finalized_round(self, receipt: RoundReceipt) -> None:
        """Buffer sealed evidence until a terminal receipt supplies authoritative hashes."""

        artifact = self.require_orchestrator().finalized_round_artifact(receipt)
        self.round_artifacts.append(artifact)

    def persist_completed_run(self, receipt: RoundReceipt, result: Dict[str, object]) -> str:
        """Write an append-only, secret-free replay only after official terminal validation."""

        terminal = receipt.terminal_outcome
        if terminal is None:
            raise ArenaRuntimeError("cannot persist a non-terminal match")
        if len(self.round_artifacts) != terminal.completed_rounds:
            raise ArenaRuntimeError("cannot persist an incomplete finalized-round evidence chain")
        prompt_models = []
        for faction in ("sol", "terra", "luna"):
            identity = {
                "faction": faction,
                "model": self.models[faction],
                "reasoning_effort": self.agent_metadata[faction]["reasoning_effort"],
            }
            prompt_models.append(
                ModelSnapshot(
                    faction_id=faction,
                    model=self.models[faction],
                    reasoning_effort=self.agent_metadata[faction]["reasoning_effort"],
                    prompt_hash=hashlib.sha256(
                        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
                    ).hexdigest(),
                )
            )
        manifest = RunManifest(
            match_id=receipt.match_id,
            protocol=receipt.protocol,
            map_id=self.map_id,
            map_hash=terminal.map_hash,
            rules_id="arena-v0.4",
            rules_hash=terminal.rules_hash,
            tool_hash=terminal.tool_hash,
            seed=self.seed,
            cognition_track=self.track,
            round_limit=self.max_rounds,
            models=prompt_models,
            metadata=RunMetadata(mode="demo" if self.brain_mode == "demo" else "benchmark"),
        )
        directory = self.artifact_store.create(manifest)
        for artifact in self.round_artifacts:
            self.artifact_store.append_round(artifact)
        factions = result.get("factions", [])
        placements = {item["faction_id"]: item["placement"] for item in factions}
        usage = {item["faction_id"]: item["usage"] for item in factions}
        self.artifact_store.finish(
            RunResult(
                match_id=receipt.match_id,
                placements=placements,
                final_state_hash=receipt.state_hash,
                completed_rounds=terminal.completed_rounds,
                winner_id=None if terminal.winner == "draw" else terminal.winner,
                draw=terminal.winner == "draw",
                usage=usage,
                metrics={
                    "formula_version": result["formula_version"],
                    "outcome_authority": result["outcome_authority"],
                    "llm_judge_used": result["llm_judge_used"],
                    "factions": factions,
                },
            )
        )
        self.artifact_directory = directory
        return directory.name


def _safe_validation_details(error: ValidationError) -> List[Dict[str, object]]:
    """Return useful schema feedback without echoing inputs (especially API keys)."""

    return [
        {
            "location": [str(item) for item in detail.get("loc", ())],
            "message": str(detail.get("msg", "invalid value")),
            "type": str(detail.get("type", "validation_error")),
        }
        for detail in error.errors(include_input=False)
    ]


async def arena_socket(websocket: WebSocket, settings: Settings) -> None:
    await websocket.accept()
    session = ArenaSession(settings)
    await websocket.send_json(
        {
            "type": "connected",
            "protocol": "world-arena/0.4",
            "supports": [
                "demo",
                "openai",
                "commit_reveal",
                "simultaneous_plans",
                "world-arena/0.2",
                "world-arena/0.3",
                "world-arena/0.4",
            ],
        }
    )

    try:
        while True:
            try:
                message = json.loads(await websocket.receive_text())
                if not isinstance(message, dict):
                    raise ValueError("message must be a JSON object")
            except json.JSONDecodeError:
                await websocket.send_json({"type": "error", "error": "invalid JSON message"})
                continue

            message_type = message.get("type")
            try:
                if message_type in {"configure_match", "configure_arena"}:
                    try:
                        config = ArenaMatchConfigure.model_validate(message)
                    except ValidationError as exc:
                        await websocket.send_json(
                            {
                                "type": "error",
                                "error": "invalid Arena configuration",
                                "details": _safe_validation_details(exc),
                            }
                        )
                        continue
                    await websocket.send_json(session.configure(config))
                    continue

                if message_type == "ping":
                    await websocket.send_json({"type": "pong", "protocol": session.protocol})
                    continue

                if message_type == "round_request":
                    orchestrator = session.require_orchestrator()
                    request = RoundRequest.model_validate(message)
                    if request.protocol != session.protocol:
                        raise ArenaRuntimeError(
                            "round request protocol does not match configuration"
                        )
                    if any(
                        observation.observation_mode != session.observation_mode
                        for observation in request.observations
                    ):
                        raise ArenaRuntimeError("observation mode does not match configuration")
                    if session.match_id and request.match_id != session.match_id:
                        raise ArenaRuntimeError("Arena session is already bound to another match")
                    session.match_id = request.match_id
                    await websocket.send_json(
                        {
                            "type": "thinking_status",
                            "match_id": request.match_id,
                            "round": request.round,
                            "statuses": {
                                "sol": "thinking",
                                "terra": "thinking",
                                "luna": "thinking",
                            },
                        }
                    )
                    commits = await orchestrator.commit_round(request)
                    statuses = {
                        commit.faction_id: ("locked" if commit.status == "planned" else "fallback")
                        for commit in commits.commits
                    }
                    await websocket.send_json(
                        {
                            "type": "thinking_status",
                            "match_id": request.match_id,
                            "round": request.round,
                            "statuses": statuses,
                        }
                    )
                    await websocket.send_json(commits.model_dump(mode="json"))
                    continue

                if message_type == "round_commits_locked":
                    orchestrator = session.require_orchestrator()
                    acknowledgement = RoundCommitsLocked.model_validate(message)
                    if acknowledgement.protocol != session.protocol:
                        raise ArenaRuntimeError("commit lock protocol does not match configuration")
                    orchestrator.lock_commits(acknowledgement)
                    reveal = await orchestrator.reveal_round(
                        acknowledgement.match_id, acknowledgement.round
                    )
                    await websocket.send_json(reveal.model_dump(mode="json"))
                    continue

                if message_type == "round_receipts":
                    orchestrator = session.require_orchestrator()
                    receipt = RoundReceipt.model_validate(message)
                    if receipt.protocol != session.protocol:
                        raise ArenaRuntimeError("receipt protocol does not match configuration")
                    if not session.match_id or receipt.match_id != session.match_id:
                        raise ArenaRuntimeError("receipt does not belong to this Arena session")
                    await orchestrator.finalize_round(receipt)
                    session.receipts[receipt.round] = receipt
                    plans, diagnostics = orchestrator.finalized_round_data(
                        receipt.match_id, receipt.round
                    )
                    session.round_plans[receipt.round] = plans
                    session.round_diagnostics[receipt.round] = diagnostics
                    session.record_finalized_round(receipt)
                    official_result = None
                    artifact_run = None
                    if receipt.terminal_outcome is not None:
                        # A terminal receipt is not acknowledged as complete unless its
                        # full evidence chain passes the artifact store's secret scanner.
                        official_result = session.official_terminal_result(receipt)
                        artifact_run = session.persist_completed_run(receipt, official_result)
                    await websocket.send_json(
                        {
                            "type": "round_receipts_accepted",
                            "protocol": receipt.protocol,
                            "match_id": receipt.match_id,
                            "round": receipt.round,
                            "state_hash": receipt.state_hash,
                        }
                    )
                    if official_result is not None:
                        await websocket.send_json(
                            {
                                "type": "match_result",
                                "protocol": receipt.protocol,
                                "result": official_result,
                                "artifact_run": artifact_run,
                            }
                        )
                    elif receipt.standings is not None:
                        await websocket.send_json(
                            {
                                "type": "match_truncated",
                                "protocol": receipt.protocol,
                                "match_id": receipt.match_id,
                                "round": receipt.round,
                                "reason": receipt.standings.reason,
                                "winner": None,
                                "standings": receipt.standings.model_dump(mode="json"),
                            }
                        )
                    continue

                await websocket.send_json(
                    {"type": "error", "error": f"unsupported message type: {message_type!r}"}
                )
            except ValidationError as exc:
                await websocket.send_json(
                    {
                        "type": "error",
                        "error": "invalid Arena protocol message",
                        "details": _safe_validation_details(exc),
                    }
                )
            except (ArenaRuntimeError, ValueError) as exc:
                await websocket.send_json(
                    {"type": "error", "error": "Arena request rejected", "details": str(exc)}
                )
    except WebSocketDisconnect:
        return
