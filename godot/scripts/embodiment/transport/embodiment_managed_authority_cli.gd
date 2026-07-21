class_name EmbodimentManagedAuthorityCli
extends SceneTree

const FrameCodec := preload(
	"res://scripts/embodiment/transport/embodiment_frame_codec.gd"
)
const SessionHost := preload(
	"res://scripts/embodiment/transport/embodiment_managed_session_host.gd"
)
const GatewayClient := preload(
	"res://scripts/embodiment/transport/embodiment_gateway_client.gd"
)
const ProtocolPackageIdentity := preload(
	"res://scripts/embodiment/protocol/embodiment_protocol_package_identity.gd"
)
const PresentationScene := preload(
	"res://scenes/embodiment/embodiment_presentation_scene.tscn"
)

const SCHEMA_VERSION := "llm-controller/managed-authority-launch/1.0.0"
const ENGINE_BUILD := "4.5.stable.official.876b29033"
const PROTOCOL_PACKAGE_SHA256 := ProtocolPackageIdentity.SHA256
const MAX_INPUT_BYTES := 65_536
const ROOT_FIELDS := ["schema_version", "launch"]
const LAUNCH_FIELDS := [
	"attachment_ticket", "config", "config_sha256", "connection_id", "episode_id",
	"gateway_url", "protocol_package_sha256", "session_secret",
]
const CONFIG_FIELDS := [
	"protocol_version", "episode_id", "mode", "task_id", "seed", "observation_profile",
	"timing_track", "maximum_episode_ticks", "participant_ids",
]

var _client = null
var _host = null
var _finished := false
var _presentation_viewport: SubViewport = null


func _init() -> void:
	_bootstrap.call_deferred()


func _bootstrap() -> void:
	if DisplayServer.get_name() not in ["headless", "macos", "macOS"] \
		or AudioServer.get_driver_name() != "Dummy" \
		or OS.get_stdin_type() not in [OS.STD_HANDLE_PIPE, OS.STD_HANDLE_UNKNOWN]:
		_fail("embodiment_godot_environment_rejected")
		return
	if _engine_identity() != ENGINE_BUILD:
		_fail("embodiment_godot_engine_mismatch")
		return
	var payload := OS.read_buffer_from_stdin(MAX_INPUT_BYTES + 1)
	if payload.is_empty() or payload.size() > MAX_INPUT_BYTES:
		_scrub_bytes(payload)
		_fail("embodiment_godot_bootstrap_input_rejected")
		return
	var parsed := _parse_envelope(payload)
	_scrub_bytes(payload)
	if not bool(parsed.get("ok", false)):
		_fail("embodiment_godot_bootstrap_input_rejected")
		return
	var launch: Dictionary = parsed.launch
	var episode_id := str(launch.episode_id)
	var hybrid := str(launch.config.observation_profile) == "hybrid-visible-v1"
	if hybrid == (DisplayServer.get_name() == "headless"):
		_scrub_launch(launch)
		_fail("embodiment_godot_environment_rejected")
		return
	var secret: PackedByteArray = launch.session_secret
	var presentation_scene: Node = null
	if hybrid:
		_presentation_viewport = SubViewport.new()
		_presentation_viewport.name = "ParticipantPresentationViewport"
		_presentation_viewport.size = Vector2i(1280, 720)
		_presentation_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_presentation_viewport.transparent_bg = false
		root.add_child(_presentation_viewport)
		presentation_scene = PresentationScene.instantiate()
		_presentation_viewport.add_child(presentation_scene)
	_host = SessionHost.new()
	var errors: PackedStringArray = _host.configure(
		launch, secret, presentation_scene, _presentation_viewport
	)
	_scrub_bytes(secret)
	launch.erase("session_secret")
	if not errors.is_empty():
		_scrub_launch(launch)
		_fail("embodiment_godot_host_rejected")
		return
	_client = GatewayClient.new()
	_client.managed_failed.connect(_on_failed)
	_client.managed_closed.connect(_on_closed)
	root.add_child(_client)
	errors = _client.configure(str(launch.gateway_url), _host)
	_scrub_launch(launch)
	if not errors.is_empty():
		_fail("embodiment_godot_transport_rejected")
		return
	errors = _client.connect_once()
	if not errors.is_empty():
		_fail("embodiment_godot_transport_start_failed")
		return
	_emit_control({
		"episode_id": episode_id,
		"kind": "embodiment_managed_started",
		"schema_version": SCHEMA_VERSION,
	})


func _parse_envelope(payload: PackedByteArray) -> Dictionary:
	var parsed := FrameCodec.parse_canonical(payload)
	if not bool(parsed.get("ok", false)) or typeof(parsed.get("value")) != TYPE_DICTIONARY:
		return {"ok": false}
	var envelope: Dictionary = parsed.value
	if not _has_exact_fields(envelope, ROOT_FIELDS) or envelope.schema_version != SCHEMA_VERSION \
		or typeof(envelope.launch) != TYPE_DICTIONARY:
		_scrub_variant(envelope)
		return {"ok": false}
	var launch: Dictionary = envelope.launch
	if not _has_exact_fields(launch, LAUNCH_FIELDS):
		_scrub_variant(envelope)
		return {"ok": false}
	var secret := _byte_array(launch.session_secret, 32)
	var config: Variant = launch.config
	if secret.size() != 32 or typeof(config) != TYPE_DICTIONARY \
		or not _valid_config(config) \
		or launch.episode_id != config.get("episode_id") \
		or not FrameCodec._valid_episode_id(str(launch.episode_id)) \
		or not FrameCodec._is_sha256(launch.config_sha256) \
		or launch.protocol_package_sha256 != PROTOCOL_PACKAGE_SHA256 \
		or FrameCodec.sha256_bytes(FrameCodec.canonical_bytes(config)) != launch.config_sha256 \
		or not _valid_ticket(str(launch.attachment_ticket)) \
		or not _valid_gateway(str(launch.gateway_url), str(launch.attachment_ticket)):
		_scrub_bytes(secret)
		_scrub_variant(envelope)
		return {"ok": false}
	## Construct explicitly so the JSON session-secret array is never duplicated into a second
	## unmanaged Variant before the mutable byte form is handed to the frame codec.
	var converted := {
		"attachment_ticket": str(launch.attachment_ticket),
		"config": (launch.config as Dictionary).duplicate(true),
		"config_sha256": str(launch.config_sha256),
		"connection_id": str(launch.connection_id),
		"episode_id": str(launch.episode_id),
		"gateway_url": str(launch.gateway_url),
		"protocol_package_sha256": str(launch.protocol_package_sha256),
		"session_secret": secret,
	}
	_scrub_variant(envelope)
	return {"ok": true, "launch": converted}


func _on_failed(_code: String) -> void:
	_fail("embodiment_godot_runtime_failed")


func _on_closed() -> void:
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
		"kind": "embodiment_managed_error",
		"schema_version": SCHEMA_VERSION,
	})
	quit(2)


func _emit_control(value: Dictionary) -> void:
	print(FrameCodec.canonical_json(value))


static func _byte_array(value: Variant, expected_size: int) -> PackedByteArray:
	var output := PackedByteArray()
	if typeof(value) != TYPE_ARRAY or value.size() != expected_size:
		return output
	output.resize(expected_size)
	for index: int in expected_size:
		var item: Variant = value[index]
		if typeof(item) != TYPE_INT or item < 0 or item > 255:
			_scrub_bytes(output)
			return PackedByteArray()
		output[index] = item
	return output


static func _has_exact_fields(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func _valid_config(config: Dictionary) -> bool:
	if not _has_exact_fields(config, CONFIG_FIELDS):
		return false
	var expected_participants := (
		["participant_0", "participant_1"]
		if config.get("mode") in ["scripted-duel-v0", "model-duel-v0"]
		else ["participant_0"]
	)
	return config.protocol_version == FrameCodec.PROTOCOL_VERSION \
		and typeof(config.seed) == TYPE_INT and config.seed >= 0 \
		and typeof(config.maximum_episode_ticks) == TYPE_INT \
		and config.maximum_episode_ticks >= 1 and config.maximum_episode_ticks <= 18_000 \
		and config.timing_track == "step-locked-v1" \
		and typeof(config.participant_ids) == TYPE_ARRAY \
		and config.participant_ids == expected_participants \
		and typeof(config.mode) == TYPE_STRING and typeof(config.task_id) == TYPE_STRING \
		and typeof(config.observation_profile) == TYPE_STRING


static func _valid_ticket(ticket: String) -> bool:
	if ticket.length() != 43:
		return false
	for index: int in ticket.length():
		var code := ticket.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 95]):
			return false
	return true


static func _valid_gateway(url: String, ticket: String) -> bool:
	if not GatewayClient.is_loopback_websocket_url(url):
		return false
	var regex := RegEx.new()
	if regex.compile(
		"^ws://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]{1,5}/ws/embodiment/" \
		+ ticket + "$"
	) != OK:
		return false
	return regex.search(url) != null


static func _engine_identity() -> String:
	var value := Engine.get_version_info()
	return "%d.%d.%s.%s.%s" % [
		int(value.get("major", -1)), int(value.get("minor", -1)),
		str(value.get("status", "")), str(value.get("build", "")),
		str(value.get("hash", "")).substr(0, 9),
	]


static func _scrub_launch(launch: Dictionary) -> void:
	_scrub_variant(launch)


static func _scrub_variant(value: Variant) -> void:
	if typeof(value) == TYPE_PACKED_BYTE_ARRAY:
		_scrub_bytes(value)
	elif typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			_scrub_variant(item)
		value.fill(0)
		value.clear()
	elif typeof(value) == TYPE_DICTIONARY:
		for item: Variant in value.values():
			_scrub_variant(item)
		value.clear()


static func _scrub_bytes(value: PackedByteArray) -> void:
	if not value.is_empty():
		value.fill(0)
		value.clear()
