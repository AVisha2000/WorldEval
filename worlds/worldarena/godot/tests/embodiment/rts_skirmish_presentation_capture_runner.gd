extends SceneTree

const Scene := preload("res://scripts/embodiment/presentation/rts/rts_skirmish_participant_scene.gd")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var output := _output_path()
	if output.is_empty():
		quit(2)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := Scene.new()
	viewport.add_child(scene)
	if not scene.configure_participant("participant_0", "blue") or not scene.apply_participant_projection(_source(), _observation()):
		quit(1)
		return
	for frame: int in 5:
		await process_frame
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty() or image.save_png(output) != OK:
		quit(1)
		return
	print("RTS_SKIRMISH_PRESENTATION_CAPTURE=%s" % output)
	quit(0)


func _output_path() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			return argument.trim_prefix("--output=")
	return ""


func _source() -> Dictionary:
	return {
		"participant_id": "participant_0",
		"operator": {"position_mt": {"x": -1900, "y": 5200}, "heading": 4, "animation_state": "walk"},
		"own": {
			"town_hall": {"position_mt": {"x": -7800, "y": 7200}, "health_percent": 92, "state": "intact"},
			"barracks": {"position_mt": {"x": -6200, "y": 4800}, "state": "building"},
			"tower": {"position_mt": {"x": -4900, "y": 2800}, "state": "active"}, "units": {"count": 3, "rally_state": "rallying"},
		},
		"visible_entities": [
			{"id": "v_wood", "kind": "resource_wood", "position_mt": {"x": -3500, "y": 2500}, "heading": 0, "animation_state": "idle"},
			{"id": "v_ore", "kind": "resource_ore", "position_mt": {"x": -700, "y": 1900}, "heading": 0, "animation_state": "idle"},
			{"id": "v_beacon", "kind": "central_beacon", "position_mt": {"x": 0, "y": 0}, "heading": 0, "animation_state": "idle"},
			{"id": "v_enemy", "kind": "operator", "position_mt": {"x": 1350, "y": 1650}, "heading": 5, "animation_state": "attack", "presentation_team_id": "red"},
		],
	}


func _observation() -> Dictionary:
	return {"episode_id": "ep_rts_capture", "observation_seq": 4, "participant_id": "participant_0", "tick": 40,
		"self": {"health_percent": 92, "status": ["carrying"]}, "visible_entities": [
			{"id": "v_wood", "state": "available"}, {"id": "v_ore", "state": "available"},
			{"id": "v_beacon", "state": "contested"}, {"id": "v_enemy", "state": "wounded", "health_percent": 62},
		], "terminal": {"outcome": "running"}}
