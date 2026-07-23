class_name EmbodimentMovementMazeAuthorityV2
extends RefCounted

const MazeMap := preload("res://scripts/embodiment/control_games/movement_maze_map.gd")
const CheckpointSerializer := preload("res://scripts/embodiment/authority/checkpoint_serializer.gd")
const HEADINGS := ["north", "north_east", "east", "south_east", "south", "south_west", "west", "north_west"]
const FORWARD_TILES := [
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
	Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
]
const BUTTONS := ["interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel"]

var episode_id := ""
var participant_id := "participant_0"
var maximum_episode_ticks := 600
var seed := 0
var tick := 0
var observation_seq := 0
var position_mt := Vector2i.ZERO
var heading := 0
var checkpoint_index := 0
var collision_count := 0
var facing_corrections := 0
var order_violation_count := 0
var invalid_windows := 0
var travelled_distance_mt := 0
var terminal := {"ended": false, "outcome": "running", "reason": "in_progress"}
var previous_receipt: Variant = null
var events: Array[Dictionary] = []
var replay_windows: Array[Dictionary] = []
var event_sequence := 0
var last_window_collisions := 0


func configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if config.get("protocol_version") != MazeMap.PROTOCOL_VERSION:
		errors.append("protocol_version must be llm-controller/0.2.0")
	if config.get("task_id") != MazeMap.TASK_ID:
		errors.append("task_id must be movement-maze-v0")
	if not _valid_episode_id(config.get("episode_id")):
		errors.append("episode_id must be an ep_ identifier")
	if config.get("participant_id", "participant_0") != "participant_0":
		errors.append("movement maze requires participant_0")
	var max_ticks: Variant = config.get("maximum_episode_ticks", 600)
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
	position_mt = MazeMap.start_position_mt()
	heading = 0
	checkpoint_index = 0
	collision_count = 0
	facing_corrections = 0
	order_violation_count = 0
	invalid_windows = 0
	travelled_distance_mt = 0
	terminal = {"ended": false, "outcome": "running", "reason": "in_progress"}
	previous_receipt = null
	events = []
	replay_windows = []
	event_sequence = 0
	last_window_collisions = 0
	return errors


func step_window(action: Variant, fallback_ticks: int = 1, no_input_reason: String = "invalid") -> Dictionary:
	assert(not episode_id.is_empty(), "configure before stepping")
	if terminal.ended:
		return _result([])
	var errors := _validate_action(action)
	var accepted := errors.is_empty()
	var duration := clampi(fallback_ticks, 1, 20)
	var control := _neutral_control(duration)
	if accepted:
		control = action.control.duplicate(true)
		duration = int(control.duration_ticks)
	else:
		invalid_windows += 1
	var window_events: Array[Dictionary] = []
	var start_tick := tick
	var start_distance := travelled_distance_mt
	var start_collisions := collision_count
	var start_corrections := facing_corrections
	for local_tick: int in duration:
		if terminal.ended:
			break
		tick += 1
		var moved_this_tick := _apply_control_tick(control, local_tick == 0, window_events)
		_check_progress(window_events, moved_this_tick)
		if tick >= maximum_episode_ticks and not terminal.ended:
			terminal = {"ended": true, "outcome": "failure", "reason": "time_limit"}
			_emit(window_events, "maze_time_limit", {})
	var disposition := "accepted" if accepted else "no_input"
	last_window_collisions = collision_count - start_collisions
	previous_receipt = {
		"action_id": action.action_id if accepted else "no_input_%d" % observation_seq,
		"observation_seq": observation_seq,
		"accepted": accepted,
		"disposition": disposition,
		"fallback": "none" if accepted else "neutral",
		"no_input_reason": null if accepted else no_input_reason if no_input_reason in ["missing", "invalid", "timeout", "stale_observation"] else "invalid",
		"start_tick": start_tick,
		"end_tick": tick,
		"applied_ticks": tick - start_tick,
		"codes": [] if accepted else ["invalid_action", "no_input"],
		"effects": [
			{"kind": "travelled_distance_mt", "value": travelled_distance_mt - start_distance},
			{"kind": "collisions", "value": last_window_collisions},
			{"kind": "facing_corrections", "value": facing_corrections - start_corrections},
			{"kind": "checkpoint_index", "value": checkpoint_index},
		],
	}
	observation_seq += 1
	var replay_action: Dictionary = action.duplicate(true) if accepted else {
		"protocol_version": MazeMap.PROTOCOL_VERSION,
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
	var target := MazeMap.target_position_mt(checkpoint_index)
	return {
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"episode_id": episode_id,
		"observation_seq": observation_seq,
		"tick": tick,
		"profile": "text-visible-v1",
		"goal": "Reach each visible checkpoint in order, then the final beacon.",
		"remaining_ticks": maxi(0, maximum_episode_ticks - tick),
		"self": {
			"health_percent": 100,
			"energy_percent": 100,
			"facing": HEADINGS[heading],
			"contact": "blocked_front" if last_window_collisions > 0 else "clear",
			"inventory": [],
			"status": [],
		},
		"visible_entities": [{
			"id": MazeMap.target_visible_id(checkpoint_index),
			"kind": MazeMap.target_kind(checkpoint_index),
			"bearing": _bearing_to(target),
			"distance": _distance_band(target),
			"affordances": ["approach"],
			"state": "next_in_order",
		}],
		"recent_events": events.slice(maxi(0, events.size() - 16)),
		"memory": "",
		"previous_receipt": previous_receipt,
		"terminal": terminal.duplicate(true),
	}


func checkpoint() -> Dictionary:
	return {
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"task_id": MazeMap.TASK_ID,
		"episode_id": episode_id,
		"seed": seed,
		"tick": tick,
		"observation_seq": observation_seq,
		"position_mt": {"x": position_mt.x, "y": position_mt.y},
		"heading": heading,
		"checkpoint_index": checkpoint_index,
		"collision_count": collision_count,
		"facing_corrections": facing_corrections,
		"order_violation_count": order_violation_count,
		"invalid_windows": invalid_windows,
		"travelled_distance_mt": travelled_distance_mt,
		"terminal": terminal.duplicate(true),
	}


func checkpoint_hash() -> String:
	return CheckpointSerializer.hash_checkpoint(checkpoint())


func replay() -> Dictionary:
	return {
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"task_id": MazeMap.TASK_ID,
		"episode_id": episode_id,
		"participant_ids": [participant_id],
		"windows": replay_windows.duplicate(true),
		"final_checkpoint_hash": checkpoint_hash(),
		"final_terminal": terminal.duplicate(true),
		"authority_aggregates": authority_aggregates(),
	}


func authority_aggregates() -> Dictionary:
	return {
		"completion_tick": tick if terminal.outcome == "success" else null,
		"checkpoint_count": checkpoint_index,
		"checkpoint_total": MazeMap.CHECKPOINT_TILES.size(),
		"checkpoint_order_valid": checkpoint_index == MazeMap.CHECKPOINT_TILES.size() \
			and order_violation_count == 0,
		"order_violation_count": order_violation_count,
		"collision_count": collision_count,
		"facing_corrections": facing_corrections,
		"invalid_windows": invalid_windows,
		"travelled_distance_mt": travelled_distance_mt,
		"terminal_outcome": terminal.outcome,
		"terminal_reason": terminal.reason,
	}


func participant_presentation_source(requested_participant_id: String) -> Dictionary:
	if requested_participant_id != participant_id:
		return {}
	var target := MazeMap.target_position_mt(checkpoint_index)
	return {
		"participant_id": participant_id,
		"operator": {"position_mt": {"x": position_mt.x, "y": position_mt.y}, "heading": heading},
		"visible_entities": [{
			"id": MazeMap.target_visible_id(checkpoint_index),
			"kind": MazeMap.target_kind(checkpoint_index),
			"position_mt": {"x": target.x, "y": target.y},
		}],
	}


func _validate_action(action: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not action is Dictionary:
		errors.append("action must be an object")
		return errors
	var required := ["protocol_version", "episode_id", "observation_seq", "action_id", "control", "intent_label", "memory_update"]
	if action.keys().size() != required.size() or required.any(func(key: String) -> bool: return not action.has(key)):
		errors.append("action fields are invalid")
		return errors
	if not action.protocol_version is String or action.protocol_version != MazeMap.PROTOCOL_VERSION \
		or not action.episode_id is String or action.episode_id != episode_id \
		or not action.observation_seq is int or action.observation_seq != observation_seq:
		errors.append("action boundary is stale or mismatched")
	if not _valid_action_id(action.action_id):
		errors.append("action_id is invalid")
	if not action.intent_label is String or action.intent_label.length() > 160 or not action.memory_update is String or action.memory_update.to_utf8_buffer().size() > 2048:
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
		if not control[axis] is int or abs(int(control[axis])) > 1000:
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


func _apply_control_tick(control: Dictionary, first_tick: bool, window_events: Array[Dictionary]) -> bool:
	if first_tick and int(control.look_x) != 0:
		var previous_heading := heading
		heading = posmod(heading + (1 if int(control.look_x) > 0 else -1), 8)
		facing_corrections += 1
		_emit(window_events, "maze_facing_corrected", {"from": HEADINGS[previous_heading], "to": HEADINGS[heading]})
	var local := Vector2i(int(control.move_x), -int(control.move_y))
	if local == Vector2i.ZERO:
		return false
	# Maze motion is deliberately tile-locked. Direct controls must ask for one full cardinal step;
	# diagonal or analogue drift is a collision/no-move, which makes mapping regressions obvious.
	if (abs(local.x) == 1000 and local.y == 0) or (local.x == 0 and abs(local.y) == 1000):
		var forward: Vector2i = FORWARD_TILES[heading]
		var right: Vector2i = FORWARD_TILES[posmod(heading + 2, 8)]
		var delta := right * signi(local.x) + forward * -signi(local.y)
		if abs(delta.x) + abs(delta.y) != 1:
			_record_collision(window_events)
			return false
		var candidate := position_mt + delta * MazeMap.TILE_MT
		if MazeMap.is_legal_position_mt(candidate):
			position_mt = candidate
			travelled_distance_mt += MazeMap.TILE_MT
			return true
		else:
			_record_collision(window_events)
	else:
		_record_collision(window_events)
	return false


func _check_progress(window_events: Array[Dictionary], moved_this_tick: bool) -> void:
	if checkpoint_index < MazeMap.CHECKPOINT_TILES.size() and position_mt == MazeMap.checkpoint_position_mt(checkpoint_index):
		checkpoint_index += 1
		_emit(window_events, "maze_checkpoint_reached", {"checkpoint_id": "checkpoint_%d" % checkpoint_index, "order": checkpoint_index})
	elif checkpoint_index == MazeMap.CHECKPOINT_TILES.size() and position_mt == MazeMap.beacon_position_mt():
		terminal = {"ended": true, "outcome": "success", "reason": "final_beacon"}
		_emit(window_events, "maze_final_beacon_reached", {"checkpoints_reached": checkpoint_index})
	elif moved_this_tick and _is_future_checkpoint(position_mt):
		order_violation_count += 1
		# Future marker identity and order remain hidden. The participant learns only the visible
		# physical consequence that an out-of-order checkpoint crossing was rejected.
		_emit(window_events, "maze_checkpoint_out_of_order", {"violations": order_violation_count})


func _is_future_checkpoint(candidate_mt: Vector2i) -> bool:
	for future_index: int in range(checkpoint_index + 1, MazeMap.CHECKPOINT_TILES.size()):
		if candidate_mt == MazeMap.checkpoint_position_mt(future_index):
			return true
	return false


func _record_collision(window_events: Array[Dictionary]) -> void:
	collision_count += 1
	_emit(window_events, "maze_movement_blocked", {"contact": "blocked_front"})


func _emit(window_events: Array[Dictionary], kind: String, data: Dictionary) -> void:
	event_sequence += 1
	var event := {
		"event_id": "evt_maze_%08d" % event_sequence,
		"tick": tick,
		"kind": kind,
		"summary": _event_summary(kind),
		"participant_ids": [participant_id],
		"data": data,
	}
	window_events.append(event)
	events.append(event)


func _bearing_to(target_mt: Vector2i) -> String:
	var delta := target_mt - position_mt
	var absolute_heading := 0
	if abs(delta.x) > abs(delta.y):
		absolute_heading = 2 if delta.x > 0 else 6
	elif delta.y != 0:
		absolute_heading = 4 if delta.y > 0 else 0
	var relative := posmod(absolute_heading - heading, 8)
	return ["front", "front_right", "right", "back_right", "back", "back_left", "left", "front_left"][relative]


func _distance_band(target_mt: Vector2i) -> String:
	var distance: int = abs(target_mt.x - position_mt.x) + abs(target_mt.y - position_mt.y)
	if distance == 0:
		return "touching"
	if distance <= 2000:
		return "near"
	if distance <= 4000:
		return "medium"
	return "far"


func _neutral_control(duration: int) -> Dictionary:
	var buttons := {}
	for button: String in BUTTONS:
		buttons[button] = false
	return {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0, "duration_ticks": duration, "buttons": buttons}


func _result(window_events: Array[Dictionary]) -> Dictionary:
	return {
		"observations": {participant_id: observe()},
		"receipts": {participant_id: previous_receipt},
		"public_events": window_events,
		"terminal": terminal.duplicate(true),
		"state_hash": checkpoint_hash(),
	}


func _event_summary(kind: String) -> String:
	match kind:
		"maze_checkpoint_reached":
			return "The operator reached the next checkpoint."
		"maze_checkpoint_out_of_order":
			return "A visible checkpoint was crossed before its turn."
		"maze_final_beacon_reached":
			return "The operator reached the final beacon."
		"maze_movement_blocked":
			return "The operator's movement was blocked."
		"maze_facing_corrected":
			return "The operator corrected its facing."
		"maze_time_limit":
			return "The movement-maze time limit was reached."
		_:
			return "A visible maze event occurred."


func _valid_episode_id(value: Variant) -> bool:
	if not value is String or value.length() < 4 or value.length() > 123 or not value.begins_with("ep_"):
		return false
	for index: int in range(3, value.length()):
		var code: int = value.unicode_at(index)
		if not (_is_ascii_alphanumeric(code) or code in [46, 95, 45]):
			return false
	return true


func _valid_action_id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 64:
		return false
	if not _is_ascii_alphanumeric(value.unicode_at(0)):
		return false
	for index: int in value.length():
		var code: int = value.unicode_at(index)
		if not (_is_ascii_alphanumeric(code) or code in [46, 95, 45]):
			return false
	return true


func _is_ascii_alphanumeric(code: int) -> bool:
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
