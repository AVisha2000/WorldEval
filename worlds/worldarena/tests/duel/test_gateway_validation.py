from __future__ import annotations

import json

from genesis_arena.duel import (
    ActionEnvelopeValidator,
    BatchErrorCode,
    BatchIdempotencyRegistry,
    BatchValidationContext,
)


def _context(**updates: object) -> BatchValidationContext:
    values: dict[str, object] = {
        "match_id": "m_match_1",
        "observation_seq": 2,
        "observation_hash": "a" * 64,
        "application_tick": 201,
        "controller_valid_until_tick": 201,
        "squad_sizes": {},
        "transport_passenger_counts": {},
    }
    values.update(updates)
    return BatchValidationContext(**values)  # type: ignore[arg-type]


def _payload(**updates: object) -> bytes:
    values: dict[str, object] = {
        "message_type": "action_batch",
        "protocol_version": "worldeval-rts/1.0.0",
        "match_id": "m_match_1",
        "observation_seq": 2,
        "based_on_observation_hash": "a" * 64,
        "client_batch_id": "batch_2",
        "valid_until_tick": 201,
        "commands": [],
    }
    values.update(updates)
    return json.dumps(values, separators=(",", ":")).encode()


def test_gateway_validator_accepts_one_exact_empty_batch() -> None:
    result = ActionEnvelopeValidator().validate(_payload(), _context())
    assert result.valid
    assert result.batch is not None
    assert result.batch.commands == []
    assert result.budget is not None and result.budget.atomic_orders == 0


def test_gateway_validator_does_not_repair_prose_fences_or_duplicate_json() -> None:
    validator = ActionEnvelopeValidator()
    assert validator.validate(b"```json\n{}\n```", _context()).code is BatchErrorCode.INVALID_JSON
    duplicate = _payload() + _payload()
    assert validator.validate(duplicate, _context()).code is BatchErrorCode.INVALID_JSON
    duplicate_key = b'{"message_type":"action_batch","message_type":"action_batch"}'
    assert validator.validate(duplicate_key, _context()).code is BatchErrorCode.INVALID_JSON


def test_gateway_validator_checks_context_hash_and_validity_window() -> None:
    validator = ActionEnvelopeValidator()
    wrong_hash = validator.validate(_payload(based_on_observation_hash="b" * 64), _context())
    assert wrong_hash.code is BatchErrorCode.OBSERVATION_HASH_MISMATCH

    extended = validator.validate(_payload(valid_until_tick=202), _context())
    assert extended.code is BatchErrorCode.SCHEMA_MISMATCH

    expired = validator.validate(
        _payload(valid_until_tick=200),
        _context(application_tick=201, controller_valid_until_tick=201),
    )
    assert expired.code is BatchErrorCode.EXPIRED_BATCH


def test_gateway_validator_rejects_unknown_fields_and_deep_values() -> None:
    validator = ActionEnvelopeValidator()
    unknown = validator.validate(_payload(shell_command="do not run"), _context())
    assert unknown.code is BatchErrorCode.SCHEMA_MISMATCH

    deep: object = "leaf"
    for _ in range(18):
        deep = [deep]
    nested = validator.validate(_payload(intent_summary=deep), _context())
    assert nested.code is BatchErrorCode.SCHEMA_MISMATCH


def test_gateway_validator_emits_stable_non_secret_envelope_codes() -> None:
    validator = ActionEnvelopeValidator()
    unsupported = validator.validate(
        _payload(protocol_version="worldeval-rts/999.0.0"), _context()
    )
    assert unsupported.code is BatchErrorCode.UNSUPPORTED_VERSION

    duplicate_commands = [
        {"command_id": "same", "op": "stop", "actor_ids": ["e_a"]},
        {"command_id": "same", "op": "stop", "actor_ids": ["e_b"]},
    ]
    duplicate = validator.validate(_payload(commands=duplicate_commands), _context())
    assert duplicate.code is BatchErrorCode.DUPLICATE_COMMAND_ID

    too_many = [
        {"command_id": f"c_{index}", "op": "stop", "actor_ids": ["e_a"]}
        for index in range(17)
    ]
    assert (
        validator.validate(_payload(commands=too_many), _context()).code
        is BatchErrorCode.TOO_MANY_COMMANDS
    )

    actors = [f"e_{index}" for index in range(25)]
    oversized_group = [{"command_id": "c", "op": "stop", "actor_ids": actors}]
    assert (
        validator.validate(_payload(commands=oversized_group), _context()).code
        is BatchErrorCode.TOO_MANY_ACTORS
    )


def test_client_batch_idempotency_is_scoped_by_match_and_player() -> None:
    registry = BatchIdempotencyRegistry()
    assert registry.register(match_id="m_one", player_slot=0, client_batch_id="batch_1")
    assert not registry.register(match_id="m_one", player_slot=0, client_batch_id="batch_1")
    assert registry.register(match_id="m_one", player_slot=1, client_batch_id="batch_1")
    assert registry.register(match_id="m_two", player_slot=0, client_batch_id="batch_1")
    assert registry.contains(match_id="m_one", player_slot=0, client_batch_id="batch_1")
    registry.clear_match("m_one")
    assert not registry.contains(match_id="m_one", player_slot=0, client_batch_id="batch_1")
