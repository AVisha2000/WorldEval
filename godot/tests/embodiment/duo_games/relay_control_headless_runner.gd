extends SceneTree

const Authority := preload("res://scripts/embodiment/duo_games/relay_control_authority.gd")

var failures := PackedStringArray()


func _init() -> void:
	_test_no_attacks_and_independent_fallback()
	_test_relay_hold_and_seat_symmetry()
	_test_contested_time_limit_draw()
	_test_dictionary_order_replay_hash()
	_finish()


func _authority():
	var authority := Authority.new()
	var errors := authority.configure({"protocol_version": "llm-controller/0.2.0",
		"task_id": "duo-relay-control-v0", "episode_id": "ep_duo_relay_test",
		"participant_ids": ["participant_0", "participant_1"], "maximum_episode_ticks": 1200})
	_check(errors.is_empty(), "configuration failed: %s" % str(errors))
	return authority


func _test_no_attacks_and_independent_fallback() -> void:
	var authority = _authority()
	var invalid := _action(authority, "participant_0", {"move_y": 1000})
	invalid.control.move_y = 1.0
	var result := authority.step_window(_window(authority, invalid,
		_action(authority, "participant_1", {"move_y": 1000, "primary": true})))
	_check(not result.receipts.participant_0.accepted, "strict-type invalid action was accepted")
	_check(result.receipts.participant_1.accepted, "valid rival was rejected")
	_check(authority.tick == 10, "invalid seat stalled common time")
	_check(authority.operators.participant_0.position_mt == Vector2i(0, 6000), "neutral seat moved")
	_check(authority.operators.participant_1.position_mt == Vector2i(0, -4000), "valid rival did not move")
	_check(authority.operators.participant_0.health == 1000, "relay control enabled attack damage")


func _test_relay_hold_and_seat_symmetry() -> void:
	var first = _authority()
	first.operators.participant_0.position_mt = Vector2i.ZERO
	for index: int in 6:
		first.step_window(_window(first, _action(first, "participant_0", {}, "hold_%d" % index),
			_action(first, "participant_1", {}, "away_%d" % index)))
	_check(first.terminal.outcome == "win" and first.terminal.reason == "hold_target" \
		and first.winner_id == "participant_0",
		"seat 0 relay hold did not win at 60 ticks")
	_check(first.tick == 60, "relay hold terminal tick drifted")
	var second = _authority()
	second.operators.participant_1.position_mt = Vector2i.ZERO
	for index: int in 6:
		second.step_window(_window(second, _action(second, "participant_0", {}, "away_%d" % index),
			_action(second, "participant_1", {}, "hold_%d" % index)))
	_check(second.terminal.outcome == "win" and second.winner_id == "participant_1",
		"seat-swapped relay hold did not mirror winner")
	_check(first.authority_aggregates().participants.participant_0.relay_control_ticks \
		== second.authority_aggregates().participants.participant_1.relay_control_ticks,
		"seat-swapped relay aggregate diverged")


func _test_contested_time_limit_draw() -> void:
	var authority = _authority()
	authority.tick = 1199
	authority.operators.participant_0.position_mt = Vector2i(0, 400)
	authority.operators.participant_1.position_mt = Vector2i(0, -400)
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0"), _action(authority, "participant_1")))
	_check(result.terminal.outcome == "draw" and result.terminal.reason == "time_limit",
		"contested simultaneous time terminal did not draw")
	_check(authority.tick == 1200, "time terminal did not stop at authoritative bound")


func _test_dictionary_order_replay_hash() -> void:
	var first = _authority()
	var second = _authority()
	for index: int in 2:
		first.step_window(_window(first,
			_action(first, "participant_0", {"move_y": 250}, "repeat_%d" % index),
			_action(first, "participant_1", {"move_y": 250}, "repeat_%d" % index)))
		var decisions := {}
		decisions["participant_1"] = _decision(_action(second, "participant_1", {"move_y": 250}, "repeat_%d" % index))
		decisions["participant_0"] = _decision(_action(second, "participant_0", {"move_y": 250}, "repeat_%d" % index))
		second.step_window({"episode_id": second.episode_id, "observation_seq": second.observation_seq,
			"start_tick": second.tick, "duration_ticks": 10, "decisions": decisions})
	_check(first.replay_hash() == second.replay_hash(), "dictionary order changed relay replay hash")


func _window(authority, action_0: Dictionary, action_1: Dictionary) -> Dictionary:
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"start_tick": authority.tick, "duration_ticks": 10,
		"decisions": {"participant_0": _decision(action_0), "participant_1": _decision(action_1)}}


func _decision(action: Dictionary) -> Dictionary:
	return {"disposition": "accepted", "action": action, "fallback": "none", "no_input_reason": null}


func _action(authority, participant_id: String, overrides: Dictionary = {}, label: String = "relay") -> Dictionary:
	var buttons := {"interact": false, "primary": false, "guard": false, "dash": false,
		"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false}
	for key: String in buttons:
		buttons[key] = bool(overrides.get(key, false))
	return {"protocol_version": "llm-controller/0.2.0", "episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "%s_%s_%d" % [label, participant_id, authority.observation_seq],
		"control": {"move_x": int(overrides.get("move_x", 0)), "move_y": int(overrides.get("move_y", 0)),
			"look_x": int(overrides.get("look_x", 0)), "look_y": 0, "duration_ticks": 10, "buttons": buttons},
		"intent_label": label, "memory_update": ""}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("DUO_RELAY_CONTROL_OK")
		quit(0)
		return
	for failure: String in failures:
		push_error("DUO_RELAY_CONTROL_FAILURE: %s" % failure)
	quit(1)
