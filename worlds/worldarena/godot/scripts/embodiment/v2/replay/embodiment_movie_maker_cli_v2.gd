extends SceneTree

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const Verifier := preload(
	"res://scripts/embodiment/v2/replay/embodiment_replay_verifier_v2.gd"
)
const Dispatcher := preload(
	"res://scripts/embodiment/v2/transport/control_game_dispatcher_v2.gd"
)
const ParticipantScene := preload(
	"res://scripts/embodiment/presentation/v2/control_game_participant_scene_v2.gd"
)
const RtsParticipantScene := preload(
	"res://scripts/embodiment/presentation/rts/rts_skirmish_participant_scene.gd"
)
const ProjectionTween := preload(
	"res://scripts/embodiment/presentation/preview/versioned_projection_tween.gd"
)

const FRAMES_PER_TICK := 3
const INTRO_FRAMES := 15
const OUTRO_FRAMES := 30

var _scene: Node
var _failed := false
var _participant_id := "participant_0"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("embodiment_v2_movie_maker_environment_invalid")
		return
	var replay_path := _replay_path()
	if replay_path.is_empty():
		_fail("embodiment_v2_movie_maker_replay_missing")
		return
	var payload := FileAccess.get_file_as_bytes(replay_path)
	if payload.is_empty() or not bool(Verifier.new().verify(payload).get("ok", false)):
		_fail("embodiment_v2_movie_maker_replay_unverified")
		return
	var parsed := Codec.parse_canonical(payload, Verifier.MAX_REPLAY_BYTES)
	payload.fill(0)
	if not bool(parsed.get("ok", false)):
		_fail("embodiment_v2_movie_maker_replay_invalid")
		return
	var replay: Dictionary = parsed.value
	_participant_id = _requested_participant_id()
	if _participant_id not in replay.config.participant_ids:
		_fail("embodiment_v2_movie_maker_participant_invalid")
		return
	var dispatcher := Dispatcher.new()
	if not dispatcher.configure(replay.config).is_empty():
		_fail("embodiment_v2_movie_maker_authority_rejected")
		return
	var is_rts_skirmish := str(replay.config.task_id) in ["rts-skirmish-v0", "rts-skirmish-v1"]
	_scene = RtsParticipantScene.new() if is_rts_skirmish else ParticipantScene.new()
	root.add_child(_scene)
	var scene_configured: bool
	if is_rts_skirmish:
		scene_configured = _scene.configure_participant(
			_participant_id, "blue" if _participant_id == "participant_0" else "red"
		)
	else:
		scene_configured = _scene.configure_task(
			str(replay.config.task_id), _participant_id,
			_duo_entrant_for_seat(str(replay.config.episode_id), _participant_id)
		)
	if not scene_configured:
		_fail("embodiment_v2_movie_maker_projection_rejected")
		return
	var current_source: Dictionary = dispatcher.participant_presentation_source(_participant_id)
	var current_observation: Dictionary = dispatcher.observe_all()[_participant_id]
	if not _apply_projection(dispatcher, current_source, current_observation):
		_fail("embodiment_v2_movie_maker_projection_rejected")
		return
	for frame: int in INTRO_FRAMES:
		await process_frame
	for step_value: Variant in replay.steps:
		if not step_value is Dictionary or not step_value.get("decision_window") is Dictionary:
			_fail("embodiment_v2_movie_maker_step_invalid")
			return
		var duration: Variant = step_value.decision_window.get("duration_ticks")
		if typeof(duration) != TYPE_INT or duration < 1 or duration > 20:
			_fail("embodiment_v2_movie_maker_duration_invalid")
			return
		dispatcher.step_window(step_value.decision_window)
		var after_source: Dictionary = dispatcher.participant_presentation_source(_participant_id)
		var after_observation: Dictionary = dispatcher.observe_all()[_participant_id]
		var frame_count: int = int(duration) * FRAMES_PER_TICK
		for frame: int in frame_count:
			var progress_milli := int((frame + 1) * 1000 / frame_count)
			var source := ProjectionTween.interpolate(
				current_source, after_source, progress_milli, "llm-controller/0.2.0"
			)
			if source.is_empty() or not _apply_projection(dispatcher, source, after_observation):
				_fail("embodiment_v2_movie_maker_projection_rejected")
				return
			await process_frame
		current_source = after_source
	for frame: int in OUTRO_FRAMES:
		await process_frame
	print("EMBODIMENT_V2_MOVIE_MAKER_OK")
	quit(0)


func _apply_projection(
		dispatcher: Object, source: Dictionary, observation: Dictionary,
) -> bool:
	var before: String = dispatcher.checkpoint_hash()
	return _scene.apply_participant_projection(source, observation) \
		and dispatcher.checkpoint_hash() == before


func _replay_path() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--embodiment-replay="):
			return argument.trim_prefix("--embodiment-replay=")
	return ""


func _requested_participant_id() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--embodiment-participant="):
			return argument.trim_prefix("--embodiment-participant=")
	return "participant_0"


func _duo_entrant_for_seat(episode_id: String, participant_id: String) -> String:
	if participant_id not in ["participant_0", "participant_1"]:
		return ""
	var swapped := episode_id.ends_with("_b")
	if participant_id == "participant_0":
		return "bravo" if swapped else "alpha"
	return "alpha" if swapped else "bravo"


func _fail(code: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(code)
	quit(2)
