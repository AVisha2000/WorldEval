extends SceneTree

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const RuntimeCatalog := preload("res://scripts/duel/protocol/duel_runtime_catalog.gd")
const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const AuthoritativeVisibility := preload(
	"res://scripts/duel/knowledge/duel_authoritative_visibility.gd"
)
const KnowledgeState := preload(
	"res://scripts/duel/knowledge/duel_agent_knowledge_state.gd"
)
const Projector := preload(
	"res://scripts/duel/knowledge/duel_knowledge_projector.gd"
)

const EXPECTED_GOLDEN := "549772d41452ad22b359f970b7239ecc549a4880f81f0740f2e9a56d4e246432"

var _failures := PackedStringArray()


func _init() -> void:
	var visibility_summary := _test_status_visibility_and_knowledge()
	var disable_summary := _test_structure_disable_pause_and_resume()
	var wake_summary := _test_damage_wake_minimum()
	var trap_summary := _test_trap_first_enemy_trigger()
	var aura_summary := _test_persistent_visible_aura_pruning()
	var summary := {
		"aura_visibility": aura_summary,
		"damage_wake": wake_summary,
		"structure_disable": disable_summary,
		"trap_trigger": trap_summary,
		"visibility": visibility_summary,
	}
	var golden := Codec.sha256_canonical(summary)
	if not EXPECTED_GOLDEN.is_empty():
		_check(golden == EXPECTED_GOLDEN, "authority golden changed: %s" % golden)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_VISIBILITY_STATUS_FAILURE: " + failure)
		print("DUEL_VISIBILITY_STATUS_FAILED count=%d hash=%s" % [
			_failures.size(), golden,
		])
		quit(1)
		return
	print("DUEL_VISIBILITY_STATUS_OK hash=%s summary=%s" % [
		golden, JSON.stringify(summary),
	])
	quit(0)


func _test_status_visibility_and_knowledge() -> Dictionary:
	var sim := Simulation.new({"grid_height": 24, "grid_width": 32, "match_seed": 91})
	var source := _entity(1, 0, "scout", [1_250, 1_250], ["ground"])
	source.integer_attributes["sight_day_mt"] = 5_000
	source.integer_attributes["sight_night_mt"] = 5_000
	var near_invisible := _entity(2, 1, "near_invisible", [3_250, 1_250], ["ground"])
	var flare_invisible := _entity(3, 1, "flare_invisible", [8_250, 8_250], ["ground"])
	var never_seen := _entity(4, 1, "never_seen", [15_250, 750], ["ground"])
	for entity: EntityRecord in [source, near_invisible, flare_invisible, never_seen]:
		_check(sim.add_entity(entity, true) == entity.internal_id, "visibility entity add failed")
	sim.state.combat.enabled = true
	sim.state.combat.statuses = {
		10: _status(10, 1, 2, "invisibility", "invisibility", 1, 0, 60),
		11: _status(
			11, 1, 1, "allied_detection_radius_mt",
			"allied_detection_radius_mt", 3_000, 0, 60
		),
		12: _status(12, 1, 3, "invisibility", "invisibility", 1, 0, 60),
	}
	_check(sim.configure_abilities("vanguard-v1").is_empty(), "ability catalog setup failed")
	sim.abilities.state.casts[700] = {
		"ability_id": "recon_flare",
		"actor_id": 1,
		"cast_id": 700,
		"commit_tick": 0,
		"rank": 1,
		"status": "committed",
		"target": {"kind": "point", "position_mt": [8_250, 8_250]},
	}
	var computed := AuthoritativeVisibility.compute_for_seat(sim, 0, "day")
	_check(bool(computed.get("ok", false)), "status visibility compute failed: %s" % _errors(computed))
	_check(
		(computed.get("visible_entity_ids", []) as Array).has(2),
		"active detection did not expose the nearby invisible target"
	)
	_check(
		(computed.get("visible_entity_ids", []) as Array).has(3) \
			and (computed.get("detected_entity_ids", []) as Array).has(3),
		"temporary point sight/detection did not expose the invisible flare target"
	)
	_check(
		not (computed.get("visible_entity_ids", []) as Array).has(4),
		"temporary vision leaked an entity outside every legal source"
	)
	var forward := AuthoritativeVisibility.candidate_entity_ids(
		sim, 0, [1, 2, 3, 4], true
	)
	var reverse := AuthoritativeVisibility.candidate_entity_ids(
		sim, 0, [4, 3, 2, 1], true
	)
	_check(forward == [1, 2, 3], "candidate enumeration was not observer-closed: %s" % str(forward))
	_check(reverse == forward, "candidate enumeration depended on input insertion order")

	## Targeted reveal bypasses ordinary detection for exactly its source seat.
	sim.state.combat.statuses.erase(11)
	sim.state.combat.statuses[13] = _status(
		13, 1, 2, "reveal_target", "reveal_target", 1, 0, 60
	)
	var revealed := AuthoritativeVisibility.compute_for_seat(sim, 0, "day")
	_check(
		(revealed.get("visible_entity_ids", []) as Array).has(2) \
			and (revealed.get("detected_entity_ids", []) as Array).has(2),
		"targeted reveal did not override invisibility for its legal observer"
	)
	var opponent_overrides := AuthoritativeVisibility.observer_overrides(sim, 1)
	_check(
		(opponent_overrides["revealed_entity_internal_ids"] as Array).is_empty() \
			and (opponent_overrides["temporary_vision_sources"] as Array).is_empty(),
		"seat-specific reveal authority leaked to the opposing observer"
	)

	## The same closed facts must drive persistent public knowledge. The second
	## projection mutates hidden HP and proves remembered facts stay frozen.
	sim.state.combat.statuses[11] = _status(
		11, 1, 1, "allied_detection_radius_mt",
		"allied_detection_radius_mt", 3_000, 0, 60
	)
	var rows := AuthoritativeVisibility.augment_entity_snapshots(sim, _projection_rows(sim))
	var overrides := AuthoritativeVisibility.observer_overrides(sim, 0)
	var knowledge := KnowledgeState.new()
	var manifest := _official_manifest()
	_check(not manifest.is_empty(), "official manifest load failed")
	_check(
		knowledge.configure(0, "status-visibility-alias-salt".to_utf8_buffer(), manifest).is_empty(),
		"knowledge state setup failed"
	)
	var first := Projector.project_phase_12(
		knowledge, 0, "day", sim.grid.to_canonical_dict(), rows, [],
		overrides["temporary_vision_sources"],
		overrides["revealed_entity_internal_ids"]
	)
	_check(bool(first.get("ok", false)), "status-aware knowledge projection failed: %s" % _errors(first))
	_check(
		(first.get("projection", {}).get("visible_contacts", []) as Array).size() == 2,
		"knowledge projection did not contain exactly the two legally revealed contacts"
	)
	sim.state.tick = 60
	sim.state.combat.statuses = {
		10: _status(10, 1, 2, "invisibility", "invisibility", 1, 0, 120),
		12: _status(12, 1, 3, "invisibility", "invisibility", 1, 0, 120),
	}
	sim.abilities.state.casts.clear()
	sim.state.entities[2].hp = 7
	sim.state.entities[3].hp = 9
	var hidden_rows := AuthoritativeVisibility.augment_entity_snapshots(
		sim, _projection_rows(sim)
	)
	var second := Projector.project_phase_12(
		knowledge, 60, "day", sim.grid.to_canonical_dict(), hidden_rows
	)
	_check(bool(second.get("ok", false)), "hidden knowledge projection failed: %s" % _errors(second))
	_check(
		(second.get("projection", {}).get("visible_contacts", []) as Array).is_empty(),
		"expired reveal or detection remained visible"
	)
	var memory: Array = second.get("projection", {}).get("remembered_contacts", [])
	_check(memory.size() == 2, "legally seen contacts were not retained as frozen memory")
	for contact_variant: Variant in memory:
		var contact: Dictionary = contact_variant
		_check(
			int(contact["last_observed"]["hp"]) == 100,
			"hidden HP mutation leaked into remembered knowledge"
		)
	var public_json := Codec.canonical_json(second.get("projection", {}))
	_check(
		not public_json.contains("internal_id") and not public_json.contains("revealed_entity"),
		"provider-visible knowledge serialized protected visibility authority"
	)
	return {
		"candidate_ids": forward,
		"first_contacts": int((first.get("projection", {}).get("visible_contacts", []) as Array).size()),
		"memory_contacts": memory.size(),
		"visible_cells": int((computed.get("visible_cell_ids", []) as Array).size()),
	}


func _test_structure_disable_pause_and_resume() -> Dictionary:
	var loaded := CatalogLoader.load_official_catalogs()
	_check(bool(loaded.get("ok", false)), "official catalog load failed")
	if not bool(loaded.get("ok", false)):
		return {}
	var compiled := RuntimeCatalog.compile_selected_faction("vanguard-v1", loaded)
	_check(bool(compiled.get("ok", false)), "runtime catalog compile failed")
	if not bool(compiled.get("ok", false)):
		return {}
	var runtime: Dictionary = compiled["runtime"]
	var sim := Simulation.new({"grid_height": 20, "grid_width": 24, "match_seed": 92})
	_check(sim.configure_economy(runtime["economy"]).is_empty(), "economy setup failed")
	_check(sim.configure_combat(
		loaded["catalogs"]["attack_armor"],
		loaded["catalogs"]["faction:vanguard-v1"],
		loaded["catalogs"]["rules"]
	).is_empty(), "combat setup failed")
	_check(bool(sim.economy.configure_player(sim.state, 0, 2_000, 2_000, 1)["accepted"]), "seat 0 economy setup failed")
	_check(bool(sim.economy.configure_player(sim.state, 1, 2_000, 2_000, 1)["accepted"]), "seat 1 economy setup failed")
	var stronghold_type := str(runtime["structure_type_by_role"]["stronghold"])
	var barracks_type := str(runtime["structure_type_by_role"]["barracks"])
	var producer := _entity(1, 0, barracks_type, [2_250, 2_250], ["producer", "structure"])
	producer.max_hp = 3_000
	producer.hp = 3_000
	producer.radius_mt = 500
	var target_type := str((runtime["economy"]["units"] as Dictionary).keys()[0])
	var target := _entity(2, 1, target_type, [3_250, 2_250], ["biological", "ground"])
	var capacity := _entity(3, 0, stronghold_type, [6_250, 6_250], ["producer", "structure"])
	capacity.max_hp = 3_000
	capacity.hp = 3_000
	capacity.radius_mt = 500
	_check(sim.add_entity(producer, true) == 1, "producer add failed")
	_check(sim.add_entity(target, true) == 2, "combat target add failed")
	_check(sim.add_entity(capacity, true) == 3, "food-capacity structure add failed")
	_check(sim.economy.register_completed_entity(sim.state, 1).is_empty(), "producer economy registration failed")
	_check(sim.economy.register_completed_entity(sim.state, 3).is_empty(), "food-capacity economy registration failed")
	_check(sim.register_combat_entity(1, "structure", "tower").is_empty(), "structure attack profile failed")
	_check(sim.register_combat_entity(2, "unit", target_type).is_empty(), "target combat profile failed")
	var unit_type := str(runtime.get("unit_type_by_role", {}).get("worker", ""))
	if unit_type.is_empty():
		for unit_variant: Variant in runtime["economy"]["units"].keys():
			var definition: Dictionary = runtime["economy"]["units"][unit_variant]
			if "barracks" in definition.get("producer_roles", []):
				unit_type = str(unit_variant)
				break
	var queued := sim.economy.queue_production(sim.state, 0, 1, unit_type, 1)
	_check(bool(queued.get("accepted", false)), "production fixture queue failed: %s" % str(queued))
	var initial_remaining := int(sim.state.economy.production_queues[1][0]["remaining_ticks"])
	var status_receipt := sim.combat.add_status(
		sim.state, 1, 2, "disable_attack", "freezing_breath::disable", 1, 2
	)
	_check(bool(status_receipt.get("accepted", false)), "structure disable status add failed")
	var status_id := int(status_receipt.get("status_id", 0))
	sim.state.combat.statuses[status_id]["ability_id"] = "frost_drake_freezing_breath"
	sim.state.combat.statuses[status_id]["effect_kind"] = \
		"disable_structure_attack_and_production"
	var attack := sim.combat.issue_attack(sim.state, 1, 2)
	_check(bool(attack.get("accepted", false)), "structure attack order setup failed: %s" % str(attack))
	for tick: int in [0, 1]:
		sim.state.tick = tick
		sim.economy.collect_work_intents(sim.state)
		sim.economy.apply_collected_work(sim.state, sim.grid, tick)
		sim.combat.start_windups(sim.state, tick)
		_check(
			int(sim.state.economy.production_queues[1][0]["remaining_ticks"]) \
			== initial_remaining,
			"disabled producer advanced at tick %d" % tick
		)
		_check(sim.state.combat.windups.is_empty(), "disabled structure began an attack windup")
	sim.state.tick = 2
	sim.combat.expire_statuses(sim.state, 2)
	sim.economy.collect_work_intents(sim.state)
	sim.economy.apply_collected_work(sim.state, sim.grid, 2)
	sim.combat.start_windups(sim.state, 2)
	var resumed_remaining := int(sim.state.economy.production_queues[1][0]["remaining_ticks"])
	_check(resumed_remaining == initial_remaining - 1, "production did not resume on exact expiry tick")
	_check(not sim.state.combat.windups.is_empty(), "structure attack did not resume on expiry tick")
	return {
		"initial_remaining": initial_remaining,
		"resumed_remaining": resumed_remaining,
		"windups_after_resume": sim.state.combat.windups.size(),
	}


func _test_damage_wake_minimum() -> Dictionary:
	var forward := _damage_wake_case(false)
	var reverse := _damage_wake_case(true)
	_check(forward == reverse, "damage-wake result depended on status insertion order")
	var ledger_forward := _damage_wake_ledger_case(false)
	var ledger_reverse := _damage_wake_ledger_case(true)
	_check(ledger_forward == ledger_reverse,
		"damage-wake ledger result depended on delta insertion order")
	forward["simultaneous_net_heal_woke"] = ledger_forward
	return forward


func _damage_wake_case(reverse: bool) -> Dictionary:
	var sim := Simulation.new({"grid_height": 8, "grid_width": 8, "match_seed": 93})
	var sleeper := _entity(1, 0, "sleeper", [1_250, 1_250], ["biological", "ground"])
	_check(sim.add_entity(sleeper, true) == 1, "sleep fixture entity add failed")
	sim.state.combat.enabled = true
	var disable := _status(20, 2, 1, "disable", "disable", 1, 0, 90)
	var wake := _status(
		21, 2, 1, "damage_wakes_after_minimum_ticks",
		"damage_wakes_after_minimum_ticks", 20, 0, 90
	)
	disable["ability_id"] = "night_sovereign_sleep"
	wake["ability_id"] = "night_sovereign_sleep"
	if reverse:
		sim.state.combat.statuses[21] = wake
		sim.state.combat.statuses[20] = disable
	else:
		sim.state.combat.statuses[20] = disable
		sim.state.combat.statuses[21] = wake
	_check(
		not sim.combat.notify_hp_damage_applied(sim.state, 1, 19),
		"damage woke sleep before its locked minimum"
	)
	_check(sim.state.combat.statuses.size() == 2, "early damage removed a sleep status")
	_check(
		sim.combat.notify_hp_damage_applied(sim.state, 1, 20),
		"damage did not wake sleep at its locked minimum"
	)
	_check(sim.state.combat.statuses.is_empty(), "wake did not remove paired sleep statuses")
	return {"early_statuses": 2, "wake_tick": 20, "remaining_statuses": sim.state.combat.statuses.size()}


func _damage_wake_ledger_case(reverse: bool) -> bool:
	var sim := Simulation.new({"grid_height": 8, "grid_width": 8, "match_seed": 96})
	var sleeper := _entity(1, 0, "sleeper", [1_250, 1_250], ["biological", "ground"])
	sleeper.hp = 50
	_check(sim.add_entity(sleeper, true) == 1, "ledger sleep fixture entity add failed")
	sim.state.combat.enabled = true
	var disable := _status(40, 2, 1, "disable", "disable", 1, 0, 90)
	var wake := _status(
		41, 2, 1, "damage_wakes_after_minimum_ticks",
		"damage_wakes_after_minimum_ticks", 20, 0, 90
	)
	disable["ability_id"] = "night_sovereign_sleep"
	wake["ability_id"] = "night_sovereign_sleep"
	sim.state.combat.statuses[40] = disable
	sim.state.combat.statuses[41] = wake
	sim.state.tick = 20
	var damage := DeltaRecord.new()
	damage.application_tick = 20
	damage.entity_id = 1
	damage.kind = DeltaRecord.Kind.HP
	damage.amount = -10
	damage.source_internal_id = 2
	damage.local_seq = 1
	var heal := DeltaRecord.new()
	heal.application_tick = 20
	heal.entity_id = 1
	heal.kind = DeltaRecord.Kind.HP
	heal.amount = 20
	heal.source_internal_id = 1
	heal.local_seq = 2
	var deltas: Array = [damage, heal]
	if reverse:
		deltas.reverse()
	for delta_variant: Variant in deltas:
		_check(sim.ledger.queue_delta(delta_variant).is_empty(), "wake ledger delta rejected")
	sim.step_tick(false)
	_check(sim.state.entities[1].hp == 60, "simultaneous damage/heal aggregate was incorrect")
	var woke := sim.state.combat.statuses.is_empty()
	_check(woke, "post-shield HP damage hidden by net healing did not wake sleep")
	return woke


func _test_trap_first_enemy_trigger() -> Dictionary:
	var forward := _trap_trigger_case(false)
	var reverse := _trap_trigger_case(true)
	_check(forward == reverse, "trap trigger depended on combat actor insertion order")
	return forward


func _trap_trigger_case(reverse: bool) -> Dictionary:
	var sim := Simulation.new({"grid_height": 16, "grid_width": 20, "match_seed": 94})
	_check(sim.configure_abilities("warhost-v1").is_empty(), "warhost ability setup failed")
	var source := _entity(1, 0, "dusk_hunter", [1_250, 1_250], ["ground"])
	var trap := _entity(2, 0, "invisible_trap", [5_250, 5_250], [
		"ground", "immobile", "invisible", "summon", "trap",
	])
	trap.max_hp = 1
	trap.hp = 1
	trap.integer_attributes["summon_source_id"] = 1
	var enemy_internal_first := _entity(3, 1, "enemy_z", [4_750, 5_250], ["ground"])
	enemy_internal_first.public_id = "z_target"
	var enemy_public_first := _entity(4, 1, "enemy_a", [5_750, 5_250], ["ground"])
	enemy_public_first.public_id = "a_target"
	for entity: EntityRecord in [source, trap, enemy_internal_first, enemy_public_first]:
		_check(sim.add_entity(entity, true) == entity.internal_id, "trap fixture entity add failed")
	sim.state.combat.enabled = true
	if reverse:
		sim.state.combat.actors[4] = {"layer": "ground"}
		sim.state.combat.actors[3] = {"layer": "ground"}
	else:
		sim.state.combat.actors[3] = {"layer": "ground"}
		sim.state.combat.actors[4] = {"layer": "ground"}
	sim.abilities.state.persistent_effects[90] = {
		"ability_id": "dusk_hunter_snare_trap",
		"cast_id": 80,
		"dispel_class": "ordinary_magical",
		"effect_id": 90,
		"effect_kind": "root_first_enemy",
		"rank": 2,
		"resolved_duration_ticks": 60,
		"resolved_value": 1,
		"source_id": 1,
		"status_stacking_key": "snare_trap",
		"target": {"kind": "point", "position_mt": [5_250, 5_250]},
	}
	_check(
		sim.abilities.persistent_effect_snapshot().is_empty(),
		"armed root leaked into generic persistent aura synchronization"
	)
	var result: Dictionary = sim.abilities.resolve_armed_triggers(sim)
	_check(bool(result.get("ok", false)), "trap trigger resolver failed: %s" % _errors(result))
	_check(int(result.get("triggered", 0)) == 1, "armed trap did not trigger exactly once")
	_check(sim.abilities.persistent_effect_snapshot().is_empty(), "consumed trap effect remained persistent")
	_check(sim.state.entities[2].hp == 0, "triggered trap was not consumed")
	_check(sim.state.combat.statuses.size() == 1, "trap did not create exactly one root status")
	var status: Dictionary = sim.state.combat.statuses.values()[0]
	_check(int(status["target_id"]) == 4, "equal-distance trap tie did not use stable public ID")
	_check(int(status["expiry_tick"]) == 60, "trap root duration was not exact")
	return {
		"duration_ticks": int(status["expiry_tick"]) - int(status["start_tick"]),
		"target_id": int(status["target_id"]),
		"triggered": int(result.get("triggered", 0)),
	}


func _test_persistent_visible_aura_pruning() -> Dictionary:
	var sim := Simulation.new({"grid_height": 12, "grid_width": 20, "match_seed": 95})
	_check(sim.configure_abilities("crypt-v1").is_empty(), "crypt ability setup failed")
	var source := _entity(1, 0, "night_sovereign", [1_250, 1_250], ["ground"])
	source.integer_attributes["sight_day_mt"] = 1_000
	source.integer_attributes["sight_night_mt"] = 1_000
	var target := _entity(2, 1, "hidden_enemy", [5_250, 1_250], ["ground"])
	_check(sim.add_entity(source, true) == 1, "aura source add failed")
	_check(sim.add_entity(target, true) == 2, "aura target add failed")
	sim.state.combat.enabled = true
	sim.state.combat.actors[1] = {"layer": "ground"}
	sim.state.combat.actors[2] = {"layer": "ground"}
	sim.abilities.state.persistent_effects[91] = {
		"ability_id": "night_sovereign_dread_aura",
		"effect_id": 91,
		"effect_kind": "damage_dealt_bp",
		"source_id": 1,
	}
	var hidden_status := _status(
		30, 1, 2, "damage_dealt_bp", "damage_dealt_bp", -500, 0, 2
	)
	hidden_status["ability_id"] = "night_sovereign_dread_aura"
	sim.state.combat.statuses[30] = hidden_status
	var removed_hidden := sim.abilities.prune_illegal_persistent_visibility_statuses(sim)
	_check(removed_hidden == 1 and sim.state.combat.statuses.is_empty(),
		"persistent visible aura mutated a hidden hostile")
	sim.grid.release_ground_actor(2)
	sim.state.entities[2].set_position_mt(1_750, 1_250)
	_check(
		sim.grid.reserve_ground_actor(2, 1_750, 1_250, sim.state.entities[2].radius_mt),
		"visible aura target reposition failed"
	)
	var visible_status := hidden_status.duplicate(true)
	visible_status["status_id"] = 31
	sim.state.combat.statuses[31] = visible_status
	var removed_visible := sim.abilities.prune_illegal_persistent_visibility_statuses(sim)
	_check(removed_visible == 0 and sim.state.combat.statuses.has(31),
		"persistent visible aura pruned a legally visible hostile")
	return {"hidden_removed": removed_hidden, "visible_removed": removed_visible}


func _projection_rows(sim: Variant) -> Array:
	var result: Array = []
	var grid: Dictionary = sim.grid.to_canonical_dict()
	for entity_id: int in sim.state.sorted_entity_ids():
		var entity: EntityRecord = sim.state.entities[entity_id]
		var cells: Array = sim.grid.ground_cells_for_actor(entity_id)
		cells.sort()
		result.append({
			"alive": entity.alive,
			"catalog_id": entity.catalog_id,
			"hp": entity.hp,
			"internal_id": entity_id,
			"mana": entity.mana,
			"max_hp": entity.max_hp,
			"observable_activity": "idle",
			"occupied_cell_ids": cells,
			"owner_seat": entity.owner_seat,
			"position_mt": [entity.position_x_mt, entity.position_y_mt],
			"region_id": str(grid["region_ids"][cells[0]]) if not cells.is_empty() else "unknown",
			"sight_day_mt": int(entity.integer_attributes.get("sight_day_mt", 0)),
			"sight_night_mt": int(entity.integer_attributes.get("sight_night_mt", 0)),
			"tags": entity.tags.duplicate(),
			"type_id": entity.catalog_id,
			"visible_statuses": [],
		})
	return result


func _entity(
	entity_id: int, seat: int, catalog_id: String, position: Array, tags: Array
) -> EntityRecord:
	var entity := EntityRecord.new(entity_id, seat, "structure" if "structure" in tags else "unit")
	entity.public_id = "e_fixture_%08d" % entity_id
	entity.catalog_id = catalog_id
	entity.set_position_mt(int(position[0]), int(position[1]))
	entity.max_hp = 100
	entity.hp = 100
	entity.radius_mt = 100
	entity.tags.assign(tags)
	entity.tags.sort()
	return entity


func _status(
	status_id: int,
	source_id: int,
	target_id: int,
	status_kind: String,
	effect_kind: String,
	magnitude: int,
	start_tick: int,
	expiry_tick: int
) -> Dictionary:
	return {
		"dispel_class": "ordinary_magical",
		"effect_kind": effect_kind,
		"expiry_tick": expiry_tick,
		"magnitude": magnitude,
		"source_id": source_id,
		"stacking_key": "fixture::%d" % status_id,
		"start_tick": start_tick,
		"status_id": status_id,
		"status_kind": status_kind,
		"target_id": target_id,
	}


func _official_manifest() -> Dictionary:
	var file := FileAccess.open(
		"res://../game/duel_protocol/maps/crossroads-duel-v1.json", FileAccess.READ
	)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	return normalized.get("value", {}) if bool(normalized.get("ok", false)) else {}


func _errors(result: Dictionary) -> String:
	var values := PackedStringArray()
	for value: Variant in result.get("errors", []):
		values.append(str(value))
	return "; ".join(values)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
