class_name DuelRules
extends RefCounted

## Frozen constants shared by the render-free Duel simulation foundation.
## Numeric authoritative values are integers. Presentation code must convert them
## to display units without feeding the result back into simulation state.

const PROTOCOL_VERSION := "worldeval-rts/1.0.0"
const RULESET_ID := "duel-rules-v1"
const ENGINE_BUILD := "4.5.stable.official.876b29033"

const TICKS_PER_SECOND := 10
const TICK_DURATION_MS := 100
const CELL_SIZE_MT := 500
const OFFICIAL_GRID_WIDTH := 384
const OFFICIAL_GRID_HEIGHT := 256
const OFFICIAL_WORLD_WIDTH_MT := 192_000
const OFFICIAL_WORLD_HEIGHT_MT := 128_000

const CARDINAL_COST := 1_000
const DIAGONAL_COST := 1_414
const TERRAIN_COST_BASE := 1_000
const ORDINARY_REPLAN_TICKS := 20

enum TickPhase {
	ACTIVATE_ORDERS = 1,
	EXPIRE_TEMPORARY_STATE = 2,
	COMPILE_INTENTS = 3,
	COMPUTE_PATHS = 4,
	RESOLVE_MOVEMENT = 5,
	START_WINDUPS = 6,
	RESOLVE_IMPACTS = 7,
	ACCUMULATE_DELTAS = 8,
	APPLY_DELTAS = 9,
	RESOLVE_LIFECYCLE = 10,
	RESOLVE_HERO_AND_INVENTORY = 11,
	UPDATE_KNOWLEDGE = 12,
	TEST_TERMINAL = 13,
	EMIT_EVENTS_AND_CHECKPOINT = 14,
}

const TICK_PHASES: Array[Dictionary] = [
	{"id": TickPhase.ACTIVATE_ORDERS, "name": "activate_orders"},
	{"id": TickPhase.EXPIRE_TEMPORARY_STATE, "name": "expire_temporary_state"},
	{"id": TickPhase.COMPILE_INTENTS, "name": "compile_intents"},
	{"id": TickPhase.COMPUTE_PATHS, "name": "compute_paths"},
	{"id": TickPhase.RESOLVE_MOVEMENT, "name": "resolve_movement"},
	{"id": TickPhase.START_WINDUPS, "name": "start_windups"},
	{"id": TickPhase.RESOLVE_IMPACTS, "name": "resolve_impacts"},
	{"id": TickPhase.ACCUMULATE_DELTAS, "name": "accumulate_deltas"},
	{"id": TickPhase.APPLY_DELTAS, "name": "apply_deltas"},
	{"id": TickPhase.RESOLVE_LIFECYCLE, "name": "resolve_lifecycle"},
	{"id": TickPhase.RESOLVE_HERO_AND_INVENTORY, "name": "resolve_hero_and_inventory"},
	{"id": TickPhase.UPDATE_KNOWLEDGE, "name": "update_knowledge"},
	{"id": TickPhase.TEST_TERMINAL, "name": "test_terminal"},
	{"id": TickPhase.EMIT_EVENTS_AND_CHECKPOINT, "name": "emit_events_and_checkpoint"},
]

## Direction IDs are part of the ruleset. Never reorder this array.
const NEIGHBORS: Array[Dictionary] = [
	{"direction": 0, "dx": 0, "dy": -1, "base_cost": CARDINAL_COST, "diagonal": false},
	{"direction": 1, "dx": 1, "dy": -1, "base_cost": DIAGONAL_COST, "diagonal": true},
	{"direction": 2, "dx": 1, "dy": 0, "base_cost": CARDINAL_COST, "diagonal": false},
	{"direction": 3, "dx": 1, "dy": 1, "base_cost": DIAGONAL_COST, "diagonal": true},
	{"direction": 4, "dx": 0, "dy": 1, "base_cost": CARDINAL_COST, "diagonal": false},
	{"direction": 5, "dx": -1, "dy": 1, "base_cost": DIAGONAL_COST, "diagonal": true},
	{"direction": 6, "dx": -1, "dy": 0, "base_cost": CARDINAL_COST, "diagonal": false},
	{"direction": 7, "dx": -1, "dy": -1, "base_cost": DIAGONAL_COST, "diagonal": true},
]


static func default_config() -> Dictionary:
	return {
		"protocol_version": PROTOCOL_VERSION,
		"ruleset_id": RULESET_ID,
		"engine_build": ENGINE_BUILD,
		"match_seed": 0,
		"tick_hz": TICKS_PER_SECOND,
		"cell_size_mt": CELL_SIZE_MT,
		"grid_width": OFFICIAL_GRID_WIDTH,
		"grid_height": OFFICIAL_GRID_HEIGHT,
		"protocol_hash": "",
		"engine_build_hash": "",
		"ruleset_hash": "",
		"map_hash": "",
		"faction_hash": "",
		"item_hash": "",
		"neutral_hash": "",
		"helper_hash": "",
		"prompt_hash": "",
		"tie_key_commitment": "",
		"scored": false,
	}


static func merge_with_defaults(overrides: Dictionary) -> Dictionary:
	var merged: Dictionary = default_config()
	var keys: Array = overrides.keys()
	keys.sort()
	for key_variant: Variant in keys:
		merged[key_variant] = overrides[key_variant]
	return merged


static func validate_config(config: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	_validate_exact_string(config, "protocol_version", PROTOCOL_VERSION, errors)
	_validate_exact_string(config, "ruleset_id", RULESET_ID, errors)
	_validate_exact_string(config, "engine_build", ENGINE_BUILD, errors)
	_validate_exact_int(config, "tick_hz", TICKS_PER_SECOND, errors)
	_validate_exact_int(config, "cell_size_mt", CELL_SIZE_MT, errors)

	if not config.has("match_seed") or typeof(config["match_seed"]) != TYPE_INT:
		errors.append("match_seed must be an integer")
	elif int(config["match_seed"]) < 0:
		errors.append("match_seed must be non-negative")

	_validate_positive_dimension(config, "grid_width", errors)
	_validate_positive_dimension(config, "grid_height", errors)

	if not config.has("scored") or typeof(config["scored"]) != TYPE_BOOL:
		errors.append("scored must be a boolean")
	var scored := bool(config.get("scored", false))
	if scored and (
		int(config.get("grid_width", 0)) != OFFICIAL_GRID_WIDTH
		or int(config.get("grid_height", 0)) != OFFICIAL_GRID_HEIGHT
	):
		errors.append("scored matches must use the official 384 x 256 grid")
	for hash_key: String in [
		"protocol_hash", "engine_build_hash", "ruleset_hash", "map_hash", "faction_hash",
		"item_hash", "neutral_hash", "helper_hash", "prompt_hash", "tie_key_commitment",
	]:
		if not config.has(hash_key) or typeof(config[hash_key]) != TYPE_STRING:
			errors.append("%s must be a string" % hash_key)
		elif scored and not _is_lower_hex_hash(str(config[hash_key])):
			errors.append("%s must be a 64-character lowercase hex digest for scored matches" % hash_key)

	var allowed_keys: Array[String] = [
		"protocol_version", "ruleset_id", "engine_build", "match_seed", "tick_hz",
		"cell_size_mt", "grid_width", "grid_height", "protocol_hash", "engine_build_hash",
		"ruleset_hash", "map_hash", "faction_hash", "item_hash", "neutral_hash", "helper_hash",
		"prompt_hash", "tie_key_commitment", "scored", "map_manifest",
	]
	for key_variant: Variant in config.keys():
		if typeof(key_variant) != TYPE_STRING or not str(key_variant) in allowed_keys:
			errors.append("unknown config field: %s" % str(key_variant))
	return errors


static func phase_name(phase_id: int) -> String:
	for phase: Dictionary in TICK_PHASES:
		if int(phase["id"]) == phase_id:
			return str(phase["name"])
	return "unknown"


static func ordinary_replan_tick(internal_entity_id: int, current_tick: int) -> int:
	var offset := posmod(internal_entity_id, ORDINARY_REPLAN_TICKS)
	var cycle_start := current_tick - posmod(current_tick, ORDINARY_REPLAN_TICKS)
	var candidate := cycle_start + offset
	if candidate <= current_tick:
		candidate += ORDINARY_REPLAN_TICKS
	return candidate


static func _validate_exact_string(
	config: Dictionary,
	key: String,
	expected: String,
	errors: PackedStringArray
) -> void:
	if not config.has(key) or typeof(config[key]) != TYPE_STRING:
		errors.append("%s must be a string" % key)
	elif str(config[key]) != expected:
		errors.append("%s must equal %s" % [key, expected])


static func _validate_exact_int(
	config: Dictionary,
	key: String,
	expected: int,
	errors: PackedStringArray
) -> void:
	if not config.has(key) or typeof(config[key]) != TYPE_INT:
		errors.append("%s must be an integer" % key)
	elif int(config[key]) != expected:
		errors.append("%s must equal %d" % [key, expected])


static func _validate_positive_dimension(
	config: Dictionary,
	key: String,
	errors: PackedStringArray
) -> void:
	if not config.has(key) or typeof(config[key]) != TYPE_INT:
		errors.append("%s must be an integer" % key)
		return
	var value := int(config[key])
	var maximum := OFFICIAL_GRID_WIDTH if key == "grid_width" else OFFICIAL_GRID_HEIGHT
	if value <= 0 or value > maximum:
		errors.append("%s must be in [1, %d]" % [key, maximum])


static func _is_lower_hex_hash(value: String) -> bool:
	if value.length() != 64:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true
