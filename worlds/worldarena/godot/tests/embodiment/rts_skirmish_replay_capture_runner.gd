extends SceneTree

## Produces a sealed deterministic rts-skirmish-v0 replay from additive rts-task-plan-v1
## windows.  The replay envelope retains ordinary ten-tick decisions for v2 compatibility;
## the private sibling evidence array retains the full structured plans used by authority.

const Canonical := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Dispatcher := preload("res://scripts/embodiment/v2/transport/control_game_dispatcher_v2.gd")
const Identity := preload("res://scripts/embodiment/v2/protocol/embodiment_protocol_package_identity_v2.gd")
const Verifier := preload("res://scripts/embodiment/v2/replay/embodiment_replay_verifier_v2.gd")

const PARTICIPANTS := ["participant_0", "participant_1"]
const MAX_WINDOWS := 120

var _failures := PackedStringArray()


func _init() -> void:
	_run()


func _run() -> void:
	var output := _output_path()
	if output.is_empty():
		_failures.append("output_path_missing")
		_finish()
		return
	var config := {
		"protocol_version": Identity.PROTOCOL_VERSION,
		"episode_id": "ep_rts_skirmish_demo_20260721",
		"mode": "model-duel-v0",
		"task_id": "rts-skirmish-v0",
		"seed": 20260721,
		"observation_profile": "text-visible-v1",
		"timing_track": "step-locked-v1",
		"maximum_episode_ticks": 1200,
		"participant_ids": PARTICIPANTS,
	}
	var dispatcher := Dispatcher.new()
	_check(dispatcher.configure(config).is_empty(), "RTS dispatcher rejected the capture configuration")
	if not _failures.is_empty():
		_finish()
		return
	var body := {
		"schema_version": "llm-controller/episode-replay/1.0.0",
		"protocol_version": Identity.PROTOCOL_VERSION,
		"protocol_package_sha256": Identity.SHA256,
		"config": config,
		"config_sha256": Canonical.sha256_bytes(Canonical.canonical_bytes(config)),
		"initial_observations": dispatcher.observe_all(),
		"initial_state_hash": dispatcher.checkpoint_hash(),
		"steps": [],
		"final_terminal": {},
		"final_state_hash": "",
		"rts_task_plan_evidence": [],
	}
	for index: int in MAX_WINDOWS:
		if bool(dispatcher.terminal().get("ended", false)):
			break
		var window := _window(dispatcher, config, index)
		_check(_task_window_shape_valid(window), "scripted RTS task window shape was invalid")
		if not _failures.is_empty():
			break
		var result: Dictionary = dispatcher.step_window(window)
		_check(not dispatcher.last_replay_decision_window.is_empty(), "RTS task window did not produce a compatibility replay window")
		body.steps.append({"decision_window": dispatcher.last_replay_decision_window, "result": result})
		body.rts_task_plan_evidence.append(dispatcher.last_rts_task_plan_window.duplicate(true))
	body.final_terminal = dispatcher.terminal()
	body.final_state_hash = dispatcher.checkpoint_hash()
	_check(bool(body.final_terminal.get("ended", false)), "scripted RTS match did not terminate")
	if _failures.is_empty():
		var replay := body.duplicate(true)
		replay["ledger_sha256"] = Canonical.sha256_bytes(Canonical.canonical_bytes(body))
		var payload := Canonical.canonical_bytes(replay)
		var result := Verifier.new().verify(payload)
		_check(bool(result.get("ok", false)), "RTS replay verifier rejected capture: %s" % str(result.get("code", "")))
		if _failures.is_empty():
			var file := FileAccess.open(output, FileAccess.WRITE)
			_check(file != null, "could not write RTS replay")
			if file != null:
				file.store_buffer(payload)
				file.close()
				print("RTS_SKIRMISH_REPLAY_CAPTURE_OK output=%s ticks=%d terminal=%s" % [output, int(dispatcher.authority.tick), str(body.final_terminal.get("reason", ""))])
	_finish()


func _window(dispatcher: Object, config: Dictionary, index: int) -> Dictionary:
	var authority = dispatcher.authority
	var plans := {}
	for participant_id: String in PARTICIPANTS:
		plans[participant_id] = _task_plan(authority, participant_id, index)
	return {
		"episode_id": config.episode_id,
		"observation_seq": authority.observation_seq,
		"mode": config.mode,
		"start_tick": authority.tick,
		"duration_ticks": 10,
		"plans": plans,
	}


func _task_plan(authority: Object, participant_id: String, index: int) -> Variant:
	var unit_id := _first_alive_unit(authority, participant_id)
	if unit_id.is_empty():
		# A defeated faction has no owned, living unit to assign.  The authority records this
		# as a neutral ten-tick window; it never pauses the deterministic clock.
		return null
	var team := "blue" if participant_id == "participant_0" else "red"
	var task := "gather"
	var target := "%s_tree_0" % team
	match str(authority.story_phase):
		"construction_and_arming":
			task = "build"
			target = "barracks" if int(authority.tick) < 590 else "tower"
		"rally":
			task = "rally"; target = "bridge"
		"bridge_battle":
			task = "attack_unit"; target = _first_alive_unit(authority, "participant_1" if participant_id == "participant_0" else "participant_0")
		"pursuit":
			if participant_id == "participant_1":
				task = "retreat"; target = "town_hall"
			else:
				task = "attack_unit"; target = "red_2"
		"tower_siege":
			task = "attack_structure"; target = "enemy_tower" if participant_id == "participant_0" else "enemy_town_hall"
		"town_hall_siege":
			task = "attack_structure"; target = "enemy_town_hall"
		"victory":
			task = "hold"; target = "bridge"
		_:
			if str(authority.story_phase) == "opening_economy" and int(authority.tick) >= 160:
				task = "return_material"; target = "town_hall"
			elif str(authority.story_phase) == "final_economy":
				task = "gather"; target = "%s_ore_1" % team
			elif int(authority.tick) >= 550:
				task = "arm"; target = "barracks"
	return {
		"protocol": "rts-task-plan-v1", "episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"intent_label": _task_label(task, target), "memory_update": "Demo policy window %d" % index,
		"assignments": [{"unit_id": unit_id, "task": task, "target_id": target}],
	}


func _first_alive_unit(authority: Object, participant_id: String) -> String:
	var prefix := "blue_" if participant_id == "participant_0" else "red_"
	for index: int in 3:
		var unit_id := prefix + str(index)
		if authority.units.has(unit_id) and bool(authority.units[unit_id].alive):
			return unit_id
	return ""


func _task_label(task: String, target: String) -> String:
	return "%s %s" % [task.capitalize().replace("_", " "), target.replace("_", " ")]


func _task_window_shape_valid(window: Dictionary) -> bool:
	return window.get("duration_ticks") == 10 and window.get("plans") is Dictionary \
		and window.plans.size() == 2


func _policy_action(authority: Object, participant_id: String, index: int) -> Dictionary:
	# The v1 cinematic is authority-scripted at milestone level.  The capture still records a
	# conventional ten-tick accepted controller receipt for every participant/window; it never
	# drives a presentation shortcut or mutates a position.
	return _neutral(authority, participant_id, index, "cinematic_authority")
	# Kept below as the legacy controller-policy reference for older replays.
	var op: Dictionary = authority.operators[participant_id]
	var tick: int = int(authority.tick)
	var rival_id := "participant_1" if participant_id == "participant_0" else "participant_0"
	# Cinematic Demo-provider story. Every transition remains a normal fixed-ten-tick action:
	# rapid economy, bridge clash, Red retreat, Blue reinforcement/rally, and Town Hall siege.
	if int(op.units_trained) < 2:
		return _economy_action(authority, participant_id, op, index, 2)
	if tick < 690:
		return _toward(authority, participant_id, op, Vector2i(-700, 700) if participant_id == "participant_0" else Vector2i(700, -700), {"dash": true}, "bridge_rally")
	if tick < 760:
		# Fixed opposite ends of the centre bridge keep both squads in weapon range without
		# a presentation-only teleport or a moving-target steering loop.
		var bridge_point := Vector2i(-500, 500) if participant_id == "participant_0" else Vector2i(500, -500)
		if participant_id == "participant_1":
			return _bridge_battle_action(authority, participant_id, op, bridge_point, authority.operators[rival_id].position_mt, true)
		return _bridge_battle_action(authority, participant_id, op, bridge_point, authority.operators[rival_id].position_mt)
	if participant_id == "participant_1":
		return _toward(authority, participant_id, op, authority.BARRACKS[participant_id], {"dash": true}, "red_retreat")
	if int(op.units_trained) < 3:
		return _economy_action(authority, participant_id, op, index, 3)
	return _toward(authority, participant_id, op, authority.TOWN_HALLS[rival_id], {"primary": true, "dash": true}, "blue_counterattack")


func _economy_action(authority: Object, participant_id: String, op: Dictionary, index: int, target_units: int) -> Dictionary:
	if not str(op.carrying).is_empty():
		return _toward(authority, participant_id, op, authority.TOWN_HALLS[participant_id], {"interact": true}, "deposit")
	if str(authority.barracks_state[participant_id]) != "active":
		if int(op.wood) < 1:
			return _toward(authority, participant_id, op, authority.WOOD["wood_0" if participant_id == "participant_0" else "wood_1"], {"interact": true}, "gather_wood")
		if int(op.ore) < 1:
			return _toward(authority, participant_id, op, authority.ORE["ore_0" if participant_id == "participant_0" else "ore_1"], {"interact": true}, "gather_ore")
		return _toward(authority, participant_id, op, authority.BARRACKS[participant_id], {"ability_1": true}, "build_barracks")
	if int(op.units_trained) < target_units:
		if int(op.wood) < 1:
			return _toward(authority, participant_id, op, authority.WOOD["wood_0" if participant_id == "participant_0" else "wood_1"], {"interact": true}, "gather_training_wood")
		return _toward(authority, participant_id, op, authority.BARRACKS[participant_id], {"ability_2": true}, "train_unit")
	return _neutral(authority, participant_id, index, "economy_wait")


func _toward(authority: Object, participant_id: String, op: Dictionary, target: Vector2i, buttons: Dictionary, label: String) -> Dictionary:
	var target_heading := _heading_to(op.position_mt, target)
	if target_heading != int(op.heading):
		# Heading is integrated every authority tick.  ±100 therefore gives one 45° turn across
		# a ten-tick decision window, visibly rotating before the following walk window.
		return _action(authority, participant_id, {"look_x": _turn_direction(int(op.heading), target_heading) * 100}, "%s_turn" % label)
	var offset: Vector2i = target - op.position_mt
	if offset.x * offset.x + offset.y * offset.y > 900 * 900:
		# A ten-tick window at full input covers 2,000 millitiles.  Scale the final
		# approach rather than oscillating across an interaction radius.
		var greatest: int = maxi(abs(offset.x), abs(offset.y))
		var approach_input: int = clampi(int((greatest * 1000 + 1999) / 2000), 120, 1000)
		var walking_buttons := buttons.duplicate(true)
		walking_buttons["move_y"] = approach_input
		return _action(authority, participant_id, walking_buttons, "%s_walk" % label)
	return _action(authority, participant_id, buttons, label)


func _attack_standoff(authority: Object, participant_id: String, op: Dictionary, rival_position: Vector2i) -> Dictionary:
	# Stay just outside the 1,200 mt capture radius while the opposing squad holds centre;
	# the 1,600 mt weapon range still yields visible combat without cancelling the objective.
	var offset: Vector2i = op.position_mt - rival_position
	var standoff := rival_position + Vector2i(1500 if offset.x >= 0 else -1500, 0)
	var remaining: Vector2i = standoff - op.position_mt
	var distance_sq: int = remaining.x * remaining.x + remaining.y * remaining.y
	if distance_sq > 250 * 250:
		return _toward(authority, participant_id, op, standoff, {"dash": true}, "counterattack_approach")
	var desired_heading := _heading_to(op.position_mt, rival_position)
	if desired_heading != int(op.heading):
		return _action(authority, participant_id, {"look_x": _turn_direction(int(op.heading), desired_heading) * 100}, "counterattack_turn")
	return _action(authority, participant_id, {"primary": true}, "counterattack")


func _bridge_battle_action(authority: Object, participant_id: String, op: Dictionary, bridge_point: Vector2i, rival_position: Vector2i, defend: bool = false) -> Dictionary:
	var offset: Vector2i = bridge_point - op.position_mt
	if offset.x * offset.x + offset.y * offset.y > 250 * 250:
		var bridge_heading := _heading_to(op.position_mt, bridge_point)
		if bridge_heading != int(op.heading):
			return _action(authority, participant_id, {"look_x": _turn_direction(int(op.heading), bridge_heading) * 100}, "bridge_battle_turn")
		var greatest: int = maxi(abs(offset.x), abs(offset.y))
		return _action(authority, participant_id, {"move_y": clampi(int((greatest * 1000 + 1999) / 2000), 120, 1000)}, "bridge_battle_walk")
	var desired_heading := _heading_to(op.position_mt, rival_position)
	if desired_heading != int(op.heading):
		return _action(authority, participant_id, {"look_x": _turn_direction(int(op.heading), desired_heading) * 100}, "bridge_battle_turn")
	return _action(authority, participant_id, {"guard": true} if defend else {"primary": true}, "bridge_battle_guard" if defend else "bridge_battle_attack")


func _heading_to(origin: Vector2i, target: Vector2i) -> int:
	var offset := target - origin
	if offset == Vector2i.ZERO:
		return 0
	var horizontal: bool = abs(offset.x) * 2 >= abs(offset.y)
	var vertical: bool = abs(offset.y) * 2 >= abs(offset.x)
	if horizontal and not vertical:
		return 2 if offset.x > 0 else 6
	if vertical and not horizontal:
		return 4 if offset.y > 0 else 0
	if offset.x > 0:
		return 3 if offset.y > 0 else 1
	return 5 if offset.y > 0 else 7


func _turn_direction(current: int, target: int) -> int:
	var clockwise := posmod(target - current, 8)
	return 1 if clockwise <= 4 else -1


func _decision(action: Dictionary) -> Dictionary:
	return {"disposition": "accepted", "action": action, "fallback": "none", "no_input_reason": null}


func _neutral(authority: Object, participant_id: String, index: int, label: String) -> Dictionary:
	return _action(authority, participant_id, {}, "%s_%d" % [label, index])


func _action(authority: Object, participant_id: String, values: Dictionary, label: String) -> Dictionary:
	var buttons := {"interact": false, "primary": false, "guard": false, "dash": false, "ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false}
	for key: String in buttons:
		buttons[key] = bool(values.get(key, false))
	return {
		"protocol_version": Identity.PROTOCOL_VERSION,
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "%s_%s_%d" % [label, participant_id, authority.observation_seq],
		"control": {"move_x": int(values.get("move_x", 0)), "move_y": int(values.get("move_y", 0)), "look_x": int(values.get("look_x", 0)), "look_y": 0, "duration_ticks": 10, "buttons": buttons},
		"intent_label": "Demo RTS: %s" % label,
		"memory_update": "",
	}


func _output_path() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--write-rts-replay="):
			return argument.trim_prefix("--write-rts-replay=")
	return ""


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		quit(0)
		return
	for failure: String in _failures:
		push_error("RTS_SKIRMISH_REPLAY_CAPTURE_FAILURE: %s" % failure)
	quit(1)
