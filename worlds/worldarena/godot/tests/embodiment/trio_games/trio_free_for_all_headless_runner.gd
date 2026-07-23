extends SceneTree

const Authority := preload("res://scripts/embodiment/trio_games/trio_free_for_all_authority.gd")
const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]

var failures := PackedStringArray()


func _init() -> void:
	_test_primary_guard_dash_and_stopped_seat()
	_test_last_standing_for_every_seat()
	_test_simultaneous_knockout_permutations()
	_test_knockout_precedes_same_tick_objective()
	_test_objective_precedes_same_tick_time_limit()
	_test_time_limit_tie_permutations()
	_test_cyclic_symmetry_and_replay_invariance()
	_test_participant_privacy_and_safe_aggregates()
	_finish()


func _authority(rotation: int = 0, suffix: String = "ffa"):
	var authority := Authority.new()
	var errors := authority.configure({
		"protocol_version": "llm-controller/0.3.0", "task_id": "trio-free-for-all-v0",
		"episode_id": "ep_trio_%s_%d" % [suffix, rotation], "participant_ids": PARTICIPANTS,
		"maximum_episode_ticks": 1200, "seat_rotation": rotation,
	})
	_check(errors.is_empty(), "configuration failed: %s" % str(errors))
	return authority


func _test_primary_guard_dash_and_stopped_seat() -> void:
	var guard = _authority(0, "guard")
	guard.operators.participant_0.position_axial = Vector2i.ZERO
	guard.operators.participant_1.position_axial = Vector2i(1000, 0)
	guard.operators.participant_2.position_axial = Vector2i(-5000, 5000)
	_face_target(guard, "participant_0", "participant_1")
	_face_target(guard, "participant_1", "participant_0")
	guard.step_window(_window(guard, {
		"participant_0": _action(guard, "participant_0", {"primary": true}),
		"participant_1": _action(guard, "participant_1", {"guard": true}),
		"participant_2": _action(guard, "participant_2"),
	}))
	_check(guard.operators.participant_1.health == 875, "front guard did not halve primary damage")
	_check(guard.operators.participant_1.energy == 600,
		"guard did not consume deterministic energy across ten ticks")

	var dash = _authority(0, "dash")
	var dash_start: Vector2i = dash.operators.participant_0.position_axial
	var dash_result := dash.step_window(_window(dash, {
		"participant_0": _action(dash, "participant_0", {"dash": true}),
		"participant_1": _action(dash, "participant_1"),
		"participant_2": _action(dash, "participant_2"),
	}))
	_check(dash._axial_distance(dash_start, dash.operators.participant_0.position_axial) == 900,
		"dash did not use exact axial distance")
	_check("dash_applied" in dash_result.receipts.participant_0.codes,
		"dash receipt omitted applied code")

	var stopped = _authority(0, "stopped")
	stopped.operators.participant_0.position_axial = Vector2i.ZERO
	stopped.operators.participant_1.position_axial = Vector2i(1000, 0)
	stopped.operators.participant_2.position_axial = Vector2i(-5000, 5000)
	stopped.operators.participant_1.health = 250
	_face_target(stopped, "participant_0", "participant_1")
	stopped.step_window(_window(stopped, {
		"participant_0": _action(stopped, "participant_0", {"primary": true}),
		"participant_1": _action(stopped, "participant_1"),
		"participant_2": _action(stopped, "participant_2"),
	}))
	_check(not stopped.terminal.ended and stopped.operators.participant_1.health == 0,
		"first elimination incorrectly ended a three-way match")
	var eliminated_position: Vector2i = stopped.operators.participant_1.position_axial
	var invalid_before := int(stopped.invalid_windows.participant_1)
	var result := stopped.step_window(_window(stopped, {
		"participant_0": _action(stopped, "participant_0"),
		"participant_1": _action(stopped, "participant_1", {"move_y": 1000, "dash": true}),
		"participant_2": _action(stopped, "participant_2"),
	}))
	_check(result.receipts.participant_1.disposition == "eliminated"
		and result.receipts.participant_1.no_input_reason == "eliminated",
		"stopped seat did not receive deterministic eliminated disposition")
	_check(stopped.operators.participant_1.position_axial == eliminated_position,
		"eliminated seat continued acting")
	_check(stopped.invalid_windows.participant_1 == invalid_before,
		"eliminated disposition was incorrectly counted as invalid input")
	_check(stopped.tick == 20 and result.receipts.participant_1.applied_ticks == 10,
		"stopped-seat accounting did not cover the common window")


func _test_last_standing_for_every_seat() -> void:
	for winner_index: int in 3:
		var authority = _authority(winner_index, "last_%d" % winner_index)
		var winner: String = PARTICIPANTS[winner_index]
		for participant_id: String in PARTICIPANTS:
			if participant_id != winner:
				authority.operators[participant_id].health = 0
				authority.operators[participant_id].eliminated_tick = 1
		var events: Array[Dictionary] = []
		authority._resolve_terminal(events)
		_check(authority.winner_id == winner and authority.terminal.reason == "last_standing",
			"participant %s did not receive last-standing terminal" % winner)
		_check(authority.placements[0].participant_ids == [winner]
			and authority.placements[1].participant_ids.size() == 2,
			"last-standing placement did not preserve tied elimination group")


func _test_simultaneous_knockout_permutations() -> void:
	# Two simultaneous knockouts leave the untouched third participant as winner.
	for winner_index: int in 3:
		var authority = _authority(0, "double_%d" % winner_index)
		var fighters: Array[String] = []
		for participant_id: String in PARTICIPANTS:
			if participant_id != PARTICIPANTS[winner_index]:
				fighters.append(participant_id)
		authority.operators[fighters[0]].position_axial = Vector2i.ZERO
		authority.operators[fighters[1]].position_axial = Vector2i(1000, 0)
		authority.operators[PARTICIPANTS[winner_index]].position_axial = Vector2i(-5000, 5000)
		authority.operators[fighters[0]].health = 250
		authority.operators[fighters[1]].health = 250
		_face_target(authority, fighters[0], fighters[1])
		_face_target(authority, fighters[1], fighters[0])
		var actions := _neutral_actions(authority)
		actions[fighters[0]] = _action(authority, fighters[0], {"primary": true})
		actions[fighters[1]] = _action(authority, fighters[1], {"primary": true})
		authority.step_window(_window(authority, actions))
		_check(authority.winner_id == PARTICIPANTS[winner_index]
			and authority.terminal.reason == "last_standing",
			"double knockout did not select untouched seat %d" % winner_index)

	# All-three simultaneous knockout is a typed three-way draw.
	var all = _authority(0, "triple")
	all.operators.participant_0.position_axial = Vector2i(0, -500)
	all.operators.participant_1.position_axial = Vector2i(500, 0)
	all.operators.participant_2.position_axial = Vector2i(-500, 500)
	for participant_id: String in PARTICIPANTS:
		all.operators[participant_id].health = 250
	var target_cycle := {"participant_0": "participant_1", "participant_1": "participant_2",
		"participant_2": "participant_0"}
	for participant_id: String in PARTICIPANTS:
		_face_selected_target(all, participant_id, target_cycle[participant_id])
	var triple_actions := {}
	for participant_id: String in PARTICIPANTS:
		triple_actions[participant_id] = _action(all, participant_id, {"primary": true})
	all.step_window(_window(all, triple_actions))
	_check(all.terminal.outcome == "draw" and all.terminal.reason == "simultaneous_knockout",
		"three-way simultaneous knockout was not drawn")
	_check(all.placements == [{"place": 1, "participant_ids": PARTICIPANTS,
		"tie": true, "basis": "simultaneous_knockout"}],
		"simultaneous knockout placement was not a typed three-way tie")


func _test_knockout_precedes_same_tick_objective() -> void:
	var authority = _authority(0, "priority")
	authority.operators.participant_0.position_axial = Vector2i.ZERO
	authority.operators.participant_1.position_axial = Vector2i(1500, 0)
	authority.operators.participant_2.position_axial = Vector2i(-5000, 5000)
	authority.operators.participant_0.health = 250
	authority.operators.participant_2.health = 0
	authority.operators.participant_2.eliminated_tick = 1
	authority.relay_controller = "participant_0"
	authority.relay_hold_ticks = 59
	_face_target(authority, "participant_1", "participant_0")
	authority.step_window(_window(authority, {
		"participant_0": _action(authority, "participant_0"),
		"participant_1": _action(authority, "participant_1", {"primary": true}),
		"participant_2": _action(authority, "participant_2"),
	}))
	_check(authority.winner_id == "participant_1" and authority.terminal.reason == "last_standing",
		"relay objective incorrectly outranked same-tick last-standing knockout")
	var knockout_time = _authority(0, "knockout_time")
	knockout_time.operators.participant_0.position_axial = Vector2i.ZERO
	knockout_time.operators.participant_1.position_axial = Vector2i(1500, 0)
	knockout_time.operators.participant_2.health = 0
	knockout_time.operators.participant_2.eliminated_tick = 1
	knockout_time.operators.participant_0.health = 250
	knockout_time.tick = 1199
	_face_target(knockout_time, "participant_1", "participant_0")
	knockout_time.step_window(_window(knockout_time, {
		"participant_0": _action(knockout_time, "participant_0"),
		"participant_1": _action(knockout_time, "participant_1", {"primary": true}),
		"participant_2": _action(knockout_time, "participant_2"),
	}))
	_check(knockout_time.winner_id == "participant_1"
		and knockout_time.terminal.reason == "last_standing",
		"time limit incorrectly outranked same-tick knockout")


func _test_objective_precedes_same_tick_time_limit() -> void:
	var authority = _authority(0, "objective_time")
	authority.operators.participant_0.position_axial = Vector2i.ZERO
	authority.relay_controller = "participant_0"
	authority.relay_hold_ticks = 59
	authority.tick = 1199
	authority.step_window(_window(authority, _neutral_actions(authority)))
	_check(authority.winner_id == "participant_0" and authority.terminal.reason == "relay_hold",
		"time limit incorrectly outranked same-tick relay objective")
	_check(authority.placements[0].basis == "relay_hold",
		"objective terminal did not record typed placement basis")


func _test_time_limit_tie_permutations() -> void:
	var all_tie = _authority(0, "time_all")
	all_tie.tick = 1199
	all_tie.step_window(_window(all_tie, _neutral_actions(all_tie)))
	_check(all_tie.terminal.reason == "time_limit_tie"
		and all_tie.placements[0].participant_ids == PARTICIPANTS,
		"equal three-way time-limit state was not tied")
	var pair = _authority(0, "time_pair")
	pair.operators.participant_0.health = 900
	pair.operators.participant_1.health = 900
	pair.operators.participant_2.health = 500
	pair.tick = 1199
	pair.step_window(_window(pair, _neutral_actions(pair)))
	_check(pair.terminal.reason == "time_limit_tie"
		and pair.placements[0].participant_ids == ["participant_0", "participant_1"]
		and pair.placements[1].place == 3,
		"two-way health lead did not produce ordered tie groups")
	var unique = _authority(0, "time_unique")
	unique.operators.participant_0.health = 600
	unique.operators.participant_1.health = 800
	unique.operators.participant_2.health = 700
	unique.tick = 1199
	unique.step_window(_window(unique, _neutral_actions(unique)))
	_check(unique.winner_id == "participant_1" and unique.terminal.reason == "time_limit_ranking",
		"unique health leader did not win time-limit ranking")
	_check(unique.placements.map(func(group): return group.participant_ids[0]) \
		== ["participant_1", "participant_2", "participant_0"],
		"health placement permutation was not descending")


func _test_cyclic_symmetry_and_replay_invariance() -> void:
	var authorities := [_authority(0, "cycle_0"), _authority(1, "cycle_1"), _authority(2, "cycle_2")]
	for authority in authorities:
		for window_index: int in 2:
			authority.step_window(_window(authority, {
				"participant_0": _action(authority, "participant_0", {"move_y": 500}, "cycle_%d" % window_index),
				"participant_1": _action(authority, "participant_1", {"move_y": 500}, "cycle_%d" % window_index),
				"participant_2": _action(authority, "participant_2", {"move_y": 500}, "cycle_%d" % window_index),
			}))
	var distance: int = authorities[0].authority_aggregates().participants.participant_0.distance_travelled_mt
	for authority in authorities:
		for participant_id: String in PARTICIPANTS:
			_check(authority.authority_aggregates().participants[participant_id].distance_travelled_mt == distance,
				"cyclic rotation changed symmetric movement aggregate")
	var first = _authority(2, "order")
	var second = _authority(2, "order")
	for window_index: int in 2:
		first.step_window(_window(first, _neutral_actions(first, "same_%d" % window_index)))
		var reversed := {}
		for participant_id: String in ["participant_2", "participant_1", "participant_0"]:
			reversed[participant_id] = _decision(_action(second, participant_id, {}, "same_%d" % window_index))
		second.step_window(_window(second, reversed, true))
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "arrival order changed FFA checkpoint")
	_check(first.replay_hash() == second.replay_hash(), "arrival order changed FFA replay hash")


func _test_participant_privacy_and_safe_aggregates() -> void:
	var authority = _authority()
	authority.step_window(_window(authority, {
		"participant_0": _action(authority, "participant_0", {"move_y": 1000}),
		"participant_1": _action(authority, "participant_1"),
		"participant_2": _action(authority, "participant_2"),
	}))
	var observation_text := JSON.stringify(authority.observe("participant_0")).to_lower()
	for protected: String in ["\"position", "coordinate", "axial", "movement_q", "movement_r",
		"spawn", "spectator", "checkpoint_hash"]:
		_check(protected not in observation_text, "FFA observation leaked protected token %s" % protected)
	var aggregates_text := JSON.stringify(authority.authority_aggregates()).to_lower()
	for protected: String in ["\"position", "coordinate", "axial", "memory", "event"]:
		_check(protected not in aggregates_text, "safe aggregate leaked protected token %s" % protected)


func _face_target(authority, attacker_id: String, target_id: String) -> void:
	for heading: int in 6:
		authority.operators[attacker_id].heading = heading
		if authority._can_hit(authority.operators[attacker_id], authority.operators[target_id]):
			return
	_check(false, "could not face %s toward %s" % [attacker_id, target_id])


func _face_selected_target(authority, attacker_id: String, target_id: String) -> void:
	for heading: int in 6:
		authority.operators[attacker_id].heading = heading
		if authority._select_target(attacker_id) == target_id:
			return
	_check(false, "could not isolate selected target %s -> %s" % [attacker_id, target_id])


func _neutral_actions(authority, label: String = "idle") -> Dictionary:
	var output := {}
	for participant_id: String in PARTICIPANTS:
		output[participant_id] = _action(authority, participant_id, {}, label)
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


func _action(authority, participant_id: String, overrides: Dictionary = {}, label: String = "ffa") -> Dictionary:
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


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TRIO_FREE_FOR_ALL_OK")
		quit(0)
		return
	for failure: String in failures:
		push_error("TRIO_FREE_FOR_ALL_FAILURE: %s" % failure)
	quit(1)
