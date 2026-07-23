class_name EmbodimentRtsSkirmishV1Authority
extends "res://scripts/embodiment/rts_skirmish/rts_skirmish_authority.gd"

## Action-driven successor to the sealed rts-skirmish-v0 showcase.
##
## No tick in this class calls `_story_tick`: accepted, validated task plans are the sole
## source of worker orders.  Both teams are applied in the fixed participant order and combat
## damage is committed simultaneously, keeping the replay deterministic and seat neutral.

const TaskPlanV1 := preload("res://scripts/embodiment/rts_skirmish/rts_v1_task_plan_contract.gd")
const TASK_ID_V1 := "rts-skirmish-v1"
const BUILD_TICKS := 30
const TRAIN_TICKS := 20
const GATHER_TICKS_V1 := 20
const DEPOSIT_TICKS_V1 := 10
const ATTACK_DAMAGE := 35
const STRUCTURE_DAMAGE := 25
const ATTACK_COOLDOWN := 5
const HOLD_SCORE_TICKS := 60

var orders: Dictionary = {}
var central_hold_ticks: Dictionary = {}
var trained_units: Dictionary = {}


func expected_task_id() -> String:
	return TASK_ID_V1


func configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if config.get("protocol_version") != PROTOCOL_VERSION: errors.append("protocol_version_invalid")
	if config.get("task_id") != TASK_ID_V1: errors.append("task_id_invalid")
	if not config.get("episode_id") is String or not str(config.episode_id).begins_with("ep_"): errors.append("episode_id_invalid")
	if config.get("participant_ids") != PARTICIPANTS: errors.append("participant_ids_invalid")
	if config.get("maximum_episode_ticks") != MAXIMUM_TICKS: errors.append("maximum_episode_ticks_invalid")
	if not errors.is_empty(): return errors
	task_id = TASK_ID_V1
	episode_id = str(config.episode_id)
	reset()
	return errors


func reset() -> Dictionary:
	# v0 reset only creates state; it does not advance its cinematic.  Reuse its deterministic
	# map layout and presentation-compatible unit model, then replace its initial conditions.
	var observations: Dictionary = super.reset()
	story_phase = "live_command"
	victory_latched = false
	orders = {}
	central_hold_ticks = {"participant_0": 0, "participant_1": 0}
	trained_units = {"participant_0": 0, "participant_1": 0}
	for participant_id: String in PARTICIPANTS:
		_spawn_unit(participant_id, 1)
		_spawn_unit(participant_id, 2)
		structures[participant_id].barracks = {"state": "unbuilt", "progress_ticks": 0, "built": false}
		structures[participant_id].tower = {"health": TOWER_HEALTH, "state": "unbuilt", "progress_ticks": 0, "built": false}
		for unit_id: String in _team_unit_ids(participant_id):
			units[unit_id].role = "worker"
			units[unit_id].position_mt = TOWN_HALLS[participant_id] + Vector2i(0, (int(unit_id.get_slice("_", 1)) - 1) * 250)
			orders[unit_id] = {"task": "hold", "target_id": "hold_position"}
		_sync_operator(participant_id)
	return observations


func task_plan_schema_valid(participant_id: String, plan: Variant) -> bool:
	if not TaskPlanV1.validate(plan, episode_id, observation_seq, _team_unit_ids(participant_id), _visible_target_ids(participant_id), _alive_unit_ids(participant_id)).is_empty():
		return false
	for assignment: Dictionary in plan.assignments:
		if not _task_target_compatible(participant_id, str(assignment.task), str(assignment.target_id)):
			return false
	return true


func step_task_plan_window(window: Dictionary) -> Dictionary:
	# Invalid plan windows deliberately clear that team's active orders.  A stale or malformed
	# command can therefore never continue moving units after it has been rejected.
	var plans: Dictionary = window.get("plans", {})
	for participant_id: String in PARTICIPANTS:
		var plan: Variant = plans.get(participant_id)
		if not task_plan_schema_valid(participant_id, plan):
			_hold_team(participant_id)
			continue
		for assignment: Dictionary in plan.assignments:
			orders[str(assignment.unit_id)] = {"task": str(assignment.task), "target_id": str(assignment.target_id)}
	return super.step_task_plan_window(window)


func _apply_joint_tick(_controls: Dictionary, _first_tick: bool, _receipt_codes: Dictionary, events: Array[Dictionary]) -> void:
	var pending_unit_damage := {}
	var pending_structure_damage := {}
	for participant_id: String in PARTICIPANTS:
		pending_unit_damage[participant_id] = {}
		pending_structure_damage[participant_id] = {"town_hall": 0, "tower": 0, "barracks": 0}
	for participant_id: String in PARTICIPANTS:
		for unit_id: String in _team_unit_ids(participant_id):
			var unit: Dictionary = units[unit_id]
			if bool(unit.alive):
				_apply_order(unit, participant_id, pending_unit_damage, pending_structure_damage, events)
	_commit_damage(pending_unit_damage, pending_structure_damage, events)
	for participant_id: String in PARTICIPANTS:
		_sync_operator(participant_id)


func _apply_order(unit: Dictionary, participant_id: String, pending_unit_damage: Dictionary, pending_structure_damage: Dictionary, events: Array[Dictionary]) -> void:
	unit.attack_cooldown_ticks = maxi(0, int(unit.attack_cooldown_ticks) - 1)
	var order: Dictionary = orders.get(str(unit.id), {"task": "hold", "target_id": "hold_position"})
	var task := str(order.task)
	var target_id := str(order.target_id)
	if task == "hold":
		unit.task = "holding"; unit.animation_state = "idle"; unit.target_id = target_id
		# Each formation lane is deliberately a short distance from the literal centre; the
		# objective owns the whole bridge footprint rather than a single overlap pixel.
		if unit.position_mt.distance_squared_to(Vector2i.ZERO) <= 600 * 600:
			central_hold_ticks[participant_id] = int(central_hold_ticks[participant_id]) + 1
		return
	if task == "gather":
		_gather(unit, participant_id, target_id, events)
		return
	if task == "return_material":
		_return_material(unit, participant_id, events)
		return
	if task == "build":
		_build(unit, participant_id, target_id, events)
		return
	if task == "train" or task == "arm":
		_train(unit, participant_id, events)
		return
	if task == "rally":
		_walk_to(unit, _bridge_lane(participant_id, int(str(unit.id).get_slice("_", 1))), "rallying", "bridge")
		return
	if task == "retreat":
		_walk_to(unit, TOWN_HALLS[participant_id], "retreating", "town_hall")
		return
	if task == "attack_unit":
		_attack_unit(unit, participant_id, target_id, pending_unit_damage, events)
		return
	if task == "attack_structure":
		_attack_structure(unit, participant_id, target_id, pending_structure_damage, events)
		return
	unit.task = "holding"; unit.animation_state = "idle"


func _gather(unit: Dictionary, participant_id: String, resource_id: String, events: Array[Dictionary]) -> void:
	if not unit.carrying.is_empty():
		_return_material(unit, participant_id, events)
		return
	var resource: Dictionary = resources.get(resource_id, {})
	if resource.is_empty() or int(resource.stock) <= 0:
		unit.task = "holding"; unit.animation_state = "idle"
		return
	if not _walk_to(unit, resource.position_mt, "walking", resource_id): return
	unit.task = "harvesting"; unit.animation_state = "gather"; unit.progress_ticks += 1
	if int(unit.progress_ticks) < GATHER_TICKS_V1: return
	unit.carrying = "wood" if str(resource.kind) == "tree" else "ore"
	unit.progress_ticks = 0; resource.stock = maxi(0, int(resource.stock) - 1)
	resource.state = "stump" if str(resource.kind) == "tree" else "cracked"
	events.append(_event("rts_v1_material_gathered", [participant_id], {"unit_id": unit.id, "kind": unit.carrying}))


func _return_material(unit: Dictionary, participant_id: String, events: Array[Dictionary]) -> void:
	if unit.carrying.is_empty():
		unit.task = "holding"; unit.animation_state = "idle"; return
	if not _walk_to(unit, TOWN_HALLS[participant_id], "returning", "town_hall"): return
	unit.task = "depositing"; unit.animation_state = "gather"; unit.progress_ticks += 1
	if int(unit.progress_ticks) < DEPOSIT_TICKS_V1: return
	var kind := str(unit.carrying)
	economy[participant_id][kind] = int(economy[participant_id][kind]) + 1
	unit.deposits += 1; unit.materials_gathered += 1; unit.carrying = ""; unit.progress_ticks = 0
	events.append(_event("rts_v1_material_deposited", [participant_id], {"unit_id": unit.id, "kind": kind, "team_total": int(economy[participant_id][kind])}))


func _build(unit: Dictionary, participant_id: String, structure_id: String, events: Array[Dictionary]) -> void:
	var structure: Dictionary = structures[participant_id].get(structure_id, {})
	if structure.is_empty() or bool(structure.built):
		unit.task = "holding"; unit.animation_state = "idle"; return
	var cost := {"wood": 2, "ore": 1} if structure_id == "barracks" else {"wood": 1, "ore": 1}
	if str(structure.state) == "unbuilt":
		if int(economy[participant_id].wood) < int(cost.wood) or int(economy[participant_id].ore) < int(cost.ore):
			unit.task = "holding"; unit.animation_state = "idle"; return
		economy[participant_id].wood -= int(cost.wood); economy[participant_id].ore -= int(cost.ore)
		structure.state = "building"
		events.append(_event("rts_v1_construction_started", [participant_id], {"structure": structure_id}))
	var destination: Vector2i = BARRACKS[participant_id] if structure_id == "barracks" else TOWERS[participant_id]
	if not _walk_to(unit, destination, "building", structure_id): return
	unit.animation_state = "build"; structure.progress_ticks = int(structure.progress_ticks) + 1
	if int(structure.progress_ticks) < BUILD_TICKS: return
	structure.state = "active"; structure.built = true
	events.append(_event("rts_v1_structure_built", [participant_id], {"structure": structure_id}))


func _train(unit: Dictionary, participant_id: String, events: Array[Dictionary]) -> void:
	if str(unit.role) == "militia":
		unit.task = "holding"; unit.animation_state = "idle"; return
	if not bool(structures[participant_id].barracks.built):
		unit.task = "holding"; unit.animation_state = "idle"; return
	if not _walk_to(unit, BARRACKS[participant_id], "arming", "barracks"): return
	unit.animation_state = "build"; unit.arming_ticks += 1
	if int(unit.arming_ticks) < TRAIN_TICKS: return
	unit.role = "militia"; unit.arming_ticks = 0; trained_units[participant_id] = int(trained_units[participant_id]) + 1
	events.append(_event("rts_v1_unit_trained", [participant_id], {"unit_id": unit.id}))


func _attack_unit(unit: Dictionary, participant_id: String, target_id: String, pending: Dictionary, events: Array[Dictionary]) -> void:
	var target: Dictionary = units.get(target_id, {})
	if str(unit.role) != "militia" or target.is_empty() or not bool(target.alive): return
	if not _walk_to(unit, target.position_mt, "attacking", target_id): return
	if unit.position_mt.distance_squared_to(target.position_mt) > ATTACK_RANGE_MT * ATTACK_RANGE_MT or int(unit.attack_cooldown_ticks) > 0: return
	unit.attack_cooldown_ticks = ATTACK_COOLDOWN; unit.animation_state = "attack"
	pending[str(target.team)][target_id] = int(pending[str(target.team)].get(target_id, 0)) + ATTACK_DAMAGE
	combat_stats[participant_id].hits_landed = int(combat_stats[participant_id].hits_landed) + 1
	events.append(_event("rts_v1_attack_committed", [participant_id, str(target.team)], {"attacker": unit.id, "target": target_id}))


func _attack_structure(unit: Dictionary, participant_id: String, target_id: String, pending: Dictionary, events: Array[Dictionary]) -> void:
	if str(unit.role) != "militia": return
	var rival := _rival(participant_id)
	var structure_id := "town_hall" if target_id == "enemy_town_hall" else "tower" if target_id == "enemy_tower" else "barracks"
	var target: Dictionary = structures[rival].get(structure_id, {})
	if target.is_empty() or str(target.state) == "destroyed": return
	var position: Vector2i = TOWN_HALLS[rival] if structure_id == "town_hall" else TOWERS[rival] if structure_id == "tower" else BARRACKS[rival]
	if not _walk_to(unit, position, "attacking", target_id): return
	if unit.position_mt.distance_squared_to(position) > SIEGE_RANGE_MT * SIEGE_RANGE_MT or int(unit.attack_cooldown_ticks) > 0: return
	unit.attack_cooldown_ticks = ATTACK_COOLDOWN; unit.animation_state = "attack"; pending[rival][structure_id] = int(pending[rival][structure_id]) + STRUCTURE_DAMAGE
	events.append(_event("rts_v1_structure_attack_committed", [participant_id, rival], {"attacker": unit.id, "structure": structure_id}))


func _commit_damage(pending_units: Dictionary, pending_structures: Dictionary, events: Array[Dictionary]) -> void:
	for participant_id: String in PARTICIPANTS:
		for unit_id: String in _team_unit_ids(participant_id):
			var damage := int(pending_units[participant_id].get(unit_id, 0))
			if damage <= 0 or not bool(units[unit_id].alive): continue
			var unit: Dictionary = units[unit_id]; unit.health = maxi(0, int(unit.health) - damage); combat_stats[participant_id].hits_received += 1
			if int(unit.health) == 0:
				unit.alive = false; unit.task = "defeated"; unit.animation_state = "defeat"
				events.append(_event("rts_v1_unit_lost", [participant_id, _rival(participant_id)], {"unit_id": unit_id}))
		for structure_id: String in ["town_hall", "tower", "barracks"]:
			var damage := int(pending_structures[participant_id][structure_id])
			if damage <= 0: continue
			var structure: Dictionary = structures[participant_id][structure_id]
			if str(structure.state) == "destroyed": continue
			structure.health = maxi(0, int(structure.get("health", TOWER_HEALTH)) - damage)
			combat_stats[_rival(participant_id)].town_hall_damage_dealt += damage if structure_id == "town_hall" else 0
			combat_stats[participant_id].town_hall_damage_received += damage if structure_id == "town_hall" else 0
			if int(structure.health) == 0:
				structure.state = "destroyed"
				events.append(_event("rts_v1_structure_destroyed", [participant_id, _rival(participant_id)], {"structure": structure_id}))


func _resolve_terminal(events: Array[Dictionary]) -> void:
	if bool(terminal.ended): return
	var defeated := []
	for participant_id: String in PARTICIPANTS:
		if int(structures[participant_id].town_hall.health) <= 0: defeated.append(participant_id)
	if defeated.size() == 1:
		winner_id = _rival(str(defeated[0])); terminal = {"ended": true, "outcome": "win", "reason": "town_hall_destroyed"}
	elif defeated.size() == 2:
		winner_id = null; terminal = {"ended": true, "outcome": "draw", "reason": "simultaneous_town_hall_destroyed"}
	elif int(central_hold_ticks.participant_0) >= HOLD_SCORE_TICKS and int(central_hold_ticks.participant_1) < HOLD_SCORE_TICKS:
		winner_id = "participant_0"; terminal = {"ended": true, "outcome": "win", "reason": "central_objective"}
	elif int(central_hold_ticks.participant_1) >= HOLD_SCORE_TICKS and int(central_hold_ticks.participant_0) < HOLD_SCORE_TICKS:
		winner_id = "participant_1"; terminal = {"ended": true, "outcome": "win", "reason": "central_objective"}
	elif tick >= MAXIMUM_TICKS:
		var blue_score := _score("participant_0"); var red_score := _score("participant_1")
		winner_id = "participant_0" if blue_score > red_score else "participant_1" if red_score > blue_score else null
		terminal = {"ended": true, "outcome": "draw" if winner_id == null else "win", "reason": "time_limit_draw" if winner_id == null else "time_limit_score"}
	if not bool(terminal.ended): return
	events.append(_event("rts_skirmish_v1_completed", PARTICIPANTS, {"task_id": TASK_ID_V1, "completion_tick": tick, "terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason, "winner_id": winner_id}))
	for participant_id: String in PARTICIPANTS:
		var outcome := "draw" if winner_id == null else "win" if participant_id == winner_id else "loss"
		events.append(_event("rts_skirmish_v1_participant_summary", [participant_id], _summary(participant_id, outcome)))


func _summary(participant_id: String, outcome: String) -> Dictionary:
	var deposits := 0
	for unit_id: String in _team_unit_ids(participant_id): deposits += int(units[unit_id].deposits)
	var stats: Dictionary = combat_stats[participant_id]
	return {"task_id": TASK_ID_V1, "completion_tick": tick, "terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason, "participant_id": participant_id, "outcome": outcome, "decision_windows": int(operators[participant_id].decision_windows), "fallback_windows": int(operators[participant_id].fallback_windows), "materials_gathered": deposits, "deposits": deposits, "barracks_built": 1 if bool(structures[participant_id].barracks.built) else 0, "towers_built": 1 if bool(structures[participant_id].tower.built) else 0, "units_trained": int(trained_units[participant_id]), "central_hold_ticks": int(central_hold_ticks[participant_id]), "town_hall_damage_dealt": int(stats.town_hall_damage_dealt), "town_hall_damage_received": int(stats.town_hall_damage_received), "hits_landed": int(stats.hits_landed), "hits_received": int(stats.hits_received), "knockouts": int(stats.knockouts)}


func checkpoint() -> Dictionary:
	var value: Dictionary = super.checkpoint()
	# The inherited RTS checkpoint already projects all physical unit, economy, and structure
	# state. Keep its canonical JSON shape so replay hashing cannot retain task-plan internals.
	value.task_id = TASK_ID_V1
	return value


func _visible_target_ids(participant_id: String) -> Array[String]:
	var values: Array[String] = ["town_hall", "barracks", "tower", "bridge", "hold_position", "enemy_tower", "enemy_town_hall"]
	for resource_id: String in _sorted_keys(resources):
		if str(resources[resource_id].team) == participant_id and int(resources[resource_id].stock) > 0: values.append(resource_id)
	for unit_id: String in _team_unit_ids(participant_id):
		if bool(units[unit_id].alive): values.append(unit_id)
	for unit_id: String in _team_unit_ids(_rival(participant_id)):
		if bool(units[unit_id].alive): values.append(unit_id)
	return values


func _task_target_compatible(participant_id: String, task: String, target_id: String) -> bool:
	if task == "gather": return target_id in _owned_resource_ids(participant_id)
	if task == "return_material" or task == "retreat": return target_id == "town_hall"
	if task == "build": return target_id in ["barracks", "tower"]
	if task == "train" or task == "arm": return target_id == "barracks"
	if task == "rally": return target_id == "bridge"
	if task == "hold": return target_id in ["bridge", "hold_position"]
	if task == "attack_unit": return target_id in _team_unit_ids(_rival(participant_id))
	if task == "attack_structure": return target_id in ["enemy_town_hall", "enemy_tower"]
	return false


func _public_objective() -> String:
	return "Issue validated worker orders: gather, build, train, rally, attack, retreat, or hold."


func _hold_team(participant_id: String) -> void:
	for unit_id: String in _team_unit_ids(participant_id):
		orders[unit_id] = {"task": "hold", "target_id": "hold_position"}


func _score(participant_id: String) -> int:
	var town := int(structures[participant_id].town_hall.health)
	return town + 250 * int(trained_units[participant_id]) + 20 * int(central_hold_ticks[participant_id]) + 50 * _living_count(participant_id)
