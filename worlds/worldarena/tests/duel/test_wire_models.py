from __future__ import annotations

import json
from pathlib import Path

import pytest
from genesis_arena.duel import (
    ActionBatch,
    DuelSchemaValidator,
    MatchConfig,
    MatchInit,
    Observation,
)
from pydantic import ValidationError


def _batch(**updates: object) -> dict[str, object]:
    value: dict[str, object] = {
        "message_type": "action_batch",
        "protocol_version": "worldeval-rts/1.0.0",
        "match_id": "m_match_1",
        "observation_seq": 3,
        "based_on_observation_hash": "a" * 64,
        "client_batch_id": "batch_3",
        "valid_until_tick": 301,
        "commands": [],
    }
    value.update(updates)
    return value


def test_match_config_requires_mirrored_slots_and_official_mode_values() -> None:
    match = MatchConfig(
        decision_mode="fixed_simultaneous",
        faction_preset_id="vanguard-v1",
        seed=42,
        decision_period_ticks=100,
        response_deadline_ms=45_000,
        players=[
            {"slot": 0, "model": "model-a", "reasoning": "medium"},
            {"slot": 1, "model": "model-b", "reasoning": "medium"},
        ],
    )
    assert match.mirror_faction is True
    assert [player.slot for player in match.players] == [0, 1]

    with pytest.raises(ValidationError, match="50, 100, or 150"):
        MatchConfig.model_validate({**match.model_dump(), "decision_period_ticks": 75})
    with pytest.raises(ValidationError, match="canonical order"):
        MatchConfig.model_validate(
            {
                **match.model_dump(),
                "players": [
                    {"slot": 0, "model": "model-a", "reasoning": "medium"},
                    {"slot": 0, "model": "model-b", "reasoning": "medium"},
                ],
            }
        )


def test_match_init_model_covers_every_required_schema_field() -> None:
    fixture_path = (
        Path(__file__).resolve().parents[2]
        / "game"
        / "duel_protocol"
        / "fixtures"
        / "match-init.valid.json"
    )
    payload = json.loads(fixture_path.read_text(encoding="utf-8"))
    message = MatchInit.model_validate(payload)
    assert message.match_id == "m_fixture_0042"
    assert message.faction["mirror_faction"] is True
    assert message.decision["mode"] == "fixed_simultaneous"
    DuelSchemaValidator().validate("match-init.v1.schema.json", message.model_dump(mode="json"))

    payload.pop("starting_state")
    with pytest.raises(ValidationError, match="starting_state"):
        MatchInit.model_validate(payload)


def test_observation_model_covers_every_required_schema_field() -> None:
    fixture_path = (
        Path(__file__).resolve().parents[2]
        / "game"
        / "duel_protocol"
        / "fixtures"
        / "observation.maximal.valid.json"
    )
    payload = json.loads(fixture_path.read_text(encoding="utf-8"))
    observation = Observation.model_validate(payload)
    assert observation.day_phase == "day"
    assert observation.remaining_match_ticks == 16_200
    assert observation.visible_items and observation.visible_shops
    assert observation.visible_shops[0].shop_id == "e_shop1"
    DuelSchemaValidator().validate(
        "observation.v1.schema.json", observation.model_dump(mode="json")
    )

    payload.pop("food")
    with pytest.raises(ValidationError, match="food"):
        Observation.model_validate(payload)


def test_action_batch_is_a_strict_discriminated_command_union() -> None:
    batch = ActionBatch.model_validate(
        _batch(
            commands=[
                {
                    "command_id": "c_move",
                    "op": "move",
                    "actor_ids": ["e_unit1", "e_unit2"],
                    "target": {"kind": "region_slot", "region_id": "r_center", "slot_id": "choke"},
                    "queue": "replace",
                },
                {
                    "command_id": "c_train",
                    "op": "produce",
                    "producer_id": "e_barracks",
                    "unit_type_id": "longbow",
                    "quantity": 2,
                },
            ]
        )
    )
    assert [command.op for command in batch.commands] == ["move", "produce"]
    DuelSchemaValidator().validate(
        "action-batch.v1.schema.json", batch.model_dump(mode="json", exclude_none=True)
    )

    with pytest.raises(ValidationError, match="Extra inputs"):
        ActionBatch.model_validate(_batch(cheat_code="give_gold"))
    with pytest.raises(ValidationError, match="unique"):
        ActionBatch.model_validate(
            _batch(
                commands=[
                    {"command_id": "same", "op": "stop", "actor_ids": ["e_unit1"]},
                    {"command_id": "same", "op": "stop", "actor_ids": ["e_unit2"]},
                ]
            )
        )


def test_action_batch_bounds_utf8_memory_and_rejects_control_text() -> None:
    ActionBatch.model_validate(_batch(working_memory="é" * 2_048))
    with pytest.raises(ValidationError, match="4096"):
        ActionBatch.model_validate(_batch(working_memory="é" * 2_049))
    with pytest.raises(ValidationError, match="control"):
        ActionBatch.model_validate(_batch(working_memory="hidden\ninstruction"))


def test_targeted_laboratory_reveal_has_explicit_service_target() -> None:
    batch = ActionBatch.model_validate(
        _batch(
            commands=[
                {
                    "command_id": "reveal_center",
                    "op": "purchase_offer",
                    "buyer_id": "e_hero1",
                    "shop_id": "e_lab1",
                    "offer_id": "laboratory_reveal",
                    "quantity": 1,
                    "service_target": {"kind": "point", "xy_mt": [96_000, 64_000]},
                }
            ]
        )
    )
    assert batch.commands[0].op == "purchase_offer"
