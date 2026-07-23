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
var _task_serial := 0
var _event_serial := 0

func _init(seed: int = 1, map_path: String = MAP_PATH) -> void:
	_map = _load_map(map_path)
	start_match(seed)

# Stable integration surface. `start_match` may be reused by a season runner.
func start_match(seed: int = 1) -> Dictionary:
	_rng_state = max(1, seed % RNG_MOD)
	_unit_serial = 0
	_structure_serial = 0
	_task_serial = 0
	_event_serial = 0
	state = _initial_state(seed)
	_hash_state()
	return get_snapshot()

# Applies one simultaneous 15-second round and returns the authoritative snapshot.
func apply_round(plans: Dictionary = {}) -> Dictionary:
	return resolve_round(plans)

# Applies one round while sampling the authoritative state every `stride_ticks`.
# This is a replay/export surface only: the normal resolver stays allocation-light,
# and sampled states never feed back into rules or rendering.
func apply_round_with_trace(plans: Dictionary = {}, stride_ticks: int = 10) -> Dictionary:
	var trace: Array = []
	var resolved := _resolve_round_internal(plans, trace, clampi(stride_ticks, 1, Rules.ROUND_TICKS))
	return {"snapshot": resolved, "trace": trace}

func get_snapshot() -> Dictionary:
	return snapshot()

func get_events() -> Array:
	return state.events.duplicate(true)

func get_state_hash() -> String:
	return state_hash()

# Public terminal-result helpers. Consumers can read authoritative ranking/value data
# without re-implementing the simulation's diagnostic standings or structure-cost rules.
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
		"match": {"id": "conquest_%d" % seed, "seed": seed, "round": 1, "tick": 0, "phase": "planning", "narrative_phase": "Opening", "ended": false, "truncated": false, "termination": "", "winner": "", "state_hash": "", "elimination_order": []},
		"map": {"id": str(_map.id), "version": int(_map.version), "adjacency": _map.adjacency.duplicate(true)},
		"factions": {}, "districts": {}, "units": {}, "structures": {}, "tasks": {}, "receipts": [], "build_queue": [], "train_queue": [], "events": [], "rng_state": _rng_state
	}
	for district_id in _map.districts.keys():
		var template: Dictionary = _map.districts[district_id]
		var resources: Dictionary = template.get("resources", {}).duplicate(true)
		result.districts[district_id] = {"id": district_id, "kind": str(template.kind), "owner": template.get("owner", null), "outpost_id": null, "capture": {"faction": null, "progress": 0}, "resources": resources.duplicate(true), "max_resources": resources.duplicate(true), "wildlife": _seed_wildlife(resources), "unsupplied_rounds": 0}
	for faction in Rules.FACTIONS:
		var core := "core_%s" % faction
		var home := "home_%s" % faction
		result.factions[faction] = {"id": faction, "core_id": core, "core_hp": 900.0, "eliminated": false, "eliminated_round": 0, "destroyed_by": "", "enemy_strongholds_destroyed": 0, "commander_respawn_round": -1, "stockpile": Rules.STARTING_STOCKPILE.duplicate(true), "supply": {"used": 1, "capacity": Rules.BASE_UNIT_SUPPLY, "external_capacity": 1, "priority": [home], "supplied_districts": [core, home]}, "territory": {"owned": [core, home], "control_point_rounds": 0}, "tech": {"tier": 0, "completed": []}, "knowledge": {"seen_districts": {core: 0, home: 0}, "contacts": {}}, "diplomacy": {"offers": {}, "treaties": {}}, "cognition": {"scheduled_used": 0, "interrupt_used": 0, "advisor_used": 0}, "starving_rounds": 0}
		_add_structure_to(result, faction, "outpost", home, true)
		_add_unit_to(result, faction, "commander", home)
		_add_unit_to(result, faction, "worker", home)
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
	return _resolve_round_internal(plans, [], 0)

func _resolve_round_internal(plans: Dictionary, trace: Array, trace_stride: int) -> Dictionary:
	if bool(state.match.ended): return snapshot()
	state.events = []
	state.match.phase = "resolving"
	var trace_event_cursor := 0
	var accepted: Dictionary = {}
	for faction in Rules.FACTIONS:
		accepted[faction] = _validate_plan(faction, plans.get(faction, []))
	for faction in Rules.FACTIONS:
		_apply_orders(faction, accepted[faction])
	_advance_movement()
	for local_tick in Rules.ROUND_TICKS:
		state.match.tick = (int(state.match.round) - 1) * Rules.ROUND_TICKS + local_tick + 1
		_advance_work_tasks()
		_resolve_combat(1)
		if trace_stride > 0 and ((local_tick + 1) % trace_stride == 0 or local_tick == Rules.ROUND_TICKS - 1):
			var sampled_events: Array = state.events.slice(trace_event_cursor)
			trace.append({
				"tick": int(state.match.tick),
				"round_tick": local_tick + 1,
				"snapshot": snapshot(),
				"events": sampled_events.duplicate(true)
			})
			trace_event_cursor = state.events.size()
	_advance_queues()
	_harvest_and_farms()
	_resolve_hunts()
	_consume_food()
	_recompute_supply()
	_resolve_capture()
	_update_territory_metrics()
	_regenerate()
	_update_visibility()
	_update_narrative_phase()
	_check_conquest_end()
	state.match.round = int(state.match.round) + 1
	# Tick is the absolute authoritative tick just resolved.  Do not derive it from
	# the next planning round: presentation replays this exact stream.
	if not bool(state.match.ended): state.match.phase = "planning"
	_hash_state()
	# Queue completion, harvesting, capture, scoring, and terminal events happen
	# after the final 10 Hz work/combat tick. Fold those results into the last
	# sample at the same authoritative tick instead of inventing a new physics tick.
	if trace_stride > 0:
		var trailing_events: Array = state.events.slice(trace_event_cursor)
		if trace.is_empty():
			trace.append({
				"tick": int(state.match.tick),
				"round_tick": Rules.ROUND_TICKS,
				"snapshot": snapshot(),
				"events": trailing_events.duplicate(true)
			})
		else:
			trace[-1]["snapshot"] = snapshot()
			trace[-1]["events"].append_array(trailing_events.duplicate(true))
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
		var order := _normalize_order(faction, raw)
		var kind := _order_kind(order)
		var cost := Rules.order_cost(kind)
		if cp + cost > Rules.COMMAND_POINTS or not _order_is_valid(faction, order):
			_event("order_rejected", faction, {"kind": kind, "reason": _rejection_reason(faction, order)})
			continue
		cp += cost
		valid.append(order.duplicate(true))
		_event("order_accepted", faction, {"kind": kind})
	return valid

func _order_is_valid(faction: String, order: Dictionary) -> bool:
	var kind := _order_kind(order)
	var faction_state: Dictionary = state.factions[faction]
	match kind:
		"Gather":
			return _owned_supplied(faction, str(order.get("district", ""))) and Rules.HARVEST.has(str(order.get("node", ""))) and not _eligible_worker_ids(faction, str(order.get("district", "")), order.get("unit_ids", [])).is_empty()
		"hunt":
			return _valid_hunt(faction, order)
		"Build":
			var structure := str(order.get("structure", ""))
			var district := str(order.get("district", ""))
			if str(order.get("mode", "")) == "repair": return _valid_repair(faction, order)
			if not Rules.STRUCTURES.has(structure) or not _can_pay(faction_state.stockpile, Rules.STRUCTURES[structure].cost):
				return false
			if structure == "outpost":
				return _can_build(faction, structure, district) and _has_supplied_neighbor(faction, district) and _has_worker_at(faction, district)
			return _owned_supplied(faction, district) and _can_build(faction, structure, district) and _has_worker_at(faction, district)
		"train":
			var unit_kind := str(order.get("unit", ""))
			return Rules.TRAINING.has(unit_kind) and _can_pay(faction_state.stockpile, Rules.TRAINING[unit_kind].cost) and _can_train(faction, unit_kind)
		"Move":
			return order.get("unit_ids", []) is Array and _valid_unit_move(faction, order)
		"Attack":
			return _valid_attack(faction, order)
		"Research":
			var technology := str(order.get("technology_id", order.get("technology", "")))
			var district := str(order.get("district", "home_%s" % faction))
			return Rules.RESEARCH.has(technology) \
				and not faction_state.tech.completed.has(technology) \
				and not _has_active_research(faction) \
				and _research_prerequisites_met(faction, technology) \
				and _owned_supplied(faction, district) \
				and _has_workshop(faction) \
				and not _eligible_worker_ids(faction, district, order.get("worker_ids", order.get("actor_ids", order.get("unit_ids", [])))).is_empty() \
				and _can_pay(faction_state.stockpile, Rules.RESEARCH[technology].cost)
		"Negotiate", "Think":
			return true
		"set_supply_priority":
			return order.get("districts", []) is Array
		"reinforce", "repair", "research":
			return false
		_:
			return false

func _apply_orders(faction: String, orders: Array) -> void:
	for order in orders:
		var kind := _order_kind(order)
		match kind:
			"Gather":
				_assign_gather_tasks(faction, str(order.get("district", "")), str(order.get("node", "")), order.get("unit_ids", []))
			"hunt":
				for unit_id in order.get("unit_ids", []):
					if state.units.has(unit_id): state.units[unit_id].hunt = str(order.species)
			"Build":
				if str(order.get("mode", "")) == "repair":
					_create_repair_task(faction, order)
					continue
				var spec: Dictionary = Rules.STRUCTURES[str(order.structure)]
				_pay(state.factions[faction].stockpile, spec.cost)
				_create_build_task(faction, str(order.structure), str(order.district), order.get("worker_ids", order.get("unit_ids", [])), spec.cost)
			"train":
				var training: Dictionary = Rules.TRAINING[str(order.unit)]; _pay(state.factions[faction].stockpile, training.cost)
				state.train_queue.append({"faction": faction, "kind": str(order.unit), "remaining": int(training.rounds)})
			"Move":
				for unit_id in order.unit_ids:
					if state.units.has(unit_id): state.units[unit_id].target = str(order.get("target", state.factions[faction].core_id))
			"Attack":
				_event("order_started", faction, {"action": "Attack", "target_id": str(order.get("target_id", order.get("target", "")))})
				for unit_id in order.get("unit_ids", order.get("actor_ids", [])):
					if state.units.has(unit_id):
						state.units[unit_id].attack_target = str(order.get("target_id", order.get("target", "")))
						state.units[unit_id].target = str(order.get("target", order.get("target_id", "")))
			"Research":
				_start_research_task(faction, order)
			"Negotiate": _event("negotiation_recorded", faction, {"state": "accepted"})
			"Think": _event("think_recorded", faction, {"state": "accepted"})
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
		var core_attackers: Dictionary = {}
		for attacker_id in state.units.keys():
			var attacker: Dictionary = state.units[attacker_id]
			if not str(attacker.get("attack_target", "")).is_empty(): _event("attack_progress", str(attacker.faction), {"unit_id": attacker_id, "target_id": attacker.attack_target})
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
				var dealt := _unit_damage(attacker, true)
				core_damage[district_owner] = float(core_damage.get(district_owner, 0.0)) + dealt
				if not core_attackers.has(district_owner): core_attackers[district_owner] = {}
				var contributors: Dictionary = core_attackers[district_owner]
				contributors[attacker.faction] = float(contributors.get(attacker.faction, 0.0)) + dealt
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
				_event("structure_damaged", str(state.structures[structure_id].faction), {"structure_id": structure_id, "damage": structure_damage[structure_id]})
				if state.structures[structure_id].hp <= 0.0: _destroy_structure(structure_id)
		for faction in core_damage.keys():
			state.factions[faction].core_hp -= core_damage[faction]
			var attacker_id := _dominant_damage_faction(core_attackers.get(faction, {}))
			_event("core_damaged", str(faction), {"actor_id": attacker_id, "attacker_id": attacker_id, "victim_id": str(faction), "damage": core_damage[faction], "remaining_hp": maxf(0.0, float(state.factions[faction].core_hp))})
			if state.factions[faction].core_hp <= 0.0: _eliminate_faction(str(faction), attacker_id)

func _dominant_damage_faction(contributors: Dictionary) -> String:
	var factions: Array = contributors.keys()
	factions.sort()
	var winner := ""
	var best := -1.0
	for faction in factions:
		var damage := float(contributors[faction])
		if damage > best:
			winner = str(faction)
			best = damage
	return winner

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
	# Build work lives in state.tasks in v0.3.  Keep build_queue as a compatibility
	# projection for callers that displayed the old round-count queue.
	state.build_queue = _build_queue_projection()
	for queue_name in ["train_queue"]:
		var next_queue: Array = []
		for job in state[queue_name]:
			if bool(state.factions[job.faction].eliminated): continue
			job.remaining = int(job.remaining) - 1
			if int(job.remaining) > 0:
				next_queue.append(job)
			else: _add_unit_to(state, str(job.faction), str(job.kind), str(state.factions[job.faction].core_id))
		state[queue_name] = next_queue
	_respawn_commanders()

# v0.3 work tasks -----------------------------------------------------------
# Tasks, rather than the renderer or a round queue, own all worker progress.
# Work is deliberately integer-valued: each eligible worker contributes one work
# unit per 10 Hz tick, up to the task's staffing cap.
func _assign_gather_tasks(faction: String, district: String, node: String, raw_worker_ids: Variant) -> void:
	var worker_ids := _eligible_worker_ids(faction, district, raw_worker_ids)
	if worker_ids.is_empty(): return
	for worker_id in worker_ids: _unassign_worker(worker_id)
	var task := _new_task("gather", faction, district, worker_ids, Rules.GATHER_CYCLE_WORK)
	task.node = node
	task.resource = str(Rules.HARVEST[node].resource)
	task.amount = int(Rules.HARVEST[node].amount)
	state.tasks[task.id] = task
	for worker_id in worker_ids: state.units[worker_id].task_id = task.id
	_event("task_started", faction, {"task_id": task.id, "task_kind": "gather", "actor_id": worker_ids[0], "target_ids": worker_ids, "district": district, "node": node, "required_work": task.required_work, "completed_work": 0, "state": "start"})

func _create_build_task(faction: String, kind: String, district: String, raw_worker_ids: Variant, reserved_cost: Dictionary) -> void:
	var requested: Array = raw_worker_ids if raw_worker_ids is Array else []
	if requested.is_empty():
		for unit_id in state.units.keys():
			var unit: Dictionary = state.units[unit_id]
			if unit.faction == faction and unit.kind == "worker" and unit.district == district: requested.append(unit_id)
	var worker_ids := _eligible_worker_ids(faction, district, requested)
	worker_ids = worker_ids.slice(0, Rules.BUILD_STAFFING_CAP)
	for worker_id in worker_ids: _unassign_worker(worker_id)
	var task := _new_task("build", faction, district, worker_ids, int(Rules.STRUCTURES[kind].rounds) * Rules.ROUND_TICKS)
	task.structure_kind = kind
	task.reserved_cost = reserved_cost.duplicate(true)
	task.staffing_cap = Rules.BUILD_STAFFING_CAP
	state.tasks[task.id] = task
	for worker_id in worker_ids: state.units[worker_id].task_id = task.id
	_event("task_started", faction, {"task_id": task.id, "task_kind": "build", "actor_id": worker_ids[0] if not worker_ids.is_empty() else "", "target_ids": worker_ids, "district": district, "structure": kind, "required_work": task.required_work, "completed_work": 0, "state": "start"})

func _new_task(kind: String, faction: String, district: String, worker_ids: Array, required_work: int) -> Dictionary:
	_task_serial += 1
	return {"id": "task_%04d" % _task_serial, "kind": kind, "faction": faction, "district": district, "worker_ids": worker_ids.duplicate(), "required_work": required_work, "completed_work": 0, "state": "active", "pause_reason": ""}

func _advance_work_tasks() -> void:
	var task_ids: Array = state.tasks.keys()
	task_ids.sort()
	for task_id in task_ids:
		if not state.tasks.has(task_id): continue
		var task: Dictionary = state.tasks[task_id]
		var workers := _active_task_workers(task)
		if workers.is_empty():
			if task.state != "paused":
				task.state = "paused"; task.pause_reason = "no_eligible_workers"
				_event("task_paused", str(task.faction), {"task_id": task_id, "task_kind": task.kind, "required_work": task.required_work, "completed_work": task.completed_work, "state": "paused", "reason": task.pause_reason})
			continue
		if task.state == "paused":
			task.state = "active"; task.pause_reason = ""
			_event("task_resumed", str(task.faction), {"task_id": task_id, "task_kind": task.kind, "required_work": task.required_work, "completed_work": task.completed_work, "state": "progress"})
		var contribution := mini(workers.size(), int(task.get("staffing_cap", workers.size())))
		task.completed_work = int(task.completed_work) + contribution
		_event("task_progress", str(task.faction), {"task_id": task_id, "task_kind": task.kind, "actor_id": workers[0], "target_ids": workers, "required_work": task.required_work, "completed_work": task.completed_work, "work_delta": contribution, "state": "progress"})
		if int(task.completed_work) >= int(task.required_work):
			if task.kind == "gather": _complete_gather_task(task_id, task, workers)
			elif task.kind == "build": _complete_build_task(task_id, task, workers)
			elif task.kind == "research": _complete_research_task(task_id, task, workers)
			elif task.kind == "repair": _complete_repair_task(task_id, task, workers)

func _complete_gather_task(task_id: String, task: Dictionary, workers: Array) -> void:
	if not _can_gather_task(task):
		task.state = "paused"; task.pause_reason = "gather_precondition_failed"
		_event("task_paused", str(task.faction), {"task_id": task_id, "task_kind": "gather", "required_work": task.required_work, "completed_work": task.completed_work, "state": "paused", "reason": task.pause_reason})
		return
	var district: Dictionary = state.districts[task.district]
	var amount := mini(int(task.amount), int(district.resources.get(task.node, 0)))
	if amount <= 0:
		task.state = "paused"; task.pause_reason = "resource_depleted"
		_event("task_paused", str(task.faction), {"task_id": task_id, "task_kind": "gather", "required_work": task.required_work, "completed_work": task.completed_work, "state": "paused", "reason": task.pause_reason})
		return
	district.resources[task.node] -= amount
	_add_stockpile(str(task.faction), str(task.resource), amount)
	task.completed_work = 0
	task.cycles_completed = int(task.get("cycles_completed", 0)) + 1
	_event("task_impact", str(task.faction), {"task_id": task_id, "task_kind": "gather", "actor_id": workers[0], "target_ids": workers, "district": task.district, "node": task.node, "resource": task.resource, "resource_delta": amount, "required_work": task.required_work, "completed_work": 0, "state": "impact"})

func _complete_build_task(task_id: String, task: Dictionary, workers: Array) -> void:
	_add_structure_to(state, str(task.faction), str(task.structure_kind), str(task.district), false)
	for worker_id in workers:
		if state.units.has(worker_id) and str(state.units[worker_id].get("task_id", "")) == task_id: state.units[worker_id].erase("task_id")
	state.tasks.erase(task_id)
	_event("task_completed", str(task.faction), {"task_id": task_id, "task_kind": "build", "actor_id": workers[0], "target_ids": workers, "district": task.district, "structure": task.structure_kind, "required_work": task.required_work, "completed_work": task.required_work, "state": "complete"})

func _complete_research_task(task_id: String, task: Dictionary, workers: Array) -> void:
	var faction := str(task.faction)
	state.factions[faction].tech.completed.append(str(task.technology))
	state.factions[faction].tech.tier = max(int(state.factions[faction].tech.tier), int(Rules.RESEARCH[task.technology].tier))
	for worker_id in workers:
		if state.units.has(worker_id): state.units[worker_id].erase("task_id")
	state.tasks.erase(task_id)
	_event("research_completed", faction, {"task_id": task_id, "technology": task.technology, "tier": state.factions[faction].tech.tier})

func _complete_repair_task(task_id: String, task: Dictionary, workers: Array) -> void:
	if state.structures.has(str(task.target_id)):
		var structure: Dictionary = state.structures[str(task.target_id)]
		structure.hp = float(Rules.STRUCTURES[structure.kind].hp)
		_event("repair_completed", str(task.faction), {"task_id": task_id, "structure_id": task.target_id})
	for worker_id in workers:
		if state.units.has(worker_id): state.units[worker_id].erase("task_id")
	state.tasks.erase(task_id)

func _eligible_worker_ids(faction: String, district: String, raw_worker_ids: Variant) -> Array:
	var result: Array = []
	if not raw_worker_ids is Array: return result
	for raw_id in raw_worker_ids:
		var worker_id := str(raw_id)
		if not state.units.has(worker_id) or result.has(worker_id): continue
		var unit: Dictionary = state.units[worker_id]
		if unit.faction == faction and unit.kind == "worker" and unit.district == district: result.append(worker_id)
	result.sort()
	return result

func _active_task_workers(task: Dictionary) -> Array:
	var workers: Array = []
	for worker_id in task.worker_ids:
		if not state.units.has(worker_id): continue
		var unit: Dictionary = state.units[worker_id]
		if unit.faction == task.faction and unit.kind == "worker" and unit.district == task.district and str(unit.get("task_id", "")) == str(task.id): workers.append(worker_id)
	workers.sort()
	return workers

func _unassign_worker(worker_id: String) -> void:
	if not state.units.has(worker_id): return
	var old_task_id := str(state.units[worker_id].get("task_id", ""))
	if old_task_id.is_empty() or not state.tasks.has(old_task_id): return
	var old_task: Dictionary = state.tasks[old_task_id]
	old_task.worker_ids.erase(worker_id)
	state.units[worker_id].erase("task_id")
	_event("task_worker_removed", str(old_task.faction), {"task_id": old_task_id, "task_kind": old_task.kind, "actor_id": worker_id, "state": "progress"})

func _can_gather_task(task: Dictionary) -> bool:
	if not _owned_supplied(str(task.faction), str(task.district)): return false
	if task.node == "iron" and not _has_structure_at(str(task.faction), str(task.district), "mine"): return false
	if task.node == "crystal" and (not _has_structure_at(str(task.faction), str(task.district), "mine") or not _has_workshop(str(task.faction))): return false
	return true

func _build_queue_projection() -> Array:
	var queue: Array = []
	for task_id in state.tasks.keys():
		var task: Dictionary = state.tasks[task_id]
		if task.kind != "build": continue
		var remaining_work := maxi(0, int(task.required_work) - int(task.completed_work))
		queue.append({"id": task_id, "faction": task.faction, "kind": task.structure_kind, "district": task.district, "worker_ids": task.worker_ids.duplicate(), "required_work": task.required_work, "completed_work": task.completed_work, "remaining": ceili(float(remaining_work) / float(Rules.ROUND_TICKS))})
	queue.sort_custom(func(left, right): return str(left.id) < str(right.id))
	return queue

func _harvest_and_farms() -> void:
	# Worker harvesting is advanced every tick by _advance_work_tasks(). Farms stay
	# round-based for now because they are passive structures rather than worker work.
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
		fs.supply.used = _unit_supply_used(faction)
		fs.supply.capacity = Rules.BASE_UNIT_SUPPLY + Rules.STORAGE_UNIT_SUPPLY_BONUS * _structure_count(faction, "storage")
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

func _update_territory_metrics() -> void:
	for faction in Rules.FACTIONS:
		var faction_state: Dictionary = state.factions[faction]
		var owned: Array = []
		for district_id in state.districts.keys():
			if state.districts[district_id].owner == faction:
				owned.append(str(district_id))
		owned.sort()
		faction_state.territory.owned = owned
		if not bool(faction_state.eliminated):
			var held_land := maxi(0, owned.size() - 1)
			faction_state.territory.control_point_rounds = int(faction_state.territory.get("control_point_rounds", 0)) + held_land

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

func _check_conquest_end() -> void:
	var survivors: Array = []
	for faction_id in Rules.FACTIONS:
		if float(state.factions[faction_id].core_hp) > 0.0: survivors.append(faction_id)
	if survivors.size() <= 1:
		_finish_match(str(survivors[0]) if survivors.size() == 1 else "", "last_stronghold")
		return
	if int(state.match.round) >= Rules.MATCH_ROUNDS:
		state.match.ended = true; state.match.truncated = true; state.match.termination = "round_limit"; state.match.phase = "ended"
		_event("match_truncated", "", {"reason": "round_limit", "standings": _top_ranked_factions()})

func _finish_match(winner: String, reason: String) -> void:
	state.match.ended = true; state.match.winner = winner; state.match.termination = reason; state.match.phase = "ended"; _event("match_ended", winner, {"reason": reason})

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
		if district_id != state.factions[faction].core_id and state.districts[district_id].outpost_id != null: outposts += 1
	var structure_value := 0
	for structure in state.structures.values():
		if structure.faction == faction: structure_value += _structure_value(str(structure.kind))
	return [outposts, state.factions[faction].territory.owned.size(), int(state.factions[faction].core_hp), structure_value]

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
	_unassign_worker(unit_id)
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

func _eliminate_faction(faction: String, destroyed_by: String = "") -> void:
	var fs: Dictionary = state.factions[faction]
	if bool(fs.eliminated): return
	fs.core_hp = 0.0
	fs.eliminated = true
	fs.eliminated_round = int(state.match.round)
	fs.destroyed_by = destroyed_by
	if not destroyed_by.is_empty() and destroyed_by != faction and state.factions.has(destroyed_by):
		state.factions[destroyed_by].enemy_strongholds_destroyed = int(state.factions[destroyed_by].get("enemy_strongholds_destroyed", 0)) + 1
	state.match.elimination_order.append({"order": state.match.elimination_order.size() + 1, "faction_id": faction, "eliminated_by": destroyed_by, "round": int(state.match.round), "tick": int(state.match.tick)})
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
	for task_id in state.tasks.keys().duplicate():
		if state.tasks[task_id].faction == faction: state.tasks.erase(task_id)
	var elimination_order: int = state.match.elimination_order.size()
	var event_id := _event("core_destroyed", faction, {"actor_id": destroyed_by, "victim_id": faction, "destroyed_by": destroyed_by, "elimination_order": elimination_order, "eliminated_round": int(state.match.round), "core_hp": 0, "policy": "neutralize_holdings_remove_units"})
	state.match.elimination_order[-1]["event_id"] = event_id

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
	if kind == "tower" and int(state.factions[faction].tech.tier) < 2: return false
	if kind == "wall": return _wall_count(district) < 3
	if kind == "farm": return state.districts[district].kind in ["home", "wild"] and _structure_count_at(district, "farm") == 0
	if kind == "outpost": return state.districts[district].outpost_id == null and state.districts[district].capture.faction == faction and int(state.districts[district].capture.progress) >= 2
	return _structure_count_at(district, kind) == 0
func _can_train(faction: String, kind: String) -> bool:
	if kind == "guard" and not (_has_workshop(faction) and int(state.factions[faction].tech.tier) >= 1): return false
	if kind == "siege" and not (_has_workshop(faction) and int(state.factions[faction].tech.tier) >= 2): return false
	return _queued_and_live_supply(faction) + int(Rules.UNIT_STATS[kind].supply) <= int(state.factions[faction].supply.capacity)

func _unit_supply_used(faction: String) -> int:
	var used := 0
	for unit in state.units.values():
		if str(unit.faction) == faction: used += int(Rules.UNIT_STATS[str(unit.kind)].supply)
	return used

func _queued_and_live_supply(faction: String) -> int:
	var used := _unit_supply_used(faction)
	for job in state.train_queue:
		if str(job.faction) == faction: used += int(Rules.UNIT_STATS[str(job.kind)].supply)
	return used
func _valid_hunt(faction: String, order: Dictionary) -> bool:
	var district := str(order.get("district", ""))
	var species := str(order.get("species", ""))
	if not _owned_supplied(faction, district) or not state.districts[district].wildlife.has(species): return false
	for unit_id in order.get("unit_ids", []):
		if not state.units.has(unit_id) or state.units[unit_id].faction != faction or state.units[unit_id].kind != "worker" or state.units[unit_id].district != district: return false
	return not order.get("unit_ids", []).is_empty()

func _canonical_kind(kind: String) -> String:
	var normalized := kind.to_lower()
	return {"assign_workers": "Gather", "gather": "Gather", "build": "Build", "train": "train", "mobilize": "Move", "move": "Move", "retreat": "Move", "attack": "Attack", "research": "Research", "negotiate": "Negotiate", "think": "Think"}.get(normalized, kind)

func _order_kind(order: Dictionary) -> String:
	return _canonical_kind(str(order.get("kind", order.get("type", order.get("action", "")))))

func _normalize_order(faction: String, raw: Dictionary) -> Dictionary:
	var order: Dictionary = raw.duplicate(true)
	var attributes: Dictionary = {}
	if order.get("attributes", {}) is Dictionary: attributes = order.get("attributes", {})
	order.kind = _order_kind(order)
	if not order.has("unit_ids") and order.get("actor_ids", []) is Array: order.unit_ids = order.get("actor_ids", []).duplicate()
	if not order.has("worker_ids") and order.get("actor_ids", []) is Array: order.worker_ids = order.get("actor_ids", []).duplicate()
	var kind := str(order.kind)
	var target_id := str(order.get("target_id", order.get("target", "")))
	if kind == "Gather":
		if not order.has("district"): order.district = _district_for_target(target_id)
		if not order.has("node"):
			order.node = str(attributes.get("resource_node_id", attributes.get("node", _node_for_resource(str(order.get("district", "")), str(order.get("resource", ""))))))
	elif kind == "Build":
		order.mode = str(order.get("mode", attributes.get("mode", "")))
		if str(order.mode) == "train":
			order.kind = "train"
			order.unit = str(order.get("unit", order.get("option", attributes.get("unit_kind", attributes.get("unit", "")))))
		else:
			if not order.has("structure"): order.structure = str(order.get("option", attributes.get("structure_kind", attributes.get("structure", ""))))
			if not order.has("district"): order.district = _district_for_target(target_id)
	elif kind == "Research":
		if not order.has("technology_id"): order.technology_id = str(order.get("option", attributes.get("technology_id", attributes.get("technology", ""))))
	elif kind in ["Move", "Attack"]:
		var target_district := _district_for_target(target_id)
		if not target_district.is_empty(): order.target = target_district
	return order

func _district_for_target(target_id: String) -> String:
	if state.districts.has(target_id): return target_id
	if state.units.has(target_id): return str(state.units[target_id].district)
	if state.structures.has(target_id): return str(state.structures[target_id].district)
	return ""

func _node_for_resource(district_id: String, resource: String) -> String:
	if not state.districts.has(district_id): return ""
	for node in state.districts[district_id].resources.keys():
		if Rules.HARVEST.has(str(node)) and str(Rules.HARVEST[str(node)].resource) == resource: return str(node)
	return ""

func _valid_attack(faction: String, order: Dictionary) -> bool:
	var target := str(order.get("target_id", order.get("target", "")))
	if target.is_empty(): return false
	for unit_id in order.get("unit_ids", order.get("actor_ids", [])):
		if not state.units.has(unit_id) or state.units[unit_id].faction != faction: return false
	return true

func _valid_repair(faction: String, order: Dictionary) -> bool:
	var target_id := str(order.get("target_id", ""))
	if not state.structures.has(target_id): return false
	var structure: Dictionary = state.structures[target_id]
	return structure.faction == faction and float(structure.hp) < float(Rules.STRUCTURES[structure.kind].hp) and not _eligible_worker_ids(faction, str(structure.district), order.get("worker_ids", order.get("actor_ids", []))).is_empty()

func _create_repair_task(faction: String, order: Dictionary) -> void:
	var target_id := str(order.target_id)
	var structure: Dictionary = state.structures[target_id]
	var workers := _eligible_worker_ids(faction, str(structure.district), order.get("worker_ids", order.get("actor_ids", []))).slice(0, Rules.BUILD_STAFFING_CAP)
	for worker_id in workers: _unassign_worker(worker_id)
	var missing := ceili(float(Rules.STRUCTURES[structure.kind].hp) - float(structure.hp))
	var task := _new_task("repair", faction, str(structure.district), workers, maxi(1, missing))
	task.target_id = target_id; task.staffing_cap = Rules.BUILD_STAFFING_CAP
	state.tasks[task.id] = task
	for worker_id in workers: state.units[worker_id].task_id = task.id
	_event("repair_started", faction, {"task_id": task.id, "structure_id": target_id, "required_work": task.required_work})

func _start_research_task(faction: String, order: Dictionary) -> void:
	var technology := str(order.get("technology_id", order.get("technology", "")))
	if state.factions[faction].tech.completed.has(technology): return
	var workers := _eligible_worker_ids(faction, str(order.get("district", "home_%s" % faction)), order.get("worker_ids", order.get("actor_ids", [])))
	if workers.is_empty(): return
	var spec: Dictionary = Rules.RESEARCH[technology]
	_pay(state.factions[faction].stockpile, spec.cost)
	for worker_id in workers: _unassign_worker(worker_id)
	var task := _new_task("research", faction, str(state.units[workers[0]].district), workers.slice(0, Rules.RESEARCH_STAFFING_CAP), int(spec.work))
	task.technology = technology; task.staffing_cap = Rules.RESEARCH_STAFFING_CAP
	state.tasks[task.id] = task
	for worker_id in task.worker_ids: state.units[worker_id].task_id = task.id
	_event("research_started", faction, {"task_id": task.id, "technology": technology})

func _update_visibility() -> void:
	for faction in Rules.FACTIONS:
		var seen: Dictionary = state.factions[faction].knowledge.seen_districts
		for unit in state.units.values():
			if unit.faction != faction: continue
			seen[str(unit.district)] = int(state.match.round)
			for neighbor in _map.adjacency[str(unit.district)]: seen[str(neighbor)] = int(state.match.round)
		for enemy in state.units.values():
			if seen.has(str(enemy.district)) and enemy.faction != faction:
				state.factions[faction].knowledge.contacts[str(enemy.id)] = {"faction": enemy.faction, "kind": enemy.kind, "district": enemy.district, "last_seen_round": int(state.match.round)}

func project_faction_observation(faction: String) -> Dictionary:
	var knowledge: Dictionary = state.factions[faction].knowledge
	var districts := {}
	for district_id in knowledge.seen_districts.keys():
		districts[district_id] = state.districts[district_id].duplicate(true)
		districts[district_id]["adjacent_ids"] = _map.adjacency[district_id].duplicate()
	var groups: Array = []
	for unit in state.units.values():
		if str(unit.faction) == faction: groups.append(unit.duplicate(true))
	groups.sort_custom(func(left, right): return str(left.id) < str(right.id))
	var structures: Array = []
	for structure in state.structures.values():
		if str(structure.faction) == faction: structures.append(structure.duplicate(true))
	structures.sort_custom(func(left, right): return str(left.id) < str(right.id))
	var public_scores := {}
	for other in Rules.FACTIONS:
		public_scores[other] = {"core_hp": maxf(0.0, float(state.factions[other].core_hp)), "eliminated": bool(state.factions[other].eliminated), "eliminated_round": int(state.factions[other].get("eliminated_round", 0)), "destroyed_by": str(state.factions[other].get("destroyed_by", ""))}
	var participant_events: Array = []
	var globally_visible_types := ["capture_ready", "district_neutralized", "structure_destroyed", "core_damaged", "core_destroyed", "match_ended", "match_truncated", "narrative_phase"]
	for event in state.events:
		if str(event.faction) == faction or globally_visible_types.has(str(event.type)):
			participant_events.append(event.duplicate(true))
	return {
		"faction_id": faction,
		"round": state.match.round,
		"narrative_phase": state.match.narrative_phase,
		"inventory": state.factions[faction].stockpile.duplicate(true),
		"groups": groups,
		"structures": structures,
		"districts": districts,
		"contacts": knowledge.contacts.duplicate(true),
		"tasks": state.tasks.values().filter(func(task): return task.faction == faction).map(func(task): return task.duplicate(true)),
		"training_queue": state.train_queue.filter(func(job): return str(job.faction) == faction).map(func(job): return job.duplicate(true)),
		"technology": state.factions[faction].tech.duplicate(true),
		"supply": state.factions[faction].supply.duplicate(true),
		"public_scores": public_scores,
		"recent_events": participant_events,
		"elimination_order": state.match.elimination_order.duplicate(true),
		"action_mask": legal_actions_for(faction)
	}

func legal_actions_for(faction: String) -> Array:
	var actions: Array = []
	for action in ["Move", "Gather", "Build", "Attack", "Research", "Negotiate", "Think"]:
		actions.append({"action": action, "enabled": not bool(state.factions[faction].eliminated), "reason": "" if not bool(state.factions[faction].eliminated) else "faction_eliminated"})
	return actions

func _update_narrative_phase() -> void:
	var next := "Opening"
	if int(state.match.round) >= 8: next = "Fortify"
	if state.structures.size() >= 9: next = "Expand"
	if state.units.size() >= 12: next = "War"
	if Rules.FACTIONS.filter(func(faction): return not bool(state.factions[faction].eliminated)).size() <= 2: next = "Endgame"
	if state.match.narrative_phase != next:
		state.match.narrative_phase = next; _event("narrative_phase", "", {"phase": next})
func _rejection_reason(_faction: String, order: Dictionary) -> String:
	var kind := _canonical_kind(str(order.get("kind", order.get("type", ""))))
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
func _has_active_research(faction: String) -> bool:
	for task in state.tasks.values():
		if str(task.faction) == faction and str(task.kind) == "research": return true
	return false
func _research_prerequisites_met(faction: String, technology: String) -> bool:
	var completed: Array = state.factions[faction].tech.completed
	if technology == "ironworking": return completed.has("fieldcraft")
	if technology == "siegecraft": return completed.has("ironworking")
	return technology == "fieldcraft"
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
func _event(type: String, faction: String, payload: Dictionary) -> String:
	_event_serial += 1
	var event := {"event_id": "event.%04d.%06d" % [int(state.match.tick), _event_serial], "type": type, "kind": type, "round": int(state.match.round), "tick": int(state.match.tick), "faction": faction, "actor_id": "", "target_ids": [], "state": ""}
	event.merge(payload)
	state.events.append(event)
	return str(event.event_id)
func _hash_state() -> void:
	var copy := state.duplicate(true); copy.match.state_hash = ""; state.match.state_hash = JSON.stringify(copy, "", true).sha256_text()
