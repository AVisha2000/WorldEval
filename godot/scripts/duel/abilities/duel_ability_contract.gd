class_name DuelAbilityContract
extends RefCounted

const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

## Closed executable vocabulary of the checked-in faction catalogs. Adding a
## catalog effect, schedule, activation mode, or target mode without extending
## this contract prevents the ability authority from being configured.

const ACTIVATION_KINDS: Array[String] = [
	"active", "active_channel", "active_research_transform",
	"active_resource_conversion", "active_sacrifice", "active_transform",
	"active_transform_toggle", "active_transport", "active_ultimate",
	"active_ultimate_channel", "active_ultimate_transform", "passive",
	"passive_attack_modifier", "passive_aura", "passive_conditional",
	"passive_storage", "passive_threshold", "passive_trigger", "toggle", "triggered",
]

const TARGET_KINDS: Array[String] = [
	"attack_ground_area", "attack_line", "attack_target", "attack_target_chain",
	"attack_target_cone", "cone", "corpse", "entity", "entity_chain", "global",
	"line", "point", "point_or_entity", "self", "self_area", "site", "structure",
]

const IMPACT_SCHEDULES: Array[String] = [
	"after_30_uninterrupted_attack_move_ticks_then_first_melee_impact",
	"attack_impact", "attack_projectile_path", "continuous",
	"continuous_below_4000_hp_bp", "dash_completion", "every_10_ticks",
	"every_10_ticks_for_100_ticks", "first_attack_impact_from_invisibility",
	"immediate_at_commit", "immediate_at_commit_then_destroy_caster",
	"immediate_at_commit_then_first_enemy_trigger",
	"immediate_then_per_tick_for_50_ticks", "integer_accumulator_over_60_ticks",
	"next_activation_phase", "night_after_stationary_windup", "per_tick_for_40_ticks",
	"per_tick_for_50_ticks", "per_tick_for_60_ticks", "per_tick_for_80_ticks",
	"per_tick_for_rank_duration", "per_tick_while_commanded", "research_completion",
	"six_impacts_every_10_ticks", "tick_boundary", "windup_completion",
]

const REQUIRED_FIELDS: Array[String] = [
	"activation_kind", "allowed_owners", "area_radius_mt", "cast_range_mt",
	"channel_ticks", "cooldown_ticks_by_rank", "dispel_class", "effects",
	"forbidden_target_tags", "impact_schedule", "interruption_flags",
	"mana_cost_by_rank", "required_target_tags", "status_stacking_key",
	"target_kind", "target_layers", "windup_ticks",
]

const OPTIONAL_FIELDS: Array[String] = [
	"area_radius_mt_by_rank", "autocast_eligible", "cast_range_mt_by_rank",
	"cone_angle_mdeg", "requires_upgrade", "windup_ticks_by_rank",
]

## Each catalog effect is routed explicitly. `effect_kind` is retained on the
## emitted primitive; these families state which authority adapter must apply
## it and keep the runtime free of prose interpretation.
const EFFECT_DISPATCH: Dictionary = {
	"additional_targets": "selection",
	"allied_detection_radius_mt": "vision",
	"armor_centi": "status_modifier",
	"attack_cooldown_bp": "status_modifier",
	"attack_speed_bp": "status_modifier",
	"bounce_damage_bp": "attack_modifier",
	"capacity": "storage",
	"chain_damage_bp": "attack_modifier",
	"consume_corpse": "corpse",
	"create_generic_corpse": "corpse",
	"create_illusions": "summon",
	"create_owned_blight": "world_zone",
	"damage_dealt_bp": "status_modifier",
	"damage_loss_per_jump_bp": "selection",
	"damage_per_projectile": "damage",
	"damage_received_bp": "status_modifier",
	"damage_taken_from_owner_bp": "status_modifier",
	"damage_wakes_after_minimum_ticks": "control_rule",
	"dash": "movement",
	"destroy_trees": "world_edit",
	"disable": "control",
	"disable_attack": "control",
	"disable_structure_attack_and_production": "control",
	"disable_structures": "control",
	"dispel": "dispel",
	"distribute_post_mitigation_damage_evenly": "link",
	"enemy_mana_burn": "resource",
	"energy_to_hp": "resource_conversion",
	"energy_to_mana_ratio": "resource_conversion",
	"final_damage_bp": "attack_modifier",
	"force_air_to_ground_and_root": "control",
	"force_ground_immobile": "control",
	"force_night": "world_clock",
	"friendly_fire_bp": "attack_modifier",
	"garrison_worker": "transport",
	"heal_owned_crypt": "healing",
	"hero_damage": "damage",
	"hero_damage_flat": "status_modifier",
	"hp_regeneration_bp": "status_modifier",
	"illusion_damage_bp": "summon_modifier",
	"illusion_damage_taken_bp": "summon_modifier",
	"invisibility": "status_modifier",
	"jumps": "selection",
	"link_maximum_allies": "link",
	"living_enemy_spell_damage": "damage",
	"magic_immunity": "status_modifier",
	"mana_burn": "resource",
	"maximum_hits_per_target": "selection",
	"maximum_targets": "selection",
	"maximum_visible_targets": "selection",
	"movement_speed_bp": "status_modifier",
	"night_sight_radius_mt": "vision",
	"physical_damage_bp": "status_modifier",
	"physical_damage_received_bp": "status_modifier",
	"pierce_damage_received_bp": "status_modifier",
	"pierce_projectile_count": "projectile",
	"restore_hp": "healing",
	"restore_hp_per_10_ticks": "healing",
	"restore_hp_per_tick": "healing",
	"restore_hp_total": "healing",
	"restore_owned_biological_hp_per_tick": "healing",
	"return_hp_bp": "revival",
	"reveal": "vision",
	"reveal_target": "vision",
	"revive_most_expensive_corpses": "revival",
	"root": "control",
	"root_first_enemy": "control",
	"root_hostile": "control",
	"root_or_force_ground": "control",
	"secondary_blade_damage_bp": "attack_modifier",
	"sequential_target_damage_bp": "attack_modifier",
	"set_armor_centi": "transform",
	"set_armor_class_fortified": "transform",
	"set_armor_class_heavy": "transform",
	"set_attack_cooldown_ticks": "transform",
	"set_attack_damage": "transform",
	"set_flying": "transform",
	"set_max_hp_preserve_percentage": "transform",
	"set_speed_mt_per_second": "transform",
	"shield": "shield",
	"self_heal_bp_of_damage_dealt": "healing",
	"siege_damage_taken_bp": "status_modifier",
	"sight_and_detection": "vision",
	"sight_radius_mt": "vision",
	"silence": "control",
	"spell_damage": "damage",
	"spell_damage_equal_to_mana_burned": "damage",
	"spell_damage_per_impact": "damage",
	"spell_damage_per_tick": "damage",
	"spell_resistance_bp": "status_modifier",
	"splash_damage_bands_bp": "attack_modifier",
	"splash_damage_bp": "attack_modifier",
	"store_corpse": "storage",
	"structure_damage_bp": "damage_modifier",
	"stun": "control",
	"summon_crypt_thrall": "summon",
	"summon_grove_treant": "summon",
	"summon_invisible_trap": "summon",
	"summon_mending_ward": "summon",
	"summon_spell_damage": "damage_summon",
	"temporary_max_hp_bp": "status_modifier",
	"temporary_max_hp_flat_preserve_percentage": "transform",
	"temporary_summon_xp_bp": "summon_modifier",
	"transfer_hp_per_tick": "resource_conversion",
	"transform_attack_tower": "transform",
	"transform_militia": "transform",
	"transform_rooted_ancient": "transform",
	"transform_uprooted_ancient": "transform",
	"visible_enemy_sight_bp": "vision",
}


static func compile_official_registry(loaded_result: Dictionary = {}) -> Dictionary:
	var loaded := loaded_result
	if loaded.is_empty():
		loaded = CatalogLoader.load_official_catalogs()
	var errors := PackedStringArray()
	if not bool(loaded.get("ok", false)):
		_append_errors(errors, loaded.get("errors", ["official catalog load failed"]))
		return _result({}, {}, errors)
	var catalogs: Dictionary = loaded.get("catalogs", {})
	var hashes: Dictionary = loaded.get("canonical_hashes", {})
	var registry: Dictionary = {}
	var faction_hashes: Dictionary = {}
	for faction_id: String in CatalogLoader.FACTION_IDS:
		var key := "faction:%s" % faction_id
		if typeof(catalogs.get(key, null)) != TYPE_DICTIONARY:
			errors.append("official faction catalog is missing: %s" % faction_id)
			continue
		var faction: Dictionary = catalogs[key]
		if str(faction.get("faction_id", "")) != faction_id:
			errors.append("official faction ID mismatch: %s" % faction_id)
			continue
		if typeof(faction.get("abilities", null)) != TYPE_DICTIONARY:
			errors.append("faction abilities must be an object: %s" % faction_id)
			continue
		faction_hashes[faction_id] = str(hashes.get(key, ""))
		var ability_ids: Array = faction["abilities"].keys()
		ability_ids.sort()
		for ability_variant: Variant in ability_ids:
			var ability_id := str(ability_variant)
			if registry.has(ability_id):
				errors.append("ability ID is not globally unique: %s" % ability_id)
				continue
			var definition: Dictionary = faction["abilities"][ability_id]
			_validate_ability(faction_id, ability_id, definition, errors)
			var compiled := definition.duplicate(true)
			compiled["ability_id"] = ability_id
			compiled["faction_id"] = faction_id
			compiled["rank_count"] = (definition.get("mana_cost_by_rank", []) as Array).size()
			var dispatch: Array = []
			for effect_variant: Variant in definition.get("effects", []):
				var effect: Dictionary = effect_variant
				dispatch.append({
					"effect_kind": str(effect.get("kind", "")),
					"primitive_kind": str(EFFECT_DISPATCH.get(str(effect.get("kind", "")), "")),
				})
			compiled["effect_dispatch"] = dispatch
			registry[ability_id] = compiled
	if registry.size() != 100:
		errors.append("locked faction ability count must equal 100, got %d" % registry.size())
	if EFFECT_DISPATCH.size() != 109:
		errors.append("locked effect vocabulary must equal 109, got %d" % EFFECT_DISPATCH.size())
	if IMPACT_SCHEDULES.size() != 26:
		errors.append("locked impact schedule vocabulary must equal 26")
	return _result(registry, faction_hashes, errors)


static func coverage() -> Dictionary:
	return {
		"activation_kinds": ACTIVATION_KINDS.size(),
		"effect_kinds": EFFECT_DISPATCH.size(),
		"impact_schedules": IMPACT_SCHEDULES.size(),
		"target_kinds": TARGET_KINDS.size(),
	}


static func _validate_ability(
	faction_id: String,
	ability_id: String,
	ability: Dictionary,
	errors: PackedStringArray
) -> void:
	var path := "%s.abilities.%s" % [faction_id, ability_id]
	for field: String in REQUIRED_FIELDS:
		if not ability.has(field):
			errors.append("%s is missing %s" % [path, field])
	var allowed_fields: Dictionary = {}
	for field: String in REQUIRED_FIELDS + OPTIONAL_FIELDS:
		allowed_fields[field] = true
	for field_variant: Variant in ability.keys():
		if not allowed_fields.has(str(field_variant)):
			errors.append("%s contains unsupported field %s" % [path, str(field_variant)])
	if not errors.is_empty() and not _has_required_shape(ability):
		return
	if str(ability["activation_kind"]) not in ACTIVATION_KINDS:
		errors.append("%s activation_kind is unsupported" % path)
	if str(ability["target_kind"]) not in TARGET_KINDS:
		errors.append("%s target_kind is unsupported" % path)
	if str(ability["impact_schedule"]) not in IMPACT_SCHEDULES:
		errors.append("%s impact_schedule is unsupported" % path)
	if str(ability["dispel_class"]) not in ["none", "ordinary_magical", "undispellable"]:
		errors.append("%s dispel_class is unsupported" % path)
	for field: String in ["cast_range_mt", "area_radius_mt", "windup_ticks", "channel_ticks"]:
		if typeof(ability[field]) != TYPE_INT or int(ability[field]) < 0:
			errors.append("%s.%s must be a non-negative integer" % [path, field])
	for field: String in [
		"allowed_owners", "target_layers", "required_target_tags",
		"forbidden_target_tags", "interruption_flags",
	]:
		_validate_string_array(ability[field], "%s.%s" % [path, field], errors)
	if (ability["allowed_owners"] as Array).is_empty():
		errors.append("%s.allowed_owners must not be empty" % path)
	for layer_variant: Variant in ability["target_layers"]:
		if str(layer_variant) not in ["air", "ground"]:
			errors.append("%s contains unsupported target layer" % path)
	var rank_count := _validate_rank_array(ability["mana_cost_by_rank"], path + ".mana_cost_by_rank", errors)
	var cooldown_count := _validate_rank_array(ability["cooldown_ticks_by_rank"], path + ".cooldown_ticks_by_rank", errors)
	if rank_count != cooldown_count:
		errors.append("%s mana/cooldown rank counts differ" % path)
	for optional_rank_field: String in [
		"area_radius_mt_by_rank", "cast_range_mt_by_rank", "windup_ticks_by_rank",
	]:
		if ability.has(optional_rank_field) \
			and _validate_rank_array(ability[optional_rank_field], path + "." + optional_rank_field, errors) != rank_count:
			errors.append("%s.%s rank count differs" % [path, optional_rank_field])
	if ability.has("autocast_eligible") and typeof(ability["autocast_eligible"]) != TYPE_BOOL:
		errors.append("%s.autocast_eligible must be boolean" % path)
	if ability.has("requires_upgrade") \
		and (typeof(ability["requires_upgrade"]) != TYPE_STRING or str(ability["requires_upgrade"]).is_empty()):
		errors.append("%s.requires_upgrade must be a non-empty ID" % path)
	if typeof(ability["effects"]) != TYPE_ARRAY or (ability["effects"] as Array).is_empty():
		errors.append("%s.effects must be a non-empty array" % path)
		return
	for index: int in (ability["effects"] as Array).size():
		var effect_variant: Variant = ability["effects"][index]
		if typeof(effect_variant) != TYPE_DICTIONARY:
			errors.append("%s.effects[%d] must be an object" % [path, index])
			continue
		var effect: Dictionary = effect_variant
		if _sorted_strings(effect.keys()) != ["duration_ticks", "kind", "values"]:
			errors.append("%s.effects[%d] has unsupported fields" % [path, index])
			continue
		var kind := str(effect.get("kind", ""))
		if not EFFECT_DISPATCH.has(kind):
			errors.append("%s.effects[%d] kind is unsupported: %s" % [path, index, kind])
		_validate_integer_array(effect.get("values"), "%s.effects[%d].values" % [path, index], errors, false)
		_validate_integer_array(effect.get("duration_ticks"), "%s.effects[%d].duration_ticks" % [path, index], errors, true)
		if (effect.get("values", []) as Array).size() != (effect.get("duration_ticks", []) as Array).size():
			errors.append("%s.effects[%d] values/durations differ" % [path, index])
	for message: String in Codec.validate_canonical_value(ability, "$catalog.%s.%s" % [faction_id, ability_id]):
		errors.append(message)


static func _has_required_shape(ability: Dictionary) -> bool:
	for field: String in REQUIRED_FIELDS:
		if not ability.has(field):
			return false
	return true


static func _validate_rank_array(value: Variant, path: String, errors: PackedStringArray) -> int:
	_validate_integer_array(value, path, errors, true)
	if typeof(value) != TYPE_ARRAY:
		return 0
	if (value as Array).is_empty():
		errors.append("%s must not be empty" % path)
	return (value as Array).size()


static func _validate_integer_array(
	value: Variant, path: String, errors: PackedStringArray, non_negative: bool
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append("%s must be an array" % path)
		return
	for index: int in (value as Array).size():
		if typeof(value[index]) != TYPE_INT:
			errors.append("%s[%d] must be an integer" % [path, index])
		elif non_negative and int(value[index]) < 0:
			errors.append("%s[%d] must be non-negative" % [path, index])


static func _validate_string_array(value: Variant, path: String, errors: PackedStringArray) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append("%s must be an array" % path)
		return
	var seen: Dictionary = {}
	for index: int in (value as Array).size():
		if typeof(value[index]) != TYPE_STRING or str(value[index]).is_empty():
			errors.append("%s[%d] must be a non-empty string" % [path, index])
			continue
		var current := str(value[index])
		if seen.has(current):
			errors.append("%s must not contain duplicates" % path)
		seen[current] = true


static func _sorted_strings(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value: Variant in values:
		result.append(str(value))
	result.sort()
	return result


static func _append_errors(target: PackedStringArray, values: Variant) -> void:
	if typeof(values) not in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY]:
		target.append(str(values))
		return
	for value: Variant in values:
		target.append(str(value))


static func _result(
	registry: Dictionary, faction_hashes: Dictionary, errors: PackedStringArray
) -> Dictionary:
	return {
		"coverage": coverage(),
		"errors": errors,
		"faction_hashes": faction_hashes,
		"ok": errors.is_empty(),
		"registry": registry,
	}
