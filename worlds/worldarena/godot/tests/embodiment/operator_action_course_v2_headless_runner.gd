extends SceneTree

const CourseAuthority := preload("res://scripts/embodiment/control_games/operator_action_course_authority.gd")
const CourseMap := preload("res://scripts/embodiment/control_games/operator_action_course_map.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_v2_only_and_visible_boundary()
	_test_invalid_neutral_advancement()
	_test_control_matrix_and_real_hazard()
	_test_repeatable_replay()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("OPERATOR_ACTION_COURSE_V2_FAILURE: %s" % failure)
		print("OPERATOR_ACTION_COURSE_V2_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("OPERATOR_ACTION_COURSE_V2_OK")
	quit(0)


func _authority():
	var authority := CourseAuthority.new()
	var errors := authority.configure({
		"protocol_version": CourseMap.PROTOCOL_VERSION,
		"task_id": CourseMap.TASK_ID,
		"episode_id": "ep_operator_action_course",
		"participant_id": "participant_0",
		"maximum_episode_ticks": 100,
	})
	_check(errors.is_empty(), "valid v2 configuration failed: %s" % str(errors))
	return authority


func _test_v2_only_and_visible_boundary() -> void:
	var invalid := CourseAuthority.new()
	_check(not invalid.configure({"protocol_version": "llm-controller/0.1.0", "task_id": CourseMap.TASK_ID, "episode_id": "ep_old"}).is_empty(), "legacy protocol launched v2 course")
	var observation_text := JSON.stringify(_authority().observe())
	var observation: Dictionary = _authority().observe()
	_check(typeof(observation.self.health_percent) == TYPE_INT, "health percent was not integer authority data")
	_check(typeof(observation.self.energy_percent) == TYPE_INT, "energy percent was not integer authority data")
	for forbidden: String in ["position", "coordinate", "station_results", "damage_taken", "deposited_material"]:
		_check(forbidden not in observation_text, "participant observation leaked %s" % forbidden)


func _test_invalid_neutral_advancement() -> void:
	var authority = _authority()
	var malformed := _action(authority, {"move_y": 1000})
	malformed.control.move_y = 1.0
	var result: Dictionary = authority.step_window(malformed, 3)
	_check(authority.tick == 3, "invalid action stalled course time")
	_check(authority.station_index == 0, "neutral fallback completed a control station")
	_check(result.receipts.participant_0.disposition == "no_input", "invalid action lacked neutral receipt")
	_check(result.receipts.participant_0.applied_ticks == 3, "neutral horizon drifted")


func _test_control_matrix_and_real_hazard() -> void:
	var authority = _authority()
	var initial_position: Vector2i = authority.position_mt
	var initial_heading: int = authority.heading
	var expected_events := {
		"walk": "course_walked",
		"turn": "course_turned",
		"gather": "course_material_gathered",
		"carry": "course_material_carried",
		"deposit": "course_material_deposited",
		"build": "course_barricade_built",
		"dash": "course_dash_performed",
		"guard": "course_guard_held",
		"primary": "course_primary_strike",
		"cancel": "course_interaction_cancelled",
		"hazard": "course_hazard_damage",
		"celebrate": "course_success_celebration",
	}
	_apply_course(authority)
	_check(authority.station_results.walk.completion_tick == 1, "walk station completed on the wrong tick")
	var expected_after_walk: Vector2i = initial_position + CourseAuthority.FORWARD_MT[initial_heading]
	var turned_heading := posmod(initial_heading + 1, 8)
	var expected_final_position: Vector2i = expected_after_walk + CourseAuthority.FORWARD_MT[turned_heading] * 3
	_check(authority.position_mt == expected_final_position, "walk/carry/dash transforms disagreed with authoritative headings")
	_check(expected_after_walk == Vector2i(0, -1000), "north-facing forward transform drifted")
	_check(CourseAuthority.FORWARD_MT[turned_heading] == Vector2i(707, -707), "north-east transform drifted")
	_check(authority.heading == posmod(initial_heading + 1, 8), "turn station changed heading in the wrong direction")
	_check(authority.terminal == {"ended": true, "outcome": "success", "reason": "course_complete"}, "course did not finish successfully")
	_check(authority.station_index == CourseMap.STATIONS.size(), "control matrix left stations incomplete")
	_check(authority.station_results.size() == CourseMap.STATIONS.size(), "station results are not independently assertable")
	for station_id: String in expected_events:
		_check(authority.station_results.has(station_id), "%s station result missing" % station_id)
		_check(authority.events.any(func(event: Dictionary) -> bool: return event.kind == expected_events[station_id]), "%s authority event missing" % station_id)
	_check(authority.damage_taken == 200 and authority.health == 800, "hazard did not apply real authority damage")
	_check(authority.station_results.hazard.animation_state == "hit", "hazard did not derive hit reaction state")
	_check(authority.station_results.celebrate.animation_state == "celebrate", "success did not derive celebration")
	_check(authority.active_interaction == "none" and authority.gather_progress == 0, "cancel did not interrupt named held interaction")
	_check(authority.events.any(func(event: Dictionary) -> bool: return event.kind == "course_cancel_hold_started" and event.data.interaction == "course_cancel_hold"), "named cancel hold never started")
	_check(authority.events.all(func(event: Dictionary) -> bool: return event.keys().size() == 6), "typed event shape drifted")
	_check(authority.replay().windows.all(func(window: Dictionary) -> bool: return window.receipt.keys().size() == 11), "typed receipt shape drifted")


func _test_repeatable_replay() -> void:
	var first = _authority()
	var second = _authority()
	_apply_course(first)
	_apply_course(second)
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "course checkpoint hashes diverged")
	_check(first.replay() == second.replay(), "course replays diverged")
	var public_text := JSON.stringify(first.authority_aggregates())
	for forbidden: String in ["position", "heading", "active_interaction"]:
		_check(forbidden not in public_text, "course aggregate leaked %s" % forbidden)


func _apply_course(authority: Object) -> void:
	authority.step_window(_action(authority, {"move_y": 1000}, "walk"))
	authority.step_window(_action(authority, {"look_x": 1000}, "turn"))
	authority.step_window(_action(authority, {"interact": true}, "gather_1"))
	authority.step_window(_action(authority, {"interact": true}, "gather_2"))
	authority.step_window(_action(authority, {"move_y": 1000}, "carry"))
	authority.step_window(_action(authority, {"interact": true}, "deposit"))
	authority.step_window(_action(authority, {"interact": true}, "build_1"))
	authority.step_window(_action(authority, {"interact": true}, "build_2"))
	authority.step_window(_action(authority, {"dash": true}, "dash"))
	authority.step_window(_action(authority, {"guard": true}, "guard"))
	authority.step_window(_action(authority, {"primary": true}, "primary"))
	authority.step_window(_action(authority, {"interact": true}, "cancel_hold"))
	authority.step_window(_action(authority, {"cancel": true}, "cancel"))
	authority.step_window(_action(authority, {}, "hazard_wait"))
	authority.step_window(_action(authority, {"ability_1": true}, "celebrate"))


func _action(authority: Object, values: Dictionary = {}, action_id: String = "course_action") -> Dictionary:
	var buttons := {}
	for button: String in CourseAuthority.BUTTONS:
		buttons[button] = bool(values.get(button, false))
	var control := {
		"move_x": int(values.get("move_x", 0)),
		"move_y": int(values.get("move_y", 0)),
		"look_x": int(values.get("look_x", 0)),
		"look_y": 0,
		"duration_ticks": 1,
		"buttons": buttons,
	}
	return {
		"protocol_version": CourseMap.PROTOCOL_VERSION,
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": action_id,
		"control": control,
		"intent_label": "Complete the visible control station",
		"memory_update": "",
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
