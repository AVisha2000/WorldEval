class_name EmbodimentHybridPresentationAdapter
extends RefCounted

const SnapshotFilter := preload(
	"res://scripts/embodiment/presentation/privacy/presentation_snapshot_filter.gd"
)
const FrameCapture := preload(
	"res://scripts/embodiment/presentation/capture/participant_frame_capture.gd"
)

var _authority: Object
var _scene: Node
var _viewport: SubViewport
var _renderer_provider: Variant
var _capture: EmbodimentParticipantFrameCapture
var _closed := false


func _init(
	authority: Object,
	presentation_scene: Node,
	viewport: SubViewport,
	renderer_provider: Variant = null,
	max_frames: int = FrameCapture.DEFAULT_MAX_FRAMES,
	max_bytes: int = FrameCapture.DEFAULT_MAX_BYTES,
) -> void:
	_authority = authority
	_scene = presentation_scene
	_viewport = viewport
	_renderer_provider = viewport if renderer_provider == null else renderer_provider
	_capture = FrameCapture.new(max_frames, max_bytes)


func capture_boundary(participant_id: String) -> Dictionary:
	if _closed:
		return _failure("hybrid_adapter_closed")
	if _authority == null or _scene == null or _viewport == null:
		return _failure("hybrid_adapter_unavailable")
	var authority_hash_before: String = _authority.checkpoint_hash()
	var source: Dictionary = (
		_authority.presentation_source_snapshot_for(participant_id)
		if _authority.has_method("presentation_source_snapshot_for")
		else _authority.presentation_source_snapshot()
	)
	var visible_ids: Array[String] = (
		_authority.presentation_visible_entity_ids_for(participant_id)
		if _authority.has_method("presentation_visible_entity_ids_for")
		else _authority.presentation_visible_entity_ids()
	)
	var filtered: Dictionary = SnapshotFilter.filter_for_participant(
		source, participant_id, visible_ids
	)
	if not bool(filtered.get("ok", false)):
		return _failure("hybrid_snapshot_rejected")
	var render_snapshot: Dictionary = filtered.snapshot
	var text_result: Dictionary = SnapshotFilter.project_visible_text(render_snapshot)
	if not bool(text_result.get("ok", false)):
		return _failure("hybrid_text_projection_rejected")
	var binding: Dictionary = SnapshotFilter.bind_digests(
		render_snapshot, text_result.projection
	)
	if not bool(binding.get("ok", false)):
		return _failure("hybrid_digest_binding_rejected")
	if not _scene.apply_snapshot(scene_snapshot(render_snapshot)):
		return _failure("hybrid_scene_rejected")
	# The managed authority keeps this SubViewport alive throughout an active episode.  A capture
	# is merely a serialization boundary, not the lifetime of the presentation: UPDATE_ONCE would
	# stop the viewport after this PNG and leave subsequent cached executor ticks visually frozen.
	# Keep rendering continuously so scene updates below remain visible locally, while only fresh
	# boundaries pay the PNG capture / transport / evidence cost.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	var captured: Dictionary = _capture.capture(
		render_snapshot, participant_id, int(render_snapshot.observation_seq), _renderer_provider
	)
	if not bool(captured.get("ok", false)):
		return captured
	if captured.capture_record.visible_snapshot_sha256 \
		!= binding.binding.render_snapshot_sha256:
		return _failure("hybrid_snapshot_digest_mismatch")
	var observation: Dictionary = (
		_authority.observe(participant_id).duplicate(true)
		if _authority.has_method("presentation_source_snapshot_for")
		else _authority.observe().duplicate(true)
	)
	if not _text_matches_authority(text_result.projection, observation):
		return _failure("hybrid_text_authority_mismatch")
	observation["profile"] = "hybrid-visible-v1"
	observation["frame"] = captured.metadata.duplicate(true)
	if _authority.checkpoint_hash() != authority_hash_before:
		return _failure("presentation_mutated_authority")
	return {
		"ok": true,
		"observation": observation,
		"frame_bytes": captured.bytes.duplicate(),
		"capture_record": captured.capture_record.duplicate(true),
		"binding": {
			"digests": binding.binding.duplicate(true),
			"frame_sha256": captured.metadata.sha256,
			"transport_ref": captured.metadata.transport_ref,
		},
	}


func frame_bytes(transport_ref: String) -> Dictionary:
	return _capture.frame_bytes(transport_ref) if not _closed else _failure("hybrid_adapter_closed")


func frame_record(transport_ref: String) -> Dictionary:
	return _capture.capture_record(transport_ref) if not _closed else _failure("hybrid_adapter_closed")


func take_frame_bytes(transport_ref: String) -> Dictionary:
	return _capture.take_frame_bytes(transport_ref) if not _closed else _failure("hybrid_adapter_closed")


func discard_frame(transport_ref: String) -> Dictionary:
	return _capture.discard_frame(transport_ref) if not _closed else _failure("hybrid_adapter_closed")


func observe_with_cached_frame(participant_id: String, frame_metadata: Dictionary) -> Dictionary:
	## Cached pixels are only used between autonomous executor ticks.  The semantic projection is
	## still rebuilt from the current participant-filtered authority snapshot; a fresh capture is
	## forced before an external planner boundary, task completion, terminal state, or stale limit.
	if _closed:
		return _failure("hybrid_adapter_closed")
	if _authority == null or _scene == null or _viewport == null:
		return _failure("hybrid_adapter_unavailable")
	if not _valid_frame_metadata(frame_metadata):
		return _failure("hybrid_cached_frame_invalid")
	var authority_hash_before: String = _authority.checkpoint_hash()
	var source: Dictionary = (
		_authority.presentation_source_snapshot_for(participant_id)
		if _authority.has_method("presentation_source_snapshot_for")
		else _authority.presentation_source_snapshot()
	)
	var visible_ids: Array[String] = (
		_authority.presentation_visible_entity_ids_for(participant_id)
		if _authority.has_method("presentation_visible_entity_ids_for")
		else _authority.presentation_visible_entity_ids()
	)
	var filtered: Dictionary = SnapshotFilter.filter_for_participant(
		source, participant_id, visible_ids
	)
	if not bool(filtered.get("ok", false)):
		return _failure("hybrid_snapshot_rejected")
	var render_snapshot: Dictionary = filtered.snapshot
	# Keep the live presentation scene synchronized to the latest safe projection even when this
	# executor tick reuses its canonical frame bytes.  No viewport capture happens here, and the
	# scene receives only participant-filtered entities/semantics.
	if not _scene.apply_snapshot(scene_snapshot(render_snapshot)):
		return _failure("hybrid_scene_rejected")
	# A caller must never be able to leave a managed participant viewport in one-shot mode.  This
	# does not read pixels or create frame evidence; it only lets Godot render the current, already
	# participant-filtered scene between canonical frame captures.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var text_result: Dictionary = SnapshotFilter.project_visible_text(render_snapshot)
	if not bool(text_result.get("ok", false)):
		return _failure("hybrid_text_projection_rejected")
	var observation: Dictionary = (
		_authority.observe(participant_id).duplicate(true)
		if _authority.has_method("presentation_source_snapshot_for")
		else _authority.observe().duplicate(true)
	)
	if not _text_matches_authority(text_result.projection, observation):
		return _failure("hybrid_text_authority_mismatch")
	observation["profile"] = "hybrid-visible-v1"
	observation["frame"] = frame_metadata.duplicate(true)
	if _authority.checkpoint_hash() != authority_hash_before:
		return _failure("presentation_mutated_authority")
	return {"ok": true, "observation": observation}


func close() -> void:
	if _closed:
		return
	_closed = true
	_capture.close()
	_authority = null
	_scene = null
	_viewport = null
	_renderer_provider = null


static func scene_snapshot(render_snapshot: Dictionary) -> Dictionary:
	var self_entity: Dictionary = render_snapshot.self
	var entities: Array[Dictionary] = []
	for entity: Dictionary in render_snapshot.visible_entities:
		var projected := {
			"id": str(entity.id),
			"kind": str(entity.kind),
			"position_mt": entity.position_mt.duplicate(),
			"heading_milli": int(entity.heading_sector) * 1000,
			"state": str(entity.semantic.state),
		}
		entities.append(projected)
		if entity.kind == "build_pad" and _construction_is_visible(str(entity.semantic.state)):
			entities.append({
				"id": "%s_barricade" % entity.id,
				"kind": "barricade",
				"position_mt": entity.position_mt.duplicate(),
				"heading_milli": int(entity.heading_sector) * 1000,
				"state": str(entity.semantic.state),
			})
	return {
		"episode_id": render_snapshot.episode_id,
		"observation_seq": render_snapshot.observation_seq,
		"participant_id": render_snapshot.participant_id,
		"task_id": render_snapshot.task_id,
		"tick": render_snapshot.tick,
		"operator": {
			"position_mt": self_entity.position_mt.duplicate(),
			"heading_milli": int(self_entity.heading_sector) * 1000,
			"state": self_entity.animation,
		},
		"entities": entities,
		"agency": render_snapshot.agency.duplicate(true),
	}


static func interpolated_scene_snapshot(
	before_render: Variant, after_render: Variant, progress_milli: Variant
) -> Dictionary:
	## Movie Maker-only visual tweening. Both inputs must already be participant-filtered render
	## snapshots. Only entities visible at both boundaries are eligible between boundaries; entities
	## newly visible at the after-boundary appear only when progress reaches 1000.
	if typeof(progress_milli) != TYPE_INT or progress_milli < 0 or progress_milli > 1000:
		return {"ok": false, "code": "presentation_interpolation_progress_invalid"}
	if SnapshotFilter.safe_snapshot_digest(before_render) == "" \
		or SnapshotFilter.safe_snapshot_digest(after_render) == "":
		return {"ok": false, "code": "presentation_interpolation_snapshot_invalid"}
	for field: String in ["protocol_version", "episode_id", "participant_id", "task_id"]:
		if before_render[field] != after_render[field]:
			return {"ok": false, "code": "presentation_interpolation_scope_mismatch"}
	if after_render.observation_seq < before_render.observation_seq \
		or after_render.tick < before_render.tick:
		return {"ok": false, "code": "presentation_interpolation_order_invalid"}

	var before_scene := scene_snapshot(before_render)
	var after_scene := scene_snapshot(after_render)
	var output: Dictionary = after_scene.duplicate(true)
	output.operator.position_mt = _interpolate_position(
		before_scene.operator.position_mt, after_scene.operator.position_mt, progress_milli
	)
	output.operator.heading_milli = _interpolate_heading_milli(
		int(before_scene.operator.heading_milli), int(after_scene.operator.heading_milli),
		progress_milli,
	)
	var before_entities := {}
	for entity: Dictionary in before_scene.entities:
		before_entities[str(entity.id)] = entity
	var interpolated_entities: Array[Dictionary] = []
	for after_entity: Dictionary in after_scene.entities:
		var entity_id := str(after_entity.id)
		var before_entity: Variant = before_entities.get(entity_id)
		if progress_milli < 1000 and (
			before_entity == null or str(before_entity.kind) != str(after_entity.kind)
		):
			continue
		var projected: Dictionary = after_entity.duplicate(true)
		if before_entity is Dictionary:
			projected.position_mt = _interpolate_position(
				before_entity.position_mt, after_entity.position_mt, progress_milli
			)
			projected.heading_milli = _interpolate_heading_milli(
				int(before_entity.heading_milli), int(after_entity.heading_milli), progress_milli
			)
		interpolated_entities.append(projected)
	output.entities = interpolated_entities
	return {"ok": true, "snapshot": output}


static func _interpolate_position(before: Array, after: Array, progress_milli: int) -> Array:
	return [
		int(before[0]) + _divide_toward_zero((int(after[0]) - int(before[0])) * progress_milli, 1000),
		int(before[1]) + _divide_toward_zero((int(after[1]) - int(before[1])) * progress_milli, 1000),
	]


static func _interpolate_heading_milli(before: int, after: int, progress_milli: int) -> int:
	var delta := after - before
	while delta > 4000:
		delta -= 8000
	while delta < -4000:
		delta += 8000
	return posmod(before + _divide_toward_zero(delta * progress_milli, 1000), 8000)


static func _divide_toward_zero(numerator: int, denominator: int) -> int:
	if numerator >= 0:
		return int(numerator / denominator)
	return -int(-numerator / denominator)


static func _construction_is_visible(state: String) -> bool:
	return state == "complete" or state in [
		"building_started", "building_mid", "building_near_complete",
	]


func _text_matches_authority(projection: Dictionary, observation: Dictionary) -> bool:
	for field: String in ["protocol_version", "episode_id", "observation_seq", "tick", "goal", "remaining_ticks", "terminal"]:
		if projection.get(field) != observation.get(field):
			return false
	for field: String in ["health_percent", "energy_percent", "facing", "status"]:
		if projection.self.get(field) != observation.self.get(field):
			return false
	return projection.visible_entities == observation.visible_entities


func _valid_frame_metadata(value: Dictionary) -> bool:
	if value.size() != 6:
		return false
	if value.get("sensor_id") != "operator-follow-v1" \
		or value.get("mime_type") != "image/png" \
		or value.get("width") != 1280 or value.get("height") != 720:
		return false
	var digest: Variant = value.get("sha256")
	var transport_ref: Variant = value.get("transport_ref")
	if typeof(digest) != TYPE_STRING or digest.length() != 64 \
		or typeof(transport_ref) != TYPE_STRING or not transport_ref.begins_with("frame:"):
		return false
	for code: int in digest.to_utf8_buffer():
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
