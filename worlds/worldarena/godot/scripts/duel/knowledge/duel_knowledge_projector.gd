class_name DuelKnowledgeProjector
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const Visibility := preload("res://scripts/duel/knowledge/duel_visibility.gd")
const AudienceEvents := preload("res://scripts/duel/knowledge/duel_audience_event_stream.gd")

const OWNED_PUBLIC_FIELDS: Array[String] = [
	"abilities",
	"armor_centi",
	"armor_class",
	"attack_cooldown_remaining_ticks",
	"attributes",
	"autocast",
	"buffs",
	"builders",
	"cargo",
	"class",
	"completed_upgrades",
	"construction_progress_bp",
	"current_order",
	"death_state",
	"debuffs",
	"formation_id",
	"hero_level",
	"hp",
	"inventory",
	"mana",
	"max_hp",
	"max_mana",
	"movement_state",
	"pause_reason",
	"producer_queue",
	"queued_orders",
	"rally_target",
	"revival_state",
	"route_summary",
	"selected_by_squad_ids",
	"skill_points",
	"stance",
	"statuses",
	"tactical_slot",
	"work_progress_bp",
	"xp",
]

## Phase-12 projection boundary.  It accepts canonical snapshots only, updates
## DuelAgentKnowledgeState, and never hands an observation builder WorldState.


static func project_phase_12(
	knowledge_state: RefCounted,
	tick: int,
	day_phase: String,
	grid_snapshot_input: Dictionary,
	entity_snapshots_input: Array,
	candidate_events_input: Array = [],
	temporary_vision_sources_input: Array = [],
	revealed_entity_internal_ids_input: Array = []
) -> Dictionary:
	var errors := PackedStringArray()
	if knowledge_state == null or not knowledge_state.is_configured():
		errors.append("knowledge_state must be a configured DuelAgentKnowledgeState")
		return _failure(errors)
	if tick < 0:
		errors.append("tick must be non-negative")
	for error: String in Codec.validate_canonical_value(grid_snapshot_input, "$.grid_snapshot"):
		errors.append(error)
	for error: String in Codec.validate_canonical_value(entity_snapshots_input, "$.entities"):
		errors.append(error)
	for error: String in Codec.validate_canonical_value(candidate_events_input, "$.candidate_events"):
		errors.append(error)
	for error: String in Codec.validate_canonical_value(
		temporary_vision_sources_input, "$.temporary_vision_sources"
	):
		errors.append(error)
	for error: String in Codec.validate_canonical_value(
		revealed_entity_internal_ids_input, "$.revealed_entity_internal_ids"
	):
		errors.append(error)
	if not errors.is_empty():
		return _failure(errors)

	## Deep copies make the snapshot immutable from this subsystem's point of
	## view and ensure remembered records cannot retain hidden live references.
	var grid := grid_snapshot_input.duplicate(true)
	var entities: Array = entity_snapshots_input.duplicate(true)
	var candidate_events: Array = candidate_events_input.duplicate(true)
	var visibility_result := Visibility.compute(
		grid,
		entities,
		int(knowledge_state.observer_seat),
		day_phase,
		temporary_vision_sources_input,
		revealed_entity_internal_ids_input
	)
	if not bool(visibility_result["ok"]):
		errors.append_array(visibility_result["errors"])
		return _failure(errors)
	errors.append_array(knowledge_state.begin_phase_12(
		tick, visibility_result["visible_cell_ids"], grid
	))
	if not errors.is_empty():
		return _failure(errors)

	entities.sort_custom(_entity_less)
	var visible_ids: Dictionary = {}
	for id_variant: Variant in visibility_result["visible_entity_ids"]:
		visible_ids[int(id_variant)] = true
	var current_ids: Dictionary = {}
	var owned_records: Dictionary = {}
	var transition_drafts: Array = []

	for entity_variant: Variant in entities:
		var entity: Dictionary = entity_variant
		var internal_id := int(entity["internal_id"])
		current_ids[internal_id] = true
		if int(entity["owner_seat"]) == int(knowledge_state.observer_seat):
			var owned_result := _owned_public_record(knowledge_state, entity, grid)
			if not bool(owned_result["ok"]):
				errors.append_array(owned_result["errors"])
				continue
			owned_records[internal_id] = owned_result["record"]
			continue

		var previous: Dictionary = knowledge_state.contact_if_known(internal_id)
		if bool(entity["alive"]) and knowledge_state.alias_book.is_tombstoned(internal_id):
			errors.append("tombstoned internal entity ID %d was reused" % internal_id)
			continue
		if not bool(entity["alive"]):
			if not previous.is_empty() and not bool(entity.get("invisible", false)) \
				and Visibility.entity_location_is_visible(
					entity, grid, visibility_result["visible_cell_ids"]
				):
				_mark_destroyed(knowledge_state, internal_id, previous, tick, transition_drafts)
			else:
				## A hidden death is not knowledge. Treat the contact exactly like
				## any other entity that left sight, preserving its alive state.
				_update_hidden_contact(
					knowledge_state,
					internal_id,
					previous,
					visibility_result["visible_cell_ids"],
					tick,
					transition_drafts
				)
			continue

		if visible_ids.has(internal_id):
			var visible_result := _visible_public_record(knowledge_state, entity, grid, tick, previous)
			if not bool(visible_result["ok"]):
				errors.append_array(visible_result["errors"])
				continue
			var contact: Dictionary = visible_result["contact"]
			knowledge_state.set_contact(internal_id, contact)
			if previous.is_empty():
				transition_drafts.append(_transition_event(
					internal_id, "entity_entered_vision", tick, contact["visible_contact"]
				))
			elif str(previous.get("knowledge_state", "")) in ["remembered", "unlocated"]:
				transition_drafts.append(_transition_event(
					internal_id, "entity_reacquired", tick, contact["visible_contact"]
				))
		else:
			_update_hidden_contact(
				knowledge_state,
				internal_id,
				previous,
				visibility_result["visible_cell_ids"],
				tick,
				transition_drafts
			)

	## An entity may be absent because phase 10 removed it.  Unless a legal
	## destruction fact was supplied, revisiting its frozen location reveals
	## only `unlocated`, never death or a cause.
	for internal_id: int in knowledge_state.protected_contact_internal_ids():
		if current_ids.has(internal_id):
			continue
		var previous: Dictionary = knowledge_state.contact_if_known(internal_id)
		_update_hidden_contact(
			knowledge_state,
			internal_id,
			previous,
			visibility_result["visible_cell_ids"],
			tick,
			transition_drafts
		)

	knowledge_state.replace_owned_records(owned_records)
	if not errors.is_empty():
		return _failure(errors)

	transition_drafts.sort_custom(_transition_less)
	var public_transitions: Array = []
	for transition_variant: Variant in transition_drafts:
		var transition: Dictionary = transition_variant
		transition.erase("_internal_id")
		public_transitions.append(transition)
	var event_result := AudienceEvents.project(knowledge_state, candidate_events, grid)
	if not bool(event_result["ok"]):
		errors.append_array(event_result["errors"])
	var all_event_drafts: Array = public_transitions
	all_event_drafts.append_array(event_result["events"])
	errors.append_array(knowledge_state.emit_event_drafts(all_event_drafts))
	if not errors.is_empty():
		return _failure(errors)

	return {
		"errors": errors,
		"knowledge_hash": knowledge_state.public_projection_hash(),
		"ok": true,
		"projection": knowledge_state.public_projection(),
		"visibility": visibility_result,
	}


static func _owned_public_record(
	state: RefCounted,
	entity: Dictionary,
	grid: Dictionary
) -> Dictionary:
	var errors := PackedStringArray()
	var alias: String = state.ensure_alias(int(entity["internal_id"]))
	if alias.is_empty():
		errors.append("failed to allocate owned entity alias")
		return {"errors": errors, "ok": false, "record": {}}
	var source: Dictionary = {}
	if entity.has("owned_observation"):
		if typeof(entity["owned_observation"]) != TYPE_DICTIONARY:
			errors.append("owned_observation must be an object")
			return {"errors": errors, "ok": false, "record": {}}
		source = entity["owned_observation"]
		if _contains_forbidden_key(source):
			errors.append("owned observation contains a protected internal/secret key")
			return {"errors": errors, "ok": false, "record": {}}
	else:
		source = entity
	var record: Dictionary = {}
	for key: String in OWNED_PUBLIC_FIELDS:
		if source.has(key):
			record[key] = source[key]
	record["entity_id"] = alias
	record["type_id"] = str(entity.get("type_id", entity.get("catalog_id", "unknown")))
	record["tags"] = _sorted_strings(entity.get("tags", []))
	var position: Array = state.coordinate_frame.world_point_to_self(entity["position_mt"])
	if position.is_empty():
		errors.append("owned position is outside the self-canonical frame")
	else:
		record["position_mt"] = position
	record["region_id"] = state.coordinate_frame.world_public_id_to_self(
		_entity_region_id(entity, grid)
	)
	if entity.has("elevation"):
		record["elevation"] = int(entity["elevation"])
	if entity.has("facing_mdeg"):
		record["facing_mdeg"] = state.coordinate_frame.world_facing_to_self(
			int(entity["facing_mdeg"])
		)
	if _contains_forbidden_key(record):
		errors.append("projected owned record contains a protected internal/secret key")
	for error: String in Codec.validate_canonical_value(record, "$.owned_record"):
		errors.append(error)
	return {"errors": errors, "ok": errors.is_empty(), "record": record.duplicate(true)}


static func _visible_public_record(
	state: RefCounted,
	entity: Dictionary,
	grid: Dictionary,
	tick: int,
	previous: Dictionary
) -> Dictionary:
	var errors := PackedStringArray()
	var internal_id := int(entity["internal_id"])
	var alias: String = state.ensure_alias(internal_id)
	if alias.is_empty():
		errors.append("failed to allocate visible entity alias")
		return {"contact": {}, "errors": errors, "ok": false}
	var position: Array = state.coordinate_frame.world_point_to_self(entity["position_mt"])
	if position.is_empty():
		errors.append("visible position is outside the self-canonical frame")
		return {"contact": {}, "errors": errors, "ok": false}
	var owner_category := "neutral" if int(entity["owner_seat"]) == -1 else "opponent"
	var type_id := str(entity.get("type_id", entity.get("catalog_id", "unknown")))
	var first_seen_tick := tick if previous.is_empty() else int(previous["first_seen_tick"])
	var statuses := _visible_statuses(entity)
	var region_id: String = state.coordinate_frame.world_public_id_to_self(
		_entity_region_id(entity, grid)
	)
	var visible_contact := {
		"entity_id": alias,
		"first_seen_tick": first_seen_tick,
		"hero_level": entity.get("hero_level", null),
		"hp": int(entity.get("hp", 0)),
		"last_seen_tick": tick,
		"max_hp": maxi(1, int(entity.get("max_hp", 1))),
		"observable_activity": str(entity.get("observable_activity", "unknown")),
		"owner_category": owner_category,
		"position_mt": position,
		"region_id": region_id,
		"tags": _sorted_strings(entity.get("tags", [])),
		"type_id": type_id,
		"visible_mana": null if bool(entity.get("mana_hidden", false)) else entity.get("mana", null),
		"visible_statuses": statuses,
	}
	var visible_status_ids: Array[String] = []
	for status_variant: Variant in statuses:
		if typeof(status_variant) == TYPE_DICTIONARY:
			var status: Dictionary = status_variant
			var status_id := str(status.get("status_id", status.get("id", "")))
			if not status_id.is_empty():
				visible_status_ids.append(status_id)
	visible_status_ids.sort()
	var last_observed := {
		"hero_level": visible_contact["hero_level"],
		"hp": visible_contact["hp"],
		"max_hp": visible_contact["max_hp"],
		"observable_activity": visible_contact["observable_activity"],
		"position_mt": position.duplicate(),
		"region_id": region_id,
		"visible_mana": visible_contact["visible_mana"],
		"visible_status_ids": visible_status_ids,
	}
	var contact := {
		"entity_id": alias,
		"first_seen_tick": first_seen_tick,
		"knowledge_state": "visible",
		"last_location_cell_ids": Visibility.entity_occupied_cell_ids(entity, grid),
		"last_observed": last_observed,
		"last_seen_tick": tick,
		"owner_category": owner_category,
		"type_id": type_id,
		"visible_contact": visible_contact,
	}
	if _contains_forbidden_key(contact):
		errors.append("projected visible record contains a protected internal/secret key")
	for error: String in Codec.validate_canonical_value(contact, "$.contact"):
		errors.append(error)
	return {"contact": contact, "errors": errors, "ok": errors.is_empty()}


static func _update_hidden_contact(
	state: RefCounted,
	internal_id: int,
	previous: Dictionary,
	visible_cell_ids: Array,
	tick: int,
	transition_drafts: Array
) -> void:
	if previous.is_empty() or str(previous.get("knowledge_state", "")) == "destroyed":
		return
	var was_visible := str(previous.get("knowledge_state", "")) == "visible"
	var last_location_revisited := false
	for cell_id_variant: Variant in previous.get("last_location_cell_ids", []):
		if visible_cell_ids.has(int(cell_id_variant)):
			last_location_revisited = true
			break
	var updated := previous.duplicate(true)
	updated["knowledge_state"] = "unlocated" if last_location_revisited else "remembered"
	updated.erase("visible_contact")
	## No other field is touched: last_observed, last_seen_tick, type, HP,
	## mana, inventory-derived visibility, and alive knowledge stay frozen.
	state.set_contact(internal_id, updated)
	if was_visible:
		transition_drafts.append({
			"_internal_id": internal_id,
			"kind": "entity_left_vision",
			"payload": {"entity_id": str(updated["entity_id"])},
			"tick": tick,
		})


static func _mark_destroyed(
	state: RefCounted,
	internal_id: int,
	previous: Dictionary,
	tick: int,
	transition_drafts: Array
) -> void:
	if str(previous.get("knowledge_state", "")) == "destroyed":
		return
	var updated := previous.duplicate(true)
	updated["knowledge_state"] = "destroyed"
	updated["last_seen_tick"] = tick
	updated.erase("visible_contact")
	state.set_contact(internal_id, updated)
	state.tombstone_alias(internal_id)
	transition_drafts.append({
		"_internal_id": internal_id,
		"kind": "entity_destroyed",
		"payload": {
			"entity_id": str(updated["entity_id"]),
			"type_id": str(updated["type_id"]),
		},
		"tick": tick,
	})


static func _transition_event(
	internal_id: int,
	kind: String,
	tick: int,
	visible_contact: Dictionary
) -> Dictionary:
	return {
		"_internal_id": internal_id,
		"kind": kind,
		"payload": {
			"entity_id": str(visible_contact["entity_id"]),
			"position_mt": (visible_contact["position_mt"] as Array).duplicate(),
			"region_id": str(visible_contact["region_id"]),
			"type_id": str(visible_contact["type_id"]),
		},
		"tick": tick,
	}


static func _entity_region_id(entity: Dictionary, grid: Dictionary) -> String:
	if entity.has("region_id"):
		return str(entity["region_id"])
	var occupied := Visibility.entity_occupied_cell_ids(entity, grid)
	if occupied.is_empty() or not grid.has("region_ids"):
		return "unknown"
	return str((grid["region_ids"] as Array)[occupied[0]])


static func _visible_statuses(entity: Dictionary) -> Array:
	var result: Array = []
	if entity.has("visible_statuses") and typeof(entity["visible_statuses"]) == TYPE_ARRAY:
		result = (entity["visible_statuses"] as Array).duplicate(true)
	result.sort_custom(_status_less)
	return result


static func _sorted_strings(value: Variant) -> Array:
	var strings: Array[String] = []
	if typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			strings.append(str(element))
	strings.sort()
	var result: Array = []
	result.assign(strings)
	return result


static func _contains_forbidden_key(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary: Dictionary = value
		for key_variant: Variant in dictionary.keys():
			var key := str(key_variant).to_lower()
			if "internal_id" in key or key in [
				"alias_salt", "omniscient_state_hash", "world_checkpoint_hash", "world_hash",
			]:
				return true
			if _contains_forbidden_key(dictionary[key_variant]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			if _contains_forbidden_key(element):
				return true
	return false


static func _entity_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("internal_id", 0)) < int(right.get("internal_id", 0))


static func _status_less(left: Variant, right: Variant) -> bool:
	if typeof(left) != TYPE_DICTIONARY or typeof(right) != TYPE_DICTIONARY:
		return str(left) < str(right)
	var left_dict: Dictionary = left
	var right_dict: Dictionary = right
	return str(left_dict.get("status_id", left_dict.get("id", ""))) \
		< str(right_dict.get("status_id", right_dict.get("id", "")))


static func _transition_less(left: Dictionary, right: Dictionary) -> bool:
	if int(left["_internal_id"]) != int(right["_internal_id"]):
		return int(left["_internal_id"]) < int(right["_internal_id"])
	return str(left["kind"]) < str(right["kind"])


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {
		"errors": errors,
		"knowledge_hash": "",
		"ok": false,
		"projection": {},
		"visibility": {},
	}
