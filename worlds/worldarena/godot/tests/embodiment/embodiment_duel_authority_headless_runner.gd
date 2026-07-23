extends SceneTree

const DuelAuthority := preload(
	"res://scripts/embodiment/duel_authority/embodiment_duel_authority.gd"
)

var _failures := PackedStringArray()


func _init() -> void:
	_test_configuration_and_fixed_window()
	_test_mirrored_motion_and_privacy()
	_test_camera_visibility_filters_semantics_and_pixels()
	_test_invalid_seat_uses_neutral_without_stalling()
	_test_participant_agency_projection()
	_test_relay_hold_victory()
	_test_simultaneous_knockout_draw()
	_test_relay_and_knockout_same_tick_draw()
	_test_repeatable_hashes()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_DUEL_AUTHORITY_FAILURE: %s" % failure)
		print("EMBODIMENT_DUEL_AUTHORITY_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_DUEL_AUTHORITY_OK")
	quit(0)


func _authority(mode: String = "model-duel-v0"):
	var authority := DuelAuthority.new()
	var errors := authority.configure({"episode_id": "ep_duel_authority", "mode": mode,
		"task_id": "central-relay-v0",
		"participant_ids": ["participant_0", "participant_1"],
		"observation_profile": "text-visible-v1", "maximum_episode_ticks": 1800})
	_check(errors.is_empty(), "valid duel configuration failed: %s" % str(errors))
	return authority


func _test_configuration_and_fixed_window() -> void:
	var authority = _authority("scripted-duel-v0")
	_check(authority.decision_window_duration("scripted-duel-v0", 1) == 10, "scripted horizon drifted")
	_check(authority.decision_window_duration("model-duel-v0", 20) == 10, "model horizon drifted")
	var result := authority.step_window(_window(authority, _action(authority, "participant_0"),
		_action(authority, "participant_1"), 1))
	_check(result.observations.participant_0.tick == 10, "invalid joint horizon stalled time")
	_check(not result.receipts.participant_0.accepted, "invalid joint horizon accepted seat 0")
	_check(not result.receipts.participant_1.accepted, "invalid joint horizon accepted seat 1")


func _test_mirrored_motion_and_privacy() -> void:
	var authority = _authority()
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"move_y": 1000}),
		_action(authority, "participant_1", {"move_y": 1000})))
	var p0: Vector2i = authority.operators.participant_0.position_mt
	var p1: Vector2i = authority.operators.participant_1.position_mt
	_check(p0 == -p1, "180-degree mirrored motion diverged")
	_check(result.observations.size() == 2 and result.receipts.size() == 2, "result was not participant-indexed")
	for participant_id: String in ["participant_0", "participant_1"]:
		var observation: Dictionary = result.observations[participant_id]
		_check(not observation.has("operators"), "observation leaked authority operators")
		_check(not observation.visible_entities[0].has("position_mt"), "observation leaked exact rival position")


func _test_camera_visibility_filters_semantics_and_pixels() -> void:
	var authority = _authority()
	authority.operators.participant_0.heading = 4
	var observation: Dictionary = authority.observe("participant_0")
	_check(observation.visible_entities.is_empty(), "behind-camera entities leaked into visible text")
	_check(
		authority.presentation_visible_entity_ids_for("participant_0").is_empty(),
		"behind-camera entities leaked into the participant pixel allowlist",
	)
	var snapshot: Dictionary = authority.presentation_source_snapshot_for("participant_0")
	_check(snapshot.entities.size() == 1, "behind-camera presentation source retained a rival or relay")
	_check(snapshot.entities[0].id == "operator_participant_0", "self projection was removed")
	var rival_view: Dictionary = authority.observe("participant_1")
	_check(
		rival_view.visible_entities.any(func(entity: Dictionary) -> bool: return entity.id == "v_rival"),
		"participant-relative visibility incorrectly hid the front-facing rival",
	)


func _test_invalid_seat_uses_neutral_without_stalling() -> void:
	var authority = _authority()
	var invalid := _action(authority, "participant_0")
	invalid.control.move_x = 1.0
	var result := authority.step_window(_window(authority, invalid,
		_action(authority, "participant_1", {"move_y": 1000})))
	_check(result.receipts.participant_0.disposition == "no_input", "invalid seat lacked no_input")
	_check(result.receipts.participant_0.applied_ticks == 10, "invalid seat stalled common time")
	_check(result.receipts.participant_1.accepted, "valid rival seat was rejected")
	_check(authority.operators.participant_0.position_mt == Vector2i(0, 7000), "neutral seat moved")
	_check(authority.operators.participant_1.position_mt == Vector2i(0, -5000), "valid rival did not move")
	var neutral_agency: Dictionary = authority.presentation_source_snapshot_for("participant_0").agency
	_check(neutral_agency.receipt.disposition == "no_input", "neutral receipt missing from HUD source")
	_check(neutral_agency.intent_label.is_empty(), "invalid participant intent entered HUD source")
	_check(neutral_agency.controller.move_x == 0, "invalid participant controller was not neutralized")


func _test_participant_agency_projection() -> void:
	var authority = _authority()
	authority.step_window(_window(
		authority,
		_action(authority, "participant_0", {"move_x": 250}, "seat_zero_intent"),
		_action(authority, "participant_1", {"move_y": 750, "guard": true}, "seat_one_intent"),
	))
	var hash_before: String = authority.checkpoint_hash()
	var source_0: Dictionary = authority.presentation_source_snapshot_for("participant_0")
	var source_1: Dictionary = authority.presentation_source_snapshot_for("participant_1")
	_check(authority.checkpoint_hash() == hash_before, "agency projection changed duel authority hash")
	_check(source_0.agency.intent_label == "seat_zero_intent", "seat 0 intent was not participant-local")
	_check(source_1.agency.intent_label == "seat_one_intent", "seat 1 intent was not participant-local")
	_check(source_0.agency.controller.move_x == 250, "seat 0 controller evidence drifted")
	_check(source_1.agency.controller.move_y == 750, "seat 1 controller evidence drifted")
	_check(source_1.agency.controller.buttons.guard, "seat 1 button evidence drifted")
	var source_0_text := JSON.stringify(source_0.agency)
	var source_1_text := JSON.stringify(source_1.agency)
	_check("seat_one_intent" not in source_0_text, "seat 1 intent leaked into seat 0 agency")
	_check("seat_zero_intent" not in source_1_text, "seat 0 intent leaked into seat 1 agency")


func _test_relay_hold_victory() -> void:
	var authority = _authority()
	authority.operators.participant_0.position_mt = Vector2i.ZERO
	authority.operators.participant_1.position_mt = Vector2i(0, -7000)
	var result: Dictionary
	for index: int in 10:
		result = authority.step_window(_window(authority,
			_action(authority, "participant_0", {}, "relay_%d_0" % index),
			_action(authority, "participant_1", {}, "relay_%d_1" % index)))
	_check(result.terminal.ended and result.terminal.reason == "relay_hold", "100-tick relay hold did not win")
	_check(authority.winner_id == "participant_0", "relay winner drifted")
	_check(result.observations.participant_0.terminal == result.terminal, "seat 0 terminal boundary drifted")
	_check(result.observations.participant_1.terminal == result.terminal, "seat 1 terminal boundary drifted")
	_check(_exact_terminal(result.terminal), "shared terminal shape violated protocol schema")
	_check(_exact_terminal(result.observations.participant_0.terminal), "winner terminal shape drifted")
	_check(_exact_terminal(result.observations.participant_1.terminal), "loser terminal shape drifted")
	_check(authority.tick == 100, "relay terminal tick drifted")


func _test_simultaneous_knockout_draw() -> void:
	var authority = _authority()
	authority.operators.participant_0.position_mt = Vector2i(0, 500)
	authority.operators.participant_0.heading = 0
	authority.operators.participant_0.health = 250
	authority.operators.participant_1.position_mt = Vector2i(0, -500)
	authority.operators.participant_1.heading = 4
	authority.operators.participant_1.health = 250
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"primary": true}),
		_action(authority, "participant_1", {"primary": true})))
	_check(result.terminal.outcome == "draw", "simultaneous knockout was not a draw")
	_check(result.terminal.reason == "simultaneous_terminal", "simultaneous reason drifted")
	_check(authority.tick == 1, "simultaneous knockout did not stop on its tick")


func _test_relay_and_knockout_same_tick_draw() -> void:
	var authority = _authority()
	authority.operators.participant_0.position_mt = Vector2i.ZERO
	authority.operators.participant_0.heading = 0
	authority.operators.participant_0.health = 250
	authority.operators.participant_1.position_mt = Vector2i(0, -1500)
	authority.operators.participant_1.heading = 4
	authority.relay_controller = "participant_0"
	authority.relay_hold_ticks = 99
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0"),
		_action(authority, "participant_1", {"primary": true})))
	_check(result.terminal.outcome == "draw", "relay/knockout same-tick claims did not draw")
	_check(result.terminal.reason == "simultaneous_terminal", "relay/knockout draw reason drifted")
	_check(authority.tick == 1, "relay/knockout draw did not stop on claim tick")


func _test_repeatable_hashes() -> void:
	var first = _authority()
	var second = _authority()
	for index: int in 3:
		var first_result := first.step_window(_window(first,
			_action(first, "participant_0", {"move_x": 400}, "repeat_%d_0" % index),
			_action(first, "participant_1", {"move_x": 400}, "repeat_%d_1" % index)))
		var second_result := second.step_window(_window(second,
			_action(second, "participant_0", {"move_x": 400}, "repeat_%d_0" % index),
			_action(second, "participant_1", {"move_x": 400}, "repeat_%d_1" % index)))
		_check(first_result.state_hash == second_result.state_hash, "identical duel transcript hash drifted")


func _window(authority, action_0: Dictionary, action_1: Dictionary, duration: int = 10) -> Dictionary:
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"mode": authority.mode, "start_tick": authority.tick, "duration_ticks": duration,
		"decisions": {
			"participant_0": {"disposition": "accepted", "action": action_0,
				"fallback": "none", "no_input_reason": null},
			"participant_1": {"disposition": "accepted", "action": action_1,
				"fallback": "none", "no_input_reason": null}}}


func _action(authority, participant_id: String, overrides: Dictionary = {}, action_id: String = "action") -> Dictionary:
	var buttons := {"interact": false, "primary": false, "guard": false, "dash": false,
		"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false}
	for key: String in overrides:
		if key in buttons:
			buttons[key] = overrides[key]
	var control := {"move_x": int(overrides.get("move_x", 0)), "move_y": int(overrides.get("move_y", 0)),
		"look_x": int(overrides.get("look_x", 0)), "look_y": 0, "duration_ticks": 10, "buttons": buttons}
	return {"protocol_version": "llm-controller/0.1.0", "episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq, "action_id": "%s_%s" % [action_id, participant_id],
		"control": control, "intent_label": action_id, "memory_update": ""}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _exact_terminal(value: Dictionary) -> bool:
	var keys: Array = value.keys()
	keys.sort()
	return keys == ["ended", "outcome", "reason"]
