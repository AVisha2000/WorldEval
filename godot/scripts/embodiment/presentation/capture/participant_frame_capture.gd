class_name EmbodimentParticipantFrameCapture
extends RefCounted

const SENSOR_ID := "operator-follow-v1"
const MIME_TYPE := "image/png"
const FRAME_WIDTH := 1280
const FRAME_HEIGHT := 720
const DEFAULT_MAX_FRAMES := 256
const DEFAULT_MAX_BYTES := 512 * 1024 * 1024
static var PNG_SIGNATURE := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])

var _max_frames: int
var _max_bytes: int
var _stored_bytes := 0
var _closed := false
var _frames: Dictionary = {}
var _records: Dictionary = {}
var _boundary_refs: Dictionary = {}


func _init(max_frames: int = DEFAULT_MAX_FRAMES, max_bytes: int = DEFAULT_MAX_BYTES) -> void:
	_max_frames = max_frames
	_max_bytes = max_bytes


func capture(
		presentation_snapshot: Dictionary,
		participant_id: String,
		observation_sequence: int,
		renderer_provider: Variant
) -> Dictionary:
	if _closed:
		return _failure("frame_store_closed")
	if _max_frames < 1 or _max_bytes < 1:
		return _failure("frame_store_bounds_invalid")
	if not _valid_participant_id(participant_id):
		return _failure("participant_id_invalid")
	if observation_sequence < 0:
		return _failure("observation_sequence_invalid")

	var before := _canonical_snapshot(presentation_snapshot)
	if not bool(before.ok):
		return before
	var snapshot_sha256: String = _sha256(before.bytes)
	var boundary_key := "%s:%d" % [participant_id, observation_sequence]
	if _boundary_refs.has(boundary_key):
		var existing_ref: String = _boundary_refs[boundary_key]
		var existing_record: Dictionary = _records[existing_ref]
		if existing_record.visible_snapshot_sha256 != snapshot_sha256:
			return _failure("boundary_snapshot_mismatch")
		return _success(existing_ref)

	# Presentation receives a disposable deep projection. Mutating it is still a contract
	# violation, but can never mutate the caller-owned authority projection.
	var renderer_snapshot := presentation_snapshot.duplicate(true)
	var rendered: Dictionary = _render_png(renderer_provider, renderer_snapshot, participant_id, observation_sequence)
	var renderer_after := _canonical_snapshot(renderer_snapshot)
	if not bool(renderer_after.ok) or renderer_after.bytes != before.bytes:
		return _failure("presentation_snapshot_mutated")
	var caller_after := _canonical_snapshot(presentation_snapshot)
	if not bool(caller_after.ok) or caller_after.bytes != before.bytes:
		return _failure("presentation_snapshot_mutated")
	if not bool(rendered.ok):
		return rendered

	var png: PackedByteArray = rendered.bytes
	var png_error := _validate_png(png)
	if not png_error.is_empty():
		return _failure(png_error)
	if _frames.size() >= _max_frames:
		return _failure("frame_store_count_exceeded")
	if png.size() > _max_bytes - _stored_bytes:
		return _failure("frame_store_bytes_exceeded")

	var frame_sha256 := _sha256(png)
	# The player-visible reference binds the frame bytes, participant, and boundary without
	# exposing the authority checkpoint or the exact-coordinate snapshot digest.
	var transport_ref := "frame:%s.%d.%s" % [participant_id, observation_sequence, frame_sha256]
	var metadata := {
		"sensor_id": SENSOR_ID,
		"mime_type": MIME_TYPE,
		"width": FRAME_WIDTH,
		"height": FRAME_HEIGHT,
		"sha256": frame_sha256,
		"transport_ref": transport_ref,
	}
	var record := {
		"participant_id": participant_id,
		"observation_sequence": observation_sequence,
		"visible_snapshot_sha256": snapshot_sha256,
		"frame": metadata.duplicate(true),
	}
	_frames[transport_ref] = png.duplicate()
	_records[transport_ref] = record
	_boundary_refs[boundary_key] = transport_ref
	_stored_bytes += png.size()
	return _success(transport_ref)


func frame_bytes(transport_ref: String) -> Dictionary:
	if _closed:
		return _failure("frame_store_closed")
	if not _frames.has(transport_ref):
		return _failure("frame_not_found")
	return {"ok": true, "bytes": (_frames[transport_ref] as PackedByteArray).duplicate()}


func take_frame_bytes(transport_ref: String) -> Dictionary:
	if _closed:
		return _failure("frame_store_closed")
	if not _frames.has(transport_ref) or not _records.has(transport_ref):
		return _failure("frame_not_found")
	var bytes: PackedByteArray = (_frames[transport_ref] as PackedByteArray).duplicate()
	var record: Dictionary = (_records[transport_ref] as Dictionary).duplicate(true)
	var boundary_key := "%s:%d" % [record.participant_id, record.observation_sequence]
	_stored_bytes -= (_frames[transport_ref] as PackedByteArray).size()
	var scrubbed: PackedByteArray = _frames[transport_ref]
	scrubbed.fill(0)
	_frames.erase(transport_ref)
	_records.erase(transport_ref)
	_boundary_refs.erase(boundary_key)
	return {"ok": true, "bytes": bytes, "record": record}


func capture_record(transport_ref: String) -> Dictionary:
	if _closed:
		return _failure("frame_store_closed")
	if not _records.has(transport_ref):
		return _failure("frame_not_found")
	return {"ok": true, "record": (_records[transport_ref] as Dictionary).duplicate(true)}


func frame_count() -> int:
	return _frames.size()


func stored_byte_count() -> int:
	return _stored_bytes


func close() -> void:
	if _closed:
		return
	for transport_ref: String in _frames:
		var scrubbed: PackedByteArray = _frames[transport_ref]
		scrubbed.fill(0)
		_frames[transport_ref] = scrubbed
	_frames.clear()
	_records.clear()
	_boundary_refs.clear()
	_stored_bytes = 0
	_closed = true


func _success(transport_ref: String) -> Dictionary:
	var record: Dictionary = _records[transport_ref]
	return {
		"ok": true,
		"bytes": (_frames[transport_ref] as PackedByteArray).duplicate(),
		"metadata": (record.frame as Dictionary).duplicate(true),
		"capture_record": record.duplicate(true),
	}


func _render_png(
		renderer_provider: Variant,
		presentation_snapshot: Dictionary,
		participant_id: String,
		observation_sequence: int
) -> Dictionary:
	var value: Variant
	if renderer_provider is SubViewport:
		var viewport := renderer_provider as SubViewport
		var texture := viewport.get_texture()
		if texture == null:
			return _failure("renderer_unavailable")
		var image := texture.get_image()
		if image == null or image.is_empty():
			return _failure("renderer_empty_frame")
		value = image.save_png_to_buffer()
	elif renderer_provider is Object and renderer_provider.has_method("render_participant_png"):
		value = renderer_provider.call(
			"render_participant_png", presentation_snapshot, participant_id, observation_sequence
		)
	else:
		return _failure("renderer_unavailable")
	if not value is PackedByteArray:
		return _failure("renderer_result_invalid")
	return {"ok": true, "bytes": value}


func _validate_png(png: PackedByteArray) -> String:
	if png.is_empty():
		return "renderer_empty_frame"
	if png.size() < 24:
		return "frame_not_png"
	for index: int in PNG_SIGNATURE.size():
		if png[index] != PNG_SIGNATURE[index]:
			return "frame_not_png"
	if _read_u32_be(png, 8) != 13:
		return "frame_png_header_invalid"
	if png.slice(12, 16).get_string_from_ascii() != "IHDR":
		return "frame_png_header_invalid"
	if _read_u32_be(png, 16) != FRAME_WIDTH or _read_u32_be(png, 20) != FRAME_HEIGHT:
		return "frame_dimensions_invalid"
	if not _png_structure_complete(png):
		return "frame_png_decode_failed"
	var decoded := Image.new()
	if decoded.load_png_from_buffer(png) != OK:
		return "frame_png_decode_failed"
	if decoded.get_width() != FRAME_WIDTH or decoded.get_height() != FRAME_HEIGHT:
		return "frame_dimensions_invalid"
	return ""


func _png_structure_complete(png: PackedByteArray) -> bool:
	var offset := 8
	var saw_header := false
	var saw_data := false
	while offset <= png.size() - 12:
		var data_size := _read_u32_be(png, offset)
		if data_size < 0 or data_size > png.size() - offset - 12:
			return false
		var chunk_type := png.slice(offset + 4, offset + 8).get_string_from_ascii()
		if not saw_header:
			if chunk_type != "IHDR" or data_size != 13:
				return false
			saw_header = true
		elif chunk_type == "IDAT":
			saw_data = true
		var next_offset := offset + data_size + 12
		if chunk_type == "IEND":
			return data_size == 0 and saw_header and saw_data and next_offset == png.size()
		offset = next_offset
	return false


func _canonical_snapshot(snapshot: Dictionary) -> Dictionary:
	var encoded := _canonical_json(snapshot)
	if not bool(encoded.ok):
		return _failure("presentation_snapshot_invalid")
	return {"ok": true, "bytes": (encoded.text as String).to_utf8_buffer()}


func _canonical_json(value: Variant) -> Dictionary:
	match typeof(value):
		TYPE_NIL:
			return {"ok": true, "text": "null"}
		TYPE_BOOL:
			return {"ok": true, "text": "true" if value else "false"}
		TYPE_INT:
			return {"ok": true, "text": str(value)}
		TYPE_STRING:
			return {"ok": true, "text": JSON.stringify(value)}
		TYPE_ARRAY:
			var array_items := PackedStringArray()
			for item: Variant in value:
				var encoded := _canonical_json(item)
				if not bool(encoded.ok):
					return encoded
				array_items.append(encoded.text)
			return {"ok": true, "text": "[" + ",".join(array_items) + "]"}
		TYPE_DICTIONARY:
			var keys := PackedStringArray()
			for key: Variant in value:
				if typeof(key) != TYPE_STRING:
					return {"ok": false}
				keys.append(key)
			keys.sort()
			var object_items := PackedStringArray()
			for key: String in keys:
				var encoded := _canonical_json(value[key])
				if not bool(encoded.ok):
					return encoded
				object_items.append(JSON.stringify(key) + ":" + encoded.text)
			return {"ok": true, "text": "{" + ",".join(object_items) + "}"}
	return {"ok": false}


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(bytes[offset] << 24)
		| (bytes[offset + 1] << 16)
		| (bytes[offset + 2] << 8)
		| bytes[offset + 3]
	)


func _valid_participant_id(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		if not (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or code == 45
			or code == 46
			or code == 95
		):
			return false
	return true


func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
