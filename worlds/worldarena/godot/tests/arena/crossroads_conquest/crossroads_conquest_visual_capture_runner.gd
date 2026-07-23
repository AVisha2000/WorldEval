extends SceneTree

## Captures the eight acceptance frames from the same sealed replay and public
## broadcast scene used by Movie Maker.  No alternate visual fixture is allowed.

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const BroadcastScene := preload(
	"res://scripts/arena/presentation/crossroads_conquest/crossroads_conquest_broadcast_scene.gd"
)
const CAPTURES := [
	{"name": "opening", "msec": 4000},
	{"name": "terra-crossroads-control", "msec": 38000},
	{"name": "sol-center-breakthrough", "msec": 84000},
	{"name": "terra-counter-raid", "msec": 108000},
	{"name": "terra-elimination", "msec": 131000},
	{"name": "luna-staging", "msec": 141000},
	{"name": "sol-elimination", "msec": 164000},
	{"name": "podium", "msec": 174000},
]

var _failed := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var replay_path := _argument("--crossroads-replay=")
	var output_directory := _argument("--crossroads-capture-dir=")
	if replay_path.is_empty() or not FileAccess.file_exists(replay_path) \
			or output_directory.is_empty() or not output_directory.is_absolute_path() \
			or output_directory != output_directory.simplify_path():
		_fail("crossroads_visual_capture_arguments_invalid")
		return
	var parsed := Codec.parse_canonical(FileAccess.get_file_as_bytes(replay_path), 64 * 1024 * 1024)
	if not bool(parsed.get("ok", false)) or not parsed.get("value") is Dictionary:
		_fail("crossroads_visual_capture_replay_invalid")
		return
	if DirAccess.make_dir_recursive_absolute(output_directory) != OK:
		_fail("crossroads_visual_capture_directory_invalid")
		return
	var scene := BroadcastScene.new()
	root.add_child(scene)
	var configured: Dictionary = scene.configure_replay(parsed.value)
	if not bool(configured.get("ok", false)):
		_fail("crossroads_visual_capture_projection_rejected:%s" % str(configured.get("error", "unknown")))
		return
	for capture: Dictionary in CAPTURES:
		var destination := output_directory.path_join("%s.png" % str(capture.name))
		if FileAccess.file_exists(destination):
			_fail("crossroads_visual_capture_refuses_overwrite")
			return
		if not scene.apply_broadcast_time_msec(int(capture.msec)):
			_fail("crossroads_visual_capture_projection_rejected")
			return
		await process_frame
		await process_frame
		var image := root.get_texture().get_image()
		if image == null or image.get_width() != 1920 or image.get_height() != 1080 \
				or image.save_png(destination) != OK:
			_fail("crossroads_visual_capture_write_failed")
			return
	print("CROSSROADS_CONQUEST_VISUAL_CAPTURE_OK frames=%d output=%s" % [CAPTURES.size(), output_directory])
	quit(0)


func _argument(prefix: String) -> String:
	for value: String in OS.get_cmdline_user_args():
		if value.begins_with(prefix):
			return value.trim_prefix(prefix).strip_edges()
	return ""


func _fail(code: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(code)
	quit(2)
