extends SceneTree

const MazeMap := preload("res://scripts/embodiment/trio_games/trio_maze_map.gd")
const Authority := preload("res://scripts/embodiment/trio_games/trio_maze_race_authority.gd")
const Broadcast := preload("res://scripts/embodiment/presentation/maze/trio_maze_broadcast_scene.gd")


func _init() -> void:
	var invariants := MazeMap.fixture_invariants()
	if invariants != {"walkable_cells": 97, "junctions": 5, "dead_ends": 6, "shortest_path_cells": 60}:
		quit(1)
		return
	var authority := Authority.new()
	if not authority.configure({
		"task_id": MazeMap.TASK_ID,
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"episode_id": "ep_maze_headless",
	}).is_empty():
		quit(1)
		return
	var observation := authority.observe("participant_0")
	if observation.available_passages != ["right"] or observation.has("position") \
			or observation.has("competitors") or observation.has("standings"):
		quit(1)
		return
	var receipt := authority.submit_decision({
		"protocol_version": MazeMap.PROTOCOL_VERSION,
		"episode_id": "ep_maze_headless",
		"observation_id": observation.observation_id,
		"participant_id": "participant_0",
		"passage_choice": "right",
		"scratchpad_update": "start:right",
	})
	if not receipt.accepted or receipt.path_cells != 8:
		quit(1)
		return
	for _tick: int in 32:
		authority.step_tick()
	if authority.public_snapshot().racers[0].distance_cells != 8:
		quit(1)
		return
	var broadcast := Broadcast.new()
	if broadcast == null:
		quit(1)
		return
	print("TRIO_MAZE_RACE_HEADLESS_OK")
	quit(0)
