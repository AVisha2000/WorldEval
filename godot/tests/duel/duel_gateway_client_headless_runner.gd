extends SceneTree

const Client := preload("res://scripts/duel/protocol/duel_gateway_client.gd")
const Host := preload("res://scripts/duel/match/duel_gateway_session_host.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const EXPECTED_GOLDEN := "edaf9f87d206883cff205257cc0eb06e5a8a59ebc7c0e13088b1e05386f14f0c"

var _failures := PackedStringArray()


func _init() -> void:
	var valid := [
		"ws://127.0.0.1:1/duel",
		"ws://127.0.0.1:65535/ws/duel/m_test",
		"ws://localhost:8000/ws/duel",
		"ws://[::1]:443/authority",
	]
	var invalid := [
		"", "http://127.0.0.1:8000/duel", "wss://127.0.0.1:8000/duel",
		"ws://0.0.0.0:8000/duel", "ws://192.168.1.10:8000/duel",
		"ws://127.0.0.1:0/duel", "ws://127.0.0.1:65536/duel",
		"ws://127.0.0.1:8000/duel?token=secret",
		"ws://127.0.0.1:8000/duel#fragment",
		"ws://user@127.0.0.1:8000/duel",
	]
	for url: String in valid:
		_check(Client.is_loopback_websocket_url(url), "valid loopback URL was rejected: " + url)
	for url: String in invalid:
		_check(not Client.is_loopback_websocket_url(url), "unsafe gateway URL was accepted: " + url)
	var client := Client.new()
	var host := Host.new()
	_check(not client.configure("ws://example.com:8000/duel", host).is_empty(),
		"client accepted a non-loopback endpoint")
	client.free()
	var summary := {"invalid_rejected": invalid.size(), "valid_accepted": valid.size()}
	var golden := Codec.sha256_canonical(summary)
	_check(golden == EXPECTED_GOLDEN, "gateway client policy golden changed: " + golden)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_GATEWAY_CLIENT_FAILURE: " + failure)
		print("DUEL_GATEWAY_CLIENT_FAILED count=%d hash=%s" % [_failures.size(), golden])
		quit(1)
		return
	print("DUEL_GATEWAY_CLIENT_OK hash=%s summary=%s" % [golden, JSON.stringify(summary)])
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
