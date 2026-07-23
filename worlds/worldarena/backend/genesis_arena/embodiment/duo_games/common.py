"""Shared fail-closed helpers for credential-free duo game policies.

Only participant-visible observations cross this module.  The helpers intentionally cannot accept
authority objects, world maps, transforms, opponent-private observations, or provider credentials.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Callable, Literal, Mapping, Sequence

from ..contracts import ControllerAction, ControllerButtons, ControllerState
from ..demo_provider import DemoPolicyLock, DemoProvider
from ..protocol import canonical_json_bytes, strict_json_loads
from ..providers.contracts import ProviderFailureKind, ProviderRequest

PROTOCOL_VERSION = "llm-controller/0.2.0"
FIXED_DUO_WINDOW_TICKS = 10
DuoFixtureMode = Literal[
    "valid", "invalid", "malformed", "stale", "oversized", "refused", "timeout"
]

_FIXTURE_MODES = frozenset(
    ("valid", "invalid", "malformed", "stale", "oversized", "refused", "timeout")
)
_VISIBLE_PROFILES = frozenset(("text-visible-v1", "hybrid-visible-v1"))
_SAFE_VISIBLE_ID = re.compile(r"^v_[A-Za-z0-9][A-Za-z0-9._-]{0,78}$")
_SAFE_PARTICIPANT_ID = re.compile(r"^participant_[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_BEARINGS = frozenset(
    ("front", "front_right", "right", "back_right", "back", "back_left", "left", "front_left")
)
_DISTANCES = frozenset(("touching", "near", "medium", "far"))
_PROTECTED_KEYS = frozenset(
    {
        "api_key",
        "authority_state",
        "checkpoint_hash",
        "coordinate",
        "coordinates",
        "credential",
        "credentials",
        "hidden_state",
        "opponent_observation",
        "opponent_private",
        "position",
        "position_mt",
        "private_state",
        "prompt",
        "raw_model_output",
        "raw_output",
        "spectator",
        "spectator_state",
        "system_prompt",
        "transform",
        "world_state",
    }
)
_RIGHT_BEARINGS = frozenset(("front_right", "right", "back_right", "back"))
_LEFT_BEARINGS = frozenset(("front_left", "left", "back_left"))


@dataclass(frozen=True)
class DuoPolicySpec:
    """One frozen local policy identity, independent of a participant seat."""

    scenario_id: str
    policy_id: str
    model: str
    variant: str


DuoBehavior = Callable[[ProviderRequest, DemoPolicyLock, int], bytes]


def build_demo_provider(
    *,
    spec: DuoPolicySpec,
    participant_id: str,
    seed: int,
    decision_budget: int,
    behavior: DuoBehavior,
    fixture_mode: DuoFixtureMode = "valid",
) -> DemoProvider:
    """Build an immutable, bounded, network-free provider for one duo participant."""

    if not _SAFE_PARTICIPANT_ID.fullmatch(participant_id):
        raise ValueError("participant_id must be a participant-scoped identifier")
    if fixture_mode not in _FIXTURE_MODES:
        raise ValueError("unsupported duo fixture mode")
    fixture = canonical_json_bytes(
        {
            "fixture_mode": fixture_mode,
            "fixture_version": "llm-controller/duo-game-demo-fixture/1.0.0",
            "model": spec.model,
            "policy_id": spec.policy_id,
            "scenario_id": spec.scenario_id,
            "variant": spec.variant,
        }
    )
    lock = DemoPolicyLock(
        scenario_id=spec.scenario_id,
        policy_id=spec.policy_id,
        fixture_sha256=hashlib.sha256(fixture).hexdigest(),
        seed=seed,
        participant_id=participant_id,
        model=spec.model,
        total_decision_budget=decision_budget,
    )

    def fixture_behavior(
        request: ProviderRequest, policy_lock: DemoPolicyLock, call_index: int
    ) -> bytes | ProviderFailureKind:
        if fixture_mode == "valid":
            return behavior(request, policy_lock, call_index)
        if fixture_mode == "invalid":
            return b"{}"
        if fixture_mode == "malformed":
            return b"{malformed"
        if fixture_mode == "oversized":
            return b"x" * (request.max_output_bytes + 1)
        if fixture_mode == "refused":
            return ProviderFailureKind.REFUSAL
        if fixture_mode == "timeout":
            return ProviderFailureKind.TIMEOUT
        # A future sequence is also observation-mismatched at sequence zero, while remaining a
        # syntactically valid controller response for the normal stale-observation boundary.
        value = strict_json_loads(behavior(request, policy_lock, call_index))
        if not isinstance(value, dict):
            raise ValueError("valid duo behavior did not return an action object")
        value["observation_seq"] = (
            request.observation_seq - 1 if request.observation_seq > 0 else 1
        )
        return canonical_json_bytes(value)

    return DemoProvider(lock, behavior=fixture_behavior, fixture_bytes=fixture)


def parse_visible_observation(request: ProviderRequest) -> tuple[Mapping[str, Any], ...]:
    """Return a deterministic entity sequence after rejecting protected observation semantics."""

    value = strict_json_loads(request.observation_json)
    if not isinstance(value, Mapping):
        raise ValueError("duo game observation must be an object")
    reject_protected_semantics(value)
    if value.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("duo game observation must use protocol v2")
    if value.get("profile") not in _VISIBLE_PROFILES:
        raise ValueError("duo game observation profile is unsupported")
    entities = value.get("visible_entities")
    if not isinstance(entities, list) or len(entities) > 64:
        raise ValueError("visible_entities must be a bounded array")
    normalized: list[Mapping[str, Any]] = []
    for entity in entities:
        if not isinstance(entity, Mapping):
            raise ValueError("visible entity must be an object")
        visible_id = entity.get("id")
        if not isinstance(visible_id, str) or _SAFE_VISIBLE_ID.fullmatch(visible_id) is None:
            raise ValueError("visible entity id is invalid")
        if entity.get("bearing") not in _BEARINGS or entity.get("distance") not in _DISTANCES:
            raise ValueError("visible entity relation is invalid")
        affordances = entity.get("affordances")
        if (
            not isinstance(affordances, list)
            or any(not isinstance(item, str) for item in affordances)
            or len(affordances) != len(set(affordances))
        ):
            raise ValueError("visible entity affordances are invalid")
        normalized.append(entity)
    return tuple(sorted(normalized, key=_entity_sort_key))


def reject_protected_semantics(value: Any) -> None:
    """Reject protected keys at arbitrary nesting before policy selection."""

    if isinstance(value, Mapping):
        for key, child in value.items():
            if not isinstance(key, str) or key.casefold() in _PROTECTED_KEYS:
                raise ValueError("observation contains protected duo-game semantics")
            reject_protected_semantics(child)
    elif isinstance(value, list):
        for child in value:
            reject_protected_semantics(child)


def select_visible_entity(
    entities: Sequence[Mapping[str, Any]],
    *,
    kinds: Sequence[str],
    required_affordance: str | None = None,
    states: frozenset[str] | None = None,
) -> Mapping[str, Any] | None:
    """Select by semantic priority and canonical identity, never list arrival order."""

    for kind in kinds:
        candidates = []
        for entity in entities:
            if entity.get("kind") != kind:
                continue
            affordances = entity.get("affordances")
            if required_affordance is not None and required_affordance not in affordances:
                continue
            if states is not None and entity.get("state") not in states:
                continue
            candidates.append(entity)
        if candidates:
            return min(candidates, key=_entity_sort_key)
    return None


def direct_action(
    request: ProviderRequest,
    *,
    call_index: int,
    action_prefix: str,
    control: ControllerState,
    intent: str,
) -> bytes:
    if control.duration_ticks != FIXED_DUO_WINDOW_TICKS:
        raise ValueError("duo action must span exactly ten authority ticks")
    action = ControllerAction(
        protocol_version=PROTOCOL_VERSION,
        episode_id=request.episode_id,
        observation_seq=request.observation_seq,
        action_id=f"{action_prefix}_{call_index:06d}",
        control=control,
        intent_label=intent,
        memory_update="",
    )
    return canonical_json_bytes(action.as_dict())


def neutral_control() -> ControllerState:
    return ControllerState.neutral(FIXED_DUO_WINDOW_TICKS)


def move_or_turn_toward(entity: Mapping[str, Any], *, blocked_turn: int = 1000) -> ControllerState:
    bearing = entity["bearing"]
    if bearing in _LEFT_BEARINGS:
        return ControllerState(0, 0, -1000, 0, FIXED_DUO_WINDOW_TICKS)
    if bearing in _RIGHT_BEARINGS:
        return ControllerState(0, 0, 1000, 0, FIXED_DUO_WINDOW_TICKS)
    if bearing != "front":
        return ControllerState(0, 0, blocked_turn, 0, FIXED_DUO_WINDOW_TICKS)
    return ControllerState(0, 1000, 0, 0, FIXED_DUO_WINDOW_TICKS)


def interact_control() -> ControllerState:
    return ControllerState(
        0,
        0,
        0,
        0,
        FIXED_DUO_WINDOW_TICKS,
        ControllerButtons(interact=True),
    )


def validate_two_participant_summaries(
    value: Any,
    *,
    extra_fields: frozenset[str],
    outcomes: frozenset[str] = frozenset(("win", "loss", "draw", "void")),
) -> tuple[tuple[str, Mapping[str, Any]], ...]:
    """Validate the shared public-safe participant aggregate envelope."""

    if not isinstance(value, Mapping) or len(value) != 2:
        raise ValueError("duo evaluation requires exactly two participant summaries")
    expected = frozenset(("outcome", "decision_windows", "fallback_windows")) | extra_fields
    summaries: list[tuple[str, Mapping[str, Any]]] = []
    for participant_id, summary in value.items():
        if (
            not isinstance(participant_id, str)
            or _SAFE_PARTICIPANT_ID.fullmatch(participant_id) is None
            or not isinstance(summary, Mapping)
            or set(summary) != expected
        ):
            raise ValueError("duo participant summary is malformed")
        if summary["outcome"] not in outcomes:
            raise ValueError("duo participant outcome is invalid")
        for field in ("decision_windows", "fallback_windows", *sorted(extra_fields)):
            number = summary[field]
            if isinstance(number, bool) or not isinstance(number, int) or number < 0:
                raise ValueError(f"{field} must be a non-negative integer")
        if summary["fallback_windows"] > summary["decision_windows"]:
            raise ValueError("fallback windows exceed decision windows")
        summaries.append((participant_id, summary))
    summaries.sort(key=lambda item: item[0])
    return tuple(summaries)


def participant_window_projection(
    summaries: Sequence[tuple[str, Mapping[str, Any]]],
    *,
    extra_fields: Sequence[str],
) -> tuple[dict[str, Any], dict[str, int | bool]]:
    """Project sorted participant summaries and seat-symmetric absolute differences."""

    projected: dict[str, Any] = {}
    for participant_id, summary in summaries:
        windows = summary["decision_windows"]
        fallbacks = summary["fallback_windows"]
        projected[participant_id] = {
            "outcome": summary["outcome"],
            "decision_windows": windows,
            "fallback_windows": fallbacks,
            "fallback_ratio_per_mille": 0 if windows == 0 else fallbacks * 1000 // windows,
            **{field: summary[field] for field in extra_fields},
        }
    first = summaries[0][1]
    second = summaries[1][1]
    symmetry: dict[str, int | bool] = {
        "decision_window_delta": abs(first["decision_windows"] - second["decision_windows"]),
        "fallback_window_delta": abs(first["fallback_windows"] - second["fallback_windows"]),
        "equal_decision_windows": first["decision_windows"] == second["decision_windows"],
    }
    return projected, symmetry


def validate_completion_tick(value: Any) -> int | None:
    if value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0):
        raise ValueError("completion_tick must be null or a non-negative integer")
    return value


def validate_match_outcomes(
    summaries: Sequence[tuple[str, Mapping[str, Any]]], terminal_outcome: str
) -> None:
    outcomes = sorted(summary["outcome"] for _, summary in summaries)
    expected = {
        "win": ["loss", "win"],
        "draw": ["draw", "draw"],
        "void": ["void", "void"],
    }
    if (
        not isinstance(terminal_outcome, str)
        or terminal_outcome not in expected
        or outcomes != expected[terminal_outcome]
    ):
        raise ValueError("participant outcomes differ from terminal outcome")


def frozen_specs(values: Mapping[str, DuoPolicySpec]) -> Mapping[str, DuoPolicySpec]:
    return MappingProxyType(dict(values))


def _entity_sort_key(entity: Mapping[str, Any]) -> tuple[str, str, str, str]:
    return (
        str(entity.get("kind", "")),
        str(entity.get("id", "")),
        str(entity.get("bearing", "")),
        str(entity.get("distance", "")),
    )


__all__ = [
    "DuoFixtureMode",
    "DuoPolicySpec",
    "FIXED_DUO_WINDOW_TICKS",
    "PROTOCOL_VERSION",
    "build_demo_provider",
    "direct_action",
    "frozen_specs",
    "interact_control",
    "move_or_turn_toward",
    "neutral_control",
    "parse_visible_observation",
    "participant_window_projection",
    "select_visible_entity",
    "validate_completion_tick",
    "validate_match_outcomes",
    "validate_two_participant_summaries",
]
