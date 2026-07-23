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

## A model only plans at an autonomous-task boundary.  Reusing an already participant-visible
## frame between executor ticks prevents PNG capture/transport from delaying deterministic 10 Hz
## authority.  The short wait horizon matches the task-plan contract; other tasks get a forced
## refresh before their deterministic safety timeout can cause another planner request.
const AUTONOMOUS_FRAME_REFRESH_TICKS := 180
const WAIT_FRAME_REFRESH_TICKS := 10

var _authority = null
var _codec = null
var _phase := PHASE_UNCONFIGURED
var _connection_id := ""
var _attachment_ticket := ""
var _config_hash := ""
var _participant_ids: Array[String] = ["participant_0"]
var _observation_profile := "text-visible-v1"
var _task_id := ""
var _presentations := {}
var _cached_frame_metadata := {}
var _active_autonomous_task := ""
var _active_autonomous_ticks := 0


func configure(
	launch: Dictionary,
	session_secret: PackedByteArray,
	presentation_scene: Variant = null,
	viewport: Variant = null,
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
	_task_id = str(config.get("task_id", ""))
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
		for participant_id: String in _participant_ids:
			var participant_scene: Variant = (
				presentation_scene.get(participant_id)
				if presentation_scene is Dictionary else presentation_scene
			)
			var participant_viewport: Variant = (
				viewport.get(participant_id) if viewport is Dictionary else viewport
			)
			if not participant_scene is Node or not participant_viewport is SubViewport:
				errors.append("hybrid_presentation_unavailable")
				break
			_presentations[participant_id] = HybridAdapter.new(
				_authority, participant_scene, participant_viewport, null, 8, 64 * 1024 * 1024
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
	var closed := {}
	for presentation: Variant in _presentations.values():
		if presentation != null and not closed.has(presentation):
			presentation.close()
			closed[presentation] = true
	_presentations.clear()
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
	var observation_result := await _boundary_observations(true)
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
			var capture_fresh_frame := _should_capture_fresh_frame(frame.body.window, result)
			var observation_result := await _boundary_observations(capture_fresh_frame)
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


func _boundary_observations(capture_fresh_frame: bool) -> Dictionary:
	var observations := {}
	for participant_id: String in _participant_ids:
		if _observation_profile != "hybrid-visible-v1":
			observations[participant_id] = (
				_authority.observe(participant_id)
				if _participant_ids.size() == 2 else _authority.observe()
			)
			continue
		var presentation: Variant = _presentations.get(participant_id)
		if presentation == null:
			return _failure("hybrid_presentation_unavailable")
		if capture_fresh_frame or not _cached_frame_metadata.has(participant_id):
			_discard_cached_frame(participant_id)
			var captured: Dictionary = await presentation.capture_boundary(participant_id)
			if not bool(captured.get("ok", false)):
				return _failure(str(captured.get("code", "hybrid_capture_failed")))
			observations[participant_id] = captured.observation
			_cached_frame_metadata[participant_id] = captured.observation.frame.duplicate(true)
		else:
			var reused: Dictionary = presentation.observe_with_cached_frame(
				participant_id, _cached_frame_metadata[participant_id]
			)
			if not bool(reused.get("ok", false)):
				return _failure(str(reused.get("code", "hybrid_cached_frame_failed")))
			observations[participant_id] = reused.observation
	return {"ok": true, "observations": observations}


func _receive_frame_request(frame: Dictionary) -> Dictionary:
	if not _exact_body(
		frame.body, ["participant_id", "sensor_id", "observation_seq", "transport_ref"]
	) or not _presentations.has(str(frame.body.get("participant_id", ""))):
		return _fail("frame_request_invalid")
	if frame.body.participant_id not in _participant_ids \
		or frame.body.sensor_id != "operator-follow-v1" \
		or typeof(frame.body.observation_seq) != TYPE_INT \
		or typeof(frame.body.transport_ref) != TYPE_STRING:
		return _fail("frame_request_invalid")
	var presentation: Variant = _presentations.get(str(frame.body.participant_id))
	var fetched: Dictionary = presentation.frame_bytes(frame.body.transport_ref)
	if not bool(fetched.get("ok", false)):
		return _fail("frame_request_invalid")
	var fetched_record: Dictionary = presentation.frame_record(frame.body.transport_ref)
	if not bool(fetched_record.get("ok", false)):
		return _fail("frame_request_invalid")
	var record: Dictionary = fetched_record.record
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


func _should_capture_fresh_frame(window: Dictionary, result: Dictionary) -> bool:
	# This optimization is deliberately scoped to the managed Construction task-plan executor.
	# Other hybrid tasks and every duel retain their prior fresh-boundary behavior.
	if _observation_profile != "hybrid-visible-v1" or _task_id != "construction-v0":
		return true
	var task := _autonomous_task(window)
	if task.is_empty():
		_active_autonomous_task = ""
		_active_autonomous_ticks = 0
		return true
	if task != _active_autonomous_task:
		_active_autonomous_task = task
		_active_autonomous_ticks = 1
		return true
	_active_autonomous_ticks += 1
	if bool(result.get("terminal", {}).get("ended", false)) or _task_completed(result):
		_active_autonomous_task = ""
		_active_autonomous_ticks = 0
		return true
	var refresh_limit := WAIT_FRAME_REFRESH_TICKS if task == "wait" else AUTONOMOUS_FRAME_REFRESH_TICKS
	if _active_autonomous_ticks >= refresh_limit:
		_active_autonomous_ticks = 0
		return true
	return false


func _autonomous_task(window: Dictionary) -> String:
	if not window.has("decisions") or not window.decisions is Dictionary:
		return ""
	if _participant_ids.is_empty():
		return ""
	var decision: Variant = window.decisions.get(_participant_ids[0])
	if not decision is Dictionary or decision.get("disposition") != "accepted":
		return ""
	var action: Variant = decision.get("action")
	if not action is Dictionary or not action.get("control") is Dictionary:
		return ""
	var task: Variant = action.control.get("autonomous_task")
	return task if typeof(task) == TYPE_STRING else ""


func _task_completed(result: Dictionary) -> bool:
	var receipts: Variant = result.get("receipts")
	if not receipts is Dictionary:
		return false
	for participant_id: String in _participant_ids:
		var receipt: Variant = receipts.get(participant_id)
		if receipt is Dictionary and receipt.get("codes") is Array \
			and "autonomous_task_complete" in receipt.codes:
			return true
	return false


func _discard_cached_frame(participant_id: String) -> void:
	var metadata: Variant = _cached_frame_metadata.get(participant_id)
	var presentation: Variant = _presentations.get(participant_id)
	if metadata is Dictionary and presentation != null:
		presentation.discard_frame(str(metadata.get("transport_ref", "")))
	_cached_frame_metadata.erase(participant_id)


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
