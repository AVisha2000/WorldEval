"""Human-language task adapter; game state always remains in Godot."""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

from worldeval.contracts import canonical_json_bytes, strict_json_loads
from worldeval.replay import (
    PUBLIC,
    ArtifactInput,
    NativeVerifierRegistry,
    verify_replay_bundle,
    write_terminal_demo_bundle,
)

from .godot import NATIVE_SCHEMA, NATIVE_VERIFIER, GodotConversationWarehouseRunner
from .interpreter import (
    DemoVisibleReferentInterpreter,
    VisibleReferentInterpreter,
)

SCENARIO_ID = "warehouse-pickup-clarification-v0"


class ConversationSessionNotFound(KeyError):
    pass


class ConversationSessionConflict(ValueError):
    pass


@dataclass
class _Session:
    session_id: str
    run_id: str
    history: list[dict[str, Any]] = field(default_factory=list)
    messages: list[dict[str, str]] = field(default_factory=list)
    snapshot: Mapping[str, Any] | None = None
    intent_id: str | None = None
    target_id: str | None = None
    binding_id: str | None = None
    clarification_id: str | None = None
    status: str = "awaiting_message"
    replay: dict[str, Any] = field(
        default_factory=lambda: {
            "state": "not_started",
            "runId": None,
            "verified": False,
            "bundleUrl": None,
        }
    )


class ConversationSandboxService:
    def __init__(
        self,
        *,
        runner: GodotConversationWarehouseRunner,
        replay_root: Path,
        interpreter: VisibleReferentInterpreter | None = None,
    ) -> None:
        self.runner, self.replay_root, self.sessions = (
            runner,
            Path(replay_root).resolve(),
            {},
        )
        self.interpreter = interpreter or DemoVisibleReferentInterpreter()
        self.scenario = strict_json_loads(runner.scenario_path.read_bytes())
        self.initialization_hash = (
            "sha256:"
            + hashlib.sha256(
                canonical_json_bytes(
                    {"protocol": "worldeval-agent/0.1.0", "scenario": self.scenario}
                )
            ).hexdigest()
        )
        self.objects = {
            str(item["object_id"]): item
            for item in self.scenario["objects"]
            if isinstance(item, dict)
        }
        self.binding_targets = {
            "binding-blue-large": "box-blue-large-1",
            "binding-blue-small": "box-blue-small-1",
        }

    def catalog(self) -> Mapping[str, Any]:
        return {
            "gameId": self.scenario["environment_id"],
            "protocol": "worldeval-conversation/0.1.0",
            "actionProfile": "warehouse-direct-actions-v1",
            "observationProfile": "warehouse-visible-v1",
            "decisionProfile": "dynamic-step-locked-v1",
            "groundingInterpreter": self.interpreter.name,
            "scenarios": [
                {
                    "scenarioId": SCENARIO_ID,
                    "label": "Clarify → pick up → deliver",
                    "description": (
                        "Ask for a box, resolve the visible ambiguity, then watch "
                        "the agent adapt to a barrier."
                    ),
                }
            ],
        }

    def create_session(self, scenario_id: str) -> Mapping[str, Any]:
        if scenario_id != SCENARIO_ID:
            raise ConversationSessionConflict("unknown scenario")
        token = uuid.uuid4().hex[:12]
        session = _Session(session_id=f"conversation-{token}", run_id=f"conversation-{token}")
        session.snapshot = self._advance(session)
        self.sessions[session.session_id] = session
        return self._projection(session)

    def get_session(self, session_id: str) -> Mapping[str, Any]:
        return self._projection(self._session(session_id))

    def send_message(self, session_id: str, text: str) -> Mapping[str, Any]:
        session = self._session(session_id)
        clean = " ".join(text.split())
        if not clean:
            raise ConversationSessionConflict("empty message")
        session.messages.append(
            {"messageId": f"message-{len(session.messages) + 1}", "role": "user", "text": clean}
        )
        if session.intent_id is not None:
            return self._projection(session)
        candidate_ids = self.interpreter.candidates(
            text=clean,
            visible_objects=list(self.objects.values()),
        )
        allowed_ids = set(self.binding_targets.values())
        candidate_ids = tuple(item for item in candidate_ids if item in allowed_ids)
        if not candidate_ids:
            session.messages.append(
                {
                    "messageId": f"message-{len(session.messages) + 1}",
                    "role": "agent",
                    "text": "I cannot identify a visible portable box for that request.",
                }
            )
            return self._projection(session)
        session.intent_id = "intent-001"
        session.history.extend(
            [
                {
                    "kind": "intent.begin",
                    "intent_id": session.intent_id,
                    "revision": 1,
                    "text": clean,
                },
                {
                    "kind": "binding.request",
                    "intent_id": session.intent_id,
                    "candidate_ids": list(candidate_ids),
                },
            ]
        )
        session.snapshot = self._advance(session)
        session.clarification_id, session.status = "clarification-001", "clarification_required"
        session.messages.append(
            {
                "messageId": f"message-{len(session.messages) + 1}",
                "role": "agent",
                "text": "I can see two blue boxes. Which one should I pick up?",
            }
        )
        return self._projection(session)

    def acknowledge(
        self, session_id: str, clarification_id: str, binding_id: str
    ) -> Mapping[str, Any]:
        session = self._session(session_id)
        if (
            session.status != "clarification_required"
            or clarification_id != session.clarification_id
            or binding_id not in self.binding_targets
        ):
            raise ConversationSessionConflict("clarification is stale or unavailable")
        target_id = self.binding_targets[binding_id]
        target = self.objects[target_id]
        session.target_id, session.binding_id = target_id, binding_id
        session.history.append(
            {
                "kind": "binding.resolve",
                "intent_id": session.intent_id,
                "binding_id": binding_id,
                "object_id": target_id,
                "generation": int(target["generation"]),
            }
        )
        session.snapshot = self._advance(session)
        # The planner emits individual authority commands. It never delegates a route.
        for command in self._commands(session, binding_id, target):
            session.history.append({"kind": "command", "command": command})
            session.snapshot = self._advance(session)
        session.status = (
            "completed"
            if session.snapshot["replay"]["terminal_outcome"] == "delivered"
            else "failed"
        )
        completion_text = (
            f"Delivered the {target['traits']['size']} blue box to loading bay B. "
            "The barrier required an explicit detour."
            if session.status == "completed"
            else (
                f"I delivered the {target['traits']['size']} blue box, but it was not "
                "the scenario's required box. The attempt is recorded as a failure."
            )
        )
        session.messages.append(
            {
                "messageId": f"message-{len(session.messages) + 1}",
                "role": "agent",
                "text": completion_text,
            }
        )
        self._seal(session)
        return self._projection(session)

    def _commands(
        self,
        session: _Session,
        binding_id: str,
        target: Mapping[str, Any],
    ) -> list[dict[str, Any]]:
        assert session.snapshot is not None and session.intent_id is not None

        def source() -> dict[str, Any]:
            observation = session.snapshot["observation"]
            return {
                "observation_seq": observation["observation_seq"],
                "tick": observation["tick"],
                "state_hash": observation["state_hash"],
            }

        # Commands are executed one-by-one below, so compute each source lazily.
        templates = [
            {"type": "move", "target": dict(target["position"])},
            {"type": "pickup"},
            {"type": "move", "target": {"x": 13, "y": 5}},
            {"type": "replan"},
            {"type": "move", "target": {"x": 6, "y": 2}},
            {"type": "move", "target": {"x": 8, "y": 2}},
            {"type": "move", "target": {"x": 13, "y": 5}},
            {"type": "place", "bay_id": "loading-bay-b"},
        ]
        result: list[dict[str, Any]] = []
        # Each caller iteration advances; use marker and materialize source just-in-time there.
        for template in templates:
            result.append(template)
        return result

    def _advance(self, session: _Session) -> Mapping[str, Any]:
        # Materialize missing source fields from the immediately preceding observation.
        history: list[dict[str, Any]] = []
        snapshot: Mapping[str, Any] | None = None
        for entry in session.history:
            copied = dict(entry)
            if copied.get("kind") == "command" and "source" not in copied["command"]:
                command = dict(copied["command"])
                if snapshot is None:
                    snapshot = self.runner.advance(
                        history=history,
                        initialization_hash=self.initialization_hash,
                        run_id=session.run_id,
                    )
                observation = snapshot["observation"]
                command.setdefault("intent_id", session.intent_id)
                if command["type"] != "replan":
                    command.setdefault("binding_id", session.binding_id)
                command["source"] = {
                    "observation_seq": observation["observation_seq"],
                    "tick": observation["tick"],
                    "state_hash": observation["state_hash"],
                }
                copied["command"] = command
                # This command is newly proposed. Older commands retain the
                # source that was actually observed when they were submitted.
                session.history[session.history.index(entry)] = copied
            history.append(copied)
            snapshot = None
        return self.runner.advance(
            history=history, initialization_hash=self.initialization_hash, run_id=session.run_id
        )

    def _seal(self, session: _Session) -> None:
        replay = session.snapshot["replay"]
        verification = self.runner.verify_native_replay(replay)
        target = self.objects[session.target_id or "box-blue-large-1"]
        objective = {
            "objective_id": f"deliver-{target['object_id']}-to-bay-b",
            "instruction": (f"Deliver the {target['traits']['size']} blue box to loading bay B."),
        }
        initialization = {
            "protocol": "worldeval-conversation/0.1.0",
            "game_id": self.scenario["environment_id"],
            "environment_id": self.scenario["environment_id"],
            "initialization_hash": self.initialization_hash,
            "profiles": {
                "action": "warehouse-direct-actions-v1",
                "observation": "warehouse-visible-v1",
                "decision": "dynamic-step-locked-v1",
            },
            "active_objective": objective,
        }
        evaluation = {
            "objective_id": objective["objective_id"],
            "outcome": replay["terminal_outcome"],
            "terminal_tick": replay["terminal_tick"],
            "passed": replay["terminal_outcome"] == "delivered",
            "replay_saved": True,
            "replay_offline_verified": True,
            "provider_calls": 0,
        }
        metadata = {
            "run_id": session.run_id,
            "game": {"id": self.scenario["environment_id"]},
            "scenario": {"id": replay["scenario_id"]},
            "task": {"id": objective["objective_id"]},
            "subject": {"kind": "agent", "id": "warehouse-agent-1"},
            "protocol": {
                "id": "worldeval-conversation",
                "version": "0.1.0",
                "package_hash": "sha256:" + "0" * 64,
            },
            "engine": {"id": "godot", "build_hash": "sha256:" + "0" * 64},
            "seed": 0,
            "profiles": initialization["profiles"],
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
        artifacts = [
            ArtifactInput.json(
                path="replays/primary.replay.json",
                role="primary",
                kind="replay",
                value=replay,
                visibility=PUBLIC,
                native_schema=NATIVE_SCHEMA,
                verifier=NATIVE_VERIFIER,
                final_state_hash=replay["terminal_state_hash"],
            ),
            ArtifactInput.json(
                path="evidence/environment-init.json",
                role="environment_init",
                kind="evidence",
                value=initialization,
                visibility=PUBLIC,
            ),
            ArtifactInput.json(
                path="evidence/objective.json",
                role="objective",
                kind="evidence",
                value=objective,
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
                path="evidence/result.json",
                role="result",
                kind="evidence",
                value={
                    "run_id": session.run_id,
                    "scenario_id": replay["scenario_id"],
                    "outcome": replay["terminal_outcome"],
                    "terminal_tick": replay["terminal_tick"],
                    "terminal_state_hash": verification.final_state_hash,
                    "passed": evaluation["passed"],
                },
                visibility=PUBLIC,
            ),
        ]
        registry = NativeVerifierRegistry(
            {
                (NATIVE_VERIFIER, NATIVE_SCHEMA): lambda payload, _: (
                    self.runner.verify_native_replay(strict_json_loads(payload))
                )
            }
        )
        bundle = write_terminal_demo_bundle(
            self.replay_root, metadata=metadata, artifacts=artifacts, native_verifiers=registry
        )
        verify_replay_bundle(
            bundle,
            native_verifiers=registry,
            require_native_verification=True,
            require_provider_calls_zero=True,
        )
        session.replay = {
            "state": "ready",
            "runId": session.run_id,
            "verified": True,
            "bundleUrl": f"/api/worldeval/replays/{session.run_id}",
        }

    def _projection(self, session: _Session) -> Mapping[str, Any]:
        native_receipts = [] if not session.snapshot else session.snapshot["replay"]["receipts"]
        receipts = [
            {
                "receiptId": item["receipt_id"],
                "label": item["code"].replace("_", " "),
                "state": (
                    "completed"
                    if item["accepted"] and item["code"] in {"pickup_complete", "place_complete"}
                    else "accepted"
                    if item["accepted"]
                    else "suspended"
                    if item["code"] == "movement_blocked"
                    else "rejected"
                ),
            }
            for item in native_receipts
        ]
        binding_status = "bound" if session.binding_id else "candidate"
        return {
            "sessionId": session.session_id,
            "scenarioId": SCENARIO_ID,
            "status": session.status,
            "messages": session.messages,
            "grounding": {
                "intentRevision": 1 if session.intent_id else 0,
                "state": "ambiguous"
                if session.status == "clarification_required"
                else ("bound" if session.intent_id else "unbound"),
                "taskSummary": "Deliver a selected blue box to loading bay B."
                if session.intent_id
                else None,
                "bindings": [
                    {
                        "bindingId": "binding-blue-large",
                        "label": "large blue box",
                        "status": (
                            "bound"
                            if session.binding_id == "binding-blue-large"
                            else "rejected"
                            if session.binding_id
                            else binding_status
                        ),
                    },
                    {
                        "bindingId": "binding-blue-small",
                        "label": "small blue box",
                        "status": (
                            "bound"
                            if session.binding_id == "binding-blue-small"
                            else "rejected"
                            if session.binding_id
                            else binding_status
                        ),
                    },
                ],
                "clarification": None
                if session.status != "clarification_required"
                else {
                    "clarificationId": session.clarification_id,
                    "prompt": "Which blue box?",
                    "options": [
                        {"bindingId": "binding-blue-large", "label": "large blue box"},
                        {"bindingId": "binding-blue-small", "label": "small blue box"},
                    ],
                },
            },
            "constraints": [
                {
                    "constraintId": "godot-authority",
                    "label": "Godot is the gameplay authority.",
                    "kind": "hard",
                    "state": "active",
                },
                {
                    "constraintId": "explicit-detour",
                    "label": "The planner must explicitly route around barriers.",
                    "kind": "safety",
                    "state": "satisfied"
                    if any(item["code"] == "replan_accepted" for item in native_receipts)
                    else "active",
                },
            ],
            "plan": None
            if not session.intent_id
            else {
                "planId": "warehouse-plan-001" if session.intent_id else None,
                "status": session.status,
                "steps": [
                    {
                        "stepId": f"step-{index + 1}",
                        "label": receipt["label"],
                        "state": (
                            "completed"
                            if receipt["state"] in {"accepted", "completed"}
                            else "suspended"
                            if receipt["state"] == "suspended"
                            else "aborted"
                        ),
                    }
                    for index, receipt in enumerate(receipts)
                ],
            },
            "receipts": receipts,
            "replay": session.replay,
        }

    def _session(self, session_id: str) -> _Session:
        if session_id not in self.sessions:
            raise ConversationSessionNotFound(session_id)
        return self.sessions[session_id]
