class_name DuelProtocolCodec
extends RefCounted

## Restricted RFC 8785 JSON canonicalization for authoritative Duel values.
## The protocol intentionally forbids floats, packed/vector engine types, and
## non-string Dictionary keys. Arrays retain their semantic input order.

const MAX_SAFE_INTEGER := 9_007_199_254_740_991
const MIN_SAFE_INTEGER := -MAX_SAFE_INTEGER


static func canonical_json(value: Variant) -> String:
	var validation_errors := validate_canonical_value(value)
	if not validation_errors.is_empty():
		push_error("Cannot canonicalize value: %s" % "; ".join(validation_errors))
		return ""
	return _encode(value)


static func canonical_bytes(value: Variant) -> PackedByteArray:
	return canonical_json(value).to_utf8_buffer()


static func sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	var start_error := context.start(HashingContext.HASH_SHA256)
	if start_error != OK:
		push_error("Failed to initialize SHA-256 context: %d" % start_error)
		return ""
	var update_error := context.update(bytes)
	if update_error != OK:
		push_error("Failed to update SHA-256 context: %d" % update_error)
		return ""
	return context.finish().hex_encode()


static func sha256_text(text: String) -> String:
	return sha256_bytes(text.to_utf8_buffer())


static func sha256_canonical(value: Variant) -> String:
	var encoded := canonical_json(value)
	if encoded.is_empty():
		return ""
	return sha256_bytes(encoded.to_utf8_buffer())


static func validate_canonical_value(value: Variant, path: String = "$") -> PackedStringArray:
	var errors := PackedStringArray()
	_validate_recursive(value, path, errors)
	return errors


static func _validate_recursive(value: Variant, path: String, errors: PackedStringArray) -> void:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return
		TYPE_INT:
			var integer_value := int(value)
			if integer_value < MIN_SAFE_INTEGER or integer_value > MAX_SAFE_INTEGER:
				errors.append("%s: integer is outside the interoperable JCS range" % path)
		TYPE_FLOAT:
			errors.append("%s: floats are forbidden" % path)
		TYPE_ARRAY:
			var array_value: Array = value
			for index: int in array_value.size():
				_validate_recursive(array_value[index], "%s[%d]" % [path, index], errors)
		TYPE_DICTIONARY:
			var dictionary_value: Dictionary = value
			for key_variant: Variant in dictionary_value.keys():
				if typeof(key_variant) != TYPE_STRING:
					errors.append("%s: dictionary keys must be strings" % path)
					continue
				var key := str(key_variant)
				_validate_recursive(dictionary_value[key_variant], "%s.%s" % [path, key], errors)
		_:
			errors.append("%s: unsupported authoritative Variant type %d" % [path, typeof(value)])


static func _encode(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if bool(value) else "false"
		TYPE_INT:
			return str(int(value))
		TYPE_STRING:
			return _encode_string(str(value))
		TYPE_ARRAY:
			var parts: PackedStringArray = []
			for element: Variant in value:
				parts.append(_encode(element))
			return "[" + ",".join(parts) + "]"
		TYPE_DICTIONARY:
			var dictionary_value: Dictionary = value
			var keys: Array = dictionary_value.keys()
			keys.sort_custom(_jcs_key_less)
			var pairs: PackedStringArray = []
			for key_variant: Variant in keys:
				var key := str(key_variant)
				pairs.append(_encode_string(key) + ":" + _encode(dictionary_value[key_variant]))
			return "{" + ",".join(pairs) + "}"
	return ""


static func _encode_string(value: String) -> String:
	var encoded := "\""
	for index: int in value.length():
		var code := value.unicode_at(index)
		match code:
			8:
				encoded += "\\b"
			9:
				encoded += "\\t"
			10:
				encoded += "\\n"
			12:
				encoded += "\\f"
			13:
				encoded += "\\r"
			34:
				encoded += "\\\""
			92:
				encoded += "\\\\"
			_:
				if code >= 0 and code <= 31:
					encoded += "\\u%04x" % code
				else:
					encoded += String.chr(code)
	return encoded + "\""


## RFC 8785 sorts property names by their UTF-16 code units. Godot strings are
## Unicode scalar sequences, so non-BMP code points are expanded explicitly.
static func _jcs_key_less(left_variant: Variant, right_variant: Variant) -> bool:
	var left_units := _utf16_units(str(left_variant))
	var right_units := _utf16_units(str(right_variant))
	for index: int in mini(left_units.size(), right_units.size()):
		if left_units[index] != right_units[index]:
			return left_units[index] < right_units[index]
	return left_units.size() < right_units.size()


static func _utf16_units(value: String) -> Array[int]:
	var units: Array[int] = []
	for index: int in value.length():
		var code_point := value.unicode_at(index)
		if code_point <= 0xffff:
			units.append(code_point)
		else:
			var supplementary := code_point - 0x10000
			units.append(0xd800 + (supplementary >> 10))
			units.append(0xdc00 + (supplementary & 0x3ff))
	return units
