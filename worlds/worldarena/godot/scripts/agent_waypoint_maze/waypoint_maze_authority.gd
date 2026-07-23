class_name WaypointMazeAuthority
extends "res://scripts/agent_sandbox/primitive_sandbox_authority.gd"

## Godot-only gameplay authority for WorldArena Waypoint Maze.
##
## The inherited protocol runtime applies only agent-declared direct movement.
## This game adds ordered route state and its terminal predicate. It never
## chooses a target, waypoint, route, or detour for the agent.

var route: Array = []
var route_index := 0
var visited_waypoints: Array = []


func configure(
	value: Dictionary,
	expected_initialization_hash: String = "",
	configured_decision_profile: Dictionary = {},
) -> void:
	route = value.get("route", []).duplicate(true)
	route_index = 0
	visited_waypoints = []
	super.configure(value, expected_initialization_hash, configured_decision_profile)


func state_payload() -> Dictionary:
	var live_objects: Array = []
	var object_ids := objects.keys()
	object_ids.sort()
	for object_id in object_ids:
		live_objects.append(objects[object_id].duplicate(true))
	return {
		"tick": tick,
		"agent": {
			"object_id": agent["object_id"],
			"generation": agent["generation"],
			"position": agent["position"].duplicate(true),
			"visited_waypoints": visited_waypoints.duplicate(true),
		},
		"objects": live_objects,
		"route": route.duplicate(true),
		"route_index": route_index,
		"path_distance": path_distance,
		"forbidden_autonomy_count": forbidden_autonomy_count,
		"hostile_attacks": hostile_attacks,
		"terminal": terminal,
		"outcome": outcome,
	}


func _fire_triggers(events: Array) -> void:
	if route_index >= route.size():
		return
	var target_id: String = str(route[route_index])
	if not objects.has(target_id):
		return
	if not _same_position(agent["position"], objects[target_id]["position"]):
		return
	var target: Dictionary = objects[target_id].duplicate(true)
	if target["type_id"] == "waypoint":
		target["state"]["visited"] = true
		objects[target_id] = target
		visited_waypoints.append(target_id)
		agent["state"]["visited_waypoints"] = visited_waypoints.duplicate(true)
	route_index += 1
	events.append(
		_event(
			"waypoint_reached",
			target_id,
			{"order": route_index, "route_complete": route_index == route.size()},
		)
	)


func _check_terminal() -> void:
	if route_index == route.size():
		terminal = true
		outcome = "route_complete"
	elif tick >= int(scenario["tick_budget"]):
		terminal = true
		outcome = "timeout"


func _record_boundary(execution: Dictionary) -> void:
	if active_plan.is_empty():
		return
	var material: Array = []
	for event in execution["events"]:
		if _is_material_interrupt(event["kind"]):
			material.append(event["kind"])
	if execution["completed"]:
		plan_step_index += 1
	if not material.is_empty():
		interrupt_events = []
		for event_kind in material:
			if not interrupt_events.has(event_kind):
				interrupt_events.append(event_kind)
		interrupt_events.sort()
		plan_status = "suspended"
		return
	if execution["completed"] or execution["applied_ticks"] > 0:
		plan_status = "awaiting_confirmation"


func _valid_action_arguments(call: Dictionary) -> bool:
	var action: String = call["action"]
	var arguments: Dictionary = call["arguments"]
	if action == "move_to":
		return (
			_has_exact_keys(arguments, ["target", "navigation"])
			and arguments["navigation"] == "direct_only"
			and _valid_move_target(arguments["target"])
		)
	if action == "wait" or action == "cancel":
		return arguments.is_empty()
	return false


func _validate_scenario(value: Dictionary) -> void:
	assert(value.get("schema_version") == "waypoint-maze-scenario.v1")
	assert(value.get("environment_id") == "worldarena-waypoint-maze-v0")
	assert(value.get("scenario_id") == "beacon-route-v0")
	assert(int(value.get("width", 0)) == 12 and int(value.get("height", 0)) == 9)
	assert(value.get("coordinate_frame") == "maze_grid")
	assert(int(value.get("tick_budget", 0)) == 80)
	assert(value.get("expected_outcome") == "route_complete")
	assert(value.get("agent") is Dictionary)
	assert(value.get("objects") is Array)
	assert(value.get("route") is Array and value["route"].size() == 5)
	var route_ids: Dictionary = {}
	for object_id in value["route"]:
		assert(_is_identifier(object_id))
		assert(not route_ids.has(object_id), "maze route IDs must be unique")
		route_ids[object_id] = true
	var object_ids: Dictionary = {}
	for item in value["objects"]:
		assert(item is Dictionary and _is_identifier(item.get("object_id")))
		assert(not object_ids.has(item["object_id"]), "maze object IDs must be unique")
		object_ids[item["object_id"]] = true
	for object_id in value["route"]:
		assert(object_ids.has(object_id), "maze route target must exist")
