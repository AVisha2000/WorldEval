from __future__ import annotations

import json
import os
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any, Dict, List

from openai import AsyncOpenAI, OpenAIError

from .catalog import ActionCatalog
from .config import Settings
from .models import ActionCommand, ActionName, Observation


class BrainError(RuntimeError):
    pass


class Brain(ABC):
    @abstractmethod
    async def decide(self, observation: Observation, memory: List[str]) -> ActionCommand:
        raise NotImplementedError


class DemoBrain(Brain):
    """A predictable policy for offline demos and protocol regression tests."""

    def _can_see(self, observation: Observation, kind: str) -> bool:
        return any(
            resource.kind.value == kind and resource.quantity > 0
            for resource in observation.visible_resources
        )

    def _command(
        self,
        observation: Observation,
        action: ActionName,
        intent: str,
        **parameters: Any,
    ) -> ActionCommand:
        return ActionCommand(
            turn=observation.turn,
            agent_id=observation.agent_id,
            action=action,
            parameters=parameters,
            intent=intent,
            source="demo-policy",
        )

    async def decide(self, observation: Observation, memory: List[str]) -> ActionCommand:
        state = observation.agent
        inventory = state.inventory
        shelter_count = state.structures.get("shelter", 0)

        if state.food <= 26 and self._can_see(observation, "food"):
            return self._command(
                observation,
                ActionName.COLLECT,
                "Food is approaching the danger threshold; forage before expanding.",
                resource="food",
            )

        if shelter_count == 0:
            if inventory.get("wood", 0) < 12 and self._can_see(observation, "wood"):
                return self._command(
                    observation,
                    ActionName.COLLECT,
                    "Gather enough timber for the first shelter.",
                    resource="wood",
                )
            if inventory.get("stone", 0) < 4 and self._can_see(observation, "stone"):
                return self._command(
                    observation,
                    ActionName.COLLECT,
                    "Secure the stone foundation needed for shelter.",
                    resource="stone",
                )
            if inventory.get("wood", 0) >= 12 and inventory.get("stone", 0) >= 4:
                return self._command(
                    observation,
                    ActionName.BUILD,
                    "Build shelter now to reduce exposure for the remaining days.",
                    structure="shelter",
                )

        if state.health < 60:
            return self._command(
                observation,
                ActionName.REST,
                "Recover health before taking another journey.",
            )

        if state.food < 62 and self._can_see(observation, "food"):
            return self._command(
                observation,
                ActionName.COLLECT,
                "Replenish the food reserve while nearby forage remains.",
                resource="food",
            )

        directions = ["north", "east", "south", "west"]
        area = directions[observation.turn % len(directions)]
        return self._command(
            observation,
            ActionName.INSPECT,
            f"Immediate needs are stable; scout {area} for the next opportunity.",
            area=area,
        )


class OpenAIBrain(Brain):
    """GPT-5.6 planner using strict Responses API function tools."""

    def __init__(self, settings: Settings, catalog: ActionCatalog):
        if not os.getenv("OPENAI_API_KEY"):
            raise BrainError("GENESIS_BRAIN_MODE=openai requires OPENAI_API_KEY")
        self.settings = settings
        self.catalog = catalog
        self.client = AsyncOpenAI()
        self.identity = self._load_identity(settings.agents_dir / "sol.md")

    @staticmethod
    def _load_identity(path: Path) -> str:
        with path.open("r", encoding="utf-8") as handle:
            return handle.read().strip()

    @staticmethod
    def _observation_payload(observation: Observation, memory: List[str]) -> str:
        payload: Dict[str, Any] = observation.model_dump(mode="json")
        payload["memory"] = memory
        return json.dumps(payload, separators=(",", ":"))

    async def decide(self, observation: Observation, memory: List[str]) -> ActionCommand:
        tools = self.catalog.tools_for(observation.available_actions)
        if not tools:
            raise BrainError("the current observation exposes no callable actions")

        instructions = (
            f"{self.identity}\n\n"
            "Choose exactly one provided function. Coordinates and low-level movement "
            "are forbidden. The world may reject or fail the action, so never assume "
            "success. Base the choice only "
            "on the observation and memory. Keep intent factual and under 120 characters."
        )
        try:
            response = await self.client.responses.create(
                model=self.settings.openai_model,
                reasoning={"effort": self.settings.reasoning_effort},
                instructions=instructions,
                input=self._observation_payload(observation, memory),
                tools=tools,
                tool_choice="required",
                parallel_tool_calls=False,
                store=False,
            )
        except OpenAIError as exc:
            raise BrainError(f"OpenAI decision request failed: {exc}") from exc

        call = next(
            (item for item in response.output if getattr(item, "type", "") == "function_call"),
            None,
        )
        if call is None:
            raise BrainError("model returned no function call")

        try:
            arguments = json.loads(call.arguments)
            intent = str(arguments.pop("intent"))
            action = ActionName(call.name)
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
            raise BrainError(f"invalid function call returned by model: {exc}") from exc

        resolved_model = getattr(response, "model", self.settings.openai_model)
        return ActionCommand(
            turn=observation.turn,
            agent_id=observation.agent_id,
            action=action,
            parameters=arguments,
            intent=intent,
            source=f"openai:{resolved_model}",
        )


def create_brain(settings: Settings, catalog: ActionCatalog) -> Brain:
    mode = settings.brain_mode
    if mode == "openai" or (mode == "auto" and os.getenv("OPENAI_API_KEY")):
        return OpenAIBrain(settings, catalog)
    return DemoBrain()
