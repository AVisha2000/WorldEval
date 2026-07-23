class_name DuelCombatState
extends RefCounted

## Serializable authoritative state for the bounded Phase-4 combat slice.
## Runtime-only event and delta buffers live in DuelCombat; everything that may
## survive a tick boundary is represented here with integer/string values.

var enabled: bool = false
var attack_armor_catalog_id: String = ""
var faction_catalog_id: String = ""
var matrix_bp: Dictionary = {}
var combat_rules: Dictionary = {}
var catalog_profiles: Dictionary = {}
var actors: Dictionary = {}
var attack_orders: Dictionary = {}
var windups: Dictionary = {}
var projectiles: Dictionary = {}
var scheduled_effects: Dictionary = {}
var statuses: Dictionary = {}
var next_sequence_id: int = 1


func to_canonical_dict() -> Dictionary:
	return {
		"actors": _dictionary_values_sorted_by_int_key(actors),
		"attack_armor_catalog_id": attack_armor_catalog_id,
		"attack_orders": _dictionary_values_sorted_by_int_key(attack_orders),
		"catalog_profiles": _string_key_dictionary_canonical(catalog_profiles),
		"combat_rules": _canonical_dictionary(combat_rules),
		"enabled": enabled,
		"faction_catalog_id": faction_catalog_id,
		"matrix_bp": _canonical_dictionary(matrix_bp),
		"next_sequence_id": next_sequence_id,
		"projectiles": _dictionary_values_sorted_by_int_key(projectiles),
		"scheduled_effects": _dictionary_values_sorted_by_int_key(scheduled_effects),
		"statuses": _dictionary_values_sorted_by_int_key(statuses),
		"windups": _dictionary_values_sorted_by_int_key(windups),
	}


func validate(entities: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not enabled:
		return errors
	if attack_armor_catalog_id.is_empty() or faction_catalog_id.is_empty():
		errors.append("configured combat requires catalog IDs")
	if next_sequence_id <= 0:
		errors.append("next combat sequence ID must be positive")
	for attack_type_variant: Variant in matrix_bp.keys():
		var attack_type := str(attack_type_variant)
		if typeof(matrix_bp[attack_type_variant]) != TYPE_DICTIONARY:
			errors.append("combat matrix row %s must be an object" % attack_type)
			continue
		for armor_variant: Variant in (matrix_bp[attack_type_variant] as Dictionary).keys():
			if typeof((matrix_bp[attack_type_variant] as Dictionary)[armor_variant]) != TYPE_INT:
				errors.append("combat matrix %s/%s must be integer basis points" % [attack_type, armor_variant])
	for entity_id_variant: Variant in actors.keys():
		var entity_id := int(entity_id_variant)
		if not entities.has(entity_id):
			errors.append("combat actor %d has no entity" % entity_id)
		var actor: Dictionary = actors[entity_id_variant]
		if int(actor.get("entity_id", 0)) != entity_id:
			errors.append("combat actor dictionary key mismatch for %d" % entity_id)
		if str(actor.get("armor_class", "")).is_empty():
			errors.append("combat actor %d has no armor class" % entity_id)
		if str(actor.get("layer", "")) not in ["air", "ground"]:
			errors.append("combat actor %d has invalid layer" % entity_id)
		if int(actor.get("shield_hp", 0)) < 0:
			errors.append("combat actor %d has negative shield" % entity_id)
		if typeof(actor.get("attack", {})) != TYPE_DICTIONARY:
			errors.append("combat actor %d attack must be an object" % entity_id)
		if typeof(actor.get("ground_attack", {})) != TYPE_DICTIONARY:
			errors.append("combat actor %d ground_attack must be an object" % entity_id)
	for collection: Dictionary in [attack_orders, windups, projectiles, scheduled_effects, statuses]:
		for key_variant: Variant in collection.keys():
			if int(key_variant) <= 0 or typeof(collection[key_variant]) != TYPE_DICTIONARY:
				errors.append("combat sequence collections require positive integer keys and object values")
	return errors


static func _dictionary_values_sorted_by_int_key(source: Dictionary) -> Array:
	var keys: Array[int] = []
	for key_variant: Variant in source.keys():
		keys.append(int(key_variant))
	keys.sort()
	var result: Array = []
	for key: int in keys:
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
