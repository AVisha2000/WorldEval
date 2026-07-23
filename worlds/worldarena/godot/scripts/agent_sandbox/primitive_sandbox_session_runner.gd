extends SceneTree

## Rebuild one interactive Primitive Sandbox decision boundary from its complete
## normalized history. The process is intentionally one-shot: Godot remains the
## gameplay authority without requiring a fragile long-lived subprocess.

const Authority := preload("res://scripts/agent_sandbox/primitive_sandbox_authority.gd")
const DEFAULT_SCENARIO := "res://../games/primitive-sandbox/scenarios/tree-chop-interrupted-v0.json"


func _init() -> void:
	var arguments := _arguments()
	var scenario_path: String = arguments.get("scenario", DEFAULT_SCENARIO)
	var scenario := _read_json_object(scenario_path)
	if scenario.is_empty():
		_fail("scenario could not be loaded", 64)
		return
	var history_path: String = arguments.get("history", "")
	var history = _read_json_array(history_path)
	if history == null:
		_fail("decision history could not be loaded", 64)
		return
	history = _integerize(history)
	var initialization_hash: String = arguments.get("initialization-hash", "")
	if initialization_hash.is_empty():
		_fail("initialization hash is required", 64)
		return
	var run_id: String = arguments.get("run-id", "")
	if run_id.is_empty():
		_fail("run ID is required", 64)
		return

	var authority := Authority.new()
	authority.configure(scenario, initialization_hash)
	if not history.is_empty():
		if not authority.acknowledge_initialization(initialization_hash):
			_fail("initialization acknowledgement failed", 65)
			return
		for entry in history:
			if authority.terminal:
				_fail("decision history continues after terminal state", 65)
				return
			if not _apply_entry(authority, entry):
				_fail("decision history entry is malformed", 65)
				return

	var replay := authority.native_replay(run_id, false)
	var verification := _verify_history(scenario, replay)
	if not verification["verified"]:
		_fail("history verification failed: %s" % verification["reason"], 65)
		return
	if authority.terminal:
		replay["offline_verified"] = true
	var snapshot := {
		"schema_version": "primitive-sandbox-session-snapshot.v1",
		"run_id": run_id,
		"scenario_id": scenario["scenario_id"],
		"history_count": history.size(),
		"history_verified": true,
		"terminal": authority.terminal,
		"observation": authority.current_observation(),
		"receipt": null if authority.receipts.is_empty() else authority.receipts[-1].duplicate(true),
		"replay": replay,
	}
	var output_path: String = arguments.get("output", "")
	if output_path.is_empty():
		_fail("output path is required", 64)
		return
	var output := FileAccess.open(output_path, FileAccess.WRITE)
	if output == null:
		_fail("output path could not be opened", 73)
		return
	output.store_string(JSON.stringify(snapshot, "", true, false))
	output.flush()
	print(
		"PRIMITIVE_SANDBOX_SESSION_OK scenario=%s boundaries=%d terminal=%s tick=%d state_hash=%s" % [
			scenario["scenario_id"],
			history.size(),
			str(authority.terminal).to_lower(),
			authority.tick,
			authority.state_hash(),
		]
	)
	quit(0)


func _apply_entry(authority, entry) -> bool:
	if not entry is Dictionary:
		return false
	var decision = entry.get("decision")
	var no_input_reason = entry.get("no_input_reason")
	if no_input_reason != null and no_input_reason not in ["missing", "invalid"]:
		return false
	if no_input_reason == null:
		if not decision is Dictionary:
			return false
		authority.respond(decision)
		return true
	if decision != null:
		return false
	authority.respond(null)
	if no_input_reason == "invalid":
		# Invalid transport input is deliberately normalized to a replay-safe null
		# decision. The receipt still records why the neutral no-op occurred.
		authority.receipts[-1]["no_input_reason"] = "invalid"
	return true


func _verify_history(scenario: Dictionary, replay: Dictionary) -> Dictionary:
	var verifier := Authority.new()
	verifier.configure(scenario, replay.get("initialization_hash", ""))
	if replay.get("initialization_hash") != verifier.initialization_hash:
		return {"verified": false, "reason": "initialization_hash_mismatch"}
	if replay.get("initial_state_hash") != verifier.initial_state_hash:
		return {"verified": false, "reason": "initial_state_hash_mismatch"}
	if not replay.get("decisions", []).is_empty():
		if not verifier.acknowledge_initialization(replay["initialization_hash"]):
			return {"verified": false, "reason": "initialization_acknowledgement_failed"}
		for index in range(replay["decisions"].size()):
			var decision = replay["decisions"][index]
			verifier.respond(decision)
			var expected_reason = replay["receipts"][index].get("no_input_reason")
			if decision == null and expected_reason == "invalid":
				verifier.receipts[-1]["no_input_reason"] = "invalid"
	var rebuilt := verifier.native_replay(replay["run_id"], false)
	for field in [
		"environment_id",
		"scenario_id",
		"initialization_hash",
		"initial_state_hash",
		"terminal_state_hash",
		"terminal_outcome",
		"terminal_tick",
		"authority_metrics",
		"observations",
		"decisions",
		"receipts",
		"provider_calls",
	]:
		if JSON.stringify(rebuilt.get(field), "", true, false) != JSON.stringify(replay.get(field), "", true, false):
			return {"verified": false, "reason": "%s_mismatch" % field}
	return {"verified": true, "reason": "verified", "final_state_hash": verifier.state_hash()}


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


func _read_json_array(path: String):
	if path.is_empty():
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var value = JSON.parse_string(file.get_as_text())
	return value if value is Array else null


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
	if typeof(value) == TYPE_FLOAT:
		if value != floor(value):
			return value
		return int(value)
	return value


func _fail(message: String, code: int) -> void:
	push_error("PRIMITIVE_SANDBOX_SESSION_ERROR %s" % message)
	quit(code)
