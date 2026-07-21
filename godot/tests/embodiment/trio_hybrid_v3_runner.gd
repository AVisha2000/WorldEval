extends SceneTree

const Host := preload("res://scripts/embodiment/v3/transport/embodiment_managed_session_host_v3.gd")
const Codec := preload("res://scripts/embodiment/v3/transport/embodiment_frame_codec_v3.gd")
const Canonical := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Identity := preload("res://scripts/embodiment/v3/protocol/embodiment_protocol_package_identity_v3.gd")
const Scene := preload("res://scripts/embodiment/presentation/v3/trio_participant_scene_v3.gd")
const Adapter := preload("res://scripts/embodiment/presentation/v3/trio_game_participant_frame_adapter_v3.gd")
const TICKET := "0123456789abcdef0123456789abcdef0123456789a"
const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("TRIO_HYBRID_V3_SKIPPED")
		quit(0)
		return
	var scenes := {}
	var viewports := {}
	for participant_id: String in PARTICIPANTS:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(1280, 720)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var scene := Scene.new()
		viewport.add_child(scene)
		if not scene.configure_task("trio-relay-v0", participant_id):
			_fail("scene configure")
			return
		scenes[participant_id] = scene
		viewports[participant_id] = viewport
	var config := {
		"protocol_version": Identity.PROTOCOL_VERSION, "episode_id": "ep_hybrid_trio_v3",
		"mode": "trio-game-v0", "task_id": "trio-relay-v0", "seed": 7,
		"observation_profile": "hybrid-visible-v1", "timing_track": "step-locked-v1",
		"maximum_episode_ticks": 1200, "participant_ids": PARTICIPANTS.duplicate(),
		"seat_rotation": 0,
	}
	var launch := {
		"attachment_ticket": TICKET, "config": config,
		"config_sha256": Canonical.sha256_bytes(Canonical.canonical_bytes(config)),
		"connection_id": "hybrid_trio_v3", "protocol_package_sha256": Identity.SHA256,
	}
	var secret := PackedByteArray()
	secret.resize(32)
	for index: int in 32:
		secret[index] = index + 1
	var host := Host.new()
	var errors: PackedStringArray = host.configure(launch, secret, Adapter.new(scenes, viewports))
	if not errors.is_empty():
		_fail("host configure %s" % str(errors))
		return
	var peer := Codec.new()
	if not peer.configure(config.episode_id, secret, "python").is_empty():
		_fail("peer configure")
		return
	var hello: Dictionary = peer.decode(host.begin_handshake().payload)
	if not bool(hello.get("ok", false)):
		_fail("hello")
		return
	var auth := peer.encode("auth", Codec.ZERO_HASH, {"attachment_ticket": TICKET})
	var ready_response: Dictionary = host.receive(auth.payload)
	var ready: Dictionary = peer.decode(ready_response.payload)
	if not bool(ready.get("ok", false)):
		_fail("ready")
		return
	var refs: Array[String] = []
	for participant_id: String in PARTICIPANTS:
		var observation: Dictionary = ready.frame.body.observations[participant_id]
		if observation.profile != "hybrid-visible-v1" or not observation.frame is Dictionary:
			_fail("hybrid observation %s" % participant_id)
			return
		refs.append(str(observation.frame.transport_ref))
		var snapshot: Dictionary = scenes[participant_id].snapshot_copy()
		if snapshot.get("participant_id") != participant_id:
			_fail("participant projection scope %s" % participant_id)
			return
		var frame_request := peer.encode("frame_request", ready.frame.body.state_hash, {
			"observation_seq": observation.observation_seq, "participant_id": participant_id,
			"sensor_id": observation.frame.sensor_id,
			"transport_ref": observation.frame.transport_ref,
		})
		var response: Dictionary = host.receive(frame_request.payload)
		var decoded: Dictionary = peer.decode(response.payload)
		if not bool(decoded.get("ok", false)) \
			or decoded.frame.body.participant_id != participant_id \
			or Marshalls.base64_to_raw(decoded.frame.body.png_base64).size() < 1000:
			_fail("frame response %s" % participant_id)
			return
	if refs.size() != 3 or refs[0] == refs[1] or refs[1] == refs[2] or refs[0] == refs[2]:
		_fail("participant-scoped frame references were not distinct")
		return
	print("TRIO_HYBRID_V3_OK")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TRIO_HYBRID_V3_FAILED %s" % message)
	quit(1)
