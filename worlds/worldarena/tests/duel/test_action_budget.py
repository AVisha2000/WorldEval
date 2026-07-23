from __future__ import annotations

import pytest
from genesis_arena.duel import ActionBatch, ActionBudgetError, action_batch_budget


def _batch(commands: list[dict[str, object]]) -> ActionBatch:
    return ActionBatch(
        match_id="m_match_1",
        observation_seq=2,
        based_on_observation_hash="a" * 64,
        client_batch_id="batch_2",
        valid_until_tick=201,
        commands=commands,
    )


def test_group_and_quantity_commands_cannot_evade_atomic_budget() -> None:
    batch = _batch(
        [
            {
                "command_id": "move_24",
                "op": "move",
                "actor_ids": [f"e_unit{index}" for index in range(24)],
                "target": {"kind": "point", "xy_mt": [50_000, 50_000]},
                "queue": "replace",
            },
            {
                "command_id": "train_5",
                "op": "produce",
                "producer_id": "e_barracks",
                "unit_type_id": "longbow",
                "quantity": 5,
            },
            {
                "command_id": "squad_20",
                "op": "order_squad",
                "squad_id": "squad.main",
                "objective": "attack_move_to",
                "target": {
                    "kind": "region_slot",
                    "region_id": "r_center",
                    "slot_id": "high_ground",
                },
                "formation": "spread",
                "engagement": "engage_visible",
                "queue": "replace",
            },
        ]
    )
    budget = action_batch_budget(batch, squad_sizes={"squad.main": 20})
    assert budget.atomic_orders == 49
    assert budget.command_objects == 3


def test_purchase_quantity_is_priced_as_one_atomic_order_per_charge() -> None:
    batch = _batch(
        [
            {
                "command_id": "buy_5",
                "op": "purchase_offer",
                "buyer_id": "e_hero",
                "shop_id": "e_merchant",
                "offer_id": "lesser_vitality_draught",
                "quantity": 5,
            }
        ]
    )
    assert action_batch_budget(batch).atomic_orders == 5


def test_unknown_squad_or_transport_fails_closed() -> None:
    squad_batch = _batch(
        [
            {
                "command_id": "squad",
                "op": "order_squad",
                "squad_id": "squad.unknown",
                "objective": "move_to",
                "target": {"kind": "point", "xy_mt": [1_000, 1_000]},
                "formation": "none",
                "engagement": "avoid",
                "queue": "replace",
            }
        ]
    )
    with pytest.raises(ActionBudgetError, match="unknown squad"):
        action_batch_budget(squad_batch)

    unload_batch = _batch(
        [
            {
                "command_id": "unload",
                "op": "unload_transport",
                "transport_id": "e_barge",
                "passengers": "all",
                "target": {"kind": "point", "xy_mt": [10_000, 10_000]},
            }
        ]
    )
    with pytest.raises(ActionBudgetError, match="unknown transport"):
        action_batch_budget(unload_batch)


def test_batch_above_sixty_four_atomic_orders_is_rejected() -> None:
    commands: list[dict[str, object]] = []
    for group in range(3):
        commands.append(
            {
                "command_id": f"move_{group}",
                "op": "move",
                "actor_ids": [f"e_g{group}u{index}" for index in range(24)],
                "target": {"kind": "point", "xy_mt": [5_000, 5_000]},
                "queue": "replace",
            }
        )
    with pytest.raises(ActionBudgetError, match="64-order"):
        action_batch_budget(_batch(commands))
