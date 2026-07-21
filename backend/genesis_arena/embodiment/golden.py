"""Strict golden-transcript certification for deterministic embodiment authority.

Golden transcripts contain only player-visible observations, public authority events,
receipts, opaque checkpoint hashes, and the decision windows that produced them.  They
intentionally never contain authority checkpoints or spectator-only state.
"""

from __future__ import annotations

import hashlib
import hmac
import re
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Sequence

from .protocol import (
    EmbodimentProtocolPackage,
    ProtocolValidationError,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)

GOLDEN_SCHEMA_VERSION = "llm-controller/golden-transcript/1.0.0"
PROTOCOL_VERSION = "llm-controller/0.1.0"
MAX_GOLDEN_BYTES = 16 * 1024 * 1024

_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_TRANSCRIPT_ID = re.compile(r"^[a-z][a-z0-9-]{0,95}$")
_PARTICIPANT_ID = re.compile(r"^participant_[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_ROOT_FIELDS = {
    "schema_version",
    "protocol_version",
    "transcript_id",
    "config",
    "config_sha256",
    "initial_boundary",
    "steps",
    "terminal_boundary",
    "transcript_sha256",
}
_INITIAL_FIELDS = {"observations", "state_hash"}
_STEP_FIELDS = {
    "index",
    "decision_window",
    "result",
    "event_sequence_sha256",
    "state_hash",
}
_TERMINAL_FIELDS = {"terminal", "state_hash"}
_CONFIG_FIELDS = {
    "protocol_version",
    "episode_id",
    "mode",
    "task_id",
    "seed",
    "observation_profile",
    "timing_track",
    "maximum_episode_ticks",
    "participant_ids",
}
_WINDOW_FIELDS = {
    "episode_id",
    "observation_seq",
    "mode",
    "start_tick",
    "duration_ticks",
    "decisions",
}


class GoldenTranscriptError(ValueError):
    """A stable failure raised for an invalid or diverging golden transcript."""


def seal_golden_body(body: Mapping[str, Any]) -> Dict[str, Any]:
    """Return a canonicalizable transcript envelope sealed over its complete body."""

    if not isinstance(body, Mapping) or "transcript_sha256" in body:
        raise GoldenTranscriptError("golden body is invalid")
    material = dict(body)
    if set(material) != _ROOT_FIELDS - {"transcript_sha256"}:
        raise GoldenTranscriptError("golden body fields differ")
    digest = hashlib.sha256(canonical_json_bytes(material)).hexdigest()
    return {**material, "transcript_sha256": digest}


def load_golden_transcript(
    path: Path, *, package: EmbodimentProtocolPackage | None = None
) -> Mapping[str, Any]:
    """Load and verify one canonical golden transcript without mutating it."""

    if not isinstance(path, Path):
        raise TypeError("golden transcript path must be a Path")
    try:
        payload = path.read_bytes()
    except OSError as error:
        raise GoldenTranscriptError("golden transcript could not be read") from error
    return verify_golden_bytes(payload, package=package)


def verify_golden_bytes(
    payload: bytes, *, package: EmbodimentProtocolPackage | None = None
) -> Mapping[str, Any]:
    """Verify canonical encoding, exact structure, schemas, ordering, and all digests."""

    if not isinstance(payload, bytes) or not payload or len(payload) > MAX_GOLDEN_BYTES:
        raise GoldenTranscriptError("golden transcript bytes are invalid")
    try:
        value = strict_json_loads(payload)
        # Checked-in artifacts use one POSIX record terminator.  The JSON value before it is JCS;
        # no other leading or trailing whitespace is accepted.
        if not isinstance(value, dict) or canonical_json_bytes(value) + b"\n" != payload:
            raise GoldenTranscriptError("golden transcript is not canonical")
    except ProtocolValidationError as error:
        raise GoldenTranscriptError("golden transcript JSON is invalid") from error

    _require_fields(value, _ROOT_FIELDS, "golden transcript")
    if (
        value["schema_version"] != GOLDEN_SCHEMA_VERSION
        or value["protocol_version"] != PROTOCOL_VERSION
        or not isinstance(value["transcript_id"], str)
        or _TRANSCRIPT_ID.fullmatch(value["transcript_id"]) is None
    ):
        raise GoldenTranscriptError("golden transcript identity is invalid")

    seal = value["transcript_sha256"]
    body = {key: child for key, child in value.items() if key != "transcript_sha256"}
    expected_seal = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
    if (
        not isinstance(seal, str)
        or _SHA256.fullmatch(seal) is None
        or not hmac.compare_digest(seal, expected_seal)
    ):
        raise GoldenTranscriptError("golden transcript seal differs")

    config = value["config"]
    if (
        not isinstance(config, dict)
        or set(config) != _CONFIG_FIELDS
        or config.get("protocol_version") != PROTOCOL_VERSION
        or not _valid_sha256(value["config_sha256"])
        or canonical_sha256(config) != value["config_sha256"]
    ):
        raise GoldenTranscriptError("golden transcript configuration is invalid")
    participant_ids = config.get("participant_ids")
    if (
        not isinstance(participant_ids, list)
        or not participant_ids
        or any(
            not isinstance(participant_id, str) or _PARTICIPANT_ID.fullmatch(participant_id) is None
            for participant_id in participant_ids
        )
        or len(participant_ids) != len(set(participant_ids))
    ):
        raise GoldenTranscriptError("golden transcript participants are invalid")
    if package is not None:
        _validate_schema(package, "episode-config", config)

    initial = value["initial_boundary"]
    if not isinstance(initial, dict):
        raise GoldenTranscriptError("golden initial boundary is invalid")
    _require_fields(initial, _INITIAL_FIELDS, "golden initial boundary")
    _verify_observations(
        initial["observations"], participant_ids, package=package, expected_sequence=0
    )
    if not _valid_sha256(initial["state_hash"]):
        raise GoldenTranscriptError("golden initial state hash is invalid")
    initial_terminals = [
        observation.get("terminal") for observation in initial["observations"].values()
    ]
    if any(
        not isinstance(terminal, dict) or terminal.get("ended") is not False
        for terminal in initial_terminals
    ):
        raise GoldenTranscriptError("golden transcript starts terminal")

    steps = value["steps"]
    if not isinstance(steps, list) or not steps:
        raise GoldenTranscriptError("golden transcript steps are invalid")
    previous_tick = _common_observation_tick(initial["observations"])
    event_ids: set[str] = set()
    previous_event_tick = -1
    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            raise GoldenTranscriptError("golden step is invalid")
        _require_fields(step, _STEP_FIELDS, "golden step")
        if isinstance(step["index"], bool) or step["index"] != index:
            raise GoldenTranscriptError("golden step indices are not contiguous")
        window = step["decision_window"]
        result = step["result"]
        if not isinstance(window, dict) or not isinstance(result, dict):
            raise GoldenTranscriptError("golden step payload is invalid")
        _require_fields(window, _WINDOW_FIELDS, "golden decision window")
        if package is not None:
            _validate_schema(package, "decision-window", window)
            _validate_schema(package, "multi-participant-step-result", result)
        if (
            window.get("episode_id") != config.get("episode_id")
            or window.get("mode") != config.get("mode")
            or isinstance(window.get("observation_seq"), bool)
            or window.get("observation_seq") != index
            or isinstance(window.get("start_tick"), bool)
            or window.get("start_tick") != previous_tick
            or isinstance(window.get("duration_ticks"), bool)
            or not isinstance(window.get("duration_ticks"), int)
            or not 1 <= window["duration_ticks"] <= 20
            or not isinstance(window.get("decisions"), dict)
            or list(sorted(window["decisions"])) != list(sorted(participant_ids))
        ):
            raise GoldenTranscriptError("golden decision window boundary differs")
        _verify_result(
            result,
            participant_ids,
            index=index,
            start_tick=previous_tick,
            duration_ticks=window["duration_ticks"],
            package=package,
        )
        if result["state_hash"] != step["state_hash"] or not _valid_sha256(step["state_hash"]):
            raise GoldenTranscriptError("golden step state hash differs")
        events = result["public_events"]
        if (
            not _valid_sha256(step["event_sequence_sha256"])
            or canonical_sha256(events) != step["event_sequence_sha256"]
        ):
            raise GoldenTranscriptError("golden event-sequence digest differs")
        for event in events:
            event_id = event.get("event_id")
            event_tick = event.get("tick")
            if (
                not isinstance(event_id, str)
                or event_id in event_ids
                or isinstance(event_tick, bool)
                or not isinstance(event_tick, int)
                or not previous_tick
                <= event_tick
                <= _common_observation_tick(result["observations"])
                or event_tick < previous_event_tick
            ):
                raise GoldenTranscriptError("golden authority event sequence is invalid")
            event_ids.add(event_id)
            previous_event_tick = event_tick
        ended = result["terminal"].get("ended") is True
        if ended != (index == len(steps) - 1):
            raise GoldenTranscriptError("golden terminal ordering differs")
        previous_tick = _common_observation_tick(result["observations"])

    terminal_boundary = value["terminal_boundary"]
    if not isinstance(terminal_boundary, dict):
        raise GoldenTranscriptError("golden terminal boundary is invalid")
    _require_fields(terminal_boundary, _TERMINAL_FIELDS, "golden terminal boundary")
    final_result = steps[-1]["result"]
    if (
        terminal_boundary["terminal"] != final_result["terminal"]
        or terminal_boundary["terminal"].get("ended") is not True
        or terminal_boundary["state_hash"] != final_result["state_hash"]
        or not _valid_sha256(terminal_boundary["state_hash"])
    ):
        raise GoldenTranscriptError("golden terminal boundary differs")
    return value


def verify_runtime_output(
    transcript: Mapping[str, Any],
    *,
    config: Mapping[str, Any],
    initial_observations: Mapping[str, Any],
    initial_state_hash: str,
    steps: Iterable[Mapping[str, Any]],
) -> None:
    """Compare an authority run against every certified boundary in a transcript."""

    if canonical_json_bytes(config) != canonical_json_bytes(transcript.get("config")):
        raise GoldenTranscriptError("runtime configuration differs from golden transcript")
    initial = transcript.get("initial_boundary")
    if not isinstance(initial, Mapping):
        raise GoldenTranscriptError("runtime transcript initial boundary is missing")
    if canonical_json_bytes(initial_observations) != canonical_json_bytes(initial["observations"]):
        raise GoldenTranscriptError("runtime initial observations differ")
    if initial_state_hash != initial["state_hash"]:
        raise GoldenTranscriptError("runtime initial state hash differs")
    actual_steps = list(steps)
    expected_steps = transcript.get("steps")
    if not isinstance(expected_steps, Sequence) or len(actual_steps) != len(expected_steps):
        raise GoldenTranscriptError("runtime step count differs")
    for index, (actual, expected) in enumerate(zip(actual_steps, expected_steps)):
        if not isinstance(actual, Mapping) or set(actual) != {"decision_window", "result"}:
            raise GoldenTranscriptError(f"runtime step {index} shape differs")
        if canonical_json_bytes(actual["decision_window"]) != canonical_json_bytes(
            expected["decision_window"]
        ):
            raise GoldenTranscriptError(f"runtime decision window {index} differs")
        if canonical_json_bytes(actual["result"]) != canonical_json_bytes(expected["result"]):
            raise GoldenTranscriptError(f"runtime result {index} differs")


def _verify_result(
    result: Mapping[str, Any],
    participant_ids: Sequence[str],
    *,
    index: int,
    start_tick: int,
    duration_ticks: int,
    package: EmbodimentProtocolPackage | None,
) -> None:
    required = {"observations", "receipts", "public_events", "state_hash", "terminal"}
    _require_fields(result, required, "golden step result")
    _verify_observations(
        result["observations"], participant_ids, package=package, expected_sequence=index + 1
    )
    receipts = result["receipts"]
    if not isinstance(receipts, dict) or set(receipts) != set(participant_ids):
        raise GoldenTranscriptError("golden result receipts differ")
    end_tick = _common_observation_tick(result["observations"])
    if end_tick > start_tick + duration_ticks:
        raise GoldenTranscriptError("golden result exceeded its decision horizon")
    for receipt in receipts.values():
        if (
            not isinstance(receipt, dict)
            or isinstance(receipt.get("observation_seq"), bool)
            or receipt.get("observation_seq") != index
            or receipt.get("start_tick") != start_tick
            or receipt.get("end_tick") != end_tick
            or isinstance(receipt.get("applied_ticks"), bool)
            or receipt.get("applied_ticks") != end_tick - start_tick
        ):
            raise GoldenTranscriptError("golden result receipt boundary differs")
    if not isinstance(result["public_events"], list) or not _valid_sha256(result["state_hash"]):
        raise GoldenTranscriptError("golden result boundary is invalid")
    terminal = result["terminal"]
    if not isinstance(terminal, dict):
        raise GoldenTranscriptError("golden result terminal is invalid")
    if terminal.get("ended") is not True and end_tick != start_tick + duration_ticks:
        raise GoldenTranscriptError("golden nonterminal result did not consume its window")
    for observation in result["observations"].values():
        if observation.get("terminal") != terminal:
            raise GoldenTranscriptError("golden observation terminal differs")


def _verify_observations(
    observations: Any,
    participant_ids: Sequence[str],
    *,
    package: EmbodimentProtocolPackage | None,
    expected_sequence: int,
) -> None:
    if not isinstance(observations, dict) or set(observations) != set(participant_ids):
        raise GoldenTranscriptError("golden observations differ from participants")
    for observation in observations.values():
        if (
            not isinstance(observation, dict)
            or observation.get("observation_seq") != expected_sequence
        ):
            raise GoldenTranscriptError("golden observation sequence differs")
        if package is not None:
            _validate_schema(package, "observation", observation)


def _common_observation_tick(observations: Mapping[str, Any]) -> int:
    ticks = {observation.get("tick") for observation in observations.values()}
    if len(ticks) != 1:
        raise GoldenTranscriptError("golden participant observation ticks differ")
    tick = next(iter(ticks))
    if isinstance(tick, bool) or not isinstance(tick, int) or tick < 0:
        raise GoldenTranscriptError("golden observation tick is invalid")
    return tick


def _validate_schema(
    package: EmbodimentProtocolPackage, schema_name: str, instance: Mapping[str, Any]
) -> None:
    try:
        package.validate(schema_name, instance)
    except ProtocolValidationError as error:
        raise GoldenTranscriptError(f"golden {schema_name} schema validation failed") from error


def _require_fields(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise GoldenTranscriptError(f"{label} fields differ")


def _valid_sha256(value: Any) -> bool:
    return isinstance(value, str) and _SHA256.fullmatch(value) is not None


__all__ = [
    "GOLDEN_SCHEMA_VERSION",
    "MAX_GOLDEN_BYTES",
    "PROTOCOL_VERSION",
    "GoldenTranscriptError",
    "load_golden_transcript",
    "seal_golden_body",
    "verify_golden_bytes",
    "verify_runtime_output",
]
