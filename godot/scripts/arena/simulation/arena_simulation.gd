class_name ArenaSimulation
extends RefCounted

const Rules := preload("res://scripts/arena/simulation/arena_rules.gd")
const MAP_PATH := "res://data/arena/tri_13_v1.json"
const RNG_MOD := 2147483647
const RNG_MULT := 48271

var state: Dictionary = {}
var _map: Dictionary = {}
var _rng_state: int = 1
var _unit_serial := 0
var _structure_serial := 0

func _init(seed: int = 1, map_path: String = MAP_PATH) -> void:
	_map = _load_map(map_path)
	start_match(seed)

# Stable integration surface. `start_match` may be reused by a season runner.
func start_match(seed: int = 1) -> Dictionary:
	_rng_state = max(1, seed % RNG_MOD)
	_unit_serial = 0
	_structure_serial = 0
	state = _initial_state(seed)
	_hash_state()
	return get_snapshot()

# Applies one simultaneous 15-second round and returns the authoritative snapshot.
func apply_round(plans: Dictionary = {}) -> Dictionary:
	return resolve_round(plans)

func get_snapshot() -> Dictionary:
	return snapshot()

func get_events() -> Array:
	return state.events.duplicate(true)

func get_state_hash() -> String:
	return state_hash()

# Public terminal-result helpers. Consumers can read authoritative ranking/value data
# without re-implementing the simulation's tie-break or structure-cost rules.
func get_faction_ranking_metrics(faction: String) -> Array:
	assert(Rules.FACTIONS.has(faction), "Unknown faction: %s" % faction)
	return _ranking_metrics(faction).duplicate()

func get_structure_value(kind: String) -> int:
	assert(Rules.STRUCTURES.has(kind), "Unknown structure: %s" % kind)
	return _structure_value(kind)

func _load_map(path: String) -> Dictionary:
	var json := JSON.new()
	assert(json.parse(FileAccess.get_file_as_string(path)) == OK, "Arena map is invalid: %s" % path)
	return json.data

func _initial_state(seed: int) -> Dictionary:
	var result := {
		"schema_version": Rules.VERSION,
		"match": {"id": "tri_13_%d" % seed, "seed": seed, "round": 1, "tick": 0, "phase": "planning", "sudden_death": false, "sudden_death_started_round": 0, "ended": false, "winner": "", "state_hash": ""},
		"map": {"id": str(_map.id), "version": int(_map.version), "adjacency": _map.adjacency.duplicate(true)},
		"factions": {}, "districts": {}, "units": {}, "structures": {}, "build_queue": [], "train_queue": [], "events": [], "rng_state": _rng_state
	}
	for district_id in _map.districts.keys():
		var template: Dictionary = _map.districts[district_id]
		var resources: Dictionary = template.get("resources", {}).duplicate(true)
		result.districts[district_id] = {"id": district_id, "kind": str(template.kind), "owner": template.get("owner", null), "outpost_id": null, "capture": {"faction": null, "progress": 0}, "resources": resources.duplicate(true), "max_resources": resources.duplicate(true), "wildlife": _seed_wildlife(resources), "unsupplied_rounds": 0}
	for faction in Rules.FACTIONS:
		var core := "core_%s" % faction
		var home := "home_%s" % faction
		result.factions[faction] = {"id": faction, "core_id": core, "core_hp": 1000.0, "eliminated": false, "commander_respawn_round": -1, "stockpile": {"food": 120, "wood": 90, "stone": 70, "iron": 0, "crystal": 0}, "supply": {"used": 5, "capacity": 8, "external_capacity": 2, "priority": [home], "supplied_districts": [core, home]}, "territory": {"owned": [core, home], "control_point_rounds": 0, "crown_hold_rounds": 0}, "cognition": {"scheduled_used": 0, "interrupt_used": 0, "advisor_used": 0}, "starving_rounds": 0}
		_add_structure_to(result, faction, "outpost", home, true)
		_add_structure_to(result, faction, "tower", core, true)
		_add_unit_to(result, faction, "commander", home)
		for i in 3: _add_unit_to(result, faction, "worker", home)
		for i in 2: _add_unit_to(result, faction, "militia", home)
	return result

func snapshot() -> Dictionary:
	return state.duplicate(true)

func state_hash() -> String:
	return str(state.match.state_hash)

func rng_next() -> float:
	_rng_state = int((_rng_state * RNG_MULT) % RNG_MOD)
	state.rng_state = _rng_state
	return float(_rng_state) / float(RNG_MOD)

func resolve_round(plans: Dictionary = {}) -> Dictionary:
	if bool(state.match.ended): return snapshot()
	state.events = []
	state.match.phase = "resolving"
	var accepted: Dictionary = {}
	for faction in Rules.FACTIONS:
		accepted[faction] = _validate_plan(faction, plans.get(faction, []))
	for faction in Rules.FACTIONS:
		_apply_orders(faction, accepted[faction])
	_advance_movement()
	_resolve_combat()
	_advance_queues()
	_harvest_and_farms()
	_resolve_hunts()
	_consume_food()
	_recompute_supply()
	_resolve_capture()
	_regenerate()
	_crown_surge()
	_score_and_end()
	state.match.round = int(state.match.round) + 1
	state.match.tick = int(state.match.round) * Rules.ROUND_TICKS
	if not bool(state.match.ended): state.match.phase = "planning"
	_hash_state()
	return snapshot()

func _validate_plan(faction: String, raw_orders: Variant) -> Array:
	var valid: Array = []
	var cp := 0
	if bool(state.factions[faction].eliminated):
		if raw_orders is Array and not raw_orders.is_empty(): _event("order_rejected", faction, {"kind": "", "reason": "faction_eliminated"})
		return valid
	if not raw_orders is Array: return valid
	for raw in raw_orders:
		if valid.size() >= Rules.MAX_ORDERS or not raw is Dictionary: break
		var order: Dictionary = raw
		var kind := str(order.get("kind", ""))
		var cost := Rules.order_cost(kind)
		if cp + cost > Rules.COMMAND_POINTS or not _order_is_valid(faction, order):
			_event("order_rejected", faction, {"kind": kind, "reason": _rejection_reason(faction, order)})
			continue
		cp += cost
		valid.append(order.duplicate(true))
		_event("order_accepted", faction, {"kind": kind})
	return valid

func _order_is_valid(faction: String, order: Dictionary) -> bool:
	var kind := str(order.get("kind", ""))
	var faction_state: Dictionary = state.factions[faction]
	match kind:
		"assign_workers":
			return _owned_supplied(faction, str(order.get("district", ""))) and Rules.HARVEST.has(str(order.get("node", "")))
		"hunt":
			return _valid_hunt(faction, order)
		"build":
			var structure := str(order.get("structure", ""))
			var district := str(order.get("district", ""))
			if not Rules.STRUCTURES.has(structure) or not _can_pay(faction_state.stockpile, Rules.STRUCTURES[structure].cost):
				return false
			if structure == "outpost":
				return _can_build(faction, structure, district) and _has_supplied_neighbor(faction, district) and _has_worker_at(faction, district)
			return _owned_supplied(faction, district) and _can_build(faction, structure, district)
		"train":
			var unit_kind := str(order.get("unit", ""))
			return Rules.TRAINING.has(unit_kind) and _can_pay(faction_state.stockpile, Rules.TRAINING[unit_kind].cost) and _can_train(faction, unit_kind)
		"mobilize", "retreat":
			return order.get("unit_ids", []) is Array and _valid_unit_move(faction, order)
		"set_supply_priority":
			return order.get("districts", []) is Array
		"reinforce", "repair", "research":
			return false
		_:
			return false

func _apply_orders(faction: String, orders: Array) -> void:
	for order in orders:
		match str(order.kind):
			"assign_workers":
				for unit_id in order.get("unit_ids", []):
					if state.units.has(unit_id) and state.units[unit_id].faction == faction and state.units[unit_id].kind == "worker": state.units[unit_id].harvest = str(order.node)
			"hunt":
				for unit_id in order.get("unit_ids", []):
					if state.units.has(unit_id): state.units[unit_id].hunt = str(order.species)
			"build":
				var spec: Dictionary = Rules.STRUCTURES[str(order.structure)]
				_pay(state.factions[faction].stockpile, spec.cost)
				state.build_queue.append({"faction": faction, "kind": str(order.structure), "district": str(order.district), "remaining": int(spec.rounds)})
			"train":
				var training: Dictionary = Rules.TRAINING[str(order.unit)]; _pay(state.factions[faction].stockpile, training.cost)
				state.train_queue.append({"faction": faction, "kind": str(order.unit), "remaining": int(training.rounds)})
			"mobilize", "retreat":
				for unit_id in order.unit_ids:
					if state.units.has(unit_id): state.units[unit_id].target = str(order.get("target", state.factions[faction].core_id))
			"set_supply_priority": state.factions[faction].supply.priority = order.districts.duplicate()

func _advance_movement() -> void:
	for unit_id in state.units.keys():
		var unit: Dictionary = state.units[unit_id]
		var target := str(unit.get("target", ""))
		if target.is_empty() or target == str(unit.district): continue
		var next := _next_hop(str(unit.district), target)
		if not next.is_empty():
			unit.district = next
			_event("unit_moved", str(unit.faction), {"unit_id": unit_id, "district": next})

func _resolve_combat(ticks: int = Rules.ROUND_TICKS) -> void:
	# Production resolution uses exactly 150 simultaneous 0.1-second combat ticks.
	# The explicit parameter exists only for deterministic headless micro-scenarios.
	for tick in ticks:
		var unit_damage: Dictionary = {}
		var structure_damage: Dictionary = {}
		var core_damage: Dictionary = {}
		for attacker_id in state.units.keys():
			var attacker: Dictionary = state.units[attacker_id]
			var structure_id := _hostile_structure_target(attacker)
			if attacker.kind == "siege" and not structure_id.is_empty():
				structure_damage[structure_id] = float(structure_damage.get(structure_id, 0.0)) + _unit_damage(attacker, true)
				continue
			var target_id := _combat_target(attacker_id)
			if not target_id.is_empty():
				unit_damage[target_id] = float(unit_damage.get(target_id, 0.0)) + _unit_damage(attacker, false)
				continue
			if not structure_id.is_empty():
				structure_damage[structure_id] = float(structure_damage.get(structure_id, 0.0)) + _unit_damage(attacker, true)
				continue
			var district_owner: Variant = state.districts[attacker.district].owner
			if district_owner != null and district_owner != attacker.faction and str(attacker.district) == str(state.factions[district_owner].core_id):
				core_damage[district_owner] = float(core_damage.get(district_owner, 0.0)) + _unit_damage(attacker, true)
		for structure in state.structures.values():
			if structure.kind != "tower": continue
			var target := _tower_target(structure)
			if not target.is_empty(): unit_damage[target] = float(unit_damage.get(target, 0.0)) + float(Rules.STRUCTURES.tower.dps) * Rules.TICK_SECONDS
		for target_id in unit_damage.keys():
			if state.units.has(target_id):
				state.units[target_id].hp -= unit_damage[target_id]
				if state.units[target_id].hp <= 0.0: _kill_unit(target_id)
		for structure_id in structure_damage.keys():
			if state.structures.has(structure_id):
				state.structures[structure_id].hp -= structure_damage[structure_id]
				if state.structures[structure_id].hp <= 0.0: _destroy_structure(structure_id)
		for faction in core_damage.keys():
			state.factions[faction].core_hp -= core_damage[faction]
			if state.factions[faction].core_hp <= 0.0: _eliminate_faction(str(faction))

func _unit_damage(attacker: Dictionary, target_is_structure: bool = false) -> float:
	var multiplier: float = 1.0
	if _has_workshop(str(attacker.faction)): multiplier *= 1.15
	if not _district_is_supplied(str(attacker.faction), str(attacker.district)): multiplier *= 0.85
	var roll: float = 0.95 + rng_next() * 0.10
	var stats: Dictionary = Rules.UNIT_STATS[attacker.kind]
	var dps: float = float(stats.get("dps", stats.get("dps_units", 0.0)))
	if attacker.kind == "siege": dps = float(stats.dps_structures) if target_is_structure else float(stats.dps_units)
	return dps * Rules.TICK_SECONDS * multiplier * roll

func _combat_target(attacker_id: String) -> String:
	var attacker: Dictionary = state.units[attacker_id]
	var choices: Array = []
	for unit_id in state.units.keys():
		var unit: Dictionary = state.units[unit_id]
		if unit.faction != attacker.faction and unit.district == attacker.district: choices.append(unit_id)
	choices.sort_custom(func(a, b): return _target_rank(state.units[a]) < _target_rank(state.units[b]) or (_target_rank(state.units[a]) == _target_rank(state.units[b]) and a < b))
	return str(choices[0]) if not choices.is_empty() else ""

func _hostile_structure_target(attacker: Dictionary) -> String:
	var candidates: Array = []
	for structure_id in state.structures.keys():
		var structure: Dictionary = state.structures[structure_id]
		if structure.district == attacker.district and structure.faction != attacker.faction: candidates.append(structure_id)
	candidates.sort()
	return str(candidates[0]) if not candidates.is_empty() else ""

func _tower_target(tower: Dictionary) -> String:
	var candidates: Array = []
	for unit_id in state.units.keys():
		var unit: Dictionary = state.units[unit_id]
		if unit.district == tower.district and unit.faction != tower.faction: candidates.append(unit_id)
	candidates.sort()
	return str(candidates[0]) if not candidates.is_empty() else ""

func _target_rank(unit: Dictionary) -> int:
	return {"commander": 0, "worker": 1, "guard": 2, "militia": 3, "scout": 4}.get(str(unit.kind), 9)

func _advance_queues() -> void:
	for queue_name in ["build_queue", "train_queue"]:
		var next_queue: Array = []
		for job in state[queue_name]:
			if bool(state.factions[job.faction].eliminated): continue
			job.remaining = int(job.remaining) - 1
			if int(job.remaining) > 0:
				next_queue.append(job)
			elif queue_name == "build_queue": _add_structure_to(state, str(job.faction), str(job.kind), str(job.district), false)
			else: _add_unit_to(state, str(job.faction), str(job.kind), str(state.factions[job.faction].core_id))
		state[queue_name] = next_queue
	_respawn_commanders()

func _harvest_and_farms() -> void:
	for unit in state.units.values():
		if unit.kind != "worker" or not unit.has("harvest") or not _owned_supplied(str(unit.faction), str(unit.district)): continue
		var node := str(unit.harvest)
		if not Rules.HARVEST.has(node): continue
		if node == "iron" and not _has_structure_at(str(unit.faction), str(unit.district), "mine"): continue
		if node == "crystal" and (not _has_structure_at(str(unit.faction), str(unit.district), "mine") or not _has_workshop(str(unit.faction))): continue
		var district: Dictionary = state.districts[unit.district]
		var amount: int = min(int(Rules.HARVEST[node].amount), int(district.resources.get(node, 0)))
		if amount > 0:
			district.resources[node] -= amount
			_add_stockpile(str(unit.faction), str(Rules.HARVEST[node].resource), amount)
	for structure in state.structures.values():
		if structure.kind == "farm" and _owned_supplied(str(structure.faction), str(structure.district)): _add_stockpile(str(structure.faction), "food", 18)

func _resolve_hunts() -> void:
	for unit in state.units.values():
		if unit.kind != "worker" or not unit.has("hunt") or not _owned_supplied(str(unit.faction), str(unit.district)): continue
		var district: Dictionary = state.districts[unit.district]
		var species := str(unit.hunt)
		if not district.wildlife.has(species) or int(district.wildlife[species].count) <= 0: continue
		var yield_food: int = {"deer": int(Rules.HARVEST.animals.amount), "boar": 12, "wolves": 5}.get(species, 0)
		district.wildlife[species].count -= 1
		district.resources.animals = max(0, int(district.resources.get("animals", 0)) - yield_food)
		_add_stockpile(str(unit.faction), "food", yield_food)
		if species == "boar": unit.hp -= 4.0
		if species == "wolves": unit.hp -= 10.0
		_event("wildlife_hunted", str(unit.faction), {"district": unit.district, "species": species, "food": yield_food})
		if unit.hp <= 0.0: _kill_unit(str(unit.id))

func _consume_food() -> void:
	for faction in Rules.FACTIONS:
		if bool(state.factions[faction].eliminated): continue
		var count := 0
		for unit in state.units.values(): if unit.faction == faction and unit.kind != "commander": count += 1
		var stock: Dictionary = state.factions[faction].stockpile
		if int(stock.food) >= count:
			stock.food -= count; state.factions[faction].starving_rounds = 0
		else:
			stock.food = 0; state.factions[faction].starving_rounds = int(state.factions[faction].starving_rounds) + 1
			_event("starvation", faction, {"units": count})

func _recompute_supply() -> void:
	for faction in Rules.FACTIONS:
		if bool(state.factions[faction].eliminated): continue
		var fs: Dictionary = state.factions[faction]; var core := str(fs.core_id); var owned: Array = [core]
		var capacity: int = min(2 + _structure_count(faction, "storage"), 6)
		fs.supply.external_capacity = capacity
		var candidates: Array = []
		for district_id in state.districts.keys():
			if district_id != core and state.districts[district_id].owner == faction and state.districts[district_id].outpost_id != null: candidates.append(district_id)
		var priority: Array = fs.supply.priority.duplicate(); candidates.sort()
		for district_id in priority:
			if candidates.has(district_id) and owned.size() <= capacity and _has_owned_path(faction, core, district_id):
				owned.append(district_id)
				candidates.erase(district_id)
		for district_id in candidates:
			if owned.size() <= capacity and _has_owned_path(faction, core, district_id):
				owned.append(district_id)
		fs.supply.supplied_districts = owned
		for district_id in state.districts.keys():
			var district: Dictionary = state.districts[district_id]
			if district.owner != faction or district_id == core: continue
			if owned.has(district_id): district.unsupplied_rounds = 0
			else:
				district.unsupplied_rounds += 1
				if int(district.unsupplied_rounds) >= 3: _neutralize_district(district_id)

func _resolve_capture() -> void:
	for district_id in state.districts.keys():
		var district: Dictionary = state.districts[district_id]
		if district.kind == "core" or district.outpost_id != null: continue
		var claimers: Array = []
		for faction in Rules.FACTIONS:
			if _has_claimer(faction, district_id): claimers.append(faction)
		if claimers.size() == 1:
			var faction := str(claimers[0])
			if district.capture.faction == null or district.capture.faction == faction:
				district.capture.faction = faction; district.capture.progress = min(2, int(district.capture.progress) + 1)
				if int(district.capture.progress) == 2: _event("capture_ready", faction, {"district": district_id})
		elif claimers.is_empty() and int(district.capture.progress) > 0:
			district.capture.progress -= 1
			if int(district.capture.progress) == 0: district.capture.faction = null

func _regenerate() -> void:
	for district in state.districts.values():
		for node in Rules.REGEN.get(str(district.kind), {}).keys(): district.resources[node] = min(int(district.max_resources[node]), int(district.resources[node]) + int(Rules.REGEN[district.kind][node]))
		if int(state.match.round) % 5 == 0 and int(district.resources.get("animals", 0)) > 0:
			for species in district.wildlife.keys():
				if rng_next() < 0.35: district.wildlife[species].count += 1

func _crown_surge() -> void:
	if int(state.match.round) != 20: return
	var crown: Dictionary = state.districts.crown
	crown.resources.crystal = int(crown.resources.get("crystal", 0)) + 150
	crown.max_resources.crystal = max(int(crown.max_resources.get("crystal", 0)), int(crown.resources.crystal))
	_event("crown_surge", "", {"district": "crown", "crystal": 150})

func _score_and_end() -> void:
	var survivors: Array = []
	for faction_id in Rules.FACTIONS:
		if float(state.factions[faction_id].core_hp) > 0.0: survivors.append(faction_id)
	if survivors.size() <= 1:
		_finish_match(str(survivors[0]) if survivors.size() == 1 else "draw")
		return
	for faction in Rules.FACTIONS:
		if bool(state.factions[faction].eliminated): continue
		var score := 0
		for district_id in state.factions[faction].supply.supplied_districts:
			if state.districts[district_id].kind != "core":
				if district_id == "crown":
					score += Rules.crown_weight(bool(state.match.sudden_death))
					state.factions[faction].territory.crown_hold_rounds += 1
				else: score += 1
		state.factions[faction].territory.control_point_rounds += score
	if not bool(state.match.sudden_death) and int(state.match.round) >= Rules.MATCH_ROUNDS:
		var top := _top_ranked_factions()
		if top.size() == 1: _finish_match(str(top[0]))
		else:
			state.match.sudden_death = true
			state.match.sudden_death_started_round = int(state.match.round) + 1
			_event("sudden_death_started", "", {"contenders": top})
	elif bool(state.match.sudden_death) and int(state.match.round) >= int(state.match.sudden_death_started_round) + Rules.SUDDEN_DEATH_ROUNDS - 1:
		var final_top := _top_ranked_factions()
		_finish_match(str(final_top[0]) if final_top.size() == 1 else "draw")

func _finish_match(winner: String) -> void:
	state.match.ended = true; state.match.winner = winner; state.match.phase = "ended"; _event("match_ended", winner, {})

func _rank_winner() -> String:
	var top := _top_ranked_factions()
	return str(top[0]) if top.size() == 1 else "draw"

func _top_ranked_factions() -> Array:
	var best_metrics: Array = []
	var winners: Array = []
	for faction in Rules.FACTIONS:
		if bool(state.factions[faction].eliminated): continue
		var metrics := _ranking_metrics(faction)
		if winners.is_empty() or _metrics_greater(metrics, best_metrics):
			best_metrics = metrics; winners = [faction]
		elif metrics == best_metrics:
			winners.append(faction)
	return winners

func _ranking_metrics(faction: String) -> Array:
	var outposts := 0
	for district_id in state.factions[faction].supply.supplied_districts:
		if district_id == state.factions[faction].core_id: continue
		if state.districts[district_id].outpost_id != null: outposts += Rules.crown_weight(bool(state.match.sudden_death)) if district_id == "crown" else 1
	var structure_value := 0
	for structure in state.structures.values():
		if structure.faction == faction: structure_value += _structure_value(str(structure.kind))
	return [outposts, int(state.factions[faction].territory.control_point_rounds), int(state.factions[faction].core_hp), structure_value]

func _metrics_greater(left: Array, right: Array) -> bool:
	for index in min(left.size(), right.size()):
		if int(left[index]) != int(right[index]): return int(left[index]) > int(right[index])
	return false

func _structure_value(kind: String) -> int:
	var value := 0
	for cost in Rules.STRUCTURES[kind].cost.values(): value += int(cost)
	return value

func _add_unit_to(target_state: Dictionary, faction: String, kind: String, district: String) -> void:
	_unit_serial += 1; var id := "unit_%04d" % _unit_serial; var stats: Dictionary = Rules.UNIT_STATS[kind]
	target_state.units[id] = {"id": id, "faction": faction, "kind": kind, "hp": float(stats.hp), "district": district, "target": ""}

func _add_structure_to(target_state: Dictionary, faction: String, kind: String, district: String, initial: bool) -> void:
	_structure_serial += 1; var id := "structure_%04d" % _structure_serial; var spec: Dictionary = Rules.STRUCTURES[kind]
	target_state.structures[id] = {"id": id, "faction": faction, "kind": kind, "district": district, "hp": float(spec.hp), "initial": initial}
	if kind == "outpost": target_state.districts[district].outpost_id = id; target_state.districts[district].owner = faction

func _kill_unit(unit_id: String) -> void:
	var unit: Dictionary = state.units[unit_id]
	var faction := str(unit.faction)
	if unit.kind == "commander" and not bool(state.factions[faction].eliminated) and float(state.factions[faction].core_hp) > 0.0:
		state.factions[faction].commander_respawn_round = int(state.match.round) + 3
		_event("commander_defeated", faction, {"unit_id": unit_id, "respawn_round": state.factions[faction].commander_respawn_round})
	else:
		_event("unit_killed", faction, {"unit_id": unit_id})
	state.units.erase(unit_id)

func _respawn_commanders() -> void:
	for faction in Rules.FACTIONS:
		var fs: Dictionary = state.factions[faction]
		if bool(fs.eliminated) or int(fs.commander_respawn_round) < 0 or int(state.match.round) < int(fs.commander_respawn_round): continue
		_add_unit_to(state, faction, "commander", str(fs.core_id))
		fs.commander_respawn_round = -1
		_event("commander_respawned", faction, {"district": fs.core_id})

func _eliminate_faction(faction: String) -> void:
	var fs: Dictionary = state.factions[faction]
	if bool(fs.eliminated): return
	fs.core_hp = 0.0
	fs.eliminated = true
	fs.commander_respawn_round = -1
	for unit_id in state.units.keys().duplicate():
		if state.units[unit_id].faction == faction: state.units.erase(unit_id)
	for structure_id in state.structures.keys().duplicate():
		if state.structures[structure_id].faction == faction: state.structures.erase(structure_id)
	for district_id in state.districts.keys():
		if state.districts[district_id].owner == faction:
			state.districts[district_id].owner = null
			state.districts[district_id].outpost_id = null
			state.districts[district_id].capture = {"faction": null, "progress": 0}
	fs.supply.supplied_districts = []
	fs.territory.owned = []
	state.build_queue = state.build_queue.filter(func(job): return job.faction != faction)
	state.train_queue = state.train_queue.filter(func(job): return job.faction != faction)
	_event("core_destroyed", faction, {"policy": "neutralize_holdings_remove_units"})

func _destroy_structure(structure_id: String) -> void:
	var structure: Dictionary = state.structures[structure_id]
	var district_id := str(structure.district)
	_event("structure_destroyed", str(structure.faction), {"structure_id": structure_id, "kind": structure.kind, "district": district_id})
	state.structures.erase(structure_id)
	if structure.kind == "outpost":
		state.districts[district_id].outpost_id = null
		state.districts[district_id].owner = null
		state.districts[district_id].capture = {"faction": null, "progress": 0}

func _neutralize_district(district_id: String) -> void:
	var district: Dictionary = state.districts[district_id]
	district.owner = null
	district.outpost_id = null
	district.capture = {"faction": null, "progress": 0}
	for structure_id in state.structures.keys().duplicate():
		if state.structures[structure_id].district == district_id:
			state.structures.erase(structure_id)
	_event("district_neutralized", "", {"district": district_id})

func _owned_supplied(faction: String, district_id: String) -> bool:
	return state.districts.has(district_id) and state.districts[district_id].owner == faction and _district_is_supplied(faction, district_id)
func _district_is_supplied(faction: String, district_id: String) -> bool: return state.factions[faction].supply.supplied_districts.has(district_id)
func _can_pay(stock: Dictionary, cost: Dictionary) -> bool:
	for resource in cost.keys(): if int(stock.get(resource, 0)) < int(cost[resource]): return false
	return true
func _pay(stock: Dictionary, cost: Dictionary) -> void:
	for resource in cost.keys(): stock[resource] -= int(cost[resource])
func _add_stockpile(faction: String, resource: String, amount: int) -> void: state.factions[faction].stockpile[resource] = min(400 + 50 * _structure_count(faction, "storage"), int(state.factions[faction].stockpile.get(resource, 0)) + amount)
func _can_build(faction: String, kind: String, district: String) -> bool:
	if kind == "wall": return _wall_count(district) < 3
	if kind == "farm": return state.districts[district].kind in ["home", "wild"] and _structure_count_at(district, "farm") == 0
	if kind == "outpost": return state.districts[district].outpost_id == null and state.districts[district].capture.faction == faction and int(state.districts[district].capture.progress) >= 2
	return _structure_count_at(district, kind) == 0
func _can_train(faction: String, kind: String) -> bool:
	return (kind != "guard" and kind != "siege") or _has_workshop(faction)
func _valid_hunt(faction: String, order: Dictionary) -> bool:
	var district := str(order.get("district", ""))
	var species := str(order.get("species", ""))
	if not _owned_supplied(faction, district) or not state.districts[district].wildlife.has(species): return false
	for unit_id in order.get("unit_ids", []):
		if not state.units.has(unit_id) or state.units[unit_id].faction != faction or state.units[unit_id].kind != "worker" or state.units[unit_id].district != district: return false
	return not order.get("unit_ids", []).is_empty()
func _rejection_reason(_faction: String, order: Dictionary) -> String:
	var kind := str(order.get("kind", ""))
	if kind in ["reinforce", "repair", "research"]: return "unsupported_action"
	if kind.is_empty(): return "missing_kind"
	return "invalid_precondition"
func _seed_wildlife(resources: Dictionary) -> Dictionary:
	var animals: int = int(resources.get("animals", 0))
	if animals <= 0: return {}
	return {"deer": {"count": 2 + int(rng_next() * 3)}, "boar": {"count": 1 + int(rng_next() * 2)}, "wolves": {"count": int(rng_next() * 2)}}
func _valid_unit_move(faction: String, order: Dictionary) -> bool:
	var target := str(order.get("target", state.factions[faction].core_id))
	if not state.districts.has(target): return false
	for unit_id in order.unit_ids: if not state.units.has(unit_id) or state.units[unit_id].faction != faction: return false
	return true
func _has_supplied_neighbor(faction: String, district_id: String) -> bool:
	if not state.districts.has(district_id): return false
	for neighbor in _map.adjacency[district_id]:
		if _owned_supplied(faction, str(neighbor)): return true
	return false
func _has_worker_at(faction: String, district_id: String) -> bool:
	for unit in state.units.values():
		if unit.faction == faction and unit.kind == "worker" and unit.district == district_id: return true
	return false
func _has_owned_path(faction: String, start: String, destination: String) -> bool:
	if start == destination: return true
	var queue: Array = [start]
	var seen := {start: true}
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for neighbor in _map.adjacency[current]:
			if seen.has(neighbor): continue
			if state.districts[neighbor].owner != faction: continue
			if str(neighbor) == destination: return true
			seen[neighbor] = true
			queue.append(neighbor)
	return false
func _next_hop(start: String, destination: String) -> String:
	if not _map.adjacency.has(start): return ""
	var queue: Array = [start]; var visited := {start: ""}
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if current == destination: break
		for neighbor in _map.adjacency[current]: if not visited.has(neighbor): visited[neighbor] = current; queue.append(neighbor)
	if not visited.has(destination): return ""
	var step := destination
	while visited[step] != start and visited[step] != "": step = visited[step]
	return step
func _has_claimer(faction: String, district: String) -> bool:
	for unit in state.units.values(): if unit.faction == faction and unit.district == district and unit.kind in ["commander", "militia", "guard"]: return true
	return false
func _has_workshop(faction: String) -> bool:
	for structure in state.structures.values():
		if structure.faction == faction and structure.kind == "workshop" and _owned_supplied(faction, str(structure.district)): return true
	return false
func _has_structure_at(faction: String, district: String, kind: String) -> bool:
	for structure in state.structures.values():
		if structure.faction == faction and structure.district == district and structure.kind == kind: return true
	return false
func _structure_count(faction: String, kind: String) -> int:
	var count := 0; for s in state.structures.values(): if s.faction == faction and s.kind == kind: count += 1
	return count
func _structure_count_at(district: String, kind: String) -> int:
	var count := 0; for s in state.structures.values(): if s.district == district and s.kind == kind: count += 1
	return count
func _wall_count(district: String) -> int: return _structure_count_at(district, "wall")
func _winner_without(loser: String) -> String:
	var survivors: Array = []
	for faction in Rules.FACTIONS:
		if faction != loser and float(state.factions[faction].core_hp) > 0.0: survivors.append(faction)
	if survivors.size() == 1: return str(survivors[0])
	return _rank_winner() if survivors.size() > 1 else "draw"
func _event(type: String, faction: String, payload: Dictionary) -> void:
	var event := {"type": type, "round": int(state.match.round), "faction": faction}; event.merge(payload); state.events.append(event)
func _hash_state() -> void:
	var copy := state.duplicate(true); copy.match.state_hash = ""; state.match.state_hash = JSON.stringify(copy, "", true).sha256_text()
