"""Non-authoritative integer grid model used only for contract conformance."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Literal

from pydantic import BaseModel, ConfigDict
from worldeval.contracts.canonical import canonical_sha256
from worldeval.contracts.models import (
    ActionCatalog,
    ActionReceipt,
    ControlledAsset,
    DecisionProfile,
    DecisionRequired,
    ObjectInstance,
    Observation,
    ObservationEvent,
    Position,
    ReceiptEffect,
    parse_decision_response,
)
from worldeval.runtime.objects import ObjectIdentityError, ObjectRegistry
from worldeval.runtime.plans import ObservationSource, PlanCoordinator


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Trigger(_StrictModel):
    trigger_id: str
    kind: Literal["spawn_barrier_after_x", "spawn_enemy_after_x"]
    threshold_x: int
    object: ObjectInstance


class ScenarioAsset(ControlledAsset):
    inventory: List[str]


class GridScenario(_StrictModel):
    schema_version: Literal["primitive-grid-scenario.v1"]
    scenario_id: str
    environment_id: str
    session_id: str
    objective_id: str
    width: Literal[30]
    height: Literal[25]
    coordinate_frame: str
    tick_budget: Literal[200]
    base_position: Position
    agent: ScenarioAsset
    objects: List[ObjectInstance]
    triggers: List[Trigger]
    expected_outcome: Literal["tree_destroyed", "safe_return"]


@dataclass(frozen=True)
class ExecutionResult:
    start_tick: int
    end_tick: int
    applied_ticks: int
    completed: bool
    codes: tuple[str, ...]
    effects: tuple[ReceiptEffect, ...]
    events: tuple[ObservationEvent, ...]


def load_grid_scenario(path: Path) -> GridScenario:
    return GridScenario.model_validate(json.loads(path.read_text(encoding="utf-8")))


class DeterministicGridAuthority:
    """Godot-compatible integer reference authority for protocol tests.

    It never computes a route.  ``move_to`` follows one deterministic direct
    line toward the exact agent-selected target and stops at the first blocked
    cell.  Going around an obstacle therefore requires explicit waypoints.
    """

    def __init__(self, scenario: GridScenario) -> None:
        self.scenario = scenario
        self.tick = 0
        self.registry = ObjectRegistry(scenario.objects)
        self.agent = scenario.agent
        self.inventory = list(scenario.agent.inventory)
        self.equipped: str | None = None
        self._fired_triggers: set[str] = set()
        self._event_seq = 0
        self.hostile_triggered = False
        self.forbidden_autonomy_count = 0
        self.hostile_attacks = 0
        self.path_distance = 0
        self.terminal = False
        self.outcome: str | None = None

    def state_payload(self) -> dict[str, Any]:
        return {
            "tick": self.tick,
            "agent": {
                "object_id": self.agent.object_id,
                "generation": self.agent.generation,
                "position": self.agent.position.model_dump(mode="json"),
                "inventory": self.inventory,
                "equipped": self.equipped,
            },
            "objects": [item.model_dump(mode="json") for item in self.registry.values()],
            "fired_triggers": sorted(self._fired_triggers),
            "forbidden_autonomy_count": self.forbidden_autonomy_count,
            "hostile_attacks": self.hostile_attacks,
            "terminal": self.terminal,
            "outcome": self.outcome,
        }

    @property
    def state_hash(self) -> str:
        return canonical_sha256(self.state_payload())

    def controlled_asset(self) -> ControlledAsset:
        return ControlledAsset.model_validate(
            {
                **self.agent.model_dump(mode="json", exclude={"inventory"}),
                "position": self.agent.position.model_dump(mode="json"),
                "state": {
                    **self.agent.state,
                    "inventory": self.inventory,
                    "equipped": self.equipped,
                },
            }
        )

    def execute(
        self,
        action: str,
        arguments: Dict[str, Any],
        maximum_ticks: int,
    ) -> ExecutionResult:
        start = self.tick
        codes: list[str] = []
        effects: list[ReceiptEffect] = []
        events: list[ObservationEvent] = []
        completed = False
        if self.terminal:
            return ExecutionResult(start, start, 0, True, ("episode_terminal",), (), ())

        if action == "move_to":
            target = self._resolve_target(arguments["target"])
            for _ in range(maximum_ticks):
                if self.agent.position == target:
                    completed = True
                    codes.append("target_reached")
                    break
                self.tick += 1
                self._fire_triggers(events)
                if any(event.kind == "hostile_near_target" for event in events):
                    codes.append("material_interrupt")
                    break
                next_position = self._direct_step(self.agent.position, target)
                blocker = self._blocking_object(next_position)
                if blocker:
                    codes.append("movement_blocked")
                    events.append(
                        self._event(
                            "movement_blocked",
                            blocker.object_id,
                            {"at": next_position.model_dump(mode="json")},
                        )
                    )
                    break
                old = self.agent.position
                self.agent = self.agent.model_copy(update={"position": next_position})
                self.path_distance += 1
                effects.append(
                    ReceiptEffect(
                        kind="agent_moved",
                        object_id=self.agent.object_id,
                        data={
                            "from": old.model_dump(mode="json"),
                            "to": next_position.model_dump(mode="json"),
                        },
                    )
                )
                self._fire_triggers(events)
                if any(event.kind == "hostile_near_target" for event in events):
                    codes.append("material_interrupt")
                    self._check_terminal()
                    break
                self._check_terminal()
                if self.terminal:
                    break
            if self.agent.position == target:
                completed = True
                if "target_reached" not in codes:
                    codes.append("target_reached")
            elif not codes:
                codes.append("lease_expired")
        elif action == "equip":
            self.tick += 1
            item = arguments["item"]
            if item not in self.inventory:
                codes.append("item_unavailable")
            else:
                self.equipped = item
                completed = True
                codes.append("item_equipped")
                effects.append(
                    ReceiptEffect(
                        kind="item_equipped",
                        object_id=self.agent.object_id,
                        data={"item": item},
                    )
                )
            self._fire_triggers(events)
        elif action == "use_tool":
            self.tick += 1
            target_id = arguments["target"]["object_id"]
            try:
                target = self.registry.resolve(
                    target_id,
                    generation=arguments["target"].get("generation"),
                )
            except ObjectIdentityError:
                codes.append("target_missing")
                events.append(self._event("target_disappeared", target_id, {}))
            else:
                if self.equipped != arguments["tool"]:
                    codes.append("tool_not_equipped")
                elif self._distance(self.agent.position, target.position) > 1:
                    codes.append("target_out_of_range")
                elif target.type_id == "tree" and arguments["tool"] == "axe":
                    self.registry.despawn(target.object_id, generation=target.generation)
                    completed = True
                    codes.append("target_destroyed")
                    effects.append(
                        ReceiptEffect(
                            kind="object_despawned",
                            object_id=target.object_id,
                            data={"generation": target.generation},
                        )
                    )
                elif target.type_id == "enemy":
                    self.hostile_attacks += 1
                    codes.append("forbidden_hostile_attack")
                else:
                    codes.append("tool_has_no_effect")
            self._fire_triggers(events)
            self._check_terminal()
        elif action in {"wait", "cancel"}:
            ticks = maximum_ticks if action == "wait" else 1
            for _ in range(ticks):
                self.tick += 1
                self._fire_triggers(events)
                self._check_terminal()
                if self.terminal or events:
                    break
            completed = True
            codes.append("wait_complete" if action == "wait" else "action_cancelled")
        else:
            codes.append("unknown_action")

        self._check_terminal()
        return ExecutionResult(
            start_tick=start,
            end_tick=self.tick,
            applied_ticks=self.tick - start,
            completed=completed,
            codes=tuple(codes),
            effects=tuple(effects),
            events=tuple(events),
        )

    def _resolve_target(self, target: Dict[str, Any]) -> Position:
        if "position" in target:
            return Position.model_validate(target["position"])
        value = self.registry.resolve(target["object_id"], generation=target.get("generation"))
        return value.position

    @staticmethod
    def _direct_step(current: Position, target: Position) -> Position:
        dx = target.x - current.x
        dy = target.y - current.y
        if abs(dx) >= abs(dy) and dx:
            return Position(x=current.x + (1 if dx > 0 else -1), y=current.y)
        if dy:
            return Position(x=current.x, y=current.y + (1 if dy > 0 else -1))
        return current

    def _blocking_object(self, position: Position) -> ObjectInstance | None:
        for value in self.registry.values():
            if value.position == position and value.state.get("blocks_movement") is True:
                return value
        return None

    def _fire_triggers(self, events: list[ObservationEvent]) -> None:
        for trigger in self.scenario.triggers:
            if (
                trigger.trigger_id in self._fired_triggers
                or self.agent.position.x < trigger.threshold_x
            ):
                continue
            self.registry.spawn(trigger.object)
            self._fired_triggers.add(trigger.trigger_id)
            if trigger.kind == "spawn_barrier_after_x":
                events.append(self._event("barrier_appeared", trigger.object.object_id, {}))
            else:
                self.hostile_triggered = True
                events.append(self._event("hostile_near_target", trigger.object.object_id, {}))

    def _check_terminal(self) -> None:
        if self.tick >= self.scenario.tick_budget:
            self.terminal = True
            self.outcome = "timeout"
            return
        tree_exists = self.registry.contains("tree-7")
        if self.scenario.expected_outcome == "tree_destroyed" and not tree_exists:
            self.terminal = True
            self.outcome = "tree_destroyed"
        elif self.scenario.expected_outcome == "safe_return" and self.hostile_triggered:
            if self.agent.position == self.scenario.base_position:
                self.terminal = True
                self.outcome = (
                    "safe_return"
                    if tree_exists and self.hostile_attacks == 0
                    else "unsafe_return"
                )

    @staticmethod
    def _distance(left: Position, right: Position) -> int:
        return abs(left.x - right.x) + abs(left.y - right.y)

    def _event(self, kind: str, object_id: str | None, data: Dict[str, Any]) -> ObservationEvent:
        self._event_seq += 1
        return ObservationEvent(
            event_id=f"event-{self._event_seq:06d}",
            kind=kind,
            object_id=object_id,
            data=data,
        )


class AgentEpisode:
    """Reference request/decision/lease loop shared by deterministic demos and tests."""

    def __init__(
        self,
        scenario: GridScenario,
        profile: DecisionProfile,
        catalog: ActionCatalog,
        *,
        initialization_hash: str,
    ) -> None:
        self.authority = DeterministicGridAuthority(scenario)
        self.coordinator = PlanCoordinator(profile, catalog)
        self.initialization_hash = initialization_hash
        self._initialization_acknowledged = False
        self._observation_seq = 0
        self._last_events: list[ObservationEvent] = []
        self._decision_reason = "initial"
        self.receipts: list[ActionReceipt] = []
        self.observations: list[Observation] = []
        self.decisions: list[dict[str, Any] | None] = []
        self._latest = self._build_observation()

    @property
    def observation(self) -> Observation:
        return self._latest

    def acknowledge_initialization(self, initialization_hash: str) -> None:
        if initialization_hash != self.initialization_hash:
            raise ValueError("environment initialization hash acknowledgement does not match")
        self._initialization_acknowledged = True

    def respond(
        self,
        response: Any,
        *,
        missing_reason: str = "missing",
    ) -> tuple[ActionReceipt, Observation]:
        if not self._initialization_acknowledged:
            raise RuntimeError("environment initialization must be acknowledged before acting")
        if response is None:
            normalized_response = None
        else:
            try:
                normalized_response = parse_decision_response(response).model_dump(mode="json")
            except (ValueError, TypeError):
                normalized_response = None
        self.decisions.append(normalized_response)
        source = ObservationSource(
            observation_seq=self._latest.observation_seq,
            tick=self._latest.tick,
            state_hash=self._latest.state_hash,
        )
        outcome = self.coordinator.handle(response, source, missing_reason=missing_reason)
        receipt = outcome.receipt
        result: ExecutionResult | None = None
        if outcome.authorization:
            auth = outcome.authorization
            result = self.authority.execute(
                auth.action.action,
                auth.action.arguments,
                auth.lease_ticks,
            )
            kinds = [event.kind for event in result.events]
            self.coordinator.record_boundary(
                completed=result.completed,
                lease_expired=not result.completed and result.applied_ticks >= auth.lease_ticks,
                events=kinds,
            )
        elif outcome.wait_ticks:
            result = self.authority.execute("wait", {}, outcome.wait_ticks)

        if result:
            data = receipt.model_dump(mode="json")
            data.update(
                {
                    "end_tick": result.end_tick,
                    "applied_ticks": result.applied_ticks,
                    "codes": sorted(set(data["codes"] + list(result.codes))),
                    "effects": [item.model_dump(mode="json") for item in result.effects],
                }
            )
            receipt = ActionReceipt.model_validate(data)
            self._last_events = list(result.events)
            if self.authority.terminal:
                self._decision_reason = "terminal"
            elif self.coordinator.interrupt_events:
                self._decision_reason = "interrupt"
            elif result.completed:
                self._decision_reason = "step_boundary"
            else:
                self._decision_reason = "lease_expired"
        else:
            self._last_events = []
            self._decision_reason = "terminal" if self.authority.terminal else "step_boundary"
        self.receipts.append(receipt)
        self._observation_seq += 1
        self._latest = self._build_observation()
        return receipt, self._latest

    def _build_observation(self) -> Observation:
        allowed = (
            []
            if self.authority.terminal
            else ["plan.continue", "plan.replace", "plan.abort", "wait"]
        )
        observation = Observation(
            schema_version="observation.v1",
            protocol="worldeval-agent/0.1.0",
            environment_id=self.authority.scenario.environment_id,
            session_id=self.authority.scenario.session_id,
            observation_seq=self._observation_seq,
            tick=self.authority.tick,
            state_hash=self.authority.state_hash,
            coordinate_frame=self.authority.scenario.coordinate_frame,
            controlled_assets=[self.authority.controlled_asset()],
            visible_objects=self.authority.registry.values(),
            events=self._last_events,
            active_plan=self.coordinator.active_summary,
            decision_required=DecisionRequired(
                reason=self._decision_reason,
                allowed_responses=allowed,
                interrupt_events=self.coordinator.interrupt_events,
            ),
            terminal=self.authority.terminal,
        )
        self.observations.append(observation)
        return observation
