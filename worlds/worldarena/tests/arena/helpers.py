from __future__ import annotations

from typing import Dict

from genesis_arena.arena import (
    CognitionBudget,
    CognitionView,
    DemoCommander,
    DistrictObservation,
    FactionObservation,
    FactionPlan,
    FactionRuntime,
    FriendlyGroup,
    PublicFactionScore,
    ResourceBundle,
    RoundRequest,
    ScriptedCommander,
)

FACTIONS = ("sol", "terra", "luna")
STATE_HASH = "a" * 64


def observation(faction: str, *, round_number: int = 1) -> FactionObservation:
    return FactionObservation(
        match_id="match-test",
        round=round_number,
        faction_id=faction,
        snapshot_hash=STATE_HASH,
        inventory=ResourceBundle(food=120, wood=90, stone=70),
        groups=[
            FriendlyGroup(
                group_id=f"{faction}-workers",
                unit_kind="worker",
                count=3,
                district_id=f"home-{faction}",
                health=90,
            )
        ],
        districts=[
            DistrictObservation(
                district_id=f"home-{faction}",
                owner_id=faction,
                supplied=True,
                last_seen_round=round_number,
                resources=ResourceBundle(wood=300, stone=200),
            )
        ],
        public_scores=[
            PublicFactionScore(
                faction_id=item,
                core_health=1000,
                supplied_land=1,
                territory_time=round_number,
            )
            for item in FACTIONS
        ],
        cognition=CognitionView(track="agentic", remaining_units=120),
        available_actions=["assign_workers", "mobilize"],
    )


def request(*, round_number: int = 1) -> RoundRequest:
    return RoundRequest(
        match_id="match-test",
        round=round_number,
        snapshot_hash=STATE_HASH,
        observations=[observation(faction, round_number=round_number) for faction in FACTIONS],
    )


def plan_for(observation_value: FactionObservation, _recommendations: list) -> FactionPlan:
    return FactionPlan(
        match_id=observation_value.match_id,
        round=observation_value.round,
        faction_id=observation_value.faction_id,
        public_intent="Maintain production while observing both opponents.",
    )


def runtimes(*, delays: Dict[str, float] | None = None) -> Dict[str, FactionRuntime]:
    delays = delays or {}
    return {
        faction: FactionRuntime(
            faction_id=faction,
            commander=ScriptedCommander(plan_for, delay_seconds=delays.get(faction, 0)),
            budget=CognitionBudget(),
        )
        for faction in FACTIONS
    }


def demo_runtimes() -> Dict[str, FactionRuntime]:
    return {
        faction: FactionRuntime(
            faction_id=faction,
            commander=DemoCommander(),
            budget=CognitionBudget(track="standard", total_units=80),
        )
        for faction in FACTIONS
    }
