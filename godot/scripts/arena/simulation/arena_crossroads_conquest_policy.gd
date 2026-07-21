class_name ArenaCrossroadsConquestPolicy
extends RefCounted

## Locked, credential-free showcase policy.  Its only input is the participant
## projection returned by ArenaSimulation.project_faction_observation().

const POLICY_ID := "crossroads-conquest-demo-v1"
const HOME := {"sol": "home_sol", "terra": "home_terra", "luna": "home_luna"}
const CORE := {"sol": "core_sol", "terra": "core_terra", "luna": "core_luna"}
const MINE := {"sol": "mine_st", "terra": "mine_tl", "luna": "mine_ls"}


func orders_for(observation: Dictionary) -> Array:
	var faction := str(observation.faction_id)
	var round_number := int(observation.round)
	if bool(observation.public_scores[faction].eliminated): return []
	var orders: Array = []
	if round_number <= 7:
		_opening(observation, orders)
	elif faction == "sol":
		_sol(observation, orders)
	elif faction == "terra":
		_terra(observation, orders)
	else:
		_luna(observation, orders)
	return orders


func _opening(observation: Dictionary, orders: Array) -> void:
	var faction := str(observation.faction_id)
	var round_number := int(observation.round)
	var home := str(HOME[faction])
	var mine := str(MINE[faction])
	var home_workers := _units_at(observation, "worker", home)
	var core_workers := _units_at(observation, "worker", str(CORE[faction]))
	if round_number == 1:
		_gather(orders, home, "animals", home_workers.slice(0, 1))
		_train(observation, orders, "worker")
	elif round_number == 2:
		_move(orders, core_workers, home)
		_gather(orders, home, "stone", home_workers.slice(0, 1))
		_train(observation, orders, "worker")
	elif round_number == 3:
		_move(orders, core_workers, home)
		_gather(orders, home, "forest", home_workers)
		_train(observation, orders, "worker")
	elif round_number == 4:
		var builders := home_workers.slice(0, 2)
		_build(observation, orders, "storage", home, builders)
		var movers := _units_at(observation, "commander", home)
		movers.append_array(home_workers.slice(2, 3))
		movers.append_array(core_workers)
		_move(orders, movers, mine)
	elif round_number == 5:
		# The core worker ordered toward the mine in round four continues along its
		# visible target; do not accidentally send a third home worker after it.
		_gather(orders, home, "stone", home_workers)
		if faction == "luna": _train(observation, orders, "scout")
	elif round_number == 6:
		if _capture_ready(observation, mine, faction):
			_build(observation, orders, "outpost", mine, _units_at(observation, "worker", mine).slice(0, 2))
		_gather(orders, home, "forest", home_workers.slice(0, 1))
	elif round_number == 7:
		_build(observation, orders, "mine", mine, _units_at(observation, "worker", mine).slice(0, 2))
		_gather(orders, home, "animals", home_workers.slice(0, 1))
		if faction == "terra": _move(orders, _units_at(observation, "commander", mine), "crossroads")


func _sol(observation: Dictionary, orders: Array) -> void:
	var round_number := int(observation.round)
	var center := _district(observation, "crossroads")
	var center_owner := str(center.get("owner", ""))
	var center_outpost := str(center.get("outpost_id", ""))
	var home_workers := _units_at(observation, "worker", "home_sol")
	var mine_workers := _units_at(observation, "worker", "mine_st")
	var center_workers := _units_at(observation, "worker", "crossroads")
	if round_number == 8:
		_gather(orders, "mine_st", "iron", mine_workers.slice(0, 1))
		_gather(orders, "mine_st", "forest", mine_workers.slice(1, 2))
		_train(observation, orders, "militia")
	elif round_number == 9:
		_build(observation, orders, "workshop", "home_sol", home_workers.slice(0, 2))
		_move(orders, _units_at(observation, "militia", "core_sol"), "home_sol")
	elif round_number == 10:
		if _has_structure(observation, "home_sol", "workshop"):
			_research(observation, orders, "fieldcraft", "home_sol", home_workers.slice(0, 2))
		_move(orders, _units_at(observation, "militia", "home_sol"), "mine_st")
	elif round_number == 11:
		if observation.technology.completed.has("fieldcraft"):
			_research(observation, orders, "ironworking", "home_sol", home_workers.slice(0, 2))
			_train(observation, orders, "guard")
	elif _capture_ready(observation, "crossroads", "sol") and not _has_structure(observation, "crossroads", "outpost"):
		_build(observation, orders, "outpost", "crossroads", center_workers.slice(0, 2))
	elif not center_outpost.is_empty() and center_owner == "terra":
		_attack(orders, _combat_units(observation), "crossroads")
		if observation.technology.completed.has("fieldcraft"): _train(observation, orders, "guard")
		_gather(orders, "home_sol", "forest", home_workers)
	elif center_owner != "sol":
		_attack(orders, _combat_units(observation), "crossroads")
		_move(orders, mine_workers, "crossroads")
	elif not _has_structure(observation, "crossroads", "outpost"):
		_build(observation, orders, "outpost", "crossroads", center_workers.slice(0, 2))
	elif not _has_structure(observation, "crossroads", "mine"):
		_build(observation, orders, "mine", "crossroads", center_workers.slice(0, 2))
	elif not _has_unit(observation, "siege"):
		_gather(orders, "crossroads", "crystal", center_workers)
		_train(observation, orders, "siege")
	else:
		var siege_at_center := _units_at(observation, "siege", "crossroads")
		if siege_at_center.is_empty():
			_move(orders, _units_of_kind(observation, "siege"), "crossroads")
		else:
			_attack(orders, _combat_units(observation), "core_terra")


func _terra(observation: Dictionary, orders: Array) -> void:
	var round_number := int(observation.round)
	var center := _district(observation, "crossroads")
	var center_workers := _units_at(observation, "worker", "crossroads")
	if round_number == 8:
		_move(orders, _units_at(observation, "worker", "mine_tl"), "crossroads")
		_gather(orders, "home_terra", "forest", _units_at(observation, "worker", "home_terra"))
	elif _capture_ready(observation, "crossroads", "terra") and not _has_structure(observation, "crossroads", "outpost"):
		_build(observation, orders, "outpost", "crossroads", center_workers.slice(0, 2))
	elif str(center.get("owner", "")) == "terra" and not _has_structure(observation, "crossroads", "mine"):
		_build(observation, orders, "mine", "crossroads", center_workers.slice(0, 2))
	elif round_number == 12:
		_gather(orders, "crossroads", "iron", center_workers.slice(0, 1))
		_gather(orders, "crossroads", "stone", center_workers.slice(1, 2))
		_train(observation, orders, "militia")
	elif round_number == 13:
		_build(observation, orders, "workshop", "home_terra", _units_at(observation, "worker", "home_terra").slice(0, 2))
		_move(orders, _units_at(observation, "militia", "core_terra").slice(0, 1), "crossroads")
		_train(observation, orders, "militia")
	elif round_number == 14:
		_build(observation, orders, "wall", "home_terra", _units_at(observation, "worker", "home_terra").slice(0, 2))
		_train(observation, orders, "militia")
	elif round_number == 15:
		_train(observation, orders, "militia")
	elif round_number <= 16 and str(center.get("owner", "")) == "terra":
		_train(observation, orders, "militia")
	elif round_number == 17:
		var raiders := _units_at(observation, "commander", "core_terra")
		raiders.append_array(_units_at(observation, "militia", "core_terra").slice(0, 2))
		_move(orders, raiders, "wild_st")
	elif round_number >= 18:
		var raid_force := _combat_units_in(observation, ["wild_st", "home_sol", "core_sol"])
		if float(observation.public_scores.sol.core_hp) < 900.0:
			_move(orders, raid_force, "wild_st")
		elif not raid_force.is_empty():
			_attack(orders, raid_force, "core_sol")
	else:
		_train(observation, orders, "militia")


func _luna(observation: Dictionary, orders: Array) -> void:
	var round_number := int(observation.round)
	var home_workers := _units_at(observation, "worker", "home_luna")
	var mine_workers := _units_at(observation, "worker", "mine_ls")
	var terra_fallen := bool(observation.public_scores.terra.eliminated)
	if terra_fallen:
		_attack(orders, _combat_units(observation), "core_sol")
	elif round_number == 8:
		_gather(orders, "mine_ls", "iron", mine_workers.slice(0, 1))
		_gather(orders, "mine_ls", "forest", mine_workers.slice(1, 2))
		_move(orders, _units_at(observation, "scout", "core_luna"), "mine_ls")
	elif round_number == 9:
		_build(observation, orders, "workshop", "home_luna", home_workers.slice(0, 2))
	elif round_number == 10:
		if _has_structure(observation, "home_luna", "workshop"):
			_research(observation, orders, "fieldcraft", "home_luna", home_workers.slice(0, 2))
	elif round_number in [11, 12]:
		if observation.technology.completed.has("fieldcraft"): _train(observation, orders, "guard")
	elif round_number in [13, 14]:
		_train(observation, orders, "militia")
	elif round_number >= 23:
		_move(orders, _combat_units(observation), "mine_ls")
	else:
		_gather(orders, "home_luna", "animals", home_workers.slice(0, 1))
		_think(orders)


func _units_at(observation: Dictionary, kind: String, district: String) -> Array:
	var ids: Array = []
	for unit in observation.groups:
		if str(unit.kind) == kind and str(unit.district) == district: ids.append(str(unit.id))
	ids.sort()
	return ids


func _combat_units(observation: Dictionary) -> Array:
	var ids: Array = []
	for unit in observation.groups:
		if str(unit.kind) != "worker": ids.append(str(unit.id))
	ids.sort()
	return ids


func _units_of_kind(observation: Dictionary, kind: String) -> Array:
	var ids: Array = []
	for unit in observation.groups:
		if str(unit.kind) == kind: ids.append(str(unit.id))
	ids.sort()
	return ids


func _combat_units_in(observation: Dictionary, districts: Array) -> Array:
	var ids: Array = []
	for unit in observation.groups:
		if str(unit.kind) != "worker" and districts.has(str(unit.district)): ids.append(str(unit.id))
	ids.sort()
	return ids


func _district(observation: Dictionary, district: String) -> Dictionary:
	return observation.districts.get(district, {})


func _capture_ready(observation: Dictionary, district: String, faction: String) -> bool:
	var capture: Dictionary = _district(observation, district).get("capture", {})
	return str(capture.get("faction", "")) == faction and int(capture.get("progress", 0)) >= 2


func _has_structure(observation: Dictionary, district: String, kind: String) -> bool:
	for structure in observation.structures:
		if str(structure.district) == district and str(structure.kind) == kind: return true
	for task in observation.tasks:
		if str(task.district) == district and str(task.get("structure_kind", "")) == kind: return true
	return false


func _has_unit(observation: Dictionary, kind: String) -> bool:
	for unit in observation.groups:
		if str(unit.kind) == kind: return true
	return false


func _can_afford(observation: Dictionary, cost: Dictionary) -> bool:
	for resource in cost:
		if int(observation.inventory.get(resource, 0)) < int(cost[resource]): return false
	return true


func _cp(orders: Array) -> int:
	var total := 0
	for order in orders: total += 2 if str(order.type) in ["Move", "Attack"] else 1
	return total


func _move(orders: Array, unit_ids: Array, target: String) -> void:
	if not unit_ids.is_empty() and _cp(orders) + 2 <= 4: orders.append({"type": "Move", "unit_ids": unit_ids, "target": target})


func _attack(orders: Array, unit_ids: Array, target: String) -> void:
	if not unit_ids.is_empty() and _cp(orders) + 2 <= 4: orders.append({"type": "Attack", "unit_ids": unit_ids, "target_id": target})


func _gather(orders: Array, district: String, node: String, unit_ids: Array) -> void:
	if not unit_ids.is_empty() and _cp(orders) + 1 <= 4: orders.append({"type": "Gather", "district": district, "node": node, "unit_ids": unit_ids})


func _build(observation: Dictionary, orders: Array, kind: String, district: String, workers: Array) -> void:
	var costs := {"storage": {"wood": 70, "stone": 35}, "outpost": {"wood": 80, "stone": 50}, "mine": {"wood": 60, "stone": 40}, "workshop": {"wood": 120, "stone": 60, "iron": 40}, "wall": {"wood": 30, "stone": 45}, "tower": {"stone": 70, "iron": 25}}
	if not workers.is_empty() and costs.has(kind) and _can_afford(observation, costs[kind]) and _cp(orders) + 1 <= 4:
		orders.append({"type": "Build", "structure": kind, "district": district, "worker_ids": workers})


func _train(observation: Dictionary, orders: Array, kind: String) -> void:
	var costs := {"worker": {"food": 30}, "scout": {"food": 25, "wood": 20}, "militia": {"food": 40, "wood": 25}, "guard": {"food": 55, "iron": 20}, "siege": {"food": 60, "wood": 40, "iron": 30, "crystal": 15}}
	var supply_cost := {"worker": 1, "scout": 1, "militia": 1, "guard": 1, "siege": 2}
	var queued_supply := 0
	var same_kind_queued := false
	for job in observation.training_queue:
		queued_supply += int(supply_cost.get(str(job.kind), 0))
		if str(job.kind) == kind: same_kind_queued = true
	var technology_ok := true
	if kind == "guard": technology_ok = observation.technology.completed.has("fieldcraft") and _has_structure(observation, str(HOME[observation.faction_id]), "workshop")
	if kind == "siege": technology_ok = observation.technology.completed.has("ironworking") and _has_structure(observation, str(HOME[observation.faction_id]), "workshop") and not same_kind_queued and not _has_unit(observation, "siege")
	var supply_ok := int(observation.supply.used) + queued_supply + int(supply_cost.get(kind, 0)) <= int(observation.supply.capacity)
	if technology_ok and supply_ok and costs.has(kind) and _can_afford(observation, costs[kind]) and _cp(orders) + 1 <= 4:
		orders.append({"type": "train", "unit": kind})


func _research(observation: Dictionary, orders: Array, technology: String, district: String, workers: Array) -> void:
	var costs := {"fieldcraft": {"food": 20, "wood": 15}, "ironworking": {"wood": 35, "stone": 30, "iron": 15}}
	if not workers.is_empty() and costs.has(technology) and _can_afford(observation, costs[technology]) and _cp(orders) + 1 <= 4:
		orders.append({"type": "Research", "technology_id": technology, "district": district, "worker_ids": workers})


func _think(orders: Array) -> void:
	if orders.size() < 3: orders.append({"type": "Think"})
