from __future__ import annotations

import pytest
from genesis_arena.arena.demo_policy import ArenaDemoCommander
from genesis_arena.arena.models import CognitionView, FriendlyGroup, PhysicalAction

from .helpers import observation


@pytest.mark.asyncio
async def test_demo_policy_opens_with_movement_economy_diplomacy_and_advisors() -> None:
    view = observation("sol")
    view.cognition = CognitionView(track="agentic", remaining_units=120)
    view.groups.append(
        FriendlyGroup(
            group_id="sol-militia",
            unit_kind="militia",
            count=2,
            district_id="home-sol",
            health=150,
        )
    )
    commander = ArenaDemoCommander()

    plan = await commander.plan(view, [])

    assert sum(order.command_points for order in plan.orders) <= 4
    assert any(order.action == PhysicalAction.MOBILIZE for order in plan.orders)
    assert any(message.visibility == "public" for message in plan.communication.utterances)
    assert {operation.specialist_id for operation in plan.specialist_ops} == {
        "sol_economy",
        "sol_military",
    }


@pytest.mark.asyncio
async def test_demo_policy_uses_private_pact_on_round_two() -> None:
    view = observation("terra", round_number=2)
    plan = await ArenaDemoCommander().plan(view, [])

    assert plan.communication.new_offer is not None
    assert plan.communication.new_offer.kind == "non_aggression"
    assert plan.communication.new_offer.recipient == "luna"
    assert plan.communication.utterances[0].visibility == "private"
