class_name EmbodimentManagedAuthorityCliV2
extends SceneTree

const CanonicalCodec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Host := preload("res://scripts/embodiment/v2/transport/embodiment_managed_session_host_v2.gd")
const GatewayClient := preload("res://scripts/embodiment/transport/embodiment_gateway_client.gd")
const ProtocolIdentity := preload("res://scripts/embodiment/v2/protocol/embodiment_protocol_package_identity_v2.gd")
const Dispatcher := preload("res://scripts/embodiment/v2/transport/control_game_dispatcher_v2.gd")
const ParticipantScene := preload(
	"res://scripts/embodiment/presentation/v2/control_game_participant_scene_v2.gd"
)
const ParticipantFrameAdapter := preload(
	"res://scripts/embodiment/presentation/v2/control_game_participant_frame_adapter_v2.gd"
)
const RtsParticipantScene := preload(
	"res://scripts/embodiment/presentation/rts/rts_skirmish_participant_scene.gd"
)
const RtsParticipantFrameAdapter := preload(
	"res://scripts/embodiment/presentation/rts/rts_skirmish_participant_frame_adapter.gd"
)
const RtsBroadcastScene := preload(
	"res://scripts/embodiment/presentation/rts/rts_skirmish_broadcast_scene.gd"
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
const OPTIONAL_PRESENTATION_ENTRANT_IDS := "presentation_entrant_ids"
const OPTIONAL_PRESENTATION_BROADCAST_TICKET := "presentation_broadcast_ticket"

var _client = null
var _host = null
var _finished := false
var _presentation_viewports: Dictionary = {}
var _participant_scenes: Dictionary = {}
var _preview_publisher = null
var _broadcast_preview_publisher = null
var _broadcast_viewport: SubViewport = null
var _broadcast_scene: Node = null


func _init() -> void:
	_bootstrap.call_deferred()


func _bootstrap() -> void:
	if _engine_identity() != ENGINE_BUILD \
		or OS.get_stdin_type() not in [OS.STD_HANDLE_PIPE, OS.STD_HANDLE_UNKNOWN]:
		_fail("embodiment_v2_environment_rejected")
		return
	var payload := OS.read_buffer_from_stdin(MAX_INPUT_BYTES + 1)
	if payload.is_empty() or payload.size() > MAX_INPUT_BYTES:
		_scrub_bytes(payload)
		_fail("embodiment_v2_bootstrap_input_rejected")
		return
	var parsed := _parse_envelope(payload)
	_scrub_bytes(payload)
	if not bool(parsed.get("ok", false)):
		_fail("embodiment_v2_bootstrap_input_rejected")
		return
	var launch: Dictionary = parsed.launch
	var secret: PackedByteArray = launch.session_secret
	var presentation_entrant_ids: Dictionary = launch.presentation_entrant_ids
	var presentation_broadcast_ticket := str(launch.presentation_broadcast_ticket)
	var hybrid := str(launch.config.observation_profile) == "hybrid-visible-v1"
	if hybrid == (DisplayServer.get_name() == "headless"):
		_scrub_bytes(secret)
		_scrub_variant(launch)
		_fail("embodiment_v2_environment_rejected")
		return
	var is_rts_skirmish := str(launch.config.task_id) in ["rts-skirmish-v0", "rts-skirmish-v1"]
	var frame_adapter = null
	if hybrid:
		for participant_id: String in launch.config.participant_ids:
			var viewport := SubViewport.new()
			viewport.name = "ControlGameViewport_%s" % participant_id
			viewport.size = Vector2i(1280, 720)
			viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			viewport.transparent_bg = false
			root.add_child(viewport)
			var participant_scene: Node
			var presentation_ok: bool
			if is_rts_skirmish:
				var rts_scene := RtsParticipantScene.new()
				viewport.add_child(rts_scene)
				participant_scene = rts_scene
				var rts_team := "blue" if participant_id == "participant_0" else "red"
				presentation_ok = rts_scene.configure_participant(participant_id, rts_team)
			else:
				var control_scene := ParticipantScene.new()
				viewport.add_child(control_scene)
				participant_scene = control_scene
				presentation_ok = control_scene.configure_task(
					str(launch.config.task_id), participant_id,
					str(presentation_entrant_ids.get(
						participant_id, _duo_entrant_for_seat(str(launch.config.episode_id), participant_id)
					)))
			if not presentation_ok:
				_scrub_bytes(secret)
				_scrub_variant(launch)
				_fail("embodiment_v2_presentation_rejected")
				return
			_presentation_viewports[participant_id] = viewport
			_participant_scenes[participant_id] = participant_scene
		frame_adapter = RtsParticipantFrameAdapter.new(_participant_scenes, _presentation_viewports) if is_rts_skirmish else ParticipantFrameAdapter.new(_participant_scenes, _presentation_viewports)
		if is_rts_skirmish and not presentation_broadcast_ticket.is_empty():
			_broadcast_viewport = SubViewport.new()
			_broadcast_viewport.name = "RtsPublicBroadcastViewport"
			_broadcast_viewport.size = Vector2i(1280, 720)
			_broadcast_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			_broadcast_viewport.transparent_bg = false
			root.add_child(_broadcast_viewport)
			_broadcast_scene = RtsBroadcastScene.new()
			_broadcast_viewport.add_child(_broadcast_scene)
			if not frame_adapter.set_broadcast_scene(_broadcast_scene):
				_scrub_bytes(secret)
				_scrub_variant(launch)
				_fail("embodiment_v2_broadcast_rejected")
				return
	_host = Host.new()
	var errors: PackedStringArray = _host.configure(launch, secret, frame_adapter)
	if errors.is_empty() and hybrid:
		_preview_publisher = PreviewPublisher.new()
		root.add_child(_preview_publisher)
		var preview_errors: PackedStringArray = _preview_publisher.configure(
			str(launch.gateway_url), str(launch.attachment_ticket), str(launch.episode_id),
			secret, _presentation_viewports.participant_0, _participant_scenes.participant_0,
			"participant_0",
		)
		if not preview_errors.is_empty():
			_preview_publisher.close()
			_preview_publisher.queue_free()
			_preview_publisher = null
		if is_rts_skirmish and not presentation_broadcast_ticket.is_empty() \
				and _broadcast_viewport != null and _broadcast_scene != null:
			_broadcast_preview_publisher = PreviewPublisher.new()
			root.add_child(_broadcast_preview_publisher)
			var broadcast_errors: PackedStringArray = _broadcast_preview_publisher.configure(
				str(launch.gateway_url), presentation_broadcast_ticket, str(launch.episode_id),
				secret, _broadcast_viewport, _broadcast_scene, "broadcast",
			)
			if not broadcast_errors.is_empty():
				_broadcast_preview_publisher.close()
				_broadcast_preview_publisher.queue_free()
				_broadcast_preview_publisher = null
	_scrub_bytes(secret)
	launch.erase("session_secret")
	if not errors.is_empty():
		_scrub_variant(launch)
		_fail("embodiment_v2_host_rejected")
		return
	_client = GatewayClient.new()
	_client.managed_failed.connect(_on_failed)
	_client.managed_closed.connect(_on_closed)
	root.add_child(_client)
	errors = _client.configure(str(launch.gateway_url), _host)
	var episode_id := str(launch.episode_id)
	_scrub_variant(launch)
	if not errors.is_empty() or not _client.connect_once().is_empty():
		_fail("embodiment_v2_transport_rejected")
		return
	_emit_control({"episode_id": episode_id, "kind": "embodiment_managed_v2_started", "schema_version": SCHEMA_VERSION})


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
	if not _valid_launch_fields(launch):
		_scrub_variant(envelope)
		return {"ok": false}
	var presentation_entrant_ids := _presentation_entrant_ids(launch.get(
		OPTIONAL_PRESENTATION_ENTRANT_IDS, {}
	))
	if presentation_entrant_ids.is_empty() and launch.has(OPTIONAL_PRESENTATION_ENTRANT_IDS):
		_scrub_variant(envelope)
		return {"ok": false}
	var presentation_broadcast_ticket := _broadcast_ticket(launch.get(
		OPTIONAL_PRESENTATION_BROADCAST_TICKET, ""), str(launch.config.get("task_id", ""))
	)
	if presentation_broadcast_ticket.is_empty() and launch.has(OPTIONAL_PRESENTATION_BROADCAST_TICKET):
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
		"presentation_entrant_ids": presentation_entrant_ids,
		"presentation_broadcast_ticket": presentation_broadcast_ticket,
		"session_secret": secret,
	}
	_scrub_variant(envelope)
	return {"ok": true, "launch": converted}


func _on_failed(_code: String) -> void:
	_fail("embodiment_v2_runtime_failed")


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
	_emit_control({"code": code, "kind": "embodiment_managed_v2_error", "schema_version": SCHEMA_VERSION})
	quit(2)


func _close_preview() -> void:
	if _preview_publisher != null:
		_preview_publisher.close()
		_preview_publisher.queue_free()
		_preview_publisher = null
	if _broadcast_preview_publisher != null:
		_broadcast_preview_publisher.close()
		_broadcast_preview_publisher.queue_free()
		_broadcast_preview_publisher = null
	_broadcast_scene = null
	_broadcast_viewport = null


static func _duo_entrant_for_seat(episode_id: String, participant_id: String) -> String:
	# Paired Demo series reserve public episode suffixes `_a` and `_b` for their two swapped
	# legs.  This makes the avatar palette follow Alpha/Bravo rather than participant seat while
	# staying entirely outside the immutable authority config and player observation.
	if participant_id not in ["participant_0", "participant_1"]:
		return ""
	var swapped := episode_id.ends_with("_b")
	if participant_id == "participant_0":
		return "bravo" if swapped else "alpha"
	return "alpha" if swapped else "bravo"


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


static func _valid_launch_fields(launch: Dictionary) -> bool:
	for field: String in LAUNCH_FIELDS:
		if not launch.has(field):
			return false
	for field: String in launch.keys():
		if field not in LAUNCH_FIELDS and field not in [
			OPTIONAL_PRESENTATION_ENTRANT_IDS, OPTIONAL_PRESENTATION_BROADCAST_TICKET,
		]:
			return false
	return true


static func _presentation_entrant_ids(value: Variant) -> Dictionary:
	if value == null:
		return {}
	if not value is Dictionary or value.size() != 2 \
		or not value.has("participant_0") or not value.has("participant_1"):
		return {}
	var first := str(value.participant_0).to_lower()
	var second := str(value.participant_1).to_lower()
	if first not in ["alpha", "bravo"] or second not in ["alpha", "bravo"] or first == second:
		return {}
	return {"participant_0": first, "participant_1": second}


static func _broadcast_ticket(value: Variant, task_id: String) -> String:
	if task_id not in ["rts-skirmish-v0", "rts-skirmish-v1"]:
		return ""
	if not value is String or value.length() != 43:
		return ""
	for index: int in value.length():
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) or code in [45, 95]):
			return ""
	return value


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
