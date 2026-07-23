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
const DEFAULT_SCENARIO := "res://../games/waypoint-maze/scenarios/beacon-route-v0.json"
const DEFAULT_PROFILE := "res://../games/waypoint-maze/decision-profiles/static-event-gated-v1.json"
const DEFAULT_SKILL := "res://../games/shared/skills/navigation.follow-visible-waypoints-v1.json"


func _init() -> void:
	var arguments := _arguments()
	var scenario := _read_json(arguments.get("scenario", DEFAULT_SCENARIO))
	var decision_profile := _read_json(arguments.get("decision-profile", DEFAULT_PROFILE))
	var skill_manifest := _read_json(arguments.get("skill", DEFAULT_SKILL))
	if scenario.is_empty() or decision_profile.is_empty() or skill_manifest.is_empty():
		_fail("scenario, decision profile, or skill could not be loaded", 64)
		return
	var authority := Authority.new()
	authority.configure(
		scenario,
		arguments.get("initialization-hash", ""),
		decision_profile,
	)
	assert(authority.acknowledge_initialization(authority.initialization_hash))
	var expansion := DemoPolicy.run(authority, skill_manifest)
	var run_id: String = arguments.get("run-id", "waypoint-maze-%s" % scenario["scenario_id"])
	var replay := authority.native_replay(run_id, false)
	replay["offline_verified"] = true
	var verification := ReplayVerifier.verify(
		scenario,
		decision_profile,
		replay,
		authority.initialization_hash,
	)
	if not verification["verified"]:
		_fail("offline replay verification failed: %s" % verification["reason"], 65)
		return
	var output_path: String = arguments.get("output", "")
	if not output_path.is_empty():
		if not _write_json(output_path, replay):
			_fail("replay output path could not be opened", 73)
			return
	var expansion_path: String = arguments.get("expansion-output", "")
	if not expansion_path.is_empty():
		if not _write_json(expansion_path, expansion):
			_fail("skill expansion output path could not be opened", 73)
			return
	print(
		"WAYPOINT_MAZE_HEADLESS_OK scenario=%s outcome=%s tick=%d decisions=%d final_state_hash=%s" % [
			scenario["scenario_id"],
			authority.outcome,
			authority.tick,
			authority.decisions.size(),
			authority.state_hash(),
		]
	)
	quit(0)


func _arguments() -> Dictionary:
	var result: Dictionary = {}
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--"):
			continue
		var parts := argument.trim_prefix("--").split("=", true, 1)
		result[parts[0]] = parts[1] if parts.size() == 2 else "true"
	return result


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value = JSON.parse_string(file.get_as_text())
	return _integerize(value) if value is Dictionary else {}


func _write_json(path: String, value: Dictionary) -> bool:
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		return false
	output.store_string(JSON.stringify(value, "", true, false))
	output.flush()
	return true


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


func _fail(message: String, code: int) -> void:
	push_error("WAYPOINT_MAZE_HEADLESS_ERROR %s" % message)
	quit(code)
