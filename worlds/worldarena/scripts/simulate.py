#!/usr/bin/env python3
"""Run milestone one headlessly through the real controller contracts."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import tempfile
from pathlib import Path
from typing import Dict

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "backend"))

from genesis_arena.config import Settings  # noqa: E402
from genesis_arena.evaluation import evaluate  # noqa: E402
from genesis_arena.models import AgentState, Observation, RunMetrics, VisibleResource  # noqa: E402
from genesis_arena.orchestrator import Orchestrator  # noqa: E402


async def simulate(days: int, emit_json_only: bool = False) -> Dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="genesis-arena-") as memory_directory:
        settings = Settings(brain_mode="demo", memory_dir=Path(memory_directory))
        orchestrator = Orchestrator(settings)

        health = 100.0
        food = 50.0
        inventory = {"wood": 0, "stone": 0, "iron": 0, "crystal": 0}
        structures = {"shelter": 0, "farm": 0, "storage": 0, "wall": 0, "workshop": 0}
        sources = {"wood": 8, "stone": 6, "food": 8}
        yields = {"wood": 4, "stone": 2, "food": 18}
        collected = 0
        spent = 0
        shelter_built_day = 0
        last_event = "Sol entered an unknown world."

        for turn in range(days):
            observation = Observation(
                turn=turn,
                day=turn,
                max_days=days,
                agent_id="sol",
                agent=AgentState(
                    health=health,
                    food=food,
                    inventory=inventory,
                    structures=structures,
                    technology=0,
                    population=1,
                ),
                visible_resources=[
                    VisibleResource(
                        id=f"headless_{kind}",
                        kind=kind,
                        distance=20 + index * 7,
                        direction=["west", "north", "south"][index],
                        quantity=quantity,
                    )
                    for index, (kind, quantity) in enumerate(sources.items())
                    if quantity > 0
                ],
                visible_world=[{"type": "camp", "sheltered": structures["shelter"] > 0}],
                events=[last_event],
            )
            command = await orchestrator.decide(observation)
            action = command.action.value

            if action == "collect":
                kind = str(command.parameters["resource"])
                sources[kind] -= 1
                amount = yields[kind]
                collected += amount
                if kind == "food":
                    food = min(100.0, food + amount)
                else:
                    inventory[kind] += amount
                last_event = f"Collected {amount} {kind}."
            elif action == "build":
                structure = str(command.parameters["structure"])
                cost = orchestrator.catalog.building_cost(structure)
                for kind, amount in cost.items():
                    inventory[kind] -= amount
                    spent += amount
                structures[structure] += 1
                if structure == "shelter" and shelter_built_day == 0:
                    shelter_built_day = turn + 1
                last_event = f"Built {structure}."
            elif action == "rest":
                recovery = 12 if structures["shelter"] else 5
                health = min(100.0, health + recovery)
                last_event = f"Rested and recovered {recovery} health."
            else:
                last_event = f"Inspected the {command.parameters.get('area', 'camp')} sector."

            food = max(0.0, food - 4)
            if food <= 0:
                health = max(0.0, health - 9)
            elif not structures["shelter"]:
                health = max(0.0, health - 1.5)
            else:
                health = min(100.0, health + 0.5)

            if not emit_json_only:
                print(
                    f"Day {turn + 1:02d} | {action:<7} | "
                    f"health={health:5.1f} food={food:5.1f} "
                    f"wood={inventory['wood']:2d} stone={inventory['stone']:2d} | "
                    f"{command.intent}"
                )
            if health <= 0:
                break

        metrics = RunMetrics(
            agent_id="sol",
            survived=health > 0 and (turn + 1) >= days,
            days_survived=turn + 1,
            health=health,
            resources_collected=collected,
            resources_spent=spent,
            resources_wasted=0,
            shelter_built_day=shelter_built_day,
        )
        report = evaluate(metrics)
        if not emit_json_only:
            print()
        print(json.dumps(report, indent=2))
        return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=20)
    parser.add_argument("--json", action="store_true", help="Suppress turn-by-turn output.")
    args = parser.parse_args()
    if args.days < 1:
        parser.error("--days must be at least 1")
    asyncio.run(simulate(args.days, emit_json_only=args.json))


if __name__ == "__main__":
    main()
