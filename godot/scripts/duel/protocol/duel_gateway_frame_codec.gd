class_name DuelGatewayFrameCodec
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")

## Canonical, authenticated frame codec shared by the Godot authority and the
## Python provider gateway. The transport may carry these bytes over a local
## WebSocket, an in-memory test link, or a replay harness; none of those layers
## may reinterpret the frame.

const PROTOCOL_VERSION := "worldeval-rts/1.0.0"
const MAX_FRAME_BYTES := 1_048_576
const MAX_SEQUENCE := 9_007_199_254_740_991
const SESSION_BOUNDARY_HASH := "0000000000000000000000000000000000000000000000000000000000000000"
const AUTH_DOMAIN := "worldeval-rts/godot-gateway-frame/v1\u0000"
const KEY_DOMAIN := "worldeval-rts/godot-gateway-key/v1\u0000"

const FRAME_FIELDS: Array[String] = [
	"auth_tag",
	"body",
	"boundary_hash",
	"boundary_hash_kind",
	"match_id",
	"message_type",
	"protocol_version",
	"sender",
	"sequence",
]
const MESSAGE_BOUNDARY_KIND := {
	"action": "checkpoint",
	"action_pair": "checkpoint",
	"action_receipts": "checkpoint",
	"artifact_ready": "artifact",
	"auth": "session",
	"batch_commit_hashes": "checkpoint",
	"batch_commits_locked": "checkpoint",
	"batch_reveal": "checkpoint",
	"checkpoint": "checkpoint",
	"config_accepted": "config",
	"continuous_start": "checkpoint",
	"continuous_start_accepted": "checkpoint",
	"gateway_disposition": "checkpoint",
	"gateway_disposition_accepted": "checkpoint",
	"hello": "session",
	"match_config": "config",
	"match_init": "protocol",
	"observation": "observation",
	"observation_pair": "checkpoint",
	"terminal": "result",
	"thinking_status": "observation",
	"tick_events": "checkpoint",
}
const PROVIDER_VISIBLE_TYPES := {
	"match_init": true,
	"observation": true,
}
const HIDDEN_WORLD_HASH_KEYS := {
	"checkpoint_hash": true,
	"final_state_hash": true,
	"omniscient_state_hash": true,
	"state_hash": true,
	"world_hash": true,
}

var match_id: String = ""
var local_role: String = ""
var remote_role: String = ""

var _keys: Dictionary = {}
var _outbound_sequence: int = 0
var _inbound_sequence: int = 0
var _configured: bool = false
var _failed: bool = false
var _closed: bool = false


func configure(match_id_input: String, token: PackedByteArray, role: String) -> PackedStringArray:
	var errors := PackedStringArray()
	if _configured:
		errors.append("gateway frame codec is already configured")
		return errors
	if not ObservationContract.is_match_id(match_id_input):
		errors.append("gateway frame match_id is invalid")
	if token.size() < 32:
		errors.append("gateway frame token must contain at least 32 random bytes")
	if role not in ["gateway", "godot"]:
		errors.append("gateway frame role must be gateway or godot")
	if not errors.is_empty():
		return errors
	match_id = match_id_input
	local_role = role
	remote_role = "godot" if role == "gateway" else "gateway"
	for key_role: String in ["gateway", "godot"]:
		var key_material := KEY_DOMAIN.to_utf8_buffer()
		key_material.append_array(key_role.to_utf8_buffer())
		_keys[key_role] = KeyedRandom.hmac_sha256_hex(token, key_material).hex_decode()
	_outbound_sequence = 0
	_inbound_sequence = 0
	_configured = true
	return errors


func encode(message_type: String, boundary_hash: String, body: Dictionary) -> Dictionary:
	var guard := _open_guard()
	if not bool(guard.get("ok", false)):
		return guard
	if not MESSAGE_BOUNDARY_KIND.has(message_type):
		return _fail("unsupported_message_type", "outbound message type is unsupported")
	if not ObservationContract.is_sha256(boundary_hash):
		return _fail("outbound_frame_invalid", "outbound boundary hash is invalid")
	if message_type in ["hello", "auth"] and boundary_hash != SESSION_BOUNDARY_HASH:
		return _fail(
			"outbound_frame_invalid", "handshake frames require the zero session boundary hash"
		)
	var body_errors := Codec.validate_canonical_value(body, "$.body")
	if not body_errors.is_empty():
		return _fail(
			"outbound_frame_invalid",
			"outbound body is not a canonical authoritative value: %s" % "; ".join(body_errors)
		)
	if PROVIDER_VISIBLE_TYPES.has(message_type) and _contains_hidden_world_hash(body):
		return _fail(
			"outbound_frame_invalid", "provider-visible frame contains an omniscient world hash"
		)
	var unsigned := {
		"body": body.duplicate(true),
		"boundary_hash": boundary_hash,
		"boundary_hash_kind": str(MESSAGE_BOUNDARY_KIND[message_type]),
		"match_id": match_id,
		"message_type": message_type,
		"protocol_version": PROTOCOL_VERSION,
		"sender": local_role,
		"sequence": _outbound_sequence,
	}
	var auth_tag := _auth_tag(_keys[local_role], unsigned)
	if auth_tag.is_empty():
		return _fail("outbound_frame_invalid", "outbound frame authentication failed")
	var frame := unsigned.duplicate(true)
	frame["auth_tag"] = auth_tag
	var payload := Codec.canonical_bytes(frame)
	if payload.is_empty() or payload.size() > MAX_FRAME_BYTES:
		return _fail("frame_too_large", "outbound frame exceeds the byte limit")
	_outbound_sequence += 1
	return {
		"errors": PackedStringArray(),
		"frame": frame,
		"ok": true,
		"payload": payload,
	}


func decode(payload: PackedByteArray) -> Dictionary:
	var guard := _open_guard()
	if not bool(guard.get("ok", false)):
		return guard
	if payload.is_empty() or payload.size() > MAX_FRAME_BYTES:
		return _fail("frame_too_large", "inbound frame is empty or exceeds the byte limit")
	var text := payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload:
		return _fail("inbound_frame_invalid", "inbound frame is not valid UTF-8")
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return _fail("inbound_frame_invalid", "inbound frame is not valid JSON")
	var normalized := CatalogLoader.normalize_json_boundary(parser.data)
	if not bool(normalized.get("ok", false)):
		return _fail(
			"inbound_frame_invalid",
			"inbound frame contains a forbidden JSON value: %s" % "; ".join(normalized["errors"])
		)
	var value: Variant = normalized["value"]
	if typeof(value) != TYPE_DICTIONARY:
		return _fail("inbound_frame_invalid", "inbound frame root must be an object")
	var frame: Dictionary = value
	if Codec.canonical_bytes(frame) != payload:
		return _fail("inbound_frame_invalid", "inbound frame bytes are not canonical")
	var validation := _validate_frame(frame)
	if not bool(validation.get("ok", false)):
		return _fail(str(validation["code"]), str(validation["message"]))
	if str(frame["match_id"]) != match_id:
		return _fail("wrong_match", "inbound frame has the wrong match_id")
	if str(frame["sender"]) != remote_role:
		return _fail("wrong_sender", "inbound frame has the wrong sender role")
	if int(frame["sequence"]) != _inbound_sequence:
		return _fail(
			"sequence_violation",
			"expected inbound sequence %d, got %d" % [
				_inbound_sequence, int(frame["sequence"]),
			]
		)
	var unsigned := frame.duplicate(true)
	unsigned.erase("auth_tag")
	var expected_tag := _auth_tag(_keys[remote_role], unsigned)
	if not _constant_time_equal(str(frame["auth_tag"]), expected_tag):
		return _fail("authentication_failed", "inbound frame authentication failed")
	_inbound_sequence += 1
	return {
		"errors": PackedStringArray(),
		"frame": frame.duplicate(true),
		"ok": true,
	}


func close() -> void:
	_closed = true


func is_failed() -> bool:
	return _failed


func outbound_sequence() -> int:
	return _outbound_sequence


func inbound_sequence() -> int:
	return _inbound_sequence


func _validate_frame(frame: Dictionary) -> Dictionary:
	if frame.size() != FRAME_FIELDS.size():
		return _invalid("inbound_frame_invalid", "inbound frame fields are not exact")
	for field: String in FRAME_FIELDS:
		if not frame.has(field):
			return _invalid("inbound_frame_invalid", "inbound frame is missing " + field)
	for key_variant: Variant in frame.keys():
		if typeof(key_variant) != TYPE_STRING or str(key_variant) not in FRAME_FIELDS:
			return _invalid("inbound_frame_invalid", "inbound frame has an unknown field")
	if str(frame["protocol_version"]) != PROTOCOL_VERSION:
		return _invalid("inbound_frame_invalid", "inbound protocol version is unsupported")
	if not ObservationContract.is_match_id(frame["match_id"]):
		return _invalid("inbound_frame_invalid", "inbound match_id is invalid")
	if typeof(frame["sender"]) != TYPE_STRING or str(frame["sender"]) not in ["gateway", "godot"]:
		return _invalid("inbound_frame_invalid", "inbound sender is invalid")
	if typeof(frame["sequence"]) != TYPE_INT \
		or int(frame["sequence"]) < 0 or int(frame["sequence"]) > MAX_SEQUENCE:
		return _invalid("inbound_frame_invalid", "inbound sequence is invalid")
	if typeof(frame["message_type"]) != TYPE_STRING \
		or not MESSAGE_BOUNDARY_KIND.has(str(frame["message_type"])):
		return _invalid("inbound_frame_invalid", "inbound message type is unsupported")
	var message_type := str(frame["message_type"])
	if typeof(frame["boundary_hash_kind"]) != TYPE_STRING \
		or str(frame["boundary_hash_kind"]) != str(MESSAGE_BOUNDARY_KIND[message_type]):
		return _invalid("inbound_frame_invalid", "inbound boundary hash kind is inconsistent")
	if not ObservationContract.is_sha256(frame["boundary_hash"]):
		return _invalid("inbound_frame_invalid", "inbound boundary hash is invalid")
	if message_type in ["hello", "auth"] \
		and str(frame["boundary_hash"]) != SESSION_BOUNDARY_HASH:
		return _invalid(
			"inbound_frame_invalid", "handshake frames require the zero session boundary hash"
		)
	if not ObservationContract.is_sha256(frame["auth_tag"]):
		return _invalid("inbound_frame_invalid", "inbound authentication tag is invalid")
	if typeof(frame["body"]) != TYPE_DICTIONARY:
		return _invalid("inbound_frame_invalid", "inbound frame body must be an object")
	var body_errors := Codec.validate_canonical_value(frame["body"], "$.body")
	if not body_errors.is_empty():
		return _invalid("inbound_frame_invalid", "inbound frame body is not canonical")
	if PROVIDER_VISIBLE_TYPES.has(message_type) \
		and _contains_hidden_world_hash(frame["body"]):
		return _invalid(
			"inbound_frame_invalid", "provider-visible frame contains an omniscient world hash"
		)
	return {"ok": true}


func _auth_tag(key: PackedByteArray, unsigned: Dictionary) -> String:
	var canonical := Codec.canonical_bytes(unsigned)
	if canonical.is_empty():
		return ""
	var material := AUTH_DOMAIN.to_utf8_buffer()
	material.append_array(canonical)
	return KeyedRandom.hmac_sha256_hex(key, material)


func _open_guard() -> Dictionary:
	if not _configured:
		return _failure_without_transition("codec_unconfigured", "gateway frame codec is not configured")
	if _failed:
		return _failure_without_transition("codec_failed_closed", "gateway frame codec already failed closed")
	if _closed:
		return _failure_without_transition("codec_closed", "gateway frame codec is closed")
	return {"ok": true}


func _fail(code: String, message: String) -> Dictionary:
	_failed = true
	return _failure_without_transition(code, message)


static func _failure_without_transition(code: String, message: String) -> Dictionary:
	return {
		"code": code,
		"errors": PackedStringArray([message]),
		"ok": false,
	}


static func _invalid(code: String, message: String) -> Dictionary:
	return {"code": code, "message": message, "ok": false}


static func _constant_time_equal(left: String, right: String) -> bool:
	var left_bytes := left.to_utf8_buffer()
	var right_bytes := right.to_utf8_buffer()
	var difference := left_bytes.size() ^ right_bytes.size()
	var maximum := maxi(left_bytes.size(), right_bytes.size())
	for index: int in maximum:
		var left_byte := left_bytes[index] if index < left_bytes.size() else 0
		var right_byte := right_bytes[index] if index < right_bytes.size() else 0
		difference |= left_byte ^ right_byte
	return difference == 0


static func _contains_hidden_world_hash(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		for key_variant: Variant in (value as Dictionary).keys():
			if HIDDEN_WORLD_HASH_KEYS.has(str(key_variant)):
				return true
			if _contains_hidden_world_hash((value as Dictionary)[key_variant]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for element: Variant in (value as Array):
			if _contains_hidden_world_hash(element):
				return true
	return false
