extends SceneTree

const Dispatcher := preload(
	"res://scripts/embodiment/v3/transport/trio_game_dispatcher_v3.gd"
)
const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")


func _init() -> void:
	var path := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture="):
			path = argument.trim_prefix("--fixture=")
	if path.is_empty():
		push_error("trio_conformance_fixture_argument_missing")
		quit(2)
		return
	var payload := FileAccess.get_file_as_bytes(path)
	if not payload.is_empty() and payload[-1] == 10:
		payload.resize(payload.size() - 1)
	var parsed: Dictionary = Codec.parse_canonical(payload, 1024 * 1024)
	if not bool(parsed.get("ok", false)) or not parsed.get("value") is Dictionary:
		push_error("trio_conformance_fixture_parse_failed %s" % str(parsed))
		quit(2)
		return
	var fixture: Dictionary = parsed.value
	var results := {}
	for value: Variant in fixture.get("config_cases", []):
		if value is Dictionary:
			var dispatcher := Dispatcher.new()
			results[str(value.id)] = dispatcher.configure(value.payload).is_empty()
	var configured := Dispatcher.new()
	var valid_config: Dictionary = fixture.config_cases[0].payload
	if not configured.configure(valid_config).is_empty():
		push_error("trio_conformance_valid_config_failed")
		quit(2)
		return
	for value: Variant in fixture.get("action_cases", []):
		if value is Dictionary:
			results[str(value.id)] = configured.authority._valid_action(value.payload)
	for value: Variant in fixture.get("decision_window_cases", []):
		if value is Dictionary:
			results[str(value.id)] = configured.decision_window_schema_valid(value.payload)
	print(Codec.canonical_json({"results": results}))
	quit(0)
