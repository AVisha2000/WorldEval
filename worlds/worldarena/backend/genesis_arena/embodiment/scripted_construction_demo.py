"""Deterministic, credential-free Construction presentation demo.

This is deliberately a local *demo* controller, not a scored entrant and not a fallback for a
live provider.  It emits the same strict ``construction-task-plan`` JSON a model must emit, then
the normal :class:`ConstructionTaskProvider` expands that plan into controller actions for Godot.
"""

from __future__ import annotations

from typing import Any, Mapping

from .protocol import canonical_json_bytes, strict_json_loads
from .providers.contracts import ProviderCallResult, ProviderRequest, ProviderTelemetry

SCRIPTED_CONSTRUCTION_PROVIDER = "scripted"
SCRIPTED_CONSTRUCTION_MODEL = "construction-demo-v1"
SCRIPTED_CONSTRUCTION_TASK = "construction-v0"

# Godot executes one authoritative tick every 100 ms.  The planner starts the final short build
# approach late enough that the terminal result normally lands just under two minutes, while the
# 1,300-tick episode budget retains enough room for a deterministic safety margin.
DEMO_TARGET_DURATION_TICKS = 1_200
# The late approach includes three turns, twelve movement ticks, a final facing correction, and
# six construction ticks in the fixed Stage-C map.  Keep a small deterministic allowance rather
# than relying on wall-clock render timing.
DEMO_FINAL_BUILD_BUDGET_TICKS = 24
DEMO_BUILD_START_TICK = DEMO_TARGET_DURATION_TICKS - DEMO_FINAL_BUILD_BUDGET_TICKS
DEMO_MINIMUM_EPISODE_TICKS = 1_300


class ScriptedConstructionDemoProvider:
    """A deterministic planner for the local Construction demonstration.

    The selection uses only the player-visible task state: inventory, visible entity states, and
    the visible authority tick.  It deliberately does not receive credentials, prompts, hidden
    positions, or spectator data.
    """

    provider_name = SCRIPTED_CONSTRUCTION_PROVIDER

    def __init__(self, *, showcase: bool = False) -> None:
        self._showcase = showcase

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        try:
            observation = strict_json_loads(request.observation_json)
            if not isinstance(observation, Mapping):
                raise ValueError("observation is not an object")
            task = _next_task(observation, showcase=self._showcase)
        except (TypeError, ValueError, KeyError):
            # The ordinary live runner records this through its normal neutral-window policy.
            from .providers.contracts import ProviderFailureKind

            return ProviderCallResult.failed(
                ProviderFailureKind.INVALID_RESPONSE, ProviderTelemetry(0)
            )
        plan = {
            "protocol_version": "llm-controller/0.1.0",
            "episode_id": request.episode_id,
            "observation_seq": request.observation_seq,
            "task_id": task,
            "intent_label": _intent_label(task),
            "memory_update": "",
        }
        return ProviderCallResult.success(canonical_json_bytes(plan), ProviderTelemetry(0))


def demo_task_timeout_ticks(task: str, observation: Mapping[str, Any]) -> int:
    """Return the bounded local executor horizon for one demo milestone.

    The public task contract has a deliberately short default ``wait`` policy for live models.
    In this demo only, one visible wait milestone occupies the presentation interval until the
    late build phase.  It remains bounded, is deterministic, and cannot affect authority scoring
    because the scripted provider is rejected outside this dedicated demo route.
    """

    if task != "wait":
        return 180
    tick = observation.get("tick")
    if isinstance(tick, bool) or not isinstance(tick, int) or tick < 0:
        return 10
    return max(1, DEMO_BUILD_START_TICK - tick)


def _next_task(observation: Mapping[str, Any], *, showcase: bool = False) -> str:
    entities = observation.get("visible_entities")
    if not isinstance(entities, list):
        raise ValueError("visible entities are absent")
    states = {
        item.get("id"): item.get("state")
        for item in entities
        if isinstance(item, Mapping)
        and isinstance(item.get("id"), str)
        and isinstance(item.get("state"), str)
    }
    self_state = observation.get("self")
    if not isinstance(self_state, Mapping):
        raise ValueError("self state is absent")
    inventory = self_state.get("inventory")
    if not isinstance(inventory, list):
        raise ValueError("inventory is absent")
    carrying = any(
        isinstance(item, Mapping)
        and item.get("kind") == "material"
        and isinstance(item.get("count"), int)
        and not isinstance(item.get("count"), bool)
        and item["count"] > 0
        for item in inventory
    )
    tick = observation.get("tick")
    if isinstance(tick, bool) or not isinstance(tick, int) or tick < 0:
        raise ValueError("tick is invalid")

    # Make two visibly complete gather-and-deliver cycles while material remains.  This gives the
    # demo a substantive opening rather than a static countdown before construction.
    if carrying and states.get("v_relay_1") in {"empty", "materials_present", "materials_ready"}:
        return "deliver_materials"
    if states.get("v_resource_1") == "available":
        return "gather_materials"
    if states.get("v_build_pad_1") == "ready" and (
        not showcase or tick >= DEMO_BUILD_START_TICK
    ):
        return "build_barricade"
    return "wait"


def _intent_label(task: str) -> str:
    return {
        "gather_materials": "Demo: gather visible materials",
        "deliver_materials": "Demo: deliver carried materials",
        "build_barricade": "Demo: construct the barricade",
        "wait": "Demo: stage the construction finale",
    }[task]


__all__ = [
    "DEMO_BUILD_START_TICK",
    "DEMO_FINAL_BUILD_BUDGET_TICKS",
    "DEMO_MINIMUM_EPISODE_TICKS",
    "DEMO_TARGET_DURATION_TICKS",
    "SCRIPTED_CONSTRUCTION_MODEL",
    "SCRIPTED_CONSTRUCTION_PROVIDER",
    "SCRIPTED_CONSTRUCTION_TASK",
    "ScriptedConstructionDemoProvider",
    "demo_task_timeout_ticks",
]
