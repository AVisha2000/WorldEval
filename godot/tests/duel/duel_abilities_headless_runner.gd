extends SceneTree

const AbilityRuntime := preload("res://scripts/duel/abilities/duel_ability_runtime.gd")
const AbilityContract := preload("res://scripts/duel/abilities/duel_ability_contract.gd")
const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const GOLDEN_SCENARIO_HASH := "8dee9b1013037747d9bc237594753d78215f4da98420057e9633a652bbc5650c"

var _failures := PackedStringArray()


func _init() -> void:
	_test_locked_catalogue_coverage()
	_test_catalogue_mutations_fail_closed()
	_test_target_mana_cooldown_rank_tech_and_autocast_validation()
	_test_regular_and_hero_cross_faction_execution()
	_test_trigger_and_periodic_schedules()
	_test_accumulator_channel_interrupt_and_toggle()
	_test_deterministic_autocast_and_checkpoint()
	var first := _golden_scenario(false)
	var second := _golden_scenario(true)
	_check(first["hash"] == second["hash"], "ability golden hash depends on candidate insertion order")
	_check(first["summary"] == second["summary"], "ability golden summary depends on candidate insertion order")
	if not GOLDEN_SCENARIO_HASH.is_empty():
		_check(first["hash"] == GOLDEN_SCENARIO_HASH, "ability golden hash changed: %s" % first["hash"])
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_ABILITIES_FAILURE: %s" % failure)
		print("DUEL_ABILITIES_FAILED count=%d hash=%s" % [_failures.size(), first["hash"]])
		quit(1)
		return
	print("DUEL_ABILITIES_OK hash=%s summary=%s" % [
		first["hash"], JSON.stringify(first["summary"]),
	])
	quit(0)


func _test_locked_catalogue_coverage() -> void:
	var loaded := CatalogLoader.load_official_catalogs()
	_check(bool(loaded["ok"]), "official catalog package failed to load")
	var compiled := AbilityContract.compile_official_registry(loaded)
	_check(bool(compiled["ok"]), "ability contract rejected locked catalogs: %s" % _errors(compiled))
	_check(compiled["registry"].size() == 100, "ability registry does not contain all 100 faction abilities")
	_check(AbilityContract.EFFECT_DISPATCH.size() == 109, "effect dispatch does not contain all 109 effect kinds")
	_check(AbilityContract.IMPACT_SCHEDULES.size() == 26, "schedule dispatch does not contain all 26 schedules")
	var seen_schedules: Dictionary = {}
	var seen_effects: Dictionary = {}
	for ability_id: String in _sorted_string_keys(compiled["registry"]):
		var ability: Dictionary = compiled["registry"][ability_id]
		seen_schedules[str(ability["impact_schedule"])] = true
		_check(not (ability["effect_dispatch"] as Array).is_empty(), "ability omitted dispatch: %s" % ability_id)
		for dispatch_variant: Variant in ability["effect_dispatch"]:
			var dispatch: Dictionary = dispatch_variant
			seen_effects[str(dispatch["effect_kind"])] = true
			_check(not str(dispatch["primitive_kind"]).is_empty(), "effect has no primitive: %s" % dispatch["effect_kind"])
	_check(seen_schedules.size() == 26, "locked registry did not exercise every schedule")
	_check(seen_effects.size() == 109, "locked registry did not exercise every effect kind")


func _test_catalogue_mutations_fail_closed() -> void:
	var loaded := CatalogLoader.load_official_catalogs()
	var unknown_effect := loaded.duplicate(true)
	unknown_effect["catalogs"]["faction:vanguard-v1"]["abilities"]["priest_mend"]["effects"][0]["kind"] = "invented_heal"
	var rejected_effect := AbilityContract.compile_official_registry(unknown_effect)
	_check(not bool(rejected_effect["ok"]), "unknown catalog effect did not fail closed")
	_check("unsupported" in _errors(rejected_effect), "unknown effect rejection was not explicit")
	var unknown_schedule := loaded.duplicate(true)
	unknown_schedule["catalogs"]["faction:warhost-v1"]["abilities"]["binding_net"]["impact_schedule"] = "whenever_animation_finishes"
	var rejected_schedule := AbilityContract.compile_official_registry(unknown_schedule)
	_check(not bool(rejected_schedule["ok"]), "unknown catalog schedule did not fail closed")
	var unknown_field := loaded.duplicate(true)
	unknown_field["catalogs"]["faction:crypt-v1"]["abilities"]["grounding_web"]["secret_power"] = 99
	_check(not bool(AbilityContract.compile_official_registry(unknown_field)["ok"]), "unknown executable field did not fail closed")


func _test_target_mana_cooldown_rank_tech_and_autocast_validation() -> void:
	var setup := _new_authority("vanguard-v1", 101)
	var sim: Variant = setup["sim"]
	var runtime: AbilityRuntime = setup["runtime"]
	var priest := _add_entity(sim, 1_001, 0, "priest", [20_000, 20_000], ["biological"], 100, 100)
	var ally := _add_entity(sim, 1_002, 0, "footguard", [21_000, 20_000], ["biological"], 300, 0)
	var enemy := _add_entity(sim, 1_003, 1, "enemy", [21_000, 20_000], ["biological"], 300, 0)
	_check(runtime.register_actor(sim, priest, "priest").is_empty(), "priest registration failed")
	var wrong_owner := runtime.compile_cast(sim, priest, "priest_mend", {"entity_id": enemy}, {})
	_check(not wrong_owner["ok"] and wrong_owner["code"] == "invalid_target", "owned-target rule was not enforced")
	sim.state.entities[priest].mana = 0
	_check(runtime.compile_cast(sim, priest, "priest_mend", {"entity_id": ally}, {})["code"] == "insufficient_mana", "mana validation failed")
	sim.state.entities[priest].mana = 100
	var far := _add_entity(sim, 1_004, 0, "footguard", [40_001, 20_000], ["biological"], 300, 0)
	_check(runtime.compile_cast(sim, priest, "priest_mend", {"entity_id": far}, {})["code"] == "out_of_range", "cast range validation failed")
	_check(runtime.set_autocast(sim, priest, "priest_mend", true)["accepted"], "catalog-eligible autocast was rejected")
	_check(not runtime.set_autocast(sim, priest, "priest_cleanse", true)["accepted"], "non-autocast spell was enabled")

	var arcanist := _add_entity(sim, 1_005, 0, "arcanist", [20_000, 21_000], ["biological"], 250, 300)
	_check(runtime.register_actor(sim, arcanist, "arcanist").is_empty(), "arcanist registration failed")
	_check(runtime.compile_cast(sim, arcanist, "arcanist_barrier", {"entity_id": ally}, {})["code"] == "prerequisite_missing", "upgrade prerequisite was not enforced")
	var allowed := runtime.compile_cast(sim, arcanist, "arcanist_barrier", {"entity_id": ally}, {
		"completed_upgrade_ids": ["caster_mastery_2"],
	})
	_check(allowed["ok"], "explicit completed upgrade did not unlock spell")

	var marshal := _add_entity(sim, 1_006, 0, "marshal", [20_000, 20_000], ["biological", "hero"], 1_000, 500)
	_check(runtime.register_actor(sim, marshal, "marshal", {"marshal_shield_strike": 2}).is_empty(), "Hero rank registration failed")
	_check(runtime.compile_cast(sim, marshal, "marshal_shield_strike", {"entity_id": enemy}, {"rank": 3})["code"] == "ability_unavailable", "unlearned Hero rank was accepted")
	var cast := runtime.execute_cast(sim, marshal, "marshal_shield_strike", {"entity_id": enemy}, {"rank": 2})
	_check(cast["accepted"], "legal Hero cast was rejected")
	if not cast["accepted"]:
		return
	sim.state.tick = int(cast["details"]["commit_tick"])
	_check(runtime.advance(sim, "commit")["ok"], "Hero commit phase failed")
	_check(runtime.compile_cast(sim, marshal, "marshal_shield_strike", {"entity_id": enemy}, {"rank": 2})["code"] == "cooldown_active", "cooldown was not enforced after commit")


func _test_regular_and_hero_cross_faction_execution() -> void:
	var cases: Array[Dictionary] = [
		{"ability": "priest_mend", "actor": "priest", "faction": "vanguard-v1", "hero": false, "rank": 1, "target_tags": ["biological"], "target_seat": 0},
		{"ability": "marshal_shield_strike", "actor": "marshal", "faction": "vanguard-v1", "hero": true, "rank": 3, "target_tags": ["biological"], "target_seat": 1},
		{"ability": "binding_net", "actor": "wolf_rider", "faction": "warhost-v1", "hero": false, "rank": 1, "target_tags": ["biological"], "target_seat": 1},
		{"ability": "warcaller_earthbreak", "actor": "warcaller", "faction": "warhost-v1", "hero": true, "point": true, "rank": 1},
		{"ability": "dryad_unweave", "actor": "dryad", "faction": "grove-v1", "hero": false, "rank": 1, "target_tags": ["summoned"], "target_seat": 1},
		{"ability": "grove_keeper_root_snare", "actor": "grove_keeper", "faction": "grove-v1", "hero": true, "rank": 3, "periodic": true, "target_tags": ["biological"], "target_seat": 1},
		{"ability": "veil_adept_wither", "actor": "veil_adept", "faction": "crypt-v1", "hero": false, "rank": 1, "target_tags": ["biological"], "target_seat": 1},
		{"ability": "rime_oracle_frost_lance", "actor": "rime_oracle", "faction": "crypt-v1", "hero": true, "rank": 3, "target_tags": ["biological"], "target_seat": 1},
	]
	for index: int in cases.size():
		var case: Dictionary = cases[index]
		var setup := _new_authority(str(case["faction"]), 200 + index)
		var sim: Variant = setup["sim"]
		var runtime: AbilityRuntime = setup["runtime"]
		var actor_tags: Array[String] = ["biological"]
		if bool(case["hero"]):
			actor_tags.append("hero")
		var actor := _add_entity(sim, 2_001, 0, str(case["actor"]), [30_000, 30_000], actor_tags, 1_200, 1_000)
		var ranks: Dictionary = {str(case["ability"]): int(case["rank"])} if bool(case["hero"]) else {}
		_check(runtime.register_actor(sim, actor, str(case["actor"]), ranks).is_empty(), "cross-faction actor registration failed: %s" % case["ability"])
		var target: Dictionary
		if bool(case.get("point", false)):
			target = {"kind": "point", "position_mt": [31_000, 30_000]}
		else:
			var target_id := _add_entity(sim, 2_002, int(case["target_seat"]), "target", [30_500, 30_000], case["target_tags"], 1_000, 300)
			target = {"entity_id": target_id, "kind": "entity"}
		var receipt := runtime.execute_cast(sim, actor, str(case["ability"]), target, {"rank": int(case["rank"])})
		_check(receipt["accepted"], "representative cast rejected: %s (%s)" % [case["ability"], receipt["code"]])
		if not receipt["accepted"]:
			continue
		sim.state.tick = int(receipt["details"]["commit_tick"])
		runtime.advance(sim, "commit")
		if bool(case.get("periodic", false)):
			sim.state.tick += 1
			runtime.advance(sim, "periodic")
		var effects := runtime.consume_effect_intents()
		_check(not effects.is_empty(), "representative cast emitted no primitive: %s" % case["ability"])
		for effect: Dictionary in effects:
			_check(not str(effect["primitive_kind"]).is_empty(), "representative primitive was untyped")


func _test_trigger_and_periodic_schedules() -> void:
	var setup := _new_authority("vanguard-v1", 501)
	var sim: Variant = setup["sim"]
	var runtime: AbilityRuntime = setup["runtime"]
	var lancer := _add_entity(sim, 3_001, 0, "lancer", [40_000, 40_000], ["biological"], 600, 0)
	var enemy := _add_entity(sim, 3_002, 1, "enemy", [40_000, 40_000], ["biological"], 600, 0)
	_check(runtime.register_actor(sim, lancer, "lancer").is_empty(), "lancer registration failed")
	var early := runtime.trigger_ability(sim, lancer, "lancer_charge", "after_30_uninterrupted_attack_move_ticks_then_first_melee_impact", {"entity_id": enemy}, {
		"first_melee_impact": true, "uninterrupted_attack_move_ticks": 29,
	})
	_check(not early["accepted"] and early["code"] == "requirement_not_met", "charge fired before 30 uninterrupted ticks")
	var fired := runtime.trigger_ability(sim, lancer, "lancer_charge", "after_30_uninterrupted_attack_move_ticks_then_first_melee_impact", {"entity_id": enemy}, {
		"first_melee_impact": true, "uninterrupted_attack_move_ticks": 30,
	})
	_check(fired["accepted"], "legal charge trigger was rejected")
	runtime.advance(sim, "periodic")
	_check(runtime.consume_effect_intents().size() == 2, "charge did not emit both catalog effects")

	var crypt := _new_authority("crypt-v1", 502)
	var crypt_sim: Variant = crypt["sim"]
	var crypt_runtime: AbilityRuntime = crypt["runtime"]
	var regent := _add_entity(crypt_sim, 3_101, 0, "grave_regent", [40_000, 40_000], ["biological", "hero"], 1_500, 1_000)
	_check(crypt_runtime.register_actor(crypt_sim, regent, "grave_regent", {"grave_regent_recall_fallen": 1}).is_empty(), "Crypt Hero registration failed")
	var recalled := crypt_runtime.execute_cast(crypt_sim, regent, "grave_regent_recall_fallen", {}, {"rank": 1})
	_check(recalled["accepted"], "self-area ultimate was rejected")
	crypt_sim.state.tick = int(recalled["details"]["commit_tick"])
	crypt_runtime.advance(crypt_sim, "commit")
	_check(crypt_runtime.consume_effect_intents().size() == 3, "self-area ultimate did not emit its full ordered effect list")


func _test_deterministic_autocast_and_checkpoint() -> void:
	var first := _autocast_choice(false)
	var second := _autocast_choice(true)
	_check(first == second, "autocast target/checkpoint depends on candidate insertion order")


func _test_accumulator_channel_interrupt_and_toggle() -> void:
	var crypt := _new_authority("crypt-v1", 601)
	var crypt_sim: Variant = crypt["sim"]
	var crypt_runtime: AbilityRuntime = crypt["runtime"]
	var ghast := _add_entity(crypt_sim, 3_201, 0, "ghast", [45_000, 45_000], ["biological"], 500, 0)
	var corpse := _add_entity(crypt_sim, 3_202, -1, "generic_corpse", [45_500, 45_000], ["corpse"], 1, 0)
	crypt_sim.state.entities[corpse].alive = false
	crypt_sim.state.entities[corpse].hp = 0
	crypt_runtime.register_actor(crypt_sim, ghast, "ghast")
	var consume := crypt_runtime.execute_cast(crypt_sim, ghast, "ghast_consume_corpse", {"entity_id": corpse}, {})
	_check(consume["accepted"], "corpse-consume cast was rejected")
	if consume["accepted"]:
		crypt_sim.state.tick = int(consume["details"]["commit_tick"])
		crypt_runtime.advance(crypt_sim, "commit")
		var initial := crypt_runtime.consume_effect_intents()
		_check(initial.size() == 1 and initial[0]["effect_kind"] == "consume_corpse", "corpse consume was not a one-shot primitive")
		var restored := 0
		var restore_impacts := 0
		for offset: int in range(1, 61):
			crypt_sim.state.tick = int(consume["details"]["commit_tick"]) + offset
			crypt_runtime.advance(crypt_sim, "periodic")
			for effect: Dictionary in crypt_runtime.consume_effect_intents():
				if str(effect["effect_kind"]) == "restore_hp_total":
					restored += int(effect["primitive_value"])
					restore_impacts += 1
		_check(restore_impacts == 60 and restored == 180, "integer accumulator did not distribute exactly 180 HP over 60 ticks")

	var vanguard := _new_authority("vanguard-v1", 602)
	var sim: Variant = vanguard["sim"]
	var runtime: AbilityRuntime = vanguard["runtime"]
	var arcanist := _add_entity(sim, 3_301, 0, "high_arcanist", [45_000, 45_000], ["biological", "hero"], 1_000, 1_000)
	runtime.register_actor(sim, arcanist, "high_arcanist", {"high_arcanist_falling_stars": 1})
	var channel := runtime.execute_cast(sim, arcanist, "high_arcanist_falling_stars", {
		"kind": "point", "position_mt": [46_000, 45_000],
	}, {})
	_check(channel["accepted"], "channel cast was rejected")
	if channel["accepted"]:
		sim.state.tick = int(channel["details"]["commit_tick"])
		runtime.advance(sim, "commit")
		_check(runtime.interrupt_actor(arcanist, "stun") == 1, "stun did not interrupt active channel")
		sim.state.tick += 10
		runtime.advance(sim, "periodic")
		_check(runtime.consume_effect_intents().is_empty(), "interrupted channel emitted a later impact")
		_check(int(sim.state.entities[arcanist].mana) < 1_000, "post-commit channel interruption incorrectly refunded mana")

	var footguard := _add_entity(sim, 3_302, 0, "footguard", [45_000, 46_000], ["biological"], 600, 0)
	runtime.register_actor(sim, footguard, "footguard")
	var toggle_on := runtime.execute_cast(sim, footguard, "defensive_line", {}, {"enabled": true})
	_check(toggle_on["accepted"], "catalog toggle-on was rejected")
	if toggle_on["accepted"]:
		sim.state.tick = int(toggle_on["details"]["commit_tick"])
		runtime.advance(sim, "activation")
		var passive_count := 0
		for effect: Dictionary in runtime.persistent_effect_snapshot():
			if str(effect["ability_id"]) == "defensive_line":
				passive_count += 1
		_check(passive_count == 3, "toggle-on did not install all three persistent modifiers")
		var toggle_off := runtime.execute_cast(sim, footguard, "defensive_line", {}, {"enabled": false})
		_check(toggle_off["accepted"], "catalog toggle-off was rejected")
		if toggle_off["accepted"]:
			sim.state.tick = int(toggle_off["details"]["commit_tick"])
			runtime.advance(sim, "activation")
			var removals := runtime.consume_effect_intents()
			_check(removals.size() == 1 and removals[0]["primitive_kind"] == "status_remove", "toggle-off did not emit exact status removal primitive")


func _autocast_choice(reverse_candidates: bool) -> Dictionary:
	var setup := _new_authority("vanguard-v1", 701)
	var sim: Variant = setup["sim"]
	var runtime: AbilityRuntime = setup["runtime"]
	var priest := _add_entity(sim, 4_001, 0, "priest", [50_000, 50_000], ["biological"], 300, 200)
	var ally_a := _add_entity(sim, 4_002, 0, "ally", [51_000, 50_000], ["biological"], 100, 0)
	var ally_b := _add_entity(sim, 4_003, 0, "ally", [49_000, 50_000], ["biological"], 100, 0)
	sim.state.entities[ally_a].hp = 50
	sim.state.entities[ally_b].hp = 50
	runtime.register_actor(sim, priest, "priest")
	runtime.set_autocast(sim, priest, "priest_mend", true)
	var candidates: Array = [ally_a, ally_b]
	if reverse_candidates:
		candidates.reverse()
	var receipt := runtime.execute_autocast(sim, priest, "priest_mend", candidates, {
		"opaque_order_keys": {str(ally_a): "opaque_b", str(ally_b): "opaque_a"},
	})
	var cast_id := int(receipt.get("details", {}).get("cast_id", 0))
	var target_id := int(runtime.state.casts.get(cast_id, {}).get("target", {}).get("entity_id", 0))
	return {"hash": runtime.checkpoint_hash(), "target_id": target_id}


func _golden_scenario(reverse_candidates: bool) -> Dictionary:
	var setup := _new_authority("vanguard-v1", 8_675_309)
	var sim: Variant = setup["sim"]
	var runtime: AbilityRuntime = setup["runtime"]
	var priest := _add_entity(sim, 5_001, 0, "priest", [60_000, 60_000], ["biological"], 300, 200)
	var marshal := _add_entity(sim, 5_002, 0, "marshal", [60_000, 61_000], ["biological", "hero"], 1_200, 500)
	var ally_a := _add_entity(sim, 5_003, 0, "ally", [61_000, 60_000], ["biological"], 300, 0)
	var ally_b := _add_entity(sim, 5_004, 0, "ally", [59_000, 60_000], ["biological"], 300, 0)
	var enemy := _add_entity(sim, 5_005, 1, "enemy", [60_500, 61_000], ["biological"], 1_000, 200)
	sim.state.entities[ally_a].hp = 200
	sim.state.entities[ally_b].hp = 100
	runtime.register_actor(sim, priest, "priest")
	runtime.register_actor(sim, marshal, "marshal", {"marshal_shield_strike": 2})
	runtime.set_autocast(sim, priest, "priest_mend", true)
	var candidates: Array = [ally_a, ally_b]
	if reverse_candidates:
		candidates.reverse()
	var auto := runtime.execute_autocast(sim, priest, "priest_mend", candidates, {
		"opaque_order_keys": {str(ally_a): "opaque_a", str(ally_b): "opaque_b"},
	})
	var strike := runtime.execute_cast(sim, marshal, "marshal_shield_strike", {"entity_id": enemy}, {"rank": 2})
	_check(auto["accepted"] and strike["accepted"], "golden casts were rejected")
	sim.state.tick = 5
	runtime.advance(sim, "commit")
	var effects := runtime.consume_effect_intents()
	var effect_kinds: Array[String] = []
	for effect: Dictionary in effects:
		effect_kinds.append(str(effect["effect_kind"]))
	var summary := {
		"casts": runtime.state.casts.size(),
		"effect_kinds": effect_kinds,
		"effects": effects.size(),
		"marshal_mana": int(sim.state.entities[marshal].mana),
		"priest_mana": int(sim.state.entities[priest].mana),
		"tick": runtime.state.tick,
	}
	_check(runtime.validate().is_empty(), "golden ability authority failed canonical validation")
	return {
		"hash": Codec.sha256_canonical({"authority": runtime.to_canonical_dict(), "effects": effects}),
		"summary": summary,
	}


func _new_authority(faction_id: String, seed: int) -> Dictionary:
	var boot := Bootstrap.create_official({
		"faction_id": faction_id, "match_seed": seed, "scored": false,
	})
	_check(bool(boot["ok"]), "official bootstrap failed for %s: %s" % [faction_id, _errors(boot)])
	var runtime := AbilityRuntime.new()
	var errors := runtime.configure(faction_id)
	_check(errors.is_empty(), "ability runtime configuration failed for %s: %s" % [faction_id, "; ".join(errors)])
	return {"runtime": runtime, "sim": boot["simulation"]}


func _add_entity(
	sim: Variant,
	entity_id: int,
	seat: int,
	catalog_id: String,
	position_mt: Array,
	tags_input: Array,
	max_hp: int,
	max_mana: int
) -> int:
	var entity := EntityRecord.new(entity_id, seat, "hero" if "hero" in tags_input else "unit")
	entity.public_id = "e_ability_%08d" % entity_id
	entity.catalog_id = catalog_id
	entity.set_position_mt(int(position_mt[0]), int(position_mt[1]))
	entity.max_hp = max_hp
	entity.hp = max_hp
	entity.max_mana = max_mana
	entity.mana = max_mana
	entity.radius_mt = 300
	for tag_variant: Variant in tags_input:
		entity.tags.append(str(tag_variant))
	entity.tags.sort()
	_check(sim.add_entity(entity, false) == entity_id, "could not add ability fixture entity %d" % entity_id)
	return entity_id


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


static func _errors(result: Dictionary) -> String:
	var values: PackedStringArray = []
	for value: Variant in result.get("errors", []):
		values.append(str(value))
	return "; ".join(values)


static func _sorted_string_keys(source: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_variant: Variant in source.keys():
		result.append(str(key_variant))
	result.sort()
	return result
