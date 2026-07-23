extends SceneTree

const Bootstrap := preload("res://scripts/duel/match/duel_match_bootstrap.gd")
const MatchRuntime := preload("res://scripts/duel/match/duel_match_runtime.gd")
const SnapshotBuilder := preload("res://scripts/duel/perception/duel_phase_snapshot_builder.gd")
const PerceptionRuntime := preload("res://scripts/duel/perception/duel_perception_runtime.gd")
const LegalContextBuilder := preload("res://scripts/duel/controller/duel_legal_context_builder.gd")
const ActionValidator := preload("res://scripts/duel/actions/duel_action_validator.gd")
const IntentBridge := preload("res://scripts/duel/controller/duel_intent_execution_bridge.gd")
const ActionContract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const MATCH_ID := "m_legal-context"
const TIE_KEY_TEXT := "legal-context-protected-tie-key-v1"
const EXPECTED_GOLDEN := "ad5bd7d68bfe3d73eb9abcd4c85ce1372c199890c4c56980f5040a9546a45db9"

var _failures := PackedStringArray()


func _init() -> void:
	if OS.get_environment("DUEL_SHOP_ALIAS_ONLY") == "1":
		_test_visible_shop_alias_join()
		_finish_shop_alias_only()
		return
	_test_operation_coverage()
	_test_visible_shop_alias_join()
	var first := _run_scenario(false)
	var reversed := _run_scenario(true)
	_check(bool(first.get("ok", false)), "primary legal-context scenario failed")
	_check(bool(reversed.get("ok", false)), "reversed-order legal-context scenario failed")
	_check(
		str(first.get("hash", "")) == str(reversed.get("hash", "")),
		"dictionary insertion order changed legal-context output"
	)
	var golden := str(first.get("hash", ""))
	if not EXPECTED_GOLDEN.is_empty():
		_check(golden == EXPECTED_GOLDEN, "legal-context golden changed: %s" % golden)
	else:
		print("DUEL_LEGAL_CONTEXT_CANDIDATE_GOLDEN=%s" % golden)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_LEGAL_CONTEXT_FAILURE: %s" % failure)
		print("DUEL_LEGAL_CONTEXT_FAILED count=%d hash=%s" % [_failures.size(), golden])
		quit(1)
		return
	print("DUEL_LEGAL_CONTEXT_OK hash=%s summary=%s" % [
		golden, JSON.stringify(first["summary"]),
	])
	quit(0)


func _finish_shop_alias_only() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_SHOP_ALIAS_FAILURE: %s" % failure)
		print("DUEL_SHOP_ALIAS_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_SHOP_ALIAS_OK")
	quit(0)


func _test_operation_coverage() -> void:
	var coverage := LegalContextBuilder.operation_coverage()
	var keys: Array = coverage.keys()
	keys.sort()
	_check(keys == ActionContract.OPERATIONS, "legal-context operation coverage drifted")
	_check(keys.size() == 37, "legal-context adapter must name all 37 operations")
	for operation: String in keys:
		_check(
			str(coverage[operation]) == "context_supported",
			"legal-context adapter does not support operation %s" % operation
		)


func _test_visible_shop_alias_join() -> void:
	var bootstrap := Bootstrap.create_official({
		"faction_id": "vanguard-v1",
		"match_seed": 73_502,
	})
	_check(bool(bootstrap.get("ok", false)), "shop-alias bootstrap failed")
	if not bool(bootstrap.get("ok", false)):
		return
	var key := "shop-alias-protected-key-v1".to_utf8_buffer()
	var attached := MatchRuntime.attach_protected_authority(bootstrap, key)
	_check(bool(attached.get("ok", false)), "shop-alias authority attach failed")
	if not bool(attached.get("ok", false)):
		return
	var simulation: Variant = attached["simulation"]
	var map_manifest: Dictionary = bootstrap["map_manifest"]
	var runtime_catalog: Dictionary = bootstrap["runtime"]
	var registry: Dictionary = bootstrap["registry"]
	var bindings: Dictionary = {}
	var binding_id := 1_000_000_000
	var building_ids: Array = simulation.state.neutrals.buildings.keys()
	building_ids.sort()
	for building_id_variant: Variant in building_ids:
		bindings[str(building_id_variant)] = binding_id
		binding_id += 1
	var shop_site_id := "neutral_west_laboratory"
	var shop_authority: Dictionary = simulation.state.neutrals.buildings[shop_site_id]
	var own_worker_id := _map_entity_id(registry, "spawn_self_worker_01")
	var sight_position := _teleport_near_point(
		simulation, own_worker_id, shop_authority["position_mt"]
	)
	_check(
		not sight_position.is_empty(),
		"shop-alias worker could not be placed near the laboratory"
	)
	if sight_position.is_empty():
		return
	var perception := PerceptionRuntime.new()
	var perception_errors := perception.configure(
		MATCH_ID + "-shop",
		map_manifest,
		"shop-alias-seat-zero-salt".to_utf8_buffer(),
		"shop-alias-seat-one-salt".to_utf8_buffer()
	)
	_check(perception_errors.is_empty(), "shop-alias perception configure failed")
	if not perception_errors.is_empty():
		return
	var neutral_registry := SnapshotBuilder.neutral_registry_from_authority(
		simulation, bindings
	)
	var emitted := _emit(
		simulation, perception, 1, "fixed_simultaneous", neutral_registry
	)
	_check(bool(emitted.get("ok", false)), "shop-alias observation emission failed")
	if not bool(emitted.get("ok", false)):
		return
	var observation: Dictionary = emitted["observations"]["0"]
	var shop: Dictionary = {}
	for row_variant: Variant in observation["visible_shops"]:
		var row: Dictionary = row_variant
		if str(row["site_id"]) == shop_site_id:
			shop = row
			break
	_check(
		not shop.is_empty(),
		"visible laboratory was not emitted: %s" % JSON.stringify(observation["visible_shops"])
	)
	if shop.is_empty():
		return
	var shop_alias := str(shop["shop_id"])
	_check(ActionContract.is_entity_id(shop_alias), "visible laboratory shop_id is not opaque")
	_check(shop_alias != shop_site_id, "visible laboratory exposed its site ID as shop_id")
	_check(
		shop_alias != "e_%d" % int(bindings[shop_site_id]),
		"visible laboratory exposed its protected virtual internal ID"
	)
	var boundary := {
		"accepted_batch_ids": [],
		"neutral_building_bindings": bindings,
		"received_tick": int(simulation.state.tick),
	}
	var builder := LegalContextBuilder.new()
	var built := builder.build(
		perception, 0, observation, simulation, map_manifest,
		runtime_catalog, boundary, key
	)
	_check(bool(built.get("ok", false)), "visible shop legal join failed: %s" % _errors(built))
	if not bool(built.get("ok", false)):
		return
	_check(
		built["legal_context"]["entities"].has(shop_alias)
		and (built["legal_context"]["entities"][shop_alias]["tags"] as Array).has("shop"),
		"shop alias did not enter the visible legal entity set"
	)
	_check(
		int(built["protected_resolution_data"]["entities"][shop_alias]["internal_id"])
		== int(bindings[shop_site_id])
		and str(built["protected_resolution_data"]["entities"][shop_alias]["neutral_building_id"])
		== shop_site_id,
		"shop alias did not resolve through its protected neutral binding"
	)
	var available_offer := ""
	var offer_requires_target := false
	for offer_variant: Variant in shop["offers"]:
		var offer: Dictionary = offer_variant
		if bool(offer["available"]):
			available_offer = str(offer["offer_id"])
			offer_requires_target = bool(offer.get("requires_service_target", false))
			break
	_check(not available_offer.is_empty(), "visible laboratory has no purchasable offer fixture")
	var buyer_alias := _alias_for_internal(
		built["protected_resolution_data"]["entities"], own_worker_id
	)
	var purchase_command := {
		"buyer_id": buyer_alias,
		"command_id": "buy_visible_offer",
		"offer_id": available_offer,
		"op": "purchase_offer",
		"quantity": 1,
		"shop_id": shop_alias,
	}
	if offer_requires_target:
		purchase_command["service_target"] = {
			"kind": "point",
			"xy_mt": (shop["position_mt"] as Array).duplicate(),
		}
	var purchase := _batch(observation, [purchase_command])
	var compiled := ActionValidator.new().validate_and_compile(
		purchase, built["legal_context"]
	)
	_check(
		bool(compiled.get("ok", false))
		and (compiled.get("intents", []) as Array).size() == 1,
		"purchase_offer could not consume the emitted shop alias"
	)
	## The sell path uses the same emitted shop target. Give the authoritative
	## owned actor a narrow synthetic Hero inventory fact in this validator-only
	## fixture so both public operations prove the joined alias surface.
	var sell_context: Dictionary = (built["legal_context"] as Dictionary).duplicate(true)
	var seller: Dictionary = sell_context["entities"][buyer_alias]
	var seller_tags: Array = seller["tags"].duplicate()
	seller_tags.append("hero")
	seller_tags.sort()
	seller["tags"] = seller_tags
	seller["item_instance_ids"] = ["shop_alias_test_item"]
	var sell := _batch(observation, [{
		"command_id": "sell_at_visible_shop",
		"hero_id": buyer_alias,
		"item_instance_id": "shop_alias_test_item",
		"op": "sell_item",
		"shop_id": shop_alias,
	}])
	var sell_compiled := ActionValidator.new().validate_and_compile(sell, sell_context)
	_check(
		bool(sell_compiled.get("ok", false))
		and (sell_compiled.get("intents", []) as Array).size() == 1,
		"sell_item could not consume the emitted shop alias"
	)
	var tampered := observation.duplicate(true)
	tampered["visible_shops"][0]["shop_id"] = buyer_alias
	tampered["observation_hash"] = ObservationContract.observation_hash(tampered)
	_check(
		not bool(builder.build(
			perception, 0, tampered, simulation, map_manifest,
			runtime_catalog, boundary, key
		).get("ok", false)),
		"legal join accepted a shop row carrying another entity's alias"
	)


func _run_scenario(reverse_input: bool) -> Dictionary:
	var bootstrap := Bootstrap.create_official({
		"faction_id": "vanguard-v1",
		"match_seed": 73_501,
	})
	_check(bool(bootstrap.get("ok", false)), "official legal-context bootstrap failed")
	if not bool(bootstrap.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	var simulation: Variant = bootstrap["simulation"]
	var runtime: Dictionary = bootstrap["runtime"]
	var map_manifest: Dictionary = bootstrap["map_manifest"]
	var registry: Dictionary = bootstrap["registry"]
	_queue_one_tier_each(simulation)

	var perception := PerceptionRuntime.new()
	var perception_errors := perception.configure(
		MATCH_ID,
		map_manifest,
		"legal-context-seat-zero-salt".to_utf8_buffer(),
		"legal-context-seat-one-salt".to_utf8_buffer()
	)
	_check(perception_errors.is_empty(), "legal-context perception configure failed")
	if not perception_errors.is_empty():
		return {"hash": "", "ok": false, "summary": {}}

	var emitted_hidden := _emit(simulation, perception, 1)
	_check(bool(emitted_hidden.get("ok", false)), "hidden-phase observation emission failed")
	if not bool(emitted_hidden.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	var observation_zero: Dictionary = emitted_hidden["observations"]["0"]
	var observation_one: Dictionary = emitted_hidden["observations"]["1"]
	var builder := LegalContextBuilder.new()
	var boundary := {"accepted_batch_ids": [], "received_tick": 0}
	var key := TIE_KEY_TEXT.to_utf8_buffer()
	var map_input := _reverse_top_dictionary(map_manifest) if reverse_input else map_manifest
	var runtime_input := _reverse_top_dictionary(runtime) if reverse_input else runtime
	var boundary_input := _reverse_top_dictionary(boundary) if reverse_input else boundary
	var zero_input := _reverse_top_dictionary(observation_zero) if reverse_input else observation_zero
	var one_input := _reverse_top_dictionary(observation_one) if reverse_input else observation_one
	var zero := builder.build(
		perception, 0, zero_input, simulation, map_input, runtime_input, boundary_input, key
	)
	var one := builder.build(
		perception, 1, one_input, simulation, map_input, runtime_input, boundary_input, key
	)
	_check(bool(zero.get("ok", false)), "seat-0 legal context failed: %s" % _errors(zero))
	_check(bool(one.get("ok", false)), "seat-1 legal context failed: %s" % _errors(one))
	if not bool(zero.get("ok", false)) or not bool(one.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	_assert_context_shape(zero, observation_zero, 0)
	_assert_context_shape(one, observation_one, 1)
	_test_queue_join(zero, observation_zero)

	var enemy_worker_id := _map_entity_id(registry, "spawn_opponent_worker_01")
	var hidden_alias: String = str(
		perception.knowledge_state_for_checkpoint(0).ensure_alias(enemy_worker_id)
	)
	var hidden_again := builder.build(
		perception, 0, observation_zero, simulation, map_manifest, runtime, boundary, key
	)
	_check(bool(hidden_again.get("ok", false)), "known-but-hidden alias rebuild failed")
	if bool(hidden_again.get("ok", false)):
		_check(
			not hidden_again["legal_context"]["entities"].has(hidden_alias),
			"known-but-hidden alias entered validator context"
		)
		_check(
			not hidden_again["protected_resolution_data"]["entities"].has(hidden_alias),
			"known-but-hidden alias entered resolver context"
		)
	_test_hidden_attack_rejection(zero, observation_zero, hidden_alias)
	_test_tamper_rejection(
		builder, perception, observation_zero, observation_one,
		simulation, map_manifest, runtime, boundary, key
	)
	_test_continuous_application_tick(
		builder, perception, observation_zero, simulation, map_manifest, runtime, key
	)

	var own_worker_id := _map_entity_id(registry, "spawn_self_worker_01")
	var original_enemy_position := [
		int(simulation.state.entities[enemy_worker_id].position_x_mt),
		int(simulation.state.entities[enemy_worker_id].position_y_mt),
	]
	var visible_position := _teleport_near(
		simulation, enemy_worker_id, own_worker_id
	)
	_check(not visible_position.is_empty(), "could not create visible opponent fixture")
	var emitted_visible := _emit(simulation, perception, 3)
	_check(bool(emitted_visible.get("ok", false)), "visible-phase observation emission failed")
	if not bool(emitted_visible.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	var visible_zero_obs: Dictionary = emitted_visible["observations"]["0"]
	var visible_one_obs: Dictionary = emitted_visible["observations"]["1"]
	var visible_zero := builder.build(
		perception, 0, visible_zero_obs, simulation, map_manifest, runtime, boundary, key
	)
	var visible_one := builder.build(
		perception, 1, visible_one_obs, simulation, map_manifest, runtime, boundary, key
	)
	_check(bool(visible_zero.get("ok", false)), "visible seat-0 legal context failed: %s" % _errors(visible_zero))
	_check(bool(visible_one.get("ok", false)), "visible seat-1 legal context failed: %s" % _errors(visible_one))
	if not bool(visible_zero.get("ok", false)) or not bool(visible_one.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	var seat_zero_enemy_alias := _alias_for_internal(
		visible_zero["protected_resolution_data"]["entities"], enemy_worker_id
	)
	var seat_one_owner_alias := _alias_for_internal(
		visible_one["protected_resolution_data"]["entities"], enemy_worker_id
	)
	_check(not seat_zero_enemy_alias.is_empty(), "visible enemy alias was not targetable")
	_check(not seat_one_owner_alias.is_empty(), "seat-one owner alias is missing")
	_check(seat_zero_enemy_alias != seat_one_owner_alias, "observer aliases collided for one entity")
	var combined := builder.build_combined_resolution_context(visible_zero, visible_one, key)
	_check(bool(combined.get("ok", false)), "combined dual-observer resolver failed: %s" % _errors(combined))
	var tampered_zero := visible_zero.duplicate(false)
	tampered_zero["legal_context"] = (visible_zero["legal_context"] as Dictionary).duplicate(true)
	tampered_zero["protected_resolution_data"] = (
		visible_zero["protected_resolution_data"] as Dictionary
	).duplicate(true)
	var tampered_alias := str(tampered_zero["protected_resolution_data"]["entities"].keys()[0])
	tampered_zero["protected_resolution_data"]["entities"][tampered_alias]["internal_id"] += 10_000
	_check(
		not bool(builder.build_combined_resolution_context(
			tampered_zero, visible_one, key
		).get("ok", false)),
		"combined resolver accepted tampered protected resolution data"
	)
	if bool(combined.get("ok", false)):
		var combined_context: Variant = combined["resolution_context"]
		var resolved_zero: Dictionary = combined_context.resolve_public_entity(seat_zero_enemy_alias)
		var resolved_one: Dictionary = combined_context.resolve_public_entity(seat_one_owner_alias)
		_check(
			bool(resolved_zero.get("ok", false)) and bool(resolved_one.get("ok", false))
			and int(resolved_zero["internal_id"]) == enemy_worker_id
			and int(resolved_one["internal_id"]) == enemy_worker_id,
			"combined resolver did not preserve both observer aliases"
		)
		_check(
			str(combined_context.alias_for_internal_entity(enemy_worker_id)).is_empty(),
			"combined resolver exposed an ambiguous reverse alias"
		)
		_test_simultaneous_execute(
			simulation, visible_zero, visible_one, visible_zero_obs, visible_one_obs, combined
		)

	_check(
		_teleport_exact(simulation, enemy_worker_id, original_enemy_position),
		"could not restore opponent fixture position"
	)
	var emitted_remembered := _emit(simulation, perception, 4)
	_check(bool(emitted_remembered.get("ok", false)), "remembered-phase observation emission failed")
	if not bool(emitted_remembered.get("ok", false)):
		return {"hash": "", "ok": false, "summary": {}}
	var remembered_obs: Dictionary = emitted_remembered["observations"]["0"]
	var remembered := builder.build(
		perception, 0, remembered_obs, simulation, map_manifest, runtime, boundary, key
	)
	_check(bool(remembered.get("ok", false)), "remembered legal context failed: %s" % _errors(remembered))
	_check(
		(remembered_obs["remembered_contacts"] as Array).any(
			func(row: Dictionary) -> bool: return str(row["entity_id"]) == seat_zero_enemy_alias
		),
		"visible contact did not become remembered"
	)
	if bool(remembered.get("ok", false)):
		_check(
			not remembered["legal_context"]["entities"].has(seat_zero_enemy_alias),
			"remembered contact remained targetable"
		)
		_check(
			not remembered["protected_resolution_data"]["entities"].has(seat_zero_enemy_alias),
			"remembered contact remained resolvable"
		)

	var golden_document := {
		"combined_hash": str(combined.get("protected_context_hash", "")),
		"hidden_zero_hash": str(zero["protected_context_hash"]),
		"hidden_one_hash": str(one["protected_context_hash"]),
		"remembered_hash": str(remembered.get("protected_context_hash", "")),
		"visible_zero_hash": str(visible_zero["protected_context_hash"]),
		"visible_one_hash": str(visible_one["protected_context_hash"]),
	}
	var summary := {
		"combined_aliases": int((combined.get("public_resolution_snapshot", {}).get("entities", {}) as Dictionary).size()),
		"hidden_entities": int((zero["legal_context"]["entities"] as Dictionary).size()),
		"known_regions": int((zero["legal_context"]["known_regions"] as Dictionary).size()),
		"known_sites": int((zero["legal_context"]["known_sites"] as Dictionary).size()),
		"remembered_contacts": int((remembered_obs["remembered_contacts"] as Array).size()),
		"visible_contacts": int((visible_zero_obs["visible_contacts"] as Array).size()),
	}
	return {
		"hash": Codec.sha256_canonical(golden_document),
		"ok": true,
		"summary": summary,
	}


func _assert_context_shape(result: Dictionary, observation: Dictionary, seat: int) -> void:
	var legal: Dictionary = result["legal_context"]
	_check(str(legal["observation_hash"]) == str(observation["observation_hash"]), "legal context observation hash drifted")
	_check(int(legal["player_seat"]) == seat, "legal context seat drifted")
	var legal_aliases: Array = legal["entities"].keys()
	var resolver_aliases: Array = result["protected_resolution_data"]["entities"].keys()
	legal_aliases.sort()
	resolver_aliases.sort()
	_check(legal_aliases == resolver_aliases, "validator/resolver actionable alias sets differ")
	_check(bool(legal["self_rotates_to_world"]) == (seat == 1), "legal coordinate frame drifted")
	_check(not (legal["known_regions"] as Dictionary).is_empty(), "explored regions were not joined")
	_check(not (legal["known_sites"] as Dictionary).is_empty(), "explored build sites were not joined")
	_check(
		Codec.validate_canonical_value(legal, "$.runner_legal_context").is_empty(),
		"legal context is not canonical JSON-safe"
	)
	var public_json := Codec.canonical_json(result["public_resolution_snapshot"])
	_check(not public_json.contains("internal_"), "public resolver snapshot leaked internal IDs")
	_check(not public_json.contains(TIE_KEY_TEXT), "public resolver snapshot leaked raw tie key")


func _test_queue_join(result: Dictionary, observation: Dictionary) -> void:
	var found := false
	for structure_variant: Variant in observation["owned_structures"]:
		var structure: Dictionary = structure_variant
		if (structure["production_queue"] as Array).is_empty():
			continue
		var alias := str(structure["entity_id"])
		var public_queue := str(structure["production_queue"][0]["queue_entry_id"])
		var legal_record: Dictionary = result["legal_context"]["entities"][alias]
		_check(public_queue in legal_record.get("queue_entry_ids", []), "observed queue ID is not cancellable")
		var resolved: Dictionary = result["resolution_context"].resolve_queue_entry(public_queue, alias)
		_check(bool(resolved.get("ok", false)), "observed queue ID did not resolve to economy authority")
		found = true
		break
	_check(found, "queue join fixture did not expose an owned queue")


func _test_hidden_attack_rejection(
	result: Dictionary,
	observation: Dictionary,
	hidden_alias: String
) -> void:
	var own_alias := str(observation["owned_entities"][0]["entity_id"])
	var command := {
		"actor_ids": [own_alias],
		"command_id": "hidden_target",
		"op": "attack_entity",
		"queue": "replace",
		"target": {"entity_id": hidden_alias, "kind": "entity"},
	}
	var compiled := ActionValidator.new().validate_and_compile(
		_batch(observation, [command]), result["legal_context"]
	)
	_check(bool(compiled.get("ok", false)), "hidden-target command invalidated its envelope")
	_check(
		str(compiled["receipt"]["commands"][0]["code"]) == "target_unavailable",
		"hidden target did not fail with non-leaking target_unavailable"
	)


func _test_tamper_rejection(
	builder: Variant,
	perception: Variant,
	observation_zero: Dictionary,
	observation_one: Dictionary,
	simulation: Variant,
	map_manifest: Dictionary,
	runtime: Dictionary,
	boundary: Dictionary,
	key: PackedByteArray
) -> void:
	var tampered := observation_zero.duplicate(true)
	tampered["owned_entities"][0]["position_mt"][0] += 500
	tampered["observation_hash"] = ObservationContract.observation_hash(tampered)
	_check(
		ObservationContract.validate_observation(tampered, true).is_empty(),
		"tamper fixture was not structurally valid after rehash"
	)
	var rejected: Dictionary = builder.build(
		perception, 0, tampered, simulation, map_manifest, runtime, boundary, key
	)
	_check(not bool(rejected.get("ok", false)), "validly rehashed observation tamper was accepted")
	var tier_tampered := observation_zero.duplicate(true)
	tier_tampered["technology"]["tier"] = 2
	tier_tampered["observation_hash"] = ObservationContract.observation_hash(tier_tampered)
	_check(
		not bool(builder.build(
			perception, 0, tier_tampered, simulation, map_manifest, runtime, boundary, key
		).get("ok", false)),
		"validly rehashed technology-authority tamper was accepted"
	)
	var crossed: Dictionary = builder.build(
		perception, 0, observation_one, simulation, map_manifest, runtime, boundary, key
	)
	_check(not bool(crossed.get("ok", false)), "seat-one observation was accepted for seat zero")
	var unknown_boundary := boundary.duplicate(true)
	unknown_boundary["provider_identity"] = "secret"
	_check(
		not bool(builder.build(
			perception, 0, observation_zero, simulation, map_manifest, runtime,
			unknown_boundary, key
		).get("ok", false)),
		"unknown/protected boundary field was accepted"
	)


func _test_continuous_application_tick(
	builder: Variant,
	perception: Variant,
	fixed_observation: Dictionary,
	simulation: Variant,
	map_manifest: Dictionary,
	runtime: Dictionary,
	key: PackedByteArray
) -> void:
	var emitted := _emit(simulation, perception, 2, "continuous_realtime")
	_check(bool(emitted.get("ok", false)), "continuous observation emission failed")
	if not bool(emitted.get("ok", false)):
		return
	var observation: Dictionary = emitted["observations"]["0"]
	var observation_tick := int(observation["tick"])
	var valid_until_tick := int(observation["decision"]["valid_until_tick"])
	var boundary := {
		"accepted_batch_ids": [],
		"application_tick": observation_tick + 5,
		"received_tick": observation_tick,
	}
	var accepted: Dictionary = builder.build(
		perception, 0, observation, simulation, map_manifest, runtime, boundary, key
	)
	_check(bool(accepted.get("ok", false)), "continuous protected application tick was rejected")
	if bool(accepted.get("ok", false)):
		_check(
			int(accepted["legal_context"]["application_tick"]) == observation_tick + 5,
			"continuous application tick did not reach the frozen legal context"
		)
	var missing := boundary.duplicate(true)
	missing.erase("application_tick")
	_check(
		not bool(builder.build(
			perception, 0, observation, simulation, map_manifest, runtime, missing, key
		).get("ok", false)),
		"continuous context accepted a missing ready-time application tick"
	)
	var early := boundary.duplicate(true)
	early["application_tick"] = observation_tick
	_check(
		not bool(builder.build(
			perception, 0, observation, simulation, map_manifest, runtime, early, key
		).get("ok", false)),
		"continuous context accepted an application tick at the observation tick"
	)
	var late := boundary.duplicate(true)
	late["application_tick"] = valid_until_tick + 1
	_check(
		not bool(builder.build(
			perception, 0, observation, simulation, map_manifest, runtime, late, key
		).get("ok", false)),
		"continuous context accepted an application tick beyond validity"
	)
	var validity_tampered := observation.duplicate(true)
	validity_tampered["decision"]["valid_until_tick"] += 1
	validity_tampered["observation_hash"] = ObservationContract.observation_hash(validity_tampered)
	_check(
		not bool(builder.build(
			perception, 0, validity_tampered, simulation, map_manifest, runtime,
			boundary, key
		).get("ok", false)),
		"continuous context accepted a rehashed expanded validity window"
	)
	var fixed_override := {
		"accepted_batch_ids": [],
		"application_tick": int(fixed_observation["tick"]) + 1,
		"received_tick": int(fixed_observation["tick"]),
	}
	_check(
		not bool(builder.build(
			perception, 0, fixed_observation, simulation, map_manifest, runtime,
			fixed_override, key
		).get("ok", false)),
		"fixed mode accepted a boundary application-tick override"
	)


func _test_simultaneous_execute(
	simulation: Variant,
	zero: Dictionary,
	one: Dictionary,
	observation_zero: Dictionary,
	observation_one: Dictionary,
	combined: Dictionary
) -> void:
	var zero_actor := str(observation_zero["owned_entities"][0]["entity_id"])
	var one_actor := str(observation_one["owned_entities"][0]["entity_id"])
	var zero_batch := _batch(observation_zero, [{
		"actor_ids": [zero_actor], "command_id": "seat_zero_stop", "op": "stop",
	}])
	var one_batch := _batch(observation_one, [{
		"actor_ids": [one_actor], "command_id": "seat_one_stop", "op": "stop",
	}])
	zero_batch["client_batch_id"] = "batch_seat_zero"
	one_batch["client_batch_id"] = "batch_seat_one"
	var compiled_zero := ActionValidator.new().validate_and_compile(zero_batch, zero["legal_context"])
	var compiled_one := ActionValidator.new().validate_and_compile(one_batch, one["legal_context"])
	_check(bool(compiled_zero.get("ok", false)), "seat-zero simultaneous compile failed")
	_check(bool(compiled_one.get("ok", false)), "seat-one simultaneous compile failed")
	var intents: Array[Dictionary] = []
	intents.append_array(compiled_zero.get("intents", []))
	intents.append_array(compiled_one.get("intents", []))
	var execution := IntentBridge.new().execute(
		simulation, intents, combined["resolution_context"]
	)
	_check(bool(execution.get("ok", false)), "one-call dual-seat intent execution failed")
	_check(
		(execution.get("receipts", []) as Array).size() == 2,
		"one-call dual-seat execution did not emit two receipts"
	)


func _queue_one_tier_each(simulation: Variant) -> void:
	for seat: int in [0, 1]:
		var stronghold_id := 0
		for entity_id: int in simulation.state.economy.sorted_entity_record_ids():
			var record: Dictionary = simulation.state.economy.entity_records[entity_id]
			if int(record["owner_seat"]) == seat \
				and str(record["semantic_role"]) == "stronghold":
				stronghold_id = entity_id
				break
		simulation.state.economy.players[seat]["gold"] = 2_000
		simulation.state.economy.players[seat]["lumber"] = 1_000
		var receipt: Dictionary = simulation.economy.queue_tier_upgrade(
			simulation.state, seat, stronghold_id, 2
		)
		_check(bool(receipt.get("accepted", false)), "queue fixture failed for seat %d" % seat)


func _emit(
	simulation: Variant,
	perception: Variant,
	observation_seq: int,
	mode: String = "fixed_simultaneous",
	neutral_registry: Dictionary = {}
) -> Dictionary:
	var effective_neutral_registry := (
		SnapshotBuilder.empty_neutral_registry()
		if neutral_registry.is_empty()
		else neutral_registry.duplicate(true)
	)
	var context := {
		"controller_registry": SnapshotBuilder.empty_controller_registry(),
		"day_phase": "day",
		"neutral_registry": effective_neutral_registry,
		"seat_runtime": [
			_seat_runtime(0, observation_seq, int(simulation.state.tick), mode),
			_seat_runtime(1, observation_seq, int(simulation.state.tick), mode),
		],
		"world_event_seq_after": 0,
	}
	var snapshot := SnapshotBuilder.new().build(simulation, context)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	return perception.phase_12(snapshot["phase_snapshot"])


static func _seat_runtime(
	seat: int,
	observation_seq: int,
	tick: int,
	mode: String = "fixed_simultaneous"
) -> Dictionary:
	var continuous := mode == "continuous_realtime"
	return {
		"decision": {
			"commands_apply_tick": null if continuous else tick + 1,
			"mode": mode,
			"observation_tick": tick,
			"response_deadline_ms": 30_000,
			"valid_until_tick": tick + 100 if continuous else tick + 1,
		},
		"last_action_receipt": null,
		"observation_seq": observation_seq,
		"seat": seat,
		"working_memory": "seat-%d-memory" % seat,
	}


static func _batch(observation: Dictionary, commands: Array) -> Dictionary:
	return {
		"based_on_observation_hash": str(observation["observation_hash"]),
		"client_batch_id": "batch_legal_context",
		"commands": commands,
		"match_id": str(observation["match_id"]),
		"message_type": "action_batch",
		"observation_seq": int(observation["observation_seq"]),
		"protocol_version": ActionContract.PROTOCOL_VERSION,
		"valid_until_tick": int(observation["decision"]["valid_until_tick"]),
	}


static func _teleport_near(simulation: Variant, entity_id: int, anchor_id: int) -> Array:
	var anchor: Variant = simulation.state.entities[anchor_id]
	var candidates: Array = []
	for distance: int in [1500, 2000, 2500, 3000, 3500, 4000]:
		for offset: Array in [[distance, 0], [-distance, 0], [0, distance], [0, -distance]]:
			candidates.append([
				int(anchor.position_x_mt) + int(offset[0]),
				int(anchor.position_y_mt) + int(offset[1]),
			])
	var entity: Variant = simulation.state.entities[entity_id]
	simulation.grid.release_ground_actor(entity_id)
	for point_variant: Variant in candidates:
		var point: Array = point_variant
		if simulation.grid.reserve_ground_actor(
			entity_id, int(point[0]), int(point[1]), int(entity.radius_mt)
		):
			entity.set_position_mt(int(point[0]), int(point[1]))
			return point
	return []


static func _teleport_near_point(
	simulation: Variant, entity_id: int, anchor_point: Array
) -> Array:
	var entity: Variant = simulation.state.entities[entity_id]
	simulation.grid.release_ground_actor(entity_id)
	for distance: int in [1_500, 2_000, 2_500, 3_000, 3_500, 4_000, 5_000, 6_000, 7_000]:
		for direction: Array in [
			[1, 0], [-1, 0], [0, 1], [0, -1],
			[1, 1], [1, -1], [-1, 1], [-1, -1],
		]:
			var point := [
				int(anchor_point[0]) + distance * int(direction[0]),
				int(anchor_point[1]) + distance * int(direction[1]),
			]
			if simulation.grid.reserve_ground_actor(
				entity_id, int(point[0]), int(point[1]), int(entity.radius_mt)
			):
				entity.set_position_mt(int(point[0]), int(point[1]))
				return point
	return []


static func _teleport_exact(simulation: Variant, entity_id: int, point: Array) -> bool:
	var entity: Variant = simulation.state.entities[entity_id]
	simulation.grid.release_ground_actor(entity_id)
	if not simulation.grid.reserve_ground_actor(
		entity_id, int(point[0]), int(point[1]), int(entity.radius_mt)
	):
		return false
	entity.set_position_mt(int(point[0]), int(point[1]))
	return true


static func _map_entity_id(registry: Dictionary, map_id: String) -> int:
	return int(registry["entity_id_by_map_id"].get(map_id, 0))


static func _alias_for_internal(entities: Dictionary, internal_id: int) -> String:
	for alias_variant: Variant in entities.keys():
		if int(entities[alias_variant]["internal_id"]) == internal_id:
			return str(alias_variant)
	return ""


static func _reverse_top_dictionary(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys: Array = value.keys()
	keys.sort()
	keys.reverse()
	for key_variant: Variant in keys:
		result[key_variant] = value[key_variant]
	return result


static func _errors(result: Dictionary) -> String:
	var messages: Array[String] = []
	for message_variant: Variant in result.get("errors", []):
		messages.append(str(message_variant))
	return "; ".join(messages)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
