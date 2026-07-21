class_name EmbodimentReplayCli
extends SceneTree

const Codec := preload(
	"res://scripts/embodiment/transport/embodiment_frame_codec.gd"
)
const Verifier := preload(
	"res://scripts/embodiment/replay/embodiment_replay_verifier.gd"
)


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() != "headless" \
		or OS.get_stdin_type() not in [OS.STD_HANDLE_PIPE, OS.STD_HANDLE_UNKNOWN]:
		_fail("replay_environment_rejected")
		return
	var payload := OS.read_buffer_from_stdin(Verifier.MAX_REPLAY_BYTES + 1)
	var result: Dictionary = Verifier.new().verify(payload)
	if not payload.is_empty():
		payload.fill(0)
		payload.clear()
	if not bool(result.get("ok", false)):
		_fail(str(result.get("code", "replay_invalid")))
		return
	print(Codec.canonical_json({
		"episode_id": result.episode_id,
		"final_state_hash": result.final_state_hash,
		"kind": "embodiment_replay_verified",
		"schema_version": Verifier.SCHEMA_VERSION,
	}))
	quit(0)


func _fail(code: String) -> void:
	print(Codec.canonical_json({
		"code": code,
		"kind": "embodiment_replay_error",
		"schema_version": Verifier.SCHEMA_VERSION,
	}))
	quit(2)
