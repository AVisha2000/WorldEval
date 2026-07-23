class_name WaypointMazeReplayVerifier
extends RefCounted

## Provider-free deterministic re-execution in the Godot gameplay authority.

const Authority := preload(
	"res://scripts/agent_waypoint_maze/waypoint_maze_authority.gd"
)
const REPLAY_SCHEMA := "replay-bundle.v1"
const PROTOCOL := "worldeval-agent/0.1.0"


static func verify(
	scenario: Dictionary,
	decision_profile: Dictionary,
	replay: Dictionary,
	expected_initialization_hash: String,
) -> Dictionary:
	if scenario.is_empty() or decision_profile.is_empty() or replay.is_empty():
		return _failure("input_missing")
	if replay.get("schema_version") != REPLAY_SCHEMA:
		return _failure("schema_version_mismatch")
	if replay.get("protocol") != PROTOCOL:
		return _failure("protocol_mismatch")
	if replay.get("environment_id") != scenario.get("environment_id"):
		return _failure("environment_id_mismatch")
	if replay.get("scenario_id") != scenario.get("scenario_id"):
		return _failure("scenario_id_mismatch")
	if not replay.get("run_id") is String or replay["run_id"].is_empty():
		return _failure("run_id_invalid")
	if replay.get("provider_calls") != 0:
		return _failure("provider_calls_nonzero")
	if replay.get("terminal_outcome") == "incomplete":
		return _failure("terminal_outcome_incomplete")
	if replay.get("offline_verified") != true:
		return _failure("offline_verification_flag_missing")

	var replay_decisions = replay.get("decisions")
	var replay_receipts = replay.get("receipts")
	var replay_observations = replay.get("observations")
	if not replay_decisions is Array:
		return _failure("decisions_invalid")
	if not replay_receipts is Array:
		return _failure("receipts_invalid")
	if not replay_observations is Array:
		return _failure("observations_invalid")
	if replay_decisions.size() != replay_receipts.size():
		return _failure("receipt_count_mismatch")
	if replay_observations.size() != replay_decisions.size() + 1:
		return _failure("observation_count_mismatch")

	if (
		expected_initialization_hash.is_empty()
		or replay.get("initialization_hash") != expected_initialization_hash
	):
		return _failure("initialization_hash_mismatch")
	var verifier := Authority.new()
	verifier.configure(scenario, expected_initialization_hash, decision_profile)
	if replay.get("initial_state_hash") != verifier.initial_state_hash:
		return _failure("initial_state_hash_mismatch")
	if not verifier.acknowledge_initialization(replay["initialization_hash"]):
		return _failure("initialization_acknowledgement_failed")

	for index in range(replay_decisions.size()):
		if not replay_receipts[index] is Dictionary:
			return _failure("receipt_invalid")
		if verifier.terminal:
			return _failure("decision_after_terminal")
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
		if _canonical(rebuilt.get(field)) != _canonical(replay.get(field)):
			return _failure("%s_mismatch" % field)
	if not verifier.terminal:
		return _failure("reexecution_not_terminal")
	return {
		"verified": true,
		"reason": "verified",
		"final_state_hash": verifier.state_hash(),
		"provider_calls": 0,
	}


static func _canonical(value) -> String:
	return JSON.stringify(value, "", true, false)


static func _failure(reason: String) -> Dictionary:
	return {"verified": false, "reason": reason}
