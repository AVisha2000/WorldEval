extends SceneTree

const SoloSimulation := preload(
	"res://scripts/embodiment/embodiment_solo_simulation.gd"
)
const ProtocolValidator := preload(
	"res://scripts/embodiment/embodiment_protocol_validator.gd"
)
const ArenaMap := preload("res://scripts/embodiment/authority/arena_map.gd")
const Visibility := preload("res://scripts/embodiment/authority/visibility.gd")
const EventLedger := preload("res://scripts/embodiment/authority/event_ledger.gd")
const CheckpointSerializer := preload(
	"res://scripts/embodiment/authority/checkpoint_serializer.gd"
)

var _failures := PackedStringArray()


func _init() -> void:
	_test_capability_and_pre_reset_rejection()
	_test_shared_conformance_policy()
	_test_initial_observation()
	_test_semantic_shortcut_rejected()
	_test_missing_input_falls_back_to_neutral()
	_test_presentation_agency_is_hash_invariant()
	_test_strict_types_and_utf8_limits()
	_test_solo_window_bounds()
	_test_cross_runtime_checkpoint_hash()
	_test_authority_module_boundaries()
	_test_granular_orientation_success()
	_test_repeatability()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_SOLO_FAILURE: %s" % failure)
		print("EMBODIMENT_SOLO_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_SOLO_OK")
	quit(0)


func _simulation(episode_id: String = "ep_orientation_test"):
	var simulation := SoloSimulation.new()
	var errors := simulation.configure({
		"episode_id": episode_id,
		"mode": "solo-curriculum-v0",
		"task_id": "orientation-v0",
		"observation_profile": "text-visible-v1",
		"maximum_episode_ticks": 600,
	})
	_check(errors.is_empty(), "valid Stage-A configuration was rejected: %s" % str(errors))
	return simulation


func _test_initial_observation() -> void:
	var simulation = _simulation()
	var observation := simulation.observe()
	_check(int(observation.tick) == 0, "initial observation did not start at tick zero")
	_check(str(observation.self.facing) == "north", "Operator did not face north")
	_check(str(observation.visible_entities[0].bearing) == "front", "beacon was not ahead")
	_check(str(observation.visible_entities[0].distance) == "far", "beacon distance band is wrong")
	_check(not bool(observation.terminal.ended), "fresh episode was terminal")


func _test_capability_and_pre_reset_rejection() -> void:
	var simulation = _simulation("ep_capability_test")
	var capability: Dictionary = simulation.capability_status()
	_check(capability.implemented_modes == ["solo-curriculum-v0"], "Stage-A mode capability drifted")
	_check(capability.implemented_observation_profiles == ["text-visible-v1"], "base solo profile capability drifted")
	_check(
		capability.implemented_tasks == [
			"orientation-v0", "interaction-v0", "construction-v0", "neutral-encounter-v0",
		],
		"solo curriculum task capability drifted",
	)
	_check(capability.certified_modes.is_empty(), "Stage-A prototype was incorrectly marked certified")
	_check(capability.certified_observation_profiles.is_empty(), "text-only prototype was incorrectly certified")
	_check(capability.scored_observation_profiles.is_empty(), "text-only prototype was incorrectly marked scored")
	_check(simulation.decision_window_duration("model-duel-v0", 1) == 10, "duel horizon accepted one tick")
	_check(simulation.decision_window_duration("scripted-duel-v0", 20) == 10, "duel horizon accepted 20 ticks")
	var original_checkpoint: Dictionary = simulation.checkpoint()
	var hybrid_errors := simulation.configure({
		"episode_id": "ep_unimplemented_hybrid",
		"mode": "solo-curriculum-v0",
		"task_id": "orientation-v0",
		"observation_profile": "hybrid-visible-v1",
		"maximum_episode_ticks": 600,
	})
	_check(
		"observation_profile_unsupported" in hybrid_errors,
		"hybrid profile was accepted without participant-frame authority",
	)
	_check(simulation.checkpoint() == original_checkpoint, "rejected profile reset authority state")
	var duel_errors := simulation.configure({
		"episode_id": "ep_unimplemented_duel",
		"mode": "model-duel-v0",
		"task_id": "orientation-v0",
		"observation_profile": "text-visible-v1",
		"maximum_episode_ticks": 1800,
		"participant_ids": ["participant_0", "participant_1"],
	})
	_check("mode_unsupported" in duel_errors, "unimplemented duel mode was accepted")
	_check(simulation.checkpoint() == original_checkpoint, "rejected duel reset authority state")


func _test_shared_conformance_policy() -> void:
	var fixture_path := ProjectSettings.globalize_path(
		"res://../game/embodiment_protocol/conformance/protocol-conformance.v1.json"
	)
	var file := FileAccess.open(fixture_path, FileAccess.READ)
	_check(file != null, "shared protocol conformance fixture could not be opened")
	if file == null:
		return
	var fixture: Variant = JSON.parse_string(file.get_as_text())
	_check(fixture is Dictionary, "shared protocol conformance fixture was not JSON object")
	if not fixture is Dictionary:
		return
	_check(
		str(fixture.corpus_version) == "llm-controller-conformance/1",
		"shared conformance corpus version drifted",
	)
	for case: Dictionary in fixture.reset_capability_cases:
		var simulation := SoloSimulation.new()
		var participant_count := 1 if case.mode == "solo-curriculum-v0" else 2
		var configured_participants := ["participant_0"] \
			if participant_count == 1 else ["participant_0", "participant_1"]
		var errors := simulation.configure({
			"episode_id": "ep_fixture_%s" % case.id,
			"mode": case.mode,
			"task_id": case.task_id,
			"observation_profile": case.profile,
			"maximum_episode_ticks": 600,
			"participant_ids": configured_participants,
		})
		_check(
			errors.is_empty() == bool(case.expected_accepted),
			"reset capability fixture disagreed for %s: %s" % [case.id, str(errors)],
		)
	var horizon_probe := SoloSimulation.new()
	var validator := ProtocolValidator.new()
	for case: Dictionary in fixture.action_cases:
		var raw: PackedByteArray
		if case.input.has("raw_json"):
			raw = str(case.input.raw_json).to_utf8_buffer()
		else:
			var instance: Dictionary = _restore_fixture_integers(case.input.instance)
			if case.input.has("utf8_repeat"):
				var repeat: Dictionary = case.input.utf8_repeat
				_check(str(repeat.pointer) == "/memory_update", "unsupported fixture JSON pointer")
				instance.memory_update = str(repeat.text).repeat(int(repeat.count))
			raw = JSON.stringify(instance, "", true, false).to_utf8_buffer()
		var parsed: Dictionary = validator.parse_action(raw)
		_check(
			bool(parsed.valid) == bool(case.expected.wire_valid),
			"strict wire fixture disagreed for %s: %s" % [case.id, str(parsed.codes)],
		)
		var disposition := "no_input"
		var reason: Variant = "invalid"
		if bool(parsed.valid):
			if parsed.instance.observation_seq != case.context.observation_seq:
				reason = "stale_observation"
			elif case.context.mode in ["scripted-duel-v0", "model-duel-v0"] \
				and parsed.instance.control.duration_ticks != 10:
				reason = "invalid"
			else:
				disposition = "accepted"
				reason = null
		_check(disposition == case.expected.disposition, "action disposition fixture disagreed for %s" % case.id)
		_check(reason == case.expected.reason, "action reason fixture disagreed for %s" % case.id)
		var expected_ticks := int(case.expected.advance_ticks)
		var policy_ticks := horizon_probe.decision_window_duration(
			str(case.context.mode), int(case.context.window_ticks)
		)
		_check(
			policy_ticks == expected_ticks,
			"decision horizon fixture disagreed for %s" % case.id,
		)
	var bom_result: Dictionary = validator.parse_action(PackedByteArray([0xef, 0xbb, 0xbf, 123, 125]))
	_check(not bool(bom_result.valid), "UTF-8 BOM was accepted at strict wire boundary")
	var invalid_utf8: Dictionary = validator.parse_action(PackedByteArray([0xc3, 0x28]))
	_check(not bool(invalid_utf8.valid), "invalid UTF-8 was accepted at strict wire boundary")
	for case: Dictionary in fixture.observation_cases:
		_check(
			validator.observation_schema_valid(_restore_fixture_integers(case.instance)) \
				== bool(case.expected_schema_valid),
			"observation schema fixture disagreed for %s" % case.id,
		)
	for case: Dictionary in fixture.decision_window_cases:
		var instance: Dictionary = _restore_fixture_integers(case.instance)
		_check(
			validator.decision_window_schema_valid(instance) == bool(case.expected_schema_valid),
			"decision-window schema fixture disagreed for %s" % case.id,
		)


func _restore_fixture_integers(value: Variant) -> Variant:
	if typeof(value) == TYPE_FLOAT:
		return int(value)
	if value is Array:
		var restored: Array = []
		for item: Variant in value:
			restored.append(_restore_fixture_integers(item))
		return restored
	if value is Dictionary:
		var restored := {}
		for key: Variant in value:
			restored[key] = _restore_fixture_integers(value[key])
		return restored
	return value


func _test_semantic_shortcut_rejected() -> void:
	var simulation = _simulation("ep_rejection_test")
	var shortcut := _action(simulation, "shortcut", 10)
	shortcut["move_to"] = [0, -7000]
	var result := simulation.step(shortcut)
	var receipt: Dictionary = result.receipts.participant_0
	_check(not bool(receipt.accepted), "semantic move_to shortcut was accepted")
	_check(int(result.observations.participant_0.tick) == 10, "neutral fallback did not advance time")
	_check(int(receipt.applied_ticks) == 10, "neutral fallback did not record its full window")
	_check("action_shape_invalid" in receipt.codes, "rejection code was not stable")
	_check("no_input" in receipt.codes, "invalid action was not recorded as no_input")
	_check(result.observations.size() == 1, "result observations were not participant-indexed")
	_check(result.receipts.size() == 1, "result receipts were not participant-indexed")


func _test_missing_input_falls_back_to_neutral() -> void:
	var simulation = _simulation("ep_missing_input")
	var result := simulation.step_window({
		"episode_id": simulation.episode_id,
		"observation_seq": 0,
		"mode": "solo-curriculum-v0",
		"start_tick": 0,
		"duration_ticks": 7,
		"decisions": {"participant_0": {
			"disposition": "no_input",
			"action": null,
			"fallback": "neutral",
			"no_input_reason": "missing",
		}},
	})
	var receipt: Dictionary = result.receipts.participant_0
	_check(not bool(receipt.accepted), "missing input was marked accepted")
	_check("no_input" in receipt.codes, "missing input disposition was not recorded")
	_check(str(receipt.no_input_reason) == "missing", "missing-input reason was not retained")
	_check(int(receipt.start_tick) == 0 and int(receipt.end_tick) == 7, "neutral window ticks drifted")
	_check(int(receipt.effects[0].value) == 7, "neutral effect did not record applied ticks")
	var neutral_agency: Dictionary = simulation.presentation_source_snapshot().agency
	_check(neutral_agency.receipt.disposition == "no_input", "solo HUD source omitted no_input")
	_check(neutral_agency.controller.duration_ticks == 7, "solo HUD neutral duration drifted")
	_check(neutral_agency.intent_label.is_empty(), "solo no_input invented an intent")


func _test_presentation_agency_is_hash_invariant() -> void:
	var simulation = _simulation("ep_presentation_agency")
	var action := _action(simulation, "agency_action", 3)
	action.intent_label = "Face the visible beacon."
	action.control.look_x = 500
	var result := simulation.step(action)
	_check(result.receipts.participant_0.accepted, "solo agency fixture action was rejected")
	var hash_before: String = simulation.checkpoint_hash()
	var source: Dictionary = simulation.presentation_source_snapshot()
	_check(simulation.checkpoint_hash() == hash_before, "solo agency projection changed authority hash")
	_check(source.agency.controller.look_x == 500, "solo controller evidence drifted")
	_check(source.agency.controller.duration_ticks == 3, "solo controller duration drifted")
	_check(source.agency.receipt.disposition == "accepted", "solo accepted receipt was not projected")
	_check(source.agency.intent_label == "Face the visible beacon.", "solo intent label drifted")


func _test_strict_types_and_utf8_limits() -> void:
	var float_simulation = _simulation("ep_float_rejection")
	var float_action := _action(float_simulation, "float_axis", 1)
	float_action.control.move_x = 1.0
	var float_result := float_simulation.step(float_action)
	_check("move_x_invalid" in float_result.receipts.participant_0.codes, "float axis was accepted")

	var bool_simulation = _simulation("ep_bool_rejection")
	var bool_action := _action(bool_simulation, "bool_seq", 1)
	bool_action.observation_seq = false
	var bool_result := bool_simulation.step(bool_action)
	_check(
		"observation_seq_mismatch" in bool_result.receipts.participant_0.codes,
		"boolean observation sequence was accepted as integer zero",
	)

	var exact_simulation = _simulation("ep_utf8_exact")
	var exact_action := _action(exact_simulation, "utf8_exact", 1)
	exact_action.memory_update = "😀".repeat(512)
	var exact_result := exact_simulation.step(exact_action)
	_check(bool(exact_result.receipts.participant_0.accepted), "2 KB UTF-8 memory was rejected")

	var large_simulation = _simulation("ep_utf8_large")
	var large_action := _action(large_simulation, "utf8_large", 1)
	large_action.memory_update = "😀".repeat(513)
	var large_result := large_simulation.step(large_action)
	_check(
		"memory_update_too_large" in large_result.receipts.participant_0.codes,
		"memory larger than 2 KB UTF-8 was accepted",
	)


func _test_solo_window_bounds() -> void:
	var simulation = _simulation("ep_solo_horizons")
	var one_tick := simulation.step(_action(simulation, "one_tick", 1))
	_check(int(one_tick.receipts.participant_0.applied_ticks) == 1, "one-tick solo window failed")
	var twenty_ticks := simulation.step(_action(simulation, "twenty_ticks", 20))
	_check(int(twenty_ticks.receipts.participant_0.applied_ticks) == 20, "20-tick solo window failed")


func _test_cross_runtime_checkpoint_hash() -> void:
	var simulation = _simulation("ep_hash_fixture")
	var actual_hash: String = simulation.checkpoint_hash()
	_check(
		actual_hash == "252bf04813da94df02986249451b1c334aaa7741b83868f7273e2459854cf8bf",
		"Godot checkpoint hash diverged from canonical UTF-8 JSON SHA-256 fixture: %s" % actual_hash,
	)


func _test_authority_module_boundaries() -> void:
	var clear_move: Dictionary = ArenaMap.move(Vector2i(0, 0), 1000, 0)
	_check(clear_move.position_mt == Vector2i(200, 0), "integer arena motion drifted")
	_check(clear_move.contact == "clear", "clear arena motion reported collision")
	var blocked_move: Dictionary = ArenaMap.move(Vector2i(9950, 0), 1000, 0)
	_check(blocked_move.position_mt == Vector2i(10000, 0), "arena clamp drifted")
	_check(blocked_move.contact == "blocked_front", "arena boundary did not report collision")
	_check(ArenaMap.divide_toward_zero(-5, 2) == -2, "signed integer division drifted")
	_check(Visibility.relative_bearing(Vector2i(0, -1), 0) == "front", "north bearing drifted")
	_check(Visibility.relative_bearing(Vector2i(1, 0), 0) == "right", "east bearing drifted")
	_check(Visibility.distance_band(Vector2i(1200, 0), 1200) == "touching", "touching band drifted")
	_check(Visibility.distance_band(Vector2i(9001, 0), 1200) == "far", "far band drifted")
	var simulation = _simulation("ep_module_boundaries")
	var events: Array[Dictionary] = []
	EventLedger.append(simulation, events, "beacon_entered", "Entered.")
	_check(events.size() == 1 and events[0].event_id == "evt_0_0", "event ledger sequence drifted")
	_check(simulation.event_seq == 1, "event ledger did not advance sequence")
	var checkpoint: Dictionary = simulation.checkpoint()
	_check(not CheckpointSerializer.contains_float(checkpoint), "authority checkpoint contains a float")
	_check(
		CheckpointSerializer.hash_checkpoint(checkpoint) == simulation.checkpoint_hash(),
		"checkpoint serializer and façade hash disagreed",
	)
	var observation: Dictionary = simulation.observe()
	_check(not CheckpointSerializer.contains_float(observation), "player observation contains a float")
	_check(not observation.has("operator_position_mt"), "observation leaked exact authority position")
	_check(not observation.visible_entities[0].has("position_mt"), "entity observation leaked exact position")


func _test_granular_orientation_success() -> void:
	var simulation = _simulation("ep_success_test")
	var windows := 0
	while not bool(simulation.terminal.ended) and windows < 10:
		var result := simulation.step(_action(simulation, "forward_%02d" % windows, 20))
		var receipt: Dictionary = result.receipts.participant_0
		_check(bool(receipt.accepted), "valid controller window was rejected")
		_check(int(receipt.applied_ticks) <= 20, "action exceeded its bounded horizon")
		windows += 1
	_check(bool(simulation.terminal.ended), "forward controller sequence did not finish")
	_check(str(simulation.terminal.outcome) == "success", "orientation outcome was not success")
	_check(str(simulation.terminal.reason) == "beacon_held", "orientation reason was wrong")
	_check(windows == 4, "orientation did not require four granular action windows")
	_check(simulation.tick == 73, "orientation terminal tick drifted: %d" % simulation.tick)
	_check(not simulation.recent_events.is_empty(), "terminal authority event was missing")
	for event: Dictionary in simulation.recent_events:
		_check(
			event.keys().size() == 6 and event.has("event_id") and event.has("tick")
				and event.has("kind") and event.has("summary") and event.has("participant_ids")
				and event.has("data"),
			"authority event did not use the typed event envelope",
		)
		_check(str(event.event_id).begins_with("evt_"), "authority event id was not stable")
		_check(event.participant_ids == ["participant_0"], "authority event leaked participant scope")


func _test_repeatability() -> void:
	var first = _simulation("ep_repeatable")
	var second = _simulation("ep_repeatable")
	for index: int in 3:
		var first_result := first.step(_action(first, "step_%d" % index, 17))
		var second_result := second.step(_action(second, "step_%d" % index, 17))
		_check(
			str(first_result.state_hash) == str(second_result.state_hash),
			"identical action transcript produced different checkpoint hashes",
		)
	_check(first.checkpoint() == second.checkpoint(), "repeatable checkpoints differ")


func _action(
	simulation, action_id: String, duration_ticks: int
) -> Dictionary:
	return {
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": simulation.episode_id,
		"observation_seq": simulation.observation_seq,
		"action_id": action_id,
		"control": {
			"move_x": 0,
			"move_y": 1000,
			"look_x": 0,
			"look_y": 0,
			"duration_ticks": duration_ticks,
			"buttons": {
				"interact": false,
				"primary": false,
				"guard": false,
				"dash": false,
				"ability_1": false,
				"ability_2": false,
				"cycle_item": false,
				"cancel": false,
			},
		},
		"intent_label": "Walk toward the visible beacon.",
		"memory_update": "Beacon remains ahead.",
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
