from __future__ import annotations

import pytest
from genesis_arena.duel import ActionBatch, DuelSchemaValidator

POINT = {"kind": "point", "xy_mt": [1_000, 2_000]}
ENTITY = {"kind": "entity", "entity_id": "e_target"}
SITE = {"kind": "site", "site_id": "site.home"}
REGION_SLOT = {"kind": "region_slot", "region_id": "r_center", "slot_id": "slot.main"}


COMMANDS = [
    {"op": "move", "actor_ids": ["e_a"], "target": POINT, "queue": "replace"},
    {"op": "attack_move", "actor_ids": ["e_a"], "target": REGION_SLOT, "queue": "append"},
    {"op": "attack_entity", "actor_ids": ["e_a"], "target": ENTITY, "queue": "replace"},
    {"op": "attack_ground", "actor_ids": ["e_a"], "target": POINT, "queue": "replace"},
    {"op": "stop", "actor_ids": ["e_a"]},
    {"op": "hold_position", "actor_ids": ["e_a"]},
    {
        "op": "patrol",
        "actor_ids": ["e_a"],
        "targets": [POINT, REGION_SLOT],
        "queue": "replace",
    },
    {
        "op": "follow",
        "actor_ids": ["e_a"],
        "target": ENTITY,
        "distance_mt": 1_000,
        "queue": "replace",
    },
    {"op": "retreat", "actor_ids": ["e_a"], "target": SITE, "queue": "replace"},
    {"op": "set_stance", "actor_ids": ["e_a"], "stance": "defensive"},
    {
        "op": "gather",
        "worker_ids": ["e_a"],
        "resource_target": SITE,
        "queue": "replace",
    },
    {"op": "return_cargo", "worker_ids": ["e_a"], "queue": "replace"},
    {"op": "repair", "worker_ids": ["e_a"], "target": ENTITY, "queue": "replace"},
    {
        "op": "build",
        "builder_ids": ["e_a"],
        "building_type_id": "barracks",
        "build_site_id": "site.home",
    },
    {"op": "cancel_construction", "building_id": "e_build"},
    {"op": "produce", "producer_id": "e_prod", "unit_type_id": "footman", "quantity": 1},
    {"op": "research", "producer_id": "e_prod", "upgrade_id": "melee_attack_1"},
    {"op": "upgrade_tier", "stronghold_id": "e_hold", "target_tier": 2},
    {"op": "cancel_queue", "producer_id": "e_prod", "queue_entry_id": "q_1"},
    {"op": "set_rally", "producer_id": "e_prod", "target": POINT},
    {
        "op": "revive_hero",
        "reviver_id": "e_altar",
        "hero_id": "e_hero",
        "revival_method": "altar",
    },
    {
        "op": "cast",
        "actor_id": "e_hero",
        "ability_id": "heal",
        "target": ENTITY,
        "queue": "replace",
    },
    {"op": "set_autocast", "actor_ids": ["e_a"], "ability_id": "heal", "enabled": True},
    {"op": "learn_ability", "hero_id": "e_hero", "ability_id": "heal"},
    {
        "op": "use_item",
        "hero_id": "e_hero",
        "item_instance_id": "item_1",
        "target": ENTITY,
        "queue": "replace",
    },
    {"op": "pick_up_item", "hero_id": "e_hero", "item_entity_id": "e_item", "queue": "replace"},
    {"op": "drop_item", "hero_id": "e_hero", "item_instance_id": "item_1", "target": POINT},
    {
        "op": "transfer_item",
        "from_hero_id": "e_hero",
        "to_hero_id": "e_other",
        "item_instance_id": "item_1",
    },
    {"op": "sell_item", "hero_id": "e_hero", "shop_id": "e_shop", "item_instance_id": "item_1"},
    {
        "op": "purchase_offer",
        "buyer_id": "e_hero",
        "shop_id": "e_shop",
        "offer_id": "potion",
        "quantity": 1,
    },
    {
        "op": "load_transport",
        "transport_id": "e_ship",
        "passenger_ids": ["e_a"],
        "queue": "replace",
    },
    {"op": "unload_transport", "transport_id": "e_ship", "passengers": "all", "target": POINT},
    {"op": "define_squad", "squad_id": "squad.main", "member_ids": ["e_a"]},
    {"op": "update_squad", "squad_id": "squad.main", "member_ids": ["e_a"]},
    {"op": "disband_squad", "squad_id": "squad.main"},
    {
        "op": "order_squad",
        "squad_id": "squad.main",
        "objective": "move_to",
        "target": POINT,
        "formation": "line",
        "engagement": "avoid",
        "queue": "replace",
    },
    {
        "op": "set_tactics",
        "subject": {"kind": "actors", "actor_ids": ["e_a"]},
        "formation": "line",
        "stance": "defensive",
        "focus_tag": "none",
        "retreat_hp_threshold_bp": 0,
    },
]


@pytest.mark.parametrize("command", COMMANDS, ids=lambda value: value["op"])
def test_every_hybrid_operation_matches_pydantic_and_json_schema(
    command: dict[str, object],
) -> None:
    command_index = next(index for index, value in enumerate(COMMANDS) if value is command)
    value = {
        "message_type": "action_batch",
        "protocol_version": "worldeval-rts/1.0.0",
        "match_id": "m_contract",
        "observation_seq": 1,
        "based_on_observation_hash": "a" * 64,
        "client_batch_id": f"batch_{command_index}",
        "valid_until_tick": 2,
        "commands": [{"command_id": f"command_{command_index}", **command}],
    }

    batch = ActionBatch.model_validate(value)
    DuelSchemaValidator().validate(
        "action-batch.v1.schema.json",
        batch.model_dump(mode="json", exclude_none=True),
    )


def test_action_catalog_and_wire_union_have_exactly_the_same_operations() -> None:
    catalog = DuelSchemaValidator().package.read_catalog("actions.hybrid-v1.json")
    assert set(catalog["operations"]) == {command["op"] for command in COMMANDS}
    assert len(COMMANDS) == 37
