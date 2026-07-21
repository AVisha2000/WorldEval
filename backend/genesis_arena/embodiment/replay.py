"""Canonical append-only replay ledger for managed embodiment episodes."""

from __future__ import annotations

import hashlib
import hmac
import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping

from .protocol import (
    EmbodimentProtocolPackage,
    ProtocolValidationError,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)

REPLAY_SCHEMA_VERSION = "llm-controller/episode-replay/1.0.0"
PROTOCOL_VERSION = "llm-controller/0.1.0"
MAX_REPLAY_BYTES = 16 * 1024 * 1024
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_EPISODE = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")


class ReplayValidationError(ValueError):
    """Stable replay construction or verification failure."""


@dataclass
class ReplayLedger:
    config: Mapping[str, Any]
    config_sha256: str
    protocol_package_sha256: str
    _initial_observations: Dict[str, Any] | None = field(default=None, init=False, repr=False)
    _initial_state_hash: str | None = field(default=None, init=False, repr=False)
    _steps: List[Dict[str, Any]] = field(default_factory=list, init=False, repr=False)
    _final_terminal: Dict[str, Any] | None = field(default=None, init=False, repr=False)
    _final_state_hash: str | None = field(default=None, init=False, repr=False)
    _sealed: bytes | None = field(default=None, init=False, repr=False)

    def __post_init__(self) -> None:
        if (
            not isinstance(self.config, Mapping)
            or _EPISODE.fullmatch(str(self.config.get("episode_id", ""))) is None
            or _SHA256.fullmatch(self.config_sha256) is None
            or canonical_sha256(self.config) != self.config_sha256
            or _SHA256.fullmatch(self.protocol_package_sha256) is None
        ):
            raise ReplayValidationError("replay configuration is invalid")
        canonical_json_bytes(self.config)

    def record_initial(self, *, observations: Mapping[str, Any], state_hash: str) -> None:
        self._require_mutable()
        if (
            self._initial_observations is not None
            or not isinstance(observations, Mapping)
            or not observations
            or _SHA256.fullmatch(state_hash) is None
        ):
            raise ReplayValidationError("replay initial boundary is invalid")
        self._initial_observations = dict(observations)
        self._initial_state_hash = state_hash
        canonical_json_bytes(self._initial_observations)

    def record_step(
        self,
        *,
        decision_window: Mapping[str, Any],
        result: Mapping[str, Any],
    ) -> None:
        self._require_mutable()
        if self._initial_observations is None or self._final_state_hash is not None:
            raise ReplayValidationError("replay step is out of order")
        if not isinstance(decision_window, Mapping) or not isinstance(result, Mapping):
            raise ReplayValidationError("replay step is invalid")
        observation_seq = decision_window.get("observation_seq")
        if isinstance(observation_seq, bool) or observation_seq != len(self._steps):
            raise ReplayValidationError("replay decision sequence is not contiguous")
        state_hash = result.get("state_hash")
        if not isinstance(state_hash, str) or _SHA256.fullmatch(state_hash) is None:
            raise ReplayValidationError("replay result state hash is invalid")
        record = {"decision_window": dict(decision_window), "result": dict(result)}
        canonical_json_bytes(record)
        self._steps.append(record)

    def seal(self, *, final_terminal: Mapping[str, Any], final_state_hash: str) -> bytes:
        self._require_mutable()
        if (
            self._initial_observations is None
            or self._final_state_hash is not None
            or not self._steps
            or _SHA256.fullmatch(final_state_hash) is None
        ):
            raise ReplayValidationError("replay terminal boundary is invalid")
        final_result = self._steps[-1]["result"]
        terminal = final_result.get("terminal")
        if (
            final_result.get("state_hash") != final_state_hash
            or not isinstance(terminal, Mapping)
            or terminal.get("ended") is not True
            or not isinstance(final_terminal, Mapping)
            or dict(terminal) != dict(final_terminal)
        ):
            raise ReplayValidationError("replay final step is not terminal")
        self._final_terminal = dict(final_terminal)
        self._final_state_hash = final_state_hash
        body = self._body()
        digest = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
        payload = canonical_json_bytes({**body, "ledger_sha256": digest})
        if len(payload) > MAX_REPLAY_BYTES:
            raise ReplayValidationError("replay exceeds byte limit")
        self._sealed = payload
        return payload

    @property
    def sealed_bytes(self) -> bytes:
        if self._sealed is None:
            raise ReplayValidationError("replay is not sealed")
        return self._sealed

    def _body(self) -> Dict[str, Any]:
        return {
            "schema_version": REPLAY_SCHEMA_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "protocol_package_sha256": self.protocol_package_sha256,
            "config": dict(self.config),
            "config_sha256": self.config_sha256,
            "initial_observations": self._initial_observations,
            "initial_state_hash": self._initial_state_hash,
            "steps": list(self._steps),
            "final_terminal": self._final_terminal,
            "final_state_hash": self._final_state_hash,
        }

    def _require_mutable(self) -> None:
        if self._sealed is not None:
            raise ReplayValidationError("replay is already sealed")


def verify_replay_bytes(
    payload: bytes, *, package: EmbodimentProtocolPackage | None = None
) -> Mapping[str, Any]:
    """Verify canonical encoding, exact shape, ordering, and the replay seal."""

    if not isinstance(payload, bytes) or not payload or len(payload) > MAX_REPLAY_BYTES:
        raise ReplayValidationError("replay bytes are invalid")
    try:
        value = strict_json_loads(payload)
        if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
            raise ReplayValidationError("replay is not canonical")
    except ProtocolValidationError as error:
        raise ReplayValidationError("replay JSON is invalid") from error
    required = {
        "schema_version",
        "protocol_version",
        "protocol_package_sha256",
        "config",
        "config_sha256",
        "initial_observations",
        "initial_state_hash",
        "steps",
        "final_terminal",
        "final_state_hash",
        "ledger_sha256",
    }
    if set(value) != required:
        raise ReplayValidationError("replay envelope fields differ")
    if (
        value["schema_version"] != REPLAY_SCHEMA_VERSION
        or value["protocol_version"] != PROTOCOL_VERSION
        or _SHA256.fullmatch(value["protocol_package_sha256"]) is None
    ):
        raise ReplayValidationError("replay identity is invalid")
    if package is not None:
        try:
            package.validate("episode-replay", value)
        except ProtocolValidationError as error:
            raise ReplayValidationError("replay schema validation failed") from error
        if value["protocol_package_sha256"] != package.package_sha256:
            raise ReplayValidationError("replay protocol package hash differs")
    body = {key: child for key, child in value.items() if key != "ledger_sha256"}
    expected_digest = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
    digest = value["ledger_sha256"]
    if (
        not isinstance(digest, str)
        or _SHA256.fullmatch(digest) is None
        or not hmac.compare_digest(digest, expected_digest)
    ):
        raise ReplayValidationError("replay seal differs")
    if (
        not isinstance(value["config"], dict)
        or _SHA256.fullmatch(value["config_sha256"]) is None
        or canonical_sha256(value["config"]) != value["config_sha256"]
    ):
        raise ReplayValidationError("replay configuration is invalid")
    _verify_replay_semantics(value)
    return body


def _verify_replay_semantics(replay: Mapping[str, Any]) -> None:
    config = replay["config"]
    episode_id = config.get("episode_id")
    mode = config.get("mode")
    profile = config.get("observation_profile")
    participant_ids = config.get("participant_ids")
    if (
        not isinstance(episode_id, str)
        or _EPISODE.fullmatch(episode_id) is None
        or mode not in ("solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0")
        or not isinstance(profile, str)
        or not isinstance(participant_ids, list)
        or not participant_ids
        or len(participant_ids) != len(set(participant_ids))
        or any(not isinstance(participant_id, str) for participant_id in participant_ids)
    ):
        raise ReplayValidationError("replay configuration semantics differ")
    participants = set(participant_ids)
    expected_count = 1 if mode == "solo-curriculum-v0" else 2
    if len(participants) != expected_count:
        raise ReplayValidationError("replay participant configuration differs")

    initial = replay["initial_observations"]
    if (
        not isinstance(initial, dict)
        or set(initial) != participants
        or _SHA256.fullmatch(replay["initial_state_hash"]) is None
    ):
        raise ReplayValidationError("replay initial boundary is invalid")
    previous_tick = _verify_observation_boundary(
        initial,
        participants=participants,
        episode_id=episode_id,
        profile=profile,
        observation_seq=0,
        terminal=None,
    )
    if previous_tick != 0 or any(
        not isinstance(observation.get("terminal"), dict)
        or observation["terminal"].get("ended") is not False
        or observation.get("previous_receipt") is not None
        for observation in initial.values()
    ):
        raise ReplayValidationError("replay initial observation semantics differ")

    steps = replay["steps"]
    if not isinstance(steps, list) or not steps:
        raise ReplayValidationError("replay steps are invalid")
    previous_hash = replay["initial_state_hash"]
    for index, record in enumerate(steps):
        if not isinstance(record, dict) or set(record) != {"decision_window", "result"}:
            raise ReplayValidationError("replay step fields differ")
        window = record["decision_window"]
        result = record["result"]
        if not isinstance(window, dict) or not isinstance(result, dict):
            raise ReplayValidationError("replay step payload is invalid")
        duration_ticks = window.get("duration_ticks")
        if (
            window.get("episode_id") != episode_id
            or window.get("mode") != mode
            or not _is_int(window.get("observation_seq"), index)
            or not _is_int(window.get("start_tick"), previous_tick)
            or isinstance(duration_ticks, bool)
            or not isinstance(duration_ticks, int)
            or not (1 <= duration_ticks <= 20)
            or (mode != "solo-curriculum-v0" and duration_ticks != 10)
            or not isinstance(window.get("decisions"), dict)
            or set(window["decisions"]) != participants
        ):
            raise ReplayValidationError("replay decision boundary differs")
        terminal = result.get("terminal")
        observations = result.get("observations")
        receipts = result.get("receipts")
        if (
            not isinstance(terminal, dict)
            or not isinstance(observations, dict)
            or not isinstance(receipts, dict)
            or set(observations) != participants
            or set(receipts) != participants
            or not isinstance(result.get("state_hash"), str)
            or _SHA256.fullmatch(result["state_hash"]) is None
        ):
            raise ReplayValidationError("replay result boundary is invalid")
        end_tick = _verify_observation_boundary(
            observations,
            participants=participants,
            episode_id=episode_id,
            profile=profile,
            observation_seq=index + 1,
            terminal=terminal,
        )
        if end_tick < previous_tick or end_tick > previous_tick + duration_ticks:
            raise ReplayValidationError("replay result tick exceeds decision window")
        ended = terminal.get("ended") is True
        if ended != (index == len(steps) - 1):
            raise ReplayValidationError("replay terminal ordering differs")
        if not ended and end_tick != previous_tick + duration_ticks:
            raise ReplayValidationError("replay nonterminal window did not fully advance")
        for participant_id in participant_ids:
            _verify_receipt(
                receipt=receipts[participant_id],
                decision=window["decisions"][participant_id],
                episode_id=episode_id,
                observation_seq=index,
                start_tick=previous_tick,
                end_tick=end_tick,
                duration_ticks=duration_ticks,
                observation=observations[participant_id],
            )
        events = result.get("public_events")
        if not isinstance(events, list) or any(
            not isinstance(event, dict)
            or not _is_bounded_tick(event.get("tick"), previous_tick, end_tick)
            for event in events
        ):
            raise ReplayValidationError("replay public event boundary differs")
        previous_tick = end_tick
        previous_hash = result["state_hash"]

    terminal = steps[-1]["result"]["terminal"]
    if (
        replay["final_state_hash"] != previous_hash
        or terminal.get("ended") is not True
        or replay["final_terminal"] != terminal
    ):
        raise ReplayValidationError("replay terminal boundary differs")


def _verify_observation_boundary(
    observations: Mapping[str, Any],
    *,
    participants: set[str],
    episode_id: str,
    profile: str,
    observation_seq: int,
    terminal: Mapping[str, Any] | None,
) -> int:
    ticks: set[int] = set()
    for participant_id in participants:
        observation = observations.get(participant_id)
        if (
            not isinstance(observation, dict)
            or observation.get("episode_id") != episode_id
            or observation.get("profile") != profile
            or not _is_int(observation.get("observation_seq"), observation_seq)
            or isinstance(observation.get("tick"), bool)
            or not isinstance(observation.get("tick"), int)
            or observation["tick"] < 0
            or (terminal is not None and observation.get("terminal") != terminal)
        ):
            raise ReplayValidationError("replay observation boundary differs")
        ticks.add(observation["tick"])
    if len(ticks) != 1:
        raise ReplayValidationError("replay participant observation ticks differ")
    return next(iter(ticks))


def _verify_receipt(
    *,
    receipt: Any,
    decision: Any,
    episode_id: str,
    observation_seq: int,
    start_tick: int,
    end_tick: int,
    duration_ticks: int,
    observation: Mapping[str, Any],
) -> None:
    if (
        not isinstance(receipt, dict)
        or not isinstance(decision, dict)
        or not _is_int(receipt.get("observation_seq"), observation_seq)
        or not _is_int(receipt.get("start_tick"), start_tick)
        or not _is_int(receipt.get("end_tick"), end_tick)
        or not _is_int(receipt.get("applied_ticks"), end_tick - start_tick)
        or observation.get("previous_receipt") != receipt
    ):
        raise ReplayValidationError("replay receipt boundary differs")
    disposition = decision.get("disposition")
    if disposition == "accepted":
        action = decision.get("action")
        if (
            not isinstance(action, dict)
            or action.get("episode_id") != episode_id
            or not _is_int(action.get("observation_seq"), observation_seq)
            or not isinstance(action.get("control"), dict)
            or not _is_int(action["control"].get("duration_ticks"), duration_ticks)
            or receipt.get("action_id") != action.get("action_id")
            or receipt.get("accepted") is not True
            or receipt.get("disposition") != "accepted"
            or receipt.get("fallback") != "none"
            or receipt.get("no_input_reason") is not None
        ):
            raise ReplayValidationError("replay accepted receipt differs from decision")
    elif disposition == "no_input":
        if (
            decision.get("action") is not None
            or decision.get("fallback") != "neutral"
            or receipt.get("accepted") is not False
            or receipt.get("disposition") != "no_input"
            or receipt.get("fallback") != "neutral"
            or receipt.get("no_input_reason") != decision.get("no_input_reason")
            or decision.get("no_input_reason")
            not in ("missing", "invalid", "timeout", "stale_observation")
        ):
            raise ReplayValidationError("replay no-input receipt differs from decision")
    else:
        raise ReplayValidationError("replay decision disposition is invalid")


def _is_int(value: Any, expected: int) -> bool:
    return not isinstance(value, bool) and isinstance(value, int) and value == expected


def _is_bounded_tick(value: Any, minimum: int, maximum: int) -> bool:
    return not isinstance(value, bool) and isinstance(value, int) and minimum <= value <= maximum


__all__ = [
    "MAX_REPLAY_BYTES",
    "PROTOCOL_VERSION",
    "REPLAY_SCHEMA_VERSION",
    "ReplayLedger",
    "ReplayValidationError",
    "verify_replay_bytes",
]
