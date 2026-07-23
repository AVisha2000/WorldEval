extends SceneTree

## Test-only length-prefixed loopback bridge used to exercise the real Python DemoProvider against the real
## protocol-v2 Godot dispatcher. It owns no policy and exposes only ordinary participant-visible
## observations plus the public step result returned by the dispatcher.

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Dispatcher := preload("res://scripts/embodiment/v2/transport/control_game_dispatcher_v2.gd")
const MAX_LINE_BYTES := 1_048_576

var _peer := StreamPeerTCP.new()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 1 or not arguments[0].is_valid_int():
		_fail("bridge_port_invalid")
		return
	var port := int(arguments[0])
	if port < 1 or port > 65535 or _peer.connect_to_host("127.0.0.1", port) != OK:
		_fail("bridge_connect_failed")
		return
	while _peer.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		_peer.poll()
		await create_timer(0.001).timeout
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_fail("bridge_connect_failed")
		return
	var config_message := await _read_message()
	if not bool(config_message.get("ok", false)) \
		or not config_message.value is Dictionary \
		or not Codec._has_exact_fields(config_message.value, ["config"]):
		_fail("bridge_config_invalid")
		return
	var dispatcher := Dispatcher.new()
	if not dispatcher.configure(config_message.value.config).is_empty():
		_fail("bridge_config_rejected")
		return
	_emit({
		"observation": dispatcher.observe_all().participant_0,
		"state_hash": dispatcher.checkpoint_hash(),
	})
	while not bool(dispatcher.terminal().ended):
		var message := await _read_message()
		if not bool(message.get("ok", false)) \
			or not message.value is Dictionary \
			or not Codec._has_exact_fields(message.value, ["window"]):
			_fail("bridge_window_invalid")
			return
		var result: Dictionary = dispatcher.step_window(message.value.window)
		_emit({"result": result})
	await create_timer(0.01).timeout
	_peer.disconnect_from_host()
	quit(0)


func _read_message() -> Dictionary:
	var prefix := await _read_exact(4)
	if prefix.size() != 4:
		return {"ok": false}
	var size := (int(prefix[0]) << 24) | (int(prefix[1]) << 16) \
		| (int(prefix[2]) << 8) | int(prefix[3])
	if size < 1 or size > MAX_LINE_BYTES:
		return {"ok": false}
	var payload := await _read_exact(size)
	if payload.size() != size:
		return {"ok": false}
	var parsed := Codec.parse_canonical(payload, MAX_LINE_BYTES)
	payload.fill(0)
	payload.clear()
	return parsed


func _read_exact(size: int) -> PackedByteArray:
	var output := PackedByteArray()
	while output.size() < size and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_peer.poll()
		var available := mini(_peer.get_available_bytes(), size - output.size())
		if available > 0:
			var received := _peer.get_data(available)
			if received[0] != OK:
				return PackedByteArray()
			output.append_array(received[1])
		else:
			await create_timer(0.001).timeout
	return output


func _emit(value: Dictionary) -> void:
	var payload := Codec.canonical_bytes(value)
	var prefix := PackedByteArray([
		(payload.size() >> 24) & 255,
		(payload.size() >> 16) & 255,
		(payload.size() >> 8) & 255,
		payload.size() & 255,
	])
	prefix.append_array(payload)
	if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_peer.put_data(prefix)


func _fail(code: String) -> void:
	if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_emit({"error": code})
	else:
		push_error(code)
	quit(2)
