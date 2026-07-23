#!/usr/bin/env python3
"""Build the deterministic 90-second world-arena/0.4 conquest showcase.

This is an authored, presentation-only replay.  It uses the same snapshot and
cue schema as the showcase player, while telling the current conquest loop:
workers gather over time, collaborate on construction, unlock research and
training, scout crossroads, and then take a defended enemy stronghold by siege.
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
    "core_sol", "home_sol", "core_terra", "home_terra", "core_luna", "home_luna",
    "mine_ls", "mine_st", "mine_tl", "wild_ls", "wild_st", "wild_tl", "crossroads",
)
BASE_OWNERS = {
    "core_sol": "sol", "home_sol": "sol", "core_terra": "terra",
    "home_terra": "terra", "core_luna": "luna", "home_luna": "luna",
}
CATEGORY_WEIGHTS = {
    "objective_control": 0.35,
    "planning_adaptation": 0.20,
    "resource_combat_efficiency": 0.15,
    "social_intelligence": 0.15,
    "delegation_cognition": 0.10,
    "reliability_safety": 0.05,
}


def unit(unit_id: str, faction_id: str, unit_type: str, district_id: str,
         position: list[float], task_name: str, health: int | None = None,
         combat: bool = False) -> dict:
    maximum = {"commander": 150, "worker": 30, "scout": 40, "militia": 75, "guard": 110, "siege": 130}[unit_type]
    return {
        "id": unit_id, "faction_id": faction_id, "unit_type": unit_type,
        "district_id": district_id, "position": position, "health": maximum if health is None else health,
        "max_health": maximum, "task": task_name, "in_combat": combat,
    }


def faction(faction_id: str, state: str, resources: dict, intent: str,
            land: int, army: int = 0, core_hp: int = 900) -> dict:
    return {
        "id": faction_id, "core_hp": core_hp, "land_percent": land,
        "army_strength": army, "state": state, "resources": resources,
        "strategic_intent": intent, "orders": [], "specialists": [],
    }


def districts(owners: dict[str, str], contested: bool = False) -> list[dict]:
    result = []
    for district_id in DISTRICTS:
        record = {"id": district_id, "owner": owners.get(district_id, "neutral"), "supplied": True}
        if district_id == "crossroads":
            record.update({"contested": contested, "capture_progress": 0.5 if contested else 0.0})
        result.append(record)
    return result


def task(task_id: str, faction_id: str, actor_id: str, district_id: str,
         resource: str, completed: int, position: list[float]) -> dict:
    return {
        "id": task_id, "kind": "gather", "faction_id": faction_id,
        "actor_id": actor_id, "district_id": district_id, "resource": resource,
        "state": "active" if completed < 100 else "complete", "completed_work": completed,
        "required_work": 100, "position": position,
    }


def construction(completed: int, builders: list[str]) -> dict:
    return {
        "id": "sol_war_workshop", "kind": "construction", "structure": "Workshop",
        "faction_id": "sol", "district_id": "home_sol", "position": [-88, 0.45, 58],
        "state": "active" if completed < 100 else "complete", "completed_work": completed,
        "required_work": 100, "builder_ids": builders,
    }


def snapshot(round_number: int, sim_time: str, units: list[dict], factions: list[dict],
             owners: dict[str, str], *, work: list[dict], build: int = -1,
             builders: list[str] | None = None, contested: bool = False,
             phase: str = "resolution") -> dict:
    return {
        "match_id": "local-conquest-protocol-004", "round": round_number,
        "max_rounds": 120, "phase": phase, "sim_time": sim_time,
        "thinking_status": {"sol": "locked", "terra": "locked", "luna": "locked"},
        "factions": factions, "districts": districts(owners, contested), "units": units,
        "tasks": work, "construction": [construction(build, builders or [])] if build >= 0 else [],
    }


def event(event_id: str, round_number: int, kind: str, actor: str, summary: str,
          payload: dict | None = None) -> dict:
    result = {"event_id": event_id, "round": round_number, "kind": kind,
              "actor_id": actor, "target_ids": [], "visibility": "public", "summary": summary}
    if payload:
        result["payload"] = payload
    return result


def add(cues: list[dict], cue_id: str, at: float, kind: str, **content: object) -> None:
    cues.append({"cue_id": cue_id, "at": at, "kind": kind, **content})


def evaluation(faction_id: str, placement: int, scores: dict[str, float], metrics: dict,
               best_round: int, best: str, miss_round: int, miss: str) -> dict:
    categories = [
        {"category": category, "score": float(scores[category]), "weight": weight,
         "weighted_contribution": round(float(scores[category]) * weight, 2),
         "measurement_count": 1, "event_ids": [f"demo.{faction_id}.{category}"],
         "action_ids": [f"demo-action.{faction_id}.{category}"]}
        for category, weight in CATEGORY_WEIGHTS.items()
    ]
    return {
        "faction_id": faction_id, "placement": placement, "model": f"demo-policy · {faction_id}",
        "worldarena_score": round(sum(item["weighted_contribution"] for item in categories), 1),
        "categories": categories, "metrics": metrics,
        "best_decision": {"round": best_round, "summary": best},
        "biggest_failure": {"round": miss_round, "summary": miss},
    }


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    sol = faction("sol", "opening", {"food": 40, "wood": 25, "stone": 15, "iron": 0, "crystal": 0}, "Gather, fortify, and break a rival stronghold.", 15)
    terra = faction("terra", "opening", {"food": 40, "wood": 25, "stone": 15, "iron": 0, "crystal": 0}, "Hold the eastern stronghold and counterattack.", 15)
    luna = faction("luna", "opening", {"food": 40, "wood": 25, "stone": 15, "iron": 0, "crystal": 0}, "Scout crossroads and preserve its stronghold.", 15)
    units = [
        unit("sol_commander", "sol", "commander", "home_sol", [-108, .45, 96], "lead gathering party"),
        unit("sol_worker_1", "sol", "worker", "home_sol", [-114, .45, 88], "walk to forest"),
        unit("terra_commander", "terra", "commander", "home_terra", [108, .45, 96], "fortify eastern route"),
        unit("terra_worker_1", "terra", "worker", "home_terra", [114, .45, 88], "walk to quarry"),
        unit("luna_commander", "luna", "commander", "home_luna", [0, .45, -108], "lead scout route"),
        unit("luna_worker_1", "luna", "worker", "home_luna", [7, .45, -104], "walk to iron"),
    ]
    cues: list[dict] = []
    initial = snapshot(1, "00:00", units, [sol, terra, luna], BASE_OWNERS, work=[], phase="thinking")
    add(cues, "opening", 0, "phase", phase="thinking", statuses={"sol": "thinking", "terra": "thinking", "luna": "thinking"})
    add(cues, "opening-title", .2, "chapter", title="THREE STRONGHOLDS. NO SHORTCUT.", subtitle="Conquest ends only when one stronghold remains.", duration=3, accent="neutral")
    add(cues, "opening-shot", 1, "camera", target_id="overview", shot="overview")

    walk = deepcopy(units)
    for index, position, district, label in [
        (0, [-92, .45, 84], "home_sol", "lead forest route"), (1, [-98, .45, 74], "home_sol", "walk to forest"),
        (2, [92, .45, 84], "home_terra", "lead quarry route"), (3, [98, .45, 74], "home_terra", "walk to stone"),
        (4, [0, .45, -91], "home_luna", "lead scout route"), (5, [10, .45, -88], "home_luna", "walk to iron"),
    ]:
        walk[index].update(position=position, district_id=district, task=label)
    add(cues, "walk-out", 8, "snapshot", snapshot=snapshot(5, "00:08", walk, [sol, terra, luna], BASE_OWNERS, work=[]))
    add(cues, "walk-shot", 8.1, "camera", target_id="sol_worker_1", shot="medium")

    work0 = deepcopy(walk)
    work0[0].update(position=[-78, .45, 62], district_id="wild_ls", task="guard worker")
    work0[1].update(position=[-82, .45, 55], district_id="wild_ls", task="gather wood · 0%")
    work0[2].update(position=[78, .45, 62], district_id="mine_st", task="guard worker")
    work0[3].update(position=[82, .45, 55], district_id="mine_st", task="gather stone · 0%")
    work0[4].update(position=[-4, .45, -72], district_id="mine_tl", task="scout crossroads")
    work0[5].update(position=[8, .45, -68], district_id="mine_tl", task="gather iron · 0%")
    owners1 = {**BASE_OWNERS, "wild_ls": "sol", "mine_st": "terra", "mine_tl": "luna"}
    gathering0 = [task("sol_wood", "sol", "sol_worker_1", "wild_ls", "wood", 0, [-82, .45, 55]), task("terra_stone", "terra", "terra_worker_1", "mine_st", "stone", 0, [82, .45, 55]), task("luna_iron", "luna", "luna_worker_1", "mine_tl", "iron", 0, [8, .45, -68])]
    add(cues, "gather-zero", 16, "snapshot", snapshot=snapshot(10, "00:16", work0, [sol, terra, luna], owners1, work=gathering0))
    add(cues, "gather-title", 16.2, "chapter", title="WORK PERSISTS", subtitle="Workers walk, gather, and deliver over time — no instant resource grant.", duration=3, accent="sol")
    add(cues, "gather-effect", 18, "effect", effect="gather", target_id="sol_worker_1", duration=2)

    work55 = deepcopy(work0)
    work55[1].update(position=[-72, .45, 47], task="gather wood · 55%")
    work55[3].update(position=[72, .45, 47], task="gather stone · 55%")
    work55[5].update(position=[9, .45, -57], task="gather iron · 55%")
    sol2 = deepcopy(sol); sol2.update(state="gathering", resources={"food": 40, "wood": 61, "stone": 15, "iron": 0, "crystal": 0})
    terra2 = deepcopy(terra); terra2.update(state="gathering", resources={"food": 40, "wood": 25, "stone": 51, "iron": 0, "crystal": 0})
    luna2 = deepcopy(luna); luna2.update(state="scouting", resources={"food": 40, "wood": 25, "stone": 15, "iron": 18, "crystal": 0})
    gathering55 = [task("sol_wood", "sol", "sol_worker_1", "wild_ls", "wood", 55, [-72, .45, 47]), task("terra_stone", "terra", "terra_worker_1", "mine_st", "stone", 55, [72, .45, 47]), task("luna_iron", "luna", "luna_worker_1", "mine_tl", "iron", 55, [9, .45, -57])]
    add(cues, "gather-fifty-five", 25, "snapshot", snapshot=snapshot(16, "00:25", work55, [sol2, terra2, luna2], owners1, work=gathering55))

    builders = deepcopy(work55)
    builders[1].update(position=[-88, .45, 58], district_id="home_sol", task="build workshop · 30%")
    builders.append(unit("sol_worker_2", "sol", "worker", "home_sol", [-81, .45, 56], "build workshop · 30%"))
    sol3 = deepcopy(sol2); sol3.update(state="building", resources={"food": 30, "wood": 5, "stone": 0, "iron": 0, "crystal": 0})
    add(cues, "two-builders", 34, "snapshot", snapshot=snapshot(23, "00:34", builders, [sol3, terra2, luna2], owners1, work=[gathering55[1], gathering55[2]], build=30, builders=["sol_worker_1", "sol_worker_2"]))
    add(cues, "two-builders-title", 34.2, "chapter", title="TWO WORKERS, FASTER BUILD", subtitle="The same workshop task advances faster with a second builder.", duration=3, accent="sol")
    add(cues, "build-effect", 36, "effect", effect="build", target_id="sol_worker_2", duration=2)

    workshop = deepcopy(builders)
    workshop[1].update(position=[-83, .45, 54], task="workshop complete; start fieldcraft")
    workshop[6].update(position=[-78, .45, 51], task="workshop complete; assist research")
    workshop.append(unit("sol_scout_1", "sol", "scout", "home_sol", [-72, .45, 44], "trained scout leaves workshop"))
    sol4 = deepcopy(sol3); sol4.update(state="researching", resources={"food": 12, "wood": 20, "stone": 5, "iron": 0, "crystal": 0}, army_strength=1)
    add(cues, "research-training", 43, "snapshot", snapshot=snapshot(31, "00:43", workshop, [sol4, terra2, luna2], owners1, work=[], build=100, builders=["sol_worker_1", "sol_worker_2"]))
    add(cues, "fieldcraft-event", 44, "events", events=[event("c01", 31, "research", "sol", "Fieldcraft completes: workshop training unlocks guard units."), event("c02", 31, "train", "sol", "A scout trains and remains visible as it leaves the workshop.")])

    scout = deepcopy(workshop)
    scout[7].update(position=[-12, .45, 8], district_id="crossroads", task="reveal crossroads route")
    scout[4].update(position=[2, .45, -24], district_id="crossroads", task="spot Sol scout")
    add(cues, "crossroads-scout", 51, "snapshot", snapshot=snapshot(39, "00:51", scout, [sol4, terra2, luna2], owners1, work=[], build=100, builders=["sol_worker_1", "sol_worker_2"], contested=True))
    add(cues, "crossroads-title", 51.2, "chapter", title="SCOUT CROSSROADS", subtitle="Scouting reveals the shortest approach to Terra's defended core.", duration=3, accent="luna")
    add(cues, "crossroads-shot", 54, "camera", target_id="sol_scout_1", shot="close")

    assault = deepcopy(scout)
    assault.append(unit("sol_guard_1", "sol", "guard", "mine_st", [48, .45, 34], "fieldcraft guard escorts siege"))
    assault.append(unit("sol_siege_1", "sol", "siege", "mine_st", [55, .45, 39], "siege approaches Terra wall"))
    assault[0].update(position=[36, .45, 31], district_id="mine_st", task="command assault")
    assault[1].update(position=[40, .45, 28], district_id="mine_st", task="carry supplies")
    assault[7].update(position=[35, .45, 25], district_id="mine_st", task="spot wall targets")
    terra3 = deepcopy(terra2); terra3.update(state="fortified", resources={"food": 25, "wood": 20, "stone": 10, "iron": 0, "crystal": 0}, army_strength=1)
    sol5 = deepcopy(sol4); sol5.update(state="sieging", army_strength=2, land_percent=31)
    add(cues, "siege-march", 61, "snapshot", snapshot=snapshot(48, "01:01", assault, [sol5, terra3, luna2], owners1, work=[], build=100, builders=["sol_worker_1", "sol_worker_2"]))
    add(cues, "siege-title", 61.2, "chapter", title="SIEGE THE STRONGHOLD", subtitle="Walls absorb damage first; the core falls only after the defense breaks.", duration=3, accent="terra")

    exchange1 = deepcopy(assault)
    exchange1[8].update(position=[77, .45, 18], district_id="home_terra", task="fire on Terra wall", combat=True, health=126)
    exchange1[9].update(position=[70, .45, 20], district_id="home_terra", task="screen siege", combat=True, health=100)
    exchange1[2].update(position=[84, .45, 22], district_id="home_terra", task="hold wall", combat=True, health=137)
    add(cues, "siege-exchange-one", 68, "snapshot", snapshot=snapshot(54, "01:08", exchange1, [sol5, terra3, luna2], owners1, work=[], build=100, builders=["sol_worker_1", "sol_worker_2"]))
    add(cues, "siege-exchange-one-event", 69, "events", events=[event("c03", 54, "combat", "sol", "Exchange one: Sol's siege damages Terra's wall; Terra's commander answers from cover."), event("c04", 54, "structure_damaged", "terra", "Terra wall: 180 → 92 HP. The core remains untouched.")])
    add(cues, "siege-effect-one", 69.1, "effect", effect="combat", target_id="sol_siege_1", duration=2)

    exchange2 = deepcopy(exchange1)
    exchange2[8].update(position=[88, .45, 12], district_id="core_terra", task="breach wall; fire on core", combat=True, health=112)
    exchange2[9].update(position=[81, .45, 14], district_id="core_terra", task="hold breach", combat=True, health=78)
    exchange2[2].update(position=[91, .45, 14], district_id="core_terra", task="defend core", combat=True, health=112)
    terra4 = deepcopy(terra3); terra4.update(state="stronghold under siege", core_hp=640)
    add(cues, "siege-exchange-two", 75, "snapshot", snapshot=snapshot(60, "01:15", exchange2, [sol5, terra4, luna2], owners1, work=[], build=100, builders=["sol_worker_1", "sol_worker_2"]))
    add(cues, "siege-exchange-two-event", 76, "events", events=[event("c05", 60, "structure_destroyed", "sol", "Exchange two: the wall breaks. Siege fire now reaches Terra's core."), event("c06", 60, "core_damaged", "terra", "Terra core: 900 → 640 HP.")])

    final = deepcopy(exchange2)
    final[8].update(position=[96, .45, 5], task="final siege volley", combat=True, health=96)
    final[9].update(position=[89, .45, 7], task="secure stronghold", combat=True, health=61)
    final[2].update(position=[102, .45, 4], task="last defense", combat=True, health=74)
    sol6 = deepcopy(sol5); sol6.update(state="leading · one rival remains", land_percent=39)
    terra5 = deepcopy(terra4); terra5.update(state="eliminated", land_percent=0, core_hp=0, army_strength=0)
    owners_final = {**owners1, "mine_st": "sol", "home_terra": "neutral", "core_terra": "neutral"}
    add(cues, "siege-exchange-three", 83, "snapshot", snapshot=snapshot(67, "01:23", final, [sol6, terra5, luna2], owners_final, work=[], build=100, builders=["sol_worker_1", "sol_worker_2"], phase="resolution"))
    add(cues, "last-stronghold", 84, "events", events=[event("c07", 67, "core_destroyed", "sol", "Exchange three: Terra's stronghold falls; its units and holdings are removed."), event("c08", 67, "conquest", "sol", "Two strongholds remain. Sol must still outlast Luna — conquest is last stronghold standing.")])
    add(cues, "objective-title", 86, "chapter", title="ONE RIVAL REMAINS", subtitle="Sol wins this siege, but conquest ends only when a single stronghold is still standing.", duration=3, accent="sol")
    add(cues, "final-shot", 88, "camera", target_id="core_terra", shot="wide")

    result = {
        "schema_version": 2, "formula_version": "worldarena-score/1.1.0",
        "match_id": "local-conquest-protocol-004",
        "result_notice": "Offline deterministic conquest presentation. Not an official benchmark result.",
        "weights": CATEGORY_WEIGHTS,
        "factions": [
            evaluation("sol", 1, {"objective_control": 94, "planning_adaptation": 90, "resource_combat_efficiency": 92, "social_intelligence": 62, "delegation_cognition": 84, "reliability_safety": 75}, {"strongholds_destroyed": 1, "strongholds_alive": 1, "territory": 39, "structures_destroyed": 1, "invalid": 0}, 60, "Committed research, guard, and siege only after the scout exposed the route.", 54, "Left the workshop workers briefly exposed while the scout crossed crossroads."),
            evaluation("terra", 2, {"objective_control": 54, "planning_adaptation": 76, "resource_combat_efficiency": 70, "social_intelligence": 52, "delegation_cognition": 66, "reliability_safety": 80}, {"strongholds_destroyed": 0, "strongholds_alive": 0, "territory": 0, "structures_destroyed": 0, "invalid": 0}, 54, "Used its wall to absorb the first exchange and protect the core.", 60, "Could not replace the breached wall before the siege reached the core."),
            evaluation("luna", 3, {"objective_control": 48, "planning_adaptation": 72, "resource_combat_efficiency": 66, "social_intelligence": 80, "delegation_cognition": 70, "reliability_safety": 88}, {"strongholds_destroyed": 0, "strongholds_alive": 1, "territory": 15, "structures_destroyed": 0, "invalid": 0}, 39, "Scouted crossroads without losing its initial units.", 48, "Did not contest Sol's route before the eastern siege began."),
        ],
    }
    add(cues, "demo-result", 89, "result", result=result)
    cues.sort(key=lambda cue: (float(cue["at"]), cue["cue_id"]))
    replay = {
        "schema_version": 1, "duration_seconds": DURATION_SECONDS,
        "title": "WorldArena — Protocol 0.4 Conquest", "mode": "offline_deterministic_demo",
        "notice": "UNVERIFIED LOCAL DEMO — deterministic presentation-only conquest story; not an official benchmark result.",
        "initial_snapshot": initial, "cues": cues, "result": result,
    }
    assert all(0 <= float(cue["at"]) <= DURATION_SECONDS for cue in cues)
    assert [cue["cue_id"] for cue in cues] == list(dict.fromkeys(cue["cue_id"] for cue in cues))
    REPLAY_PATH.write_text(json.dumps(replay, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    digest = hashlib.sha256(REPLAY_PATH.read_bytes()).hexdigest()
    manifest = {"schema_version": 1, "protocol": "world-arena/0.4", "verified": False,
                "label": "UNVERIFIED LOCAL DEMO", "notice": "Offline deterministic conquest presentation; not an official benchmark result.",
                "replay_file": REPLAY_PATH.name, "replay_sha256": digest}
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (OUT / "showcase.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {REPLAY_PATH.relative_to(ROOT)} ({len(cues)} cues, {DURATION_SECONDS}s)")
    print(f"SHA-256 {digest}")


if __name__ == "__main__":
    main()
