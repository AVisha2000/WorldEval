from __future__ import annotations

import pytest
from genesis_arena.duel import ActionReceipt, DuelSchemaValidator, ObservableEvent
from pydantic import ValidationError


def test_action_receipt_preserves_required_null_code_and_matches_schema() -> None:
    receipt = ActionReceipt(
        batch_id="batch_1",
        observation_seq=4,
        received_tick=401,
        apply_tick=402,
        batch_status="applied",
        commands=[
            {
                "command_id": "move_1",
                "status": "applied",
                "code": None,
                "requested_quantity": 2,
                "accepted_quantity": 2,
                "atomic_cost": 2,
                "compiled_order_ids": ["order_1", "order_2"],
            }
        ],
    )

    wire = receipt.to_wire_dict()
    assert wire["commands"][0]["code"] is None
    DuelSchemaValidator().validate("action-receipt.v1.schema.json", wire)


def test_receipt_rejects_inconsistent_application_and_quantity_state() -> None:
    with pytest.raises(ValidationError, match="requires apply_tick"):
        ActionReceipt(
            batch_id="batch_1",
            observation_seq=4,
            received_tick=401,
            apply_tick=None,
            batch_status="applied",
            commands=[],
        )
    with pytest.raises(ValidationError, match="cannot exceed"):
        ActionReceipt(
            batch_id="batch_1",
            observation_seq=4,
            received_tick=401,
            apply_tick=402,
            batch_status="partially_applied",
            commands=[
                {
                    "command_id": "move_1",
                    "status": "partially_applied",
                    "code": None,
                    "requested_quantity": 1,
                    "accepted_quantity": 2,
                }
            ],
        )


def test_observable_event_is_strict_canonical_and_schema_valid() -> None:
    event = ObservableEvent(
        event_seq=7,
        tick=402,
        kind="resource_deposited",
        audience="self",
        payload={
            "entity_id": "e_worker",
            "resource": "gold",
            "amount": 10,
            "details": ["mine.home", "stronghold.home"],
        },
    )
    DuelSchemaValidator().validate("event.v1.schema.json", event.to_wire_dict())

    with pytest.raises(ValidationError, match="ascending canonical order"):
        ObservableEvent(
            event_seq=8,
            tick=402,
            kind="order_completed",
            audience="self",
            payload={"details": ["z", "a"]},
        )
