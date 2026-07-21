extends SceneTree

const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")

const GOLDEN_SCENARIO_HASH := "fd08c03adec0d001486de72a0dc061d2476e39a22de221397f23c73fccab608e"

var _failures := PackedStringArray()


func _init() -> void:
	_test_finite_remainder_and_upkeep()
	_test_tier_and_upgrade_completion()
	var first := _run_vanguard_scenario(false)
	if not GOLDEN_SCENARIO_HASH.is_empty():
		_check(str(first["hash"]) == GOLDEN_SCENARIO_HASH, "economy golden hash changed: %s" % first["hash"])
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_ECONOMY_FAILURE: %s" % failure)
		print("DUEL_ECONOMY_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_ECONOMY_OK hash=%s summary=%s" % [first["hash"], JSON.stringify(first["summary"])])
	quit(0)


func _run_vanguard_scenario(reverse_insertion: bool) -> Dictionary:
	var sim := Simulation.new({"grid_height": 24, "grid_width": 32, "match_seed": 72_019})
	_check(sim.configure_economy(_vanguard_catalog()).is_empty(), "Vanguard economy catalog failed")
	var configured := sim.economy.configure_player(sim.state, 0, 500, 200, 1)
	_check(bool(configured["accepted"]), "seat economy did not configure")
	var entities: Array[EntityRecord] = []
	entities.append(_entity(1, 0, "structure", "vanguard-citadel", 3_250, 5_250, 3_000, 500, ["deposit", "producer"]))
	entities.append(_entity(2, 0, "structure", "vanguard-homestead", 5_250, 5_250, 650, 350, []))
	for index: int in 5:
		entities.append(_entity(
			10 + index, 0, "unit", "vanguard-mason",
			6_250 + index * 500, 8_250, 240, 100, ["worker"]
		))
	entities.append(_entity(20, -1, "resource", "home-gold-mine", 11_250, 7_250, 1, 0, ["resource"]))
	entities.append(_entity(21, -1, "resource", "home-tree-cluster", 11_250, 9_250, 1, 0, ["resource"]))
	if reverse_insertion:
		entities.reverse()
	for entity: EntityRecord in entities:
		var reserve_occupancy := entity.owner_seat >= 0
		_check(sim.add_entity(entity, reserve_occupancy) == entity.internal_id, "fixture entity failed to add")
	for entity_id: int in [1, 2, 10, 11, 12, 13, 14]:
		_check(sim.economy.register_completed_entity(sim.state, entity_id).is_empty(), "fixture economic entity failed to register")
	_check(sim.economy.register_resource_node(sim.state, 20, "gold", 12_000, 5, 10, 20).is_empty(), "gold mine failed to register")
	_check(sim.economy.register_resource_node(sim.state, 21, "lumber", 3_000, 2, 10, 30).is_empty(), "forest failed to register")

	var player: Dictionary = sim.state.economy.players[0]
	_check(player["gold"] == 500 and player["lumber"] == 200, "Vanguard starting resources are wrong")
	_check(player["food_used"] == 5 and player["food_capacity"] == 20, "Vanguard starting food is wrong")
	_check(sim.state.economy.resource_nodes[20]["stock"] == 12_000, "home mine does not start at 12000")

	var gather_gold := sim.economy.assign_gather(sim.state, 0, [10, 11, 12], 20, 1, 2, 3)
	var gather_lumber := sim.economy.assign_gather(sim.state, 0, [13, 14], 21, 1, 3, 3)
	_check(bool(gather_gold["accepted"]) and bool(gather_lumber["accepted"]), "gather orders were rejected")
	_run_until(sim, func() -> bool: return player["gold"] >= 530 and player["lumber"] >= 220, 100, "initial deposits")
	_check(int(sim.state.economy.resource_nodes[20]["stock"]) < 12_000, "gold mine did not deplete")
	_check(int(sim.state.economy.resource_nodes[21]["stock"]) < 3_000, "trees did not deplete")
	## Deterministic scenario funding isolates the long-duration build/production
	## rules from thousands of redundant gather ticks. Exact cargo, work,
	## depletion, deposit, and upkeep behavior is asserted independently above.
	player["gold"] = 1_900
	player["lumber"] = 850

	var homestead_receipt := sim.economy.begin_construction(
		sim.state, sim.grid, 0, "vanguard-homestead", "fixture-food-site",
		7_250, 10_250, [10, 11, 12, 13, 14]
	)
	_check(bool(homestead_receipt["accepted"]), "Homestead construction was rejected")
	var new_homestead_id := int(homestead_receipt["details"]["building_id"])
	_check(sim.state.entities[new_homestead_id].hp == 65, "incomplete Vanguard Homestead did not start at 10% HP")
	_check(player["food_capacity"] == 20, "incomplete Homestead provided food")
	var homestead_start_tick := sim.state.tick
	_run_until(sim, func() -> bool: return sim.state.economy.entity_records.has(new_homestead_id), 200, "Homestead completion")
	_check(sim.state.tick - homestead_start_tick == 90, "five-worker Homestead multiplier did not complete in 90 ticks")
	_check(player["food_capacity"] == 30, "completed Homestead did not provide 10 food")

	var garrison_receipt := sim.economy.begin_construction(
		sim.state, sim.grid, 0, "vanguard-garrison", "fixture-barracks-site",
		10_250, 10_250, [10, 11, 12, 13, 14]
	)
	_check(bool(garrison_receipt["accepted"]), "Garrison construction was rejected")
	var garrison_id := int(garrison_receipt["details"]["building_id"])
	var garrison_start_tick := sim.state.tick
	_run_until(sim, func() -> bool: return sim.state.economy.entity_records.has(garrison_id), 300, "Garrison completion")
	_check(sim.state.tick - garrison_start_tick == 215, "five-worker Garrison multiplier did not complete in 215 ticks")

	var produce_receipt := sim.economy.queue_production(sim.state, 0, garrison_id, "vanguard-footguard", 2)
	_check(bool(produce_receipt["accepted"]), "Footguard production was rejected")
	_check(player["reserved_food"] == 4 and player["food_used"] == 5, "production food was not reserved")
	var second_entry_id := int(sim.state.economy.production_queues[garrison_id][1]["entry_id"])
	var cancel_queue_receipt := sim.economy.cancel_queue_entry(sim.state, 0, garrison_id, second_entry_id)
	_check(bool(cancel_queue_receipt["accepted"]), "queued Footguard cancellation was rejected")
	_check(int(cancel_queue_receipt["details"]["refund_gold"]) == 121, "zero-progress queue refund was not floor(90%)")
	_check(player["reserved_food"] == 2, "queue cancellation did not release reserved food")
	var tier_receipt := sim.economy.queue_tier_upgrade(sim.state, 0, 1, 2)
	_check(bool(tier_receipt["accepted"]), "Tier-2 upgrade was rejected")

	var production_start_tick := sim.state.tick
	_run_until(sim, func() -> bool: return _count_catalog(sim, "vanguard-footguard") == 1, 350, "Footguard completion")
	_check(sim.state.tick - production_start_tick == 250, "Footguard did not complete in exactly 250 ticks")
	_check(player["reserved_food"] == 0 and player["food_used"] == 7, "completed Footguard food accounting is wrong")
	_check(sim.state.economy.tier_queues.has(0), "Tier-2 queue disappeared before completion")
	_check(int(sim.state.economy.tier_queues[0]["remaining_ticks"]) == 500, "Tier-2 queue did not advance exactly 250 ticks")

	var garrison: EntityRecord = sim.state.entities[garrison_id]
	garrison.hp -= 100
	var gold_before_repair := int(player["gold"])
	var repair_receipt := sim.economy.assign_repair(sim.state, 0, garrison_id, [10, 11])
	_check(bool(repair_receipt["accepted"]), "repair assignment was rejected")
	var repair_start_tick := sim.state.tick
	_run_until(sim, func() -> bool: return garrison.hp == garrison.max_hp, 40, "Garrison repair")
	_check(sim.state.tick - repair_start_tick == 25, "two workers did not repair exactly 4 HP per tick")
	_check(gold_before_repair - int(player["gold"]) == 5, "repair ledger did not charge exact proportional gold")

	var tower_receipt := sim.economy.begin_construction(
		sim.state, sim.grid, 0, "vanguard-tower", "fixture-cancel-site",
		13_250, 10_250, [10]
	)
	_check(bool(tower_receipt["accepted"]), "cancellation fixture construction was rejected")
	var tower_id := int(tower_receipt["details"]["building_id"])
	for _tick: int in 10:
		sim.step_tick()
	var gold_before_cancel := int(player["gold"])
	var lumber_before_cancel := int(player["lumber"])
	var cancel_receipt := sim.economy.cancel_construction(sim.state, sim.grid, 0, tower_id)
	_check(bool(cancel_receipt["accepted"]), "construction cancellation was rejected")
	_check(int(player["gold"]) - gold_before_cancel == 108, "pre-25% gold refund was not 90%")
	_check(int(player["lumber"]) - lumber_before_cancel == 72, "pre-25% lumber refund was not 90%")
	_check(sim.validate().is_empty(), "completed economy scenario failed validation: %s" % "; ".join(sim.validate()))

	var event_counts := {}
	for event_variant: Variant in sim.state.events:
		var kind := str(event_variant.event_kind)
		event_counts[kind] = int(event_counts.get(kind, 0)) + 1
	var summary := {
		"food_capacity": int(player["food_capacity"]),
		"food_used": int(player["food_used"]),
		"gold": int(player["gold"]),
		"lumber": int(player["lumber"]),
		"receipts": sim.state.economy.receipts.size(),
		"resource_deposits": int(event_counts.get("resource_deposited", 0)),
		"tick": sim.state.tick,
		"tier_queue_remaining": int(sim.state.economy.tier_queues[0]["remaining_ticks"]),
		"units": _count_catalog(sim, "vanguard-footguard"),
	}
	return {"hash": sim.checkpoint_hash(), "summary": summary}


func _test_finite_remainder_and_upkeep() -> void:
	var sim := Simulation.new({"grid_height": 16, "grid_width": 16, "match_seed": 4})
	_check(sim.configure_economy(_vanguard_catalog()).is_empty(), "remainder fixture catalog failed")
	sim.economy.configure_player(sim.state, 0, 0, 0, 1)
	var citadel := _entity(1, 0, "structure", "vanguard-citadel", 2_250, 2_250, 3_000, 250, ["deposit"])
	var worker_a := _entity(2, 0, "unit", "vanguard-mason", 4_250, 2_250, 240, 100, ["worker"])
	var worker_b := _entity(3, 0, "unit", "vanguard-mason", 4_750, 2_250, 240, 100, ["worker"])
	var mine := _entity(4, -1, "resource", "tiny-mine", 6_250, 2_250, 1, 0, ["resource"])
	for entity: EntityRecord in [citadel, worker_a, worker_b, mine]:
		sim.add_entity(entity, entity.owner_seat >= 0)
	for entity_id: int in [1, 2, 3]:
		sim.economy.register_completed_entity(sim.state, entity_id)
	sim.economy.register_resource_node(sim.state, 4, "gold", 15, 2, 10, 1)
	var player: Dictionary = sim.state.economy.players[0]
	player["food_capacity"] = 100
	player["food_used"] = 51
	sim.economy.assign_gather(sim.state, 0, [2, 3], 4, 1, 0, 0)
	for _tick: int in 5:
		sim.step_tick()
	_check(int(sim.state.economy.resource_nodes[4]["stock"]) == 0, "finite remainder was not exhausted")
	_check(int(player["gold"]) == 10, "low-upkeep deposits did not floor 10 and 5 cargo to 7 and 3")
	_check(str(player["upkeep_tier"]) == "low", "51 food did not select low upkeep")
	var extracted_by_worker := {}
	for event_variant: Variant in sim.state.events:
		if str(event_variant.event_kind) == "resource_extracted":
			extracted_by_worker[int(event_variant.source_internal_id)] = int(event_variant.payload["amount"])
	_check(int(extracted_by_worker.get(2, 0)) == 10, "lowest worker ID did not receive the first finite-resource cargo")
	_check(int(extracted_by_worker.get(3, 0)) == 5, "second worker did not receive the five-unit remainder")


func _test_tier_and_upgrade_completion() -> void:
	var sim := Simulation.new({"grid_height": 12, "grid_width": 16, "match_seed": 8})
	_check(sim.configure_economy(_vanguard_catalog()).is_empty(), "tier fixture catalog failed")
	sim.economy.configure_player(sim.state, 0, 2_000, 1_000, 1)
	var citadel := _entity(1, 0, "structure", "vanguard-citadel", 2_250, 2_250, 3_000, 250, ["deposit"])
	var armory := _entity(2, 0, "structure", "vanguard-armory", 5_250, 2_250, 900, 250, ["producer"])
	for entity: EntityRecord in [citadel, armory]:
		sim.add_entity(entity)
		sim.economy.register_completed_entity(sim.state, entity.internal_id)
	var tier_receipt := sim.economy.queue_tier_upgrade(sim.state, 0, 1, 2)
	var upgrade_receipt := sim.economy.queue_upgrade(sim.state, 0, 2, "shared-melee-attack")
	_check(bool(tier_receipt["accepted"]) and bool(upgrade_receipt["accepted"]), "tier/research entries were rejected")
	for _tick: int in 750:
		sim.step_tick()
	var player: Dictionary = sim.state.economy.players[0]
	_check(int(player["technology_tier"]) == 2 and int(player["hero_slots"]) == 2, "Tier 2 did not complete exactly at 750 ticks")
	_check(int(player["completed_upgrades"].get("shared-melee-attack", 0)) == 1, "shared upgrade did not complete")
	_check(not sim.state.economy.tier_queues.has(0), "completed tier queue was retained")
	_check((sim.state.economy.production_queues.get(2, []) as Array).is_empty(), "completed research queue was retained")


func _run_until(sim: Simulation, predicate: Callable, limit: int, label: String) -> void:
	for _tick: int in limit:
		if predicate.call():
			return
		sim.step_tick()
	_check(predicate.call(), "%s did not finish within %d ticks" % [label, limit])


func _count_catalog(sim: Simulation, catalog_id: String) -> int:
	var count := 0
	for entity_id: int in sim.state.sorted_entity_ids():
		var entity: EntityRecord = sim.state.entities[entity_id]
		if entity.alive and entity.catalog_id == catalog_id:
			count += 1
	return count


func _entity(
	internal_id: int,
	seat: int,
	kind: String,
	catalog_id: String,
	x_mt: int,
	y_mt: int,
	max_hp: int,
	radius_mt: int,
	tags: Array[String]
) -> EntityRecord:
	var entity := EntityRecord.new(internal_id, seat, kind)
	entity.catalog_id = catalog_id
	entity.max_hp = max_hp
	entity.hp = max_hp
	entity.radius_mt = radius_mt
	entity.set_position_mt(x_mt, y_mt)
	entity.tags.assign(tags)
	return entity


func _vanguard_catalog() -> Dictionary:
	var common_exit_offsets := [
		{"x": 0, "y": -4}, {"x": 1, "y": -4}, {"x": 2, "y": -4},
		{"x": 3, "y": -3}, {"x": 4, "y": -2}, {"x": 4, "y": -1},
		{"x": 4, "y": 0}, {"x": 4, "y": 1}, {"x": 4, "y": 2},
		{"x": 3, "y": 3}, {"x": 2, "y": 4}, {"x": 1, "y": 4},
		{"x": 0, "y": 4}, {"x": -1, "y": 4}, {"x": -2, "y": 4},
		{"x": -3, "y": 3}, {"x": -4, "y": 2}, {"x": -4, "y": 1},
		{"x": -4, "y": 0}, {"x": -4, "y": -1}, {"x": -4, "y": -2},
		{"x": -3, "y": -3}, {"x": -2, "y": -4}, {"x": -1, "y": -4},
	]
	return {
		"catalog_id": "vanguard-economy-fixture-v1",
		"construction": {
			"cooperative_speed_bp": [10_000, 16_000, 21_000, 25_000, 28_000],
			"full_repair_cost_bp_of_original": 3_000,
			"minimum_incomplete_hp_bp": 1_000,
			"repair_hp_per_worker_tick": 2,
			"work_bp_per_worker_tick": 100,
		},
		"food_and_upkeep": {
			"maximum_food": 100,
			"upkeep": [
				{"gold_delivery_bp": 10_000, "maximum_used": 50, "minimum_used": 0, "tier": "none"},
				{"gold_delivery_bp": 7_000, "maximum_used": 80, "minimum_used": 51, "tier": "low"},
				{"gold_delivery_bp": 4_000, "maximum_used": 100, "minimum_used": 81, "tier": "high"},
			],
		},
		"structures": {
			"vanguard-armory": {
				"build_ticks": 500, "cost_gold": 180, "cost_lumber": 120,
				"food_provided": 0, "max_hp": 900, "radius_mt": 500,
				"required_tier": 1, "semantic_role": "forge", "tags": ["producer", "structure"],
				"worker_range_mt": 4_000, "exit_offsets_cells": common_exit_offsets,
			},
			"vanguard-citadel": {
				"build_ticks": 0, "cost_gold": 0, "cost_lumber": 0,
				"food_provided": 10, "is_deposit": true, "max_hp": 3_000,
				"radius_mt": 500, "required_tier": 1, "semantic_role": "stronghold",
				"tags": ["deposit", "producer", "structure"], "worker_range_mt": 4_000,
				"exit_offsets_cells": common_exit_offsets,
			},
			"vanguard-garrison": {
				"build_ticks": 600, "cost_gold": 220, "cost_lumber": 100,
				"food_provided": 0, "max_hp": 1_200, "radius_mt": 500,
				"required_tier": 1, "semantic_role": "barracks",
				"tags": ["producer", "structure"], "worker_range_mt": 4_000,
				"exit_offsets_cells": common_exit_offsets,
			},
			"vanguard-homestead": {
				"build_ticks": 250, "cost_gold": 100, "cost_lumber": 40,
				"food_provided": 10, "max_hp": 650, "radius_mt": 350,
				"required_tier": 1, "semantic_role": "food",
				"tags": ["food", "structure"], "worker_range_mt": 4_000,
				"exit_offsets_cells": common_exit_offsets,
			},
			"vanguard-township": {
				"build_ticks": 700, "cost_gold": 450, "cost_lumber": 250,
				"food_provided": 10, "is_deposit": true, "max_hp": 1_800,
				"radius_mt": 500, "required_tier": 1, "semantic_role": "expansion_hall",
				"tags": ["deposit", "producer", "structure"], "worker_range_mt": 4_000,
				"exit_offsets_cells": common_exit_offsets,
			},
			"vanguard-tower": {
				"build_ticks": 450, "cost_gold": 120, "cost_lumber": 80,
				"food_provided": 0, "max_hp": 650, "radius_mt": 350,
				"required_tier": 1, "semantic_role": "tower",
				"tags": ["structure"], "worker_range_mt": 4_000,
				"exit_offsets_cells": common_exit_offsets,
			},
		},
		"technology": {
			"tier_2": {"cost_gold": 650, "cost_lumber": 250, "duration_ticks": 750, "hero_slots": 2},
			"tier_3": {"cost_gold": 900, "cost_lumber": 350, "duration_ticks": 900, "hero_slots": 3},
		},
		"units": {
			"vanguard-footguard": {
				"cost_gold": 135, "cost_lumber": 0, "food_cost": 2,
				"is_worker": false, "max_hp": 520, "max_mana": 0,
				"producer_roles": ["barracks"], "radius_mt": 100,
				"required_tier": 1, "semantic_role": "melee", "tags": ["biological", "melee"],
				"train_ticks": 250,
			},
			"vanguard-mason": {
				"cost_gold": 75, "cost_lumber": 0, "food_cost": 1,
				"is_worker": true, "max_hp": 240, "max_mana": 0,
				"producer_roles": ["barracks", "expansion_hall", "stronghold"],
				"radius_mt": 100, "required_tier": 1, "semantic_role": "worker",
				"tags": ["biological", "worker"], "train_ticks": 150,
			},
		},
		"upgrades": {
			"shared-melee-attack": {
				"levels": [
					{"cost_gold": 150, "cost_lumber": 75, "research_ticks": 400, "required_tier": 1},
					{"cost_gold": 225, "cost_lumber": 125, "research_ticks": 500, "required_tier": 2},
					{"cost_gold": 300, "cost_lumber": 175, "research_ticks": 600, "required_tier": 3},
				],
				"producer_roles": ["forge"],
			},
		},
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
