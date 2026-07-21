class_name EmbodimentTrioMazeRaceAuthority
extends RefCounted

const MazeMap := preload("res://scripts/embodiment/trio_games/trio_maze_map.gd")
const CheckpointSerializer := preload("res://scripts/embodiment/authority/checkpoint_serializer.gd")
const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]
const DISPLAY_NAMES := {"participant_0": "Sol", "participant_1": "Luna", "participant_2": "Terra"}
const MODELS := {"participant_0": "demo-sol-v1", "participant_1": "demo-luna-v1", "participant_2": "demo-terra-v1"}
const COLOURS := {"participant_0": "#fbbf24", "participant_1": "#a78bfa", "participant_2": "#34d399"}
const MAXIMUM_TICKS := 600
const TICKS_PER_CELL := 4

var episode_id := ""
var tick := 0
var racers := {}
var terminal := {"ended": false, "reason": "in_progress"}
var public_events: Array[Dictionary] = []
var _event_sequence := 0


func configure(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if config.get("task_id") != MazeMap.TASK_ID:
		errors.append("task_id must be trio-maze-race-v0")
	if config.get("protocol_version") != MazeMap.PROTOCOL_VERSION:
		errors.append("protocol_version must be maze-task-plan-v1")
	if not config.get("episode_id") is String or not str(config.episode_id).begins_with("ep_"):
		errors.append("episode_id must be an ep_ identifier")
	if not errors.is_empty():
		return errors
	episode_id = str(config.episode_id)
	tick = 0
	terminal = {"ended": false, "reason": "in_progress"}
	public_events.clear()
	_event_sequence = 0
	racers.clear()
	for participant_id: String in PARTICIPANTS:
		racers[participant_id] = {
			"participant_id": participant_id,
			"cell": MazeMap.start_cell(),
			"heading": 0,
			"path": [],
			"path_index": 0,
			"movement_subtick": 0,
			"neutral_until": 0,
			"awaiting_decision": true,
			"scratchpad": "",
			"task": "exploring",
			"distance_cells": 0,
			"visited_cells": {MazeMap.start_cell(): true},
			"passages": {},
			"dead_ends_entered": 0,
			"successful_backtracks": 0,
			"collisions": 0,
			"invalid_decisions": 0,
			"idle_thinking_ticks": 0,
			"finish_tick": null,
			"last_event": "New junction",
		}
	return errors


func submit_decision(plan: Variant) -> Dictionary:
	if terminal.ended or not plan is Dictionary:
		return {"accepted": false, "reason": "terminal" if terminal.ended else "invalid"}
	var required := ["protocol_version", "episode_id", "observation_id", "participant_id", "passage_choice", "scratchpad_update"]
	if plan.keys().size() != required.size() or required.any(func(key: String) -> bool: return not plan.has(key)):
		return _invalid_plan(str(plan.get("participant_id", "")), "invalid_fields")
	var participant_id := str(plan.participant_id)
	if participant_id not in PARTICIPANTS or plan.protocol_version != MazeMap.PROTOCOL_VERSION \
			or plan.episode_id != episode_id or plan.observation_id != _observation_id(participant_id):
		return _invalid_plan(participant_id, "stale_or_mismatched")
	var racer: Dictionary = racers[participant_id]
	if racer.finish_tick != null or not racer.awaiting_decision:
		return _invalid_plan(participant_id, "not_awaiting_decision")
	if not plan.scratchpad_update is String or plan.scratchpad_update.to_utf8_buffer().size() > 2048:
		return _invalid_plan(participant_id, "invalid_scratchpad")
	var choice := str(plan.passage_choice)
	if choice == "wait":
		racer.neutral_until = tick + 10
		racer.idle_thinking_ticks += 10
		racer.last_event = "Inspecting passages"
		return {"accepted": true, "reason": "wait"}
	if choice not in MazeMap.available_passages(racer.cell, int(racer.heading)):
		return _invalid_plan(participant_id, "passage_unavailable")
	var path := MazeMap.corridor_path(racer.cell, int(racer.heading), choice)
	if path.size() < 2:
		return _invalid_plan(participant_id, "passage_unavailable")
	var passage_key := _passage_key(path[0], path[-1])
	if racer.passages.has(passage_key):
		racer.successful_backtracks += 1
		racer.task = "backtracking"
		racer.last_event = "Backtracking"
	else:
		racer.passages[passage_key] = true
		racer.task = "turning"
		racer.last_event = "Trying the %s passage" % choice
	racer.scratchpad = plan.scratchpad_update
	racer.path = path
	racer.path_index = 0
	racer.movement_subtick = 0
	racer.awaiting_decision = false
	_emit(participant_id, "maze_passage_selected", racer.last_event)
	return {"accepted": true, "reason": "accepted", "path_cells": path.size() - 1}


func step_tick() -> Dictionary:
	if terminal.ended:
		return public_snapshot()
	tick += 1
	for participant_id: String in PARTICIPANTS:
		var racer: Dictionary = racers[participant_id]
		if racer.finish_tick != null:
			continue
		if tick < int(racer.neutral_until):
			continue
		if racer.path.is_empty():
			if racer.awaiting_decision:
				racer.idle_thinking_ticks += 1
			continue
		racer.task = "backtracking" if racer.task == "backtracking" else "exploring"
		racer.movement_subtick += 1
		if racer.movement_subtick < TICKS_PER_CELL:
			continue
		racer.movement_subtick = 0
		var source: Vector2i = racer.path[racer.path_index]
		racer.path_index += 1
		var target: Vector2i = racer.path[racer.path_index]
		racer.heading = MazeMap.DIRECTIONS.find(target - source)
		racer.cell = target
		racer.distance_cells += 1
		racer.visited_cells[target] = true
		if racer.path_index < racer.path.size() - 1:
			continue
		racer.path = []
		racer.path_index = 0
		racer.awaiting_decision = true
		var location := MazeMap.location_type(target)
		if location == "exit":
			racer.finish_tick = tick
			racer.awaiting_decision = false
			racer.task = "finished"
			racer.last_event = "Exit found!"
			_emit(participant_id, "maze_finished", "Exit found!")
		elif location == "dead_end":
			racer.dead_ends_entered += 1
			racer.task = "dead_end"
			racer.last_event = "Dead end"
			_emit(participant_id, "maze_dead_end", "Dead end")
		else:
			racer.task = "exploring"
			racer.last_event = "New junction"
			_emit(participant_id, "maze_junction_reached", "New junction")
	if PARTICIPANTS.all(func(participant_id: String) -> bool: return racers[participant_id].finish_tick != null):
		terminal = {"ended": true, "reason": "all_racers_finished"}
	elif tick >= MAXIMUM_TICKS:
		terminal = {"ended": true, "reason": "time_limit"}
	return public_snapshot()


func observe(participant_id: String) -> Dictionary:
	if participant_id not in PARTICIPANTS:
		return {}
	var racer: Dictionary = racers[participant_id]
	return {
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"episode_id": episode_id,
		"observation_id": _observation_id(participant_id),
		"participant_id": participant_id,
		"tick": tick,
		"elapsed_ticks": tick,
		"heading": ["north", "east", "south", "west"][int(racer.heading)],
		"available_passages": MazeMap.available_passages(racer.cell, int(racer.heading)) if racer.awaiting_decision else [],
		"visible_landmark": MazeMap.landmark(racer.cell),
		"location_type": MazeMap.location_type(racer.cell),
		"last_action_result": racer.last_event,
		"recent_events": _recent_events(participant_id),
		"scratchpad": racer.scratchpad,
		"terminal": {"ended": racer.finish_tick != null, "reason": "exit" if racer.finish_tick != null else "running"},
	}


func public_snapshot() -> Dictionary:
	var public_racers := []
	for participant_id: String in PARTICIPANTS:
		var racer: Dictionary = racers[participant_id]
		public_racers.append({
			"participant_id": participant_id,
			"display_name": DISPLAY_NAMES[participant_id],
			"model": MODELS[participant_id],
			"color": COLOURS[participant_id],
			"position_mt": {"x": int(racer.cell.x) * MazeMap.TILE_MT, "y": int(racer.cell.y) * MazeMap.TILE_MT},
			"heading": racer.heading,
			"task": racer.task,
			"passages_explored": racer.passages.size(),
			"dead_ends_entered": racer.dead_ends_entered,
			"distance_cells": racer.distance_cells,
			"finish_tick": racer.finish_tick,
			"last_event": racer.last_event,
		})
	return {"task_id": MazeMap.TASK_ID, "tick": tick, "maximum_ticks": MAXIMUM_TICKS, "racers": public_racers, "terminal": terminal.duplicate(true)}


func evaluation() -> Dictionary:
	var rows := []
	var ordered := PARTICIPANTS.duplicate()
	ordered.sort_custom(func(left: String, right: String) -> bool:
		var left_tick := int(racers[left].finish_tick) if racers[left].finish_tick != null else MAXIMUM_TICKS + 1
		var right_tick := int(racers[right].finish_tick) if racers[right].finish_tick != null else MAXIMUM_TICKS + 1
		return left_tick < right_tick or (left_tick == right_tick and left < right)
	)
	for index: int in ordered.size():
		var participant_id: String = ordered[index]
		var racer: Dictionary = racers[participant_id]
		var distance := maxi(1, int(racer.distance_cells))
		rows.append({
			"participant_id": participant_id,
			"display_name": DISPLAY_NAMES[participant_id],
			"model": MODELS[participant_id],
			"color": COLOURS[participant_id],
			"place": index + 1,
			"finish_tick": racer.finish_tick,
			"distance_cells": racer.distance_cells,
			"shortest_path_cells": MazeMap.shortest_path_cells(),
			"path_efficiency_basis_points": MazeMap.shortest_path_cells() * 10000 / distance,
			"unique_corridor_cells": racer.visited_cells.size(),
			"repeated_corridor_cells": int(racer.distance_cells) + 1 - racer.visited_cells.size(),
			"passages_explored": racer.passages.size(),
			"dead_ends_entered": racer.dead_ends_entered,
			"successful_backtracks": racer.successful_backtracks,
			"collisions": racer.collisions,
			"invalid_decisions": racer.invalid_decisions,
			"idle_thinking_ticks": racer.idle_thinking_ticks,
		})
	return {"task_id": MazeMap.TASK_ID, "participants": rows, "deterministic_replay": true}


func checkpoint_hash() -> String:
	return CheckpointSerializer.hash_checkpoint({"episode_id": episode_id, "tick": tick, "racers": racers, "terminal": terminal})


func _invalid_plan(participant_id: String, reason: String) -> Dictionary:
	if participant_id in PARTICIPANTS:
		var racer: Dictionary = racers[participant_id]
		racer.invalid_decisions += 1
		racer.neutral_until = tick + 10
		racer.idle_thinking_ticks += 10
		racer.last_event = "Decision rejected"
		_emit(participant_id, "maze_invalid_decision", "Decision rejected")
	return {"accepted": false, "reason": reason, "neutral_ticks": 10}


func _observation_id(participant_id: String) -> String:
	return "obs_%s_%04d" % [participant_id, tick]


func _passage_key(left: Vector2i, right: Vector2i) -> String:
	var values := ["%d,%d" % [left.x, left.y], "%d,%d" % [right.x, right.y]]
	values.sort()
	return "%s|%s" % values


func _recent_events(participant_id: String) -> Array[Dictionary]:
	var values: Array[Dictionary] = []
	for event: Dictionary in public_events:
		if event.participant_id == participant_id:
			values.append(event.duplicate(true))
	return values.slice(maxi(0, values.size() - 4))


func _emit(participant_id: String, kind: String, label: String) -> void:
	_event_sequence += 1
	public_events.append({"event_id": "evt_maze_%06d" % _event_sequence, "tick": tick, "participant_id": participant_id, "kind": kind, "label": label})
