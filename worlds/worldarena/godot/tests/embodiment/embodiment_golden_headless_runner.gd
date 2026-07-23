extends SceneTree

## Cross-runtime certification: replay the checked-in Stage-A golden decisions through Godot and
## compare every visible boundary, event sequence, and checkpoint hash byte-for-byte.

const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")

const GOLDEN_SCHEMA_VERSION := "llm-controller/golden-transcript/1.0.0"
const PROTOCOL_VERSION := "llm-controller/0.1.0"
const ROOT_FIELDS := [
	"schema_version", "protocol_version", "transcript_id", "config", "config_sha256",
	"initial_boundary", "steps", "terminal_boundary", "transcript_sha256",
]
const TRANSCRIPT_IDS := [
	"stage-a-orientation-forward-v1",
	"stage-b-interaction-v1",
	"stage-c-construction-v1",
	"stage-d-neutral-encounter-v1",
]


func _init() -> void:
	for transcript_id: String in TRANSCRIPT_IDS:
		var result := _verify_fixture(transcript_id)
		if not bool(result.get("ok", false)):
			push_error(
				"EMBODIMENT_GOLDEN_FAILED: %s: %s"
				% [transcript_id, str(result.get("code", "unknown"))]
			)
			quit(1)
			return
	print("EMBODIMENT_GOLDEN_OK")
	quit(0)


func _verify_fixture(transcript_id: String) -> Dictionary:
	var fixture_path := ProjectSettings.globalize_path(
		"res://../game/embodiment_protocol/golden/%s.json" % transcript_id
	)
	var file := FileAccess.open(fixture_path, FileAccess.READ)
	if file == null:
		return _failure("fixture_missing")
	var payload := file.get_buffer(file.get_length())
	if payload.is_empty() or payload[payload.size() - 1] != 10:
		return _failure("fixture_record_terminator_invalid")
	payload.resize(payload.size() - 1)
	var parsed := Codec.parse_canonical(payload, 16 * 1024 * 1024)
	if not bool(parsed.get("ok", false)) or typeof(parsed.get("value")) != TYPE_DICTIONARY:
		return _failure("fixture_not_canonical")
	var transcript: Dictionary = parsed.value
	if not _exact_fields(transcript, ROOT_FIELDS) \
		or transcript.schema_version != GOLDEN_SCHEMA_VERSION \
		or transcript.protocol_version != PROTOCOL_VERSION \
		or transcript.transcript_id != transcript_id:
		return _failure("fixture_identity_invalid")
	var body := transcript.duplicate(true)
	body.erase("transcript_sha256")
	if not Codec._is_sha256(transcript.transcript_sha256) \
		or Codec.sha256_bytes(Codec.canonical_bytes(body)) != transcript.transcript_sha256:
		return _failure("fixture_seal_mismatch")
	if typeof(transcript.config) != TYPE_DICTIONARY \
		or Codec.sha256_bytes(Codec.canonical_bytes(transcript.config)) != transcript.config_sha256:
		return _failure("fixture_config_digest_mismatch")
	var authority := Authority.new()
	var errors: PackedStringArray = authority.configure(transcript.config)
	if not errors.is_empty():
		return _failure("fixture_config_invalid")
	var expected_initial := {
		"observations": {"participant_0": authority.observe()},
		"state_hash": authority.checkpoint_hash(),
	}
	if transcript.initial_boundary != expected_initial:
		return _failure("fixture_initial_boundary_mismatch")
	if typeof(transcript.steps) != TYPE_ARRAY or transcript.steps.is_empty():
		return _failure("fixture_steps_invalid")
	for index: int in transcript.steps.size():
		var step: Variant = transcript.steps[index]
		if typeof(step) != TYPE_DICTIONARY or not _exact_fields(
			step,
			["index", "decision_window", "result", "event_sequence_sha256", "state_hash"],
		) or step.index != index:
			return _failure("fixture_step_invalid")
		var actual: Dictionary = authority.step_window(step.decision_window)
		if actual != step.result:
			return _failure("fixture_result_mismatch_%d" % index)
		if actual.state_hash != step.state_hash:
			return _failure("fixture_state_hash_mismatch_%d" % index)
		var event_digest := Codec.sha256_bytes(Codec.canonical_bytes(actual.public_events))
		if event_digest != step.event_sequence_sha256:
			return _failure("fixture_event_sequence_mismatch_%d" % index)
	var expected_terminal := {
		"terminal": authority.terminal.duplicate(true),
		"state_hash": authority.checkpoint_hash(),
	}
	if transcript.terminal_boundary != expected_terminal or not bool(authority.terminal.ended):
		return _failure("fixture_terminal_boundary_mismatch")
	return {"ok": true, "code": ""}


static func _exact_fields(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
