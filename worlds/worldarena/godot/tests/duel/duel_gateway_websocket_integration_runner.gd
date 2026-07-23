extends SceneTree

const Controller := preload("res://scripts/duel/duel_match_controller.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const ProtocolCodec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

var _controller := Controller.new()
var _finished: bool = false
var _continuous_action_applied: bool = false


func _init() -> void:
	var url := OS.get_environment("WORLDEVAL_DUEL_TEST_URL")
	var match_id := OS.get_environment("WORLDEVAL_DUEL_TEST_MATCH_ID")
	var token_hex := OS.get_environment("WORLDEVAL_DUEL_TEST_TOKEN_HEX")
	if token_hex.length() < 64 or token_hex.length() % 2 != 0:
		_fail("protected test token was not injected")
		return
	var token := token_hex.hex_decode()
	if token.hex_encode() != token_hex.to_lower():
		_fail("protected test token is not canonical hexadecimal")
		return
	get_root().add_child(_controller)
	_controller.authority_event.connect(_on_authority_event)
	_controller.match_failed.connect(_on_match_failed)
	_controller.match_closed.connect(_on_match_closed)
	var match_init := _load_match_init(match_id)
	if match_init.is_empty():
		return
	var protocol_hash := OS.get_environment("WORLDEVAL_DUEL_TEST_PROTOCOL_HASH")
	if protocol_hash.is_empty():
		protocol_hash = "e".repeat(64)
	var configure_errors := _controller.configure_launch({
		"authority": {
			"alias_salt_seat_0": "websocket-integration-observer-zero".to_utf8_buffer(),
			"alias_salt_seat_1": "websocket-integration-observer-one".to_utf8_buffer(),
			"authoritative_hashes": {},
			"scored": false,
			"tie_key": "websocket-integration-protected-tie-key".to_utf8_buffer(),
		},
		"connection_id": "godot-websocket-integration",
		"gateway_url": url,
		"match_id": match_id,
		"match_init": match_init,
		"protocol_hash": protocol_hash,
		"token": token,
	})
	if not configure_errors.is_empty():
		_fail("controller configuration failed: %s" % "; ".join(configure_errors))
		return
	var start_errors := _controller.start_match()
	if not start_errors.is_empty():
		_fail("controller start failed: %s" % "; ".join(start_errors))
		return
	_timeout.call_deferred()


func _load_match_init(match_id: String) -> Dictionary:
	var path := OS.get_environment("WORLDEVAL_DUEL_TEST_MATCH_INIT_PATH")
	if path.is_empty():
		return {
			"match_id": match_id,
			"message_type": "match_init",
			"protocol_version": "worldeval-rts/1.0.0",
		}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("full MATCH_INIT test artifact could not be opened")
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("full MATCH_INIT test artifact is not a JSON object")
		return {}
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	if not bool(normalized.get("ok", false)):
		_fail("full MATCH_INIT numeric normalization failed: %s" % "; ".join(
			normalized.get("errors", PackedStringArray())
		))
		return {}
	var result: Dictionary = normalized["value"]
	var canonical_errors := ProtocolCodec.validate_canonical_value(result, "$.match_init")
	if not canonical_errors.is_empty():
		_fail("full MATCH_INIT contains unsupported values: %s" % "; ".join(canonical_errors))
		return {}
	if str(result.get("match_id", "")) != match_id:
		_fail("full MATCH_INIT test artifact has the wrong match ID")
		return {}
	return result


func _timeout() -> void:
	await create_timer(120.0).timeout
	if not _finished:
		_fail("authenticated WebSocket integration timed out")


func _on_authority_event(kind: String, _payload: Dictionary) -> void:
	if kind == "continuous_action_pair_applied":
		_continuous_action_applied = true


func _on_match_failed(code: String, message: String) -> void:
	_fail("match failed (%s): %s" % [code, message])


func _on_match_closed() -> void:
	if _finished:
		return
	if not _continuous_action_applied:
		_fail("continuous action evidence was never applied before the terminal disposition")
		return
	_finished = true
	print("DUEL_GATEWAY_WEBSOCKET_INTEGRATION_OK phase=%s tick=%d" % [
		_controller.host.phase(), int(_controller.host.session.simulation.state.tick),
	])
	quit(0)


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("DUEL_GATEWAY_WEBSOCKET_INTEGRATION_FAILURE: " + message)
	print("DUEL_GATEWAY_WEBSOCKET_INTEGRATION_FAILED")
	quit(1)
