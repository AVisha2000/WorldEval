class_name DuelReplayBundleLoader
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Loads the materialized, content-addressed directories written by
## ImmutableArtifactBundle.write_directory().  Every byte is re-hashed and the
## exact canonical bundle envelope is reconstructed before anything is exposed
## to the replay verifier.

const BUNDLE_SCHEMA_VERSION := "worldeval-rts/artifact-bundle/1.0.0"
const EMPTY_SHA256 := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
const PUBLIC_LAYER := "publishable"
const PROTECTED_LAYER := "protected_audit"
const INDEX_FIELDS: Array[String] = [
	"artifacts", "index_sha256", "layer", "manifest", "schema_version",
]
const MANIFEST_DESCRIPTOR_FIELDS: Array[String] = [
	"bytes", "media_type", "path", "sha256",
]
const ARTIFACT_DESCRIPTOR_FIELDS: Array[String] = [
	"bytes", "media_type", "path", "role", "sha256",
]


## Godot's generic JSON decoder represents every numeric token as a float.
## Official Duel JSON forbids floats and requires interoperable integers, so
## replay boundaries use this deliberately small integer-preserving decoder
## before re-encoding the value to prove byte-for-byte canonical form.
class RestrictedCanonicalJsonParser:
	extends RefCounted

	const MAX_DEPTH := 64
	const MAX_SAFE_INTEGER := 9_007_199_254_740_991

	var source: String
	var cursor := 0
	var failure := ""


	func _init(source_input: String) -> void:
		source = source_input


	func parse() -> Variant:
		var value: Variant = _value(0)
		if failure.is_empty() and cursor != source.length():
			failure = "trailing bytes follow the JSON value"
		return value


	func _value(depth: int) -> Variant:
		if depth > MAX_DEPTH:
			failure = "JSON nesting exceeds the replay limit"
			return null
		if cursor >= source.length():
			failure = "JSON value ended unexpectedly"
			return null
		match source.unicode_at(cursor):
			123:
				return _object(depth + 1)
			91:
				return _array(depth + 1)
			34:
				return _string()
			116:
				return _literal("true", true)
			102:
				return _literal("false", false)
			110:
				return _literal("null", null)
			45, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
				return _integer()
		failure = "JSON contains an unsupported token"
		return null


	func _object(depth: int) -> Variant:
		cursor += 1
		var result: Dictionary = {}
		if _consume(125):
			return result
		while failure.is_empty():
			if cursor >= source.length() or source.unicode_at(cursor) != 34:
				failure = "JSON object key must be a string"
				return null
			var key_variant: Variant = _string()
			if not failure.is_empty():
				return null
			var key := str(key_variant)
			if result.has(key):
				failure = "JSON object key is duplicated"
				return null
			if not _consume(58):
				failure = "JSON object key has no value separator"
				return null
			result[key] = _value(depth)
			if not failure.is_empty():
				return null
			if _consume(125):
				return result
			if not _consume(44):
				failure = "JSON object entries are not comma-separated"
				return null
		return null


	func _array(depth: int) -> Variant:
		cursor += 1
		var result: Array = []
		if _consume(93):
			return result
		while failure.is_empty():
			result.append(_value(depth))
			if not failure.is_empty():
				return null
			if _consume(93):
				return result
			if not _consume(44):
				failure = "JSON array entries are not comma-separated"
				return null
		return null


	func _string() -> Variant:
		if not _consume(34):
			failure = "JSON string is missing its opening quote"
			return null
		var result := ""
		while cursor < source.length():
			var code := source.unicode_at(cursor)
			cursor += 1
			if code == 34:
				return result
			if code < 32:
				failure = "JSON string contains an unescaped control character"
				return null
			if code != 92:
				result += String.chr(code)
				continue
			if cursor >= source.length():
				failure = "JSON string escape is truncated"
				return null
			var escaped := source.unicode_at(cursor)
			cursor += 1
			match escaped:
				34, 47, 92:
					result += String.chr(escaped)
				98:
					result += "\b"
				102:
					result += "\f"
				110:
					result += "\n"
				114:
					result += "\r"
				116:
					result += "\t"
				117:
					var unicode_value := _unicode_escape()
					if unicode_value < 0:
						return null
					result += String.chr(unicode_value)
				_:
					failure = "JSON string escape is invalid"
					return null
		failure = "JSON string is unterminated"
		return null


	func _unicode_escape() -> int:
		var first := _hex_quad()
		if first < 0:
			return -1
		if first >= 0xd800 and first <= 0xdbff:
			if not _consume(92) or not _consume(117):
				failure = "JSON high surrogate has no low surrogate"
				return -1
			var second := _hex_quad()
			if second < 0xdc00 or second > 0xdfff:
				failure = "JSON low surrogate is invalid"
				return -1
			return 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
		if first >= 0xdc00 and first <= 0xdfff:
			failure = "JSON contains an unpaired low surrogate"
			return -1
		return first


	func _hex_quad() -> int:
		if cursor + 4 > source.length():
			failure = "JSON unicode escape is truncated"
			return -1
		var value := 0
		for _index: int in 4:
			var digit := _hex_digit(source.unicode_at(cursor))
			cursor += 1
			if digit < 0:
				failure = "JSON unicode escape contains a non-hex digit"
				return -1
			value = value * 16 + digit
		return value


	func _integer() -> Variant:
		var start := cursor
		if source.unicode_at(cursor) == 45:
			cursor += 1
			if cursor >= source.length():
				failure = "JSON integer sign has no digits"
				return null
		if source.unicode_at(cursor) == 48:
			cursor += 1
			if cursor < source.length() and _is_digit(source.unicode_at(cursor)):
				failure = "JSON integer has a leading zero"
				return null
		else:
			if not _is_digit_one_to_nine(source.unicode_at(cursor)):
				failure = "JSON integer is invalid"
				return null
			while cursor < source.length() and _is_digit(source.unicode_at(cursor)):
				cursor += 1
		if cursor < source.length() and source.unicode_at(cursor) in [46, 69, 101]:
			failure = "JSON floats and exponents are forbidden"
			return null
		var token := source.substr(start, cursor - start)
		if not token.is_valid_int():
			failure = "JSON integer is outside the runtime range"
			return null
		var value := token.to_int()
		if value < -MAX_SAFE_INTEGER or value > MAX_SAFE_INTEGER:
			failure = "JSON integer is outside the interoperable range"
			return null
		return value


	func _literal(token: String, value: Variant) -> Variant:
		if source.substr(cursor, token.length()) != token:
			failure = "JSON literal is invalid"
			return null
		cursor += token.length()
		return value


	func _consume(expected: int) -> bool:
		if cursor < source.length() and source.unicode_at(cursor) == expected:
			cursor += 1
			return true
		return false


	static func _hex_digit(code: int) -> int:
		if code >= 48 and code <= 57:
			return code - 48
		if code >= 65 and code <= 70:
			return code - 65 + 10
		if code >= 97 and code <= 102:
			return code - 97 + 10
		return -1


	static func _is_digit(code: int) -> bool:
		return code >= 48 and code <= 57


	static func _is_digit_one_to_nine(code: int) -> bool:
		return code >= 49 and code <= 57


func load_materialized(
	public_directory: String,
	protected_directory: String,
	expected_public_sha256: String = "",
	expected_protected_sha256: String = ""
) -> Dictionary:
	var public_result := _load_layer(
		public_directory, PUBLIC_LAYER, expected_public_sha256
	)
	if not bool(public_result.get("ok", false)):
		return public_result
	var protected_result := _load_layer(
		protected_directory, PROTECTED_LAYER, expected_protected_sha256
	)
	if not bool(protected_result.get("ok", false)):
		return protected_result
	return {
		"errors": PackedStringArray(),
		"ok": true,
		"package": {
			"protected": protected_result["layer"],
			"public": public_result["layer"],
		},
	}


static func parse_canonical_value(
	bytes: PackedByteArray, context: String, errors: PackedStringArray
) -> Variant:
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		errors.append("%s is not exact UTF-8" % context)
		return null
	var parser := RestrictedCanonicalJsonParser.new(text)
	var value: Variant = parser.parse()
	if not parser.failure.is_empty():
		errors.append("%s is invalid restricted JSON: %s" % [context, parser.failure])
		return null
	var canonical := Codec.canonical_json(value)
	if canonical.is_empty() or canonical.to_utf8_buffer() != bytes:
		errors.append("%s is not canonical JSON" % context)
		return null
	return value


func _load_layer(directory: String, expected_layer: String, expected_hash: String) -> Dictionary:
	var errors := PackedStringArray()
	if directory.is_empty() or not DirAccess.dir_exists_absolute(directory):
		errors.append("bundle directory is absent: %s" % directory)
		return _failure("bundle_directory_absent", errors)
	if not expected_hash.is_empty() and not _is_sha256(expected_hash):
		errors.append("expected bundle content hash is invalid")
		return _failure("invalid_expected_hash", errors)

	var index_path := directory.path_join("bundle-index.json")
	var index_bytes := _read_bytes(index_path, errors)
	if not errors.is_empty():
		return _failure("bundle_index_unreadable", errors)
	var parsed_index := _canonical_object(index_bytes, "bundle index", errors)
	if not errors.is_empty():
		return _failure("bundle_index_not_canonical", errors)
	var index: Dictionary = parsed_index
	_exact_fields(index, INDEX_FIELDS, "bundle index", errors)
	if str(index.get("schema_version", "")) != BUNDLE_SCHEMA_VERSION:
		errors.append("bundle index schema_version is unsupported")
	if str(index.get("layer", "")) != expected_layer:
		errors.append("bundle layer does not match the expected layer")
	if not _is_sha256(index.get("index_sha256")):
		errors.append("bundle index_sha256 is invalid")
	else:
		var index_body := index.duplicate(true)
		index_body.erase("index_sha256")
		if Codec.sha256_canonical(index_body) != str(index["index_sha256"]):
			errors.append("bundle index SHA-256 mismatch")
	if typeof(index.get("manifest")) != TYPE_DICTIONARY:
		errors.append("bundle manifest descriptor must be an object")
	if typeof(index.get("artifacts")) != TYPE_ARRAY:
		errors.append("bundle artifact descriptors must be an array")
	if not errors.is_empty():
		return _failure("bundle_index_invalid", errors)

	var manifest_descriptor: Dictionary = index["manifest"]
	_validate_descriptor(manifest_descriptor, true, errors)
	var expected_manifest_path := (
		"replay-manifest.json" if expected_layer == PUBLIC_LAYER
		else "protected-audit-manifest.json"
	)
	if str(manifest_descriptor.get("path", "")) != expected_manifest_path:
		errors.append("bundle manifest path disagrees with its layer")

	var descriptors: Array[Dictionary] = []
	var role_descriptors: Dictionary = {}
	var previous_key := ""
	for index_value: Variant in index["artifacts"]:
		if typeof(index_value) != TYPE_DICTIONARY:
			errors.append("bundle artifact descriptor must be an object")
			continue
		var descriptor: Dictionary = index_value
		_validate_descriptor(descriptor, false, errors)
		var role := str(descriptor.get("role", ""))
		var sort_key := role + "\u0000" + str(descriptor.get("path", ""))
		if not previous_key.is_empty() and sort_key < previous_key:
			errors.append("bundle artifacts are not in canonical role/path order")
		previous_key = sort_key
		if role_descriptors.has(role):
			errors.append("bundle artifact roles must be unique")
		else:
			role_descriptors[role] = descriptor.duplicate(true)
		descriptors.append(descriptor)
	if not errors.is_empty():
		return _failure("bundle_descriptor_invalid", errors)

	var payloads: Dictionary = {}
	var expected_paths: Dictionary = {"bundle-index.json": true}
	var all_descriptors: Array[Dictionary] = [manifest_descriptor]
	all_descriptors.append_array(descriptors)
	for descriptor: Dictionary in all_descriptors:
		var relative_path := str(descriptor["path"])
		if expected_paths.has(relative_path):
			continue
		expected_paths[relative_path] = true
		var payload := _read_bytes(directory.path_join(relative_path), errors)
		if errors.is_empty():
			_verify_payload(descriptor, payload, errors)
			payloads[relative_path] = payload
	if not errors.is_empty():
		return _failure("bundle_payload_mismatch", errors)

	var actual_paths: Array[String] = []
	_collect_relative_files(directory, directory, actual_paths, errors)
	actual_paths.sort()
	var expected_path_list: Array[String] = []
	for path_variant: Variant in expected_paths.keys():
		expected_path_list.append(str(path_variant))
	expected_path_list.sort()
	if actual_paths != expected_path_list:
		errors.append("materialized bundle file set differs from its index")
	if not errors.is_empty():
		return _failure("bundle_file_set_mismatch", errors)

	var manifest_bytes: PackedByteArray = payloads[str(manifest_descriptor["path"])]
	var parsed_manifest := _canonical_object(manifest_bytes, "bundle manifest", errors)
	if not errors.is_empty():
		return _failure("bundle_manifest_not_canonical", errors)
	var manifest: Dictionary = parsed_manifest
	var expected_files: Array = []
	for descriptor: Dictionary in descriptors:
		expected_files.append(descriptor.duplicate(true))
	if manifest.get("files") != expected_files:
		errors.append("bundle manifest files are not bound to the bundle index")
		return _failure("bundle_manifest_file_binding_mismatch", errors)

	var payload_rows: Array = []
	var payload_paths: Array[String] = []
	for path_variant: Variant in payloads.keys():
		payload_paths.append(str(path_variant))
	payload_paths.sort()
	for relative_path: String in payload_paths:
		payload_rows.append({
			"data_base64": _base64_bytes(payloads[relative_path]),
			"path": relative_path,
		})
	var content_sha256 := Codec.sha256_canonical({
		"index": index,
		"payloads": payload_rows,
	})
	if not expected_hash.is_empty() and content_sha256 != expected_hash:
		errors.append("bundle content SHA-256 mismatch")
		return _failure("bundle_content_hash_mismatch", errors)

	var artifacts: Dictionary = {}
	for role_variant: Variant in role_descriptors.keys():
		var role := str(role_variant)
		var descriptor: Dictionary = role_descriptors[role]
		artifacts[role] = {
			"bytes": (payloads[str(descriptor["path"])] as PackedByteArray).duplicate(),
			"descriptor": descriptor.duplicate(true),
		}
	return {
		"errors": errors,
		"layer": {
			"artifacts": artifacts,
			"content_sha256": content_sha256,
			"index": index.duplicate(true),
			"manifest": manifest.duplicate(true),
		},
		"ok": true,
	}


func _validate_descriptor(
	descriptor: Dictionary, is_manifest: bool, errors: PackedStringArray
) -> void:
	_exact_fields(
		descriptor,
		MANIFEST_DESCRIPTOR_FIELDS if is_manifest else ARTIFACT_DESCRIPTOR_FIELDS,
		"manifest descriptor" if is_manifest else "artifact descriptor",
		errors
	)
	if typeof(descriptor.get("bytes")) != TYPE_INT or int(descriptor.get("bytes", -1)) < 0:
		errors.append("bundle descriptor byte count is invalid")
	if not _is_sha256(descriptor.get("sha256")):
		errors.append("bundle descriptor SHA-256 is invalid")
	if str(descriptor.get("media_type", "")) not in [
		"application/json", "application/x-ndjson", "application/octet-stream",
	]:
		errors.append("bundle descriptor media type is invalid")
	var path := str(descriptor.get("path", ""))
	if not _safe_relative_path(path):
		errors.append("bundle descriptor path is unsafe")
	if not is_manifest:
		var role := str(descriptor.get("role", ""))
		if not _safe_role(role):
			errors.append("bundle artifact role is unsafe")
		if _is_sha256(descriptor.get("sha256")) \
			and path != "objects/sha256/" + str(descriptor["sha256"]):
			errors.append("artifact path is not content-addressed by its SHA-256")


func _verify_payload(
	descriptor: Dictionary, payload: PackedByteArray, errors: PackedStringArray
) -> void:
	if payload.size() != int(descriptor["bytes"]):
		errors.append("artifact byte-size mismatch: %s" % str(descriptor["path"]))
	if _sha256_bytes(payload) != str(descriptor["sha256"]):
		errors.append("artifact SHA-256 mismatch: %s" % str(descriptor["path"]))


func _canonical_object(
	bytes: PackedByteArray, context: String, errors: PackedStringArray
) -> Dictionary:
	var value: Variant = parse_canonical_value(bytes, context, errors)
	if typeof(value) != TYPE_DICTIONARY:
		if errors.is_empty():
			errors.append("%s is not a JSON object" % context)
		return {}
	return value


func _read_bytes(path: String, errors: PackedStringArray) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		errors.append("bundle file is absent: %s" % path)
		return PackedByteArray()
	var stream := FileAccess.open(path, FileAccess.READ)
	if stream == null:
		errors.append("bundle file could not be opened: %s" % path)
		return PackedByteArray()
	return stream.get_buffer(stream.get_length())


func _collect_relative_files(
	root_path: String,
	current_path: String,
	result: Array[String],
	errors: PackedStringArray
) -> void:
	var directory := DirAccess.open(current_path)
	if directory == null:
		errors.append("bundle directory could not be traversed")
		return
	directory.list_dir_begin()
	while true:
		var name := directory.get_next()
		if name.is_empty():
			break
		if name in [".", ".."]:
			continue
		if directory.is_link(name):
			errors.append("symlinks are forbidden in materialized bundles")
			continue
		var absolute := current_path.path_join(name)
		if directory.current_is_dir():
			_collect_relative_files(root_path, absolute, result, errors)
		else:
			result.append(absolute.trim_prefix(root_path + "/"))
	directory.list_dir_end()


static func _exact_fields(
	value: Dictionary, expected: Array[String], context: String, errors: PackedStringArray
) -> void:
	var actual: Array[String] = []
	for key_variant: Variant in value.keys():
		actual.append(str(key_variant))
	actual.sort()
	var wanted := expected.duplicate()
	wanted.sort()
	if actual != wanted:
		errors.append("%s fields are incomplete or unknown" % context)


static func _safe_relative_path(value: String) -> bool:
	if value.is_empty() or value.begins_with("/") or "\\" in value or "\u0000" in value:
		return false
	for part: String in value.split("/", false):
		if part.is_empty() or part in [".", ".."]:
			return false
	return true


static func _safe_role(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		if index == 0 and (code < 97 or code > 122):
			return false
		if index > 0 and not (
			(code >= 97 and code <= 122) or (code >= 48 and code <= 57) or code == 95
		):
			return false
	return true


static func _is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or str(value).length() != 64:
		return false
	var text := str(value)
	return text == text.to_lower() and text.hex_decode().size() == 32 \
		and text.hex_decode().hex_encode() == text


static func _sha256_bytes(bytes: PackedByteArray) -> String:
	return EMPTY_SHA256 if bytes.is_empty() else Codec.sha256_bytes(bytes)


static func _base64_bytes(bytes: PackedByteArray) -> String:
	return "" if bytes.is_empty() else Marshalls.raw_to_base64(bytes)


static func _failure(code: String, errors: PackedStringArray) -> Dictionary:
	return {
		"code": code,
		"errors": errors,
		"ok": false,
	}
