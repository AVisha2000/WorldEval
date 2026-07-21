class_name EmbodimentReplayVerifierV3
extends RefCounted

const CanonicalCodec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Dispatcher := preload("res://scripts/embodiment/v3/transport/trio_game_dispatcher_v3.gd")
const ProtocolIdentity := preload("res://scripts/embodiment/v3/protocol/embodiment_protocol_package_identity_v3.gd")

const SCHEMA_VERSION := "llm-controller/episode-replay/1.0.0"
const MAX_REPLAY_BYTES := 16 * 1024 * 1024
const ROOT_FIELDS := [
	"schema_version", "protocol_version", "protocol_package_sha256", "config", "config_sha256",
	"initial_observations", "initial_state_hash", "steps", "final_terminal",
	"final_result", "final_state_hash", "ledger_sha256",
]
const BODY_FIELDS := [
	"schema_version", "protocol_version", "protocol_package_sha256", "config", "config_sha256",
	"initial_observations", "initial_state_hash", "steps", "final_terminal", "final_result",
	"final_state_hash",
]


func verify(payload: PackedByteArray) -> Dictionary:
	if payload.is_empty() or payload.size() > MAX_REPLAY_BYTES:
		return _failure("replay_size_invalid")
	var parsed := CanonicalCodec.parse_canonical(payload, MAX_REPLAY_BYTES)
	if not bool(parsed.get("ok", false)) or not parsed.get("value") is Dictionary:
		return _failure("replay_json_invalid")
	var replay: Dictionary = parsed.value
	if not _exact_fields(replay, ROOT_FIELDS) \
		or replay.get("schema_version") != SCHEMA_VERSION \
		or replay.get("protocol_version") != ProtocolIdentity.PROTOCOL_VERSION \
		or replay.get("protocol_package_sha256") != ProtocolIdentity.SHA256 \
		or not replay.get("config") is Dictionary \
		or not CanonicalCodec._is_sha256(replay.get("config_sha256")) \
		or CanonicalCodec.sha256_bytes(CanonicalCodec.canonical_bytes(replay.config)) != replay.config_sha256 \
		or not replay.get("initial_observations") is Dictionary \
		or not replay.get("steps") is Array or replay.steps.is_empty() \
		or not replay.get("final_terminal") is Dictionary \
		or not replay.get("final_result") is Dictionary \
		or not CanonicalCodec._is_sha256(replay.get("initial_state_hash")) \
		or not CanonicalCodec._is_sha256(replay.get("final_state_hash")) \
		or not CanonicalCodec._is_sha256(replay.get("ledger_sha256")):
		return _failure("replay_shape_invalid")
	var body := replay.duplicate(true)
	body.erase("ledger_sha256")
	if not _exact_fields(body, BODY_FIELDS) \
		or CanonicalCodec.sha256_bytes(CanonicalCodec.canonical_bytes(body)) != replay.ledger_sha256:
		return _failure("replay_digest_mismatch")
	var dispatcher := Dispatcher.new()
	if not dispatcher.configure(replay.config).is_empty():
		return _failure("replay_config_invalid")
	if _semantic_observations(replay.initial_observations) != dispatcher.observe_all():
		return _failure("initial_observation_mismatch")
	if replay.initial_state_hash != dispatcher.checkpoint_hash():
		return _failure("initial_hash_mismatch")
	for step_variant: Variant in replay.steps:
		if not step_variant is Dictionary or not _exact_fields(step_variant, ["decision_window", "result"]) \
			or not dispatcher.decision_window_schema_valid(step_variant.decision_window) \
			or not step_variant.result is Dictionary:
			return _failure("replay_step_invalid")
		var actual: Dictionary = dispatcher.step_window(step_variant.decision_window)
		var expected: Dictionary = step_variant.result.duplicate(true)
		expected.observations = _semantic_observations(expected.observations)
		if actual != expected:
			return _failure("replay_result_mismatch")
	if not bool(dispatcher.terminal().get("ended", false)) \
		or replay.final_terminal != dispatcher.terminal():
		return _failure("replay_incomplete")
	if replay.final_result != replay.steps[-1].result.get("trio_result"):
		return _failure("replay_final_result_mismatch")
	if replay.final_state_hash != dispatcher.checkpoint_hash():
		return _failure("terminal_hash_mismatch")
	return {
		"ok": true,
		"code": "",
		"episode_id": str(replay.config.episode_id),
		"final_state_hash": dispatcher.checkpoint_hash(),
		"protocol_version": ProtocolIdentity.PROTOCOL_VERSION,
		"protocol_package_sha256": ProtocolIdentity.SHA256,
	}


static func _semantic_observations(value: Dictionary) -> Dictionary:
	var output: Dictionary = value.duplicate(true)
	for participant_id: String in output:
		var observation: Dictionary = output[participant_id]
		if observation.get("profile") == "hybrid-visible-v1":
			observation.erase("frame")
			observation.profile = "text-visible-v1"
		output[participant_id] = observation
	return output


static func _exact_fields(value: Variant, fields: Array) -> bool:
	if not value is Dictionary or value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
