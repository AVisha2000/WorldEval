class_name DuelIntentResolutionContext
extends RefCounted

const Contract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Closed, frozen resolver used by the authoritative intent bridge.
##
## Compiled intents carry internal IDs only as tamper-evident hints.  Execution
## always starts from the public alias and proves that the hint agrees with this
## context.  The protected tie key is deliberately excluded from public and
## canonical output.

const REQUIRED_FIELDS: Array[String] = ["entities", "world_max_inclusive_mt"]
const OPTIONAL_FIELDS: Array[String] = [
	"default_deposit_by_seat",
	"field_revival_tavern_by_seat",
	"gather_travel_ticks",
	"queue_entries",
	"region_slots",
	"sites",
	"transport_capacities",
	"transport_range_mt",
]
const ENTITY_REQUIRED: Array[String] = ["internal_id", "owner_seat"]
const ENTITY_OPTIONAL: Array[String] = ["neutral_building_id"]
const SITE_REQUIRED: Array[String] = ["xy_mt"]
const SITE_OPTIONAL: Array[String] = ["internal_object_id"]
const REGION_SLOT_REQUIRED: Array[String] = ["xy_mt"]
const REGION_SLOT_OPTIONAL: Array[String] = []
const QUEUE_ENTRY_REQUIRED: Array[String] = ["internal_entry_id", "producer_alias"]
const QUEUE_ENTRY_OPTIONAL: Array[String] = []

var _frozen: Dictionary = {}
var _protected_tie_key := PackedByteArray()
var _reverse_entity_aliases: Dictionary = {}
var _configured: bool = false


func configure(value_input: Dictionary, protected_tie_key: PackedByteArray) -> PackedStringArray:
	_configured = false
	_frozen.clear()
	_reverse_entity_aliases.clear()
	_protected_tie_key.clear()
	var errors := PackedStringArray()
	var value: Dictionary = value_input.duplicate(true)
	if protected_tie_key.is_empty():
		errors.append("intent resolution context requires a protected tie key")
	if not _has_exact_fields(value, REQUIRED_FIELDS, OPTIONAL_FIELDS):
		errors.append("intent resolution context has missing or unknown fields")
		return errors
	if typeof(value.get("entities", null)) != TYPE_DICTIONARY:
		errors.append("intent resolution context entities must be an object")
	if not _valid_point(value.get("world_max_inclusive_mt", null), true):
		errors.append("intent resolution context world bounds are invalid")
	for field: String in [
		"default_deposit_by_seat", "field_revival_tavern_by_seat", "queue_entries", "region_slots", "sites",
		"transport_capacities",
	]:
		if value.has(field) and typeof(value[field]) != TYPE_DICTIONARY:
			errors.append("intent resolution context %s must be an object" % field)
	if value.has("gather_travel_ticks"):
		var travel: Variant = value["gather_travel_ticks"]
		if typeof(travel) != TYPE_DICTIONARY \
			or not _has_exact_fields(travel, ["return", "to_resource"], []) \
			or typeof((travel as Dictionary)["return"]) != TYPE_INT \
			or typeof((travel as Dictionary)["to_resource"]) != TYPE_INT \
			or int((travel as Dictionary)["return"]) < 0 \
			or int((travel as Dictionary)["to_resource"]) < 0:
			errors.append("intent resolution context gather travel ticks are invalid")
	if value.has("transport_range_mt") \
		and (typeof(value["transport_range_mt"]) != TYPE_INT \
		or int(value["transport_range_mt"]) < 0):
		errors.append("intent resolution context transport range is invalid")

	var reverse: Dictionary = {}
	if typeof(value.get("entities", null)) == TYPE_DICTIONARY:
		var aliases: Array = (value["entities"] as Dictionary).keys()
		aliases.sort()
		for alias_variant: Variant in aliases:
			var alias := str(alias_variant)
			var record_variant: Variant = (value["entities"] as Dictionary)[alias_variant]
			if not Contract.is_entity_id(alias) or typeof(record_variant) != TYPE_DICTIONARY:
				errors.append("intent resolution context entity alias is invalid: %s" % alias)
				continue
			var record: Dictionary = record_variant
			if not _has_exact_fields(record, ENTITY_REQUIRED, ENTITY_OPTIONAL) \
				or typeof(record.get("internal_id", null)) != TYPE_INT \
				or int(record.get("internal_id", 0)) <= 0 \
				or typeof(record.get("owner_seat", null)) != TYPE_INT \
				or int(record.get("owner_seat", -2)) < -1 \
				or int(record.get("owner_seat", -2)) > 1:
				errors.append("intent resolution context entity record is invalid: %s" % alias)
				continue
			if record.has("neutral_building_id") \
				and (typeof(record["neutral_building_id"]) != TYPE_STRING \
				or str(record["neutral_building_id"]).is_empty()):
				errors.append("intent resolution context neutral building ID is invalid: %s" % alias)
			var internal_id := int(record["internal_id"])
			if reverse.has(internal_id):
				errors.append("intent resolution context maps two aliases to one entity")
			else:
				reverse[internal_id] = alias

	_validate_point_records(value.get("sites", {}), SITE_REQUIRED, SITE_OPTIONAL, "site", errors)
	_validate_point_records(
		value.get("region_slots", {}), REGION_SLOT_REQUIRED, REGION_SLOT_OPTIONAL,
		"region slot", errors
	)
	_validate_records_in_bounds(value.get("sites", {}), value.get("world_max_inclusive_mt", []), "site", errors)
	_validate_records_in_bounds(
		value.get("region_slots", {}), value.get("world_max_inclusive_mt", []),
		"region slot", errors
	)
	_validate_queue_entries(value.get("queue_entries", {}), value.get("entities", {}), errors)
	_validate_default_deposits(value.get("default_deposit_by_seat", {}), value.get("entities", {}), errors)
	_validate_neutral_taverns(
		value.get("field_revival_tavern_by_seat", {}), value.get("entities", {}), errors
	)
	_validate_transport_capacities(value.get("transport_capacities", {}), value.get("entities", {}), errors)
	for message: String in Codec.validate_canonical_value(value, "$.intent_resolution_context"):
		errors.append(message)
	if not errors.is_empty():
		return errors

	_frozen = _canonicalize(value)
	_reverse_entity_aliases = reverse
	_protected_tie_key = protected_tie_key.duplicate()
	_configured = true
	return errors


func is_configured() -> bool:
	return _configured


func protected_tie_key() -> PackedByteArray:
	return _protected_tie_key.duplicate()


func public_snapshot() -> Dictionary:
	var result := _frozen.duplicate(true)
	for entity_variant: Variant in (result.get("entities", {}) as Dictionary).values():
		if typeof(entity_variant) != TYPE_DICTIONARY:
			continue
		(entity_variant as Dictionary).erase("internal_id")
		(entity_variant as Dictionary).erase("neutral_building_id")
	for entry_variant: Variant in (result.get("queue_entries", {}) as Dictionary).values():
		if typeof(entry_variant) == TYPE_DICTIONARY:
			(entry_variant as Dictionary).erase("internal_entry_id")
	for site_variant: Variant in (result.get("sites", {}) as Dictionary).values():
		if typeof(site_variant) == TYPE_DICTIONARY:
			(site_variant as Dictionary).erase("internal_object_id")
	result["protected_tie_key_sha256"] = Codec.sha256_bytes(_protected_tie_key)
	return result


func resolve_entity(reference: Variant, expected_owner: int = -2) -> Dictionary:
	if not _configured or typeof(reference) != TYPE_DICTIONARY:
		return _failure("invalid_reference")
	var value: Dictionary = reference
	if str(value.get("kind", "")) != "entity" \
		or typeof(value.get("public_id", null)) != TYPE_STRING:
		return _failure("invalid_reference")
	var public_id := str(value["public_id"])
	var entities: Dictionary = _frozen["entities"]
	if not entities.has(public_id):
		return _failure("unknown_entity")
	var record: Dictionary = entities[public_id]
	if value.has("internal_id") \
		and (typeof(value["internal_id"]) != TYPE_INT \
		or int(value["internal_id"]) != int(record["internal_id"])):
		return _failure("reference_mismatch")
	if expected_owner != -2 and int(record["owner_seat"]) != expected_owner:
		return _failure("not_owner")
	return {
		"internal_id": int(record["internal_id"]),
		"neutral_building_id": str(record.get("neutral_building_id", "")),
		"ok": true,
		"owner_seat": int(record["owner_seat"]),
		"public_id": public_id,
	}


func resolve_public_entity(public_id: String, expected_owner: int = -2) -> Dictionary:
	return resolve_entity({"kind": "entity", "public_id": public_id}, expected_owner)


func resolve_target(target: Variant) -> Dictionary:
	if not _configured or typeof(target) != TYPE_DICTIONARY:
		return _failure("invalid_target")
	var value: Dictionary = target
	match str(value.get("kind", "")):
		"entity":
			var resolved := resolve_entity(value)
			if not bool(resolved.get("ok", false)):
				return resolved
			return {
				"internal_id": int(resolved["internal_id"]),
				"kind": "entity",
				"ok": true,
				"public": {"kind": "entity", "public_id": str(resolved["public_id"])},
			}
		"point":
			if not _valid_point(value.get("xy_mt", null), true) \
				or not _point_in_bounds(value["xy_mt"]):
				return _failure("out_of_bounds")
			var point: Array = value["xy_mt"]
			return {
				"kind": "point", "ok": true,
				"public": {"kind": "point", "xy_mt": [int(point[0]), int(point[1])]},
				"xy_mt": [int(point[0]), int(point[1])],
			}
		"region_slot":
			var region_id := str(value.get("region_id", ""))
			var slot_id := str(value.get("slot_id", ""))
			var key := "%s|%s" % [region_id, slot_id]
			var slots: Dictionary = _frozen.get("region_slots", {})
			if not slots.has(key):
				return _failure("unknown_region_slot")
			var record: Dictionary = slots[key]
			if value.has("xy_mt") and not _same_point(value["xy_mt"], record["xy_mt"]):
				return _failure("reference_mismatch")
			return {
				"kind": "region_slot", "ok": true,
				"public": {"kind": "region_slot", "region_id": region_id, "slot_id": slot_id},
				"xy_mt": (record["xy_mt"] as Array).duplicate(),
			}
		"site":
			var site_id := str(value.get("site_id", ""))
			var sites: Dictionary = _frozen.get("sites", {})
			if not sites.has(site_id):
				return _failure("unknown_site")
			var record: Dictionary = sites[site_id]
			if value.has("xy_mt") and not _same_point(value["xy_mt"], record["xy_mt"]):
				return _failure("reference_mismatch")
			return {
				"internal_object_id": str(record.get("internal_object_id", site_id)),
				"kind": "site", "ok": true,
				"public": {"kind": "site", "site_id": site_id},
				"site_id": site_id,
				"xy_mt": (record["xy_mt"] as Array).duplicate(),
			}
	return _failure("invalid_target")


func resolve_queue_entry(public_entry_id: String, producer_public_id: String) -> Dictionary:
	var entries: Dictionary = _frozen.get("queue_entries", {})
	if not entries.has(public_entry_id):
		return _failure("target_unavailable")
	var record: Dictionary = entries[public_entry_id]
	if str(record["producer_alias"]) != producer_public_id:
		return _failure("reference_mismatch")
	return {
		"internal_entry_id": int(record["internal_entry_id"]),
		"ok": true,
		"public_entry_id": public_entry_id,
	}


func default_deposit_for_seat(seat: int) -> Dictionary:
	var deposits: Dictionary = _frozen.get("default_deposit_by_seat", {})
	var key := str(seat)
	if not deposits.has(key):
		return _failure("target_unavailable")
	return resolve_public_entity(str(deposits[key]), seat)


func gather_travel_ticks() -> Dictionary:
	var value: Dictionary = _frozen.get("gather_travel_ticks", {"return": 0, "to_resource": 0})
	return value.duplicate(true)


func field_revival_tavern_for_seat(seat: int) -> Dictionary:
	var taverns: Dictionary = _frozen.get("field_revival_tavern_by_seat", {})
	var key := str(seat)
	if not taverns.has(key):
		return _failure("target_unavailable")
	var result := resolve_public_entity(str(taverns[key]), -1)
	if not bool(result.get("ok", false)) or str(result.get("neutral_building_id", "")).is_empty():
		return _failure("target_unavailable")
	return result


func transport_capacity(public_id: String) -> int:
	return int((_frozen.get("transport_capacities", {}) as Dictionary).get(public_id, 0))


func transport_range_mt() -> int:
	return int(_frozen.get("transport_range_mt", 0))


func alias_for_internal_entity(internal_id: int) -> String:
	return str(_reverse_entity_aliases.get(internal_id, ""))


func neutral_building_id(public_entity_id: String) -> String:
	var entities: Dictionary = _frozen.get("entities", {})
	if not entities.has(public_entity_id):
		return ""
	return str((entities[public_entity_id] as Dictionary).get("neutral_building_id", ""))


func site_internal_object_id(site_id: String) -> String:
	var sites: Dictionary = _frozen.get("sites", {})
	if not sites.has(site_id):
		return ""
	return str((sites[site_id] as Dictionary).get("internal_object_id", site_id))


func _point_in_bounds(point_variant: Variant) -> bool:
	if not _valid_point(point_variant, true):
		return false
	var point: Array = point_variant
	var maximum: Array = _frozen["world_max_inclusive_mt"]
	return int(point[0]) <= int(maximum[0]) and int(point[1]) <= int(maximum[1])


static func _validate_point_records(
	records_variant: Variant,
	required: Array[String],
	optional: Array[String],
	label: String,
	errors: PackedStringArray
) -> void:
	if typeof(records_variant) != TYPE_DICTIONARY:
		return
	var records: Dictionary = records_variant
	var keys: Array = records.keys()
	keys.sort()
	for key_variant: Variant in keys:
		var key := str(key_variant)
		var record_variant: Variant = records[key_variant]
		if key.is_empty() or typeof(record_variant) != TYPE_DICTIONARY \
			or not _has_exact_fields(record_variant, required, optional):
			errors.append("intent resolution context %s record is invalid: %s" % [label, key])
			continue
		var record: Dictionary = record_variant
		if not _valid_point(record.get("xy_mt", null), true):
			errors.append("intent resolution context %s point is invalid: %s" % [label, key])
		if record.has("internal_object_id") \
			and (typeof(record["internal_object_id"]) != TYPE_STRING \
			or str(record["internal_object_id"]).is_empty()):
			errors.append("intent resolution context %s internal object ID is invalid: %s" % [label, key])


static func _validate_queue_entries(
	entries_variant: Variant,
	entities_variant: Variant,
	errors: PackedStringArray
) -> void:
	if typeof(entries_variant) != TYPE_DICTIONARY or typeof(entities_variant) != TYPE_DICTIONARY:
		return
	var entries: Dictionary = entries_variant
	var entities: Dictionary = entities_variant
	for key_variant: Variant in entries.keys():
		var key := str(key_variant)
		var record_variant: Variant = entries[key_variant]
		if not Contract.is_public_id(key) or typeof(record_variant) != TYPE_DICTIONARY \
			or not _has_exact_fields(record_variant, QUEUE_ENTRY_REQUIRED, QUEUE_ENTRY_OPTIONAL):
			errors.append("intent resolution context queue entry is invalid: %s" % key)
			continue
		var record: Dictionary = record_variant
		if typeof(record.get("internal_entry_id", null)) != TYPE_INT \
			or int(record.get("internal_entry_id", 0)) <= 0 \
			or typeof(record.get("producer_alias", null)) != TYPE_STRING \
			or not entities.has(str(record.get("producer_alias", ""))):
			errors.append("intent resolution context queue entry record is invalid: %s" % key)


static func _validate_records_in_bounds(
	records_variant: Variant,
	maximum_variant: Variant,
	label: String,
	errors: PackedStringArray
) -> void:
	if typeof(records_variant) != TYPE_DICTIONARY or not _valid_point(maximum_variant, true):
		return
	var maximum: Array = maximum_variant
	for key_variant: Variant in (records_variant as Dictionary).keys():
		var record_variant: Variant = (records_variant as Dictionary)[key_variant]
		if typeof(record_variant) != TYPE_DICTIONARY \
			or not _valid_point((record_variant as Dictionary).get("xy_mt", null), true):
			continue
		var point: Array = (record_variant as Dictionary)["xy_mt"]
		if int(point[0]) > int(maximum[0]) or int(point[1]) > int(maximum[1]):
			errors.append("intent resolution context %s is out of bounds: %s" % [
				label, str(key_variant),
			])


static func _validate_default_deposits(
	deposits_variant: Variant,
	entities_variant: Variant,
	errors: PackedStringArray
) -> void:
	if typeof(deposits_variant) != TYPE_DICTIONARY or typeof(entities_variant) != TYPE_DICTIONARY:
		return
	var deposits: Dictionary = deposits_variant
	var entities: Dictionary = entities_variant
	for key_variant: Variant in deposits.keys():
		var key := str(key_variant)
		if key not in ["0", "1"] or typeof(deposits[key_variant]) != TYPE_STRING \
			or not entities.has(str(deposits[key_variant])):
			errors.append("intent resolution context default deposit is invalid: %s" % key)


static func _validate_neutral_taverns(
	taverns_variant: Variant,
	entities_variant: Variant,
	errors: PackedStringArray
) -> void:
	if typeof(taverns_variant) != TYPE_DICTIONARY or typeof(entities_variant) != TYPE_DICTIONARY:
		return
	var taverns: Dictionary = taverns_variant
	var entities: Dictionary = entities_variant
	for key_variant: Variant in taverns.keys():
		var key := str(key_variant)
		var alias := str(taverns[key_variant])
		if key not in ["0", "1"] or typeof(taverns[key_variant]) != TYPE_STRING \
			or not entities.has(alias) or typeof(entities[alias]) != TYPE_DICTIONARY:
			errors.append("intent resolution context field-revival Tavern is invalid: %s" % key)
			continue
		var record: Dictionary = entities[alias]
		if int(record.get("owner_seat", -2)) != -1 \
			or str(record.get("neutral_building_id", "")).is_empty():
			errors.append("intent resolution context field-revival Tavern record is invalid: %s" % key)


static func _validate_transport_capacities(
	capacities_variant: Variant,
	entities_variant: Variant,
	errors: PackedStringArray
) -> void:
	if typeof(capacities_variant) != TYPE_DICTIONARY or typeof(entities_variant) != TYPE_DICTIONARY:
		return
	var capacities: Dictionary = capacities_variant
	var entities: Dictionary = entities_variant
	for alias_variant: Variant in capacities.keys():
		var alias := str(alias_variant)
		if not entities.has(alias) or typeof(capacities[alias_variant]) != TYPE_INT \
			or int(capacities[alias_variant]) < 0:
			errors.append("intent resolution context transport capacity is invalid: %s" % alias)


static func _canonicalize(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = value.keys()
	keys.sort()
	for key_variant: Variant in keys:
		var key := str(key_variant)
		result[key] = value[key_variant]
	return result


static func _has_exact_fields(value_variant: Variant, required: Array, optional: Array) -> bool:
	if typeof(value_variant) != TYPE_DICTIONARY:
		return false
	var value: Dictionary = value_variant
	var allowed: Dictionary = {}
	for field_variant: Variant in required:
		var field := str(field_variant)
		if not value.has(field):
			return false
		allowed[field] = true
	for field_variant: Variant in optional:
		allowed[str(field_variant)] = true
	for key_variant: Variant in value.keys():
		if typeof(key_variant) != TYPE_STRING or not allowed.has(str(key_variant)):
			return false
	return true


static func _valid_point(value: Variant, require_non_negative: bool) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2:
		return false
	var point: Array = value
	if typeof(point[0]) != TYPE_INT or typeof(point[1]) != TYPE_INT:
		return false
	return not require_non_negative or (int(point[0]) >= 0 and int(point[1]) >= 0)


static func _same_point(left: Variant, right: Variant) -> bool:
	return _valid_point(left, true) and _valid_point(right, true) \
		and int((left as Array)[0]) == int((right as Array)[0]) \
		and int((left as Array)[1]) == int((right as Array)[1])


static func _failure(code: String) -> Dictionary:
	return {"code": code, "ok": false}
