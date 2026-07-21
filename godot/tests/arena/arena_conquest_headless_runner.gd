extends SceneTree

const ArenaSimulation := preload("res://scripts/arena/simulation/arena_simulation.gd")
const Rules := preload("res://scripts/arena/simulation/arena_rules.gd")


func _init() -> void:
	var sim := ArenaSimulation.new(404)
	var sol_view: Dictionary = sim.project_faction_observation("sol")
	assert(not sol_view.districts.has("home_terra"), "fog projection leaked an unseen enemy district")
	assert(not sol_view.has("stockpile"), "faction projection leaked enemy stockpiles")
	assert(sol_view.tasks.all(func(task): return task.faction == "sol"), "projection leaked enemy tasks")

	var sol_commander := _unit_id(sim, "sol", "commander")
	sim.apply_round({"sol": [{"type": "Move", "unit_ids": [sol_commander], "target": "mine_st"}]})
	sol_view = sim.project_faction_observation("sol")
	assert(sol_view.districts.has("mine_st"), "scouting/movement did not discover a district")
	assert(not sol_view.contacts.is_empty(), "scouting did not produce a last-seen contact")
	var contact: Dictionary = sol_view.contacts.values()[0]
	assert(int(contact.last_seen_round) >= 1, "contact lacks deterministic last-seen data")

	var protocol := ArenaSimulation.new(405)
	var terra_worker := _unit_id(protocol, "terra", "worker")
	var wood_before := int(protocol.state.factions.terra.stockpile.wood)
	protocol.apply_round({"terra": [{"action": "Gather", "actor_ids": [terra_worker], "target_id": "home_terra", "resource": "wood"}]})
	assert(int(protocol.state.factions.terra.stockpile.wood) > wood_before, "v0.4 action/actor/resource gather order was not accepted")
	var normalized_build := protocol._normalize_order("terra", {"action": "Build", "actor_ids": [terra_worker], "target_id": "home_terra", "option": "wall", "attributes": {"mode": "build"}})
	assert(normalized_build.kind == "Build" and normalized_build.structure == "wall" and normalized_build.district == "home_terra", "Build option/attributes were not normalized")
	var normalized_train := protocol._normalize_order("terra", {"action": "Build", "actor_ids": [terra_worker], "target_id": "home_terra", "option": "militia", "mode": "train"})
	assert(normalized_train.kind == "train" and normalized_train.unit == "militia", "Build train mode was not normalized")
	var normalized_research := protocol._normalize_order("terra", {"action": "Research", "actor_ids": [terra_worker], "option": "fieldcraft"})
	assert(normalized_research.technology_id == "fieldcraft", "Research option was not normalized")
	var sol_target := _unit_id(protocol, "sol", "commander")
	var normalized_attack := protocol._normalize_order("terra", {"action": "Attack", "actor_ids": [terra_worker], "target_id": sol_target})
	assert(normalized_attack.target_id == sol_target and normalized_attack.target == "home_sol", "Attack target identity/district were not both retained")

	sim._add_structure_to(sim.state, "sol", "workshop", "home_sol", false)
	assert(not sim._can_train("sol", "guard"), "guard must require fieldcraft")
	var sol_worker := _unit_id(sim, "sol", "worker")
	sim.apply_round({"sol": [{"type": "Research", "technology_id": "fieldcraft", "district": "home_sol", "worker_ids": [sol_worker]}]})
	assert(sim.state.factions.sol.tech.completed.has("fieldcraft"), "research task did not complete")
	assert(sim._can_train("sol", "guard"), "fieldcraft did not unlock guard")
	assert(not sim._can_train("sol", "siege"), "siege must remain locked before ironworking")

	sim._add_structure_to(sim.state, "sol", "wall", "home_sol", false)
	var wall_id := _structure_id(sim, "sol", "wall")
	sim.state.structures[wall_id].hp = 90.0
	sim.apply_round({"sol": [{"type": "Build", "mode": "repair", "target_id": wall_id, "worker_ids": [sol_worker]}]})
	assert(is_equal_approx(float(sim.state.structures[wall_id].hp), float(Rules.STRUCTURES.wall.hp)), "worker repair task did not restore the wall")

	var siege := ArenaSimulation.new(505)
	siege._add_structure_to(siege.state, "terra", "wall", "core_terra", false)
	var defending_wall := _structure_id(siege, "terra", "wall")
	siege._add_unit_to(siege.state, "sol", "militia", "core_terra")
	var core_before := float(siege.state.factions.terra.core_hp)
	var wall_before := float(siege.state.structures[defending_wall].hp)
	siege._resolve_combat(1)
	assert(float(siege.state.structures[defending_wall].hp) < wall_before, "siege must damage a wall before the core")
	assert(is_equal_approx(float(siege.state.factions.terra.core_hp), core_before), "wall must gate core damage")

	var conquest := ArenaSimulation.new(606)
	conquest._eliminate_faction("terra")
	conquest._eliminate_faction("luna")
	conquest._check_conquest_end()
	assert(conquest.state.match.winner == "sol" and not bool(conquest.state.match.truncated), "last survivor must be the only winner")

	var capped := ArenaSimulation.new(707)
	capped.state.match.round = Rules.MATCH_ROUNDS
	capped._check_conquest_end()
	assert(bool(capped.state.match.truncated), "round cap must truncate")
	assert(str(capped.state.match.winner).is_empty(), "truncated conquest must not assign a winner")
	print("ARENA_CONQUEST_HEADLESS_OK")
	quit(0)


func _unit_id(sim: ArenaSimulation, faction: String, kind: String) -> String:
	for unit_id in sim.state.units.keys():
		if sim.state.units[unit_id].faction == faction and sim.state.units[unit_id].kind == kind:
			return str(unit_id)
	return ""


func _structure_id(sim: ArenaSimulation, faction: String, kind: String) -> String:
	for structure_id in sim.state.structures.keys():
		if sim.state.structures[structure_id].faction == faction and sim.state.structures[structure_id].kind == kind:
			return str(structure_id)
	return ""

