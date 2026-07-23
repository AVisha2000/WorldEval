"""Safe language-to-visible-referent boundary for conversational worlds.

The interpreter may propose which *visible* objects a human phrase could mean.
It cannot produce game actions, coordinates, hidden-object IDs, or a continuation
decision.  The service verifies its candidates against the current Godot
observation before a binding can exist.
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass
from typing import Any, Mapping, Protocol, Sequence


class ConversationInterpretationError(RuntimeError):
    """An interpreter did not return a safe, usable grounding result."""


class VisibleReferentInterpreter(Protocol):
    name: str

    def candidates(
        self,
        *,
        text: str,
        visible_objects: Sequence[Mapping[str, Any]],
    ) -> tuple[str, ...]:
        """Return an ordered subset of current visible object IDs only."""


class VisibleActionPlanner(Protocol):
    """Choose exactly one next visible semantic action at a decision boundary."""

    name: str

    def next_action(
        self,
        *,
        observation: Mapping[str, Any],
        target: Mapping[str, Any],
        bay: Mapping[str, Any],
    ) -> Mapping[str, Any]:
        """Return an unbound action object; authority source is added later."""


@dataclass(frozen=True)
class DemoVisibleReferentInterpreter:
    """Deterministic, credential-free oracle for demos and replay acceptance."""

    name: str = "demo-visible-grounding-v1"

    def candidates(
        self,
        *,
        text: str,
        visible_objects: Sequence[Mapping[str, Any]],
    ) -> tuple[str, ...]:
        lowered = text.casefold()
        boxes = [
            item
            for item in visible_objects
            if item.get("type_id") == "box" and item.get("state", {}).get("visible")
        ]
        if "blue" in lowered:
            boxes = [item for item in boxes if item.get("traits", {}).get("color") == "blue"]
        if "large" in lowered:
            boxes = [item for item in boxes if item.get("traits", {}).get("size") == "large"]
        if "small" in lowered:
            boxes = [item for item in boxes if item.get("traits", {}).get("size") == "small"]
        return tuple(sorted(str(item["object_id"]) for item in boxes))


@dataclass(frozen=True)
class DemoVisibleActionPlanner:
    """Boundary-by-boundary policy used only for deterministic acceptance demos."""

    name: str = "demo-visible-action-planner-v1"

    def next_action(
        self,
        *,
        observation: Mapping[str, Any],
        target: Mapping[str, Any],
        bay: Mapping[str, Any],
    ) -> Mapping[str, Any]:
        agent = observation["controlled_assets"][0]
        position = agent["position"]
        carrying_id = agent.get("carrying_id", "")
        if observation["decision_required"].get("replan_required"):
            return {"type": "replan"}
        if not carrying_id:
            if position != target["position"]:
                return {"type": "move", "target": dict(target["position"])}
            return {"type": "pickup"}
        if position == bay["position"]:
            return {"type": "place", "bay_id": bay["object_id"]}
        # Try the declared direct route first. If a newly materialized barrier
        # blocks it, the next authority observation requires an explicit replan.
        if position == target["position"]:
            return {"type": "move", "target": dict(bay["position"])}
        # This is a proposal, not a game shortcut: the authority still applies
        # each visible move and can interrupt the plan at every boundary.
        if int(position["x"]) <= 6 and int(position["y"]) != 2:
            return {"type": "move", "target": {"x": int(position["x"]), "y": 2}}
        if int(position["x"]) < 8:
            return {"type": "move", "target": {"x": 8, "y": 2}}
        return {"type": "move", "target": dict(bay["position"])}


class OpenAIVisibleActionPlanner:
    """Optional structured-output planner for one action per authority boundary."""

    name = "openai-visible-action-planner-v1"

    def __init__(self, *, model: str, api_key: str | None = None) -> None:
        key = api_key or os.getenv("OPENAI_API_KEY")
        if not key:
            raise ConversationInterpretationError(
                "OpenAI conversation mode requires OPENAI_API_KEY"
            )
        self.model, self._api_key = model, key

    def next_action(
        self,
        *,
        observation: Mapping[str, Any],
        target: Mapping[str, Any],
        bay: Mapping[str, Any],
    ) -> Mapping[str, Any]:
        try:
            return asyncio.run(self._request(observation=observation, target=target, bay=bay))
        except RuntimeError as error:
            raise ConversationInterpretationError(
                "OpenAI action planning cannot run inside an active event loop"
            ) from error

    async def _request(
        self,
        *,
        observation: Mapping[str, Any],
        target: Mapping[str, Any],
        bay: Mapping[str, Any],
    ) -> Mapping[str, Any]:
        from openai import AsyncOpenAI

        schema = {
            "type": "object",
            "additionalProperties": False,
            "required": ["type"],
            "properties": {
                "type": {"type": "string", "enum": ["move", "pickup", "place", "replan"]},
                "target": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["x", "y"],
                    "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}},
                },
                "bay_id": {"type": "string"},
            },
        }
        client = AsyncOpenAI(api_key=self._api_key, max_retries=0)
        try:
            response = await client.responses.create(
                model=self.model,
                instructions=(
                    "Choose one visible semantic action only. You control no hidden "
                    "state and must never invent object IDs. If movement is blocked, "
                    "first choose replan; then choose explicit waypoints yourself."
                ),
                input=json.dumps({"observation": observation, "target": target, "bay": bay}),
                text={
                    "format": {
                        "type": "json_schema",
                        "name": "warehouse_action",
                        "strict": True,
                        "schema": schema,
                    }
                },
                store=False,
            )
            value = json.loads(response.output_text)
        except Exception as error:
            raise ConversationInterpretationError(
                "OpenAI action planning request failed"
            ) from error
        finally:
            await client.close()
        return _validate_visible_action(value, bay_id=str(bay["object_id"]))


def _validate_visible_action(value: Any, *, bay_id: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) - {"type", "target", "bay_id"}:
        raise ConversationInterpretationError("action response is invalid")
    kind = value.get("type")
    if kind == "move":
        target = value.get("target")
        if (
            not isinstance(target, dict)
            or set(target) != {"x", "y"}
            or any(
                isinstance(target[key], bool) or not isinstance(target[key], int) for key in target
            )
            or not 0 <= target["x"] < 30
            or not 0 <= target["y"] < 25
        ):
            raise ConversationInterpretationError("move response is invalid")
        return {"type": "move", "target": dict(target)}
    if kind == "pickup" and set(value) == {"type"}:
        return {"type": "pickup"}
    if kind == "replan" and set(value) == {"type"}:
        return {"type": "replan"}
    if kind == "place" and value.get("bay_id") == bay_id and set(value) == {"type", "bay_id"}:
        return {"type": "place", "bay_id": bay_id}
    raise ConversationInterpretationError("action response is unsupported")


class OpenAIVisibleReferentInterpreter:
    """Optional OpenAI structured-output interpreter for real chat sessions.

    It receives only the user message and current public visible-object catalog.
    Raw output and credentials remain process-local and never reach the public
    session projection or deterministic replay bundle.
    """

    name = "openai-visible-grounding-v1"

    def __init__(self, *, model: str, api_key: str | None = None) -> None:
        key = api_key or os.getenv("OPENAI_API_KEY")
        if not key:
            raise ConversationInterpretationError(
                "OpenAI conversation mode requires OPENAI_API_KEY"
            )
        self.model = model
        self._api_key = key

    def candidates(
        self,
        *,
        text: str,
        visible_objects: Sequence[Mapping[str, Any]],
    ) -> tuple[str, ...]:
        try:
            return asyncio.run(self._request(text=text, visible_objects=visible_objects))
        except RuntimeError as error:
            raise ConversationInterpretationError(
                "OpenAI grounding cannot run inside an active event loop"
            ) from error

    async def _request(
        self,
        *,
        text: str,
        visible_objects: Sequence[Mapping[str, Any]],
    ) -> tuple[str, ...]:
        from openai import AsyncOpenAI

        visible = [
            {
                "object_id": item["object_id"],
                "type_id": item["type_id"],
                "traits": item.get("traits", {}),
            }
            for item in visible_objects
            if item.get("state", {}).get("visible")
        ]
        client = AsyncOpenAI(api_key=self._api_key, max_retries=0)
        try:
            response = await client.responses.create(
                model=self.model,
                instructions=(
                    "Ground the human's request to zero or more IDs in the supplied "
                    "visible object catalog. Never invent IDs or actions. If wording is "
                    "ambiguous, return all plausible IDs so the human can clarify."
                ),
                input=json.dumps({"message": text, "visible_objects": visible}),
                text={
                    "format": {
                        "type": "json_schema",
                        "name": "visible_referents",
                        "strict": True,
                        "schema": {
                            "type": "object",
                            "additionalProperties": False,
                            "required": ["candidate_ids"],
                            "properties": {
                                "candidate_ids": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "maxItems": 16,
                                }
                            },
                        },
                    }
                },
                store=False,
            )
            value = json.loads(response.output_text)
        except Exception as error:
            raise ConversationInterpretationError("OpenAI grounding request failed") from error
        finally:
            await client.close()
        ids = value.get("candidate_ids") if isinstance(value, dict) else None
        allowed = {item["object_id"] for item in visible}
        if not isinstance(ids, list) or any(not isinstance(item, str) for item in ids):
            raise ConversationInterpretationError("OpenAI grounding response is invalid")
        if len(ids) > 16 or len(ids) != len(set(ids)) or not set(ids).issubset(allowed):
            raise ConversationInterpretationError("OpenAI grounding response is unsafe")
        return tuple(ids)


def create_visible_referent_interpreter(*, mode: str, model: str) -> VisibleReferentInterpreter:
    if mode == "openai" or (mode == "auto" and os.getenv("OPENAI_API_KEY")):
        return OpenAIVisibleReferentInterpreter(model=model)
    return DemoVisibleReferentInterpreter()


def create_visible_action_planner(*, mode: str, model: str) -> VisibleActionPlanner:
    if mode == "openai" or (mode == "auto" and os.getenv("OPENAI_API_KEY")):
        return OpenAIVisibleActionPlanner(model=model)
    return DemoVisibleActionPlanner()
