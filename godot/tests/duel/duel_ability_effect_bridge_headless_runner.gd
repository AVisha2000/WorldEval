extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const MatchRuntime := preload("res://scripts/duel/match/duel_match_runtime.gd")
const EffectBridge := preload("res://scripts/duel/abilities/duel_ability_effect_bridge.gd")
const Contract := preload("res://scripts/duel/abilities/duel_ability_contract.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const TIE_KEY := "worldarena-ability-effect-bridge-conformance-v1"
const GOLDEN_HASH := "53ebe3c8c4585200467e5effdcaa085c648bf15fe7763258f907c5a632ae9a60"

var _failures := PackedStringArray()
var _official_100_tick_ms: int = -1


func _init() -> void:
	if "--effect-perf-only" in OS.get_cmdline_user_args():
		_run_performance_probe()
		quit(0 if _failures.is_empty() else 1)
		return
	_test_contract_fail_closed()
	var first := _coverage_scenario(false)
	var second := _coverage_scenario(true)
	_check(first.get("hash", "") == second.get("hash", ""),
		"effect bridge state depends on input insertion order")
	_check(first.get("summary", {}) == second.get("summary", {}),
		"effect bridge summary depends on input insertion order")
	_test_active_authority_mutations()
	_test_faction_summons_and_regeneration()
	var hash := str(first.get("hash", ""))
	if not GOLDEN_HASH.is_empty():
		_check(hash == GOLDEN_HASH, "ability effect bridge golden changed: %s" % hash)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_ABILITY_EFFECT_BRIDGE_FAILURE: %s" % failure)
		print("DUEL_ABILITY_EFFECT_BRIDGE_FAILED count=%d hash=%s" % [
			_failures.size(), hash,
		])
		quit(1)
		return
	print("DUEL_ABILITY_EFFECT_BRIDGE_OK hash=%s perf_100_ticks_ms=%d summary=%s" % [
		hash, _official_100_tick_ms, JSON.stringify(first.get("summary", {})),
	])
	quit(0)


func _run_performance_probe() -> void:
	var simulation: Variant = _official_simulation("vanguard-v1", 90_900)
	if simulation == null:
		return
	for index: int in range(0, 10):
		var started := Time.get_ticks_usec()
		simulation.step_tick(false)
		print("DUEL_ABILITY_EFFECT_PERF enabled tick=%d ms=%d statuses=%d events=%d" % [
			simulation.state.tick,
			int((Time.get_ticks_usec() - started) / 1_000),
			simulation.state.combat.statuses.size(),
			simulation.state.events.size(),
		])
	simulation.ledger.abilities = null
	simulation.ledger.ability_effects = null
	for index: int in range(0, 10):
		var started := Time.get_ticks_usec()
		simulation.step_tick(false)
		print("DUEL_ABILITY_EFFECT_PERF disabled tick=%d ms=%d statuses=%d events=%d" % [
			simulation.state.tick,
			int((Time.get_ticks_usec() - started) / 1_000),
			simulation.state.combat.statuses.size(),
			simulation.state.events.size(),
		])


func _test_contract_fail_closed() -> void:
	var bridge := EffectBridge.new()
	_check(bridge.configure("vanguard-v1").is_empty(), "bridge configuration failed")
	_check(bridge.validate().is_empty(), "bridge rejected its closed dispatch")
	var primitives: Dictionary = {}
	for primitive_variant: Variant in Contract.EFFECT_DISPATCH.values():
		primitives[str(primitive_variant)] = true
	_check(Contract.EFFECT_DISPATCH.size() == 109, "locked effect vocabulary is not 109")
	_check(primitives.size() == 27, "locked primitive family vocabulary is not 27")
	_check(EffectBridge.SUPPORTED_PRIMITIVE_FAMILIES.size() == 27,
		"bridge does not name all 27 primitive families")


func _coverage_scenario(reverse_input: bool) -> Dictionary:
	var simulation: Variant = _official_simulation("vanguard-v1", 90_001)
	if simulation == null:
		return {"hash": "", "summary": {}}
	var source := _mobile_entity(simulation, 0, 0)
	var ally := _mobile_entity(simulation, 0, 1)
	var enemy := _mobile_entity(simulation, 1, 0)
	_check(source > 0 and ally > 0 and enemy > 0, "coverage fixture lacks mobile actors")
	if source <= 0 or ally <= 0 or enemy <= 0:
		return {"hash": "", "summary": {}}
	_add_tag(simulation.state.entities[enemy], "summon")
	simulation.state.entities[enemy].max_mana = 500
	simulation.state.entities[enemy].mana = 500
	simulation.state.entities[ally].hp = maxi(1, simulation.state.entities[ally].max_hp - 100)
	simulation.state.entities[source].integer_attributes["stored_energy"] = 500
	simulation.state.entities[source].integer_attributes["stored_corpses"] = 5
	var consume_corpse := _add_corpse(simulation, 0, 250)
	var revive_corpse := _add_corpse(simulation, 0, 900)
	var store_corpse := _add_corpse(simulation, 0, 350)
	var point := _find_open_position(simulation, 350)
	var dash_point := _find_open_near(simulation, source, 350, 5_000)
	_check(not point.is_empty() and not dash_point.is_empty(), "coverage fixture has no open target")

	var descriptors := _effect_descriptors(simulation)
	_check(descriptors.size() == 109, "registry did not expose 109 unique effect kinds")
	var intents: Array = []
	var primitive_coverage: Dictionary = {}
	var effect_ids: Dictionary = {}
	var effect_kinds: Dictionary = {}
	var index := 0
	for kind: String in _sorted_string_keys(descriptors):
		var descriptor: Dictionary = descriptors[kind]
		var primitive := str(Contract.EFFECT_DISPATCH[kind])
		primitive_coverage[primitive] = true
		var effect_id := index + 1
		var cast_id := 10_000 + index
		if kind in ["create_illusions", "illusion_damage_bp", "illusion_damage_taken_bp"]:
			cast_id = 8_000
		elif kind in [
			"revive_most_expensive_corpses", "return_hp_bp", "temporary_summon_xp_bp",
		]:
			cast_id = 8_001
		var target_ids: Array = _coverage_targets(
			primitive, kind, source, ally, enemy, consume_corpse, revive_corpse,
			store_corpse
		)
		var target: Dictionary = {"entity_id": target_ids[0], "kind": "entity"} \
			if not target_ids.is_empty() else {"kind": "point", "position_mt": point}
		if primitive == "movement":
			target = {"kind": "point", "position_mt": dash_point}
		elif primitive in ["summon", "corpse"] and kind != "consume_corpse":
			target = {"kind": "point", "position_mt": point}
		var intent := _intent_from_descriptor(
			descriptor, effect_id, cast_id, source, target, target_ids
		)
		intents.append(intent)
		effect_ids[str(effect_id)] = true
		effect_kinds[kind] = true
		index += 1
	if reverse_input:
		intents.reverse()
	var result: Dictionary = simulation.ability_effects.apply_effect_intents(
		simulation, simulation.abilities, intents
	)
	_check(bool(result.get("ok", false)), "109-effect batch failed: %s" % _errors(result))
	_check(int(result.get("applied", 0)) == 109, "not every locked effect was applied")
	_check(primitive_coverage.size() == 27, "batch did not exercise all 27 primitive families")
	_check(effect_kinds.size() == 109 and effect_ids.size() == 109,
		"batch coverage bookkeeping is incomplete")
	var duplicate: Dictionary = simulation.ability_effects.apply_effect_intents(
		simulation, simulation.abilities, intents
	)
	_check(bool(duplicate.get("ok", false)), "exact replay was not accepted idempotently")
	_check(int(duplicate.get("applied", -1)) == 0 \
		and int(duplicate.get("ignored_duplicates", -1)) == 109,
		"exact replay mutated authoritative state")
	var collision_effect: Dictionary = (intents[0] as Dictionary).duplicate(true)
	collision_effect["primitive_value"] = int(collision_effect["primitive_value"]) + 1
	var collision: Dictionary = simulation.ability_effects.apply_effect_intents(
		simulation, simulation.abilities, [collision_effect]
	)
	_check(not bool(collision.get("ok", true)) and "different content" in _errors(collision),
		"effect-ID content collision did not fail closed")
	var malformed: Dictionary = simulation.ability_effects.apply_effect_intents(
		simulation, simulation.abilities, [{
			"effect_id": 999_999,
			"effect_kind": "spell_damage",
			"primitive_kind": "damage",
		}]
	)
	_check(not bool(malformed.get("ok", true)) and "requires integer" in _errors(malformed),
		"malformed effect intent did not fail closed")
	var valid_sibling: Dictionary = (intents[0] as Dictionary).duplicate(true)
	valid_sibling["cast_id"] = 999_997
	valid_sibling["effect_id"] = 999_997
	var forged_lifecycle: Dictionary = valid_sibling.duplicate(true)
	forged_lifecycle["ability_id"] = "wisp_dissolve"
	forged_lifecycle["cast_id"] = 999_998
	forged_lifecycle["effect_id"] = 999_998
	forged_lifecycle["effect_kind"] = "forged_lifecycle"
	forged_lifecycle["primitive_kind"] = "lifecycle"
	var snapshot_before_mixed := Codec.sha256_canonical(simulation.snapshot())
	var mixed_invalid: Dictionary = simulation.ability_effects.apply_effect_intents(
		simulation, simulation.abilities, [valid_sibling, forged_lifecycle]
	)
	_check(not bool(mixed_invalid.get("ok", true)) \
		and int(mixed_invalid.get("applied", -1)) == 0,
		"mixed invalid effect batch was partially applied")
	_check(Codec.sha256_canonical(simulation.snapshot()) == snapshot_before_mixed,
		"mixed invalid effect batch mutated authoritative state")
	var invalid_timing: Dictionary = valid_sibling.duplicate(true)
	invalid_timing["cast_id"] = 999_996
	invalid_timing["effect_id"] = 999_996
	invalid_timing["impact_tick"] = -1
	var timing_result: Dictionary = simulation.ability_effects.apply_effect_intents(
		simulation, simulation.abilities, [invalid_timing]
	)
	_check(not bool(timing_result.get("ok", true)) and "non-negative" in _errors(timing_result),
		"negative effect timing did not fail closed")
	_check(simulation.validate().is_empty(),
		"109-effect authoritative state is invalid: %s" % "; ".join(simulation.validate()))
	var events: Array = simulation.ability_effects.take_events()
	var summary := {
		"applied": int(result.get("applied", 0)),
		"effect_kinds": effect_kinds.size(),
		"events": events.size(),
		"ignored_duplicates": int(duplicate.get("ignored_duplicates", 0)),
		"primitive_families": primitive_coverage.size(),
		"statuses": simulation.state.combat.statuses.size(),
		"summoned_entities": _tagged_count(simulation, "summon"),
	}
	return {
		"hash": Codec.sha256_canonical({
			"events": events,
			"snapshot": simulation.snapshot(),
			"summary": summary,
		}),
		"summary": summary,
	}


func _test_active_authority_mutations() -> void:
	var simulation: Variant = _official_simulation("vanguard-v1", 90_002)
	if simulation == null:
		return
	var source := _mobile_entity(simulation, 0, 0)
	var ally := _mobile_entity(simulation, 0, 1)
	var enemy := _mobile_entity(simulation, 1, 0)
	var bridge: EffectBridge = simulation.ability_effects
	var ally_entity: EntityRecord = simulation.state.entities[ally]
	ally_entity.hp = ally_entity.max_hp - 50
	var hp_before := ally_entity.hp
	simulation.state.entities[enemy].max_mana = 100
	simulation.state.entities[enemy].mana = 80
	var enemy_hp_before: int = simulation.state.entities[enemy].hp
	var open_near := _find_open_near(simulation, source, 350, 5_000)
	var source_position := [
		simulation.state.entities[source].position_x_mt,
		simulation.state.entities[source].position_y_mt,
	]
	var active: Array = [
		_manual_intent(simulation, "shield", 100_001, source, [ally], {}, 40, 5),
		_manual_intent(simulation, "spell_damage", 100_002, source, [ally], {}, 80, 1),
		_manual_intent(simulation, "restore_hp", 100_003, source, [ally], {}, 20, 1),
		_manual_intent(simulation, "mana_burn", 100_004, source, [enemy], {}, 30, 1),
		_manual_intent(
			simulation, "spell_damage_equal_to_mana_burned", 100_015,
			source, [enemy], {}, 1, 1
		),
		_manual_intent(simulation, "dash", 100_008, source, [], {
			"kind": "point", "position_mt": open_near,
		}, 5_000, 1),
		_manual_intent(simulation, "force_night", 100_009, source, [], {}, 1, 8),
		_manual_intent(simulation, "create_owned_blight", 100_010, source, [source], {}, 1, 2),
		_manual_intent(simulation, "destroy_trees", 100_011, source, [], {}, 1, 1),
	]
	var applied := bridge.apply_effect_intents(simulation, simulation.abilities, active)
	_check(bool(applied.get("ok", false)) and int(applied.get("applied", 0)) == active.size(),
		"active mutation batch failed: %s" % _errors(applied))
	_check(simulation.state.entities[enemy].mana == 50, "mana burn did not mutate exact mana")
	_check(int(simulation.state.combat.actors[ally]["shield_hp"]) == 40,
		"shield did not attach to combat authority")
	_check(source_position != [
		simulation.state.entities[source].position_x_mt,
		simulation.state.entities[source].position_y_mt,
	], "dash did not move its source")
	_check(not simulation.neutrals.state.forced_night_effects.is_empty(),
		"forced night did not reach the neutral clock")
	_check(int(simulation.state.entities[source].integer_attributes.get(
		"owned_blight_radius_mt", 0
	)) > 0, "world-zone effect did not create owned blight")
	_check(simulation.state.entities[source].integer_attributes.has("tree_destruction_tick"),
		"world edit did not emit an authoritative marker")
	var tick_result: Dictionary = simulation.step_tick(false)
	_check(not bool(tick_result.get("skipped_invalid_config", false)),
		"active mutation tick did not run")
	_check(ally_entity.hp == hp_before - 20,
		"damage/heal/shield resolution was not exact: %d" % ally_entity.hp)
	_check(simulation.state.entities[enemy].hp == enemy_hp_before - 30,
		"mana-rend damage did not equal the exact mana burned")
	_check(int(simulation.state.combat.actors[ally]["shield_hp"]) == 0,
		"damage did not consume the shield")
	var status_intents: Array = [
		_manual_intent(simulation, "movement_speed_bp", 100_005, source, [ally], {}, -1000, 5),
		_manual_intent(simulation, "magic_immunity", 100_006, source, [ally], {}, 1, 5),
		_manual_intent(simulation, "disable_attack", 100_007, source, [ally], {}, 1, 5),
		_manual_intent(simulation, "damage_received_bp", 100_016, source, [ally], {}, 10_000, 5),
	]
	for status_intent_variant: Variant in status_intents:
		(status_intent_variant as Dictionary)["status_stacking_key"] = "effect_test"
		(status_intent_variant as Dictionary)["dispel_class"] = "ordinary_magical"
	var statuses: Dictionary = bridge.apply_effect_intents(
		simulation, simulation.abilities, status_intents
	)
	_check(bool(statuses.get("ok", false)), "active status batch failed: %s" % _errors(statuses))
	_check(bool(simulation.state.combat.actors[ally]["magic_immune"]),
		"magic-immunity status did not synchronize")
	_check(not bool(simulation.state.combat.actors[ally]["attack"]["enabled"]),
		"disable-attack status did not synchronize")
	var sibling_keys: Dictionary = {}
	for status_variant: Variant in simulation.state.combat.statuses.values():
		var status: Dictionary = status_variant
		if int(status["target_id"]) == ally \
			and str(status["stacking_key"]).begins_with("effect_test::"):
			sibling_keys[str(status["stacking_key"])] = true
	_check(sibling_keys.size() == 4,
		"sibling effect kinds collapsed under one status stacking key")
	var modifier_hp_before: int = ally_entity.hp
	var modifier_damage := bridge.apply_effect_intents(simulation, simulation.abilities, [
		_manual_intent(simulation, "hero_damage", 100_017, source, [ally], {}, 10, 1),
	])
	_check(bool(modifier_damage.get("ok", false)), "modifier damage fixture failed")
	simulation.step_tick(false)
	_check(ally_entity.hp == modifier_hp_before - 20,
		"numeric combat status was not applied exactly once: %d" % (
			modifier_hp_before - ally_entity.hp
		))
	var dispellable_shield := bridge.apply_effect_intents(simulation, simulation.abilities, [
		_manual_intent(simulation, "shield", 100_019, source, [ally], {}, 25, 5),
	])
	_check(bool(dispellable_shield.get("ok", false)) \
		and int(simulation.state.combat.actors[ally]["shield_hp"]) == 25,
		"dispellable shield fixture was not installed")
	var dispel := bridge.apply_effect_intents(simulation, simulation.abilities, [
		_manual_intent(simulation, "dispel", 100_012, source, [ally], {}, 1, 1),
	])
	_check(bool(dispel.get("ok", false)), "active dispel failed")
	_check(int(simulation.state.combat.actors[ally]["shield_hp"]) == 0,
		"dispel did not remove an ordinary-magical shield")
	_check(not bool(simulation.state.combat.actors[ally]["magic_immune"]),
		"dispel did not restore magic-immunity state")
	_check(bool(simulation.state.combat.actors[ally]["attack"]["enabled"]),
		"dispel did not restore attack state")
	var militia_base_max_hp: int = simulation.state.entities[source].max_hp
	var militia_base_armor: int = simulation.state.combat.actors[source]["armor_centi"]
	var militia_base_damage: int = simulation.state.combat.actors[source]["attack"]["damage"]
	var militia := bridge.apply_effect_intents(simulation, simulation.abilities, [
		_manual_intent(simulation, "transform_militia", 100_018, source, [source], {}, 1, 2),
	])
	_check(bool(militia.get("ok", false)), "militia transform failed: %s" % _errors(militia))
	_check(simulation.state.entities[source].max_hp == 360 \
		and int(simulation.state.combat.actors[source]["armor_centi"]) == 200 \
		and int(simulation.state.combat.actors[source]["attack"]["damage"]) == 16,
		"militia transform did not install its faction combat profile")
	simulation.state.tick += 2
	bridge.resolve_lifecycle(simulation)
	_check(simulation.state.entities[source].max_hp == militia_base_max_hp \
		and int(simulation.state.combat.actors[source]["armor_centi"]) == militia_base_armor \
		and int(simulation.state.combat.actors[source]["attack"]["damage"]) == militia_base_damage,
		"militia transform did not restore its base profile")
	_check("militia" not in simulation.state.entities[source].tags,
		"militia transform left a stale entity tag")
	var toggle_buff := _manual_intent(
		simulation, "movement_speed_bp", 100_022, source, [source], {}, -2_000, 2
	)
	toggle_buff["ability_id"] = "defensive_line"
	toggle_buff["status_stacking_key"] = "defensive_line"
	var toggle_applied: Dictionary = bridge.apply_effect_intents(
		simulation, simulation.abilities, [toggle_buff]
	)
	_check(bool(toggle_applied.get("ok", false)), "toggle status fixture failed")
	var toggle_removed: Dictionary = toggle_buff.duplicate(true)
	toggle_removed["cast_id"] = 100_023
	toggle_removed["effect_id"] = 100_023
	toggle_removed["effect_kind"] = "remove_stacking_key"
	toggle_removed["primitive_kind"] = "status_remove"
	toggle_removed["primitive_value"] = 1
	toggle_removed["resolved_duration_ticks"] = 0
	var toggle_result: Dictionary = bridge.apply_effect_intents(
		simulation, simulation.abilities, [toggle_removed]
	)
	_check(bool(toggle_result.get("ok", false)) \
		and int(toggle_result.get("applied", 0)) == 1,
		"synthetic toggle removal failed: %s" % _errors(toggle_result))
	for status_variant: Variant in simulation.state.combat.statuses.values():
		var status: Dictionary = status_variant
		_check(not (int(status["target_id"]) == source \
			and str(status["stacking_key"]).begins_with("defensive_line::")),
			"synthetic toggle removal left a stale status")
	var periodic_a := _manual_intent(
		simulation, "restore_hp_per_tick", 100_020, source, [ally], {}, 3, 10
	)
	periodic_a["impact_index"] = 0
	periodic_a["impact_tick"] = simulation.state.tick
	var periodic_b: Dictionary = periodic_a.duplicate(true)
	periodic_b["impact_index"] = 1
	periodic_b["impact_tick"] = simulation.state.tick + 1
	var periodic_result: Dictionary = bridge.apply_effect_intents(
		simulation, simulation.abilities, [periodic_b, periodic_a]
	)
	_check(bool(periodic_result.get("ok", false)) \
		and int(periodic_result.get("applied", 0)) == 2,
		"distinct periodic impacts sharing one effect ID were rejected")

	var transform := bridge.apply_effect_intents(simulation, simulation.abilities, [
		_manual_intent(simulation, "set_flying", 100_013, source, [source], {}, 1, 2),
	])
	_check(bool(transform.get("ok", false)), "timed flying transform failed")
	_check(str(simulation.state.movement.actors[source]["layer"]) == "air",
		"flying transform did not reserve an air lane")
	var previous_air_cells: Array = simulation.state.movement.actors[source][
		"occupied_cells"
	].duplicate()
	var air_target := _find_open_near(simulation, source, 350, 5_000)
	var air_dash: Dictionary = bridge.apply_effect_intents(simulation, simulation.abilities, [
		_manual_intent(simulation, "dash", 100_021, source, [], {
			"kind": "point", "position_mt": air_target,
		}, 5_000, 1),
	])
	_check(bool(air_dash.get("ok", false)), "air dash failed: %s" % _errors(air_dash))
	_check(previous_air_cells != simulation.state.movement.actors[source]["occupied_cells"],
		"air dash did not move its altitude-lane occupancy")
	simulation.state.tick += 2
	bridge.resolve_lifecycle(simulation)
	_check(str(simulation.state.movement.actors[source]["layer"]) == "ground",
		"timed flying transform did not revert")
	_check(not simulation.grid.ground_cells_for_actor(source).is_empty(),
		"reverted flying transform did not restore ground occupancy")
	var lifecycle := bridge.apply_effect_intents(simulation, simulation.abilities, [{
		"ability_id": "wisp_dissolve",
		"cast_id": 100_014,
		"effect_id": 100_014,
		"effect_kind": "destroy_caster",
		"impact_tick": simulation.state.tick,
		"primitive_kind": "lifecycle",
		"primitive_value": 1,
		"resolved_duration_ticks": 0,
		"selected_target_ids": [enemy],
		"source_id": enemy,
		"target": {"entity_id": enemy, "kind": "entity"},
	}])
	_check(bool(lifecycle.get("ok", false)) and simulation.state.entities[enemy].hp == 0,
		"lifecycle primitive did not destroy its caster")


func _test_faction_summons_and_regeneration() -> void:
	var cases: Array[Dictionary] = [
		{"count": 2, "faction": "crypt-v1", "kind": "summon_crypt_thrall"},
		{"count": 2, "faction": "grove-v1", "kind": "summon_grove_treant"},
		{"count": 1, "faction": "warhost-v1", "kind": "summon_mending_ward"},
	]
	var seed := 90_100
	for case: Dictionary in cases:
		var simulation: Variant = _official_simulation(str(case["faction"]), seed)
		seed += 1
		if simulation == null:
			continue
		var source := _mobile_entity(simulation, 0, 0)
		var point := _find_open_near(simulation, source, 500, 7_000)
		if point.is_empty():
			point = _find_open_position(simulation, 500)
		var before: int = simulation.state.entities.size()
		var summon: Dictionary = simulation.ability_effects.apply_effect_intents(
			simulation, simulation.abilities, [
				_manual_intent(
					simulation, str(case["kind"]), 200_000 + seed, source, [],
					{"kind": "point", "position_mt": point}, int(case["count"]), 30
				),
			]
		)
		_check(bool(summon.get("ok", false)), "%s summon failed: %s" % [
			case["faction"], _errors(summon),
		])
		_check(simulation.state.entities.size() == before + int(case["count"]),
			"%s summon count is wrong" % case["faction"])
		for entity_id: int in simulation.state.sorted_entity_ids():
			if entity_id < simulation.state.next_entity_id - int(case["count"]):
				continue
			_check(simulation.state.combat.actors.has(entity_id),
				"summon is absent from combat authority")
			_check(simulation.state.movement.actors.has(entity_id),
				"summon is absent from movement authority")
		_check(simulation.validate().is_empty(), "%s summon state is invalid" % case["faction"])
		if str(case["faction"]) == "warhost-v1":
			_test_mending_ward_healing(simulation, source)
			_test_warhost_regeneration(simulation)
		elif str(case["faction"]) == "crypt-v1":
			_test_corpse_storage_order(simulation, source)
			_test_crypt_blight_regeneration(simulation)
		elif str(case["faction"]) == "grove-v1":
			_test_real_lifecycle_delivery(simulation)
			_test_real_periodic_delivery(simulation)


func _test_warhost_regeneration(simulation: Variant) -> void:
	var worker := _mobile_entity(simulation, 0, 0)
	var entity: EntityRecord = simulation.state.entities[worker]
	entity.hp = entity.max_hp - 20
	entity.max_mana = 20
	entity.mana = 0
	var errors: PackedStringArray = simulation.ability_effects.synchronize_persistent(
		simulation, simulation.abilities
	)
	_check(errors.is_empty(), "Warhost passive synchronization failed: %s" % "; ".join(errors))
	var has_aura := false
	for status_variant: Variant in simulation.state.combat.statuses.values():
		var status: Dictionary = status_variant
		if int(status["target_id"]) == worker \
			and str(status["status_kind"]) == "hp_regeneration_bp":
			has_aura = true
	_check(has_aura, "Warhost home-regeneration aura did not reach its worker")
	var hp_total := 0
	var mana_total := 0
	for tick: int in range(0, 20):
		simulation.state.tick = tick
		for delta_variant: Variant in simulation.ability_effects.regeneration_deltas(simulation):
			var delta: DeltaRecord = delta_variant
			if delta.entity_id != worker:
				continue
			if delta.kind == DeltaRecord.Kind.HP:
				hp_total += delta.amount
			elif delta.kind == DeltaRecord.Kind.MANA:
				mana_total += delta.amount
	_check(hp_total == 1, "Warhost 150%% regeneration cadence is wrong: %d" % hp_total)
	_check(mana_total == 2, "base mana regeneration cadence is wrong: %d" % mana_total)
	entity.tags.append("hero")
	entity.tags.sort()
	simulation.state.heroes.heroes[worker] = {
		"derived": {"hp_regen_per_100_ticks": 2},
	}
	entity.integer_attributes["hero_hp_regen_bonus_accumulator"] = 0
	var hero_bonus_total := 0
	for tick: int in range(20, 120):
		simulation.state.tick = tick
		for delta_variant: Variant in simulation.ability_effects.regeneration_deltas(simulation):
			var delta: DeltaRecord = delta_variant
			if delta.entity_id == worker and delta.kind == DeltaRecord.Kind.HP:
				hero_bonus_total += delta.amount
	_check(hero_bonus_total == 1,
		"Warhost Hero regeneration bonus cadence is wrong: %d" % hero_bonus_total)
	simulation.state.heroes.heroes.erase(worker)
	entity.tags.erase("hero")
	entity.integer_attributes.erase("hero_hp_regen_bonus_accumulator")


func _test_mending_ward_healing(simulation: Variant, target_id: int) -> void:
	var ward_id := _entity_by_catalog(simulation, "mending_ward")
	_check(ward_id > 0, "Mending Ward fixture has no summoned ward")
	if ward_id <= 0:
		return
	var ward: EntityRecord = simulation.state.entities[ward_id]
	_check(int(ward.integer_attributes.get("detection_radius_mt", 0)) == 6_000,
		"Mending Ward detection radius was not installed")
	_check(int(ward.integer_attributes.get("sight_day_mt", 0)) == 8_000,
		"Mending Ward sight radius was not installed")
	var target: EntityRecord = simulation.state.entities[target_id]
	target.hp = maxi(1, target.max_hp - 20)
	target.integer_attributes["hp_regen_accumulator"] = 0
	var healed := 0
	for delta_variant: Variant in simulation.ability_effects.regeneration_deltas(simulation):
		var delta: DeltaRecord = delta_variant
		if delta.entity_id == target_id and delta.kind == DeltaRecord.Kind.HP:
			healed += delta.amount
	_check(healed == 4, "Mending Ward healing cadence is wrong: %d" % healed)
	## Isolate the separate faction-regeneration assertion below.
	ward.integer_attributes["healing_per_tick"] = 0


func _test_corpse_storage_order(simulation: Variant, source_id: int) -> void:
	var source: EntityRecord = simulation.state.entities[source_id]
	source.integer_attributes.erase("corpse_storage_capacity")
	source.integer_attributes["stored_corpses"] = 0
	var corpse_id := _add_corpse(simulation, source.owner_seat, 100)
	var store := _manual_intent(
		simulation, "store_corpse", 210_001, source_id, [corpse_id], {}, 1, 0
	)
	var capacity := _manual_intent(
		simulation, "capacity", 210_002, source_id, [source_id], {}, 8, 0
	)
	capacity["cast_id"] = int(store["cast_id"])
	var applied: Dictionary = simulation.ability_effects.apply_effect_intents(
		simulation, simulation.abilities, [store, capacity]
	)
	_check(bool(applied.get("ok", false)) and int(applied.get("applied", 0)) == 2,
		"real-order corpse storage batch failed: %s" % _errors(applied))
	_check(int(source.integer_attributes.get("corpse_storage_capacity", 0)) == 8 \
		and int(source.integer_attributes.get("stored_corpses", 0)) == 1,
		"corpse storage did not apply capacity before its first store")
	_check(not simulation.state.entities.has(corpse_id),
		"stored corpse remained in world authority")


func _test_crypt_blight_regeneration(simulation: Variant) -> void:
	var worker := _mobile_entity(simulation, 0, 0)
	var source := _owned_structure_near(simulation, worker)
	_check(source > 0, "Crypt regeneration fixture has no owned structure")
	if source <= 0:
		return
	var entity: EntityRecord = simulation.state.entities[worker]
	entity.hp = maxi(1, entity.max_hp - 100)
	simulation.state.entities[source].integer_attributes["owned_blight_radius_mt"] = 16_000
	simulation.state.tick = 99
	var hp_total := 0
	for delta_variant: Variant in simulation.ability_effects.regeneration_deltas(simulation):
		var delta: DeltaRecord = delta_variant
		if delta.entity_id == worker and delta.kind == DeltaRecord.Kind.HP:
			hp_total += delta.amount
	_check(hp_total == maxi(1, entity.max_hp / 100),
		"Crypt owned-Blight regeneration cadence is wrong: %d" % hp_total)


func _test_real_lifecycle_delivery(simulation: Variant) -> void:
	var wisp_id := _entity_by_catalog(simulation, "wisp")
	_check(wisp_id > 0, "Grove lifecycle fixture has no Wisp")
	if wisp_id <= 0:
		return
	var cast: Dictionary = simulation.abilities.execute_cast(
		simulation, wisp_id, "wisp_dissolve",
		{"entity_id": wisp_id, "kind": "entity"}, {}
	)
	_check(bool(cast.get("accepted", false)), "real Wisp lifecycle cast was rejected: %s" % str(
		cast.get("code", "")
	))
	if not bool(cast.get("accepted", false)):
		return
	for _tick: int in range(0, 12):
		simulation.step_tick(false)
		if simulation.state.entities[wisp_id].hp <= 0:
			break
	_check(simulation.state.entities[wisp_id].hp == 0,
		"real Wisp lifecycle primitive did not destroy its caster")
	var lifecycle_errors := 0
	for event_variant: Variant in simulation.state.events:
		if str(event_variant.event_kind) == "ability_authority_error" \
			and int(event_variant.source_internal_id) == wisp_id:
			lifecycle_errors += 1
	_check(lifecycle_errors == 0,
		"real Wisp lifecycle primitive produced an authority error")


func _test_real_periodic_delivery(simulation: Variant) -> void:
	var position := _find_open_position(simulation, 350)
	var entity_id: int = simulation.state.next_entity_id
	var mystic := EntityRecord.new(entity_id, 0, "unit")
	mystic.public_id = "e_effect_test_mystic_%08d" % entity_id
	mystic.catalog_id = "grove_mystic"
	mystic.set_position_mt(int(position[0]), int(position[1]))
	mystic.hp = 300
	mystic.max_hp = 350
	mystic.mana = 320
	mystic.max_mana = 320
	mystic.radius_mt = 350
	mystic.tags = ["biological", "caster", "ground", "ranged"]
	_check(simulation.add_entity(mystic, true) == entity_id,
		"could not add real periodic caster")
	_check(simulation.register_combat_entity(entity_id, "unit", "grove_mystic").is_empty(),
		"could not register periodic caster combat")
	_check(simulation.register_movement_entity(entity_id, "unit", "grove_mystic").is_empty(),
		"could not register periodic caster movement")
	_check(simulation.register_ability_actor(entity_id, "grove_mystic").is_empty(),
		"could not register periodic caster abilities")
	var cast: Dictionary = simulation.abilities.execute_cast(
		simulation, entity_id, "grove_mystic_renew",
		{"entity_id": entity_id, "kind": "entity"}, {}
	)
	_check(bool(cast.get("accepted", false)), "real periodic cast was rejected: %s" % str(
		cast.get("code", "")
	))
	if not bool(cast.get("accepted", false)):
		return
	for _tick: int in range(0, 8):
		simulation.step_tick(false)
	_check(mystic.hp == 324, "real periodic healing did not apply two impacts: %d" % mystic.hp)
	var authority_errors := 0
	for event_variant: Variant in simulation.state.events:
		if str(event_variant.event_kind) == "ability_authority_error":
			authority_errors += 1
	_check(authority_errors == 0,
		"periodic impacts sharing one effect ID produced an authority collision")
	var start_usec := Time.get_ticks_usec()
	var completed := 0
	for _tick: int in range(0, 100):
		var tick_result: Dictionary = simulation.step_tick(false)
		if bool(tick_result.get("skipped_terminal", false)):
			break
		completed += 1
	_official_100_tick_ms = int((Time.get_ticks_usec() - start_usec) / 1_000)
	_check(completed == 100, "official performance fixture terminated before 100 ticks")
	_check(_official_100_tick_ms < 30_000,
		"official 100-tick runtime is too slow: %d ms" % _official_100_tick_ms)


func _official_simulation(faction_id: String, seed: int) -> Variant:
	var bootstrap := Bootstrap.create_official({
		"faction_id": faction_id, "match_seed": seed, "scored": false,
	})
	_check(bool(bootstrap.get("ok", false)), "%s official bootstrap failed: %s" % [
		faction_id, _errors(bootstrap),
	])
	if not bool(bootstrap.get("ok", false)):
		return null
	var attached := MatchRuntime.attach_protected_authority(
		bootstrap, (TIE_KEY + ":" + faction_id).to_utf8_buffer()
	)
	_check(bool(attached.get("ok", false)), "%s protected runtime failed: %s" % [
		faction_id, _errors(attached),
	])
	return attached.get("simulation", null) if bool(attached.get("ok", false)) else null


func _effect_descriptors(simulation: Variant) -> Dictionary:
	var result: Dictionary = {}
	for ability_id: String in _sorted_string_keys(simulation.abilities.registry):
		var ability: Dictionary = simulation.abilities.registry[ability_id]
		for effect_variant: Variant in ability.get("effects", []):
			var effect: Dictionary = effect_variant
			var kind := str(effect["kind"])
			if result.has(kind):
				continue
			result[kind] = {
				"ability_id": ability_id,
				"dispel_class": str(ability["dispel_class"]),
				"duration_ticks": (effect["duration_ticks"] as Array).duplicate(),
				"kind": kind,
				"status_stacking_key": str(ability["status_stacking_key"]),
				"values": (effect["values"] as Array).duplicate(),
			}
	return result


func _intent_from_descriptor(
	descriptor: Dictionary,
	effect_id: int,
	cast_id: int,
	source_id: int,
	target: Dictionary,
	target_ids: Array
) -> Dictionary:
	var values: Array = descriptor["values"]
	var durations: Array = descriptor["duration_ticks"]
	return {
		"ability_id": str(descriptor["ability_id"]),
		"cast_id": cast_id,
		"dispel_class": str(descriptor["dispel_class"]),
		"effect_id": effect_id,
		"effect_index": 0,
		"effect_kind": str(descriptor["kind"]),
		"impact_tick": 0,
		"primitive_kind": str(Contract.EFFECT_DISPATCH[str(descriptor["kind"])]),
		"primitive_value": int(values[0]),
		"rank": 1,
		"resolved_duration_ticks": int(durations[0]),
		"resolved_durations": durations.duplicate(),
		"resolved_value": int(values[0]),
		"resolved_values": values.duplicate(),
		"selected_target_ids": target_ids.duplicate(),
		"source_id": source_id,
		"status_stacking_key": str(descriptor["status_stacking_key"]),
		"target": target.duplicate(true),
	}


func _coverage_targets(
	primitive: String,
	kind: String,
	source: int,
	ally: int,
	enemy: int,
	consume_corpse: int,
	revive_corpse: int,
	store_corpse: int
) -> Array:
	if primitive in ["damage", "damage_summon", "resource", "selection", "projectile"]:
		return [enemy]
	if primitive in [
		"attack_modifier", "control", "control_rule", "damage_modifier", "dispel",
		"healing", "link", "shield", "status_modifier", "vision",
	]:
		return [ally]
	if primitive == "resource_conversion":
		return [enemy] if kind == "transfer_hp_per_tick" else [ally]
	if primitive == "corpse":
		return [consume_corpse] if kind == "consume_corpse" else []
	if primitive == "storage":
		return [store_corpse] if kind == "store_corpse" else [source]
	if primitive == "transform" or primitive == "world_zone":
		return [source]
	if primitive == "revival":
		return [revive_corpse]
	if primitive == "transport":
		return [ally]
	return []


func _manual_intent(
	simulation: Variant,
	kind: String,
	effect_id: int,
	source_id: int,
	target_ids: Array,
	target_override: Dictionary,
	value: int,
	duration: int
) -> Dictionary:
	var descriptor: Dictionary = _effect_descriptors(simulation).get(kind, {})
	if descriptor.is_empty():
		return {}
	var target := target_override.duplicate(true)
	if target.is_empty() and not target_ids.is_empty():
		target = {"entity_id": int(target_ids[0]), "kind": "entity"}
	elif target.is_empty():
		target = {"entity_id": source_id, "kind": "entity"}
	var result := _intent_from_descriptor(
		descriptor, effect_id, effect_id, source_id, target, target_ids
	)
	result["primitive_value"] = value
	result["resolved_value"] = value
	result["resolved_values"] = [value]
	result["resolved_duration_ticks"] = duration
	result["resolved_durations"] = [duration]
	return result


func _ability_id_for_kind(simulation: Variant, kind: String) -> String:
	return str((_effect_descriptors(simulation).get(kind, {}) as Dictionary).get(
		"ability_id", ""
	))


func _mobile_entity(simulation: Variant, seat: int, ordinal: int) -> int:
	var found: Array[int] = []
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		if entity.owner_seat == seat and entity.alive \
			and simulation.state.combat.actors.has(entity_id) \
			and simulation.state.movement.actors.has(entity_id):
			found.append(entity_id)
	return found[ordinal] if ordinal >= 0 and ordinal < found.size() else 0


func _entity_by_catalog(simulation: Variant, catalog_id: String) -> int:
	for entity_id: int in simulation.state.sorted_entity_ids():
		var entity: EntityRecord = simulation.state.entities[entity_id]
		if entity.alive and entity.catalog_id == catalog_id:
			return entity_id
	return 0


func _owned_structure_near(simulation: Variant, entity_id: int) -> int:
	if not simulation.state.entities.has(entity_id):
		return 0
	var entity: EntityRecord = simulation.state.entities[entity_id]
	var candidates: Array[Dictionary] = []
	for candidate_id: int in simulation.state.sorted_entity_ids():
		var candidate: EntityRecord = simulation.state.entities[candidate_id]
		if candidate.owner_seat != entity.owner_seat or candidate.entity_kind != "structure":
			continue
		var dx := candidate.position_x_mt - entity.position_x_mt
		var dy := candidate.position_y_mt - entity.position_y_mt
		candidates.append({"distance": dx * dx + dy * dy, "entity_id": candidate_id})
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return [int(left["distance"]), int(left["entity_id"])] \
			< [int(right["distance"]), int(right["entity_id"])]
	)
	return int(candidates[0]["entity_id"]) if not candidates.is_empty() else 0


func _add_corpse(simulation: Variant, owner_seat: int, max_hp: int) -> int:
	var entity_id: int = simulation.state.next_entity_id
	var corpse := EntityRecord.new(entity_id, owner_seat, "corpse")
	corpse.public_id = "e_effect_test_corpse_%08d" % entity_id
	corpse.catalog_id = "test_corpse"
	corpse.set_position_mt(0, 0)
	corpse.alive = false
	corpse.hp = 0
	corpse.max_hp = max_hp
	corpse.radius_mt = 0
	corpse.tags = ["corpse"]
	corpse.integer_attributes["gold_value"] = max_hp
	_check(simulation.add_entity(corpse, false) == entity_id, "could not add corpse fixture")
	return entity_id


func _find_open_position(simulation: Variant, radius_mt: int) -> Array:
	for y: int in range(0, simulation.grid.height):
		for x: int in range(0, simulation.grid.width):
			var center: Vector2i = simulation.grid.cell_center_mt(x, y)
			if simulation.grid.fits_ground_footprint_at_position(
				center.x, center.y, radius_mt
			):
				return [center.x, center.y]
	return []


func _find_open_near(
	simulation: Variant, entity_id: int, radius_mt: int, maximum_distance_mt: int
) -> Array:
	var entity: EntityRecord = simulation.state.entities[entity_id]
	var offsets: Array = [
		[2_000, 0], [0, 2_000], [-2_000, 0], [0, -2_000],
		[3_000, 0], [0, 3_000], [-3_000, 0], [0, -3_000],
		[4_000, 0], [0, 4_000], [-4_000, 0], [0, -4_000],
	]
	for offset_variant: Variant in offsets:
		var offset: Array = offset_variant
		var x := entity.position_x_mt + int(offset[0])
		var y := entity.position_y_mt + int(offset[1])
		if int(offset[0]) * int(offset[0]) + int(offset[1]) * int(offset[1]) \
			> maximum_distance_mt * maximum_distance_mt:
			continue
		if simulation.grid.fits_ground_footprint_at_position(x, y, radius_mt):
			return [x, y]
	return []


func _tagged_count(simulation: Variant, tag: String) -> int:
	var result := 0
	for entity_id: int in simulation.state.sorted_entity_ids():
		if tag in simulation.state.entities[entity_id].tags:
			result += 1
	return result


func _add_tag(entity: EntityRecord, tag: String) -> void:
	if tag not in entity.tags:
		entity.tags.append(tag)
		entity.tags.sort()


func _sorted_string_keys(source: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_variant: Variant in source.keys():
		result.append(str(key_variant))
	result.sort()
	return result


func _errors(result: Dictionary) -> String:
	var messages: Array[String] = []
	for value: Variant in result.get("errors", []):
		messages.append(str(value))
	return "; ".join(messages)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
