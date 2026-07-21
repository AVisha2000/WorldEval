class_name YBotOperator
extends Node3D

## Presentation-only Mixamo Y Bot animation controller.
##
## Authority owns the root transform. Imported Mixamo clips animate only the reviewed Y Bot
## skeleton; horizontal hip translation is removed so animation root motion cannot move the
## participant projection away from its authoritative position.

const LIBRARY_NAME := &"worldarena"
const SOURCE_ANIMATION := &"mixamo_com"
const REQUIRED_STATES := [
	&"idle", &"walk", &"run", &"attack", &"guard", &"gather", &"build", &"hit",
	&"celebrate", &"defeat",
]
const LOOPING_STATES := {
	&"idle": true,
	&"walk": true,
	&"run": true,
	&"guard": true,
	&"gather": true,
	&"build": true,
}
const STATE_ALIASES := {
	&"dash": &"run",
	&"guarding": &"guard",
}

@export var clip_scenes: Dictionary = {}

var _animation_player: AnimationPlayer
var _animation_tree: AnimationTree
var _state_machine: AnimationNodeStateMachine
var _playback: AnimationNodeStateMachinePlayback
var _current_state := &""
var _ready_for_states := false
var _last_error := ""


func _ready() -> void:
	_initialize_animation_mapping()
	if _ready_for_states:
		play_state(&"idle")


func play_state(requested_state: StringName) -> bool:
	if not _ready_for_states:
		_initialize_animation_mapping()
	if not _ready_for_states:
		return false
	var state: StringName = STATE_ALIASES.get(requested_state, requested_state)
	if state not in REQUIRED_STATES:
		state = &"idle"
	if state == _current_state:
		return true
	_playback.start(state, true)
	_current_state = state
	set_meta("animation_state", String(state))
	return true


func animation_state() -> StringName:
	return _current_state


func available_states() -> Array[StringName]:
	var states: Array[StringName] = []
	if _animation_player == null:
		return states
	for state: StringName in REQUIRED_STATES:
		if _animation_player.has_animation(_library_animation(state)):
			states.append(state)
	return states


func last_error() -> String:
	return _last_error


func _initialize_animation_mapping() -> void:
	if _ready_for_states:
		return
	_animation_player = get_node_or_null("AnimationPlayer") as AnimationPlayer
	_animation_tree = get_node_or_null("AnimationTree") as AnimationTree
	if _animation_player == null or _animation_tree == null:
		_last_error = "y_bot_animation_nodes_missing"
		return
	if set_keys(clip_scenes) != _required_state_keys():
		_last_error = "y_bot_clip_mapping_invalid"
		return
	if _animation_player.has_animation_library(LIBRARY_NAME):
		_animation_player.remove_animation_library(LIBRARY_NAME)
	var library := AnimationLibrary.new()
	for state: StringName in REQUIRED_STATES:
		var clip_scene := clip_scenes.get(String(state)) as PackedScene
		var animation := _animation_from_scene(clip_scene)
		if animation == null:
			_last_error = "y_bot_clip_invalid_%s" % state
			return
		animation.loop_mode = (
			Animation.LOOP_LINEAR if LOOPING_STATES.has(state) else Animation.LOOP_NONE
		)
		_strip_horizontal_root_motion(animation)
		library.add_animation(state, animation)
	_animation_player.add_animation_library(LIBRARY_NAME, library)
	_state_machine = _animation_tree.tree_root as AnimationNodeStateMachine
	if _state_machine == null:
		_last_error = "y_bot_state_machine_missing"
		return
	for state: StringName in REQUIRED_STATES:
		var node := AnimationNodeAnimation.new()
		node.animation = _library_animation(state)
		_state_machine.add_node(state, node)
	_animation_tree.active = true
	_playback = _animation_tree.get("parameters/playback") as AnimationNodeStateMachinePlayback
	if _playback == null:
		_last_error = "y_bot_state_playback_missing"
		_animation_tree.active = false
		return
	_ready_for_states = true
	_last_error = ""
	set_meta("asset_identity", "mixamo-y-bot")
	set_meta("presentation_placeholder", false)


func _animation_from_scene(scene: PackedScene) -> Animation:
	if scene == null:
		return null
	var instance := scene.instantiate()
	var source_player := instance.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if source_player == null or not source_player.has_animation(SOURCE_ANIMATION):
		instance.free()
		return null
	var source := source_player.get_animation(SOURCE_ANIMATION)
	var animation := source.duplicate(true) as Animation if source != null else null
	instance.free()
	return animation


func _strip_horizontal_root_motion(animation: Animation) -> void:
	for track_index: int in animation.get_track_count():
		if animation.track_get_type(track_index) != Animation.TYPE_POSITION_3D:
			continue
		if not String(animation.track_get_path(track_index)).ends_with(":mixamorig_Hips"):
			continue
		if animation.track_get_key_count(track_index) == 0:
			continue
		var anchor: Vector3 = animation.track_get_key_value(track_index, 0)
		for key_index: int in animation.track_get_key_count(track_index):
			var value: Vector3 = animation.track_get_key_value(track_index, key_index)
			value.x = anchor.x
			value.z = anchor.z
			animation.track_set_key_value(track_index, key_index, value)


func _library_animation(state: StringName) -> StringName:
	return StringName("%s/%s" % [LIBRARY_NAME, state])


func _required_state_keys() -> Array[String]:
	var keys: Array[String] = []
	for state: StringName in REQUIRED_STATES:
		keys.append(String(state))
	keys.sort()
	return keys


func set_keys(value: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for key: Variant in value.keys():
		if typeof(key) != TYPE_STRING:
			return []
		keys.append(key)
	keys.sort()
	return keys
