class_name ConversationalWarehouseReplayVerifier
extends RefCounted

const Authority := preload("res://scripts/conversational_sandbox/conversational_warehouse_authority.gd")

static func verify(scenario: Dictionary, replay: Dictionary) -> Dictionary:
	if replay.get("schema_version") != "conversational-warehouse-replay.v1" or replay.get("provider_calls") != 0:
		return {"verified": false, "reason": "unsupported_replay"}
	var authority := Authority.new()
	authority.configure(scenario, str(replay.get("initialization_hash", "")))
	if not authority.acknowledge_initialization(str(replay.get("initialization_hash", ""))):
		return {"verified": false, "reason": "initialization_acknowledgement_failed"}
	for entry in replay.get("decisions", []):
		if not _apply(authority, entry):
			return {"verified": false, "reason": "malformed_replay_decision"}
	var rebuilt := authority.native_replay(str(replay.get("run_id", "")), false)
	# The replay is re-executed from its typed decisions.  Observation snapshots
	# are presentation evidence and can differ only in JSON's integer/float
	# spelling after a Python transport round-trip, so validate their terminal
	# state through the rebuilt authority rather than byte-string formatting.
	for field in ["scenario_id", "initialization_hash", "terminal_outcome", "terminal_tick", "terminal_state_hash", "provider_calls"]:
		if JSON.stringify(rebuilt.get(field), "", true, false) != JSON.stringify(replay.get(field), "", true, false):
			return {"verified": false, "reason": "%s_mismatch" % field}
	return {"verified": true, "reason": "verified", "final_state_hash": authority.state_hash()}


static func _apply(authority, entry: Dictionary) -> bool:
	match str(entry.get("kind", "")):
		"intent.begin": authority.begin_intent(str(entry.get("intent_id", "")), int(entry.get("revision", 0)), str(entry.get("text", "")))
		"binding.request": authority.request_binding(str(entry.get("intent_id", "")), entry.get("candidate_ids", []))
		"binding.resolve": authority.bind_target(str(entry.get("intent_id", "")), str(entry.get("binding_id", "")), str(entry.get("object_id", "")), int(entry.get("generation", 0)))
		"intent.revise": authority.revise_intent(str(entry.get("intent_id", "")), int(entry.get("revision", 0)))
		"command": authority.command(entry.get("command"))
		_: return false
	return true
