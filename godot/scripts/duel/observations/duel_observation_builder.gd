class_name DuelObservationBuilder
extends RefCounted

## Provider-visible observation serializer.
##
## The type boundary is deliberate: this builder accepts only a
## DuelAgentKnowledgeState and invokes exactly public_projection(). Everything
## not yet stored by that projection (owned economy/technology, decision-window
## metadata, visible item/shop records, squads, memory, and the prior receipt)
## crosses through DuelObservationContract's closed public-context object.

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const KnowledgeState := preload("res://scripts/duel/knowledge/duel_agent_knowledge_state.gd")
const Contract := preload("res://scripts/duel/observations/duel_observation_contract.gd")

const ZERO_HASH := "0000000000000000000000000000000000000000000000000000000000000000"


static func build(knowledge_state: RefCounted, public_context_input: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if knowledge_state == null or not (knowledge_state is KnowledgeState):
		errors.append("observation builder requires DuelAgentKnowledgeState, never WorldState")
		return _failure(errors)

	## Validate before copying so unknown/hidden keys are rejected rather than
	## silently redacted. The duplicate makes caller mutation unable to affect a
	## message being assembled.
	errors.append_array(Contract.validate_public_context(public_context_input))
	if not errors.is_empty():
		return _failure(errors)
	var context := public_context_input.duplicate(true)

	## This is intentionally the only knowledge-state call in this subsystem.
	var projection_variant: Variant = knowledge_state.public_projection()
	errors.append_array(Contract.validate_knowledge_projection(projection_variant))
	if not errors.is_empty():
		return _failure(errors)
	var projection: Dictionary = (projection_variant as Dictionary).duplicate(true)
	var tick := int(projection["tick"])
	if int((context["decision"] as Dictionary).get("observation_tick", -1)) != tick:
		errors.append("public decision observation_tick must equal knowledge projection tick")
		return _failure(errors)

	var structure_type_ids := _string_set(context.get("structure_type_ids", []))
	var heroes: Array = []
	var owned_entities: Array = []
	var owned_structures: Array = []
	for source_variant: Variant in projection["owned_entities"]:
		if typeof(source_variant) != TYPE_DICTIONARY:
			errors.append("owned knowledge record must be an object")
			continue
		var source: Dictionary = source_variant
		if _is_hero(source):
			heroes.append(_normalize_hero(source))
		elif _is_structure(source, structure_type_ids):
			owned_structures.append(_normalize_structure(source))
		else:
			owned_entities.append(_normalize_owned_base(source))
	_sort_dictionary_array(heroes, "entity_id")
	_sort_dictionary_array(owned_entities, "entity_id")
	_sort_dictionary_array(owned_structures, "entity_id")

	var visible_contacts: Array = []
	var visible_neutrals: Array = []
	for source_variant: Variant in projection["visible_contacts"]:
		if typeof(source_variant) != TYPE_DICTIONARY:
			errors.append("visible knowledge record must be an object")
			continue
		var contact := _normalize_visible_contact(source_variant)
		if str(contact.get("owner_category", "")) == "neutral":
			visible_neutrals.append(contact)
		else:
			visible_contacts.append(contact)
	_sort_dictionary_array(visible_contacts, "entity_id")
	_sort_dictionary_array(visible_neutrals, "entity_id")

	var remembered_contacts: Array = []
	for source_variant: Variant in projection["remembered_contacts"]:
		if typeof(source_variant) != TYPE_DICTIONARY:
			errors.append("remembered knowledge record must be an object")
			continue
		remembered_contacts.append(_normalize_remembered_contact(source_variant))
	_sort_dictionary_array(remembered_contacts, "entity_id")

	var events := _normalize_events(projection["events_since_previous"])
	var map_state := _normalize_map_state(projection["map_state"])
	var economy: Dictionary = (context["economy"] as Dictionary).duplicate(true)
	var food: Dictionary = (context["food"] as Dictionary).duplicate(true)
	var technology := _normalize_technology(context["technology"])
	var visible_items := _normalize_visible_items(context["visible_items"])
	var visible_shops := _normalize_visible_shops(context["visible_shops"])
	var squads := _normalize_squads(context["squads"])
	var receipt: Variant = _normalize_receipt(context["last_action_receipt"])
	var day_phase := str(context["day_phase"])

	var observation := {
		"message_type": "observation",
		"protocol_version": Contract.PROTOCOL_VERSION,
		"match_id": str(context["match_id"]),
		"observation_seq": int(context["observation_seq"]),
		"observation_hash": ZERO_HASH,
		"tick": tick,
		"game_time": {
			"ticks": tick,
			"seconds": int(tick / 10),
			"day_phase": day_phase,
			"cycle_tick": tick % 4_800,
		},
		"decision": (context["decision"] as Dictionary).duplicate(true),
		"working_memory": str(context["working_memory"]),
		"objective": {
			"kind": "destroy_enemy_stronghold",
			"enemy_structure_role": "stronghold",
			"own_structure_role": "stronghold",
		},
		"match_state": (context["match_state"] as Dictionary).duplicate(true),
		"day_phase": day_phase,
		"remaining_match_ticks": int(context["remaining_match_ticks"]),
		"economy": economy,
		"food": food,
		"upkeep": (context["upkeep"] as Dictionary).duplicate(true),
		"technology": technology,
		"heroes": heroes,
		"owned_entities": owned_entities,
		"owned_structures": owned_structures,
		"squads": squads,
		"visible_contacts": visible_contacts,
		"remembered_contacts": remembered_contacts,
		"visible_neutrals": visible_neutrals,
		"visible_items": visible_items,
		"visible_shops": visible_shops,
		"map_state": map_state,
		"events_since_previous": events,
		"last_action_receipt": receipt,
		"limits_remaining": {
			"max_command_objects": Contract.MAX_COMMAND_OBJECTS,
			"max_atomic_order_cost": Contract.MAX_ATOMIC_ORDER_COST,
			"max_actor_ids_per_command": Contract.MAX_ACTOR_IDS,
			"max_queue_entries_per_entity": Contract.MAX_QUEUE_ENTRIES,
			"max_working_memory_bytes": Contract.MAX_WORKING_MEMORY_BYTES,
		},
		"observation_truncated": false,
		"omitted_counts": {
			"brief": 0,
			"remembered_units": 0,
			"remembered_buildings": 0,
			"local_context_paths": 0,
		},
	}
	if bool(context.get("include_brief", true)):
		observation["brief"] = _build_brief(observation)

	var maximum_bytes := int(context.get(
		"maximum_observation_bytes", Contract.MAX_OBSERVATION_BYTES
	))
	errors.append_array(_apply_truncation(observation, maximum_bytes, structure_type_ids))
	if not errors.is_empty():
		return _failure(errors)

	observation["observation_hash"] = Contract.observation_hash(observation)
	errors.append_array(Contract.validate_observation(observation, true))
	if not errors.is_empty():
		return _failure(errors)
	var canonical_json := Codec.canonical_json(observation)
	var byte_count := canonical_json.to_utf8_buffer().size()
	if byte_count > maximum_bytes:
		errors.append("observation exceeds its post-truncation byte ceiling")
		return _failure(errors)
	return {
		"byte_count": byte_count,
		"canonical_json": canonical_json,
		"errors": errors,
		"observation": observation.duplicate(true),
		"observation_hash": str(observation["observation_hash"]),
		"ok": true,
	}


static func _normalize_owned_base(source: Dictionary) -> Dictionary:
	var record := {
		"entity_id": str(source.get("entity_id", "")),
		"type_id": str(source.get("type_id", "")),
		"tags": _sorted_unique_strings(source.get("tags", [])),
		"position_mt": _point_copy(source.get("position_mt", [])),
		"region_id": str(source.get("region_id", "")),
		"elevation": int(source.get("elevation", 0)),
		"facing_mdeg": int(source.get("facing_mdeg", 0)),
		"hp": int(source.get("hp", 0)),
		"max_hp": int(source.get("max_hp", 0)),
		"shields": int(source.get("shields", 0)),
		"mana": int(source.get("mana", 0)),
		"max_mana": int(source.get("max_mana", 0)),
		"armor_centi": int(source.get("armor_centi", 0)),
		"armor_class": str(source.get("armor_class", "")),
		"movement_state": str(source.get("movement_state", "idle")),
		"cargo": _normalize_cargo(source.get("cargo", {})),
		"current_order": _normalize_order_or_null(source.get("current_order", null)),
		"queued_orders": _normalize_orders(source.get("queued_orders", [])),
		"stance": str(source.get("stance", "defensive")),
		"formation": str(source.get("formation", source.get("formation_id", "none"))),
		"attack_cooldown_remaining_ticks": int(source.get("attack_cooldown_remaining_ticks", 0)),
		"abilities": _normalize_abilities(source.get("abilities", [])),
		"statuses": _normalize_statuses(source.get("statuses", [])),
		"squad_ids": _sorted_unique_strings(source.get(
			"squad_ids", source.get("selected_by_squad_ids", [])
		)),
	}
	if source.has("tactical_slot_id"):
		record["tactical_slot_id"] = source["tactical_slot_id"]
	elif source.has("tactical_slot"):
		record["tactical_slot_id"] = source["tactical_slot"]
	for optional: String in ["detection_radius_mt", "cargo_capacity_food"]:
		if source.has(optional):
			record[optional] = int(source[optional])
	if source.has("passenger_ids"):
		record["passenger_ids"] = _sorted_unique_strings(source["passenger_ids"])
	return record


static func _normalize_hero(source: Dictionary) -> Dictionary:
	var record := _normalize_owned_base(source)
	record["hero_type_id"] = str(source.get("hero_type_id", source.get("type_id", "")))
	record["level"] = int(source.get("level", source.get("hero_level", 1)))
	record["xp"] = int(source.get("xp", 0))
	record["next_level_xp"] = source.get("next_level_xp", null)
	record["unspent_skill_points"] = int(source.get(
		"unspent_skill_points", source.get("skill_points", 0)
	))
	record["attributes_centi"] = _normalize_attributes(source.get(
		"attributes_centi", source.get("attributes", {})
	))
	record["inventory"] = _normalize_inventory(source.get("inventory", []))
	record["life_state"] = str(source.get("life_state", source.get("death_state", "alive")))
	record["death_tick"] = source.get("death_tick", null)
	record["revival"] = _normalize_revival(source.get("revival", source.get("revival_state", null)))
	return record


static func _normalize_structure(source: Dictionary) -> Dictionary:
	var record := _normalize_owned_base(source)
	record["structure_role"] = str(source.get(
		"structure_role", source.get("class", source.get("type_id", ""))
	))
	var progress := int(source.get(
		"construction_progress_bp", source.get("work_progress_bp", 10_000)
	))
	record["complete"] = bool(source.get("complete", progress >= 10_000))
	record["construction_progress_bp"] = progress
	record["builders"] = _sorted_unique_strings(source.get("builders", []))
	record["production_queue"] = _normalize_queue(source.get(
		"production_queue", source.get("producer_queue", [])
	))
	record["rally_target"] = _normalize_rally_target(source.get("rally_target", null))
	record["disabled"] = bool(source.get("disabled", false))
	record["pause_reason"] = source.get("pause_reason", null)
	return record


static func _normalize_visible_contact(source: Dictionary) -> Dictionary:
	return {
		"entity_id": str(source.get("entity_id", "")),
		"owner_category": str(source.get("owner_category", "")),
		"type_id": str(source.get("type_id", "")),
		"tags": _sorted_unique_strings(source.get("tags", [])),
		"position_mt": _point_copy(source.get("position_mt", [])),
		"region_id": str(source.get("region_id", "")),
		"hp": int(source.get("hp", 0)),
		"max_hp": int(source.get("max_hp", 0)),
		"visible_mana": source.get("visible_mana", null),
		"hero_level": source.get("hero_level", null),
		"visible_statuses": _normalize_statuses(source.get("visible_statuses", [])),
		"observable_activity": str(source.get("observable_activity", "unknown")),
		"first_seen_tick": int(source.get("first_seen_tick", 0)),
		"last_seen_tick": int(source.get("last_seen_tick", 0)),
	}


static func _normalize_remembered_contact(source: Dictionary) -> Dictionary:
	var observed_source: Dictionary = source.get("last_observed", {})
	var observed := {
		"position_mt": _point_copy(observed_source.get("position_mt", [])),
		"region_id": str(observed_source.get("region_id", "")),
		"hp": int(observed_source.get("hp", 0)),
		"max_hp": int(observed_source.get("max_hp", 0)),
		"observable_activity": str(observed_source.get("observable_activity", "unknown")),
	}
	for optional: String in ["visible_mana", "hero_level"]:
		if observed_source.has(optional):
			observed[optional] = observed_source[optional]
	if observed_source.has("visible_status_ids"):
		observed["visible_status_ids"] = _sorted_unique_strings(
			observed_source["visible_status_ids"]
		)
	return {
		"entity_id": str(source.get("entity_id", "")),
		"type_id": str(source.get("type_id", "")),
		"owner_category": str(source.get("owner_category", "")),
		"first_seen_tick": int(source.get("first_seen_tick", 0)),
		"last_seen_tick": int(source.get("last_seen_tick", 0)),
		"memory_age_ticks": int(source.get("memory_age_ticks", 0)),
		"last_observed": observed,
		"last_location_status": str(source.get("last_location_status", "unverified")),
	}


static func _normalize_technology(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	var researching: Array = []
	for row_variant: Variant in source.get("researching", []):
		if typeof(row_variant) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_variant
		researching.append({
			"producer_id": str(row.get("producer_id", "")),
			"entry": _normalize_queue_entry(row.get("entry", {})),
		})
	_sort_dictionary_array(researching, "producer_id")
	return {
		"tier": int(source.get("tier", 0)),
		"completed_upgrades": _sorted_unique_strings(source.get("completed_upgrades", [])),
		"researching": researching,
		"hero_slots": (source.get("hero_slots", {}) as Dictionary).duplicate(true),
	}


static func _normalize_squads(value: Variant) -> Array:
	var squads: Array = []
	if typeof(value) != TYPE_ARRAY:
		return squads
	for source_variant: Variant in value:
		if typeof(source_variant) != TYPE_DICTIONARY:
			continue
		var source: Dictionary = source_variant
		var squad := {
			"squad_id": str(source.get("squad_id", "")),
			"member_ids": _sorted_unique_strings(source.get("member_ids", [])),
			"formation": str(source.get("formation", "none")),
			"stance": str(source.get("stance", "defensive")),
			"current_order": _normalize_order_or_null(source.get("current_order", null)),
		}
		if source.has("retreat_hp_threshold_bp"):
			squad["retreat_hp_threshold_bp"] = int(source["retreat_hp_threshold_bp"])
		squads.append(squad)
	_sort_dictionary_array(squads, "squad_id")
	return squads


static func _normalize_visible_items(value: Variant) -> Array:
	var items: Array = []
	if typeof(value) != TYPE_ARRAY:
		return items
	for source_variant: Variant in value:
		if typeof(source_variant) != TYPE_DICTIONARY:
			continue
		var source: Dictionary = source_variant
		var item := {
			"item_entity_id": str(source.get("item_entity_id", "")),
			"item_type_id": str(source.get("item_type_id", "")),
			"position_mt": _point_copy(source.get("position_mt", [])),
			"region_id": str(source.get("region_id", "")),
			"charges": int(source.get("charges", 0)),
		}
		if source.has("despawn_tick"):
			item["despawn_tick"] = source["despawn_tick"]
		items.append(item)
	_sort_dictionary_array(items, "item_entity_id")
	return items


static func _normalize_visible_shops(value: Variant) -> Array:
	var shops: Array = []
	if typeof(value) != TYPE_ARRAY:
		return shops
	for source_variant: Variant in value:
		if typeof(source_variant) != TYPE_DICTIONARY:
			continue
		var source: Dictionary = source_variant
		var offers: Array = []
		for offer_variant: Variant in source.get("offers", []):
			if typeof(offer_variant) != TYPE_DICTIONARY:
				continue
			var offer_source: Dictionary = offer_variant
			var offer := {
				"offer_id": str(offer_source.get("offer_id", "")),
				"kind": str(offer_source.get("kind", "")),
				"cost_gold": int(offer_source.get("cost_gold", 0)),
				"cost_lumber": int(offer_source.get("cost_lumber", 0)),
				"stock": offer_source.get("stock", null),
				"next_restock_tick": offer_source.get("next_restock_tick", null),
				"available": bool(offer_source.get("available", false)),
			}
			if offer_source.has("requires_service_target"):
				offer["requires_service_target"] = bool(offer_source["requires_service_target"])
			offers.append(offer)
		_sort_dictionary_array(offers, "offer_id")
		shops.append({
			"shop_id": str(source.get("shop_id", "")),
			"site_id": str(source.get("site_id", "")),
			"shop_type": str(source.get("shop_type", "")),
			"position_mt": _point_copy(source.get("position_mt", [])),
			"region_id": str(source.get("region_id", "")),
			"offers": offers,
		})
	_sort_dictionary_array(shops, "site_id")
	return shops


static func _normalize_map_state(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	var changes: Array = []
	for change_variant: Variant in source.get("terrain_changes", []):
		if typeof(change_variant) != TYPE_DICTIONARY:
			continue
		var change: Dictionary = change_variant
		changes.append({
			"change_id": str(change.get("change_id", "")),
			"kind": str(change.get("kind", "")),
			"position_mt": _point_copy(change.get("position_mt", [])),
			"observed_tick": int(change.get("observed_tick", 0)),
		})
	_sort_dictionary_array(changes, "change_id")
	var contexts: Array = []
	for context_variant: Variant in source.get("local_context", []):
		if typeof(context_variant) == TYPE_DICTIONARY:
			contexts.append(_normalize_local_context(context_variant))
	_sort_dictionary_array(contexts, "anchor_id")
	return {
		"explored_region_ids": _sorted_unique_strings(source.get("explored_region_ids", [])),
		"visible_region_ids": _sorted_unique_strings(source.get("visible_region_ids", [])),
		"terrain_changes": changes,
		"local_context": contexts,
	}


static func _normalize_local_context(source: Dictionary) -> Dictionary:
	var exits: Array = []
	for exit_variant: Variant in source.get("exits", []):
		if typeof(exit_variant) != TYPE_DICTIONARY:
			continue
		var exit: Dictionary = exit_variant
		exits.append({
			"to_region_id": str(exit.get("to_region_id", "")),
			"bearing": str(exit.get("bearing", "")),
			"path_distance_mt": int(exit.get("path_distance_mt", 0)),
			"choke_width_mt": int(exit.get("choke_width_mt", 0)),
			"known_blockage": str(exit.get("known_blockage", "unknown")),
		})
	_sort_dictionary_array(exits, "to_region_id")
	var visible: Array = []
	for contact_variant: Variant in source.get("visible_contacts", []):
		if typeof(contact_variant) != TYPE_DICTIONARY:
			continue
		var contact: Dictionary = contact_variant
		visible.append({
			"entity_id": str(contact.get("entity_id", "")),
			"bearing": str(contact.get("bearing", "")),
			"distance_mt": int(contact.get("distance_mt", 0)),
			"known_path_distance_mt": contact.get("known_path_distance_mt", null),
			"line_of_sight": bool(contact.get("line_of_sight", false)),
		})
	_sort_dictionary_array(visible, "entity_id")
	var remembered: Array = []
	for threat_variant: Variant in source.get("remembered_threats", []):
		if typeof(threat_variant) != TYPE_DICTIONARY:
			continue
		var threat: Dictionary = threat_variant
		remembered.append({
			"entity_id": str(threat.get("entity_id", "")),
			"age_ticks": int(threat.get("age_ticks", 0)),
			"bearing": str(threat.get("bearing", "")),
			"distance_mt": int(threat.get("distance_mt", 0)),
		})
	_sort_dictionary_array(remembered, "entity_id")
	var features: Array = []
	for feature_variant: Variant in source.get("nearby_features", []):
		if typeof(feature_variant) != TYPE_DICTIONARY:
			continue
		var feature_source: Dictionary = feature_variant
		var feature := {
			"site_id": str(feature_source.get("site_id", "")),
			"kind": str(feature_source.get("kind", "")),
			"bearing": str(feature_source.get("bearing", "")),
			"path_distance_mt": int(feature_source.get("path_distance_mt", 0)),
		}
		if feature_source.has("state"):
			feature["state"] = str(feature_source["state"])
		features.append(feature)
	_sort_dictionary_array(features, "site_id")
	return {
		"anchor_id": str(source.get("anchor_id", "")),
		"position_mt": _point_copy(source.get("position_mt", [])),
		"region_id": str(source.get("region_id", "")),
		"tactical_slot": source.get("tactical_slot", null),
		"terrain": str(source.get("terrain", "")),
		"elevation": int(source.get("elevation", 0)),
		"exits": exits,
		"visible_contacts": visible,
		"remembered_threats": remembered,
		"nearby_features": features,
		"visibility_radius_mt": int(source.get("visibility_radius_mt", 0)),
		"detection_radius_mt": int(source.get("detection_radius_mt", 0)),
		"retreat_route": _string_array_copy(source.get("retreat_route", [])),
	}


static func _normalize_events(value: Variant) -> Array:
	var events: Array = []
	if typeof(value) != TYPE_ARRAY:
		return events
	for source_variant: Variant in value:
		if typeof(source_variant) != TYPE_DICTIONARY:
			continue
		var source: Dictionary = source_variant
		events.append({
			"event_seq": int(source.get("event_seq", 0)),
			"tick": int(source.get("tick", 0)),
			"kind": str(source.get("kind", "")),
			"audience": str(source.get("audience", "")),
			"payload": (source.get("payload", {}) as Dictionary).duplicate(true),
		})
	_sort_dictionary_array(events, "event_seq", true)
	return events


static func _normalize_receipt(value: Variant) -> Variant:
	if value == null or typeof(value) != TYPE_DICTIONARY:
		return value
	var source: Dictionary = value
	var commands: Array = []
	for command_variant: Variant in source.get("commands", []):
		if typeof(command_variant) != TYPE_DICTIONARY:
			continue
		var command_source: Dictionary = command_variant
		var command := {
			"command_id": str(command_source.get("command_id", "")),
			"status": str(command_source.get("status", "")),
			"code": command_source.get("code", null),
		}
		for optional: String in ["requested_quantity", "accepted_quantity", "atomic_cost"]:
			if command_source.has(optional):
				command[optional] = int(command_source[optional])
		if command_source.has("compiled_order_ids"):
			command["compiled_order_ids"] = _sorted_unique_strings(
				command_source["compiled_order_ids"]
			)
		commands.append(command)
	var receipt := {
		"batch_id": str(source.get("batch_id", "")),
		"observation_seq": int(source.get("observation_seq", 0)),
		"received_tick": int(source.get("received_tick", 0)),
		"apply_tick": source.get("apply_tick", null),
		"batch_status": str(source.get("batch_status", "")),
		"commands": commands,
	}
	if source.has("code"):
		receipt["code"] = source["code"]
	return receipt


static func _normalize_order_or_null(value: Variant) -> Variant:
	if value == null:
		return null
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	var order := {
		"compiled_order_id": str(source.get("compiled_order_id", "")),
		"op": str(source.get("op", "")),
		"state": str(source.get("state", "")),
		"issued_tick": int(source.get("issued_tick", 0)),
	}
	for optional: String in [
		"batch_id", "command_id", "target_entity_id", "target_region_id", "target_site_id",
	]:
		if source.has(optional):
			order[optional] = str(source[optional])
	if source.has("target_position_mt"):
		order["target_position_mt"] = _point_copy(source["target_position_mt"])
	if source.has("route_region_ids"):
		order["route_region_ids"] = _string_array_copy(source["route_region_ids"])
	return order


static func _normalize_orders(value: Variant) -> Array:
	var orders: Array = []
	if typeof(value) != TYPE_ARRAY:
		return orders
	for order: Variant in value:
		orders.append(_normalize_order_or_null(order))
	return orders


static func _normalize_queue(value: Variant) -> Array:
	var queue: Array = []
	if typeof(value) != TYPE_ARRAY:
		return queue
	for entry: Variant in value:
		queue.append(_normalize_queue_entry(entry))
	return queue


static func _normalize_queue_entry(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	var entry := {
		"queue_entry_id": str(source.get("queue_entry_id", "")),
		"kind": str(source.get("kind", "")),
		"type_id": str(source.get("type_id", "")),
		"progress_bp": int(source.get("progress_bp", 0)),
		"remaining_ticks": int(source.get("remaining_ticks", 0)),
		"paused": bool(source.get("paused", false)),
		"reserved_gold": int(source.get("reserved_gold", 0)),
		"reserved_lumber": int(source.get("reserved_lumber", 0)),
		"reserved_food": int(source.get("reserved_food", 0)),
	}
	if source.has("pause_reason"):
		entry["pause_reason"] = source["pause_reason"]
	return entry


static func _normalize_abilities(value: Variant) -> Array:
	var abilities: Array = []
	if typeof(value) != TYPE_ARRAY:
		return abilities
	for source_variant: Variant in value:
		if typeof(source_variant) != TYPE_DICTIONARY:
			continue
		var source: Dictionary = source_variant
		abilities.append({
			"ability_id": str(source.get("ability_id", source.get("id", ""))),
			"rank": int(source.get("rank", 0)),
			"cooldown_remaining_ticks": int(source.get("cooldown_remaining_ticks", 0)),
			"autocast_enabled": bool(source.get("autocast_enabled", false)),
		})
	_sort_dictionary_array(abilities, "ability_id")
	return abilities


static func _normalize_statuses(value: Variant) -> Array:
	var statuses: Array = []
	if typeof(value) != TYPE_ARRAY:
		return statuses
	for source_variant: Variant in value:
		if typeof(source_variant) != TYPE_DICTIONARY:
			continue
		var source: Dictionary = source_variant
		var status := {
			"status_id": str(source.get("status_id", source.get("id", ""))),
			"source_entity_id": str(source.get("source_entity_id", "")),
			"start_tick": int(source.get("start_tick", 0)),
			"expiry_tick": source.get("expiry_tick", null),
			"stacking_key": str(source.get("stacking_key", source.get("status_id", ""))),
			"stacks": int(source.get("stacks", 1)),
			"dispel_class": str(source.get("dispel_class", "none")),
		}
		if source.has("magnitude"):
			status["magnitude"] = int(source["magnitude"])
		statuses.append(status)
	_sort_dictionary_array(statuses, "status_id")
	return statuses


static func _normalize_cargo(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {"resource": "none", "amount": 0}
	var source: Dictionary = value
	return {
		"resource": str(source.get("resource", "none")),
		"amount": int(source.get("amount", 0)),
	}


static func _normalize_attributes(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {"strength": 0, "agility": 0, "intellect": 0}
	var source: Dictionary = value
	return {
		"strength": int(source.get("strength", 0)),
		"agility": int(source.get("agility", 0)),
		"intellect": int(source.get("intellect", 0)),
	}


static func _normalize_inventory(value: Variant) -> Array:
	var inventory: Array = []
	if typeof(value) != TYPE_ARRAY:
		return inventory
	for source_variant: Variant in value:
		if typeof(source_variant) != TYPE_DICTIONARY:
			continue
		var source: Dictionary = source_variant
		inventory.append({
			"item_instance_id": str(source.get("item_instance_id", "")),
			"item_type_id": str(source.get("item_type_id", "")),
			"slot": int(source.get("slot", 0)),
			"charges": int(source.get("charges", 0)),
			"cooldown_remaining_ticks": int(source.get("cooldown_remaining_ticks", 0)),
		})
	_sort_dictionary_array(inventory, "slot", true)
	return inventory


static func _normalize_revival(value: Variant) -> Variant:
	if value == null:
		return null
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	return {
		"method": str(source.get("method", "")),
		"progress_bp": int(source.get("progress_bp", 0)),
		"remaining_ticks": int(source.get("remaining_ticks", 0)),
		"reviver_id": str(source.get("reviver_id", "")),
	}


static func _normalize_rally_target(value: Variant) -> Variant:
	if value == null or typeof(value) == TYPE_STRING:
		return value
	return _point_copy(value)


static func _build_brief(observation: Dictionary) -> Array:
	var economy: Dictionary = observation["economy"]
	var food: Dictionary = observation["food"]
	var technology: Dictionary = observation["technology"]
	var lines: Array = [
		"Self has %d gold, %d lumber, %d of %d food, and technology tier %d." % [
			int(economy["gold"]), int(economy["lumber"]), int(food["used"]),
			int(food["cap"]), int(technology["tier"]),
		],
	]
	var contacts: Array = observation["visible_contacts"]
	if contacts.size() == 1:
		var contact: Dictionary = contacts[0]
		var descriptor := "unit"
		var tags: Array = contact.get("tags", [])
		if tags.has("hero"):
			descriptor = "Hero"
		elif tags.has("structure"):
			descriptor = "structure"
		elif tags.has("ranged"):
			descriptor = "ranged unit"
		elif tags.has("melee"):
			descriptor = "melee unit"
		elif tags.has("air"):
			descriptor = "air unit"
		lines.append("One opponent %s is visible in %s." % [
			descriptor, str(contact["region_id"]),
		])
	elif contacts.size() > 1:
		var region_set: Dictionary = {}
		for contact_variant: Variant in contacts:
			region_set[str((contact_variant as Dictionary)["region_id"])] = true
		lines.append("%d opponent contacts are visible across %d regions." % [
			contacts.size(), region_set.size(),
		])
	return lines


static func _apply_truncation(
	observation: Dictionary, maximum_bytes: int, structure_type_ids: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	var counts: Dictionary = observation["omitted_counts"]
	## Enforce the schema cap with the same normative low-priority order even if
	## the byte envelope itself would fit.
	while (observation["remembered_contacts"] as Array).size() > 256:
		if _remove_oldest_remembered(observation, structure_type_ids, false):
			counts["remembered_units"] = int(counts["remembered_units"]) + 1
		elif _remove_oldest_remembered(observation, structure_type_ids, true):
			counts["remembered_buildings"] = int(counts["remembered_buildings"]) + 1
		else:
			errors.append("remembered-contact cap cannot be met without truncating a Hero")
			return errors

	if _observation_byte_count(observation) > maximum_bytes and observation.has("brief"):
		counts["brief"] = (observation["brief"] as Array).size()
		observation.erase("brief")
	while _observation_byte_count(observation) > maximum_bytes:
		if _remove_oldest_remembered(observation, structure_type_ids, false):
			counts["remembered_units"] = int(counts["remembered_units"]) + 1
		else:
			break
	while _observation_byte_count(observation) > maximum_bytes:
		if _remove_oldest_remembered(observation, structure_type_ids, true):
			counts["remembered_buildings"] = int(counts["remembered_buildings"]) + 1
		else:
			break
	while _observation_byte_count(observation) > maximum_bytes:
		if _remove_one_redundant_local_path(observation):
			counts["local_context_paths"] = int(counts["local_context_paths"]) + 1
		else:
			break
	observation["observation_truncated"] = (
		int(counts["brief"]) + int(counts["remembered_units"])
		+ int(counts["remembered_buildings"]) + int(counts["local_context_paths"]) > 0
	)
	if _observation_byte_count(observation) > maximum_bytes:
		errors.append(
			"observation exceeds maximum bytes after exhausting the legal truncation order"
		)
	return errors


static func _remove_oldest_remembered(
	observation: Dictionary, structure_type_ids: Dictionary, want_structure: bool
) -> bool:
	var records: Array = observation["remembered_contacts"]
	var chosen := -1
	for index: int in records.size():
		var record: Dictionary = records[index]
		var observed: Dictionary = record["last_observed"]
		if observed.get("hero_level", null) != null:
			continue
		var is_structure := structure_type_ids.has(str(record["type_id"]))
		if is_structure != want_structure:
			continue
		if chosen < 0 or _remembered_is_older(record, records[chosen]):
			chosen = index
	if chosen < 0:
		return false
	records.remove_at(chosen)
	return true


static func _remembered_is_older(left: Dictionary, right: Dictionary) -> bool:
	if int(left["last_seen_tick"]) != int(right["last_seen_tick"]):
		return int(left["last_seen_tick"]) < int(right["last_seen_tick"])
	return str(left["entity_id"]) < str(right["entity_id"])


static func _remove_one_redundant_local_path(observation: Dictionary) -> bool:
	var contexts: Array = (observation["map_state"] as Dictionary)["local_context"]
	for context_variant: Variant in contexts:
		var context: Dictionary = context_variant
		if not (context["retreat_route"] as Array).is_empty():
			context["retreat_route"] = []
			return true
	for context_variant: Variant in contexts:
		var context: Dictionary = context_variant
		for contact_variant: Variant in context["visible_contacts"]:
			var contact: Dictionary = contact_variant
			if contact["known_path_distance_mt"] != null:
				contact["known_path_distance_mt"] = null
				return true
	return false


static func _observation_byte_count(observation: Dictionary) -> int:
	return Codec.canonical_bytes(observation).size()


static func _is_hero(source: Dictionary) -> bool:
	var tags: Array = source.get("tags", [])
	return tags.has("hero") or str(source.get("class", "")) == "hero" \
		or source.has("hero_type_id") or source.has("hero_level") or source.has("level")


static func _is_structure(source: Dictionary, structure_type_ids: Dictionary) -> bool:
	var tags: Array = source.get("tags", [])
	return tags.has("structure") or str(source.get("class", "")) == "structure" \
		or source.has("structure_role") or structure_type_ids.has(str(source.get("type_id", "")))


static func _string_set(value: Variant) -> Dictionary:
	var result: Dictionary = {}
	if typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			result[str(element)] = true
	return result


static func _sorted_unique_strings(value: Variant) -> Array:
	var set: Dictionary = {}
	if typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			set[str(element)] = true
	var strings: Array[String] = []
	for key: Variant in set.keys():
		strings.append(str(key))
	strings.sort()
	var result: Array = []
	result.assign(strings)
	return result


static func _string_array_copy(value: Variant) -> Array:
	var result: Array = []
	if typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			result.append(str(element))
	return result


static func _point_copy(value: Variant) -> Array:
	if typeof(value) != TYPE_ARRAY:
		return []
	return (value as Array).duplicate()


static func _sort_dictionary_array(values: Array, key: String, numeric: bool = false) -> void:
	## Stable insertion sort avoids relying on Dictionary insertion order or a
	## bound-comparator implementation detail.
	for index: int in range(1, values.size()):
		var current: Variant = values[index]
		var cursor := index - 1
		while cursor >= 0 and _dictionary_row_less(current, values[cursor], key, numeric):
			values[cursor + 1] = values[cursor]
			cursor -= 1
		values[cursor + 1] = current


static func _dictionary_row_less(
	left_variant: Variant, right_variant: Variant, key: String, numeric: bool
) -> bool:
	if typeof(left_variant) != TYPE_DICTIONARY or typeof(right_variant) != TYPE_DICTIONARY:
		return str(left_variant) < str(right_variant)
	var left: Dictionary = left_variant
	var right: Dictionary = right_variant
	if numeric:
		return int(left.get(key, 0)) < int(right.get(key, 0))
	return str(left.get(key, "")) < str(right.get(key, ""))


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {
		"byte_count": 0,
		"canonical_json": "",
		"errors": errors,
		"observation": {},
		"observation_hash": "",
		"ok": false,
	}
