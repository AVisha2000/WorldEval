extends SceneTree

const OUTPUT_PATH := "/tmp/worldarena-ui-remediated.png"


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	var packed: PackedScene = load("res://scenes/arena_v1.tscn")
	var scene := packed.instantiate()
	root.add_child(scene)
	# Let the offline match dismiss setup, populate the HUD, and render a stable frame.
	for ignored in 12:
		await process_frame
	RenderingServer.force_draw(false, 0.0)
	var capture := root.get_texture().get_image()
	var result := capture.save_png(OUTPUT_PATH)
	assert(result == OK, "failed to save Arena UI capture")
	print("ARENA_UI_CAPTURE_OK path=%s size=%dx%d" % [OUTPUT_PATH, capture.get_width(), capture.get_height()])
	quit(0)
