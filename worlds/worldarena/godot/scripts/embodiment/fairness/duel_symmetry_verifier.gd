class_name EmbodimentDuelSymmetryVerifier
extends RefCounted

## Validates complete duel layouts. Every non-central authored feature must name an
## explicit counterpart; this makes omissions fail closed instead of being inferred.


static func rotate_position_180(position_mt: Vector2i) -> Vector2i:
	return -position_mt


static func rotate_heading_180(heading: int) -> int:
	return posmod(heading + 4, 8)


static func validate_layout(layout: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var half_extent := int(layout.get("arena_half_extent_mt", 0))
	if half_extent <= 0:
		errors.append("arena_half_extent_invalid")
	var relay: Dictionary = layout.get("central_relay", {})
	if _position(relay) != Vector2i.ZERO:
		errors.append("central_relay_not_rotation_fixed")
	var participants: Dictionary = layout.get("participant_spawns", {})
	_validate_participants(participants, half_extent, errors)
	var features: Array = layout.get("features", [])
	_validate_features(features, half_extent, errors)
	return errors


static func _validate_participants(
	participants: Dictionary, half_extent: int, errors: PackedStringArray
) -> void:
	if participants.size() != 2 or not participants.has("participant_0") \
		or not participants.has("participant_1"):
		errors.append("participant_spawns_incomplete")
		return
	var first: Dictionary = participants.participant_0
	var second: Dictionary = participants.participant_1
	if not _inside(_position(first), half_extent) or not _inside(_position(second), half_extent):
		errors.append("participant_spawn_out_of_bounds")
	if rotate_position_180(_position(first)) != _position(second):
		errors.append("participant_spawn_position_asymmetric")
	if rotate_heading_180(int(first.get("heading", -1))) != int(second.get("heading", -1)):
		errors.append("participant_spawn_heading_asymmetric")


static func _validate_features(
	features: Array, half_extent: int, errors: PackedStringArray
) -> void:
	var by_id := {}
	for raw_feature: Variant in features:
		if not raw_feature is Dictionary:
			errors.append("feature_not_object")
			continue
		var feature: Dictionary = raw_feature
		var feature_id := str(feature.get("id", ""))
		if feature_id.is_empty() or by_id.has(feature_id):
			errors.append("feature_id_invalid_or_duplicate")
			continue
		by_id[feature_id] = feature
		if not _inside(_position(feature), half_extent):
			errors.append("feature_out_of_bounds:%s" % feature_id)
	var feature_ids: Array = by_id.keys()
	feature_ids.sort()
	for feature_id_raw: Variant in feature_ids:
		var feature_id := str(feature_id_raw)
		var feature: Dictionary = by_id[feature_id]
		var mirror_id := str(feature.get("mirror_id", ""))
		if not by_id.has(mirror_id):
			errors.append("feature_mirror_missing:%s" % feature_id)
			continue
		var mirror: Dictionary = by_id[mirror_id]
		if str(mirror.get("mirror_id", "")) != feature_id:
			errors.append("feature_mirror_not_involution:%s" % feature_id)
		if rotate_position_180(_position(feature)) != _position(mirror):
			errors.append("feature_position_asymmetric:%s" % feature_id)
		if not _same_properties(feature, mirror):
			errors.append("feature_properties_asymmetric:%s" % feature_id)


static func _same_properties(first: Dictionary, second: Dictionary) -> bool:
	var ignored := ["id", "mirror_id", "position_mt"]
	var first_keys: Array = first.keys().filter(func(key: Variant) -> bool: return key not in ignored)
	var second_keys: Array = second.keys().filter(func(key: Variant) -> bool: return key not in ignored)
	first_keys.sort()
	second_keys.sort()
	if first_keys != second_keys:
		return false
	for key: Variant in first_keys:
		if first[key] != second[key]:
			return false
	return true


static func _position(item: Dictionary) -> Vector2i:
	var raw: Variant = item.get("position_mt", [])
	if raw is Vector2i:
		return raw
	if raw is Array and raw.size() == 2 and raw[0] is int and raw[1] is int:
		return Vector2i(raw[0], raw[1])
	return Vector2i(2_147_483_647, 2_147_483_647)


static func _inside(position_mt: Vector2i, half_extent: int) -> bool:
	return half_extent > 0 and abs(position_mt.x) <= half_extent \
		and abs(position_mt.y) <= half_extent
