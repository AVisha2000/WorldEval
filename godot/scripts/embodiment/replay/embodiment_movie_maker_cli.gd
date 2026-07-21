extends SceneTree

const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")
const ReplayVerifier := preload(
	"res://scripts/embodiment/replay/embodiment_replay_verifier.gd"
)
const SoloAuthority := preload(
	"res://scripts/embodiment/authority/authority_orchestrator.gd"
)
const DuelAuthority := preload(
	"res://scripts/embodiment/duel_authority/embodiment_duel_authority.gd"
)
const SnapshotFilter := preload(
	"res://scripts/embodiment/presentation/privacy/presentation_snapshot_filter.gd"
)
const HybridAdapter := preload(
	"res://scripts/embodiment/presentation/embodiment_hybrid_presentation_adapter.gd"
)
const PresentationScene := preload(
	"res://scenes/embodiment/embodiment_presentation_scene.tscn"
)

const RENDER_FRAMES_PER_AUTHORITY_TICK := 3
const MAX_RENDER_DURATION_TICKS := 20
const INITIAL_SNAPSHOT_FRAMES := 15
const INTRO_FRAMES := 30
const OUTRO_FRAMES := 30

var _scene: Node = null
var _failed := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("embodiment_movie_maker_environment_invalid")
		return
	var replay_paths := _replay_paths()
	if replay_paths.is_empty():
		_fail("embodiment_movie_maker_replay_missing")
		return
	_scene = PresentationScene.instantiate()
	root.add_child(_scene)
	for frame: int in INTRO_FRAMES:
		await process_frame
	for replay_path: String in replay_paths:
		if not await _play_verified_replay(replay_path):
			return
	for frame: int in OUTRO_FRAMES:
		await process_frame
	print("EMBODIMENT_MOVIE_MAKER_OK replays=%d" % replay_paths.size())
	quit(0)


func _play_verified_replay(path: String) -> bool:
	var payload := FileAccess.get_file_as_bytes(path)
	if payload.is_empty():
		_fail("embodiment_movie_maker_replay_unreadable")
		return false
	var verified: Dictionary = ReplayVerifier.new().verify(payload)
	if not bool(verified.get("ok", false)):
		_fail("embodiment_movie_maker_replay_unverified")
		return false
	var parsed: Dictionary = Codec.parse_canonical(payload, ReplayVerifier.MAX_REPLAY_BYTES)
	payload.fill(0)
	payload.clear()
	if not bool(parsed.get("ok", false)):
		_fail("embodiment_movie_maker_replay_invalid")
		return false
	var replay: Dictionary = parsed.value
	var duel: bool = replay.config.mode in ["scripted-duel-v0", "model-duel-v0"]
	var authority = DuelAuthority.new() if duel else SoloAuthority.new()
	var errors: PackedStringArray = authority.configure_managed_hybrid(replay.config)
	if not errors.is_empty():
		_fail("embodiment_movie_maker_authority_rejected")
		return false
	var participant_id := "participant_0"
	var initial_result := _filtered_snapshot(authority, participant_id)
	if not bool(initial_result.get("ok", false)):
		return false
	var current_render: Dictionary = initial_result.snapshot
	if not _apply_scene_snapshot(
		HybridAdapter.scene_snapshot(current_render), authority, str(initial_result.authority_hash)
	):
		return false
	for frame: int in INITIAL_SNAPSHOT_FRAMES:
		await process_frame
	for step_variant: Variant in replay.steps:
		if typeof(step_variant) != TYPE_DICTIONARY:
			_fail("embodiment_movie_maker_replay_step_invalid")
			return false
		var step: Dictionary = step_variant
		var decision_window_variant: Variant = step.get("decision_window")
		if typeof(decision_window_variant) != TYPE_DICTIONARY:
			_fail("embodiment_movie_maker_duration_invalid")
			return false
		var decision_window: Dictionary = decision_window_variant
		var frame_count := render_frames_for_duration(decision_window.get("duration_ticks"))
		if frame_count == 0:
			_fail("embodiment_movie_maker_duration_invalid")
			return false
		authority.step_window(decision_window)
		var after_result := _filtered_snapshot(authority, participant_id)
		if not bool(after_result.get("ok", false)):
			return false
		for frame: int in frame_count:
			var progress_milli := int((frame + 1) * 1000 / frame_count)
			var interpolated := HybridAdapter.interpolated_scene_snapshot(
				current_render, after_result.snapshot, progress_milli
			)
			if not bool(interpolated.get("ok", false)) or not _apply_scene_snapshot(
				interpolated.snapshot, authority, str(after_result.authority_hash)
			):
				return false
			await process_frame
		current_render = after_result.snapshot
	return true


static func render_frames_for_duration(duration: Variant) -> int:
	if typeof(duration) != TYPE_INT:
		return 0
	var duration_ticks: int = duration
	if duration_ticks < 1 or duration_ticks > MAX_RENDER_DURATION_TICKS:
		return 0
	return duration_ticks * RENDER_FRAMES_PER_AUTHORITY_TICK


func _filtered_snapshot(authority: Object, participant_id: String) -> Dictionary:
	var authority_hash: String = authority.checkpoint_hash()
	var source: Dictionary = (
		authority.presentation_source_snapshot_for(participant_id)
		if authority.has_method("presentation_source_snapshot_for")
		else authority.presentation_source_snapshot()
	)
	var visible_ids: Array[String] = (
		authority.presentation_visible_entity_ids_for(participant_id)
		if authority.has_method("presentation_visible_entity_ids_for")
		else authority.presentation_visible_entity_ids()
	)
	var filtered: Dictionary = SnapshotFilter.filter_for_participant(
		source, participant_id, visible_ids
	)
	if not bool(filtered.get("ok", false)) or authority.checkpoint_hash() != authority_hash:
		_fail("embodiment_movie_maker_projection_rejected")
		return {"ok": false}
	return {
		"ok": true,
		"snapshot": filtered.snapshot,
		"authority_hash": authority_hash,
	}


func _apply_scene_snapshot(snapshot: Dictionary, authority: Object, authority_hash: String) -> bool:
	if not _scene.apply_snapshot(snapshot) or authority.checkpoint_hash() != authority_hash:
		_fail("embodiment_movie_maker_projection_rejected")
		return false
	return true


func _replay_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--embodiment-replay="):
			var path := argument.trim_prefix("--embodiment-replay=")
			if not path.is_empty():
				paths.append(path)
	return paths


func _fail(code: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(code)
	quit(2)
