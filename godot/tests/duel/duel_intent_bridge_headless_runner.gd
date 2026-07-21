extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const Contract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const Compiler := preload("res://scripts/duel/actions/duel_order_compiler.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const ResolutionContext := preload("res://scripts/duel/controller/duel_intent_resolution_context.gd")
const ContestResolver := preload("res://scripts/duel/controller/duel_contest_resolver.gd")
const IntentBridge := preload("res://scripts/duel/controller/duel_intent_execution_bridge.gd")
const AbilityRuntime := preload("res://scripts/duel/abilities/duel_ability_runtime.gd")

const EXPECTED_GOLDEN := "557f5f15fe024ad3760d30738e82caead2e007e3ba77f1731e7147b971d84a9b"
const TIE_KEY_TEXT := "worldarena-intent-bridge-test-key-v1"

var _failures := PackedStringArray()
var _loaded: Dictionary = {}


func _init() -> void:
	_loaded = CatalogLoader.load_official_catalogs()
	_check(bool(_loaded.get("ok", false)), "official catalogs failed to load")
	_test_dispatch_coverage()
	_test_resolution_context_boundary()
	_test_contest_resolver()
	var first := _run_scenario(false)
	var second := _run_scenario(true)
	_check(first.get("hash", "") == second.get("hash", ""),
		"shuffled compiled-intent input changed authoritative bridge output")
	_check(first.get("summary", {}) == second.get("summary", {}),
		"shuffled compiled-intent input changed bridge scenario summary")
	if not EXPECTED_GOLDEN.is_empty():
		_check(first.get("hash", "") == EXPECTED_GOLDEN,
			"intent bridge golden changed: %s" % first.get("hash", ""))
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_INTENT_BRIDGE_FAILURE: %s" % failure)
		print("DUEL_INTENT_BRIDGE_FAILED count=%d hash=%s" % [
			_failures.size(), first.get("hash", ""),
		])
		quit(1)
		return
	print("DUEL_INTENT_BRIDGE_OK hash=%s summary=%s" % [
		first["hash"], JSON.stringify(first["summary"]),
	])
	quit(0)


func _test_dispatch_coverage() -> void:
	var coverage := IntentBridge.dispatch_coverage()
	var keys: Array = coverage.keys()
	keys.sort()
	_check(keys == Contract.OPERATIONS, "intent bridge dispatch table drifted from all 37 locked operations")
	_check(keys.size() == 37, "intent bridge must cover exactly 37 public operations")
	_check(str(coverage["order_squad"]) == "compiler_expands_to_core_orders",
		"order_squad compiler-expansion coverage is not explicit")
	_check(str(coverage["attack_ground"]) == "core_order_ground_projectile_area",
		"attack_ground projectile-area dispatch classification drifted")
	_check(str(coverage["cast"]) == "ability_service",
		"cast ability-service dispatch classification drifted")


func _test_resolution_context_boundary() -> void:
	var tie_key := TIE_KEY_TEXT.to_utf8_buffer()
	var context := ResolutionContext.new()
	var errors := context.configure({
		"entities": {
			"e_actor": {"internal_id": 41, "owner_seat": 0},
			"e_enemy": {"internal_id": 72, "owner_seat": 1},
		},
		"world_max_inclusive_mt": [191999, 127999],
	}, tie_key)
	_check(errors.is_empty(), "minimal closed resolution context failed: %s" % "; ".join(errors))
	var correct := context.resolve_entity({
		"internal_id": 41, "kind": "entity", "public_id": "e_actor",
	}, 0)
	_check(bool(correct.get("ok", false)), "correct public alias did not resolve")
	var tampered := context.resolve_entity({
		"internal_id": 72, "kind": "entity", "public_id": "e_actor",
	}, 0)
	_check(not bool(tampered.get("ok", false)) and tampered.get("code") == "reference_mismatch",
		"claimed internal-ID substitution was not rejected")
	_check(not context.public_snapshot().has("protected_tie_key"),
		"protected tie key leaked into public context snapshot")
	_check(not Codec.canonical_bytes(context.public_snapshot()).get_string_from_utf8().contains(
		"internal_"
	), "internal resolver IDs leaked into public context snapshot")
	var invalid := ResolutionContext.new()
	_check(not invalid.configure({
		"entities": {}, "unknown": true,
		"world_max_inclusive_mt": [191999, 127999],
	}, tie_key).is_empty(), "unknown resolution-context field was accepted")


func _test_contest_resolver() -> void:
	var key := TIE_KEY_TEXT.to_utf8_buffer()
	var digest_a := Codec.sha256_text("claim-a")
	var digest_b := Codec.sha256_text("claim-b")
	var claims: Array[Dictionary] = [
		{
			"canonical_command_digest": digest_a,
			"claim_id": "claim.a", "claim_kind": "ground_item",
			"internal_actor_id": 10, "object_id": "item-secret-9",
		},
		{
			"canonical_command_digest": digest_b,
			"claim_id": "claim.b", "claim_kind": "ground_item",
			"internal_actor_id": 20, "object_id": "item-secret-9",
		},
	]
	var capacities := {ContestResolver.group_id("ground_item", "item-secret-9"): 1}
	var first := ContestResolver.new().resolve(80, claims, capacities, key)
	claims.reverse()
	var second := ContestResolver.new().resolve(80, claims, capacities, key)
	_check(first == second, "exclusive-claim ranking depends on input order")
	_check(first["accepted_claim_ids"].size() == 1 and first["rejected_claim_ids"].size() == 1,
		"one-charge contest did not accept exactly one claimant")
	_check(first["audit"].size() == 1,
		"exclusive claim did not emit one protected HMAC audit record")


func _run_scenario(reverse_input: bool) -> Dictionary:
	var boot := Bootstrap.create_official({"faction_id": "vanguard-v1", "match_seed": 44017})
	_check(bool(boot.get("ok", false)), "official bridge fixture bootstrap failed")
	if not bool(boot.get("ok", false)):
		return {"hash": "", "summary": {}}
	var sim: Variant = boot["simulation"]
	var runtime: Dictionary = boot["runtime"]
	var registry: Dictionary = boot["registry"]
	var manifest: Dictionary = boot["map_manifest"]
	var faction: Dictionary = _loaded["catalogs"]["faction:vanguard-v1"]
	var tie_key := TIE_KEY_TEXT.to_utf8_buffer()
	_check(sim.configure_movement(faction, tie_key).is_empty(),
		"bridge fixture movement failed to configure")

	var self_worker := _map_entity_id(registry, "spawn_self_worker_01")
	var enemy_worker := _map_entity_id(registry, "spawn_opponent_worker_01")
	var self_hall := _map_entity_id(registry, "spawn_self_stronghold")
	var enemy_hall := _map_entity_id(registry, "spawn_opponent_stronghold")
	var resource := _map_entity_id(registry, "res_self_home_gold")
	for entity_id: int in [self_worker, enemy_worker]:
		var entity: Variant = sim.state.entities[entity_id]
		_check(sim.register_movement_entity(entity_id, "unit", str(entity.catalog_id)).is_empty(),
			"bridge fixture worker movement registration failed")

	var hero0_id: int = sim.state.next_entity_id
	var hero0 := _entity(hero0_id, 0, "marshal", 96250, 104250, ["biological", "ground", "hero"])
	_check(sim.add_entity(hero0, false) == hero0_id, "seat-zero bridge Hero failed to add")
	_check(sim.register_hero(hero0_id, "marshal", "opaque-hero-a").is_empty(),
		"seat-zero bridge Hero failed to register")
	var hero1_id: int = sim.state.next_entity_id
	var hero1 := _entity(hero1_id, 1, "marshal", 96250, 104250, ["biological", "ground", "hero"])
	_check(sim.add_entity(hero1, false) == hero1_id, "seat-one bridge Hero failed to add")
	_check(sim.register_hero(hero1_id, "marshal", "opaque-hero-b").is_empty(),
		"seat-one bridge Hero failed to register")
	var priest_id: int = sim.state.next_entity_id
	var priest := _entity(
		priest_id, 0, "priest", 96000, 104250,
		["biological", "caster", "ground", "healer", "ranged"]
	)
	priest.max_hp = 360
	priest.hp = 360
	priest.max_mana = 260
	priest.mana = 260
	_check(sim.add_entity(priest, false) == priest_id, "bridge Priest failed to add")
	var transport_id: int = sim.state.next_entity_id
	var transport := _entity(
		transport_id, 0, "fixture_transport", 95500, 104250,
		["air", "mechanical", "transport"]
	)
	_check(sim.add_entity(transport, false) == transport_id, "bridge transport failed to add")
	var passenger_a_id: int = sim.state.next_entity_id
	var passenger_a := _entity(
		passenger_a_id, 0, "footguard", 95400, 104250,
		["biological", "ground", "melee"]
	)
	_check(sim.add_entity(passenger_a, false) == passenger_a_id,
		"first bridge transport passenger failed to add")
	var passenger_b_id: int = sim.state.next_entity_id
	var passenger_b := _entity(
		passenger_b_id, 0, "footguard", 95600, 104250,
		["biological", "ground", "melee"]
	)
	_check(sim.add_entity(passenger_b, false) == passenger_b_id,
		"second bridge transport passenger failed to add")

	var potion: Dictionary = sim.heroes.grant_item(sim.state, hero0_id, "lesser_vitality_draught")
	_check(bool(potion.get("accepted", false)), "bridge fixture potion grant failed")
	var potion_id := str(potion.get("details", {}).get("item", {}).get("item_instance_id", ""))
	hero0.hp = 100
	var ground_source: Dictionary = sim.heroes.grant_item(sim.state, hero0_id, "edge_stone")
	var ground_source_id := str(ground_source.get("details", {}).get("item", {}).get("item_instance_id", ""))
	var dropped: Dictionary = sim.heroes.drop_item(
		sim.state, hero0_id, ground_source_id, [96250, 104250], sim.state.tick
	)
	_check(bool(dropped.get("accepted", false)), "bridge fixture ground item creation failed")
	var ground_item_id := int(dropped.get("details", {}).get("item_entity_id", 0))

	var build_site: Dictionary = _record_by_id(manifest["build_sites"], "bs_east_contested_economy_01")
	var site_position := _build_site_center(
		build_site, int(manifest["coordinate_system"]["cell_size_mt"])
	)
	var context := ResolutionContext.new()
	var context_errors := context.configure({
		"default_deposit_by_seat": {"0": "e_self_hall", "1": "e_enemy_hall"},
		"entities": {
			"e_enemy_hall": {"internal_id": enemy_hall, "owner_seat": 1},
			"e_enemy_worker": {"internal_id": enemy_worker, "owner_seat": 1},
			"e_ground_item": {"internal_id": ground_item_id, "owner_seat": -1},
			"e_hero_a": {"internal_id": hero0_id, "owner_seat": 0},
			"e_hero_b": {"internal_id": hero1_id, "owner_seat": 1},
			"e_passenger_a": {"internal_id": passenger_a_id, "owner_seat": 0},
			"e_passenger_b": {"internal_id": passenger_b_id, "owner_seat": 0},
			"e_priest": {"internal_id": priest_id, "owner_seat": 0},
			"e_resource": {"internal_id": resource, "owner_seat": -1},
			"e_self_hall": {"internal_id": self_hall, "owner_seat": 0},
			"e_self_worker": {"internal_id": self_worker, "owner_seat": 0},
			"e_transport": {"internal_id": transport_id, "owner_seat": 0},
		},
		"gather_travel_ticks": {"return": 2, "to_resource": 3},
		"queue_entries": {},
		"region_slots": {
			"r_center|center": {"xy_mt": [96250, 64250]},
		},
		"sites": {
			str(build_site["id"]): {
				"internal_object_id": "protected-build-site-17",
				"xy_mt": site_position,
			},
		},
		"transport_capacities": {"e_transport": 1},
		"transport_range_mt": 1000,
		"world_max_inclusive_mt": [191999, 127999],
	}, tie_key)
	_check(context_errors.is_empty(), "bridge fixture context failed: %s" % "; ".join(context_errors))
	if not context_errors.is_empty():
		return {"hash": "", "summary": {}}

	var intents := _scenario_intents(
		sim, runtime, context, self_worker, enemy_worker, self_hall, enemy_hall, resource,
		hero0_id, hero1_id, priest_id, transport_id, passenger_a_id, passenger_b_id,
		ground_item_id, potion_id,
		str(build_site["id"]), site_position
	)
	if reverse_input:
		intents.reverse()
	var bridge := IntentBridge.new()
	var ability_service := AbilityRuntime.new()
	_check(ability_service.configure("vanguard-v1", _loaded).is_empty(),
		"real ability service failed to configure for the bridge fixture")
	var execution := bridge.execute(sim, intents, context, {"abilities": ability_service})
	_check(bool(execution.get("ok", false)), "bridge execution failed")
	var receipts: Array = execution.get("receipts", [])
	_check(receipts.size() == intents.size(), "bridge did not emit one receipt per atomic intent")
	_check(not _contains_hidden_integer_id(receipts), "public intent receipt leaked an internal numeric ID")
	_check(_count_receipts(receipts, "build", "applied") == 1,
		"same-tick build-site contest did not accept exactly one command")
	_check(_count_receipts(receipts, "build", "rejected") == 1,
		"same-tick build-site contest did not reject exactly one command")
	_check(_count_receipts(receipts, "pick_up_item", "applied") == 1,
		"same-tick ground-item contest did not accept exactly one Hero")
	_check(_count_receipts(receipts, "pick_up_item", "rejected") == 1,
		"same-tick ground-item contest did not reject exactly one Hero")
	_check(_count_receipts(receipts, "load_transport", "applied") == 1 \
		and _count_receipts(receipts, "load_transport", "rejected") == 1,
		"same-tick transport-seat contest did not accept exactly one passenger")
	_check((bridge.transport_manifests.get("e_transport", []) as Array).size() == 1,
		"transport-seat winner was not committed exactly once")
	_check(_count_receipt_code(receipts, "attack_ground", "requirement_not_met") == 1,
		"unsupported actor did not fail closed through the ground-attack runtime")
	_check(_count_receipts(receipts, "cast", "applied") == 1 \
		and ability_service.state.casts.size() == 1,
		"cast intent did not route exactly once through the ability service")
	_check(ability_service.state.actors.has(priest_id) \
		and bool((ability_service.state.actors[priest_id] as Dictionary)["autocast"].get(
			"priest_mend", false
		)), "set_autocast did not update the real ability authority")
	_check(ability_service.validate().is_empty(), "real ability service state failed validation")
	_check(_count_receipt_code(receipts, "stop", "not_owner") == 1,
		"execution-time seat ownership check did not reject an opponent actor")
	_check(hero0.hp == 300, "bridge Hero item dispatch did not apply vitality restoration")
	_check((execution["protected_contest_audit"] as Array).size() >= 3,
		"bridge did not retain protected build/item/transport contest audits")
	_check(not Codec.canonical_bytes(receipts).get_string_from_utf8().contains("protected-build-site"),
		"protected build-site object ID leaked into player receipts")

	## Replace orders activate on the declared application tick; the append hook
	## is separate and intentionally called before the ledger phase-1 boundary.
	bridge.activate_pending_appends(sim)
	sim.step_tick()
	sim.step_tick()
	var validation: PackedStringArray = sim.validate()
	_check(validation.is_empty(), "bridge scenario state validation failed: %s" % "; ".join(validation))

	var summary := {
		"ability_casts": ability_service.state.casts.size(),
		"applied": _status_count(receipts, "applied"),
		"audit_records": (execution["protected_contest_audit"] as Array).size(),
		"buildings_under_construction": sim.state.economy.construction_sites.size(),
		"ground_items": sim.state.heroes.ground_items.size(),
		"hero0_hp": hero0.hp,
		"orders": sim.state.orders.size(),
		"rejected": _status_count(receipts, "rejected"),
		"transported": (bridge.transport_manifests.get("e_transport", []) as Array).size(),
		"unsupported": _code_count(receipts, "unsupported_operation"),
	}
	var golden_document := {
		"ability_checkpoint_hash": ability_service.checkpoint_hash(),
		"bridge": bridge.to_canonical_dict(),
		"checkpoint_hash": sim.checkpoint_hash(),
		"protected_audit": execution["protected_contest_audit"],
		"receipts": receipts,
		"summary": summary,
	}
	return {"hash": Codec.sha256_canonical(golden_document), "summary": summary}


func _scenario_intents(
	sim: Variant,
	runtime: Dictionary,
	_context: ResolutionContext,
	self_worker: int,
	enemy_worker: int,
	self_hall: int,
	enemy_hall: int,
	resource: int,
	hero0_id: int,
	hero1_id: int,
	priest_id: int,
	transport_id: int,
	passenger_a_id: int,
	passenger_b_id: int,
	ground_item_id: int,
	potion_id: String,
	build_site_id: String,
	site_position: Array
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var application_tick: int = sim.state.tick + 1
	var compiler := Compiler.new()
	var batch := _compiler_batch("batch.move")
	var move_command := {
		"actor_ids": ["e_self_worker"], "command_id": "move", "op": "move",
		"queue": "replace", "target": {"kind": "point", "xy_mt": [95500, 107500]},
	}
	result.append_array(compiler.compile_command(
		move_command, 0, batch,
		{"application_tick": application_tick, "player_seat": 0,
			"entities": {"e_self_worker": {"internal_id": self_worker}}},
		{"actor_ids": ["e_self_worker"], "parameters": {}, "queue_policy": "replace",
			"target": move_command["target"]}
	))
	result.append(_intent("attack_entity", "order", 0, "e_self_worker", self_worker,
		{"internal_id": enemy_worker, "kind": "entity", "public_id": "e_enemy_worker"},
		{}, "replace", application_tick, "batch.orders", 0))
	result.append(_intent("gather", "economy", 0, "e_self_worker", self_worker,
		{"internal_id": resource, "kind": "entity", "public_id": "e_resource"},
		{}, "replace", application_tick, "batch.economy", 0))
	result.append(_intent("produce", "economy", 0, "e_self_hall", self_hall, {}, {
		"quantity_index": 0, "requested_quantity": 1,
		"unit_type_id": str(runtime["starting_state"]["worker_type_id"]),
	}, "none", application_tick, "batch.economy", 1))
	result.append(_controller_intent("define_squad", 0, {
		"member_ids": ["e_self_worker"], "squad_id": "squad.alpha",
	}, application_tick, "batch.controller", 0))
	result.append(_intent("set_stance", "tactics", 0, "e_self_worker", self_worker, {}, {
		"stance": "defensive",
	}, "none", application_tick, "batch.controller", 1))
	result.append(_intent("set_autocast", "ability", 0, "e_priest", priest_id, {}, {
		"ability_id": "priest_mend", "enabled": true,
	}, "none", application_tick, "batch.hero", 0))
	result.append(_intent("learn_ability", "ability", 0, "e_hero_a", hero0_id, {}, {
		"ability_id": "marshal_shield_strike",
	}, "none", application_tick, "batch.hero", 1))
	result.append(_intent("use_item", "item", 0, "e_hero_a", hero0_id, {}, {
		"item_instance_id": potion_id,
	}, "replace", application_tick, "batch.hero", 2))

	var food_type := str(runtime["structure_type_by_role"]["food"])
	result.append(_build_intent(
		0, "e_self_worker", self_worker, food_type, build_site_id, site_position,
		application_tick, "batch.build.self", "build_self"
	))
	result.append(_build_intent(
		1, "e_enemy_worker", enemy_worker, food_type, build_site_id, site_position,
		application_tick, "batch.build.enemy", "build_enemy"
	))
	var ground_target := {
		"internal_id": ground_item_id, "kind": "entity", "public_id": "e_ground_item",
	}
	result.append(_intent("pick_up_item", "item", 0, "e_hero_a", hero0_id,
		ground_target, {}, "replace", application_tick, "batch.pickup.self", 0))
	result.append(_intent("pick_up_item", "item", 1, "e_hero_b", hero1_id,
		ground_target, {}, "replace", application_tick, "batch.pickup.enemy", 0))
	result.append(_intent("load_transport", "transport", 0, "e_transport", transport_id,
		{}, {"passenger": {
			"internal_id": passenger_a_id, "kind": "entity", "public_id": "e_passenger_a",
		}}, "replace", application_tick, "batch.transport.a", 0))
	result.append(_intent("load_transport", "transport", 0, "e_transport", transport_id,
		{}, {"passenger": {
			"internal_id": passenger_b_id, "kind": "entity", "public_id": "e_passenger_b",
		}}, "replace", application_tick, "batch.transport.b", 0))
	result.append(_intent("attack_ground", "order", 0, "e_self_worker", self_worker,
		{"kind": "point", "xy_mt": [96250, 64250]}, {}, "replace",
		application_tick, "batch.unsupported", 0))
	result.append(_intent("cast", "ability", 0, "e_hero_a", hero0_id, {
		"internal_id": hero1_id, "kind": "entity", "public_id": "e_hero_b",
	}, {
		"ability_id": "marshal_shield_strike",
	}, "replace", application_tick, "batch.unsupported", 1))
	result.append(_intent("stop", "order", 0, "e_enemy_worker", enemy_worker, {}, {},
		"replace", application_tick, "batch.ownership", 0))
	return result


func _build_intent(
	seat: int,
	public_worker: String,
	worker_id: int,
	building_type_id: String,
	site_id: String,
	site_position: Array,
	application_tick: int,
	batch_id: String,
	command_id: String
) -> Dictionary:
	var command := {
		"builder_ids": [public_worker], "building_type_id": building_type_id,
		"build_site_id": site_id, "command_id": command_id, "op": "build",
	}
	var compiled := Compiler.new().compile_command(
		command, 0, _compiler_batch(batch_id),
		{"application_tick": application_tick, "player_seat": seat,
			"entities": {public_worker: {"internal_id": worker_id}}},
		{
			"actor_ids": [public_worker],
			"parameters": {"building_type_id": building_type_id},
			"queue_policy": "replace",
			"target": {"kind": "site", "site_id": site_id, "xy_mt": site_position},
		}
	)
	return compiled[0]


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
			"match_id": "m_intent_bridge",
			"observation_seq": 1,
		},
		"subject": {
			"internal_id": internal_actor, "kind": "entity", "public_id": public_actor,
		},
		"target": target.duplicate(true),
	}
	var digest := Codec.sha256_canonical(body)
	var result := body.duplicate(true)
	result["intent_digest"] = digest
	result["intent_id"] = "ci_" + digest
	return result


func _controller_intent(
	operation: String,
	seat: int,
	parameters: Dictionary,
	apply_tick: int,
	batch_id: String,
	command_index: int
) -> Dictionary:
	var command_digest := Codec.sha256_text("%s|%s|%d" % [batch_id, operation, command_index])
	var body := {
		"apply_tick": apply_tick,
		"intent_type": "squad_state",
		"operation": operation,
		"owner_seat": seat,
		"parameters": parameters.duplicate(true),
		"queue_policy": "none",
		"source": {
			"batch_id": batch_id,
			"command_digest": command_digest,
			"command_id": "%s_%d" % [operation, command_index],
			"command_index": command_index,
			"expansion_index": 0,
			"match_id": "m_intent_bridge",
			"observation_seq": 1,
		},
		"subject": {"kind": "controller", "seat": seat},
		"target": {},
	}
	var digest := Codec.sha256_canonical(body)
	var result := body.duplicate(true)
	result["intent_digest"] = digest
	result["intent_id"] = "ci_" + digest
	return result


static func _compiler_batch(batch_id: String) -> Dictionary:
	return {
		"client_batch_id": batch_id,
		"match_id": "m_intent_bridge",
		"observation_seq": 1,
	}


static func _entity(
	entity_id: int,
	seat: int,
	catalog_id: String,
	x_mt: int,
	y_mt: int,
	tags: Array[String]
) -> EntityRecord:
	var entity := EntityRecord.new(entity_id, seat, "unit")
	entity.catalog_id = catalog_id
	entity.max_hp = 1
	entity.hp = 1
	entity.radius_mt = 450
	entity.set_position_mt(x_mt, y_mt)
	entity.tags.assign(tags)
	return entity


static func _map_entity_id(registry: Dictionary, map_id: String) -> int:
	return int(registry["entity_id_by_map_id"].get(map_id, 0))


static func _map_entity_id_from_state(sim: Variant, catalog_id: String) -> int:
	for entity_id: int in sim.state.sorted_entity_ids():
		if str(sim.state.entities[entity_id].catalog_id) == catalog_id:
			return entity_id
	return 0


static func _record_by_id(records: Array, record_id: String) -> Dictionary:
	for record_variant: Variant in records:
		var record: Dictionary = record_variant
		if str(record.get("id", "")) == record_id:
			return record
	return {}


static func _build_site_center(site: Dictionary, cell_size_mt: int) -> Array:
	var cells: Array = site["footprint_cells"]
	var min_x := 1_000_000
	var min_y := 1_000_000
	var max_x := -1
	var max_y := -1
	for cell_variant: Variant in cells:
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


static func _count_receipts(receipts: Array, operation: String, status: String) -> int:
	var count := 0
	for receipt_variant: Variant in receipts:
		var receipt: Dictionary = receipt_variant
		if str(receipt["operation"]) == operation and str(receipt["status"]) == status:
			count += 1
	return count


static func _status_count(receipts: Array, status: String) -> int:
	var count := 0
	for receipt_variant: Variant in receipts:
		if str((receipt_variant as Dictionary)["status"]) == status:
			count += 1
	return count


static func _count_receipt_code(receipts: Array, operation: String, code: String) -> int:
	var count := 0
	for receipt_variant: Variant in receipts:
		var receipt: Dictionary = receipt_variant
		if str(receipt.get("operation", "")) == operation and str(receipt.get("code", "")) == code:
			count += 1
	return count


static func _code_count(receipts: Array, code: String) -> int:
	var count := 0
	for receipt_variant: Variant in receipts:
		if str((receipt_variant as Dictionary).get("code", "")) == code:
			count += 1
	return count


static func _contains_hidden_integer_id(value: Variant, key: String = "") -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		for child_key_variant: Variant in (value as Dictionary).keys():
			var child_key := str(child_key_variant)
			if _contains_hidden_integer_id((value as Dictionary)[child_key_variant], child_key):
				return true
		return false
	if typeof(value) == TYPE_ARRAY:
		for child: Variant in (value as Array):
			if _contains_hidden_integer_id(child, key):
				return true
		return false
	return typeof(value) == TYPE_INT and (key.ends_with("_id") or key.ends_with("_ids"))


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
