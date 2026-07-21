extends SceneTree

const Scene := preload("res://scripts/embodiment/presentation/rts/rts_skirmish_participant_scene.gd")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := Scene.new()
	root.add_child(scene)
	if not scene.configure_participant("participant_0", "blue"):
		_fail("participant configuration rejected")
		return
	await process_frame
	if not scene.has_node("FrontierForestMap/TexturedGrassland") or not scene.has_node("FrontierForestMap/ForestRiver"):
		_fail("forest map is incomplete")
		return
	var camera := scene.participant_camera("participant_0")
	if camera == null or not bool(camera.get_meta("presentation_only", false)) or camera.position.y < 18.0:
		_fail("participant-only broadcast camera missing")
		return
	if not scene.apply_participant_projection(_source(), _observation()):
		_fail("participant-safe RTS source rejected")
		return
	for entity: String in ["Visible_own_town_hall", "Visible_own_barracks", "Visible_own_tower", "Visible_v_wood", "Visible_v_ore", "Visible_v_enemy"]:
		if not scene.has_node("ParticipantVisibleRtsEntities/%s" % entity):
			_fail("visible RTS entity missing: %s" % entity)
			return
	var enemy := scene.get_node("ParticipantVisibleRtsEntities/Visible_v_enemy") as Node3D
	if enemy.get_meta("presentation_team_id", "") != "red":
		_fail("visible opposing unit does not carry red presentation team")
		return
	var snapshot := scene.snapshot_copy()
	if JSON.stringify(snapshot).contains("spectator") or JSON.stringify(snapshot).contains("participant_1"):
		_fail("presentation snapshot leaked nonparticipant state")
		return
	print("RTS_SKIRMISH_PRESENTATION_OK")
	quit(0)


func _source() -> Dictionary:
	return {
		"participant_id": "participant_0",
		"operator": {"position_mt": {"x": -3200, "y": 6400}, "heading": 4, "animation_state": "walk"},
		"own": {
			"town_hall": {"position_mt": {"x": -7800, "y": 7200}, "health_percent": 92, "state": "intact"},
			"barracks": {"position_mt": {"x": -6500, "y": 5700}, "state": "building"},
			"tower": {"position_mt": {"x": -5100, "y": 4800}, "state": "active"},
			"units": {"count": 3, "rally_state": "rallying"},
		},
		"visible_entities": [
			{"id": "v_wood", "kind": "resource_wood", "position_mt": {"x": -2500, "y": 3300}, "heading": 0, "animation_state": "idle"},
			{"id": "v_ore", "kind": "resource_ore", "position_mt": {"x": -900, "y": 2500}, "heading": 0, "animation_state": "idle"},
			{"id": "v_beacon", "kind": "central_beacon", "position_mt": {"x": 0, "y": 0}, "heading": 0, "animation_state": "idle"},
			{"id": "v_enemy", "kind": "operator", "position_mt": {"x": 1800, "y": 1800}, "heading": 5, "animation_state": "attack", "presentation_team_id": "red"},
		],
	}


func _observation() -> Dictionary:
	return {
		"episode_id": "ep_rts_presentation", "observation_seq": 4, "participant_id": "participant_0", "tick": 40,
		"self": {"health_percent": 92, "status": ["carrying"]},
		"visible_entities": [
			{"id": "v_wood", "state": "available"}, {"id": "v_ore", "state": "available"},
			{"id": "v_beacon", "state": "contested"}, {"id": "v_enemy", "state": "wounded", "health_percent": 62},
		],
		"terminal": {"outcome": "running"},
	}


func _fail(message: String) -> void:
	push_error("RTS_SKIRMISH_PRESENTATION_FAILED: %s" % message)
	quit(1)
