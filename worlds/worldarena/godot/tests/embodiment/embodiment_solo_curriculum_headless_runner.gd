extends SceneTree

const SoloSimulation := preload("res://scripts/embodiment/embodiment_solo_simulation.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_stage_b()
	_test_stage_c()
	_test_stage_c_range_departure_interrupts()
	_test_stage_d()
	_test_stage_d_relay_range_failure()
	_test_unavailable_inputs_preserve_controller_effects()
	_test_stage_d_no_input_advances_neutral()
	_test_stage_d_receipt_effects_and_cooldowns()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_CURRICULUM_FAILURE: %s" % failure)
		print("EMBODIMENT_CURRICULUM_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_CURRICULUM_OK")
	quit(0)


func _simulation(task_id: String):
	var simulation := SoloSimulation.new()
	var errors := simulation.configure({
		"episode_id": "ep_%s_test" % task_id.trim_suffix("-v0"),
		"mode": "solo-curriculum-v0",
		"task_id": task_id,
		"observation_profile": "text-visible-v1",
		"maximum_episode_ticks": 600,
		"participant_ids": ["participant_0"],
	})
	_check(errors.is_empty(), "%s configuration failed: %s" % [task_id, str(errors)])
	return simulation


func _test_stage_b() -> void:
	var simulation = _simulation("interaction-v0")
	_move_to_resource(simulation)
	_step(simulation, "gather_b", 4, 0, 0, 0, {"interact": true})
	_check(simulation.inventory_material_units == 1, "Stage B did not gather one unit")
	_turn_around_and_return(simulation)
	var result := _step(simulation, "deposit_b", 1, 0, 0, 0, {"interact": true})
	_check(bool(result.terminal.ended), "Stage B did not end after deposit")
	_check(str(result.terminal.reason) == "resource_deposited", "Stage B reason drifted")
	_check("deposit_complete" in result.receipts.participant_0.codes, "Stage B receipt omitted deposit")


func _test_stage_c() -> void:
	var simulation = _simulation("construction-v0")
	_move_to_resource(simulation)
	_step(simulation, "turn_miss", 1, 0, 0, 1000)
	var miss := _step(simulation, "miss_resource", 1, 0, 0, 0, {"interact": true})
	_check("interaction_misaligned" in miss.receipts.participant_0.codes, "Stage C omitted miss")
	_step(simulation, "correct_resource", 1, 0, 0, -1000)
	_step(simulation, "gather_c_0", 4, 0, 0, 0, {"interact": true})
	_step(simulation, "gather_c_1", 4, 0, 0, 0, {"interact": true})
	_check(simulation.inventory_material_units == 2, "Stage C did not repeat gathering")
	_turn_around_and_return(simulation)
	_step(simulation, "deposit_c", 1, 0, 0, 0, {"interact": true})
	_check(simulation.deposited_material_units == 2, "Stage C deposit total drifted")
	_step(simulation, "face_pad", 3, 0, 0, -1000)
	_step(simulation, "approach_pad", 12, 0, 1000, 0)
	_step(simulation, "align_pad", 1, 0, 0, 1000)
	var partial := _step(simulation, "build_partial", 3, 0, 0, 0, {"interact": true})
	_check("construction_progress" in partial.receipts.participant_0.codes, "Stage C omitted build progress")
	var interruption := _step(simulation, "build_interrupt", 1, 0, 0, 0)
	_check("construction_interrupted" in interruption.receipts.participant_0.codes, "Stage C omitted interruption")
	var complete := _step(simulation, "build_complete", 3, 0, 0, 0, {"interact": true})
	_check(bool(complete.terminal.ended), "Stage C did not end after repeated construction")
	_check(str(complete.terminal.reason) == "barricade_built", "Stage C reason drifted")
	_check("construction_complete" in complete.receipts.participant_0.codes, "Stage C completion receipt drifted")


func _test_stage_c_range_departure_interrupts() -> void:
	var simulation = _simulation("construction-v0")
	simulation.operator_position_mt = simulation.build_pad_position_mt
	simulation.deposited_material_units = simulation.ConstructionSystem.BARRICADE_MATERIAL_REQUIRED
	_step(simulation, "start_build_before_departure", 1, 0, 0, 0, {"interact": true})
	_check(simulation.construction_active, "Stage C construction did not become active")
	simulation.operator_position_mt = simulation.build_pad_position_mt + Vector2i(
		simulation.ConstructionSystem.BUILD_RANGE_MT + 1, 0
	)
	var departure := _step(
		simulation, "depart_active_build", 1, 0, 0, 0, {"interact": true}
	)
	_check(not simulation.construction_active, "leaving the build pad stranded active construction")
	_check(
		"construction_out_of_range" in departure.receipts.participant_0.codes,
		"build-pad departure omitted out-of-range receipt evidence",
	)
	var kinds: Array = departure.public_events.map(func(event: Dictionary): return event.kind)
	_check("construction_interrupted" in kinds, "build-pad departure omitted interruption event")
	_check("construction_out_of_range" in kinds, "build-pad departure omitted range event")


func _test_stage_d() -> void:
	var simulation = _simulation("neutral-encounter-v0")
	_step(simulation, "approach_d_0", 20, 0, 1000, 0)
	_step(simulation, "approach_d_1", 10, 0, 1000, 0)
	var first_hit := _step(simulation, "primary_d_0", 1, 0, 0, 0, {"primary": true})
	_check("primary_hit" in first_hit.receipts.participant_0.codes, "Stage D first attack missed")
	_check(
		_effect_value(first_hit.receipts.participant_0.effects, "primary_damage") > 0,
		"Stage D receipt discarded primary damage effect",
	)
	var guarded := _step(simulation, "guard_d", 5, 0, 0, 0, {"guard": true})
	_check("guard_active" in guarded.receipts.participant_0.codes, "Stage D guard did not activate")
	_check(
		_effect_value(guarded.receipts.participant_0.effects, "damage_prevented") > 0,
		"Stage D receipt discarded guarded damage reduction",
	)
	var second_hit := _step(simulation, "primary_d_1", 1, 0, 0, 0, {"primary": true})
	_check("neutral_retreating" in second_hit.receipts.participant_0.codes, "Stage D neutral did not retreat")
	_step(simulation, "pursue_d", 5, 0, 1000, 0, {"guard": true})
	var third_hit := _step(simulation, "primary_d_2", 1, 0, 0, 0, {"primary": true})
	_check("neutral_defeated" in third_hit.receipts.participant_0.codes, "Stage D neutral was not defeated")
	_step(simulation, "approach_relay_d", 4, 0, 1000, 0)
	var relay := _step(simulation, "relay_d", 3, 0, 0, 0, {"interact": true})
	_check(bool(relay.terminal.ended), "Stage D relay did not terminate")
	_check(str(relay.terminal.reason) == "relay_activated", "Stage D reason drifted")
	_check("relay_activated" in relay.receipts.participant_0.codes, "Stage D receipt omitted relay activation")


func _test_stage_d_relay_range_failure() -> void:
	var simulation = _simulation("neutral-encounter-v0")
	simulation.neutral_state = "defeated"
	simulation.operator_position_mt = simulation.relay_position_mt
	_step(simulation, "relay_progress_before_departure", 1, 0, 0, 0, {"interact": true})
	_check(simulation.relay_activation_ticks == 1, "in-range relay interaction did not progress")
	simulation.operator_position_mt = simulation.relay_position_mt + Vector2i(
		simulation.NeutralController.RELAY_RADIUS_MT + 1, 0
	)
	var result := _step(simulation, "relay_out_of_range", 1, 0, 0, 0, {"interact": true})
	_check(
		"relay_out_of_range" in result.receipts.participant_0.codes,
		"out-of-range relay interaction was silent",
	)
	_check(
		"relay_activation_cancelled" in result.receipts.participant_0.codes,
		"leaving relay range omitted cancellation receipt evidence",
	)
	_check(
		result.public_events.any(func(event: Dictionary): return event.kind == "relay_out_of_range"),
		"out-of-range relay event was missing",
	)
	_check(simulation.relay_activation_ticks == 0, "out-of-range relay interaction advanced progress")


func _test_unavailable_inputs_preserve_controller_effects() -> void:
	var simulation = _simulation("neutral-encounter-v0")
	simulation.neutral_position_mt = simulation.operator_position_mt + Vector2i(0, -1000)
	var result := _step(simulation, "unavailable_with_primary", 1, 0, 0, 0, {
		"ability_1": true, "ability_2": true, "cycle_item": true, "primary": true,
	})
	var codes: Array = result.receipts.participant_0.codes
	_check("primary_hit" in codes, "unavailable controls suppressed a valid primary effect")
	for button: String in ["ability_1", "ability_2", "cycle_item"]:
		_check(("%s_unavailable" % button) in codes, "%s lacked unavailable receipt evidence" % button)
	var unavailable_events: Array = result.public_events.filter(
		func(event: Dictionary): return event.kind == "controller_input_unavailable"
	)
	_check(unavailable_events.size() == 3, "unavailable inputs did not emit one event each")


func _test_stage_d_no_input_advances_neutral() -> void:
	var simulation = _simulation("neutral-encounter-v0")
	_step(simulation, "approach_no_input", 20, 0, 1000, 0)
	var before_position: Vector2i = simulation.neutral_position_mt
	var result: Dictionary = simulation.step_window({
		"episode_id": simulation.episode_id,
		"observation_seq": simulation.observation_seq,
		"mode": simulation.mode,
		"start_tick": simulation.tick,
		"duration_ticks": 10,
		"decisions": {"participant_0": {
			"disposition": "no_input", "action": null,
			"fallback": "neutral", "no_input_reason": "invalid",
		}},
	})
	_check(result.receipts.participant_0.applied_ticks == 10, "Stage D no-input stalled time")
	_check(simulation.neutral_position_mt != before_position, "Stage D no-input froze neutral authority")


func _test_stage_d_receipt_effects_and_cooldowns() -> void:
	var simulation = _simulation("neutral-encounter-v0")
	var dash := _step(simulation, "dash_integrated", 1, 0, 0, 0, {"dash": true})
	var dash_receipt: Dictionary = dash.receipts.participant_0
	_check("dash_applied" in dash_receipt.codes, "integrated dash was not applied")
	_check(
		_effect_value(dash_receipt.effects, "dash_distance_mt") > 0,
		"integrated dash distance effect was discarded",
	)
	_check(
		not dash_receipt.effects.any(
			func(effect: Dictionary): return effect.kind == "beacon_hold_ticks"
		),
		"Stage D receipt retained irrelevant beacon effects",
	)
	var cooling := _step(simulation, "dash_cooling", 1, 0, 0, 0, {"dash": true})
	_check("dash_cooldown" in cooling.receipts.participant_0.codes, "dash cooldown was not visible")


func _move_to_resource(simulation) -> void:
	_step(simulation, "approach_0", 20, 0, 1000, 0)
	_step(simulation, "approach_1", 20, 0, 1000, 0)
	_step(simulation, "approach_2", 3, 0, 1000, 0)


func _turn_around_and_return(simulation) -> void:
	_step(simulation, "turn_home", 4, 0, 0, 1000)
	_step(simulation, "return_0", 20, 0, 1000, 0)
	_step(simulation, "return_1", 20, 0, 1000, 0)
	_step(simulation, "return_2", 3, 0, 1000, 0)


func _step(
	simulation,
	action_id: String,
	duration_ticks: int,
	move_x: int,
	move_y: int,
	look_x: int,
	button_overrides: Dictionary = {},
) -> Dictionary:
	var buttons := {
		"interact": false, "primary": false, "guard": false, "dash": false,
		"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false,
	}
	buttons.merge(button_overrides, true)
	return simulation.step({
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": simulation.episode_id,
		"observation_seq": simulation.observation_seq,
		"action_id": action_id,
		"control": {
			"move_x": move_x, "move_y": move_y, "look_x": look_x, "look_y": 0,
			"duration_ticks": duration_ticks, "buttons": buttons,
		},
		"intent_label": action_id,
		"memory_update": action_id,
	})


func _effect_value(effects: Array, kind: String) -> int:
	var total := 0
	for effect: Dictionary in effects:
		if effect.kind == kind:
			total += int(effect.value)
	return total


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
