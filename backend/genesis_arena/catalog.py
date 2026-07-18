from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Iterable, List

from .models import ActionCommand, Observation


class ActionValidationError(ValueError):
    """Raised when a brain requests an action that reality cannot accept."""


class ActionCatalog:
    def __init__(self, path: Path):
        self.path = path
        with path.open("r", encoding="utf-8") as handle:
            document = json.load(handle)
        self.version = str(document["version"])
        self.actions: Dict[str, Dict[str, Any]] = document["actions"]

    @property
    def enabled_names(self) -> List[str]:
        return [name for name, spec in self.actions.items() if spec.get("enabled")]

    def tools_for(self, names: Iterable[str]) -> List[Dict[str, Any]]:
        enabled = set(names)
        tools: List[Dict[str, Any]] = []
        for name, spec in self.actions.items():
            if name not in enabled or not spec.get("enabled"):
                continue
            tools.append(
                {
                    "type": "function",
                    "name": name,
                    "description": spec["description"],
                    "parameters": {
                        "type": "object",
                        "properties": spec.get("parameters", {}),
                        "required": spec.get("required", []),
                        "additionalProperties": False,
                    },
                    "strict": True,
                }
            )
        return tools

    def building_cost(self, structure: str) -> Dict[str, int]:
        costs = self.actions["build"].get("costs", {})
        return {name: int(amount) for name, amount in costs.get(structure, {}).items()}

    def validate(self, command: ActionCommand, observation: Observation) -> None:
        name = command.action.value
        if name not in observation.available_actions:
            raise ActionValidationError(f"{name!r} is not enabled in this observation")

        spec = self.actions.get(name)
        if not spec or not spec.get("enabled"):
            raise ActionValidationError(f"{name!r} is not enabled by the controller")

        supplied = {**command.parameters, "intent": command.intent}
        allowed = spec.get("parameters", {})
        unknown = set(supplied) - set(allowed)
        if unknown and not spec.get("additionalProperties", False):
            raise ActionValidationError(f"unexpected parameters: {sorted(unknown)}")

        missing = set(spec.get("required", [])) - set(supplied)
        if missing:
            raise ActionValidationError(f"missing parameters: {sorted(missing)}")

        for key, value in supplied.items():
            rule = allowed.get(key, {})
            if rule.get("type") == "string" and not isinstance(value, str):
                raise ActionValidationError(f"{key!r} must be a string")
            if "enum" in rule and value not in rule["enum"]:
                raise ActionValidationError(f"{key!r} must be one of {rule['enum']}")
            if isinstance(value, str):
                if len(value) < rule.get("minLength", 0):
                    raise ActionValidationError(f"{key!r} is too short")
                if len(value) > rule.get("maxLength", 10_000):
                    raise ActionValidationError(f"{key!r} is too long")

        if name == "collect":
            kind = command.parameters["resource"]
            available = any(
                resource.kind.value == kind and resource.quantity > 0
                for resource in observation.visible_resources
            )
            if not available:
                raise ActionValidationError(f"no visible {kind} source is available")

        if name == "build":
            structure = command.parameters["structure"]
            cost = self.building_cost(structure)
            if not cost:
                raise ActionValidationError(f"no cost is defined for {structure}")
            for resource, required in cost.items():
                held = observation.agent.inventory.get(resource, 0)
                if held < required:
                    raise ActionValidationError(
                        f"building {structure} needs {required} {resource}; agent has {held}"
                    )
