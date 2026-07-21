extends SceneTree

## One-frame participant-view smoke capture for local visual QA. It is not replay evidence and
## does not communicate with authority; its source is the same participant-filtered fixture used
## by the compact presentation test.

const Scene := preload("res://scripts/embodiment/presentation/v2/control_game_participant_scene_v2.gd")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var output := _output_path()
	if output.is_empty():
		push_error("RESOURCE_RELAY_CAPTURE_OUTPUT_MISSING")
		quit(2)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	root.add_child(viewport)
	var scene := Scene.new()
	viewport.add_child(scene)
	if not scene.configure_task("duo-resource-relay-v0", "participant_0", "alpha"):
		_fail("configuration rejected")
		return
	if not scene.apply_participant_projection(_source(), _observation()):
		_fail("participant projection rejected")
		return
	for frame: int in 4:
		await process_frame
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty() or image.get_width() != 1280 or image.get_height() != 720:
		_fail("participant frame unavailable")
		return
	var error := image.save_png(output)
	if error != OK:
		_fail("participant frame save failed")
		return
	print("RESOURCE_RELAY_BATTLEFIELD_CAPTURE=%s" % output)
	quit(0)


func _output_path() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			return argument.trim_prefix("--output=")
	return ""


func _source() -> Dictionary:
	return {
		"participant_id": "participant_0",
		"operator": {"position_mt": {"x": 0, "y": 6500}, "heading": 4,
			"animation_state": "walk", "presentation_entrant_id": "alpha"},
		"visible_entities": [
			{"id": "v_resource_0", "kind": "resource", "position_mt": {"x": -3200, "y": 0}, "heading": 0, "animation_state": "idle"},
			{"id": "v_friendly_relay", "kind": "relay", "position_mt": {"x": -3200, "y": 5400}, "heading": 0, "animation_state": "idle"},
			{"id": "v_friendly_barricade", "kind": "barricade", "position_mt": {"x": -3200, "y": 5400}, "heading": 0, "animation_state": "idle"},
			{"id": "v_rival", "kind": "operator", "position_mt": {"x": 900, "y": 5200}, "heading": 4, "animation_state": "walk"},
		],
	}


func _observation() -> Dictionary:
	return {
		"episode_id": "ep_battlefield_capture", "observation_seq": 1, "participant_id": "participant_0",
		"profile": "hybrid-visible-v1", "goal": "Gather material, secure your relay, and outscore the visible rival.", "tick": 10,
		"self": {"health_percent": 100, "energy_percent": 88, "status": ["ready"]},
		"visible_entities": [
			{"id": "v_resource_0", "state": "available"}, {"id": "v_friendly_relay", "state": "ready"},
			{"id": "v_friendly_barricade", "state": "not_built"}, {"id": "v_rival", "state": "ready"},
		],
		"previous_receipt": {"disposition": "accepted"},
	}


func _fail(message: String) -> void:
	push_error("RESOURCE_RELAY_CAPTURE_FAILED: %s" % message)
	quit(1)
