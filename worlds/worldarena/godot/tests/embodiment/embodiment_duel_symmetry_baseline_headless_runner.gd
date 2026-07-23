extends SceneTree

const BaselinePolicy := preload("res://scripts/embodiment/baselines/duel_baseline_policy.gd")
const SymmetryVerifier := preload("res://scripts/embodiment/fairness/duel_symmetry_verifier.gd")
const DuelAuthority := preload(
	"res://scripts/embodiment/duel_authority/embodiment_duel_authority.gd"
)

var _failures := PackedStringArray()


func _init() -> void:
	_test_exhaustive_arena_rotation()
	_test_complete_layout_symmetry()
	_test_layout_rejections()
	_test_baseline_contract_and_determinism()
	_test_shared_baseline_conformance()
	_test_baseline_tiers_and_side_neutrality()
	_test_authority_layout_and_baseline_self_play()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_DUEL_SUPPORT_FAILURE: %s" % failure)
		print("EMBODIMENT_DUEL_SUPPORT_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_DUEL_SUPPORT_OK")
	quit(0)


func _test_shared_baseline_conformance() -> void:
	var path := "res://../game/embodiment_protocol/conformance/duel-baseline-conformance.v1.json"
	var file := FileAccess.open(path, FileAccess.READ)
	_check(file != null, "shared baseline conformance fixture was unavailable")
	if file == null:
		return
	var fixture: Variant = JSON.parse_string(file.get_as_text())
	_check(fixture is Dictionary, "shared baseline conformance fixture was invalid JSON")
	if not fixture is Dictionary:
		return
	_check(
		str(fixture.get("format", "")) == "llm-controller/duel-baseline-conformance/1.0.0",
		"shared baseline conformance format drifted",
	)
	for raw_case: Variant in fixture.get("cases", []):
		if not raw_case is Dictionary:
			_check(false, "shared baseline conformance case was not an object")
			continue
		var case: Dictionary = raw_case
		var action := BaselinePolicy.make_action(str(case.tier), case.observation)
		var expected: Dictionary = _normalize_fixture_numbers(case.expected)
		var expected_intent := str(expected.get("intent_label", ""))
		expected.erase("intent_label")
		_check(action.control == expected, "shared baseline control drifted: %s" % case.id)
		_check(action.intent_label == expected_intent, "shared baseline intent drifted: %s" % case.id)


func _normalize_fixture_numbers(value: Variant) -> Variant:
	if value is Dictionary:
		var output := {}
		for key: Variant in value:
			output[key] = _normalize_fixture_numbers(value[key])
		return output
	if value is Array:
		var output := []
		for item: Variant in value:
			output.append(_normalize_fixture_numbers(item))
		return output
	if value is float and value == floor(value):
		return int(value)
	return value


func _test_exhaustive_arena_rotation() -> void:
	const HALF_EXTENT := 10_000
	# Exhaust every integer coordinate on both axes and every boundary point. The
	# square interior follows directly from independent axis negation.
	for coordinate: int in range(-HALF_EXTENT, HALF_EXTENT + 1):
		var probes := [
			Vector2i(coordinate, 0), Vector2i(0, coordinate),
			Vector2i(coordinate, -HALF_EXTENT), Vector2i(coordinate, HALF_EXTENT),
			Vector2i(-HALF_EXTENT, coordinate), Vector2i(HALF_EXTENT, coordinate),
		]
		for position: Vector2i in probes:
			var rotated := SymmetryVerifier.rotate_position_180(position)
			_check(abs(rotated.x) <= HALF_EXTENT and abs(rotated.y) <= HALF_EXTENT, "rotation escaped arena")
			_check(SymmetryVerifier.rotate_position_180(rotated) == position, "position rotation was not involutive")
	for heading: int in 8:
		var rotated_heading := SymmetryVerifier.rotate_heading_180(heading)
		_check(SymmetryVerifier.rotate_heading_180(rotated_heading) == heading, "heading rotation was not involutive")


func _test_complete_layout_symmetry() -> void:
	_check(SymmetryVerifier.validate_layout(_layout()).is_empty(), "valid mirrored layout was rejected")


func _test_layout_rejections() -> void:
	var relay_offset := _layout()
	relay_offset.central_relay.position_mt = [1, 0]
	_check("central_relay_not_rotation_fixed" in SymmetryVerifier.validate_layout(relay_offset), "off-center relay was accepted")
	var spawn_drift := _layout()
	spawn_drift.participant_spawns.participant_1.position_mt = [0, -5900]
	_check("participant_spawn_position_asymmetric" in SymmetryVerifier.validate_layout(spawn_drift), "asymmetric spawn was accepted")
	var feature_missing := _layout()
	feature_missing.features.pop_back()
	_check(_has_prefix(SymmetryVerifier.validate_layout(feature_missing), "feature_mirror_missing:"), "missing feature mirror was accepted")
	var property_drift := _layout()
	property_drift.features[1].radius_mt = 701
	_check(_has_prefix(SymmetryVerifier.validate_layout(property_drift), "feature_properties_asymmetric:"), "feature property drift was accepted")


func _test_baseline_contract_and_determinism() -> void:
	var observation := _observation("front", "near", 100, 6)
	for tier_id: String in BaselinePolicy.TIERS:
		var first := BaselinePolicy.make_action(tier_id, observation)
		var second := BaselinePolicy.make_action(tier_id, observation.duplicate(true))
		_check(first == second, "baseline output was nondeterministic for %s" % tier_id)
		_check(first.protocol_version == BaselinePolicy.PROTOCOL_VERSION, "baseline protocol drifted")
		_check(first.observation_seq == 6 and first.episode_id == "ep_duel_support", "baseline action correlation drifted")
		_check(first.control.duration_ticks == 10, "baseline emitted a non-duel horizon")
		_check(first.control.keys().size() == 6 and first.control.buttons.keys().size() == 8, "baseline control shape drifted")
		_check(first.memory_update == "", "baseline wrote participant memory")


func _test_baseline_tiers_and_side_neutrality() -> void:
	var opponent_near := _observation("front", "near", 100, 6)
	var scout := BaselinePolicy.choose_control(BaselinePolicy.TIER_SCOUT_V1, opponent_near)
	var balanced := BaselinePolicy.choose_control(BaselinePolicy.TIER_BALANCED_V1, opponent_near)
	_check(not scout.buttons.primary and balanced.buttons.primary, "baseline tiers did not expose stable difficulty")
	var low_health := _observation("front", "near", 35, 6)
	var guarded := BaselinePolicy.choose_control(BaselinePolicy.TIER_BALANCED_V1, low_health)
	_check(guarded.buttons.guard and guarded.move_y < 0, "balanced low-health response drifted")
	var distant := _observation("back_right", "far", 100, 6)
	var challenger := BaselinePolicy.choose_control(BaselinePolicy.TIER_CHALLENGER_V1, distant)
	_check(challenger.buttons.dash and challenger.move_x > 0 and challenger.move_y < 0, "challenger pursuit drifted")
	# Participant observations are player-relative. Identical scoped observations on
	# opposite seats must therefore produce byte-for-byte identical controls.
	var seat_a := _observation("front_left", "medium", 80, 9)
	var seat_b := seat_a.duplicate(true)
	seat_b.episode_id = "ep_duel_support_leg_b"
	_check(
		BaselinePolicy.choose_control(BaselinePolicy.TIER_CHALLENGER_V1, seat_a)
		== BaselinePolicy.choose_control(BaselinePolicy.TIER_CHALLENGER_V1, seat_b),
		"baseline policy depended on spawn side or episode identity",
	)


func _test_authority_layout_and_baseline_self_play() -> void:
	var authority := DuelAuthority.new()
	var errors := authority.configure({
		"episode_id": "ep_duel_baseline_self_play",
		"mode": "scripted-duel-v0",
		"participant_ids": ["participant_0", "participant_1"],
		"observation_profile": "text-visible-v1",
		"maximum_episode_ticks": DuelAuthority.MAXIMUM_TICKS,
	})
	_check(errors.is_empty(), "duel authority rejected baseline self-play configuration")
	var layout := {
		"arena_half_extent_mt": 10_000,
		"central_relay": {"position_mt": [0, 0]},
		"participant_spawns": {
			"participant_0": {
				"position_mt": authority.operators.participant_0.position_mt,
				"heading": authority.operators.participant_0.heading,
			},
			"participant_1": {
				"position_mt": authority.operators.participant_1.position_mt,
				"heading": authority.operators.participant_1.heading,
			},
		},
		"features": [],
	}
	_check(SymmetryVerifier.validate_layout(layout).is_empty(), "actual authority spawn layout was asymmetric")
	var terminal := {"ended": false, "outcome": "running", "reason": "running"}
	for _window_index: int in DuelAuthority.MAXIMUM_TICKS / BaselinePolicy.DUEL_WINDOW_TICKS:
		var observations: Dictionary = authority.observe_all()
		var action_0 := BaselinePolicy.make_action(
			BaselinePolicy.TIER_BALANCED_V1, observations.participant_0
		)
		var action_1 := BaselinePolicy.make_action(
			BaselinePolicy.TIER_BALANCED_V1, observations.participant_1
		)
		var result: Dictionary = authority.step_window(_decision_window(authority, action_0, action_1))
		terminal = result.terminal
		_check(result.receipts.participant_0.accepted, "baseline action was rejected for seat 0")
		_check(result.receipts.participant_1.accepted, "baseline action was rejected for seat 1")
		_check(
			authority.operators.participant_0.position_mt
			== -authority.operators.participant_1.position_mt,
			"baseline self-play position symmetry drifted",
		)
		_check(
			SymmetryVerifier.rotate_heading_180(authority.operators.participant_0.heading)
			== authority.operators.participant_1.heading,
			"baseline self-play heading symmetry drifted",
		)
		if bool(result.terminal.ended):
			break
	_check(bool(terminal.ended), "baseline self-play did not reach a terminal result")
	_check(authority.tick == DuelAuthority.MAXIMUM_TICKS, "baseline self-play horizon drifted")
	_check(
		str(terminal.outcome) == "draw" and str(terminal.reason) == "time_limit",
		"symmetric baseline self-play did not end in a side-neutral draw",
	)


func _decision_window(authority, action_0: Dictionary, action_1: Dictionary) -> Dictionary:
	return {
		"episode_id": authority.episode_id,
		"mode": authority.mode,
		"observation_seq": authority.observation_seq,
		"start_tick": authority.tick,
		"duration_ticks": BaselinePolicy.DUEL_WINDOW_TICKS,
		"decisions": {
			"participant_0": {
				"disposition": "accepted", "action": action_0,
				"fallback": "none", "no_input_reason": null,
			},
			"participant_1": {
				"disposition": "accepted", "action": action_1,
				"fallback": "none", "no_input_reason": null,
			},
		},
	}


func _layout() -> Dictionary:
	return {
		"arena_half_extent_mt": 10_000,
		"central_relay": {"position_mt": [0, 0]},
		"participant_spawns": {
			"participant_0": {"position_mt": [0, 6000], "heading": 0},
			"participant_1": {"position_mt": [0, -6000], "heading": 4},
		},
		"features": [
			{"id": "cover_nw", "mirror_id": "cover_se", "kind": "cover", "position_mt": [-2200, -1800], "radius_mt": 700},
			{"id": "cover_se", "mirror_id": "cover_nw", "kind": "cover", "position_mt": [2200, 1800], "radius_mt": 700},
			{"id": "cover_ne", "mirror_id": "cover_sw", "kind": "cover", "position_mt": [2200, -1800], "radius_mt": 700},
			{"id": "cover_sw", "mirror_id": "cover_ne", "kind": "cover", "position_mt": [-2200, 1800], "radius_mt": 700},
		]
	}


func _observation(
	opponent_bearing: String, opponent_distance: String, health_percent: int, observation_seq: int
) -> Dictionary:
	return {
		"episode_id": "ep_duel_support",
		"observation_seq": observation_seq,
		"self": {"health_percent": health_percent},
		"visible_entities": [
			{"id": "v_rival", "kind": "operator", "bearing": opponent_bearing, "distance": opponent_distance, "affordances": ["hostile"], "state": "active"},
			{"id": "v_relay", "kind": "relay", "bearing": "front", "distance": "medium", "affordances": ["interactable", "capture"], "state": "neutral"},
		],
	}


func _has_prefix(errors: PackedStringArray, prefix: String) -> bool:
	for error: String in errors:
		if error.begins_with(prefix):
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
