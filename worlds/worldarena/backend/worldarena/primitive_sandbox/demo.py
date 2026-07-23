"""Credential-free agent policy that uses the public interactive session surface."""

from __future__ import annotations

from typing import Any, Mapping

PROTOCOL = "worldeval-agent/0.1.0"


class PrimitiveSandboxDemoAgent:
    """Emit only visible protocol decisions; it has no gameplay authority."""

    def __init__(self) -> None:
        self._aborted_unsafe_plan = False

    def decide(self, observation: Mapping[str, Any]) -> Mapping[str, Any]:
        events = {
            str(event["kind"])
            for event in observation.get("events", ())
            if isinstance(event, Mapping) and isinstance(event.get("kind"), str)
        }
        active = observation.get("active_plan")
        if active is None:
            if self._aborted_unsafe_plan:
                return _replace(observation, "return-to-base", _return_steps(), None)
            return _replace(
                observation,
                "approach-equip-chop",
                _tree_steps(),
                None,
            )
        if not isinstance(active, Mapping) or not isinstance(active.get("plan_id"), str):
            raise RuntimeError("Demo agent received a malformed active plan")
        active_plan_id = str(active["plan_id"])
        if "hostile_near_target" in events:
            self._aborted_unsafe_plan = True
            return {
                "type": "plan.abort",
                "plan_id": active_plan_id,
                "source": _source(observation),
                "reason": (
                    "Hostile now occupies the protected target radius; retreat is required."
                ),
            }
        if "movement_blocked" in events:
            return _replace(
                observation,
                "explicit-barrier-detour",
                _detour_steps(),
                active_plan_id,
            )
        return {
            "type": "plan.continue",
            "plan_id": active_plan_id,
            "source": _source(observation),
            "lease_ticks": 3,
        }


def _replace(
    observation: Mapping[str, Any],
    plan_id: str,
    steps: list[Mapping[str, Any]],
    replaces: str | None,
) -> Mapping[str, Any]:
    return {
        "type": "plan.replace",
        "replaces_plan_id": replaces,
        "plan": {
            "schema_version": "action-plan.v1",
            "protocol": PROTOCOL,
            "plan_id": plan_id,
            "source": _source(observation),
            "lease_ticks": 3,
            "execution_policy": "confirm_each_boundary",
            "steps": steps,
            "abort_behavior": "cancel_current_action",
        },
    }


def _source(observation: Mapping[str, Any]) -> Mapping[str, Any]:
    return {
        "observation_seq": observation["observation_seq"],
        "tick": observation["tick"],
        "state_hash": observation["state_hash"],
    }


def _tree_steps() -> list[Mapping[str, Any]]:
    return [
        _step(
            "approach-tree",
            "move_to",
            {
                "target": {"object_id": "tree-7", "generation": 1},
                "navigation": "direct_only",
            },
            [{"kind": "target_visible", "subject": "tree-7", "parameters": {}}],
            {"kind": "agent_at_target", "subject": "tree-7", "parameters": {}},
            ["movement_blocked", "target_disappeared", "hostile_near_target"],
        ),
        _step(
            "equip-axe",
            "equip",
            {"item": "axe"},
            [
                {
                    "kind": "item_in_inventory",
                    "subject": "worker-1",
                    "parameters": {"item": "axe"},
                }
            ],
            {
                "kind": "item_equipped",
                "subject": "worker-1",
                "parameters": {"item": "axe"},
            },
            ["inventory_changed"],
        ),
        _step(
            "chop-tree",
            "use_tool",
            {"tool": "axe", "target": {"object_id": "tree-7", "generation": 1}},
            [
                {
                    "kind": "target_in_range",
                    "subject": "tree-7",
                    "parameters": {},
                }
            ],
            {
                "kind": "object_destroyed",
                "subject": "tree-7",
                "parameters": {"generation": 1},
            },
            ["target_disappeared", "hostile_near_target"],
        ),
    ]


def _detour_steps() -> list[Mapping[str, Any]]:
    return [
        _step(
            "waypoint-south",
            "move_to",
            {
                "target": {"position": {"x": 11, "y": 11}},
                "navigation": "direct_only",
            },
            [],
            {
                "kind": "agent_at_coordinate",
                "subject": "worker-1",
                "parameters": {"x": 11, "y": 11},
            },
            ["movement_blocked", "hostile_near_target"],
        ),
        _step(
            "waypoint-past-barrier",
            "move_to",
            {
                "target": {"position": {"x": 14, "y": 11}},
                "navigation": "direct_only",
            },
            [],
            {
                "kind": "agent_at_coordinate",
                "subject": "worker-1",
                "parameters": {"x": 14, "y": 11},
            },
            ["movement_blocked", "hostile_near_target"],
        ),
    ]


def _return_steps() -> list[Mapping[str, Any]]:
    return [
        _step(
            "return-base",
            "move_to",
            {
                "target": {"object_id": "base-1", "generation": 1},
                "navigation": "direct_only",
            },
            [{"kind": "target_visible", "subject": "base-1", "parameters": {}}],
            {
                "kind": "agent_at_target",
                "subject": "base-1",
                "parameters": {},
            },
            ["movement_blocked", "health_threshold_crossed"],
        )
    ]


def _step(
    step_id: str,
    action: str,
    arguments: Mapping[str, Any],
    preconditions: list[Mapping[str, Any]],
    expected_completion: Mapping[str, Any],
    interrupt_on: list[str],
) -> Mapping[str, Any]:
    return {
        "step_id": step_id,
        "action": {"action": action, "arguments": arguments},
        "preconditions": preconditions,
        "expected_completion": expected_completion,
        "interrupt_on": interrupt_on,
    }


__all__ = ["PrimitiveSandboxDemoAgent"]
