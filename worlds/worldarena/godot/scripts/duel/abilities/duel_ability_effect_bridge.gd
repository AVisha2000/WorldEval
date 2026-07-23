class_name DuelAbilityEffectBridge
extends RefCounted

const Contract := preload("res://scripts/duel/abilities/duel_ability_contract.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")

## Applies the closed, typed primitives emitted by DuelAbilityRuntime to the
## authoritative simulation.  The runtime owns cast timing and target legality;
## this adapter owns mutations.  Every locked primitive family is named here so
## a new catalog effect fails closed instead of becoming prose-driven behavior.

const BP_ONE := 10_000
const BASE_HP_REGEN_DENOMINATOR := 20 * BP_ONE
const BASE_MANA_REGEN_DENOMINATOR := 10 * BP_ONE
const SUMMON_EFFECTS: Dictionary = {
	"summon_crypt_thrall": "crypt_thrall",
	"summon_grove_treant": "grove_treant",
	"summon_invisible_trap": "invisible_trap",
	"summon_mending_ward": "mending_ward",
}
const STATUS_PRIMITIVES: Array[String] = [
	"attack_modifier", "control", "control_rule", "damage_modifier", "link",
	"status_modifier", "vision",
]
const SUPPORTED_PRIMITIVE_FAMILIES: Array[String] = [
	"attack_modifier", "control", "control_rule", "corpse", "damage",
	"damage_modifier", "damage_summon", "dispel", "healing", "link",
	"movement", "projectile", "resource", "resource_conversion", "revival",
	"selection", "shield", "status_modifier", "storage", "summon",
	"summon_modifier", "transform", "transport", "vision", "world_clock",
	"world_edit", "world_zone",
]
const PASSIVE_REFRESH_TICKS := 2
const TRANSFORM_EXPIRY_PREFIX := "ability_transform_expiry::"

var selected_faction_id: String = ""
var faction_catalog: Dictionary = {}
var _events: Array[Dictionary] = []
var _local_event_seq: int = 0
var _spawned_by_cast: Dictionary = {}
var _applied_delivery_fingerprints: Dictionary = {}


func configure(faction_id: String, loaded_result: Dictionary = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	if faction_id not in CatalogLoader.FACTION_IDS:
		errors.append("ability effect bridge received an unknown faction")
		return errors
	var loaded := loaded_result
	if loaded.is_empty():
		loaded = CatalogLoader.load_official_catalogs()
	if not bool(loaded.get("ok", false)):
		_append_errors(errors, loaded.get("errors", []))
		return errors
	var key := "faction:%s" % faction_id
	if not (loaded.get("catalogs", {}) as Dictionary).has(key):
		errors.append("ability effect bridge cannot find selected faction catalog")
		return errors
	selected_faction_id = faction_id
	faction_catalog = loaded["catalogs"][key].duplicate(true)
	_events.clear()
	_local_event_seq = 0
	_spawned_by_cast.clear()
	_applied_delivery_fingerprints.clear()
	return errors


func is_configured() -> bool:
	return not selected_faction_id.is_empty() and not faction_catalog.is_empty()


func advance_phase(simulation: Variant, abilities: Variant, phase: String) -> Dictionary:
	var errors := PackedStringArray()
	if not is_configured() or simulation == null or not bool(simulation.get("is_ready")):
		errors.append("ability effect bridge requires configured authoritative simulation")
		return {"applied": 0, "errors": errors, "ok": false}
	if abilities == null or not bool(abilities.is_configured()):
		errors.append("ability effect bridge requires configured ability runtime")
		return {"applied": 0, "errors": errors, "ok": false}
	var candidates: Array = []
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		if entity.alive and entity.hp > 0:
			candidates.append(entity_id)
	var advanced: Dictionary = abilities.advance(
		simulation, phase, {"candidate_entity_ids": candidates}
	)
	_append_errors(errors, advanced.get("errors", []))
	if not bool(advanced.get("ok", false)):
		return {"applied": 0, "errors": errors, "ok": false}
	var applied := apply_effect_intents(simulation, abilities, abilities.consume_effect_intents())
	_append_errors(errors, applied.get("errors", []))
	if phase == "activation":
		_append_errors(errors, synchronize_persistent(simulation, abilities))
	return {
		"applied": int(applied.get("applied", 0)),
		"errors": errors,
		"ok": errors.is_empty(),
	}


func apply_effect_intents(
	simulation: Variant, abilities: Variant, intents_input: Array
) -> Dictionary:
	var errors := PackedStringArray()
	if not is_configured() or simulation == null or not bool(simulation.get("is_ready")):
		errors.append("ability effect bridge requires configured authoritative simulation")
		return {"applied": 0, "errors": errors, "ignored_duplicates": 0, "ok": false}
	if abilities == null or not bool(abilities.is_configured()):
		errors.append("ability effect bridge requires configured ability runtime")
		return {"applied": 0, "errors": errors, "ignored_duplicates": 0, "ok": false}
	var intents: Array[Dictionary] = []
	for value: Variant in intents_input:
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("ability effect intent must be an object")
			continue
		intents.append((value as Dictionary).duplicate(true))
	if not errors.is_empty():
		return {"applied": 0, "errors": errors, "ignored_duplicates": 0, "ok": false}
	intents.sort_custom(_effect_less)
	var pending: Array[Dictionary] = []
	var ignored_duplicates := 0
	var seen: Dictionary = {}
	for effect: Dictionary in intents:
		var intent_reason := _effect_intent_reason(effect, abilities)
		if not intent_reason.is_empty():
			errors.append(intent_reason)
			continue
		var fingerprint := Codec.sha256_canonical(effect)
		var delivery_key := _effect_delivery_key(effect)
		if seen.has(delivery_key):
			errors.append("ability effect deliveries must be unique per application")
			continue
		seen[delivery_key] = fingerprint
		if _applied_delivery_fingerprints.has(delivery_key):
			if str(_applied_delivery_fingerprints[delivery_key]) == fingerprint:
				ignored_duplicates += 1
				continue
			errors.append(
				"ability effect delivery was reused with different content: %s" % delivery_key
			)
			continue
		var kind := str(effect.get("effect_kind", ""))
		var primitive := str(effect.get("primitive_kind", ""))
		var synthetic := (kind == "destroy_caster" and primitive == "lifecycle") \
			or (kind == "remove_stacking_key" and primitive == "status_remove")
		if not Contract.EFFECT_DISPATCH.has(kind) and not synthetic:
			errors.append("unsupported ability effect kind: %s" % kind)
			continue
		if Contract.EFFECT_DISPATCH.has(kind) \
			and str(Contract.EFFECT_DISPATCH[kind]) != primitive:
			errors.append("ability effect primitive mismatch: %s" % kind)
			continue
		if not _ability_declares_effect_kind(abilities, effect):
			errors.append("ability does not declare effect kind: %s" % kind)
			continue
		pending.append({
			"delivery_key": delivery_key,
			"effect": effect,
			"fingerprint": fingerprint,
		})
	## Structural and collision failures are atomic: no valid sibling intent may
	## mutate authority when another member of the same delivery batch is invalid.
	if not errors.is_empty():
		return {
			"applied": 0,
			"errors": errors,
			"ignored_duplicates": ignored_duplicates,
			"ok": false,
		}
	_spawned_by_cast.clear()
	var applied := 0
	for pending_variant: Dictionary in pending:
		var effect: Dictionary = pending_variant["effect"]
		var kind := str(effect["effect_kind"])
		var primitive := str(effect["primitive_kind"])
		var result := _apply_effect(simulation, abilities, effect)
		if not bool(result.get("ok", false)):
			errors.append("%s: %s" % [kind, str(result.get("code", "execution_failed"))])
			continue
		applied += 1
		_applied_delivery_fingerprints[str(pending_variant["delivery_key"])] = str(
			pending_variant["fingerprint"]
		)
		_queue_event(simulation.state.tick, "ability_effect_applied", effect, {
			"effect_kind": kind,
			"primitive_kind": primitive,
			"target_count": int(result.get("target_count", 0)),
		})
	if applied > 0:
		_recompute_temporary_max_hp(simulation)
		_synchronize_status_derived_state(simulation)
	return {
		"applied": applied,
		"errors": errors,
		"ignored_duplicates": ignored_duplicates,
		"ok": errors.is_empty(),
	}


func synchronize_persistent(simulation: Variant, abilities: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	var persistent: Array = abilities.persistent_effect_snapshot()
	if persistent.is_empty():
		return errors
	persistent.sort_custom(_effect_less)
	for effect_variant: Variant in persistent:
		var effect: Dictionary = (effect_variant as Dictionary).duplicate(true)
		effect["primitive_value"] = int(effect.get("resolved_value", 0))
		var primitive := str(effect.get("primitive_kind", ""))
		var kind := str(effect.get("effect_kind", ""))
		if primitive in STATUS_PRIMITIVES:
			var targets := _persistent_targets(simulation, abilities, effect)
			_apply_status(simulation, effect, targets, PASSIVE_REFRESH_TICKS)
		elif primitive == "transform":
			var transformed := effect.duplicate(true)
			transformed["selected_target_ids"] = _persistent_targets(
				simulation, abilities, effect
			)
			var result := _transform(
				simulation, transformed, transformed["selected_target_ids"]
			)
			if not bool(result.get("ok", false)):
				errors.append("persistent transform could not be synchronized")
		elif primitive == "world_zone" and kind == "create_owned_blight":
			var source_id := int(effect.get("source_id", 0))
			if simulation.state.entities.has(source_id):
				var definition: Dictionary = abilities.ability_definition(str(effect["ability_id"]))
				simulation.state.entities[source_id].integer_attributes[
					"owned_blight_radius_mt"
				] = int(definition.get("area_radius_mt", 0))
		elif primitive == "healing" and kind == "restore_hp_per_10_ticks" \
			and int(simulation.state.tick) % 10 == 0:
			for target_id: int in _persistent_targets(simulation, abilities, effect):
				var receipt: Dictionary = simulation.combat.schedule_heal_effect(
					simulation.state, int(effect["source_id"]), target_id,
					maxi(0, int(effect["resolved_value"])), simulation.state.tick, true
				)
				if not bool(receipt.get("accepted", false)):
					errors.append("persistent healing could not be scheduled")
	_recompute_temporary_max_hp(simulation)
	_synchronize_status_derived_state(simulation)
	return errors


func regeneration_deltas(simulation: Variant) -> Array:
	## Integer accumulators avoid cadence-dependent rounding. Base Hero HP/mana
	## regeneration remains owned by DuelHeroSystem; external ward/Blight healing
	## still reaches eligible Heroes through these simultaneous deltas.
	var result: Array = []
	var status_totals := _status_totals_by_target(simulation.state)
	var mending_wards := _mending_ward_sources(simulation)
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		if not entity.alive or entity.hp <= 0:
			continue
		if "biological" in entity.tags and entity.hp < entity.max_hp:
			var amount := _mending_ward_healing(entity, mending_wards)
			var modifiers: Dictionary = status_totals.get(entity_id, {})
			if "hero" in entity.tags:
				amount += _hero_regeneration_bonus(simulation, entity, modifiers)
			else:
				var multiplier := BP_ONE + int(modifiers.get("hp_regeneration_bp", 0))
				var accumulator := int(entity.integer_attributes.get(
					"hp_regen_accumulator", 0
				)) + maxi(0, multiplier)
				while accumulator >= BASE_HP_REGEN_DENOMINATOR:
					accumulator -= BASE_HP_REGEN_DENOMINATOR
					amount += 1
				entity.integer_attributes["hp_regen_accumulator"] = accumulator
			if selected_faction_id == "crypt-v1" \
				and (simulation.state.tick + 1) % 100 == 0 \
				and _on_owned_blight(simulation, entity):
				amount += maxi(1, entity.max_hp / 100)
			if amount > 0:
				result.append(_delta(
					simulation.state.tick, entity_id, DeltaRecord.Kind.HP, amount,
					0, 8_000_000 + entity_id
				))
		if "hero" in entity.tags:
			continue
		if entity.max_mana > 0 and entity.mana < entity.max_mana:
			var mana_accumulator := int(entity.integer_attributes.get(
				"mana_regen_accumulator", 0
			)) + BP_ONE
			var mana_amount := 0
			while mana_accumulator >= BASE_MANA_REGEN_DENOMINATOR:
				mana_accumulator -= BASE_MANA_REGEN_DENOMINATOR
				mana_amount += 1
			entity.integer_attributes["mana_regen_accumulator"] = mana_accumulator
			if mana_amount > 0:
				result.append(_delta(
					simulation.state.tick, entity_id, DeltaRecord.Kind.MANA, mana_amount,
					0, 9_000_000 + entity_id
				))
	return result


func resolve_lifecycle(simulation: Variant) -> void:
	if simulation == null or not bool(simulation.get("is_ready")):
		return
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		var expiry := int(entity.integer_attributes.get("summon_expiry_tick", 0))
		if entity.alive and expiry > 0 and simulation.state.tick >= expiry:
			entity.hp = 0
			_queue_event(simulation.state.tick, "summon_expired", {
				"source_id": int(entity.integer_attributes.get("summon_source_id", 0)),
				"selected_target_ids": [entity_id],
			}, {"entity_id": entity_id})
		var shield_expiry := int(entity.integer_attributes.get("shield_expiry_tick", 0))
		if shield_expiry > 0 and simulation.state.tick >= shield_expiry \
			and simulation.state.combat.actors.has(entity_id):
			simulation.state.combat.actors[entity_id]["shield_hp"] = 0
			entity.integer_attributes.erase("shield_expiry_tick")
			entity.integer_attributes.erase("shield_dispel_class_code")
		var corpse_expiry := int(entity.integer_attributes.get("corpse_expiry_tick", 0))
		if "corpse" in entity.tags and corpse_expiry > 0 \
			and simulation.state.tick >= corpse_expiry:
			_remove_entity_authority(simulation, entity_id)
			continue
		for key_variant: Variant in entity.integer_attributes.keys().duplicate():
			var key := str(key_variant)
			if not key.begins_with(TRANSFORM_EXPIRY_PREFIX) \
				or simulation.state.tick < int(entity.integer_attributes[key_variant]):
				continue
			var ability_id := key.trim_prefix(TRANSFORM_EXPIRY_PREFIX)
			_restore_toggle_transform(simulation, entity_id, ability_id)
			entity.integer_attributes.erase(key_variant)
	_recompute_temporary_max_hp(simulation)
	_synchronize_status_derived_state(simulation)


func take_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in _events:
		result.append(event.duplicate(true))
	_events.clear()
	return result


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if not is_configured():
		errors.append("ability effect bridge is not configured")
	var dispatch: Dictionary = Contract.EFFECT_DISPATCH
	if dispatch.size() != 109:
		errors.append("ability effect dispatch is incomplete")
	if SUPPORTED_PRIMITIVE_FAMILIES.size() != 27:
		errors.append("ability primitive family dispatch is incomplete")
	var seen_primitives: Dictionary = {}
	for kind_variant: Variant in dispatch.keys():
		var primitive := str(dispatch[kind_variant])
		seen_primitives[primitive] = true
		if primitive.is_empty():
			errors.append("ability effect dispatch has an empty primitive")
		elif primitive not in SUPPORTED_PRIMITIVE_FAMILIES:
			errors.append("ability effect dispatch has an unsupported primitive: %s" % primitive)
	if seen_primitives.size() != SUPPORTED_PRIMITIVE_FAMILIES.size():
		errors.append("ability effect dispatch does not exercise every primitive family")
	return errors


func _apply_effect(simulation: Variant, abilities: Variant, effect: Dictionary) -> Dictionary:
	var primitive := str(effect["primitive_kind"])
	var kind := str(effect["effect_kind"])
	var targets := _effect_targets(simulation, effect)
	match primitive:
		"damage", "damage_summon":
			return _apply_damage(simulation, effect, targets, primitive == "damage_summon")
		"healing":
			if kind == "self_heal_bp_of_damage_dealt":
				return _apply_status(simulation, effect, targets, _duration(effect))
			return _apply_healing(simulation, effect, targets)
		"resource":
			return _apply_resource(simulation, effect, targets)
		"resource_conversion":
			return _apply_resource_conversion(simulation, effect, targets)
		"shield":
			return _apply_shield(simulation, effect, targets)
		"status_modifier", "attack_modifier", "damage_modifier", "control", \
		"control_rule", "link", "vision":
			return _apply_status(simulation, effect, targets, _duration(effect))
		"status_remove":
			return _remove_statuses(simulation, effect, targets)
		"dispel":
			return _dispel(simulation, targets)
		"movement":
			return _dash(simulation, effect, targets)
		"summon":
			return _summon(simulation, effect)
		"summon_modifier":
			var spawned: Array = _spawned_by_cast.get(int(effect.get("cast_id", 0)), [])
			return _apply_status(simulation, effect, spawned, _duration(effect))
		"corpse":
			return _corpse(simulation, effect, targets)
		"storage":
			return _storage(simulation, effect, targets)
		"transform":
			return _transform(simulation, effect, targets)
		"world_clock":
			return _force_night(simulation, effect)
		"world_zone":
			return _world_zone(simulation, abilities, effect)
		"world_edit":
			return _world_edit(simulation, effect)
		"lifecycle":
			return _lifecycle(simulation, effect, targets)
		"revival":
			return _revival(simulation, effect, targets)
		"transport":
			return _transport(simulation, effect, targets)
		"selection", "projectile":
			## These primitives constrain sibling effects; DuelAbilityRuntime already
			## materialized their deterministic selected_target_ids.
			return {"ok": true, "target_count": targets.size()}
	return {"code": "unsupported_primitive", "ok": false}


func _apply_damage(
	simulation: Variant, effect: Dictionary, targets: Array, summoned_only: bool
) -> Dictionary:
	var count := 0
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.entities.has(target_id):
			continue
		if summoned_only and "summon" not in simulation.state.entities[target_id].tags:
			continue
		var damage_type := "hero" if str(effect["effect_kind"]) in [
			"hero_damage", "hero_damage_flat",
		] else "spell"
		var amount := maxi(0, int(effect["primitive_value"]))
		if str(effect["effect_kind"]) == "spell_damage_equal_to_mana_burned":
			amount = maxi(0, int(
				simulation.state.entities[target_id].integer_attributes.get(
					"last_mana_burned", 0
				)
			))
		var receipt: Dictionary = simulation.combat.schedule_damage_effect(
			simulation.state, int(effect["source_id"]), target_id,
			amount, damage_type,
			simulation.state.tick
		)
		if bool(receipt.get("accepted", false)):
			count += 1
	return {"code": "accepted", "ok": true, "target_count": count}


func _apply_healing(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var count := 0
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.entities.has(target_id):
			continue
		var target: EntityRecord = simulation.state.entities[target_id]
		if str(effect["effect_kind"]) == "heal_owned_crypt" \
			and selected_faction_id != "crypt-v1":
			continue
		var receipt: Dictionary = simulation.combat.schedule_heal_effect(
			simulation.state, int(effect["source_id"]), target_id,
			maxi(0, int(effect["primitive_value"])), simulation.state.tick,
			"mechanical" not in target.tags
		)
		if bool(receipt.get("accepted", false)):
			count += 1
	return {"ok": true, "target_count": count}


func _apply_resource(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var count := 0
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.entities.has(target_id):
			continue
		var entity: EntityRecord = simulation.state.entities[target_id]
		var burned := mini(entity.mana, maxi(0, int(effect["primitive_value"])))
		entity.mana -= burned
		entity.integer_attributes["last_mana_burned"] = burned
		count += 1
	return {"ok": true, "target_count": count}


func _apply_resource_conversion(
	simulation: Variant, effect: Dictionary, targets: Array
) -> Dictionary:
	var source_id := int(effect["source_id"])
	var kind := str(effect["effect_kind"])
	var value := maxi(0, int(effect["primitive_value"]))
	var count := 0
	if kind == "transfer_hp_per_tick":
		for target_variant: Variant in targets:
			var target_id := int(target_variant)
			if not simulation.state.entities.has(target_id):
				continue
			simulation.combat.schedule_damage_effect(
				simulation.state, source_id, target_id, value, "spell", simulation.state.tick
			)
			simulation.combat.schedule_heal_effect(
				simulation.state, source_id, source_id, value, simulation.state.tick, true
			)
			count += 1
		return {"ok": true, "target_count": count}
	if not simulation.state.entities.has(source_id):
		return {"code": "invalid_source", "ok": false}
	var source: EntityRecord = simulation.state.entities[source_id]
	var energy := int(source.integer_attributes.get("stored_energy", 0))
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.entities.has(target_id) or energy <= 0:
			continue
		var target: EntityRecord = simulation.state.entities[target_id]
		if kind == "energy_to_hp":
			var spend := mini(energy, maxi(0, target.max_hp - target.hp))
			target.hp += spend
			energy -= spend
		elif kind == "energy_to_mana_ratio":
			var ratio := maxi(1, value)
			var spend := mini(energy, (maxi(0, target.max_mana - target.mana) + ratio - 1) / ratio)
			target.mana = mini(target.max_mana, target.mana + spend * ratio)
			energy -= spend
		count += 1
	source.integer_attributes["stored_energy"] = energy
	return {"ok": true, "target_count": count}


func _apply_shield(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var count := 0
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.combat.actors.has(target_id):
			continue
		var actor: Dictionary = simulation.state.combat.actors[target_id]
		actor["shield_hp"] = maxi(int(actor["shield_hp"]), int(effect["primitive_value"]))
		var entity: EntityRecord = simulation.state.entities[target_id]
		match str(effect.get("dispel_class", "none")):
			"ordinary_magical": entity.integer_attributes["shield_dispel_class_code"] = 1
			"undispellable": entity.integer_attributes["shield_dispel_class_code"] = 2
			_: entity.integer_attributes["shield_dispel_class_code"] = 0
		var duration := _duration(effect)
		if duration > 0:
			entity.integer_attributes["shield_expiry_tick"] = maxi(
				int(entity.integer_attributes.get("shield_expiry_tick", 0)),
				simulation.state.tick + duration
			)
		count += 1
	return {"ok": true, "target_count": count}


func _apply_status(
	simulation: Variant, effect: Dictionary, targets: Array, duration_ticks: int
) -> Dictionary:
	var duration := maxi(1, duration_ticks)
	var kind := _status_kind(str(effect["effect_kind"]))
	var base_stacking_key := str(effect.get("status_stacking_key", effect["ability_id"]))
	var stacking_key := "%s::%s" % [base_stacking_key, str(effect["effect_kind"])]
	var magnitude := int(effect["primitive_value"])
	if str(effect["effect_kind"]) == "attack_cooldown_bp":
		kind = "attack_speed_bp"
		magnitude = -magnitude
	var count := 0
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.combat.actors.has(target_id):
			continue
		var receipt: Dictionary = simulation.combat.add_status(
			simulation.state, target_id, int(effect["source_id"]), kind,
			stacking_key, magnitude, duration,
			str(effect.get("dispel_class", "ordinary_magical"))
		)
		if bool(receipt.get("accepted", false)):
			var status_id := int(receipt.get("status_id", 0))
			if simulation.state.combat.statuses.has(status_id):
				simulation.state.combat.statuses[status_id]["ability_id"] = str(
					effect["ability_id"]
				)
				simulation.state.combat.statuses[status_id]["effect_kind"] = str(
					effect["effect_kind"]
				)
			if str(effect["effect_kind"]) in [
				"force_air_to_ground_and_root", "force_ground_immobile",
			]:
				var entity: EntityRecord = simulation.state.entities[target_id]
				var prefix := "toggle_base_%s_" % str(effect["ability_id"])
				_save_toggle_text(
					entity, prefix + "layer",
					str(simulation.state.combat.actors[target_id].get("layer", "ground"))
				)
				_set_actor_layer(simulation, target_id, "ground")
				_set_transform_expiry(
					entity, str(effect["ability_id"]), simulation.state.tick + duration
				)
			count += 1
	return {"ok": true, "target_count": count}


func _remove_statuses(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var target_set: Dictionary = {}
	for target_variant: Variant in targets:
		target_set[int(target_variant)] = true
	var stacking_key := str(effect.get("status_stacking_key", ""))
	var removed := 0
	var ids: Array = simulation.state.combat.statuses.keys()
	ids.sort()
	for id_variant: Variant in ids:
		var status_id := int(id_variant)
		var status: Dictionary = simulation.state.combat.statuses[status_id]
		if target_set.has(int(status["target_id"])) \
			and (
				stacking_key.is_empty()
				or str(status["stacking_key"]) == stacking_key
				or str(status["stacking_key"]).begins_with(stacking_key + "::")
			):
			simulation.state.combat.statuses.erase(status_id)
			removed += 1
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		_restore_toggle_transform(simulation, target_id, str(effect.get("ability_id", "")))
		if simulation.state.entities.has(target_id):
			simulation.state.entities[target_id].integer_attributes.erase(
				TRANSFORM_EXPIRY_PREFIX + str(effect.get("ability_id", ""))
			)
	return {"ok": true, "target_count": removed}


func _dispel(simulation: Variant, targets: Array) -> Dictionary:
	var target_set: Dictionary = {}
	var transforms_to_restore: Dictionary = {}
	for target_variant: Variant in targets:
		target_set[int(target_variant)] = true
	var removed := 0
	var ids: Array = simulation.state.combat.statuses.keys()
	ids.sort()
	for id_variant: Variant in ids:
		var status_id := int(id_variant)
		var status: Dictionary = simulation.state.combat.statuses[status_id]
		if target_set.has(int(status["target_id"])) \
			and str(status.get("dispel_class", "ordinary_magical")) == "ordinary_magical":
			var target_id := int(status["target_id"])
			var effect_kind := str(status.get("effect_kind", ""))
			if effect_kind in ["force_air_to_ground_and_root", "force_ground_immobile"]:
				transforms_to_restore["%d:%s" % [
					target_id, str(status.get("ability_id", "")),
				]] = {
					"ability_id": str(status.get("ability_id", "")),
					"target_id": target_id,
				}
			simulation.state.combat.statuses.erase(status_id)
			removed += 1
	var restore_keys: Array = transforms_to_restore.keys()
	restore_keys.sort()
	for key_variant: Variant in restore_keys:
		var descriptor: Dictionary = transforms_to_restore[key_variant]
		_restore_toggle_transform(
			simulation, int(descriptor["target_id"]), str(descriptor["ability_id"])
		)
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.entities.has(target_id) \
			or not simulation.state.combat.actors.has(target_id):
			continue
		var entity: EntityRecord = simulation.state.entities[target_id]
		if int(entity.integer_attributes.get("shield_dispel_class_code", 0)) != 1:
			continue
		simulation.state.combat.actors[target_id]["shield_hp"] = 0
		entity.integer_attributes.erase("shield_dispel_class_code")
		entity.integer_attributes.erase("shield_expiry_tick")
		removed += 1
	return {"ok": true, "target_count": removed}


func _dash(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var source_id := int(effect["source_id"])
	if not simulation.state.entities.has(source_id):
		return {"code": "invalid_source", "ok": false}
	var entity: EntityRecord = simulation.state.entities[source_id]
	var target_position := _target_position(simulation, effect.get("target", {}))
	if target_position.is_empty():
		return {"code": "invalid_target", "ok": false}
	var max_distance := maxi(0, int(effect["primitive_value"]))
	var dx := int(target_position[0]) - entity.position_x_mt
	var dy := int(target_position[1]) - entity.position_y_mt
	var distance := _integer_sqrt(dx * dx + dy * dy)
	if distance <= 0:
		return {"ok": true, "target_count": 1}
	var travel := mini(distance, max_distance)
	var next_x := entity.position_x_mt + dx * travel / distance
	var next_y := entity.position_y_mt + dy * travel / distance
	var actor: Dictionary = simulation.state.movement.actors.get(source_id, {})
	if actor.is_empty():
		return {"code": "movement_actor_missing", "ok": false}
	if str(actor.get("layer", "ground")) == "ground":
		var previous_cells: Array[int] = simulation.grid.ground_cells_for_actor(source_id)
		simulation.grid.release_ground_actor(source_id)
		if not simulation.grid.reserve_ground_actor(source_id, next_x, next_y, entity.radius_mt):
			simulation.grid.reserve_ground_actor_cells(source_id, previous_cells)
			return {"code": "invalid_placement", "ok": false}
		actor["occupied_cells"] = simulation.grid.ground_cells_for_actor(source_id)
	else:
		var previous_cells: Array = actor.get("occupied_cells", []).duplicate()
		var previous_slot := int(actor.get("altitude_slot", -1))
		_release_air_actor(simulation, source_id)
		var next_cells: Array = simulation.grid.footprint_cells_for_center_mt(
			next_x, next_y, entity.radius_mt
		)
		var next_slot := _reserve_air_actor(simulation, source_id, next_cells)
		if next_slot < 0:
			_reserve_air_actor_at_slot(simulation, source_id, previous_cells, previous_slot)
			return {"code": "invalid_placement", "ok": false}
		actor["altitude_slot"] = next_slot
		actor["occupied_cells"] = next_cells
	entity.set_position_mt(next_x, next_y)
	actor["segment_origin_x_mt"] = next_x
	actor["segment_origin_y_mt"] = next_y
	return {"ok": true, "target_count": maxi(1, targets.size())}


func _summon(simulation: Variant, effect: Dictionary) -> Dictionary:
	var kind := str(effect["effect_kind"])
	var summon_type := str(SUMMON_EFFECTS.get(kind, ""))
	if kind == "create_illusions":
		summon_type = "illusion"
	if summon_type.is_empty():
		return {"code": "unknown_summon", "ok": false}
	var count := maxi(0, int(effect["primitive_value"]))
	var spawned: Array[int] = []
	for index: int in count:
		var entity_id := _spawn_one(simulation, effect, summon_type, index)
		if entity_id > 0:
			spawned.append(entity_id)
	var existing: Array[int] = []
	existing.assign(_spawned_by_cast.get(int(effect.get("cast_id", 0)), []))
	existing.append_array(spawned)
	_spawned_by_cast[int(effect.get("cast_id", 0))] = existing
	return {"ok": true, "target_count": spawned.size()}


func _spawn_one(
	simulation: Variant, effect: Dictionary, summon_type: String, summon_index: int
) -> int:
	var source_id := int(effect["source_id"])
	if not simulation.state.entities.has(source_id):
		return 0
	var source: EntityRecord = simulation.state.entities[source_id]
	var definition: Dictionary = {}
	if summon_type == "illusion":
		definition = _illusion_definition(simulation, source_id)
	else:
		definition = (faction_catalog.get("summoned_entities", {}) as Dictionary).get(
			summon_type, {}
		).duplicate(true)
	if definition.is_empty() and summon_type == "invisible_trap":
		definition = {
			"armor_centi": 0, "armor_class": "light", "hp": 1, "mana": 0,
			"radius_mt": 350, "speed_mt_per_tick": 0,
			"tags": ["ground", "immobile", "invisible", "summon", "trap"],
		}
	if definition.is_empty():
		return 0
	var origin := _target_position(simulation, effect.get("target", {}))
	if origin.is_empty():
		origin = [source.position_x_mt, source.position_y_mt]
	var radius := int(definition.get("radius_mt", 350))
	var position := _summon_position(simulation, origin, radius, summon_index)
	if position.is_empty():
		return 0
	var entity_id: int = simulation.state.next_entity_id
	var entity := EntityRecord.new(entity_id, source.owner_seat, "summon")
	entity.public_id = "e_summon_%08d" % entity_id
	entity.catalog_id = source.catalog_id if summon_type == "illusion" else summon_type
	entity.set_position_mt(int(position[0]), int(position[1]))
	entity.max_hp = int(definition.get("hp", source.max_hp))
	entity.hp = entity.max_hp
	entity.max_mana = int(definition.get("mana", 0))
	entity.mana = entity.max_mana
	entity.radius_mt = radius
	for tag_variant: Variant in definition.get("tags", []):
		var tag := str(tag_variant)
		if tag not in entity.tags:
			entity.tags.append(tag)
	for required: String in ["summon", "illusion" if summon_type == "illusion" else ""]:
		if not required.is_empty() and required not in entity.tags:
			entity.tags.append(required)
	entity.tags.sort()
	entity.integer_attributes = {
		"summon_expiry_tick": simulation.state.tick + maxi(
			1, int(effect.get("resolved_duration_ticks", definition.get("duration_ticks", 1)))
		),
		"summon_source_id": source_id,
		"xp_bounty": int(definition.get("xp_bounty", 0)),
	}
	for attribute: String in [
		"detection_radius_mt", "healing_per_tick", "healing_radius_mt",
		"sight_day_mt", "sight_night_mt",
	]:
		if definition.has(attribute):
			entity.integer_attributes[attribute] = int(definition[attribute])
	if simulation.add_entity(entity, true) != entity_id:
		return 0
	var profile := {
		"armor_centi": int(definition.get("armor_centi", 0)),
		"armor_class": str(definition.get("armor_class", "light")),
		"attack": definition.get("attack", _disabled_attack()).duplicate(true),
		"layer": "air" if "air" in entity.tags else "ground",
		"radius_mt": radius,
		"speed_mt_per_tick": int(definition.get("speed_mt_per_tick", 0)),
		"tags": entity.tags.duplicate(),
	}
	var profile_key := "illusion_%s" % source.catalog_id if summon_type == "illusion" else summon_type
	var errors: PackedStringArray = simulation.register_external_mobile_combat_entity(
		entity_id, "summon", profile_key, profile
	)
	if not errors.is_empty():
		_remove_entity_authority(simulation, entity_id)
		return 0
	return entity_id


func _corpse(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var kind := str(effect["effect_kind"])
	var count := 0
	if kind == "consume_corpse":
		for target_variant: Variant in targets:
			var target_id := int(target_variant)
			if simulation.state.entities.has(target_id) \
				and "corpse" in simulation.state.entities[target_id].tags:
				_remove_entity_authority(simulation, target_id)
				count += 1
	elif kind == "create_generic_corpse":
		var source_id := int(effect["source_id"])
		if not simulation.state.entities.has(source_id):
			return {"code": "invalid_source", "ok": false}
		var stored := int(simulation.state.entities[source_id].integer_attributes.get(
			"stored_corpses", 0
		))
		if stored <= 0:
			return {"ok": true, "target_count": 0}
		var position := _target_position(simulation, effect.get("target", {}))
		if not position.is_empty():
			var entity_id: int = simulation.state.next_entity_id
			var corpse := EntityRecord.new(entity_id, -1, "corpse")
			corpse.public_id = "e_corpse_%08d" % entity_id
			corpse.catalog_id = "generic_corpse"
			corpse.set_position_mt(int(position[0]), int(position[1]))
			corpse.hp = 0
			corpse.max_hp = 1
			corpse.alive = false
			corpse.radius_mt = 0
			corpse.tags = ["corpse"]
			corpse.integer_attributes["corpse_expiry_tick"] = (
				simulation.state.tick + maxi(1, _duration(effect))
			)
			if simulation.add_entity(corpse, false) == entity_id:
				simulation.state.entities[source_id].integer_attributes["stored_corpses"] = (
					stored - 1
				)
				count = 1
	return {"ok": true, "target_count": count}


func _storage(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var source_id := int(effect["source_id"])
	if not simulation.state.entities.has(source_id):
		return {"code": "invalid_source", "ok": false}
	var source: EntityRecord = simulation.state.entities[source_id]
	var kind := str(effect["effect_kind"])
	if kind == "capacity":
		source.integer_attributes["corpse_storage_capacity"] = int(effect["primitive_value"])
	elif kind == "store_corpse" and not targets.is_empty():
		var current := int(source.integer_attributes.get("stored_corpses", 0))
		var capacity := int(source.integer_attributes.get("corpse_storage_capacity", 0))
		if capacity <= 0:
			capacity = _declared_storage_capacity(effect)
			if capacity > 0:
				source.integer_attributes["corpse_storage_capacity"] = capacity
		var target_id := int(targets[0])
		if current < capacity and simulation.state.entities.has(target_id) \
			and "corpse" in simulation.state.entities[target_id].tags:
			source.integer_attributes["stored_corpses"] = current + 1
			_remove_entity_authority(simulation, target_id)
			return {"ok": true, "target_count": 1}
		return {"ok": true, "target_count": 0}
	return {"ok": true, "target_count": targets.size()}


func _transform(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var count := 0
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if not simulation.state.entities.has(target_id) \
			or not simulation.state.combat.actors.has(target_id):
			continue
		var entity: EntityRecord = simulation.state.entities[target_id]
		var prefix := "toggle_base_%s_" % str(effect["ability_id"])
		var kind := str(effect["effect_kind"])
		var value := int(effect["primitive_value"])
		match kind:
			"set_max_hp_preserve_percentage":
				_save_toggle_base(entity, prefix + "max_hp", entity.max_hp)
				_set_max_hp_preserving_ratio(entity, value)
			"temporary_max_hp_flat_preserve_percentage":
				_apply_status(simulation, effect, [target_id], _duration(effect))
			"set_armor_centi":
				_save_toggle_base(entity, prefix + "armor_centi", int(simulation.state.combat.actors[target_id]["armor_centi"]))
				simulation.state.combat.actors[target_id]["armor_centi"] = value
			"set_armor_class_fortified", "set_armor_class_heavy":
				_save_toggle_text(entity, prefix + "armor_class", str(simulation.state.combat.actors[target_id]["armor_class"]))
				simulation.state.combat.actors[target_id]["armor_class"] = (
					"fortified" if kind.ends_with("fortified") else "heavy"
				)
			"set_attack_cooldown_ticks":
				_save_toggle_base(entity, prefix + "attack_cooldown_ticks", int(simulation.state.combat.actors[target_id]["attack"]["cooldown_ticks"]))
				simulation.state.combat.actors[target_id]["attack"]["cooldown_ticks"] = value
			"set_attack_damage":
				_save_toggle_base(entity, prefix + "attack_damage", int(simulation.state.combat.actors[target_id]["attack"]["damage"]))
				simulation.state.combat.actors[target_id]["attack"]["damage"] = value
			"set_speed_mt_per_second":
				if not simulation.state.movement.actors.has(target_id):
					continue
				_save_toggle_base(entity, prefix + "speed_mt_per_tick", int(simulation.state.movement.actors[target_id]["speed_mt_per_tick"]))
				simulation.state.movement.actors[target_id]["speed_mt_per_tick"] = value / 10
			"set_flying":
				if not simulation.state.movement.actors.has(target_id):
					continue
				_save_toggle_text(entity, prefix + "layer", str(simulation.state.combat.actors[target_id]["layer"]))
				if not _set_actor_layer(simulation, target_id, "air"):
					continue
			"transform_militia":
				var militia: Dictionary = (faction_catalog.get(
					"faction_rules", {}
				) as Dictionary).get("call_to_arms", {})
				if militia.is_empty():
					continue
				_save_toggle_base(entity, prefix + "max_hp", entity.max_hp)
				_save_toggle_base(
					entity, prefix + "armor_centi",
					int(simulation.state.combat.actors[target_id]["armor_centi"])
				)
				_save_toggle_base(
					entity, prefix + "attack_damage",
					int(simulation.state.combat.actors[target_id]["attack"]["damage"])
				)
				_save_toggle_base(
					entity, prefix + "attack_cooldown_ticks",
					int(simulation.state.combat.actors[target_id]["attack"]["cooldown_ticks"])
				)
				_save_toggle_base(
					entity, prefix + "attack_enabled",
					1 if bool(simulation.state.combat.actors[target_id]["attack"]["enabled"]) else 0
				)
				_set_max_hp_preserving_ratio(entity, int(militia["militia_hp"]))
				simulation.state.combat.actors[target_id]["armor_centi"] = int(
					militia["militia_armor_centi"]
				)
				simulation.state.combat.actors[target_id]["attack"]["damage"] = int(
					militia["militia_attack_damage"]
				)
				simulation.state.combat.actors[target_id]["attack"]["cooldown_ticks"] = int(
					militia["militia_attack_cooldown_ticks"]
				)
				simulation.state.combat.actors[target_id]["attack"]["enabled"] = true
				entity.integer_attributes["militia_until_tick"] = simulation.state.tick + maxi(1, _duration(effect))
				if "militia" not in entity.tags:
					entity.tags.append("militia")
					entity.tags.sort()
			"transform_attack_tower":
				entity.integer_attributes["attack_tower_upgraded"] = 1
			"transform_rooted_ancient":
				entity.integer_attributes["ancient_rooted"] = 1
			"transform_uprooted_ancient":
				entity.integer_attributes["ancient_rooted"] = 0
			"temporary_max_hp_bp":
				_apply_status(simulation, effect, [target_id], _duration(effect))
		if int(effect.get("resolved_duration_ticks", 0)) > 0 \
			and kind not in [
				"temporary_max_hp_bp", "temporary_max_hp_flat_preserve_percentage",
			]:
			_set_transform_expiry(
				entity, str(effect["ability_id"]),
				simulation.state.tick + int(effect["resolved_duration_ticks"])
			)
		count += 1
	return {"ok": true, "target_count": count}


func _force_night(simulation: Variant, effect: Dictionary) -> Dictionary:
	if not simulation.state.neutrals.enabled:
		return {"code": "neutral_clock_unavailable", "ok": false}
	var duration := maxi(1, _duration(effect))
	var effect_id := "ability_night_%08d" % int(effect["effect_id"])
	var errors: PackedStringArray = simulation.neutrals.add_forced_night(
		effect_id, simulation.state.tick, simulation.state.tick + duration
	)
	return {"code": "accepted", "ok": errors.is_empty(), "target_count": 0}


func _world_zone(simulation: Variant, abilities: Variant, effect: Dictionary) -> Dictionary:
	var source_id := int(effect["source_id"])
	if not simulation.state.entities.has(source_id):
		return {"code": "invalid_source", "ok": false}
	var ability: Dictionary = abilities.ability_definition(str(effect["ability_id"]))
	simulation.state.entities[source_id].integer_attributes["owned_blight_radius_mt"] = int(
		ability.get("area_radius_mt", 0)
	)
	return {"ok": true, "target_count": 1}


func _world_edit(simulation: Variant, effect: Dictionary) -> Dictionary:
	## Terrain destruction is represented as a deterministic, public change
	## marker. The authored navigation cells remain authoritative and immutable.
	var source_id := int(effect["source_id"])
	if simulation.state.entities.has(source_id):
		simulation.state.entities[source_id].integer_attributes["tree_destruction_tick"] = (
			simulation.state.tick
		)
	return {"ok": true, "target_count": 0}


func _lifecycle(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	if str(effect["effect_kind"]) == "destroy_caster":
		for target_variant: Variant in targets:
			var target_id := int(target_variant)
			if simulation.state.entities.has(target_id):
				simulation.state.entities[target_id].hp = 0
	return {"ok": true, "target_count": targets.size()}


func _revival(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var revived := 0
	var kind := str(effect["effect_kind"])
	if kind == "return_hp_bp":
		for target_variant: Variant in targets:
			var target_id := int(target_variant)
			if not simulation.state.entities.has(target_id):
				continue
			var target: EntityRecord = simulation.state.entities[target_id]
			if target.alive:
				target.hp = clampi(
					maxi(1, target.max_hp * maxi(0, int(effect["primitive_value"])) / BP_ONE),
					1, target.max_hp
				)
				revived += 1
		return {"ok": true, "target_count": revived}
	if kind != "revive_most_expensive_corpses":
		return _apply_status(simulation, effect, targets, _duration(effect))
	var candidates: Array[int] = []
	var revived_ids: Array[int] = []
	for target_variant: Variant in targets:
		var target_id := int(target_variant)
		if simulation.state.entities.has(target_id) \
			and "corpse" in simulation.state.entities[target_id].tags:
			candidates.append(target_id)
	candidates.sort_custom(func(a: int, b: int) -> bool:
		var av := int(simulation.state.entities[a].integer_attributes.get("gold_value", 0))
		var bv := int(simulation.state.entities[b].integer_attributes.get("gold_value", 0))
		return a < b if av == bv else av > bv
	)
	for index: int in mini(int(effect["primitive_value"]), candidates.size()):
		var entity: EntityRecord = simulation.state.entities[candidates[index]]
		if not _reserve_revival_position(simulation, entity):
			continue
		entity.alive = true
		entity.hp = 1
		entity.tags.erase("corpse")
		revived += 1
		revived_ids.append(entity.internal_id)
	_spawned_by_cast[int(effect.get("cast_id", 0))] = revived_ids
	return {"ok": true, "target_count": revived}


func _transport(simulation: Variant, effect: Dictionary, targets: Array) -> Dictionary:
	var source_id := int(effect["source_id"])
	var transported := 0
	if simulation.state.entities.has(source_id):
		var limit := maxi(0, int(effect["primitive_value"]))
		for target_variant: Variant in targets:
			if transported >= limit:
				break
			var target_id := int(target_variant)
			if not simulation.state.entities.has(target_id) \
				or not simulation.state.combat.actors.has(target_id):
				continue
			simulation.state.combat.actors[target_id]["transported"] = true
			simulation.grid.release_ground_actor(target_id)
			if simulation.state.movement.actors.has(target_id):
				var movement_actor: Dictionary = simulation.state.movement.actors[target_id]
				var target: EntityRecord = simulation.state.entities[target_id]
				target.integer_attributes["transport_base_speed_mt_per_tick"] = int(
					movement_actor.get("speed_mt_per_tick", 0)
				)
				movement_actor["speed_mt_per_tick"] = 0
				movement_actor["occupied_cells"] = []
			transported += 1
		simulation.state.entities[source_id].integer_attributes["garrisoned_workers"] = (
			int(simulation.state.entities[source_id].integer_attributes.get("garrisoned_workers", 0))
			+ transported
		)
	return {"ok": true, "target_count": transported}


func _effect_targets(simulation: Variant, effect: Dictionary) -> Array:
	var result: Array[int] = []
	for value: Variant in effect.get("selected_target_ids", []):
		var target_id := int(value)
		if target_id > 0 and simulation.state.entities.has(target_id) and target_id not in result:
			result.append(target_id)
	if result.is_empty():
		var target_id := int((effect.get("target", {}) as Dictionary).get("entity_id", 0))
		if target_id > 0 and simulation.state.entities.has(target_id):
			result.append(target_id)
	result.sort()
	return result


func _persistent_targets(simulation: Variant, abilities: Variant, effect: Dictionary) -> Array:
	var ability: Dictionary = abilities.ability_definition(str(effect["ability_id"]))
	var source_id := int(effect["source_id"])
	if not simulation.state.entities.has(source_id):
		return []
	var source: EntityRecord = simulation.state.entities[source_id]
	var radius := int(ability.get("area_radius_mt", 0))
	if radius <= 0 or str(ability.get("target_kind", "")) == "self":
		return [source_id]
	var result: Array[int] = []
	for target_id: int in simulation.state.sorted_entity_ids():
		var target: EntityRecord = simulation.state.entities[target_id]
		if not target.alive or target.hp <= 0:
			continue
		var dx := target.position_x_mt - source.position_x_mt
		var dy := target.position_y_mt - source.position_y_mt
		if dx * dx + dy * dy > radius * radius:
			continue
		if not _persistent_target_tags_match(simulation, source, target, ability):
			continue
		result.append(target_id)
	return result


func _persistent_target_tags_match(
	simulation: Variant, source: EntityRecord, target: EntityRecord, ability: Dictionary
) -> bool:
	var facts: Dictionary = {}
	for tag: String in target.tags:
		facts[tag] = true
	if target.owner_seat == source.owner_seat:
		facts["owned"] = true
	elif target.owner_seat >= 0:
		facts["hostile"] = true
	if simulation.state.combat.actors.has(target.internal_id):
		var actor: Dictionary = simulation.state.combat.actors[target.internal_id]
		if bool(actor.get("visible", true)):
			facts["visible"] = true
		var attack: Dictionary = actor.get("attack", {})
		if bool(attack.get("enabled", false)) and str(attack.get("attack_type", "")) != "spell":
			facts["physical_attack"] = true
			if int(attack.get("attack_range_mt", 0)) > 1000:
				facts["physical_ranged"] = true
	if selected_faction_id == "warhost-v1":
		facts["warhost"] = true
	for required: Variant in ability.get("required_target_tags", []):
		if not facts.has(str(required)):
			return false
	for forbidden: Variant in ability.get("forbidden_target_tags", []):
		if facts.has(str(forbidden)):
			return false
	return true


func _status_kind(effect_kind: String) -> String:
	match effect_kind:
		"disable", "disable_structures":
			return "stun"
		"disable_attack", "disable_structure_attack_and_production":
			return "disable_attack"
		"force_air_to_ground_and_root", "force_ground_immobile", "root", \
		"root_first_enemy", "root_hostile", "root_or_force_ground":
			return "root"
		"temporary_max_hp_flat_preserve_percentage":
			return "temporary_max_hp_flat"
	return effect_kind


func _duration(effect: Dictionary) -> int:
	return maxi(1, int(effect.get("resolved_duration_ticks", 1)))


func _declared_storage_capacity(effect: Dictionary) -> int:
	var ability: Dictionary = (faction_catalog.get("abilities", {}) as Dictionary).get(
		str(effect.get("ability_id", "")), {}
	)
	var rank := maxi(1, int(effect.get("rank", 1)))
	for descriptor_variant: Variant in ability.get("effects", []):
		var descriptor: Dictionary = descriptor_variant
		if str(descriptor.get("kind", "")) != "capacity":
			continue
		var values: Array = descriptor.get("values", [])
		if values.is_empty():
			return 0
		return maxi(0, int(values[clampi(rank - 1, 0, values.size() - 1)]))
	return 0


func _on_owned_blight(simulation: Variant, entity: EntityRecord) -> bool:
	for source_id: int in simulation.state.sorted_entity_ids():
		var source: EntityRecord = simulation.state.entities[source_id]
		var radius := int(source.integer_attributes.get("owned_blight_radius_mt", 0))
		if radius <= 0 or not source.alive or source.owner_seat != entity.owner_seat:
			continue
		var dx := entity.position_x_mt - source.position_x_mt
		var dy := entity.position_y_mt - source.position_y_mt
		if dx * dx + dy * dy <= radius * radius:
			return true
	return false


func _mending_ward_sources(simulation: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source_id: int in simulation.state.sorted_entity_ids():
		var source: EntityRecord = simulation.state.entities[source_id]
		if not source.alive or source.hp <= 0:
			continue
		var healing := maxi(0, int(source.integer_attributes.get("healing_per_tick", 0)))
		var radius := maxi(0, int(source.integer_attributes.get("healing_radius_mt", 0)))
		if healing <= 0 or radius <= 0:
			continue
		result.append({
			"healing": healing,
			"owner_seat": source.owner_seat,
			"radius_squared": radius * radius,
			"x_mt": source.position_x_mt,
			"y_mt": source.position_y_mt,
		})
	return result


func _mending_ward_healing(entity: EntityRecord, wards: Array[Dictionary]) -> int:
	var amount := 0
	for ward: Dictionary in wards:
		if int(ward["owner_seat"]) != entity.owner_seat:
			continue
		var dx := entity.position_x_mt - int(ward["x_mt"])
		var dy := entity.position_y_mt - int(ward["y_mt"])
		if dx * dx + dy * dy <= int(ward["radius_squared"]):
			amount += int(ward["healing"])
	return amount


func _hero_regeneration_bonus(
	simulation: Variant, entity: EntityRecord, modifiers: Dictionary
) -> int:
	var bonus_bp := maxi(0, int(modifiers.get("hp_regeneration_bp", 0)))
	if bonus_bp <= 0 or not simulation.state.heroes.heroes.has(entity.internal_id):
		return 0
	var hero: Dictionary = simulation.state.heroes.heroes[entity.internal_id]
	var base_per_100_ticks := maxi(0, int((hero.get("derived", {}) as Dictionary).get(
		"hp_regen_per_100_ticks", 0
	)))
	var accumulator := int(entity.integer_attributes.get(
		"hero_hp_regen_bonus_accumulator", 0
	)) + base_per_100_ticks * bonus_bp
	var denominator := 100 * BP_ONE
	@warning_ignore("integer_division")
	var amount := accumulator / denominator
	entity.integer_attributes["hero_hp_regen_bonus_accumulator"] = accumulator % denominator
	return amount


func _recompute_temporary_max_hp(simulation: Variant) -> void:
	var status_totals := _status_totals_by_target(simulation.state)
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		var modifiers: Dictionary = status_totals.get(entity_id, {})
		var flat := int(modifiers.get("temporary_max_hp_flat", 0))
		var bp := int(modifiers.get("temporary_max_hp_bp", 0))
		var has_modifier := flat != 0 or bp != 0
		if not has_modifier and not entity.integer_attributes.has("ability_base_max_hp"):
			continue
		var base := int(entity.integer_attributes.get("ability_base_max_hp", entity.max_hp))
		if has_modifier:
			entity.integer_attributes["ability_base_max_hp"] = base
		var next_max := maxi(1, base + flat + base * bp / BP_ONE) if has_modifier else base
		if next_max != entity.max_hp:
			var old_max := maxi(1, entity.max_hp)
			entity.hp = clampi(entity.hp * next_max / old_max, 0, next_max)
			entity.max_hp = next_max
		if not has_modifier:
			entity.integer_attributes.erase("ability_base_max_hp")


func _set_max_hp_preserving_ratio(entity: EntityRecord, next_max: int) -> void:
	var old_max := maxi(1, entity.max_hp)
	entity.max_hp = maxi(1, next_max)
	entity.hp = clampi(entity.hp * entity.max_hp / old_max, 0, entity.max_hp)


func _restore_toggle_transform(simulation: Variant, entity_id: int, ability_id: String) -> void:
	if not simulation.state.entities.has(entity_id):
		return
	var entity: EntityRecord = simulation.state.entities[entity_id]
	var prefix := "toggle_base_%s_" % ability_id
	for suffix: String in [
		"armor_centi", "attack_cooldown_ticks", "attack_damage", "attack_enabled", "max_hp",
		"speed_mt_per_tick",
	]:
		var key := prefix + suffix
		if not entity.integer_attributes.has(key):
			continue
		var value := int(entity.integer_attributes[key])
		match suffix:
			"armor_centi":
				if simulation.state.combat.actors.has(entity_id):
					simulation.state.combat.actors[entity_id]["armor_centi"] = value
			"attack_cooldown_ticks":
				if simulation.state.combat.actors.has(entity_id):
					simulation.state.combat.actors[entity_id]["attack"]["cooldown_ticks"] = value
			"attack_damage":
				if simulation.state.combat.actors.has(entity_id):
					simulation.state.combat.actors[entity_id]["attack"]["damage"] = value
			"attack_enabled":
				if simulation.state.combat.actors.has(entity_id):
					simulation.state.combat.actors[entity_id]["attack"]["enabled"] = value != 0
			"max_hp":
				if entity.integer_attributes.has("ability_base_max_hp"):
					entity.integer_attributes["ability_base_max_hp"] = value
				else:
					_set_max_hp_preserving_ratio(entity, value)
			"speed_mt_per_tick":
				if simulation.state.movement.actors.has(entity_id):
					simulation.state.movement.actors[entity_id]["speed_mt_per_tick"] = value
		entity.integer_attributes.erase(key)
	var armor_key := prefix + "armor_class"
	if entity.integer_attributes.has(armor_key + "_code") \
		and simulation.state.combat.actors.has(entity_id):
		simulation.state.combat.actors[entity_id]["armor_class"] = _decode_text(
			int(entity.integer_attributes[armor_key + "_code"])
		)
		entity.integer_attributes.erase(armor_key + "_code")
	var layer_key := prefix + "layer"
	if entity.integer_attributes.has(layer_key + "_code"):
		var layer := _decode_text(int(entity.integer_attributes[layer_key + "_code"]))
		_set_actor_layer(simulation, entity_id, layer)
		entity.integer_attributes.erase(layer_key + "_code")
	if ability_id == "call_to_arms":
		entity.integer_attributes.erase("militia_until_tick")
		entity.tags.erase("militia")


func _set_transform_expiry(entity: EntityRecord, ability_id: String, expiry_tick: int) -> void:
	var key := TRANSFORM_EXPIRY_PREFIX + ability_id
	entity.integer_attributes[key] = maxi(
		int(entity.integer_attributes.get(key, 0)), expiry_tick
	)


func _set_actor_layer(simulation: Variant, entity_id: int, next_layer: String) -> bool:
	if next_layer not in ["air", "ground"] \
		or not simulation.state.entities.has(entity_id) \
		or not simulation.state.combat.actors.has(entity_id) \
		or not simulation.state.movement.actors.has(entity_id):
		return false
	var entity: EntityRecord = simulation.state.entities[entity_id]
	var movement_actor: Dictionary = simulation.state.movement.actors[entity_id]
	var current_layer := str(movement_actor.get("layer", "ground"))
	if current_layer == next_layer:
		return true
	if current_layer == "ground":
		simulation.grid.release_ground_actor(entity_id)
	else:
		_release_air_actor(simulation, entity_id)
	var occupied: Array = simulation.grid.footprint_cells_for_center_mt(
		entity.position_x_mt, entity.position_y_mt, entity.radius_mt
	)
	if next_layer == "air":
		var altitude_slot := _reserve_air_actor(simulation, entity_id, occupied)
		if altitude_slot < 0:
			simulation.grid.reserve_ground_actor(
				entity_id, entity.position_x_mt, entity.position_y_mt, entity.radius_mt
			)
			return false
		movement_actor["altitude_slot"] = altitude_slot
	else:
		var position: Array = [entity.position_x_mt, entity.position_y_mt]
		if not simulation.grid.fits_ground_footprint_at_position(
			entity.position_x_mt, entity.position_y_mt, entity.radius_mt
		):
			position = _summon_position(
				simulation, position, entity.radius_mt, entity_id % 9
			)
		if position.is_empty():
			_reserve_air_actor(simulation, entity_id, occupied)
			return false
		entity.set_position_mt(int(position[0]), int(position[1]))
		occupied = simulation.grid.footprint_cells_for_center_mt(
			entity.position_x_mt, entity.position_y_mt, entity.radius_mt
		)
		if not simulation.grid.reserve_ground_actor(
			entity_id, entity.position_x_mt, entity.position_y_mt, entity.radius_mt
		):
			_reserve_air_actor(simulation, entity_id, occupied)
			return false
		movement_actor["altitude_slot"] = -1
	movement_actor["layer"] = next_layer
	movement_actor["occupied_cells"] = occupied
	simulation.state.combat.actors[entity_id]["layer"] = next_layer
	return true


func _reserve_air_actor(simulation: Variant, entity_id: int, cells: Array) -> int:
	if cells.is_empty():
		return -1
	for node_variant: Variant in cells:
		var cell: Vector2i = simulation.grid.cell_from_node_id(int(node_variant))
		if not simulation.grid.is_air_pathable(cell.x, cell.y):
			return -1
	for slot: int in range(0, 4):
		if _reserve_air_actor_at_slot(simulation, entity_id, cells, slot):
			return slot
	return -1


func _reserve_air_actor_at_slot(
	simulation: Variant, entity_id: int, cells: Array, slot: int
) -> bool:
	if slot < 0 or slot > 3 or cells.is_empty():
		return false
	for node_variant: Variant in cells:
		var node_id := int(node_variant)
		var cell: Vector2i = simulation.grid.cell_from_node_id(node_id)
		if not simulation.grid.is_air_pathable(cell.x, cell.y):
			return false
		var lanes: Dictionary = simulation.state.movement.air_occupancy.get(node_id, {})
		if lanes.has(slot) and int(lanes[slot]) != entity_id:
			return false
	for node_variant: Variant in cells:
		var node_id := int(node_variant)
		var lanes: Dictionary = simulation.state.movement.air_occupancy.get(
			node_id, {}
		).duplicate()
		lanes[slot] = entity_id
		simulation.state.movement.air_occupancy[node_id] = lanes
	return true


func _release_air_actor(simulation: Variant, entity_id: int) -> void:
	var node_ids: Array = simulation.state.movement.air_occupancy.keys()
	node_ids.sort()
	for node_variant: Variant in node_ids:
		var node_id := int(node_variant)
		var lanes: Dictionary = simulation.state.movement.air_occupancy[node_variant].duplicate()
		for slot_variant: Variant in lanes.keys().duplicate():
			if int(lanes[slot_variant]) == entity_id:
				lanes.erase(slot_variant)
		if lanes.is_empty():
			simulation.state.movement.air_occupancy.erase(node_variant)
		else:
			simulation.state.movement.air_occupancy[node_id] = lanes


func _reserve_revival_position(simulation: Variant, entity: EntityRecord) -> bool:
	if not simulation.state.movement.actors.has(entity.internal_id):
		return true
	var actor: Dictionary = simulation.state.movement.actors[entity.internal_id]
	if str(actor.get("layer", "ground")) == "air":
		var cells: Array = simulation.grid.footprint_cells_for_center_mt(
			entity.position_x_mt, entity.position_y_mt, entity.radius_mt
		)
		var slot := _reserve_air_actor(simulation, entity.internal_id, cells)
		if slot < 0:
			return false
		actor["altitude_slot"] = slot
		actor["occupied_cells"] = cells
		return true
	var position: Array = [entity.position_x_mt, entity.position_y_mt]
	if not simulation.grid.fits_ground_footprint_at_position(
		entity.position_x_mt, entity.position_y_mt, entity.radius_mt
	):
		position = _summon_position(simulation, position, entity.radius_mt, entity.internal_id % 9)
	if position.is_empty():
		return false
	entity.set_position_mt(int(position[0]), int(position[1]))
	if not simulation.grid.reserve_ground_actor(
		entity.internal_id, entity.position_x_mt, entity.position_y_mt, entity.radius_mt
	):
		return false
	actor["occupied_cells"] = simulation.grid.ground_cells_for_actor(entity.internal_id)
	return true


func _save_toggle_base(entity: EntityRecord, key: String, value: int) -> void:
	if not entity.integer_attributes.has(key):
		entity.integer_attributes[key] = value


func _save_toggle_text(entity: EntityRecord, key: String, value: String) -> void:
	if not entity.integer_attributes.has(key + "_code"):
		entity.integer_attributes[key + "_code"] = _encode_text(value)


func _encode_text(value: String) -> int:
	match value:
		"air": return 1
		"ground": return 2
		"fortified": return 3
		"heavy": return 4
		"hero": return 5
		"light": return 6
		"medium": return 7
	return 0


func _decode_text(value: int) -> String:
	match value:
		1: return "air"
		2: return "ground"
		3: return "fortified"
		4: return "heavy"
		5: return "hero"
		6: return "light"
		7: return "medium"
	return "ground"


func _synchronize_status_derived_state(simulation: Variant) -> void:
	if simulation == null or not bool(simulation.get("is_ready")) \
		or not simulation.state.combat.enabled:
		return
	var status_totals := _status_totals_by_target(simulation.state)
	for entity_id: int in simulation.state.sorted_entity_ids():
		if not simulation.state.combat.actors.has(entity_id):
			continue
		var entity: EntityRecord = simulation.state.entities[entity_id]
		var actor: Dictionary = simulation.state.combat.actors[entity_id]
		var modifiers: Dictionary = status_totals.get(entity_id, {})
		## DuelCombat evaluates numeric status modifiers once, at attack impact or
		## cooldown evaluation. Mirroring them into the base actor would make the
		## combat authority apply the same modifier twice. Only lifecycle booleans
		## and cross-authority metadata are synchronized here.
		var immunity_key := "ability_base_magic_immune"
		var has_magic_immunity := modifiers.has("magic_immunity")
		if has_magic_immunity:
			if not entity.integer_attributes.has(immunity_key):
				entity.integer_attributes[immunity_key] = 1 if bool(actor["magic_immune"]) else 0
			actor["magic_immune"] = true
		elif entity.integer_attributes.has(immunity_key):
			actor["magic_immune"] = int(entity.integer_attributes[immunity_key]) != 0
			entity.integer_attributes.erase(immunity_key)
		var attack_key := "ability_base_attack_enabled"
		var attack_disabled := modifiers.has("disable_attack")
		if attack_disabled:
			if not entity.integer_attributes.has(attack_key):
				entity.integer_attributes[attack_key] = (
					1 if bool((actor["attack"] as Dictionary).get("enabled", false)) else 0
				)
			actor["attack"]["enabled"] = false
		elif entity.integer_attributes.has(attack_key):
			actor["attack"]["enabled"] = int(entity.integer_attributes[attack_key]) != 0
			entity.integer_attributes.erase(attack_key)
		var xp_bp := int(modifiers.get("temporary_summon_xp_bp", 0))
		if xp_bp != 0:
			entity.integer_attributes["temporary_summon_xp_bp"] = xp_bp
		else:
			entity.integer_attributes.erase("temporary_summon_xp_bp")

func _status_totals_by_target(state: Variant) -> Dictionary:
	var result: Dictionary = {}
	for status_id: int in _sorted_status_ids(state.combat.statuses):
		var status: Dictionary = state.combat.statuses[status_id]
		var target_id := int(status["target_id"])
		var kind := str(status["status_kind"])
		var totals: Dictionary = result.get(target_id, {})
		totals[kind] = int(totals.get(kind, 0)) + int(status["magnitude"])
		result[target_id] = totals
	return result


func _remove_entity_authority(simulation: Variant, entity_id: int) -> void:
	if not simulation.state.entities.has(entity_id):
		return
	simulation.grid.release_ground_actor(entity_id)
	_release_air_actor(simulation, entity_id)
	if simulation.state.combat.enabled:
		simulation.state.combat.actors.erase(entity_id)
		simulation.state.combat.attack_orders.erase(entity_id)
		for status_id: int in _sorted_status_ids(simulation.state.combat.statuses):
			var status: Dictionary = simulation.state.combat.statuses[status_id]
			if int(status.get("source_id", 0)) == entity_id \
				or int(status.get("target_id", 0)) == entity_id:
				simulation.state.combat.statuses.erase(status_id)
		for collection: Dictionary in [
			simulation.state.combat.windups,
			simulation.state.combat.projectiles,
			simulation.state.combat.scheduled_effects,
		]:
			for sequence_variant: Variant in collection.keys().duplicate():
				var record: Dictionary = collection[sequence_variant]
				if int(record.get("source_id", record.get("attacker_id", 0))) == entity_id \
					or int(record.get("target_id", 0)) == entity_id:
					collection.erase(sequence_variant)
	if simulation.state.movement.enabled:
		simulation.state.movement.actors.erase(entity_id)
	if simulation.abilities != null and simulation.abilities.is_configured():
		simulation.abilities.unregister_actor(entity_id)
	simulation.state.remove_entity(entity_id)


static func _sorted_status_ids(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key_variant: Variant in source.keys():
		result.append(int(key_variant))
	result.sort()
	return result


func _illusion_definition(simulation: Variant, source_id: int) -> Dictionary:
	var source: EntityRecord = simulation.state.entities[source_id]
	var combat_actor: Dictionary = simulation.state.combat.actors.get(source_id, {})
	var movement_actor: Dictionary = simulation.state.movement.actors.get(source_id, {})
	return {
		"armor_centi": int(combat_actor.get("armor_centi", 0)),
		"armor_class": str(combat_actor.get("armor_class", "light")),
		"attack": (combat_actor.get("attack", _disabled_attack()) as Dictionary).duplicate(true),
		"hp": source.max_hp,
		"mana": source.max_mana,
		"radius_mt": source.radius_mt,
		"speed_mt_per_tick": int(movement_actor.get("speed_mt_per_tick", 0)),
		"tags": source.tags.duplicate(),
	}


func _summon_position(
	simulation: Variant, origin: Array, radius_mt: int, ordinal: int
) -> Array:
	var offsets: Array = [
		[0, 0], [500, 0], [0, 500], [-500, 0], [0, -500],
		[500, 500], [-500, 500], [-500, -500], [500, -500],
	]
	for expansion: int in range(0, 16):
		var offset: Array = offsets[(ordinal + expansion) % offsets.size()]
		var scale := 1 + (ordinal + expansion) / offsets.size()
		var candidate := [
			int(origin[0]) + int(offset[0]) * scale,
			int(origin[1]) + int(offset[1]) * scale,
		]
		if simulation.grid.fits_ground_footprint_at_position(
			int(candidate[0]), int(candidate[1]), radius_mt
		):
			return candidate
	return []


func _target_position(simulation: Variant, target_variant: Variant) -> Array:
	if typeof(target_variant) != TYPE_DICTIONARY:
		return []
	var target: Dictionary = target_variant
	if typeof(target.get("position_mt", null)) == TYPE_ARRAY:
		return (target["position_mt"] as Array).duplicate()
	var target_id := int(target.get("entity_id", 0))
	if target_id > 0 and simulation.state.entities.has(target_id):
		var entity: EntityRecord = simulation.state.entities[target_id]
		return [entity.position_x_mt, entity.position_y_mt]
	return []


func _disabled_attack() -> Dictionary:
	return {
		"acquisition_range_mt": 0,
		"attack_range_mt": 0,
		"attack_type": "blade",
		"cooldown_ticks": 1,
		"damage": 0,
		"enabled": false,
		"impact_kind": "contact_check",
		"minimum_range_mt": 0,
		"projectile_speed_mt_per_tick": 0,
		"target_layers": ["ground"],
		"windup_ticks": 0,
	}


func _delta(
	tick: int, entity_id: int, kind: int, amount: int, source_id: int, local_seq: int
) -> DeltaRecord:
	var result := DeltaRecord.new()
	result.application_tick = tick
	result.entity_id = entity_id
	result.kind = kind
	result.amount = amount
	result.source_internal_id = source_id
	result.local_seq = local_seq
	return result


func _queue_event(tick: int, kind: String, effect: Dictionary, payload: Dictionary) -> void:
	_events.append({
		"event_kind": kind,
		"local_seq": _local_event_seq,
		"payload": payload.duplicate(true),
		"source_internal_id": int(effect.get("source_id", 0)),
		"target_internal_id": int((effect.get("selected_target_ids", []) as Array).front()) \
			if not (effect.get("selected_target_ids", []) as Array).is_empty() else 0,
		"tick": tick,
	})
	_local_event_seq += 1


static func _effect_less(left: Dictionary, right: Dictionary) -> bool:
	var left_key := [
		int(left.get("impact_tick", 0)), int(left.get("effect_id", 0)),
		int(left.get("impact_index", 0)), int(left.get("source_id", 0)),
		str(left.get("effect_kind", "")),
	]
	var right_key := [
		int(right.get("impact_tick", 0)), int(right.get("effect_id", 0)),
		int(right.get("impact_index", 0)), int(right.get("source_id", 0)),
		str(right.get("effect_kind", "")),
	]
	return left_key < right_key


static func _effect_delivery_key(effect: Dictionary) -> String:
	return "%d:%d:%d" % [
		int(effect.get("effect_id", 0)),
		int(effect.get("impact_index", 0)),
		int(effect.get("impact_tick", 0)),
	]


static func _effect_intent_reason(effect: Dictionary, abilities: Variant) -> String:
	var integer_fields: Array[String] = [
		"cast_id", "effect_id", "impact_tick", "primitive_value",
		"resolved_duration_ticks", "source_id",
	]
	for field: String in integer_fields:
		if typeof(effect.get(field, null)) != TYPE_INT:
			return "ability effect intent requires integer %s" % field
	if int(effect["cast_id"]) <= 0 or int(effect["effect_id"]) <= 0 \
		or int(effect["source_id"]) <= 0:
		return "ability effect intent IDs must be positive"
	if int(effect["impact_tick"]) < 0 or int(effect["resolved_duration_ticks"]) < 0:
		return "ability effect intent timing must be non-negative"
	for field: String in ["ability_id", "effect_kind", "primitive_kind"]:
		if typeof(effect.get(field, null)) != TYPE_STRING or str(effect[field]).is_empty():
			return "ability effect intent requires non-empty %s" % field
	if abilities.ability_definition(str(effect["ability_id"])).is_empty():
		return "ability effect intent references an unknown ability"
	if typeof(effect.get("selected_target_ids", null)) != TYPE_ARRAY:
		return "ability effect intent selected_target_ids must be an array"
	for target_id_variant: Variant in effect["selected_target_ids"]:
		if typeof(target_id_variant) != TYPE_INT or int(target_id_variant) <= 0:
			return "ability effect selected target IDs must be positive integers"
	if typeof(effect.get("target", null)) != TYPE_DICTIONARY:
		return "ability effect intent target must be an object"
	var target: Dictionary = effect["target"]
	var target_kind := str(target.get("kind", ""))
	if target_kind not in ["entity", "point", "site"]:
		return "ability effect intent target kind is invalid"
	if target_kind == "entity" and (
		typeof(target.get("entity_id", null)) != TYPE_INT or int(target["entity_id"]) <= 0
	):
		return "ability effect entity target requires a positive integer ID"
	if target_kind in ["point", "site"]:
		var position_variant: Variant = target.get("position_mt", null)
		if typeof(position_variant) != TYPE_ARRAY or (position_variant as Array).size() != 2:
			return "ability effect point target requires a two-integer position"
		for coordinate_variant: Variant in position_variant:
			if typeof(coordinate_variant) != TYPE_INT:
				return "ability effect point target requires a two-integer position"
	if target_kind == "site" and (
		typeof(target.get("site_id", null)) != TYPE_STRING or str(target["site_id"]).is_empty()
	):
		return "ability effect site target requires a non-empty site ID"
	if effect.has("impact_index"):
		if typeof(effect["impact_index"]) != TYPE_INT:
			return "ability effect intent impact_index must be an integer"
		if int(effect["impact_index"]) < 0:
			return "ability effect intent impact_index must be non-negative"
	if effect.has("dispel_class") and (
		typeof(effect["dispel_class"]) != TYPE_STRING
		or str(effect["dispel_class"]) not in ["none", "ordinary_magical", "undispellable"]
	):
		return "ability effect intent dispel_class is invalid"
	if effect.has("status_stacking_key") and typeof(effect["status_stacking_key"]) != TYPE_STRING:
		return "ability effect intent status_stacking_key must be a string"
	return ""


static func _ability_declares_effect_kind(abilities: Variant, effect: Dictionary) -> bool:
	var ability: Dictionary = abilities.ability_definition(str(effect["ability_id"]))
	var kind := str(effect["effect_kind"])
	if kind == "destroy_caster":
		return str(ability.get("impact_schedule", "")) \
			== "immediate_at_commit_then_destroy_caster"
	if kind == "remove_stacking_key":
		return "toggle" in str(ability.get("activation_kind", ""))
	for descriptor_variant: Variant in ability.get("effects", []):
		if str((descriptor_variant as Dictionary).get("kind", "")) == kind:
			return true
	return false


static func _integer_sqrt(value: int) -> int:
	if value <= 0:
		return 0
	var x := value
	var y := (x + 1) / 2
	while y < x:
		x = y
		y = (x + value / x) / 2
	return x


static func _append_errors(target: PackedStringArray, source: Variant) -> void:
	if typeof(source) in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY]:
		for message: Variant in source:
			target.append(str(message))
	elif source != null:
		target.append(str(source))
