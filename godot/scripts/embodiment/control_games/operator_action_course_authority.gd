class_name EmbodimentOperatorActionCourseAuthorityV2
extends RefCounted

const CourseMap := preload("res://scripts/embodiment/control_games/operator_action_course_map.gd")
const CheckpointSerializer := preload("res://scripts/embodiment/authority/checkpoint_serializer.gd")
const BUTTONS := ["interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel"]
const HEADINGS := ["north", "north_east", "east", "south_east", "south", "south_west", "west", "north_west"]
const FORWARD_MT := [
	Vector2i(0, -1000), Vector2i(707, -707), Vector2i(1000, 0), Vector2i(707, 707),
	Vector2i(0, 1000), Vector2i(-707, 707), Vector2i(-1000, 0), Vector2i(-707, -707),
]

var episode_id := ""
var participant_id := "participant_0"
var maximum_episode_ticks := 300
var seed := 0
var tick := 0
var observation_seq := 0
var station_index := 0
var position_mt := Vector2i.ZERO
var heading := 0
var health := 1000
var energy := 1000
var inventory_material := 0
var deposited_material := 0
var gather_progress := 0
var build_progress := 0
var active_interaction := "none"
var animation_state := "idle"
var invalid_windows := 0
var command_attempts := 0
var command_successes := 0
var damage_taken := 0
var travelled_distance_mt := 0
var terminal := {"ended": false, "outcome": "running", "reason": "in_progress"}
var previous_receipt: Variant = null
var events: Array[Dictionary] = []
var replay_windows: Array[Dictionary] = []
var station_results: Dictionary = {}
var event_sequence := 0


func configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if config.get("protocol_version") != CourseMap.PROTOCOL_VERSION:
		errors.append("protocol_version must be llm-controller/0.2.0")
	if config.get("task_id") != CourseMap.TASK_ID:
		errors.append("task_id must be operator-action-course-v0")
	if not _valid_episode_id(config.get("episode_id")):
		errors.append("episode_id must be an ep_ identifier")
	if config.get("participant_id", participant_id) != participant_id:
		errors.append("operator action course requires participant_0")
	var max_ticks: Variant = config.get("maximum_episode_ticks", 300)
	var configured_seed: Variant = config.get("seed", 0)
	if not max_ticks is int or max_ticks < 1:
		errors.append("maximum_episode_ticks must be a positive integer")
	if not configured_seed is int or configured_seed < 0 or configured_seed > 9_007_199_254_740_991:
		errors.append("seed must be a non-negative exact integer")
	if not errors.is_empty():
		return errors
	episode_id = config.episode_id
	maximum_episode_ticks = max_ticks
	seed = configured_seed
	tick = 0
	observation_seq = 0
	station_index = 0
	position_mt = Vector2i.ZERO
	heading = 0
	health = 1000
	energy = 1000
	inventory_material = 0
	deposited_material = 0
	gather_progress = 0
	build_progress = 0
	active_interaction = "none"
	animation_state = "idle"
	invalid_windows = 0
	command_attempts = 0
	command_successes = 0
	damage_taken = 0
	travelled_distance_mt = 0
	terminal = {"ended": false, "outcome": "running", "reason": "in_progress"}
	previous_receipt = null
	events = []
	replay_windows = []
	station_results = {}
	event_sequence = 0
	return errors


func step_window(action: Variant, fallback_ticks: int = 1, no_input_reason: String = "invalid") -> Dictionary:
	assert(not episode_id.is_empty(), "configure before stepping")
	if terminal.ended:
		return _result([])
	var validation_errors := _validate_action(action)
	var accepted := validation_errors.is_empty()
	var duration := clampi(fallback_ticks, 1, 20)
	var control := _neutral_control(duration)
	if accepted:
		control = action.control.duplicate(true)
		duration = control.duration_ticks
		command_attempts += 1
	else:
		invalid_windows += 1
	var start_tick := tick
	var start_station := station_index
	var start_damage := damage_taken
	var start_distance := travelled_distance_mt
	var window_events: Array[Dictionary] = []
	var codes := PackedStringArray()
	for local_tick: int in duration:
		if terminal.ended:
			break
		tick += 1
		_apply_station_tick(control, local_tick == 0, window_events, codes)
		if tick >= maximum_episode_ticks and not terminal.ended:
			terminal = {"ended": true, "outcome": "failure", "reason": "time_limit"}
			_emit(window_events, "course_time_limit", {})
	if accepted and station_index > start_station:
		command_successes += 1
	if not accepted:
		codes = PackedStringArray(["invalid_action", "no_input"])
	elif codes.is_empty():
		codes.append("station_waiting")
	previous_receipt = {
		"action_id": action.action_id if accepted else "no_input_%d" % observation_seq,
		"observation_seq": observation_seq,
		"accepted": accepted,
		"disposition": "accepted" if accepted else "no_input",
		"fallback": "none" if accepted else "neutral",
		"no_input_reason": null if accepted else no_input_reason if no_input_reason in ["missing", "invalid", "timeout", "stale_observation"] else "invalid",
		"start_tick": start_tick,
		"end_tick": tick,
		"applied_ticks": tick - start_tick,
		"codes": Array(codes),
		"effects": [
			{"kind": "stations_completed", "value": station_index - start_station},
			{"kind": "damage_taken", "value": damage_taken - start_damage},
			{"kind": "travelled_distance_mt", "value": travelled_distance_mt - start_distance},
		],
	}
	observation_seq += 1
	var replay_action: Dictionary = action.duplicate(true) if accepted else {
		"protocol_version": CourseMap.PROTOCOL_VERSION,
		"episode_id": episode_id,
		"observation_seq": observation_seq - 1,
		"action_id": previous_receipt.action_id,
		"control": control,
		"intent_label": "",
		"memory_update": "",
	}
	replay_windows.append({
		"start_tick": start_tick,
		"end_tick": tick,
		"action": replay_action,
		"receipt": previous_receipt.duplicate(true),
		"events": window_events.duplicate(true),
		"checkpoint_hash": checkpoint_hash(),
	})
	return _result(window_events)


func observe() -> Dictionary:
	var visible_entities: Array[Dictionary] = []
	if not terminal.ended:
		visible_entities.append({
			"id": CourseMap.visible_id(station_index),
			"kind": "control_station",
			"bearing": "front",
			"distance": "touching" if station_index not in [0, 3, 6] else "near",
			"affordances": [CourseMap.station_affordance(station_index)],
			"state": _station_visible_state(),
		})
	var status: Array[String] = [animation_state]
	if active_interaction != "none":
		status.append("interaction_active")
	return {
		"protocol_version": CourseMap.PROTOCOL_VERSION,
		"episode_id": episode_id,
		"observation_seq": observation_seq,
		"tick": tick,
		"profile": "text-visible-v1",
		"goal": "Complete each visible controller-action station in order.",
		"remaining_ticks": maxi(0, maximum_episode_ticks - tick),
		"self": {
			"health_percent": health / 10,
			"energy_percent": energy / 10,
			"facing": HEADINGS[heading],
			"contact": "clear",
			"inventory": [] if inventory_material == 0 else [{"kind": "material", "count": inventory_material, "selected": true}],
			"status": status,
		},
		"visible_entities": visible_entities,
		"recent_events": events.slice(maxi(0, events.size() - 16)),
		"memory": "",
		"previous_receipt": previous_receipt,
		"terminal": terminal.duplicate(true),
	}


func checkpoint() -> Dictionary:
	return {
		"protocol_version": CourseMap.PROTOCOL_VERSION,
		"task_id": CourseMap.TASK_ID,
		"episode_id": episode_id,
		"seed": seed,
		"tick": tick,
		"observation_seq": observation_seq,
		"station_index": station_index,
		"position_mt": {"x": position_mt.x, "y": position_mt.y},
		"heading": heading,
		"health": health,
		"energy": energy,
		"inventory_material": inventory_material,
		"deposited_material": deposited_material,
		"gather_progress": gather_progress,
		"build_progress": build_progress,
		"active_interaction": active_interaction,
		"animation_state": animation_state,
		"invalid_windows": invalid_windows,
		"command_attempts": command_attempts,
		"command_successes": command_successes,
		"damage_taken": damage_taken,
		"travelled_distance_mt": travelled_distance_mt,
		"station_results": station_results.duplicate(true),
		"terminal": terminal.duplicate(true),
	}


func checkpoint_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(checkpoint())


func replay() -> Dictionary:
	return {
		"protocol_version": CourseMap.PROTOCOL_VERSION,
		"task_id": CourseMap.TASK_ID,
		"episode_id": episode_id,
		"participant_ids": [participant_id],
		"windows": replay_windows.duplicate(true),
		"final_checkpoint_hash": checkpoint_hash(),
		"final_terminal": terminal.duplicate(true),
		"authority_aggregates": authority_aggregates(),
	}


func authority_aggregates() -> Dictionary:
	var station_passes := {}
	for station: Dictionary in CourseMap.STATIONS:
		station_passes[station.id] = station_results.has(station.id)
	return {
		"stations_completed": station_index,
		"stations_total": CourseMap.STATIONS.size(),
		"station_passes": station_passes,
		"command_attempts": command_attempts,
		"command_successes": command_successes,
		"invalid_windows": invalid_windows,
		"damage_taken": damage_taken,
		"travelled_distance_mt": travelled_distance_mt,
		"terminal_outcome": terminal.outcome,
		"terminal_reason": terminal.reason,
	}


func participant_presentation_source(requested_participant_id: String) -> Dictionary:
	if requested_participant_id != participant_id:
		return {}
	var visible_entities: Array[Dictionary] = []
	if not terminal.ended:
		visible_entities.append({
			"id": CourseMap.visible_id(station_index),
			"kind": "control_station",
		})
	return {
		"participant_id": participant_id,
		"operator": {
			"position_mt": {"x": position_mt.x, "y": position_mt.y},
			"heading": heading,
			"animation_state": animation_state,
		},
		"visible_entities": visible_entities,
	}


func _apply_station_tick(control: Dictionary, first_tick: bool, window_events: Array[Dictionary], codes: PackedStringArray) -> void:
	animation_state = "idle"
	var station_id := CourseMap.station_id(station_index)
	match station_id:
		"walk":
			if control.move_y == 1000 and control.move_x == 0:
				position_mt += FORWARD_MT[heading]
				travelled_distance_mt += 1000
				animation_state = "walk"
				_emit(window_events, "course_walked", {"distance_mt": 1000})
				_complete_station(window_events, codes)
		"turn":
			if first_tick and control.look_x != 0:
				heading = posmod(heading + (1 if control.look_x > 0 else -1), 8)
				animation_state = "turn"
				_emit(window_events, "course_turned", {"facing": HEADINGS[heading]})
				_complete_station(window_events, codes)
		"gather":
			if control.buttons.interact:
				animation_state = "gather"
				gather_progress += 1
				active_interaction = "course_gather"
				_emit(window_events, "course_gather_progressed", {"progress": gather_progress})
				if gather_progress >= 2:
					inventory_material = 1
					active_interaction = "none"
					_emit(window_events, "course_material_gathered", {"inventory_units": 1})
					_complete_station(window_events, codes)
		"carry":
			if inventory_material == 1 and control.move_y == 1000:
				position_mt += FORWARD_MT[heading]
				travelled_distance_mt += 1000
				animation_state = "walk"
				_emit(window_events, "course_material_carried", {"distance_mt": 1000})
				_complete_station(window_events, codes)
		"deposit":
			if inventory_material == 1 and control.buttons.interact:
				inventory_material = 0
				deposited_material = 1
				animation_state = "gather"
				_emit(window_events, "course_material_deposited", {"deposited_units": 1})
				_complete_station(window_events, codes)
		"build":
			if deposited_material == 1 and control.buttons.interact:
				animation_state = "build"
				build_progress += 1
				active_interaction = "course_build"
				_emit(window_events, "course_build_progressed", {"progress": build_progress})
				if build_progress >= 2:
					deposited_material = 0
					active_interaction = "none"
					_emit(window_events, "course_barricade_built", {})
					_complete_station(window_events, codes)
		"dash":
			if first_tick and control.buttons.dash and energy >= 200:
				energy -= 200
				position_mt += FORWARD_MT[heading] * 2
				travelled_distance_mt += 2000
				animation_state = "dash"
				_emit(window_events, "course_dash_performed", {"energy_spent": 200})
				_complete_station(window_events, codes)
		"guard":
			if control.buttons.guard:
				animation_state = "guard"
				_emit(window_events, "course_guard_held", {})
				_complete_station(window_events, codes)
		"primary":
			if control.buttons.primary:
				animation_state = "attack"
				_emit(window_events, "course_primary_strike", {"practice_damage": 1})
				_complete_station(window_events, codes)
		"cancel":
			if first_tick and control.buttons.cancel and active_interaction == "course_cancel_hold":
				active_interaction = "none"
				gather_progress = 0
				_emit(window_events, "course_interaction_cancelled", {"interaction": "course_cancel_hold"})
				_complete_station(window_events, codes)
			elif control.buttons.interact:
				active_interaction = "course_cancel_hold"
				gather_progress = 1
				animation_state = "gather"
				_emit(window_events, "course_cancel_hold_started", {"interaction": "course_cancel_hold"})
		"hazard":
			# Damage is produced by the deterministic authority hazard, never by an animation command.
			health = maxi(0, health - 200)
			damage_taken += 200
			animation_state = "hit"
			_emit(window_events, "course_hazard_damage", {"damage": 200, "health_remaining": health})
			_complete_station(window_events, codes)
		"celebrate":
			if first_tick and control.buttons.ability_1:
				animation_state = "celebrate"
				_emit(window_events, "course_success_celebration", {})
				_complete_station(window_events, codes)
				terminal = {"ended": true, "outcome": "success", "reason": "course_complete"}


func _complete_station(window_events: Array[Dictionary], codes: PackedStringArray) -> void:
	var station_id := CourseMap.station_id(station_index)
	station_results[station_id] = {"completion_tick": tick, "animation_state": animation_state}
	_emit(window_events, "course_station_completed", {"station_id": station_id, "order": station_index + 1})
	if "station_completed" not in codes:
		codes.append("station_completed")
	station_index += 1


func _station_visible_state() -> String:
	var station_id := CourseMap.station_id(station_index)
	if station_id == "gather" and gather_progress > 0:
		return "gather_in_progress"
	if station_id == "build" and build_progress > 0:
		return "build_in_progress"
	if station_id == "cancel" and active_interaction == "course_cancel_hold":
		return "hold_active"
	if station_id == "hazard":
		return "hazard_armed"
	return "awaiting_input"


func _validate_action(action: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not action is Dictionary:
		errors.append("action must be an object")
		return errors
	var required := ["protocol_version", "episode_id", "observation_seq", "action_id", "control", "intent_label", "memory_update"]
	if action.keys().size() != required.size() or required.any(func(key: String) -> bool: return not action.has(key)):
		errors.append("action fields are invalid")
		return errors
	if not action.protocol_version is String or action.protocol_version != CourseMap.PROTOCOL_VERSION \
		or not action.episode_id is String or action.episode_id != episode_id \
		or not action.observation_seq is int or action.observation_seq != observation_seq:
		errors.append("action boundary is stale or mismatched")
	if not _valid_action_id(action.action_id):
		errors.append("action_id is invalid")
	if not action.intent_label is String or action.intent_label.length() > 160 \
		or not action.memory_update is String or action.memory_update.to_utf8_buffer().size() > 2048:
		errors.append("action text is invalid")
	if not action.control is Dictionary:
		errors.append("control must be an object")
		return errors
	var control: Dictionary = action.control
	var control_required := ["move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons"]
	if control.keys().size() != control_required.size() or control_required.any(func(key: String) -> bool: return not control.has(key)):
		errors.append("control fields are invalid")
		return errors
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if not control[axis] is int or abs(control[axis]) > 1000:
			errors.append("control axis is invalid")
	if not control.duration_ticks is int or control.duration_ticks < 1 or control.duration_ticks > 20:
		errors.append("duration_ticks is invalid")
	if not control.buttons is Dictionary or control.buttons.keys().size() != BUTTONS.size():
		errors.append("buttons are invalid")
	else:
		for button: String in BUTTONS:
			if not control.buttons.has(button) or not control.buttons[button] is bool:
				errors.append("button is invalid")
	return errors


func _neutral_control(duration: int) -> Dictionary:
	var buttons := {}
	for button: String in BUTTONS:
		buttons[button] = false
	return {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0, "duration_ticks": duration, "buttons": buttons}


func _emit(window_events: Array[Dictionary], kind: String, data: Dictionary) -> void:
	event_sequence += 1
	var event := {
		"event_id": "evt_course_%08d" % event_sequence,
		"tick": tick,
		"kind": kind,
		"summary": _summary(kind),
		"participant_ids": [participant_id],
		"data": data,
	}
	window_events.append(event)
	events.append(event)


func _summary(kind: String) -> String:
	return kind.replace("_", " ").capitalize() + "."


func _result(window_events: Array[Dictionary]) -> Dictionary:
	return {
		"observations": {participant_id: observe()},
		"receipts": {participant_id: previous_receipt},
		"public_events": window_events,
		"state_hash": checkpoint_hash(),
		"terminal": terminal.duplicate(true),
	}


func _valid_episode_id(value: Variant) -> bool:
	if not value is String or value.length() < 4 or value.length() > 123 or not value.begins_with("ep_"):
		return false
	for index: int in range(3, value.length()):
		var code: int = value.unicode_at(index)
		if not (_is_ascii_alphanumeric(code) or code in [46, 95, 45]):
			return false
	return true


func _valid_action_id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 64 or not _is_ascii_alphanumeric(value.unicode_at(0)):
		return false
	for index: int in value.length():
		var code: int = value.unicode_at(index)
		if not (_is_ascii_alphanumeric(code) or code in [46, 95, 45]):
			return false
	return true


func _is_ascii_alphanumeric(code: int) -> bool:
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
