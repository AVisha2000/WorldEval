extends SceneTree

const Host := preload("res://scripts/embodiment/v2/transport/embodiment_managed_session_host_v2.gd")
const Codec := preload("res://scripts/embodiment/v2/transport/embodiment_frame_codec_v2.gd")
const Canonical := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Identity := preload("res://scripts/embodiment/v2/protocol/embodiment_protocol_package_identity_v2.gd")
const Scene := preload("res://scripts/embodiment/presentation/v2/control_game_participant_scene_v2.gd")
const Adapter := preload("res://scripts/embodiment/presentation/v2/control_game_participant_frame_adapter_v2.gd")
const TICKET := "0123456789abcdef0123456789abcdef0123456789a"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("CONTROL_GAME_HYBRID_V2_SKIPPED")
		quit(0)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := Scene.new()
	viewport.add_child(scene)
	if not scene.configure_task("movement-maze-v0"):
		_fail("scene configure")
		return
	var config := {
		"protocol_version": Identity.PROTOCOL_VERSION,
		"episode_id": "ep_hybrid_control_v2",
		"mode": "solo-curriculum-v0",
		"task_id": "movement-maze-v0",
		"seed": 7,
		"observation_profile": "hybrid-visible-v1",
		"timing_track": "step-locked-v1",
		"maximum_episode_ticks": 200,
		"participant_ids": ["participant_0"],
	}
	var launch := {
		"attachment_ticket": TICKET,
		"config": config,
		"config_sha256": Canonical.sha256_bytes(Canonical.canonical_bytes(config)),
		"connection_id": "hybrid_control_v2",
		"protocol_package_sha256": Identity.SHA256,
	}
	var secret := PackedByteArray()
	secret.resize(32)
	for index: int in 32:
		secret[index] = index + 1
	var host := Host.new()
	var errors: PackedStringArray = host.configure(launch, secret, Adapter.new(scene, viewport))
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
	var response: Dictionary = host.receive(auth.payload)
	if not bool(response.get("ok", false)):
		_fail("host ready %s" % str(response))
		return
	var ready: Dictionary = peer.decode(response.payload)
	if not bool(ready.get("ok", false)):
		_fail("peer ready %s" % str(ready))
		return
	var observation: Dictionary = ready.frame.body.observations.participant_0
	if observation.profile != "hybrid-visible-v1" or not observation.frame is Dictionary:
		_fail("hybrid observation")
		return
	var frame_request := peer.encode("frame_request", ready.frame.body.state_hash, {
		"observation_seq": observation.observation_seq,
		"participant_id": "participant_0",
		"sensor_id": observation.frame.sensor_id,
		"transport_ref": observation.frame.transport_ref,
	})
	var frame_response: Dictionary = host.receive(frame_request.payload)
	if not bool(frame_response.get("ok", false)) \
		or not bool(peer.decode(frame_response.payload).get("ok", false)):
		_fail("frame response")
		return
	print("CONTROL_GAME_HYBRID_V2_OK")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("CONTROL_GAME_HYBRID_V2_FAILED %s" % message)
	quit(1)
