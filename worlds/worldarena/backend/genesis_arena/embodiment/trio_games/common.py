"""Fail-closed contracts shared by the credential-free three-participant prototype.

This package deliberately does not register protocol v3 with the product runtime.  It provides
the isolated, versioned Python core that a later integration slice can bind to the immutable
``llm-controller/0.3.0`` package.  Only participant-visible observations are accepted here.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Literal, Mapping, Sequence

from ..contracts import ControllerButtons, ControllerState
from ..protocol import canonical_json_bytes, strict_json_loads
from ..providers.contracts import ProviderFailureKind, ProviderRequest

PROTOCOL_VERSION = "llm-controller/0.3.0"
FIXED_TRIO_WINDOW_TICKS = 10
TRIO_PARTICIPANT_IDS = ("participant_0", "participant_1", "participant_2")
TrioFixtureMode = Literal[
    "valid", "invalid", "malformed", "stale", "oversized", "refused", "timeout"
]
TrioDisposition = Literal["accepted", "no_input", "eliminated"]

_FIXTURE_MODES = frozenset(
    ("valid", "invalid", "malformed", "stale", "oversized", "refused", "timeout")
)
_PROFILES = frozenset(("text-visible-v1", "hybrid-visible-v1"))
_EPISODE_ID = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_ACTION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_VISIBLE_ID = re.compile(r"^v_[A-Za-z0-9][A-Za-z0-9._-]{0,78}$")
_BEARINGS = frozenset(
    ("front", "front_right", "right", "back_right", "back", "back_left", "left", "front_left")
)
_DISTANCES = frozenset(("touching", "near", "medium", "far"))
_DISTANCE_ORDER = {"touching": 0, "near": 1, "medium": 2, "far": 3}
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
_BUTTON_FIELDS = (
    "interact",
    "primary",
    "guard",
    "dash",
    "ability_1",
    "ability_2",
    "cycle_item",
    "cancel",
)
_CONTROL_FIELDS = frozenset(
    ("move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons")
)
_ACTION_FIELDS = frozenset(
    (
        "protocol_version",
        "episode_id",
        "observation_seq",
        "action_id",
        "control",
        "intent_label",
        "memory_update",
    )
)


TRIO_ACTION_SCHEMA_JSON = canonical_json_bytes(
    {
        "$id": "worldarena://llm-controller/0.3.0/controller-action.schema.json",
        "additionalProperties": False,
        "properties": {
            "action_id": {
                "maxLength": 64,
                "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
                "type": "string",
            },
            "control": {
                "additionalProperties": False,
                "properties": {
                    "buttons": {
                        "additionalProperties": False,
                        "properties": {
                            name: {"type": "boolean"} for name in _BUTTON_FIELDS
                        },
                        "required": list(_BUTTON_FIELDS),
                        "type": "object",
                    },
                    "duration_ticks": {"const": FIXED_TRIO_WINDOW_TICKS, "type": "integer"},
                    "look_x": {"maximum": 1000, "minimum": -1000, "type": "integer"},
                    "look_y": {"maximum": 1000, "minimum": -1000, "type": "integer"},
                    "move_x": {"maximum": 1000, "minimum": -1000, "type": "integer"},
                    "move_y": {"maximum": 1000, "minimum": -1000, "type": "integer"},
                },
                "required": sorted(_CONTROL_FIELDS),
                "type": "object",
            },
            "episode_id": {"pattern": "^ep_[A-Za-z0-9._-]{1,120}$", "type": "string"},
            "intent_label": {"maxLength": 160, "type": "string"},
            "memory_update": {"maxLength": 2048, "type": "string"},
            "observation_seq": {"maximum": 9_007_199_254_740_991, "minimum": 0, "type": "integer"},
            "protocol_version": {"const": PROTOCOL_VERSION, "type": "string"},
        },
        "required": sorted(_ACTION_FIELDS),
        "type": "object",
    }
)


@dataclass(frozen=True)
class TrioControllerAction:
    """A strict v3 direct-controller action independent from the not-yet-registered runtime."""

    episode_id: str
    observation_seq: int
    action_id: str
    control: ControllerState
    intent_label: str = ""
    memory_update: str = ""
    protocol_version: str = PROTOCOL_VERSION

    def __post_init__(self) -> None:
        if self.protocol_version != PROTOCOL_VERSION:
            raise ValueError("trio action must use protocol v3")
        if not isinstance(self.episode_id, str) or _EPISODE_ID.fullmatch(self.episode_id) is None:
            raise ValueError("episode_id is invalid")
        _integer("observation_seq", self.observation_seq, 0, 9_007_199_254_740_991)
        if not isinstance(self.action_id, str) or _ACTION_ID.fullmatch(self.action_id) is None:
            raise ValueError("action_id is invalid")
        if not isinstance(self.control, ControllerState):
            raise TypeError("control must be ControllerState")
        if self.control.duration_ticks != FIXED_TRIO_WINDOW_TICKS:
            raise ValueError("trio action must span exactly ten authority ticks")
        if self.control.autonomous_task is not None:
            raise ValueError("autonomous_task is not part of protocol v3")
        _bounded_text("intent_label", self.intent_label, 160)
        _bounded_text("memory_update", self.memory_update, 2048)

    def as_dict(self) -> dict[str, Any]:
        return {
            "protocol_version": self.protocol_version,
            "episode_id": self.episode_id,
            "observation_seq": self.observation_seq,
            "action_id": self.action_id,
            "control": self.control.as_dict(),
            "intent_label": self.intent_label,
            "memory_update": self.memory_update,
        }


@dataclass(frozen=True)
class TrioResolvedDecision:
    """Safe result of the normal provider/strict-parser/fallback boundary."""

    action: TrioControllerAction
    disposition: TrioDisposition
    reason: str
    provider_called: bool

    def __post_init__(self) -> None:
        if not isinstance(self.action, TrioControllerAction):
            raise TypeError("action must be TrioControllerAction")
        if self.disposition not in ("accepted", "no_input", "eliminated"):
            raise ValueError("unsupported trio decision disposition")
        if not isinstance(self.reason, str) or not self.reason:
            raise ValueError("reason is required")
        if not isinstance(self.provider_called, bool):
            raise TypeError("provider_called must be boolean")
        if self.disposition == "accepted" and not self.provider_called:
            raise ValueError("accepted decision requires a provider call")
        if self.disposition == "eliminated" and self.provider_called:
            raise ValueError("eliminated disposition must suppress provider calls")


def validate_fixture_mode(value: object) -> TrioFixtureMode:
    if not isinstance(value, str) or value not in _FIXTURE_MODES:
        raise ValueError("unsupported trio fixture mode")
    return value  # type: ignore[return-value]


def parse_visible_observation(request: ProviderRequest) -> tuple[Mapping[str, Any], ...]:
    value = strict_json_loads(request.observation_json)
    if not isinstance(value, Mapping):
        raise ValueError("trio observation must be an object")
    reject_protected_semantics(value)
    if value.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("trio observation must use protocol v3")
    if value.get("profile") not in _PROFILES:
        raise ValueError("trio observation profile is unsupported")
    entities = value.get("visible_entities")
    if not isinstance(entities, list) or len(entities) > 64:
        raise ValueError("visible_entities must be a bounded array")
    normalized: list[Mapping[str, Any]] = []
    for entity in entities:
        if not isinstance(entity, Mapping):
            raise ValueError("visible entity must be an object")
        visible_id = entity.get("id")
        if not isinstance(visible_id, str) or _VISIBLE_ID.fullmatch(visible_id) is None:
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
    if isinstance(value, Mapping):
        for key, child in value.items():
            if not isinstance(key, str) or key.casefold() in _PROTECTED_KEYS:
                raise ValueError("observation contains protected trio semantics")
            reject_protected_semantics(child)
    elif isinstance(value, list):
        for child in value:
            reject_protected_semantics(child)


def select_visible_entity(
    entities: Sequence[Mapping[str, Any]],
    *,
    kinds: Sequence[str],
    required_affordance: str | None = None,
) -> Mapping[str, Any] | None:
    for kind in kinds:
        candidates = [
            entity
            for entity in entities
            if entity.get("kind") == kind
            and (
                required_affordance is None
                or required_affordance in entity.get("affordances", ())
            )
        ]
        if candidates:
            return min(candidates, key=_entity_sort_key)
    return None


def move_or_turn_toward(entity: Mapping[str, Any]) -> ControllerState:
    bearing = entity["bearing"]
    if bearing in ("front_left", "left", "back_left"):
        return ControllerState(0, 0, -1000, 0, FIXED_TRIO_WINDOW_TICKS)
    if bearing in ("front_right", "right", "back_right", "back"):
        return ControllerState(0, 0, 1000, 0, FIXED_TRIO_WINDOW_TICKS)
    return ControllerState(0, 1000, 0, 0, FIXED_TRIO_WINDOW_TICKS)


def encode_action(
    request: ProviderRequest,
    *,
    call_index: int,
    prefix: str,
    control: ControllerState,
    intent: str,
) -> bytes:
    action = TrioControllerAction(
        episode_id=request.episode_id,
        observation_seq=request.observation_seq,
        action_id=f"{prefix}_{call_index:06d}",
        control=control,
        intent_label=intent,
    )
    return canonical_json_bytes(action.as_dict())


def parse_trio_action(raw_output: bytes, request: ProviderRequest) -> TrioControllerAction:
    value = strict_json_loads(raw_output)
    if not isinstance(value, Mapping) or set(value) != _ACTION_FIELDS:
        raise ValueError("trio controller action has invalid fields")
    if value["protocol_version"] != PROTOCOL_VERSION:
        raise ValueError("trio controller action uses the wrong protocol")
    if value["episode_id"] != request.episode_id:
        raise ValueError("trio controller action episode is stale")
    if value["observation_seq"] != request.observation_seq:
        raise ValueError("trio controller action observation is stale")
    control = _parse_control(value["control"])
    return TrioControllerAction(
        episode_id=value["episode_id"],
        observation_seq=value["observation_seq"],
        action_id=value["action_id"],
        control=control,
        intent_label=value["intent_label"],
        memory_update=value["memory_update"],
    )


def neutral_action(request: ProviderRequest, *, reason: str) -> TrioControllerAction:
    safe_reason = re.sub(r"[^a-z0-9_]", "_", reason.casefold())[:24] or "invalid"
    return TrioControllerAction(
        episode_id=request.episode_id,
        observation_seq=request.observation_seq,
        action_id=f"neutral_{request.observation_seq}_{safe_reason}",
        control=ControllerState.neutral(FIXED_TRIO_WINDOW_TICKS),
        intent_label="Demo: neutral fallback",
    )


def fixture_value(
    mode: TrioFixtureMode,
    request: ProviderRequest,
    valid_output: bytes,
) -> bytes | ProviderFailureKind:
    if mode == "valid":
        return valid_output
    if mode == "invalid":
        return b"{}"
    if mode == "malformed":
        return b"{malformed"
    if mode == "oversized":
        return b"x" * (request.max_output_bytes + 1)
    if mode == "refused":
        return ProviderFailureKind.REFUSAL
    if mode == "timeout":
        return ProviderFailureKind.TIMEOUT
    value = strict_json_loads(valid_output)
    if not isinstance(value, dict):
        raise ValueError("valid trio fixture output is malformed")
    value["observation_seq"] = request.observation_seq + 1
    return canonical_json_bytes(value)


def _parse_control(value: object) -> ControllerState:
    if not isinstance(value, Mapping) or set(value) != _CONTROL_FIELDS:
        raise ValueError("trio control has invalid fields")
    buttons = value["buttons"]
    if not isinstance(buttons, Mapping) or tuple(buttons) != _BUTTON_FIELDS:
        # Canonical JSON sorts keys, so compare sets while still requiring the complete button set.
        if not isinstance(buttons, Mapping) or set(buttons) != set(_BUTTON_FIELDS):
            raise ValueError("trio buttons have invalid fields")
    if any(not isinstance(buttons[name], bool) for name in _BUTTON_FIELDS):
        raise TypeError("trio buttons must be strict booleans")
    return ControllerState(
        move_x=_strict_control_integer("move_x", value["move_x"]),
        move_y=_strict_control_integer("move_y", value["move_y"]),
        look_x=_strict_control_integer("look_x", value["look_x"]),
        look_y=_strict_control_integer("look_y", value["look_y"]),
        duration_ticks=_duration(value["duration_ticks"]),
        buttons=ControllerButtons(**{name: buttons[name] for name in _BUTTON_FIELDS}),
    )


def _strict_control_integer(name: str, value: object) -> int:
    _integer(name, value, -1000, 1000)
    return value  # type: ignore[return-value]


def _duration(value: object) -> int:
    _integer("duration_ticks", value, FIXED_TRIO_WINDOW_TICKS, FIXED_TRIO_WINDOW_TICKS)
    return value  # type: ignore[return-value]


def _integer(name: str, value: object, minimum: int, maximum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer from {minimum} to {maximum}")


def _bounded_text(name: str, value: object, maximum_bytes: int) -> None:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a string")
    if unicodedata.normalize("NFC", value) != value:
        raise ValueError(f"{name} must be NFC normalized")
    if len(value.encode("utf-8")) > maximum_bytes:
        raise ValueError(f"{name} exceeds its UTF-8 byte limit")


def _entity_sort_key(entity: Mapping[str, Any]) -> tuple[str, int, str, str]:
    return (
        str(entity.get("kind", "")),
        _DISTANCE_ORDER.get(str(entity.get("distance", "")), 99),
        str(entity.get("id", "")),
        str(entity.get("bearing", "")),
    )


__all__ = [
    "FIXED_TRIO_WINDOW_TICKS",
    "PROTOCOL_VERSION",
    "TRIO_ACTION_SCHEMA_JSON",
    "TRIO_PARTICIPANT_IDS",
    "TrioControllerAction",
    "TrioDisposition",
    "TrioFixtureMode",
    "TrioResolvedDecision",
    "encode_action",
    "fixture_value",
    "move_or_turn_toward",
    "neutral_action",
    "parse_trio_action",
    "parse_visible_observation",
    "select_visible_entity",
    "validate_fixture_mode",
]
