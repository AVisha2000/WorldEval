class_name DuelMovementState
extends RefCounted

## Serializable authority owned by deterministic movement. Per-tick intents and
## proposals are deliberately kept in DuelMovement's transient buffers; every
## value which can affect a later tick lives here.

var enabled: bool = false
var faction_catalog_id: String = ""
var protected_tie_key_digest: String = ""
var catalog_profiles: Dictionary = {}
## internal entity ID -> resolved movement profile/runtime record.
var actors: Dictionary = {}
## conflict signature -> consecutive-conflict record.
var conflicts: Dictionary = {}
## grid node ID -> altitude slot (0..3) -> internal entity ID.
var air_occupancy: Dictionary = {}
var next_sequence_id: int = 1


func to_canonical_dict() -> Dictionary:
	return {
		"actors": _dictionary_values_sorted_by_int_key(actors),
		"air_occupancy": _air_occupancy_canonical(),
		"catalog_profiles": _string_key_dictionary_canonical(catalog_profiles),
		"conflicts": _dictionary_values_sorted_by_string_key(conflicts),
		"enabled": enabled,
		"faction_catalog_id": faction_catalog_id,
		"next_sequence_id": next_sequence_id,
		"protected_tie_key_digest": protected_tie_key_digest,
	}


func validate(entities: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not enabled:
		return errors
	if faction_catalog_id.is_empty():
		errors.append("configured movement requires a faction catalog ID")
	if protected_tie_key_digest.length() != 64:
		errors.append("configured movement requires a SHA-256 tie-key digest")
	if next_sequence_id <= 0:
		errors.append("next movement sequence ID must be positive")
	for entity_id_variant: Variant in actors.keys():
		var entity_id := int(entity_id_variant)
		if not entities.has(entity_id):
			errors.append("movement actor %d has no entity" % entity_id)
		var actor: Dictionary = actors[entity_id_variant]
		if int(actor.get("entity_id", 0)) != entity_id:
			errors.append("movement actor dictionary key mismatch for %d" % entity_id)
		if str(actor.get("layer", "")) not in ["air", "ground"]:
			errors.append("movement actor %d has invalid layer" % entity_id)
		if int(actor.get("speed_mt_per_tick", -1)) < 0:
			errors.append("movement actor %d has negative speed" % entity_id)
		if int(actor.get("radius_mt", -1)) < 0:
			errors.append("movement actor %d has negative radius" % entity_id)
		var speed_remainder := int(actor.get("speed_remainder_bp", -1))
		if speed_remainder < 0 or speed_remainder >= 10_000:
			errors.append("movement actor %d has invalid speed remainder" % entity_id)
		var altitude_slot := int(actor.get("altitude_slot", -1))
		if str(actor.get("layer", "")) == "air" and (altitude_slot < 0 or altitude_slot > 3):
			errors.append("air actor %d has invalid altitude slot" % entity_id)
		if str(actor.get("layer", "")) == "ground" and altitude_slot != -1:
			errors.append("ground actor %d must not have an altitude slot" % entity_id)
		if typeof(actor.get("occupied_cells", null)) != TYPE_ARRAY:
			errors.append("movement actor %d occupied_cells must be an array" % entity_id)
	for signature_variant: Variant in conflicts.keys():
		var signature := str(signature_variant)
		var record: Dictionary = conflicts[signature_variant]
		if str(record.get("signature", "")) != signature:
			errors.append("movement conflict signature key mismatch")
		var count := int(record.get("consecutive_ticks", 0))
		if count < 1 or count > 2:
			errors.append("persisted movement conflict count must be one or two")
	for node_variant: Variant in air_occupancy.keys():
		var node_id := int(node_variant)
		if node_id < 0 or typeof(air_occupancy[node_variant]) != TYPE_DICTIONARY:
			errors.append("air occupancy requires non-negative node IDs and slot dictionaries")
			continue
		var lanes: Dictionary = air_occupancy[node_variant]
		for slot_variant: Variant in lanes.keys():
			var slot := int(slot_variant)
			var entity_id := int(lanes[slot_variant])
			if slot < 0 or slot > 3:
				errors.append("air occupancy slot must be in [0,3]")
			if not actors.has(entity_id) or str((actors[entity_id] as Dictionary).get("layer", "")) != "air":
				errors.append("air occupancy references an unregistered air actor")
	return errors


func _air_occupancy_canonical() -> Array:
	var node_ids: Array[int] = []
	for node_variant: Variant in air_occupancy.keys():
		node_ids.append(int(node_variant))
	node_ids.sort()
	var result: Array = []
	for node_id: int in node_ids:
		var lanes: Dictionary = air_occupancy[node_id]
		var slots: Array[int] = []
		for slot_variant: Variant in lanes.keys():
			slots.append(int(slot_variant))
		slots.sort()
		var canonical_lanes: Array = []
		for slot: int in slots:
			canonical_lanes.append({"actor_id": int(lanes[slot]), "slot": slot})
		result.append({"lanes": canonical_lanes, "node_id": node_id})
	return result


static func _dictionary_values_sorted_by_int_key(source: Dictionary) -> Array:
	var keys: Array[int] = []
	for key_variant: Variant in source.keys():
		keys.append(int(key_variant))
	keys.sort()
	var result: Array = []
	for key: int in keys:
		result.append(_canonical_dictionary(source[key]))
	return result


static func _dictionary_values_sorted_by_string_key(source: Dictionary) -> Array:
	var keys: Array[String] = []
	for key_variant: Variant in source.keys():
		keys.append(str(key_variant))
	keys.sort()
	var result: Array = []
	for key: String in keys:
		result.append(_canonical_dictionary(source[key]))
	return result


static func _string_key_dictionary_canonical(source: Dictionary) -> Dictionary:
	var keys: Array[String] = []
	for key_variant: Variant in source.keys():
		keys.append(str(key_variant))
	keys.sort()
	var result: Dictionary = {}
	for key: String in keys:
		result[key] = _canonical_dictionary(source[key])
	return result


static func _canonical_dictionary(source: Dictionary) -> Dictionary:
	var keys: Array[String] = []
	for key_variant: Variant in source.keys():
		keys.append(str(key_variant))
	keys.sort()
	var result: Dictionary = {}
	for key: String in keys:
		var value: Variant = source[key]
		if typeof(value) == TYPE_DICTIONARY:
			result[key] = _canonical_dictionary(value)
		elif typeof(value) == TYPE_ARRAY:
			result[key] = _canonical_array(value)
		else:
			result[key] = value
	return result


static func _canonical_array(source: Array) -> Array:
	var result: Array = []
	for value: Variant in source:
		if typeof(value) == TYPE_DICTIONARY:
			result.append(_canonical_dictionary(value))
		elif typeof(value) == TYPE_ARRAY:
			result.append(_canonical_array(value))
		else:
			result.append(value)
	return result
