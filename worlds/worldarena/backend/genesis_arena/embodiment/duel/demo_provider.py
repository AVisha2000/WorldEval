"""Credential-free deterministic duel policies behind the normal provider boundary."""

from __future__ import annotations

import hashlib
from typing import Any, Mapping

from ..contracts import ControllerAction, ControllerButtons, ControllerState
from ..demo_provider import DemoPolicyLock, DemoProvider
from ..protocol import canonical_json_bytes, strict_json_loads
from ..providers.contracts import ProviderRequest

DEMO_DUEL_POLICIES = frozenset(("duelist-alpha-v1", "duelist-bravo-v1"))
_SCENARIO_ID = "central-relay-v0"


def build_demo_duel_provider(
    *,
    model: str,
    participant_id: str,
    seed: int,
    decision_budget: int,
) -> DemoProvider:
    """Create one independently locked local entrant with no credential or I/O surface."""

    if model not in DEMO_DUEL_POLICIES:
        raise ValueError("unsupported demo duel policy")
    fixture = canonical_json_bytes(
        {
            "policy_id": model,
            "scenario_id": _SCENARIO_ID,
            "schema_version": "llm-controller/demo-duel-policy/1.0.0",
        }
    )
    lock = DemoPolicyLock(
        scenario_id=_SCENARIO_ID,
        policy_id=model,
        fixture_sha256=hashlib.sha256(fixture).hexdigest(),
        seed=seed,
        participant_id=participant_id,
        model=model,
        total_decision_budget=decision_budget,
    )
    return DemoProvider(lock, behavior=_duel_behavior, fixture_bytes=fixture)


def _duel_behavior(request: ProviderRequest, lock: DemoPolicyLock, call_index: int) -> bytes:
    observation = strict_json_loads(request.observation_json)
    if not isinstance(observation, Mapping):
        raise ValueError("demo duel observation must be an object")
    control, intent = _select_control(observation, aggressive=lock.policy_id == "duelist-alpha-v1")
    action = ControllerAction(
        episode_id=request.episode_id,
        observation_seq=request.observation_seq,
        action_id=f"demo_duel_{call_index:06d}",
        control=control,
        intent_label=intent,
        memory_update="",
    )
    return canonical_json_bytes(action.as_dict())


def _select_control(
    observation: Mapping[str, Any], *, aggressive: bool
) -> tuple[ControllerState, str]:
    entities = observation.get("visible_entities")
    visible = entities if isinstance(entities, list) else []
    hostile = _first_visible(visible, kind="operator", affordance="hostile")
    relay = _first_visible(visible, kind="relay")

    if hostile is not None and hostile.get("distance") in ("touching", "near"):
        bearing = str(hostile.get("bearing", "front"))
        if bearing != "front":
            return _turn_toward(bearing), "Demo: face visible opponent"
        if aggressive:
            return ControllerState(
                0, 250, 0, 0, 10, ControllerButtons(primary=True)
            ), "Demo: pressure visible opponent"
        return ControllerState(
            0, 0, 0, 0, 10, ControllerButtons(guard=True)
        ), "Demo: guard visible opponent"

    target = relay if relay is not None else hostile
    if target is None:
        look = 1000 if aggressive else -1000
        return ControllerState(0, 0, look, 0, 10), "Demo: scan visible arena"
    bearing = str(target.get("bearing", "front"))
    if bearing != "front":
        return _turn_toward(bearing), "Demo: face visible target"
    if target.get("distance") == "touching" and target is relay:
        return ControllerState(
            0, 0, 0, 0, 10, ControllerButtons(interact=True)
        ), "Demo: hold visible relay"
    return ControllerState(0, 1000, 0, 0, 10), "Demo: approach visible target"


def _first_visible(
    entities: list[Any], *, kind: str, affordance: str | None = None
) -> Mapping[str, Any] | None:
    for entity in entities:
        if not isinstance(entity, Mapping) or entity.get("kind") != kind:
            continue
        affordances = entity.get("affordances")
        if affordance is None or (
            isinstance(affordances, list) and affordance in affordances
        ):
            return entity
    return None


def _turn_toward(bearing: str) -> ControllerState:
    left = bearing in ("left", "front_left", "back_left")
    return ControllerState(0, 0, -1000 if left else 1000, 0, 10)


__all__ = ["DEMO_DUEL_POLICIES", "build_demo_duel_provider"]
