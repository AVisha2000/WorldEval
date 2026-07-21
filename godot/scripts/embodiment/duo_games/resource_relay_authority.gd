class_name EmbodimentDuoResourceRelayAuthority
extends "res://scripts/embodiment/duo_games/duo_game_authority.gd"

## Additive deterministic authority for the richer two-participant resource-relay game.
##
## Coordinates live only in authority checkpoints and presentation sources. Player observations
## contain participant-local bearings, distance bands, affordances, safe state bands, receipts,
## and events. Every joint tick is resolved in immutable participant order with simultaneous
## movement, gathering, and damage commits.

const TASK_ID := "duo-resource-relay-v0"
const OBJECTIVE_TARGET := 300
const DEPOSIT_SCORE := 100
const RESOURCE_CAPACITY := 3
const INTERACTION_RADIUS_MT := 700
const GATHER_TICKS := 10
const DEPOSIT_TICKS := 10
const BUILD_TICKS := 20
const BARRICADE_MAX_HEALTH := 500
const BARRICADE_DAMAGE := 250
const RESOURCE_POSITIONS := {
	"resource_0": Vector2i(-3200, 0),
	"resource_1": Vector2i(3200, 0),
}
const RELAY_POSITIONS := {
	"participant_0": Vector2i(-3200, 5400),
	"participant_1": Vector2i(3200, -5400),
}
const START_POSITIONS := {
	"participant_0": Vector2i(0, 6500),
	"participant_1": Vector2i(0, -6500),
}

var resource_stock: Dictionary = {}
var dropped_resources: Array[Dictionary] = []
var next_drop_id := 0
var barricade_health := {"participant_0": 0, "participant_1": 0}


func expected_task_id() -> String:
	return TASK_ID


func configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if config.get("protocol_version") != PROTOCOL_VERSION:
		errors.append("protocol_version_invalid")
	if config.get("task_id") != TASK_ID:
		errors.append("task_id_invalid")
	if not config.get("episode_id") is String or not str(config.episode_id).begins_with("ep_"):
		errors.append("episode_id_invalid")
	if config.get("participant_ids") != PARTICIPANTS:
		errors.append("participant_ids_invalid")
	if not config.get("maximum_episode_ticks") is int \
		or config.get("maximum_episode_ticks") != MAXIMUM_TICKS:
		errors.append("maximum_episode_ticks_invalid")
	if not errors.is_empty():
		return errors
	task_id = TASK_ID
	episode_id = str(config.episode_id)
	reset()
	return errors


func reset() -> Dictionary:
	tick = 0
	observation_seq = 0
	event_seq = 0
	previous_receipts = {}
	recent_events = []
	replay_windows = []
	terminal = {"ended": false, "outcome": "running", "reason": "in_progress"}
	winner_id = null
	invalid_windows = {"participant_0": 0, "participant_1": 0}
	resource_stock = {"resource_0": RESOURCE_CAPACITY, "resource_1": RESOURCE_CAPACITY}
	dropped_resources = []
	next_drop_id = 0
	barricade_health = {"participant_0": 0, "participant_1": 0}
	operators = {
		"participant_0": _new_resource_operator(START_POSITIONS.participant_0, 0),
		"participant_1": _new_resource_operator(START_POSITIONS.participant_1, 4),
	}
	return observe_all()


func _new_resource_operator(position: Vector2i, heading: int) -> Dictionary:
	var operator: Dictionary = _new_operator(position, heading)
	operator.carrying = false
	operator.gather_target = ""
	operator.gather_progress = 0
	operator.deposit_progress = 0
	operator.build_progress = 0
	operator.resources_gathered = 0
	operator.deposits = 0
	operator.objective_score = 0
	operator.builds_completed = 0
	operator.defend_ticks = 0
	operator.resources_dropped = 0
	operator.dash_uses = 0
	operator.guard_ticks = 0
	return operator


func _apply_joint_tick(
	controls: Dictionary, first_tick: bool, receipt_codes: Dictionary,
	window_events: Array[Dictionary],
) -> void:
	var proposed := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var control: Dictionary = controls[participant_id]
		operator.animation_state = "idle"
		_tick_cooldowns(operator)
		_apply_heading(operator, int(control.look_x))
		if int(control.look_x) != 0:
			operator.animation_state = "turn"
		var before_move: Vector2i = operator.position_mt
		var candidate := _walk_candidate(operator, control)
		if candidate != before_move:
			operator.animation_state = "walk"
		if first_tick and bool(control.buttons.dash):
			if operator.dash_cooldown_ticks > 0:
				_append_unique(receipt_codes[participant_id], "dash_cooldown")
			elif operator.energy < DASH_COST:
				_append_unique(receipt_codes[participant_id], "dash_energy_insufficient")
			else:
				var pre_dash: Vector2i = candidate
				candidate = _dash_candidate(candidate, int(operator.heading))
				operator.distance_travelled_mt += \
					absi(candidate.x - pre_dash.x) + absi(candidate.y - pre_dash.y)
				operator.energy -= DASH_COST
				operator.dash_cooldown_ticks = DASH_COOLDOWN_TICKS
				operator.dash_uses += 1
				operator.animation_state = "dash"
				_append_unique(receipt_codes[participant_id], "dash_applied")
		proposed[participant_id] = candidate
	for participant_id: String in PARTICIPANTS:
		operators[participant_id].position_mt = proposed[participant_id]
	_update_guard(controls, receipt_codes)
	_update_interactions(controls, receipt_codes, window_events)
	if first_tick:
		_update_combat(controls, receipt_codes, window_events)


func _update_guard(controls: Dictionary, receipt_codes: Dictionary) -> void:
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		if bool(controls[participant_id].buttons.guard) and operator.energy >= GUARD_COST:
			operator.guarding = true
			operator.animation_state = "guard"
			operator.energy -= GUARD_COST
			operator.guard_ticks += 1
			if int(barricade_health[participant_id]) > 0 \
				and _within(operator.position_mt, RELAY_POSITIONS[participant_id], RELAY_RADIUS_MT):
				operator.defend_ticks += 1
			_append_unique(receipt_codes[participant_id], "guard_active")
		else:
			operator.guarding = false
			if bool(controls[participant_id].buttons.guard):
				_append_unique(receipt_codes[participant_id], "guard_energy_depleted")
			operator.energy = mini(MAX_ENERGY, int(operator.energy) + ENERGY_RECOVERY)


func _update_interactions(
	controls: Dictionary, receipt_codes: Dictionary, window_events: Array[Dictionary],
) -> void:
	var completing_gathers: Dictionary = {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var control: Dictionary = controls[participant_id]
		if operator.carrying:
			operator.gather_target = ""
			operator.gather_progress = 0
			_update_deposit(participant_id, operator, control, receipt_codes, window_events)
		else:
			operator.deposit_progress = 0
			_update_gather_progress(participant_id, operator, control, completing_gathers)
		_update_build(participant_id, operator, control, receipt_codes, window_events)
	_resolve_gather_completions(completing_gathers, receipt_codes, window_events)


func _update_gather_progress(
	participant_id: String, operator: Dictionary, control: Dictionary,
	completing_gathers: Dictionary,
) -> void:
	if not bool(control.buttons.interact):
		operator.gather_target = ""
		operator.gather_progress = 0
		return
	var target := _gather_target(operator)
	if target.is_empty():
		operator.gather_target = ""
		operator.gather_progress = 0
		return
	if operator.gather_target != target:
		operator.gather_target = target
		operator.gather_progress = 0
	operator.gather_progress += 1
	operator.animation_state = "gather"
	if int(operator.gather_progress) >= GATHER_TICKS:
		if not completing_gathers.has(target):
			completing_gathers[target] = []
		completing_gathers[target].append(participant_id)


func _resolve_gather_completions(
	claims: Dictionary, receipt_codes: Dictionary, window_events: Array[Dictionary],
) -> void:
	var targets: Array = claims.keys()
	targets.sort()
	for target: String in targets:
		var claimants: Array = claims[target]
		claimants.sort()
		var available := _resource_available(target)
		if claimants.size() > available:
			for participant_id: String in claimants:
				operators[participant_id].gather_progress = 0
				_append_unique(receipt_codes[participant_id], "gather_contested")
			window_events.append(_event("resource_gather_contested", claimants, {}))
			continue
		for participant_id: String in claimants:
			_consume_resource(target)
			var operator: Dictionary = operators[participant_id]
			operator.carrying = true
			operator.gather_target = ""
			operator.gather_progress = 0
			operator.resources_gathered += 1
			operator.animation_state = "carry"
			_append_unique(receipt_codes[participant_id], "material_gathered")
			window_events.append(_event("material_gathered", [participant_id], {
				"participant_id": participant_id,
			}))


func _update_deposit(
	participant_id: String, operator: Dictionary, control: Dictionary,
	receipt_codes: Dictionary, window_events: Array[Dictionary],
) -> void:
	var relay: Vector2i = RELAY_POSITIONS[participant_id]
	if not bool(control.buttons.interact) or not _can_interact(operator, relay):
		operator.deposit_progress = 0
		return
	operator.deposit_progress += 1
	operator.animation_state = "deposit"
	if int(operator.deposit_progress) < DEPOSIT_TICKS:
		return
	operator.deposit_progress = 0
	operator.carrying = false
	operator.deposits += 1
	operator.objective_score += DEPOSIT_SCORE
	_append_unique(receipt_codes[participant_id], "material_deposited")
	window_events.append(_event("material_deposited", [participant_id], {
		"participant_id": participant_id,
		"objective_score": int(operator.objective_score),
	}))


func _update_build(
	participant_id: String, operator: Dictionary, control: Dictionary,
	receipt_codes: Dictionary, window_events: Array[Dictionary],
) -> void:
	var can_build: bool = not bool(operator.carrying) and not bool(control.buttons.interact) \
		and int(operator.deposits) > int(operator.builds_completed) \
		and int(barricade_health[participant_id]) < BARRICADE_MAX_HEALTH
	if not bool(control.buttons.ability_1) or not can_build \
		or not _can_interact(operator, RELAY_POSITIONS[participant_id]):
		operator.build_progress = 0
		return
	operator.build_progress += 1
	operator.animation_state = "build"
	if int(operator.build_progress) < BUILD_TICKS:
		return
	operator.build_progress = 0
	barricade_health[participant_id] = BARRICADE_MAX_HEALTH
	operator.builds_completed += 1
	_append_unique(receipt_codes[participant_id], "barricade_built")
	window_events.append(_event("barricade_built", [participant_id], {
		"participant_id": participant_id, "build_number": int(operator.builds_completed),
	}))


func _update_combat(
	controls: Dictionary, receipt_codes: Dictionary, window_events: Array[Dictionary],
) -> void:
	var pending_damage := {"participant_0": 0, "participant_1": 0}
	var pending_barricade_damage := {"participant_0": 0, "participant_1": 0}
	for participant_id: String in PARTICIPANTS:
		if not bool(controls[participant_id].buttons.primary):
			continue
		var operator: Dictionary = operators[participant_id]
		var rival_id := _rival(participant_id)
		if operator.primary_cooldown_ticks > 0:
			_append_unique(receipt_codes[participant_id], "primary_cooldown")
			continue
		operator.primary_cooldown_ticks = PRIMARY_COOLDOWN_TICKS
		operator.animation_state = "attack"
		if not _can_hit(operator, operators[rival_id]):
			_append_unique(receipt_codes[participant_id], "primary_missed")
			window_events.append(_event("primary_missed", [participant_id], {}))
			continue
		if int(barricade_health[rival_id]) > 0 \
			and _within(operators[rival_id].position_mt, RELAY_POSITIONS[rival_id], RELAY_RADIUS_MT):
			pending_barricade_damage[rival_id] += BARRICADE_DAMAGE
			_append_unique(receipt_codes[participant_id], "primary_hit_barricade")
		else:
			pending_damage[rival_id] += PRIMARY_DAMAGE
			operator.hits_landed += 1
			operators[rival_id].hits_received += 1
			_append_unique(receipt_codes[participant_id], "primary_hit")
			window_events.append(_event("primary_hit", [participant_id, rival_id], {
				"attacker": participant_id, "target": rival_id,
			}))
	for participant_id: String in PARTICIPANTS:
		var barrier_damage := int(pending_barricade_damage[participant_id])
		if barrier_damage > 0:
			barricade_health[participant_id] = maxi(
				0, int(barricade_health[participant_id]) - barrier_damage)
			window_events.append(_event("barricade_damaged", [participant_id], {
				"participant_id": participant_id,
				"state": _barricade_state(participant_id),
			}))
		var damage := int(pending_damage[participant_id])
		if damage == 0:
			continue
		var defender: Dictionary = operators[participant_id]
		if defender.guarding and _can_guard(defender, operators[_rival(participant_id)]):
			damage = _divide_toward_zero(damage, 2)
			_append_unique(receipt_codes[participant_id], "guard_reduced_damage")
		var previous_health := int(defender.health)
		defender.health = maxi(0, previous_health - damage)
		defender.damage_taken += damage
		defender.animation_state = "hit"
		_append_unique(receipt_codes[participant_id], "damage_taken")
		window_events.append(_event("operator_damaged", [participant_id], {
			"participant_id": participant_id, "damage_band": _damage_band(damage),
		}))
		if previous_health > 0 and int(defender.health) == 0:
			operators[_rival(participant_id)].knockouts += 1
			_drop_carried_resource(participant_id, defender, window_events)


func _drop_carried_resource(
	participant_id: String, operator: Dictionary, window_events: Array[Dictionary],
) -> void:
	if not operator.carrying:
		return
	var drop_id := "drop_%d" % next_drop_id
	next_drop_id += 1
	dropped_resources.append({"id": drop_id, "position_mt": operator.position_mt})
	operator.carrying = false
	operator.resources_dropped += 1
	window_events.append(_event("material_dropped", [participant_id], {
		"participant_id": participant_id,
	}))


func _resolve_terminal(window_events: Array[Dictionary]) -> void:
	var zero_0 := int(operators.participant_0.health) == 0
	var zero_1 := int(operators.participant_1.health) == 0
	# Knockouts always have priority over objective and time claims from the same authority tick.
	if zero_0 or zero_1:
		if zero_0 and zero_1:
			_finish_draw("simultaneous_knockout", window_events)
		else:
			_finish_win("participant_1" if zero_0 else "participant_0", "knockout", window_events)
		return
	var reached_0 := int(operators.participant_0.objective_score) >= OBJECTIVE_TARGET
	var reached_1 := int(operators.participant_1.objective_score) >= OBJECTIVE_TARGET
	if reached_0 or reached_1:
		if reached_0 and reached_1:
			_finish_draw("simultaneous_objective", window_events)
		else:
			_finish_win(
				"participant_0" if reached_0 else "participant_1", "objective_target", window_events)
		return
	if tick < MAXIMUM_TICKS:
		return
	var score_0 := int(operators.participant_0.objective_score)
	var score_1 := int(operators.participant_1.objective_score)
	if score_0 == score_1:
		_finish_draw("time_limit_draw", window_events)
	else:
		_finish_win(
			"participant_0" if score_0 > score_1 else "participant_1",
			"time_limit_score", window_events)


func _finish_win(participant_id: String, reason: String, window_events: Array[Dictionary]) -> void:
	winner_id = participant_id
	terminal = {"ended": true, "outcome": "win", "reason": reason}
	window_events.append(_event("episode_won", PARTICIPANTS, {
		"winner": participant_id, "reason": reason,
	}))
	_emit_completion_events(window_events)


func _finish_draw(reason: String, window_events: Array[Dictionary]) -> void:
	winner_id = null
	terminal = {"ended": true, "outcome": "draw", "reason": reason}
	window_events.append(_event("episode_drawn", PARTICIPANTS, {"reason": reason}))
	_emit_completion_events(window_events)


func _emit_completion_events(window_events: Array[Dictionary]) -> void:
	window_events.append(_event("duo_game_completed", PARTICIPANTS, {
		"task_id": TASK_ID, "completion_tick": tick,
		"terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason,
		"winner_id": winner_id,
	}))
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var outcome := "draw"
		if winner_id != null:
			outcome = "win" if winner_id == participant_id else "loss"
		window_events.append(_event("duo_resource_relay_participant_summary", [participant_id], {
			"task_id": TASK_ID, "completion_tick": tick,
			"terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason,
			"participant_id": participant_id, "outcome": outcome,
			"decision_windows": int(operator.decision_windows),
			"fallback_windows": int(operator.fallback_windows),
			"resources_gathered": int(operator.resources_gathered),
			"deposits": int(operator.deposits),
			"objective_score": int(operator.objective_score),
			"builds_completed": int(operator.builds_completed),
			"defend_ticks": int(operator.defend_ticks),
			"hits_landed": int(operator.hits_landed),
			"hits_received": int(operator.hits_received),
			"knockouts": int(operator.knockouts),
			"resources_dropped": int(operator.resources_dropped),
			"dash_uses": int(operator.dash_uses),
			"guard_ticks": int(operator.guard_ticks),
		}))


func observe(participant_id: String) -> Dictionary:
	assert(participant_id in PARTICIPANTS)
	var operator: Dictionary = operators[participant_id]
	var entities: Array[Dictionary] = []
	for resource_id: String in ["resource_0", "resource_1"]:
		if int(resource_stock[resource_id]) > 0 \
			and _visible(operator, RESOURCE_POSITIONS[resource_id]):
			entities.append(_project_entity(
				operator, "v_%s" % resource_id, "resource", RESOURCE_POSITIONS[resource_id],
				["gather"], "available"))
	for dropped: Dictionary in dropped_resources:
		if _visible(operator, dropped.position_mt):
			entities.append(_project_entity(
				operator, "v_%s" % str(dropped.id), "dropped_resource", dropped.position_mt,
				["gather"], "dropped"))
	var relay: Vector2i = RELAY_POSITIONS[participant_id]
	if _visible(operator, relay):
		entities.append(_project_entity(operator, "v_friendly_relay", "relay", relay,
			["deposit"], _relay_resource_state(participant_id)))
		entities.append(_project_entity(operator, "v_friendly_barricade", "barricade", relay,
			["build", "defend"], _barricade_state(participant_id)))
	var rival_id := _rival(participant_id)
	var rival: Dictionary = operators[rival_id]
	if _visible(operator, rival.position_mt):
		entities.append(_project_entity(operator, "v_rival", "operator", rival.position_mt,
			["hostile"], _rival_state(rival)))
	entities.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return str(first.id) < str(second.id))
	return {
		"protocol_version": PROTOCOL_VERSION, "episode_id": episode_id,
		"observation_seq": observation_seq, "tick": tick, "profile": "text-visible-v1",
		"goal": "Gather visible material, deposit it at your relay, build and defend, and outscore or knock out the rival.",
		"remaining_ticks": maxi(0, MAXIMUM_TICKS - tick),
		"self": {
			"health_percent": _divide_toward_zero(int(operator.health) * 100, MAX_HEALTH),
			"energy_percent": _divide_toward_zero(int(operator.energy) * 100, MAX_ENERGY),
			"facing": FACING_NAMES[int(operator.heading)], "contact": operator.contact,
			"inventory": [{"kind": "material", "count": 1, "selected": true}] \
				if operator.carrying else [],
			"status": _self_status(operator),
		},
		"visible_entities": entities, "recent_events": _events_for(participant_id),
		"previous_receipt": previous_receipts.get(participant_id),
		"memory": str(operator.memory), "terminal": terminal.duplicate(true),
	}


func checkpoint() -> Dictionary:
	var projected_operators := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		projected_operators[participant_id] = {
			"position_mt": [operator.position_mt.x, operator.position_mt.y],
			"heading": operator.heading, "look_accumulator": operator.look_accumulator,
			"health": operator.health, "energy": operator.energy,
			"guarding": operator.guarding,
			"primary_cooldown_ticks": operator.primary_cooldown_ticks,
			"dash_cooldown_ticks": operator.dash_cooldown_ticks,
			"distance_travelled_mt": operator.distance_travelled_mt,
			"damage_taken": operator.damage_taken, "contact": operator.contact,
			"animation_state": operator.animation_state,
			"decision_windows": operator.decision_windows,
			"accepted_windows": operator.accepted_windows,
			"fallback_windows": operator.fallback_windows,
			"hits_landed": operator.hits_landed, "hits_received": operator.hits_received,
			"knockouts": operator.knockouts,
			"carrying": operator.carrying, "gather_target": operator.gather_target,
			"gather_progress": operator.gather_progress,
			"deposit_progress": operator.deposit_progress, "build_progress": operator.build_progress,
			"resources_gathered": operator.resources_gathered, "deposits": operator.deposits,
			"objective_score": operator.objective_score,
			"builds_completed": operator.builds_completed, "defend_ticks": operator.defend_ticks,
			"resources_dropped": operator.resources_dropped, "dash_uses": operator.dash_uses,
			"guard_ticks": operator.guard_ticks,
		}
	var drops: Array[Dictionary] = []
	for dropped: Dictionary in dropped_resources:
		drops.append({"id": dropped.id,
			"position_mt": [dropped.position_mt.x, dropped.position_mt.y]})
	return {
		"protocol_version": PROTOCOL_VERSION, "task_id": TASK_ID, "episode_id": episode_id,
		"tick": tick, "observation_seq": observation_seq, "event_seq": event_seq,
		"operators": projected_operators, "resource_stock": resource_stock.duplicate(true),
		"dropped_resources": drops, "next_drop_id": next_drop_id,
		"barricade_health": barricade_health.duplicate(true),
		"invalid_windows": invalid_windows.duplicate(true), "winner_id": winner_id,
		"terminal": terminal.duplicate(true),
	}


func authority_aggregates() -> Dictionary:
	var participants := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var outcome := "draw"
		if terminal.outcome == "void":
			outcome = "void"
		elif winner_id != null:
			outcome = "win" if winner_id == participant_id else "loss"
		participants[participant_id] = {
			"outcome": outcome,
			"decision_windows": int(operator.decision_windows),
			"fallback_windows": int(operator.fallback_windows),
			"resources_gathered": int(operator.resources_gathered),
			"deposits": int(operator.deposits),
			"objective_score": int(operator.objective_score),
			"builds_completed": int(operator.builds_completed),
			"defend_ticks": int(operator.defend_ticks),
			"hits_landed": int(operator.hits_landed),
			"hits_received": int(operator.hits_received),
			"knockouts": int(operator.knockouts),
			"resources_dropped": int(operator.resources_dropped),
			"dash_uses": int(operator.dash_uses),
			"guard_ticks": int(operator.guard_ticks),
		}
	return {
		"completion_tick": tick if terminal.ended else null,
		"terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason,
		"objective_target": OBJECTIVE_TARGET, "participants": participants,
	}


func participant_presentation_source(participant_id: String) -> Dictionary:
	if participant_id not in PARTICIPANTS:
		return {}
	var operator: Dictionary = operators[participant_id]
	var visible_entities: Array[Dictionary] = []
	for semantic: Dictionary in observe(participant_id).visible_entities:
		var position: Variant = _semantic_position(participant_id, str(semantic.id))
		if position != null:
			var rival: Dictionary = operators[_rival(participant_id)]
			visible_entities.append(_presentation_entity(
				str(semantic.id), str(semantic.kind), position,
				int(rival.heading) if semantic.id == "v_rival" else 0,
				str(rival.animation_state) if semantic.id == "v_rival" else "idle"))
	return {
		"participant_id": participant_id,
		"operator": {"position_mt": {"x": operator.position_mt.x, "y": operator.position_mt.y},
			"heading": int(operator.heading), "animation_state": str(operator.animation_state)},
		"visible_entities": visible_entities,
	}


func _semantic_position(participant_id: String, visible_id: String) -> Variant:
	if visible_id == "v_friendly_relay" or visible_id == "v_friendly_barricade":
		return RELAY_POSITIONS[participant_id]
	if visible_id == "v_rival":
		return operators[_rival(participant_id)].position_mt
	if visible_id.begins_with("v_resource_"):
		return RESOURCE_POSITIONS[visible_id.trim_prefix("v_")]
	if visible_id.begins_with("v_drop_"):
		var target_id := visible_id.trim_prefix("v_")
		for dropped: Dictionary in dropped_resources:
			if dropped.id == target_id:
				return dropped.position_mt
	return null


func _effect_snapshot(operator: Dictionary) -> Dictionary:
	var base: Dictionary = super._effect_snapshot(operator)
	base.carrying = operator.carrying
	base.objective_score = operator.objective_score
	base.builds_completed = operator.builds_completed
	return base


func _effects(before: Dictionary, operator: Dictionary) -> Array[Dictionary]:
	var effects: Array[Dictionary] = super._effects(before, operator)
	effects.append({"kind": "material_delta",
		"value": int(operator.carrying) - int(before.carrying)})
	effects.append({"kind": "objective_score_delta",
		"value": int(operator.objective_score) - int(before.objective_score)})
	effects.append({"kind": "build_delta",
		"value": int(operator.builds_completed) - int(before.builds_completed)})
	return effects


func _gather_target(operator: Dictionary) -> String:
	var candidates: Array[Dictionary] = []
	for resource_id: String in ["resource_0", "resource_1"]:
		if int(resource_stock[resource_id]) > 0 \
			and _can_interact(operator, RESOURCE_POSITIONS[resource_id]):
			candidates.append({"id": resource_id, "position_mt": RESOURCE_POSITIONS[resource_id]})
	for dropped: Dictionary in dropped_resources:
		if _can_interact(operator, dropped.position_mt):
			candidates.append(dropped)
	if candidates.is_empty():
		return ""
	candidates.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return str(first.id) < str(second.id))
	return str(candidates[0].id)


func _resource_available(target: String) -> int:
	if target.begins_with("resource_"):
		return int(resource_stock.get(target, 0))
	for dropped: Dictionary in dropped_resources:
		if dropped.id == target:
			return 1
	return 0


func _consume_resource(target: String) -> void:
	if target.begins_with("resource_"):
		resource_stock[target] = int(resource_stock[target]) - 1
		return
	for index: int in dropped_resources.size():
		if dropped_resources[index].id == target:
			dropped_resources.remove_at(index)
			return


func _can_interact(operator: Dictionary, position: Vector2i) -> bool:
	return _within(operator.position_mt, position, INTERACTION_RADIUS_MT) \
		and _bearing(operator, position) == "front"


func _relay_resource_state(participant_id: String) -> String:
	if int(barricade_health[participant_id]) > 0:
		return "fortified"
	return "active" if int(operators[participant_id].objective_score) > 0 else "empty"


func _barricade_state(participant_id: String) -> String:
	var health := int(barricade_health[participant_id])
	if health <= 0:
		return "unbuilt"
	if health < BARRICADE_MAX_HEALTH:
		return "damaged"
	return "built"


func _rival_state(rival: Dictionary) -> String:
	if rival.carrying:
		return "carrying"
	if rival.guarding:
		return "guarding"
	return _health_band(int(rival.health))


func _self_status(operator: Dictionary) -> Array[String]:
	var output: Array[String] = []
	if operator.carrying:
		output.append("carrying")
	if operator.guarding:
		output.append("guarding")
	return output


func _damage_band(damage: int) -> String:
	return "heavy" if damage >= PRIMARY_DAMAGE else "reduced"
