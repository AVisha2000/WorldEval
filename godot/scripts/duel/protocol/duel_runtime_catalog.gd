class_name DuelRuntimeCatalog
extends RefCounted

const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const EconomySystem := preload("res://scripts/duel/economy/duel_economy.gd")

## Compiles the locked public protocol catalogs into the deliberately smaller
## data shape consumed by authoritative runtime systems. This is the only
## adapter between public type IDs (for example `mason` and `citadel`) and the
## semantic structure roles used by the economy/combat implementations.
## Runtime systems must not copy balance constants into GDScript.

const STRUCTURE_FOOTPRINT_KEYS := {
	"barracks": "barracks",
	"expansion_hall": "hall",
	"faction_shop": "shop",
	"food": "food",
	"forge": "forge",
	"hero_altar": "altar",
	"mystic_hall": "mystic",
	"range": "range",
	"stronghold": "stronghold",
	"tower": "tower",
	"workshop": "workshop",
}


static func compile_selected_faction(
	faction_id: String,
	loaded_result: Dictionary = {}
) -> Dictionary:
	var errors := PackedStringArray()
	var loaded := loaded_result
	if loaded.is_empty():
		loaded = CatalogLoader.load_official_catalogs()
	if not bool(loaded.get("ok", false)):
		_append_errors(errors, loaded.get("errors", ["official catalog load failed"]))
		return _result({}, errors)
	if faction_id not in CatalogLoader.FACTION_IDS:
		errors.append("unknown official faction_id: %s" % faction_id)
		return _result({}, errors)

	var catalogs: Dictionary = loaded["catalogs"]
	var faction_key := "faction:%s" % faction_id
	if not catalogs.has(faction_key):
		errors.append("selected faction catalog is missing: %s" % faction_id)
		return _result({}, errors)
	var rules: Dictionary = catalogs["rules"]
	var faction: Dictionary = catalogs[faction_key]
	var economy_result := _compile_economy(rules, faction)
	_append_errors(errors, economy_result["errors"])
	if not errors.is_empty():
		return _result({}, errors)

	var structure_role_by_type_id: Dictionary = {}
	var structure_type_by_role: Dictionary = {}
	for role_variant: Variant in _sorted_keys(faction["structures"]):
		var role := str(role_variant)
		var definition: Dictionary = faction["structures"][role]
		var type_id := str(definition["type_id"])
		structure_role_by_type_id[type_id] = role
		structure_type_by_role[role] = type_id

	var body := {
		"abilities": faction["abilities"].duplicate(true),
		"catalog_hashes": {
			"attack_armor": loaded["canonical_hashes"]["attack_armor"],
			"faction": loaded["canonical_hashes"][faction_key],
			"items": loaded["canonical_hashes"]["items"],
			"neutrals": loaded["canonical_hashes"]["neutrals"],
			"rules": loaded["canonical_hashes"]["rules"],
		},
		"economy": economy_result["catalog"],
		"faction_id": faction_id,
		"faction_rules": faction["faction_rules"].duplicate(true),
		"heroes": faction["heroes"].duplicate(true),
		"protocol_version": CatalogLoader.PROTOCOL_VERSION,
		"ruleset_id": CatalogLoader.RULESET_ID,
		"starting_state": faction["starting_state"].duplicate(true),
		"structure_role_by_type_id": structure_role_by_type_id,
		"structure_type_by_role": structure_type_by_role,
		"units": faction["units"].duplicate(true),
	}
	var runtime := body.duplicate(true)
	runtime["runtime_hash"] = Codec.sha256_canonical(body)
	return _result(runtime, errors)


static func _compile_economy(rules: Dictionary, faction: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	var cooperative_speeds: Array = []
	for entry_variant: Variant in rules["construction"]["cooperative_total_speed_bp"]:
		var entry: Dictionary = entry_variant
		cooperative_speeds.append(int(entry["speed_bp"]))

	var structures: Dictionary = {}
	for role_variant: Variant in _sorted_keys(faction["structures"]):
		var role := str(role_variant)
		var themed: Dictionary = faction["structures"][role]
		if not rules["shared_structures"].has(role):
			errors.append("faction structure role has no shared definition: %s" % role)
			continue
		var shared: Dictionary = rules["shared_structures"][role]
		var type_id := str(themed["type_id"])
		if structures.has(type_id):
			errors.append("duplicate faction structure type_id: %s" % type_id)
			continue
		var footprint := _structure_footprint(rules, role, errors)
		var tags: Array[String] = ["ground", "structure"]
		if role in ["expansion_hall", "stronghold"]:
			tags.append("deposit")
		if role == "food":
			tags.append("food")
		if not (themed.get("producer_type_ids", []) as Array).is_empty():
			tags.append("producer")
		tags.sort()
		var max_hp := int(themed.get("hp_override", shared["hp"]))
		structures[type_id] = {
			"abilities": themed["abilities"].duplicate(),
			"build_ticks": int(shared["build_ticks"]),
			"cost_gold": int(shared["cost_gold"]),
			"cost_lumber": int(shared["cost_lumber"]),
			"display_name": str(themed["display_name"]),
			"food_provided": int(shared["food_provided"]),
			"footprint_cells": footprint,
			"is_deposit": role in ["expansion_hall", "stronghold"],
			"max_hp": max_hp,
			"producer_type_ids": themed["producer_type_ids"].duplicate(),
			"radius_mt": _footprint_radius_mt(footprint),
			"required_tier": int(shared["tier"]),
			"semantic_role": role,
			"tags": tags,
			"worker_range_mt": 4_000,
		}

	var units: Dictionary = {}
	for unit_id_variant: Variant in _sorted_keys(faction["units"]):
		var unit_id := str(unit_id_variant)
		var source: Dictionary = faction["units"][unit_id]
		var producer_roles: Array = [str(source["producer_role"])]
		var tags: Array = source["tags"].duplicate()
		tags.sort()
		var is_worker := "worker" in tags or "lumber_worker" in tags
		var gather_profiles := _gather_profiles(rules, faction, unit_id, tags)
		units[unit_id] = {
			"abilities": source["abilities"].duplicate(),
			"attack": source["attack"].duplicate(true),
			"cost_gold": int(source["cost_gold"]),
			"cost_lumber": int(source["cost_lumber"]),
			"display_name": str(source["display_name"]),
			"food_cost": int(source["food"]),
			"gather_profiles": gather_profiles,
			"is_worker": is_worker,
			"max_hp": int(source["hp"]),
			"max_mana": int(source["mana"]),
			"producer_roles": producer_roles,
			"radius_mt": int(source["radius_mt"]),
			"required_tier": int(source["tier"]),
			"semantic_role": "worker" if is_worker else _unit_semantic_role(tags),
			"speed_mt_per_tick": int(source["speed_mt_per_tick"]),
			"tags": tags,
			"train_ticks": int(source["train_ticks"]),
		}

	var technology := {
		"tier_2": rules["technology"]["tier_2"].duplicate(true),
		"tier_3": rules["technology"]["tier_3"].duplicate(true),
	}
	var upgrades := _compile_upgrades(rules, faction, errors)
	var catalog := {
		"catalog_id": "economy.%s.duel-v1" % str(faction["faction_id"]),
		"construction": {
			"cooperative_speed_bp": cooperative_speeds,
			"full_repair_cost_bp_of_original": int(
				rules["construction"]["full_repair_cost_bp_of_original"]
			),
			"minimum_incomplete_hp_bp": int(
				rules["construction"]["minimum_incomplete_hp_bp"]
			),
			"repair_hp_per_worker_tick": int(
				rules["construction"]["repair_hp_per_worker_tick"]
			),
			"work_bp_per_worker_tick": int(
				rules["construction"]["work_bp_per_worker_tick"]
			),
		},
		"food_and_upkeep": {
			"maximum_food": int(rules["food_and_upkeep"]["maximum_food"]),
			"upkeep": rules["food_and_upkeep"]["upkeep"].duplicate(true),
		},
		"structures": structures,
		"technology": technology,
		"units": units,
		"upgrades": upgrades,
	}
	if errors.is_empty():
		var validator := EconomySystem.new()
		errors.append_array(validator.validate_catalog(catalog))
	return {"catalog": catalog, "errors": errors}


static func _compile_upgrades(
	rules: Dictionary,
	faction: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	for line_variant: Variant in faction["upgrades"]["shared_lines"]:
		var line_id := str(line_variant)
		if not rules["shared_upgrades"].has(line_id):
			errors.append("faction references unknown shared upgrade: %s" % line_id)
			continue
		var source: Variant = rules["shared_upgrades"][line_id]
		var source_levels: Array = source if typeof(source) == TYPE_ARRAY else [source]
		var levels: Array = []
		for source_level_variant: Variant in source_levels:
			var source_level: Dictionary = source_level_variant
			levels.append({
				"cost_gold": int(source_level["gold"]),
				"cost_lumber": int(source_level["lumber"]),
				"required_tier": int(source_level["tier"]),
				"research_ticks": int(source_level["ticks"]),
			})
		result[line_id] = {"levels": levels, "producer_roles": ["forge"]}

	for upgrade_id_variant: Variant in _sorted_keys(faction["upgrades"]["faction_specific"]):
		var upgrade_id := str(upgrade_id_variant)
		var source: Dictionary = faction["upgrades"]["faction_specific"][upgrade_id]
		result[upgrade_id] = {
			"levels": [{
				"cost_gold": int(source["cost_gold"]),
				"cost_lumber": int(source["cost_lumber"]),
				"required_tier": int(source["tier"]),
				"research_ticks": int(source["research_ticks"]),
			}],
			"producer_roles": [str(source["producer_role"])],
		}
	return result


static func _structure_footprint(
	rules: Dictionary,
	role: String,
	errors: PackedStringArray
) -> Array:
	var footprint_key := str(STRUCTURE_FOOTPRINT_KEYS.get(role, ""))
	if footprint_key.is_empty() or not rules["building_footprints"].has(footprint_key):
		errors.append("structure role has no footprint mapping: %s" % role)
		return [1, 1]
	return rules["building_footprints"][footprint_key].duplicate()


static func _footprint_radius_mt(footprint: Array) -> int:
	var maximum_cells := maxi(int(footprint[0]), int(footprint[1]))
	@warning_ignore("integer_division")
	return maxi(250, (maximum_cells * 500 + 1) / 2)


static func _unit_semantic_role(tags: Array) -> String:
	for candidate: String in ["healer", "caster", "siege", "scout", "ranged", "melee"]:
		if candidate in tags:
			return candidate
	return "unit"


static func _gather_profiles(
	rules: Dictionary,
	faction: Dictionary,
	unit_id: String,
	tags: Array
) -> Dictionary:
	var result: Dictionary = {}
	var shared: Dictionary = rules["resources"]["worker_gather"]
	if "worker" in tags:
		result["gold"] = {
			"cargo": int(shared["gold_cargo"]),
			"work_ticks": int(shared["gold_work_ticks"]),
		}
		## Crypt deliberately splits gold and lumber across two starting types.
		if str(faction["faction_id"]) != "crypt-v1":
			result["lumber"] = {
				"cargo": int(shared["lumber_cargo"]),
				"work_ticks": int(shared["lumber_work_ticks"]),
			}
	if "lumber_worker" in tags:
		result["lumber"] = {
			"cargo": int(faction["faction_rules"].get(
				"%s_lumber_cargo" % unit_id, shared["lumber_cargo"]
			)),
			"work_ticks": int(faction["faction_rules"].get(
				"%s_lumber_work_ticks" % unit_id, shared["lumber_work_ticks"]
			)),
		}
	## Grove's ordinary worker has a catalogued nonstandard lumber cargo.
	if unit_id == "wisp" and result.has("lumber"):
		result["lumber"] = {
			"cargo": int(faction["faction_rules"]["wisp_lumber_cargo"]),
			"work_ticks": int(faction["faction_rules"]["wisp_lumber_work_ticks"]),
		}
	return result


static func _sorted_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort()
	return keys


static func _append_errors(target: PackedStringArray, source: Variant) -> void:
	if typeof(source) == TYPE_PACKED_STRING_ARRAY or typeof(source) == TYPE_ARRAY:
		for error_variant: Variant in source:
			target.append(str(error_variant))
	elif source != null:
		target.append(str(source))


static func _result(runtime: Dictionary, errors: PackedStringArray) -> Dictionary:
	return {"errors": errors, "ok": errors.is_empty(), "runtime": runtime}
