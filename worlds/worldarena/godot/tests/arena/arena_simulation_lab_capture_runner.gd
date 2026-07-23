extends SceneTree

## Focused visual-QA capture for the Simulation Lab and a generic artifact replay.
## Paths come from user arguments so this runner remains useful for future bundles.

const DEFAULT_LAB_OUTPUT := "/tmp/worldarena-simulation-lab-implemented.png"
const DEFAULT_REPLAY_OUTPUT := "/tmp/worldarena-artifact-replay-implemented.png"


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var options := _options()
	root.size = Vector2i(1920, 1080)
	var packed: PackedScene = load("res://scenes/arena_v1.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	for ignored in 12:
		await process_frame

	var presentation: Node = scene.get_node("Presentation")
	presentation.call("_set_lobby_mode", "simulation")
	presentation.call("set_simulation_job_status", "COMPLETED", "360 frames saved in 2.0 seconds.", false)
	presentation.call("set_replay_list", [
		{"replay_id": "arena-headless-trace-final-v2-2407", "status": "completed", "max_rounds": 24},
		{"replay_id": "sim-demo-2407", "status": "completed", "max_rounds": 12}
	])
	for ignored in 5:
		await process_frame
	_save_viewport(str(options.lab_output))

	var bundle_path := str(options.bundle)
	if bundle_path.is_empty() or not FileAccess.file_exists(bundle_path):
		printerr("ARENA_SIMULATION_LAB_CAPTURE_ERROR missing --bundle=<absolute bundle.json>")
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(bundle_path))
	if not parsed is Dictionary:
		printerr("ARENA_SIMULATION_LAB_CAPTURE_ERROR invalid replay JSON")
		quit(2)
		return
	var projected: Dictionary = scene.call("_project_artifact_bundle", parsed)
	if projected.is_empty():
		printerr("ARENA_SIMULATION_LAB_CAPTURE_ERROR replay projection failed")
		quit(2)
		return
	scene.call("_start_artifact_replay", projected)
	var player: Node = scene.get("_artifact_replay_player")
	player.call("seek", 7.75)
	for ignored in 8:
		await process_frame
	_save_viewport(str(options.replay_output))
	print("ARENA_SIMULATION_LAB_CAPTURE_OK lab=%s replay=%s" % [options.lab_output, options.replay_output])
	quit(0)


func _save_viewport(path: String) -> void:
	RenderingServer.force_draw(false, 0.0)
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	assert(error == OK, "failed to save capture to %s" % path)


func _options() -> Dictionary:
	var result := {
		"bundle": "",
		"lab_output": DEFAULT_LAB_OUTPUT,
		"replay_output": DEFAULT_REPLAY_OUTPUT
	}
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--bundle="):
			result.bundle = argument.trim_prefix("--bundle=").strip_edges()
		elif argument.begins_with("--lab-output="):
			result.lab_output = argument.trim_prefix("--lab-output=").strip_edges()
		elif argument.begins_with("--replay-output="):
			result.replay_output = argument.trim_prefix("--replay-output=").strip_edges()
	return result
