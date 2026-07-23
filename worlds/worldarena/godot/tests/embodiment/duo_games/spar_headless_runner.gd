extends SceneTree

const Authority := preload("res://scripts/embodiment/duo_games/spar_authority.gd")

var failures := PackedStringArray()


func _init() -> void:
	_test_movement_facing_dash_and_cooldown()
	_test_primary_guard_cooldown_and_local_visibility()
	_test_independent_timeout_fallback()
	_test_simultaneous_knockout_and_order_invariance()
	_test_replay_determinism_and_seat_symmetry()
	_finish()


func _authority():
	var authority := Authority.new()
	var errors := authority.configure({"protocol_version": "llm-controller/0.2.0",
		"task_id": "duo-spar-v0", "episode_id": "ep_duo_spar_test",
		"participant_ids": ["participant_0", "participant_1"], "maximum_episode_ticks": 1200})
	_check(errors.is_empty(), "configuration failed: %s" % str(errors))
	return authority


func _place_for_combat(authority) -> void:
	authority.operators.participant_0.position_mt = Vector2i(0, 500)
	authority.operators.participant_0.heading = 0
	authority.operators.participant_1.position_mt = Vector2i(0, -500)
	authority.operators.participant_1.heading = 4


func _test_movement_facing_dash_and_cooldown() -> void:
	var authority = _authority()
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"move_y": 1000, "dash": true}),
		_action(authority, "participant_1", {"move_y": 1000, "dash": true})))
	_check(authority.operators.participant_0.position_mt == -authority.operators.participant_1.position_mt,
		"mirrored dash movement diverged")
	_check(authority.operators.participant_0.position_mt.y < 4000,
		"north-facing dash did not travel forward")
	_check("dash_applied" in result.receipts.participant_0.codes, "dash lacked applied receipt")
	var cooldown := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"dash": true}), _action(authority, "participant_1")))
	_check("dash_cooldown" in cooldown.receipts.participant_0.codes, "dash cooldown was not enforced")


func _test_primary_guard_cooldown_and_local_visibility() -> void:
	var authority = _authority()
	_place_for_combat(authority)
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"primary": true}),
		_action(authority, "participant_1", {"guard": true})))
	_check(authority.operators.participant_1.health == 875, "front guard did not halve primary damage")
	_check("primary_hit" in result.receipts.participant_0.codes, "primary hit lacked receipt")
	_check("guard_reduced_damage" in result.receipts.participant_1.codes, "guard reduction lacked receipt")
	var cooldown := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"primary": true}), _action(authority, "participant_1")))
	_check("primary_cooldown" in cooldown.receipts.participant_0.codes, "primary cooldown was not enforced")
	var observation: Dictionary = authority.observe("participant_0")
	_check(not "position_mt" in JSON.stringify(observation), "spar observation leaked hidden coordinates")
	_check(observation.visible_entities.any(func(entity: Dictionary) -> bool: return entity.id == "v_rival"),
		"front-facing rival was missing from participant-local observation")
	authority.operators.participant_0.heading = 4
	_check(authority.observe("participant_0").visible_entities.is_empty(),
		"behind-camera rival leaked into participant observation")


func _test_independent_timeout_fallback() -> void:
	var authority = _authority()
	var window := _window(authority, _action(authority, "participant_0", {"move_y": 1000}),
		_action(authority, "participant_1"))
	window.decisions.participant_1 = {"disposition": "no_input", "action": null,
		"fallback": "neutral", "no_input_reason": "timeout"}
	var result := authority.step_window(window)
	_check(result.receipts.participant_0.accepted, "valid seat rejected beside timeout")
	_check(result.receipts.participant_1.no_input_reason == "timeout", "timeout reason was not preserved")
	_check(result.receipts.participant_1.applied_ticks == 10 and authority.tick == 10,
		"timeout fallback stalled common authority time")


func _test_simultaneous_knockout_and_order_invariance() -> void:
	var first = _authority()
	var second = _authority()
	for authority in [first, second]:
		_place_for_combat(authority)
		authority.operators.participant_0.health = 250
		authority.operators.participant_1.health = 250
	var ordinary := _window(first, _action(first, "participant_0", {"primary": true}, "ko"),
		_action(first, "participant_1", {"primary": true}, "ko"))
	var reversed := {}
	reversed["participant_1"] = _decision(_action(second, "participant_1", {"primary": true}, "ko"))
	reversed["participant_0"] = _decision(_action(second, "participant_0", {"primary": true}, "ko"))
	var first_result := first.step_window(ordinary)
	var second_result := second.step_window({"episode_id": second.episode_id,
		"observation_seq": second.observation_seq, "start_tick": second.tick,
		"duration_ticks": 10, "decisions": reversed})
	_check(first_result.terminal.outcome == "draw" and first_result.terminal.reason == "simultaneous_terminal",
		"simultaneous knockout was not a deterministic draw")
	_check(first.tick == 1, "simultaneous knockout did not stop on damage tick")
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "decision dictionary order changed KO state")


func _test_replay_determinism_and_seat_symmetry() -> void:
	var first = _authority()
	var second = _authority()
	for index: int in 2:
		first.step_window(_window(first,
			_action(first, "participant_0", {"move_x": 250}, "repeat_%d" % index),
			_action(first, "participant_1", {"move_x": 250}, "repeat_%d" % index)))
		second.step_window(_window(second,
			_action(second, "participant_0", {"move_x": 250}, "repeat_%d" % index),
			_action(second, "participant_1", {"move_x": 250}, "repeat_%d" % index)))
	_check(first.replay_hash() == second.replay_hash(), "identical spar replay hash drifted")
	_check(first.operators.participant_0.position_mt == -first.operators.participant_1.position_mt,
		"seat-symmetric strafe positions diverged")
	_check(first.authority_aggregates().participants.keys().size() == 2,
		"safe aggregate was not participant-indexed")


func _window(authority, action_0: Dictionary, action_1: Dictionary) -> Dictionary:
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"start_tick": authority.tick, "duration_ticks": 10,
		"decisions": {"participant_0": _decision(action_0), "participant_1": _decision(action_1)}}


func _decision(action: Dictionary) -> Dictionary:
	return {"disposition": "accepted", "action": action, "fallback": "none", "no_input_reason": null}


func _action(authority, participant_id: String, overrides: Dictionary = {}, label: String = "spar") -> Dictionary:
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
		print("DUO_SPAR_OK")
		quit(0)
		return
	for failure: String in failures:
		push_error("DUO_SPAR_FAILURE: %s" % failure)
	quit(1)
