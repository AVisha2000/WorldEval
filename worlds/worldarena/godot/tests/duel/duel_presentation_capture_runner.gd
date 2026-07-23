extends SceneTree

func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1440, 900)
	var packed := load("res://scenes/duel_v1.tscn") as PackedScene
	assert(packed != null, "duel scene failed to parse")
	var app = packed.instantiate()
	var setup_capture := OS.get_cmdline_user_args().has("--setup")
	app.start_in_live_preview = not setup_capture
	root.add_child(app)
	for _frame in 8:
		await process_frame
	RenderingServer.force_draw(false, 0.0)
	var capture := root.get_texture().get_image()
	var output_path := "/tmp/worldarena-duel-setup.png" if setup_capture else "/tmp/worldarena-duel-presentation.png"
	var result := capture.save_png(output_path)
	assert(result == OK, "failed to save Duel presentation capture")
	print("DUEL_PRESENTATION_CAPTURE_OK path=%s size=%dx%d" % [output_path, capture.get_width(), capture.get_height()])
	app.queue_free()
	await process_frame
	quit(0)
