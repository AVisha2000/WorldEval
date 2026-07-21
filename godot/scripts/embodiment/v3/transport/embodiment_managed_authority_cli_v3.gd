class_name EmbodimentManagedAuthorityCliV3
extends SceneTree

const CanonicalCodec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Host := preload("res://scripts/embodiment/v3/transport/embodiment_managed_session_host_v3.gd")
const GatewayClient := preload("res://scripts/embodiment/transport/embodiment_gateway_client.gd")
const ProtocolIdentity := preload("res://scripts/embodiment/v3/protocol/embodiment_protocol_package_identity_v3.gd")
const Dispatcher := preload("res://scripts/embodiment/v3/transport/trio_game_dispatcher_v3.gd")
const ParticipantScene := preload(
	"res://scripts/embodiment/presentation/v3/trio_participant_scene_v3.gd"
)
const ParticipantFrameAdapter := preload(
	"res://scripts/embodiment/presentation/v3/trio_game_participant_frame_adapter_v3.gd"
)
const PreviewPublisher := preload(
	"res://scripts/embodiment/presentation/preview/embodiment_preview_publisher.gd"
)

const SCHEMA_VERSION := "llm-controller/managed-authority-launch/1.0.0"
const ENGINE_BUILD := "4.5.stable.official.876b29033"
const MAX_INPUT_BYTES := 65_536
const ROOT_FIELDS := ["schema_version", "launch"]
const LAUNCH_FIELDS := [
	"attachment_ticket", "config", "config_sha256", "connection_id", "episode_id",
	"gateway_url", "protocol_package_sha256", "session_secret",
]

var _client = null
var _host = null
var _finished := false
var _presentation_viewports: Dictionary = {}
var _participant_scenes: Dictionary = {}
var _preview_publishers := {}


func _init() -> void:
	_bootstrap.call_deferred()


func _bootstrap() -> void:
	if _engine_identity() != ENGINE_BUILD \
		or OS.get_stdin_type() not in [OS.STD_HANDLE_PIPE, OS.STD_HANDLE_UNKNOWN]:
		_fail("embodiment_v3_environment_rejected")
		return
	var payload := OS.read_buffer_from_stdin(MAX_INPUT_BYTES + 1)
	if payload.is_empty() or payload.size() > MAX_INPUT_BYTES:
		_scrub_bytes(payload)
		_fail("embodiment_v3_bootstrap_input_rejected")
		return
	var parsed := _parse_envelope(payload)
	_scrub_bytes(payload)
	if not bool(parsed.get("ok", false)):
		_fail("embodiment_v3_bootstrap_input_rejected")
		return
	var launch: Dictionary = parsed.launch
	var secret: PackedByteArray = launch.session_secret
	var hybrid := str(launch.config.observation_profile) == "hybrid-visible-v1"
	if hybrid == (DisplayServer.get_name() == "headless"):
		_scrub_bytes(secret)
		_scrub_variant(launch)
		_fail("embodiment_v3_environment_rejected")
		return
	var frame_adapter = null
	if hybrid:
		for participant_id: String in launch.config.participant_ids:
			var viewport := SubViewport.new()
			viewport.name = "TrioGameViewport_%s" % participant_id
			viewport.size = Vector2i(1280, 720)
			viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			viewport.transparent_bg = false
			root.add_child(viewport)
			var participant_scene := ParticipantScene.new()
			viewport.add_child(participant_scene)
			if not participant_scene.configure_task(
				str(launch.config.task_id), participant_id, "", int(launch.config.seat_rotation)
			):
				_scrub_bytes(secret)
				_scrub_variant(launch)
				_fail("embodiment_v3_presentation_rejected")
				return
			_presentation_viewports[participant_id] = viewport
			_participant_scenes[participant_id] = participant_scene
		frame_adapter = ParticipantFrameAdapter.new(_participant_scenes, _presentation_viewports)
	_host = Host.new()
	var errors: PackedStringArray = _host.configure(launch, secret, frame_adapter)
	if errors.is_empty() and hybrid:
		for participant_id: String in launch.config.participant_ids:
			var preview_ticket := _derive_trio_preview_ticket(
				secret, str(launch.attachment_ticket), participant_id
			)
			var preview_publisher = PreviewPublisher.new()
			root.add_child(preview_publisher)
			var preview_errors: PackedStringArray = preview_publisher.configure(
				str(launch.gateway_url), preview_ticket, str(launch.episode_id), secret,
				_presentation_viewports[participant_id], _participant_scenes[participant_id],
				participant_id,
			)
			if preview_errors.is_empty():
				_preview_publishers[participant_id] = preview_publisher
			else:
				preview_publisher.close()
				preview_publisher.queue_free()
	_scrub_bytes(secret)
	launch.erase("session_secret")
	if not errors.is_empty():
		_scrub_variant(launch)
		_fail("embodiment_v3_host_rejected")
		return
	_client = GatewayClient.new()
	_client.managed_failed.connect(_on_failed)
	_client.managed_closed.connect(_on_closed)
	root.add_child(_client)
	errors = _client.configure(str(launch.gateway_url), _host)
	var episode_id := str(launch.episode_id)
	_scrub_variant(launch)
	if not errors.is_empty() or not _client.connect_once().is_empty():
		_fail("embodiment_v3_transport_rejected")
		return
	_emit_control({"episode_id": episode_id, "kind": "embodiment_managed_v3_started", "schema_version": SCHEMA_VERSION})


func _parse_envelope(payload: PackedByteArray) -> Dictionary:
	var parsed := CanonicalCodec.parse_canonical(payload, MAX_INPUT_BYTES)
	if not bool(parsed.get("ok", false)) or typeof(parsed.get("value")) != TYPE_DICTIONARY:
		return {"ok": false}
	var envelope: Dictionary = parsed.value
	if not CanonicalCodec._has_exact_fields(envelope, ROOT_FIELDS) \
		or envelope.schema_version != SCHEMA_VERSION or not envelope.launch is Dictionary:
		_scrub_variant(envelope)
		return {"ok": false}
	var launch: Dictionary = envelope.launch
	if not CanonicalCodec._has_exact_fields(launch, LAUNCH_FIELDS):
		_scrub_variant(envelope)
		return {"ok": false}
	var secret := _byte_array(launch.session_secret, 32)
	var dispatcher := Dispatcher.new()
	var config_valid := launch.config is Dictionary \
		and dispatcher.configure(launch.config).is_empty()
	if secret.size() != 32 or not config_valid \
		or launch.episode_id != launch.config.get("episode_id") \
		or launch.protocol_package_sha256 != ProtocolIdentity.SHA256 \
		or not CanonicalCodec._is_sha256(launch.config_sha256) \
		or CanonicalCodec.sha256_bytes(CanonicalCodec.canonical_bytes(launch.config)) != launch.config_sha256 \
		or not Host._ascii_token(str(launch.attachment_ticket), 43, 43) \
		or not Host._ascii_token(str(launch.connection_id), 1, 128) \
		or not _valid_gateway(str(launch.gateway_url), str(launch.attachment_ticket)):
		_scrub_bytes(secret)
		_scrub_variant(envelope)
		return {"ok": false}
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
	_fail("embodiment_v3_runtime_failed")


func _on_closed() -> void:
	if not _finished:
		_finished = true
		_close_preview()
		quit(0)


func _fail(code: String) -> void:
	if _finished:
		return
	_finished = true
	_close_preview()
	_emit_control({"code": code, "kind": "embodiment_managed_v3_error", "schema_version": SCHEMA_VERSION})
	quit(2)


func _close_preview() -> void:
	for preview_publisher: Variant in _preview_publishers.values():
		preview_publisher.close()
		preview_publisher.queue_free()
	_preview_publishers.clear()


static func _derive_trio_preview_ticket(
		session_secret: PackedByteArray, attachment_ticket: String, participant_id: String
) -> String:
	if session_secret.size() != 32 \
		or participant_id not in ["participant_0", "participant_1", "participant_2"]:
		return ""
	var material := "llm-controller/trio-preview-ticket/v1\u0000".to_utf8_buffer()
	material.append_array(attachment_ticket.to_utf8_buffer())
	material.append(0)
	material.append_array(participant_id.to_utf8_buffer())
	var context := HMACContext.new()
	if context.start(HashingContext.HASH_SHA256, session_secret) != OK \
		or context.update(material) != OK:
		material.fill(0)
		return ""
	var digest := context.finish()
	material.fill(0)
	if digest.size() != 32:
		return ""
	return Marshalls.raw_to_base64(digest).replace("+", "-").replace("/", "_").trim_suffix("=")


func _emit_control(value: Dictionary) -> void:
	print(CanonicalCodec.canonical_json(value))


static func _byte_array(value: Variant, expected_size: int) -> PackedByteArray:
	var output := PackedByteArray()
	if not value is Array or value.size() != expected_size:
		return output
	output.resize(expected_size)
	for index: int in expected_size:
		if typeof(value[index]) != TYPE_INT or value[index] < 0 or value[index] > 255:
			_scrub_bytes(output)
			return PackedByteArray()
		output[index] = value[index]
	return output


static func _valid_gateway(url: String, ticket: String) -> bool:
	if not GatewayClient.is_loopback_websocket_url(url):
		return false
	var regex := RegEx.new()
	return regex.compile(
		"^ws://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]{1,5}/ws/embodiment/" + ticket + "$"
	) == OK and regex.search(url) != null


static func _engine_identity() -> String:
	var value := Engine.get_version_info()
	return "%d.%d.%s.%s.%s" % [
		int(value.get("major", -1)), int(value.get("minor", -1)), str(value.get("status", "")),
		str(value.get("build", "")), str(value.get("hash", "")).substr(0, 9),
	]


static func _scrub_variant(value: Variant) -> void:
	if value is PackedByteArray:
		_scrub_bytes(value)
	elif value is Array:
		for item: Variant in value:
			_scrub_variant(item)
		value.fill(0)
		value.clear()
	elif value is Dictionary:
		for item: Variant in value.values():
			_scrub_variant(item)
		value.clear()


static func _scrub_bytes(value: PackedByteArray) -> void:
	if not value.is_empty():
		value.fill(0)
		value.clear()
