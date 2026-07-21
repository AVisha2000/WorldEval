extends SceneTree

const Scene := preload("res://scripts/embodiment/presentation/v2/control_game_participant_scene_v2.gd")

var _failed := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := Scene.new()
	root.add_child(scene)
	if not scene.configure_task("duo-resource-relay-v0", "participant_0", "alpha"):
		_fail("resource relay presentation configuration rejected")
		return
	await process_frame
	var battlefield := scene.get_node_or_null("ResourceRelayBattlefield") as Node3D
	if battlefield == null or not battlefield.visible:
		_fail("resource relay battlefield is missing")
		return
	for landmark: String in ["Grassland", "BluewaterRiver", "Bridge_N5_6", "ForestAndRocks"]:
		if not battlefield.has_node(landmark):
			_fail("battlefield landmark missing: %s" % landmark)
			return
	var camera: Camera3D = scene.participant_camera("participant_0")
	if camera == null or camera.position.y < 12.0 or camera.fov > 58.0:
		_fail("resource relay does not use the elevated participant camera")
		return
	var source := {
		"participant_id": "participant_0",
		"operator": {"position_mt": {"x": 0, "y": 6500}, "heading": 4,
			"animation_state": "walk", "presentation_entrant_id": "alpha"},
		"visible_entities": [
			{"id": "v_resource_0", "kind": "resource", "position_mt": {"x": -3200, "y": 0},
				"heading": 0, "animation_state": "idle"},
			{"id": "v_friendly_relay", "kind": "relay", "position_mt": {"x": -3200, "y": 5400},
				"heading": 0, "animation_state": "idle"},
			{"id": "v_friendly_barricade", "kind": "barricade", "position_mt": {"x": -3200, "y": 5400},
				"heading": 0, "animation_state": "idle"},
			{"id": "v_rival", "kind": "operator", "position_mt": {"x": 900, "y": 5200},
				"heading": 4, "animation_state": "walk"},
		],
	}
	var observation := {
		"episode_id": "ep_battlefield", "observation_seq": 1, "participant_id": "participant_0",
		"profile": "hybrid-visible-v1", "goal": "visible relay test", "tick": 10,
		"self": {"health_percent": 100, "status": ["ready"]},
		"visible_entities": [
			{"id": "v_resource_0"}, {"id": "v_friendly_relay"}, {"id": "v_friendly_barricade"},
			{"id": "v_rival"},
		],
	}
	if not scene.apply_participant_projection(source, observation):
		_fail("participant-filtered resource relay projection rejected")
		return
	for entity_name: String in ["Visible_v_resource_0", "Visible_v_friendly_relay", "Visible_v_friendly_barricade", "Visible_v_rival"]:
		if not scene.has_node("ParticipantVisibleEntities/%s" % entity_name):
			_fail("visible authority entity missing: %s" % entity_name)
			return
	var rival := scene.get_node_or_null("ParticipantVisibleEntities/Visible_v_rival") as Node3D
	if rival == null or rival.get_meta("presentation_entrant_id", "") != "bravo":
		_fail("visible rival did not receive its distinct public team colour")
		return
	var snapshot: Dictionary = scene.snapshot_copy()
	if JSON.stringify(snapshot).contains("spectator") or JSON.stringify(snapshot).contains("participant_1"):
		_fail("presentation snapshot leaked nonparticipant data")
		return
	print("RESOURCE_RELAY_BATTLEFIELD_OK")
	quit(0)


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("RESOURCE_RELAY_BATTLEFIELD_FAILED: %s" % message)
	print("RESOURCE_RELAY_BATTLEFIELD_FAILED")
	quit(1)
