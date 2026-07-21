extends SceneTree

## Native 1080p Movie Maker renderer for the explicitly-public RTS broadcast camera.
## It replays the sealed v2 authority ledger and feeds the broadcast only the two separately
## participant-filtered presentation sources. No provider text, checkpoint, or private player
## observation is passed to the scene.

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Verifier := preload("res://scripts/embodiment/v2/replay/embodiment_replay_verifier_v2.gd")
const Dispatcher := preload("res://scripts/embodiment/v2/transport/control_game_dispatcher_v2.gd")
const BroadcastScene := preload("res://scripts/embodiment/presentation/rts/rts_skirmish_broadcast_scene.gd")

# Movie Maker advances at the requested native capture FPS. Authority advances at 10 Hz, so
# three capture frames interpolate each authoritative tick: 1,200 * 3 = 3,600 replay frames.
# 150 intro frames (5 s) + 750 outro frames (25 s) yields exactly 4,500 native 30 FPS frames,
# i.e. the 150-second deliverable without any FFmpeg slow-down or duplicate-frame stretching.
const CAPTURE_FPS := 30
const AUTHORITY_HZ := 10
const FRAMES_PER_TICK := 3
const INTRO_FRAMES := 5 * CAPTURE_FPS
const OUTRO_FRAMES := 25 * CAPTURE_FPS
const EXPECTED_REPLAY_TICKS := 1200
const EXPECTED_TOTAL_FRAMES := 4500

var _scene: Node
var _failed := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("rts_movie_maker_environment_invalid")
		return
	var replay_path := _replay_path()
	if replay_path.is_empty():
		_fail("rts_movie_maker_replay_missing")
		return
	var payload := FileAccess.get_file_as_bytes(replay_path)
	if payload.is_empty() or not bool(Verifier.new().verify(payload).get("ok", false)):
		_fail("rts_movie_maker_replay_unverified")
		return
	var parsed := Codec.parse_canonical(payload, Verifier.MAX_REPLAY_BYTES)
	payload.fill(0)
	if not bool(parsed.get("ok", false)):
		_fail("rts_movie_maker_replay_invalid")
		return
	var replay: Dictionary = parsed.value
	if replay.config.get("task_id") != "rts-skirmish-v0":
		_fail("rts_movie_maker_task_invalid")
		return
	if int(replay.config.get("maximum_episode_ticks", -1)) != EXPECTED_REPLAY_TICKS:
		_fail("rts_movie_maker_duration_invalid")
		return
	var dispatcher := Dispatcher.new()
	if not dispatcher.configure(replay.config).is_empty():
		_fail("rts_movie_maker_authority_rejected")
		return
	_scene = BroadcastScene.new()
	root.add_child(_scene)
	if not _apply_sources(dispatcher):
		_fail("rts_movie_maker_projection_rejected")
		return
	_scene.begin_cinematic_intro()
	for _frame: int in INTRO_FRAMES:
		await process_frame
	var captured_frames := INTRO_FRAMES
	var replay_ticks := 0
	var task_evidence: Variant = replay.get("rts_task_plan_evidence", [])
	if task_evidence is Array and not task_evidence.is_empty() and task_evidence.size() != replay.steps.size():
		_fail("rts_movie_maker_task_evidence_invalid")
		return
	for step_index: int in replay.steps.size():
		var step_value: Variant = replay.steps[step_index]
		if not step_value is Dictionary or not step_value.get("decision_window") is Dictionary:
			_fail("rts_movie_maker_step_invalid")
			return
		var duration: Variant = step_value.decision_window.get("duration_ticks")
		if typeof(duration) != TYPE_INT or duration != 10:
			_fail("rts_movie_maker_duration_invalid")
			return
		replay_ticks += int(duration)
		var applied_window: Variant = task_evidence[step_index] if task_evidence is Array and not task_evidence.is_empty() else step_value.decision_window
		dispatcher.step_window(applied_window)
		if not _apply_sources(dispatcher):
			_fail("rts_movie_maker_projection_rejected")
			return
		for _frame: int in int(duration) * FRAMES_PER_TICK:
			await process_frame
			captured_frames += 1
	if replay_ticks != EXPECTED_REPLAY_TICKS:
		_fail("rts_movie_maker_replay_tick_count_invalid")
		return
	_scene.begin_cinematic_outro()
	for _frame: int in OUTRO_FRAMES:
		await process_frame
		captured_frames += 1
	if captured_frames != EXPECTED_TOTAL_FRAMES:
		_fail("rts_movie_maker_frame_count_invalid")
		return
	print("RTS_SKIRMISH_MOVIE_MAKER_OK")
	quit(0)


func _apply_sources(dispatcher: Object) -> bool:
	var before: String = dispatcher.checkpoint_hash()
	var sources := {
		"participant_0": dispatcher.participant_presentation_source("participant_0"),
		"participant_1": dispatcher.participant_presentation_source("participant_1"),
	}
	var observations: Dictionary = dispatcher.observe_all()
	return _scene.apply_public_sources(sources, int(observations.participant_0.observation_seq), int(observations.participant_0.tick)) \
		and dispatcher.checkpoint_hash() == before


func _replay_path() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--embodiment-replay="):
			return argument.trim_prefix("--embodiment-replay=")
	return ""


func _fail(code: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(code)
	quit(2)
