class_name EmbodimentGatewayClient
extends Node

const FrameCodec := preload(
	"res://scripts/embodiment/transport/embodiment_frame_codec.gd"
)

signal managed_started
signal managed_failed(code: String)
signal managed_closed

var _socket := WebSocketPeer.new()
var _host: Variant = null
var _url := ""
var _state := "unconfigured"
var _connected_once := false


func configure(url: String, host: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if _state != "unconfigured":
		errors.append("client_already_configured")
	if not is_loopback_websocket_url(url):
		errors.append("gateway_url_invalid")
	if host == null or not host.has_method("begin_handshake") or not host.has_method("receive"):
		errors.append("session_host_invalid")
	if not errors.is_empty():
		return errors
	_url = url
	_host = host
	_state = "configured"
	return errors


func connect_once() -> PackedStringArray:
	var errors := PackedStringArray()
	if _state != "configured" or _connected_once:
		errors.append("connection_reuse_forbidden")
		return errors
	_connected_once = true
	_socket = WebSocketPeer.new()
	_socket.inbound_buffer_size = FrameCodec.MAX_FRAME_BYTES
	_socket.outbound_buffer_size = FrameCodec.MAX_FRAME_BYTES
	var error := _socket.connect_to_url(_url)
	if error != OK:
		errors.append("connection_start_failed")
		_fail(errors[0])
		return errors
	_state = "connecting"
	set_process(true)
	return errors


func close() -> void:
	if _state in ["closed", "failed", "unconfigured"]:
		return
	_state = "closing"
	_url = ""
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, "episode complete")
	else:
		_state = "closed"
		set_process(false)
		managed_closed.emit()


func _ready() -> void:
	# A managed authority configures and connects this client in the same frame that it is
	# attached to the tree.  Do not undo the polling enabled by connect_once() when Godot
	# delivers this deferred ready callback afterwards.
	if _state == "unconfigured":
		set_process(false)


func _process(_delta: float) -> void:
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if _state == "connecting":
				_state = "open"
				_url = ""
				var hello: Dictionary = _host.begin_handshake()
				if not _send_result(hello):
					return
				managed_started.emit()
			if _state == "open":
				while _socket.get_available_packet_count() > 0:
					var packet := _socket.get_packet()
					if not _socket.was_string_packet():
						_fail("binary_frame_forbidden")
						return
					var response: Dictionary = await _host.receive(packet)
					if not _send_result(response):
						return
					if _host.phase() == "complete":
						close()
		WebSocketPeer.STATE_CLOSED:
			if _state == "closing" and _host.phase() == "complete":
				_state = "closed"
				set_process(false)
				managed_closed.emit()
			elif _state not in ["closed", "failed"]:
				_fail("connection_lost")


func _send_result(result: Dictionary) -> bool:
	if not bool(result.get("ok", false)):
		_fail(str(result.get("code", "authority_failure")))
		return false
	var payload: Variant = result.get("payload")
	if typeof(payload) != TYPE_PACKED_BYTE_ARRAY or payload.is_empty() \
		or payload.size() > FrameCodec.MAX_FRAME_BYTES:
		_fail("authority_output_invalid")
		return false
	if _socket.send_text(payload.get_string_from_utf8()) != OK:
		_fail("transport_send_failed")
		return false
	return true


func _fail(code: String) -> void:
	if _state == "failed":
		return
	_state = "failed"
	_url = ""
	_host.close()
	if _socket.get_ready_state() in [WebSocketPeer.STATE_OPEN, WebSocketPeer.STATE_CONNECTING]:
		# Codes originate from this local authority and are restricted to stable identifiers.
		# Returning one through the close reason lets the managed owner diagnose a failed
		# authority boundary without exposing observations, prompts, or provider material.
		_socket.close(4400, code.left(95))
	set_process(false)
	managed_failed.emit(code)


static func is_loopback_websocket_url(url: String) -> bool:
	var regex := RegEx.new()
	if regex.compile("^ws://(127\\.0\\.0\\.1|localhost|\\[::1\\]):([0-9]{1,5})(/[^?#]*)?$") != OK:
		return false
	var matched := regex.search(url)
	if matched == null:
		return false
	var port := int(matched.get_string(2))
	return port >= 1 and port <= 65_535
