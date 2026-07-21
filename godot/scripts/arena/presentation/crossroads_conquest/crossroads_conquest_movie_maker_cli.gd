extends SceneTree

## Native 1080p30 Movie Maker entrypoint for the sealed Crossroads Conquest
## broadcast.  One process frame is captured for every delivery frame; FFmpeg is
## used only for the final H.264/AAC container encode, never to stretch timing.

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const BroadcastScene := preload(
	"res://scripts/arena/presentation/crossroads_conquest/crossroads_conquest_broadcast_scene.gd"
)
const CAPTURE_FPS := 30
const DURATION_SECONDS := 180
const EXPECTED_TOTAL_FRAMES := CAPTURE_FPS * DURATION_SECONDS
const MAX_REPLAY_BYTES := 64 * 1024 * 1024

var _failed := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("crossroads_movie_maker_environment_invalid")
		return
	var replay_path := _argument_value("--crossroads-replay=")
	if replay_path.is_empty() or not FileAccess.file_exists(replay_path):
		_fail("crossroads_movie_maker_replay_missing")
		return
	var payload := FileAccess.get_file_as_bytes(replay_path)
	var parsed := Codec.parse_canonical(payload, MAX_REPLAY_BYTES)
	payload.fill(0)
	if not bool(parsed.get("ok", false)) or not parsed.get("value") is Dictionary:
		_fail("crossroads_movie_maker_replay_invalid")
		return
	var scene := BroadcastScene.new()
	root.add_child(scene)
	var status: Dictionary = scene.configure_replay(parsed.value)
	if not bool(status.get("ok", false)):
		_fail("crossroads_movie_maker_projection_rejected:%s" % str(status.get("error", "unknown")))
		return
	var frame_limit := _smoke_frame_limit()
	if frame_limit < 0:
		_fail("crossroads_movie_maker_smoke_limit_invalid")
		return
	var frames_to_capture := frame_limit if frame_limit > 0 else EXPECTED_TOTAL_FRAMES
	var captured_frames := 0
	for frame_index: int in frames_to_capture:
		# Sample [0, 180) at exact 1/30-second intervals.  The Movie Writer receives
		# precisely 5,400 production frames, so the encoded duration is exactly 180 s.
		var broadcast_msec := int(floor(float(frame_index) * 1000.0 / float(CAPTURE_FPS)))
		if not scene.apply_broadcast_time_msec(broadcast_msec):
			_fail("crossroads_movie_maker_projection_rejected")
			return
		await process_frame
		captured_frames += 1
	if captured_frames != frames_to_capture:
		_fail("crossroads_movie_maker_frame_count_invalid")
		return
	if frame_limit > 0:
		print("CROSSROADS_CONQUEST_MOVIE_SMOKE_OK frames=%d" % captured_frames)
	else:
		if captured_frames != EXPECTED_TOTAL_FRAMES:
			_fail("crossroads_movie_maker_frame_count_invalid")
			return
		print("CROSSROADS_CONQUEST_MOVIE_MAKER_OK frames=%d" % captured_frames)
	quit(0)


func _smoke_frame_limit() -> int:
	var value := _argument_value("--crossroads-smoke-frames=")
	if value.is_empty():
		return 0
	if not value.is_valid_int():
		return -1
	var count := int(value)
	return count if count >= 1 and count <= 3 else -1


func _argument_value(prefix: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix).strip_edges()
	return ""


func _fail(code: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(code)
	quit(2)
