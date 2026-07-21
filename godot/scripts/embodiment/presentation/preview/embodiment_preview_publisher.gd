class_name EmbodimentPreviewPublisher
extends Node

## Best-effort, presentation-only local preview publisher.
##
## This is intentionally separate from the authenticated authority transport.  It captures only
## the SubViewport whose scene has already received the participant-filtered projection, signs
## the raw PNG with a least-privilege key derived from the launch secret, and drops frames while
## an HTTP request is in flight.  It never reads authority state, changes a decision window, or
## blocks replay/checkpoint processing.

const KEY_DOMAIN := "llm-controller/preview-key/v1\u0000"
const FRAME_DOMAIN := "llm-controller/preview-frame/v1\u0000"
const FRAME_INTERVAL_SECONDS := 0.1
const MAX_FRAME_BYTES := 8 * 1024 * 1024
const FRAME_WIDTH := 1280
const FRAME_HEIGHT := 720

var _request: HTTPRequest = null
var _viewport: SubViewport = null
var _presentation_scene: Node = null
var _endpoint := ""
var _ticket := ""
var _episode_id := ""
var _preview_key := PackedByteArray()
var _sequence := 0
var _elapsed := 0.0
var _in_flight := false
var _closed := false


func configure(
		gateway_url: String,
		attachment_ticket: String,
		episode_id: String,
		session_secret: PackedByteArray,
		viewport: SubViewport,
		presentation_scene: Node
) -> PackedStringArray:
	var errors := PackedStringArray()
	if _request != null or _closed:
		errors.append("preview_publisher_already_configured")
	if viewport == null or presentation_scene == null \
		or not presentation_scene.has_method("snapshot_copy"):
		errors.append("preview_publisher_scene_invalid")
	if session_secret.size() != 32:
		errors.append("preview_publisher_secret_invalid")
	var endpoint := _endpoint_for(gateway_url, attachment_ticket)
	if endpoint.is_empty() or not _valid_episode_id(episode_id):
		errors.append("preview_publisher_url_invalid")
	if not errors.is_empty():
		return errors
	var key := _hmac_bytes(session_secret, KEY_DOMAIN.to_utf8_buffer())
	if key.size() != 32:
		errors.append("preview_publisher_key_invalid")
		return errors
	_endpoint = endpoint
	_ticket = attachment_ticket
	_episode_id = episode_id
	_preview_key = key
	_viewport = viewport
	_presentation_scene = presentation_scene
	_request = HTTPRequest.new()
	_request.name = "ParticipantPreviewRequest"
	_request.use_threads = true
	_request.timeout = 2.0
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)
	set_process(true)
	return errors


func close() -> void:
	if _closed:
		return
	_closed = true
	set_process(false)
	if _request != null:
		_request.cancel_request()
	_preview_key.fill(0)
	_preview_key.clear()
	_endpoint = ""
	_ticket = ""
	_episode_id = ""
	_viewport = null
	_presentation_scene = null


func _process(delta: float) -> void:
	if _closed or _request == null or _viewport == null or _presentation_scene == null:
		return
	_elapsed += delta
	if _elapsed < FRAME_INTERVAL_SECONDS or _in_flight:
		return
	_elapsed = 0.0
	var snapshot: Variant = _presentation_scene.call("snapshot_copy")
	if not _eligible_snapshot(snapshot):
		return
	var texture := _viewport.get_texture()
	if texture == null:
		return
	var image := texture.get_image()
	if image == null or image.is_empty() \
		or image.get_width() != FRAME_WIDTH or image.get_height() != FRAME_HEIGHT:
		return
	var png := image.save_png_to_buffer()
	if not _valid_png(png):
		return
	var sequence := _sequence
	var signature := _frame_signature(sequence, png)
	if signature.is_empty():
		return
	var headers := PackedStringArray([
		"Content-Type: image/png",
		"X-WorldArena-Preview-Sequence: %d" % sequence,
		"X-WorldArena-Preview-Auth: %s" % signature,
	])
	# Camera bytes must use Godot's binary request API.  `request()` only accepts a String body
	# and would reject the PNG before it ever reaches the isolated preview ingress.
	if _request.request_raw(_endpoint, headers, HTTPClient.METHOD_POST, png) != OK:
		return
	_sequence += 1
	_in_flight = true


func _on_request_completed(
		_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray
) -> void:
	# Any network, authentication, or queue failure is intentionally a dropped preview frame.
	# Authority and replay do not observe this channel.
	_in_flight = false


func _eligible_snapshot(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var snapshot: Dictionary = value
	return snapshot.get("participant_id") == "participant_0" \
		and snapshot.get("task_id") in [
			"orientation-v0", "interaction-v0", "construction-v0", "neutral-encounter-v0",
		] \
		and typeof(snapshot.get("observation_seq")) == TYPE_INT \
		and int(snapshot.observation_seq) >= 0


func _frame_signature(sequence: int, png: PackedByteArray) -> String:
	if _preview_key.size() != 32 or sequence < 0:
		return ""
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK or digest.update(png) != OK:
		return ""
	var material := FRAME_DOMAIN.to_utf8_buffer()
	material.append_array(_ticket.to_utf8_buffer())
	material.append(0)
	material.append_array(_episode_id.to_utf8_buffer())
	material.append(0)
	material.append_array(str(sequence).to_utf8_buffer())
	material.append(0)
	material.append_array(digest.finish())
	var output := _hmac_bytes(_preview_key, material).hex_encode()
	material.fill(0)
	return output


static func _endpoint_for(gateway_url: String, ticket: String) -> String:
	var prefix := "ws://"
	var suffix := "/ws/embodiment/%s" % ticket
	if not gateway_url.begins_with(prefix) or not gateway_url.ends_with(suffix):
		return ""
	var origin_length := gateway_url.length() - suffix.length()
	var origin := gateway_url.substr(prefix.length(), origin_length - prefix.length())
	if origin.is_empty():
		return ""
	return "http://%s/internal/embodiment/preview/%s" % [origin, ticket]


static func _hmac_bytes(key: PackedByteArray, material: PackedByteArray) -> PackedByteArray:
	var context := HMACContext.new()
	if context.start(HashingContext.HASH_SHA256, key) != OK:
		return PackedByteArray()
	if context.update(material) != OK:
		return PackedByteArray()
	return context.finish()


static func _valid_png(value: PackedByteArray) -> bool:
	if value.size() < 24 or value.size() > MAX_FRAME_BYTES:
		return false
	var signature := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])
	for index: int in signature.size():
		if value[index] != signature[index]:
			return false
	return value.slice(12, 16).get_string_from_ascii() == "IHDR" \
		and _read_u32_be(value, 16) == FRAME_WIDTH and _read_u32_be(value, 20) == FRAME_HEIGHT


static func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(bytes[offset] << 24) | (bytes[offset + 1] << 16)
		| (bytes[offset + 2] << 8) | bytes[offset + 3]
	)


static func _valid_episode_id(value: String) -> bool:
	if not value.begins_with("ep_") or value.length() < 4 or value.length() > 123:
		return false
	for index: int in range(3, value.length()):
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 46, 95]):
			return false
	return true
