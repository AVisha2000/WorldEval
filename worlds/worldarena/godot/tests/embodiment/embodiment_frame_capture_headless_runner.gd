extends SceneTree

const Capture := preload(
	"res://scripts/embodiment/presentation/capture/participant_frame_capture.gd"
)
var _png_signature := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])

var _failures := PackedStringArray()


class FakeRenderer:
	extends RefCounted

	var width: int
	var height: int
	var mode: String
	var render_count := 0

	func _init(frame_width: int = 1280, frame_height: int = 720, behavior: String = "png") -> void:
		width = frame_width
		height = frame_height
		mode = behavior

	func render_participant_png(snapshot: Dictionary, participant_id: String, sequence: int) -> Variant:
		render_count += 1
		if mode == "empty":
			return PackedByteArray()
		if mode == "text":
			return "not a byte buffer"
		if mode == "not_png":
			return "not png".to_utf8_buffer()
		if mode == "mutate":
			snapshot["tick"] = 999
		var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
		var red := (sequence * 31 + participant_id.length()) % 256
		image.fill(Color8(red, 41, 83, 255))
		var png := image.save_png_to_buffer()
		if mode == "truncated":
			png.resize(24)
		return png


func _init() -> void:
	_test_capture_and_binding()
	_test_rejections_and_immutability()
	_test_store_bounds_and_close()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_FRAME_CAPTURE_FAILURE: " + failure)
		print("EMBODIMENT_FRAME_CAPTURE_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_FRAME_CAPTURE_OK")
	quit(0)


func _test_capture_and_binding() -> void:
	var snapshot := _snapshot()
	var renderer := FakeRenderer.new()
	var store := Capture.new(4, 32 * 1024 * 1024)
	var first: Dictionary = store.capture(snapshot, "participant_0", 0, renderer)
	_check(bool(first.ok), "valid frame rejected: %s" % str(first.get("code", "")))
	if not bool(first.get("ok", false)):
		return
	var png: PackedByteArray = first.bytes
	var metadata: Dictionary = first.metadata
	_check(_has_png_signature(png), "PNG signature drifted")
	_check(_read_u32_be(png, 16) == 1280, "PNG width drifted")
	_check(_read_u32_be(png, 20) == 720, "PNG height drifted")
	_check(metadata.sensor_id == "operator-follow-v1", "sensor id drifted")
	_check(metadata.mime_type == "image/png", "MIME type drifted")
	_check(metadata.width == 1280 and metadata.height == 720, "metadata dimensions drifted")
	_check(metadata.sha256 == _sha256(png), "frame SHA-256 drifted")
	_check(String(metadata.transport_ref).begins_with("frame:participant_0.0."), "transport ref invalid")
	var expected_snapshot := (
		'{"participant_id":"participant_0","tick":0,"visible":'
		+ '{"entities":[{"entity_id":"beacon","state":"visible"}],"text":"Beacon ahead"}}'
	)
	_check(
		first.capture_record.visible_snapshot_sha256 == _sha256(expected_snapshot.to_utf8_buffer()),
		"visible snapshot binding drifted"
	)

	var idempotent: Dictionary = store.capture(snapshot, "participant_0", 0, renderer)
	_check(bool(idempotent.ok), "idempotent capture rejected")
	_check(idempotent.metadata.transport_ref == metadata.transport_ref, "same boundary changed identity")
	_check(idempotent.bytes == png, "same boundary changed bytes")
	_check(renderer.render_count == 1, "same boundary rendered more than once")

	var next: Dictionary = store.capture(snapshot, "participant_0", 1, renderer)
	_check(bool(next.ok), "different-boundary capture rejected")
	if bool(next.get("ok", false)):
		_check(next.metadata.transport_ref != metadata.transport_ref, "different boundary reused identity")

	var fetched: Dictionary = store.frame_bytes(metadata.transport_ref)
	_check(bool(fetched.ok) and fetched.bytes == png, "stored bytes were not retrievable")
	if bool(fetched.get("ok", false)):
		fetched.bytes[0] = 0
		var fetched_again: Dictionary = store.frame_bytes(metadata.transport_ref)
		_check(fetched_again.bytes[0] == _png_signature[0], "caller mutated stored frame bytes")
	var record: Dictionary = store.capture_record(metadata.transport_ref)
	_check(bool(record.ok), "capture record was not retrievable")
	if bool(record.get("ok", false)):
		_check(record.record.frame == metadata, "stored metadata drifted")

	var changed_snapshot := snapshot.duplicate(true)
	changed_snapshot.tick = 1
	var conflict: Dictionary = store.capture(changed_snapshot, "participant_0", 0, renderer)
	_check(
		not bool(conflict.ok) and conflict.code == "boundary_snapshot_mismatch",
		"changed snapshot accepted at existing boundary"
	)


func _test_rejections_and_immutability() -> void:
	var snapshot := _snapshot()
	var snapshot_before := snapshot.duplicate(true)
	var mutation_store := Capture.new()
	var mutation: Dictionary = mutation_store.capture(snapshot, "participant_0", 0, FakeRenderer.new(1280, 720, "mutate"))
	_check(
		not bool(mutation.ok) and mutation.code == "presentation_snapshot_mutated",
		"renderer mutation was accepted"
	)
	_check(snapshot == snapshot_before, "renderer mutation escaped into caller snapshot")
	_check(mutation_store.frame_count() == 0, "mutated capture entered store")

	var empty: Dictionary = Capture.new().capture(snapshot, "participant_0", 0, FakeRenderer.new(1280, 720, "empty"))
	_check(not bool(empty.ok) and empty.code == "renderer_empty_frame", "empty frame accepted")
	var not_png: Dictionary = Capture.new().capture(snapshot, "participant_0", 0, FakeRenderer.new(1280, 720, "not_png"))
	_check(not bool(not_png.ok) and not_png.code == "frame_not_png", "non-PNG frame accepted")
	var wrong_size: Dictionary = Capture.new().capture(snapshot, "participant_0", 0, FakeRenderer.new(16, 16))
	_check(
		not bool(wrong_size.ok) and wrong_size.code == "frame_dimensions_invalid",
		"wrong-size PNG accepted"
	)
	var truncated: Dictionary = Capture.new().capture(snapshot, "participant_0", 0, FakeRenderer.new(1280, 720, "truncated"))
	_check(
		not bool(truncated.ok) and truncated.code == "frame_png_decode_failed",
		"truncated PNG accepted"
	)
	var wrong_type: Dictionary = Capture.new().capture(snapshot, "participant_0", 0, FakeRenderer.new(1280, 720, "text"))
	_check(not bool(wrong_type.ok) and wrong_type.code == "renderer_result_invalid", "non-byte result accepted")
	var invalid_snapshot := snapshot.duplicate(true)
	invalid_snapshot["float"] = 1.5
	var invalid: Dictionary = Capture.new().capture(invalid_snapshot, "participant_0", 0, FakeRenderer.new())
	_check(
		not bool(invalid.ok) and invalid.code == "presentation_snapshot_invalid",
		"noncanonical snapshot accepted"
	)


func _test_store_bounds_and_close() -> void:
	var snapshot := _snapshot()
	var renderer := FakeRenderer.new()
	var bounded := Capture.new(1, 32 * 1024 * 1024)
	var first: Dictionary = bounded.capture(snapshot, "participant_0", 0, renderer)
	_check(bool(first.ok), "bounded store rejected first frame")
	var overflow: Dictionary = bounded.capture(snapshot, "participant_0", 1, renderer)
	_check(
		not bool(overflow.ok) and overflow.code == "frame_store_count_exceeded",
		"frame-count bound was not enforced"
	)
	if bool(first.get("ok", false)):
		var too_small := Capture.new(2, first.bytes.size() - 1)
		var byte_overflow: Dictionary = too_small.capture(snapshot, "participant_0", 0, FakeRenderer.new())
		_check(
			not bool(byte_overflow.ok) and byte_overflow.code == "frame_store_bytes_exceeded",
			"byte bound was not enforced"
		)
		var frame_ref: String = first.metadata.transport_ref
		bounded.close()
		bounded.close()
		_check(bounded.frame_count() == 0 and bounded.stored_byte_count() == 0, "close did not clear store")
		var after_close: Dictionary = bounded.frame_bytes(frame_ref)
		_check(
			not bool(after_close.ok) and after_close.code == "frame_store_closed",
			"closed store exposed frame bytes"
		)
		var capture_after_close: Dictionary = bounded.capture(snapshot, "participant_0", 2, renderer)
		_check(
			not bool(capture_after_close.ok) and capture_after_close.code == "frame_store_closed",
			"closed store accepted capture"
		)


func _snapshot() -> Dictionary:
	return {
		"participant_id": "participant_0",
		"tick": 0,
		"visible": {
			"entities": [{"entity_id": "beacon", "state": "visible"}],
			"text": "Beacon ahead",
		},
	}


func _has_png_signature(bytes: PackedByteArray) -> bool:
	if bytes.size() < _png_signature.size():
		return false
	for index: int in _png_signature.size():
		if bytes[index] != _png_signature[index]:
			return false
	return true


func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(bytes[offset] << 24)
		| (bytes[offset + 1] << 16)
		| (bytes[offset + 2] << 8)
		| bytes[offset + 3]
	)


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
