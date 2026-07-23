class_name DuelManagedAuthorityCli
extends SceneTree

const Controller := preload("res://scripts/duel/duel_match_controller.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Live, provider-free authority bootstrap for a Python-owned match process.
## Exactly one bounded canonical envelope enters over an anonymous stdin pipe.
## No protected value is accepted through argv, environment variables, files,
## stdout, or stderr. The configured controller can only dial a loopback
## WebSocket and all model/provider work remains in Python.

const SCHEMA_VERSION := "worldeval-rts/managed-authority-launch/1.0.0"
const ENGINE_BUILD := "4.5.stable.official.876b29033"
const MAX_INPUT_BYTES := 4 * 1024 * 1024
const ROOT_FIELDS: Array[String] = ["launch", "schema_version"]
const LAUNCH_FIELDS: Array[String] = [
	"authority",
	"connection_id",
	"gateway_url",
	"match_id",
	"match_init",
	"protocol_hash",
	"token",
]
const AUTHORITY_FIELDS: Array[String] = [
	"alias_salt_seat_0",
	"alias_salt_seat_1",
	"authoritative_hashes",
	"scored",
	"tie_key",
]

var _controller: DuelMatchController = null
var _finished := false


func _init() -> void:
	## Defer until SceneTree.root is ready to own and process the live controller.
	_bootstrap.call_deferred()


func _bootstrap() -> void:
	if DisplayServer.get_name() != "headless" or AudioServer.get_driver_name() != "Dummy":
		_fail("duel_godot_environment_rejected")
		return
	if OS.get_stdin_type() not in [OS.STD_HANDLE_PIPE, OS.STD_HANDLE_UNKNOWN]:
		## Refuse consoles (which can block forever), ordinary files (which can persist
		## launch secrets), and invalid handles. Python's macOS asyncio subprocess
		## transport is an anonymous socketpair, which Godot classifies as UNKNOWN;
		## it has the same one-use, nonpersistent EOF semantics as an anonymous pipe.
		_fail("duel_godot_environment_rejected")
		return
	if _engine_identity() != ENGINE_BUILD:
		_fail("duel_godot_engine_mismatch")
		return

	var payload := OS.read_buffer_from_stdin(MAX_INPUT_BYTES + 1)
	if payload.is_empty() or payload.size() > MAX_INPUT_BYTES:
		_scrub_bytes(payload)
		_fail("duel_godot_bootstrap_input_rejected")
		return
	var parsed := _parse_envelope(payload)
	_scrub_bytes(payload)
	if not bool(parsed.get("ok", false)):
		_fail("duel_godot_bootstrap_input_rejected")
		return

	var launch: Dictionary = parsed["launch"]
	var match_id := str(launch.get("match_id", ""))
	_controller = Controller.new()
	_controller.match_failed.connect(_on_match_failed)
	_controller.match_closed.connect(_on_match_closed)
	root.add_child(_controller)
	var errors := _controller.configure_launch(launch)
	_scrub_launch(launch)
	if not errors.is_empty():
		_fail("duel_godot_controller_rejected")
		return
	errors = _controller.start_match()
	if not errors.is_empty():
		_fail("duel_godot_controller_start_failed")
		return
	_emit_control({
		"kind": "worldarena_duel_managed_started",
		"match_id": match_id,
		"schema_version": SCHEMA_VERSION,
	})


func _parse_envelope(payload: PackedByteArray) -> Dictionary:
	var text := payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload:
		return {"ok": false}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {"ok": false}
	var normalized := CatalogLoader.normalize_json_boundary(parser.data)
	if not bool(normalized.get("ok", false)):
		return {"ok": false}
	var root_value: Variant = normalized.get("value")
	if typeof(root_value) != TYPE_DICTIONARY or Codec.canonical_bytes(root_value) != payload:
		_scrub_variant(root_value)
		return {"ok": false}
	var envelope: Dictionary = root_value
	if not _has_exact_fields(envelope, ROOT_FIELDS) \
		or str(envelope.get("schema_version", "")) != SCHEMA_VERSION \
		or typeof(envelope.get("launch")) != TYPE_DICTIONARY:
		_scrub_variant(envelope)
		return {"ok": false}
	var converted := _convert_launch(envelope["launch"])
	_scrub_variant(envelope)
	if converted.is_empty():
		return {"ok": false}
	return {"launch": converted, "ok": true}


func _convert_launch(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	if not _has_exact_fields(source, LAUNCH_FIELDS) \
		or typeof(source.get("authority")) != TYPE_DICTIONARY \
		or typeof(source.get("match_init")) != TYPE_DICTIONARY:
		return {}
	var authority_source: Dictionary = source["authority"]
	if not _has_exact_fields(authority_source, AUTHORITY_FIELDS) \
		or typeof(authority_source.get("authoritative_hashes")) != TYPE_DICTIONARY \
		or typeof(authority_source.get("scored")) != TYPE_BOOL:
		return {}
	var session_token := _byte_array(source.get("token"), 32)
	var tie_key := _byte_array(authority_source.get("tie_key"), 32)
	var salt_zero := _byte_array(authority_source.get("alias_salt_seat_0"), 32)
	var salt_one := _byte_array(authority_source.get("alias_salt_seat_1"), 32)
	if session_token.size() != 32 or tie_key.size() != 32 \
		or salt_zero.size() != 32 or salt_one.size() != 32 or salt_zero == salt_one:
		_scrub_bytes(session_token)
		_scrub_bytes(tie_key)
		_scrub_bytes(salt_zero)
		_scrub_bytes(salt_one)
		return {}
	return {
		"authority": {
			"alias_salt_seat_0": salt_zero,
			"alias_salt_seat_1": salt_one,
			"authoritative_hashes": (
				authority_source["authoritative_hashes"] as Dictionary
			).duplicate(true),
			"scored": authority_source["scored"],
			"tie_key": tie_key,
		},
		"connection_id": str(source.get("connection_id", "")),
		"gateway_url": str(source.get("gateway_url", "")),
		"match_id": str(source.get("match_id", "")),
		"match_init": (source["match_init"] as Dictionary).duplicate(true),
		"protocol_hash": str(source.get("protocol_hash", "")),
		"token": session_token,
	}


func _on_match_failed(_code: String, _message: String) -> void:
	_fail("duel_godot_controller_runtime_failed")


func _on_match_closed() -> void:
	if _finished:
		return
	_finished = true
	quit(0)


func _fail(code: String) -> void:
	if _finished:
		return
	_finished = true
	_emit_control({
		"code": code,
		"kind": "worldarena_duel_managed_error",
		"schema_version": SCHEMA_VERSION,
	})
	quit(2)


func _emit_control(value: Dictionary) -> void:
	## Only fixed schema/code/match identity fields reach the parent pipe. Never
	## interpolate parser, controller, transport, or launch payload diagnostics.
	print(Codec.canonical_json(value))


static func _byte_array(value: Variant, exact_size: int) -> PackedByteArray:
	var output := PackedByteArray()
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != exact_size:
		return output
	output.resize(exact_size)
	for index: int in exact_size:
		var item: Variant = (value as Array)[index]
		if typeof(item) != TYPE_INT or int(item) < 0 or int(item) > 255:
			_scrub_bytes(output)
			return PackedByteArray()
		output[index] = int(item)
	return output


static func _has_exact_fields(value: Dictionary, fields: Array[String]) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	for key_variant: Variant in value.keys():
		if typeof(key_variant) != TYPE_STRING or str(key_variant) not in fields:
			return false
	return true


static func _engine_identity() -> String:
	var value: Dictionary = Engine.get_version_info()
	return "%d.%d.%s.%s.%s" % [
		int(value.get("major", -1)),
		int(value.get("minor", -1)),
		str(value.get("status", "")),
		str(value.get("build", "")),
		str(value.get("hash", "")).substr(0, 9),
	]


static func _scrub_launch(launch: Dictionary) -> void:
	var token: Variant = launch.get("token")
	_scrub_variant(token)
	var authority: Variant = launch.get("authority")
	_scrub_variant(authority)
	launch.clear()


static func _scrub_variant(value: Variant) -> void:
	if typeof(value) == TYPE_PACKED_BYTE_ARRAY:
		var bytes: PackedByteArray = value
		_scrub_bytes(bytes)
	elif typeof(value) == TYPE_ARRAY:
		var array: Array = value
		for item: Variant in array:
			_scrub_variant(item)
		for index: int in array.size():
			array[index] = 0
		array.clear()
	elif typeof(value) == TYPE_DICTIONARY:
		var dictionary: Dictionary = value
		for item: Variant in dictionary.values():
			_scrub_variant(item)
		dictionary.clear()


static func _scrub_bytes(value: PackedByteArray) -> void:
	if not value.is_empty():
		value.fill(0)
		value.clear()
