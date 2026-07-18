from __future__ import annotations

import asyncio
import time
from collections import deque
from typing import Deque, Dict, List

from .brain import Brain, BrainError, DemoBrain, create_brain
from .catalog import ActionCatalog, ActionValidationError
from .config import Settings
from .memory import MemoryStore
from .models import ActionCommand, DecisionTrace, Observation


class Orchestrator:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.catalog = ActionCatalog(settings.action_catalog_path)
        self.memory = MemoryStore(settings.memory_dir)
        self.brain: Brain = create_brain(settings, self.catalog)
        self.fallback = DemoBrain()
        self.traces: Deque[DecisionTrace] = deque(maxlen=100)

    @property
    def provider_name(self) -> str:
        return self.brain.__class__.__name__

    async def decide(self, observation: Observation) -> ActionCommand:
        self.memory.learn(observation)
        facts = self.memory.load(observation.agent_id)
        started = time.perf_counter()
        error = ""
        source = self.provider_name

        try:
            command = await asyncio.wait_for(
                self.brain.decide(observation, facts),
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
            "catalog_version": self.catalog.version,
            "enabled_actions": self.catalog.enabled_names,
            "recent_decisions": recent,
        }
