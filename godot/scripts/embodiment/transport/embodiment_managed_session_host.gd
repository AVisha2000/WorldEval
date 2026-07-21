class_name EmbodimentManagedSessionHost
extends RefCounted

const FrameCodec := preload(
	"res://scripts/embodiment/transport/embodiment_frame_codec.gd"
)
const SoloAuthority := preload(
	"res://scripts/embodiment/embodiment_solo_simulation.gd"
)
const DuelAuthority := preload(
	"res://scripts/embodiment/duel_authority/embodiment_duel_authority.gd"
)
const HybridAdapter := preload(
	"res://scripts/embodiment/presentation/embodiment_hybrid_presentation_adapter.gd"
)

const PHASE_UNCONFIGURED := "unconfigured"
const PHASE_AWAITING_AUTH := "awaiting_auth"
const PHASE_RUNNING := "running"
const PHASE_COMPLETE := "complete"
const PHASE_FAILED := "failed"

var _authority = null
var _codec = null
var _phase := PHASE_UNCONFIGURED
var _connection_id := ""
var _attachment_ticket := ""
var _config_hash := ""
var _participant_ids: Array[String] = ["participant_0"]
var _observation_profile := "text-visible-v1"
var _presentation = null


func configure(
	launch: Dictionary,
	session_secret: PackedByteArray,
	presentation_scene: Node = null,
	viewport: SubViewport = null,
) -> PackedStringArray:
	var errors := PackedStringArray()
	if _phase != PHASE_UNCONFIGURED:
		errors.append("host_already_configured")
		return errors
	_connection_id = str(launch.get("connection_id", ""))
	_attachment_ticket = str(launch.get("attachment_ticket", ""))
	_config_hash = str(launch.get("config_sha256", ""))
	if not _ascii_token(_connection_id, 1, 128):
		errors.append("connection_id_invalid")
	if not _ascii_token(_attachment_ticket, 43, 43):
		errors.append("attachment_ticket_invalid")
	if not FrameCodec._is_sha256(_config_hash):
		errors.append("config_hash_invalid")
	var config: Variant = launch.get("config")
	if typeof(config) != TYPE_DICTIONARY:
		errors.append("config_invalid")
	elif FrameCodec.sha256_bytes(FrameCodec.canonical_bytes(config)) != _config_hash:
		errors.append("config_hash_mismatch")
	if not errors.is_empty():
		return errors
	_observation_profile = str(config.get("observation_profile", ""))
	_participant_ids.assign(config.get("participant_ids", []))
	if _observation_profile == "hybrid-visible-v1":
		if presentation_scene == null or viewport == null:
			errors.append("hybrid_presentation_unavailable")
			return errors
	var duel_mode := str(config.get("mode", "")) in ["scripted-duel-v0", "model-duel-v0"]
	_authority = DuelAuthority.new() if duel_mode else SoloAuthority.new()
	if _observation_profile == "hybrid-visible-v1":
		errors.append_array(_authority.configure_managed_hybrid(config))
	else:
		errors.append_array(_authority.configure(config))
	if not errors.is_empty():
		_authority = null
		return errors
	if _observation_profile == "hybrid-visible-v1":
		_presentation = HybridAdapter.new(
			_authority, presentation_scene, viewport, null, 8, 64 * 1024 * 1024
		)
	_codec = FrameCodec.new()
	errors.append_array(_codec.configure(str(config.episode_id), session_secret, "godot"))
	if not errors.is_empty():
		_authority = null
		_codec = null
		return errors
	_phase = PHASE_AWAITING_AUTH
	return errors


func begin_handshake() -> Dictionary:
	if _phase != PHASE_AWAITING_AUTH:
		return _failure("phase_violation")
	return _codec.encode("hello", FrameCodec.ZERO_HASH, {"connection_id": _connection_id})


func receive(payload: PackedByteArray) -> Dictionary:
	if _phase not in [PHASE_AWAITING_AUTH, PHASE_RUNNING]:
		return _failure("phase_violation")
	var decoded: Dictionary = _codec.decode(payload)
	if not bool(decoded.get("ok", false)):
		return _fail(str(decoded.get("code", "frame_invalid")))
	var frame: Dictionary = decoded.frame
	match _phase:
		PHASE_AWAITING_AUTH:
			return await _receive_auth(frame)
		PHASE_RUNNING:
			return await _receive_running(frame)
	return _fail("phase_violation")


func close() -> void:
	if _codec != null:
		_codec.close()
	if _presentation != null:
		_presentation.close()
		_presentation = null
	_attachment_ticket = ""
	_connection_id = ""
	if _phase != PHASE_COMPLETE:
		_phase = PHASE_FAILED


func phase() -> String:
	return _phase


func checkpoint_hash() -> String:
	return _authority.checkpoint_hash() if _authority != null else FrameCodec.ZERO_HASH


func _receive_auth(frame: Dictionary) -> Dictionary:
	if frame.message_type != "auth" or frame.body != {"attachment_ticket": _attachment_ticket}:
		return _fail("auth_invalid")
	_attachment_ticket = ""
	_phase = PHASE_RUNNING
	var observation_result := await _boundary_observations()
	if not bool(observation_result.get("ok", false)):
		return _fail(str(observation_result.get("code", "hybrid_capture_failed")))
	return _codec.encode("episode_ready", _config_hash, {
		"capability_status": _authority.capability_status(),
		"observations": observation_result.observations,
		"state_hash": _authority.checkpoint_hash(),
	})


func _receive_running(frame: Dictionary) -> Dictionary:
	var expected_hash: String = _authority.checkpoint_hash()
	if frame.boundary_hash != expected_hash:
		return _fail("stale_checkpoint")
	match str(frame.message_type):
		"decision_window":
			if not _exact_body(frame.body, ["window"]) or not frame.body.window is Dictionary:
				return _fail("decision_window_body_invalid")
			var result: Dictionary = _authority.step_window(frame.body.window)
			var observation_result := await _boundary_observations()
			if not bool(observation_result.get("ok", false)):
				return _fail(str(observation_result.get("code", "hybrid_capture_failed")))
			result.observations = observation_result.observations
			return _codec.encode("step_result", _authority.checkpoint_hash(), {"result": result})
		"frame_request":
			return _receive_frame_request(frame)
		"close_episode":
			if not frame.body.is_empty():
				return _fail("close_body_invalid")
			_phase = PHASE_COMPLETE
			return _codec.encode("episode_closed", expected_hash, {
				"state_hash": expected_hash,
				"terminal": _authority.terminal.duplicate(true),
			})
	return _fail("message_type_out_of_phase")


func _boundary_observations() -> Dictionary:
	var observations := {}
	for participant_id: String in _participant_ids:
		if _observation_profile != "hybrid-visible-v1":
			observations[participant_id] = (
				_authority.observe(participant_id)
				if _participant_ids.size() == 2 else _authority.observe()
			)
			continue
		if _presentation == null:
			return _failure("hybrid_presentation_unavailable")
		var captured: Dictionary = await _presentation.capture_boundary(participant_id)
		if not bool(captured.get("ok", false)):
			return _failure(str(captured.get("code", "hybrid_capture_failed")))
		observations[participant_id] = captured.observation
	return {"ok": true, "observations": observations}


func _receive_frame_request(frame: Dictionary) -> Dictionary:
	if _presentation == null or not _exact_body(
		frame.body, ["participant_id", "sensor_id", "observation_seq", "transport_ref"]
	):
		return _fail("frame_request_invalid")
	if frame.body.participant_id not in _participant_ids \
		or frame.body.sensor_id != "operator-follow-v1" \
		or typeof(frame.body.observation_seq) != TYPE_INT \
		or typeof(frame.body.transport_ref) != TYPE_STRING:
		return _fail("frame_request_invalid")
	var fetched: Dictionary = _presentation.take_frame_bytes(frame.body.transport_ref)
	if not bool(fetched.get("ok", false)):
		return _fail("frame_request_invalid")
	var record: Dictionary = fetched.record
	if record.participant_id != frame.body.participant_id \
		or record.observation_sequence != frame.body.observation_seq \
		or record.frame.sensor_id != frame.body.sensor_id \
		or record.frame.transport_ref != frame.body.transport_ref:
		return _fail("frame_request_invalid")
	return _codec.encode("frame_response", _authority.checkpoint_hash(), {
		"metadata": record.frame,
		"observation_seq": record.observation_sequence,
		"participant_id": record.participant_id,
		"png_base64": Marshalls.raw_to_base64(fetched.bytes),
	})


func _fail(code: String) -> Dictionary:
	_phase = PHASE_FAILED
	return _failure(code)


func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}


static func _exact_body(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _ascii_token(value: String, minimum: int, maximum: int) -> bool:
	if value.length() < minimum or value.length() > maximum:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 46, 95]):
			return false
	return true
