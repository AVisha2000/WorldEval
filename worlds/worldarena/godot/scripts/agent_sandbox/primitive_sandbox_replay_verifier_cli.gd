extends SceneTree

## Provider-free, one-shot native replay verification entrypoint. The caller
## supplies only an allow-listed authored scenario and canonical replay file.

const ReplayVerifier := preload(
	"res://scripts/agent_sandbox/primitive_sandbox_replay_verifier.gd"
)


func _init() -> void:
	var arguments := _arguments()
	var scenario_path: String = arguments.get("scenario", "")
	var replay_path: String = arguments.get("replay", "")
	var initialization_hash: String = arguments.get("initialization-hash", "")
	if (
		scenario_path.is_empty()
		or replay_path.is_empty()
		or initialization_hash.is_empty()
	):
		_fail("scenario, replay, and initialization hash are required", 64)
		return
	var scenario := _read_json_object(scenario_path)
	var replay := _read_json_object(replay_path)
	if scenario.is_empty() or replay.is_empty():
		_fail("scenario or replay could not be loaded", 64)
		return
	scenario = _integerize(scenario)
	replay = _integerize(replay)
	var verification := ReplayVerifier.verify(
		scenario,
		replay,
		initialization_hash,
	)
	if not verification["verified"]:
		_fail("native replay verification failed: %s" % verification["reason"], 65)
		return
	print(
		"PRIMITIVE_SANDBOX_REPLAY_VERIFIED scenario=%s provider_calls=%d final_state_hash=%s" % [
			scenario["scenario_id"],
			verification["provider_calls"],
			verification["final_state_hash"],
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


func _read_json_object(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}


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
	push_error("PRIMITIVE_SANDBOX_REPLAY_ERROR %s" % message)
	quit(code)
