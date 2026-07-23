extends SceneTree

const Authority := preload("res://scripts/embodiment/trio_games/trio_relay_authority.gd")
const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]

var failures := PackedStringArray()


func _init() -> void:
	_test_configuration_and_exact_cyclic_orbit()
	_test_independent_fallback_movement_facing_and_disabled_combat()
	_test_each_seat_can_win_under_every_rotation()
	_test_time_limit_placement_permutations()
	_test_arrival_and_dictionary_order_invariance()
	_test_coordinate_free_participant_projection()
	_finish()


func _authority(rotation: int = 0, suffix: String = "relay"):
	var authority := Authority.new()
	var errors := authority.configure({
		"protocol_version": "llm-controller/0.3.0", "task_id": "trio-relay-v0",
		"episode_id": "ep_trio_%s_%d" % [suffix, rotation], "participant_ids": PARTICIPANTS,
		"maximum_episode_ticks": 1200, "seat_rotation": rotation,
	})
	_check(errors.is_empty(), "configuration failed: %s" % str(errors))
	return authority


func _test_configuration_and_exact_cyclic_orbit() -> void:
	var bad := Authority.new()
	var errors := bad.configure({
		"protocol_version": "llm-controller/0.3.0", "task_id": "trio-relay-v0",
		"episode_id": "ep_bad", "participant_ids": ["participant_0", "participant_1"],
		"maximum_episode_ticks": 1200, "seat_rotation": 3,
	})
	_check("participant_ids_invalid" in errors, "two-participant configuration was accepted")
	_check("seat_rotation_invalid" in errors, "invalid cyclic rotation was accepted")
	var authority = _authority()
	var first: Vector2i = authority.operators.participant_0.position_axial
	var second: Vector2i = authority.rotate_axial_120(first)
	var third: Vector2i = authority.rotate_axial_120(second)
	_check(second == authority.operators.participant_1.position_axial,
		"first exact 120-degree orbit member diverged")
	_check(third == authority.operators.participant_2.position_axial,
		"second exact 120-degree orbit member diverged")
	_check(authority.rotate_axial_120(third) == first, "integer orbit was not exactly order three")
	var observer: Dictionary = authority.operators.participant_0.duplicate(true)
	observer.position_axial = Vector2i.ZERO
	observer.heading = 0
	for target: Vector2i in [Vector2i(1000, -500), Vector2i(500, 500), Vector2i(-500, -500)]:
		var relative := authority._bearing_index(observer, target)
		var rotated_observer: Dictionary = observer.duplicate(true)
		rotated_observer.heading = 2
		_check(authority._bearing_index(rotated_observer, authority.rotate_axial_120(target)) == relative,
			"bearing tie policy was not equivariant under exact 120-degree rotation")
	for participant_id: String in PARTICIPANTS:
		authority.operators[participant_id].position_axial = authority.SPAWN_ORBIT[
			PARTICIPANTS.find(participant_id)] * 4 / 3
	var boundary_before := {
		"participant_0": authority.operators.participant_0.position_axial,
		"participant_1": authority.operators.participant_1.position_axial,
		"participant_2": authority.operators.participant_2.position_axial,
	}
	authority.step_window(_window(authority, {
		"participant_0": _action(authority, "participant_0", {"move_y": -1000}),
		"participant_1": _action(authority, "participant_1", {"move_y": -1000}),
		"participant_2": _action(authority, "participant_2", {"move_y": -1000}),
	}))
	for participant_id: String in PARTICIPANTS:
		_check(authority.operators[participant_id].position_axial == boundary_before[participant_id],
			"boundary rejection broke exact cyclic symmetry for %s" % participant_id)


func _test_independent_fallback_movement_facing_and_disabled_combat() -> void:
	var authority = _authority(0, "fallback")
	var start_0: Vector2i = authority.operators.participant_0.position_axial
	var start_1: Vector2i = authority.operators.participant_1.position_axial
	var result := authority.step_window(_window(authority, {
		"participant_0": _invalid_action(authority, "participant_0"),
		"participant_1": _action(authority, "participant_1", {"move_y": 1000, "primary": true}),
		"participant_2": _action(authority, "participant_2"),
	}))
	_check(authority.tick == 10, "one invalid seat stalled common authority time")
	_check(not result.receipts.participant_0.accepted and result.receipts.participant_1.accepted,
		"fallback was not independent per seat")
	_check(authority.operators.participant_0.position_axial == start_0, "neutral fallback seat moved")
	_check(authority._axial_norm(authority.operators.participant_1.position_axial) \
		< authority._axial_norm(start_1), "forward input did not move along facing toward relay")
	_check(authority.operators.participant_0.health == 1000, "objective-only relay enabled combat damage")
	_check("primary_disabled" in result.receipts.participant_1.codes,
		"objective-only relay did not explicitly reject primary")
	_check("dash_disabled" not in result.receipts.participant_1.codes,
		"primary incorrectly aliased to dash behavior")
	var heading_before := int(authority.operators.participant_2.heading)
	authority.step_window(_window(authority, {
		"participant_0": _action(authority, "participant_0"),
		"participant_1": _action(authority, "participant_1"),
		"participant_2": _action(authority, "participant_2", {"look_x": 1000, "move_y": 1000}),
	}))
	_check(authority.operators.participant_2.heading == posmod(heading_before + 4, 6),
		"facing did not advance once per tick from integer look input")


func _test_each_seat_can_win_under_every_rotation() -> void:
	for rotation: int in 3:
		for winner_index: int in 3:
			var authority = _authority(rotation, "winner_%d" % winner_index)
			var winner: String = PARTICIPANTS[winner_index]
			authority.operators[winner].position_axial = Vector2i.ZERO
			for window_index: int in 6:
				authority.step_window(_window(authority, _actions(authority)))
			_check(authority.terminal.outcome == "win" and authority.winner_id == winner,
				"seat %s did not win relay under rotation %d" % [winner, rotation])
			_check(authority.tick == 60, "relay terminal drifted from 60 ticks")
			_check(authority.placements[0] == {
				"place": 1, "participant_ids": [winner], "tie": false, "basis": "relay_hold",
			}, "relay winner placement was not typed and ordered")


func _test_time_limit_placement_permutations() -> void:
	var all_tie = _authority(0, "all_tie")
	all_tie.tick = 1199
	all_tie.step_window(_window(all_tie, _actions(all_tie)))
	_check(all_tie.terminal.reason == "time_limit_tie", "three-way time tie was not drawn")
	_check(all_tie.placements[0].participant_ids == PARTICIPANTS and all_tie.placements[0].tie,
		"three-way tie group was not ordered")
	var pair_tie = _authority(0, "pair_tie")
	pair_tie.relay_total_ticks = {"participant_0": 20, "participant_1": 20, "participant_2": 10}
	pair_tie.tick = 1199
	pair_tie.step_window(_window(pair_tie, _actions(pair_tie)))
	_check(pair_tie.terminal.reason == "time_limit_tie", "shared lead did not draw")
	_check(pair_tie.placements[0].participant_ids == ["participant_0", "participant_1"],
		"shared lead group order was unstable")
	_check(pair_tie.placements[1].place == 3 and pair_tie.placements[1].participant_ids == ["participant_2"],
		"post-tie placement number was wrong")
	var unique = _authority(0, "unique")
	unique.relay_total_ticks = {"participant_0": 10, "participant_1": 30, "participant_2": 20}
	unique.tick = 1199
	unique.step_window(_window(unique, _actions(unique)))
	_check(unique.winner_id == "participant_1" and unique.terminal.reason == "time_limit_ranking",
		"unique time-limit score did not win")
	_check(unique.placements.map(func(group): return group.participant_ids[0]) \
		== ["participant_1", "participant_2", "participant_0"],
		"unique placement permutation was not descending")


func _test_arrival_and_dictionary_order_invariance() -> void:
	var first = _authority(1, "order")
	var second = _authority(1, "order")
	for index: int in 3:
		first.step_window(_window(first, _actions(first, index)))
		var reversed := {}
		reversed["participant_2"] = _decision(_action(second, "participant_2", {"move_y": 250}, "order_%d" % index))
		reversed["participant_1"] = _decision(_action(second, "participant_1", {"move_y": 250}, "order_%d" % index))
		reversed["participant_0"] = _decision(_action(second, "participant_0", {"move_y": 250}, "order_%d" % index))
		second.step_window(_window(second, reversed, true))
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "dictionary arrival order changed checkpoint")
	_check(first.replay_hash() == second.replay_hash(), "dictionary arrival order changed replay hash")
	var repeated = _authority(1, "order")
	for index: int in 3:
		repeated.step_window(_window(repeated, _actions(repeated, index)))
	_check(first.replay_hash() == repeated.replay_hash(), "identical replay inputs changed canonical hash")


func _test_coordinate_free_participant_projection() -> void:
	var authority = _authority()
	authority.step_window(_window(authority, {
		"participant_0": _action(authority, "participant_0", {"move_y": 1000}),
		"participant_1": _action(authority, "participant_1"),
		"participant_2": _action(authority, "participant_2"),
	}))
	var observation: Dictionary = authority.observe("participant_0")
	var serialized := JSON.stringify(observation).to_lower()
	for protected: String in ["\"position", "coordinate", "axial", "movement_q", "movement_r",
		"spawn", "spectator", "checkpoint_hash"]:
		_check(protected not in serialized, "participant observation leaked protected token %s" % protected)
	_check(observation.visible_entities[0].has("bearing") and observation.visible_entities[0].has("distance"),
		"coordinate-free relay projection omitted relative spatial bands")


func _actions(authority, suffix: int = -1) -> Dictionary:
	var output := {}
	for participant_id: String in PARTICIPANTS:
		output[participant_id] = _decision(_action(authority, participant_id,
			{"move_y": 250} if suffix >= 0 else {}, "order_%d" % suffix if suffix >= 0 else "hold"))
	return output


func _window(authority, values: Dictionary, already_decisions: bool = false) -> Dictionary:
	var decisions := values if already_decisions else {}
	if not already_decisions:
		for participant_id: String in PARTICIPANTS:
			var value: Variant = values.get(participant_id)
			decisions[participant_id] = value if value is Dictionary and value.get("disposition") != null \
				else _decision(value)
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"start_tick": authority.tick, "duration_ticks": 10, "decisions": decisions}


func _decision(action: Dictionary) -> Dictionary:
	return {"disposition": "accepted", "action": action, "fallback": "none", "no_input_reason": null}


func _action(authority, participant_id: String, overrides: Dictionary = {}, label: String = "relay") -> Dictionary:
	var buttons := {"interact": false, "primary": false, "guard": false, "dash": false,
		"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false}
	for key: String in buttons:
		buttons[key] = bool(overrides.get(key, false))
	return {"protocol_version": "llm-controller/0.3.0", "episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "%s_%s_%d" % [label, participant_id, authority.observation_seq],
		"control": {"move_x": int(overrides.get("move_x", 0)),
			"move_y": int(overrides.get("move_y", 0)), "look_x": int(overrides.get("look_x", 0)),
			"look_y": 0, "duration_ticks": 10, "buttons": buttons},
		"intent_label": label, "memory_update": ""}


func _invalid_action(authority, participant_id: String) -> Dictionary:
	var action := _action(authority, participant_id)
	action.control.move_y = 1.0
	return action


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TRIO_RELAY_OK")
		quit(0)
		return
	for failure: String in failures:
		push_error("TRIO_RELAY_FAILURE: %s" % failure)
	quit(1)
