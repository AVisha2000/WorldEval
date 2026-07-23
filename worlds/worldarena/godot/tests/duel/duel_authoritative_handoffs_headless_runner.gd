extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const MatchRuntime := preload("res://scripts/duel/match/duel_match_runtime.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const IntentBridge := preload("res://scripts/duel/controller/duel_intent_execution_bridge.gd")
const ResolutionContext := preload("res://scripts/duel/controller/duel_intent_resolution_context.gd")

const TIE_KEY := "worldarena-authoritative-handoffs-v1"

var _failures := PackedStringArray()
var _loaded: Dictionary = {}


func _init() -> void:
	_loaded = CatalogLoader.load_official_catalogs()
	_check(bool(_loaded.get("ok", false)), "official catalogs failed to load")
	if bool(_loaded.get("ok", false)):
		_test_hero_production_handoff()
		_test_neutral_hire_handoff()
		_test_ground_attack_bridge_and_area_impact()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_AUTHORITATIVE_HANDOFF_FAILURE: %s" % failure)
		print("DUEL_AUTHORITATIVE_HANDOFFS_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_AUTHORITATIVE_HANDOFFS_OK")
	quit(0)


func _test_hero_production_handoff() -> void:
	var fixture := _attached_fixture(91_101)
	if fixture.is_empty():
		return
	var sim: Variant = fixture["simulation"]
	var runtime: Dictionary = fixture["runtime"]
	var altar_id := _add_completed_altar(sim, runtime, fixture["map_manifest"])
	if altar_id <= 0:
		return
	var context := ResolutionContext.new()
	var context_errors := context.configure({
		"entities": {"e_altar": {"internal_id": altar_id, "owner_seat": 0}},
		"world_max_inclusive_mt": [191_999, 127_999],
	}, TIE_KEY.to_utf8_buffer())
	_check(context_errors.is_empty(), "Hero production context failed: %s" % "; ".join(context_errors))
	if not context_errors.is_empty():
		return
	var intent := _intent(
		"produce", "economy", 0, "e_altar", altar_id, {},
		{"quantity_index": 0, "requested_quantity": 1, "unit_type_id": "marshal"},
		"none", sim.state.tick, "batch.hero.first", 0
	)
	var bridge := IntentBridge.new()
	var executed: Dictionary = bridge.execute(sim, [intent], context)
	_check(bool(executed.get("ok", false)), "Hero produce intent bridge failed")
	var receipts: Array = executed.get("receipts", [])
	_check(receipts.size() == 1 and str((receipts[0] as Dictionary).get("status", "")) == "applied",
		"first Hero produce intent was not applied")
	var player: Dictionary = sim.state.economy.players[0]
	_check(int(player["gold"]) == 500 and int(player["lumber"]) == 200,
		"first Hero was not free")
	_check(int(player["food_used"]) == 5 and int(player["reserved_food"]) == 5,
		"first Hero food was not reserved")
	var queue: Array = sim.state.economy.production_queues.get(altar_id, [])
	_check(queue.size() == 1, "first Hero did not enter the altar FIFO")
	if queue.is_empty():
		return
	var entry: Dictionary = queue[0]
	_check(str(entry.get("kind", "")) == "hero" and int(entry.get("total_ticks", 0)) == 450,
		"first Hero did not use frozen 450-tick training rules")
	entry["remaining_ticks"] = 1
	var expected_hero_id: int = sim.state.next_entity_id
	sim.step_tick(false)
	_check(sim.state.entities.has(expected_hero_id), "completed Hero entity was not spawned")
	if not sim.state.entities.has(expected_hero_id):
		return
	var hero: EntityRecord = sim.state.entities[expected_hero_id]
	_check(hero.entity_kind == "hero" and hero.catalog_id == "marshal" and "hero" in hero.tags,
		"completed Hero identity/tags are incorrect")
	_check(sim.state.economy.entity_records.has(expected_hero_id),
		"completed Hero was not registered with economy")
	_check(sim.state.heroes.heroes.has(expected_hero_id),
		"completed Hero was not registered with Hero authority")
	_check(sim.state.combat.actors.has(expected_hero_id),
		"completed Hero was not registered with combat")
	_check(sim.state.movement.actors.has(expected_hero_id),
		"completed Hero was not registered with movement")
	_check(sim.state.abilities.actors.has(expected_hero_id),
		"completed Hero was not registered with abilities")
	_check(hero.hp == hero.max_hp and hero.max_hp > 400 and hero.mana == hero.max_mana,
		"Hero authority did not apply derived spawn vitals")
	_check(int(player["food_used"]) == 10 and int(player["reserved_food"]) == 0,
		"completed Hero food was not committed")
	_check(_event_count(sim, "spawn_authority_error") == 0,
		"Hero completion emitted a spawn authority error")
	var duplicate: Dictionary = sim.economy.queue_hero_production(
		sim.state, 0, altar_id, "marshal",
		sim.heroes.catalog["faction"]["heroes"]["marshal"],
		sim.heroes.catalog["rules"]["heroes"]
	)
	_check(not bool(duplicate["accepted"]) and str(duplicate["code"]) == "already_completed",
		"named Hero archetype limit was not enforced")
	var tier_one_second: Dictionary = sim.economy.queue_hero_production(
		sim.state, 0, altar_id, "high_arcanist",
		sim.heroes.catalog["faction"]["heroes"]["high_arcanist"],
		sim.heroes.catalog["rules"]["heroes"]
	)
	_check(not bool(tier_one_second["accepted"]) and str(tier_one_second["code"]) == "prerequisite_missing",
		"Tier-1 one-Hero slot limit was not enforced")
	player["technology_tier"] = 2
	player["hero_slots"] = 2
	var later: Dictionary = sim.economy.queue_hero_production(
		sim.state, 0, altar_id, "high_arcanist",
		sim.heroes.catalog["faction"]["heroes"]["high_arcanist"],
		sim.heroes.catalog["rules"]["heroes"]
	)
	_check(bool(later["accepted"]), "Tier-2 second Hero was rejected")
	queue = sim.state.economy.production_queues.get(altar_id, [])
	_check(queue.size() == 1 and int((queue[0] as Dictionary).get("total_ticks", 0)) == 550,
		"later Hero did not use frozen 550-tick training")
	_check(int(player["gold"]) == 75 and int(player["lumber"]) == 100 \
		and int(player["reserved_food"]) == 5,
		"later Hero cost/food reservation drifted from frozen rules")
	var barracks_id := _add_completed_structure(
		sim, runtime, fixture["map_manifest"], "barracks",
		"bs_self_home_inner_04_barracks", "e_test_barracks"
	)
	var worker_type_id := str(runtime["starting_state"]["worker_type_id"])
	var produced_unit: Dictionary = sim.economy.queue_production(
		sim.state, 0, barracks_id, worker_type_id, 1
	)
	_check(bool(produced_unit["accepted"]), "ordinary mobile production was rejected: %s" % str(produced_unit.get("code", "")))
	var worker_queue: Array = sim.state.economy.production_queues.get(barracks_id, [])
	if not worker_queue.is_empty():
		(worker_queue[0] as Dictionary)["remaining_ticks"] = 1
		var expected_worker_id: int = sim.state.next_entity_id
		sim.step_tick(false)
		_check(sim.state.economy.entity_records.has(expected_worker_id),
			"completed mobile was not registered with economy")
		_check(sim.state.combat.actors.has(expected_worker_id),
			"completed mobile was not registered with combat")
		_check(sim.state.movement.actors.has(expected_worker_id),
			"completed mobile was not registered with movement")
		_check(sim.state.abilities.actors.has(expected_worker_id),
			"completed ability-owning mobile was not registered with abilities")
		_check(not sim.state.heroes.heroes.has(expected_worker_id),
			"ordinary completed mobile was incorrectly registered as a Hero")
	else:
		_check(false, "ordinary mobile did not enter producer FIFO")
	_check(sim.validate().is_empty(), "Hero handoff fixture failed full state validation")


func _test_neutral_hire_handoff() -> void:
	var fixture := _attached_fixture(92_202)
	if fixture.is_empty():
		return
	var sim: Variant = fixture["simulation"]
	var registry: Dictionary = fixture["registry"]
	var buyer_id := int(registry["entity_id_by_map_id"].get("spawn_self_worker_01", 0))
	var buyer: EntityRecord = sim.state.entities.get(buyer_id)
	_check(buyer != null, "hire buyer fixture is missing")
	if buyer == null:
		return
	sim.state.tick = 600
	var advance_errors: PackedStringArray = sim.neutrals.advance_phase2(600)
	_check(advance_errors.is_empty(), "neutral market did not advance to hire availability")
	var claim := {
		"building_id": "neutral_west_laboratory",
		"buyer_alive": true,
		"buyer_internal_id": buyer_id,
		"buyer_owned": true,
		"buyer_position_mt": [buyer.position_x_mt, buyer.position_y_mt],
		"buyer_tags": buyer.tags.duplicate(),
		"canonical_command_digest": Codec.sha256_text("hire-scout-balloon"),
		"claim_id": "hire.scout_balloon",
		"command_index": 0,
		"interaction_legal": true,
		"offer_id": "scout_balloon",
		"owner_seat": 0,
		"shop_visible": true,
	}
	var market_result: Dictionary = sim.neutrals.market.resolve_shop_claims(
		600, [claim], {0: {"gold": 1_000, "lumber": 1_000}, 1: {"gold": 1_000, "lumber": 1_000}}
	)
	var accepted: Array = market_result.get("accepted", [])
	_check(accepted.size() == 1, "Laboratory hire offer was not accepted")
	if accepted.is_empty():
		return
	var market_accept: Dictionary = accepted[0]
	var handoff: Dictionary = market_accept.get("handoff", {})
	_check(str(handoff.get("kind", "")) == "spawn_hired_unit",
		"Laboratory purchase did not emit a spawn_hired_unit handoff")
	for delta_variant: Variant in market_result.get("resource_deltas", []):
		var delta: Dictionary = delta_variant
		var resource_receipt: Dictionary = sim.economy.apply_external_resource_delta(
			sim.state, int(delta["seat"]), int(delta["gold"]), int(delta["lumber"]),
			"neutral_purchase", "scout_balloon"
		)
		_check(bool(resource_receipt["accepted"]), "hire resource delta was rejected")
	var expected_hire_id: int = sim.state.next_entity_id
	var spawned: Dictionary = sim.spawn_hired_unit(handoff)
	_check(bool(spawned.get("accepted", false)), "accepted hire handoff failed to spawn")
	_check(int(spawned.get("entity_id", 0)) == expected_hire_id,
		"hire handoff spawned an unexpected internal entity")
	if not sim.state.entities.has(expected_hire_id):
		return
	var hired: EntityRecord = sim.state.entities[expected_hire_id]
	_check(hired.catalog_id == "scout_balloon" and hired.owner_seat == 0 \
		and "air" in hired.tags and "hired" in hired.tags,
		"spawned hire identity/ownership is incorrect")
	_check(sim.state.economy.entity_records.has(expected_hire_id),
		"spawned hire was not registered with economy")
	_check(sim.state.combat.actors.has(expected_hire_id),
		"spawned hire was not registered with combat")
	_check(sim.state.movement.actors.has(expected_hire_id),
		"spawned hire was not registered with movement")
	_check(str(sim.state.movement.actors[expected_hire_id]["layer"]) == "air",
		"Scout Balloon was not assigned an air movement lane")
	_check(int(sim.state.economy.players[0]["food_used"]) == 7,
		"hire food was not committed")
	_check(int(hired.integer_attributes.get("hired_expiry_tick", 0)) == 1_200,
		"temporary hire expiry tick is incorrect")
	_check(sim.validate().is_empty(), "live hire fixture failed full state validation")
	hired.integer_attributes["hired_expiry_tick"] = sim.state.tick
	sim.step_tick(false)
	_check(not hired.alive and int(hired.integer_attributes.get("despawned", 0)) == 1,
		"temporary hire did not expire through lifecycle authority")
	_check(not sim.state.economy.entity_records.has(expected_hire_id) \
		and int(sim.state.economy.players[0]["food_used"]) == 5,
		"expired hire did not release economy food/accounting")
	_check(_event_count(sim, "hired_unit_expired") == 1,
		"temporary hire expiry event was not emitted exactly once")


func _test_ground_attack_bridge_and_area_impact() -> void:
	var boot: Dictionary = Bootstrap.create_official({
		"faction_id": "vanguard-v1", "match_seed": 93_303,
	})
	_check(bool(boot.get("ok", false)), "ground attack bootstrap failed")
	if not bool(boot.get("ok", false)):
		return
	var sim: Variant = boot["simulation"]
	var faction: Dictionary = _loaded["catalogs"]["faction:vanguard-v1"]
	var bombard_id := _add_combat_unit(sim, faction, "bombard", 0, [84_250, 68_250])
	var enemy_id := _add_combat_unit(sim, faction, "footguard", 1, [96_250, 68_250])
	var ally_id := _add_combat_unit(sim, faction, "footguard", 0, [97_750, 68_250])
	var air_id := _add_combat_unit(sim, faction, "rotor_scout", 1, [96_250, 67_250])
	if mini(mini(bombard_id, enemy_id), mini(ally_id, air_id)) <= 0:
		return
	var point := [96_250, 68_250]
	_check(sim.combat.ground_attack_request_code(sim.state, bombard_id, point).is_empty(),
		"Bombard catalog-backed ground attack was rejected")
	var worker_id := int(boot["registry"]["entity_id_by_map_id"].get("spawn_self_worker_01", 0))
	_check(sim.combat.ground_attack_request_code(sim.state, worker_id, point) == "ground_attack_unsupported",
		"non-Bombard actor did not fail closed for attack_ground")
	var context := ResolutionContext.new()
	var context_errors := context.configure({
		"entities": {"e_bombard": {"internal_id": bombard_id, "owner_seat": 0}},
		"world_max_inclusive_mt": [191_999, 127_999],
	}, TIE_KEY.to_utf8_buffer())
	_check(context_errors.is_empty(), "ground attack resolution context failed")
	if not context_errors.is_empty():
		return
	var intent := _intent(
		"attack_ground", "order", 0, "e_bombard", bombard_id,
		{"kind": "point", "xy_mt": point}, {}, "replace", sim.state.tick,
		"batch.ground.bombard", 0
	)
	var bridge := IntentBridge.new()
	var execution: Dictionary = bridge.execute(sim, [intent], context)
	var receipts: Array = execution.get("receipts", [])
	_check(bool(execution.get("ok", false)) and receipts.size() == 1 \
		and str((receipts[0] as Dictionary).get("status", "")) == "applied",
		"Bombard attack_ground intent was not applied")
	var public_receipt_text := Codec.canonical_bytes(receipts).get_string_from_utf8()
	_check(not public_receipt_text.contains("internal_id") \
		and not public_receipt_text.contains("sequence_id"),
		"ground attack public receipt leaked an internal identifier")
	var enemy_hp_before: int = sim.state.entities[enemy_id].hp
	var ally_hp_before: int = sim.state.entities[ally_id].hp
	var air_hp_before: int = sim.state.entities[air_id].hp
	for _tick: int in range(23):
		sim.step_tick(false)
	var enemy_damage := enemy_hp_before - int(sim.state.entities[enemy_id].hp)
	var ally_damage := ally_hp_before - int(sim.state.entities[ally_id].hp)
	_check(enemy_damage == 34, "Bombard ground impact enemy damage drifted: %d" % enemy_damage)
	_check(ally_damage == 8, "Bombard 25%% friendly-fire damage drifted: %d" % ally_damage)
	_check(int(sim.state.entities[air_id].hp) == air_hp_before,
		"ground-area attack damaged an air target")
	_check(_event_count(sim, "ground_attack_landed") == 1,
		"ground-area projectile did not land exactly once")
	_check(int(sim.state.combat.actors[bombard_id]["cooldown_until_tick"]) > 22,
		"ground-area attack did not enter ordinary attack cooldown")
	_check(sim.validate().is_empty(), "ground attack fixture failed full state validation")


func _attached_fixture(seed: int) -> Dictionary:
	var boot: Dictionary = Bootstrap.create_official({
		"faction_id": "vanguard-v1", "match_seed": seed,
	})
	_check(bool(boot.get("ok", false)), "official handoff bootstrap failed")
	if not bool(boot.get("ok", false)):
		return {}
	var attached: Dictionary = MatchRuntime.attach_protected_authority(
		boot, TIE_KEY.to_utf8_buffer()
	)
	_check(bool(attached.get("ok", false)), "protected handoff runtime failed: %s" % "; ".join(attached.get("errors", [])))
	if not bool(attached.get("ok", false)):
		return {}
	return {
		"map_manifest": boot["map_manifest"],
		"registry": boot["registry"],
		"runtime": boot["runtime"],
		"simulation": attached["simulation"],
	}


func _add_completed_altar(sim: Variant, runtime: Dictionary, manifest: Dictionary) -> int:
	return _add_completed_structure(
		sim, runtime, manifest, "hero_altar", "bs_self_home_inner_03_altar",
		"e_test_altar"
	)


func _add_completed_structure(
	sim: Variant,
	runtime: Dictionary,
	manifest: Dictionary,
	role: String,
	site_id: String,
	public_id: String
) -> int:
	var site := _record_by_id(manifest["build_sites"], site_id)
	var type_id := str(runtime["structure_type_by_role"][role])
	var definition: Dictionary = runtime["economy"]["structures"][type_id]
	var entity_id: int = sim.state.next_entity_id
	var structure := EntityRecord.new(entity_id, 0, "structure")
	structure.public_id = public_id
	structure.catalog_id = type_id
	structure.max_hp = int(definition["max_hp"])
	structure.hp = structure.max_hp
	structure.radius_mt = int(definition["radius_mt"])
	structure.tags.assign(definition["tags"])
	var position := _build_site_center(site, sim.grid.cell_size_mt)
	structure.set_position_mt(int(position[0]), int(position[1]))
	_check(sim.grid.reserve_ground_actor_cells(entity_id, site["footprint_cells"]),
		"%s exact footprint reservation failed" % role)
	_check(sim.add_entity(structure, false) == entity_id,
		"completed %s entity failed to add" % role)
	_check(sim.economy.register_completed_entity(sim.state, entity_id).is_empty(),
		"completed %s economy registration failed" % role)
	_check(sim.register_combat_entity(entity_id, "structure", role).is_empty(),
		"completed %s combat registration failed" % role)
	return entity_id if sim.state.economy.entity_records.has(entity_id) else 0


func _add_combat_unit(
	sim: Variant,
	faction: Dictionary,
	type_id: String,
	seat: int,
	position_mt: Array
) -> int:
	var definition: Dictionary = faction["units"][type_id]
	var entity_id: int = sim.state.next_entity_id
	var entity := EntityRecord.new(entity_id, seat, "unit")
	entity.public_id = "e_test_%s_%d" % [type_id, entity_id]
	entity.catalog_id = type_id
	entity.max_hp = int(definition["hp"])
	entity.hp = entity.max_hp
	entity.max_mana = int(definition["mana"])
	entity.mana = entity.max_mana
	entity.radius_mt = int(definition["radius_mt"])
	entity.tags.assign(definition["tags"])
	entity.set_position_mt(int(position_mt[0]), int(position_mt[1]))
	var reserve_ground := "air" not in entity.tags
	_check(sim.add_entity(entity, reserve_ground) == entity_id,
		"combat fixture %s seat=%d at=%s failed to add" % [type_id, seat, str(position_mt)])
	_check(sim.register_combat_entity(entity_id, "unit", type_id).is_empty(),
		"combat fixture %s seat=%d failed to register" % [type_id, seat])
	return entity_id if sim.state.combat.actors.has(entity_id) else 0


func _intent(
	operation: String,
	intent_type: String,
	seat: int,
	public_actor: String,
	internal_actor: int,
	target: Dictionary,
	parameters: Dictionary,
	queue_policy: String,
	apply_tick: int,
	batch_id: String,
	command_index: int
) -> Dictionary:
	var command_digest := Codec.sha256_text("%s|%s|%d" % [batch_id, operation, command_index])
	var body := {
		"apply_tick": apply_tick,
		"intent_type": intent_type,
		"operation": operation,
		"owner_seat": seat,
		"parameters": parameters.duplicate(true),
		"queue_policy": queue_policy,
		"source": {
			"batch_id": batch_id,
			"command_digest": command_digest,
			"command_id": "%s_%d" % [operation, command_index],
			"command_index": command_index,
			"expansion_index": 0,
			"match_id": "m_authoritative_handoffs",
			"observation_seq": 1,
		},
		"subject": {
			"internal_id": internal_actor,
			"kind": "entity",
			"public_id": public_actor,
		},
		"target": target.duplicate(true),
	}
	var digest := Codec.sha256_canonical(body)
	var result := body.duplicate(true)
	result["intent_digest"] = digest
	result["intent_id"] = "ci_" + digest
	return result


static func _record_by_id(records: Array, record_id: String) -> Dictionary:
	for record_variant: Variant in records:
		var record: Dictionary = record_variant
		if str(record.get("id", "")) == record_id:
			return record
	return {}


static func _build_site_center(site: Dictionary, cell_size_mt: int) -> Array:
	var min_x := 2_147_483_647
	var min_y := 2_147_483_647
	var max_x := -1
	var max_y := -1
	for cell_variant: Variant in site["footprint_cells"]:
		var cell: Array = cell_variant
		min_x = mini(min_x, int(cell[0]))
		min_y = mini(min_y, int(cell[1]))
		max_x = maxi(max_x, int(cell[0]))
		max_y = maxi(max_y, int(cell[1]))
	@warning_ignore("integer_division")
	var x_mt := ((min_x + max_x + 1) * cell_size_mt) / 2
	@warning_ignore("integer_division")
	var y_mt := ((min_y + max_y + 1) * cell_size_mt) / 2
	return [x_mt, y_mt]


static func _event_count(sim: Variant, event_kind: String) -> int:
	var result := 0
	for event_variant: Variant in sim.state.events:
		var event: Variant = event_variant
		if str(event.event_kind) == event_kind:
			result += 1
	return result


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
