"""Strict, environment-agnostic runtime contracts for LLM Controller."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any, Dict, Literal, Mapping, Protocol, Tuple, Union, runtime_checkable

ProtocolVersion = Literal["llm-controller/0.1.0"]
EnvironmentMode = Literal["solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0"]
ObservationProfile = Literal["text-visible-v1", "rgb-v1", "hybrid-visible-v1"]
TimingTrack = Literal["step-locked-v1"]
ActionDisposition = Literal["accepted", "no_input"]
FallbackPolicy = Literal["none", "neutral"]
NoInputReason = Literal["missing", "invalid", "timeout", "stale_observation"]
TerminalOutcome = Literal["running", "success", "failure", "win", "loss", "draw", "void"]
JsonScalar = Union[str, int, bool, None]

_EXACT_INTEGER_MAX = 9_007_199_254_740_991
_EPISODE_ID = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_ACTION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_PARTICIPANT_ID = re.compile(r"^participant_[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_LOWER_ID = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_TASK_ID = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
_EVENT_ID = re.compile(r"^evt_[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")

_MODES = frozenset(("solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0"))
_PROFILES = frozenset(("text-visible-v1", "rgb-v1", "hybrid-visible-v1"))


def _strict_int(name: str, value: object, minimum: int, maximum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer from {minimum} to {maximum}")


def _strict_bool(name: str, value: object) -> None:
    if not isinstance(value, bool):
        raise TypeError(f"{name} must be a boolean")


def _strict_string(name: str, value: object, *, maximum_utf8_bytes: int | None = None) -> None:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a string")
    if unicodedata.normalize("NFC", value) != value:
        raise ValueError(f"{name} must be NFC-normalized")
    if maximum_utf8_bytes is not None and len(value.encode("utf-8")) > maximum_utf8_bytes:
        raise ValueError(f"{name} exceeds {maximum_utf8_bytes} UTF-8 bytes")


def _strict_pattern(name: str, value: object, pattern: re.Pattern[str]) -> None:
    _strict_string(name, value)
    if pattern.fullmatch(value) is None:
        raise ValueError(f"{name} has an invalid format")


def _strict_tuple(name: str, value: object) -> None:
    if not isinstance(value, tuple):
        raise TypeError(f"{name} must be a tuple")


@dataclass(frozen=True)
class ControllerButtons:
    """Complete button state for one bounded controller window."""

    interact: bool = False
    primary: bool = False
    guard: bool = False
    dash: bool = False
    ability_1: bool = False
    ability_2: bool = False
    cycle_item: bool = False
    cancel: bool = False

    def __post_init__(self) -> None:
        for name in (
            "interact",
            "primary",
            "guard",
            "dash",
            "ability_1",
            "ability_2",
            "cycle_item",
            "cancel",
        ):
            _strict_bool(name, getattr(self, name))

    def as_dict(self) -> Dict[str, bool]:
        return {
            "interact": self.interact,
            "primary": self.primary,
            "guard": self.guard,
            "dash": self.dash,
            "ability_1": self.ability_1,
            "ability_2": self.ability_2,
            "cycle_item": self.cycle_item,
            "cancel": self.cancel,
        }


@dataclass(frozen=True)
class ControllerState:
    """Human-equivalent controller state held for one to twenty 100 ms ticks."""

    move_x: int
    move_y: int
    look_x: int
    look_y: int
    duration_ticks: int
    buttons: ControllerButtons = field(default_factory=ControllerButtons)
    # Additive managed-solo hook.  It is never accepted for duel modes and is
    # expanded by Godot into ordinary stick/button input on every authority tick.
    autonomous_task: str | None = None

    def __post_init__(self) -> None:
        for name in ("move_x", "move_y", "look_x", "look_y"):
            _strict_int(name, getattr(self, name), -1000, 1000)
        _strict_int("duration_ticks", self.duration_ticks, 1, 20)
        if not isinstance(self.buttons, ControllerButtons):
            raise TypeError("buttons must be ControllerButtons")
        if self.autonomous_task is not None and self.autonomous_task not in (
            "gather_materials", "deliver_materials", "build_barricade", "wait"
        ):
            raise ValueError("autonomous_task is unsupported")

    @classmethod
    def neutral(cls, duration_ticks: int) -> ControllerState:
        """Return the only Phase-0 fallback input: a neutral state for the whole window."""

        return cls(0, 0, 0, 0, duration_ticks)

    def as_dict(self) -> Dict[str, Any]:
        value: Dict[str, Any] = {
            "move_x": self.move_x,
            "move_y": self.move_y,
            "look_x": self.look_x,
            "look_y": self.look_y,
            "duration_ticks": self.duration_ticks,
            "buttons": self.buttons.as_dict(),
        }
        if self.autonomous_task is not None:
            value["autonomous_task"] = self.autonomous_task
        return value


@dataclass(frozen=True)
class ControllerAction:
    """Validated model response after the strict JSON/schema boundary."""

    episode_id: str
    observation_seq: int
    action_id: str
    control: ControllerState
    intent_label: str = ""
    memory_update: str = ""
    protocol_version: ProtocolVersion = "llm-controller/0.1.0"

    def __post_init__(self) -> None:
        if self.protocol_version != "llm-controller/0.1.0":
            raise ValueError("unsupported protocol_version")
        _strict_pattern("episode_id", self.episode_id, _EPISODE_ID)
        _strict_int("observation_seq", self.observation_seq, 0, _EXACT_INTEGER_MAX)
        _strict_pattern("action_id", self.action_id, _ACTION_ID)
        if not isinstance(self.control, ControllerState):
            raise TypeError("control must be ControllerState")
        _strict_string("intent_label", self.intent_label, maximum_utf8_bytes=160)
        _strict_string("memory_update", self.memory_update, maximum_utf8_bytes=2048)

    def as_dict(self) -> Dict[str, Any]:
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
class CapabilityStatus:
    """Adapter capabilities that are implemented and safe to select before reset.

    The manifest may describe future modes and profiles without implying that they are runnable.
    The base solo authority implements text observations. Managed presentation may explicitly
    enable participant-bound hybrid observations; neither profile is certified or scored yet.
    """

    implemented_modes: Tuple[EnvironmentMode, ...] = ("solo-curriculum-v0",)
    implemented_observation_profiles: Tuple[ObservationProfile, ...] = ("text-visible-v1",)
    implemented_tasks: Tuple[str, ...] = (
        "orientation-v0",
        "interaction-v0",
        "construction-v0",
        "neutral-encounter-v0",
    )
    certified_modes: Tuple[EnvironmentMode, ...] = ()
    certified_observation_profiles: Tuple[ObservationProfile, ...] = ()
    scored_observation_profiles: Tuple[ObservationProfile, ...] = ()

    def __post_init__(self) -> None:
        for name in (
            "implemented_modes",
            "implemented_observation_profiles",
            "implemented_tasks",
            "certified_modes",
            "certified_observation_profiles",
            "scored_observation_profiles",
        ):
            values = getattr(self, name)
            _strict_tuple(name, values)
            if len(values) != len(set(values)):
                raise ValueError(f"{name} must not contain duplicates")
        if not self.implemented_modes:
            raise ValueError("implemented_modes must not be empty")
        if any(mode not in _MODES for mode in self.implemented_modes):
            raise ValueError("implemented_modes contains an unknown mode")
        if any(mode not in _MODES for mode in self.certified_modes):
            raise ValueError("certified_modes contains an unknown mode")
        if not set(self.certified_modes) <= set(self.implemented_modes):
            raise ValueError("certified modes must also be implemented")
        for name in (
            "implemented_observation_profiles",
            "certified_observation_profiles",
            "scored_observation_profiles",
        ):
            if any(profile not in _PROFILES for profile in getattr(self, name)):
                raise ValueError(f"{name} contains an unknown profile")
        if not set(self.certified_observation_profiles) <= set(
            self.implemented_observation_profiles
        ):
            raise ValueError("certified profiles must also be implemented")
        if not set(self.scored_observation_profiles) <= set(self.certified_observation_profiles):
            raise ValueError("scored profiles must also be certified")
        for task_id in self.implemented_tasks:
            _strict_pattern("implemented_tasks item", task_id, _TASK_ID)

    def supports(self, *, mode: str, observation_profile: str, task_id: str) -> bool:
        return (
            mode in self.implemented_modes
            and observation_profile in self.implemented_observation_profiles
            and task_id in self.implemented_tasks
        )

    def as_dict(self) -> Dict[str, Any]:
        return {
            "implemented_modes": list(self.implemented_modes),
            "implemented_observation_profiles": list(self.implemented_observation_profiles),
            "implemented_tasks": list(self.implemented_tasks),
            "certified_modes": list(self.certified_modes),
            "certified_observation_profiles": list(self.certified_observation_profiles),
            "scored_observation_profiles": list(self.scored_observation_profiles),
        }


@dataclass(frozen=True)
class EpisodeConfig:
    """All gameplay-affecting choices, checked against capabilities before reset."""

    episode_id: str
    mode: EnvironmentMode
    task_id: str
    seed: int
    observation_profile: ObservationProfile = "text-visible-v1"
    timing_track: TimingTrack = "step-locked-v1"
    maximum_episode_ticks: int = 1800
    participant_ids: Tuple[str, ...] = ("participant_0",)
    capability_status: CapabilityStatus = field(default_factory=CapabilityStatus, repr=False)

    def __post_init__(self) -> None:
        _strict_pattern("episode_id", self.episode_id, _EPISODE_ID)
        if self.mode not in _MODES:
            raise ValueError("mode is not defined by this protocol")
        _strict_pattern("task_id", self.task_id, _TASK_ID)
        if self.observation_profile not in _PROFILES:
            raise ValueError("observation_profile is not defined by this protocol")
        if self.timing_track != "step-locked-v1":
            raise ValueError("unsupported timing_track")
        _strict_tuple("participant_ids", self.participant_ids)
        expected_participants = 1 if self.mode == "solo-curriculum-v0" else 2
        if len(self.participant_ids) != expected_participants:
            raise ValueError(f"{self.mode} requires {expected_participants} participant(s)")
        if len(set(self.participant_ids)) != len(self.participant_ids):
            raise ValueError("participant_ids must be unique")
        for participant_id in self.participant_ids:
            _strict_pattern("participant_id", participant_id, _PARTICIPANT_ID)
        _strict_int("seed", self.seed, 0, _EXACT_INTEGER_MAX)
        _strict_int("maximum_episode_ticks", self.maximum_episode_ticks, 1, 18_000)
        if not isinstance(self.capability_status, CapabilityStatus):
            raise TypeError("capability_status must be CapabilityStatus")
        if not self.capability_status.supports(
            mode=self.mode,
            observation_profile=self.observation_profile,
            task_id=self.task_id,
        ):
            raise ValueError(
                "episode mode, observation_profile, and task_id must be implemented before reset"
            )

    def as_dict(self) -> Dict[str, Any]:
        """Return the canonical gameplay-affecting wire representation."""

        return {
            "protocol_version": "llm-controller/0.1.0",
            "episode_id": self.episode_id,
            "mode": self.mode,
            "task_id": self.task_id,
            "seed": self.seed,
            "observation_profile": self.observation_profile,
            "timing_track": self.timing_track,
            "maximum_episode_ticks": self.maximum_episode_ticks,
            "participant_ids": list(self.participant_ids),
        }


@dataclass(frozen=True)
class ParticipantDecision:
    """One participant's accepted action or recorded neutral no-input disposition."""

    disposition: ActionDisposition
    action: ControllerAction | None
    fallback: FallbackPolicy = "none"
    no_input_reason: NoInputReason | None = None

    def __post_init__(self) -> None:
        if self.disposition not in ("accepted", "no_input"):
            raise ValueError("unsupported disposition")
        if self.disposition == "accepted":
            if not isinstance(self.action, ControllerAction):
                raise ValueError("accepted decisions require a ControllerAction")
            if self.fallback != "none" or self.no_input_reason is not None:
                raise ValueError("accepted decisions cannot use a fallback or no_input_reason")
            return
        if self.action is not None:
            raise ValueError("no_input decisions cannot contain an action")
        if self.fallback != "neutral":
            raise ValueError("no_input decisions must use the neutral fallback")
        if self.no_input_reason not in ("missing", "invalid", "timeout", "stale_observation"):
            raise ValueError("no_input decisions require a recognized no_input_reason")

    @classmethod
    def no_input(cls, reason: NoInputReason) -> ParticipantDecision:
        return cls("no_input", None, "neutral", reason)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "disposition": self.disposition,
            "action": None if self.action is None else self.action.as_dict(),
            "fallback": self.fallback,
            "no_input_reason": self.no_input_reason,
        }


@dataclass(frozen=True)
class DecisionWindow:
    """A simultaneous authority window containing exactly one decision per participant."""

    episode_id: str
    observation_seq: int
    mode: EnvironmentMode
    start_tick: int
    duration_ticks: int
    decisions: Mapping[str, ParticipantDecision]

    @classmethod
    def finalize(
        cls,
        *,
        episode_id: str,
        observation_seq: int,
        mode: EnvironmentMode,
        start_tick: int,
        participant_ids: Tuple[str, ...],
        actions: Mapping[str, object],
        failure_reasons: Mapping[str, NoInputReason] | None = None,
        duration_ticks: int | None = None,
    ) -> DecisionWindow:
        """Finalize a joint window, converting every failed decision to neutral input.

        Raw parsing and provider failures can be represented without constructing an invalid
        ``ControllerAction``. Extra participant keys still fail closed because they indicate an
        orchestration bug rather than a participant failure.
        """

        _strict_tuple("participant_ids", participant_ids)
        if not isinstance(actions, Mapping):
            raise TypeError("actions must be a mapping")
        reasons: Mapping[str, NoInputReason] = failure_reasons or {}
        if not isinstance(reasons, Mapping):
            raise TypeError("failure_reasons must be a mapping")
        participant_set = set(participant_ids)
        extra_keys = (set(actions) | set(reasons)) - participant_set
        if extra_keys:
            raise ValueError("actions and failure_reasons contain an unknown participant")

        if mode == "solo-curriculum-v0":
            candidate = actions.get(participant_ids[0]) if participant_ids else None
            if duration_ticks is None:
                if not isinstance(candidate, ControllerAction):
                    raise ValueError("solo no-input windows require duration_ticks")
                duration_ticks = candidate.control.duration_ticks
        else:
            if duration_ticks is not None and duration_ticks != 10:
                raise ValueError("scored duel windows are fixed at 10 ticks")
            duration_ticks = 10

        decisions: Dict[str, ParticipantDecision] = {}
        for participant_id in participant_ids:
            reason = reasons.get(participant_id)
            candidate = actions.get(participant_id)
            if reason is not None:
                decisions[participant_id] = ParticipantDecision.no_input(reason)
            elif candidate is None:
                decisions[participant_id] = ParticipantDecision.no_input("missing")
            elif not isinstance(candidate, ControllerAction):
                decisions[participant_id] = ParticipantDecision.no_input("invalid")
            elif candidate.episode_id != episode_id:
                decisions[participant_id] = ParticipantDecision.no_input("invalid")
            elif candidate.observation_seq != observation_seq:
                decisions[participant_id] = ParticipantDecision.no_input("stale_observation")
            elif candidate.control.duration_ticks != duration_ticks:
                decisions[participant_id] = ParticipantDecision.no_input("invalid")
            else:
                decisions[participant_id] = ParticipantDecision("accepted", candidate)

        return cls(
            episode_id=episode_id,
            observation_seq=observation_seq,
            mode=mode,
            start_tick=start_tick,
            duration_ticks=duration_ticks,
            decisions=decisions,
        )

    def __post_init__(self) -> None:
        _strict_pattern("episode_id", self.episode_id, _EPISODE_ID)
        _strict_int("observation_seq", self.observation_seq, 0, _EXACT_INTEGER_MAX)
        _strict_int("start_tick", self.start_tick, 0, _EXACT_INTEGER_MAX)
        if self.mode not in _MODES:
            raise ValueError("mode is not defined by this protocol")
        if self.mode == "solo-curriculum-v0":
            _strict_int("duration_ticks", self.duration_ticks, 1, 20)
            expected_participants = 1
        else:
            _strict_int("duration_ticks", self.duration_ticks, 10, 10)
            expected_participants = 2
        if not isinstance(self.decisions, Mapping):
            raise TypeError("decisions must be a mapping")
        if len(self.decisions) != expected_participants:
            raise ValueError(f"{self.mode} requires {expected_participants} decision(s)")
        for participant_id, decision in self.decisions.items():
            _strict_pattern("decision participant_id", participant_id, _PARTICIPANT_ID)
            if not isinstance(decision, ParticipantDecision):
                raise TypeError("decision values must be ParticipantDecision")
            if decision.action is not None:
                if decision.action.episode_id != self.episode_id:
                    raise ValueError("decision action episode_id does not match its window")
                if decision.action.observation_seq != self.observation_seq:
                    raise ValueError("decision action observation_seq does not match its window")
                if decision.action.control.duration_ticks != self.duration_ticks:
                    raise ValueError("decision action duration_ticks does not match its window")

    def controller_states(self) -> Dict[str, ControllerState]:
        """Resolve every decision without semantic repair; no-input is neutral for the horizon."""

        return {
            participant_id: (
                decision.action.control
                if decision.action is not None
                else ControllerState.neutral(self.duration_ticks)
            )
            for participant_id, decision in self.decisions.items()
        }

    def as_dict(self) -> Dict[str, Any]:
        return {
            "episode_id": self.episode_id,
            "observation_seq": self.observation_seq,
            "mode": self.mode,
            "start_tick": self.start_tick,
            "duration_ticks": self.duration_ticks,
            "decisions": {
                participant_id: decision.as_dict()
                for participant_id, decision in self.decisions.items()
            },
        }


@dataclass(frozen=True)
class ReceiptEffect:
    kind: str
    value: int

    def __post_init__(self) -> None:
        _strict_pattern("effect kind", self.kind, _LOWER_ID)
        _strict_int("effect value", self.value, -_EXACT_INTEGER_MAX, _EXACT_INTEGER_MAX)

    def as_dict(self) -> Dict[str, Any]:
        return {"kind": self.kind, "value": self.value}


@dataclass(frozen=True)
class ActionReceipt:
    """Player-scoped authoritative result of one participant decision."""

    action_id: str
    observation_seq: int
    accepted: bool
    start_tick: int
    end_tick: int
    applied_ticks: int
    codes: Tuple[str, ...] = ()
    effects: Tuple[ReceiptEffect, ...] = ()
    disposition: ActionDisposition = "accepted"
    fallback: FallbackPolicy = "none"
    no_input_reason: NoInputReason | None = None

    def __post_init__(self) -> None:
        _strict_pattern("action_id", self.action_id, _ACTION_ID)
        _strict_int("observation_seq", self.observation_seq, 0, _EXACT_INTEGER_MAX)
        _strict_bool("accepted", self.accepted)
        _strict_int("start_tick", self.start_tick, 0, _EXACT_INTEGER_MAX)
        _strict_int("end_tick", self.end_tick, 0, _EXACT_INTEGER_MAX)
        _strict_int("applied_ticks", self.applied_ticks, 0, 20)
        if self.end_tick < self.start_tick or self.end_tick - self.start_tick != self.applied_ticks:
            raise ValueError("receipt tick interval must equal applied_ticks")
        _strict_tuple("codes", self.codes)
        _strict_tuple("effects", self.effects)
        if len(self.codes) > 16 or len(set(self.codes)) != len(self.codes):
            raise ValueError("codes must contain at most 16 unique values")
        for code in self.codes:
            _strict_pattern("receipt code", code, _LOWER_ID)
        if len(self.effects) > 32 or any(
            not isinstance(effect, ReceiptEffect) for effect in self.effects
        ):
            raise ValueError("effects must contain at most 32 ReceiptEffect values")
        if self.disposition == "accepted":
            if not self.accepted or self.fallback != "none" or self.no_input_reason is not None:
                raise ValueError("accepted receipt disposition is inconsistent")
        elif self.disposition == "no_input":
            if self.accepted or self.fallback != "neutral":
                raise ValueError("no_input receipt must record a rejected neutral fallback")
            if self.no_input_reason not in ("missing", "invalid", "timeout", "stale_observation"):
                raise ValueError("no_input receipt requires a recognized no_input_reason")
        else:
            raise ValueError("unsupported receipt disposition")

    def as_dict(self) -> Dict[str, Any]:
        return {
            "action_id": self.action_id,
            "observation_seq": self.observation_seq,
            "accepted": self.accepted,
            "start_tick": self.start_tick,
            "end_tick": self.end_tick,
            "applied_ticks": self.applied_ticks,
            "codes": list(self.codes),
            "effects": [effect.as_dict() for effect in self.effects],
            "disposition": self.disposition,
            "fallback": self.fallback,
            "no_input_reason": self.no_input_reason,
        }


@dataclass(frozen=True)
class AuthorityEvent:
    """A bounded, public authority event; never an authority-only state snapshot."""

    event_id: str
    tick: int
    kind: str
    summary: str
    participant_ids: Tuple[str, ...] = ()
    data: Mapping[str, JsonScalar] = field(default_factory=dict)

    def __post_init__(self) -> None:
        _strict_pattern("event_id", self.event_id, _EVENT_ID)
        _strict_int("tick", self.tick, 0, _EXACT_INTEGER_MAX)
        _strict_pattern("event kind", self.kind, _LOWER_ID)
        _strict_string("event summary", self.summary, maximum_utf8_bytes=240)
        _strict_tuple("event participant_ids", self.participant_ids)
        if len(set(self.participant_ids)) != len(self.participant_ids):
            raise ValueError("event participant_ids must be unique")
        for participant_id in self.participant_ids:
            _strict_pattern("event participant_id", participant_id, _PARTICIPANT_ID)
        if not isinstance(self.data, Mapping):
            raise TypeError("event data must be a mapping")
        for key, value in self.data.items():
            _strict_pattern("event data key", key, _LOWER_ID)
            if isinstance(value, bool):
                continue
            if isinstance(value, int):
                _strict_int("event data integer", value, -_EXACT_INTEGER_MAX, _EXACT_INTEGER_MAX)
            elif isinstance(value, str):
                _strict_string("event data string", value, maximum_utf8_bytes=240)
            elif value is not None:
                raise TypeError("event data values must be JSON scalars without floats")

    def as_dict(self) -> Dict[str, Any]:
        return {
            "event_id": self.event_id,
            "tick": self.tick,
            "kind": self.kind,
            "summary": self.summary,
            "participant_ids": list(self.participant_ids),
            "data": dict(self.data),
        }


# The short feature-plan name remains convenient while AuthorityEvent makes provenance explicit.
Event = AuthorityEvent


@dataclass(frozen=True)
class TerminalState:
    ended: bool
    outcome: TerminalOutcome
    reason: str

    def __post_init__(self) -> None:
        _strict_bool("terminal ended", self.ended)
        if self.outcome not in ("running", "success", "failure", "win", "loss", "draw", "void"):
            raise ValueError("unsupported terminal outcome")
        _strict_pattern("terminal reason", self.reason, _LOWER_ID)
        if self.ended == (self.outcome == "running"):
            raise ValueError("terminal ended and outcome are inconsistent")

    def as_dict(self) -> Dict[str, Any]:
        return {"ended": self.ended, "outcome": self.outcome, "reason": self.reason}


@dataclass(frozen=True)
class MultiParticipantStepResult:
    """One joint authority window and participant-scoped results from its boundary."""

    observations: Mapping[str, Mapping[str, Any]]
    receipts: Mapping[str, ActionReceipt]
    public_events: Tuple[AuthorityEvent, ...]
    state_hash: str
    terminal: TerminalState

    def __post_init__(self) -> None:
        if not isinstance(self.observations, Mapping) or not self.observations:
            raise ValueError("observations must be a non-empty participant mapping")
        if not isinstance(self.receipts, Mapping):
            raise TypeError("receipts must be a participant mapping")
        if set(self.observations) != set(self.receipts):
            raise ValueError("observations and receipts must have identical participant keys")
        for participant_id, observation in self.observations.items():
            _strict_pattern("result participant_id", participant_id, _PARTICIPANT_ID)
            if not isinstance(observation, Mapping):
                raise TypeError("observation values must be mappings")
            if not isinstance(self.receipts[participant_id], ActionReceipt):
                raise TypeError("receipt values must be ActionReceipt")
        _strict_tuple("public_events", self.public_events)
        if any(not isinstance(event, AuthorityEvent) for event in self.public_events):
            raise TypeError("public_events values must be AuthorityEvent")
        _strict_string("state_hash", self.state_hash)
        if len(self.state_hash) != 64 or any(
            ch not in "0123456789abcdef" for ch in self.state_hash
        ):
            raise ValueError("state_hash must be lowercase SHA-256")
        if not isinstance(self.terminal, TerminalState):
            raise TypeError("terminal must be TerminalState")

    def as_dict(self) -> Dict[str, Any]:
        return {
            "observations": {
                participant_id: dict(observation)
                for participant_id, observation in self.observations.items()
            },
            "receipts": {
                participant_id: receipt.as_dict()
                for participant_id, receipt in self.receipts.items()
            },
            "public_events": [event.as_dict() for event in self.public_events],
            "state_hash": self.state_hash,
            "terminal": self.terminal.as_dict(),
        }


@runtime_checkable
class EnvironmentAdapter(Protocol):
    """Universal bridge implemented by WorldArena and future environments."""

    def manifest(self) -> Mapping[str, Any]:
        """Return the immutable machine-readable environment manifest."""

    def capabilities(self) -> CapabilityStatus:
        """Return runnable combinations; descriptive manifest entries need not be implemented."""

    def reset(self, config: EpisodeConfig) -> Mapping[str, Mapping[str, Any]]:
        """Start an episode and return one player-scoped observation per participant."""

    def observe(self, participant_id: str) -> Mapping[str, Any]:
        """Return one current player-scoped observation without advancing time."""

    def step(self, window: DecisionWindow) -> MultiParticipantStepResult:
        """Apply one joint decision window and advance deterministic authority ticks."""

    def render(self, participant_id: str, sensor_id: str) -> bytes:
        """Return the exact encoded participant sensor frame referenced by an observation."""

    def state(self) -> Mapping[str, Any]:
        """Return bounded public episode state suitable for orchestration and UI."""

    def close(self) -> None:
        """Release environment resources idempotently."""


@runtime_checkable
class AsyncEnvironmentSession(Protocol):
    """Asynchronous lifecycle used by managed environment authority processes."""

    async def reset(self) -> Mapping[str, Mapping[str, Any]]:
        """Start the session's preconfigured episode and return participant observations."""

    async def observe(self, participant_id: str) -> Mapping[str, Any]:
        """Return the cached observation at the current authority boundary."""

    async def step(self, window: DecisionWindow) -> MultiParticipantStepResult:
        """Execute one authenticated joint decision window."""

    async def render(
        self,
        participant_id: str,
        sensor_id: str,
        transport_ref: str,
        observation_seq: int,
    ) -> bytes:
        """Return a participant frame or report the profile as unavailable."""

    async def state(self) -> Mapping[str, Any]:
        """Return bounded public lifecycle and terminal state."""

    async def close(self) -> None:
        """Close transport and reap the owned authority process idempotently."""
