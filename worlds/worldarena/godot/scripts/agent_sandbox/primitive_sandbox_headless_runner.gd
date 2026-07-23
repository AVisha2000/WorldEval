extends SceneTree

const Authority := preload("res://scripts/agent_sandbox/primitive_sandbox_authority.gd")
const DemoPolicy := preload("res://scripts/agent_sandbox/primitive_sandbox_demo_policy.gd")
const DEFAULT_SCENARIO := "res://../games/primitive-sandbox/scenarios/tree-chop-interrupted-v0.json"


func _init() -> void:
	var arguments := _arguments()
	var scenario_path: String = arguments.get("scenario", DEFAULT_SCENARIO)
	var scenario := _read_json(scenario_path)
	if scenario.is_empty():
		_fail("scenario could not be loaded", 64)
		return
	var authority := Authority.new()
	authority.configure(scenario, arguments.get("initialization-hash", ""))
	assert(authority.acknowledge_initialization(authority.initialization_hash))
	if arguments.get("debug-initial") == "true":
		print("PRIMITIVE_SANDBOX_INITIAL_STATE %s" % JSON.stringify(authority.state_payload(), "", true, false))
	DemoPolicy.run(authority)
	if arguments.get("debug-state") == "true":
		print("PRIMITIVE_SANDBOX_STATE %s" % JSON.stringify(authority.state_payload(), "", true, false))
	var run_id: String = arguments.get("run-id", "primitive-sandbox-%s" % scenario["scenario_id"])
	var replay := authority.native_replay(run_id, false)
	var verification := _verify_replay(scenario, replay)
	if not verification["verified"]:
		_fail("offline replay verification failed: %s" % verification["reason"], 65)
		return
	replay["offline_verified"] = true
	var output_path: String = arguments.get("output", "")
	if not output_path.is_empty():
		var output := FileAccess.open(output_path, FileAccess.WRITE)
		if output == null:
			_fail("output path could not be opened", 73)
			return
		output.store_string(JSON.stringify(replay, "", true, false))
		output.flush()
	print(
		"PRIMITIVE_SANDBOX_HEADLESS_OK scenario=%s outcome=%s tick=%d final_state_hash=%s" % [
			scenario["scenario_id"],
			authority.outcome,
			authority.tick,
			authority.state_hash(),
		]
	)
	quit(0)


func _verify_replay(scenario: Dictionary, replay: Dictionary) -> Dictionary:
	var verifier := Authority.new()
	verifier.configure(scenario, replay.get("initialization_hash", ""))
	if replay.get("initialization_hash") != verifier.initialization_hash:
		return {"verified": false, "reason": "initialization_hash_mismatch"}
	if replay.get("initial_state_hash") != verifier.initial_state_hash:
		return {"verified": false, "reason": "initial_state_hash_mismatch"}
	if not verifier.acknowledge_initialization(replay["initialization_hash"]):
		return {"verified": false, "reason": "initialization_acknowledgement_failed"}
	var replay_decisions: Array = replay.get("decisions", [])
	var replay_receipts: Array = replay.get("receipts", [])
	for index in range(replay_decisions.size()):
		var reason_value = replay_receipts[index].get("no_input_reason")
		var missing_reason: String = reason_value if reason_value is String else "missing"
		verifier.respond(replay_decisions[index], missing_reason)
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


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}


func _fail(message: String, code: int) -> void:
	push_error("PRIMITIVE_SANDBOX_HEADLESS_ERROR %s" % message)
	quit(code)
