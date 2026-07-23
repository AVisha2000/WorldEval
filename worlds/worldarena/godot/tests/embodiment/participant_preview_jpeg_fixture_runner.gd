extends SceneTree

## Emits the exact JPEG shape used by the live preview publisher for Python conformance testing.


func _init() -> void:
	var output := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
	if output.is_empty():
		push_error("participant_preview_fixture_output_missing")
		quit(2)
		return
	var image := Image.create(1280, 720, false, Image.FORMAT_RGB8)
	image.fill(Color8(23, 79, 137))
	var jpeg := image.save_jpg_to_buffer(0.82)
	if jpeg.size() < 128 or jpeg[0] != 255 or jpeg[1] != 216:
		push_error("participant_preview_fixture_encode_failed")
		quit(1)
		return
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		push_error("participant_preview_fixture_write_failed")
		quit(1)
		return
	file.store_buffer(jpeg)
	file.close()
	print("participant_preview_jpeg_fixture_runner: PASS")
	quit(0)
