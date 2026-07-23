class_name DuelHeadlessCli
extends SceneTree

const Runner := preload("res://scripts/duel/match/duel_headless_match_runner.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Standalone dedicated entry point. Invoke either as a source script or through
## the staged dedicated project's default nonvisual scene. It performs no
## network/provider calls and refuses non-headless display/audio drivers.

const MAX_INPUT_BYTES := 2 * 1024 * 1024
const MAX_TRANSCRIPT_BYTES := 64 * 1024 * 1024
const ENV_INPUT := "WORLDARENA_DUEL_HEADLESS_INPUT"
const ENV_OUTPUT := "WORLDARENA_DUEL_HEADLESS_OUTPUT_DIR"
const ENV_INPUT_HASH := "WORLDARENA_DUEL_HEADLESS_INPUT_SHA256"
const ENV_TRANSCRIPT := "WORLDARENA_DUEL_HEADLESS_TRANSCRIPT"


func _init() -> void:
	quit(run_command())


static func run_command() -> int:
	return _run()


static func _run() -> int:
	var parsed := _parse_arguments(OS.get_cmdline_user_args())
	if not bool(parsed.get("ok", false)):
		_emit_error(parsed.get("errors", []))
		return 2
	if DisplayServer.get_name() != "headless":
		_emit_error(["dedicated Duel CLI requires the headless display driver"])
		return 2
	if AudioServer.get_driver_name() != "Dummy":
		_emit_error(["dedicated Duel CLI requires the Dummy audio driver"])
		return 2
	var engine_version: Dictionary = Engine.get_version_info()
	var engine_identity := "%d.%d.%s.%s.%s" % [
		int(engine_version.get("major", -1)),
		int(engine_version.get("minor", -1)),
		str(engine_version.get("status", "")),
		str(engine_version.get("build", "")),
		str(engine_version.get("hash", "")).substr(0, 9),
	]
	if engine_identity != Runner.ENGINE_BUILD:
		_emit_error([
			"Godot build mismatch: expected %s, got %s"
			% [Runner.ENGINE_BUILD, engine_identity]
		])
		return 2

	var input_result := _read_canonical_json(
		str(parsed["input"]), MAX_INPUT_BYTES, TYPE_DICTIONARY, "headless run input"
	)
	if not bool(input_result.get("ok", false)):
		_emit_error(input_result.get("errors", []))
		return 2
	var input_hash := Codec.sha256_bytes(input_result["bytes"])
	if input_hash != str(parsed["expected_input_sha256"]):
		_emit_error(["headless run input bytes do not match --expected-input-sha256"])
		return 2

	var transcript: Array = []
	if not str(parsed["transcript"]).is_empty():
		var transcript_result := _read_canonical_json(
			str(parsed["transcript"]), MAX_TRANSCRIPT_BYTES, TYPE_ARRAY,
			"canonical action transcript"
		)
		if not bool(transcript_result.get("ok", false)):
			_emit_error(transcript_result.get("errors", []))
			return 2
		transcript = transcript_result["value"]

	var result := Runner.new().execute(input_result["value"], transcript)
	if not bool(result.get("ok", false)):
		_emit_error(result.get("errors", []))
		return 3
	var write_result := _write_artifacts(str(parsed["output_dir"]), result["artifacts"])
	if not bool(write_result.get("ok", false)):
		_emit_error(write_result.get("errors", []))
		return 4
	var summary: Dictionary = result["summary"].duplicate(true)
	summary["input_sha256"] = input_hash
	summary["output_directory"] = str(parsed["output_dir"])
	summary["replay_manifest_sha256"] = Codec.sha256_bytes(
		result["artifacts"]["replay-manifest.json"]
	)
	print(Codec.canonical_json({
		"kind": "worldarena_duel_headless_complete",
		"summary": summary,
	}))
	return 0


static func _parse_arguments(arguments: PackedStringArray) -> Dictionary:
	var errors := PackedStringArray()
	var values := {
		"expected_input_sha256": OS.get_environment(ENV_INPUT_HASH),
		"input": OS.get_environment(ENV_INPUT),
		"output_dir": OS.get_environment(ENV_OUTPUT),
		"transcript": OS.get_environment(ENV_TRANSCRIPT),
	}
	var seen: Dictionary = {}
	for argument: String in arguments:
		if not argument.begins_with("--") or "=" not in argument:
			errors.append("unknown dedicated CLI argument: %s" % argument)
			continue
		var separator := argument.find("=")
		var key := argument.substr(2, separator - 2).replace("-", "_")
		var value := argument.substr(separator + 1)
		if key not in values:
			errors.append("unknown dedicated CLI argument: --%s" % key.replace("_", "-"))
			continue
		if seen.has(key):
			errors.append("duplicate dedicated CLI argument: --%s" % key.replace("_", "-"))
			continue
		seen[key] = true
		values[key] = value
	for field: String in ["input", "output_dir", "expected_input_sha256"]:
		if str(values[field]).is_empty():
			errors.append("missing required dedicated CLI value: %s" % field)
	if not _is_absolute_path(str(values["input"])):
		errors.append("dedicated CLI input path must be absolute")
	if not _is_absolute_path(str(values["output_dir"])):
		errors.append("dedicated CLI output_dir path must be absolute")
	if not str(values["transcript"]).is_empty() \
		and not _is_absolute_path(str(values["transcript"])):
		errors.append("dedicated CLI transcript path must be absolute")
	if not _is_sha256(str(values["expected_input_sha256"])):
		errors.append("expected_input_sha256 must be lowercase SHA-256")
	values["errors"] = errors
	values["ok"] = errors.is_empty()
	return values


static func _read_canonical_json(
	path: String, maximum_bytes: int, expected_type: int, label: String
) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failure("%s file does not exist" % label)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("%s file could not be opened" % label)
	var length := file.get_length()
	if length <= 0 or length > maximum_bytes:
		return _failure("%s byte length is outside the allowed range" % label)
	var bytes := file.get_buffer(length)
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return _failure("%s is not exact UTF-8" % label)
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return _failure("%s contains invalid JSON" % label)
	var normalized := CatalogLoader.normalize_json_boundary(parser.data)
	if not bool(normalized.get("ok", false)):
		var errors := PackedStringArray()
		for message: String in normalized.get("errors", []):
			errors.append("%s: %s" % [label, message])
		return {"errors": errors, "ok": false}
	var value: Variant = normalized["value"]
	if typeof(value) != expected_type:
		return _failure("%s root has the wrong JSON type" % label)
	if Codec.canonical_bytes(value) != bytes:
		return _failure("%s bytes are not canonical RFC 8785 JSON" % label)
	return {"bytes": bytes, "errors": PackedStringArray(), "ok": true, "value": value}


static func _write_artifacts(output_dir: String, artifacts: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if DirAccess.dir_exists_absolute(output_dir):
		var existing := DirAccess.get_files_at(output_dir)
		var directories := DirAccess.get_directories_at(output_dir)
		if not existing.is_empty() or not directories.is_empty():
			errors.append("output directory must not already contain files")
			return {"errors": errors, "ok": false}
	else:
		var make_error := DirAccess.make_dir_recursive_absolute(output_dir)
		if make_error != OK:
			errors.append("output directory could not be created: %d" % make_error)
			return {"errors": errors, "ok": false}
	var paths: Array = artifacts.keys()
	paths.sort()
	## Write the manifest last so its presence means all referenced role files
	## were durably handed to Godot's filesystem boundary first.
	paths.erase("replay-manifest.json")
	paths.append("replay-manifest.json")
	for path_variant: Variant in paths:
		var path := str(path_variant)
		if path.get_file() != path or "/" in path or "\\" in path:
			errors.append("runner produced an unsafe output path")
			break
		var bytes_variant: Variant = artifacts[path]
		if typeof(bytes_variant) != TYPE_PACKED_BYTE_ARRAY:
			errors.append("runner output %s is not bytes" % path)
			break
		var file := FileAccess.open(output_dir.path_join(path), FileAccess.WRITE)
		if file == null:
			errors.append("could not open output artifact %s" % path)
			break
		file.store_buffer(bytes_variant)
		file.flush()
		if file.get_error() != OK:
			errors.append("could not write output artifact %s" % path)
			break
	return {"errors": errors, "ok": errors.is_empty()}


static func _emit_error(values: Variant) -> void:
	var messages: Array = []
	if typeof(values) == TYPE_PACKED_STRING_ARRAY or typeof(values) == TYPE_ARRAY:
		for value: Variant in values:
			messages.append(str(value))
	else:
		messages.append(str(values))
	print(Codec.canonical_json({
		"errors": messages,
		"kind": "worldarena_duel_headless_error",
	}))


static func _is_absolute_path(path: String) -> bool:
	return path.begins_with("/")


static func _is_sha256(value: String) -> bool:
	if value.length() != 64 or value.to_lower() != value:
		return false
	var decoded := value.hex_decode()
	return decoded.size() == 32 and decoded.hex_encode() == value


static func _failure(message: String) -> Dictionary:
	return {"errors": PackedStringArray([message]), "ok": false}
