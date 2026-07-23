extends SceneTree

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const MapLoader := preload("res://scripts/duel/simulation/duel_map_loader.gd")
const ObservationContract := preload("res://scripts/duel/observations/duel_observation_contract.gd")
const PerceptionContract := preload("res://scripts/duel/perception/duel_perception_contract.gd")
const PerceptionRuntime := preload("res://scripts/duel/perception/duel_perception_runtime.gd")

const MAP_PATH := "res://../game/duel_protocol/maps/crossroads-duel-v1.json"
const MATCH_ID := "m_perception-runtime-conformance"
const GOLDEN_DUAL_OBSERVATION_HASH := "eb148ae18acec162780a6ca5492a560e4690a59344374385ac9b7f750c8246b0"

const HERO_ZERO_POSITION := [95_250, 64_250]
const HERO_ONE_POSITION := [96_749, 63_749]
const STRUCTURE_ZERO_POSITION := [94_750, 64_750]
const STRUCTURE_ONE_POSITION := [97_249, 63_249]
const PUBLIC_CENTER_POSITION := [95_999, 63_999]

var _failures := PackedStringArray()
var _manifest: Dictionary = {}
var _grid: Dictionary = {}


func _init() -> void:
	_load_locked_world()
	if not _manifest.is_empty() and not _grid.is_empty():
		_test_dual_projection_and_public_context()
		_test_repeatability_and_insertion_order()
		_test_hidden_state_invariance_and_fail_closed_boundary()
		_test_memory_and_deterministic_truncation()
		_test_terminal_is_player_relative()
	var golden_hash := _fresh_dual_hash()
	if not GOLDEN_DUAL_OBSERVATION_HASH.is_empty():
		_check(
			golden_hash == GOLDEN_DUAL_OBSERVATION_HASH,
			"dual perception golden hash changed"
		)
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_PERCEPTION_FAILURE: %s" % failure)
		print("DUEL_PERCEPTION_FAILED count=%d hash=%s" % [_failures.size(), golden_hash])
		quit(1)
		return
	print("DUEL_PERCEPTION_OK hash=%s" % golden_hash)
	quit(0)


func _load_locked_world() -> void:
	_manifest = _load_json(MAP_PATH)
	_check(not _manifest.is_empty(), "official map manifest could not be loaded")
	if _manifest.is_empty():
		return
	var loaded_map := MapLoader.load_manifest(_manifest)
	_check(bool(loaded_map["ok"]), "official map could not be decoded: %s" % _errors(loaded_map))
	if not bool(loaded_map["ok"]):
		return
	_grid = _closed_visibility_grid(loaded_map["grid"].to_canonical_dict())
	_check(
		PerceptionContract.validate_phase_snapshot(_standard_phase()).is_empty(),
		"standard phase snapshot does not satisfy the closed boundary"
	)
	var catalogs := CatalogLoader.load_official_catalogs()
	_check(bool(catalogs["ok"]), "locked catalogs could not be loaded: %s" % _errors(catalogs))
	if bool(catalogs["ok"]):
		_check(
			(catalogs["catalogs"] as Dictionary).has("faction:vanguard-v1"),
			"locked Vanguard catalog is missing"
		)


func _test_dual_projection_and_public_context() -> void:
	var runtime := _runtime()
	var result := runtime.phase_12(_standard_phase())
	_check(bool(result["ok"]), "dual phase-12 projection failed: %s" % _errors(result))
	if not bool(result["ok"]):
		return
	var zero: Dictionary = result["observations"]["0"]
	var one: Dictionary = result["observations"]["1"]
	_check(
		ObservationContract.validate_observation(zero).is_empty()
		and ObservationContract.validate_observation(one).is_empty(),
		"a dual runtime observation failed the locked observation contract"
	)
	_check((zero["heroes"] as Array).size() == 1, "seat 0 did not receive its own Hero")
	_check((one["heroes"] as Array).size() == 1, "seat 1 did not receive its own Hero")
	_check(
		(zero["owned_structures"] as Array).size() == 1
		and (one["owned_structures"] as Array).size() == 1,
		"owned production structures were not classified"
	)
	_check(
		((zero["owned_structures"] as Array)[0]["production_queue"] as Array).size() == 1,
		"owned production queue was omitted"
	)
	_check(
		(zero["technology"]["researching"] as Array).size() == 1,
		"owned research queue was omitted"
	)
	_check(
		(zero["squads"] as Array).size() == 1
		and (zero["squads"][0]["member_ids"] as Array).size() == 1,
		"owned squad IDs were not safely aliased"
	)
	_check(
		(zero["visible_contacts"] as Array).size() >= 2
		and (one["visible_contacts"] as Array).size() >= 2,
		"nearby mirrored opponents were not legally visible"
	)
	_check(
		(zero["visible_items"] as Array).size() == 1
		and (one["visible_items"] as Array).size() == 1,
		"visible item candidates were not emitted to both legal observers"
	)
	_check(
		(zero["visible_shops"] as Array).size() == 1
		and (one["visible_shops"] as Array).size() == 1,
		"visible shop candidates were not emitted to both legal observers"
	)
	var zero_shop_id := str(zero["visible_shops"][0]["shop_id"])
	var one_shop_id := str(one["visible_shops"][0]["shop_id"])
	_check(
		ObservationContract.is_entity_id(zero_shop_id)
		and ObservationContract.is_entity_id(one_shop_id),
		"visible shops did not expose opaque entity identifiers"
	)
	_check(
		zero_shop_id != one_shop_id,
		"one neutral shop reused an alias across observers"
	)
	_check(
		zero_shop_id == str(runtime.knowledge_state_for_checkpoint(0).alias_if_known(5))
		and one_shop_id == str(runtime.knowledge_state_for_checkpoint(1).alias_if_known(5)),
		"visible shop identifiers are not backed by protected observer aliases"
	)
	var next_visible := runtime.phase_12(_next_visible_phase())
	_check(bool(next_visible.get("ok", false)), "next visible shop phase failed")
	if bool(next_visible.get("ok", false)):
		_check(
			str(next_visible["observations"]["0"]["visible_shops"][0]["shop_id"])
			== zero_shop_id
			and str(next_visible["observations"]["1"]["visible_shops"][0]["shop_id"])
			== one_shop_id,
			"shop aliases were not stable across visible observations"
		)
	var hidden_shop := _runtime().phase_12(_hidden_shop_phase())
	_check(bool(hidden_shop.get("ok", false)), "hidden shop phase failed")
	if bool(hidden_shop.get("ok", false)):
		_check(
			(hidden_shop["observations"]["0"]["visible_shops"] as Array).is_empty()
			and (hidden_shop["observations"]["1"]["visible_shops"] as Array).is_empty(),
			"shop identifiers were emitted outside current visibility"
		)
	_check(
		(zero["map_state"]["local_context"] as Array).size() == 1
		and (one["map_state"]["local_context"] as Array).size() == 1,
		"local tactical context was not built from legal knowledge"
	)
	var zero_hero: Dictionary = zero["heroes"][0]
	var one_hero: Dictionary = one["heroes"][0]
	_check(
		zero_hero["position_mt"] == one_hero["position_mt"],
		"mirrored own Heroes did not share the self-canonical position"
	)
	_check(
		str(zero_hero["entity_id"]) != str(one_hero["entity_id"]),
		"observer-scoped aliases collided across seats"
	)
	_check(
		str(zero["visible_shops"][0]["region_id"])
		== str(one["visible_shops"][0]["region_id"]),
		"invariant central shop region changed across frames"
	)
	_check(
		str(zero["map_state"]["local_context"][0]["exits"][0]["to_region_id"])
		== "r_self_natural"
		and str(one["map_state"]["local_context"][0]["exits"][0]["to_region_id"])
		== "r_self_natural",
		"world-relative exit IDs were not transformed to self-relative IDs"
	)
	_check(
		str(zero["map_state"]["local_context"][0]["exits"][0]["bearing"]) == "north"
		and str(one["map_state"]["local_context"][0]["exits"][0]["bearing"]) == "north",
		"seat-1 local bearing was not rotated"
	)
	_check(
		str(zero["working_memory"]) == "seat zero plan"
		and str(one["working_memory"]) == "seat one plan",
		"per-model working memory crossed seats"
	)
	_check(
		int(zero["economy"]["gold"]) == 700 and int(one["economy"]["gold"]) == 701,
		"own economy snapshots crossed seats"
	)
	_check(
		not str(result["canonical_json"]["0"]).contains("seat one plan")
		and not str(result["canonical_json"]["1"]).contains("seat zero plan"),
		"one model's memory leaked into the other model's message"
	)
	for seat: String in ["0", "1"]:
		var json_text := str(result["canonical_json"][seat])
		_check(not json_text.contains("internal_id"), "protected IDs reached seat %s" % seat)
		_check(not json_text.contains("alias_salt"), "alias salt reached seat %s" % seat)
		_check(
			int(result["byte_counts"][seat]) == json_text.to_utf8_buffer().size(),
			"canonical byte count is wrong for seat %s" % seat
		)


func _test_repeatability_and_insertion_order() -> void:
	var baseline := _runtime().phase_12(_standard_phase())
	var repeated := _runtime().phase_12(_standard_phase())
	_check(bool(baseline["ok"]) and bool(repeated["ok"]), "repeatability setup failed")
	if not bool(baseline["ok"]) or not bool(repeated["ok"]):
		return
	_check(
		baseline["canonical_json"] == repeated["canonical_json"],
		"fresh runtimes did not produce identical dual observation bytes"
	)
	var permuted := _standard_phase()
	(permuted["entity_snapshots"] as Array).reverse()
	(permuted["candidate_events"] as Array).reverse()
	(permuted["seat_snapshots"] as Array).reverse()
	for seat_variant: Variant in permuted["seat_snapshots"]:
		var seat: Dictionary = seat_variant
		(seat["visible_item_candidates"] as Array).reverse()
		(seat["visible_shop_candidates"] as Array).reverse()
	var reordered := _runtime().phase_12(permuted)
	_check(bool(reordered["ok"]), "permuted phase failed: %s" % _errors(reordered))
	if bool(reordered["ok"]):
		_check(
			reordered["canonical_json"] == baseline["canonical_json"],
			"authoritative insertion order changed provider-visible bytes"
		)


func _test_hidden_state_invariance_and_fail_closed_boundary() -> void:
	var baseline_phase := _hidden_phase(90)
	var changed_phase := _hidden_phase(1)
	var baseline := _runtime().phase_12(baseline_phase)
	var changed := _runtime().phase_12(changed_phase)
	_check(bool(baseline["ok"]) and bool(changed["ok"]), "hidden-state setup failed")
	if bool(baseline["ok"]) and bool(changed["ok"]):
		_check(
			baseline["canonical_json"]["0"] == changed["canonical_json"]["0"],
			"hidden opponent HP changed seat-0 observation bytes"
		)
		_check(
			baseline["observation_hashes"]["1"] != changed["observation_hashes"]["1"],
			"the same HP change was not visible to its owning seat"
		)

	var unknown := _standard_phase()
	unknown["world_checkpoint_hash"] = "f".repeat(64)
	var unknown_result := _runtime().phase_12(unknown)
	_check(not bool(unknown_result["ok"]), "unknown authoritative field was silently ignored")
	_check(
		(unknown_result["observations"] as Dictionary).is_empty(),
		"failed closed input returned a partial model observation"
	)
	var provider_leak := _standard_phase()
	provider_leak["seat_snapshots"][0]["economy"]["provider_identity"] = "secret-model"
	var provider_runtime := _runtime()
	var provider_result := provider_runtime.phase_12(provider_leak)
	_check(not bool(provider_result["ok"]), "provider identity crossed the public-context boundary")
	_check(
		(provider_result["observations"] as Dictionary).is_empty(),
		"context leak failure returned a partial dual result"
	)
	_check(
		int(provider_runtime.knowledge_state_for_checkpoint(0).current_tick) == 0
		and int(provider_runtime.knowledge_state_for_checkpoint(1).current_tick) == 0,
		"preflight failure advanced one of the persistent knowledge states"
	)


func _test_memory_and_deterministic_truncation() -> void:
	var baseline_runtime := _runtime()
	var first := baseline_runtime.phase_12(_standard_phase())
	_check(bool(first["ok"]), "memory first-sight setup failed: %s" % _errors(first))
	if not bool(first["ok"]):
		return
	var hidden_phase := _second_phase(false, 0)
	var remembered := baseline_runtime.phase_12(hidden_phase)
	_check(bool(remembered["ok"]), "remembered observation failed: %s" % _errors(remembered))
	if not bool(remembered["ok"]):
		return
	for seat: String in ["0", "1"]:
		_check(
			(remembered["observations"][seat]["remembered_contacts"] as Array).size() >= 2,
			"seat %s did not retain frozen contacts after sight was removed" % seat
		)
		_check(
			(remembered["observations"][seat]["visible_items"] as Array).is_empty(),
			"hidden ground item remained provider-visible for seat %s" % seat
		)

	var byte_ceiling := int(remembered["byte_counts"]["0"]) - 1
	var trim_runtime := _runtime()
	_check(bool(trim_runtime.phase_12(_standard_phase())["ok"]), "truncation setup failed")
	var trimmed_phase := _second_phase(true, byte_ceiling)
	var trimmed := trim_runtime.phase_12(trimmed_phase)
	_check(bool(trimmed["ok"]), "deterministic truncation failed: %s" % _errors(trimmed))
	if bool(trimmed["ok"]):
		var observation: Dictionary = trimmed["observations"]["0"]
		_check(bool(observation["observation_truncated"]), "byte ceiling did not mark truncation")
		_check(not observation.has("brief"), "brief was not the first truncation category")
		_check(
			int(observation["omitted_counts"]["brief"]) > 0,
			"brief omission count was not recorded"
		)
		_check(
			int(trimmed["byte_counts"]["0"]) <= byte_ceiling,
			"trimmed observation exceeded the requested byte ceiling"
		)


func _test_terminal_is_player_relative() -> void:
	var phase := _standard_phase()
	phase["remaining_match_ticks"] = 0
	phase["terminal"] = {
		"kind": "victory",
		"reason": "stronghold_destroyed",
		"terminal_tick": 100,
		"winner_seat": 0,
	}
	var result := _runtime().phase_12(phase)
	_check(bool(result["ok"]), "terminal perception failed: %s" % _errors(result))
	if not bool(result["ok"]):
		return
	_check(
		str(result["observations"]["0"]["match_state"]["terminal"]["result"]) == "win",
		"winner did not receive a win terminal fact"
	)
	_check(
		str(result["observations"]["1"]["match_state"]["terminal"]["result"]) == "loss",
		"loser did not receive a loss terminal fact"
	)


func _fresh_dual_hash() -> String:
	if _manifest.is_empty() or _grid.is_empty():
		return ""
	var result := _runtime().phase_12(_standard_phase())
	if not bool(result["ok"]):
		return ""
	return Codec.sha256_canonical(result["observation_hashes"])


func _runtime() -> PerceptionRuntime:
	var runtime := PerceptionRuntime.new()
	var errors := runtime.configure(
		MATCH_ID,
		_manifest,
		"perception-seat-zero-alias-salt".to_utf8_buffer(),
		"perception-seat-one-alias-salt".to_utf8_buffer()
	)
	_check(errors.is_empty(), "perception runtime configuration failed: %s" % "; ".join(errors))
	return runtime


func _standard_phase() -> Dictionary:
	if _grid.is_empty():
		return {}
	return {
		"candidate_events": [
			{
				"audience_seats": [0],
				"kind": "resource_deposited",
				"owner_seat": 0,
				"phase": 12,
				"public_payload": {"amount": 10, "resource": "gold"},
				"tick": 100,
				"visibility_rule": "owner",
				"world_event_seq": 2,
			},
			{
				"kind": "combat_seen",
				"phase": 12,
				"public_payload": {"damage": 5, "position_mt": PUBLIC_CENTER_POSITION},
				"tick": 100,
				"visibility_rule": "position_visible",
				"world_event_seq": 1,
			},
		],
		"day_phase": "day",
		"entity_snapshots": [
			_entity(1, 0, HERO_ZERO_POSITION, "marshal", ["ground", "hero"], _hero_owned(90)),
			_entity(2, 1, HERO_ONE_POSITION, "marshal", ["ground", "hero"], _hero_owned(90)),
			_entity(3, 0, STRUCTURE_ZERO_POSITION, "garrison", ["ground", "structure"], _structure_owned()),
			_entity(4, 1, STRUCTURE_ONE_POSITION, "garrison", ["ground", "structure"], _structure_owned()),
		],
		"grid_snapshot": _grid.duplicate(true),
		"no_progress_ticks": 7,
		"remaining_match_ticks": 17_900,
		"seat_snapshots": [_seat_snapshot(0), _seat_snapshot(1)],
		"terminal": null,
		"tick": 100,
	}


func _second_phase(with_ceiling: bool, byte_ceiling: int) -> Dictionary:
	var phase := _standard_phase()
	phase["tick"] = 101
	phase["remaining_match_ticks"] = 17_899
	phase["candidate_events"] = []
	for entity_variant: Variant in phase["entity_snapshots"]:
		var entity: Dictionary = entity_variant
		entity["sight_day_mt"] = 0
		entity["sight_night_mt"] = 0
	for seat_variant: Variant in phase["seat_snapshots"]:
		var seat: Dictionary = seat_variant
		seat["observation_seq"] = 2
		seat["decision"]["observation_tick"] = 101
		seat["decision"]["commands_apply_tick"] = 102
		seat["decision"]["valid_until_tick"] = 102
		if with_ceiling:
			seat["maximum_observation_bytes"] = byte_ceiling
	return phase


func _next_visible_phase() -> Dictionary:
	var phase := _standard_phase()
	phase["tick"] = 101
	phase["remaining_match_ticks"] = 17_899
	phase["candidate_events"] = []
	for seat_variant: Variant in phase["seat_snapshots"]:
		var seat: Dictionary = seat_variant
		seat["observation_seq"] = 2
		seat["decision"]["observation_tick"] = 101
		seat["decision"]["commands_apply_tick"] = 102
		seat["decision"]["valid_until_tick"] = 102
	return phase


func _hidden_shop_phase() -> Dictionary:
	var phase := _standard_phase()
	for entity_variant: Variant in phase["entity_snapshots"]:
		var entity: Dictionary = entity_variant
		entity["sight_day_mt"] = 0
		entity["sight_night_mt"] = 0
	return phase


func _hidden_phase(hidden_hp: int) -> Dictionary:
	var phase := _standard_phase()
	phase["candidate_events"] = []
	phase["entity_snapshots"] = [
		_entity(1, 0, [96_250, 114_750], "marshal", ["ground", "hero"], _hero_owned(90)),
		_entity(2, 1, [95_749, 13_249], "marshal", ["ground", "hero"], _hero_owned(hidden_hp)),
	]
	phase["entity_snapshots"][0]["region_id"] = "r_self_home"
	phase["entity_snapshots"][1]["region_id"] = "r_opponent_home"
	phase["entity_snapshots"][0]["sight_day_mt"] = 1_000
	phase["entity_snapshots"][1]["sight_day_mt"] = 1_000
	for seat_variant: Variant in phase["seat_snapshots"]:
		var seat: Dictionary = seat_variant
		seat["local_context_candidates"] = []
		seat["squad_candidates"] = []
		seat["visible_item_candidates"] = []
		seat["visible_shop_candidates"] = []
		seat["own_technology"]["researching"] = []
	return phase


func _seat_snapshot(seat: int) -> Dictionary:
	var structure_id := 3 if seat == 0 else 4
	var hero_id := 1 if seat == 0 else 2
	var own_region := "r_self_natural" if seat == 0 else "r_opponent_natural"
	var raw_bearing := "north" if seat == 0 else "south"
	return {
		"decision": {
			"commands_apply_tick": 101,
			"mode": "fixed_simultaneous",
			"observation_tick": 100,
			"response_deadline_ms": 30_000,
			"valid_until_tick": 101,
		},
		"economy": {
			"cargo_summary": {"gold": 0, "lumber": 0},
			"gold": 700 + seat,
			"gold_income_last_600_ticks": 100,
			"lumber": 300,
			"lumber_income_last_600_ticks": 50,
			"reserved_gold": 50,
			"reserved_lumber": 25,
			"worker_summary": {
				"building": 0,
				"gold": 3,
				"idle": 1,
				"lumber": 1,
				"repairing": 0,
				"total": 5,
			},
		},
		"food": {"cap": 20, "maximum": 100, "reserved": 2, "used": 8},
		"include_brief": true,
		"last_action_receipt": {
			"apply_tick": 99,
			"batch_id": "batch_previous",
			"batch_status": "applied",
			"commands": [{
				"atomic_cost": 1,
				"code": null,
				"command_id": "command_previous",
				"compiled_order_ids": ["order_previous"],
				"status": "applied",
			}],
			"observation_seq": 0,
			"received_tick": 98,
		},
		"local_context_candidates": [{
			"anchor_internal_id": hero_id,
			"detection_radius_mt": 1_500,
			"elevation": 1,
			"exits": [{
				"bearing": raw_bearing,
				"choke_width_mt": 4_000,
				"known_blockage": "clear",
				"path_distance_mt": 30_000,
				"to_region_id": own_region,
			}],
			"nearby_features": [{
				"bearing": "same",
				"kind": "tavern",
				"path_distance_mt": 1_000,
				"site_id": "neutral_center_tavern",
				"state": "open",
			}],
			"retreat_route": [own_region],
			"tactical_slot": "center",
			"terrain": "road",
			"visibility_radius_mt": 6_000,
		}],
		"observation_seq": 1,
		"own_technology": {
			"completed_upgrades": ["steel_weapons_1"],
			"hero_slots": {"available": 3, "used": 1},
			"researching": [{
				"entry": _queue_entry("research_armor", "research", "steel_armor_1"),
				"producer_internal_id": structure_id,
			}],
			"tier": 1,
		},
		"seat": seat,
		"squad_candidates": [{
			"current_order": null,
			"formation": "line",
			"member_internal_ids": [hero_id],
			"retreat_hp_threshold_bp": 2_500,
			"squad_id": "alpha",
			"stance": "defensive",
		}],
		"structure_type_ids": ["garrison"],
		"upkeep": {"gold_delivery_bp": 10_000, "tier": "none"},
		"visible_item_candidates": [{
			"charges": 1,
			"despawn_tick": 800,
			"entity_internal_id": 6,
			"item_type_id": "healing_potion",
			"position_mt": PUBLIC_CENTER_POSITION,
			"region_id": "r_center",
		}],
		"visible_shop_candidates": [{
			"entity_internal_id": 5,
			"offers": [{
				"available": true,
				"cost_gold": 425,
				"cost_lumber": 0,
				"kind": "revival",
				"next_restock_tick": null,
				"offer_id": "field_revive",
				"requires_service_target": true,
				"stock": null,
			}],
			"position_mt": PUBLIC_CENTER_POSITION,
			"region_id": "r_center",
			"shop_type": "tavern",
			"site_id": "neutral_center_tavern",
		}],
		"working_memory": "seat zero plan" if seat == 0 else "seat one plan",
	}


func _entity(
	internal_id: int,
	owner_seat: int,
	position_mt: Array,
	type_id: String,
	tags: Array,
	owned_observation: Dictionary
) -> Dictionary:
	@warning_ignore("integer_division")
	var cell_x: int = int(position_mt[0]) / 500
	@warning_ignore("integer_division")
	var cell_y: int = int(position_mt[1]) / 500
	return {
		"alive": true,
		"detection_radius_mt": 1_500,
		"elevation": 1,
		"facing_mdeg": 0 if owner_seat == 0 else 180_000,
		"hero_level": 2 if tags.has("hero") else null,
		"hp": int(owned_observation.get("hp", 500)),
		"internal_id": internal_id,
		"mana": int(owned_observation.get("mana", 0)),
		"max_hp": int(owned_observation.get("max_hp", 500)),
		"observable_activity": "idle",
		"occupied_cell_ids": [cell_y * 384 + cell_x],
		"owned_observation": owned_observation,
		"owner_seat": owner_seat,
		"position_mt": position_mt.duplicate(),
		"region_id": "r_center",
		"sight_day_mt": 6_000,
		"sight_night_mt": 3_000,
		"tags": tags.duplicate(),
		"type_id": type_id,
		"visible_statuses": [],
	}


func _hero_owned(hp: int) -> Dictionary:
	return {
		"abilities": [{
			"ability_id": "commanding_shout",
			"autocast_enabled": false,
			"cooldown_remaining_ticks": 0,
			"rank": 1,
		}],
		"armor_centi": 250,
		"armor_class": "hero",
		"attack_cooldown_remaining_ticks": 0,
		"attributes": {"agility": 1_500, "intellect": 1_200, "strength": 2_000},
		"cargo": {"amount": 0, "resource": "none"},
		"current_order": null,
		"death_state": "alive",
		"formation_id": "line",
		"hero_level": 2,
		"hp": hp,
		"inventory": [{
			"charges": 1,
			"cooldown_remaining_ticks": 0,
			"item_instance_id": "hero_item_1",
			"item_type_id": "healing_potion",
			"slot": 0,
		}],
		"mana": 100,
		"max_hp": 100,
		"max_mana": 200,
		"movement_state": "idle",
		"queued_orders": [],
		"revival_state": null,
		"selected_by_squad_ids": ["alpha"],
		"skill_points": 1,
		"stance": "defensive",
		"statuses": [],
		"xp": 250,
	}


func _structure_owned() -> Dictionary:
	return {
		"armor_centi": 500,
		"armor_class": "fortified",
		"builder_internal_ids": [],
		"cargo": {"amount": 0, "resource": "none"},
		"class": "structure",
		"construction_progress_bp": 10_000,
		"current_order": null,
		"formation_id": "none",
		"hp": 1_200,
		"mana": 0,
		"max_hp": 1_200,
		"max_mana": 0,
		"movement_state": "rooted",
		"pause_reason": null,
		"producer_queue": [_queue_entry("train_guard", "unit", "footguard")],
		"queued_orders": [],
		"rally_target": PUBLIC_CENTER_POSITION,
		"selected_by_squad_ids": [],
		"stance": "defensive",
		"statuses": [],
	}


func _queue_entry(queue_id: String, kind: String, type_id: String) -> Dictionary:
	return {
		"kind": kind,
		"paused": false,
		"progress_bp": 2_500,
		"queue_entry_id": queue_id,
		"remaining_ticks": 75,
		"reserved_food": 1 if kind == "unit" else 0,
		"reserved_gold": 100,
		"reserved_lumber": 25,
		"type_id": type_id,
	}


func _closed_visibility_grid(source: Dictionary) -> Dictionary:
	return {
		"cell_size_mt": int(source["cell_size_mt"]),
		"elevations": (source["elevations"] as Array).duplicate(),
		"height": int(source["height"]),
		"los_block_heights": (source["los_block_heights"] as Array).duplicate(),
		"region_ids": (source["region_ids"] as Array).duplicate(),
		"terrain_ids": (source["terrain_ids"] as Array).duplicate(),
		"width": int(source["width"]),
	}


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	if not bool(normalized["ok"]) or typeof(normalized["value"]) != TYPE_DICTIONARY:
		return {}
	return normalized["value"]


func _errors(result: Dictionary) -> String:
	var errors: Variant = result.get("errors", [])
	var parts := PackedStringArray()
	for error: Variant in errors:
		parts.append(str(error))
	return "; ".join(parts)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
