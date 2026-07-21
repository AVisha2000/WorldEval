from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, Mapping, Set, Tuple

from pydantic import ValidationError

from .budget import ActionBudget, ActionBudgetError, action_batch_budget
from .canonical import DuelCanonicalError, strict_json_loads
from .models import ActionBatch
from .protocol import DUEL_PROTOCOL_VERSION
from .schema_validation import DuelSchemaValidator, ProtocolSchemaError

MAX_OUTPUT_BYTES = 16_384
MAX_JSON_DEPTH = 16


class BatchErrorCode(str, Enum):
    INVALID_JSON = "invalid_json"
    SCHEMA_MISMATCH = "schema_mismatch"
    UNSUPPORTED_VERSION = "unsupported_version"
    WRONG_MATCH = "wrong_match"
    WRONG_OBSERVATION = "wrong_observation"
    OBSERVATION_HASH_MISMATCH = "observation_hash_mismatch"
    EXPIRED_BATCH = "expired_batch"
    DUPLICATE_BATCH = "duplicate_batch"
    DUPLICATE_COMMAND_ID = "duplicate_command_id"
    TOO_MANY_COMMANDS = "too_many_commands"
    ATOMIC_BUDGET_EXCEEDED = "atomic_budget_exceeded"
    TOO_MANY_ACTORS = "too_many_actors"


@dataclass(frozen=True)
class BatchValidationContext:
    match_id: str
    observation_seq: int
    observation_hash: str
    application_tick: int
    controller_valid_until_tick: int
    squad_sizes: Mapping[str, int]
    transport_passenger_counts: Mapping[str, int]


@dataclass(frozen=True)
class BatchValidationResult:
    batch: ActionBatch | None
    budget: ActionBudget | None
    code: BatchErrorCode | None

    @property
    def valid(self) -> bool:
        return self.batch is not None and self.code is None


class ActionEnvelopeValidator:
    """Fail-closed model-output validation with no prose/JSON repair path."""

    def __init__(self, schema_validator: DuelSchemaValidator | None = None) -> None:
        self.schema_validator = schema_validator

    def validate(
        self, raw_output: str | bytes | bytearray, context: BatchValidationContext
    ) -> BatchValidationResult:
        try:
            raw_bytes = (
                raw_output.encode("utf-8") if isinstance(raw_output, str) else bytes(raw_output)
            )
        except (UnicodeError, TypeError, ValueError):
            return _failure(BatchErrorCode.INVALID_JSON)
        if len(raw_bytes) > MAX_OUTPUT_BYTES:
            return _failure(BatchErrorCode.SCHEMA_MISMATCH)
        try:
            value = strict_json_loads(raw_bytes)
        except (DuelCanonicalError, UnicodeError, RecursionError):
            return _failure(BatchErrorCode.INVALID_JSON)
        if _json_depth(value) > MAX_JSON_DEPTH:
            return _failure(BatchErrorCode.SCHEMA_MISMATCH)
        structural_code = _classify_stable_envelope_failure(value)
        if structural_code is not None:
            return _failure(structural_code)
        if self.schema_validator is not None:
            try:
                self.schema_validator.validate("action-batch.v1.schema.json", value)
            except ProtocolSchemaError:
                return _failure(BatchErrorCode.SCHEMA_MISMATCH)
        try:
            batch = ActionBatch.model_validate(value)
        except ValidationError:
            return _failure(BatchErrorCode.SCHEMA_MISMATCH)

        if batch.match_id != context.match_id:
            return _failure(BatchErrorCode.WRONG_MATCH)
        if batch.observation_seq != context.observation_seq:
            return _failure(BatchErrorCode.WRONG_OBSERVATION)
        if batch.based_on_observation_hash != context.observation_hash:
            return _failure(BatchErrorCode.OBSERVATION_HASH_MISMATCH)
        if batch.valid_until_tick > context.controller_valid_until_tick:
            return _failure(BatchErrorCode.SCHEMA_MISMATCH)
        if context.application_tick > batch.valid_until_tick:
            return _failure(BatchErrorCode.EXPIRED_BATCH)
        try:
            budget = action_batch_budget(
                batch,
                squad_sizes=context.squad_sizes,
                transport_passenger_counts=context.transport_passenger_counts,
            )
        except ActionBudgetError:
            return _failure(BatchErrorCode.ATOMIC_BUDGET_EXCEEDED)
        return BatchValidationResult(batch=batch, budget=budget, code=None)


class BatchIdempotencyRegistry:
    """Track the first accepted use of each player-scoped client batch ID."""

    def __init__(self) -> None:
        self._accepted: Set[Tuple[str, int, str]] = set()

    def register(self, *, match_id: str, player_slot: int, client_batch_id: str) -> bool:
        if player_slot not in {0, 1}:
            raise ValueError("player_slot must be 0 or 1")
        key = (match_id, player_slot, client_batch_id)
        if key in self._accepted:
            return False
        self._accepted.add(key)
        return True

    def contains(self, *, match_id: str, player_slot: int, client_batch_id: str) -> bool:
        return (match_id, player_slot, client_batch_id) in self._accepted

    def clear_match(self, match_id: str) -> None:
        self._accepted = {key for key in self._accepted if key[0] != match_id}


def _json_depth(value: Any, current: int = 1) -> int:
    if isinstance(value, dict):
        return max([current] + [_json_depth(child, current + 1) for child in value.values()])
    if isinstance(value, list):
        return max([current] + [_json_depth(child, current + 1) for child in value])
    return current


def _classify_stable_envelope_failure(value: Any) -> BatchErrorCode | None:
    if not isinstance(value, dict):
        return BatchErrorCode.SCHEMA_MISMATCH
    protocol_version = value.get("protocol_version")
    if isinstance(protocol_version, str) and protocol_version != DUEL_PROTOCOL_VERSION:
        return BatchErrorCode.UNSUPPORTED_VERSION
    commands = value.get("commands")
    if not isinstance(commands, list):
        return None
    if len(commands) > 16:
        return BatchErrorCode.TOO_MANY_COMMANDS
    command_ids = [
        command.get("command_id")
        for command in commands
        if isinstance(command, dict) and isinstance(command.get("command_id"), str)
    ]
    if len(command_ids) != len(set(command_ids)):
        return BatchErrorCode.DUPLICATE_COMMAND_ID
    actor_fields = ("actor_ids", "worker_ids", "builder_ids", "passenger_ids", "member_ids")
    for command in commands:
        if not isinstance(command, dict):
            continue
        if any(
            isinstance(command.get(field), list) and len(command[field]) > 24
            for field in actor_fields
        ):
            return BatchErrorCode.TOO_MANY_ACTORS
        subject = command.get("subject")
        if (
            isinstance(subject, dict)
            and isinstance(subject.get("actor_ids"), list)
            and len(subject["actor_ids"]) > 24
        ):
            return BatchErrorCode.TOO_MANY_ACTORS
    return None


def _failure(code: BatchErrorCode) -> BatchValidationResult:
    return BatchValidationResult(batch=None, budget=None, code=code)
