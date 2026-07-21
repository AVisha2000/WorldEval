class_name DuelLaunchClient
extends Node

const HttpTransport := preload("res://scripts/duel/app/duel_http_json_transport.gd")
const JsonBoundary := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")

## Credential-safe, one-shot localhost bootstrap. The creation capability is
## consumed immediately and is never exposed through debug/status surfaces.

signal create_request_dispatched
signal claim_request_dispatched
signal launch_ready(fields: Dictionary)
signal launch_failed(code: String, message: String)

const CREATE_PATH := "/api/duel/matches"
const CLAIM_PATH := "/api/duel/launch-claim"
const CREATE_FIELDS := ["status", "launch_claim_token"]
const LAUNCH_FIELDS := [
	"authority",
	"connection_id",
	"gateway_url",
	"match_id",
	"match_init",
	"protocol_hash",
	"token",
]
const AUTHORITY_FIELDS := [
	"alias_salt_seat_0",
	"alias_salt_seat_1",
	"authoritative_hashes",
	"scored",
	"tie_key",
]
const REQUEST_FIELDS := [
	"authority_launch_mode",
	"decision_mode",
	"decision_period_ticks",
	"faction_preset_id",
	"map_id",
	"maximum_match_ticks",
	"memory_policy",
	"mirror_faction",
	"players",
	"response_deadline_ms",
	"seed",
	"spectator",
]
const JSON_HEADERS := [
	"Content-Type: application/json",
	"Accept: application/json",
	"Cache-Control: no-store",
]

@export var base_http_url := "http://127.0.0.1:8000"

var _transport: Node
var _owns_transport := false
var _phase := "idle"
var _claim_dispatched := false
var _launch_emitted := false


func _ready() -> void:
	if _transport == null:
		set_http_transport(HttpTransport.new(), true)


func set_http_transport(transport: Node, take_ownership: bool = false) -> PackedStringArray:
	var errors := PackedStringArray()
	if _phase != "idle":
		errors.append("launch HTTP transport can only be changed while idle")
		return errors
	if transport == null or not transport.has_method("dispatch_post") \
		or not transport.has_signal("completed"):
		errors.append("launch HTTP transport does not implement the required seam")
		return errors
	if _transport != null and _transport.is_connected("completed", _on_http_completed):
		_transport.disconnect("completed", _on_http_completed)
	if _owns_transport and _transport != null and is_instance_valid(_transport):
		_transport.queue_free()
	_transport = transport
	_owns_transport = take_ownership
	if take_ownership and transport.get_parent() == null:
		add_child(transport)
	_transport.connect("completed", _on_http_completed)
	return errors


func start_launch(request: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if _phase != "idle":
		errors.append("a Duel launch may start exactly once")
		return errors
	if not is_loopback_http_url(base_http_url):
		errors.append("Duel launch service must use an explicit loopback HTTP URL")
		return errors
	_validate_exact_fields(request, REQUEST_FIELDS, "match creation request", errors)
	if str(request.get("authority_launch_mode", "")) != "caller_owned":
		errors.append("interactive Duel launch must be caller_owned")
	if errors.is_empty():
		errors.append_array(_validate_players(request.get("players")))
	if not errors.is_empty():
		return errors
	if _transport == null:
		_ready()
	_phase = "creating"
	var request_bytes := JSON.stringify(request).to_utf8_buffer()
	var dispatch_error: Error = _transport.call(
		"dispatch_post", base_http_url.trim_suffix("/") + CREATE_PATH,
		PackedStringArray(JSON_HEADERS), request_bytes
	)
	request_bytes.fill(0)
	request_bytes.clear()
	if dispatch_error != OK:
		_phase = "failed"
		errors.append("local Duel match creation request could not be dispatched")
		return errors
	_scrub_request_credentials(request)
	create_request_dispatched.emit()
	return errors


func debug_state() -> Dictionary:
	return {
		"phase": _phase,
		"claim_dispatched": _claim_dispatched,
		"launch_emitted": _launch_emitted,
	}


static func is_loopback_http_url(url: String) -> bool:
	var normalized := url.strip_edges().to_lower().trim_suffix("/")
	if not normalized.begins_with("http://"):
		return false
	var authority := normalized.trim_prefix("http://")
	if authority.is_empty() or authority.contains("/") or authority.contains("@") \
		or authority.contains("?") or authority.contains("#"):
		return false
	var host := authority
	var port := ""
	if authority.begins_with("["):
		var closing := authority.find("]")
		if closing < 0:
			return false
		host = authority.substr(1, closing - 1)
		var suffix := authority.substr(closing + 1)
		if not suffix.is_empty():
			if not suffix.begins_with(":"):
				return false
			port = suffix.trim_prefix(":")
	elif authority.count(":") == 1:
		host = authority.get_slice(":", 0)
		port = authority.get_slice(":", 1)
	elif authority.count(":") > 1:
		return false
	if host not in ["127.0.0.1", "localhost", "::1"]:
		return false
	if port.is_empty():
		return true
	if not port.is_valid_int() or str(int(port)) != port:
		return false
	return int(port) >= 1 and int(port) <= 65535


static func convert_launch_fields(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	if not _has_exact_fields(source, LAUNCH_FIELDS):
		return {}
	if typeof(source.get("authority")) != TYPE_DICTIONARY \
		or not _has_exact_fields(source["authority"], AUTHORITY_FIELDS):
		return {}
	var authority_source: Dictionary = source["authority"]
	var token := _byte_array(authority_source.get("tie_key"))
	var salt_zero := _byte_array(authority_source.get("alias_salt_seat_0"))
	var salt_one := _byte_array(authority_source.get("alias_salt_seat_1"))
	var session_token := _byte_array(source.get("token"))
	if token.is_empty() or salt_zero.size() < 16 or salt_one.size() < 16 \
		or session_token.size() < 32:
		return {}
	if typeof(authority_source.get("authoritative_hashes")) != TYPE_DICTIONARY \
		or typeof(authority_source.get("scored")) != TYPE_BOOL \
		or typeof(source.get("match_init")) != TYPE_DICTIONARY:
		return {}
	return {
		"authority": {
			"alias_salt_seat_0": salt_zero,
			"alias_salt_seat_1": salt_one,
			"authoritative_hashes": (authority_source["authoritative_hashes"] as Dictionary).duplicate(true),
			"scored": authority_source["scored"],
			"tie_key": token,
		},
		"connection_id": str(source.get("connection_id", "")),
		"gateway_url": str(source.get("gateway_url", "")),
		"match_id": str(source.get("match_id", "")),
		"match_init": (source["match_init"] as Dictionary).duplicate(true),
		"protocol_hash": str(source.get("protocol_hash", "")),
		"token": session_token,
	}


func _on_http_completed(result: int, response_code: int, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("duel_launch_transport_failed", "The local Duel service did not answer.")
		return
	if _phase == "creating":
		_handle_creation(response_code, body)
	elif _phase == "claiming":
		_handle_claim(response_code, body)
	else:
		_fail("duel_launch_response_unexpected", "The local Duel service returned an unexpected response.")


func _handle_creation(response_code: int, body: PackedByteArray) -> void:
	if response_code != 202:
		_fail(_safe_error_code(body, "duel_match_creation_failed"), "The match request was rejected by the local Duel service.")
		return
	var parsed_result := _parse_json_object(body)
	if not bool(parsed_result.get("ok", false)) \
		or not _has_exact_fields(parsed_result.get("value"), CREATE_FIELDS):
		_fail("duel_match_creation_invalid", "The local Duel service returned an invalid creation response.")
		return
	var creation: Dictionary = parsed_result["value"]
	var claim_token := str(creation.get("launch_claim_token", ""))
	var status: Variant = creation.get("status")
	if claim_token.is_empty() or typeof(status) != TYPE_DICTIONARY \
		or str((status as Dictionary).get("match_id", "")).is_empty():
		_fail("duel_match_creation_invalid", "The local Duel service omitted its one-time launch claim.")
		return
	if _claim_dispatched:
		_fail("duel_launch_claim_duplicate", "The one-time authority claim was already dispatched.")
		return
	var claim_body := JSON.stringify({"claim_token": claim_token}).to_utf8_buffer()
	claim_token = ""
	_phase = "claiming"
	var dispatch_error: Error = _transport.call(
		"dispatch_post", base_http_url.trim_suffix("/") + CLAIM_PATH,
		PackedStringArray(JSON_HEADERS), claim_body
	)
	claim_body.fill(0)
	claim_body.clear()
	if dispatch_error != OK:
		_fail("duel_launch_claim_dispatch_failed", "The one-time authority claim could not be dispatched.")
		return
	_claim_dispatched = true
	claim_request_dispatched.emit()


func _handle_claim(response_code: int, body: PackedByteArray) -> void:
	if response_code != 200:
		_fail(_safe_error_code(body, "duel_launch_claim_failed"), "The one-time authority launch could not be claimed.")
		return
	var parsed_result := _parse_json_object(body)
	var fields := convert_launch_fields(parsed_result.get("value")) \
		if bool(parsed_result.get("ok", false)) else {}
	if fields.is_empty():
		_fail("duel_launch_claim_invalid", "The local Duel service returned invalid authority launch fields.")
		return
	_phase = "ready"
	_launch_emitted = true
	launch_ready.emit(fields)
	_zero_launch_fields(fields)


func _fail(code: String, message: String) -> void:
	if _phase == "failed":
		return
	_phase = "failed"
	launch_failed.emit(code, message)


static func _validate_players(value: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2:
		errors.append("match creation request must contain two player slots")
		return errors
	for slot in 2:
		var raw: Variant = (value as Array)[slot]
		if typeof(raw) != TYPE_DICTIONARY:
			errors.append("player launch entry must be an object")
			continue
		var player: Dictionary = raw
		if int(player.get("slot", -1)) != slot:
			errors.append("player launch slots must be ordered 0 then 1")
		var provider := str(player.get("provider", ""))
		var model := str(player.get("model", ""))
		var reasoning := str(player.get("reasoning", ""))
		if provider == "openai":
			if model.is_empty() or reasoning not in ["none", "low", "medium", "high", "xhigh", "max"]:
				errors.append("OpenAI player configuration is incomplete")
			if typeof(player.get("credential")) != TYPE_STRING \
				or str(player.get("credential", "")).is_empty():
				errors.append("OpenAI player credential is missing")
		elif provider in ["baseline.noop", "baseline.seeded_random", "baseline.rush"]:
			var expected: String = {
				"baseline.noop": "baseline-noop-v1",
				"baseline.seeded_random": "baseline-seeded-random-v1",
				"baseline.rush": "baseline-rush-v1",
			}[provider]
			if model != expected or reasoning != "none" \
				or player.has("credential") or player.has("service_tier"):
				errors.append("baseline player configuration is not frozen")
		else:
			errors.append("player provider is not installed")
	return errors


static func _validate_exact_fields(
	value: Variant, fields: Array, label: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_DICTIONARY or not _has_exact_fields(value, fields):
		errors.append(label + " fields are not exact")


static func _has_exact_fields(value: Variant, fields: Array) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var dictionary: Dictionary = value
	if dictionary.size() != fields.size():
		return false
	for field: Variant in fields:
		if not dictionary.has(str(field)):
			return false
	return true


static func _byte_array(value: Variant) -> PackedByteArray:
	var output := PackedByteArray()
	if typeof(value) != TYPE_ARRAY:
		return output
	for raw: Variant in value:
		if typeof(raw) not in [TYPE_INT, TYPE_FLOAT]:
			return PackedByteArray()
		var number := int(raw)
		if number < 0 or number > 255 or float(raw) != float(number):
			return PackedByteArray()
		output.append(number)
	return output


static func _scrub_request_credentials(request: Dictionary) -> void:
	var players: Variant = request.get("players")
	if typeof(players) != TYPE_ARRAY:
		return
	for raw: Variant in players:
		if typeof(raw) == TYPE_DICTIONARY and (raw as Dictionary).has("credential"):
			(raw as Dictionary)["credential"] = ""
	request.clear()


static func _zero_launch_fields(fields: Dictionary) -> void:
	var session: Variant = fields.get("token")
	if typeof(session) == TYPE_PACKED_BYTE_ARRAY:
		(session as PackedByteArray).fill(0)
	var authority: Variant = fields.get("authority")
	if typeof(authority) == TYPE_DICTIONARY:
		for key: String in ["tie_key", "alias_salt_seat_0", "alias_salt_seat_1"]:
			var bytes: Variant = (authority as Dictionary).get(key)
			if typeof(bytes) == TYPE_PACKED_BYTE_ARRAY:
				(bytes as PackedByteArray).fill(0)
	fields.clear()


static func _safe_error_code(body: PackedByteArray, fallback: String) -> String:
	var parsed_result := _parse_json_object(body)
	var parsed: Variant = parsed_result.get("value") if bool(parsed_result.get("ok", false)) else null
	if typeof(parsed) != TYPE_DICTIONARY or typeof((parsed as Dictionary).get("detail")) != TYPE_DICTIONARY:
		return fallback
	var candidate := str(((parsed as Dictionary)["detail"] as Dictionary).get("code", ""))
	if candidate.is_empty() or candidate.length() > 96:
		return fallback
	for index in candidate.length():
		var code := candidate.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 122) or code in [45, 46, 58, 95]):
			return fallback
	return candidate


static func _parse_json_object(body: PackedByteArray) -> Dictionary:
	var text := body.get_string_from_utf8()
	var valid_utf8 := text.to_utf8_buffer() == body
	body.fill(0)
	if not valid_utf8:
		return {"ok": false}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {"ok": false}
	var normalized: Dictionary = JsonBoundary.normalize_json_boundary(parser.data)
	if not bool(normalized.get("ok", false)) \
		or typeof(normalized.get("value")) != TYPE_DICTIONARY:
		return {"ok": false}
	return {"ok": true, "value": normalized["value"]}
