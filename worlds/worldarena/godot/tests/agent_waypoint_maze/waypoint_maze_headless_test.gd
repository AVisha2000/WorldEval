extends SceneTree

const Authority := preload(
	"res://scripts/agent_waypoint_maze/waypoint_maze_authority.gd"
)
const DemoPolicy := preload(
	"res://scripts/agent_waypoint_maze/waypoint_maze_demo_policy.gd"
)
const ReplayVerifier := preload(
	"res://scripts/agent_waypoint_maze/waypoint_maze_replay_verifier.gd"
)
const SCENARIO := "res://../games/waypoint-maze/scenarios/beacon-route-v0.json"
const PROFILE := "res://../games/waypoint-maze/decision-profiles/static-event-gated-v1.json"
const SKILL := "res://../games/shared/skills/navigation.follow-visible-waypoints-v1.json"


func _init() -> void:
	var scenario := _read_json(SCENARIO)
	var profile := _read_json(PROFILE)
	var skill := _read_json(SKILL)
	_assert_direct_command_stops_at_wall(scenario, profile)
	var authority := Authority.new()
	authority.configure(scenario, "", profile)
	assert(authority.acknowledge_initialization(authority.initialization_hash))
	var expansion := DemoPolicy.run(authority, skill)
	var replay := authority.native_replay("waypoint-maze-headless-test", true)
	var verification := ReplayVerifier.verify(
		scenario,
		profile,
		replay,
		authority.initialization_hash,
	)
	assert(verification["verified"])
	var forged_initialization := ReplayVerifier.verify(
		scenario,
		profile,
		replay,
		"sha256:%s" % "f".repeat(64),
	)
	assert(not forged_initialization["verified"])
	assert(forged_initialization["reason"] == "initialization_hash_mismatch")
	assert(replay["terminal_outcome"] == "route_complete")
	assert(replay["terminal_tick"] == 23)
	assert(replay["decisions"].size() == 5)
	assert(replay["authority_metrics"]["forbidden_autonomy_count"] == 0)
	assert(expansion["execution"] == "agent_expands_to_visible_actions")
	for decision in replay["decisions"]:
		if decision["type"] != "plan.replace":
			continue
		for step in decision["plan"]["steps"]:
			assert(step["action"]["action"] == "move_to")
	print(
		"WAYPOINT_MAZE_HEADLESS_TEST_OK tick=%d decisions=%d final_state_hash=%s" % [
			replay["terminal_tick"],
			replay["decisions"].size(),
			replay["terminal_state_hash"],
		]
	)
	quit(0)


func _assert_direct_command_stops_at_wall(
	scenario: Dictionary,
	profile: Dictionary,
) -> void:
	var blocked := Authority.new()
	blocked.configure(scenario, "", profile)
	assert(blocked.acknowledge_initialization(blocked.initialization_hash))
	var source := blocked.current_source()
	var result := blocked.respond(
		{
			"type": "plan.replace",
			"replaces_plan_id": null,
			"plan": {
				"schema_version": "action-plan.v1",
				"protocol": "worldeval-agent/0.1.0",
				"plan_id": "unsafe-direct-exit",
				"source": source,
				"lease_ticks": 50,
				"execution_policy": "confirm_each_boundary",
				"steps": [
					{
						"step_id": "direct-exit",
						"action": {
							"action": "move_to",
							"arguments": {
								"target": {"object_id": "exit-1", "generation": 1},
								"navigation": "direct_only",
							},
						},
						"preconditions": [
							{
								"kind": "target_visible",
								"subject": "exit-1",
								"parameters": {"generation": 1},
							},
						],
						"expected_completion": {
							"kind": "agent_at_target",
							"subject": "exit-1",
							"parameters": {},
						},
						"interrupt_on": ["movement_blocked"],
					},
				],
				"abort_behavior": "cancel_current_action",
			},
		}
	)
	assert(result["receipt"]["codes"].has("movement_blocked"))
	assert(blocked.agent["position"] == {"x": 2, "y": 1})
	assert(blocked.route_index == 0)
	assert(blocked.forbidden_autonomy_count == 0)


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	assert(file != null)
	var value = JSON.parse_string(file.get_as_text())
	return _integerize(value)


func _integerize(value):
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value.keys():
			result[key] = _integerize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for child in value:
			result.append(_integerize(child))
		return result
	if typeof(value) == TYPE_FLOAT and value == floor(value):
		return int(value)
	return value
