class_name EmbodimentCheckpointSerializer
extends RefCounted


static func hash_checkpoint(checkpoint: Dictionary) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(canonical_json(checkpoint).to_utf8_buffer())
	return context.finish().hex_encode()


static func canonical_json(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_STRING:
			return JSON.stringify(value)
		TYPE_ARRAY:
			var array_items: PackedStringArray = []
			for item: Variant in value:
				array_items.append(canonical_json(item))
			return "[" + ",".join(array_items) + "]"
		TYPE_DICTIONARY:
			var keys := PackedStringArray()
			for key: Variant in value.keys():
				assert(typeof(key) == TYPE_STRING, "canonical JSON object keys must be strings")
				keys.append(key)
			keys.sort()
			var object_items := PackedStringArray()
			for key: String in keys:
				object_items.append(JSON.stringify(key) + ":" + canonical_json(value[key]))
			return "{" + ",".join(object_items) + "}"
		_:
			assert(false, "canonical JSON authority state contains a non-JSON or non-integer value")
			return ""


static func contains_float(value: Variant) -> bool:
	if typeof(value) == TYPE_FLOAT:
		return true
	if value is Array:
		for item: Variant in value:
			if contains_float(item):
				return true
	if value is Dictionary:
		for item: Variant in value.values():
			if contains_float(item):
				return true
	return false
