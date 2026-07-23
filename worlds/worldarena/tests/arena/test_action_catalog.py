from __future__ import annotations

import json
from pathlib import Path

from genesis_arena.arena.models import COMMAND_POINT_COST, PhysicalAction


def test_frozen_arena_action_catalog_matches_wire_enum_and_costs() -> None:
    root = Path(__file__).resolve().parents[2]
    catalog = json.loads((root / "game" / "arena_actions.json").read_text(encoding="utf-8"))
    actions = catalog["actions"]

    assert catalog["protocol"] == "world-arena/0.4"
    assert catalog["schema_version"] == "arena-v2"
    canonical_actions = {
        PhysicalAction.MOVE,
        PhysicalAction.GATHER,
        PhysicalAction.BUILD,
        PhysicalAction.ATTACK,
        PhysicalAction.RESEARCH,
        PhysicalAction.NEGOTIATE,
        PhysicalAction.THINK,
    }
    assert set(actions) == {action.value for action in canonical_actions}
    for action in canonical_actions:
        assert actions[action.value]["command_points"] == COMMAND_POINT_COST[action]

    assert catalog["communication"]["offer_kinds"] == [
        "trade",
        "non_aggression",
        "coordinate_attack",
    ]
    assert catalog["specialists"]["maximum_defined"] == 3
