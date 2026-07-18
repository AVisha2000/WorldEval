from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List

from .models import Observation


class MemoryStore:
    """A compact fact store. It intentionally does not preserve full transcripts."""

    MAX_FACTS = 12
    IMPORTANT_TERMS = (
        "built",
        "failed",
        "discovered",
        "depleted",
        "winter",
        "storm",
        "attacked",
        "alliance",
        "survived",
    )

    def __init__(self, directory: Path):
        self.directory = directory
        self.directory.mkdir(parents=True, exist_ok=True)

    def _path(self, agent_id: str) -> Path:
        safe_id = "".join(
            character for character in agent_id.lower() if character.isalnum() or character == "_"
        )
        if not safe_id:
            raise ValueError("agent_id must contain at least one safe character")
        return self.directory / f"{safe_id}.json"

    def load(self, agent_id: str) -> List[str]:
        path = self._path(agent_id)
        if not path.exists():
            return []
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        return [str(fact) for fact in payload.get("memory", [])][-self.MAX_FACTS :]

    def append(self, agent_id: str, fact: str) -> None:
        concise = " ".join(fact.strip().split())[:180]
        if not concise:
            return
        facts = self.load(agent_id)
        if concise in facts:
            return
        facts.append(concise)
        payload: Dict[str, object] = {"agent_id": agent_id, "memory": facts[-self.MAX_FACTS :]}
        path = self._path(agent_id)
        temporary = path.with_suffix(".json.tmp")
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        temporary.replace(path)

    def learn(self, observation: Observation) -> None:
        for event in observation.events:
            if any(term in event.lower() for term in self.IMPORTANT_TERMS):
                self.append(observation.agent_id, f"Day {observation.day}: {event}")
