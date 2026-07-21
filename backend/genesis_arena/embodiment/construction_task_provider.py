"""Construction-only task planner that keeps continuous controller execution in Godot."""

from __future__ import annotations

from dataclasses import replace
from typing import Any, Callable, Mapping

from .demo_provider import DemoPolicyLock
from .protocol import EmbodimentProtocolPackage, canonical_json_bytes, strict_json_loads
from .providers.contracts import (
    InMemoryProviderAuditLog,
    ProviderAdapter,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)

TASKS = frozenset(("gather_materials", "deliver_materials", "build_barricade", "wait"))
TaskTimeoutPolicy = Callable[[str, Mapping[str, Any]], int]
TASK_PROMPT = """You choose the next Construction milestone for one WorldArena operator.
Use only the supplied participant-visible observation and camera. Return exactly one JSON object.
Match the supplied task-plan schema. Choose gather_materials to collect a full load, or
deliver_materials to take carried material to the relay. Choose build_barricade only when the pad
is ready, or wait when no safe productive milestone is available. Godot executes walking, turning,
and animation continuously."""


class ConstructionTaskProvider:
    """Turn one model milestone into a bounded sequence of local one-tick actions.

    The wrapped provider is contacted only after a task resolves or its deterministic timeout
    expires. Generated controls deliberately pass through the normal authority/replay boundary.
    """

    provider_name: str

    def __init__(
        self,
        provider: ProviderAdapter,
        package: EmbodimentProtocolPackage,
        *,
        task_timeout_ticks: TaskTimeoutPolicy | None = None,
    ) -> None:
        if task_timeout_ticks is not None and not callable(task_timeout_ticks):
            raise TypeError("task_timeout_ticks must be callable")
        self._provider = provider
        self._package = package
        self.provider_name = provider.provider_name
        self._task: str | None = None
        self._task_ticks = 0
        self._task_tick_limit = 0
        self._task_timeout_ticks = task_timeout_ticks or _default_task_timeout_ticks
        # The runner uses this bounded signal only to avoid duplicating protected provider
        # evidence for a controller action which was generated locally.  Authority replay still
        # records every resulting decision window and receipt.
        self._last_request_was_continuation = False

    @property
    def last_request_was_continuation(self) -> bool:
        """Whether the most recent response reused the active local task.

        This is deliberately state-local rather than part of the provider result contract: it
        must never reach a model, player observation, dashboard route, or replay payload.
        """

        return self._last_request_was_continuation

    @property
    def policy_lock(self) -> DemoPolicyLock | None:
        """Expose only an immutable inner Demo lock for run-configuration evidence."""

        value = getattr(self._provider, "policy_lock", None)
        return value if isinstance(value, DemoPolicyLock) else None

    @property
    def audit_log(self) -> InMemoryProviderAuditLog | None:
        """Expose the inner adapter audit log without copying or rewriting its request."""

        value = getattr(self._provider, "audit_log", None)
        return value if isinstance(value, InMemoryProviderAuditLog) else None

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self._last_request_was_continuation = False
        observation = strict_json_loads(request.observation_json)
        if not isinstance(observation, dict):
            return _invalid()
        if self._task is not None and not self._task_resolved(observation):
            self._task_ticks += 1
            if self._task_ticks <= self._task_tick_limit:
                self._last_request_was_continuation = True
                return _generated(request, self._task)
            self._clear_task()
        planned_request = replace(
            request,
            system_prompt=TASK_PROMPT,
            action_schema_json=canonical_json_bytes(self._package.schema("construction-task-plan")),
        )
        result = await self._provider.request(planned_request)
        if result.raw_output is None:
            return result
        try:
            value = strict_json_loads(result.raw_output)
            if not isinstance(value, dict):
                raise ValueError("task plan is not an object")
            self._package.validate("construction-task-plan", value)
            if (
                value["episode_id"] != request.episode_id
                or value["observation_seq"] != request.observation_seq
            ):
                raise ValueError("task plan boundary mismatch")
            task = str(value["task_id"])
            if task not in TASKS or not _task_visible_and_valid(task, observation):
                raise ValueError("task is not visible or valid")
        except Exception:
            return ProviderCallResult.failed(ProviderFailureKind.INVALID_RESPONSE, result.telemetry)
        try:
            task_tick_limit = self._task_timeout_ticks(task, observation)
        except Exception:
            return ProviderCallResult.failed(ProviderFailureKind.INTERNAL, result.telemetry)
        if (
            isinstance(task_tick_limit, bool)
            or not isinstance(task_tick_limit, int)
            or not 1 <= task_tick_limit <= 1_800
        ):
            return ProviderCallResult.failed(ProviderFailureKind.INTERNAL, result.telemetry)
        self._task = task
        self._task_ticks = 1
        self._task_tick_limit = task_tick_limit
        return _generated(request, task, telemetry=result.telemetry)

    def _task_resolved(self, observation: Mapping[str, Any]) -> bool:
        previous = observation.get("previous_receipt")
        if isinstance(previous, Mapping) and "autonomous_task_complete" in previous.get(
            "codes", []
        ):
            self._clear_task()
            return True
        terminal = observation.get("terminal")
        if isinstance(terminal, Mapping) and bool(terminal.get("ended", False)):
            self._clear_task()
            return True
        return False

    def _clear_task(self) -> None:
        self._task = None
        self._task_ticks = 0
        self._task_tick_limit = 0

    async def aclose(self) -> None:
        close = getattr(self._provider, "aclose", None)
        if callable(close):
            result = close()
            if hasattr(result, "__await__"):
                await result


def _task_visible_and_valid(task: str, observation: Mapping[str, Any]) -> bool:
    entities = observation.get("visible_entities")
    if not isinstance(entities, list):
        return False
    states = {
        str(item.get("id")): str(item.get("state"))
        for item in entities
        if isinstance(item, Mapping)
    }
    inventory = observation.get("self", {}).get("inventory", [])
    carrying = bool(inventory)
    if task == "gather_materials":
        return states.get("v_resource_1") == "available" and not carrying
    if task == "deliver_materials":
        return "v_relay_1" in states and carrying
    if task == "build_barricade":
        return states.get("v_build_pad_1") == "ready"
    return task == "wait"


def _default_task_timeout_ticks(task: str, _observation: Mapping[str, Any]) -> int:
    return 10 if task == "wait" else 180


def _generated(
    request: ProviderRequest, task: str, *, telemetry: ProviderTelemetry | None = None
) -> ProviderCallResult:
    value = {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": request.episode_id,
        "observation_seq": request.observation_seq,
        "action_id": f"task_{task}_{request.observation_seq}",
        "control": {
            "move_x": 0,
            "move_y": 0,
            "look_x": 0,
            "look_y": 0,
            "duration_ticks": 1,
            "autonomous_task": task,
            "buttons": {
                "interact": False,
                "primary": False,
                "guard": False,
                "dash": False,
                "ability_1": False,
                "ability_2": False,
                "cycle_item": False,
                "cancel": False,
            },
        },
        "intent_label": task.replace("_", " "),
        "memory_update": "",
    }
    return ProviderCallResult.success(
        canonical_json_bytes(value), telemetry or ProviderTelemetry(0)
    )


def _invalid() -> ProviderCallResult:
    return ProviderCallResult.failed(ProviderFailureKind.INVALID_RESPONSE, ProviderTelemetry(0))
