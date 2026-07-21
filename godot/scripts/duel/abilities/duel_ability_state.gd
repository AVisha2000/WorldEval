class_name DuelAbilityState
extends RefCounted

## Standalone integer-only authority for the locked ability catalogue.
##
## The match coordinator owns this beside DuelSimulation until abilities become
## a first-class field on DuelState. Dictionary keys are convenient internally;
## to_canonical_dict() converts them to stable, ID-sorted arrays.

var enabled: bool = false
var selected_faction_id: String = ""
var catalog_hashes: Dictionary = {}
var tick: int = 0
var next_cast_id: int = 1
var next_effect_id: int = 1
var actors: Dictionary = {}
var casts: Dictionary = {}
var scheduled_effects: Dictionary = {}
var persistent_effects: Dictionary = {}
var events: Array[Dictionary] = []
var next_event_seq: int = 1


func reset() -> void:
	enabled = false
	selected_faction_id = ""
	catalog_hashes.clear()
	tick = 0
	next_cast_id = 1
	next_effect_id = 1
	actors.clear()
	casts.clear()
	scheduled_effects.clear()
	persistent_effects.clear()
	events.clear()
	next_event_seq = 1


func allocate_cast_id() -> int:
	var result := next_cast_id
	next_cast_id += 1
	return result


func allocate_effect_id() -> int:
	var result := next_effect_id
	next_effect_id += 1
	return result


func append_event(kind: String, source_id: int, target_id: int, payload: Dictionary) -> void:
	events.append({
		"event_seq": next_event_seq,
		"kind": kind,
		"payload": payload.duplicate(true),
		"source_id": source_id,
		"target_id": target_id,
		"tick": tick,
	})
	next_event_seq += 1


func to_canonical_dict() -> Dictionary:
	return {
		"actors": _int_key_values(actors),
		"casts": _int_key_values(casts),
		"catalog_hashes": _canonical_dictionary(catalog_hashes),
		"enabled": enabled,
		"events": _canonical_array(events),
		"next_cast_id": next_cast_id,
		"next_effect_id": next_effect_id,
		"next_event_seq": next_event_seq,
		"persistent_effects": _int_key_values(persistent_effects),
		"scheduled_effects": _int_key_values(scheduled_effects),
		"selected_faction_id": selected_faction_id,
		"tick": tick,
	}


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if not enabled:
		errors.append("ability state is not enabled")
		return errors
	if selected_faction_id.is_empty():
		errors.append("ability state requires a selected faction")
	if tick < 0 or next_cast_id <= 0 or next_effect_id <= 0 or next_event_seq <= 0:
		errors.append("ability state counters must be non-negative/positive")
	for actor_id: int in _sorted_int_keys(actors):
		var actor: Dictionary = actors[actor_id]
		if int(actor.get("actor_id", 0)) != actor_id:
			errors.append("ability actor key mismatch for %d" % actor_id)
		if str(actor.get("owner_type_id", "")).is_empty():
			errors.append("ability actor %d is missing owner_type_id" % actor_id)
		if typeof(actor.get("ability_ranks", null)) != TYPE_DICTIONARY \
			or typeof(actor.get("cooldown_until_ticks", null)) != TYPE_DICTIONARY \
			or typeof(actor.get("autocast", null)) != TYPE_DICTIONARY:
			errors.append("ability actor %d has malformed ability dictionaries" % actor_id)
	for collection: Dictionary in [casts, scheduled_effects, persistent_effects]:
		for key_variant: Variant in collection.keys():
			if typeof(key_variant) != TYPE_INT or int(key_variant) <= 0 \
				or typeof(collection[key_variant]) != TYPE_DICTIONARY:
				errors.append("ability runtime collections require positive integer keys and objects")
	for message: String in DuelProtocolCodec.validate_canonical_value(to_canonical_dict()):
		errors.append(message)
	return errors


static func _int_key_values(source: Dictionary) -> Array:
	var result: Array = []
	for key: int in _sorted_int_keys(source):
		result.append(_canonical_dictionary(source[key]))
	return result


static func _sorted_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in source.keys():
		result.append(int(key_variant))
	result.sort()
	return result


static func _canonical_dictionary(source: Dictionary) -> Dictionary:
	var keys: Array = source.keys()
	keys.sort()
	var result: Dictionary = {}
	for key_variant: Variant in keys:
		var key := str(key_variant)
		var value: Variant = source[key_variant]
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
