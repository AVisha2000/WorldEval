class_name EmbodimentReplayVerifier
extends RefCounted

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const SoloAuthority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const DuelAuthority := preload(
	"res://scripts/embodiment/duel_authority/embodiment_duel_authority.gd"
)
const ProtocolPackageIdentity := preload(
	"res://scripts/embodiment/protocol/embodiment_protocol_package_identity.gd"
)

const SCHEMA_VERSION := "llm-controller/episode-replay/1.0.0"
const PROTOCOL_VERSION := "llm-controller/0.1.0"
const PROTOCOL_PACKAGE_SHA256 := ProtocolPackageIdentity.SHA256
const MAX_REPLAY_BYTES := 16 * 1024 * 1024
const ROOT_FIELDS := [
	"schema_version", "protocol_version", "protocol_package_sha256", "config", "config_sha256",
	"initial_observations", "initial_state_hash", "steps", "final_terminal",
	"final_state_hash", "ledger_sha256",
]
const BODY_FIELDS := [
	"schema_version", "protocol_version", "protocol_package_sha256", "config", "config_sha256",
	"initial_observations", "initial_state_hash", "steps", "final_terminal", "final_state_hash",
]
const CONFIG_FIELDS := [
	"protocol_version", "episode_id", "mode", "task_id", "seed", "observation_profile",
	"timing_track", "maximum_episode_ticks", "participant_ids",
]


func verify(payload: PackedByteArray) -> Dictionary:
	if payload.is_empty() or payload.size() > MAX_REPLAY_BYTES:
		return _failure("replay_size_invalid")
	var parsed := Codec.parse_canonical(payload, MAX_REPLAY_BYTES)
	if not bool(parsed.get("ok", false)) or typeof(parsed.get("value")) != TYPE_DICTIONARY:
		return _failure("replay_json_invalid")
	var replay: Dictionary = parsed.value
	if not _exact_fields(replay, ROOT_FIELDS):
		return _failure("replay_shape_invalid")
	if replay.schema_version != SCHEMA_VERSION or replay.protocol_version != PROTOCOL_VERSION:
		return _failure("replay_version_invalid")
	if typeof(replay.config) != TYPE_DICTIONARY \
		or not _exact_fields(replay.config, CONFIG_FIELDS) \
		or not Codec._valid_episode_id(str(replay.config.get("episode_id", ""))) \
		or replay.config.get("protocol_version") != PROTOCOL_VERSION \
		or replay.config.get("timing_track") != "step-locked-v1" \
		or typeof(replay.config.get("seed")) != TYPE_INT or replay.config.seed < 0 \
		or replay.protocol_package_sha256 != PROTOCOL_PACKAGE_SHA256 \
		or not Codec._is_sha256(replay.config_sha256) \
		or Codec.sha256_bytes(Codec.canonical_bytes(replay.config)) != replay.config_sha256 \
		or typeof(replay.initial_observations) != TYPE_DICTIONARY \
		or typeof(replay.steps) != TYPE_ARRAY \
		or replay.steps.is_empty() \
		or typeof(replay.final_terminal) != TYPE_DICTIONARY \
		or not Codec._is_sha256(replay.initial_state_hash) \
		or not Codec._is_sha256(replay.final_state_hash) \
		or not Codec._is_sha256(replay.ledger_sha256):
		return _failure("replay_shape_invalid")
	var body := replay.duplicate(true)
	body.erase("ledger_sha256")
	if not _exact_fields(body, BODY_FIELDS) \
		or Codec.sha256_bytes(Codec.canonical_bytes(body)) != replay.ledger_sha256:
		return _failure("replay_digest_mismatch")
	var duel: bool = replay.config.mode in ["scripted-duel-v0", "model-duel-v0"]
	var authority = DuelAuthority.new() if duel else SoloAuthority.new()
	var hybrid: bool = replay.config.observation_profile == "hybrid-visible-v1"
	var config_errors: PackedStringArray = (
		authority.configure_managed_hybrid(replay.config)
		if hybrid else authority.configure(replay.config)
	)
	if not config_errors.is_empty():
		return _failure("replay_config_invalid")
	var initial_expected: Dictionary = (
		authority.observe_all()
		if duel else {authority.PARTICIPANT_ID: authority.observe()}
	)
	if _authority_observations(replay.initial_observations, hybrid) != initial_expected:
		return _failure("initial_observation_mismatch")
	if replay.initial_state_hash != authority.checkpoint_hash():
		return _failure("initial_hash_mismatch")
	for step_variant: Variant in replay.steps:
		if typeof(step_variant) != TYPE_DICTIONARY:
			return _failure("replay_step_invalid")
		var step: Dictionary = step_variant
		if not _exact_fields(step, ["decision_window", "result"]) \
			or typeof(step.decision_window) != TYPE_DICTIONARY \
			or typeof(step.result) != TYPE_DICTIONARY:
			return _failure("replay_step_invalid")
		var actual: Dictionary = authority.step_window(step.decision_window)
		var expected: Dictionary = step.result.duplicate(true)
		expected.observations = _authority_observations(expected.observations, hybrid)
		if actual != expected:
			return _failure("replay_result_mismatch")
	if not bool(authority.terminal.get("ended", false)) or replay.final_terminal != authority.terminal:
		return _failure("replay_incomplete")
	if replay.final_state_hash != authority.checkpoint_hash():
		return _failure("terminal_hash_mismatch")
	return {
		"ok": true,
		"code": "",
		"episode_id": str(replay.config.episode_id),
		"final_state_hash": authority.checkpoint_hash(),
	}


static func _authority_observations(value: Dictionary, hybrid: bool) -> Dictionary:
	var output: Dictionary = value.duplicate(true)
	if not hybrid:
		return output
	for participant_id: String in output:
		var observation: Dictionary = output[participant_id]
		observation.erase("frame")
		output[participant_id] = observation
	return output


static func _exact_fields(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
