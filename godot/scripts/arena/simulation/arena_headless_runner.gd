extends SceneTree

const ArenaSimulation := preload("res://scripts/arena/simulation/arena_simulation.gd")
const Rules := preload("res://scripts/arena/simulation/arena_rules.gd")

func _init() -> void:
	var first := ArenaSimulation.new(424242)
	var second := ArenaSimulation.new(424242)
	for round in 48:
		first.resolve_round(_plans(first, round))
		second.resolve_round(_plans(second, round))
		assert(first.state_hash() == second.state_hash(), "non-deterministic state at round %d" % round)
	assert(first.state.match.ended, "match did not end after 40 rounds")
	assert(first.state.districts.size() == 13, "tri_13 map must have 13 districts")
	assert(first.state.units.size() > 0, "initial units missing")
	var passive := ArenaSimulation.new(99)
	var active := ArenaSimulation.new(99)
	var commander := _unit_ids(active, "sol", "commander")
	active.apply_round({"sol": [{"kind": "mobilize", "unit_ids": commander, "target": "mine_st"}]})
	passive.apply_round({})
	assert(active.get_state_hash() != passive.get_state_hash(), "different valid plans must change state")
	var surge := ArenaSimulation.new(7)
	for ignored in 20:
		surge.apply_round({})
	assert(int(surge.state.districts.crown.resources.crystal) == 270, "round-20 crown surge missing")
	assert(int(surge.state.districts.crown.max_resources.crystal) == 270, "crown surge maximum missing")
	assert(first.state.match.winner == "draw", "symmetric match must end in deterministic draw")
	assert(first.state.match.sudden_death, "symmetric tie must enter sudden death")
	var ranking := ArenaSimulation.new(3)
	ranking.state.factions.terra.territory.control_point_rounds = 99
	assert(ranking._rank_winner() == "terra", "territory-time tie-break must be deterministic")
	ranking.state.factions.sol.territory.control_point_rounds = 99
	ranking.state.factions.sol.core_hp = 900.0
	assert(ranking._rank_winner() == "terra", "core HP tie-break must outrank structure value")
	var elimination := ArenaSimulation.new(4)
	elimination._eliminate_faction("terra")
	assert(bool(elimination.state.factions.terra.eliminated), "core elimination flag missing")
	for unit in elimination.state.units.values(): assert(unit.faction != "terra", "eliminated unit survived")
	var gate := ArenaSimulation.new(5)
	assert(float(Rules.UNIT_STATS.siege.hp) == 130.0, "Siege HP contract mismatch")
	assert(float(Rules.UNIT_STATS.siege.dps_units) == 8.0, "Siege unit DPS contract mismatch")
	assert(float(Rules.UNIT_STATS.siege.dps_structures) == 32.0, "Siege structure DPS contract mismatch")
	assert(Rules.TRAINING.siege.cost == {"food": 60, "wood": 40, "iron": 30, "crystal": 15}, "Siege cost contract mismatch")
	assert(int(Rules.TRAINING.siege.rounds) == 2, "Siege training contract mismatch")
	assert(Rules.STRUCTURES.mine.cost == {"wood": 60, "stone": 40}, "Mine cost contract mismatch")
	assert(float(Rules.STRUCTURES.tower.hp) == 300.0 and float(Rules.STRUCTURES.tower.dps) == 14.0, "Tower stat contract mismatch")
	assert(Rules.STRUCTURES.tower.cost == {"stone": 70, "iron": 25}, "Tower cost contract mismatch")
	assert(_structure_ids(gate, "sol", "tower").size() == 1, "each faction must start with one defensive tower")
	var siege_unit := {"faction": "sol", "kind": "siege", "district": "home_sol"}
	var siege_unit_damage := gate._unit_damage(siege_unit, false)
	var siege_structure := ArenaSimulation.new(5)
	var siege_structure_damage := siege_structure._unit_damage(siege_unit, true)
	assert(is_equal_approx(siege_structure_damage, siege_unit_damage * 4.0), "Siege must deal four times damage to structures")
	var siege_priority := ArenaSimulation.new(10)
	siege_priority.state.units.clear()
	siege_priority.state.structures.clear()
	siege_priority._add_unit_to(siege_priority.state, "sol", "siege", "home_sol")
	siege_priority._add_unit_to(siege_priority.state, "terra", "worker", "home_sol")
	siege_priority._add_structure_to(siege_priority.state, "terra", "farm", "home_sol", false)
	var defended_worker: String = str(_unit_ids(siege_priority, "terra", "worker")[0])
	siege_priority._resolve_combat(1)
	assert(is_equal_approx(float(siege_priority.state.units[defended_worker].hp), 30.0), "Siege must target structures before units")
	gate.state.districts.home_sol.resources.iron = 20
	gate.apply_round({"sol": [{"kind": "assign_workers", "district": "home_sol", "node": "iron", "unit_ids": _unit_ids(gate, "sol", "worker")} ]})
	assert(int(gate.state.factions.sol.stockpile.iron) == 0, "iron must require Mine")
	gate._add_structure_to(gate.state, "sol", "mine", "home_sol", false)
	gate.apply_round({})
	assert(int(gate.state.factions.sol.stockpile.iron) > 0, "Mine must enable iron harvesting")
	var respawn := ArenaSimulation.new(6)
	respawn._kill_unit(str(_unit_ids(respawn, "sol", "commander")[0]))
	for ignored in 4: respawn.apply_round({})
	assert(_unit_ids(respawn, "sol", "commander").size() == 1, "Commander must respawn after three rounds")
	var crown_hold := ArenaSimulation.new(8)
	crown_hold.state.districts.crown.owner = "sol"
	crown_hold.state.factions.sol.supply.supplied_districts.append("crown")
	crown_hold._score_and_end()
	assert(int(crown_hold.state.factions.sol.territory.crown_hold_rounds) == 1, "supplied Crown must increment crown-hold metric once per scoring round")
	print("ARENA_HEADLESS_OK hash=%s winner=%s events=%d" % [first.state_hash(), first.state.match.winner, first.state.events.size()])
	quit(0)

func _plans(sim: ArenaSimulation, round: int) -> Dictionary:
	var plans := {}
	for faction in ["sol", "terra", "luna"]:
		var home := "home_%s" % faction
		var workers: Array = []
		for unit_id in sim.state.units.keys():
			if sim.state.units[unit_id].faction == faction and sim.state.units[unit_id].kind == "worker": workers.append(unit_id)
		plans[faction] = [{"kind": "assign_workers", "district": home, "node": "forest", "unit_ids": workers}]
	return plans

func _unit_ids(sim: ArenaSimulation, faction: String, kind: String) -> Array:
	var ids: Array = []
	for unit_id in sim.state.units.keys():
		if sim.state.units[unit_id].faction == faction and sim.state.units[unit_id].kind == kind:
			ids.append(unit_id)
	return ids

func _structure_ids(sim: ArenaSimulation, faction: String, kind: String) -> Array:
	var ids: Array = []
	for structure_id in sim.state.structures.keys():
		if sim.state.structures[structure_id].faction == faction and sim.state.structures[structure_id].kind == kind:
			ids.append(structure_id)
	return ids
