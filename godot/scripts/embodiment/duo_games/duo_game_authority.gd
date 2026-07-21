class_name EmbodimentDuoGameAuthority
extends RefCounted

## Shared deterministic authority core for the simple two-participant game ladder.
##
## The core deliberately iterates the immutable participant order and commits movement and
## damage simultaneously. Dictionary insertion/arrival order therefore cannot affect authority.

const CheckpointSerializer := preload(
	"res://scripts/embodiment/authority/checkpoint_serializer.gd"
)

const PROTOCOL_VERSION := "llm-controller/0.2.0"
const PARTICIPANTS := ["participant_0", "participant_1"]
const DECISION_TICKS := 10
const MAXIMUM_TICKS := 1200
const ARENA_HALF_EXTENT_MT := 8000
const SPEED_MT := 200
const MAX_HEALTH := 1000
const MAX_ENERGY := 1000
const ENERGY_RECOVERY := 25
const DASH_DISTANCE_MT := 900
const DASH_COST := 300
const DASH_COOLDOWN_TICKS := 20
const PRIMARY_RANGE_MT := 1600
const PRIMARY_DAMAGE := 250
const PRIMARY_COOLDOWN_TICKS := 20
const GUARD_COST := 40
const CHECKPOINT_RADIUS_MT := 550
const RELAY_RADIUS_MT := 1200
const RELAY_HOLD_TARGET := 60
const MAX_INTENT_UTF8_BYTES := 160
const BUTTONS := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
]
const FORWARD_BASIS := [
	Vector2i(0, -1000), Vector2i(707, -707), Vector2i(1000, 0), Vector2i(707, 707),
	Vector2i(0, 1000), Vector2i(-707, 707), Vector2i(-1000, 0), Vector2i(-707, -707),
]
const FACING_NAMES := [
	"north", "north_east", "east", "south_east",
	"south", "south_west", "west", "north_west",
]
const RACE_COURSES := {
	"participant_0": [
		Vector2i(-2500, 3000), Vector2i(-1000, 0),
		Vector2i(-2500, -3000), Vector2i(-2500, -6000),
	],
	"participant_1": [
		Vector2i(2500, -3000), Vector2i(1000, 0),
		Vector2i(2500, 3000), Vector2i(2500, 6000),
	],
}

var task_id := ""
var episode_id := ""
var tick := 0
var observation_seq := 0
var event_seq := 0
var operators: Dictionary = {}
var previous_receipts: Dictionary = {}
var recent_events: Array[Dictionary] = []
var replay_windows: Array[Dictionary] = []
var terminal := {"ended": false, "outcome": "running", "reason": "in_progress"}
var winner_id: Variant = null
var relay_controller: Variant = null
var relay_hold_ticks := 0
var relay_total_ticks := {"participant_0": 0, "participant_1": 0}
var invalid_windows := {"participant_0": 0, "participant_1": 0}


func expected_task_id() -> String:
	return ""


func configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var expected := expected_task_id()
	if expected not in ["duo-checkpoint-race-v0", "duo-relay-control-v0", "duo-spar-v0"]:
		errors.append("authority_task_invalid")
	if config.get("protocol_version") != PROTOCOL_VERSION:
		errors.append("protocol_version_invalid")
	if config.get("task_id") != expected:
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
	task_id = expected
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
	relay_controller = null
	relay_hold_ticks = 0
	relay_total_ticks = {"participant_0": 0, "participant_1": 0}
	invalid_windows = {"participant_0": 0, "participant_1": 0}
	operators = {
		"participant_0": _new_operator(Vector2i(-2500, 6000), 0),
		"participant_1": _new_operator(Vector2i(2500, -6000), 4),
	}
	if task_id != "duo-checkpoint-race-v0":
		operators.participant_0.position_mt = Vector2i(0, 6000)
		operators.participant_1.position_mt = Vector2i(0, -6000)
	return observe_all()


func decision_window_duration(_requested: Variant = null) -> int:
	return DECISION_TICKS


func step_window(window: Variant) -> Dictionary:
	assert(not episode_id.is_empty(), "configure before stepping")
	if terminal.ended:
		return _result({}, [])
	var global_codes := _validate_window(window)
	var decisions: Dictionary = window.get("decisions", {}) if window is Dictionary \
		and window.get("decisions") is Dictionary else {}
	var controls := {}
	var accepted := {}
	var action_ids := {}
	var reasons := {}
	var receipt_codes := {}
	var replay_decisions := {}
	for participant_id: String in PARTICIPANTS:
		var local_codes := PackedStringArray(global_codes)
		var decision: Variant = decisions.get(participant_id)
		var action: Variant = decision.get("action") if decision is Dictionary else null
		var valid := local_codes.is_empty() and _valid_accepted_decision(decision) \
			and _valid_action(action)
		if valid:
			controls[participant_id] = action.control.duplicate(true)
			action_ids[participant_id] = str(action.action_id)
			reasons[participant_id] = null
			operators[participant_id].memory = str(action.memory_update)
			replay_decisions[participant_id] = decision.duplicate(true)
		else:
			invalid_windows[participant_id] = int(invalid_windows[participant_id]) + 1
			controls[participant_id] = _neutral_control()
			action_ids[participant_id] = "no_input_%d_%s" % [observation_seq, participant_id]
			reasons[participant_id] = _no_input_reason(decision)
			_append_unique(local_codes, "no_input")
			replay_decisions[participant_id] = {
				"disposition": "no_input", "action": null,
				"fallback": "neutral", "no_input_reason": reasons[participant_id],
			}
		accepted[participant_id] = valid
		receipt_codes[participant_id] = local_codes
		operators[participant_id].decision_windows += 1
		if valid:
			operators[participant_id].accepted_windows += 1
		else:
			operators[participant_id].fallback_windows += 1
	var start_tick := tick
	var before := {}
	for participant_id: String in PARTICIPANTS:
		before[participant_id] = _effect_snapshot(operators[participant_id])
	var window_events: Array[Dictionary] = []
	var applied_ticks := 0
	for local_tick: int in DECISION_TICKS:
		if terminal.ended:
			break
		_apply_joint_tick(controls, local_tick == 0, receipt_codes, window_events)
		tick += 1
		applied_ticks += 1
		_resolve_terminal(window_events)
	var receipts := {}
	for participant_id: String in PARTICIPANTS:
		var codes: Array = Array(receipt_codes[participant_id])
		codes.push_front("applied" if accepted[participant_id] else "neutral_applied")
		var receipt := {
			"action_id": action_ids[participant_id],
			"observation_seq": observation_seq,
			"accepted": accepted[participant_id],
			"disposition": "accepted" if accepted[participant_id] else "no_input",
			"fallback": "none" if accepted[participant_id] else "neutral",
			"no_input_reason": reasons[participant_id],
			"start_tick": start_tick, "end_tick": tick, "applied_ticks": applied_ticks,
			"codes": codes,
			"effects": _effects(before[participant_id], operators[participant_id]),
		}
		receipts[participant_id] = receipt
		previous_receipts[participant_id] = receipt.duplicate(true)
	recent_events = window_events.duplicate(true)
	observation_seq += 1
	var replay_window := {
		"start_tick": start_tick, "end_tick": tick,
		"decisions": replay_decisions, "receipts": receipts.duplicate(true),
		"events": window_events.duplicate(true), "checkpoint_hash": checkpoint_hash(),
	}
	replay_windows.append(replay_window)
	return _result(receipts, window_events)


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
			if task_id != "duo-spar-v0":
				_append_unique(receipt_codes[participant_id], "dash_disabled")
			elif operator.dash_cooldown_ticks > 0:
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
				operator.animation_state = "dash"
				_append_unique(receipt_codes[participant_id], "dash_applied")
		proposed[participant_id] = candidate
	# Commit both positions only after every proposal was calculated.
	for participant_id: String in PARTICIPANTS:
		operators[participant_id].position_mt = proposed[participant_id]
	if task_id == "duo-checkpoint-race-v0":
		_update_race(window_events)
	elif task_id == "duo-relay-control-v0":
		_update_relay(window_events)
	else:
		_update_spar(controls, first_tick, receipt_codes, window_events)


func _update_race(window_events: Array[Dictionary]) -> void:
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var course: Array = RACE_COURSES[participant_id]
		var index := int(operator.checkpoint_index)
		if index >= course.size() or not _within(operator.position_mt, course[index], CHECKPOINT_RADIUS_MT):
			continue
		operator.checkpoint_index = index + 1
		window_events.append(_event("checkpoint_reached", [participant_id], {
			"participant_id": participant_id, "checkpoint_number": index + 1,
			"checkpoint_total": course.size(),
		}))


func _update_relay(window_events: Array[Dictionary]) -> void:
	var occupants: Array[String] = []
	for participant_id: String in PARTICIPANTS:
		if _within(operators[participant_id].position_mt, Vector2i.ZERO, RELAY_RADIUS_MT):
			occupants.append(participant_id)
	if occupants.size() != 1:
		if relay_controller != null or relay_hold_ticks != 0:
			window_events.append(_event("relay_contested", PARTICIPANTS, {}))
		relay_controller = null
		relay_hold_ticks = 0
		return
	var controller := occupants[0]
	if relay_controller != controller:
		relay_controller = controller
		relay_hold_ticks = 0
		window_events.append(_event("relay_control_changed", PARTICIPANTS, {
			"controller": controller,
		}))
	relay_hold_ticks += 1
	relay_total_ticks[controller] = int(relay_total_ticks[controller]) + 1
	if relay_hold_ticks == RELAY_HOLD_TARGET:
		window_events.append(_event("relay_secured", PARTICIPANTS, {"controller": controller}))


func _update_spar(
	controls: Dictionary, first_tick: bool, receipt_codes: Dictionary,
	window_events: Array[Dictionary],
) -> void:
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		if bool(controls[participant_id].buttons.guard) and operator.energy >= GUARD_COST:
			operator.guarding = true
			operator.animation_state = "guard"
			operator.energy -= GUARD_COST
			_append_unique(receipt_codes[participant_id], "guard_active")
		else:
			operator.guarding = false
			if bool(controls[participant_id].buttons.guard):
				_append_unique(receipt_codes[participant_id], "guard_energy_depleted")
			operator.energy = mini(MAX_ENERGY, int(operator.energy) + ENERGY_RECOVERY)
	if not first_tick:
		return
	var pending_damage := {"participant_0": 0, "participant_1": 0}
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
		if _can_hit(operator, operators[rival_id]):
			pending_damage[rival_id] += PRIMARY_DAMAGE
			operator.hits_landed += 1
			operators[rival_id].hits_received += 1
			_append_unique(receipt_codes[participant_id], "primary_hit")
			window_events.append(_event("primary_hit", [participant_id, rival_id], {
				"attacker": participant_id, "target": rival_id, "damage": PRIMARY_DAMAGE,
			}))
		else:
			_append_unique(receipt_codes[participant_id], "primary_missed")
			window_events.append(_event("primary_missed", [participant_id], {
				"attacker": participant_id,
			}))
	for participant_id: String in PARTICIPANTS:
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
		if previous_health > 0 and defender.health == 0:
			operators[_rival(participant_id)].knockouts += 1
		_append_unique(receipt_codes[participant_id], "damage_taken")
		window_events.append(_event("operator_damaged", [participant_id], {
			"participant_id": participant_id, "damage": damage,
		}))


func _resolve_terminal(window_events: Array[Dictionary]) -> void:
	var claims: Array[String] = []
	var reason := ""
	if task_id == "duo-checkpoint-race-v0":
		for participant_id: String in PARTICIPANTS:
			if int(operators[participant_id].checkpoint_index) == RACE_COURSES[participant_id].size():
				claims.append(participant_id)
		reason = "finish"
	elif task_id == "duo-relay-control-v0":
		if relay_hold_ticks >= RELAY_HOLD_TARGET:
			claims.append(str(relay_controller))
		reason = "hold_target"
	else:
		var zero_0 := int(operators.participant_0.health) == 0
		var zero_1 := int(operators.participant_1.health) == 0
		if zero_0 and zero_1:
			claims.assign(PARTICIPANTS)
		elif zero_0:
			claims.append("participant_1")
		elif zero_1:
			claims.append("participant_0")
		reason = "knockout"
	if claims.size() == 1:
		winner_id = claims[0]
		terminal = {"ended": true, "outcome": "win", "reason": reason}
		window_events.append(_event("episode_won", PARTICIPANTS, {
			"winner": winner_id, "reason": reason,
		}))
	elif claims.size() > 1:
		winner_id = null
		terminal = {"ended": true, "outcome": "draw", "reason": "simultaneous_terminal"}
		window_events.append(_event("episode_drawn", PARTICIPANTS, {
			"reason": "simultaneous_terminal",
		}))
	elif tick >= MAXIMUM_TICKS:
		winner_id = null
		terminal = {"ended": true, "outcome": "draw", "reason": "time_limit"}
		window_events.append(_event("episode_drawn", PARTICIPANTS, {"reason": "time_limit"}))
	if terminal.ended:
		_emit_completion_events(window_events)


func _emit_completion_events(window_events: Array[Dictionary]) -> void:
	window_events.append(_event("duo_game_completed", PARTICIPANTS, {
		"task_id": task_id, "completion_tick": tick,
		"terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason,
		"winner_id": winner_id,
	}))
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		var outcome := "draw"
		if winner_id != null:
			outcome = "win" if winner_id == participant_id else "loss"
		window_events.append(_event("duo_participant_summary", [participant_id], {
			"task_id": task_id, "completion_tick": tick,
			"terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason,
			"participant_id": participant_id, "outcome": outcome,
			"decision_windows": int(operator.decision_windows),
			"accepted_windows": int(operator.accepted_windows),
			"fallback_windows": int(operator.fallback_windows),
			"checkpoints_reached": int(operator.checkpoint_index),
			"control_ticks": int(relay_total_ticks[participant_id]),
			"hits_landed": int(operator.hits_landed),
			"hits_received": int(operator.hits_received),
			"knockouts": int(operator.knockouts),
		}))


func observe_all() -> Dictionary:
	return {"participant_0": observe("participant_0"), "participant_1": observe("participant_1")}


func observe(participant_id: String) -> Dictionary:
	assert(participant_id in PARTICIPANTS)
	var operator: Dictionary = operators[participant_id]
	var visible_entities: Array[Dictionary] = []
	if task_id == "duo-checkpoint-race-v0":
		var course: Array = RACE_COURSES[participant_id]
		var index := int(operator.checkpoint_index)
		if index < course.size():
			visible_entities.append(_project_entity(operator, "v_checkpoint", "checkpoint", course[index],
				["approach"], "next_%d_of_%d" % [index + 1, course.size()]))
	elif task_id == "duo-relay-control-v0":
		visible_entities.append(_project_entity(operator, "v_relay", "relay", Vector2i.ZERO,
			["capture"], _relay_state(participant_id)))
	var rival_id := _rival(participant_id)
	var rival: Dictionary = operators[rival_id]
	if _visible(operator, rival.position_mt):
		visible_entities.append(_project_entity(operator, "v_rival", "operator", rival.position_mt,
			[] if task_id != "duo-spar-v0" else ["attack", "guard"], _health_band(rival.health)))
	return {
		"protocol_version": PROTOCOL_VERSION, "episode_id": episode_id,
		"observation_seq": observation_seq, "tick": tick, "profile": "text-visible-v1",
		"goal": _goal(), "remaining_ticks": maxi(0, MAXIMUM_TICKS - tick),
		"self": {
			"health_percent": _divide_toward_zero(int(operator.health) * 100, MAX_HEALTH),
			"energy_percent": _divide_toward_zero(int(operator.energy) * 100, MAX_ENERGY),
			"facing": FACING_NAMES[int(operator.heading)], "contact": operator.contact,
			"inventory": [], "status": ["guarding"] if operator.guarding else [],
		},
		"visible_entities": visible_entities, "recent_events": _events_for(participant_id),
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
			"checkpoint_index": operator.checkpoint_index,
			"distance_travelled_mt": operator.distance_travelled_mt,
			"damage_taken": operator.damage_taken, "contact": operator.contact,
			"animation_state": operator.animation_state,
			"decision_windows": operator.decision_windows,
			"accepted_windows": operator.accepted_windows,
			"fallback_windows": operator.fallback_windows,
			"hits_landed": operator.hits_landed, "hits_received": operator.hits_received,
			"knockouts": operator.knockouts,
		}
	return {
		"protocol_version": PROTOCOL_VERSION, "task_id": task_id, "episode_id": episode_id,
		"tick": tick, "observation_seq": observation_seq, "event_seq": event_seq,
		"operators": projected_operators, "relay_controller": relay_controller,
		"relay_hold_ticks": relay_hold_ticks, "relay_total_ticks": relay_total_ticks.duplicate(true),
		"invalid_windows": invalid_windows.duplicate(true), "winner_id": winner_id,
		"terminal": terminal.duplicate(true),
	}


func checkpoint_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(checkpoint())


func replay() -> Dictionary:
	return {
		"protocol_version": PROTOCOL_VERSION, "task_id": task_id, "episode_id": episode_id,
		"participant_ids": PARTICIPANTS.duplicate(), "windows": replay_windows.duplicate(true),
		"final_checkpoint_hash": checkpoint_hash(), "terminal": terminal.duplicate(true),
		"authority_aggregates": authority_aggregates(),
	}


func replay_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(replay())


func authority_aggregates() -> Dictionary:
	var participants := {}
	for participant_id: String in PARTICIPANTS:
		var operator: Dictionary = operators[participant_id]
		participants[participant_id] = {
			"checkpoint_count": int(operator.checkpoint_index),
			"distance_travelled_mt": int(operator.distance_travelled_mt),
			"damage_taken": int(operator.damage_taken),
			"health_remaining": int(operator.health),
			"relay_control_ticks": int(relay_total_ticks[participant_id]),
			"invalid_windows": int(invalid_windows[participant_id]),
			"decision_windows": int(operator.decision_windows),
			"accepted_windows": int(operator.accepted_windows),
			"fallback_windows": int(operator.fallback_windows),
			"hits_landed": int(operator.hits_landed),
			"hits_received": int(operator.hits_received),
			"knockouts": int(operator.knockouts),
		}
	return {
		"task_id": task_id, "completion_tick": tick if terminal.ended else null,
		"terminal_outcome": terminal.outcome, "terminal_reason": terminal.reason,
		"winner_id": winner_id, "participants": participants,
	}


func participant_presentation_source(participant_id: String) -> Dictionary:
	if participant_id not in PARTICIPANTS:
		return {}
	var operator: Dictionary = operators[participant_id]
	var observation: Dictionary = observe(participant_id)
	var visible_entities: Array[Dictionary] = []
	for semantic: Dictionary in observation.visible_entities:
		var entity_id := str(semantic.id)
		if entity_id == "v_checkpoint":
			var course: Array = RACE_COURSES[participant_id]
			var index := int(operator.checkpoint_index)
			if index < course.size():
				visible_entities.append(_presentation_entity(
					entity_id, "checkpoint", course[index], 0, "idle"))
		elif entity_id == "v_relay":
			visible_entities.append(_presentation_entity(
				entity_id, "relay", Vector2i.ZERO, 0, "idle"))
		elif entity_id == "v_rival":
			var rival: Dictionary = operators[_rival(participant_id)]
			visible_entities.append(_presentation_entity(
				entity_id, "operator", rival.position_mt, int(rival.heading),
				str(rival.animation_state)))
	return {
		"participant_id": participant_id,
		"operator": {
			"position_mt": {"x": operator.position_mt.x, "y": operator.position_mt.y},
			"heading": int(operator.heading),
			"animation_state": str(operator.animation_state),
		},
		"visible_entities": visible_entities,
	}


func _presentation_entity(
	id: String, kind: String, position: Vector2i, heading: int, animation_state: String,
) -> Dictionary:
	return {"id": id, "kind": kind,
		"position_mt": {"x": position.x, "y": position.y},
		"heading": heading, "animation_state": animation_state}


func _validate_window(window: Variant) -> PackedStringArray:
	var codes := PackedStringArray()
	if not window is Dictionary:
		codes.append("window_invalid")
		return codes
	if window.get("episode_id") != episode_id:
		codes.append("episode_id_mismatch")
	if not window.get("observation_seq") is int or window.get("observation_seq") != observation_seq:
		codes.append("observation_seq_mismatch")
	if not window.get("start_tick") is int or window.get("start_tick") != tick:
		codes.append("start_tick_mismatch")
	if not window.get("duration_ticks") is int or window.get("duration_ticks") != DECISION_TICKS:
		codes.append("duration_ticks_invalid")
	if not window.get("decisions") is Dictionary:
		codes.append("decisions_invalid")
	else:
		for key: Variant in window.decisions.keys():
			if key not in PARTICIPANTS:
				codes.append("unexpected_participant")
	return codes


func _valid_accepted_decision(value: Variant) -> bool:
	return value is Dictionary and value.get("disposition") == "accepted" \
		and value.get("action") is Dictionary and value.get("fallback") == "none" \
		and value.get("no_input_reason") == null \
		and _has_exact_keys(value, ["disposition", "action", "fallback", "no_input_reason"])


func _valid_action(value: Variant) -> bool:
	if not value is Dictionary or value.get("protocol_version") != PROTOCOL_VERSION \
		or value.get("episode_id") != episode_id or not value.get("observation_seq") is int \
		or value.get("observation_seq") != observation_seq:
		return false
	if not _has_exact_keys(value, ["protocol_version", "episode_id", "observation_seq", "action_id",
		"control", "intent_label", "memory_update"]):
		return false
	if not value.get("action_id") is String or not _valid_identifier(str(value.action_id), 64) \
		or not value.get("intent_label") is String \
		or value.intent_label.to_utf8_buffer().size() > MAX_INTENT_UTF8_BYTES \
		or not value.get("memory_update") is String \
		or value.memory_update.to_utf8_buffer().size() > 2048:
		return false
	if not value.get("control") is Dictionary:
		return false
	var control: Dictionary = value.control
	if not control.get("duration_ticks") is int or control.get("duration_ticks") != DECISION_TICKS \
		or not control.get("buttons") is Dictionary:
		return false
	if not _has_exact_keys(control, ["move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons"]) \
		or not _has_exact_keys(control.buttons, BUTTONS):
		return false
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if not control.get(axis) is int or control[axis] < -1000 or control[axis] > 1000:
			return false
	for button: String in BUTTONS:
		if not control.buttons.get(button) is bool:
			return false
	return true


func _no_input_reason(decision: Variant) -> String:
	if decision is Dictionary and decision.get("disposition") == "no_input" \
		and decision.get("action") == null and decision.get("fallback") == "neutral" \
		and decision.get("no_input_reason") in ["missing", "invalid", "timeout", "stale_observation"] \
		and _has_exact_keys(decision, ["disposition", "action", "fallback", "no_input_reason"]):
		return str(decision.no_input_reason)
	return "missing" if decision == null else "invalid"


func _new_operator(position: Vector2i, heading: int) -> Dictionary:
	return {
		"position_mt": position, "heading": heading, "look_accumulator": 0,
		"health": MAX_HEALTH, "energy": MAX_ENERGY, "guarding": false,
		"primary_cooldown_ticks": 0, "dash_cooldown_ticks": 0,
		"checkpoint_index": 0, "distance_travelled_mt": 0, "damage_taken": 0,
		"contact": "clear", "memory": "", "animation_state": "idle",
		"decision_windows": 0, "accepted_windows": 0, "fallback_windows": 0,
		"hits_landed": 0, "hits_received": 0, "knockouts": 0,
	}


func _neutral_control() -> Dictionary:
	var buttons := {}
	for button: String in BUTTONS:
		buttons[button] = false
	return {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0,
		"duration_ticks": DECISION_TICKS, "buttons": buttons}


func _tick_cooldowns(operator: Dictionary) -> void:
	operator.primary_cooldown_ticks = maxi(0, int(operator.primary_cooldown_ticks) - 1)
	operator.dash_cooldown_ticks = maxi(0, int(operator.dash_cooldown_ticks) - 1)
	operator.contact = "clear"


func _apply_heading(operator: Dictionary, look_x: int) -> void:
	operator.look_accumulator += look_x
	while operator.look_accumulator >= 1000:
		operator.heading = posmod(int(operator.heading) + 1, 8)
		operator.look_accumulator -= 1000
	while operator.look_accumulator <= -1000:
		operator.heading = posmod(int(operator.heading) - 1, 8)
		operator.look_accumulator += 1000


func _walk_candidate(operator: Dictionary, control: Dictionary) -> Vector2i:
	var forward: Vector2i = FORWARD_BASIS[int(operator.heading)]
	var right: Vector2i = FORWARD_BASIS[posmod(int(operator.heading) + 2, 8)]
	var raw_x := _divide_toward_zero(
		right.x * int(control.move_x) + forward.x * int(control.move_y), 1000)
	var raw_y := _divide_toward_zero(
		right.y * int(control.move_x) + forward.y * int(control.move_y), 1000)
	var greatest := maxi(abs(raw_x), abs(raw_y))
	if greatest > 1000:
		raw_x = _divide_toward_zero(raw_x * 1000, greatest)
		raw_y = _divide_toward_zero(raw_y * 1000, greatest)
	var previous: Vector2i = operator.position_mt
	var candidate := previous + Vector2i(
		_divide_toward_zero(raw_x * SPEED_MT, 1000),
		_divide_toward_zero(raw_y * SPEED_MT, 1000))
	var clamped := Vector2i(
		clampi(candidate.x, -ARENA_HALF_EXTENT_MT, ARENA_HALF_EXTENT_MT),
		clampi(candidate.y, -ARENA_HALF_EXTENT_MT, ARENA_HALF_EXTENT_MT))
	operator.contact = "clear" if candidate == clamped else "blocked_front"
	operator.distance_travelled_mt += absi(clamped.x - previous.x) + absi(clamped.y - previous.y)
	return clamped


func _dash_candidate(position: Vector2i, heading: int) -> Vector2i:
	var forward: Vector2i = FORWARD_BASIS[heading]
	return Vector2i(
		clampi(position.x + _divide_toward_zero(forward.x * DASH_DISTANCE_MT, 1000),
			-ARENA_HALF_EXTENT_MT, ARENA_HALF_EXTENT_MT),
		clampi(position.y + _divide_toward_zero(forward.y * DASH_DISTANCE_MT, 1000),
			-ARENA_HALF_EXTENT_MT, ARENA_HALF_EXTENT_MT))


func _can_hit(attacker: Dictionary, target: Dictionary) -> bool:
	if target.health <= 0 or not _within(attacker.position_mt, target.position_mt, PRIMARY_RANGE_MT):
		return false
	var offset: Vector2i = target.position_mt - attacker.position_mt
	var forward: Vector2i = FORWARD_BASIS[int(attacker.heading)]
	var dot := forward.x * offset.x + forward.y * offset.y
	var cross := forward.x * offset.y - forward.y * offset.x
	return dot > 0 and abs(cross) <= dot


func _can_guard(defender: Dictionary, attacker: Dictionary) -> bool:
	var offset: Vector2i = attacker.position_mt - defender.position_mt
	var forward: Vector2i = FORWARD_BASIS[int(defender.heading)]
	return forward.x * offset.x + forward.y * offset.y > 0


func _within(first: Vector2i, second: Vector2i, radius: int) -> bool:
	var offset := second - first
	return offset.x * offset.x + offset.y * offset.y <= radius * radius


func _visible(observer: Dictionary, position: Vector2i) -> bool:
	if observer.position_mt == position:
		return true
	return _bearing(observer, position) in ["front", "front_left", "front_right"] \
		and _distance_squared(observer.position_mt, position) <= 8000 * 8000


func _project_entity(
	observer: Dictionary, id: String, kind: String, position: Vector2i,
	affordances: Array, state: String,
) -> Dictionary:
	return {"id": id, "kind": kind, "bearing": _bearing(observer, position),
		"distance": _distance_band(observer.position_mt, position),
		"affordances": affordances.duplicate(), "state": state}


func _bearing(observer: Dictionary, position: Vector2i) -> String:
	var offset: Vector2i = position - observer.position_mt
	if offset == Vector2i.ZERO:
		return "front"
	var forward: Vector2i = FORWARD_BASIS[int(observer.heading)]
	var right: Vector2i = FORWARD_BASIS[posmod(int(observer.heading) + 2, 8)]
	var forward_dot := forward.x * offset.x + forward.y * offset.y
	var right_dot := right.x * offset.x + right.y * offset.y
	if abs(right_dot) * 2 <= abs(forward_dot):
		return "front" if forward_dot >= 0 else "back"
	if forward_dot >= 0:
		return "front_right" if right_dot > 0 else "front_left"
	return "back_right" if right_dot > 0 else "back_left"


func _distance_band(first: Vector2i, second: Vector2i) -> String:
	var distance_squared := _distance_squared(first, second)
	if distance_squared <= 700 * 700:
		return "touching"
	if distance_squared <= 2200 * 2200:
		return "near"
	if distance_squared <= 5000 * 5000:
		return "medium"
	return "far"


func _distance_squared(first: Vector2i, second: Vector2i) -> int:
	var offset := second - first
	return offset.x * offset.x + offset.y * offset.y


func _relay_state(participant_id: String) -> String:
	if relay_controller == null:
		return "uncontrolled"
	return ("self" if relay_controller == participant_id else "rival") + "_holding"


func _health_band(value: int) -> String:
	if value <= 0:
		return "knocked_out"
	if value <= 250:
		return "critical"
	if value <= 750:
		return "wounded"
	return "ready"


func _goal() -> String:
	if task_id == "duo-checkpoint-race-v0":
		return "Reach every visible checkpoint in order before the rival finishes their mirrored lane."
	if task_id == "duo-relay-control-v0":
		return "Hold the visible central relay uncontested before time expires. Attacks are disabled."
	return "Knock out the rival using movement, facing, dash, primary, and guard."


func _events_for(participant_id: String) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for authority_event: Dictionary in recent_events:
		if participant_id in authority_event.participant_ids:
			output.append(authority_event.duplicate(true))
	return output


func _event(kind: String, participant_ids: Array, data: Dictionary) -> Dictionary:
	var authority_event := {
		"event_id": "evt_%d_%d" % [tick, event_seq], "tick": tick,
		"kind": kind, "summary": kind.replace("_", " ").capitalize() + ".",
		"participant_ids": participant_ids.duplicate(), "data": data.duplicate(true),
	}
	event_seq += 1
	return authority_event


func _effect_snapshot(operator: Dictionary) -> Dictionary:
	return {"health": operator.health, "energy": operator.energy,
		"position_x": operator.position_mt.x, "position_y": operator.position_mt.y,
		"checkpoint_index": operator.checkpoint_index}


func _effects(before: Dictionary, operator: Dictionary) -> Array[Dictionary]:
	return [
		{"kind": "health_delta", "value": int(operator.health) - int(before.health)},
		{"kind": "energy_delta", "value": int(operator.energy) - int(before.energy)},
		{"kind": "movement_x_mt", "value": int(operator.position_mt.x) - int(before.position_x)},
		{"kind": "movement_y_mt", "value": int(operator.position_mt.y) - int(before.position_y)},
		{"kind": "checkpoint_delta", "value": int(operator.checkpoint_index) - int(before.checkpoint_index)},
	]


func _result(receipts: Dictionary, window_events: Array[Dictionary]) -> Dictionary:
	return {"observations": observe_all(), "receipts": receipts,
		"public_events": window_events.duplicate(true), "state_hash": checkpoint_hash(),
		"terminal": terminal.duplicate(true)}


func _rival(participant_id: String) -> String:
	return "participant_1" if participant_id == "participant_0" else "participant_0"


func _append_unique(values: Variant, value: String) -> void:
	if value not in values:
		values.append(value)


func _has_exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key: Variant in expected:
		if not value.has(key):
			return false
	return true


func _valid_identifier(value: String, maximum_bytes: int) -> bool:
	var bytes := value.to_utf8_buffer()
	if bytes.is_empty() or bytes.size() > maximum_bytes:
		return false
	for index: int in bytes.size():
		var code := int(bytes[index])
		var alpha_numeric := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122)
		if not alpha_numeric and (index == 0 or code not in [45, 46, 95]):
			return false
	return true


func _divide_toward_zero(numerator: int, denominator: int) -> int:
	assert(denominator > 0)
	@warning_ignore("integer_division")
	var quotient: int = absi(numerator) / denominator
	return -quotient if numerator < 0 else quotient
