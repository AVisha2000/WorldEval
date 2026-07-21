class_name EmbodimentFrameCodec
extends RefCounted

## Canonical authenticated frame boundary for the managed embodiment authority.

const SCHEMA_VERSION := "llm-controller/transport-frame/1.0.0"
const PROTOCOL_VERSION := "llm-controller/0.1.0"
const MAX_FRAME_BYTES := 16 * 1024 * 1024
const MAX_SEQUENCE := 9_007_199_254_740_991
const ZERO_HASH := "0000000000000000000000000000000000000000000000000000000000000000"
const KEY_DOMAIN := "llm-controller/gateway-key/v1\u0000"
const FRAME_DOMAIN := "llm-controller/gateway-frame/v1\u0000"
const FRAME_FIELDS := [
	"schema_version", "protocol_version", "episode_id", "sender", "sequence",
	"message_type", "boundary_hash_kind", "boundary_hash", "body", "auth_tag",
]
const MESSAGE_BOUNDARY_KIND := {
	"hello": "session",
	"auth": "session",
	"episode_ready": "config",
	"decision_window": "checkpoint",
	"step_result": "checkpoint",
	"frame_request": "checkpoint",
	"frame_response": "checkpoint",
	"close_episode": "checkpoint",
	"episode_closed": "checkpoint",
	"episode_error": "checkpoint",
}
const ALLOWED_BY_SENDER := {
	"python": ["auth", "decision_window", "frame_request", "close_episode"],
	"godot": ["hello", "episode_ready", "step_result", "frame_response", "episode_closed", "episode_error"],
}
const SENDER_MESSAGE_TYPES := {
	"python": ["auth", "decision_window", "frame_request", "close_episode"],
	"godot": ["hello", "episode_ready", "step_result", "frame_response", "episode_closed", "episode_error"],
}

var episode_id := ""
var local_role := ""
var remote_role := ""
var _keys := {}
var _outbound_sequence := 0
var _inbound_sequence := 0
var _configured := false
var _failed := false
var _closed := false


func configure(configured_episode_id: String, secret: PackedByteArray, role: String) -> PackedStringArray:
	var errors := PackedStringArray()
	if _configured:
		errors.append("codec_already_configured")
	if not _valid_episode_id(configured_episode_id):
		errors.append("episode_id_invalid")
	if secret.size() != 32:
		errors.append("session_secret_invalid")
	if role not in ["python", "godot"]:
		errors.append("role_invalid")
	if not errors.is_empty():
		return errors
	episode_id = configured_episode_id
	local_role = role
	remote_role = "godot" if role == "python" else "python"
	for key_role: String in ["python", "godot"]:
		var material := KEY_DOMAIN.to_utf8_buffer()
		material.append_array(key_role.to_utf8_buffer())
		_keys[key_role] = _hmac(secret, material).hex_decode()
	_configured = true
	return errors


func encode(message_type: String, boundary_hash: String, body: Dictionary) -> Dictionary:
	if not _open():
		return _failure("codec_not_open")
	if not MESSAGE_BOUNDARY_KIND.has(message_type):
		return _fail("message_type_invalid")
	if message_type not in ALLOWED_BY_SENDER[local_role]:
		return _fail("message_type_invalid")
	if message_type not in SENDER_MESSAGE_TYPES[local_role]:
		return _fail("message_sender_invalid")
	if not _is_sha256(boundary_hash):
		return _fail("boundary_hash_invalid")
	if message_type in ["hello", "auth"] and boundary_hash != ZERO_HASH:
		return _fail("session_boundary_invalid")
	if not _canonical_value(body):
		return _fail("body_invalid")
	var unsigned := {
		"body": body.duplicate(true),
		"boundary_hash": boundary_hash,
		"boundary_hash_kind": str(MESSAGE_BOUNDARY_KIND[message_type]),
		"episode_id": episode_id,
		"message_type": message_type,
		"protocol_version": PROTOCOL_VERSION,
		"schema_version": SCHEMA_VERSION,
		"sender": local_role,
		"sequence": _outbound_sequence,
	}
	var frame := unsigned.duplicate(true)
	frame["auth_tag"] = _tag(_keys[local_role], unsigned)
	var payload := canonical_bytes(frame)
	if payload.is_empty() or payload.size() > MAX_FRAME_BYTES:
		return _fail("frame_size_invalid")
	_outbound_sequence += 1
	return {"ok": true, "payload": payload, "frame": frame, "code": ""}


func decode(payload: PackedByteArray) -> Dictionary:
	if not _open():
		return _failure("codec_not_open")
	if payload.is_empty() or payload.size() > MAX_FRAME_BYTES:
		return _fail("frame_size_invalid")
	var parsed := parse_canonical(payload)
	if not bool(parsed.get("ok", false)):
		return _fail(str(parsed.get("code", "frame_invalid")))
	var value: Variant = parsed.get("value")
	if typeof(value) != TYPE_DICTIONARY:
		return _fail("frame_invalid")
	var frame: Dictionary = value
	if not _has_exact_fields(frame, FRAME_FIELDS):
		return _fail("frame_shape_invalid")
	if frame.get("schema_version") != SCHEMA_VERSION \
		or frame.get("protocol_version") != PROTOCOL_VERSION:
		return _fail("frame_version_invalid")
	if frame.get("episode_id") != episode_id:
		return _fail("wrong_episode")
	if frame.get("sender") != remote_role:
		return _fail("wrong_sender")
	if typeof(frame.get("sequence")) != TYPE_INT or int(frame.sequence) != _inbound_sequence:
		return _fail("sequence_violation")
	var message_type: Variant = frame.get("message_type")
	if typeof(message_type) != TYPE_STRING or not MESSAGE_BOUNDARY_KIND.has(message_type):
		return _fail("message_type_invalid")
	if message_type not in ALLOWED_BY_SENDER[remote_role]:
		return _fail("message_type_invalid")
	if message_type not in SENDER_MESSAGE_TYPES[remote_role]:
		return _fail("message_sender_invalid")
	if frame.get("boundary_hash_kind") != MESSAGE_BOUNDARY_KIND[message_type]:
		return _fail("boundary_kind_invalid")
	if not _is_sha256(frame.get("boundary_hash")):
		return _fail("boundary_hash_invalid")
	if message_type in ["hello", "auth"] and frame.boundary_hash != ZERO_HASH:
		return _fail("session_boundary_invalid")
	if typeof(frame.get("body")) != TYPE_DICTIONARY or not _canonical_value(frame.body):
		return _fail("body_invalid")
	if not _is_sha256(frame.get("auth_tag")):
		return _fail("authentication_failed")
	var unsigned := frame.duplicate(true)
	unsigned.erase("auth_tag")
	var expected := _tag(_keys[remote_role], unsigned)
	if not _constant_time_equal(str(frame.auth_tag), expected):
		return _fail("authentication_failed")
	_inbound_sequence += 1
	return {"ok": true, "frame": frame.duplicate(true), "code": ""}


func close() -> void:
	_closed = true
	for key: PackedByteArray in _keys.values():
		key.fill(0)
	_keys.clear()


func is_failed() -> bool:
	return _failed


static func parse_canonical(
	payload: PackedByteArray, maximum_bytes: int = MAX_FRAME_BYTES
) -> Dictionary:
	if payload.is_empty() or payload.size() > maximum_bytes:
		return {"ok": false, "code": "json_size_invalid"}
	var text := payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload:
		return {"ok": false, "code": "utf8_invalid"}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {"ok": false, "code": "json_invalid"}
	var restored: Variant = _restore_integers(parser.data)
	if not _canonical_value(restored) or canonical_bytes(restored) != payload:
		return {"ok": false, "code": "json_noncanonical"}
	return {"ok": true, "value": restored, "code": ""}


static func canonical_bytes(value: Variant) -> PackedByteArray:
	if not _canonical_value(value):
		return PackedByteArray()
	return canonical_json(value).to_utf8_buffer()


static func canonical_json(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_STRING:
			return JSON.stringify(value)
		TYPE_ARRAY:
			var items := PackedStringArray()
			for item: Variant in value:
				items.append(canonical_json(item))
			return "[" + ",".join(items) + "]"
		TYPE_DICTIONARY:
			var keys := PackedStringArray()
			for key: Variant in value:
				keys.append(str(key))
			keys.sort()
			var members := PackedStringArray()
			for key: String in keys:
				members.append(JSON.stringify(key) + ":" + canonical_json(value[key]))
			return "{" + ",".join(members) + "}"
	return ""


static func sha256_bytes(payload: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(payload)
	return context.finish().hex_encode()


static func _restore_integers(value: Variant) -> Variant:
	if typeof(value) == TYPE_FLOAT:
		if not is_finite(value) or value != floor(value) or abs(value) > MAX_SEQUENCE:
			return value
		return int(value)
	if value is Array:
		var output: Array = []
		for item: Variant in value:
			output.append(_restore_integers(item))
		return output
	if value is Dictionary:
		var output := {}
		for key: Variant in value:
			output[key] = _restore_integers(value[key])
		return output
	return value


static func _canonical_value(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return true
		TYPE_INT:
			return abs(value) <= MAX_SEQUENCE
		TYPE_ARRAY:
			for item: Variant in value:
				if not _canonical_value(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if typeof(key) != TYPE_STRING or not _canonical_value(value[key]):
					return false
			return true
	return false


static func _has_exact_fields(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or (value as String).length() != 64:
		return false
	var text: String = value
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


static func _valid_episode_id(value: String) -> bool:
	if not value.begins_with("ep_") or value.length() < 4 or value.length() > 123:
		return false
	for index: int in range(3, value.length()):
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 46, 95]):
			return false
	return true


func _tag(key: PackedByteArray, unsigned: Dictionary) -> String:
	var material := FRAME_DOMAIN.to_utf8_buffer()
	material.append_array(canonical_bytes(unsigned))
	return _hmac(key, material)


static func _hmac(key: PackedByteArray, material: PackedByteArray) -> String:
	var context := HMACContext.new()
	if context.start(HashingContext.HASH_SHA256, key) != OK:
		return ""
	if context.update(material) != OK:
		return ""
	return context.finish().hex_encode()


static func _constant_time_equal(left: String, right: String) -> bool:
	var left_bytes := left.to_utf8_buffer()
	var right_bytes := right.to_utf8_buffer()
	var difference := left_bytes.size() ^ right_bytes.size()
	var count := maxi(left_bytes.size(), right_bytes.size())
	for index: int in count:
		var left_byte := left_bytes[index] if index < left_bytes.size() else 0
		var right_byte := right_bytes[index] if index < right_bytes.size() else 0
		difference |= left_byte ^ right_byte
	return difference == 0


func _open() -> bool:
	return _configured and not _failed and not _closed


func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}


func _fail(code: String) -> Dictionary:
	_failed = true
	return _failure(code)
