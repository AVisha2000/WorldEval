class_name EmbodimentRtsSkirmishParticipantFrameAdapter
extends RefCounted

## Hybrid frame adapter for the RTS skirmish participant view.
## It binds pixels to a deep-copied public broadcast projection. `own` is allowed because the
## authority already filtered it to the current player; no checkpoint or rival-private object is
## ever accepted by this adapter.

const Capture := preload("res://scripts/embodiment/presentation/capture/participant_frame_capture.gd")

var _scenes: Dictionary
var _viewports: Dictionary
var _capture := Capture.new(8, 64 * 1024 * 1024)
var _latest_refs := {}
var _closed := false
var _broadcast_scene: Node = null
var _broadcast_sources := {}


func _init(scenes: Dictionary, viewports: Dictionary) -> void:
	_scenes = scenes.duplicate()
	_viewports = viewports.duplicate()


func set_broadcast_scene(scene: Node) -> bool:
	if _closed or scene == null or not scene.has_method("apply_public_sources"):
		return false
	_broadcast_scene = scene
	return true


func attach_participant_frame(participant_id: String, observation: Dictionary, source: Dictionary) -> Dictionary:
	if _closed or not _scenes.has(participant_id) or not _viewports.has(participant_id):
		return {}
	if source.get("participant_id") != participant_id \
		or (observation.has("participant_id") and observation.get("participant_id") != participant_id) \
		or not source.get("operator") is Dictionary or not source.get("visible_entities") is Array:
		return {}
	var scene: Node = _scenes[participant_id]
	var viewport: SubViewport = _viewports[participant_id]
	if scene == null or viewport == null or not scene.apply_participant_projection(source.duplicate(true), observation.duplicate(true)):
		return {}
	# This is intentionally outside the participant frame/evidence path. The overview receives
	# only the two separately filtered presentation sources; it cannot influence `output`, capture
	# bytes, authority hash, provider input, or the frame request handled below.
	if _broadcast_scene != null:
		_broadcast_sources[participant_id] = source.duplicate(true)
		if _broadcast_sources.size() == 2:
			_broadcast_scene.call(
				"apply_public_sources", _broadcast_sources.duplicate(true),
				int(observation.get("observation_seq", -1)), int(observation.get("tick", -1))
			)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	RenderingServer.force_draw(false)
	if _latest_refs.has(participant_id):
		_capture.discard_frame(str(_latest_refs[participant_id]))
		_latest_refs.erase(participant_id)
	var visible_snapshot := {
		"episode_id": observation.get("episode_id", ""), "observation_seq": observation.get("observation_seq", -1),
		"participant_id": participant_id, "tick": observation.get("tick", -1),
		"operator": source.operator.duplicate(true), "own": source.get("own", {}).duplicate(true),
		"visible_entities": source.visible_entities.duplicate(true),
	}
	var captured := _capture.capture(visible_snapshot, participant_id, int(observation.observation_seq), viewport)
	if not bool(captured.get("ok", false)):
		return {}
	_latest_refs[participant_id] = str(captured.metadata.transport_ref)
	var output := observation.duplicate(true)
	output["profile"] = "hybrid-visible-v1"
	output["frame"] = captured.metadata.duplicate(true)
	return output


func frame_response(body: Variant) -> Dictionary:
	if _closed or not body is Dictionary or body.size() != 4 or not _scenes.has(str(body.get("participant_id", ""))) \
		or body.get("sensor_id") != Capture.SENSOR_ID or typeof(body.get("observation_seq")) != TYPE_INT \
		or typeof(body.get("transport_ref")) != TYPE_STRING:
		return {}
	var record := _capture.capture_record(str(body.transport_ref))
	if not bool(record.get("ok", false)) or int(record.record.observation_sequence) != int(body.observation_seq) \
		or record.record.participant_id != body.participant_id:
		return {}
	var stored := _capture.take_frame_bytes(str(body.transport_ref))
	if not bool(stored.get("ok", false)):
		return {}
	_latest_refs.erase(str(body.participant_id))
	return {"metadata": stored.record.frame.duplicate(true), "observation_seq": body.observation_seq,
		"participant_id": body.participant_id, "png_base64": Marshalls.raw_to_base64(stored.bytes)}


func close() -> void:
	if _closed:
		return
	_closed = true
	_capture.close()
	_scenes.clear()
	_viewports.clear()
	_latest_refs.clear()
	_broadcast_sources.clear()
	_broadcast_scene = null
