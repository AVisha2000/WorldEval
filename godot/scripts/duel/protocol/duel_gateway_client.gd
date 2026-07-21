class_name DuelGatewayClient
extends Node

const FrameCodec := preload("res://scripts/duel/protocol/duel_gateway_frame_codec.gd")

## One-shot loopback WebSocket transport for DuelGatewaySessionHost. The
## authenticated frame codec remains authoritative; this Node only preserves
## packet boundaries and connection lifecycle. Reconnect is intentionally
## forbidden because it would make sequence/commit state ambiguous.

signal transport_connected
signal transport_failed(code: String, message: String)
signal host_events(events: Array)
signal transport_closed

const STATE_UNCONFIGURED := "unconfigured"
const STATE_CONFIGURED := "configured"
const STATE_CONNECTING := "connecting"
const STATE_OPEN := "open"
const STATE_CLOSING := "closing"
const STATE_CLOSED := "closed"
const STATE_FAILED := "failed"

var _socket := WebSocketPeer.new()
var _host: Variant = null
var _url: String = ""
var _state: String = STATE_UNCONFIGURED
var _connected_once: bool = false
var _last_ready_state := WebSocketPeer.STATE_CLOSED


func _ready() -> void:
	if _state in [STATE_UNCONFIGURED, STATE_CONFIGURED, STATE_CLOSED, STATE_FAILED]:
		set_process(false)


func configure(url: String, host: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if _state != STATE_UNCONFIGURED:
		errors.append("Duel gateway client is already configured")
	if not is_loopback_websocket_url(url):
		errors.append("Duel gateway URL must be an explicit loopback ws:// endpoint")
	if host == null or not host.has_method("begin_handshake") \
		or not host.has_method("receive"):
		errors.append("Duel gateway client requires a session host")
	if not errors.is_empty():
		return errors
	_url = url
	_host = host
	_state = STATE_CONFIGURED
	return errors


func connect_once() -> PackedStringArray:
	var errors := PackedStringArray()
	if _state != STATE_CONFIGURED or _connected_once:
		errors.append("Duel gateway connection may be attempted exactly once")
		return errors
	_connected_once = true
	_socket = WebSocketPeer.new()
	## MATCH_INIT intentionally carries the complete locked rules/map/faction package and is much
	## larger than Godot's 64-KiB WebSocket defaults. The authenticated codec still enforces the
	## one-MiB per-frame ceiling in both directions; transport buffers must be able to hold one such
	## legal frame without changing that policy.
	_socket.inbound_buffer_size = FrameCodec.MAX_FRAME_BYTES
	_socket.outbound_buffer_size = FrameCodec.MAX_FRAME_BYTES
	_last_ready_state = WebSocketPeer.STATE_CONNECTING
	var connect_error := _socket.connect_to_url(_url)
	if connect_error != OK:
		errors.append("Duel gateway WebSocket connection could not start")
		_fail("transport_connect_failed", errors[0])
		return errors
	_state = STATE_CONNECTING
	set_process(true)
	return errors


func send_host_result(result: Dictionary) -> bool:
	if _state != STATE_OPEN:
		_fail("transport_not_open", "cannot send an authority event before the socket is open")
		return false
	return _send_result(result)


func close() -> void:
	if _state in [STATE_CLOSED, STATE_FAILED, STATE_UNCONFIGURED]:
		return
	_url = ""
	_state = STATE_CLOSING
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, "duel authority complete")
	else:
		_state = STATE_CLOSED
		set_process(false)
		transport_closed.emit()


func state() -> String:
	return _state


func _process(_delta: float) -> void:
	_socket.poll()
	var ready_state := _socket.get_ready_state()
	if ready_state != _last_ready_state:
		_last_ready_state = ready_state
		_handle_ready_state(ready_state)
	if _state != STATE_OPEN:
		return
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if not _socket.was_string_packet():
			_fail("binary_frame_forbidden", "Duel gateway accepts text frames only")
			return
		if packet.is_empty() or packet.size() > FrameCodec.MAX_FRAME_BYTES:
			_fail("frame_size_invalid", "Duel gateway frame is empty or oversized")
			return
		var result: Dictionary = _host.receive(packet)
		if not _send_result(result):
			return


func _handle_ready_state(ready_state: WebSocketPeer.State) -> void:
	match ready_state:
		WebSocketPeer.STATE_OPEN:
			if _state != STATE_CONNECTING:
				_fail("connection_state_ambiguous", "Duel gateway opened outside its initial connection")
				return
			_state = STATE_OPEN
			## The one-use attachment capability has now been consumed by the
			## loopback server. The socket owns the connection; retain no URL copy.
			_url = ""
			transport_connected.emit()
			var hello: Dictionary = _host.begin_handshake()
			_send_result(hello)
		WebSocketPeer.STATE_CLOSING:
			if _state != STATE_FAILED:
				_state = STATE_CLOSING
		WebSocketPeer.STATE_CLOSED:
			if _state == STATE_CLOSING and str(_host.phase()) == "complete":
				_state = STATE_CLOSED
				set_process(false)
				transport_closed.emit()
			elif _state not in [STATE_FAILED, STATE_CLOSED]:
				_fail("connection_lost", "Duel gateway closed before artifact completion")


func _send_result(result: Dictionary) -> bool:
	if not bool(result.get("ok", false)):
		var messages := PackedStringArray()
		for message_variant: Variant in result.get("errors", []):
			messages.append(str(message_variant))
		_fail(
			str(result.get("code", "authority_failure")),
			"; ".join(messages) if not messages.is_empty() else "Duel authority operation failed"
		)
		return false
	var outbound_variant: Variant = result.get("outbound", [])
	if typeof(outbound_variant) != TYPE_ARRAY:
		_fail("authority_output_invalid", "Duel authority outbound packets must be an array")
		return false
	for payload_variant: Variant in (outbound_variant as Array):
		if typeof(payload_variant) != TYPE_PACKED_BYTE_ARRAY:
			_fail("authority_output_invalid", "Duel authority packet must be canonical bytes")
			return false
		var payload: PackedByteArray = payload_variant
		if payload.is_empty() or payload.size() > FrameCodec.MAX_FRAME_BYTES \
			or payload.get_string_from_utf8().to_utf8_buffer() != payload:
			_fail("authority_output_invalid", "Duel authority packet is not valid bounded UTF-8")
			return false
		if _socket.send_text(payload.get_string_from_utf8()) != OK:
			_fail("transport_send_failed", "Duel gateway WebSocket send failed")
			return false
	var events_variant: Variant = result.get("events", [])
	if typeof(events_variant) == TYPE_ARRAY and not (events_variant as Array).is_empty():
		host_events.emit((events_variant as Array).duplicate(true))
	return true


func _fail(code: String, message: String) -> void:
	if _state == STATE_FAILED:
		return
	_state = STATE_FAILED
	_url = ""
	if _socket.get_ready_state() in [WebSocketPeer.STATE_OPEN, WebSocketPeer.STATE_CONNECTING]:
		_socket.close(4400, "duel authority failure")
	set_process(false)
	transport_failed.emit(code, message)


static func is_loopback_websocket_url(url: String) -> bool:
	var regex := RegEx.new()
	if regex.compile("^ws://(127\\.0\\.0\\.1|localhost|\\[::1\\]):([0-9]{1,5})(/[^?#]*)?$") != OK:
		return false
	var matched := regex.search(url)
	if matched == null:
		return false
	var port := int(matched.get_string(2))
	return port >= 1 and port <= 65_535
