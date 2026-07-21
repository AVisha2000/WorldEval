extends SceneTree

const MazeAuthority := preload("res://scripts/embodiment/control_games/movement_maze_authority.gd")
const MazeMap := preload("res://scripts/embodiment/control_games/movement_maze_map.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_configuration_is_v2_only()
	_test_visible_observation_has_no_coordinates_or_hidden_route()
	_test_invalid_and_collision_advance_without_motion()
	_test_future_checkpoint_is_not_credited()
	_test_ordered_course_and_terminal_beacon()
	_test_replay_and_checkpoint_determinism()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("MOVEMENT_MAZE_V2_FAILURE: %s" % failure)
		print("MOVEMENT_MAZE_V2_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("MOVEMENT_MAZE_V2_OK")
	quit(0)


func _authority():
	var authority := MazeAuthority.new()
	var errors := authority.configure({
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"task_id": MazeMap.TASK_ID,
		"episode_id": "ep_movement_maze",
		"participant_id": "participant_0",
		"maximum_episode_ticks": 200,
	})
	_check(errors.is_empty(), "valid v2 configuration failed: %s" % str(errors))
	return authority


func _test_configuration_is_v2_only() -> void:
	var authority := MazeAuthority.new()
	var errors := authority.configure({
		"protocol_version": "llm-controller/0.1.0",
		"task_id": MazeMap.TASK_ID,
		"episode_id": "ep_wrong_version",
	})
	_check(not errors.is_empty(), "legacy protocol unexpectedly launched a v2 game")


func _test_visible_observation_has_no_coordinates_or_hidden_route() -> void:
	var authority = _authority()
	var observation_text := JSON.stringify(authority.observe())
	for forbidden: String in ["position", "coordinate", "shortest", "route", "LEGAL_TILES", "BEACON_TILE"]:
		_check(forbidden not in observation_text, "observation leaked %s" % forbidden)
	_check(authority.observe().visible_entities.size() == 1, "observation exposed non-current checkpoints")
	_check(authority.observe().visible_entities[0].id == "v_checkpoint_1", "wrong current checkpoint visible")


func _test_invalid_and_collision_advance_without_motion() -> void:
	var authority = _authority()
	var start: Vector2i = authority.position_mt
	var invalid := _action(authority, {"move_y": 1000})
	invalid.control.move_y = 1.0
	var invalid_result: Dictionary = authority.step_window(invalid, 3)
	_check(authority.tick == 3, "invalid action stalled authority time")
	_check(authority.position_mt == start, "invalid action moved the operator")
	_check(invalid_result.receipts.participant_0.disposition == "no_input", "invalid action lacked neutral receipt")
	var collision_result: Dictionary = authority.step_window(_action(authority, {"move_x": -1000}))
	_check(authority.tick == 4, "collision did not advance one authority tick")
	_check(authority.position_mt == start, "wall collision crossed the maze boundary")
	_check(authority.collision_count == 1, "wall collision was not counted")
	_check(collision_result.public_events[0].kind == "maze_movement_blocked", "collision event missing")


func _test_ordered_course_and_terminal_beacon() -> void:
	var authority = _authority()
	_run_course(authority)
	_check(authority.terminal == {"ended": true, "outcome": "success", "reason": "final_beacon"}, "final beacon did not terminate successfully")
	_check(authority.checkpoint_index == 4, "not all ordered checkpoints were credited")
	_check(authority.order_violation_count == 0, "inactive future checkpoint was treated as current")
	_check(authority.travelled_distance_mt == MazeMap.shortest_legal_route_mt(), "route distance drifted")
	_check(authority.facing_corrections == 8, "facing corrections drifted")
	var checkpoint_events: Array = authority.events.filter(func(event: Dictionary) -> bool: return event.kind == "maze_checkpoint_reached")
	_check(checkpoint_events.map(func(event: Dictionary) -> Variant: return event.data.order) == [1, 2, 3, 4], "checkpoint receipts were out of order")
	var result: Dictionary = authority.replay().windows[0]
	_check(result.receipt.keys().size() == 11, "receipt shape drifted from protocol v2")
	_check(authority.events.all(func(event: Dictionary) -> bool: return event.keys().size() == 6), "event shape drifted from protocol v2")
	var observation: Dictionary = authority.observe()
	_check(observation.keys().size() == 13, "text observation shape drifted from protocol v2")


func _test_future_checkpoint_is_not_credited() -> void:
	var authority = _authority()
	# Cross checkpoint 4 from spawn before checkpoint 1. The violation must be recorded on entry
	# without exposing which future marker was crossed or crediting it.
	_turn(authority, 1, 2)
	_move(authority, 2)
	var result: Dictionary = authority.replay().windows[-1]
	_check(authority.checkpoint_index == 0, "future checkpoint bypassed ordered progression")
	_check(authority.observe().visible_entities[0].id == "v_checkpoint_1", "future marker replaced the ordered visible target")
	_check(authority.order_violation_count == 1, "future checkpoint crossing was not counted")
	_check(result.events.size() == 1 and result.events[0].kind == "maze_checkpoint_out_of_order", "future crossing event missing")
	_check(result.events[0].data == {"violations": 1}, "future crossing event leaked marker identity")
	authority.step_window(_action(authority))
	_check(authority.order_violation_count == 1, "stationary operator repeated one crossing violation")
	_check(authority.authority_aggregates().checkpoint_order_valid == false, "order violation remained marked valid")


func _test_replay_and_checkpoint_determinism() -> void:
	var first = _authority()
	var second = _authority()
	_run_course(first)
	_run_course(second)
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "repeat checkpoint hashes diverged")
	_check(first.replay() == second.replay(), "repeat replay evidence diverged")
	_check(not first.replay().authority_aggregates.has("position_mt"), "public aggregate leaked coordinates")


func _run_course(authority: Object) -> void:
	_move(authority, 4)
	_turn(authority, 1, 2)
	_move(authority, 4)
	_turn(authority, 1, 2)
	_move(authority, 2)
	_move(authority, 2)
	_turn(authority, 1, 2)
	_move(authority, 2)
	_turn(authority, 1, 2)
	_move(authority, 2)


func _move(authority: Object, count: int) -> void:
	for index: int in count:
		authority.step_window(_action(authority, {"move_y": 1000}, "move_%d_%d" % [authority.observation_seq, index]))


func _turn(authority: Object, direction: int, count: int) -> void:
	for index: int in count:
		authority.step_window(_action(authority, {"look_x": direction * 1000}, "turn_%d_%d" % [authority.observation_seq, index]))


func _action(authority: Object, values: Dictionary = {}, action_id: String = "maze_action") -> Dictionary:
	var buttons := {}
	for button: String in MazeAuthority.BUTTONS:
		buttons[button] = false
	var control := {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0, "duration_ticks": 1, "buttons": buttons}
	for key: String in values:
		control[key] = values[key]
	return {
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": action_id,
		"control": control,
		"intent_label": "Navigate the next visible marker",
		"memory_update": "",
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
