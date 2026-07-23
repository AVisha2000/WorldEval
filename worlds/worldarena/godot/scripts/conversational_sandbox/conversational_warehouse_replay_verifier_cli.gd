extends SceneTree

const ReplayVerifier := preload("res://scripts/conversational_sandbox/conversational_warehouse_replay_verifier.gd")

func _init() -> void:
	var args := _arguments()
	var scenario := _read_object(args.get("scenario", ""))
	var replay := _read_object(args.get("replay", ""))
	if scenario.is_empty() or replay.is_empty():
		_fail("scenario and replay are required", 64)
		return
	var verification: Dictionary = ReplayVerifier.verify(scenario, replay)
	if not verification["verified"]:
		_fail(str(verification["reason"]), 65)
		return
	print("CONVERSATIONAL_WAREHOUSE_REPLAY_VERIFIED run_id=%s state_hash=%s" % [replay["run_id"], verification["final_state_hash"]])
	quit(0)

func _arguments() -> Dictionary:
	var result := {}
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--"):
			var parts := argument.trim_prefix("--").split("=", true, 1)
			result[parts[0]] = parts[1] if parts.size() == 2 else "true"
	return result

func _read_object(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var value = null if file == null else JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}

func _fail(message: String, code: int) -> void:
	push_error("CONVERSATIONAL_WAREHOUSE_REPLAY_ERROR %s" % message)
	quit(code)
