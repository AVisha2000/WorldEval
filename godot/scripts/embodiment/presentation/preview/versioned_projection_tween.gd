class_name EmbodimentVersionedProjectionTween
extends RefCounted

## Interpolate only between two already participant-filtered v2/v3 presentation sources.
## This helper never reads authority state and never changes an observation or checkpoint.


static func interpolate(
		before: Dictionary, after: Dictionary, progress_milli: int, protocol_version: String,
) -> Dictionary:
	if progress_milli < 0 or progress_milli > 1000 \
			or before.get("participant_id") != after.get("participant_id") \
			or not before.get("operator") is Dictionary \
			or not after.get("operator") is Dictionary \
			or not before.get("visible_entities") is Array \
			or not after.get("visible_entities") is Array:
		return {}
	var position_key: String
	var axes: Array[String]
	var heading_modulus: int
	match protocol_version:
		"llm-controller/0.2.0":
			position_key = "position_mt"
			axes = ["x", "y"]
			heading_modulus = 8
		"llm-controller/0.3.0":
			position_key = "position_axial"
			axes = ["q", "r"]
			heading_modulus = 6
		_:
			return {}
	var output := after.duplicate(true)
	if not _interpolate_projection(
		before.operator, output.operator, progress_milli, position_key, axes, heading_modulus
	):
		return {}
	var before_entities := {}
	for value: Variant in before.visible_entities:
		if value is Dictionary and value.get("id") is String:
			before_entities[str(value.id)] = value
	for after_value: Variant in output.visible_entities:
		if not after_value is Dictionary:
			return {}
		var entity: Dictionary = after_value
		var previous: Variant = before_entities.get(str(entity.get("id", "")))
		if previous is Dictionary and previous.get("kind") == entity.get("kind") \
				and not _interpolate_projection(
					previous, entity, progress_milli, position_key, axes, heading_modulus
				):
			return {}
	return output


static func _interpolate_projection(
		before: Dictionary, after: Dictionary, progress_milli: int, position_key: String,
		axes: Array[String], heading_modulus: int,
) -> bool:
	var before_position: Variant = before.get(position_key)
	var after_position: Variant = after.get(position_key)
	if not before_position is Dictionary or not after_position is Dictionary:
		return false
	for axis: String in axes:
		if typeof(before_position.get(axis)) != TYPE_INT \
				or typeof(after_position.get(axis)) != TYPE_INT:
			return false
		var start: int = before_position[axis]
		var delta: int = int(after_position[axis]) - start
		after_position[axis] = start + int(delta * progress_milli / 1000)
	if before.has("heading") and after.has("heading"):
		if typeof(before.heading) != TYPE_INT or typeof(after.heading) != TYPE_INT:
			return false
		var start_heading: int = before.heading
		var heading_delta: int = int(after.heading) - start_heading
		while heading_delta > heading_modulus / 2:
			heading_delta -= heading_modulus
		while heading_delta < -heading_modulus / 2:
			heading_delta += heading_modulus
		after.presentation_heading_milli = posmod(
			start_heading * 1000 + heading_delta * progress_milli, heading_modulus * 1000
		)
	return true
