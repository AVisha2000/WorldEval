extends SceneTree

const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")

const GOLDEN_SCENARIO_HASH := "f9ac2cd7cd3610dae64455ee9fad1c9373e8fa42f8f20bb51695723b4d5031b8"

var _failures := PackedStringArray()
var _attack_armor: Dictionary = {}
var _faction: Dictionary = {}
var _rules: Dictionary = {}


func _init() -> void:
	_attack_armor = _load_json("res://../game/duel_protocol/catalogs/attack-armor.duel-v1.json")
	_faction = _load_json("res://../game/duel_protocol/catalogs/factions/vanguard-v1.json")
	_rules = _load_json("res://../game/duel_protocol/catalogs/rules.duel-v1.json")
	_test_catalog_matrix_and_integer_pipeline()
	_test_projectile_windup_arrival_and_cooldown()
	_test_simultaneous_trade_heal_shield_and_event_order()
	_test_layers_statuses_and_stale_targets()
	_test_typed_effect_immunity_and_input_rejection()
	_test_mirrored_outcome()
	var first := _run_golden_scenario(false)
	var second := _run_golden_scenario(true)
	_check(str(first["hash"]) == str(second["hash"]), "shuffled insertion changed combat checkpoint")
	_check(first["summary"] == second["summary"], "shuffled insertion changed combat outcome")
	if not GOLDEN_SCENARIO_HASH.is_empty():
		_check(str(first["hash"]) == GOLDEN_SCENARIO_HASH, "combat golden hash changed: %s" % first["hash"])
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_COMBAT_FAILURE: %s" % failure)
		print("DUEL_COMBAT_FAILED count=%d hash=%s" % [_failures.size(), first["hash"]])
		quit(1)
		return
	print("DUEL_COMBAT_OK hash=%s summary=%s" % [first["hash"], JSON.stringify(first["summary"])])
	quit(0)


func _test_catalog_matrix_and_integer_pipeline() -> void:
	var sim := _new_sim()
	var attack := {"attack_type": "blade", "damage": 100, "impact_kind": "contact_check"}
	var source := _source_actor(0)
	var target := _target_actor("medium", 0, 0)
	_check(int(sim.combat.calculate_damage(attack, source, target)["damage"]) == 125, "Blade/Medium matrix example is wrong")
	attack = {"attack_type": "pierce", "damage": 100, "impact_kind": "authoritative_homing_projectile"}
	target = _target_actor("light", 100, 0)
	_check(int(sim.combat.calculate_damage(attack, source, target)["damage"]) == 141, "Pierce/Light plus positive armor example is wrong")
	attack = {"attack_type": "blade", "damage": 100, "impact_kind": "contact_check"}
	target = _target_actor("heavy", -200, 0)
	_check(int(sim.combat.calculate_damage(attack, source, target)["damage"]) == 112, "negative armor example is wrong")
	attack = {"attack_type": "pierce", "damage": 100, "impact_kind": "authoritative_homing_projectile"}
	source["elevation"] = 0
	target = _target_actor("medium", 0, 1)
	_check(int(sim.combat.calculate_damage(attack, source, target)["damage"]) == 80, "fixed lower-to-higher ranged penalty is wrong")
	attack = {"attack_type": "spell", "damage": 100, "impact_kind": "typed_effect"}
	target = _target_actor("fortified", 1_000, 2)
	_check(int(sim.combat.calculate_damage(attack, source, target)["damage"]) == 100, "spell damage used matrix, elevation, or armor")
	target["magic_immune"] = true
	var immune: Dictionary = sim.combat.calculate_damage(attack, source, target)
	_check(bool(immune["immune"]) and int(immune["damage"]) == 0, "magic immunity did not reject spell damage")
	_check(sim.combat.armor_multiplier_bp(200) == 8_928, "positive centi-armor formula is wrong")
	_check(sim.combat.armor_multiplier_bp(-200) == 11_200, "negative centi-armor formula is wrong")
	var tower: Dictionary = sim.state.combat.catalog_profiles["vanguard-v1:structure:tower"]
	_check(int(tower["attack"]["damage"]) == 20, "shared rules did not compile the faction tower attack")


func _test_projectile_windup_arrival_and_cooldown() -> void:
	var sim := _new_sim()
	_add_and_register(sim, _entity(10, 0, "vanguard-longbow", 2_250, 2_250, 340, ["biological", "ground", "ranged"]), "unit", "longbow")
	_add_and_register(sim, _entity(20, 1, "vanguard-footguard", 14_250, 2_250, 520, ["biological", "ground", "melee"]), "unit", "footguard")
	_check(bool(sim.combat.issue_attack(sim.state, 10, 20)["accepted"]), "legal projectile attack was rejected")
	for _tick: int in 7:
		sim.step_tick()
	_check(sim.state.entities[20].hp == 520, "projectile damaged before arrival")
	_check(sim.state.combat.projectiles.size() == 1, "projectile was not authoritative after wind-up")
	var projectile: Dictionary = sim.state.combat.projectiles.values()[0]
	_check(int(projectile["launch_tick"]) == 6 and int(projectile["arrival_tick"]) == 12, "wind-up/travel schedule is wrong")
	_check(int(sim.state.combat.actors[10]["cooldown_until_tick"]) == 0, "cooldown started before projectile impact")
	for _tick: int in 6:
		sim.step_tick()
	_check(sim.state.tick == 13, "projectile timing fixture advanced wrong tick count")
	_check(sim.state.entities[20].hp == 504, "official Longbow impact mitigation is wrong")
	_check(int(sim.state.combat.actors[10]["cooldown_until_tick"]) == 28, "cooldown did not start at impact")
	_check(sim.state.combat.projectiles.is_empty(), "arrived projectile remained in state")
	_check(_event_tick(sim, "projectile_launched") == 6, "projectile launch event tick is wrong")
	_check(_event_tick(sim, "attack_impacted") == 12, "projectile impact event tick is wrong")


func _test_simultaneous_trade_heal_shield_and_event_order() -> void:
	var trade := _melee_pair_sim(false, 20, 20)
	trade.combat.issue_attack(trade.state, 10, 20)
	trade.combat.issue_attack(trade.state, 20, 10)
	for _tick: int in 2:
		trade.step_tick()
	_check(not trade.state.entities[10].alive and not trade.state.entities[20].alive, "simultaneous lethal attacks did not trade")
	var deaths: Array[int] = []
	for event_variant: Variant in trade.state.events:
		if event_variant.event_kind == "entity_died":
			deaths.append(event_variant.source_internal_id)
	_check(deaths == [10, 20], "mutual death events were not in stable entity-ID order")
	_check(_events_are_monotonic(trade), "event sequence/order is not monotonic")

	var healed := _melee_pair_sim(false, 20, 20)
	healed.combat.issue_attack(healed.state, 10, 20)
	healed.combat.schedule_heal_effect(healed.state, 20, 20, 10, 1, true)
	for _tick: int in 2:
		healed.step_tick()
	_check(healed.state.entities[20].alive and healed.state.entities[20].hp == 5, "same-tick damage/healing did not net from pre-impact HP")

	var shielded := _melee_pair_sim(false, 20, 20, 10)
	shielded.combat.issue_attack(shielded.state, 10, 20)
	for _tick: int in 2:
		shielded.step_tick()
	_check(shielded.state.entities[20].hp == 5, "shield did not absorb before HP")
	_check(int(shielded.state.combat.actors[20]["shield_hp"]) == 0, "depleted shield was not applied in phase 9")


func _test_layers_statuses_and_stale_targets() -> void:
	var layer_sim := _new_sim()
	_add_and_register(layer_sim, _entity(10, 0, "vanguard-footguard", 1_250, 1_250, 100, ["ground"]), "unit", "footguard")
	_add_and_register(layer_sim, _entity(20, 1, "vanguard-sky-griffin", 2_250, 1_250, 100, ["air"]), "unit", "sky_griffin")
	var layer_receipt: Dictionary = layer_sim.combat.issue_attack(layer_sim.state, 10, 20)
	_check(not bool(layer_receipt["accepted"]) and layer_receipt["code"] == "invalid_layer", "ground-only melee accepted an air target")
	_add_and_register(layer_sim, _entity(30, 0, "vanguard-longbow", 4_250, 1_250, 100, ["ground", "ranged"]), "unit", "longbow")
	_check(bool(layer_sim.combat.issue_attack(layer_sim.state, 30, 20)["accepted"]), "catalogued anti-air ranged attack rejected an air target")

	var status_sim := _melee_pair_sim(false, 100, 100)
	status_sim.combat.add_status(status_sim.state, 10, 20, "stun", "control:stun", 1, 1)
	status_sim.combat.add_status(status_sim.state, 10, 10, "attack_speed_bp", "speed:attack", 10_000, 20)
	status_sim.combat.issue_attack(status_sim.state, 10, 20)
	status_sim.step_tick()
	_check(status_sim.state.combat.windups.is_empty(), "stunned actor began a wind-up")
	status_sim.step_tick()
	_check(status_sim.state.combat.windups.size() == 1, "actor did not attack after deterministic stun expiry")
	_check(_event_tick(status_sim, "status_expired") == 1, "status did not expire in phase 2 on exact tick")
	status_sim.step_tick()
	_check(int(status_sim.state.combat.actors[10]["cooldown_until_tick"]) == 7, "basis-point attack speed did not use capped integer ceil cooldown")

	var stale := _new_sim()
	_add_and_register(stale, _entity(10, 0, "vanguard-longbow", 2_250, 2_250, 340, ["ground", "ranged"]), "unit", "longbow")
	_add_and_register(stale, _entity(20, 1, "vanguard-footguard", 14_250, 2_250, 100, ["ground"]), "unit", "footguard")
	stale.combat.issue_attack(stale.state, 10, 20)
	for _tick: int in 7:
		stale.step_tick()
	stale.state.entities[20].hp = 0
	stale.step_tick()
	_check(not stale.state.entities[20].alive, "zero-HP projectile target did not die in lifecycle")
	for _tick: int in 5:
		stale.step_tick()
	_check(_event_payload_reason(stale, "attack_missed") == "target_dead", "projectile did not safely miss a dead stale target")
	_check(stale.state.entities[20].hp == 0, "stale projectile changed a dead target")
	var dead_receipt: Dictionary = stale.combat.issue_attack(stale.state, 10, 20)
	_check(not bool(dead_receipt["accepted"]) and dead_receipt["code"] == "target_dead", "direct attack accepted a dead target")


func _test_mirrored_outcome() -> void:
	var original := _melee_pair_sim(false, 20, 20)
	var mirrored := _new_sim()
	var mirror_a := _entity(10, 1, "vanguard-footguard", 18_750, 1_250, 20, ["biological", "ground", "melee"])
	var mirror_b := _entity(20, 0, "vanguard-footguard", 17_750, 1_250, 20, ["biological", "ground", "melee"])
	var override := {"armor_centi": 0, "attack": {"cooldown_ticks": 10, "damage": 20, "windup_ticks": 1}}
	_add_and_register(mirrored, mirror_a, "unit", "footguard", override)
	_add_and_register(mirrored, mirror_b, "unit", "footguard", override)
	for sim: Simulation in [original, mirrored]:
		sim.combat.issue_attack(sim.state, 10, 20)
		sim.combat.issue_attack(sim.state, 20, 10)
		for _tick: int in 2:
			sim.step_tick()
	_check(original.state.entities[10].alive == mirrored.state.entities[10].alive, "side/position mirror changed actor 10 outcome")
	_check(original.state.entities[20].alive == mirrored.state.entities[20].alive, "side/position mirror changed actor 20 outcome")
	_check(original.state.entities[10].hp == mirrored.state.entities[10].hp, "side/position mirror changed actor 10 HP")
	_check(original.state.entities[20].hp == mirrored.state.entities[20].hp, "side/position mirror changed actor 20 HP")


func _test_typed_effect_immunity_and_input_rejection() -> void:
	var sim := _new_sim()
	_add_and_register(sim, _entity(10, 0, "vanguard-arcanist", 1_250, 1_250, 100, ["biological", "ground"]), "unit", "arcanist")
	_add_and_register(sim, _entity(20, 1, "vanguard-footguard", 2_250, 1_250, 100, ["biological", "ground"]), "unit", "footguard", {"magic_immune": true})
	sim.combat.schedule_damage_effect(sim.state, 10, 20, 100, "spell", 0)
	sim.step_tick()
	_check(sim.state.entities[20].hp == 100, "spell damaged a magic-immune target")
	_check(_event_payload_reason(sim, "attack_immune") == "magic_immune", "immune impact did not emit its explicit reason")

	var mechanical := _entity(30, 1, "vanguard-bombard", 3_250, 1_250, 100, ["ground", "mechanical"])
	_add_and_register(sim, mechanical, "unit", "bombard")
	mechanical.hp = 50
	sim.combat.schedule_heal_effect(sim.state, 10, 30, 20, sim.state.tick, true)
	sim.step_tick()
	_check(mechanical.hp == 50, "biological healing affected a mechanical target")
	_check(_event_payload_reason(sim, "heal_rejected") == "mechanical_target", "mechanical heal rejection was not explicit")

	var malformed := _entity(40, 0, "vanguard-footguard", 4_250, 1_250, 100, ["ground"])
	_check(sim.add_entity(malformed) == 40, "malformed-override fixture entity failed to add")
	var errors := sim.register_combat_entity(40, "unit", "footguard", {"armor_centi": 1.5})
	_check(not errors.is_empty() and not sim.state.combat.actors.has(40), "authoritative float override was accepted")


func _run_golden_scenario(reverse_insertion: bool) -> Dictionary:
	var sim := _melee_pair_sim(reverse_insertion, 80, 80, 8)
	## Core durable attack orders exercise the controller-to-kernel boundary.
	var order_a := OrderRecord.new(101, 0, 10, "attack_entity")
	order_a.issued_tick = 0
	order_a.activation_tick = 0
	order_a.command_index = 0
	order_a.target = {"entity_id": 20}
	var order_b := OrderRecord.new(102, 1, 20, "attack_entity")
	order_b.issued_tick = 0
	order_b.activation_tick = 0
	order_b.command_index = 0
	order_b.target = {"entity_id": 10}
	if reverse_insertion:
		sim.queue_order(order_b)
		sim.queue_order(order_a)
	else:
		sim.queue_order(order_a)
		sim.queue_order(order_b)
	sim.combat.add_status(sim.state, 10, 20, "attack_speed_bp", "speed:attack", 10_000, 20)
	sim.combat.schedule_heal_effect(sim.state, 10, 10, 7, 1, true)
	for _tick: int in 14:
		sim.step_tick()
	_check(sim.validate().is_empty(), "combat scenario failed validation: %s" % "; ".join(sim.validate()))
	var event_counts: Dictionary = {}
	for event_variant: Variant in sim.state.events:
		var kind := str(event_variant.event_kind)
		event_counts[kind] = int(event_counts.get(kind, 0)) + 1
	var summary := {
		"actor_10_alive": sim.state.entities[10].alive,
		"actor_10_hp": sim.state.entities[10].hp,
		"actor_20_alive": sim.state.entities[20].alive,
		"actor_20_hp": sim.state.entities[20].hp,
		"attack_impacts": int(event_counts.get("attack_impacted", 0)),
		"deaths": int(event_counts.get("entity_died", 0)),
		"events": sim.state.events.size(),
		"tick": sim.state.tick,
	}
	return {"hash": sim.checkpoint_hash(), "summary": summary}


func _melee_pair_sim(reverse_insertion: bool, hp_a: int, hp_b: int, shield_b: int = 0) -> Simulation:
	var sim := _new_sim()
	var a := _entity(10, 0, "vanguard-footguard", 1_250, 1_250, hp_a, ["biological", "ground", "melee"])
	var b := _entity(20, 1, "vanguard-footguard", 2_250, 1_250, hp_b, ["biological", "ground", "melee"])
	var attack_override := {
		"attack": {"cooldown_ticks": 10, "damage": 20, "windup_ticks": 1},
		"armor_centi": 0,
	}
	if reverse_insertion:
		_add_and_register(sim, b, "unit", "footguard", {"armor_centi": 0, "shield_hp": shield_b, "attack": attack_override["attack"]})
		_add_and_register(sim, a, "unit", "footguard", attack_override)
	else:
		_add_and_register(sim, a, "unit", "footguard", attack_override)
		_add_and_register(sim, b, "unit", "footguard", {"armor_centi": 0, "shield_hp": shield_b, "attack": attack_override["attack"]})
	return sim


func _new_sim() -> Simulation:
	var sim := Simulation.new({"grid_height": 32, "grid_width": 40, "match_seed": 41_904})
	var errors := sim.configure_combat(_attack_armor, _faction, _rules)
	_check(errors.is_empty(), "official combat catalogs failed to configure: %s" % "; ".join(errors))
	return sim


func _add_and_register(
	sim: Simulation,
	entity: EntityRecord,
	section: String,
	catalog_key: String,
	overrides: Dictionary = {}
) -> void:
	_check(sim.add_entity(entity, entity.owner_seat >= 0 and "air" not in entity.tags) == entity.internal_id, "combat entity failed to add")
	_check(sim.register_combat_entity(entity.internal_id, section, catalog_key, overrides).is_empty(), "combat entity failed to register")


func _entity(
	entity_id: int,
	owner: int,
	catalog_id: String,
	x_mt: int,
	y_mt: int,
	hp: int,
	tags: Array[String]
) -> EntityRecord:
	var entity := EntityRecord.new(entity_id, owner, "unit")
	entity.catalog_id = catalog_id
	entity.max_hp = hp
	entity.hp = hp
	entity.radius_mt = 0
	entity.set_position_mt(x_mt, y_mt)
	entity.tags.assign(tags)
	return entity


func _source_actor(elevation: int) -> Dictionary:
	return {
		"attack_upgrade_bp": 10_000,
		"elevation": elevation,
		"flat_damage_bonus": 0,
		"source_damage_bp": 10_000,
	}


func _target_actor(armor_class: String, armor_centi: int, elevation: int) -> Dictionary:
	return {
		"armor_centi": armor_centi,
		"armor_class": armor_class,
		"damage_taken_bp": 10_000,
		"elevation": elevation,
		"invulnerable": false,
		"magic_immune": false,
		"resistance_bp": 10_000,
	}


func _event_tick(sim: Simulation, kind: String) -> int:
	for event_variant: Variant in sim.state.events:
		if event_variant.event_kind == kind:
			return event_variant.tick
	return -1


func _event_payload_reason(sim: Simulation, kind: String) -> String:
	for event_variant: Variant in sim.state.events:
		if event_variant.event_kind == kind:
			return str(event_variant.payload.get("reason", ""))
	return ""


func _events_are_monotonic(sim: Simulation) -> bool:
	var expected := 1
	var previous_tick := -1
	var previous_phase := -1
	for event_variant: Variant in sim.state.events:
		if event_variant.event_seq != expected:
			return false
		if event_variant.tick < previous_tick:
			return false
		if event_variant.tick == previous_tick and event_variant.phase < previous_phase:
			return false
		expected += 1
		previous_tick = event_variant.tick
		previous_phase = event_variant.phase
	return true


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		_failures.append("missing fixture catalog: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_failures.append("invalid fixture catalog JSON: %s" % path)
		return {}
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	if not bool(normalized["ok"]):
		_failures.append("fixture catalog is not integer authoritative: %s" % path)
		return {}
	return normalized["value"]


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
