class_name EmbodimentPreviewPublisher
extends Node

## Best-effort, presentation-only local preview publisher.
##
## This is intentionally separate from the authenticated authority transport.  It captures only
## the SubViewport whose scene has already received the participant-filtered projection, signs
## a metadata-free JPEG with a least-privilege key derived from the launch secret, and retains at
## most one newest pending frame behind a persistent WebSocket. It never reads authority
## state, changes a decision window, or blocks replay/checkpoint processing.

const PreviewInterpolator := preload(
	"res://scripts/embodiment/presentation/preview/participant_preview_interpolator.gd"
)
const KEY_DOMAIN := "llm-controller/preview-key/v2\u0000"
const FRAME_DOMAIN := "llm-controller/preview-frame/v2\u0000"
const FRAME_INTERVAL_SECONDS := 1.0 / 30.0
const JPEG_QUALITY := 0.82
const MAX_FRAME_BYTES := 4 * 1024 * 1024
const FRAME_WIDTH := 1280
const FRAME_HEIGHT := 720
const MAX_RECONNECT_ATTEMPTS := 5
const RECONNECT_BASE_SECONDS := 0.25
const RECONNECT_MAX_SECONDS := 4.0

var _socket: WebSocketPeer = null
var _viewport: SubViewport = null
var _presentation_scene: Node = null
var _endpoint := ""
var _ticket := ""
var _episode_id := ""
var _participant_id := "participant_0"
var _preview_key := PackedByteArray()
var _sequence := 0
var _elapsed := 0.0
var _closed := false
var _pending_jpeg := PackedByteArray()
var _pending_sequence := -1
var _interpolator = PreviewInterpolator.new()
var _reconnect_attempts := 0
var _reconnect_elapsed := 0.0


func configure(
		gateway_url: String,
		attachment_ticket: String,
		episode_id: String,
		session_secret: PackedByteArray,
		viewport: SubViewport,
		presentation_scene: Node,
		participant_id: String = "participant_0",
) -> PackedStringArray:
	var errors := PackedStringArray()
	if _socket != null or _closed:
		errors.append("preview_publisher_already_configured")
	if viewport == null or presentation_scene == null \
		or not presentation_scene.has_method("snapshot_copy"):
		errors.append("preview_publisher_scene_invalid")
	if session_secret.size() != 32:
		errors.append("preview_publisher_secret_invalid")
	if participant_id not in ["participant_0", "participant_1", "participant_2", "broadcast"]:
		errors.append("preview_publisher_participant_invalid")
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
	_participant_id = participant_id
	_preview_key = key
	_viewport = viewport
	_presentation_scene = presentation_scene
	if not _start_connection():
		_preview_key.fill(0)
		_preview_key.clear()
		errors.append("preview_publisher_connection_failed")
		return errors
	set_process(true)
	return errors


func close() -> void:
	if _closed:
		return
	_closed = true
	set_process(false)
	if _socket != null:
		_socket.close(1000, "")
		_socket = null
	_preview_key.fill(0)
	_preview_key.clear()
	_pending_jpeg.clear()
	_pending_sequence = -1
	_interpolator.reset()
	_reconnect_attempts = 0
	_reconnect_elapsed = 0.0
	_endpoint = ""
	_ticket = ""
	_episode_id = ""
	_participant_id = "participant_0"
	_viewport = null
	_presentation_scene = null


func _process(delta: float) -> void:
	if _closed or _viewport == null or _presentation_scene == null:
		return
	if _socket != null:
		_socket.poll()
	_interpolator.advance(_presentation_scene, delta)
	var socket_state := _socket.get_ready_state() if _socket != null else WebSocketPeer.STATE_CLOSED
	if socket_state == WebSocketPeer.STATE_OPEN:
		_reconnect_attempts = 0
		_reconnect_elapsed = 0.0
		_flush_pending()
	elif socket_state == WebSocketPeer.STATE_CLOSED:
		_advance_reconnect(delta)
	_elapsed += delta
	if _elapsed < FRAME_INTERVAL_SECONDS:
		return
	_elapsed = fmod(_elapsed, FRAME_INTERVAL_SECONDS)
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
	var jpeg := image.save_jpg_to_buffer(JPEG_QUALITY)
	if not _valid_jpeg(jpeg):
		return
	var sequence := _sequence
	_sequence += 1
	# A depth-one pending slot prevents network backpressure from creating visual latency.
	_pending_jpeg = jpeg
	_pending_sequence = sequence
	_flush_pending()


func _advance_reconnect(delta: float) -> void:
	if _closed or _reconnect_attempts >= MAX_RECONNECT_ATTEMPTS:
		return
	_reconnect_elapsed += maxf(0.0, delta)
	if _reconnect_elapsed < _reconnect_delay_seconds(_reconnect_attempts):
		return
	_reconnect_elapsed = 0.0
	_reconnect_attempts += 1
	_start_connection()


func _start_connection() -> bool:
	if _closed or _endpoint.is_empty():
		return false
	if _socket != null and _socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_socket.close(1000, "")
	var candidate := WebSocketPeer.new()
	candidate.handshake_headers = PackedStringArray(["Cache-Control: no-store"])
	if candidate.connect_to_url(_endpoint) != OK:
		_socket = null
		return false
	_socket = candidate
	return true


func _flush_pending() -> void:
	if _closed or _socket == null or _pending_sequence < 0 \
			or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN \
			or _socket.get_current_outbound_buffered_amount() > 0:
		return
	var sequence := _pending_sequence
	var jpeg := _pending_jpeg
	var signature := _frame_signature(sequence, jpeg)
	if signature.size() != 32:
		return
	var packet := PackedByteArray()
	for shift: int in range(56, -1, -8):
		packet.append((sequence >> shift) & 255)
	packet.append_array(signature)
	packet.append_array(jpeg)
	if _socket.send(packet, WebSocketPeer.WRITE_MODE_BINARY) != OK:
		return
	_pending_sequence = -1
	_pending_jpeg = PackedByteArray()


func _eligible_snapshot(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var snapshot: Dictionary = value
	return snapshot.get("participant_id") == _participant_id \
		and snapshot.get("task_id") in [
			"orientation-v0", "interaction-v0", "construction-v0", "neutral-encounter-v0",
			"movement-maze-v0", "operator-action-course-v0", "central-relay-v0",
			"duo-checkpoint-race-v0", "duo-relay-control-v0", "duo-spar-v0",
			"duo-resource-relay-v0", "rts-skirmish-v0",
		] \
		and typeof(snapshot.get("observation_seq")) == TYPE_INT \
		and int(snapshot.observation_seq) >= 0


func _frame_signature(sequence: int, jpeg: PackedByteArray) -> PackedByteArray:
	if _preview_key.size() != 32 or sequence < 0:
		return PackedByteArray()
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK or digest.update(jpeg) != OK:
		return PackedByteArray()
	var material := FRAME_DOMAIN.to_utf8_buffer()
	material.append_array(_ticket.to_utf8_buffer())
	material.append(0)
	material.append_array(_episode_id.to_utf8_buffer())
	material.append(0)
	material.append_array(str(sequence).to_utf8_buffer())
	material.append(0)
	material.append_array(digest.finish())
	var output := _hmac_bytes(_preview_key, material)
	material.fill(0)
	return output


static func _endpoint_for(gateway_url: String, ticket: String) -> String:
	var prefix := "wss://" if gateway_url.begins_with("wss://") else "ws://"
	var marker := "/ws/embodiment/"
	var marker_index := gateway_url.rfind(marker)
	if not gateway_url.begins_with(prefix) or marker_index <= prefix.length() \
		or marker_index + marker.length() + 43 != gateway_url.length() \
		or ticket.length() != 43:
		return ""
	var launch_ticket := gateway_url.substr(marker_index + marker.length())
	for value: String in [launch_ticket, ticket]:
		for index: int in value.length():
			var code := value.unicode_at(index)
			if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) or code in [45, 95]):
				return ""
	var origin := gateway_url.substr(prefix.length(), marker_index - prefix.length())
	if origin.is_empty():
		return ""
	return "%s%s/internal/embodiment/preview/%s/stream" % [prefix, origin, ticket]


static func _reconnect_delay_seconds(attempt: int) -> float:
	if attempt <= 0:
		return RECONNECT_BASE_SECONDS
	return minf(RECONNECT_MAX_SECONDS, RECONNECT_BASE_SECONDS * pow(2.0, float(attempt)))


static func _hmac_bytes(key: PackedByteArray, material: PackedByteArray) -> PackedByteArray:
	var context := HMACContext.new()
	if context.start(HashingContext.HASH_SHA256, key) != OK:
		return PackedByteArray()
	if context.update(material) != OK:
		return PackedByteArray()
	return context.finish()


static func _valid_jpeg(value: PackedByteArray) -> bool:
	if value.size() < 128 or value.size() > MAX_FRAME_BYTES:
		return false
	return value[0] == 255 and value[1] == 216 \
		and value[value.size() - 2] == 255 and value[value.size() - 1] == 217


static func _valid_episode_id(value: String) -> bool:
	if not value.begins_with("ep_") or value.length() < 4 or value.length() > 123:
		return false
	for index: int in range(3, value.length()):
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 46, 95]):
			return false
	return true
