extends SceneTree

const Authority := preload("res://scripts/embodiment/rts_skirmish/rts_skirmish_authority.gd")
const TaskPlan := preload("res://scripts/embodiment/rts_skirmish/rts_task_plan_contract.gd")

var failures := PackedStringArray()


func _init() -> void:
	_test_first_class_story_and_checkpoint()
	_test_authoritative_cinematic_invariants()
	_test_deterministic_replay_and_checkpoint()
	_test_task_plan_contract_and_neutral_window()
	_finish()


func _authority():
	var authority := Authority.new()
	var errors := authority.configure({"protocol_version": "llm-controller/0.2.0", "task_id": "rts-skirmish-v0", "episode_id": "ep_rts_skirmish_test", "participant_ids": ["participant_0", "participant_1"], "maximum_episode_ticks": 1200})
	_check(errors.is_empty(), "configuration failed: %s" % str(errors))
	return authority


func _test_first_class_story_and_checkpoint() -> void:
	var authority = _authority()
	_check(authority.units.size() == 2 and authority.units.has("blue_0") and authority.units.has("red_0"), "reset did not create one first-class worker per team")
	_check(authority.resources.size() == 14 and authority.resources.has("blue_tree_3") and authority.resources.has("red_ore_2"), "reset did not create fixed 4-tree/3-ore fields")
	_check(authority.resources.blue_tree_0.position_mt == Vector2i(-6200, 5000) and authority.resources.red_tree_0.position_mt == Vector2i(6200, -5000), "resource coordinates are not the shared mirrored map table")
	var initial_public: Dictionary = authority.participant_presentation_source("participant_0")
	_check(int(initial_public.own.tower.health_percent) == 0, "unbuilt tower leaked its future full health into the public HUD")
	for participant_id: String in ["participant_0", "participant_1"]:
		for entity: Dictionary in authority.observe(participant_id).visible_entities:
			_check(str(entity.id).begins_with("v_"), "visible entity id does not satisfy the frozen v2 protocol: %s" % str(entity.id))
	var previous: Vector2i = authority.units.blue_0.position_mt
	authority.step_window(_window(authority))
	var current: Vector2i = authority.units.blue_0.position_mt
	_check(absi(current.x - previous.x) <= 800 and absi(current.y - previous.y) <= 800, "worker exceeded 80 millitiles per tick across a ten-tick window")
	while not bool(authority.terminal.ended):
		authority.step_window(_window(authority))
		if authority.tick > 1200:
			_check(false, "story did not terminate by tick 1200")
			break
	_check(authority.winner_id == "participant_0" and authority.terminal.reason == "town_hall_destroyed", "scripted story did not end in Blue Town Hall victory")
	_check(not bool(authority.units.blue_0.alive) and bool(authority.units.blue_1.alive) and bool(authority.units.blue_2.alive), "Blue casualty/survivor sequence is wrong")
	_check(not bool(authority.units.red_0.alive) and not bool(authority.units.red_1.alive) and not bool(authority.units.red_2.alive), "Red casualty sequence is wrong")
	_check(authority.units.blue_0.role == "militia" and authority.units.blue_1.role == "militia" and authority.units.blue_2.role == "militia", "workers did not arm in place as militia")
	_check(authority.structures.participant_0.barracks.state == "active" and authority.structures.participant_0.tower.state == "active", "economy did not complete Blue barracks and tower")
	_check(authority.structures.participant_1.tower.state == "destroyed" and authority.structures.participant_1.town_hall.state == "destroyed" and authority.structures.participant_1.barracks.state == "destroyed", "Red end-state structures were not destroyed with the Town Hall")
	_check(bool(authority.structures.participant_1.barracks.built), "destroying Red barracks erased historical construction evidence")
	_check(int(authority.participant_presentation_source("participant_1").own.barracks.health_percent) == 0, "destroyed Red barracks did not project zero health")
	var checkpoint: Dictionary = authority.checkpoint()
	_check(checkpoint.units.size() == 6 and checkpoint.resources.size() == 14 and checkpoint.has("structures") and checkpoint.has("last_task_plans"), "checkpoint omitted canonical first-class RTS state")
	_check(authority.replay_windows.size() > 0 and authority.replay_windows[0].has("checkpoint_hash"), "replay did not retain canonical checkpoint evidence")


func _test_task_plan_contract_and_neutral_window() -> void:
	var authority = _authority()
	var valid := {"protocol": TaskPlan.PROTOCOL, "episode_id": authority.episode_id, "observation_seq": authority.observation_seq, "intent_label": "Harvest the first tree", "memory_update": "opening economy", "assignments": [{"unit_id": "blue_0", "task": "gather", "target_id": "blue_tree_0"}]}
	_check(authority.task_plan_schema_valid("participant_0", valid), "valid owned/visible task plan was rejected")
	var invalid := valid.duplicate(true)
	invalid.assignments[0].target_id = "red_tree_0"
	invalid.assignments[0]["x"] = 1
	_check(not authority.task_plan_schema_valid("participant_0", invalid), "enemy/raw-coordinate task plan was accepted")
	var result: Dictionary = authority.step_task_plan_window({"episode_id": authority.episode_id, "observation_seq": authority.observation_seq, "mode": "model-duel-v0", "start_tick": authority.tick, "duration_ticks": 10, "plans": {"participant_0": valid, "participant_1": invalid}})
	_check(authority.tick == 10 and result.receipts.participant_1.fallback == "neutral", "invalid task plan did not produce a ten-tick neutral receipt")
	_check(authority.last_task_plans.has("participant_0") and not authority.last_task_plans.has("participant_1"), "only accepted task plans should enter replay evidence")


func _test_authoritative_cinematic_invariants() -> void:
	var authority = _authority()
	var deposits := {"participant_0": 0, "participant_1": 0}
	var armed: Array[String] = []
	var casualties: Array[Dictionary] = []
	var hit_healths := {}
	var fan_out_seen := {"participant_0": false, "participant_1": false}
	var siege_damage_seen := {"tower": false, "town_hall": false}
	for _index: int in 1200:
		var before := _unit_positions(authority)
		var events: Array[Dictionary] = []
		authority._apply_joint_tick({}, false, {}, events)
		for unit_id: String in before:
			var origin: Vector2i = before[unit_id]
			var destination: Vector2i = authority.units[unit_id].position_mt
			_check(origin.distance_squared_to(destination) <= 80 * 80, "unit %s exceeded the 80-millitile speed limit" % unit_id)
		if authority.tick >= 650 and authority.tick < 920:
			var occupied := {}
			for unit_id: String in authority.units:
				var unit: Dictionary = authority.units[unit_id]
				if not bool(unit.alive):
					continue
				var key := "%d:%d" % [unit.position_mt.x, unit.position_mt.y]
				_check(not occupied.has(key), "living bridge/rally units overlapped at %s" % key)
				occupied[key] = unit_id
		for participant_id: String in ["participant_0", "participant_1"]:
			var prefix := "blue" if participant_id == "participant_0" else "red"
			var expected_targets := {"%s_tree_2" % prefix: true, "%s_tree_3" % prefix: true, "%s_ore_1" % prefix: true}
			var active_targets := {}
			for unit_id: String in authority._team_unit_ids(participant_id):
				var target_id := str(authority.units[unit_id].target_id)
				if expected_targets.has(target_id): active_targets[target_id] = true
			if active_targets.size() == 3: fan_out_seen[participant_id] = true
		for event: Dictionary in events:
			match str(event.kind):
				"rts_material_deposited":
					deposits[str(event.participant_ids[0])] = int(deposits[str(event.participant_ids[0])]) + 1
				"rts_unit_armed":
					armed.append(str(event.data.unit_id))
				"rts_unit_hit":
					var victim_id := str(event.data.unit_id)
					if not hit_healths.has(victim_id): hit_healths[victim_id] = []
					hit_healths[victim_id].append(int(event.data.health))
				"rts_unit_lost":
					casualties.append({"tick": int(event.tick), "unit_id": str(event.data.unit_id)})
				"rts_structure_damaged":
					var structure := str(event.data.structure)
					var target: Vector2i = authority.TOWERS.participant_1 if structure == "tower" else authority.TOWN_HALLS.participant_1
					var attacker_in_range := false
					for unit_id: String in ["blue_1", "blue_2"]:
						var attacker: Dictionary = authority.units[unit_id]
						if bool(attacker.alive) and attacker.position_mt.distance_squared_to(target) <= authority.SIEGE_RANGE_MT * authority.SIEGE_RANGE_MT:
							attacker_in_range = true
					_check(attacker_in_range, "%s damage was applied without a living Blue attacker in siege range" % structure)
					siege_damage_seen[structure] = true
		authority.tick += 1
		authority._resolve_terminal(events)
		for participant_id: String in ["participant_0", "participant_1"]: authority._sync_operator(participant_id)
	_check(int(deposits.participant_0) == 6 and int(deposits.participant_1) == 6, "cinematic economy must record exactly six deposits per faction")
	_check(int(authority.economy.participant_0.wood) == 1 and int(authority.economy.participant_0.ore) == 0, "Blue did not pay the locked 3-wood/2-ore structure costs")
	_check(int(authority.economy.participant_1.wood) == 1 and int(authority.economy.participant_1.ore) == 0, "Red did not pay the locked 3-wood/2-ore structure costs")
	_check(bool(fan_out_seen.participant_0) and bool(fan_out_seen.participant_1), "all three workers never held distinct final-economy resource targets")
	armed.sort()
	_check(armed == ["blue_0", "blue_1", "blue_2", "red_0", "red_1", "red_2"], "every first-class worker must arm exactly once")
	_check(casualties == [{"tick": 850, "unit_id": "blue_0"}, {"tick": 880, "unit_id": "red_0"}, {"tick": 900, "unit_id": "red_1"}, {"tick": 1020, "unit_id": "red_2"}], "cinematic casualty ticks/order drifted")
	for victim_id: String in ["blue_0", "red_0", "red_1", "red_2"]:
		_check(hit_healths.get(victim_id, []) == [750, 500, 250, 0], "%s health must descend through four visible integer hits" % victim_id)
	_check(bool(siege_damage_seen.tower) and bool(siege_damage_seen.town_hall), "tower and Town Hall siege damage did not occur")
	_check(authority.tick == 1200 and bool(authority.terminal.ended) and authority.winner_id == "participant_0", "authority must terminate exactly at tick 1200 with Blue victory")


func _test_deterministic_replay_and_checkpoint() -> void:
	var first = _authority()
	var second = _authority()
	while not bool(first.terminal.ended): first.step_window(_window(first))
	while not bool(second.terminal.ended): second.step_window(_window(second))
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "same seed/story did not produce identical final checkpoint hashes")
	_check(JSON.stringify(first.checkpoint()) == JSON.stringify(second.checkpoint()), "same seed/story did not produce identical checkpoint state")
	_check(JSON.stringify(first.replay_windows) == JSON.stringify(second.replay_windows), "same seed/story did not produce identical replay evidence")


func _unit_positions(authority) -> Dictionary:
	var positions := {}
	for unit_id: String in authority.units:
		positions[unit_id] = authority.units[unit_id].position_mt
	return positions


func _window(authority) -> Dictionary:
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq, "start_tick": authority.tick, "duration_ticks": 10, "decisions": {"participant_0": _decision(authority, "participant_0"), "participant_1": _decision(authority, "participant_1")}}


func _decision(authority, participant_id: String) -> Dictionary:
	return {"disposition": "accepted", "action": {"protocol_version": "llm-controller/0.2.0", "episode_id": authority.episode_id, "observation_seq": authority.observation_seq, "action_id": "rts_%s_%d" % [participant_id, authority.observation_seq], "control": {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0, "duration_ticks": 10, "buttons": {"interact": false, "primary": false, "guard": false, "dash": false, "ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false}}, "intent_label": "deterministic RTS story", "memory_update": ""}, "fallback": "none", "no_input_reason": null}


func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("RTS_SKIRMISH_OK")
		quit(0)
		return
	for failure: String in failures: push_error(failure)
	quit(1)
