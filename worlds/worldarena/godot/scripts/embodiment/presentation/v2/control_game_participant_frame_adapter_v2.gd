class_name EmbodimentControlGameParticipantFrameAdapterV2
extends RefCounted

const Capture := preload("res://scripts/embodiment/presentation/capture/participant_frame_capture.gd")

var _scenes: Dictionary = {}
var _viewports: Dictionary = {}
var _capture
var _closed := false
var _latest_refs: Dictionary = {}


func _init(scene_or_scenes: Variant, viewport_or_viewports: Variant) -> void:
	if scene_or_scenes is Dictionary and viewport_or_viewports is Dictionary:
		_scenes = scene_or_scenes.duplicate()
		_viewports = viewport_or_viewports.duplicate()
	else:
		_scenes = {"participant_0": scene_or_scenes}
		_viewports = {"participant_0": viewport_or_viewports}
	_capture = Capture.new(8, 64 * 1024 * 1024)


func attach_participant_frame(
	participant_id: String, observation: Dictionary, source: Dictionary
) -> Dictionary:
	if _closed or not _scenes.has(participant_id) or not _viewports.has(participant_id):
		return {}
	var scene: Node = _scenes[participant_id]
	var viewport: SubViewport = _viewports[participant_id]
	if scene == null or viewport == null \
		or not scene.apply_participant_projection(source.duplicate(true), observation.duplicate(true)):
		return {}
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Managed hybrid launches use a real display-backed viewport. Force this participant-only
	# projection through the renderer before serializing its boundary PNG.
	RenderingServer.force_draw(false)
	if _latest_refs.has(participant_id):
		_capture.discard_frame(str(_latest_refs[participant_id]))
		_latest_refs.erase(participant_id)
	var visible_snapshot := {
		"episode_id": observation.episode_id,
		"observation_seq": observation.observation_seq,
		"participant_id": participant_id,
		"tick": observation.tick,
		"operator": source.operator.duplicate(true),
		"visible_entities": source.visible_entities.duplicate(true),
	}
	var captured: Dictionary = _capture.capture(
		visible_snapshot, participant_id, int(observation.observation_seq), viewport
	)
	if not bool(captured.get("ok", false)):
		return {}
	_latest_refs[participant_id] = str(captured.metadata.transport_ref)
	var output := observation.duplicate(true)
	output["profile"] = "hybrid-visible-v1"
	output["frame"] = captured.metadata.duplicate(true)
	return output


func frame_response(body: Variant) -> Dictionary:
	if _closed or not body is Dictionary or body.size() != 4 \
		or not _scenes.has(str(body.get("participant_id", ""))) \
		or body.get("sensor_id") != Capture.SENSOR_ID \
		or typeof(body.get("observation_seq")) != TYPE_INT \
		or typeof(body.get("transport_ref")) != TYPE_STRING:
		return {}
	var record_result: Dictionary = _capture.capture_record(str(body.transport_ref))
	if not bool(record_result.get("ok", false)) \
		or int(record_result.record.observation_sequence) != int(body.observation_seq) \
		or record_result.record.participant_id != body.participant_id:
		return {}
	var stored: Dictionary = _capture.take_frame_bytes(str(body.transport_ref))
	if not bool(stored.get("ok", false)):
		return {}
	_latest_refs.erase(str(body.participant_id))
	return {
		"metadata": stored.record.frame.duplicate(true),
		"observation_seq": body.observation_seq,
		"participant_id": body.participant_id,
		"png_base64": Marshalls.raw_to_base64(stored.bytes),
	}


func close() -> void:
	if _closed:
		return
	_closed = true
	_capture.close()
	_scenes.clear()
	_viewports.clear()
	_latest_refs.clear()
