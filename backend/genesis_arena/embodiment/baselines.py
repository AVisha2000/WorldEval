"""Canonical participant-visible scripted policies for embodiment duels."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal, Mapping, Sequence

from .contracts import ControllerButtons, ControllerState
from .protocol import canonical_sha256

BaselineTier = Literal["scout-v1", "balanced-v1", "challenger-v1"]
BASELINE_TIERS = ("scout-v1", "balanced-v1", "challenger-v1")
_BEARING_MOVEMENT = {
    "front": (0, 1000),
    "front_right": (707, 707),
    "right": (1000, 0),
    "back_right": (707, -707),
    "back": (0, -1000),
    "back_left": (-707, -707),
    "left": (-1000, 0),
    "front_left": (-707, 707),
}


@dataclass(frozen=True)
class BaselineLock:
    """Complete versioned identity of the shared Python/Godot baseline policy."""

    tier: BaselineTier
    decision_ticks: int = 10
    policy_version: str = "duel-visible-baseline-v1"

    def __post_init__(self) -> None:
        if self.tier not in BASELINE_TIERS:
            raise ValueError("unsupported baseline tier")
        if isinstance(self.decision_ticks, bool) or self.decision_ticks != 10:
            raise ValueError("decision_ticks must be exactly 10")
        if self.policy_version != "duel-visible-baseline-v1":
            raise ValueError("unsupported baseline policy version")

    def as_dict(self) -> dict[str, object]:
        return {
            "decision_ticks": self.decision_ticks,
            "policy_version": self.policy_version,
            "tier": self.tier,
        }

    @property
    def lock_sha256(self) -> str:
        return canonical_sha256(self.as_dict())


def decide_baseline(lock: BaselineLock, observation: Mapping[str, Any]) -> ControllerState:
    """Match the Godot policy using only a participant-scoped observation."""

    if not isinstance(lock, BaselineLock):
        raise TypeError("lock must be BaselineLock")
    if not isinstance(observation, Mapping):
        raise TypeError("observation must be a mapping")
    self_state = observation.get("self")
    visible_entities = observation.get("visible_entities")
    observation_seq = observation.get("observation_seq")
    if (
        not isinstance(self_state, Mapping)
        or not isinstance(visible_entities, Sequence)
        or isinstance(visible_entities, (str, bytes))
        or isinstance(observation_seq, bool)
        or not isinstance(observation_seq, int)
        or observation_seq < 0
    ):
        raise ValueError("baseline observation shape is invalid")
    health = self_state.get("health_percent")
    if isinstance(health, bool) or not isinstance(health, int) or not 0 <= health <= 100:
        raise ValueError("baseline health_percent is invalid")

    opponent = _first_with_affordance(visible_entities, "hostile")
    relay = _first_kind(visible_entities, "relay")
    if lock.tier == "scout-v1":
        return _navigate(relay, magnitude=600, interact=_touching(relay))

    opponent_close = _distance(opponent) in ("touching", "near")
    opponent_ahead = _bearing(opponent) in ("front", "front_left", "front_right")
    threshold = 40 if lock.tier == "balanced-v1" else 55
    if opponent_close and health <= threshold:
        return _navigate(opponent, magnitude=-450, guard=True)
    if opponent_close and opponent_ahead:
        return ControllerState(0, 0, 0, 0, 10, ControllerButtons(primary=True))

    target = opponent if lock.tier == "challenger-v1" and opponent else relay
    magnitude = 1000 if lock.tier == "challenger-v1" else 800
    dash = bool(
        lock.tier == "challenger-v1"
        and target
        and _distance(target) in ("medium", "far")
        and observation_seq % 3 == 0
    )
    return _navigate(
        target,
        magnitude=magnitude,
        interact=_touching(relay) and target is relay,
        dash=dash,
    )


def baseline_intent(control: ControllerState) -> str:
    if control.buttons.guard:
        return "guard and disengage"
    if control.buttons.primary:
        return "attack visible rival"
    if control.buttons.interact:
        return "contest central relay"
    if control.move_x or control.move_y:
        return "advance toward visible objective"
    return "hold position"


def _navigate(
    entity: Mapping[str, Any] | None,
    *,
    magnitude: int,
    interact: bool = False,
    guard: bool = False,
    dash: bool = False,
) -> ControllerState:
    axis = _BEARING_MOVEMENT.get(_bearing(entity), (0, 0)) if entity else (0, 0)
    move_x = _truncating_scale(axis[0], magnitude)
    move_y = _truncating_scale(axis[1], magnitude)
    return ControllerState(
        move_x,
        move_y,
        0,
        0,
        10,
        ControllerButtons(interact=interact, guard=guard, dash=dash),
    )


def _truncating_scale(axis: int, magnitude: int) -> int:
    value = axis * magnitude
    return value // 1000 if value >= 0 else -((-value) // 1000)


def _first_kind(entities: Sequence[object], kind: str) -> Mapping[str, Any] | None:
    return next(
        (
            entity
            for entity in entities
            if isinstance(entity, Mapping) and entity.get("kind") == kind
        ),
        None,
    )


def _first_with_affordance(entities: Sequence[object], affordance: str) -> Mapping[str, Any] | None:
    for entity in entities:
        if not isinstance(entity, Mapping):
            continue
        affordances = entity.get("affordances")
        if (
            isinstance(affordances, Sequence)
            and not isinstance(affordances, (str, bytes))
            and affordance in affordances
        ):
            return entity
    return None


def _bearing(entity: Mapping[str, Any] | None) -> str:
    if entity is None:
        return "front"
    value = entity.get("bearing", "front")
    return value if isinstance(value, str) and value in _BEARING_MOVEMENT else "front"


def _distance(entity: Mapping[str, Any] | None) -> str:
    if entity is None:
        return "far"
    value = entity.get("distance", "far")
    return value if value in ("touching", "near", "medium", "far") else "far"


def _touching(entity: Mapping[str, Any] | None) -> bool:
    return entity is not None and _distance(entity) == "touching"


__all__ = [
    "BASELINE_TIERS",
    "BaselineLock",
    "BaselineTier",
    "baseline_intent",
    "decide_baseline",
]
