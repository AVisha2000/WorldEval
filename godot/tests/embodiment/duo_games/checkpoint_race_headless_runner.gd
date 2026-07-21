extends SceneTree

const Authority := preload(
	"res://scripts/embodiment/duo_games/checkpoint_race_authority.gd"
)

var failures := PackedStringArray()


func _init() -> void:
	_test_exact_participant_contract_and_strict_horizon()
	_test_fixed_window_movement_facing_and_no_combat()
	_test_independent_neutral_fallback()
	_test_dictionary_order_and_replay_determinism()
	_test_seat_swap_symmetry()
	_test_simultaneous_finish_draw()
	_finish()


func _test_exact_participant_contract_and_strict_horizon() -> void:
	var invalid := Authority.new()
	var errors := invalid.configure({
		"protocol_version": "llm-controller/0.2.0", "task_id": "duo-checkpoint-race-v0",
		"episode_id": "ep_bad_seats", "participant_ids": ["participant_0"],
		"maximum_episode_ticks": 1200,
	})
	_check("participant_ids_invalid" in errors, "authority accepted anything other than exactly two seats")
	var authority = _authority()
	var window := _window(authority, _action(authority, "participant_0", {"move_y": 1000}),
		_action(authority, "participant_1", {"move_y": 1000}))
	window.duration_ticks = 10.0
	var result: Dictionary = authority.step_window(window)
	_check(authority.tick == 10, "strict-type invalid horizon stalled common time")
	_check(not result.receipts.participant_0.accepted and not result.receipts.participant_1.accepted,
		"non-integer joint horizon was accepted")


func _authority():
	var authority := Authority.new()
	var errors := authority.configure({
		"protocol_version": "llm-controller/0.2.0", "task_id": "duo-checkpoint-race-v0",
		"episode_id": "ep_duo_race_test", "participant_ids": ["participant_0", "participant_1"],
		"maximum_episode_ticks": 1200,
	})
	_check(errors.is_empty(), "configuration failed: %s" % str(errors))
	return authority


func _test_fixed_window_movement_facing_and_no_combat() -> void:
	var authority = _authority()
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"move_y": 1000, "primary": true}),
		_action(authority, "participant_1", {"move_y": 1000, "primary": true})))
	_check(authority.tick == 10, "joint decision did not apply exactly ten ticks")
	_check(authority.operators.participant_0.position_mt == Vector2i(-2500, 4000),
		"seat 0 forward movement disagreed with north facing")
	_check(authority.operators.participant_1.position_mt == Vector2i(2500, -4000),
		"seat 1 forward movement disagreed with south facing")
	_check(authority.operators.participant_0.position_mt == -authority.operators.participant_1.position_mt,
		"mirrored movement diverged")
	_check(authority.operators.participant_0.health == 1000 and authority.operators.participant_1.health == 1000,
		"race unexpectedly enabled combat")
	_check(result.observations.participant_0.self.facing == "north", "seat 0 facing projection drifted")
	_check(not _contains_protected_geometry(result.observations), "participant observation leaked geometry")


func _test_independent_neutral_fallback() -> void:
	var authority = _authority()
	var window := _window(authority, _action(authority, "participant_0", {"move_y": 1000}), {})
	window.decisions.erase("participant_1")
	var result := authority.step_window(window)
	_check(result.receipts.participant_0.accepted, "valid seat was neutralized by missing rival")
	_check(result.receipts.participant_1.disposition == "no_input", "missing rival lacked no_input")
	_check(result.receipts.participant_1.no_input_reason == "missing", "missing reason drifted")
	_check(result.receipts.participant_1.applied_ticks == 10, "missing input stalled common time")
	_check(authority.operators.participant_1.position_mt == Vector2i(2500, -6000), "neutral seat moved")


func _test_dictionary_order_and_replay_determinism() -> void:
	var first = _authority()
	var second = _authority()
	for index: int in 3:
		var action_0 := _action(first, "participant_0", {"move_y": 500}, "same_%d" % index)
		var action_1 := _action(first, "participant_1", {"move_y": 500}, "same_%d" % index)
		first.step_window(_window(first, action_0, action_1))
		var reversed_decisions := {}
		reversed_decisions["participant_1"] = _decision(_action(second, "participant_1", {"move_y": 500}, "same_%d" % index))
		reversed_decisions["participant_0"] = _decision(_action(second, "participant_0", {"move_y": 500}, "same_%d" % index))
		second.step_window({"episode_id": second.episode_id, "observation_seq": second.observation_seq,
			"start_tick": second.tick, "duration_ticks": 10, "decisions": reversed_decisions})
		_check(first.checkpoint_hash() == second.checkpoint_hash(), "dictionary order changed authority hash")
	_check(first.replay_hash() == second.replay_hash(), "identical race replay hash drifted")


func _test_seat_swap_symmetry() -> void:
	var authority = _authority()
	authority.step_window(_window(authority,
		_action(authority, "participant_0", {"move_y": 1000, "look_x": 1000}),
		_action(authority, "participant_1", {"move_y": 1000, "look_x": 1000})))
	var p0: Dictionary = authority.operators.participant_0
	var p1: Dictionary = authority.operators.participant_1
	_check(p0.position_mt == -p1.position_mt, "seat-swapped positions were not 180-degree mirrors")
	_check(posmod(int(p0.heading) + 4, 8) == int(p1.heading), "seat-swapped headings were not mirrored")
	_check(p0.distance_travelled_mt == p1.distance_travelled_mt, "seat path lengths diverged")


func _test_simultaneous_finish_draw() -> void:
	var authority = _authority()
	authority.operators.participant_0.checkpoint_index = 3
	authority.operators.participant_1.checkpoint_index = 3
	authority.operators.participant_0.position_mt = Vector2i(-2500, -6000)
	authority.operators.participant_1.position_mt = Vector2i(2500, 6000)
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0"), _action(authority, "participant_1")))
	_check(result.terminal.outcome == "draw", "simultaneous finish was not a draw")
	_check(result.terminal.reason == "simultaneous_terminal", "simultaneous tie reason drifted")
	_check(authority.tick == 1, "simultaneous terminal did not stop on claim tick")
	_check(result.public_events.all(func(event: Dictionary) -> bool:
		return "position" not in JSON.stringify(event) and "_mt" not in JSON.stringify(event)),
		"public event leaked hidden coordinates")


func _window(authority, action_0: Dictionary, action_1: Dictionary) -> Dictionary:
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"start_tick": authority.tick, "duration_ticks": 10,
		"decisions": {"participant_0": _decision(action_0), "participant_1": _decision(action_1)}}


func _decision(action: Dictionary) -> Dictionary:
	return {"disposition": "accepted", "action": action, "fallback": "none", "no_input_reason": null}


func _action(authority, participant_id: String, overrides: Dictionary = {}, label: String = "race") -> Dictionary:
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


func _contains_protected_geometry(value: Variant) -> bool:
	var encoded := JSON.stringify(value)
	return "position_mt" in encoded or "operators" in encoded or "checkpoint_hash" in encoded


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("DUO_CHECKPOINT_RACE_OK")
		quit(0)
		return
	for failure: String in failures:
		push_error("DUO_CHECKPOINT_RACE_FAILURE: %s" % failure)
	quit(1)
