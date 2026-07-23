class_name DuelObservationContract
extends RefCounted

## Locked, engine-side structural contract for observation.v1.
##
## Python performs the full Draft 2020-12 validation at the gateway boundary.
## This contract repeats the security-critical and deterministic subset in
## Godot: exact object fields, JSON-safe integer-only values, identifier and
## enum domains, collection caps/order, public-context provenance, and the
## observation-hash scope.

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const PROTOCOL_VERSION := "worldeval-rts/1.0.0"
const MAX_OBSERVATION_BYTES := 262_144
const MAX_WORKING_MEMORY_BYTES := 4_096
const MAX_MATCH_TICKS := 18_000
const MAX_COMMAND_OBJECTS := 16
const MAX_ATOMIC_ORDER_COST := 64
const MAX_ACTOR_IDS := 24
const MAX_QUEUE_ENTRIES := 8

const TOP_LEVEL_REQUIRED: Array[String] = [
	"message_type",
	"protocol_version",
	"match_id",
	"observation_seq",
	"observation_hash",
	"tick",
	"game_time",
	"decision",
	"working_memory",
	"objective",
	"match_state",
	"day_phase",
	"remaining_match_ticks",
	"economy",
	"food",
	"upkeep",
	"technology",
	"heroes",
	"owned_entities",
	"owned_structures",
	"squads",
	"visible_contacts",
	"remembered_contacts",
	"visible_neutrals",
	"visible_items",
	"visible_shops",
	"map_state",
	"events_since_previous",
	"last_action_receipt",
	"limits_remaining",
	"observation_truncated",
	"omitted_counts",
]
const TOP_LEVEL_OPTIONAL: Array[String] = ["brief"]

## Data absent from AgentKnowledgeState that is nevertheless already public to
## the observing player. Unknown keys fail closed. In particular, no WorldState,
## checkpoint hash, opponent economy, provider identity, or alias salt can be
## smuggled through this boundary.
const PUBLIC_CONTEXT_REQUIRED: Array[String] = [
	"match_id",
	"observation_seq",
	"decision",
	"working_memory",
	"match_state",
	"day_phase",
	"remaining_match_ticks",
	"economy",
	"food",
	"upkeep",
	"technology",
	"squads",
	"visible_items",
	"visible_shops",
	"last_action_receipt",
]
const PUBLIC_CONTEXT_OPTIONAL: Array[String] = [
	"include_brief",
	"maximum_observation_bytes",
	"structure_type_ids",
]

const KNOWLEDGE_REQUIRED: Array[String] = [
	"events_since_previous",
	"map_state",
	"owned_entities",
	"remembered_contacts",
	"tick",
	"visible_contacts",
]
const KNOWLEDGE_OPTIONAL: Array[String] = ["destroyed_contacts"]

const DAY_PHASES: Array[String] = ["day", "night", "forced_night"]
const MODES: Array[String] = ["fixed_simultaneous", "continuous_realtime"]
const UPKEEP_TIERS: Array[String] = ["none", "low", "high"]
const ARMOR_CLASSES: Array[String] = ["light", "medium", "heavy", "fortified", "hero"]
const MOVEMENT_STATES: Array[String] = ["idle", "moving", "rooted", "stunned", "transported"]
const STANCES: Array[String] = ["aggressive", "defensive", "hold_position", "hold_fire"]
const FORMATIONS: Array[String] = ["none", "line", "compact", "spread", "wedge"]
const BEARINGS: Array[String] = [
	"north", "north_east", "east", "south_east", "south", "south_west", "west",
	"north_west", "same",
]
const ACTIVITIES: Array[String] = [
	"idle", "moving", "attacking", "casting", "gathering", "building", "repairing",
	"transported", "unknown",
]
const TERMINAL_RESULTS: Array[String] = [
	"win", "loss", "draw", "forfeit", "infrastructure_void",
]
const BATCH_STATUSES: Array[String] = [
	"applied", "partially_applied", "rejected", "expired", "timed_out", "no_op",
]
const COMMAND_STATUSES: Array[String] = ["applied", "partially_applied", "rejected"]

const FORBIDDEN_KEY_FRAGMENTS: Array[String] = [
	"internal_id",
	"alias_salt",
	"omniscient",
	"world_checkpoint",
	"world_hash",
	"state_hash",
	"hidden_state",
	"secret",
	"provider_identity",
	"model_identity",
	"opponent_resource",
	"opponent_economy",
	"opponent_queue",
	"opponent_upgrade",
	"opponent_inventory",
	"planned_destination",
]


static func validate_public_context(value: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("$.public_context must be an object")
		return errors
	var context: Dictionary = value
	_validate_canonical_and_public(context, "$.public_context", errors)
	_validate_exact_fields(
		context, PUBLIC_CONTEXT_REQUIRED, PUBLIC_CONTEXT_OPTIONAL, "$.public_context", errors
	)
	if not is_match_id(context.get("match_id")):
		errors.append("$.public_context.match_id is invalid")
	_require_non_negative_int(context.get("observation_seq"), "$.public_context.observation_seq", errors)
	_validate_decision(context.get("decision"), "$.public_context.decision", errors)
	_validate_working_memory(context.get("working_memory"), errors)
	_validate_match_state(context.get("match_state"), "$.public_context.match_state", errors)
	if not _is_enum(context.get("day_phase"), DAY_PHASES):
		errors.append("$.public_context.day_phase is invalid")
	_require_int_range(
		context.get("remaining_match_ticks"), 0, MAX_MATCH_TICKS,
		"$.public_context.remaining_match_ticks", errors
	)
	_validate_economy(context.get("economy"), "$.public_context.economy", errors)
	_validate_food(context.get("food"), "$.public_context.food", errors)
	_validate_upkeep(context.get("upkeep"), "$.public_context.upkeep", errors)
	_validate_technology(context.get("technology"), "$.public_context.technology", errors)
	_validate_squads(context.get("squads"), "$.public_context.squads", errors)
	_validate_visible_items(context.get("visible_items"), "$.public_context.visible_items", errors)
	_validate_visible_shops(context.get("visible_shops"), "$.public_context.visible_shops", errors)
	_validate_receipt(context.get("last_action_receipt"), "$.public_context.last_action_receipt", errors)
	if context.has("include_brief") and typeof(context["include_brief"]) != TYPE_BOOL:
		errors.append("$.public_context.include_brief must be boolean")
	if context.has("maximum_observation_bytes"):
		_require_int_range(
			context["maximum_observation_bytes"], 1_024, MAX_OBSERVATION_BYTES,
			"$.public_context.maximum_observation_bytes", errors
		)
	if context.has("structure_type_ids"):
		_validate_sorted_unique_public_ids(
			context["structure_type_ids"], "$.public_context.structure_type_ids", errors, false
		)
	return errors


static func validate_knowledge_projection(value: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("$.knowledge_projection must be an object")
		return errors
	var projection: Dictionary = value
	_validate_canonical_and_public(projection, "$.knowledge_projection", errors)
	_validate_exact_fields(
		projection, KNOWLEDGE_REQUIRED, KNOWLEDGE_OPTIONAL, "$.knowledge_projection", errors
	)
	_require_non_negative_int(projection.get("tick"), "$.knowledge_projection.tick", errors)
	for field: String in [
		"owned_entities", "visible_contacts", "remembered_contacts", "events_since_previous",
	]:
		if typeof(projection.get(field)) != TYPE_ARRAY:
			errors.append("$.knowledge_projection.%s must be an array" % field)
	if projection.has("destroyed_contacts") and typeof(projection["destroyed_contacts"]) != TYPE_ARRAY:
		errors.append("$.knowledge_projection.destroyed_contacts must be an array")
	_validate_map_state(projection.get("map_state"), "$.knowledge_projection.map_state", errors)
	return errors


static func validate_observation(value: Variant, verify_hash: bool = true) -> PackedStringArray:
	var errors := PackedStringArray()
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("$ must be an object")
		return errors
	var observation: Dictionary = value
	_validate_canonical_and_public(observation, "$", errors)
	_validate_exact_fields(observation, TOP_LEVEL_REQUIRED, TOP_LEVEL_OPTIONAL, "$", errors)
	if str(observation.get("message_type", "")) != "observation":
		errors.append("$.message_type must be observation")
	if str(observation.get("protocol_version", "")) != PROTOCOL_VERSION:
		errors.append("$.protocol_version is unsupported")
	if not is_match_id(observation.get("match_id")):
		errors.append("$.match_id is invalid")
	_require_non_negative_int(observation.get("observation_seq"), "$.observation_seq", errors)
	if not is_sha256(observation.get("observation_hash")):
		errors.append("$.observation_hash must be lowercase SHA-256")
	_require_non_negative_int(observation.get("tick"), "$.tick", errors)
	_validate_game_time(observation.get("game_time"), "$.game_time", errors)
	_validate_decision(observation.get("decision"), "$.decision", errors)
	_validate_working_memory(observation.get("working_memory"), errors)
	_validate_objective(observation.get("objective"), "$.objective", errors)
	_validate_match_state(observation.get("match_state"), "$.match_state", errors)
	if not _is_enum(observation.get("day_phase"), DAY_PHASES):
		errors.append("$.day_phase is invalid")
	_require_int_range(
		observation.get("remaining_match_ticks"), 0, MAX_MATCH_TICKS,
		"$.remaining_match_ticks", errors
	)
	_validate_economy(observation.get("economy"), "$.economy", errors)
	_validate_food(observation.get("food"), "$.food", errors)
	_validate_upkeep(observation.get("upkeep"), "$.upkeep", errors)
	_validate_technology(observation.get("technology"), "$.technology", errors)
	_validate_owned_array(observation.get("heroes"), "$.heroes", 3, "hero", errors)
	_validate_owned_array(observation.get("owned_entities"), "$.owned_entities", 100, "entity", errors)
	_validate_owned_array(
		observation.get("owned_structures"), "$.owned_structures", 80, "structure", errors
	)
	_validate_squads(observation.get("squads"), "$.squads", errors)
	_validate_visible_contacts(
		observation.get("visible_contacts"), "$.visible_contacts", 180, "opponent", errors
	)
	_validate_remembered_contacts(
		observation.get("remembered_contacts"), "$.remembered_contacts", errors
	)
	_validate_visible_contacts(
		observation.get("visible_neutrals"), "$.visible_neutrals", 96, "neutral", errors
	)
	_validate_visible_items(observation.get("visible_items"), "$.visible_items", errors)
	_validate_visible_shops(observation.get("visible_shops"), "$.visible_shops", errors)
	_validate_map_state(observation.get("map_state"), "$.map_state", errors)
	_validate_events(observation.get("events_since_previous"), "$.events_since_previous", errors)
	_validate_receipt(observation.get("last_action_receipt"), "$.last_action_receipt", errors)
	_validate_limits(observation.get("limits_remaining"), "$.limits_remaining", errors)
	if observation.has("brief"):
		_validate_brief(observation["brief"], errors)
	if typeof(observation.get("observation_truncated")) != TYPE_BOOL:
		errors.append("$.observation_truncated must be boolean")
	_validate_omitted_counts(observation.get("omitted_counts"), "$.omitted_counts", errors)

	if typeof(observation.get("tick")) == TYPE_INT \
		and typeof(observation.get("game_time")) == TYPE_DICTIONARY:
		var game_time: Dictionary = observation["game_time"]
		if int(game_time.get("ticks", -1)) != int(observation["tick"]):
			errors.append("$.game_time.ticks must equal $.tick")
		if str(game_time.get("day_phase", "")) != str(observation.get("day_phase", "")):
			errors.append("$.game_time.day_phase must equal $.day_phase")
	if typeof(observation.get("decision")) == TYPE_DICTIONARY \
		and typeof(observation.get("tick")) == TYPE_INT:
		if int((observation["decision"] as Dictionary).get("observation_tick", -1)) \
			!= int(observation["tick"]):
			errors.append("$.decision.observation_tick must equal $.tick")
	if verify_hash and is_sha256(observation.get("observation_hash")):
		var expected_hash := observation_hash(observation)
		if expected_hash != str(observation["observation_hash"]):
			errors.append("$.observation_hash does not match the legal observation hash scope")
	return errors


static func observation_hash(observation: Dictionary) -> String:
	var hash_scope := observation.duplicate(true)
	hash_scope.erase("observation_hash")
	return Codec.sha256_canonical(hash_scope)


static func contains_forbidden_key(value: Variant) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary: Dictionary = value
		for key_variant: Variant in dictionary.keys():
			var key := str(key_variant).to_lower()
			for fragment: String in FORBIDDEN_KEY_FRAGMENTS:
				if fragment in key:
					return true
			if contains_forbidden_key(dictionary[key_variant]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for element: Variant in value:
			if contains_forbidden_key(element):
				return true
	return false


static func is_match_id(value: Variant) -> bool:
	return _matches(value, "^m_[A-Za-z0-9._-]{1,120}$")


static func is_entity_id(value: Variant) -> bool:
	return _matches(value, "^e_[A-Za-z0-9._-]{1,80}$")


static func is_public_id(value: Variant) -> bool:
	return _matches(value, "^[a-z0-9][a-z0-9._-]{0,95}$")


static func is_id(value: Variant) -> bool:
	return _matches(value, "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


static func is_sha256(value: Variant) -> bool:
	return _matches(value, "^[0-9a-f]{64}$")


static func _validate_canonical_and_public(
	value: Variant, path: String, errors: PackedStringArray
) -> void:
	for error: String in Codec.validate_canonical_value(value, path):
		errors.append(error)
	if contains_forbidden_key(value):
		errors.append("%s contains a protected hidden-state key" % path)


static func _validate_working_memory(value: Variant, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_STRING:
		errors.append("$.working_memory must be a string")
		return
	var text := str(value)
	if text.length() > MAX_WORKING_MEMORY_BYTES \
		or text.to_utf8_buffer().size() > MAX_WORKING_MEMORY_BYTES:
		errors.append("$.working_memory exceeds 4096 UTF-8 bytes/codepoints")
	for index: int in text.length():
		var code := text.unicode_at(index)
		if code < 32 or code == 127 or (code >= 0x202a and code <= 0x202e) \
			or (code >= 0x2066 and code <= 0x2069):
			errors.append("$.working_memory contains a control or bidi formatting code point")
			break


static func _validate_game_time(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(
		object, ["ticks", "seconds", "day_phase", "cycle_tick"], [], path, errors
	)
	_require_non_negative_int(object.get("ticks"), path + ".ticks", errors)
	_require_non_negative_int(object.get("seconds"), path + ".seconds", errors)
	if not _is_enum(object.get("day_phase"), DAY_PHASES):
		errors.append(path + ".day_phase is invalid")
	_require_int_range(object.get("cycle_tick"), 0, 4_799, path + ".cycle_tick", errors)


static func _validate_decision(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(
		object,
		["mode", "observation_tick", "commands_apply_tick", "response_deadline_ms", "valid_until_tick"],
		["opportunity_skipped"], path, errors
	)
	if not _is_enum(object.get("mode"), MODES):
		errors.append(path + ".mode is invalid")
	_require_non_negative_int(object.get("observation_tick"), path + ".observation_tick", errors)
	if object.get("commands_apply_tick") != null:
		_require_int_range(
			object.get("commands_apply_tick"), 1, Codec.MAX_SAFE_INTEGER,
			path + ".commands_apply_tick", errors
		)
	_require_int_range(object.get("response_deadline_ms"), 1, 45_000, path + ".response_deadline_ms", errors)
	_require_int_range(
		object.get("valid_until_tick"), 1, Codec.MAX_SAFE_INTEGER,
		path + ".valid_until_tick", errors
	)
	if object.has("opportunity_skipped") and typeof(object["opportunity_skipped"]) != TYPE_BOOL:
		errors.append(path + ".opportunity_skipped must be boolean")


static func _validate_objective(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(
		object, ["kind", "enemy_structure_role", "own_structure_role"], [], path, errors
	)
	if str(object.get("kind", "")) != "destroy_enemy_stronghold" \
		or str(object.get("enemy_structure_role", "")) != "stronghold" \
		or str(object.get("own_structure_role", "")) != "stronghold":
		errors.append(path + " does not encode the locked victory objective")


static func _validate_match_state(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(object, ["status", "no_progress_ticks"], ["terminal"], path, errors)
	if not _is_enum(object.get("status"), ["active", "terminal"]):
		errors.append(path + ".status is invalid")
	_require_non_negative_int(object.get("no_progress_ticks"), path + ".no_progress_ticks", errors)
	if str(object.get("status", "")) == "terminal" and not object.has("terminal"):
		errors.append(path + ".terminal is required for terminal state")
	if object.has("terminal"):
		if not _object(object["terminal"], path + ".terminal", errors):
			return
		var terminal: Dictionary = object["terminal"]
		_validate_exact_fields(terminal, ["result", "reason", "terminal_tick"], [], path + ".terminal", errors)
		if not _is_enum(terminal.get("result"), TERMINAL_RESULTS):
			errors.append(path + ".terminal.result is invalid")
		if not is_public_id(terminal.get("reason")):
			errors.append(path + ".terminal.reason is invalid")
		_require_non_negative_int(terminal.get("terminal_tick"), path + ".terminal.terminal_tick", errors)


static func _validate_economy(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(object, [
		"gold", "lumber", "gold_income_last_600_ticks", "lumber_income_last_600_ticks",
		"reserved_gold", "reserved_lumber", "worker_summary", "cargo_summary",
	], [], path, errors)
	for field: String in [
		"gold", "lumber", "gold_income_last_600_ticks", "lumber_income_last_600_ticks",
		"reserved_gold", "reserved_lumber",
	]:
		_require_non_negative_int(object.get(field), path + "." + field, errors)
	if _object(object.get("worker_summary"), path + ".worker_summary", errors):
		var workers: Dictionary = object["worker_summary"]
		_validate_exact_fields(
			workers, ["total", "gold", "lumber", "building", "repairing", "idle"], [],
			path + ".worker_summary", errors
		)
		for field: String in ["total", "gold", "lumber", "building", "repairing", "idle"]:
			_require_non_negative_int(workers.get(field), path + ".worker_summary." + field, errors)
	if _object(object.get("cargo_summary"), path + ".cargo_summary", errors):
		var cargo: Dictionary = object["cargo_summary"]
		_validate_exact_fields(cargo, ["gold", "lumber"], [], path + ".cargo_summary", errors)
		_require_non_negative_int(cargo.get("gold"), path + ".cargo_summary.gold", errors)
		_require_non_negative_int(cargo.get("lumber"), path + ".cargo_summary.lumber", errors)


static func _validate_food(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(object, ["used", "cap", "reserved", "maximum"], [], path, errors)
	for field: String in ["used", "cap", "reserved", "maximum"]:
		_require_int_range(object.get(field), 0, 100, path + "." + field, errors)
	if int(object.get("maximum", -1)) != 100:
		errors.append(path + ".maximum must be 100")


static func _validate_upkeep(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(object, ["tier", "gold_delivery_bp"], [], path, errors)
	if not _is_enum(object.get("tier"), UPKEEP_TIERS):
		errors.append(path + ".tier is invalid")
	if typeof(object.get("gold_delivery_bp")) != TYPE_INT \
		or not [10_000, 7_000, 4_000].has(int(object["gold_delivery_bp"])):
		errors.append(path + ".gold_delivery_bp is invalid")


static func _validate_technology(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var object: Dictionary = value
	_validate_exact_fields(
		object, ["tier", "completed_upgrades", "researching", "hero_slots"], [], path, errors
	)
	_require_int_range(object.get("tier"), 1, 3, path + ".tier", errors)
	_validate_sorted_unique_public_ids(object.get("completed_upgrades"), path + ".completed_upgrades", errors)
	if typeof(object.get("researching")) != TYPE_ARRAY:
		errors.append(path + ".researching must be an array")
	else:
		var rows: Array = object["researching"]
		if rows.size() > 32:
			errors.append(path + ".researching exceeds 32 entries")
		_validate_sorted_dictionary_array(rows, "producer_id", path + ".researching", errors)
		for index: int in rows.size():
			var row_path := "%s[%d]" % [path + ".researching", index]
			if not _object(rows[index], row_path, errors):
				continue
			var row: Dictionary = rows[index]
			_validate_exact_fields(row, ["producer_id", "entry"], [], row_path, errors)
			if not is_entity_id(row.get("producer_id")):
				errors.append(row_path + ".producer_id is invalid")
			_validate_queue_entry(row.get("entry"), row_path + ".entry", errors)
	if _object(object.get("hero_slots"), path + ".hero_slots", errors):
		var slots: Dictionary = object["hero_slots"]
		_validate_exact_fields(slots, ["available", "used"], [], path + ".hero_slots", errors)
		_require_int_range(slots.get("available"), 1, 3, path + ".hero_slots.available", errors)
		_require_int_range(slots.get("used"), 0, 3, path + ".hero_slots.used", errors)


static func _validate_owned_array(
	value: Variant, path: String, maximum: int, kind: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var records: Array = value
	if records.size() > maximum:
		errors.append("%s exceeds %d entries" % [path, maximum])
	_validate_sorted_dictionary_array(records, "entity_id", path, errors)
	for index: int in records.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(records[index], item_path, errors):
			continue
		_validate_owned_record(records[index], item_path, kind, errors)


static func _validate_owned_record(
	record: Dictionary, path: String, kind: String, errors: PackedStringArray
) -> void:
	var required: Array = [
		"entity_id", "type_id", "tags", "position_mt", "region_id", "elevation",
		"facing_mdeg", "hp", "max_hp", "shields", "mana", "max_mana", "armor_centi",
		"armor_class", "movement_state", "cargo", "current_order", "queued_orders", "stance",
		"formation", "attack_cooldown_remaining_ticks", "abilities", "statuses", "squad_ids",
	]
	var optional: Array = [
		"tactical_slot_id", "detection_radius_mt", "cargo_capacity_food", "passenger_ids",
	]
	if kind == "hero":
		required.append_array([
			"hero_type_id", "level", "xp", "next_level_xp", "unspent_skill_points",
			"attributes_centi", "inventory", "life_state", "death_tick", "revival",
		])
	elif kind == "structure":
		required.append_array([
			"structure_role", "complete", "construction_progress_bp", "builders",
			"production_queue", "rally_target", "disabled", "pause_reason",
		])
	_validate_exact_fields(record, required, optional, path, errors)
	if not is_entity_id(record.get("entity_id")):
		errors.append(path + ".entity_id is invalid")
	if not is_public_id(record.get("type_id")):
		errors.append(path + ".type_id is invalid")
	_validate_sorted_unique_public_ids(record.get("tags"), path + ".tags", errors)
	_validate_point(record.get("position_mt"), path + ".position_mt", errors)
	if not is_public_id(record.get("region_id")):
		errors.append(path + ".region_id is invalid")
	_require_int(record.get("elevation"), path + ".elevation", errors)
	_require_int_range(record.get("facing_mdeg"), 0, 359_999, path + ".facing_mdeg", errors)
	_require_non_negative_int(record.get("hp"), path + ".hp", errors)
	_require_int_range(record.get("max_hp"), 1, Codec.MAX_SAFE_INTEGER, path + ".max_hp", errors)
	for field: String in ["shields", "mana", "max_mana", "attack_cooldown_remaining_ticks"]:
		_require_non_negative_int(record.get(field), path + "." + field, errors)
	_require_int(record.get("armor_centi"), path + ".armor_centi", errors)
	if not _is_enum(record.get("armor_class"), ARMOR_CLASSES):
		errors.append(path + ".armor_class is invalid")
	if not _is_enum(record.get("movement_state"), MOVEMENT_STATES):
		errors.append(path + ".movement_state is invalid")
	_validate_cargo(record.get("cargo"), path + ".cargo", errors)
	_validate_order_or_null(record.get("current_order"), path + ".current_order", errors)
	_validate_orders(record.get("queued_orders"), path + ".queued_orders", errors)
	if not _is_enum(record.get("stance"), STANCES):
		errors.append(path + ".stance is invalid")
	if not _is_enum(record.get("formation"), FORMATIONS):
		errors.append(path + ".formation is invalid")
	_validate_abilities(record.get("abilities"), path + ".abilities", errors)
	_validate_statuses(record.get("statuses"), path + ".statuses", errors)
	_validate_sorted_unique_ids(record.get("squad_ids"), path + ".squad_ids", errors)
	if record.has("passenger_ids"):
		_validate_sorted_unique_entity_ids(record["passenger_ids"], path + ".passenger_ids", errors)
	if kind == "hero":
		if not is_public_id(record.get("hero_type_id")):
			errors.append(path + ".hero_type_id is invalid")
		_require_int_range(record.get("level"), 1, 10, path + ".level", errors)
		_require_non_negative_int(record.get("xp"), path + ".xp", errors)
		if record.get("next_level_xp") != null:
			_require_non_negative_int(record.get("next_level_xp"), path + ".next_level_xp", errors)
		_require_int_range(record.get("unspent_skill_points"), 0, 10, path + ".unspent_skill_points", errors)
		_validate_attributes(record.get("attributes_centi"), path + ".attributes_centi", errors)
		_validate_inventory(record.get("inventory"), path + ".inventory", errors)
		if not _is_enum(record.get("life_state"), ["alive", "dead", "reviving"]):
			errors.append(path + ".life_state is invalid")
		if record.get("death_tick") != null:
			_require_non_negative_int(record.get("death_tick"), path + ".death_tick", errors)
		_validate_revival(record.get("revival"), path + ".revival", errors)
	elif kind == "structure":
		if not is_public_id(record.get("structure_role")):
			errors.append(path + ".structure_role is invalid")
		if typeof(record.get("complete")) != TYPE_BOOL:
			errors.append(path + ".complete must be boolean")
		_require_int_range(
			record.get("construction_progress_bp"), 0, 10_000,
			path + ".construction_progress_bp", errors
		)
		_validate_sorted_unique_entity_ids(record.get("builders"), path + ".builders", errors, 5)
		_validate_queue(record.get("production_queue"), path + ".production_queue", errors, 5)
		_validate_rally_target(record.get("rally_target"), path + ".rally_target", errors)
		if typeof(record.get("disabled")) != TYPE_BOOL:
			errors.append(path + ".disabled must be boolean")
		if record.get("pause_reason") != null and typeof(record.get("pause_reason")) != TYPE_STRING:
			errors.append(path + ".pause_reason must be string or null")


static func _validate_visible_contacts(
	value: Variant, path: String, maximum: int, owner: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var records: Array = value
	if records.size() > maximum:
		errors.append("%s exceeds %d entries" % [path, maximum])
	_validate_sorted_dictionary_array(records, "entity_id", path, errors)
	for index: int in records.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(records[index], item_path, errors):
			continue
		var record: Dictionary = records[index]
		_validate_exact_fields(record, [
			"entity_id", "owner_category", "type_id", "tags", "position_mt", "region_id",
			"hp", "max_hp", "visible_mana", "hero_level", "visible_statuses",
			"observable_activity", "first_seen_tick", "last_seen_tick",
		], [], item_path, errors)
		if not is_entity_id(record.get("entity_id")):
			errors.append(item_path + ".entity_id is invalid")
		if str(record.get("owner_category", "")) != owner:
			errors.append(item_path + ".owner_category is invalid for this collection")
		if not is_public_id(record.get("type_id")):
			errors.append(item_path + ".type_id is invalid")
		_validate_sorted_unique_public_ids(record.get("tags"), item_path + ".tags", errors)
		_validate_point(record.get("position_mt"), item_path + ".position_mt", errors)
		if not is_public_id(record.get("region_id")):
			errors.append(item_path + ".region_id is invalid")
		_require_non_negative_int(record.get("hp"), item_path + ".hp", errors)
		_require_int_range(record.get("max_hp"), 1, Codec.MAX_SAFE_INTEGER, item_path + ".max_hp", errors)
		if record.get("visible_mana") != null:
			_require_non_negative_int(record.get("visible_mana"), item_path + ".visible_mana", errors)
		if record.get("hero_level") != null:
			_require_int_range(record.get("hero_level"), 1, 10, item_path + ".hero_level", errors)
		_validate_statuses(record.get("visible_statuses"), item_path + ".visible_statuses", errors)
		if not _is_enum(record.get("observable_activity"), ACTIVITIES):
			errors.append(item_path + ".observable_activity is invalid")
		_require_non_negative_int(record.get("first_seen_tick"), item_path + ".first_seen_tick", errors)
		_require_non_negative_int(record.get("last_seen_tick"), item_path + ".last_seen_tick", errors)


static func _validate_remembered_contacts(
	value: Variant, path: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var records: Array = value
	if records.size() > 256:
		errors.append(path + " exceeds 256 entries")
	_validate_sorted_dictionary_array(records, "entity_id", path, errors)
	for index: int in records.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(records[index], item_path, errors):
			continue
		var record: Dictionary = records[index]
		_validate_exact_fields(record, [
			"entity_id", "type_id", "owner_category", "first_seen_tick", "last_seen_tick",
			"memory_age_ticks", "last_observed", "last_location_status",
		], [], item_path, errors)
		if not is_entity_id(record.get("entity_id")):
			errors.append(item_path + ".entity_id is invalid")
		if not is_public_id(record.get("type_id")):
			errors.append(item_path + ".type_id is invalid")
		if not _is_enum(record.get("owner_category"), ["opponent", "neutral"]):
			errors.append(item_path + ".owner_category is invalid")
		for field: String in ["first_seen_tick", "last_seen_tick", "memory_age_ticks"]:
			_require_non_negative_int(record.get(field), item_path + "." + field, errors)
		if not _is_enum(record.get("last_location_status"), ["unverified", "unlocated"]):
			errors.append(item_path + ".last_location_status is invalid")
		_validate_last_observed(record.get("last_observed"), item_path + ".last_observed", errors)


static func _validate_squads(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var records: Array = value
	if records.size() > 32:
		errors.append(path + " exceeds 32 entries")
	_validate_sorted_dictionary_array(records, "squad_id", path, errors)
	for index: int in records.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(records[index], item_path, errors):
			continue
		var record: Dictionary = records[index]
		_validate_exact_fields(
			record, ["squad_id", "member_ids", "formation", "stance", "current_order"],
			["retreat_hp_threshold_bp"], item_path, errors
		)
		if not is_id(record.get("squad_id")):
			errors.append(item_path + ".squad_id is invalid")
		_validate_sorted_unique_entity_ids(record.get("member_ids"), item_path + ".member_ids", errors, 24, 1)
		if not _is_enum(record.get("formation"), FORMATIONS):
			errors.append(item_path + ".formation is invalid")
		if not _is_enum(record.get("stance"), STANCES):
			errors.append(item_path + ".stance is invalid")
		_validate_order_or_null(record.get("current_order"), item_path + ".current_order", errors)
		if record.has("retreat_hp_threshold_bp"):
			_require_int_range(
				record["retreat_hp_threshold_bp"], 0, 10_000,
				item_path + ".retreat_hp_threshold_bp", errors
			)


static func _validate_visible_items(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var records: Array = value
	if records.size() > 64:
		errors.append(path + " exceeds 64 entries")
	_validate_sorted_dictionary_array(records, "item_entity_id", path, errors)
	for index: int in records.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(records[index], item_path, errors):
			continue
		var item: Dictionary = records[index]
		_validate_exact_fields(
			item, ["item_entity_id", "item_type_id", "position_mt", "region_id", "charges"],
			["despawn_tick"], item_path, errors
		)
		if not is_entity_id(item.get("item_entity_id")):
			errors.append(item_path + ".item_entity_id is invalid")
		if not is_public_id(item.get("item_type_id")):
			errors.append(item_path + ".item_type_id is invalid")
		_validate_point(item.get("position_mt"), item_path + ".position_mt", errors)
		if not is_public_id(item.get("region_id")):
			errors.append(item_path + ".region_id is invalid")
		_require_non_negative_int(item.get("charges"), item_path + ".charges", errors)
		if item.has("despawn_tick") and item["despawn_tick"] != null:
			_require_non_negative_int(item["despawn_tick"], item_path + ".despawn_tick", errors)


static func _validate_visible_shops(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var shops: Array = value
	if shops.size() > 16:
		errors.append(path + " exceeds 16 entries")
	_validate_sorted_dictionary_array(shops, "site_id", path, errors)
	for index: int in shops.size():
		var shop_path := "%s[%d]" % [path, index]
		if not _object(shops[index], shop_path, errors):
			continue
		var shop: Dictionary = shops[index]
		_validate_exact_fields(
			shop, ["shop_id", "site_id", "shop_type", "position_mt", "region_id", "offers"], [],
			shop_path, errors
		)
		if not is_entity_id(shop.get("shop_id")):
			errors.append(shop_path + ".shop_id is invalid")
		if not is_public_id(shop.get("site_id")):
			errors.append(shop_path + ".site_id is invalid")
		if not _is_enum(shop.get("shop_type"), ["merchant", "laboratory", "tavern", "faction_shop"]):
			errors.append(shop_path + ".shop_type is invalid")
		_validate_point(shop.get("position_mt"), shop_path + ".position_mt", errors)
		if not is_public_id(shop.get("region_id")):
			errors.append(shop_path + ".region_id is invalid")
		_validate_offers(shop.get("offers"), shop_path + ".offers", errors)


static func _validate_map_state(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var map_state: Dictionary = value
	_validate_exact_fields(
		map_state, ["explored_region_ids", "visible_region_ids", "terrain_changes", "local_context"],
		[], path, errors
	)
	_validate_sorted_unique_public_ids(map_state.get("explored_region_ids"), path + ".explored_region_ids", errors)
	_validate_sorted_unique_public_ids(map_state.get("visible_region_ids"), path + ".visible_region_ids", errors)
	if typeof(map_state.get("terrain_changes")) != TYPE_ARRAY:
		errors.append(path + ".terrain_changes must be an array")
	else:
		var changes: Array = map_state["terrain_changes"]
		_validate_sorted_dictionary_array(changes, "change_id", path + ".terrain_changes", errors)
		for index: int in changes.size():
			var change_path := "%s.terrain_changes[%d]" % [path, index]
			if not _object(changes[index], change_path, errors):
				continue
			var change: Dictionary = changes[index]
			_validate_exact_fields(change, ["change_id", "kind", "position_mt", "observed_tick"], [], change_path, errors)
			if not is_id(change.get("change_id")):
				errors.append(change_path + ".change_id is invalid")
			if not _is_enum(change.get("kind"), ["tree_depleted", "destructible_destroyed", "path_opened", "path_blocked"]):
				errors.append(change_path + ".kind is invalid")
			_validate_point(change.get("position_mt"), change_path + ".position_mt", errors)
			_require_non_negative_int(change.get("observed_tick"), change_path + ".observed_tick", errors)
	_validate_local_context(map_state.get("local_context"), path + ".local_context", errors)


static func _validate_local_context(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var contexts: Array = value
	_validate_sorted_dictionary_array(contexts, "anchor_id", path, errors)
	for index: int in contexts.size():
		var context_path := "%s[%d]" % [path, index]
		if not _object(contexts[index], context_path, errors):
			continue
		var context: Dictionary = contexts[index]
		_validate_exact_fields(context, [
			"anchor_id", "position_mt", "region_id", "tactical_slot", "terrain", "elevation",
			"exits", "visible_contacts", "remembered_threats", "nearby_features",
			"visibility_radius_mt", "detection_radius_mt", "retreat_route",
		], [], context_path, errors)
		if not is_id(context.get("anchor_id")):
			errors.append(context_path + ".anchor_id is invalid")
		_validate_point(context.get("position_mt"), context_path + ".position_mt", errors)
		if not is_public_id(context.get("region_id")):
			errors.append(context_path + ".region_id is invalid")
		if context.get("tactical_slot") != null and typeof(context.get("tactical_slot")) != TYPE_STRING:
			errors.append(context_path + ".tactical_slot must be string or null")
		if not is_public_id(context.get("terrain")):
			errors.append(context_path + ".terrain is invalid")
		_require_int(context.get("elevation"), context_path + ".elevation", errors)
		_validate_exits(context.get("exits"), context_path + ".exits", errors)
		_validate_context_contacts(context.get("visible_contacts"), context_path + ".visible_contacts", errors)
		_validate_remembered_threats(context.get("remembered_threats"), context_path + ".remembered_threats", errors)
		_validate_nearby_features(context.get("nearby_features"), context_path + ".nearby_features", errors)
		_require_non_negative_int(context.get("visibility_radius_mt"), context_path + ".visibility_radius_mt", errors)
		_require_non_negative_int(context.get("detection_radius_mt"), context_path + ".detection_radius_mt", errors)
		_validate_public_id_array(context.get("retreat_route"), context_path + ".retreat_route", errors)


static func _validate_events(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var events: Array = value
	if events.size() > 2_048:
		errors.append(path + " exceeds 2048 entries")
	var previous_seq := 0
	for index: int in events.size():
		var event_path := "%s[%d]" % [path, index]
		if not _object(events[index], event_path, errors):
			continue
		var event: Dictionary = events[index]
		_validate_exact_fields(event, ["event_seq", "tick", "kind", "audience", "payload"], [], event_path, errors)
		_require_int_range(event.get("event_seq"), 1, Codec.MAX_SAFE_INTEGER, event_path + ".event_seq", errors)
		if typeof(event.get("event_seq")) == TYPE_INT:
			var sequence := int(event["event_seq"])
			if sequence <= previous_seq:
				errors.append(event_path + ".event_seq is not strictly ascending")
			previous_seq = sequence
		_require_non_negative_int(event.get("tick"), event_path + ".tick", errors)
		if not is_public_id(event.get("kind")):
			errors.append(event_path + ".kind is invalid")
		if str(event.get("audience", "")) != "self":
			errors.append(event_path + ".audience must be self at the provider boundary")
		if typeof(event.get("payload")) != TYPE_DICTIONARY:
			errors.append(event_path + ".payload must be an object")


static func _validate_receipt(value: Variant, path: String, errors: PackedStringArray) -> void:
	if value == null:
		return
	if not _object(value, path, errors):
		return
	var receipt: Dictionary = value
	_validate_exact_fields(
		receipt, ["batch_id", "observation_seq", "received_tick", "apply_tick", "batch_status", "commands"],
		["code"], path, errors
	)
	if not is_id(receipt.get("batch_id")):
		errors.append(path + ".batch_id is invalid")
	for field: String in ["observation_seq", "received_tick"]:
		_require_non_negative_int(receipt.get(field), path + "." + field, errors)
	if receipt.get("apply_tick") != null:
		_require_int_range(receipt.get("apply_tick"), 1, Codec.MAX_SAFE_INTEGER, path + ".apply_tick", errors)
	if not _is_enum(receipt.get("batch_status"), BATCH_STATUSES):
		errors.append(path + ".batch_status is invalid")
	if receipt.has("code") and receipt["code"] != null and typeof(receipt["code"]) != TYPE_STRING:
		errors.append(path + ".code must be string or null")
	if typeof(receipt.get("commands")) != TYPE_ARRAY:
		errors.append(path + ".commands must be an array")
		return
	var commands: Array = receipt["commands"]
	if commands.size() > 16:
		errors.append(path + ".commands exceeds 16 entries")
	for index: int in commands.size():
		var command_path := "%s.commands[%d]" % [path, index]
		if not _object(commands[index], command_path, errors):
			continue
		var command: Dictionary = commands[index]
		_validate_exact_fields(command, ["command_id", "status", "code"], [
			"requested_quantity", "accepted_quantity", "atomic_cost", "compiled_order_ids",
		], command_path, errors)
		if not _matches(command.get("command_id"), "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"):
			errors.append(command_path + ".command_id is invalid")
		if not _is_enum(command.get("status"), COMMAND_STATUSES):
			errors.append(command_path + ".status is invalid")
		if command.get("code") != null and typeof(command.get("code")) != TYPE_STRING:
			errors.append(command_path + ".code must be string or null")
		if command.has("compiled_order_ids"):
			_validate_sorted_unique_ids(command["compiled_order_ids"], command_path + ".compiled_order_ids", errors)


static func _validate_limits(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var limits: Dictionary = value
	_validate_exact_fields(limits, [
		"max_command_objects", "max_atomic_order_cost", "max_actor_ids_per_command",
		"max_queue_entries_per_entity", "max_working_memory_bytes",
	], [], path, errors)
	var expected := {
		"max_command_objects": MAX_COMMAND_OBJECTS,
		"max_atomic_order_cost": MAX_ATOMIC_ORDER_COST,
		"max_actor_ids_per_command": MAX_ACTOR_IDS,
		"max_queue_entries_per_entity": MAX_QUEUE_ENTRIES,
		"max_working_memory_bytes": MAX_WORKING_MEMORY_BYTES,
	}
	for field: String in expected:
		if limits.get(field) != expected[field]:
			errors.append("%s.%s differs from the locked limit" % [path, field])


static func _validate_omitted_counts(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var counts: Dictionary = value
	_validate_exact_fields(
		counts, ["brief", "remembered_units", "remembered_buildings", "local_context_paths"],
		[], path, errors
	)
	for field: String in counts:
		_require_non_negative_int(counts[field], path + "." + field, errors)


static func _validate_brief(value: Variant, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append("$.brief must be an array")
		return
	var lines: Array = value
	if lines.size() > 64:
		errors.append("$.brief exceeds 64 lines")
	for index: int in lines.size():
		if typeof(lines[index]) != TYPE_STRING or str(lines[index]).length() > 240:
			errors.append("$.brief[%d] must be a string of at most 240 codepoints" % index)


static func _validate_queue(value: Variant, path: String, errors: PackedStringArray, maximum: int) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var entries: Array = value
	if entries.size() > maximum:
		errors.append("%s exceeds %d entries" % [path, maximum])
	for index: int in entries.size():
		_validate_queue_entry(entries[index], "%s[%d]" % [path, index], errors)


static func _validate_queue_entry(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var entry: Dictionary = value
	_validate_exact_fields(entry, [
		"queue_entry_id", "kind", "type_id", "progress_bp", "remaining_ticks", "paused",
		"reserved_gold", "reserved_lumber", "reserved_food",
	], ["pause_reason"], path, errors)
	if not is_id(entry.get("queue_entry_id")):
		errors.append(path + ".queue_entry_id is invalid")
	if not _is_enum(entry.get("kind"), ["unit", "hero", "research", "tier", "revival"]):
		errors.append(path + ".kind is invalid")
	if not is_public_id(entry.get("type_id")):
		errors.append(path + ".type_id is invalid")
	_require_int_range(entry.get("progress_bp"), 0, 10_000, path + ".progress_bp", errors)
	for field: String in ["remaining_ticks", "reserved_gold", "reserved_lumber", "reserved_food"]:
		_require_non_negative_int(entry.get(field), path + "." + field, errors)
	if typeof(entry.get("paused")) != TYPE_BOOL:
		errors.append(path + ".paused must be boolean")
	if entry.has("pause_reason") and entry["pause_reason"] != null \
		and typeof(entry["pause_reason"]) != TYPE_STRING:
		errors.append(path + ".pause_reason must be string or null")


static func _validate_orders(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var orders: Array = value
	if orders.size() > MAX_QUEUE_ENTRIES:
		errors.append(path + " exceeds 8 entries")
	for index: int in orders.size():
		_validate_order_or_null(orders[index], "%s[%d]" % [path, index], errors, false)


static func _validate_order_or_null(
	value: Variant, path: String, errors: PackedStringArray, allow_null: bool = true
) -> void:
	if value == null and allow_null:
		return
	if not _object(value, path, errors):
		return
	var order: Dictionary = value
	_validate_exact_fields(order, ["compiled_order_id", "op", "state", "issued_tick"], [
		"batch_id", "command_id", "target_entity_id", "target_position_mt", "target_region_id",
		"target_site_id", "route_region_ids",
	], path, errors)
	if not is_id(order.get("compiled_order_id")):
		errors.append(path + ".compiled_order_id is invalid")
	if not is_public_id(order.get("op")):
		errors.append(path + ".op is invalid")
	if not _is_enum(order.get("state"), ["queued", "active", "paused", "completed", "failed"]):
		errors.append(path + ".state is invalid")
	_require_non_negative_int(order.get("issued_tick"), path + ".issued_tick", errors)
	if order.has("target_entity_id") and not is_entity_id(order["target_entity_id"]):
		errors.append(path + ".target_entity_id is invalid")
	if order.has("target_position_mt"):
		_validate_point(order["target_position_mt"], path + ".target_position_mt", errors)
	for field: String in ["target_region_id", "target_site_id"]:
		if order.has(field) and not is_public_id(order[field]):
			errors.append(path + "." + field + " is invalid")
	if order.has("route_region_ids"):
		_validate_public_id_array(order["route_region_ids"], path + ".route_region_ids", errors, 64)


static func _validate_cargo(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var cargo: Dictionary = value
	_validate_exact_fields(cargo, ["resource", "amount"], [], path, errors)
	if not _is_enum(cargo.get("resource"), ["none", "gold", "lumber"]):
		errors.append(path + ".resource is invalid")
	_require_non_negative_int(cargo.get("amount"), path + ".amount", errors)


static func _validate_abilities(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var abilities: Array = value
	_validate_sorted_dictionary_array(abilities, "ability_id", path, errors)
	for index: int in abilities.size():
		var ability_path := "%s[%d]" % [path, index]
		if not _object(abilities[index], ability_path, errors):
			continue
		var ability: Dictionary = abilities[index]
		_validate_exact_fields(
			ability, ["ability_id", "rank", "cooldown_remaining_ticks", "autocast_enabled"], [],
			ability_path, errors
		)
		if not is_public_id(ability.get("ability_id")):
			errors.append(ability_path + ".ability_id is invalid")
		_require_int_range(ability.get("rank"), 0, 3, ability_path + ".rank", errors)
		_require_non_negative_int(ability.get("cooldown_remaining_ticks"), ability_path + ".cooldown_remaining_ticks", errors)
		if typeof(ability.get("autocast_enabled")) != TYPE_BOOL:
			errors.append(ability_path + ".autocast_enabled must be boolean")


static func _validate_statuses(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var statuses: Array = value
	_validate_sorted_dictionary_array(statuses, "status_id", path, errors)
	for index: int in statuses.size():
		var status_path := "%s[%d]" % [path, index]
		if not _object(statuses[index], status_path, errors):
			continue
		var status: Dictionary = statuses[index]
		_validate_exact_fields(status, [
			"status_id", "source_entity_id", "start_tick", "expiry_tick", "stacking_key", "stacks",
			"dispel_class",
		], ["magnitude"], status_path, errors)
		if not is_public_id(status.get("status_id")):
			errors.append(status_path + ".status_id is invalid")
		if not is_entity_id(status.get("source_entity_id")):
			errors.append(status_path + ".source_entity_id is invalid")
		_require_non_negative_int(status.get("start_tick"), status_path + ".start_tick", errors)
		if status.get("expiry_tick") != null:
			_require_non_negative_int(status.get("expiry_tick"), status_path + ".expiry_tick", errors)
		if not is_public_id(status.get("stacking_key")):
			errors.append(status_path + ".stacking_key is invalid")
		_require_int_range(status.get("stacks"), 1, Codec.MAX_SAFE_INTEGER, status_path + ".stacks", errors)
		if not _is_enum(status.get("dispel_class"), ["none", "ordinary_magical", "ultimate"]):
			errors.append(status_path + ".dispel_class is invalid")


static func _validate_attributes(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var attributes: Dictionary = value
	_validate_exact_fields(attributes, ["strength", "agility", "intellect"], [], path, errors)
	for field: String in ["strength", "agility", "intellect"]:
		_require_non_negative_int(attributes.get(field), path + "." + field, errors)


static func _validate_inventory(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var inventory: Array = value
	if inventory.size() > 6:
		errors.append(path + " exceeds 6 entries")
	_validate_sorted_dictionary_array(inventory, "slot", path, errors, true)
	for index: int in inventory.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(inventory[index], item_path, errors):
			continue
		var item: Dictionary = inventory[index]
		_validate_exact_fields(
			item, ["item_instance_id", "item_type_id", "slot", "charges", "cooldown_remaining_ticks"],
			[], item_path, errors
		)
		if not is_id(item.get("item_instance_id")):
			errors.append(item_path + ".item_instance_id is invalid")
		if not is_public_id(item.get("item_type_id")):
			errors.append(item_path + ".item_type_id is invalid")
		_require_int_range(item.get("slot"), 0, 5, item_path + ".slot", errors)
		_require_non_negative_int(item.get("charges"), item_path + ".charges", errors)
		_require_non_negative_int(item.get("cooldown_remaining_ticks"), item_path + ".cooldown_remaining_ticks", errors)


static func _validate_revival(value: Variant, path: String, errors: PackedStringArray) -> void:
	if value == null:
		return
	if not _object(value, path, errors):
		return
	var revival: Dictionary = value
	_validate_exact_fields(revival, ["method", "progress_bp", "remaining_ticks", "reviver_id"], [], path, errors)
	if not _is_enum(revival.get("method"), ["altar", "tavern"]):
		errors.append(path + ".method is invalid")
	_require_int_range(revival.get("progress_bp"), 0, 10_000, path + ".progress_bp", errors)
	_require_non_negative_int(revival.get("remaining_ticks"), path + ".remaining_ticks", errors)
	if not is_entity_id(revival.get("reviver_id")):
		errors.append(path + ".reviver_id is invalid")


static func _validate_rally_target(value: Variant, path: String, errors: PackedStringArray) -> void:
	if value == null:
		return
	if is_entity_id(value):
		return
	_validate_point(value, path, errors)


static func _validate_last_observed(value: Variant, path: String, errors: PackedStringArray) -> void:
	if not _object(value, path, errors):
		return
	var observed: Dictionary = value
	_validate_exact_fields(observed, ["position_mt", "region_id", "hp", "max_hp", "observable_activity"], [
		"visible_mana", "hero_level", "visible_status_ids",
	], path, errors)
	_validate_point(observed.get("position_mt"), path + ".position_mt", errors)
	if not is_public_id(observed.get("region_id")):
		errors.append(path + ".region_id is invalid")
	_require_non_negative_int(observed.get("hp"), path + ".hp", errors)
	_require_int_range(observed.get("max_hp"), 1, Codec.MAX_SAFE_INTEGER, path + ".max_hp", errors)
	if observed.has("visible_status_ids"):
		_validate_sorted_unique_public_ids(observed["visible_status_ids"], path + ".visible_status_ids", errors)
	if not is_public_id(observed.get("observable_activity")):
		errors.append(path + ".observable_activity is invalid")


static func _validate_offers(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var offers: Array = value
	_validate_sorted_dictionary_array(offers, "offer_id", path, errors)
	for index: int in offers.size():
		var offer_path := "%s[%d]" % [path, index]
		if not _object(offers[index], offer_path, errors):
			continue
		var offer: Dictionary = offers[index]
		_validate_exact_fields(offer, [
			"offer_id", "kind", "cost_gold", "cost_lumber", "stock", "next_restock_tick", "available",
		], ["requires_service_target"], offer_path, errors)
		if not is_public_id(offer.get("offer_id")):
			errors.append(offer_path + ".offer_id is invalid")
		if not _is_enum(offer.get("kind"), ["item", "unit", "service", "revival"]):
			errors.append(offer_path + ".kind is invalid")
		for field: String in ["cost_gold", "cost_lumber"]:
			_require_non_negative_int(offer.get(field), offer_path + "." + field, errors)
		if offer.get("stock") != null:
			_require_non_negative_int(offer.get("stock"), offer_path + ".stock", errors)
		if offer.get("next_restock_tick") != null:
			_require_non_negative_int(offer.get("next_restock_tick"), offer_path + ".next_restock_tick", errors)
		if typeof(offer.get("available")) != TYPE_BOOL:
			errors.append(offer_path + ".available must be boolean")


static func _validate_exits(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var exits: Array = value
	_validate_sorted_dictionary_array(exits, "to_region_id", path, errors)
	for index: int in exits.size():
		var exit_path := "%s[%d]" % [path, index]
		if not _object(exits[index], exit_path, errors):
			continue
		var exit: Dictionary = exits[index]
		_validate_exact_fields(exit, ["to_region_id", "bearing", "path_distance_mt", "choke_width_mt", "known_blockage"], [], exit_path, errors)
		if not is_public_id(exit.get("to_region_id")):
			errors.append(exit_path + ".to_region_id is invalid")
		if not _is_enum(exit.get("bearing"), BEARINGS):
			errors.append(exit_path + ".bearing is invalid")
		_require_non_negative_int(exit.get("path_distance_mt"), exit_path + ".path_distance_mt", errors)
		_require_non_negative_int(exit.get("choke_width_mt"), exit_path + ".choke_width_mt", errors)
		if not _is_enum(exit.get("known_blockage"), ["clear", "blocked", "unknown"]):
			errors.append(exit_path + ".known_blockage is invalid")


static func _validate_context_contacts(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var contacts: Array = value
	_validate_sorted_dictionary_array(contacts, "entity_id", path, errors)
	for index: int in contacts.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(contacts[index], item_path, errors):
			continue
		var contact: Dictionary = contacts[index]
		_validate_exact_fields(contact, ["entity_id", "bearing", "distance_mt", "known_path_distance_mt", "line_of_sight"], [], item_path, errors)
		if not is_entity_id(contact.get("entity_id")):
			errors.append(item_path + ".entity_id is invalid")
		if not _is_enum(contact.get("bearing"), BEARINGS):
			errors.append(item_path + ".bearing is invalid")
		_require_non_negative_int(contact.get("distance_mt"), item_path + ".distance_mt", errors)
		if contact.get("known_path_distance_mt") != null:
			_require_non_negative_int(contact.get("known_path_distance_mt"), item_path + ".known_path_distance_mt", errors)
		if typeof(contact.get("line_of_sight")) != TYPE_BOOL:
			errors.append(item_path + ".line_of_sight must be boolean")


static func _validate_remembered_threats(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var threats: Array = value
	_validate_sorted_dictionary_array(threats, "entity_id", path, errors)
	for index: int in threats.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(threats[index], item_path, errors):
			continue
		var threat: Dictionary = threats[index]
		_validate_exact_fields(threat, ["entity_id", "age_ticks", "bearing", "distance_mt"], [], item_path, errors)
		if not is_entity_id(threat.get("entity_id")):
			errors.append(item_path + ".entity_id is invalid")
		_require_non_negative_int(threat.get("age_ticks"), item_path + ".age_ticks", errors)
		if not _is_enum(threat.get("bearing"), BEARINGS):
			errors.append(item_path + ".bearing is invalid")
		_require_non_negative_int(threat.get("distance_mt"), item_path + ".distance_mt", errors)


static func _validate_nearby_features(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var features: Array = value
	_validate_sorted_dictionary_array(features, "site_id", path, errors)
	for index: int in features.size():
		var item_path := "%s[%d]" % [path, index]
		if not _object(features[index], item_path, errors):
			continue
		var feature: Dictionary = features[index]
		_validate_exact_fields(feature, ["site_id", "kind", "bearing", "path_distance_mt"], ["state"], item_path, errors)
		if not is_public_id(feature.get("site_id")):
			errors.append(item_path + ".site_id is invalid")
		if not _is_enum(feature.get("kind"), [
			"owned_structure", "resource", "creep_camp", "neutral_merchant",
			"neutral_laboratory", "tavern", "build_site", "item", "hazard",
		]):
			errors.append(item_path + ".kind is invalid")
		if not _is_enum(feature.get("bearing"), BEARINGS):
			errors.append(item_path + ".bearing is invalid")
		_require_non_negative_int(feature.get("path_distance_mt"), item_path + ".path_distance_mt", errors)


static func _validate_point(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2 \
		or typeof(value[0]) != TYPE_INT or typeof(value[1]) != TYPE_INT:
		errors.append(path + " must be an integer pair")


static func _validate_sorted_unique_public_ids(
	value: Variant, path: String, errors: PackedStringArray, require_sorted: bool = true
) -> void:
	_validate_string_array(value, path, errors, "public", true, require_sorted)


static func _validate_sorted_unique_entity_ids(
	value: Variant, path: String, errors: PackedStringArray, maximum: int = -1, minimum: int = 0
) -> void:
	_validate_string_array(value, path, errors, "entity", true, true, maximum, minimum)


static func _validate_sorted_unique_ids(
	value: Variant, path: String, errors: PackedStringArray
) -> void:
	_validate_string_array(value, path, errors, "id", true, true)


static func _validate_public_id_array(
	value: Variant, path: String, errors: PackedStringArray, maximum: int = -1
) -> void:
	_validate_string_array(value, path, errors, "public", false, false, maximum)


static func _validate_string_array(
	value: Variant,
	path: String,
	errors: PackedStringArray,
	kind: String,
	unique: bool,
	sorted: bool,
	maximum: int = -1,
	minimum: int = 0
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append(path + " must be an array")
		return
	var values: Array = value
	if values.size() < minimum or (maximum >= 0 and values.size() > maximum):
		errors.append(path + " has an invalid item count")
	var seen: Dictionary = {}
	var previous := ""
	for index: int in values.size():
		var entry: Variant = values[index]
		var valid := is_public_id(entry) if kind == "public" \
			else is_entity_id(entry) if kind == "entity" else is_id(entry)
		if not valid:
			errors.append("%s[%d] is invalid" % [path, index])
			continue
		var text := str(entry)
		if unique and seen.has(text):
			errors.append("%s contains duplicate %s" % [path, text])
		if sorted and index > 0 and text <= previous:
			errors.append(path + " is not strictly ascending")
		seen[text] = true
		previous = text


static func _validate_sorted_dictionary_array(
	values: Array, key: String, path: String, errors: PackedStringArray, numeric: bool = false
) -> void:
	var previous_text := ""
	var previous_number := -Codec.MAX_SAFE_INTEGER
	var seen: Dictionary = {}
	for index: int in values.size():
		if typeof(values[index]) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = values[index]
		if not row.has(key):
			errors.append("%s[%d].%s is required" % [path, index, key])
			continue
		var identity := str(row[key])
		if seen.has(identity):
			errors.append("%s contains duplicate %s" % [path, identity])
		seen[identity] = true
		if numeric:
			if typeof(row[key]) != TYPE_INT:
				errors.append("%s[%d].%s must be integer" % [path, index, key])
			elif index > 0 and int(row[key]) <= previous_number:
				errors.append(path + " is not strictly ascending")
			previous_number = int(row.get(key, previous_number))
		elif index > 0 and identity <= previous_text:
			errors.append(path + " is not strictly ascending")
		previous_text = identity


static func _validate_exact_fields(
	value: Dictionary,
	required_fields: Array,
	optional_fields: Array,
	path: String,
	errors: PackedStringArray
) -> void:
	var allowed: Dictionary = {}
	for field_variant: Variant in required_fields:
		var field := str(field_variant)
		allowed[field] = true
		if not value.has(field):
			errors.append("%s.%s is required" % [path, field])
	for field_variant: Variant in optional_fields:
		allowed[str(field_variant)] = true
	for key_variant: Variant in value.keys():
		if typeof(key_variant) != TYPE_STRING or not allowed.has(str(key_variant)):
			errors.append("%s.%s is not allowed" % [path, str(key_variant)])


static func _object(value: Variant, path: String, errors: PackedStringArray) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append(path + " must be an object")
		return false
	return true


static func _require_int(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_INT:
		errors.append(path + " must be an integer")


static func _require_non_negative_int(value: Variant, path: String, errors: PackedStringArray) -> void:
	_require_int_range(value, 0, Codec.MAX_SAFE_INTEGER, path, errors)


static func _require_int_range(
	value: Variant, minimum: int, maximum: int, path: String, errors: PackedStringArray
) -> void:
	if typeof(value) != TYPE_INT or int(value) < minimum or int(value) > maximum:
		errors.append("%s must be an integer in [%d,%d]" % [path, minimum, maximum])


static func _is_enum(value: Variant, allowed: Array) -> bool:
	return typeof(value) == TYPE_STRING and allowed.has(str(value))


static func _matches(value: Variant, pattern: String) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return false
	var result := regex.search(str(value))
	return result != null and result.get_string() == str(value)
