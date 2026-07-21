class_name DuelCatalogLoader
extends RefCounted

## Strict, read-only boundary for the checked-in WorldArena Duel catalogs.
##
## Godot's JSON boundary can represent JSON numbers as floats.  Catalog data is
## authoritative, so every number is normalized to an interoperable integer
## before it is validated or hashed.  Only the explicit paths below may be
## opened; callers cannot supply filesystem paths.

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const PROTOCOL_VERSION := "worldeval-rts/1.0.0"
const RULESET_ID := "duel-rules-v1"
const CONTROL_PROFILE := "hybrid-v1"
const MAX_SAFE_JSON_INTEGER := 9_007_199_254_740_991
## IEEE-754 cannot distinguish float(2^53 - 1) from 2^53.  Float boundary
## values therefore use the greatest unambiguously safe representable integer;
## an integer Variant can still carry the full inclusive protocol limit.
const MAX_UNAMBIGUOUS_FLOAT_INTEGER := 9_007_199_254_740_990.0

const GOLDEN_HASHES_PATH := "res://../game/duel_protocol/conformance/golden-hashes.json"
const PROTOCOL_LOCK_PATH := "res://../game/duel_protocol/protocol-lock.json"
const VERSION_PATH := "res://../game/duel_protocol/VERSION"

const CATALOG_KEYS: Array[String] = [
	"actions",
	"attack_armor",
	"items",
	"neutrals",
	"rules",
	"faction:crypt-v1",
	"faction:grove-v1",
	"faction:vanguard-v1",
	"faction:warhost-v1",
]

const FACTION_IDS: Array[String] = [
	"crypt-v1",
	"grove-v1",
	"vanguard-v1",
	"warhost-v1",
]

const CATALOG_PATHS := {
	"actions": "res://../game/duel_protocol/catalogs/actions.hybrid-v1.json",
	"attack_armor": "res://../game/duel_protocol/catalogs/attack-armor.duel-v1.json",
	"items": "res://../game/duel_protocol/catalogs/items.duel-v1.json",
	"neutrals": "res://../game/duel_protocol/catalogs/neutrals.duel-v1.json",
	"rules": "res://../game/duel_protocol/catalogs/rules.duel-v1.json",
	"faction:crypt-v1": "res://../game/duel_protocol/catalogs/factions/crypt-v1.json",
	"faction:grove-v1": "res://../game/duel_protocol/catalogs/factions/grove-v1.json",
	"faction:vanguard-v1": "res://../game/duel_protocol/catalogs/factions/vanguard-v1.json",
	"faction:warhost-v1": "res://../game/duel_protocol/catalogs/factions/warhost-v1.json",
}

const ARTIFACT_RELATIVE_PATHS := {
	"actions": "catalogs/actions.hybrid-v1.json",
	"attack_armor": "catalogs/attack-armor.duel-v1.json",
	"items": "catalogs/items.duel-v1.json",
	"neutrals": "catalogs/neutrals.duel-v1.json",
	"rules": "catalogs/rules.duel-v1.json",
	"faction:crypt-v1": "catalogs/factions/crypt-v1.json",
	"faction:grove-v1": "catalogs/factions/grove-v1.json",
	"faction:vanguard-v1": "catalogs/factions/vanguard-v1.json",
	"faction:warhost-v1": "catalogs/factions/warhost-v1.json",
}

const EXPECTED_TICK_PHASES: Array[String] = [
	"activate_accepted_orders",
	"expire_status_stock_and_cooldowns",
	"compile_deterministic_actor_intents",
	"compute_scheduled_paths",
	"resolve_movement_reservations",
	"start_windups",
	"resolve_impacts_and_work",
	"accumulate_typed_deltas",
	"apply_delta_ledger",
	"resolve_deaths_corpses_summons_destruction_and_drops",
	"resolve_xp_inventory_stock_and_revival",
	"update_fog_knowledge_and_observable_events",
	"test_terminal_conditions",
	"emit_events_and_optional_checkpoint",
]

const EXPECTED_ACTION_OPERATIONS: Array[String] = [
	"attack_entity",
	"attack_ground",
	"attack_move",
	"build",
	"cancel_construction",
	"cancel_queue",
	"cast",
	"define_squad",
	"disband_squad",
	"drop_item",
	"follow",
	"gather",
	"hold_position",
	"learn_ability",
	"load_transport",
	"move",
	"order_squad",
	"patrol",
	"pick_up_item",
	"produce",
	"purchase_offer",
	"repair",
	"research",
	"retreat",
	"return_cargo",
	"revive_hero",
	"sell_item",
	"set_autocast",
	"set_rally",
	"set_stance",
	"set_tactics",
	"stop",
	"transfer_item",
	"unload_transport",
	"update_squad",
	"upgrade_tier",
	"use_item",
]

const EXPECTED_STRUCTURE_ROLES: Array[String] = [
	"barracks",
	"expansion_hall",
	"faction_shop",
	"food",
	"forge",
	"hero_altar",
	"mystic_hall",
	"range",
	"stronghold",
	"tower",
	"workshop",
]

const CANONICAL_SET_FIELDS := {
	"abilities": true,
	"tags": true,
	"target_layers": true,
}


static func official_catalog_keys() -> Array[String]:
	var keys: Array[String] = []
	keys.assign(CATALOG_KEYS)
	return keys


static func official_faction_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(FACTION_IDS)
	return ids


static func normalize_json_boundary(value: Variant) -> Dictionary:
	var errors := PackedStringArray()
	var normalized: Variant = _normalize_json_value(value, "$", errors)
	return {
		"errors": errors,
		"ok": errors.is_empty(),
		"value": normalized,
	}


static func load_official_catalogs(validation_order: Array[String] = []) -> Dictionary:
	var errors := PackedStringArray()
	var catalogs: Dictionary = {}
	var raw_hashes: Dictionary = {}
	var raw_sizes: Dictionary = {}

	_validate_version_file(errors)
	for key: String in CATALOG_KEYS:
		var read_result := _read_authoritative_json(str(CATALOG_PATHS[key]), key)
		errors.append_array(read_result["errors"])
		if not bool(read_result["ok"]):
			continue
		catalogs[key] = read_result["value"]
		var relative_path := str(ARTIFACT_RELATIVE_PATHS[key])
		raw_hashes[relative_path] = str(read_result["raw_sha256"])
		raw_sizes[relative_path] = int(read_result["raw_size_bytes"])

	var ordered_keys := _validated_order_or_default(validation_order, errors)
	for key: String in ordered_keys:
		if catalogs.has(key):
			_validate_catalog_header(key, catalogs[key], errors)

	if catalogs.size() == CATALOG_KEYS.size():
		_validate_rules(catalogs["rules"], errors)
		_validate_actions(catalogs["actions"], errors)
		_validate_attack_armor(catalogs["attack_armor"], errors)
		_validate_factions(catalogs, errors)
		_validate_neutrals(catalogs["neutrals"], errors)
		_validate_item_and_neutral_references(
			catalogs["items"], catalogs["neutrals"], errors
		)
		_validate_all_attack_and_armor_references(catalogs, errors)
		for key: String in CATALOG_KEYS:
			_validate_canonical_sets_recursive(catalogs[key], "$catalogs.%s" % key, errors)

	var verified_manifests: Array[String] = []
	for manifest_path: String in [GOLDEN_HASHES_PATH, PROTOCOL_LOCK_PATH]:
		if FileAccess.file_exists(manifest_path):
			_verify_hash_manifest(manifest_path, raw_hashes, raw_sizes, errors)
			verified_manifests.append(manifest_path)

	var canonical_hashes: Dictionary = {}
	for key: String in CATALOG_KEYS:
		if not catalogs.has(key):
			continue
		var canonical_errors := Codec.validate_canonical_value(catalogs[key])
		if not canonical_errors.is_empty():
			for message: String in canonical_errors:
				errors.append("%s: %s" % [key, message])
			continue
		canonical_hashes[key] = Codec.sha256_canonical(catalogs[key])

	var aggregate_hash := ""
	if canonical_hashes.size() == CATALOG_KEYS.size():
		aggregate_hash = Codec.sha256_canonical({
			"catalog_hashes": canonical_hashes,
			"protocol_version": PROTOCOL_VERSION,
			"ruleset_id": RULESET_ID,
		})

	return {
		"aggregate_hash": aggregate_hash,
		"canonical_hashes": canonical_hashes,
		"catalogs": catalogs,
		"errors": errors,
		"ok": errors.is_empty(),
		"raw_hashes": raw_hashes,
		"verified_hash_manifests": verified_manifests,
	}


static func selected_faction_public_bundle(
	faction_id: String,
	loaded_result: Dictionary = {}
) -> Dictionary:
	var result := loaded_result
	if result.is_empty():
		result = load_official_catalogs()
	var errors := PackedStringArray()
	if not bool(result.get("ok", false)):
		var source_errors: Variant = result.get("errors", PackedStringArray(["catalog load failed"]))
		if typeof(source_errors) == TYPE_PACKED_STRING_ARRAY:
			errors.append_array(source_errors)
		elif typeof(source_errors) == TYPE_ARRAY:
			for error_variant: Variant in source_errors:
				errors.append(str(error_variant))
		else:
			errors.append(str(source_errors))
	if not FACTION_IDS.has(faction_id):
		errors.append("unknown official faction_id: %s" % faction_id)
	if not errors.is_empty():
		return {"bundle": {}, "errors": errors, "ok": false}

	var catalogs: Dictionary = result["catalogs"]
	var hashes: Dictionary = result["canonical_hashes"]
	var faction_key := "faction:%s" % faction_id
	var public_catalogs := {
		"actions": catalogs["actions"],
		"attack_armor": catalogs["attack_armor"],
		"faction": catalogs[faction_key],
		"items": catalogs["items"],
		"neutrals": catalogs["neutrals"],
		"rules": catalogs["rules"],
	}
	var public_hashes := {
		"actions": hashes["actions"],
		"attack_armor": hashes["attack_armor"],
		"faction": hashes[faction_key],
		"items": hashes["items"],
		"neutrals": hashes["neutrals"],
		"rules": hashes["rules"],
	}
	var body := {
		"catalog_hashes": public_hashes,
		"catalogs": public_catalogs,
		"control_profile": CONTROL_PROFILE,
		"faction_id": faction_id,
		"protocol_version": PROTOCOL_VERSION,
		"ruleset_id": RULESET_ID,
	}
	var bundle := body.duplicate(true)
	bundle["bundle_hash"] = Codec.sha256_canonical(body)
	return {"bundle": bundle, "errors": errors, "ok": true}


static func _read_authoritative_json(path: String, label: String) -> Dictionary:
	var errors := PackedStringArray()
	if not FileAccess.file_exists(path):
		errors.append("%s: required catalog file is missing" % label)
		return {"errors": errors, "ok": false}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("%s: required catalog file could not be opened" % label)
		return {"errors": errors, "ok": false}
	var bytes := file.get_buffer(file.get_length())
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		errors.append("%s: catalog bytes are not valid UTF-8" % label)
		return {"errors": errors, "ok": false}
	var parser := JSON.new()
	var parse_error := parser.parse(text)
	if parse_error != OK:
		errors.append("%s: invalid JSON at line %d: %s" % [
			label, parser.get_error_line(), parser.get_error_message(),
		])
		return {"errors": errors, "ok": false}
	var normalized_result := normalize_json_boundary(parser.data)
	for message: String in normalized_result["errors"]:
		errors.append("%s: %s" % [label, message])
	if not errors.is_empty():
		return {"errors": errors, "ok": false}
	if typeof(normalized_result["value"]) != TYPE_DICTIONARY:
		errors.append("%s: catalog root must be an object" % label)
		return {"errors": errors, "ok": false}
	return {
		"errors": errors,
		"ok": true,
		"raw_sha256": Codec.sha256_bytes(bytes),
		"raw_size_bytes": bytes.size(),
		"value": normalized_result["value"],
	}


static func _normalize_json_value(
	value: Variant,
	path: String,
	errors: PackedStringArray
) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return value
		TYPE_INT:
			var integer_value := int(value)
			if integer_value < -MAX_SAFE_JSON_INTEGER \
				or integer_value > MAX_SAFE_JSON_INTEGER:
				errors.append("%s: integer is outside the interoperable JSON range" % path)
			return integer_value
		TYPE_FLOAT:
			var number := float(value)
			if not is_finite(number):
				errors.append("%s: JSON number must be finite" % path)
				return null
			if number < -MAX_UNAMBIGUOUS_FLOAT_INTEGER \
				or number > MAX_UNAMBIGUOUS_FLOAT_INTEGER:
				errors.append("%s: JSON number is outside the interoperable integer range" % path)
				return null
			if number != floor(number):
				errors.append("%s: authoritative JSON number must be mathematically integral" % path)
				return null
			return int(number)
		TYPE_ARRAY:
			var normalized_array: Array = []
			var array_value: Array = value
			for index: int in array_value.size():
				normalized_array.append(_normalize_json_value(
					array_value[index], "%s[%d]" % [path, index], errors
				))
			return normalized_array
		TYPE_DICTIONARY:
			var normalized_dictionary: Dictionary = {}
			var dictionary_value: Dictionary = value
			var keys: Array = dictionary_value.keys()
			keys.sort()
			for key_variant: Variant in keys:
				if typeof(key_variant) != TYPE_STRING:
					errors.append("%s: JSON object keys must be strings" % path)
					continue
				var key := str(key_variant)
				normalized_dictionary[key] = _normalize_json_value(
					dictionary_value[key_variant], "%s.%s" % [path, key], errors
				)
			return normalized_dictionary
		_:
			errors.append("%s: unsupported authoritative Variant type %d" % [
				path, typeof(value),
			])
			return null


static func _validated_order_or_default(
	requested: Array[String],
	errors: PackedStringArray
) -> Array[String]:
	if requested.is_empty():
		return official_catalog_keys()
	var seen: Dictionary = {}
	for key: String in requested:
		if not CATALOG_KEYS.has(key):
			errors.append("validation order contains unknown catalog key: %s" % key)
		elif seen.has(key):
			errors.append("validation order contains duplicate catalog key: %s" % key)
		seen[key] = true
	if requested.size() != CATALOG_KEYS.size():
		errors.append("validation order must contain every official catalog exactly once")
	for key: String in CATALOG_KEYS:
		if not seen.has(key):
			errors.append("validation order is missing catalog key: %s" % key)
	if not errors.is_empty():
		return official_catalog_keys()
	var result: Array[String] = []
	result.assign(requested)
	return result


static func _validate_version_file(errors: PackedStringArray) -> void:
	if not FileAccess.file_exists(VERSION_PATH):
		errors.append("VERSION: required protocol version file is missing")
		return
	var file := FileAccess.open(VERSION_PATH, FileAccess.READ)
	if file == null:
		errors.append("VERSION: protocol version file could not be opened")
		return
	if file.get_as_text().strip_edges() != PROTOCOL_VERSION:
		errors.append("VERSION: unsupported protocol version")


static func _validate_catalog_header(
	key: String,
	catalog_variant: Variant,
	errors: PackedStringArray
) -> void:
	if typeof(catalog_variant) != TYPE_DICTIONARY:
		errors.append("%s: catalog root must be an object" % key)
		return
	var catalog: Dictionary = catalog_variant
	if catalog.get("protocol_version", null) != PROTOCOL_VERSION:
		errors.append("%s: missing or unknown protocol_version" % key)
	var expected_catalog_id := ""
	match key:
		"actions":
			expected_catalog_id = "actions.hybrid-v1"
			if catalog.get("control_profile", null) != CONTROL_PROFILE:
				errors.append("actions: missing or unknown control_profile")
		"attack_armor":
			expected_catalog_id = "attack-armor.duel-v1"
		"items":
			expected_catalog_id = "items.duel-v1"
		"neutrals":
			expected_catalog_id = "neutrals.duel-v1"
		"rules":
			expected_catalog_id = "rules.duel-v1"
		_:
			if key.begins_with("faction:"):
				var faction_id := key.trim_prefix("faction:")
				expected_catalog_id = "faction.%s" % faction_id
				if catalog.get("faction_id", null) != faction_id:
					errors.append("%s: missing or unknown faction_id" % key)
			else:
				errors.append("unknown catalog key: %s" % key)
	if catalog.get("catalog_id", null) != expected_catalog_id:
		errors.append("%s: missing or unknown catalog_id" % key)
	if key != "actions" and catalog.get("ruleset_id", null) != RULESET_ID:
		errors.append("%s: missing or unknown ruleset_id" % key)


static func _validate_rules(rules: Dictionary, errors: PackedStringArray) -> void:
	var phases_variant: Variant = rules.get("tick_phases", null)
	if typeof(phases_variant) != TYPE_ARRAY:
		errors.append("rules.tick_phases must be an array")
		return
	var phases: Array = phases_variant
	if phases.size() != EXPECTED_TICK_PHASES.size():
		errors.append("rules.tick_phases must contain exactly 14 phases")
		return
	for index: int in EXPECTED_TICK_PHASES.size():
		if typeof(phases[index]) != TYPE_STRING \
			or str(phases[index]) != EXPECTED_TICK_PHASES[index]:
			errors.append("rules.tick_phases[%d] must equal %s" % [
				index, EXPECTED_TICK_PHASES[index],
			])


static func _validate_actions(actions: Dictionary, errors: PackedStringArray) -> void:
	var operations_variant: Variant = actions.get("operations", null)
	if typeof(operations_variant) != TYPE_DICTIONARY:
		errors.append("actions.operations must be an object")
		return
	var operations: Dictionary = operations_variant
	var operation_ids := _sorted_string_keys(operations, "actions.operations", errors)
	if operation_ids.size() != 37:
		errors.append("actions.operations must contain exactly 37 operations")
	if operation_ids != EXPECTED_ACTION_OPERATIONS:
		errors.append("actions.operations does not match the frozen operation set")


static func _validate_attack_armor(catalog: Dictionary, errors: PackedStringArray) -> void:
	var attack_types := _required_sorted_unique_string_array(
		catalog.get("attack_types", null), "attack_armor.attack_types", errors
	)
	var armor_classes := _required_sorted_unique_string_array(
		catalog.get("armor_classes", null), "attack_armor.armor_classes", errors
	)
	var matrix_variant: Variant = catalog.get("matrix_bp", null)
	if typeof(matrix_variant) != TYPE_DICTIONARY:
		errors.append("attack_armor.matrix_bp must be an object")
		return
	var matrix: Dictionary = matrix_variant
	var expected_matrix_types: Array[String] = []
	for attack_type: String in attack_types:
		if attack_type != "spell":
			expected_matrix_types.append(attack_type)
	var matrix_types := _sorted_string_keys(matrix, "attack_armor.matrix_bp", errors)
	if matrix_types != expected_matrix_types:
		errors.append("attack_armor.matrix_bp rows do not match matrix-using attack types")
	for attack_type: String in matrix_types:
		if typeof(matrix[attack_type]) != TYPE_DICTIONARY:
			errors.append("attack_armor.matrix_bp.%s must be an object" % attack_type)
			continue
		var row: Dictionary = matrix[attack_type]
		var row_classes := _sorted_string_keys(
			row, "attack_armor.matrix_bp.%s" % attack_type, errors
		)
		if row_classes != armor_classes:
			errors.append("attack_armor.matrix_bp.%s has incomplete armor coverage" % attack_type)
		for armor_class: String in row_classes:
			if typeof(row[armor_class]) != TYPE_INT or int(row[armor_class]) < 0:
				errors.append("attack_armor.matrix_bp.%s.%s must be a non-negative integer" % [
					attack_type, armor_class,
				])
	if not attack_types.has("spell"):
		errors.append("attack_armor.attack_types must include spell")
	var spell_damage: Variant = catalog.get("spell_damage", null)
	if typeof(spell_damage) != TYPE_DICTIONARY \
		or (spell_damage as Dictionary).get("uses_matrix", null) != false:
		errors.append("attack_armor.spell_damage must explicitly bypass the matrix")


static func _validate_factions(catalogs: Dictionary, errors: PackedStringArray) -> void:
	for faction_id: String in FACTION_IDS:
		var key := "faction:%s" % faction_id
		var faction: Dictionary = catalogs[key]
		_validate_faction(faction_id, faction, errors)


static func _validate_faction(
	faction_id: String,
	faction: Dictionary,
	errors: PackedStringArray
) -> void:
	var path := "faction:%s" % faction_id
	var structures_variant: Variant = faction.get("structures", null)
	var units_variant: Variant = faction.get("units", null)
	var heroes_variant: Variant = faction.get("heroes", null)
	var abilities_variant: Variant = faction.get("abilities", null)
	if typeof(structures_variant) != TYPE_DICTIONARY:
		errors.append("%s.structures must be an object" % path)
		return
	if typeof(units_variant) != TYPE_DICTIONARY:
		errors.append("%s.units must be an object" % path)
		return
	if typeof(heroes_variant) != TYPE_DICTIONARY:
		errors.append("%s.heroes must be an object" % path)
		return
	if typeof(abilities_variant) != TYPE_DICTIONARY:
		errors.append("%s.abilities must be an object" % path)
		return
	var structures: Dictionary = structures_variant
	var units: Dictionary = units_variant
	var heroes: Dictionary = heroes_variant
	var abilities: Dictionary = abilities_variant
	var roles := _sorted_string_keys(structures, "%s.structures" % path, errors)
	if roles != EXPECTED_STRUCTURE_ROLES:
		errors.append("%s must define exactly the 11 shared structure roles" % path)
	if units.size() != 9:
		errors.append("%s.units must define exactly 9 regular units" % path)
	if heroes.size() != 3:
		errors.append("%s.heroes must define exactly 3 heroes" % path)

	var owner_ids: Dictionary = {}
	for unit_id: String in _sorted_string_keys(units, "%s.units" % path, errors):
		owner_ids[unit_id] = true
	for hero_id: String in _sorted_string_keys(heroes, "%s.heroes" % path, errors):
		owner_ids[hero_id] = true
	for role: String in roles:
		if typeof(structures[role]) != TYPE_DICTIONARY:
			errors.append("%s.structures.%s must be an object" % [path, role])
			continue
		var structure: Dictionary = structures[role]
		if structure.get("shared_role", null) != role:
			errors.append("%s.structures.%s.shared_role must equal its role key" % [path, role])
		var structure_type: Variant = structure.get("type_id", null)
		if typeof(structure_type) != TYPE_STRING or str(structure_type).is_empty():
			errors.append("%s.structures.%s.type_id must be a non-empty string" % [path, role])
		elif owner_ids.has(str(structure_type)):
			errors.append("%s entity type_id is duplicated: %s" % [path, structure_type])
		else:
			owner_ids[str(structure_type)] = true

	var summons: Dictionary = {}
	var summons_variant: Variant = faction.get("summoned_entities", {})
	if typeof(summons_variant) == TYPE_DICTIONARY:
		summons = summons_variant
		for summon_id: String in _sorted_string_keys(summons, "%s.summoned_entities" % path, errors):
			owner_ids[summon_id] = true
	else:
		errors.append("%s.summoned_entities must be an object when present" % path)

	var starting_state_variant: Variant = faction.get("starting_state", null)
	if typeof(starting_state_variant) != TYPE_DICTIONARY:
		errors.append("%s.starting_state must be an object" % path)
	else:
		var starting_state: Dictionary = starting_state_variant
		var worker_id: Variant = starting_state.get("worker_type_id", null)
		if typeof(worker_id) != TYPE_STRING or not units.has(str(worker_id)):
			errors.append("%s starting worker_type_id does not resolve to a regular unit" % path)
		else:
			var worker_variant: Variant = units[str(worker_id)]
			if typeof(worker_variant) != TYPE_DICTIONARY \
				or not _string_array_has((worker_variant as Dictionary).get("tags", null), "worker"):
				errors.append("%s starting worker is not tagged worker" % path)
		var special_units_variant: Variant = starting_state.get("special_units", null)
		if typeof(special_units_variant) != TYPE_ARRAY:
			errors.append("%s.starting_state.special_units must be an array" % path)
		else:
			var special_units: Array = special_units_variant
			for index: int in special_units.size():
				var special_variant: Variant = special_units[index]
				if typeof(special_variant) != TYPE_DICTIONARY \
					or not units.has(str((special_variant as Dictionary).get("type_id", ""))):
					errors.append("%s.starting_state.special_units[%d] does not resolve" % [
						path, index,
					])

	_validate_entity_ability_lists(structures, abilities, "%s.structures" % path, errors)
	_validate_entity_ability_lists(units, abilities, "%s.units" % path, errors)
	_validate_entity_ability_lists(heroes, abilities, "%s.heroes" % path, errors)
	_validate_entity_ability_lists(summons, abilities, "%s.summoned_entities" % path, errors)
	_validate_ability_owners(abilities, owner_ids, "%s.abilities" % path, errors)
	_validate_structure_producers(structures, units, heroes, path, errors)
	_validate_unit_producer_roles(units, structures, path, errors)
	_validate_speed_records(units, "%s.units" % path, true, errors)
	_validate_speed_records(heroes, "%s.heroes" % path, true, errors)
	_validate_speed_records(summons, "%s.summoned_entities" % path, false, errors)


static func _validate_neutrals(neutrals: Dictionary, errors: PackedStringArray) -> void:
	var units_variant: Variant = neutrals.get("units", null)
	var abilities_variant: Variant = neutrals.get("abilities", null)
	if typeof(units_variant) != TYPE_DICTIONARY or typeof(abilities_variant) != TYPE_DICTIONARY:
		errors.append("neutrals.units and neutrals.abilities must be objects")
		return
	var units: Dictionary = units_variant
	var abilities: Dictionary = abilities_variant
	var owners: Dictionary = {}
	owners["neutral"] = true
	for unit_id: String in _sorted_string_keys(units, "neutrals.units", errors):
		owners[unit_id] = true
	_validate_entity_ability_lists(units, abilities, "neutrals.units", errors)
	_validate_ability_owners(abilities, owners, "neutrals.abilities", errors)
	_validate_speed_records(units, "neutrals.units", true, errors)
	var hires_variant: Variant = neutrals.get("laboratory_hires", null)
	if typeof(hires_variant) != TYPE_DICTIONARY:
		errors.append("neutrals.laboratory_hires must be an object")
	else:
		_validate_speed_records(hires_variant, "neutrals.laboratory_hires", true, errors)


static func _validate_item_and_neutral_references(
	items: Dictionary,
	neutrals: Dictionary,
	errors: PackedStringArray
) -> void:
	var item_defs_variant: Variant = items.get("items", null)
	if typeof(item_defs_variant) != TYPE_DICTIONARY:
		errors.append("items.items must be an object")
	else:
		var item_defs: Dictionary = item_defs_variant
		for stock_field: String in ["faction_shop_stock", "merchant_stock"]:
			var stock_variant: Variant = items.get(stock_field, null)
			if typeof(stock_variant) != TYPE_ARRAY:
				errors.append("items.%s must be an array" % stock_field)
				continue
			var stock: Array = stock_variant
			for index: int in stock.size():
				var offer_variant: Variant = stock[index]
				if typeof(offer_variant) != TYPE_DICTIONARY \
					or not item_defs.has(str((offer_variant as Dictionary).get("offer_id", ""))):
					errors.append("items.%s[%d].offer_id does not resolve" % [stock_field, index])

	var hires_variant: Variant = neutrals.get("laboratory_hires", null)
	var offers_variant: Variant = neutrals.get("laboratory_offers", null)
	if typeof(hires_variant) != TYPE_DICTIONARY or typeof(offers_variant) != TYPE_ARRAY:
		return
	var hires: Dictionary = hires_variant
	var offers: Array = offers_variant
	for index: int in offers.size():
		var offer_variant: Variant = offers[index]
		if typeof(offer_variant) != TYPE_DICTIONARY:
			errors.append("neutrals.laboratory_offers[%d] must be an object" % index)
			continue
		var offer: Dictionary = offer_variant
		if offer.get("kind", null) == "unit" and not hires.has(str(offer.get("offer_id", ""))):
			errors.append("neutrals.laboratory_offers[%d].offer_id does not resolve" % index)


static func _validate_entity_ability_lists(
	entities: Dictionary,
	ability_definitions: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	for entity_id: String in _sorted_string_keys(entities, path, errors):
		var entity_variant: Variant = entities[entity_id]
		if typeof(entity_variant) != TYPE_DICTIONARY:
			errors.append("%s.%s must be an object" % [path, entity_id])
			continue
		var entity: Dictionary = entity_variant
		if not entity.has("abilities"):
			continue
		var ability_ids_variant: Variant = entity["abilities"]
		if typeof(ability_ids_variant) != TYPE_ARRAY:
			errors.append("%s.%s.abilities must be an array" % [path, entity_id])
			continue
		var ability_ids: Array = ability_ids_variant
		for index: int in ability_ids.size():
			if typeof(ability_ids[index]) != TYPE_STRING \
				or not ability_definitions.has(str(ability_ids[index])):
				errors.append("%s.%s.abilities[%d] does not resolve" % [
					path, entity_id, index,
				])


static func _validate_ability_owners(
	abilities: Dictionary,
	owner_ids: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	for ability_id: String in _sorted_string_keys(abilities, path, errors):
		var ability_variant: Variant = abilities[ability_id]
		if typeof(ability_variant) != TYPE_DICTIONARY:
			errors.append("%s.%s must be an object" % [path, ability_id])
			continue
		var ability: Dictionary = ability_variant
		var owners_variant: Variant = ability.get("allowed_owners", null)
		if typeof(owners_variant) != TYPE_ARRAY:
			errors.append("%s.%s.allowed_owners must be an array" % [path, ability_id])
			continue
		var owners: Array = owners_variant
		if owners.is_empty():
			errors.append("%s.%s.allowed_owners must not be empty" % [path, ability_id])
		for index: int in owners.size():
			if typeof(owners[index]) != TYPE_STRING or not owner_ids.has(str(owners[index])):
				errors.append("%s.%s.allowed_owners[%d] does not resolve" % [
					path, ability_id, index,
				])


static func _validate_structure_producers(
	structures: Dictionary,
	units: Dictionary,
	heroes: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	for role: String in _sorted_string_keys(structures, "%s.structures" % path, errors):
		var structure_variant: Variant = structures[role]
		if typeof(structure_variant) != TYPE_DICTIONARY:
			continue
		var producers_variant: Variant = (structure_variant as Dictionary).get(
			"producer_type_ids", null
		)
		if typeof(producers_variant) != TYPE_ARRAY:
			errors.append("%s.structures.%s.producer_type_ids must be an array" % [path, role])
			continue
		var producer_ids: Array = producers_variant
		for index: int in producer_ids.size():
			var producer_id := str(producer_ids[index])
			if typeof(producer_ids[index]) != TYPE_STRING \
				or (not units.has(producer_id) and not heroes.has(producer_id)):
				errors.append("%s.structures.%s.producer_type_ids[%d] does not resolve" % [
					path, role, index,
				])


static func _validate_unit_producer_roles(
	units: Dictionary,
	structures: Dictionary,
	path: String,
	errors: PackedStringArray
) -> void:
	for unit_id: String in _sorted_string_keys(units, "%s.units" % path, errors):
		var unit_variant: Variant = units[unit_id]
		if typeof(unit_variant) != TYPE_DICTIONARY:
			continue
		var role: Variant = (unit_variant as Dictionary).get("producer_role", null)
		if typeof(role) != TYPE_STRING or not structures.has(str(role)):
			errors.append("%s.units.%s.producer_role does not resolve" % [path, unit_id])


static func _validate_speed_records(
	records_variant: Variant,
	path: String,
	require_speed: bool,
	errors: PackedStringArray
) -> void:
	if typeof(records_variant) != TYPE_DICTIONARY:
		return
	var records: Dictionary = records_variant
	for record_id: String in _sorted_string_keys(records, path, errors):
		var record_variant: Variant = records[record_id]
		if typeof(record_variant) != TYPE_DICTIONARY:
			continue
		var record: Dictionary = record_variant
		var has_second := record.has("speed_mt_per_second")
		var has_tick := record.has("speed_mt_per_tick")
		if require_speed and (not has_second or not has_tick):
			errors.append("%s.%s must define second and tick movement speeds" % [path, record_id])
			continue
		if not has_second and not has_tick:
			continue
		if not has_second or not has_tick \
			or typeof(record["speed_mt_per_second"]) != TYPE_INT \
			or typeof(record["speed_mt_per_tick"]) != TYPE_INT:
			errors.append("%s.%s movement speeds must be integer pairs" % [path, record_id])
			continue
		if int(record["speed_mt_per_second"]) != int(record["speed_mt_per_tick"]) * 10:
			errors.append("%s.%s speed_per_second must equal speed_per_tick * 10" % [
				path, record_id,
			])


static func _validate_all_attack_and_armor_references(
	catalogs: Dictionary,
	errors: PackedStringArray
) -> void:
	var attack_armor: Dictionary = catalogs["attack_armor"]
	var attack_types := _required_sorted_unique_string_array(
		attack_armor.get("attack_types", null), "attack_armor.attack_types", errors
	)
	var armor_classes := _required_sorted_unique_string_array(
		attack_armor.get("armor_classes", null), "attack_armor.armor_classes", errors
	)
	for key: String in CATALOG_KEYS:
		_validate_reference_fields_recursive(
			catalogs[key], "$catalogs.%s" % key, attack_types, armor_classes, errors
		)


static func _validate_reference_fields_recursive(
	value: Variant,
	path: String,
	attack_types: Array[String],
	armor_classes: Array[String],
	errors: PackedStringArray
) -> void:
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary: Dictionary = value
		if dictionary.has("attack_type"):
			var attack_type: Variant = dictionary["attack_type"]
			if typeof(attack_type) != TYPE_STRING or not attack_types.has(str(attack_type)):
				errors.append("%s.attack_type does not resolve" % path)
		if dictionary.has("armor_class"):
			var armor_class: Variant = dictionary["armor_class"]
			if typeof(armor_class) != TYPE_STRING or not armor_classes.has(str(armor_class)):
				errors.append("%s.armor_class does not resolve" % path)
		var keys: Array = dictionary.keys()
		keys.sort()
		for key_variant: Variant in keys:
			_validate_reference_fields_recursive(
				dictionary[key_variant], "%s.%s" % [path, str(key_variant)],
				attack_types, armor_classes, errors
			)
	elif typeof(value) == TYPE_ARRAY:
		var array: Array = value
		for index: int in array.size():
			_validate_reference_fields_recursive(
				array[index], "%s[%d]" % [path, index], attack_types, armor_classes, errors
			)


static func _validate_canonical_sets_recursive(
	value: Variant,
	path: String,
	errors: PackedStringArray
) -> void:
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary: Dictionary = value
		var keys: Array = dictionary.keys()
		keys.sort()
		for key_variant: Variant in keys:
			var key := str(key_variant)
			var child: Variant = dictionary[key_variant]
			if CANONICAL_SET_FIELDS.has(key) and typeof(child) == TYPE_ARRAY:
				_required_sorted_unique_string_array(child, "%s.%s" % [path, key], errors)
			_validate_canonical_sets_recursive(child, "%s.%s" % [path, key], errors)
	elif typeof(value) == TYPE_ARRAY:
		var array: Array = value
		for index: int in array.size():
			_validate_canonical_sets_recursive(array[index], "%s[%d]" % [path, index], errors)


static func _required_sorted_unique_string_array(
	value: Variant,
	path: String,
	errors: PackedStringArray
) -> Array[String]:
	var strings: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		errors.append("%s must be an array" % path)
		return strings
	var array: Array = value
	var seen: Dictionary = {}
	var is_canonical := true
	for index: int in array.size():
		if typeof(array[index]) != TYPE_STRING:
			errors.append("%s[%d] must be a string" % [path, index])
			continue
		var item := str(array[index])
		if seen.has(item):
			is_canonical = false
		seen[item] = true
		strings.append(item)
	var sorted: Array[String] = []
	sorted.assign(strings)
	sorted.sort()
	if strings != sorted:
		is_canonical = false
	if not is_canonical:
		errors.append("%s must be sorted and unique" % path)
	return strings


static func _sorted_string_keys(
	dictionary: Dictionary,
	path: String,
	errors: PackedStringArray
) -> Array[String]:
	var result: Array[String] = []
	for key_variant: Variant in dictionary.keys():
		if typeof(key_variant) != TYPE_STRING:
			errors.append("%s has a non-string key" % path)
			continue
		result.append(str(key_variant))
	result.sort()
	return result


static func _string_array_has(value: Variant, expected: String) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	var array: Array = value
	return array.has(expected)


static func _verify_hash_manifest(
	manifest_path: String,
	raw_hashes: Dictionary,
	raw_sizes: Dictionary,
	errors: PackedStringArray
) -> void:
	var manifest_result := _read_authoritative_json(manifest_path, manifest_path.get_file())
	if not bool(manifest_result["ok"]):
		errors.append_array(manifest_result["errors"])
		return
	var manifest: Dictionary = manifest_result["value"]
	if manifest.get("protocol_version", null) != PROTOCOL_VERSION:
		errors.append("%s: missing or unknown protocol_version" % manifest_path.get_file())
	var artifacts_variant: Variant = manifest.get("artifacts", null)
	if typeof(artifacts_variant) != TYPE_ARRAY:
		errors.append("%s: artifacts must be an array" % manifest_path.get_file())
		return
	var expected: Dictionary = {}
	var artifacts: Array = artifacts_variant
	for index: int in artifacts.size():
		var artifact_variant: Variant = artifacts[index]
		if typeof(artifact_variant) != TYPE_DICTIONARY:
			continue
		var artifact: Dictionary = artifact_variant
		if typeof(artifact.get("path", null)) == TYPE_STRING:
			expected[str(artifact["path"])] = artifact
	var relative_paths: Array = raw_hashes.keys()
	relative_paths.sort()
	for relative_variant: Variant in relative_paths:
		var relative_path := str(relative_variant)
		if not expected.has(relative_path):
			errors.append("%s: missing catalog digest for %s" % [
				manifest_path.get_file(), relative_path,
			])
			continue
		var entry: Dictionary = expected[relative_path]
		if entry.get("sha256", null) != raw_hashes[relative_path]:
			errors.append("%s: catalog SHA-256 mismatch for %s" % [
				manifest_path.get_file(), relative_path,
			])
		if entry.get("size_bytes", null) != raw_sizes[relative_path]:
			errors.append("%s: catalog byte size mismatch for %s" % [
				manifest_path.get_file(), relative_path,
			])
