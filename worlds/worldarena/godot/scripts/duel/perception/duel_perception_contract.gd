class_name DuelPerceptionContract
extends RefCounted

## Closed input contract for the phase-12 bridge.  This is deliberately not a
## serializer for DuelState: the authoritative kernel must freeze only these
## fields and pass plain canonical values across the boundary.

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")

const PHASE_REQUIRED: Array[String] = [
	"candidate_events",
	"day_phase",
	"entity_snapshots",
	"grid_snapshot",
	"no_progress_ticks",
	"remaining_match_ticks",
	"seat_snapshots",
	"terminal",
	"tick",
]
const GRID_REQUIRED: Array[String] = [
	"cell_size_mt",
	"elevations",
	"height",
	"los_block_heights",
	"region_ids",
	"terrain_ids",
	"width",
]
const GRID_OPTIONAL: Array[String] = ["los_block_kinds"]
const ENTITY_REQUIRED: Array[String] = [
	"alive", "internal_id", "owner_seat", "position_mt",
]
const ENTITY_OPTIONAL: Array[String] = [
	"catalog_id",
	"detection_radius_mt",
	"elevation",
	"facing_mdeg",
	"hero_level",
	"hp",
	"invisible",
	"is_air",
	"layer",
	"mana",
	"mana_hidden",
	"max_hp",
	"observable_activity",
	"occupied_cell_ids",
	"occupied_cells",
	"owned_observation",
	"region_id",
	"sight_day_mt",
	"sight_night_mt",
	"sight_radius_mt",
	"tags",
	"type_id",
	"visible_statuses",
]
const SEAT_REQUIRED: Array[String] = [
	"decision",
	"economy",
	"food",
	"last_action_receipt",
	"observation_seq",
	"own_technology",
	"seat",
	"squad_candidates",
	"upkeep",
	"working_memory",
]
const SEAT_OPTIONAL: Array[String] = [
	"include_brief",
	"local_context_candidates",
	"maximum_observation_bytes",
	"revealed_entity_internal_ids",
	"structure_type_ids",
	"temporary_vision_sources",
	"visible_item_candidates",
	"visible_shop_candidates",
]
const EVENT_REQUIRED: Array[String] = []
const EVENT_OPTIONAL: Array[String] = [
	"audience_mask",
	"audience_seats",
	"entity_internal_id",
	"event_kind",
	"event_seq",
	"kind",
	"owner_seat",
	"payload",
	"phase",
	"player_payloads",
	"public_payload",
	"source_internal_id",
	"target_internal_id",
	"tick",
	"visibility_rule",
	"world_event_seq",
]
const ITEM_REQUIRED: Array[String] = [
	"charges", "entity_internal_id", "item_type_id", "position_mt", "region_id",
]
const ITEM_OPTIONAL: Array[String] = ["despawn_tick"]
const SHOP_REQUIRED: Array[String] = [
	"entity_internal_id", "offers", "position_mt", "region_id", "shop_type", "site_id",
]
const LOCAL_REQUIRED: Array[String] = [
	"anchor_internal_id",
	"detection_radius_mt",
	"elevation",
	"exits",
	"nearby_features",
	"retreat_route",
	"tactical_slot",
	"terrain",
	"visibility_radius_mt",
]
const LOCAL_OPTIONAL: Array[String] = []
const TERMINAL_REQUIRED: Array[String] = ["kind", "reason", "terminal_tick", "winner_seat"]
const TERMINAL_KINDS: Array[String] = [
	"victory", "draw", "forfeit", "infrastructure_void",
]
const PROTECTED_INPUT_KEY_FRAGMENTS: Array[String] = [
	"alias_salt",
	"hidden_state",
	"model_identity",
	"omniscient",
	"opponent_economy",
	"opponent_inventory",
	"opponent_queue",
	"opponent_resource",
	"opponent_upgrade",
	"provider_identity",
	"secret",
	"state_hash",
	"world_checkpoint",
	"world_hash",
]

const OWNED_OBSERVATION_KEYS: Array[String] = [
	"abilities",
	"armor_centi",
	"armor_class",
	"attack_cooldown_remaining_ticks",
	"attributes",
	"autocast",
	"buffs",
	"builder_internal_ids",
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


static func validate_phase_snapshot(value: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("$.phase_snapshot must be an object")
		return errors
	var phase: Dictionary = value
	for error: String in Codec.validate_canonical_value(phase, "$.phase_snapshot"):
		errors.append(error)
	if _contains_protected_input_key(phase):
		errors.append("$.phase_snapshot contains a protected hidden/provider key")
	_exact_fields(phase, PHASE_REQUIRED, [], "$.phase_snapshot", errors)
	_non_negative_int(phase.get("tick"), "$.phase_snapshot.tick", errors)
	if str(phase.get("day_phase", "")) not in ObservationContract.DAY_PHASES:
		errors.append("$.phase_snapshot.day_phase is invalid")
	_int_range(
		phase.get("remaining_match_ticks"), 0, ObservationContract.MAX_MATCH_TICKS,
		"$.phase_snapshot.remaining_match_ticks", errors
	)
	_non_negative_int(
		phase.get("no_progress_ticks"), "$.phase_snapshot.no_progress_ticks", errors
	)
	_validate_grid(phase.get("grid_snapshot"), errors)
	_validate_entities(phase.get("entity_snapshots"), errors)
	_validate_events(phase.get("candidate_events"), errors)
	_validate_seats(
		phase.get("seat_snapshots"),
		int(phase.get("tick", -1)),
		_entity_owner_index(phase.get("entity_snapshots")),
		errors
	)
	_validate_terminal(phase.get("terminal"), errors)
	return errors


static func _validate_grid(value: Variant, errors: PackedStringArray) -> void:
	var path := "$.phase_snapshot.grid_snapshot"
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " must be an object")
		return
	var grid: Dictionary = value
	_exact_fields(grid, GRID_REQUIRED, GRID_OPTIONAL, path, errors)
	if typeof(grid.get("width")) != TYPE_INT or int(grid.get("width", 0)) <= 0:
		errors.append(path + ".width must be a positive integer")
	if typeof(grid.get("height")) != TYPE_INT or int(grid.get("height", 0)) <= 0:
		errors.append(path + ".height must be a positive integer")
	if grid.get("cell_size_mt") != 500:
		errors.append(path + ".cell_size_mt must be 500")
	if typeof(grid.get("width")) != TYPE_INT or typeof(grid.get("height")) != TYPE_INT:
		return
	var count := int(grid["width"]) * int(grid["height"])
	for field: String in [
		"elevations", "los_block_heights", "region_ids", "terrain_ids",
	]:
		if typeof(grid.get(field)) != TYPE_ARRAY or (grid[field] as Array).size() != count:
			errors.append("%s.%s must contain exactly %d entries" % [path, field, count])
	if grid.has("los_block_kinds") and (
		typeof(grid["los_block_kinds"]) != TYPE_ARRAY
		or (grid["los_block_kinds"] as Array).size() != count
	):
		errors.append("%s.los_block_kinds must contain exactly %d entries" % [path, count])


static func _validate_entities(value: Variant, errors: PackedStringArray) -> void:
	var path := "$.phase_snapshot.entity_snapshots"
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var seen: Dictionary = {}
	for index: int in (value as Array).size():
		var row_path := "%s[%d]" % [path, index]
		if typeof(value[index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var entity: Dictionary = value[index]
		_exact_fields(entity, ENTITY_REQUIRED, ENTITY_OPTIONAL, row_path, errors)
		var internal_id: Variant = entity.get("internal_id")
		if typeof(internal_id) != TYPE_INT or int(internal_id) <= 0:
			errors.append(row_path + ".internal_id must be positive")
		elif seen.has(int(internal_id)):
			errors.append(row_path + ".internal_id is duplicated")
		else:
			seen[int(internal_id)] = true
		if typeof(entity.get("owner_seat")) != TYPE_INT \
			or int(entity.get("owner_seat", -2)) < -1 \
			or int(entity.get("owner_seat", -2)) > 1:
			errors.append(row_path + ".owner_seat must be -1, 0, or 1")
		if typeof(entity.get("alive")) != TYPE_BOOL:
			errors.append(row_path + ".alive must be boolean")
		_integer_pair(entity.get("position_mt"), row_path + ".position_mt", errors)
		if entity.has("owned_observation"):
			if typeof(entity["owned_observation"]) != TYPE_DICTIONARY:
				errors.append(row_path + ".owned_observation must be an object")
			else:
				_exact_fields(
					entity["owned_observation"], [], OWNED_OBSERVATION_KEYS,
					row_path + ".owned_observation", errors
				)
				_validate_owned_observation(
					entity["owned_observation"], row_path + ".owned_observation", errors
				)


static func _validate_events(value: Variant, errors: PackedStringArray) -> void:
	var path := "$.phase_snapshot.candidate_events"
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	for index: int in (value as Array).size():
		var row_path := "%s[%d]" % [path, index]
		if typeof(value[index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var event: Dictionary = value[index]
		_exact_fields(event, EVENT_REQUIRED, EVENT_OPTIONAL, row_path, errors)
		if not event.has("kind") and not event.has("event_kind"):
			errors.append(row_path + " must define kind or event_kind")


static func _validate_seats(
	value: Variant,
	tick: int,
	entity_owners: Dictionary,
	errors: PackedStringArray
) -> void:
	var path := "$.phase_snapshot.seat_snapshots"
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2:
		errors.append(path + " must contain exactly two seat snapshots")
		return
	var seats: Dictionary = {}
	for index: int in (value as Array).size():
		var row_path := "%s[%d]" % [path, index]
		if typeof(value[index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var seat_snapshot: Dictionary = value[index]
		_exact_fields(seat_snapshot, SEAT_REQUIRED, SEAT_OPTIONAL, row_path, errors)
		var seat_value: Variant = seat_snapshot.get("seat")
		if typeof(seat_value) != TYPE_INT or int(seat_value) not in [0, 1]:
			errors.append(row_path + ".seat must be 0 or 1")
		else:
			seats[int(seat_value)] = true
		_non_negative_int(seat_snapshot.get("observation_seq"), row_path + ".observation_seq", errors)
		if typeof(seat_snapshot.get("decision")) == TYPE_DICTIONARY \
			and int((seat_snapshot["decision"] as Dictionary).get("observation_tick", -1)) != tick:
			errors.append(row_path + ".decision.observation_tick must equal phase tick")
		_validate_candidate_array(
			seat_snapshot.get("visible_item_candidates", []), ITEM_REQUIRED, ITEM_OPTIONAL,
			row_path + ".visible_item_candidates", errors
		)
		_validate_candidate_array(
			seat_snapshot.get("visible_shop_candidates", []), SHOP_REQUIRED, [],
			row_path + ".visible_shop_candidates", errors
		)
		_validate_candidate_array(
			seat_snapshot.get("local_context_candidates", []), LOCAL_REQUIRED, LOCAL_OPTIONAL,
			row_path + ".local_context_candidates", errors
		)
		_preflight_public_fields(seat_snapshot, row_path, errors)
		_validate_own_technology(
			seat_snapshot.get("own_technology"), int(seat_value), entity_owners,
			row_path + ".own_technology", errors
		)
		_validate_squad_candidates(
			seat_snapshot.get("squad_candidates"), int(seat_value), entity_owners,
			row_path + ".squad_candidates", errors
		)
		_validate_item_candidates(
			seat_snapshot.get("visible_item_candidates", []),
			row_path + ".visible_item_candidates", errors
		)
		_validate_shop_candidates(
			seat_snapshot.get("visible_shop_candidates", []),
			row_path + ".visible_shop_candidates", errors
		)
		_validate_local_candidates(
			seat_snapshot.get("local_context_candidates", []), int(seat_value), entity_owners,
			row_path + ".local_context_candidates", errors
		)
		_validate_visibility_overrides(
			seat_snapshot.get("temporary_vision_sources", []),
			seat_snapshot.get("revealed_entity_internal_ids", []),
			entity_owners,
			row_path,
			errors
		)
	if seats.size() != 2:
		errors.append(path + " must contain one snapshot for each seat")


static func _validate_visibility_overrides(
	sources_value: Variant,
	revealed_value: Variant,
	entity_owners: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	if typeof(sources_value) != TYPE_ARRAY:
		errors.append(path + ".temporary_vision_sources must be an array")
	else:
		for index: int in (sources_value as Array).size():
			var row_path := "%s.temporary_vision_sources[%d]" % [path, index]
			if typeof(sources_value[index]) != TYPE_DICTIONARY:
				errors.append(row_path + " must be an object")
				continue
			var source: Dictionary = sources_value[index]
			_exact_fields(source, [
				"detection_radius_mt", "elevation", "position_mt", "sight_radius_mt",
			], [], row_path, errors)
			_integer_pair(source.get("position_mt"), row_path + ".position_mt", errors)
			for field: String in ["detection_radius_mt", "elevation", "sight_radius_mt"]:
				_non_negative_int(source.get(field), row_path + "." + field, errors)
			if int(source.get("elevation", -1)) > 2:
				errors.append(row_path + ".elevation must be in [0,2]")
	if typeof(revealed_value) != TYPE_ARRAY:
		errors.append(path + ".revealed_entity_internal_ids must be an array")
		return
	var seen: Dictionary = {}
	for index: int in (revealed_value as Array).size():
		var value: Variant = revealed_value[index]
		if typeof(value) != TYPE_INT or int(value) <= 0 \
			or not entity_owners.has(int(value)) or seen.has(int(value)):
			errors.append(
				"%s.revealed_entity_internal_ids[%d] is invalid or duplicated" % [path, index]
			)
		else:
			seen[int(value)] = true


static func _validate_candidate_array(
	value: Variant,
	required: Array[String],
	optional: Array[String],
	path: String,
	errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	for index: int in (value as Array).size():
		var row_path := "%s[%d]" % [path, index]
		if typeof(value[index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		_exact_fields(value[index], required, optional, row_path, errors)


static func _validate_terminal(value: Variant, errors: PackedStringArray) -> void:
	if value == null:
		return
	var path := "$.phase_snapshot.terminal"
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " must be null or an object")
		return
	var terminal: Dictionary = value
	_exact_fields(terminal, TERMINAL_REQUIRED, [], path, errors)
	var kind := str(terminal.get("kind", ""))
	if kind not in TERMINAL_KINDS:
		errors.append(path + ".kind is invalid")
	var winner: Variant = terminal.get("winner_seat")
	if kind in ["victory", "forfeit"]:
		if typeof(winner) != TYPE_INT or int(winner) not in [0, 1]:
			errors.append(path + ".winner_seat must be 0 or 1")
	elif winner != null:
		errors.append(path + ".winner_seat must be null for this terminal kind")
	if not ObservationContract.is_public_id(terminal.get("reason")):
		errors.append(path + ".reason is invalid")
	_non_negative_int(terminal.get("terminal_tick"), path + ".terminal_tick", errors)


static func _preflight_public_fields(
	seat_snapshot: Dictionary, path: String, errors: PackedStringArray
) -> void:
	var context := {
		"day_phase": "day",
		"decision": _copy_container(seat_snapshot.get("decision", {})),
		"economy": _copy_container(seat_snapshot.get("economy", {})),
		"food": _copy_container(seat_snapshot.get("food", {})),
		"last_action_receipt": _copy_container(seat_snapshot.get("last_action_receipt", null)),
		"match_id": "m_perception-preflight",
		"match_state": {"no_progress_ticks": 0, "status": "active"},
		"observation_seq": seat_snapshot.get("observation_seq", -1),
		"remaining_match_ticks": ObservationContract.MAX_MATCH_TICKS,
		"squads": [],
		"technology": {
			"completed_upgrades": [],
			"hero_slots": {"available": 3, "used": 0},
			"researching": [],
			"tier": 1,
		},
		"upkeep": _copy_container(seat_snapshot.get("upkeep", {})),
		"visible_items": [],
		"visible_shops": [],
		"working_memory": seat_snapshot.get("working_memory", null),
	}
	for optional: String in [
		"include_brief", "maximum_observation_bytes", "structure_type_ids",
	]:
		if seat_snapshot.has(optional):
			context[optional] = _copy_container(seat_snapshot[optional])
	for message: String in ObservationContract.validate_public_context(context):
		errors.append(path + " public preflight: " + message)


static func _validate_own_technology(
	value: Variant,
	seat: int,
	entity_owners: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " must be an object")
		return
	var technology: Dictionary = value
	_exact_fields(
		technology, ["completed_upgrades", "hero_slots", "researching", "tier"], [],
		path, errors
	)
	if typeof(technology.get("researching")) != TYPE_ARRAY:
		errors.append(path + ".researching must be an array")
		return
	for index: int in (technology["researching"] as Array).size():
		var row_path := "%s.researching[%d]" % [path, index]
		if typeof(technology["researching"][index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var row: Dictionary = technology["researching"][index]
		_exact_fields(row, ["entry", "producer_internal_id"], [], row_path, errors)
		_validate_queue_entry(row.get("entry"), row_path + ".entry", errors)
		_validate_owned_reference(
			row.get("producer_internal_id"), seat, entity_owners,
			row_path + ".producer_internal_id", errors
		)


static func _validate_squad_candidates(
	value: Variant,
	seat: int,
	entity_owners: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	for index: int in (value as Array).size():
		var row_path := "%s[%d]" % [path, index]
		if typeof(value[index]) != TYPE_DICTIONARY:
			errors.append(row_path + " must be an object")
			continue
		var row: Dictionary = value[index]
		_exact_fields(
			row,
			["current_order", "formation", "member_internal_ids", "squad_id", "stance"],
			["retreat_hp_threshold_bp"], row_path, errors
		)
		if typeof(row.get("member_internal_ids")) != TYPE_ARRAY:
			errors.append(row_path + ".member_internal_ids must be an array")
		else:
			for member: Variant in row["member_internal_ids"]:
				_validate_owned_reference(
					member, seat, entity_owners, row_path + ".member_internal_ids", errors
				)
		_validate_order(row.get("current_order"), row_path + ".current_order", errors)


static func _validate_item_candidates(
	value: Array, path: String, errors: PackedStringArray
) -> void:
	for index: int in value.size():
		var row: Dictionary = value[index]
		_positive_int(row.get("entity_internal_id"), "%s[%d].entity_internal_id" % [path, index], errors)
		_integer_pair(row.get("position_mt"), "%s[%d].position_mt" % [path, index], errors)


static func _validate_shop_candidates(
	value: Array, path: String, errors: PackedStringArray
) -> void:
	for index: int in value.size():
		var row: Dictionary = value[index]
		var row_path := "%s[%d]" % [path, index]
		_positive_int(row.get("entity_internal_id"), row_path + ".entity_internal_id", errors)
		_integer_pair(row.get("position_mt"), row_path + ".position_mt", errors)
		if typeof(row.get("offers")) != TYPE_ARRAY:
			errors.append(row_path + ".offers must be an array")
			continue
		for offer_index: int in (row["offers"] as Array).size():
			var offer_path := "%s.offers[%d]" % [row_path, offer_index]
			if typeof(row["offers"][offer_index]) != TYPE_DICTIONARY:
				errors.append(offer_path + " must be an object")
				continue
			_exact_fields(
				row["offers"][offer_index],
				[
					"available", "cost_gold", "cost_lumber", "kind", "next_restock_tick",
					"offer_id", "stock",
				],
				["requires_service_target"], offer_path, errors
			)


static func _validate_local_candidates(
	value: Array,
	seat: int,
	entity_owners: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	for index: int in value.size():
		var row: Dictionary = value[index]
		var row_path := "%s[%d]" % [path, index]
		_validate_owned_reference(
			row.get("anchor_internal_id"), seat, entity_owners,
			row_path + ".anchor_internal_id", errors
		)
		if typeof(row.get("exits")) != TYPE_ARRAY:
			errors.append(row_path + ".exits must be an array")
		else:
			for exit_index: int in (row["exits"] as Array).size():
				var exit_path := "%s.exits[%d]" % [row_path, exit_index]
				if typeof(row["exits"][exit_index]) != TYPE_DICTIONARY:
					errors.append(exit_path + " must be an object")
					continue
				_exact_fields(
					row["exits"][exit_index],
					[
						"bearing", "choke_width_mt", "known_blockage", "path_distance_mt",
						"to_region_id",
					], [], exit_path, errors
				)
		if typeof(row.get("nearby_features")) != TYPE_ARRAY:
			errors.append(row_path + ".nearby_features must be an array")
		else:
			for feature_index: int in (row["nearby_features"] as Array).size():
				var feature_path := "%s.nearby_features[%d]" % [row_path, feature_index]
				if typeof(row["nearby_features"][feature_index]) != TYPE_DICTIONARY:
					errors.append(feature_path + " must be an object")
					continue
				_exact_fields(
					row["nearby_features"][feature_index],
					["bearing", "kind", "path_distance_mt", "site_id"], ["state"],
					feature_path, errors
				)


static func _validate_owned_observation(
	value: Dictionary, path: String, errors: PackedStringArray
) -> void:
	if value.has("cargo"):
		_validate_nested_exact(value["cargo"], ["amount", "resource"], [], path + ".cargo", errors)
	if value.has("attributes"):
		_validate_nested_exact(
			value["attributes"], ["agility", "intellect", "strength"], [],
			path + ".attributes", errors
		)
	for field: String in ["abilities"]:
		_validate_dictionary_array_if_present(
			value, field,
			["ability_id", "autocast_enabled", "cooldown_remaining_ticks", "rank"], [],
			path, errors
		)
	for field: String in ["producer_queue"]:
		if not value.has(field):
			continue
		if typeof(value[field]) != TYPE_ARRAY:
			errors.append(path + "." + field + " must be an array")
		else:
			for index: int in (value[field] as Array).size():
				_validate_queue_entry(
					value[field][index], "%s.%s[%d]" % [path, field, index], errors
				)
	_validate_dictionary_array_if_present(
		value, "inventory",
		["charges", "cooldown_remaining_ticks", "item_instance_id", "item_type_id", "slot"],
		[], path, errors
	)
	for field: String in ["statuses", "buffs", "debuffs"]:
		_validate_dictionary_array_if_present(
			value, field,
			[
				"dispel_class", "expiry_tick", "stacking_key", "stacks", "start_tick",
				"status_id",
			],
			["magnitude", "source_entity_id", "source_internal_id"], path, errors
		)
	if value.has("current_order"):
		_validate_order(value["current_order"], path + ".current_order", errors)
	if value.has("queued_orders"):
		if typeof(value["queued_orders"]) != TYPE_ARRAY:
			errors.append(path + ".queued_orders must be an array")
		else:
			for index: int in (value["queued_orders"] as Array).size():
				_validate_order(
					value["queued_orders"][index], "%s.queued_orders[%d]" % [path, index], errors
				)
	if value.has("revival_state") and value["revival_state"] != null:
		_validate_nested_exact(
			value["revival_state"], ["method", "progress_bp", "remaining_ticks"],
			["reviver_id", "reviver_internal_id"], path + ".revival_state", errors
		)


static func _validate_queue_entry(value: Variant, path: String, errors: PackedStringArray) -> void:
	_validate_nested_exact(
		value,
		[
			"kind", "paused", "progress_bp", "queue_entry_id", "remaining_ticks",
			"reserved_food", "reserved_gold", "reserved_lumber", "type_id",
		], ["pause_reason"], path, errors
	)


static func _validate_order(value: Variant, path: String, errors: PackedStringArray) -> void:
	if value == null:
		return
	_validate_nested_exact(
		value, ["compiled_order_id", "issued_tick", "op", "state"],
		[
			"batch_id", "command_id", "route_region_ids", "target_entity_id",
			"target_internal_id", "target_position_mt", "target_region_id", "target_site_id",
		], path, errors
	)


static func _validate_dictionary_array_if_present(
	container: Dictionary,
	field: String,
	required: Array[String],
	optional: Array[String],
	path: String,
	errors: PackedStringArray
) -> void:
	if not container.has(field):
		return
	if typeof(container[field]) != TYPE_ARRAY:
		errors.append(path + "." + field + " must be an array")
		return
	for index: int in (container[field] as Array).size():
		_validate_nested_exact(
			container[field][index], required, optional,
			"%s.%s[%d]" % [path, field, index], errors
		)


static func _validate_nested_exact(
	value: Variant,
	required: Array[String],
	optional: Array[String],
	path: String,
	errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " must be an object")
		return
	_exact_fields(value, required, optional, path, errors)


static func _validate_owned_reference(
	value: Variant,
	seat: int,
	entity_owners: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_INT or int(value) <= 0:
		errors.append(path + " must be a positive entity reference")
	elif int(entity_owners.get(int(value), -2)) != seat:
		errors.append(path + " must reference an entity owned by the same seat")


static func _entity_owner_index(value: Variant) -> Dictionary:
	var result: Dictionary = {}
	if typeof(value) == TYPE_ARRAY:
		for entity_variant: Variant in value:
			if typeof(entity_variant) == TYPE_DICTIONARY:
				var entity: Dictionary = entity_variant
				if typeof(entity.get("internal_id")) == TYPE_INT \
					and typeof(entity.get("owner_seat")) == TYPE_INT:
					result[int(entity["internal_id"])] = int(entity["owner_seat"])
	return result


static func _contains_protected_input_key(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		for key_variant: Variant in (value as Dictionary).keys():
			var key := str(key_variant).to_lower()
			for fragment: String in PROTECTED_INPUT_KEY_FRAGMENTS:
				if fragment in key:
					return true
			if _contains_protected_input_key(value[key_variant]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			if _contains_protected_input_key(element):
				return true
	return false


static func _copy_container(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY or typeof(value) == TYPE_ARRAY:
		return value.duplicate(true)
	return value


static func _exact_fields(
	value: Dictionary,
	required: Array[String],
	optional: Array[String],
	path: String,
	errors: PackedStringArray
) -> void:
	for key: String in required:
		if not value.has(key):
			errors.append(path + "." + key + " is required")
	var allowed: Dictionary = {}
	for key: String in required:
		allowed[key] = true
	for key: String in optional:
		allowed[key] = true
	for key_variant: Variant in value.keys():
		var key := str(key_variant)
		if not allowed.has(key):
			errors.append(path + "." + key + " is not allowed")


static func _non_negative_int(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_INT or int(value) < 0:
		errors.append(path + " must be a non-negative integer")


static func _positive_int(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_INT or int(value) <= 0:
		errors.append(path + " must be a positive integer")


static func _int_range(
	value: Variant, minimum: int, maximum: int, path: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_INT or int(value) < minimum or int(value) > maximum:
		errors.append("%s must be an integer in [%d,%d]" % [path, minimum, maximum])


static func _integer_pair(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2 \
		or typeof(value[0]) != TYPE_INT or typeof(value[1]) != TYPE_INT:
		errors.append(path + " must be an integer pair")
