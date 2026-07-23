from __future__ import annotations

from genesis_arena.models import AgentState, Observation, VisibleResource


def observation(
    *,
    wood: int = 0,
    stone: int = 0,
    food: float = 50,
    shelter: int = 0,
) -> Observation:
    return Observation(
        turn=1,
        day=1,
        agent_id="sol",
        agent=AgentState(
            health=100,
            food=food,
            inventory={"wood": wood, "stone": stone, "iron": 0, "crystal": 0},
            structures={
                "shelter": shelter,
                "farm": 0,
                "storage": 0,
                "wall": 0,
                "workshop": 0,
            },
            technology=0,
            population=1,
        ),
        visible_resources=[
            VisibleResource(id="tree", kind="wood", distance=12, direction="west", quantity=3),
            VisibleResource(id="rock", kind="stone", distance=20, direction="north", quantity=3),
            VisibleResource(id="berries", kind="food", distance=8, direction="south", quantity=3),
        ],
        visible_world=[{"type": "camp", "sheltered": shelter > 0}],
        events=["No new event."],
    )
