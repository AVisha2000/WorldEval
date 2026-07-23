class_name EmbodimentVersionedReplayCli
extends SceneTree

const Dispatcher := preload("res://scripts/embodiment/v2/replay/embodiment_replay_dispatcher.gd")
const MAX_REPLAY_BYTES := 16 * 1024 * 1024


func _init() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 1:
		print("EMBODIMENT_REPLAY_REJECTED replay_path_required")
		quit(2)
		return
	var file := FileAccess.open(arguments[0], FileAccess.READ)
	if file == null or file.get_length() < 1 or file.get_length() > MAX_REPLAY_BYTES:
		print("EMBODIMENT_REPLAY_REJECTED replay_file_invalid")
		quit(2)
		return
	var result: Dictionary = Dispatcher.new().verify(file.get_buffer(file.get_length()))
	if not bool(result.get("ok", false)):
		print("EMBODIMENT_REPLAY_REJECTED %s" % str(result.get("code", "replay_invalid")))
		quit(1)
		return
	print("EMBODIMENT_REPLAY_VERIFIED %s %s" % [result.protocol_version, result.final_state_hash])
	quit(0)
