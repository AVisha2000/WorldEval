class_name DuelNeutralState
extends RefCounted

## Canonical, integer-only authority for camps, neutral services, drops, and
## expansion gates. Runtime dictionaries are keyed for efficient lookup; this
## class converts them to sorted arrays before checkpointing.

var enabled: bool = false
var tick: int = 0
var match_seed: int = 0
var ruleset_hash: String = ""
var protected_tie_key_commitment: String = ""
var map_id: String = ""
var map_raw_hash: String = ""
var catalog_hashes: Dictionary = {}

var camps: Dictionary = {}
var buildings: Dictionary = {}
var expansions: Dictionary = {}
var ground_drops: Dictionary = {}
var forced_night_effects: Dictionary = {}
var reveal_effects: Dictionary = {}
var reveal_cooldowns: Dictionary = {0: 0, 1: 0}
var contest_audit: Array[Dictionary] = []
var events: Array[Dictionary] = []
var next_reveal_effect_id: int = 1
var next_event_seq: int = 1


func reset() -> void:
	enabled = false
	tick = 0
	match_seed = 0
	ruleset_hash = ""
	protected_tie_key_commitment = ""
	map_id = ""
	map_raw_hash = ""
	catalog_hashes.clear()
	camps.clear()
	buildings.clear()
	expansions.clear()
	ground_drops.clear()
	forced_night_effects.clear()
	reveal_effects.clear()
	reveal_cooldowns = {0: 0, 1: 0}
	contest_audit.clear()
	events.clear()
	next_reveal_effect_id = 1
	next_event_seq = 1


func append_event(event_kind: String, source_id: String, target_id: String, payload: Dictionary) -> Dictionary:
	var event := {
		"event_kind": event_kind,
		"event_seq": next_event_seq,
		"payload": payload.duplicate(true),
		"source_id": source_id,
		"target_id": target_id,
		"tick": tick,
	}
	next_event_seq += 1
	events.append(event)
	return event.duplicate(true)


func allocate_reveal_effect_id() -> String:
	var result := "reveal_%08d" % next_reveal_effect_id
	next_reveal_effect_id += 1
	return result


func sorted_camp_ids() -> Array[String]:
	return _sorted_string_keys(camps)


func sorted_building_ids() -> Array[String]:
	return _sorted_string_keys(buildings)


func sorted_expansion_ids() -> Array[String]:
	return _sorted_string_keys(expansions)


func to_canonical_dict() -> Dictionary:
	var canonical_camps: Array = []
	for camp_id: String in sorted_camp_ids():
		var camp: Dictionary = camps[camp_id].duplicate(true)
		camp["members"] = _sorted_dictionary_values(camp["members"], "member_id")
		camp["summons"] = _sorted_int_string_dictionary_values(camp["summons"], "internal_id")
		camp["damage_by_seat"] = _canonical_damage_by_seat(camp["damage_by_seat"])
		canonical_camps.append(camp)

	var canonical_buildings: Array = []
	for building_id: String in sorted_building_ids():
		var building: Dictionary = buildings[building_id].duplicate(true)
		building["offers"] = _sorted_dictionary_values(building["offers"], "offer_id")
		canonical_buildings.append(building)

	var canonical_expansions: Array = []
	for expansion_id: String in sorted_expansion_ids():
		canonical_expansions.append(expansions[expansion_id].duplicate(true))

	var canonical_drops := _sorted_dictionary_values(ground_drops, "drop_id")
	var canonical_night := _sorted_dictionary_values(forced_night_effects, "effect_id")
	var canonical_reveals := _sorted_dictionary_values(reveal_effects, "effect_id")
	var cooldowns: Array = []
	for seat: int in [0, 1]:
		cooldowns.append({"cooldown_until_tick": int(reveal_cooldowns.get(seat, 0)), "seat": seat})

	var canonical_events: Array = []
	for event: Dictionary in events:
		canonical_events.append(event.duplicate(true))
	var canonical_audit: Array = []
	for entry: Dictionary in contest_audit:
		canonical_audit.append(entry.duplicate(true))

	return {
		"buildings": canonical_buildings,
		"camps": canonical_camps,
		"catalog_hashes": _sorted_dictionary(catalog_hashes),
		"contest_audit": canonical_audit,
		"enabled": enabled,
		"events": canonical_events,
		"expansions": canonical_expansions,
		"forced_night_effects": canonical_night,
		"ground_drops": canonical_drops,
		"map_id": map_id,
		"map_raw_hash": map_raw_hash,
		"match_seed": match_seed,
		"next_event_seq": next_event_seq,
		"next_reveal_effect_id": next_reveal_effect_id,
		"protected_tie_key_commitment": protected_tie_key_commitment,
		"reveal_cooldowns": cooldowns,
		"reveal_effects": canonical_reveals,
		"ruleset_hash": ruleset_hash,
		"tick": tick,
	}


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if not enabled:
		errors.append("neutral state is not enabled")
		return errors
	if tick < 0 or match_seed < 0:
		errors.append("neutral tick and match seed must be non-negative")
	if ruleset_hash.length() != 64 or map_raw_hash.length() != 64:
		errors.append("neutral authority hashes must be SHA-256 hex")
	if protected_tie_key_commitment.length() != 64:
		errors.append("protected tie key commitment must be SHA-256 hex")
	if next_reveal_effect_id <= 0 or next_event_seq <= 0:
		errors.append("neutral state next IDs must be positive")
	for seat: int in [0, 1]:
		if int(reveal_cooldowns.get(seat, -1)) < 0:
			errors.append("reveal cooldown for seat %d is invalid" % seat)
	for camp_id: String in sorted_camp_ids():
		var camp: Dictionary = camps[camp_id]
		if str(camp.get("camp_id", "")) != camp_id:
			errors.append("camp key mismatch for %s" % camp_id)
		if str(camp.get("status", "")) not in ["sleeping", "idle", "engaged", "returning", "cleared"]:
			errors.append("camp %s has an invalid status" % camp_id)
		if int(camp.get("total_level", 0)) <= 0 or int(camp.get("gold_bounty", -1)) < 0:
			errors.append("camp %s has invalid level or bounty" % camp_id)
		for member_id: String in _sorted_string_keys(camp.get("members", {})):
			var member: Dictionary = camp["members"][member_id]
			if str(member.get("member_id", "")) != member_id:
				errors.append("camp member key mismatch for %s" % member_id)
			if int(member.get("hp", -1)) < 0 or int(member.get("hp", 0)) > int(member.get("max_hp", 0)):
				errors.append("camp member %s has invalid HP" % member_id)
	for building_id: String in sorted_building_ids():
		var building: Dictionary = buildings[building_id]
		if str(building.get("building_id", "")) != building_id:
			errors.append("neutral building key mismatch for %s" % building_id)
		for offer_id: String in _sorted_string_keys(building.get("offers", {})):
			var offer: Dictionary = building["offers"][offer_id]
			if int(offer.get("current_stock", -2)) < -1:
				errors.append("offer %s/%s has invalid stock" % [building_id, offer_id])
			if int(offer.get("current_stock", 0)) > int(offer.get("maximum_stock", 0)) \
				and int(offer.get("maximum_stock", 0)) >= 0:
				errors.append("offer %s/%s exceeds maximum stock" % [building_id, offer_id])
	for drop_id: String in _sorted_string_keys(ground_drops):
		var drop: Dictionary = ground_drops[drop_id]
		if int(drop.get("despawn_tick", 0)) <= int(drop.get("spawn_tick", 0)):
			errors.append("ground drop %s has an invalid lifetime" % drop_id)
	return errors


static func _canonical_damage_by_seat(value: Dictionary) -> Array:
	var result: Array = []
	for seat: int in [0, 1]:
		var record: Dictionary = value.get(seat, {"records": [], "total": 0})
		var records: Array = []
		for record_variant: Variant in record.get("records", []):
			records.append((record_variant as Dictionary).duplicate(true))
		records.sort_custom(_damage_record_less)
		result.append({"records": records, "seat": seat, "total": int(record.get("total", 0))})
	return result


static func _sorted_dictionary(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: String in _sorted_string_keys(value):
		result[key] = value[key]
	return result


static func _sorted_dictionary_values(value: Dictionary, id_field: String) -> Array:
	var result: Array = []
	for key: String in _sorted_string_keys(value):
		var record: Dictionary = value[key].duplicate(true)
		if not record.has(id_field):
			record[id_field] = key
		result.append(record)
	return result


static func _sorted_int_string_dictionary_values(value: Dictionary, id_field: String) -> Array:
	var integer_keys: Array[int] = []
	for key_variant: Variant in value.keys():
		integer_keys.append(int(key_variant))
	integer_keys.sort()
	var result: Array = []
	for integer_key: int in integer_keys:
		var record: Dictionary = value.get(str(integer_key), value.get(integer_key, {})).duplicate(true)
		if not record.has(id_field):
			record[id_field] = integer_key
		result.append(record)
	return result


static func _sorted_string_keys(value: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_variant: Variant in value.keys():
		result.append(str(key_variant))
	result.sort()
	return result


static func _damage_record_less(left: Dictionary, right: Dictionary) -> bool:
	var left_key := [int(left.get("source_internal_id", 0)), str(left.get("command_digest", ""))]
	var right_key := [int(right.get("source_internal_id", 0)), str(right.get("command_digest", ""))]
	return left_key < right_key
