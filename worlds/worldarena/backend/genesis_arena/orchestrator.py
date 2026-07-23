from __future__ import annotations

import asyncio
import time
from collections import deque
from typing import Deque, Dict, List

from .brain import Brain, BrainError, DemoBrain, OpenAIBrain, create_brain
from .catalog import ActionCatalog, ActionValidationError
from .config import Settings
from .memory import MemoryStore
from .models import ActionCommand, DecisionTrace, Observation, SimulationConfig


class Orchestrator:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.catalog = ActionCatalog(settings.action_catalog_path)
        self.memory = MemoryStore(settings.memory_dir)
        self.brain: Brain = create_brain(settings, self.catalog)
        self.brains: Dict[str, Brain] = {}
        self.models: Dict[str, str] = {}
        self.fallback = DemoBrain()
        self.traces: Deque[DecisionTrace] = deque(maxlen=100)

    @property
    def provider_name(self) -> str:
        if self.models:
            return f"{len(self.models)} OpenAI competitors"
        return self.brain.__class__.__name__

    def configure(self, config: SimulationConfig) -> Dict[str, str]:
        agent_ids = [entry.agent_id for entry in config.agents]
        if len(set(agent_ids)) != len(agent_ids):
            raise ValueError("agent IDs must be unique")

        brains: Dict[str, Brain] = {}
        models: Dict[str, str] = {}
        for entry in config.agents:
            identity_path = self.settings.agents_dir / f"{entry.agent_id}.md"
            if not identity_path.exists():
                identity_path = self.settings.agents_dir / "sol.md"
            brains[entry.agent_id] = OpenAIBrain(
                self.settings,
                self.catalog,
                api_key=config.api_key,
                model=entry.model,
                reasoning_effort=entry.reasoning_effort,
                identity_path=identity_path,
            )
            models[entry.agent_id] = entry.model

        self.brains = brains
        self.models = models
        return dict(models)

    def _brain_for(self, agent_id: str) -> Brain:
        return self.brains.get(agent_id, self.brain)

    def provider_for(self, agent_id: str) -> str:
        brain = self._brain_for(agent_id)
        return getattr(brain, "provider_name", brain.__class__.__name__)

    async def decide(self, observation: Observation) -> ActionCommand:
        self.memory.learn(observation)
        facts = self.memory.load(observation.agent_id)
        started = time.perf_counter()
        error = ""
        brain = self._brain_for(observation.agent_id)
        source = self.provider_for(observation.agent_id)

        try:
            command = await asyncio.wait_for(
                brain.decide(observation, facts),
                timeout=self.settings.decision_timeout_seconds,
            )
            self.catalog.validate(command, observation)
        except (asyncio.TimeoutError, BrainError, ActionValidationError, RuntimeError) as exc:
            error = str(exc) or exc.__class__.__name__
            command = await self.fallback.decide(observation, facts)
            self.catalog.validate(command, observation)
            command.source = f"fallback:{command.source}"

        latency_ms = (time.perf_counter() - started) * 1000
        self.traces.append(
            DecisionTrace(
                turn=observation.turn,
                agent_id=observation.agent_id,
                action=command.action.value,
                valid=True,
                source=source,
                latency_ms=latency_ms,
                error=error,
            )
        )
        return command

    def state(self) -> Dict[str, object]:
        recent: List[Dict[str, object]] = [trace.model_dump() for trace in self.traces]
        return {
            "brain": self.provider_name,
            "models": dict(self.models),
            "catalog_version": self.catalog.version,
            "enabled_actions": self.catalog.enabled_names,
            "recent_decisions": recent,
        }
