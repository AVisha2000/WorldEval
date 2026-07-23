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
		print("DUO_V2_HYBRID_SKIPPED")
		quit(0)
		return
	var scenes := {}
	var viewports := {}
	for participant_id: String in ["participant_0", "participant_1"]:
		var viewport := SubViewport.new()
		viewport.name = "TestViewport_%s" % participant_id
		viewport.size = Vector2i(1280, 720)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var scene := Scene.new()
		viewport.add_child(scene)
		if not scene.configure_task("duo-spar-v0", participant_id):
			_fail("scene configuration failed for %s" % participant_id)
			return
		scenes[participant_id] = scene
		viewports[participant_id] = viewport
	var config := {"protocol_version": Identity.PROTOCOL_VERSION,
		"episode_id": "ep_duo_hybrid_v2", "mode": "model-duel-v0",
		"task_id": "duo-spar-v0", "seed": 43,
		"observation_profile": "hybrid-visible-v1", "timing_track": "step-locked-v1",
		"maximum_episode_ticks": 1200,
		"participant_ids": ["participant_0", "participant_1"]}
	var launch := {"attachment_ticket": TICKET, "config": config,
		"config_sha256": Canonical.sha256_bytes(Canonical.canonical_bytes(config)),
		"connection_id": "duo_hybrid_v2", "protocol_package_sha256": Identity.SHA256}
	var secret := PackedByteArray()
	secret.resize(32)
	for index: int in 32:
		secret[index] = index + 1
	var host := Host.new()
	var errors: PackedStringArray = host.configure(launch, secret, Adapter.new(scenes, viewports))
	if not errors.is_empty():
		_fail("host configure failed: %s" % str(errors))
		return
	var peer := Codec.new()
	if not peer.configure(config.episode_id, secret, "python").is_empty():
		_fail("peer configure failed")
		return
	if not bool(peer.decode(host.begin_handshake().payload).get("ok", false)):
		_fail("hello failed")
		return
	var auth := peer.encode("auth", Codec.ZERO_HASH, {"attachment_ticket": TICKET})
	var ready := peer.decode(host.receive(auth.payload).payload)
	if not bool(ready.get("ok", false)):
		_fail("ready failed: %s" % str(ready))
		return
	var observations: Dictionary = ready.frame.body.observations
	if observations.size() != 2:
		_fail("hybrid boundary omitted a participant")
		return
	for participant_id: String in ["participant_0", "participant_1"]:
		var rival_id := "participant_1" if participant_id == "participant_0" else "participant_0"
		var observation: Dictionary = observations[participant_id]
		if observation.profile != "hybrid-visible-v1" or not observation.frame is Dictionary \
			or not str(observation.frame.transport_ref).begins_with("frame:%s." % participant_id):
			_fail("%s hybrid metadata was not participant bound" % participant_id)
			return
		var snapshot_text := JSON.stringify(scenes[participant_id].snapshot_copy())
		if rival_id in snapshot_text or "spectator" in snapshot_text:
			_fail("%s renderer snapshot leaked rival identity or spectator state" % participant_id)
			return
		var request := peer.encode("frame_request", ready.frame.body.state_hash, {
			"observation_seq": observation.observation_seq,
			"participant_id": participant_id, "sensor_id": observation.frame.sensor_id,
			"transport_ref": observation.frame.transport_ref,
		})
		var response := peer.decode(host.receive(request.payload).payload)
		if not bool(response.get("ok", false)):
			_fail("%s frame response failed" % participant_id)
			return
		var frame_body: Dictionary = response.frame.body
		var png := Marshalls.base64_to_raw(str(frame_body.png_base64))
		if frame_body.participant_id != participant_id \
			or frame_body.metadata.sha256 != observation.frame.sha256 \
			or png.size() < 24 or png[0] != 137 or png[1] != 80:
			_fail("%s frame bytes were not bound to its participant metadata" % participant_id)
			return
	print("DUO_V2_HYBRID_OK")
	quit(0)


func _fail(message: String) -> void:
	push_error("DUO_V2_HYBRID_FAILURE: %s" % message)
	print("DUO_V2_HYBRID_FAILED")
	quit(1)
