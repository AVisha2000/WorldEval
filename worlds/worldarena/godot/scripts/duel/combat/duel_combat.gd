class_name DuelCombat
extends RefCounted

const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const CombatState := preload("res://scripts/duel/combat/duel_combat_state.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const BP_ONE := 10_000
const ATTACK_TYPES := ["arcane", "blade", "hero", "pierce", "siege", "spell"]
const ARMOR_CLASSES := ["fortified", "heavy", "hero", "light", "medium"]
const TARGET_LAYERS := ["air", "ground"]
const IMPACT_CONTACT := "contact_check"
const IMPACT_PROJECTILE := "authoritative_homing_projectile"
const GROUND_ATTACK_TARGET_KIND := "attack_ground_area"

var catalog: Dictionary = {}
var _events: Array[Dictionary] = []
var _deltas: Array = []
var _shield_updates: Dictionary = {}
var _progress_this_tick: bool = false


func configure(
	combat_state: CombatState,
	attack_armor_catalog: Dictionary,
	faction_catalog: Dictionary,
	rules_catalog: Dictionary = {}
) -> PackedStringArray:
	var errors := validate_catalogs(attack_armor_catalog, faction_catalog, rules_catalog)
	if not errors.is_empty():
		return errors
	catalog = {
		"attack_armor": attack_armor_catalog.duplicate(true),
		"faction": faction_catalog.duplicate(true),
		"rules": rules_catalog.duplicate(true),
	}
	combat_state.enabled = true
	combat_state.attack_armor_catalog_id = str(attack_armor_catalog["catalog_id"])
	combat_state.faction_catalog_id = str(faction_catalog["catalog_id"])
	combat_state.matrix_bp = attack_armor_catalog["matrix_bp"].duplicate(true)
	combat_state.combat_rules = {
		"high_ground": attack_armor_catalog["high_ground"].duplicate(true),
		"spell_damage": attack_armor_catalog["spell_damage"].duplicate(true),
	}
	combat_state.catalog_profiles = _compile_profiles(faction_catalog, rules_catalog)
	combat_state.actors.clear()
	combat_state.attack_orders.clear()
	combat_state.windups.clear()
	combat_state.projectiles.clear()
	combat_state.scheduled_effects.clear()
	combat_state.statuses.clear()
	combat_state.next_sequence_id = 1
	clear_pending()
	return errors


func validate_catalogs(
	attack_armor_catalog: Dictionary,
	faction_catalog: Dictionary,
	rules_catalog: Dictionary = {}
) -> PackedStringArray:
	var errors := PackedStringArray()
	for field: String in ["catalog_id", "matrix_bp", "high_ground", "spell_damage"]:
		if not attack_armor_catalog.has(field):
			errors.append("attack/armor catalog is missing %s" % field)
	for field: String in ["catalog_id", "faction_id", "structures", "units", "heroes"]:
		if not faction_catalog.has(field):
			errors.append("faction catalog is missing %s" % field)
	if not errors.is_empty():
		return errors
	if typeof(attack_armor_catalog["matrix_bp"]) != TYPE_DICTIONARY:
		errors.append("attack/armor matrix must be an object")
		return errors
	var matrix: Dictionary = attack_armor_catalog["matrix_bp"]
	for attack_type: String in ATTACK_TYPES:
		if attack_type == "spell":
			continue
		if typeof(matrix.get(attack_type, null)) != TYPE_DICTIONARY:
			errors.append("attack/armor matrix is missing %s" % attack_type)
			continue
		for armor_class: String in ARMOR_CLASSES:
			if typeof((matrix[attack_type] as Dictionary).get(armor_class, null)) != TYPE_INT:
				errors.append("attack/armor matrix %s/%s must be integer basis points" % [attack_type, armor_class])
	for section: String in ["structures", "units", "heroes"]:
		if typeof(faction_catalog[section]) != TYPE_DICTIONARY:
			errors.append("faction %s must be an object" % section)
	if not rules_catalog.is_empty() and typeof(rules_catalog.get("shared_structures", null)) != TYPE_DICTIONARY:
		errors.append("rules catalog shared_structures must be an object when supplied")
	for entry: Dictionary in [
		{"label": "attack_armor", "value": attack_armor_catalog},
		{"label": "faction", "value": faction_catalog},
		{"label": "rules", "value": rules_catalog},
	]:
		for message: String in Codec.validate_canonical_value(entry["value"], "$.%s" % entry["label"]):
			errors.append(message)
	return errors


func install_external_profile(
	combat_state: CombatState,
	section: String,
	catalog_key: String,
	definition: Dictionary
) -> PackedStringArray:
	## Locked neutral, hired, and summoned actors are not members of the selected
	## faction catalog, but they must use the same combat authority. This explicit
	## boundary compiles their already-validated integer definition into the exact
	## profile shape consumed by register_entity().
	var errors := PackedStringArray()
	if not combat_state.enabled or catalog.is_empty():
		errors.append("combat is not configured")
		return errors
	if section not in ["hire", "neutral", "summon"]:
		errors.append("external combat profile section is invalid")
	if catalog_key.is_empty():
		errors.append("external combat profile key must not be empty")
	for field: String in ["armor_centi", "armor_class", "layer"]:
		if not definition.has(field):
			errors.append("external combat definition is missing %s" % field)
	if typeof(definition.get("attack", {})) != TYPE_DICTIONARY:
		errors.append("external combat definition attack must be an object")
	if not errors.is_empty():
		return errors
	var tags := _definition_tags(definition, "units")
	var attack := _normalized_attack(definition.get("attack", {}))
	errors.append_array(_validate_resolved_attack(attack))
	if str(definition["armor_class"]) not in ARMOR_CLASSES:
		errors.append("external combat armor class is invalid")
	if str(definition["layer"]) not in TARGET_LAYERS:
		errors.append("external combat layer is invalid")
	if not errors.is_empty():
		return errors
	var profile_id := "%s:%s:%s" % [
		str(catalog["faction"]["faction_id"]), section, catalog_key,
	]
	var profile := {
		"armor_centi": int(definition["armor_centi"]),
		"armor_class": str(definition["armor_class"]),
		"attack": attack,
		"ground_attack": _disabled_ground_attack_profile(),
		"layer": str(definition["layer"]),
		"magic_immune": "magic_immune" in tags,
		"profile_id": profile_id,
		"tags": tags,
	}
	if combat_state.catalog_profiles.has(profile_id) \
		and combat_state.catalog_profiles[profile_id] != profile:
		errors.append("external combat profile conflicts with existing profile")
		return errors
	combat_state.catalog_profiles[profile_id] = profile
	return errors


func register_entity(
	state: Variant,
	entity_id: int,
	section: String,
	catalog_key: String,
	overrides: Dictionary = {}
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not state.combat.enabled:
		errors.append("combat is not configured")
		return errors
	if not state.entities.has(entity_id):
		errors.append("combat entity does not exist")
		return errors
	if state.combat.actors.has(entity_id):
		errors.append("combat entity is already registered")
		return errors
	errors.append_array(_validate_register_overrides(overrides))
	if not errors.is_empty():
		return errors
	var profile_id := "%s:%s:%s" % [
		str(catalog["faction"]["faction_id"]), section, catalog_key,
	]
	if not state.combat.catalog_profiles.has(profile_id):
		errors.append("combat catalog profile does not exist: %s" % profile_id)
		return errors
	var profile: Dictionary = state.combat.catalog_profiles[profile_id].duplicate(true)
	var actor := {
		"armor_centi": int(overrides.get("armor_centi", profile["armor_centi"])),
		"armor_class": str(overrides.get("armor_class", profile["armor_class"])),
		"attack": profile["attack"].duplicate(true),
		"attack_upgrade_bp": int(overrides.get("attack_upgrade_bp", BP_ONE)),
		"cooldown_until_tick": int(overrides.get("cooldown_until_tick", 0)),
		"damage_taken_bp": int(overrides.get("damage_taken_bp", BP_ONE)),
		"elevation": int(overrides.get("elevation", 0)),
		"entity_id": entity_id,
		"flat_damage_bonus": int(overrides.get("flat_damage_bonus", 0)),
		"ground_attack": profile.get(
			"ground_attack", _disabled_ground_attack_profile()
		).duplicate(true),
		"invulnerable": bool(overrides.get("invulnerable", false)),
		"layer": str(overrides.get("layer", profile["layer"])),
		"magic_immune": bool(overrides.get("magic_immune", profile["magic_immune"])),
		"net_attack_speed_bp": int(overrides.get("net_attack_speed_bp", 0)),
		"pending_attack_sequence_id": 0,
		"profile_id": profile_id,
		"resistance_bp": int(overrides.get("resistance_bp", BP_ONE)),
		"shield_hp": int(overrides.get("shield_hp", 0)),
		"source_damage_bp": int(overrides.get("source_damage_bp", BP_ONE)),
		"transported": bool(overrides.get("transported", false)),
		"visible": bool(overrides.get("visible", true)),
	}
	if typeof(overrides.get("attack", null)) == TYPE_DICTIONARY:
		for key_variant: Variant in (overrides["attack"] as Dictionary).keys():
			actor["attack"][key_variant] = overrides["attack"][key_variant]
		actor["attack"]["target_layers"] = _normalized_string_set(actor["attack"].get("target_layers", []))
	if str(actor["armor_class"]) not in ARMOR_CLASSES:
		errors.append("combat actor armor_class is invalid")
	if str(actor["layer"]) not in TARGET_LAYERS:
		errors.append("combat actor layer is invalid")
	if int(actor["shield_hp"]) < 0:
		errors.append("combat actor shield_hp must be non-negative")
	for field: String in ["attack_upgrade_bp", "damage_taken_bp", "resistance_bp", "source_damage_bp"]:
		if int(actor[field]) < 0:
			errors.append("combat actor %s must be non-negative" % field)
	errors.append_array(_validate_resolved_attack(actor["attack"]))
	errors.append_array(_validate_ground_attack_profile(actor["ground_attack"], actor["attack"]))
	if not errors.is_empty():
		return errors
	state.combat.actors[entity_id] = actor
	return errors


func issue_attack(state: Variant, attacker_id: int, target_id: int) -> Dictionary:
	var reason := _attack_request_reason(state, attacker_id, target_id)
	if not reason.is_empty():
		return {"accepted": false, "code": reason}
	var sequence_id := _next_sequence(state.combat)
	state.combat.attack_orders[attacker_id] = {
		"actor_id": attacker_id,
		"core_order_id": 0,
		"order_source": "combat_api",
		"sequence_id": sequence_id,
		"target_kind": "entity",
		"target_id": target_id,
	}
	return {"accepted": true, "code": "accepted", "sequence_id": sequence_id}


func issue_ground_attack(state: Variant, attacker_id: int, target_point_mt: Array) -> Dictionary:
	var reason := _ground_attack_request_reason(state, attacker_id, target_point_mt)
	if not reason.is_empty():
		return {"accepted": false, "code": reason}
	var sequence_id := _next_sequence(state.combat)
	state.combat.attack_orders[attacker_id] = {
		"actor_id": attacker_id,
		"core_order_id": 0,
		"order_source": "combat_api",
		"sequence_id": sequence_id,
		"target_kind": "point",
		"target_point_mt": [int(target_point_mt[0]), int(target_point_mt[1])],
	}
	return {"accepted": true, "code": "accepted", "sequence_id": sequence_id}


func ground_attack_request_code(
	state: Variant,
	attacker_id: int,
	target_point_mt: Array
) -> String:
	return _ground_attack_request_reason(state, attacker_id, target_point_mt)


func cancel_attack(state: Variant, attacker_id: int) -> bool:
	if not state.combat.attack_orders.has(attacker_id):
		return false
	state.combat.attack_orders.erase(attacker_id)
	_cancel_actor_windup(state, attacker_id, "cancelled")
	return true


func schedule_damage_effect(
	state: Variant,
	source_id: int,
	target_id: int,
	amount: int,
	damage_type: String,
	landing_tick: int,
	target_layers: Array[String] = ["air", "ground"]
) -> Dictionary:
	if not state.combat.enabled or amount <= 0 or damage_type not in ATTACK_TYPES:
		return {"accepted": false, "code": "invalid_effect"}
	if landing_tick < state.tick or not state.entities.has(target_id):
		return {"accepted": false, "code": "invalid_target"}
	var sequence_id := _next_sequence(state.combat)
	state.combat.scheduled_effects[sequence_id] = {
		"amount": amount,
		"damage_type": damage_type,
		"effect_kind": "damage",
		"landing_tick": landing_tick,
		"sequence_id": sequence_id,
		"source_id": source_id,
		"target_id": target_id,
		"target_layers": _sorted_strings(target_layers),
	}
	return {"accepted": true, "code": "accepted", "sequence_id": sequence_id}


func schedule_heal_effect(
	state: Variant,
	source_id: int,
	target_id: int,
	amount: int,
	landing_tick: int,
	biological_only: bool = true
) -> Dictionary:
	if not state.combat.enabled or amount <= 0 or landing_tick < state.tick:
		return {"accepted": false, "code": "invalid_effect"}
	if not state.entities.has(target_id):
		return {"accepted": false, "code": "invalid_target"}
	var sequence_id := _next_sequence(state.combat)
	state.combat.scheduled_effects[sequence_id] = {
		"amount": amount,
		"biological_only": biological_only,
		"effect_kind": "heal",
		"landing_tick": landing_tick,
		"sequence_id": sequence_id,
		"source_id": source_id,
		"target_id": target_id,
	}
	return {"accepted": true, "code": "accepted", "sequence_id": sequence_id}


func add_status(
	state: Variant,
	target_id: int,
	source_id: int,
	status_kind: String,
	stacking_key: String,
	magnitude: int,
	duration_ticks: int,
	dispel_class: String = "ordinary_magical"
) -> Dictionary:
	if not state.combat.enabled or not state.combat.actors.has(target_id) \
		or status_kind.is_empty() or stacking_key.is_empty() or duration_ticks <= 0:
		return {"accepted": false, "code": "invalid_status"}
	var expiry_tick: int = int(state.tick) + duration_ticks
	var status_ids := _sorted_int_keys(state.combat.statuses)
	for status_id: int in status_ids:
		var existing: Dictionary = state.combat.statuses[status_id]
		if int(existing["target_id"]) == target_id and str(existing["stacking_key"]) == stacking_key:
			if absi(magnitude) > absi(int(existing["magnitude"])):
				existing["magnitude"] = magnitude
			existing["expiry_tick"] = maxi(int(existing["expiry_tick"]), expiry_tick)
			return {"accepted": true, "code": "refreshed", "status_id": status_id}
	var sequence_id := _next_sequence(state.combat)
	state.combat.statuses[sequence_id] = {
		"dispel_class": dispel_class,
		"expiry_tick": expiry_tick,
		"magnitude": magnitude,
		"source_id": source_id,
		"stacking_key": stacking_key,
		"start_tick": state.tick,
		"status_id": sequence_id,
		"status_kind": status_kind,
		"target_id": target_id,
	}
	return {"accepted": true, "code": "accepted", "status_id": sequence_id}


func compile_intents(state: Variant, tick: int) -> void:
	if not state.combat.enabled:
		return
	for actor_id: int in _sorted_int_keys(state.combat.actors):
		var entity: EntityRecord = state.entities.get(actor_id)
		if entity == null:
			continue
		if entity.active_order_id == 0 or not state.orders.has(entity.active_order_id):
			_clear_stale_core_order(state, actor_id)
			continue
		var order: OrderRecord = state.orders[entity.active_order_id]
		if order.status != OrderRecord.Status.ACTIVE \
			or order.order_kind not in ["attack", "attack_entity", "attack_ground"]:
			_clear_stale_core_order(state, actor_id)
			continue
		if order.order_kind == "attack_ground":
			var target_point: Array = order.target.get("xy_mt", [])
			var current_ground: Dictionary = state.combat.attack_orders.get(actor_id, {})
			if str(current_ground.get("order_source", "")) == "core_order" \
				and int(current_ground.get("core_order_id", 0)) == order.internal_order_id \
				and str(current_ground.get("target_kind", "")) == "point" \
				and current_ground.get("target_point_mt", []) == target_point:
				continue
			var ground_reason := _ground_attack_request_reason(state, actor_id, target_point)
			if not ground_reason.is_empty():
				_queue_event(3, "ground_attack_order_invalid", actor_id, 0, {
					"reason": ground_reason,
					"target_point_mt": target_point.duplicate(),
				})
				continue
			state.combat.attack_orders[actor_id] = {
				"actor_id": actor_id,
				"core_order_id": order.internal_order_id,
				"order_source": "core_order",
				"sequence_id": _next_sequence(state.combat),
				"target_kind": "point",
				"target_point_mt": [int(target_point[0]), int(target_point[1])],
			}
			continue
		var target_id := int(order.target.get("entity_id", order.target.get("target_id", 0)))
		if target_id <= 0:
			continue
		var current: Dictionary = state.combat.attack_orders.get(actor_id, {})
		if str(current.get("order_source", "")) == "core_order" \
			and int(current.get("core_order_id", 0)) == order.internal_order_id \
			and int(current.get("target_id", 0)) == target_id:
			continue
		var reason := _attack_request_reason(state, actor_id, target_id)
		if not reason.is_empty():
			_queue_event(3, "attack_order_invalid", actor_id, target_id, {"reason": reason})
			continue
		state.combat.attack_orders[actor_id] = {
			"actor_id": actor_id,
			"core_order_id": order.internal_order_id,
			"order_source": "core_order",
			"sequence_id": _next_sequence(state.combat),
			"target_kind": "entity",
			"target_id": target_id,
		}


func expire_statuses(state: Variant, tick: int) -> void:
	if not state.combat.enabled:
		return
	for actor_id: int in _sorted_int_keys(state.combat.actors):
		var actor: Dictionary = state.combat.actors[actor_id]
		var ready_tick := int(actor["cooldown_until_tick"])
		if ready_tick > 0 and ready_tick <= tick:
			actor["cooldown_until_tick"] = 0
			_queue_event(2, "attack_cooldown_ready", actor_id, 0, {"ready_tick": ready_tick})
	for status_id: int in _sorted_int_keys(state.combat.statuses):
		var status: Dictionary = state.combat.statuses[status_id]
		if int(status["expiry_tick"]) > tick:
			continue
		state.combat.statuses.erase(status_id)
		_queue_event(2, "status_expired", int(status["source_id"]), int(status["target_id"]), {
			"stacking_key": str(status["stacking_key"]),
			"status_id": status_id,
			"status_kind": str(status["status_kind"]),
		})


## Consumer for the locked `damage_wakes_after_minimum_ticks` control rule.
## Only HP damage that survived mitigation/shields reaches this boundary. The
## associated sleep-disable status is removed at or after the exact integer
## minimum, while earlier damage leaves the sleep untouched.
func notify_hp_damage_applied(state: Variant, target_id: int, tick: int) -> bool:
	if not state.combat.enabled or not state.entities.has(target_id):
		return false
	var wake_statuses: Array[Dictionary] = []
	for status_id: int in _sorted_int_keys(state.combat.statuses):
		var status: Dictionary = state.combat.statuses[status_id]
		if int(status.get("target_id", 0)) != target_id \
			or str(status.get("status_kind", "")) \
			!= "damage_wakes_after_minimum_ticks" \
			or int(status.get("expiry_tick", -1)) <= tick \
			or str(status.get("ability_id", "")).is_empty():
			continue
		var minimum_ticks := maxi(0, int(status.get("magnitude", 0)))
		if tick >= int(status.get("start_tick", 0)) + minimum_ticks:
			wake_statuses.append(status.duplicate(true))
	if wake_statuses.is_empty():
		return false
	var remove_ids: Array[int] = []
	for status_id: int in _sorted_int_keys(state.combat.statuses):
		var candidate: Dictionary = state.combat.statuses[status_id]
		if int(candidate.get("target_id", 0)) != target_id:
			continue
		for wake: Dictionary in wake_statuses:
			if str(candidate.get("ability_id", "")) == str(wake.get("ability_id", "")) \
				and int(candidate.get("source_id", 0)) == int(wake.get("source_id", 0)) \
				and int(candidate.get("start_tick", -1)) == int(wake.get("start_tick", -2)) \
				and str(candidate.get("status_kind", "")) in [
					"damage_wakes_after_minimum_ticks", "disable", "stun",
				]:
				remove_ids.append(status_id)
				break
	for status_id: int in remove_ids:
		state.combat.statuses.erase(status_id)
	var first: Dictionary = wake_statuses[0]
	_queue_event(9, "sleep_woken_by_damage", int(first.get("source_id", 0)), target_id, {
		"minimum_ticks": maxi(0, int(first.get("magnitude", 0))),
		"removed_status_count": remove_ids.size(),
		"wake_tick": tick,
	})
	return true


func start_windups(state: Variant, tick: int) -> void:
	if not state.combat.enabled:
		return
	for attacker_id: int in _sorted_int_keys(state.combat.attack_orders):
		if not state.combat.actors.has(attacker_id) or not state.entities.has(attacker_id):
			continue
		var actor: Dictionary = state.combat.actors[attacker_id]
		var entity: EntityRecord = state.entities[attacker_id]
		if not entity.alive or entity.hp <= 0 or int(actor["pending_attack_sequence_id"]) != 0:
			continue
		if tick < int(actor["cooldown_until_tick"]) or _status_blocks_attack(state.combat, attacker_id):
			continue
		var order: Dictionary = state.combat.attack_orders[attacker_id]
		if str(order.get("target_kind", "entity")) == "point":
			var target_point: Array = order.get("target_point_mt", [])
			var ground_reason := _ground_attack_request_reason(state, attacker_id, target_point)
			if ground_reason in [
				"attacker_dead", "attacker_missing", "attack_disabled",
				"ground_attack_unsupported", "invalid_target",
			]:
				_queue_event(6, "ground_attack_cancelled", attacker_id, 0, {
					"reason": ground_reason,
					"target_point_mt": target_point.duplicate(),
				})
				state.combat.attack_orders.erase(attacker_id)
				continue
			if not ground_reason.is_empty():
				continue
			var ground_sequence_id := _next_sequence(state.combat)
			var base_attack: Dictionary = actor["attack"]
			var ground_commit_tick := tick + int(base_attack["windup_ticks"])
			state.combat.windups[ground_sequence_id] = {
				"attacker_id": attacker_id,
				"commit_tick": ground_commit_tick,
				"sequence_id": ground_sequence_id,
				"start_tick": tick,
				"target_kind": "point",
				"target_point_mt": [int(target_point[0]), int(target_point[1])],
			}
			actor["pending_attack_sequence_id"] = ground_sequence_id
			_queue_event(6, "ground_attack_windup_started", attacker_id, 0, {
				"commit_tick": ground_commit_tick,
				"sequence_id": ground_sequence_id,
				"target_point_mt": target_point.duplicate(),
			})
			continue
		var target_id := int(order["target_id"])
		var reason := _attack_request_reason(state, attacker_id, target_id)
		if reason in ["target_dead", "target_missing", "invalid_layer", "not_hostile", "attacker_dead"]:
			_queue_event(6, "attack_cancelled", attacker_id, target_id, {"reason": reason})
			state.combat.attack_orders.erase(attacker_id)
			continue
		if not reason.is_empty():
			continue
		var attack: Dictionary = actor["attack"]
		if not _in_attack_range(state, attacker_id, target_id, attack):
			continue
		var sequence_id := _next_sequence(state.combat)
		var commit_tick := tick + int(attack["windup_ticks"])
		state.combat.windups[sequence_id] = {
			"attacker_id": attacker_id,
			"commit_tick": commit_tick,
			"sequence_id": sequence_id,
			"start_tick": tick,
			"target_id": target_id,
		}
		actor["pending_attack_sequence_id"] = sequence_id
		_queue_event(6, "attack_windup_started", attacker_id, target_id, {
			"commit_tick": commit_tick,
			"sequence_id": sequence_id,
		})


func resolve_impacts(state: Variant, tick: int) -> void:
	if not state.combat.enabled:
		return
	var impacts: Array[Dictionary] = []
	for sequence_id: int in _sorted_int_keys(state.combat.windups):
		var windup: Dictionary = state.combat.windups[sequence_id]
		if int(windup["commit_tick"]) != tick:
			continue
		state.combat.windups.erase(sequence_id)
		_commit_windup(state, windup, tick, impacts)

	## Includes zero-travel projectiles launched by a wind-up in this phase.
	for sequence_id: int in _sorted_int_keys(state.combat.projectiles):
		var projectile: Dictionary = state.combat.projectiles[sequence_id]
		if int(projectile["arrival_tick"]) != tick:
			continue
		state.combat.projectiles.erase(sequence_id)
		_arrive_projectile(state, projectile, tick, impacts)

	for sequence_id: int in _sorted_int_keys(state.combat.scheduled_effects):
		var effect: Dictionary = state.combat.scheduled_effects[sequence_id]
		if int(effect["landing_tick"]) != tick:
			continue
		state.combat.scheduled_effects.erase(sequence_id)
		impacts.append(effect)

	impacts.sort_custom(_impact_less)
	_resolve_impact_records(state, impacts, tick)


func apply_shield_updates(state: Variant) -> void:
	for target_id: int in _sorted_int_keys(_shield_updates):
		if state.combat.actors.has(target_id):
			state.combat.actors[target_id]["shield_hp"] = int(_shield_updates[target_id])
	_shield_updates.clear()


func resolve_lifecycle(state: Variant, tick: int) -> void:
	if not state.combat.enabled:
		return
	for actor_id: int in _sorted_int_keys(state.combat.actors):
		if not state.entities.has(actor_id):
			state.combat.actors.erase(actor_id)
			state.combat.attack_orders.erase(actor_id)
			continue
		var entity: EntityRecord = state.entities[actor_id]
		if entity.alive:
			continue
		state.combat.attack_orders.erase(actor_id)
		_cancel_actor_windup(state, actor_id, "attacker_dead")
		for status_id: int in _sorted_int_keys(state.combat.statuses):
			if int(state.combat.statuses[status_id]["target_id"]) == actor_id:
				state.combat.statuses.erase(status_id)


func take_events() -> Array[Dictionary]:
	var result := _events.duplicate(true)
	_events.clear()
	return result


func take_deltas() -> Array:
	var result := _deltas.duplicate()
	_deltas.clear()
	return result


func take_progress() -> bool:
	var result := _progress_this_tick
	_progress_this_tick = false
	return result


func clear_pending() -> void:
	_events.clear()
	_deltas.clear()
	_shield_updates.clear()
	_progress_this_tick = false


func calculate_damage(attack: Dictionary, source_actor: Dictionary, target_actor: Dictionary) -> Dictionary:
	var attack_type := str(attack.get("attack_type", ""))
	var base_damage := int(attack.get("damage", 0))
	if attack_type not in ATTACK_TYPES or base_damage <= 0:
		return {"damage": 0, "immune": false, "reason": "invalid_damage"}
	if bool(target_actor.get("invulnerable", false)):
		return {"damage": 0, "immune": true, "reason": "invulnerable"}
	if bool(target_actor.get("magic_immune", false)) and attack_type in ["arcane", "spell"]:
		return {"damage": 0, "immune": true, "reason": "magic_immune"}

	var damage := maxi(0, base_damage + int(source_actor.get("flat_damage_bonus", 0)))
	damage = _mul_bp(damage, int(source_actor.get("attack_upgrade_bp", BP_ONE)))
	damage = _mul_bp(damage, int(source_actor.get("source_damage_bp", BP_ONE)))
	if attack_type != "spell":
		var armor_class := str(target_actor.get("armor_class", ""))
		if not catalog.is_empty():
			var matrix: Dictionary = catalog["attack_armor"]["matrix_bp"]
			damage = _mul_bp(damage, int((matrix.get(attack_type, {}) as Dictionary).get(armor_class, 0)))
		else:
			return {"damage": 0, "immune": false, "reason": "combat_not_configured"}
		var ranged := str(attack.get("impact_kind", "")) == IMPACT_PROJECTILE
		if ranged and int(source_actor.get("elevation", 0)) < int(target_actor.get("elevation", 0)):
			var high_ground: Dictionary = catalog["attack_armor"]["high_ground"]
			damage = _mul_bp(damage, int(high_ground["ranged_physical_low_to_high_bp"]))
		damage = _mul_bp(damage, armor_multiplier_bp(int(target_actor.get("armor_centi", 0))))
	damage = _mul_bp(damage, int(target_actor.get("resistance_bp", BP_ONE)))
	damage = _mul_bp(damage, int(target_actor.get("damage_taken_bp", BP_ONE)))
	if damage <= 0:
		damage = 1
	return {"damage": damage, "immune": false, "reason": "hit"}


static func armor_multiplier_bp(armor_centi: int) -> int:
	if armor_centi >= 0:
		@warning_ignore("integer_division")
		return (BP_ONE * BP_ONE) / (BP_ONE + 6 * armor_centi)
	return mini(20_000, BP_ONE + 6 * absi(armor_centi))


func _compile_profiles(faction: Dictionary, rules: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var faction_id := str(faction["faction_id"])
	for section: String in ["units", "heroes"]:
		var definitions: Dictionary = faction[section]
		var keys: Array = definitions.keys()
		keys.sort()
		for key_variant: Variant in keys:
			var key := str(key_variant)
			var definition: Dictionary = definitions[key]
			var tags := _definition_tags(definition, section)
			var damage_override := -1
			var armor_centi := int(definition.get("armor_centi", definition.get("base_armor_centi", 0)))
			var armor_class := str(definition.get("armor_class", "hero" if section == "heroes" else "light"))
			if section == "heroes":
				var primary := str(definition["primary_attribute"])
				var attributes: Dictionary = definition["base_attributes_centi"]
				@warning_ignore("integer_division")
				damage_override = int(definition["base_damage_before_primary"]) + int(attributes[primary]) / 100
				@warning_ignore("integer_division")
				armor_centi += int(attributes["agility"]) * 15 / 100
			var attack := _normalized_attack(definition.get("attack", {}), damage_override)
			var singular := "unit" if section == "units" else "hero"
			var profile_id := "%s:%s:%s" % [faction_id, singular, key]
			var ground_attack := _compile_ground_attack_profile(
				faction, key, definition, attack
			)
			result[profile_id] = {
				"armor_centi": armor_centi,
				"armor_class": armor_class,
				"attack": attack,
				"ground_attack": ground_attack,
				"layer": "air" if "air" in tags else "ground",
				"magic_immune": "magic_immune" in tags,
				"profile_id": profile_id,
				"tags": tags,
			}

	var shared_structures: Dictionary = rules.get("shared_structures", {})
	var structures: Dictionary = faction["structures"]
	var structure_keys: Array = structures.keys()
	structure_keys.sort()
	for key_variant: Variant in structure_keys:
		var key := str(key_variant)
		var faction_definition: Dictionary = structures[key]
		var role := str(faction_definition["shared_role"])
		var shared: Dictionary = shared_structures.get(role, {})
		var attack_raw: Dictionary = {}
		if shared.has("attack_damage"):
			attack_raw = {
				"acquisition_range_mt": int(shared["acquisition_range_mt"]),
				"attack_range_mt": int(shared["attack_range_mt"]),
				"attack_type": str(shared["attack_type"]),
				"cooldown_ticks": int(shared["attack_cooldown_ticks"]),
				"damage": int(shared["attack_damage"]),
				"impact_kind": IMPACT_PROJECTILE,
				"minimum_range_mt": 0,
				"projectile_speed_mt_per_tick": int(shared["projectile_speed_mt_per_tick"]),
				"target_layers": shared["target_layers"].duplicate(),
				"windup_ticks": int(shared["windup_ticks"]),
			}
		var profile_id := "%s:structure:%s" % [faction_id, key]
		result[profile_id] = {
			"armor_centi": int(shared.get("armor_centi", 0)),
			"armor_class": str(shared.get("armor_class", "fortified")),
			"attack": _normalized_attack(attack_raw),
			"ground_attack": _disabled_ground_attack_profile(),
			"layer": "ground",
			"magic_immune": false,
			"profile_id": profile_id,
			"tags": ["ground", "structure"],
		}
	return result


func _normalized_attack(raw_variant: Variant, damage_override: int = -1) -> Dictionary:
	var raw: Dictionary = raw_variant if typeof(raw_variant) == TYPE_DICTIONARY else {}
	var damage := damage_override if damage_override >= 0 else int(raw.get("damage", 0))
	var enabled := bool(raw.get("enabled", damage > 0)) and damage > 0
	var layers: Array[String] = []
	for layer_variant: Variant in raw.get("target_layers", []):
		layers.append(str(layer_variant))
	layers.sort()
	return {
		"acquisition_range_mt": int(raw.get("acquisition_range_mt", 0)),
		"attack_range_mt": int(raw.get("attack_range_mt", 0)),
		"attack_type": str(raw.get("attack_type", "blade")),
		"cooldown_ticks": int(raw.get("cooldown_ticks", 0)),
		"damage": damage,
		"enabled": enabled,
		"impact_kind": str(raw.get("impact_kind", "none")),
		"minimum_range_mt": int(raw.get("minimum_range_mt", 0)),
		"projectile_speed_mt_per_tick": int(raw.get("projectile_speed_mt_per_tick", 0)),
		"target_layers": layers,
		"windup_ticks": int(raw.get("windup_ticks", 0)),
	}


static func _compile_ground_attack_profile(
	faction: Dictionary,
	owner_type_id: String,
	owner_definition: Dictionary,
	attack: Dictionary
) -> Dictionary:
	var result := _disabled_ground_attack_profile()
	if not bool(attack.get("enabled", false)) \
		or str(attack.get("impact_kind", "")) != IMPACT_PROJECTILE:
		return result
	var ability_ids: Array[String] = []
	for ability_variant: Variant in owner_definition.get("abilities", []):
		ability_ids.append(str(ability_variant))
	ability_ids.sort()
	for ability_id: String in ability_ids:
		if not faction.get("abilities", {}).has(ability_id):
			continue
		var ability: Dictionary = faction["abilities"][ability_id]
		if str(ability.get("activation_kind", "")) != "passive_attack_modifier" \
			or str(ability.get("target_kind", "")) != GROUND_ATTACK_TARGET_KIND \
			or str(ability.get("impact_schedule", "")) != "attack_impact" \
			or owner_type_id not in ability.get("allowed_owners", []) \
			or int(ability.get("cast_range_mt", 0)) <= 0 \
			or int(ability.get("area_radius_mt", 0)) <= 0:
			continue
		var damage_bands_bp: Array[int] = [BP_ONE]
		var friendly_fire_bp := 0
		for effect_variant: Variant in ability.get("effects", []):
			var effect: Dictionary = effect_variant
			var values: Array = effect.get("values", [])
			match str(effect.get("kind", "")):
				"splash_damage_bp", "splash_damage_bands_bp":
					damage_bands_bp.clear()
					for value_variant: Variant in values:
						damage_bands_bp.append(int(value_variant))
				"friendly_fire_bp":
					if not values.is_empty():
						friendly_fire_bp = int(values[0])
		var layers := _normalized_string_set(ability.get("target_layers", []))
		result = {
			"ability_id": ability_id,
			"area_radius_mt": int(ability["area_radius_mt"]),
			"cast_range_mt": mini(
				int(ability["cast_range_mt"]), int(attack["attack_range_mt"])
			),
			"damage_bands_bp": damage_bands_bp,
			"enabled": true,
			"friendly_fire_bp": friendly_fire_bp,
			"minimum_range_mt": int(attack["minimum_range_mt"]),
			"target_layers": layers,
		}
		break
	return result


static func _disabled_ground_attack_profile() -> Dictionary:
	return {
		"ability_id": "",
		"area_radius_mt": 0,
		"cast_range_mt": 0,
		"damage_bands_bp": [],
		"enabled": false,
		"friendly_fire_bp": 0,
		"minimum_range_mt": 0,
		"target_layers": [],
	}


static func _validate_ground_attack_profile(
	ground_attack: Dictionary,
	attack: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not bool(ground_attack.get("enabled", false)):
		return errors
	if str(ground_attack.get("ability_id", "")).is_empty():
		errors.append("ground attack profile requires an ability ID")
	if str(attack.get("impact_kind", "")) != IMPACT_PROJECTILE \
		or int(attack.get("projectile_speed_mt_per_tick", 0)) <= 0:
		errors.append("ground attack requires an authoritative projectile attack")
	if int(ground_attack.get("area_radius_mt", 0)) <= 0 \
		or int(ground_attack.get("cast_range_mt", 0)) <= 0:
		errors.append("ground attack radius/range must be positive")
	if int(ground_attack.get("minimum_range_mt", -1)) < 0 \
		or int(ground_attack.get("minimum_range_mt", 0)) \
		>= int(ground_attack.get("cast_range_mt", 0)):
		errors.append("ground attack minimum range is invalid")
	var bands: Array = ground_attack.get("damage_bands_bp", [])
	if bands.is_empty():
		errors.append("ground attack requires at least one damage band")
	for value_variant: Variant in bands:
		if typeof(value_variant) != TYPE_INT or int(value_variant) < 0:
			errors.append("ground attack damage bands must be non-negative integers")
	if int(ground_attack.get("friendly_fire_bp", -1)) < 0:
		errors.append("ground attack friendly fire must be non-negative")
	var layers: Array = ground_attack.get("target_layers", [])
	if layers.is_empty():
		errors.append("ground attack requires target layers")
	for layer_variant: Variant in layers:
		if str(layer_variant) not in TARGET_LAYERS:
			errors.append("ground attack target layer is invalid")
	return errors


func _validate_register_overrides(overrides: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var integer_fields := [
		"armor_centi", "attack_upgrade_bp", "cooldown_until_tick", "damage_taken_bp",
		"elevation", "flat_damage_bonus", "net_attack_speed_bp", "resistance_bp",
		"shield_hp", "source_damage_bp",
	]
	var bool_fields := ["invulnerable", "magic_immune", "transported", "visible"]
	var allowed := integer_fields + bool_fields + ["armor_class", "layer", "attack"]
	for key_variant: Variant in overrides.keys():
		var key := str(key_variant)
		if key not in allowed:
			errors.append("unknown combat override: %s" % key)
		elif key in integer_fields and typeof(overrides[key_variant]) != TYPE_INT:
			errors.append("combat override %s must be an integer" % key)
		elif key in bool_fields and typeof(overrides[key_variant]) != TYPE_BOOL:
			errors.append("combat override %s must be a boolean" % key)
		elif key in ["armor_class", "layer"] and typeof(overrides[key_variant]) != TYPE_STRING:
			errors.append("combat override %s must be a string" % key)
	if overrides.has("attack"):
		if typeof(overrides["attack"]) != TYPE_DICTIONARY:
			errors.append("combat override attack must be an object")
		else:
			var attack: Dictionary = overrides["attack"]
			var allowed_attack := [
				"acquisition_range_mt", "attack_range_mt", "attack_type", "cooldown_ticks",
				"damage", "enabled", "impact_kind", "minimum_range_mt",
				"projectile_speed_mt_per_tick", "target_layers", "windup_ticks",
			]
			for key_variant: Variant in attack.keys():
				var key := str(key_variant)
				if key not in allowed_attack:
					errors.append("unknown combat attack override: %s" % key)
				elif key in ["attack_type", "impact_kind"] and typeof(attack[key_variant]) != TYPE_STRING:
					errors.append("combat attack override %s must be a string" % key)
				elif key == "enabled" and typeof(attack[key_variant]) != TYPE_BOOL:
					errors.append("combat attack override enabled must be a boolean")
				elif key == "target_layers":
					if typeof(attack[key_variant]) != TYPE_ARRAY:
						errors.append("combat attack override target_layers must be an array")
					else:
						for layer_variant: Variant in attack[key_variant]:
							if typeof(layer_variant) != TYPE_STRING:
								errors.append("combat attack target layers must be strings")
				elif typeof(attack[key_variant]) != TYPE_INT:
					errors.append("combat attack override %s must be an integer" % key)
	return errors


func _validate_resolved_attack(attack: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not bool(attack.get("enabled", false)):
		return errors
	if int(attack.get("damage", 0)) <= 0:
		errors.append("enabled combat attack requires positive fixed damage")
	if str(attack.get("attack_type", "")) not in ATTACK_TYPES:
		errors.append("combat attack type is invalid")
	if int(attack.get("cooldown_ticks", 0)) <= 0:
		errors.append("enabled combat attack requires a positive cooldown")
	if int(attack.get("windup_ticks", -1)) < 0:
		errors.append("combat attack windup must be non-negative")
	if int(attack.get("minimum_range_mt", -1)) < 0 \
		or int(attack.get("attack_range_mt", -1)) < int(attack.get("minimum_range_mt", 0)):
		errors.append("combat attack range is invalid")
	var impact_kind := str(attack.get("impact_kind", ""))
	if impact_kind not in [IMPACT_CONTACT, IMPACT_PROJECTILE]:
		errors.append("enabled combat attack impact kind is invalid")
	if impact_kind == IMPACT_PROJECTILE and int(attack.get("projectile_speed_mt_per_tick", 0)) <= 0:
		errors.append("projectile combat attack requires positive integer speed")
	var layers: Array = attack.get("target_layers", [])
	if layers.is_empty():
		errors.append("enabled combat attack requires target layers")
	for layer_variant: Variant in layers:
		if str(layer_variant) not in TARGET_LAYERS:
			errors.append("combat attack target layer is invalid")
	return errors


func _definition_tags(definition: Dictionary, section: String) -> Array[String]:
	var tags: Array[String] = []
	for value: Variant in definition.get("tags", []):
		tags.append(str(value))
	if section == "heroes":
		for tag: String in ["biological", "ground", "hero"]:
			if tag not in tags:
				tags.append(tag)
	tags.sort()
	return tags


func _commit_windup(state: Variant, windup: Dictionary, tick: int, impacts: Array[Dictionary]) -> void:
	var attacker_id := int(windup["attacker_id"])
	var target_id := int(windup.get("target_id", 0))
	if not state.combat.actors.has(attacker_id) or not state.entities.has(attacker_id):
		return
	var source_entity: EntityRecord = state.entities[attacker_id]
	var source_actor: Dictionary = state.combat.actors[attacker_id]
	if not source_entity.alive or source_entity.hp <= 0 or _status_blocks_attack(state.combat, attacker_id):
		source_actor["pending_attack_sequence_id"] = 0
		_queue_event(7, "attack_windup_interrupted", attacker_id, target_id, {"reason": "attacker_disabled"})
		return
	if str(windup.get("target_kind", "entity")) == "point":
		_commit_ground_windup(state, windup, source_entity, source_actor, tick)
		return
	var attack: Dictionary = source_actor["attack"]
	if str(attack["impact_kind"]) == IMPACT_CONTACT:
		if not _target_valid_after_launch(state, attacker_id, target_id, attack) \
			or not _in_attack_range(state, attacker_id, target_id, attack):
			_finish_attack_attempt(state, attacker_id, tick, int(windup["sequence_id"]))
			_queue_event(7, "attack_missed", attacker_id, target_id, {
				"reason": "contact_lost", "sequence_id": int(windup["sequence_id"]),
			})
			return
		impacts.append({
			"attack": attack.duplicate(true),
			"effect_kind": "attack",
			"sequence_id": int(windup["sequence_id"]),
			"source_actor": _damage_source_snapshot(source_actor),
			"source_id": attacker_id,
			"target_id": target_id,
		})
		_finish_attack_attempt(state, attacker_id, tick, int(windup["sequence_id"]))
		return

	if str(attack["impact_kind"]) != IMPACT_PROJECTILE \
		or int(attack["projectile_speed_mt_per_tick"]) <= 0:
		source_actor["pending_attack_sequence_id"] = 0
		_queue_event(7, "attack_missed", attacker_id, target_id, {"reason": "invalid_impact_kind"})
		return
	if not _target_valid_after_launch(state, attacker_id, target_id, attack):
		_finish_attack_attempt(state, attacker_id, tick, int(windup["sequence_id"]))
		_queue_event(7, "attack_missed", attacker_id, target_id, {
			"reason": "target_invalid_before_launch", "sequence_id": int(windup["sequence_id"]),
		})
		return
	var target_entity: EntityRecord = state.entities[target_id]
	var distance_sq := _distance_squared(source_entity, target_entity)
	var travel_ticks := _travel_ticks(distance_sq, int(attack["projectile_speed_mt_per_tick"]))
	var projectile_id := int(windup["sequence_id"])
	state.combat.projectiles[projectile_id] = {
		"arrival_tick": tick + travel_ticks,
		"attack": attack.duplicate(true),
		"launch_tick": tick,
		"projectile_id": projectile_id,
		"source_actor": _damage_source_snapshot(source_actor),
		"source_id": attacker_id,
		"target_id": target_id,
		"travel_ticks": travel_ticks,
	}
	_queue_event(7, "projectile_launched", attacker_id, target_id, {
		"arrival_tick": tick + travel_ticks,
		"projectile_id": projectile_id,
		"travel_ticks": travel_ticks,
	})


func _commit_ground_windup(
	state: Variant,
	windup: Dictionary,
	source_entity: EntityRecord,
	source_actor: Dictionary,
	tick: int
) -> void:
	var attacker_id := int(windup["attacker_id"])
	var target_point: Array = windup.get("target_point_mt", [])
	var reason := _ground_attack_request_reason(state, attacker_id, target_point)
	if not reason.is_empty():
		_finish_attack_attempt(state, attacker_id, tick, int(windup["sequence_id"]))
		_queue_event(7, "ground_attack_missed", attacker_id, 0, {
			"reason": reason,
			"sequence_id": int(windup["sequence_id"]),
			"target_point_mt": target_point.duplicate(),
		})
		return
	var attack: Dictionary = source_actor["attack"]
	var distance_sq := _distance_squared_to_point(source_entity, target_point)
	var travel_ticks := _travel_ticks(
		distance_sq, int(attack["projectile_speed_mt_per_tick"])
	)
	var projectile_id := int(windup["sequence_id"])
	state.combat.projectiles[projectile_id] = {
		"arrival_tick": tick + travel_ticks,
		"attack": attack.duplicate(true),
		"ground_attack": (source_actor["ground_attack"] as Dictionary).duplicate(true),
		"launch_tick": tick,
		"projectile_id": projectile_id,
		"source_actor": _damage_source_snapshot(source_actor),
		"source_id": attacker_id,
		"source_owner_seat": source_entity.owner_seat,
		"target_kind": "point",
		"target_point_mt": [int(target_point[0]), int(target_point[1])],
		"travel_ticks": travel_ticks,
	}
	_queue_event(7, "ground_projectile_launched", attacker_id, 0, {
		"arrival_tick": tick + travel_ticks,
		"projectile_id": projectile_id,
		"target_point_mt": target_point.duplicate(),
		"travel_ticks": travel_ticks,
	})


func _arrive_projectile(state: Variant, projectile: Dictionary, tick: int, impacts: Array[Dictionary]) -> void:
	if str(projectile.get("target_kind", "entity")) == "point":
		_arrive_ground_projectile(state, projectile, tick, impacts)
		return
	var attacker_id := int(projectile["source_id"])
	var target_id := int(projectile["target_id"])
	var attack: Dictionary = projectile["attack"]
	if not _target_valid_after_launch(state, attacker_id, target_id, attack):
		_finish_attack_attempt(state, attacker_id, tick, int(projectile["projectile_id"]))
		_queue_event(7, "attack_missed", attacker_id, target_id, {
			"reason": _target_invalid_reason(state, target_id),
			"sequence_id": int(projectile["projectile_id"]),
		})
		return
	impacts.append({
		"attack": attack.duplicate(true),
		"effect_kind": "attack",
		"sequence_id": int(projectile["projectile_id"]),
		"source_actor": projectile["source_actor"].duplicate(true),
		"source_id": attacker_id,
		"target_id": target_id,
	})
	_finish_attack_attempt(state, attacker_id, tick, int(projectile["projectile_id"]))


func _arrive_ground_projectile(
	state: Variant,
	projectile: Dictionary,
	tick: int,
	impacts: Array[Dictionary]
) -> void:
	var attacker_id := int(projectile["source_id"])
	var point: Array = projectile["target_point_mt"]
	var ground_attack: Dictionary = projectile["ground_attack"]
	var attack: Dictionary = projectile["attack"]
	var radius := int(ground_attack["area_radius_mt"])
	var impacted_count := 0
	for target_id: int in _sorted_int_keys(state.combat.actors):
		if not state.entities.has(target_id):
			continue
		var target: EntityRecord = state.entities[target_id]
		var target_actor: Dictionary = state.combat.actors[target_id]
		if not target.alive or target.hp <= 0 or bool(target_actor.get("transported", false)) \
			or str(target_actor.get("layer", "")) not in ground_attack["target_layers"]:
			continue
		var distance_sq := _distance_squared_entity_to_point(target, point)
		if distance_sq > radius * radius:
			continue
		var band_bp := _ground_damage_band_bp(
			distance_sq, radius, ground_attack["damage_bands_bp"]
		)
		var relation_bp := BP_ONE
		if target.owner_seat == int(projectile["source_owner_seat"]):
			relation_bp = int(ground_attack["friendly_fire_bp"])
		if band_bp <= 0 or relation_bp <= 0:
			continue
		var resolved_attack := attack.duplicate(true)
		resolved_attack["damage"] = _mul_bp(
			_mul_bp(int(attack["damage"]), band_bp), relation_bp
		)
		if int(resolved_attack["damage"]) <= 0:
			continue
		impacts.append({
			"attack": resolved_attack,
			"effect_kind": "attack",
			"ground_attack": true,
			"sequence_id": int(projectile["projectile_id"]),
			"source_actor": projectile["source_actor"].duplicate(true),
			"source_id": attacker_id,
			"target_id": target_id,
		})
		impacted_count += 1
	_finish_attack_attempt(state, attacker_id, tick, int(projectile["projectile_id"]))
	_queue_event(7, "ground_attack_landed", attacker_id, 0, {
		"impacted_count": impacted_count,
		"sequence_id": int(projectile["projectile_id"]),
		"target_point_mt": point.duplicate(),
	})


func _resolve_impact_records(state: Variant, impacts: Array[Dictionary], tick: int) -> void:
	var remaining_shield: Dictionary = {}
	for impact: Dictionary in impacts:
		var source_id := int(impact["source_id"])
		var target_id := int(impact["target_id"])
		if not state.entities.has(target_id):
			_queue_event(7, "effect_missed", source_id, target_id, {"reason": "target_missing"})
			continue
		var target_entity: EntityRecord = state.entities[target_id]
		if not target_entity.alive or target_entity.hp <= 0:
			_queue_event(7, "effect_missed", source_id, target_id, {"reason": "target_dead"})
			continue
		var kind := str(impact["effect_kind"])
		if kind == "heal":
			if bool(impact.get("biological_only", true)) and "mechanical" in target_entity.tags:
				_queue_event(7, "heal_rejected", source_id, target_id, {"reason": "mechanical_target"})
				continue
			var heal_amount := int(impact["amount"])
			_queue_hp_delta(tick, target_id, source_id, heal_amount, int(impact["sequence_id"]))
			_queue_event(7, "heal_impacted", source_id, target_id, {
				"amount": heal_amount, "sequence_id": int(impact["sequence_id"]),
			})
			_progress_this_tick = true
			continue

		if not state.combat.actors.has(target_id):
			_queue_event(7, "effect_missed", source_id, target_id, {"reason": "target_not_combat_registered"})
			continue
		var target_actor: Dictionary = state.combat.actors[target_id]
		var attack: Dictionary
		var source_actor: Dictionary
		if kind == "attack":
			attack = impact["attack"]
			source_actor = impact["source_actor"]
		else:
			if str(target_actor["layer"]) not in impact.get("target_layers", []):
				_queue_event(7, "effect_missed", source_id, target_id, {"reason": "invalid_layer"})
				continue
			attack = {
				"attack_type": str(impact["damage_type"]),
				"damage": int(impact["amount"]),
				"impact_kind": "typed_effect",
			}
			source_actor = {
				"attack_upgrade_bp": BP_ONE,
				"elevation": int(target_actor["elevation"]),
				"flat_damage_bonus": 0,
				"source_damage_bp": BP_ONE,
			}
		source_actor = _source_actor_with_statuses(
			state, source_id, source_actor, str(attack["attack_type"]), target_entity
		)
		target_actor = _target_actor_with_statuses(
			state, target_id, target_actor, str(attack["attack_type"])
		)
		var result := calculate_damage(attack, source_actor, target_actor)
		if bool(result["immune"]):
			_queue_event(7, "attack_immune", source_id, target_id, {
				"reason": str(result["reason"]), "sequence_id": int(impact["sequence_id"]),
			})
			continue
		var mitigated := int(result["damage"])
		if mitigated <= 0:
			continue
		if not remaining_shield.has(target_id):
			remaining_shield[target_id] = int(target_actor["shield_hp"])
		var absorbed := mini(int(remaining_shield[target_id]), mitigated)
		remaining_shield[target_id] = int(remaining_shield[target_id]) - absorbed
		var hp_damage := mitigated - absorbed
		if hp_damage > 0:
			_queue_hp_delta(tick, target_id, source_id, -hp_damage, int(impact["sequence_id"]))
		var event_kind := "attack_impacted" if kind == "attack" else "effect_impacted"
		_queue_event(7, event_kind, source_id, target_id, {
			"absorbed_by_shield": absorbed,
			"damage": mitigated,
			"hp_damage": hp_damage,
			"sequence_id": int(impact["sequence_id"]),
		})
		_progress_this_tick = true
	for target_id: int in _sorted_int_keys(remaining_shield):
		_shield_updates[target_id] = int(remaining_shield[target_id])


func _finish_attack_attempt(state: Variant, attacker_id: int, tick: int, sequence_id: int) -> void:
	if not state.combat.actors.has(attacker_id):
		return
	var actor: Dictionary = state.combat.actors[attacker_id]
	if int(actor["pending_attack_sequence_id"]) == sequence_id:
		actor["pending_attack_sequence_id"] = 0
	var attack: Dictionary = actor["attack"]
	var effective := _effective_cooldown(state.combat, attacker_id, int(attack["cooldown_ticks"]))
	actor["cooldown_until_tick"] = tick + effective
	_queue_event(7, "attack_cooldown_started", attacker_id, 0, {
		"cooldown_ticks": effective,
		"ready_tick": tick + effective,
		"sequence_id": sequence_id,
	})


func _effective_cooldown(combat_state: CombatState, actor_id: int, base_ticks: int) -> int:
	var actor: Dictionary = combat_state.actors[actor_id]
	var speed_bp := int(actor["net_attack_speed_bp"])
	for status_id: int in _sorted_int_keys(combat_state.statuses):
		var status: Dictionary = combat_state.statuses[status_id]
		if int(status["target_id"]) == actor_id and str(status["status_kind"]) == "attack_speed_bp":
			speed_bp += int(status["magnitude"])
	speed_bp = clampi(speed_bp, -5_000, 10_000)
	var denominator := BP_ONE + speed_bp
	@warning_ignore("integer_division")
	return maxi(1, (base_ticks * BP_ONE + denominator - 1) / denominator)


func _attack_request_reason(state: Variant, attacker_id: int, target_id: int) -> String:
	if not state.combat.enabled:
		return "combat_not_configured"
	if not state.entities.has(attacker_id) or not state.combat.actors.has(attacker_id):
		return "attacker_missing"
	var attacker: EntityRecord = state.entities[attacker_id]
	if not attacker.alive or attacker.hp <= 0:
		return "attacker_dead"
	var actor: Dictionary = state.combat.actors[attacker_id]
	var attack: Dictionary = actor["attack"]
	if not bool(attack.get("enabled", false)):
		return "attack_disabled"
	if not state.entities.has(target_id) or not state.combat.actors.has(target_id):
		return "target_missing"
	var target: EntityRecord = state.entities[target_id]
	if not target.alive or target.hp <= 0:
		return "target_dead"
	if attacker.owner_seat == target.owner_seat:
		return "not_hostile"
	var target_actor: Dictionary = state.combat.actors[target_id]
	if str(target_actor["layer"]) not in attack["target_layers"]:
		return "invalid_layer"
	if bool(target_actor["transported"]):
		return "target_transported"
	if not bool(target_actor["visible"]):
		return "target_not_visible"
	return ""


func _ground_attack_request_reason(
	state: Variant,
	attacker_id: int,
	target_point_mt: Array
) -> String:
	if not state.combat.enabled:
		return "combat_not_configured"
	if not state.entities.has(attacker_id) or not state.combat.actors.has(attacker_id):
		return "attacker_missing"
	var attacker: EntityRecord = state.entities[attacker_id]
	if not attacker.alive or attacker.hp <= 0:
		return "attacker_dead"
	if target_point_mt.size() != 2 \
		or typeof(target_point_mt[0]) != TYPE_INT \
		or typeof(target_point_mt[1]) != TYPE_INT \
		or int(target_point_mt[0]) < 0 or int(target_point_mt[1]) < 0:
		return "invalid_target"
	var actor: Dictionary = state.combat.actors[attacker_id]
	if bool(actor.get("transported", false)):
		return "attacker_unavailable"
	var attack: Dictionary = actor["attack"]
	if not bool(attack.get("enabled", false)):
		return "attack_disabled"
	var ground_attack: Dictionary = actor.get(
		"ground_attack", _disabled_ground_attack_profile()
	)
	if not bool(ground_attack.get("enabled", false)):
		return "ground_attack_unsupported"
	if str(attack.get("impact_kind", "")) != IMPACT_PROJECTILE \
		or int(attack.get("projectile_speed_mt_per_tick", 0)) <= 0:
		return "ground_attack_unsupported"
	var distance_sq := _distance_squared_to_point(attacker, target_point_mt)
	var maximum := int(ground_attack["cast_range_mt"])
	var minimum := int(ground_attack["minimum_range_mt"])
	if distance_sq > maximum * maximum or distance_sq < minimum * minimum:
		return "out_of_range"
	return ""


func _target_valid_after_launch(state: Variant, attacker_id: int, target_id: int, attack: Dictionary) -> bool:
	if not state.entities.has(target_id) or not state.combat.actors.has(target_id):
		return false
	var target: EntityRecord = state.entities[target_id]
	var target_actor: Dictionary = state.combat.actors[target_id]
	if not target.alive or target.hp <= 0 or bool(target_actor["transported"]):
		return false
	if str(target_actor["layer"]) not in attack["target_layers"]:
		return false
	if state.entities.has(attacker_id):
		var attacker: EntityRecord = state.entities[attacker_id]
		if attacker.owner_seat == target.owner_seat:
			return false
	return true


func _target_invalid_reason(state: Variant, target_id: int) -> String:
	if not state.entities.has(target_id) or not state.combat.actors.has(target_id):
		return "target_missing"
	var target: EntityRecord = state.entities[target_id]
	var target_actor: Dictionary = state.combat.actors[target_id]
	if not target.alive or target.hp <= 0:
		return "target_dead"
	if bool(target_actor["invulnerable"]):
		return "target_invulnerable"
	if bool(target_actor["transported"]):
		return "target_transported"
	return "target_invalid"


func _in_attack_range(state: Variant, attacker_id: int, target_id: int, attack: Dictionary) -> bool:
	if not state.entities.has(attacker_id) or not state.entities.has(target_id):
		return false
	var distance_sq := _distance_squared(state.entities[attacker_id], state.entities[target_id])
	var maximum := int(attack["attack_range_mt"])
	var minimum := int(attack["minimum_range_mt"])
	return distance_sq <= maximum * maximum and distance_sq >= minimum * minimum


static func _distance_squared(source: EntityRecord, target: EntityRecord) -> int:
	var dx := target.position_x_mt - source.position_x_mt
	var dy := target.position_y_mt - source.position_y_mt
	return dx * dx + dy * dy


static func _distance_squared_to_point(source: EntityRecord, point: Array) -> int:
	var dx := int(point[0]) - source.position_x_mt
	var dy := int(point[1]) - source.position_y_mt
	return dx * dx + dy * dy


static func _distance_squared_entity_to_point(target: EntityRecord, point: Array) -> int:
	var dx := target.position_x_mt - int(point[0])
	var dy := target.position_y_mt - int(point[1])
	return dx * dx + dy * dy


static func _ground_damage_band_bp(
	distance_squared: int,
	radius_mt: int,
	bands_variant: Variant
) -> int:
	var bands: Array = bands_variant if typeof(bands_variant) == TYPE_ARRAY else []
	if bands.is_empty() or radius_mt <= 0:
		return 0
	if bands.size() == 1:
		return int(bands[0])
	var distance := _ceil_sqrt(distance_squared)
	@warning_ignore("integer_division")
	var index := mini(bands.size() - 1, (distance * bands.size()) / radius_mt)
	return int(bands[index])


static func _travel_ticks(distance_squared: int, speed_mt_per_tick: int) -> int:
	if distance_squared <= 0:
		return 0
	var distance := _ceil_sqrt(distance_squared)
	@warning_ignore("integer_division")
	return (distance + speed_mt_per_tick - 1) / speed_mt_per_tick


static func _ceil_sqrt(value: int) -> int:
	if value <= 0:
		return 0
	var low := 1
	var high := value
	while low < high:
		@warning_ignore("integer_division")
		var middle := low + (high - low) / 2
		if middle > value / middle:
			high = middle
		elif middle * middle >= value:
			high = middle
		else:
			low = middle + 1
	return low


static func _mul_bp(value: int, multiplier_bp: int) -> int:
	@warning_ignore("integer_division")
	return (value * multiplier_bp) / BP_ONE


static func _damage_source_snapshot(actor: Dictionary) -> Dictionary:
	return {
		"attack_upgrade_bp": int(actor["attack_upgrade_bp"]),
		"elevation": int(actor["elevation"]),
		"flat_damage_bonus": int(actor["flat_damage_bonus"]),
		"source_damage_bp": int(actor["source_damage_bp"]),
	}


func _status_blocks_attack(combat_state: CombatState, actor_id: int) -> bool:
	for status_id: int in _sorted_int_keys(combat_state.statuses):
		var status: Dictionary = combat_state.statuses[status_id]
		if int(status["target_id"]) == actor_id and str(status["status_kind"]) in [
			"disable", "disable_attack", "stun",
		]:
			return true
	return false


func _source_actor_with_statuses(
	state: Variant,
	source_id: int,
	base_actor: Dictionary,
	attack_type: String,
	target_entity: EntityRecord
) -> Dictionary:
	var result := base_actor.duplicate(true)
	var additive_damage_bp := 0
	var flat_bonus := int(result.get("flat_damage_bonus", 0))
	for status_id: int in _sorted_int_keys(state.combat.statuses):
		var status: Dictionary = state.combat.statuses[status_id]
		if int(status["target_id"]) != source_id:
			continue
		var magnitude := int(status["magnitude"])
		match str(status["status_kind"]):
			"damage_dealt_bp": additive_damage_bp += magnitude
			"physical_damage_bp":
				if attack_type in ["arcane", "blade", "hero", "pierce", "siege"]:
					additive_damage_bp += magnitude
			"hero_damage_flat":
				if attack_type == "hero": flat_bonus += magnitude
			"final_damage_bp":
				if "air" in target_entity.tags: additive_damage_bp += magnitude
			"structure_damage_bp":
				if "structure" in target_entity.tags: additive_damage_bp += magnitude
	result["flat_damage_bonus"] = flat_bonus
	result["source_damage_bp"] = maxi(
		0, int(result.get("source_damage_bp", BP_ONE)) + additive_damage_bp
	)
	return result


func _target_actor_with_statuses(
	state: Variant, target_id: int, base_actor: Dictionary, attack_type: String
) -> Dictionary:
	var result := base_actor.duplicate(true)
	var damage_taken_delta := 0
	var resistance_delta := 0
	for status_id: int in _sorted_int_keys(state.combat.statuses):
		var status: Dictionary = state.combat.statuses[status_id]
		if int(status["target_id"]) != target_id:
			continue
		var magnitude := int(status["magnitude"])
		match str(status["status_kind"]):
			"armor_centi": result["armor_centi"] = int(result["armor_centi"]) + magnitude
			"damage_received_bp", "damage_taken_from_owner_bp":
				damage_taken_delta += magnitude
			"physical_damage_received_bp":
				if attack_type in ["arcane", "blade", "hero", "pierce", "siege"]:
					damage_taken_delta += magnitude
			"pierce_damage_received_bp":
				if attack_type == "pierce": damage_taken_delta += magnitude
			"siege_damage_taken_bp":
				if attack_type == "siege": damage_taken_delta += magnitude
			"spell_resistance_bp":
				if attack_type == "spell": resistance_delta -= magnitude
			"magic_immunity":
				if magnitude > 0: result["magic_immune"] = true
	result["damage_taken_bp"] = maxi(
		0, int(result.get("damage_taken_bp", BP_ONE)) + damage_taken_delta
	)
	result["resistance_bp"] = maxi(
		0, int(result.get("resistance_bp", BP_ONE)) + resistance_delta
	)
	return result


func _clear_stale_core_order(state: Variant, actor_id: int) -> void:
	if not state.combat.attack_orders.has(actor_id):
		return
	var order: Dictionary = state.combat.attack_orders[actor_id]
	if str(order["order_source"]) == "core_order":
		state.combat.attack_orders.erase(actor_id)
		_cancel_actor_windup(state, actor_id, "core_order_inactive")


func _cancel_actor_windup(state: Variant, actor_id: int, reason: String) -> void:
	if not state.combat.actors.has(actor_id):
		return
	var actor: Dictionary = state.combat.actors[actor_id]
	var sequence_id := int(actor["pending_attack_sequence_id"])
	if sequence_id == 0:
		return
	if state.combat.windups.has(sequence_id):
		var windup: Dictionary = state.combat.windups[sequence_id]
		state.combat.windups.erase(sequence_id)
		actor["pending_attack_sequence_id"] = 0
		_queue_event(10, "attack_windup_cancelled", actor_id, int(windup.get("target_id", 0)), {
			"reason": reason, "sequence_id": sequence_id,
		})


func _queue_hp_delta(tick: int, target_id: int, source_id: int, amount: int, local_seq: int) -> void:
	var delta := DeltaRecord.new()
	delta.application_tick = tick
	delta.entity_id = target_id
	delta.kind = DeltaRecord.Kind.HP
	delta.amount = amount
	delta.source_internal_id = source_id
	delta.local_seq = local_seq
	_deltas.append(delta)


func _queue_event(phase: int, kind: String, source_id: int, target_id: int, payload: Dictionary) -> void:
	_events.append({
		"event_kind": kind,
		"payload": payload,
		"phase": phase,
		"source_internal_id": source_id,
		"target_internal_id": target_id,
	})


static func _impact_less(left: Dictionary, right: Dictionary) -> bool:
	for field: String in ["target_id", "source_id", "sequence_id"]:
		var left_value := int(left[field])
		var right_value := int(right[field])
		if left_value != right_value:
			return left_value < right_value
	return str(left["effect_kind"]) < str(right["effect_kind"])


static func _next_sequence(combat_state: CombatState) -> int:
	var result := combat_state.next_sequence_id
	combat_state.next_sequence_id += 1
	return result


static func _sorted_int_keys(source: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for value: Variant in source.keys():
		result.append(int(value))
	result.sort()
	return result


static func _sorted_strings(source: Array[String]) -> Array[String]:
	var result: Array[String] = source.duplicate()
	result.sort()
	return result


static func _normalized_string_set(source: Variant) -> Array[String]:
	var result: Array[String] = []
	if typeof(source) != TYPE_ARRAY:
		return result
	for value: Variant in source:
		var item := str(value)
		if item not in result:
			result.append(item)
	result.sort()
	return result
