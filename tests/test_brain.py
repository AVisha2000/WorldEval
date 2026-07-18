from __future__ import annotations

import pytest
from genesis_arena.brain import DemoBrain

from .helpers import observation


@pytest.mark.asyncio
async def test_demo_brain_gathers_wood_before_building() -> None:
    command = await DemoBrain().decide(observation(wood=4, stone=0), [])

    assert command.action.value == "collect"
    assert command.parameters == {"resource": "wood"}


@pytest.mark.asyncio
async def test_demo_brain_builds_when_cost_is_available() -> None:
    command = await DemoBrain().decide(observation(wood=12, stone=4), [])

    assert command.action.value == "build"
    assert command.parameters == {"structure": "shelter"}


@pytest.mark.asyncio
async def test_demo_brain_prioritises_critical_food() -> None:
    command = await DemoBrain().decide(observation(wood=12, stone=4, food=20), [])

    assert command.action.value == "collect"
    assert command.parameters == {"resource": "food"}
