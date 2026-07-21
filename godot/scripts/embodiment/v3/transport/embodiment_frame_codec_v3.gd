class_name EmbodimentFrameCodecV3
extends RefCounted

const CanonicalCodec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const SCHEMA_VERSION := "llm-controller/transport-frame/1.0.0"
const PROTOCOL_VERSION := "llm-controller/0.3.0"
const MAX_FRAME_BYTES := CanonicalCodec.MAX_FRAME_BYTES
const MAX_SEQUENCE := CanonicalCodec.MAX_SEQUENCE
const ZERO_HASH := CanonicalCodec.ZERO_HASH
const KEY_DOMAIN := CanonicalCodec.KEY_DOMAIN
const FRAME_DOMAIN := CanonicalCodec.FRAME_DOMAIN
const FRAME_FIELDS := CanonicalCodec.FRAME_FIELDS
const MESSAGE_BOUNDARY_KIND := CanonicalCodec.MESSAGE_BOUNDARY_KIND
const ALLOWED_BY_SENDER := CanonicalCodec.ALLOWED_BY_SENDER
const SENDER_MESSAGE_TYPES := CanonicalCodec.SENDER_MESSAGE_TYPES

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
	if not CanonicalCodec._valid_episode_id(configured_episode_id):
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
		_keys[key_role] = CanonicalCodec._hmac(secret, material).hex_decode()
	_configured = true
	return errors


func encode(message_type: String, boundary_hash: String, body: Dictionary) -> Dictionary:
	if not _open():
		return _failure("codec_not_open")
	if not MESSAGE_BOUNDARY_KIND.has(message_type) \
		or message_type not in ALLOWED_BY_SENDER[local_role] \
		or message_type not in SENDER_MESSAGE_TYPES[local_role]:
		return _fail("message_type_invalid")
	if not CanonicalCodec._is_sha256(boundary_hash):
		return _fail("boundary_hash_invalid")
	if message_type in ["hello", "auth"] and boundary_hash != ZERO_HASH:
		return _fail("session_boundary_invalid")
	if not CanonicalCodec._canonical_value(body):
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
	var payload := CanonicalCodec.canonical_bytes(frame)
	if payload.is_empty() or payload.size() > MAX_FRAME_BYTES:
		return _fail("frame_size_invalid")
	_outbound_sequence += 1
	return {"ok": true, "payload": payload, "frame": frame, "code": ""}


func decode(payload: PackedByteArray) -> Dictionary:
	if not _open():
		return _failure("codec_not_open")
	if payload.is_empty() or payload.size() > MAX_FRAME_BYTES:
		return _fail("frame_size_invalid")
	var parsed := CanonicalCodec.parse_canonical(payload)
	if not bool(parsed.get("ok", false)) or typeof(parsed.get("value")) != TYPE_DICTIONARY:
		return _fail(str(parsed.get("code", "frame_invalid")))
	var frame: Dictionary = parsed.value
	if not CanonicalCodec._has_exact_fields(frame, FRAME_FIELDS):
		return _fail("frame_shape_invalid")
	if frame.get("schema_version") != SCHEMA_VERSION or frame.get("protocol_version") != PROTOCOL_VERSION:
		return _fail("frame_version_invalid")
	if frame.get("episode_id") != episode_id or frame.get("sender") != remote_role:
		return _fail("wrong_session_identity")
	if typeof(frame.get("sequence")) != TYPE_INT or frame.sequence != _inbound_sequence:
		return _fail("sequence_violation")
	var message_type: Variant = frame.get("message_type")
	if typeof(message_type) != TYPE_STRING or not MESSAGE_BOUNDARY_KIND.has(message_type) \
		or message_type not in ALLOWED_BY_SENDER[remote_role] \
		or message_type not in SENDER_MESSAGE_TYPES[remote_role]:
		return _fail("message_type_invalid")
	if frame.get("boundary_hash_kind") != MESSAGE_BOUNDARY_KIND[message_type]:
		return _fail("boundary_kind_invalid")
	if not CanonicalCodec._is_sha256(frame.get("boundary_hash")):
		return _fail("boundary_hash_invalid")
	if message_type in ["hello", "auth"] and frame.boundary_hash != ZERO_HASH:
		return _fail("session_boundary_invalid")
	if typeof(frame.get("body")) != TYPE_DICTIONARY \
		or not CanonicalCodec._canonical_value(frame.body) \
		or not CanonicalCodec._is_sha256(frame.get("auth_tag")):
		return _fail("frame_body_invalid")
	var unsigned := frame.duplicate(true)
	unsigned.erase("auth_tag")
	if not CanonicalCodec._constant_time_equal(str(frame.auth_tag), _tag(_keys[remote_role], unsigned)):
		return _fail("authentication_failed")
	_inbound_sequence += 1
	return {"ok": true, "frame": frame.duplicate(true), "code": ""}


func close() -> void:
	_closed = true
	for key: PackedByteArray in _keys.values():
		key.fill(0)
	_keys.clear()


func _tag(key: PackedByteArray, unsigned: Dictionary) -> String:
	var material := FRAME_DOMAIN.to_utf8_buffer()
	material.append_array(CanonicalCodec.canonical_bytes(unsigned))
	return CanonicalCodec._hmac(key, material)


func _open() -> bool:
	return _configured and not _failed and not _closed


func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}


func _fail(code: String) -> Dictionary:
	_failed = true
	return _failure(code)
