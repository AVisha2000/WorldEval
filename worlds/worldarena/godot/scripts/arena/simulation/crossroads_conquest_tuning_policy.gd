extends "res://scripts/arena/simulation/arena_crossroads_conquest_policy.gd"

## Scratch policy used by crossroads_conquest_tuning_runner.gd.  It deliberately
## subclasses the canonical policy so tuning never races edits to the package policy.


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
		_build(observation, orders, "storage", home, home_workers.slice(0, 2))
		var movers := _units_at(observation, "commander", home)
		movers.append_array(home_workers.slice(2, 3))
		movers.append_array(core_workers)
		_move(orders, movers, mine)
	elif round_number == 5:
		# One core worker is already continuing toward the mine.  Move one of the
		# finished storage builders as the third expansion worker and keep one home.
		_move(orders, home_workers.slice(0, 1), mine)
		_gather(orders, home, "animals", home_workers.slice(1, 2))
		if faction == "luna": _train(observation, orders, "scout")
	elif round_number == 6:
		if _capture_ready(observation, mine, faction):
			_build(observation, orders, "outpost", mine, _units_at(observation, "worker", mine).slice(0, 3))
		_gather(orders, home, "forest", home_workers.slice(0, 1))
	elif round_number == 7:
		_build(observation, orders, "mine", mine, _units_at(observation, "worker", mine).slice(0, 3))
		_gather(orders, home, "animals", home_workers.slice(0, 1))
		if faction == "terra": _move(orders, _units_at(observation, "commander", mine), "crossroads")


func _sol(observation: Dictionary, orders: Array) -> void:
	var round_number := int(observation.round)
	var home_workers := _units_at(observation, "worker", "home_sol")
	var mine_workers := _units_at(observation, "worker", "mine_st")
	var center_workers := _units_at(observation, "worker", "crossroads")
	var guard_ids := _units_of_kind(observation, "guard")
	if round_number == 8:
		_move(orders, mine_workers.slice(2, 3), "home_sol")
		_gather(orders, "mine_st", "forest", mine_workers.slice(0, 1))
		_gather(orders, "mine_st", "iron", mine_workers.slice(1, 2))
	elif round_number == 9:
		_build(observation, orders, "workshop", "home_sol", home_workers.slice(0, 2))
		_gather(orders, "mine_st", "iron", mine_workers)
		_train(observation, orders, "militia")
	elif round_number == 10:
		if _has_structure(observation, "home_sol", "workshop"):
			_research(observation, orders, "fieldcraft", "home_sol", home_workers.slice(0, 2))
		_move(orders, _units_at(observation, "militia", "core_sol"), "crossroads")
		_gather(orders, "mine_st", "animals", mine_workers)
	elif round_number == 11:
		if observation.technology.completed.has("fieldcraft"):
			_research(observation, orders, "ironworking", "home_sol", home_workers.slice(0, 2))
			_train(observation, orders, "guard")
		_move(orders, _units_at(observation, "militia", "home_sol"), "crossroads")
	elif round_number == 12:
		_attack(orders, _combat_units_in(observation, ["mine_st"]), "crossroads")
		_gather(orders, "home_sol", "animals", home_workers.slice(0, 1))
	elif round_number == 13:
		_attack(orders, _combat_units_in(observation, ["crossroads"]), "crossroads")
		_move(orders, _units_at(observation, "guard", "core_sol"), "crossroads")
	elif round_number == 14:
		var movers := mine_workers.duplicate()
		movers.append_array(_combat_units_in(observation, ["home_sol", "mine_st"]))
		_move(orders, movers, "crossroads")
		_attack(orders, _combat_units_in(observation, ["crossroads"]), "crossroads")
	elif _capture_ready(observation, "crossroads", "sol") and not _has_structure(observation, "crossroads", "outpost"):
		_build(observation, orders, "outpost", "crossroads", center_workers.slice(0, 2))
		_move(orders, _combat_units_in(observation, ["mine_st"]), "crossroads")
	elif _owns(observation, "crossroads", "sol") and not _has_structure(observation, "crossroads", "mine"):
		_build(observation, orders, "mine", "crossroads", center_workers.slice(0, 2))
	elif not _has_unit(observation, "siege") and not _training(observation, "siege"):
		if _has_structure(observation, "crossroads", "mine"):
			_gather(orders, "crossroads", "crystal", center_workers)
		if int(observation.inventory.get("crystal", 0)) >= 15:
			_train(observation, orders, "siege")
	elif round_number <= 22:
		_move(orders, _combat_units(observation), "crossroads")
	else:
		_attack(orders, _combat_units(observation), "core_terra")


func _terra(observation: Dictionary, orders: Array) -> void:
	var round_number := int(observation.round)
	var home_workers := _units_at(observation, "worker", "home_terra")
	var mine_workers := _units_at(observation, "worker", "mine_tl")
	var center_workers := _units_at(observation, "worker", "crossroads")
	if round_number == 8:
		_move(orders, mine_workers.slice(0, 2), "crossroads")
		_gather(orders, "mine_tl", "forest", mine_workers.slice(2, 3))
		_gather(orders, "home_terra", "animals", home_workers.slice(0, 1))
	elif round_number == 9:
		if _capture_ready(observation, "crossroads", "terra"):
			_build(observation, orders, "outpost", "crossroads", center_workers.slice(0, 2))
		_gather(orders, "mine_tl", "animals", mine_workers.slice(0, 1))
		_train(observation, orders, "militia")
	elif round_number == 10:
		if _owns(observation, "crossroads", "terra"):
			_build(observation, orders, "mine", "crossroads", center_workers.slice(0, 2))
		_gather(orders, "mine_tl", "iron", mine_workers.slice(0, 1))
		_train(observation, orders, "militia")
	elif round_number == 11:
		_gather(orders, "crossroads", "stone", center_workers.slice(0, 1))
		_move(orders, center_workers.slice(1, 2), "home_terra")
		_gather(orders, "mine_tl", "iron", mine_workers.slice(0, 1))
	elif round_number == 12:
		_move(orders, center_workers, "home_terra")
		_gather(orders, "mine_tl", "animals", mine_workers.slice(0, 1))
	elif round_number == 13:
		# The first center worker reaches home this round and becomes visible to the
		# workshop gate in the following planning snapshot.
		_gather(orders, "mine_tl", "iron", mine_workers.slice(0, 1))
		_think(orders)
	elif round_number == 14:
		_build(observation, orders, "workshop", "home_terra", home_workers.slice(0, 3))
		_gather(orders, "mine_tl", "iron", mine_workers.slice(0, 1))
	elif round_number == 15:
		if _has_structure(observation, "home_terra", "workshop"):
			_research(observation, orders, "fieldcraft", "home_terra", home_workers.slice(0, 3))
	elif round_number == 16:
		if observation.technology.completed.has("fieldcraft"):
			_research(observation, orders, "ironworking", "home_terra", home_workers.slice(0, 3))
			_train(observation, orders, "guard")
	elif round_number == 17:
		_build(observation, orders, "wall", "home_terra", home_workers.slice(0, 1))
		_build(observation, orders, "tower", "home_terra", home_workers.slice(1, 3))
	elif round_number == 19:
		var raiders := _units_at(observation, "commander", "core_terra")
		raiders.append_array(_units_at(observation, "militia", "core_terra").slice(0, 2))
		_move(orders, raiders, "wild_st")
	elif round_number == 20:
		_move(orders, _combat_units_in(observation, ["home_terra"]), "wild_st")
	elif round_number in [21, 22]:
		_attack(orders, _combat_units_in(observation, ["wild_st", "home_sol"]), "core_sol")
	elif float(observation.public_scores.sol.core_hp) < 900.0:
		_move(orders, _combat_units_in(observation, ["core_sol", "home_sol"]), "wild_st")
	else:
		_think(orders)


func _luna(observation: Dictionary, orders: Array) -> void:
	var round_number := int(observation.round)
	var home_workers := _units_at(observation, "worker", "home_luna")
	var mine_workers := _units_at(observation, "worker", "mine_ls")
	if bool(observation.public_scores.terra.eliminated):
		_attack(orders, _combat_units(observation), "core_sol")
	elif round_number == 8:
		var movers := mine_workers.slice(2, 3)
		movers.append_array(_units_at(observation, "scout", "core_luna"))
		_move(orders, movers, "home_luna")
		_gather(orders, "mine_ls", "forest", mine_workers.slice(0, 1))
		_gather(orders, "mine_ls", "iron", mine_workers.slice(1, 2))
	elif round_number == 9:
		_build(observation, orders, "workshop", "home_luna", home_workers.slice(0, 2))
		_gather(orders, "mine_ls", "stone", mine_workers)
		_move(orders, _units_at(observation, "scout", "home_luna"), "mine_ls")
	elif round_number == 10:
		_build(observation, orders, "storage", "mine_ls", mine_workers.slice(0, 2))
		if _has_structure(observation, "home_luna", "workshop"):
			_research(observation, orders, "fieldcraft", "home_luna", home_workers.slice(0, 2))
	elif round_number in [11, 12]:
		if observation.technology.completed.has("fieldcraft"):
			_train(observation, orders, "guard")
			_train(observation, orders, "militia")
		_gather(orders, "mine_ls", "animals", mine_workers)
	elif round_number >= 21:
		_move(orders, _combat_units(observation), "mine_ls")
	else:
		_gather(orders, "home_luna", "animals", home_workers.slice(0, 1))
		_think(orders)


func _owns(observation: Dictionary, district: String, faction: String) -> bool:
	var value: Variant = _district(observation, district).get("owner", null)
	return value != null and str(value) == faction


func _training(observation: Dictionary, kind: String) -> bool:
	for job in observation.training_queue:
		if str(job.kind) == kind: return true
	return false
