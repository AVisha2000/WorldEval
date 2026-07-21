extends SceneTree

const SetupPanel := preload("res://scripts/duel/presentation/duel_setup_panel.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const EXPECTED_GOLDEN := "17d8bf307769288e2584f15695d0c31636e4f0a14635bbe658b832e8259309d1"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var setup := SetupPanel.new()
	root.add_child(setup)
	await process_frame

	_check(setup.mode_buttons.size() == 2, "setup did not expose both decision modes")
	_check(setup.faction_buttons.size() == 4, "setup did not expose all four faction presets")
	_check(SetupPanel.PROVIDER_ORDER == ["openai", "baseline.noop", "baseline.seeded_random", "baseline.rush"], "setup provider registry changed")
	_check(setup.player_provider_inputs.size() == 2, "setup did not expose one provider selector per player")
	var invalid: Dictionary = setup.validate_setup()
	_check(not bool(invalid["valid"]), "empty model slots unexpectedly validated")

	for faction_id in SetupPanel.FACTION_ORDER:
		_check(setup.select_faction(faction_id), "could not select faction " + faction_id)
		var faction_config := setup.build_submission()
		_check(str(faction_config["faction_preset_id"]) == faction_id, "selected faction not reflected in config")
		_check(bool(faction_config["mirror_faction"]), "faction was not mirrored")

	setup.set_player_label(0, "Atlas")
	setup.set_player_label(1, "Nova")
	setup.set_player_model(0, "gpt-5.4")
	setup.set_player_model(1, "gpt-5.4-mini")
	setup.set_player_reasoning(0, "high")
	setup.set_player_reasoning(1, "medium")
	setup.set_protected_key(0, "TOP-SECRET-A")
	setup.set_protected_key(1, "TOP-SECRET-B")
	setup.set_faction_integrity("a".repeat(64), true)
	_check(bool(setup.validate_setup()["valid"]), "complete setup did not validate")

	var emitted: Array[Dictionary] = []
	var launch_requests: Array[Dictionary] = []
	setup.setup_submitted.connect(func(config: Dictionary) -> void: emitted.append(config))
	setup.launch_requested.connect(func(request: Dictionary) -> void: launch_requests.append(request.duplicate(true)))
	_check(setup.submit_if_valid(), "valid setup did not submit")
	_check(emitted.size() == 1, "setup emitted the wrong number of configs")
	_check(launch_requests.size() == 1, "setup did not emit one protected launch request")
	_check(not setup.protected_keys_are_clear(), "protected API fields cleared before HTTP dispatch acceptance")
	var submitted := emitted[0]
	_check(not _contains_value(submitted, "TOP-SECRET-A"), "player A secret leaked into config")
	_check(not _contains_value(submitted, "TOP-SECRET-B"), "player B secret leaked into config")
	var launch_request := launch_requests[0]
	_check(_contains_value(launch_request, "TOP-SECRET-A"), "player A secret did not reach protected launch request")
	_check(_contains_value(launch_request, "TOP-SECRET-B"), "player B secret did not reach protected launch request")
	_check(not launch_request.has("fairness") and not launch_request.has("protocol_version"), "UI-only metadata crossed the API boundary")
	_check(str(launch_request["authority_launch_mode"]) == "caller_owned", "interactive authority mode changed")
	setup.acknowledge_launch_dispatched()
	_check(setup.protected_keys_are_clear(), "protected API fields were not cleared after dispatch acceptance")
	_check(int(submitted["fairness"]["working_memory_bytes_per_player"]) == 4096, "memory budget fairness summary changed")
	_check(bool(submitted["fairness"]["faction_content_hash_equal"]), "verified faction equality was lost")

	setup.set_official_locked(false)
	_check(setup.select_mode("fixed_simultaneous"), "fixed mode selection failed")
	var fixed_config := setup.build_submission()
	_check(int(fixed_config["decision_period_ticks"]) == 100, "fixed cadence changed")
	_check(int(fixed_config["response_deadline_ms"]) == 45000, "fixed deadline changed")
	_check(setup.select_mode("continuous_realtime"), "continuous mode selection failed")
	var continuous_config := setup.build_submission()
	_check(int(continuous_config["decision_period_ticks"]) == 50, "continuous cadence changed")
	_check(int(continuous_config["response_deadline_ms"]) == 8000, "continuous deadline changed")

	setup.memory_select.select(1)
	_check(str(setup.build_launch_request()["memory_policy"]) == "adaptive-series", "adaptive-series wire ID changed")
	setup.set_protected_key(1, "MUST-CLEAR-FOR-BASELINE")
	setup.set_player_service_tier(1, "priority")
	_check(setup.select_player_provider(1, "baseline.rush"), "rush baseline provider selection failed")
	_check(setup.player_model_inputs[1].text == "baseline-rush-v1", "rush baseline model was not frozen")
	_check(str(setup.player_reasoning_inputs[1].get_item_metadata(setup.player_reasoning_inputs[1].selected)) == "none", "baseline reasoning was not forced to none")
	_check(setup.protected_key_inputs[1].text.is_empty() and setup.player_service_tier_inputs[1].text.is_empty(), "baseline retained key or tier")
	var baseline_player: Dictionary = setup.build_launch_request()["players"][1]
	_check(not baseline_player.has("credential") and not baseline_player.has("service_tier"), "baseline API payload contained hosted-provider options")
	setup.set_protected_key(0, "REENTERED-AFTER-DISPATCH")

	setup.set_faction_integrity("", false)
	setup.set_official_locked(true)
	_check(setup.official_locked, "official setup did not lock")
	_check(not bool(setup.validate_setup()["valid"]), "official setup validated before faction hash equality")
	setup.set_faction_integrity("a".repeat(64), true)
	_check(bool(setup.validate_setup()["valid"]), "official setup rejected host-verified faction equality")
	_check(not setup.select_mode("fixed_simultaneous"), "locked official mode could still change")
	_check(not setup.select_faction("vanguard-v1"), "locked official faction could still change")

	var summary := {
		"config_secret_free": not _contains_value(submitted, "TOP-SECRET-A") and not _contains_value(submitted, "TOP-SECRET-B"),
		"factions": setup.faction_buttons.size(),
		"locked": setup.official_locked,
		"modes": setup.mode_buttons.size(),
		"players": submitted["players"].size(),
	}
	var golden := Codec.sha256_canonical(summary)
	if not EXPECTED_GOLDEN.is_empty():
		_check(golden == EXPECTED_GOLDEN, "setup presentation golden changed: " + golden)
	setup.queue_free()
	await process_frame
	_finish("DUEL_SETUP_PANEL", golden, summary)


func _contains_value(value: Variant, needle: String) -> bool:
	if value is String:
		return value == needle or value.contains(needle)
	if value is Dictionary:
		for child: Variant in value.values():
			if _contains_value(child, needle):
				return true
	if value is Array:
		for child: Variant in value:
			if _contains_value(child, needle):
				return true
	return false


func _finish(prefix: String, golden: String, summary: Dictionary) -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error(prefix + "_FAILURE: " + failure)
		print("%s_FAILED count=%d hash=%s" % [prefix, _failures.size(), golden])
		quit(1)
		return
	print("%s_OK hash=%s summary=%s" % [prefix, golden, JSON.stringify(summary)])
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
