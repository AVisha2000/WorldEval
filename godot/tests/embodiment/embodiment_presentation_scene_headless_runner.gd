extends SceneTree

const SCENE_PATH := "res://scenes/embodiment/embodiment_presentation_scene.tscn"
const SOURCE_PATH := "res://scripts/embodiment/presentation/scene/embodiment_presentation_scene.gd"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	_check(packed != null, "procedural presentation scene did not load")
	if packed == null:
		_finish()
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	_test_composition(scene)
	_test_stage_c_projection(scene)
	_test_camera_and_idempotence(scene)
	_test_locomotion_follows_authority_heading(scene)
	_test_immutable_boundary(scene)
	_test_hidden_removal_and_neutral(scene)
	_test_no_authority_imports()
	scene.free()
	_finish()


func _test_composition(scene: Node) -> void:
	_check(scene.has_node("ArenaStatic/Floor"), "arena floor missing")
	for boundary: String in ["BoundaryNorth", "BoundarySouth", "BoundaryWest", "BoundaryEast"]:
		_check(scene.has_node("ArenaStatic/%s" % boundary), "%s missing" % boundary)
	_check(scene.has_node("OperatorProjection/Skeleton3D"), "reviewed Y Bot skeleton missing")
	_check(scene.has_node("OperatorProjection/AnimationTree"), "Y Bot AnimationTree missing")
	_check(scene.has_node("OperatorProjection/ParticipantCameraRig/ParticipantCamera"), "third-person participant camera missing")
	_check(not bool(scene.get_node("OperatorProjection").get_meta("presentation_placeholder", true)), "reviewed Y Bot is still marked as a placeholder")
	_check(str(scene.get_node("OperatorProjection").get_meta("asset_identity", "")) == "mixamo-y-bot", "operator does not identify the approved Y Bot")
	_check(scene.has_node("ArenaStatic/QuaterniusStableLandmark"), "reviewed Quaternius landmark missing")
	_check(scene.has_node("ParticipantHUD/Panel/Content/Observation"), "participant HUD missing")
	_check(scene.has_node("ParticipantHUD/Panel/Content/ControllerState"), "controller HUD missing")
	_check(scene.has_node("ParticipantHUD/Panel/Content/Receipt"), "receipt HUD missing")
	_check(scene.has_node("ParticipantHUD/Panel/Content/NonAuthoritativeIntent"), "intent HUD missing")
	_check(
		str(scene.get_node("ParticipantHUD/Panel").get_meta("asset_source", ""))
			== "kenney_ui_pack_adventure_reviewed_subset",
		"participant HUD does not identify the reviewed Kenney source",
	)
	_check(scene.has_node("EventAudio"), "event-driven presentation audio missing")


func _test_stage_c_projection(scene: Node) -> void:
	var snapshot := _stage_c_snapshot()
	_check(scene.apply_snapshot(snapshot), "valid Stage-C projection was rejected")
	var expected := {
		"resource_1": ["resource", "gathering_mid"],
		"relay_1": ["relay", "materials_ready"],
		"build_pad_1": ["build_pad", "building_mid"],
		"barricade_1": ["barricade", "building_mid"],
	}
	for entity_id: String in expected:
		var projection: Node3D = scene.projection_node(entity_id)
		_check(projection != null, "%s projection missing" % entity_id)
		if projection != null:
			_check(str(projection.get_meta("kind", "")) == expected[entity_id][0], "%s kind drifted" % entity_id)
			_check(str(projection.get_meta("state", "")) == expected[entity_id][1], "%s state is not legible" % entity_id)
			var label := projection.get_node("StateLabel") as Label3D
			_check(str(expected[entity_id][1]) in label.text, "%s state label missing" % entity_id)
	var barricade: Node3D = scene.projection_node("barricade_1")
	_check(barricade != null and barricade.scale.y > 0.5 and barricade.scale.y < 1.0, "partial barricade progress has no visible state")
	_check(str(scene.get_node("OperatorProjection/OperatorLabel").text).contains("BUILD"), "Operator action is not legible without logs")
	_check(str(scene.get_node("OperatorProjection").call("animation_state")) == "build", "Operator did not play the build animation")
	var pad: Node3D = scene.projection_node("build_pad_1")
	_check(pad != null and pad.get_node("ProgressRing").visible, "coarse build progress ring is not visible")
	_check(
		pad != null and pad.get_node("ConstructionParticles").emitting,
		"construction progress does not drive particles",
	)
	_check(
		str(scene.get_node("ParticipantHUD/Panel/Content/Observation").text).contains("12"),
		"participant HUD did not update observation identity",
	)
	_check(
		str(scene.get_node("ParticipantHUD/Panel/Content/ControllerState").text).contains("10t"),
		"participant HUD did not render controller duration",
	)
	_check(
		str(scene.get_node("ParticipantHUD/Panel/Content/Receipt").text).contains("ACCEPTED"),
		"participant HUD did not render accepted receipt",
	)
	_check(
		str(scene.get_node("ParticipantHUD/Panel/Content/NonAuthoritativeIntent").text)
			.contains("INTENT (NON-AUTHORITATIVE)"),
		"participant HUD did not label intent as non-authoritative",
	)
	var state: Dictionary = scene.debug_state()
	_check(str(state.episode_id) == "episode-presentation-001", "episode boundary identity drifted")
	_check(int(state.observation_seq) == 12, "observation boundary identity drifted")
	_check(str(state.task_id) == "construction-v0", "task identity drifted")


func _test_camera_and_idempotence(scene: Node) -> void:
	var camera: Camera3D = scene.participant_camera("participant_0")
	_check(camera != null, "participant cannot own its camera")
	_check(camera != null and camera.current, "participant camera is not current")
	_check(scene.participant_camera("spectator") == null, "camera leaked to a different perspective")
	_check(camera != null and camera.get_parent().get_parent() == scene.get_node("OperatorProjection"), "camera does not follow the Operator")
	var prior_resource: Node3D = scene.projection_node("resource_1")
	var prior_barricade: Node3D = scene.projection_node("barricade_1")
	_check(scene.apply_snapshot(_stage_c_snapshot()), "idempotent snapshot update failed")
	_check(scene.projection_node("resource_1") == prior_resource, "idempotent update rebuilt resource")
	_check(scene.projection_node("barricade_1") == prior_barricade, "idempotent update rebuilt barricade")
	_check(scene.debug_state().agency == _accepted_agency(), "idempotent update changed agency evidence")
	var complete := _stage_c_snapshot()
	complete.observation_seq = 13
	complete.tick = 71
	complete.entities[2].state = "complete"
	complete.entities[3].state = "complete"
	_check(scene.apply_snapshot(complete), "completed construction snapshot failed")
	_check(is_equal_approx(scene.projection_node("barricade_1").scale.y, 1.0), "complete barricade did not reach full visual height")
	var not_started := _stage_c_snapshot()
	not_started.observation_seq = 14
	not_started.tick = 72
	not_started.operator.state = "idle"
	not_started.entities[2].state = "needs_materials"
	not_started.entities.remove_at(3)
	_check(scene.apply_snapshot(not_started), "pre-construction snapshot failed")
	_check(scene.projection_node("barricade_1") == null, "pre-construction state invented a barricade")


func _test_locomotion_follows_authority_heading(scene: Node) -> void:
	var walking := _stage_c_snapshot()
	walking.observation_seq = 15
	walking.tick = 73
	walking.operator.position_mt = [2200, 4600]
	walking.operator.heading_milli = 3000
	walking.operator.state = "walk"
	_check(scene.apply_snapshot(walking), "turning walk snapshot was rejected")
	var operator := scene.get_node("OperatorProjection") as Node3D
	_check(
		is_equal_approx(operator.rotation.y, 3.0 * PI / 4.0),
		"walking Y Bot did not rotate to the authoritative heading",
	)
	_check(str(operator.call("animation_state")) == "walk", "turning Y Bot stopped walking")
	var running := walking.duplicate(true)
	running.observation_seq = 16
	running.tick = 74
	running.operator.position_mt = [2600, 4200]
	running.operator.heading_milli = 5000
	running.operator.state = "run"
	_check(scene.apply_snapshot(running), "turning run snapshot was rejected")
	_check(
		is_equal_approx(operator.rotation.y, 5.0 * PI / 4.0),
		"running Y Bot did not continue rotating with authority",
	)
	_check(str(operator.call("animation_state")) == "run", "turning Y Bot stopped running")
	var camera: Camera3D = scene.participant_camera("participant_0")
	_check(
		camera != null and camera.get_parent().get_parent() == operator,
		"third-person camera stopped following the rotating Operator",
	)


func _test_immutable_boundary(scene: Node) -> void:
	var snapshot := _stage_c_snapshot()
	var before := JSON.stringify(snapshot)
	_check(scene.apply_snapshot(snapshot), "immutable test snapshot failed")
	_check(JSON.stringify(snapshot) == before, "presentation mutated caller snapshot")
	snapshot.operator.position_mt[0] = 9999
	snapshot.entities[0].state = "caller_mutation"
	var cached: Dictionary = scene.snapshot_copy()
	_check(int(cached.operator.position_mt[0]) == 1200, "presentation retained caller operator data")
	_check(str(cached.entities[0].state) == "gathering_mid", "presentation retained caller entity data")
	cached.entities[0].state = "returned_copy_mutation"
	_check(str(scene.snapshot_copy().entities[0].state) != "returned_copy_mutation", "snapshot_copy exposed mutable internal state")


func _test_hidden_removal_and_neutral(scene: Node) -> void:
	var neutral := {
		"episode_id": "episode-presentation-001",
		"observation_seq": 14,
		"participant_id": "participant_0",
		"task_id": "neutral-encounter-v0",
		"tick": 80,
		"operator": {"position_mt": [0, 1000], "heading_milli": 0, "state": "guarding"},
		"agency": _no_input_agency(),
		"entities": [
			{"id": "neutral_1", "kind": "neutral", "position_mt": [0, -1000], "heading_milli": 4000, "state": "engaging_health_80"},
			{"id": "relay_1", "kind": "relay", "position_mt": [0, -2000], "heading_milli": 0, "state": "activation_4_of_10"},
		],
	}
	_check(scene.apply_snapshot(neutral), "neutral projection was rejected")
	_check(scene.projection_node("neutral_1") != null, "neutral projection missing")
	_check(str(scene.projection_node("neutral_1").get_meta("state", "")) == "engaging_health_80", "neutral task state drifted")
	_check(scene.projection_node("resource_1") == null, "omitted resource remained visible")
	_check(scene.projection_node("build_pad_1") == null, "omitted build pad remained visible")
	_check(scene.projection_node("barricade_1") == null, "omitted barricade remained visible")
	_check(
		str(scene.get_node("ParticipantHUD/Panel/Content/Receipt").text).contains("NO_INPUT"),
		"neutral window receipt was not legible in participant HUD",
	)
	_check(
		str(scene.get_node("ParticipantHUD/Panel/Content/NonAuthoritativeIntent").text).ends_with("—"),
		"no_input HUD invented an intent",
	)
	var invalid := neutral.duplicate(true)
	invalid.entities[0].position_mt = [0.5, -1000]
	var prior: Dictionary = scene.snapshot_copy()
	_check(not scene.apply_snapshot(invalid), "float authority coordinate crossed projection boundary")
	_check(scene.snapshot_copy() == prior, "rejected snapshot changed presentation state")
	var hidden_payload := neutral.duplicate(true)
	hidden_payload["spectator_hidden_state"] = {"neutral_exact_position": [123, 456]}
	_check(not scene.apply_snapshot(hidden_payload), "spectator-only payload crossed exact projection boundary")
	_check(scene.snapshot_copy() == prior, "hidden payload changed presentation state")


func _test_no_authority_imports() -> void:
	var source := FileAccess.get_file_as_string(SOURCE_PATH)
	_check(not source.is_empty(), "presentation source could not be inspected")
	_check(not "/authority/" in source, "presentation imports authority code")
	_check(not "AuthorityOrchestrator" in source, "presentation names an authority implementation")


func _stage_c_snapshot() -> Dictionary:
	return {
		"episode_id": "episode-presentation-001",
		"observation_seq": 12,
		"participant_id": "participant_0",
		"task_id": "construction-v0",
		"tick": 64,
		"operator": {"position_mt": [1200, 5000], "heading_milli": 2000, "state": "build"},
		"agency": _accepted_agency(),
		"entities": [
			{"id": "resource_1", "kind": "resource", "position_mt": [0, -3000], "heading_milli": 0, "state": "gathering_mid"},
			{"id": "relay_1", "kind": "relay", "position_mt": [0, 7000], "heading_milli": 0, "state": "materials_ready"},
			{"id": "build_pad_1", "kind": "build_pad", "position_mt": [3000, 5000], "heading_milli": 2000, "state": "building_mid"},
			{"id": "barricade_1", "kind": "barricade", "position_mt": [3000, 5000], "heading_milli": 2000, "state": "building_mid"},
		],
	}


func _accepted_agency() -> Dictionary:
	var agency := _no_input_agency()
	agency.controller.move_x = 350
	agency.controller.move_y = -700
	agency.controller.buttons.interact = true
	agency.receipt = {
		"disposition": "accepted", "accepted": true, "fallback": "none",
		"applied_ticks": 10, "codes": ["applied", "construction_progressed"],
	}
	agency.intent_label = "Continue building the visible barricade."
	return agency


func _no_input_agency() -> Dictionary:
	return {
		"controller": {
			"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0,
			"duration_ticks": 10,
			"buttons": {
				"interact": false, "primary": false, "guard": false, "dash": false,
				"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false,
			},
		},
		"receipt": {
			"disposition": "no_input", "accepted": false, "fallback": "neutral",
			"applied_ticks": 10, "codes": ["no_input"],
		},
		"intent_label": "",
	}


func _finish() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_PRESENTATION_SCENE_FAILURE: %s" % failure)
		print("EMBODIMENT_PRESENTATION_SCENE_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_PRESENTATION_SCENE_OK")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
