extends SceneTree

const SCENE_PATH := "res://scenes/embodiment/y_bot_operator.tscn"
const SOURCE_PATH := "res://scripts/embodiment/presentation/scene/y_bot_operator.gd"
const REQUIRED_STATES := [
	"idle", "walk", "run", "attack", "guard", "gather", "build", "hit", "celebrate",
	"defeat",
]

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	_check(packed != null, "reviewed Y Bot scene did not load")
	if packed == null:
		_finish()
		return
	var operator := packed.instantiate() as Node3D
	root.add_child(operator)
	await process_frame
	_check(operator.has_node("Skeleton3D"), "Y Bot skeleton missing")
	_check(operator.has_node("Skeleton3D/Alpha_Surface"), "Y Bot body mesh missing")
	_check(operator.has_node("AnimationPlayer"), "Y Bot AnimationPlayer missing")
	_check(operator.has_node("AnimationTree"), "Y Bot AnimationTree missing")
	_check((operator.get_node("AnimationTree") as AnimationTree).active, "AnimationTree inactive")
	_check(str(operator.get_meta("asset_identity", "")) == "mixamo-y-bot", "asset identity drifted")
	_check(not bool(operator.get_meta("presentation_placeholder", true)), "Y Bot marked placeholder")
	var states: Array = operator.call("available_states")
	for state: String in REQUIRED_STATES:
		_check(StringName(state) in states, "missing normalized animation %s" % state)
		_check(bool(operator.call("play_state", StringName(state))), "state %s did not play" % state)
		_check(str(operator.call("animation_state")) == state, "state %s did not become current" % state)
	_check(bool(operator.call("play_state", &"dash")), "dash alias failed")
	_check(str(operator.call("animation_state")) == "run", "dash did not map to run")
	_check(bool(operator.call("play_state", &"guarding")), "guarding alias failed")
	_check(str(operator.call("animation_state")) == "guard", "guarding did not map to guard")
	_check(bool(operator.call("play_state", &"unknown_state")), "unknown fallback failed")
	_check(str(operator.call("animation_state")) == "idle", "unknown state did not fail closed to idle")
	_check(str(operator.call("last_error")).is_empty(), "Y Bot controller reported an error")
	var source := FileAccess.get_file_as_string(SOURCE_PATH)
	_check(not "/authority/" in source, "Y Bot presentation imports authority code")
	operator.free()
	_finish()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("Y_BOT_OPERATOR_FAILURE: %s" % failure)
		print("Y_BOT_OPERATOR_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("Y_BOT_OPERATOR_OK")
	quit(0)
