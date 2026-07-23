"""Visible-only, credential-free Sol/Luna/Terra policies for trio games."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping

from ..contracts import ControllerButtons, ControllerState
from ..demo_provider import DemoPolicyLock, DemoProvider
from ..protocol import canonical_json_bytes
from ..providers.contracts import ProviderAuditRecord, ProviderFailureKind, ProviderRequest
from .common import (
    FIXED_TRIO_WINDOW_TICKS,
    TrioFixtureMode,
    TrioResolvedDecision,
    encode_action,
    fixture_value,
    move_or_turn_toward,
    neutral_action,
    parse_trio_action,
    parse_visible_observation,
    select_visible_entity,
    validate_fixture_mode,
)
from .scheduling import TRIO_DEMO_ENTRANTS, TRIO_TASK_IDS, TrioTaskId


@dataclass(frozen=True)
class TrioPolicySpec:
    task_id: TrioTaskId
    display_name: str
    model: str
    policy_id: str
    policy_version: str
    style: str


def _specs() -> Mapping[tuple[str, str], TrioPolicySpec]:
    values: dict[tuple[str, str], TrioPolicySpec] = {}
    for task_id in sorted(TRIO_TASK_IDS):
        for entrant in TRIO_DEMO_ENTRANTS:
            style = {"Sol": "objective", "Luna": "defensive", "Terra": "pressure"}[
                entrant.display_name
            ]
            values[(task_id, entrant.model)] = TrioPolicySpec(
                task_id=task_id,
                display_name=entrant.display_name,
                model=entrant.model,
                policy_id=f"{entrant.policy_id}-{task_id}",
                policy_version="1.0.0",
                style=style,
            )
    return MappingProxyType(values)


TRIO_POLICY_SPECS = _specs()


class TrioDemoSeatController:
    """Normal provider boundary plus permanent, call-free eliminated disposition."""

    provider_name = "demo"
    requires_credential = False
    is_networked = False

    def __init__(self, provider: DemoProvider, spec: TrioPolicySpec) -> None:
        if not isinstance(provider, DemoProvider) or not isinstance(spec, TrioPolicySpec):
            raise TypeError("trio seat controller arguments are invalid")
        self._provider = provider
        self._spec = spec
        self._eliminated = False
        self._provider_calls = 0
        self._suppressed_calls = 0

    @property
    def policy_lock(self) -> DemoPolicyLock:
        return self._provider.policy_lock

    @property
    def decision_count(self) -> int:
        return self._provider.decision_count

    @property
    def suppressed_eliminated_calls(self) -> int:
        return self._suppressed_calls

    @property
    def provider_calls(self) -> int:
        """Count adapter invocations, including safe budget-exhaustion failures."""

        return self._provider_calls

    @property
    def eliminated(self) -> bool:
        return self._eliminated

    def drain_audits(self, episode_id: str) -> tuple[ProviderAuditRecord, ...]:
        """Transfer protected provider evidence without exposing it through decisions."""

        return self._provider.audit_log.drain_episode(episode_id)

    async def decide(
        self, request: ProviderRequest, *, eliminated: bool = False
    ) -> TrioResolvedDecision:
        if request.participant_id != self.policy_lock.participant_id:
            raise ValueError("request participant does not match the trio seat")
        if self._eliminated or eliminated:
            self._eliminated = True
            self._suppressed_calls += 1
            return TrioResolvedDecision(
                neutral_action(request, reason="eliminated"),
                "eliminated",
                "eliminated",
                False,
            )

        self._provider_calls += 1
        result = await self._provider.request(request)
        if result.failure is not None:
            reason = result.failure.value
            return TrioResolvedDecision(
                neutral_action(request, reason=reason), "no_input", reason, True
            )
        try:
            action = parse_trio_action(result.raw_output or b"", request)
        except (TypeError, ValueError) as error:
            reason = (
                "stale_observation"
                if "observation is stale" in str(error)
                else "invalid_response"
            )
            return TrioResolvedDecision(
                neutral_action(request, reason=reason),
                "no_input",
                reason,
                True,
            )
        return TrioResolvedDecision(action, "accepted", "accepted", True)

    async def aclose(self) -> None:
        await self._provider.aclose()


def build_trio_demo_controller(
    *,
    task_id: TrioTaskId,
    model: str,
    participant_id: str,
    seed: int,
    decision_budget: int,
    fixture_mode: TrioFixtureMode = "valid",
) -> TrioDemoSeatController:
    """Build one independently locked local participant with no key or network surface."""

    if task_id not in TRIO_TASK_IDS:
        raise ValueError("unsupported trio task")
    if participant_id not in ("participant_0", "participant_1", "participant_2"):
        raise ValueError("trio controller requires one of exactly three participant seats")
    try:
        spec = TRIO_POLICY_SPECS[(task_id, model)]
    except KeyError as error:
        raise ValueError("unsupported trio Demo model") from error
    fixture_mode = validate_fixture_mode(fixture_mode)
    fixture = canonical_json_bytes(
        {
            "display_name": spec.display_name,
            "fixture_mode": fixture_mode,
            "fixture_version": "llm-controller/trio-demo-fixture/1.0.0",
            "model": spec.model,
            "policy_id": spec.policy_id,
            "policy_version": spec.policy_version,
            "task_id": spec.task_id,
        }
    )
    lock = DemoPolicyLock(
        scenario_id=task_id,
        policy_id=spec.policy_id,
        fixture_sha256=hashlib.sha256(fixture).hexdigest(),
        seed=seed,
        participant_id=participant_id,
        model=model,
        total_decision_budget=decision_budget,
    )

    def behavior(
        request: ProviderRequest, policy_lock: DemoPolicyLock, call_index: int
    ) -> bytes | ProviderFailureKind:
        if (
            policy_lock.scenario_id != spec.task_id
            or policy_lock.policy_id != spec.policy_id
            or policy_lock.model != spec.model
        ):
            raise ValueError("trio Demo policy lock is incompatible")
        output = _valid_behavior(request, spec, call_index)
        return fixture_value(fixture_mode, request, output)

    provider = DemoProvider(lock, behavior=behavior, fixture_bytes=fixture)
    return TrioDemoSeatController(provider, spec)


def _valid_behavior(
    request: ProviderRequest, spec: TrioPolicySpec, call_index: int
) -> bytes:
    entities = parse_visible_observation(request)
    hostile = select_visible_entity(
        entities, kinds=("operator",), required_affordance="attack"
    )
    objective = select_visible_entity(
        entities,
        kinds=("relay", "objective", "resource", "deposit"),
        required_affordance="capture",
    )

    if spec.style == "pressure" and hostile is not None:
        control, intent = _pressure(hostile)
    elif spec.style == "defensive" and hostile is not None and hostile["distance"] in {
        "touching",
        "near",
    }:
        if hostile["bearing"] == "front":
            control = ControllerState(
                0,
                0,
                0,
                0,
                FIXED_TRIO_WINDOW_TICKS,
                ControllerButtons(guard=True),
            )
            intent = "Demo: guard the visible threat"
        else:
            control, intent = move_or_turn_toward(hostile), "Demo: face the visible threat"
    elif objective is not None:
        control, intent = _objective(objective)
    elif hostile is not None:
        control, intent = _pressure(hostile)
    else:
        turn = {"objective": 700, "defensive": -700, "pressure": 1000}[spec.style]
        control = ControllerState(0, 0, turn, 0, FIXED_TRIO_WINDOW_TICKS)
        intent = "Demo: scan participant-visible space"
    return encode_action(
        request,
        call_index=call_index,
        prefix=spec.display_name.casefold(),
        control=control,
        intent=intent,
    )


def _objective(entity: Mapping[str, object]) -> tuple[ControllerState, str]:
    if entity["bearing"] == "front" and entity["distance"] == "touching":
        return (
            ControllerState(
                0,
                0,
                0,
                0,
                FIXED_TRIO_WINDOW_TICKS,
                ControllerButtons(interact=True),
            ),
            "Demo: interact with the visible objective",
        )
    return move_or_turn_toward(entity), "Demo: approach the visible objective"


def _pressure(entity: Mapping[str, object]) -> tuple[ControllerState, str]:
    if entity["bearing"] == "front" and entity["distance"] in {"touching", "near"}:
        return (
            ControllerState(
                0,
                300,
                0,
                0,
                FIXED_TRIO_WINDOW_TICKS,
                ControllerButtons(primary=True),
            ),
            "Demo: pressure the visible opponent",
        )
    return move_or_turn_toward(entity), "Demo: approach the visible opponent"


__all__ = [
    "TRIO_POLICY_SPECS",
    "TrioDemoSeatController",
    "TrioPolicySpec",
    "build_trio_demo_controller",
]
