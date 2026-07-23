class_name EmbodimentManagedSessionHostV3
extends RefCounted

const CodecV3 := preload("res://scripts/embodiment/v3/transport/embodiment_frame_codec_v3.gd")
const CanonicalCodec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Dispatcher := preload("res://scripts/embodiment/v3/transport/trio_game_dispatcher_v3.gd")
const ProtocolIdentity := preload("res://scripts/embodiment/v3/protocol/embodiment_protocol_package_identity_v3.gd")

const PHASE_UNCONFIGURED := "unconfigured"
const PHASE_AWAITING_AUTH := "awaiting_auth"
const PHASE_RUNNING := "running"
const PHASE_COMPLETE := "complete"
const PHASE_FAILED := "failed"

var _dispatcher = null
var _codec = null
var _phase := PHASE_UNCONFIGURED
var _connection_id := ""
var _attachment_ticket := ""
var _config_hash := ""
var _observation_profile := "text-visible-v1"
var _frame_adapter = null


func configure(launch: Dictionary, session_secret: PackedByteArray, participant_frame_adapter: Object = null) -> PackedStringArray:
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
	if launch.get("protocol_package_sha256") != ProtocolIdentity.SHA256:
		errors.append("protocol_package_hash_invalid")
	if not CanonicalCodec._is_sha256(_config_hash):
		errors.append("config_hash_invalid")
	var config: Variant = launch.get("config")
	if typeof(config) != TYPE_DICTIONARY:
		errors.append("config_invalid")
	elif CanonicalCodec.sha256_bytes(CanonicalCodec.canonical_bytes(config)) != _config_hash:
		errors.append("config_hash_mismatch")
	if not errors.is_empty():
		return errors
	_observation_profile = config.observation_profile
	_frame_adapter = participant_frame_adapter
	if _observation_profile == "hybrid-visible-v1" and _frame_adapter == null:
		errors.append("hybrid_participant_frame_adapter_unavailable")
		return errors
	_dispatcher = Dispatcher.new()
	errors.append_array(_dispatcher.configure(config))
	if not errors.is_empty():
		_dispatcher = null
		return errors
	_codec = CodecV3.new()
	errors.append_array(_codec.configure(str(config.episode_id), session_secret, "godot"))
	if not errors.is_empty():
		_dispatcher = null
		_codec = null
		return errors
	_phase = PHASE_AWAITING_AUTH
	return errors


func begin_handshake() -> Dictionary:
	if _phase != PHASE_AWAITING_AUTH:
		return _failure("phase_violation")
	return _codec.encode("hello", CodecV3.ZERO_HASH, {"connection_id": _connection_id})


func receive(payload: PackedByteArray) -> Dictionary:
	if _phase not in [PHASE_AWAITING_AUTH, PHASE_RUNNING]:
		return _failure("phase_violation")
	var decoded: Dictionary = _codec.decode(payload)
	if not bool(decoded.get("ok", false)):
		return _fail(str(decoded.get("code", "frame_invalid")))
	var frame: Dictionary = decoded.frame
	if _phase == PHASE_AWAITING_AUTH:
		return _receive_auth(frame)
	return _receive_running(frame)


func close() -> void:
	if _codec != null:
		_codec.close()
	if _frame_adapter != null and _frame_adapter.has_method("close"):
		_frame_adapter.close()
	_frame_adapter = null
	_attachment_ticket = ""
	_connection_id = ""
	if _phase != PHASE_COMPLETE:
		_phase = PHASE_FAILED


func phase() -> String:
	return _phase


func checkpoint_hash() -> String:
	return _dispatcher.checkpoint_hash() if _dispatcher != null else CodecV3.ZERO_HASH


func _receive_auth(frame: Dictionary) -> Dictionary:
	if frame.message_type != "auth" or frame.body != {"attachment_ticket": _attachment_ticket}:
		return _fail("auth_invalid")
	_attachment_ticket = ""
	_phase = PHASE_RUNNING
	var observations := _boundary_observations()
	if not bool(observations.get("ok", false)):
		return _fail(str(observations.get("code", "participant_frame_failed")))
	return _codec.encode("episode_ready", _config_hash, {
		"capability_status": _dispatcher.capability_status(),
		"observations": observations.observations,
		"protocol_package_sha256": ProtocolIdentity.SHA256,
		"state_hash": _dispatcher.checkpoint_hash(),
	})


func _receive_running(frame: Dictionary) -> Dictionary:
	var expected_hash: String = _dispatcher.checkpoint_hash()
	if frame.boundary_hash != expected_hash:
		return _fail("stale_checkpoint")
	match str(frame.message_type):
		"decision_window":
			if not _exact_body(frame.body, ["window"]):
				return _fail("decision_window_body_invalid")
			var result: Dictionary = _dispatcher.step_window(frame.body.window)
			var observations := _boundary_observations()
			if not bool(observations.get("ok", false)):
				return _fail(str(observations.get("code", "participant_frame_failed")))
			result.observations = observations.observations
			if not _valid_result_shape(result):
				return _fail("authority_result_invalid")
			return _codec.encode("step_result", _dispatcher.checkpoint_hash(), {"result": result})
		"frame_request":
			return _receive_frame_request(frame)
		"close_episode":
			if not frame.body.is_empty():
				return _fail("close_body_invalid")
			_phase = PHASE_COMPLETE
			return _codec.encode("episode_closed", expected_hash, {
				"state_hash": expected_hash,
				"terminal": _dispatcher.terminal(),
			})
	return _fail("message_type_out_of_phase")


func _boundary_observations() -> Dictionary:
	var observations: Dictionary = _dispatcher.observe_all()
	if _observation_profile == "text-visible-v1":
		return {"ok": true, "observations": observations}
	if _frame_adapter == null or not _frame_adapter.has_method("attach_participant_frame"):
		return _failure("hybrid_participant_frame_adapter_unavailable")
	for participant_id: String in _dispatcher.config.participant_ids:
		if not observations.has(participant_id):
			return _failure("participant_observation_missing")
		var source: Dictionary = _dispatcher.participant_presentation_source(participant_id)
		if source.get("participant_id") != participant_id:
			return _failure("participant_presentation_source_invalid")
		var attached: Variant = _frame_adapter.attach_participant_frame(
			participant_id, observations[participant_id], source
		)
		if not attached is Dictionary or attached.get("profile") != "hybrid-visible-v1" \
			or not attached.get("frame") is Dictionary:
			return _failure("hybrid_participant_frame_invalid")
		observations[participant_id] = attached
	return {"ok": true, "observations": observations}


func _receive_frame_request(frame: Dictionary) -> Dictionary:
	if _frame_adapter == null or not _frame_adapter.has_method("frame_response"):
		return _fail("frame_request_invalid")
	var response: Variant = _frame_adapter.frame_response(frame.body)
	if not response is Dictionary:
		return _fail("frame_request_invalid")
	return _codec.encode("frame_response", _dispatcher.checkpoint_hash(), response)


func _valid_result_shape(result: Dictionary) -> bool:
	var participant_ids: Array = _dispatcher.config.participant_ids
	return _exact_body(result, [
		"observations", "receipts", "public_events", "state_hash", "terminal", "placements",
		"trio_result",
	]) \
		and _participant_keys_match(result.observations, participant_ids) \
		and _participant_keys_match(result.receipts, participant_ids) \
		and result.public_events is Array \
		and result.placements is Array \
		and ((bool(result.terminal.get("ended", false)) and result.trio_result is Dictionary) \
			or (not bool(result.terminal.get("ended", false)) and result.trio_result == null)) \
		and CanonicalCodec._is_sha256(result.state_hash) \
		and result.terminal is Dictionary


static func _participant_keys_match(value: Variant, participant_ids: Array) -> bool:
	if not value is Dictionary or value.size() != participant_ids.size():
		return false
	for participant_id: String in participant_ids:
		if not value.has(participant_id):
			return false
	return true


func _fail(code: String) -> Dictionary:
	_phase = PHASE_FAILED
	return _failure(code)


func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}


static func _exact_body(value: Variant, fields: Array) -> bool:
	if not value is Dictionary or value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _ascii_token(value: String, minimum: int, maximum: int) -> bool:
	if value.length() < minimum or value.length() > maximum:
		return false
	for index: int in value.length():
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 46, 95]):
			return false
	return true
