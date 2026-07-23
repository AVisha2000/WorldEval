class_name ArenaArtifactReplayPlayer
extends Node

## Read-only player for saved `world-arena-replay/1` artifacts.  Unlike the
## authored Showcase player this has no fixed duration or cue grammar: timing is
## supplied by the saved frames themselves.

signal loaded_changed(status: Dictionary)
signal completed

var loaded := false
var playing := false
var complete := false
var elapsed_seconds := 0.0
var duration_seconds := 0.0
var bundle: Dictionary = {}
var frames: Array[Dictionary] = []
var _next_frame := 0
var _presentation: Node


func load_bundle(value: Variant) -> Dictionary:
	_reset()
	if not value is Dictionary:
		return _refuse("Replay bundle is not a JSON object.")
	var candidate: Dictionary = value.duplicate(true)
	if str(candidate.get("protocol", "")) != "world-arena-replay/1":
		return _refuse("Replay uses an unsupported protocol.")
	if not candidate.get("initial_snapshot", null) is Dictionary:
		return _refuse("Replay is missing its initial snapshot.")
	var raw_frames: Variant = candidate.get("frames", [])
	if not raw_frames is Array or raw_frames.is_empty():
		return _refuse("Replay contains no frames.")
	var previous_time := -1.0
	for raw_frame in raw_frames:
		if not raw_frame is Dictionary:
			return _refuse("Replay contains a malformed frame.")
		var frame: Dictionary = raw_frame.duplicate(true)
		var at := float(frame.get("at_seconds", -1.0))
		if at < 0.0 or at < previous_time:
			return _refuse("Replay frames must be ordered by non-negative at_seconds.")
		if not frame.get("snapshot", null) is Dictionary:
			return _refuse("Replay frame %d is missing a snapshot." % frames.size())
		if not frame.get("events", []) is Array:
			return _refuse("Replay frame %d has malformed events." % frames.size())
		previous_time = at
		frames.append(frame)
	bundle = candidate
	duration_seconds = maxf(previous_time, float(candidate.get("duration_seconds", 0.0)))
	loaded = true
	var status := get_status()
	loaded_changed.emit(status)
	return status


func start(presentation_node: Node) -> bool:
	if not loaded or presentation_node == null:
		return false
	_presentation = presentation_node
	playing = true
	complete = false
	elapsed_seconds = 0.0
	_rebuild_to(0.0)
	return true


func advance(delta_seconds: float) -> void:
	if not loaded or not playing or complete:
		return
	elapsed_seconds = minf(duration_seconds, elapsed_seconds + maxf(0.0, delta_seconds))
	_apply_due_frames()
	_publish_time()
	if elapsed_seconds >= duration_seconds:
		playing = false
		complete = true
		if _presentation != null and _presentation.has_method("show_match_result") and bundle.get("result", null) is Dictionary:
			var result: Dictionary = bundle.get("result", {})
			_presentation.call("show_match_result", result.duplicate(true))
		completed.emit()


func seek(target_seconds: float) -> void:
	if not loaded:
		return
	var target := clampf(target_seconds, 0.0, duration_seconds)
	if target < elapsed_seconds - 0.0001:
		elapsed_seconds = target
		complete = false
		_rebuild_to(target)
		return
	elapsed_seconds = target
	if elapsed_seconds < duration_seconds:
		complete = false
	_apply_due_frames()
	_publish_time()


func _rebuild_to(target: float) -> void:
	if _presentation == null:
		return
	# Scrubs rebuild from immutable artifact snapshots. Normal playback never
	# comes through this path, which keeps persistent actors on screen.
	if _presentation.has_method("prepare_artifact_replay"):
		_presentation.call("prepare_artifact_replay")
	if _presentation.has_method("configure_from_snapshot"):
		var initial_snapshot: Dictionary = bundle.get("initial_snapshot", {})
		_presentation.call("configure_from_snapshot", initial_snapshot.duplicate(true))
	_next_frame = 0
	elapsed_seconds = target
	_apply_due_frames()
	_publish_time()


func _apply_due_frames() -> void:
	if _presentation == null:
		return
	while _next_frame < frames.size() and float(frames[_next_frame].get("at_seconds", 0.0)) <= elapsed_seconds + 0.0001:
		var frame := frames[_next_frame]
		if _presentation.has_method("configure_from_snapshot"):
			var frame_snapshot: Dictionary = frame.get("snapshot", {})
			_presentation.call("configure_from_snapshot", frame_snapshot.duplicate(true))
		if _presentation.has_method("apply_events"):
			var frame_events: Array = frame.get("events", [])
			_presentation.call("apply_events", frame_events.duplicate(true))
		_next_frame += 1


func _publish_time() -> void:
	if _presentation.has_method("set_artifact_replay_time"):
		_presentation.call("set_artifact_replay_time", elapsed_seconds, duration_seconds)


func set_playing(value: bool) -> void:
	if loaded and not complete:
		playing = value


func get_status() -> Dictionary:
	return {"loaded": loaded, "playing": playing, "complete": complete, "elapsed_seconds": elapsed_seconds, "duration_seconds": duration_seconds, "frame_count": frames.size(), "error": ""}


func _refuse(message: String) -> Dictionary:
	_reset()
	var status := get_status()
	status["error"] = message
	loaded_changed.emit(status)
	return status


func _reset() -> void:
	loaded = false
	playing = false
	complete = false
	elapsed_seconds = 0.0
	duration_seconds = 0.0
	bundle.clear()
	frames.clear()
	_next_frame = 0
	_presentation = null
