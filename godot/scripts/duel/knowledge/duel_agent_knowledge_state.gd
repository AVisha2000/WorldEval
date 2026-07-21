class_name DuelAgentKnowledgeState
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CoordinateFrame := preload("res://scripts/duel/knowledge/duel_coordinate_frame.gd")
const AliasBook := preload("res://scripts/duel/knowledge/duel_alias_book.gd")

## The only legal input boundary for a future ObservationBuilder.  Protected
## internal-ID associations remain here; public_projection() contains no world
## IDs, salt, world checkpoint hash, or hidden live object references.

var observer_seat: int = -1
var current_tick: int = 0
var coordinate_frame: CoordinateFrame
var alias_book: AliasBook

var _owned_by_internal: Dictionary = {}
var _contacts_by_internal: Dictionary = {}
var _visible_cell_ids: Dictionary = {}
var _explored_cell_ids: Dictionary = {}
var _visible_region_ids: Dictionary = {}
var _explored_region_ids: Dictionary = {}
var _events_since_previous: Array[Dictionary] = []
var _next_event_seq: int = 1
var _configured: bool = false


func configure(
	p_observer_seat: int,
	alias_salt: PackedByteArray,
	map_manifest: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	coordinate_frame = CoordinateFrame.new()
	errors.append_array(coordinate_frame.configure(p_observer_seat, map_manifest))
	alias_book = AliasBook.new()
	errors.append_array(alias_book.configure(p_observer_seat, alias_salt))
	if not errors.is_empty():
		return errors
	observer_seat = p_observer_seat
	current_tick = 0
	_owned_by_internal.clear()
	_contacts_by_internal.clear()
	_visible_cell_ids.clear()
	_explored_cell_ids.clear()
	_visible_region_ids.clear()
	_explored_region_ids.clear()
	_events_since_previous.clear()
	_next_event_seq = 1
	_configured = true
	return errors


func is_configured() -> bool:
	return _configured


func begin_phase_12(
	tick: int,
	visible_cell_ids: Array,
	grid_snapshot: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _configured:
		errors.append("knowledge state is not configured")
		return errors
	if tick < current_tick:
		errors.append("phase-12 tick cannot move backwards")
		return errors
	current_tick = tick
	_visible_cell_ids.clear()
	_visible_region_ids.clear()
	for id_variant: Variant in visible_cell_ids:
		var node_id := int(id_variant)
		_visible_cell_ids[node_id] = true
		_explored_cell_ids[node_id] = true
		var region_id := _region_id_at(grid_snapshot, node_id)
		if not region_id.is_empty():
			var canonical_region := coordinate_frame.world_public_id_to_self(region_id)
			_visible_region_ids[canonical_region] = true
			_explored_region_ids[canonical_region] = true
	_events_since_previous.clear()
	return errors


func replace_owned_records(records_by_internal: Dictionary) -> void:
	## The projector supplied deep-copied canonical records.  Duplicate again at
	## the ownership boundary so later mutation of a local temporary is harmless.
	_owned_by_internal = records_by_internal.duplicate(true)


func contact_if_known(internal_id: int) -> Dictionary:
	if not _contacts_by_internal.has(internal_id):
		return {}
	return (_contacts_by_internal[internal_id] as Dictionary).duplicate(true)


func protected_contact_internal_ids() -> Array[int]:
	var ids: Array[int] = []
	for id_variant: Variant in _contacts_by_internal.keys():
		ids.append(int(id_variant))
	ids.sort()
	return ids


func set_contact(internal_id: int, record: Dictionary) -> void:
	_contacts_by_internal[internal_id] = record.duplicate(true)


func alias_if_known(internal_id: int) -> String:
	return alias_book.alias_if_known(internal_id)


func ensure_alias(internal_id: int) -> String:
	return alias_book.ensure_alias(internal_id)


func tombstone_alias(internal_id: int) -> bool:
	return alias_book.tombstone(internal_id)


func is_owned_internal_id(internal_id: int) -> bool:
	return _owned_by_internal.has(internal_id)


func is_currently_visible_internal_id(internal_id: int) -> bool:
	if not _contacts_by_internal.has(internal_id):
		return false
	return str((_contacts_by_internal[internal_id] as Dictionary).get("knowledge_state", "")) == "visible"


func is_cell_currently_visible(node_id: int) -> bool:
	return _visible_cell_ids.has(node_id)


func emit_event_drafts(event_drafts: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	for index: int in event_drafts.size():
		var draft_variant: Variant = event_drafts[index]
		if typeof(draft_variant) != TYPE_DICTIONARY:
			errors.append("event draft %d must be an object" % index)
			continue
		var draft: Dictionary = (draft_variant as Dictionary).duplicate(true)
		for error: String in Codec.validate_canonical_value(draft, "$.event_draft"):
			errors.append(error)
		if not errors.is_empty():
			continue
		draft["event_seq"] = _next_event_seq
		draft["audience"] = "self"
		_next_event_seq += 1
		_events_since_previous.append(draft)
	return errors


func public_projection() -> Dictionary:
	var owned: Array = []
	for record_variant: Variant in _owned_by_internal.values():
		owned.append((record_variant as Dictionary).duplicate(true))
	owned.sort_custom(_public_entity_less)

	var visible: Array = []
	var remembered: Array = []
	var destroyed: Array = []
	for internal_id: int in protected_contact_internal_ids():
		var contact: Dictionary = _contacts_by_internal[internal_id]
		var state := str(contact.get("knowledge_state", ""))
		if state == "visible":
			visible.append((contact["visible_contact"] as Dictionary).duplicate(true))
		elif state == "remembered" or state == "unlocated":
			remembered.append(_remembered_public_record(contact))
		elif state == "destroyed":
			destroyed.append({
				"entity_id": str(contact["entity_id"]),
				"last_seen_tick": int(contact["last_seen_tick"]),
				"owner_category": str(contact["owner_category"]),
				"type_id": str(contact["type_id"]),
			})
	visible.sort_custom(_public_entity_less)
	remembered.sort_custom(_public_entity_less)
	destroyed.sort_custom(_public_entity_less)

	var visible_regions := _sorted_string_keys(_visible_region_ids)
	var explored_regions := _sorted_string_keys(_explored_region_ids)
	var events: Array = []
	for event: Dictionary in _events_since_previous:
		events.append(event.duplicate(true))
	return {
		"destroyed_contacts": destroyed,
		"events_since_previous": events,
		"map_state": {
			"explored_region_ids": explored_regions,
			"local_context": [],
			"terrain_changes": [],
			"visible_region_ids": visible_regions,
		},
		"owned_entities": owned,
		"remembered_contacts": remembered,
		"tick": current_tick,
		"visible_contacts": visible,
	}


func public_projection_hash() -> String:
	return Codec.sha256_canonical(public_projection())


func to_protected_canonical_dict() -> Dictionary:
	var owned_rows: Array = []
	var owned_ids: Array[int] = []
	for id_variant: Variant in _owned_by_internal.keys():
		owned_ids.append(int(id_variant))
	owned_ids.sort()
	for internal_id: int in owned_ids:
		owned_rows.append({
			"internal_id": internal_id,
			"record": (_owned_by_internal[internal_id] as Dictionary).duplicate(true),
		})
	var contact_rows: Array = []
	for internal_id: int in protected_contact_internal_ids():
		contact_rows.append({
			"internal_id": internal_id,
			"record": (_contacts_by_internal[internal_id] as Dictionary).duplicate(true),
		})
	return {
		"aliases": alias_book.to_protected_canonical_dict(),
		"contacts": contact_rows,
		"current_tick": current_tick,
		"events_since_previous": _events_since_previous.duplicate(true),
		"explored_cell_ids": _sorted_int_keys(_explored_cell_ids),
		"next_event_seq": _next_event_seq,
		"observer_seat": observer_seat,
		"owned": owned_rows,
		"visible_cell_ids": _sorted_int_keys(_visible_cell_ids),
	}


func _remembered_public_record(contact: Dictionary) -> Dictionary:
	return {
		"entity_id": str(contact["entity_id"]),
		"first_seen_tick": int(contact["first_seen_tick"]),
		"last_location_status": (
			"unlocated" if str(contact["knowledge_state"]) == "unlocated" else "unverified"
		),
		"last_observed": (contact["last_observed"] as Dictionary).duplicate(true),
		"last_seen_tick": int(contact["last_seen_tick"]),
		"memory_age_ticks": maxi(0, current_tick - int(contact["last_seen_tick"])),
		"owner_category": str(contact["owner_category"]),
		"type_id": str(contact["type_id"]),
	}


static func _region_id_at(grid_snapshot: Dictionary, node_id: int) -> String:
	if not grid_snapshot.has("region_ids") or typeof(grid_snapshot["region_ids"]) != TYPE_ARRAY:
		return ""
	var regions: Array = grid_snapshot["region_ids"]
	if node_id < 0 or node_id >= regions.size():
		return ""
	return str(regions[node_id])


static func _public_entity_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("entity_id", "")) < str(right.get("entity_id", ""))


static func _sorted_int_keys(values: Dictionary) -> Array:
	var result: Array[int] = []
	for value: Variant in values.keys():
		result.append(int(value))
	result.sort()
	var untyped: Array = []
	untyped.assign(result)
	return untyped


static func _sorted_string_keys(values: Dictionary) -> Array:
	var result: Array[String] = []
	for value: Variant in values.keys():
		result.append(str(value))
	result.sort()
	var untyped: Array = []
	untyped.assign(result)
	return untyped
