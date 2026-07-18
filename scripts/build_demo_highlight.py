#!/usr/bin/env python3
"""Build the secret-free, deterministic WorldArena 90-second demo replay.

This is deliberately presentation data, not an authoritative benchmark artifact.
It exists so a local Godot capture has a repeatable story: exploration, economy,
diplomacy, a Crown clash, betrayal, and a readable winner.
"""

from __future__ import annotations

import hashlib
import json
from copy import deepcopy
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "godot" / "showcases" / "demo_highlight"
REPLAY_PATH = OUT / "replay.json"
MANIFEST_PATH = OUT / "manifest.json"
DURATION_SECONDS = 90
DISTRICTS = (
    "core_sol", "core_terra", "core_luna", "home_sol", "home_terra", "home_luna",
    "mine_st", "mine_tl", "mine_ls", "wild_st", "wild_tl", "wild_ls", "crown",
)


def unit(unit_id: str, faction: str, kind: str, district: str, position: list[float], task: str, *, health: int | None = None, combat: bool = False) -> dict:
    max_health = {"commander": 150, "worker": 30, "scout": 40, "guard": 110, "militia": 75, "siege": 130}[kind]
    return {
        "id": unit_id, "faction_id": faction, "unit_type": kind, "district_id": district,
        "position": position, "health": max_health if health is None else health,
        "max_health": max_health, "task": task, "in_combat": combat,
    }


def faction(faction_id: str, model: str, *, core_hp: int, land: int, army: int, state: str, resources: dict, intent: str, orders: list[dict]) -> dict:
    return {
        "id": faction_id, "model": model, "core_hp": core_hp, "land_percent": land,
        "army_strength": army, "state": state, "resources": resources,
        "cognition": {"round_spent": 44, "round_budget": 100, "match_spent": 260 + army * 19},
        "strategic_intent": intent, "orders": orders,
        "specialists": [],
    }


def district_states(owners: dict[str, str], *, contested: str = "", progress: float = 0.0, cut: tuple[str, ...] = ()) -> list[dict]:
    states = []
    for district_id in DISTRICTS:
        owner = owners.get(district_id, "neutral")
        state = {"id": district_id, "owner": owner, "supplied": owner == "neutral" or district_id not in cut}
        if district_id == contested:
            state.update({"contested": True, "capture_progress": progress})
        states.append(state)
    return states


BASE_OWNERS = {
    "core_sol": "sol", "home_sol": "sol", "core_terra": "terra", "home_terra": "terra",
    "core_luna": "luna", "home_luna": "luna",
}


def snapshot(round_number: int, sim_time: str, phase: str, units: list[dict], factions: list[dict], owners: dict[str, str], *, contested: str = "", progress: float = 0.0, cut: tuple[str, ...] = (), relationships: list[dict] | None = None) -> dict:
    return {
        "match_id": "local-demo-open-world-001", "round": round_number, "max_rounds": 40,
        "phase": phase, "sim_time": sim_time,
        "thinking_status": {"sol": "locked", "terra": "locked", "luna": "locked"},
        "factions": factions, "districts": district_states(owners, contested=contested, progress=progress, cut=cut),
        "units": units, "relationships": relationships or [],
    }


def event(event_id: str, round_number: int, kind: str, actor: str, summary: str, *, targets: list[str] | None = None, visibility: str = "public", state: str = "", payload: dict | None = None) -> dict:
    result = {
        "event_id": event_id, "round": round_number, "kind": kind, "actor_id": actor,
        "target_ids": targets or [], "visibility": visibility, "summary": summary,
    }
    if visibility != "public":
        result["visible_to"] = [actor, *(targets or [])]
    if state:
        result["state"] = state
    if payload:
        result["payload"] = payload
    return result


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    sol = faction("sol", "gpt-5.6-sol", core_hp=1000, land=15, army=4, state="exploring", resources={"food": 70, "wood": 15, "stone": 8, "iron": 0, "crystal": 0}, intent="Secure wood and establish the western Crown front.", orders=[{"action": "collect", "target": "wild_ls"}])
    terra = faction("terra", "gpt-5.6-terra", core_hp=1000, land=15, army=4, state="building", resources={"food": 62, "wood": 10, "stone": 16, "iron": 0, "crystal": 0}, intent="Build a mine economy and force the eastern Crown front.", orders=[{"action": "build", "target": "home_terra"}])
    luna = faction("luna", "gpt-5.6-luna", core_hp=1000, land=15, army=3, state="scouting", resources={"food": 66, "wood": 8, "stone": 6, "iron": 0, "crystal": 0}, intent="Observe both fronts, map supply routes, and sell scouting intelligence.", orders=[{"action": "inspect", "target": "wild_tl"}])
    start_units = [
        unit("sol_commander", "sol", "commander", "home_sol", [-108, .45, 96], "rally workers"),
        unit("sol_worker_1", "sol", "worker", "home_sol", [-114, .45, 88], "gather wood"),
        unit("sol_guard_1", "sol", "guard", "home_sol", [-100, .45, 91], "escort"),
        unit("terra_commander", "terra", "commander", "home_terra", [108, .45, 96], "plan workshop"),
        unit("terra_worker_1", "terra", "worker", "home_terra", [115, .45, 87], "gather stone"),
        unit("terra_guard_1", "terra", "guard", "home_terra", [100, .45, 91], "defend camp"),
        unit("luna_commander", "luna", "commander", "home_luna", [0, .45, -112], "dispatch scout"),
        unit("luna_scout_1", "luna", "scout", "home_luna", [8, .45, -107], "survey route"),
        unit("luna_worker_1", "luna", "worker", "home_luna", [-7, .45, -106], "forage"),
    ]
    initial = snapshot(1, "00:00", "thinking", start_units, [sol, terra, luna], BASE_OWNERS)
    cues: list[dict] = [
        {"cue_id": "intro-overview", "at": 0, "kind": "camera", "target_id": "overview", "shot": "overview"},
        {"cue_id": "intro-phase", "at": 0, "kind": "phase", "phase": "thinking", "statuses": {"sol": "thinking", "terra": "thinking", "luna": "thinking"}},
        {"cue_id": "intro-message", "at": 1, "kind": "message", "event": event("demo-001", 1, "message", "sol", "One accelerated hour. I will secure the western road to the Crown.")},
    ]

    # 6s: agents fan out. Positions change by <35m between subsequent snapshots so
    # the presentation's actor tweens visibly walk rather than teleport.
    u = deepcopy(start_units)
    u[0].update({"district_id": "home_sol", "position": [-90, .45, 93], "task": "lead west expedition"})
    u[1].update({"district_id": "wild_ls", "position": [-121, .45, 24], "task": "chop trees"})
    u[2].update({"district_id": "home_sol", "position": [-89, .45, 87], "task": "escort commander"})
    u[3].update({"district_id": "home_terra", "position": [91, .45, 94], "task": "lead build team"})
    u[4].update({"district_id": "home_terra", "position": [115, .45, 66], "task": "quarry stone"})
    u[6].update({"district_id": "home_luna", "position": [0, .45, -93], "task": "send scout north"})
    u[7].update({"district_id": "home_luna", "position": [17, .45, -89], "task": "survey east road"})
    cues += [
        {"cue_id": "fan-out", "at": 6, "kind": "snapshot", "snapshot": snapshot(4, "00:04", "resolution", u, [sol, terra, luna], BASE_OWNERS)},
        {"cue_id": "fan-out-shot", "at": 6.1, "kind": "camera", "target_id": "sol_commander", "shot": "wide"},
        {"cue_id": "wood-gathered", "at": 9, "kind": "events", "events": [event("demo-002", 4, "resource", "sol", "Sol workers fell trees in West Wildwood; wood reserve rising.")]},
    ]

    # 14s: build/mine/scout scenes.
    sol2, terra2, luna2 = deepcopy(sol), deepcopy(terra), deepcopy(luna)
    sol2.update({"land_percent": 22, "army_strength": 5, "state": "expanding", "resources": {"food": 79, "wood": 49, "stone": 16, "iron": 0, "crystal": 0}, "intent": "Use the wood lead to establish a forward shelter."})
    terra2.update({"land_percent": 25, "army_strength": 5, "state": "building", "resources": {"food": 69, "wood": 18, "stone": 48, "iron": 14, "crystal": 0}, "intent": "Convert stone and iron into a defended workshop."})
    luna2.update({"land_percent": 18, "army_strength": 3, "state": "scouting", "resources": {"food": 78, "wood": 21, "stone": 11, "iron": 0, "crystal": 3}, "intent": "Reveal Terra's eastern route and sell the timing to Sol."})
    u = deepcopy(u)
    u[0].update({"district_id": "wild_ls", "position": [-111, .45, 48], "task": "raise shelter"})
    u[1].update({"district_id": "wild_ls", "position": [-116, .45, 8], "task": "haul timber"})
    u[2].update({"district_id": "wild_ls", "position": [-103, .45, 45], "task": "guard shelter"})
    u[3].update({"district_id": "mine_st", "position": [77, .45, 93], "task": "build workshop"})
    u[4].update({"district_id": "mine_st", "position": [47, .45, 93], "task": "mine iron"})
    u[5].update({"district_id": "mine_st", "position": [82, .45, 84], "task": "guard builders"})
    u[6].update({"district_id": "mine_tl", "position": [11, .45, -75], "task": "analyse route"})
    u[7].update({"district_id": "mine_tl", "position": [34, .45, -70], "task": "discover Ember Mine"})
    u[8].update({"district_id": "home_luna", "position": [-4, .45, -87], "task": "gather food"})
    owners = {**BASE_OWNERS, "wild_ls": "sol", "mine_st": "terra"}
    cues += [
        {"cue_id": "economy-snapshot", "at": 14, "kind": "snapshot", "snapshot": snapshot(8, "00:10", "resolution", u, [sol2, terra2, luna2], owners)},
        {"cue_id": "build-shot", "at": 14.1, "kind": "camera", "target_id": "terra_commander", "shot": "medium"},
        {"cue_id": "workshop-complete", "at": 16, "kind": "events", "events": [event("demo-003", 8, "territory", "terra", "Terra's builders raise a palisade and complete a forward workshop.", payload={"district_id": "mine_st", "district_state": {"owner": "terra", "supplied": True}}), event("demo-003b", 8, "build", "terra", "Stone becomes a defended route: workshop online, guards deployed.")]},
        {"cue_id": "scout-shot", "at": 19, "kind": "camera", "target_id": "luna_scout_1", "shot": "close"},
        {"cue_id": "scout-report", "at": 20, "kind": "message", "event": event("demo-004", 8, "message", "luna", "Terra's eastern workshop is live. Their Crown force moves in twelve simulated minutes.")},
    ]

    # 25s: negotiation and atomic trade. Private messages remain spectator-visible.
    u = deepcopy(u)
    u[0].update({"district_id": "mine_ls", "position": [-67, .45, -8], "task": "meet Luna envoy"})
    u[2].update({"district_id": "mine_ls", "position": [-79, .45, -10], "task": "protect trade"})
    u[6].update({"district_id": "mine_ls", "position": [-39, .45, -46], "task": "negotiate"})
    u[7].update({"district_id": "mine_tl", "position": [55, .45, -45], "task": "watch Terra"})
    cues += [
        {"cue_id": "negotiation-snapshot", "at": 25, "kind": "snapshot", "snapshot": snapshot(13, "00:17", "diplomacy", u, [sol2, terra2, luna2], owners)},
        {"cue_id": "negotiation-shot", "at": 25.1, "kind": "camera", "target_id": "sol_commander", "shot": "medium"},
        {"cue_id": "private-offer", "at": 26, "kind": "message", "event": event("demo-005", 13, "offer", "sol", "Private: 25 wood for Terra's eastern timing and the weak bridge approach.", targets=["luna"], visibility="participants", state="proposed", payload={"give": {"wood": 25}, "request": "eastern_route_report"})},
        {"cue_id": "private-accept", "at": 28, "kind": "message", "event": event("demo-006", 13, "message", "luna", "Private: Accepted. I will keep scouting; the eastern bridge is lightly guarded.", targets=["sol"], visibility="participants")},
        {"cue_id": "trade-executed", "at": 30, "kind": "events", "events": [event("demo-007", 13, "trade", "sol", "Atomic trade executed: Sol buys Luna's eastern-route intelligence.", targets=["luna"], visibility="participants", state="executed"), event("demo-007b", 13, "message", "luna", "Trade received. Terra commits to the eastern front; the western flank is clear.", targets=["sol"], visibility="participants")]},
    ]

    # 34s: centre converges, visibly walking from three approaches.
    sol3, terra3, luna3 = deepcopy(sol2), deepcopy(terra2), deepcopy(luna2)
    sol3.update({"land_percent": 30, "army_strength": 8, "state": "pressuring", "resources": {"food": 92, "wood": 33, "stone": 26, "iron": 9, "crystal": 0}, "intent": "Open a western Crown front before Terra's eastern force settles."})
    terra3.update({"land_percent": 31, "army_strength": 10, "state": "attacking", "resources": {"food": 82, "wood": 25, "stone": 57, "iron": 34, "crystal": 0}, "intent": "Win the eastern Crown front with workshop reinforcements."})
    luna3.update({"land_percent": 20, "army_strength": 3, "state": "scouting", "resources": {"food": 83, "wood": 31, "stone": 13, "iron": 4, "crystal": 5}, "intent": "Observe both fronts without committing a costly army."})
    u = deepcopy(u)
    u[0].update({"district_id": "mine_ls", "position": [-46, .45, -6], "task": "advance Crown road"})
    u[1].update({"district_id": "mine_ls", "position": [-81, .45, -20], "task": "build supply cache"})
    u[2].update({"district_id": "mine_ls", "position": [-37, .45, -8], "task": "escort advance"})
    u[3].update({"district_id": "mine_st", "position": [54, .45, 61], "task": "march to Crown"})
    u[4].update({"district_id": "mine_st", "position": [30, .45, 65], "task": "bring iron"})
    u[5].update({"district_id": "mine_st", "position": [44, .45, 61], "task": "frontline"})
    u[6].update({"district_id": "mine_tl", "position": [20, .45, -32], "task": "circle Crown"})
    u[7].update({"district_id": "mine_tl", "position": [41, .45, -22], "task": "mark targets"})
    u.append(unit("terra_militia_1", "terra", "militia", "mine_st", [38, .45, 49], "join assault"))
    u.append(unit("sol_militia_1", "sol", "militia", "mine_ls", [-32, .45, -5], "join assault"))
    owners = {**owners, "mine_ls": "neutral", "mine_tl": "neutral"}
    cues += [
        {"cue_id": "crown-approach", "at": 34, "kind": "snapshot", "snapshot": snapshot(19, "00:23", "resolution", u, [sol3, terra3, luna3], owners, contested="crown", progress=.22)},
        {"cue_id": "crown-wide", "at": 34.1, "kind": "camera", "target_id": "crown", "shot": "wide"},
        {"cue_id": "public-pact", "at": 36, "kind": "message", "event": event("demo-008", 19, "message", "luna", "Public: Scout report only. Sol takes the west; Terra owns the east until one breaks.", targets=["sol", "terra"])},
        {"cue_id": "terra-response", "at": 38, "kind": "message", "event": event("demo-009", 19, "message", "terra", "Then watch closely. My workshop is already supplying the eastern front.")},
    ]

    # 43s: battle, close enough for equipment and walking silhouettes to read.
    u = deepcopy(u)
    for index, pos in {0: [-18, .45, 4], 2: [-11, .45, 6], 3: [21, .45, 8], 5: [13, .45, 4], 6: [3, .45, -20], 7: [17, .45, -12], 9: [27, .45, 13], 10: [-25, .45, 9]}.items():
        u[index]["position"] = pos
        u[index]["district_id"] = "crown"
        u[index]["in_combat"] = True
        u[index]["task"] = "fight for Crown"
    u[0]["health"] = 120
    u[3]["health"] = 132
    u[6]["health"] = 108
    cues += [
        {"cue_id": "battle-snapshot", "at": 43, "kind": "snapshot", "snapshot": snapshot(24, "00:29", "resolution", u, [sol3, terra3, luna3], owners, contested="crown", progress=.64)},
        {"cue_id": "battle-close", "at": 43.1, "kind": "camera", "target_id": "terra_commander", "shot": "close"},
        {"cue_id": "battle-event", "at": 44, "kind": "events", "events": [event("demo-010", 24, "combat", "terra", "Terra's shield line clashes with Sol's vanguard at the Crown."), event("demo-011", 24, "combat", "luna", "Luna scouts a flank instead of joining the frontal fight.")]},
        {"cue_id": "luna-betrayal", "at": 48, "kind": "message", "event": event("demo-012", 24, "message", "luna", "Public: Terra's eastern reserves are shifting to the Crown. Sol's west road is still open.", targets=["sol", "terra"])},
    ]

    # 52s: Terra appears to have won.  This is deliberately *not* the ending: it
    # gives the final third of the short film a reversal rather than a static
    # victory lap.  The replay is scripted presentation data, not a scored match.
    sol4, terra4, luna4 = deepcopy(sol3), deepcopy(terra3), deepcopy(luna3)
    sol4.update({"land_percent": 34, "army_strength": 8, "state": "adapting", "resources": {"food": 78, "wood": 28, "stone": 22, "iron": 14, "crystal": 12}, "intent": "Cut Terra's supply road, then retake the Crown from the flank."})
    terra4.update({"core_hp": 900, "land_percent": 39, "army_strength": 10, "state": "leading", "resources": {"food": 69, "wood": 16, "stone": 42, "iron": 25, "crystal": 30}, "intent": "Fortify the Crown before Sol can recover."})
    luna4.update({"land_percent": 21, "army_strength": 3, "state": "scouting", "resources": {"food": 70, "wood": 33, "stone": 14, "iron": 8, "crystal": 8}, "intent": "Keep the two fronts visible and avoid getting trapped in the centre."})
    u = deepcopy(u)
    u[0].update({"position": [-21, .45, -5], "health": 107, "task": "fall back and flank", "in_combat": False})
    u[2].update({"position": [-26, .45, -8], "health": 71, "task": "cut supply trail", "in_combat": False})
    u[3].update({"district_id": "crown", "position": [7, .45, 3], "health": 112, "task": "raise Terra banner", "in_combat": False})
    u[5].update({"district_id": "crown", "position": [13, .45, 9], "health": 54, "task": "fortify Crown", "in_combat": False})
    u[6].update({"district_id": "mine_tl", "position": [58, .45, -22], "health": 108, "task": "observe eastern front", "in_combat": False})
    u[7].update({"district_id": "mine_tl", "position": [69, .45, -29], "task": "mark supply movement", "in_combat": False})
    owners = {**owners, "crown": "terra"}
    cues += [
        {"cue_id": "terra-leads-snapshot", "at": 52, "kind": "snapshot", "snapshot": snapshot(31, "00:35", "resolution", u, [sol4, terra4, luna4], owners, contested="crown", progress=0.86, cut=("mine_tl",))},
        {"cue_id": "terra-leads-shot", "at": 52.1, "kind": "camera", "target_id": "terra_commander", "shot": "close"},
        {"cue_id": "terra-nearly-wins", "at": 53, "kind": "events", "events": [event("demo-013", 31, "territory", "terra", "Terra claims the Crown first. Sol is down to one route into the centre.", payload={"district_id": "crown", "district_state": {"owner": "terra", "supplied": True, "capture_progress": 0.86}})]},
        {"cue_id": "sol-adapts", "at": 55, "kind": "message", "event": event("demo-014", 31, "message", "sol", "Terra holds the point, not the road. Cut the supply line; leave the banner for last.")},
        {"cue_id": "flank-shot", "at": 57, "kind": "camera", "target_id": "sol_guard_1", "shot": "medium"},
    ]

    # 60–90s is a second, faster act in the accelerated one-hour match: Sol's
    # western flank breaks Terra's eastern supply, Terra counterattacks, and Luna
    # remains the visibly smaller scouting force between both fronts.
    reversal_units = deepcopy(u)
    reversal_units[0].update({"position": [-8, .45, -2], "task": "lead flank into Crown", "in_combat": True})
    reversal_units[2].update({"position": [-3, .45, -10], "task": "break supply line", "in_combat": True})
    reversal_units[3].update({"position": [13, .45, 5], "health": 92, "task": "hold against flank", "in_combat": True})
    reversal_units[5].update({"position": [16, .45, 11], "health": 31, "task": "protect banner", "in_combat": True})
    reversal_units[6].update({"district_id": "mine_tl", "position": [77, .45, -18], "task": "mark Terra reinforcements", "in_combat": False})
    reversal_units[7].update({"district_id": "mine_tl", "position": [80, .45, -17], "task": "scan east road", "in_combat": False})
    sol5, terra5, luna5 = deepcopy(sol4), deepcopy(terra4), deepcopy(luna4)
    sol5.update({"land_percent": 39, "army_strength": 9, "state": "counterattacking", "resources": {"food": 72, "wood": 21, "stone": 18, "iron": 13, "crystal": 25}, "intent": "Finish the flank before Terra's workshop can resupply the Crown."})
    terra5.update({"land_percent": 34, "army_strength": 8, "state": "under_pressure", "resources": {"food": 57, "wood": 12, "stone": 31, "iron": 16, "crystal": 19}, "intent": "Counterattack from Sunfall Mine and save second place."})
    luna5.update({"land_percent": 20, "army_strength": 3, "state": "scouting", "resources": {"food": 61, "wood": 28, "stone": 14, "iron": 10, "crystal": 10}, "intent": "Preserve the scout team and report the two-front reversal."})
    owners_reversal = {**owners, "crown": "sol"}
    cues += [
        {"cue_id": "reversal-snapshot", "at": 60, "kind": "snapshot", "snapshot": snapshot(35, "00:40", "resolution", reversal_units, [sol5, terra5, luna5], owners_reversal, contested="crown", progress=0.72, cut=("mine_st",))},
        {"cue_id": "reversal-wide", "at": 60.1, "kind": "camera", "target_id": "crown", "shot": "wide"},
        {"cue_id": "supply-cut", "at": 61, "kind": "events", "events": [event("demo-015", 35, "combat", "sol", "Sol's guard cuts Terra's Sunfall supply trail; the Crown defenders lose reinforcement.")]},
        {"cue_id": "crown-captured", "at": 63, "kind": "events", "events": [event("demo-016", 35, "territory", "sol", "Sol retakes the Crown with a supply-line flank, not a frontal assault.", payload={"district_id": "crown", "district_state": {"owner": "sol", "supplied": True, "capture_progress": 1.0}})]},
    ]
    luna_overreach_units = deepcopy(reversal_units)
    luna_overreach_units[6].update({"position": [91, .45, -4], "task": "confirm reserve route"})
    luna_overreach_units[7].update({"position": [94, .45, -7], "task": "scout beyond eastern line"})
    cues += [
        {"cue_id": "luna-overreach-snapshot", "at": 65, "kind": "snapshot", "snapshot": snapshot(36, "00:43", "resolution", luna_overreach_units, [sol5, terra5, luna5], owners_reversal, contested="crown", progress=0.92, cut=("mine_st", "mine_tl"))},
        {"cue_id": "luna-overextends", "at": 65.2, "kind": "message", "event": event("demo-017", 36, "message", "luna", "Public: Terra's reserve road is empty. Sol's western flank is cutting through.", targets=["sol", "terra"])},
        {"cue_id": "luna-shot", "at": 67, "kind": "camera", "target_id": "luna_commander", "shot": "close"},
    ]

    counter_units = deepcopy(reversal_units)
    counter_units[0].update({"position": [0, .45, 3], "health": 88, "task": "fortify captured Crown", "in_combat": False})
    counter_units[2].update({"position": [-7, .45, 10], "health": 58, "task": "hold west gate", "in_combat": False})
    counter_units[3].update({"district_id": "mine_st", "position": [20, .45, 45], "health": 88, "task": "counterattack road", "in_combat": True})
    counter_units[4].update({"district_id": "mine_st", "position": [29, .45, 56], "task": "repair workshop", "in_combat": False})
    counter_units[5].update({"district_id": "mine_st", "position": [13, .45, 54], "health": 28, "task": "screen counterattack", "in_combat": True})
    counter_units[6].update({"district_id": "mine_tl", "position": [65, .45, -5], "health": 84, "task": "escape crossfire", "in_combat": True})
    counter_units[7].update({"district_id": "mine_tl", "position": [72, .45, -8], "health": 18, "task": "evacuate scout", "in_combat": True})
    cues += [
        {"cue_id": "counterattack-snapshot", "at": 70, "kind": "snapshot", "snapshot": snapshot(38, "00:47", "resolution", counter_units, [sol5, terra5, luna5], owners_reversal, contested="crown", progress=1.0, cut=("mine_st", "mine_tl"))},
        {"cue_id": "counterattack-shot", "at": 70.1, "kind": "camera", "target_id": "terra_commander", "shot": "medium"},
        {"cue_id": "terra-saves-second", "at": 72, "kind": "events", "events": [event("demo-018", 38, "combat", "terra", "Terra's disciplined counterattack saves Sunfall Mine and second place, but cannot reach the Crown.")]},
        {"cue_id": "luna-collapse", "at": 74, "kind": "events", "events": [event("demo-019", 38, "combat", "luna", "Luna's small scout team is caught in the crossfire and retreats; information alone cannot win the Crown.")]},
        {"cue_id": "sol-offer", "at": 76, "kind": "message", "event": event("demo-020", 38, "message", "sol", "Public: Withdraw from the centre. Trade is open after the score is settled.", targets=["terra", "luna"])},
        {"cue_id": "overview-aftershock", "at": 78, "kind": "camera", "target_id": "overview", "shot": "overview"},
    ]

    final_units = deepcopy(counter_units)
    final_units[0].update({"position": [1, .45, 4], "task": "victory patrol"})
    final_units[2].update({"position": [-8, .45, 9], "task": "guard Crown"})
    final_units[3].update({"district_id": "home_terra", "position": [52, .45, 77], "task": "rebuild defences", "in_combat": False})
    final_units[4].update({"district_id": "mine_st", "position": [39, .45, 72], "task": "restore mine"})
    final_units[6].update({"district_id": "home_luna", "position": [28, .45, -72], "task": "return from raid", "in_combat": False})
    final_units[7].update({"district_id": "home_luna", "position": [22, .45, -79], "task": "report losses", "in_combat": False})
    sol_final, terra_final, luna_final = deepcopy(sol5), deepcopy(terra5), deepcopy(luna5)
    sol_final.update({"land_percent": 43, "army_strength": 9, "state": "victorious", "resources": {"food": 75, "wood": 24, "stone": 19, "iron": 16, "crystal": 48}, "intent": "Hold the Crown and convert the lead into a durable settlement."})
    terra_final.update({"land_percent": 33, "army_strength": 8, "state": "recovering", "resources": {"food": 55, "wood": 16, "stone": 36, "iron": 21, "crystal": 8}, "intent": "Rebuild behind the Sunfall Mine line."})
    luna_final.update({"land_percent": 18, "army_strength": 3, "state": "retreating", "resources": {"food": 54, "wood": 28, "stone": 12, "iron": 10, "crystal": 10}, "intent": "Consolidate the scout team after the two-front crossfire."})
    final_owners = {**owners_reversal, "mine_tl": "neutral"}
    cues += [
        {"cue_id": "final-world-state", "at": 81, "kind": "snapshot", "snapshot": snapshot(40, "01:00", "complete", final_units, [sol_final, terra_final, luna_final], final_owners)},
        {"cue_id": "final-sol-shot", "at": 81.1, "kind": "camera", "target_id": "sol_commander", "shot": "medium"},
        {"cue_id": "season-summary", "at": 83, "kind": "events", "events": [event("demo-021", 40, "territory", "sol", "Accelerated one-hour match complete: Sol holds the Crown and 43% of the island."), event("demo-022", 40, "territory", "terra", "Terra's eastern workshop economy survives the two-front war in second place."), event("demo-023", 40, "territory", "luna", "Luna's valuable scouting never becomes a decisive fighting force, leaving third place." )]},
        {"cue_id": "podium-overview", "at": 86, "kind": "camera", "target_id": "overview", "shot": "overview"},
    ]

    result = {
        "schema_version": 2, "formula_version": "worldarena-score/demo-local-1", "match_id": "local-demo-open-world-001",
        "result_notice": "Offline deterministic accelerated one-hour presentation demo. Not an official benchmark result.",
        "factions": [
            {"faction_id": "sol", "model_id": "gpt-5.6-sol", "placement": 1, "worldarena_score": 86.0, "reason": "Crown control, resilient economy, and timely diplomacy."},
            {"faction_id": "terra", "model_id": "gpt-5.6-terra", "placement": 2, "worldarena_score": 74.0, "reason": "Early infrastructure and a disciplined counterattack preserved second place."},
            {"faction_id": "luna", "model_id": "gpt-5.6-luna", "placement": 3, "worldarena_score": 62.0, "reason": "Useful scouting could not match the two frontline armies."},
        ],
    }
    # Chapters and restrained world-space effects are deliberately spread across
    # the whole runtime.  They make the upload read like a short film without
    # adding a wall of UI or claiming that an LLM produced these decisions.
    cues += [
        {"cue_id": "chapter-frontier", "at": 0.2, "kind": "chapter", "title": "ONE ACCELERATED HOUR", "subtitle": "Sol and Terra race to control two routes into the Crown.", "duration": 2.8, "accent": "neutral"},
        {"cue_id": "effect-sol-gather", "at": 8.0, "kind": "effect", "effect": "gather", "target_id": "sol_worker_1", "duration": 1.5},
        {"cue_id": "chapter-economy", "at": 12.0, "kind": "chapter", "title": "THE OPENING", "subtitle": "Gather, build, and find the routes to power.", "duration": 2.6, "accent": "terra"},
        {"cue_id": "effect-terra-build", "at": 15.0, "kind": "effect", "effect": "build", "target_id": "terra_commander", "duration": 2.0},
        {"cue_id": "effect-luna-gather", "at": 19.4, "kind": "effect", "effect": "gather", "target_id": "luna_scout_1", "duration": 1.2},
        {"cue_id": "chapter-diplomacy", "at": 24.0, "kind": "chapter", "title": "THE SCOUT REPORT", "subtitle": "Luna sells the eastern timing; Sol commits to the western front.", "duration": 2.5, "accent": "luna"},
        {"cue_id": "effect-trade", "at": 29.5, "kind": "effect", "effect": "trade", "target_id": "sol_commander", "duration": 1.8},
        {"cue_id": "effect-sol-build", "at": 32.0, "kind": "effect", "effect": "build", "target_id": "sol_worker_1", "duration": 1.4},
        {"cue_id": "chapter-crown", "at": 41.0, "kind": "chapter", "title": "TWO FRONTS COLLIDE", "subtitle": "Sol attacks from the west. Terra fortifies from the east.", "duration": 2.7, "accent": "terra"},
        {"cue_id": "effect-crown-combat-a", "at": 43.6, "kind": "effect", "effect": "combat", "target_id": "terra_commander", "duration": 2.1},
        {"cue_id": "effect-crown-combat-b", "at": 46.0, "kind": "effect", "effect": "combat", "target_id": "sol_guard_1", "duration": 1.7},
        {"cue_id": "effect-terra-capture", "at": 52.5, "kind": "effect", "effect": "capture", "target_id": "crown", "duration": 2.4},
        {"cue_id": "chapter-reversal", "at": 58.5, "kind": "chapter", "title": "THE REVERSAL", "subtitle": "Sol abandons the banner and cuts the supply road.", "duration": 2.8, "accent": "sol"},
        {"cue_id": "effect-sol-combat", "at": 60.7, "kind": "effect", "effect": "combat", "target_id": "sol_commander", "duration": 2.3},
        {"cue_id": "effect-sol-capture", "at": 63.2, "kind": "effect", "effect": "capture", "target_id": "crown", "duration": 2.5},
        {"cue_id": "effect-luna-greed", "at": 65.1, "kind": "effect", "effect": "gather", "target_id": "luna_commander", "duration": 1.2},
        {"cue_id": "effect-terra-counter", "at": 70.6, "kind": "effect", "effect": "combat", "target_id": "terra_commander", "duration": 2.0},
        {"cue_id": "effect-luna-ambush", "at": 74.2, "kind": "effect", "effect": "combat", "target_id": "luna_scout_1", "duration": 1.6},
        {"cue_id": "chapter-verdict", "at": 80.0, "kind": "chapter", "title": "THE VERDICT", "subtitle": "Sol adapts, Terra endures, Luna scouts the aftermath.", "duration": 2.8, "accent": "sol"},
        {"cue_id": "effect-terra-rally-east", "at": 37.0, "kind": "effect", "effect": "combat", "target_id": "terra_guard_1", "duration": 1.3},
        {"cue_id": "effect-sol-push-west", "at": 39.4, "kind": "effect", "effect": "combat", "target_id": "sol_commander", "duration": 1.3},
        {"cue_id": "effect-luna-scouting", "at": 49.2, "kind": "effect", "effect": "gather", "target_id": "luna_scout_1", "duration": 1.0},
        {"cue_id": "effect-terra-fortify", "at": 55.6, "kind": "effect", "effect": "build", "target_id": "terra_guard_1", "duration": 1.4},
        {"cue_id": "effect-sol-hold-west", "at": 68.1, "kind": "effect", "effect": "build", "target_id": "sol_guard_1", "duration": 1.3},
        {"cue_id": "effect-final-capture", "at": 84.0, "kind": "effect", "effect": "capture", "target_id": "crown", "duration": 1.7},
        {"cue_id": "demo-result", "at": 89, "kind": "result", "result": result},
    ]
    # The show player consumes cues in temporal order; sort after composing the
    # small story blocks so chapter/effect additions cannot create accidental gaps.
    cues.sort(key=lambda cue: (float(cue["at"]), cue["cue_id"]))
    replay = {
        "schema_version": 1, "duration_seconds": DURATION_SECONDS,
        "title": "WorldArena — Accelerated One-Hour Two-Front Highlight", "mode": "offline_deterministic_demo",
        "notice": "UNVERIFIED LOCAL DEMO — accelerated one-hour, presentation-only story; not an official benchmark result.",
        "initial_snapshot": initial, "cues": cues, "result": result,
    }
    assert all(0 <= float(cue["at"]) <= DURATION_SECONDS for cue in cues)
    assert [cue["cue_id"] for cue in cues] == list(dict.fromkeys(cue["cue_id"] for cue in cues))
    REPLAY_PATH.write_text(json.dumps(replay, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    digest = hashlib.sha256(REPLAY_PATH.read_bytes()).hexdigest()
    manifest = {
        "schema_version": 1, "protocol": "world-arena/0.2", "verified": False,
        "label": "UNVERIFIED LOCAL DEMO", "notice": "Offline deterministic accelerated one-hour presentation demo; not an official benchmark result.",
        "replay_file": REPLAY_PATH.name, "replay_sha256": digest,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    # The exporter uses this friendly name while older tooling still accepts a
    # standard manifest.json beside the replay.
    (OUT / "showcase.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {REPLAY_PATH.relative_to(ROOT)} ({len(cues)} cues, {DURATION_SECONDS}s)")
    print(f"SHA-256 {digest}")


if __name__ == "__main__":
    main()
