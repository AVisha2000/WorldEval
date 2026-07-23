extends SceneTree

## One-shot history runner, intentionally shaped like PrimitiveSandboxRunner.
const Authority := preload("res://scripts/conversational_sandbox/conversational_warehouse_authority.gd")
const DEFAULT_SCENARIO := "res://../games/conversational-warehouse/scenario.json"

func _init() -> void:
	var args := _arguments()
	var scenario := _read_object(args.get("scenario", DEFAULT_SCENARIO))
	var history: Variant = _read_history(args.get("history", ""))
	if scenario.is_empty() or history == null or args.get("initialization-hash", "").is_empty() or args.get("run-id", "").is_empty() or args.get("output", "").is_empty():
		_fail("scenario, history, initialization-hash, run-id, and output are required; received=%s" % JSON.stringify(args), 64)
		return
	var authority := Authority.new()
	authority.configure(scenario, args["initialization-hash"])
	if not authority.acknowledge_initialization(args["initialization-hash"]):
		_fail("initialization acknowledgement failed", 65)
		return
	for entry in history:
		if not entry is Dictionary or not _apply(authority, entry):
			_fail("malformed history entry", 65)
			return
	var replay := authority.native_replay(args["run-id"], authority.terminal)
	var output := FileAccess.open(args["output"], FileAccess.WRITE)
	if output == null:
		_fail("output could not be opened", 73)
		return
	output.store_string(JSON.stringify({"schema_version": "conversational-warehouse-session-snapshot.v1", "scenario_id": scenario["scenario_id"], "terminal": authority.terminal, "observation": authority.current_observation(), "receipt": null if authority.receipts.is_empty() else authority.receipts[-1], "replay": replay, "history_count": history.size()}, "", true, false))
	print("CONVERSATIONAL_WAREHOUSE_SESSION_OK scenario=%s boundaries=%d terminal=%s tick=%d state_hash=%s" % [scenario["scenario_id"], history.size(), str(authority.terminal).to_lower(), authority.tick, authority.state_hash()])
	quit(0)

func _apply(authority, entry: Dictionary) -> bool:
	match str(entry.get("kind", "")):
		"intent.begin": authority.begin_intent(str(entry.get("intent_id", "")), int(entry.get("revision", 0)), str(entry.get("text", "")))
		"binding.request": authority.request_binding(str(entry.get("intent_id", "")), entry.get("candidate_ids", []))
		"binding.resolve": authority.bind_target(str(entry.get("intent_id", "")), str(entry.get("binding_id", "")), str(entry.get("object_id", "")), int(entry.get("generation", 0)))
		"intent.revise": authority.revise_intent(str(entry.get("intent_id", "")), int(entry.get("revision", 0)))
		"command": authority.command(entry.get("command"))
		_: return false
	return true

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

func _read_history(input_value: String):
	# Accept canonical JSON directly (the normal adapter path) or a file path for
	# shell-friendly larger histories.
	var parsed = JSON.parse_string(input_value) if input_value.begins_with("[") else null
	if parsed is Array:
		return parsed
	var file := FileAccess.open(input_value, FileAccess.READ)
	parsed = null if file == null else JSON.parse_string(file.get_as_text())
	return parsed if parsed is Array else null

func _fail(message: String, code: int) -> void:
	push_error("CONVERSATIONAL_WAREHOUSE_SESSION_ERROR %s" % message)
	quit(code)
