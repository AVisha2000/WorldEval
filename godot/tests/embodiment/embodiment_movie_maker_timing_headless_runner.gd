extends SceneTree

const MovieMaker := preload(
	"res://scripts/embodiment/replay/embodiment_movie_maker_cli.gd"
)

var _failures := PackedStringArray()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_check(
		MovieMaker.render_frames_for_duration(1) == 3,
		"one authoritative tick did not render three frames",
	)
	_check(
		MovieMaker.render_frames_for_duration(7) == 21,
		"multi-tick render duration drifted",
	)
	_check(
		MovieMaker.render_frames_for_duration(20) == 60,
		"maximum solo window did not render at thirty FPS",
	)
	for malformed_duration: Variant in [null, false, 0, -1, 1.0, "1", {}, []]:
		_check(
			MovieMaker.render_frames_for_duration(malformed_duration) == 0,
			"malformed render duration was accepted: %s" % str(malformed_duration),
		)
	_finish()


func _finish() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_MOVIE_MAKER_TIMING_FAILURE: %s" % failure)
		print("EMBODIMENT_MOVIE_MAKER_TIMING_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_MOVIE_MAKER_TIMING_OK")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
