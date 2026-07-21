class_name DuelNeutralMarket
extends RefCounted

const NeutralState := preload("res://scripts/duel/neutrals/duel_neutral_state.gd")
const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const BP_ONE := 10_000

var state: NeutralState
var rules: Dictionary = {}
var neutrals: Dictionary = {}
var items: Dictionary = {}
var map_manifest: Dictionary = {}
var protected_tie_key := PackedByteArray()


func configure(
	state_value: NeutralState,
	rules_catalog: Dictionary,
	neutral_catalog: Dictionary,
	item_catalog: Dictionary,
	manifest: Dictionary,
	tie_key: PackedByteArray
) -> PackedStringArray:
	var errors := PackedStringArray()
	if state_value == null:
		errors.append("neutral market requires state")
	if tie_key.is_empty():
		errors.append("neutral market requires a protected tie key")
	for entry: Dictionary in [
		{"catalog": rules_catalog, "fields": ["exclusive_claims", "heroes", "shared_structures"], "label": "rules"},
		{"catalog": neutral_catalog, "fields": ["laboratory_hires", "laboratory_offers", "laboratory_reveal", "tavern"], "label": "neutrals"},
		{"catalog": item_catalog, "fields": ["faction_shop_stock", "items", "merchant_stock"], "label": "items"},
	]:
		for field: String in entry["fields"]:
			if not (entry["catalog"] as Dictionary).has(field):
				errors.append("%s catalog is missing %s" % [entry["label"], field])
	if not manifest.has("neutral_buildings") or not manifest.has("coordinate_system"):
		errors.append("map manifest is missing neutral market data")
	if not errors.is_empty():
		return errors
	state = state_value
	rules = rules_catalog.duplicate(true)
	neutrals = neutral_catalog.duplicate(true)
	items = item_catalog.duplicate(true)
	map_manifest = manifest.duplicate(true)
	protected_tie_key = tie_key.duplicate()
	_initialize_neutral_buildings(errors)
	return errors


func register_faction_shop(
	building_id: String,
	owner_seat: int,
	position_mt: Array,
	completed_tick: int
) -> PackedStringArray:
	var errors := PackedStringArray()
	if building_id.is_empty() or state.buildings.has(building_id):
		errors.append("faction shop ID is empty or already registered")
	if owner_seat not in [0, 1]:
		errors.append("faction shop owner must be seat 0 or 1")
	if not _valid_position(position_mt) or completed_tick < 0:
		errors.append("faction shop position/completion tick is invalid")
	if not errors.is_empty():
		return errors
	var building := {
		"approach_cells": [],
		"building_id": building_id,
		"building_type": "faction_shop",
		"completed_tick": completed_tick,
		"field_revival_last_claim_tick": -1,
		"offers": {},
		"owner_seat": owner_seat,
		"position_mt": [int(position_mt[0]), int(position_mt[1])],
		"region_id": "",
		"tags": ["owned", "shop"],
	}
	for stock_variant: Variant in items["faction_shop_stock"]:
		var stock: Dictionary = stock_variant
		var definition: Dictionary = items["items"][str(stock["offer_id"])]
		_add_offer(building, stock, "item", definition, completed_tick)
	state.buildings[building_id] = building
	return errors


func remove_faction_shop(building_id: String) -> void:
	if state.buildings.has(building_id) \
		and str(state.buildings[building_id].get("building_type", "")) == "faction_shop":
		state.buildings.erase(building_id)


func advance_phase2(tick: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if tick < state.tick:
		errors.append("neutral market cannot move backwards in tick time")
		return errors
	state.tick = tick
	for building_id: String in state.sorted_building_ids():
		var building: Dictionary = state.buildings[building_id]
		var offer_ids: Array = building["offers"].keys()
		offer_ids.sort()
		for offer_id_variant: Variant in offer_ids:
			var offer: Dictionary = building["offers"][offer_id_variant]
			_update_offer_stock(offer, tick)
	var expired_night: Array[String] = []
	for effect_id: String in NeutralState._sorted_string_keys(state.forced_night_effects):
		if tick >= int(state.forced_night_effects[effect_id]["end_tick_exclusive"]):
			expired_night.append(effect_id)
	for effect_id: String in expired_night:
		state.forced_night_effects.erase(effect_id)
	var expired_reveals: Array[String] = []
	for effect_id: String in NeutralState._sorted_string_keys(state.reveal_effects):
		if tick >= int(state.reveal_effects[effect_id]["end_tick_exclusive"]):
			expired_reveals.append(effect_id)
	for effect_id: String in expired_reveals:
		state.reveal_effects.erase(effect_id)
	return errors


func public_offers(building_id: String, tick: int) -> Array[Dictionary]:
	if not state.buildings.has(building_id):
		return []
	if tick >= state.tick:
		advance_phase2(tick)
	var result: Array[Dictionary] = []
	var building: Dictionary = state.buildings[building_id]
	var offer_ids: Array = building["offers"].keys()
	offer_ids.sort()
	for offer_id_variant: Variant in offer_ids:
		var offer: Dictionary = building["offers"][offer_id_variant]
		result.append({
			"available": bool(offer["activated"]) and int(offer["current_stock"]) != 0,
			"cost_gold": int(offer["cost_gold"]),
			"cost_lumber": int(offer["cost_lumber"]),
			"current_stock": int(offer["current_stock"]),
			"initial_tick": int(offer["initial_tick"]),
			"kind": str(offer["kind"]),
			"maximum_stock": int(offer["maximum_stock"]),
			"next_restock_tick": int(offer["next_restock_tick"]),
			"offer_id": str(offer["offer_id"]),
			"requires_service_target": bool(offer["requires_service_target"]),
			"restock_ticks_per_charge": int(offer["restock_ticks_per_charge"]),
		})
	return result


func public_field_revival_offer(
	tavern_id: String,
	tick: int,
	hero_level: int,
	death_tick: int,
	hero_is_dead: bool
) -> Dictionary:
	if not state.buildings.has(tavern_id) \
		or str(state.buildings[tavern_id]["building_type"]) != "tavern" \
		or hero_level < 1 or hero_level > 10:
		return {"available": false, "code": "invalid_target"}
	if tick >= state.tick:
		advance_phase2(tick)
	var revival: Dictionary = rules["heroes"]["revival"]
	var altar_cost := int(revival["altar_base_gold"]) \
		+ int(revival["altar_gold_per_level"]) * hero_level
	@warning_ignore("integer_division")
	var cost := (altar_cost * int(neutrals["tavern"]["field_revival_cost_bp_of_altar"])) / BP_ONE
	var offer: Dictionary = state.buildings[tavern_id]["offers"]["field_revival"]
	var age_legal := hero_is_dead and death_tick >= 0 \
		and tick - death_tick >= int(neutrals["tavern"]["field_revival_available_after_death_ticks"])
	var stock_available := int(offer["current_stock"]) > 0
	return {
		"available": age_legal and stock_available,
		"code": "accepted" if age_legal and stock_available else ("target_unavailable" if age_legal else "prerequisite_missing"),
		"cost_gold": cost,
		"cost_lumber": 0,
		"mana_bp": int(neutrals["tavern"]["field_revival_mana_bp"]),
		"offer_id": "field_revival",
		"return_hp_bp": int(neutrals["tavern"]["field_revival_hp_bp"]),
	}


## Phase-11 API. Claims are already-expanded atomic purchase operations. The
## caller supplies the frozen authoritative player resources and actor facts;
## this method returns exact deltas/handoffs and mutates only neutral authority.
func resolve_shop_claims(
	tick: int,
	claims: Array,
	player_resources: Dictionary
) -> Dictionary:
	if tick < state.tick:
		return {"accepted": [], "errors": ["tick_moved_backwards"], "rejected": [], "resource_deltas": []}
	advance_phase2(tick)
	var results: Dictionary = {}
	var candidates: Array[Dictionary] = []
	var shadow_resources := _copy_player_resources(player_resources)
	var shadow_reveal_cooldowns := {
		0: int(state.reveal_cooldowns.get(0, 0)),
		1: int(state.reveal_cooldowns.get(1, 0)),
	}
	var ordered := _sorted_claims_for_budget(claims)
	for claim: Dictionary in ordered:
		var claim_id := str(claim.get("claim_id", ""))
		if claim_id.is_empty() or results.has(claim_id):
			continue
		var legality := _validate_shop_claim(tick, claim, shadow_resources, shadow_reveal_cooldowns)
		if not bool(legality["ok"]):
			results[claim_id] = _claim_result(claim_id, false, str(legality["code"]), {}, {})
			continue
		var candidate := claim.duplicate(true)
		candidate["cost_gold"] = int(legality["offer"]["cost_gold"])
		candidate["cost_lumber"] = int(legality["offer"]["cost_lumber"])
		candidate["offer_kind"] = str(legality["offer"]["kind"])
		candidate["internal_actor_id"] = int(claim.get("buyer_internal_id", 0))
		candidate["canonical_command_digest"] = str(claim.get("canonical_command_digest", ""))
		candidates.append(candidate)
		var seat := int(claim["owner_seat"])
		shadow_resources[seat]["gold"] -= int(candidate["cost_gold"])
		shadow_resources[seat]["lumber"] -= int(candidate["cost_lumber"])
		if str(claim["offer_id"]) == "laboratory_reveal":
			shadow_reveal_cooldowns[seat] = tick + int(neutrals["laboratory_reveal"]["per_player_cooldown_ticks"])

	var winners := _resolve_offer_capacity(tick, candidates)
	var winner_ids: Dictionary = {}
	for winner: Dictionary in winners:
		winner_ids[str(winner["claim_id"])] = winner
	var resource_delta_by_seat := {
		0: {"gold": 0, "lumber": 0, "seat": 0},
		1: {"gold": 0, "lumber": 0, "seat": 1},
	}
	candidates.sort_custom(_claim_id_less)
	for candidate: Dictionary in candidates:
		var claim_id := str(candidate["claim_id"])
		if not winner_ids.has(claim_id):
			results[claim_id] = _claim_result(claim_id, false, "target_unavailable", {}, {})
			continue
		var building: Dictionary = state.buildings[str(candidate["building_id"])]
		var offer: Dictionary = building["offers"][str(candidate["offer_id"])]
		_consume_offer_charge(offer, tick)
		var seat := int(candidate["owner_seat"])
		resource_delta_by_seat[seat]["gold"] -= int(candidate["cost_gold"])
		resource_delta_by_seat[seat]["lumber"] -= int(candidate["cost_lumber"])
		var handoff := _accepted_shop_handoff(tick, candidate, building, offer)
		var charge := {"gold": int(candidate["cost_gold"]), "lumber": int(candidate["cost_lumber"])}
		results[claim_id] = _claim_result(claim_id, true, "accepted", charge, handoff)
		state.append_event("neutral_offer_purchased", str(candidate["building_id"]), claim_id, {
			"offer_id": str(candidate["offer_id"]), "owner_seat": seat,
		})

	var all_claims: Array[Dictionary] = []
	for claim: Dictionary in claims:
		var claim_id := str(claim.get("claim_id", ""))
		if not claim_id.is_empty() and not results.has(claim_id):
			results[claim_id] = _claim_result(claim_id, false, "invalid_request", {}, {})
	for claim_id: String in NeutralState._sorted_string_keys(results):
		all_claims.append(results[claim_id])
	var accepted: Array[Dictionary] = []
	var rejected: Array[Dictionary] = []
	for result: Dictionary in all_claims:
		(accepted if bool(result["accepted"]) else rejected).append(result)
	return {
		"accepted": accepted,
		"errors": [],
		"rejected": rejected,
		"resource_deltas": [resource_delta_by_seat[0], resource_delta_by_seat[1]],
	}


## Phase-11 handoff for the central Tavern. One field-revival slot exists per
## Tavern and tick. Hero ownership/death facts come from the frozen Hero state.
func resolve_field_revival_claims(
	tick: int,
	claims: Array,
	player_resources: Dictionary
) -> Dictionary:
	if tick < state.tick:
		return {"accepted": [], "rejected": [], "resource_deltas": [], "errors": ["tick_moved_backwards"]}
	advance_phase2(tick)
	var shadow := _copy_player_resources(player_resources)
	var candidates: Array[Dictionary] = []
	var results: Dictionary = {}
	for claim: Dictionary in _sorted_claims_for_budget(claims):
		var claim_id := str(claim.get("claim_id", ""))
		if claim_id.is_empty() or results.has(claim_id):
			continue
		var validation := _validate_field_revival_claim(tick, claim, shadow)
		if not bool(validation["ok"]):
			results[claim_id] = _claim_result(claim_id, false, str(validation["code"]), {}, {})
			continue
		var candidate := claim.duplicate(true)
		candidate["cost_gold"] = int(validation["cost_gold"])
		candidate["internal_actor_id"] = int(claim["hero_internal_id"])
		candidate["canonical_command_digest"] = str(claim["canonical_command_digest"])
		candidates.append(candidate)
		shadow[int(claim["owner_seat"])]["gold"] -= int(candidate["cost_gold"])

	var winners: Array[Dictionary] = []
	var grouped: Dictionary = {}
	for candidate: Dictionary in candidates:
		var tavern_id := str(candidate["tavern_id"])
		if not grouped.has(tavern_id):
			grouped[tavern_id] = []
		grouped[tavern_id].append(candidate)
	for tavern_id: String in NeutralState._sorted_string_keys(grouped):
		winners.append_array(_rank_capacity(tick, "field_revival_slot", tavern_id, grouped[tavern_id], 1))
	var winner_ids: Dictionary = {}
	for winner: Dictionary in winners:
		winner_ids[str(winner["claim_id"])] = true
	var deltas := {0: {"gold": 0, "lumber": 0, "seat": 0}, 1: {"gold": 0, "lumber": 0, "seat": 1}}
	candidates.sort_custom(_claim_id_less)
	for candidate: Dictionary in candidates:
		var claim_id := str(candidate["claim_id"])
		if not winner_ids.has(claim_id):
			results[claim_id] = _claim_result(claim_id, false, "target_unavailable", {}, {})
			continue
		var seat := int(candidate["owner_seat"])
		var cost := int(candidate["cost_gold"])
		deltas[seat]["gold"] -= cost
		var tavern: Dictionary = state.buildings[str(candidate["tavern_id"])]
		_consume_offer_charge(tavern["offers"]["field_revival"], tick)
		tavern["field_revival_last_claim_tick"] = tick
		var handoff := {
			"hero_internal_id": int(candidate["hero_internal_id"]),
			"kind": "field_revive_hero",
			"mana_bp": int(neutrals["tavern"]["field_revival_mana_bp"]),
			"position_mt": tavern["position_mt"].duplicate(),
			"return_hp_bp": int(neutrals["tavern"]["field_revival_hp_bp"]),
			"tavern_id": str(candidate["tavern_id"]),
		}
		results[claim_id] = _claim_result(claim_id, true, "accepted", {"gold": cost, "lumber": 0}, handoff)
		state.append_event("field_revival_claimed", str(candidate["tavern_id"]), claim_id, {
			"hero_internal_id": int(candidate["hero_internal_id"]), "owner_seat": seat,
		})
	for claim: Dictionary in claims:
		var claim_id := str(claim.get("claim_id", ""))
		if not claim_id.is_empty() and not results.has(claim_id):
			results[claim_id] = _claim_result(claim_id, false, "invalid_request", {}, {})
	return _partition_results(results, [deltas[0], deltas[1]])


func active_reveal_sources(tick: int, owner_seat: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for effect_id: String in NeutralState._sorted_string_keys(state.reveal_effects):
		var effect: Dictionary = state.reveal_effects[effect_id]
		if int(effect["owner_seat"]) == owner_seat \
			and tick >= int(effect["start_tick"]) and tick < int(effect["end_tick_exclusive"]):
			result.append(effect.duplicate(true))
	return result


func _initialize_neutral_buildings(errors: PackedStringArray) -> void:
	for building_variant: Variant in map_manifest["neutral_buildings"]:
		var source: Dictionary = building_variant
		var building_id := str(source["id"])
		var building_type := str(source["building_type"])
		var building := {
			"approach_cells": source["approach_cells"].duplicate(true),
			"building_id": building_id,
			"building_type": building_type,
			"completed_tick": 0,
			"field_revival_last_claim_tick": -1,
			"offers": {},
			"owner_seat": -1,
			"position_mt": source["position_mt"].duplicate(),
			"region_id": str(source["region_id"]),
			"tags": source["tags"].duplicate(),
		}
		match building_type:
			"merchant":
				for stock_variant: Variant in items["merchant_stock"]:
					var stock: Dictionary = stock_variant
					var offer_id := str(stock["offer_id"])
					if not items["items"].has(offer_id):
						errors.append("merchant references unknown item %s" % offer_id)
						continue
					_add_offer(building, stock, "item", items["items"][offer_id], 0)
			"laboratory":
				for stock_variant: Variant in neutrals["laboratory_offers"]:
					var stock: Dictionary = stock_variant
					var offer_id := str(stock["offer_id"])
					var definition: Dictionary = {}
					if str(stock["kind"]) == "unit":
						if not neutrals["laboratory_hires"].has(offer_id):
							errors.append("laboratory references unknown hire %s" % offer_id)
							continue
						definition = neutrals["laboratory_hires"][offer_id]
					_add_offer(building, stock, str(stock["kind"]), definition, 0)
			"tavern":
				building["offers"]["field_revival"] = {
					"activated": true,
					"cost_gold": 0,
					"cost_lumber": 0,
					"current_stock": 1,
					"initial_tick": 0,
					"kind": "service",
					"maximum_stock": 1,
					"next_restock_tick": -1,
					"offer_id": "field_revival",
					"requires_service_target": true,
					"restock_ticks_per_charge": 1,
				}
			_:
				errors.append("unsupported neutral building type %s" % building_type)
		state.buildings[building_id] = building


func _add_offer(
	building: Dictionary,
	stock: Dictionary,
	kind: String,
	definition: Dictionary,
	base_tick: int
) -> void:
	var offer_id := str(stock["offer_id"])
	var maximum := int(stock["stock"])
	var initial_tick := base_tick + int(stock["initial_tick"])
	var cost_gold := int(stock.get("cost_gold", definition.get("cost_gold", 0)))
	var cost_lumber := int(stock.get("cost_lumber", definition.get("cost_lumber", 0)))
	building["offers"][offer_id] = {
		"activated": initial_tick == 0,
		"cost_gold": cost_gold,
		"cost_lumber": cost_lumber,
		"current_stock": maximum if initial_tick == 0 else 0,
		"initial_tick": initial_tick,
		"kind": kind,
		"maximum_stock": maximum,
		"next_restock_tick": -1,
		"offer_id": offer_id,
		"requires_service_target": bool(stock.get("requires_service_target", false)),
		"restock_ticks_per_charge": int(stock["restock_ticks_per_charge"]),
	}


func _update_offer_stock(offer: Dictionary, tick: int) -> void:
	if not bool(offer["activated"]) and tick >= int(offer["initial_tick"]):
		offer["activated"] = true
		offer["current_stock"] = int(offer["maximum_stock"])
		offer["next_restock_tick"] = -1
	if not bool(offer["activated"]) or int(offer["maximum_stock"]) < 0:
		return
	var restock_ticks := int(offer["restock_ticks_per_charge"])
	while int(offer["current_stock"]) < int(offer["maximum_stock"]) \
		and restock_ticks > 0 and int(offer["next_restock_tick"]) >= 0 \
		and tick >= int(offer["next_restock_tick"]):
		offer["current_stock"] += 1
		if int(offer["current_stock"]) < int(offer["maximum_stock"]):
			offer["next_restock_tick"] += restock_ticks
		else:
			offer["next_restock_tick"] = -1


func _consume_offer_charge(offer: Dictionary, tick: int) -> void:
	if int(offer["maximum_stock"]) < 0:
		return
	offer["current_stock"] -= 1
	if int(offer["next_restock_tick"]) < 0 and int(offer["restock_ticks_per_charge"]) > 0:
		offer["next_restock_tick"] = tick + int(offer["restock_ticks_per_charge"])


func _validate_shop_claim(
	tick: int,
	claim: Dictionary,
	shadow_resources: Dictionary,
	shadow_cooldowns: Dictionary
) -> Dictionary:
	for field: String in ["claim_id", "building_id", "offer_id", "canonical_command_digest"]:
		if not claim.has(field) or typeof(claim[field]) != TYPE_STRING or str(claim[field]).is_empty():
			return {"code": "invalid_request", "ok": false}
	if not claim.has("owner_seat") or typeof(claim["owner_seat"]) != TYPE_INT \
		or int(claim["owner_seat"]) not in [0, 1]:
		return {"code": "invalid_actor", "ok": false}
	if not claim.has("buyer_internal_id") or typeof(claim["buyer_internal_id"]) != TYPE_INT \
		or int(claim["buyer_internal_id"]) <= 0:
		return {"code": "invalid_actor", "ok": false}
	if str(claim["canonical_command_digest"]).length() != 64:
		return {"code": "invalid_request", "ok": false}
	var building_id := str(claim["building_id"])
	if not state.buildings.has(building_id):
		return {"code": "target_unavailable", "ok": false}
	var building: Dictionary = state.buildings[building_id]
	if str(building["building_type"]) not in ["merchant", "laboratory", "faction_shop"]:
		return {"code": "invalid_target", "ok": false}
	if str(building["building_type"]) == "faction_shop" \
		and int(building["owner_seat"]) != int(claim["owner_seat"]):
		return {"code": "not_owned", "ok": false}
	if not bool(claim.get("buyer_owned", false)) or not bool(claim.get("buyer_alive", false)):
		return {"code": "invalid_actor", "ok": false}
	if not bool(claim.get("shop_visible", false)) or not bool(claim.get("interaction_legal", false)):
		return {"code": "target_unavailable", "ok": false}
	var offer_id := str(claim["offer_id"])
	if not building["offers"].has(offer_id):
		return {"code": "unknown_catalog_id", "ok": false}
	var offer: Dictionary = building["offers"][offer_id]
	if not bool(offer["activated"]) or int(offer["current_stock"]) == 0:
		return {"code": "target_unavailable", "ok": false}
	var buyer_tags: Array = claim.get("buyer_tags", [])
	if str(offer["kind"]) == "item" and "hero" not in buyer_tags:
		return {"code": "invalid_actor", "ok": false}
	if str(building["building_type"]) == "laboratory" and not ("hero" in buyer_tags or "worker" in buyer_tags):
		return {"code": "invalid_actor", "ok": false}
	var seat := int(claim["owner_seat"])
	if int(shadow_resources[seat]["gold"]) < int(offer["cost_gold"]) \
		or int(shadow_resources[seat]["lumber"]) < int(offer["cost_lumber"]):
		return {"code": "insufficient_resources", "ok": false}
	if offer_id == "laboratory_reveal":
		if tick < int(shadow_cooldowns[seat]):
			return {"code": "cooldown_active", "ok": false}
		if not _valid_position(claim.get("buyer_position_mt", [])) \
			or not _valid_position(claim.get("service_target_xy_mt", [])):
			return {"code": "invalid_target", "ok": false}
		var buyer: Array = claim["buyer_position_mt"]
		var target: Array = claim["service_target_xy_mt"]
		var maximum: Array = map_manifest["coordinate_system"]["bounds_mt"]["max_exclusive"]
		if int(target[0]) < 0 or int(target[1]) < 0 \
			or int(target[0]) >= int(maximum[0]) or int(target[1]) >= int(maximum[1]):
			return {"code": "invalid_target", "ok": false}
		var range_mt := int(neutrals["laboratory_reveal"]["buyer_range_mt"])
		if _distance_squared(buyer, building["position_mt"]) > range_mt * range_mt:
			return {"code": "target_unavailable", "ok": false}
	return {"code": "accepted", "offer": offer, "ok": true}


func _resolve_offer_capacity(tick: int, candidates: Array[Dictionary]) -> Array[Dictionary]:
	var grouped: Dictionary = {}
	for candidate: Dictionary in candidates:
		var group_id := "%s|%s" % [candidate["building_id"], candidate["offer_id"]]
		if not grouped.has(group_id):
			grouped[group_id] = []
		grouped[group_id].append(candidate)
	var winners: Array[Dictionary] = []
	for group_id: String in NeutralState._sorted_string_keys(grouped):
		var group: Array = grouped[group_id]
		var first: Dictionary = group[0]
		var offer: Dictionary = state.buildings[str(first["building_id"])]["offers"][str(first["offer_id"])]
		var capacity := int(offer["current_stock"])
		if capacity < 0:
			group.sort_custom(_claim_id_less)
			winners.append_array(group)
		else:
			winners.append_array(_rank_capacity(tick, "shop_or_hire_charge", group_id, group, capacity))
	return winners


func _rank_capacity(
	tick: int,
	claim_kind: String,
	object_id: String,
	claims: Array,
	capacity: int
) -> Array[Dictionary]:
	var remaining: Array[Dictionary] = []
	for claim_variant: Variant in claims:
		remaining.append((claim_variant as Dictionary).duplicate(true))
	var winners: Array[Dictionary] = []
	for charge_index: int in mini(capacity, remaining.size()):
		var group_key := "%d|%s|%s|%d" % [tick, claim_kind, object_id, charge_index]
		var ranked := KeyedRandom.rank_claimants(protected_tie_key, group_key, remaining)
		var winner: Dictionary = ranked[0]
		winners.append(winner)
		var audit_ranking: Array = []
		for ranked_claim: Dictionary in ranked:
			audit_ranking.append({
				"claim_id": str(ranked_claim["claim_id"]),
				"rank_digest": str(ranked_claim["rank_digest"]),
			})
		state.contest_audit.append({
			"charge_index": charge_index,
			"claim_kind": claim_kind,
			"group_key": group_key,
			"object_id": object_id,
			"ranking": audit_ranking,
			"tick": tick,
			"winner_claim_id": str(winner["claim_id"]),
		})
		var next_remaining: Array[Dictionary] = []
		for candidate: Dictionary in remaining:
			if str(candidate["claim_id"]) != str(winner["claim_id"]):
				next_remaining.append(candidate)
		remaining = next_remaining
	return winners


func _accepted_shop_handoff(
	tick: int,
	claim: Dictionary,
	building: Dictionary,
	offer: Dictionary
) -> Dictionary:
	var offer_id := str(claim["offer_id"])
	match str(offer["kind"]):
		"item":
			return {
				"buyer_internal_id": int(claim["buyer_internal_id"]),
				"item_definition": items["items"][offer_id].duplicate(true),
				"item_type_id": offer_id,
				"kind": "grant_purchased_item",
			}
		"unit":
			return {
				"hire_definition": neutrals["laboratory_hires"][offer_id].duplicate(true),
				"hire_type_id": offer_id,
				"kind": "spawn_hired_unit",
				"owner_seat": int(claim["owner_seat"]),
				"spawn_approach_cells": building["approach_cells"].duplicate(true),
			}
		"service":
			var reveal: Dictionary = neutrals["laboratory_reveal"]
			var effect_id := state.allocate_reveal_effect_id()
			var effect := {
				"detection": bool(reveal["provides_detection"]),
				"effect_id": effect_id,
				"end_tick_exclusive": tick + int(reveal["last_tick_offset"]) + 1,
				"normal_knowledge_update": bool(reveal["uses_normal_knowledge_update"]),
				"owner_seat": int(claim["owner_seat"]),
				"position_mt": claim["service_target_xy_mt"].duplicate(),
				"radius_mt": int(reveal["radius_mt"]),
				"sight": bool(reveal["provides_sight"]),
				"source_building_id": str(claim["building_id"]),
				"start_tick": tick + int(reveal["first_tick_offset"]),
			}
			state.reveal_effects[effect_id] = effect
			state.reveal_cooldowns[int(claim["owner_seat"])] = tick + int(reveal["per_player_cooldown_ticks"])
			return {"kind": "create_private_reveal_source", "reveal_source": effect.duplicate(true)}
	return {"kind": "none"}


func _validate_field_revival_claim(tick: int, claim: Dictionary, shadow: Dictionary) -> Dictionary:
	for field: String in ["claim_id", "tavern_id", "canonical_command_digest"]:
		if not claim.has(field) or typeof(claim[field]) != TYPE_STRING or str(claim[field]).is_empty():
			return {"code": "invalid_request", "ok": false}
	for field: String in ["owner_seat", "hero_owner_seat", "hero_internal_id", "hero_level", "death_tick"]:
		if not claim.has(field) or typeof(claim[field]) != TYPE_INT:
			return {"code": "invalid_request", "ok": false}
	var seat := int(claim["owner_seat"])
	if seat not in [0, 1] or int(claim["hero_owner_seat"]) != seat:
		return {"code": "not_owned", "ok": false}
	if int(claim["hero_internal_id"]) <= 0 or int(claim["hero_level"]) < 1 or int(claim["hero_level"]) > 10:
		return {"code": "invalid_target", "ok": false}
	if bool(claim.get("hero_alive", true)) or bool(claim.get("already_reviving", false)):
		return {"code": "invalid_target", "ok": false}
	var tavern_id := str(claim["tavern_id"])
	if not state.buildings.has(tavern_id) \
		or str(state.buildings[tavern_id]["building_type"]) != "tavern" \
		or not bool(claim.get("tavern_visible", false)):
		return {"code": "target_unavailable", "ok": false}
	if int(state.buildings[tavern_id].get("field_revival_last_claim_tick", -1)) == tick:
		return {"code": "target_unavailable", "ok": false}
	if int(state.buildings[tavern_id]["offers"]["field_revival"]["current_stock"]) <= 0:
		return {"code": "target_unavailable", "ok": false}
	if tick - int(claim["death_tick"]) < int(neutrals["tavern"]["field_revival_available_after_death_ticks"]):
		return {"code": "prerequisite_missing", "ok": false}
	var revival: Dictionary = rules["heroes"]["revival"]
	var altar_cost := int(revival["altar_base_gold"]) \
		+ int(revival["altar_gold_per_level"]) * int(claim["hero_level"])
	@warning_ignore("integer_division")
	var cost := (altar_cost * int(neutrals["tavern"]["field_revival_cost_bp_of_altar"])) / BP_ONE
	if int(shadow[seat]["gold"]) < cost:
		return {"code": "insufficient_resources", "ok": false}
	return {"code": "accepted", "cost_gold": cost, "ok": true}


static func _partition_results(results: Dictionary, deltas: Array) -> Dictionary:
	var accepted: Array[Dictionary] = []
	var rejected: Array[Dictionary] = []
	for claim_id: String in NeutralState._sorted_string_keys(results):
		var result: Dictionary = results[claim_id]
		(accepted if bool(result["accepted"]) else rejected).append(result)
	return {"accepted": accepted, "errors": [], "rejected": rejected, "resource_deltas": deltas}


static func _claim_result(
	claim_id: String,
	accepted: bool,
	code: String,
	charge: Dictionary,
	handoff: Dictionary
) -> Dictionary:
	return {
		"accepted": accepted,
		"charge": charge.duplicate(true),
		"claim_id": claim_id,
		"code": code,
		"handoff": handoff.duplicate(true),
	}


static func _copy_player_resources(source: Dictionary) -> Dictionary:
	var result := {}
	for seat: int in [0, 1]:
		var record: Dictionary = source.get(seat, source.get(str(seat), {}))
		result[seat] = {
			"gold": int(record.get("gold", 0)),
			"lumber": int(record.get("lumber", 0)),
		}
	return result


static func _sorted_claims_for_budget(claims: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for claim: Dictionary in claims:
		result.append(claim.duplicate(true))
	result.sort_custom(_budget_claim_less)
	return result


static func _budget_claim_less(left: Dictionary, right: Dictionary) -> bool:
	var left_key := [
		int(left.get("owner_seat", -1)),
		int(left.get("command_index", 0)),
		str(left.get("claim_id", "")),
	]
	var right_key := [
		int(right.get("owner_seat", -1)),
		int(right.get("command_index", 0)),
		str(right.get("claim_id", "")),
	]
	return left_key < right_key


static func _claim_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("claim_id", "")) < str(right.get("claim_id", ""))


static func _valid_position(value: Variant) -> bool:
	return typeof(value) == TYPE_ARRAY and (value as Array).size() == 2 \
		and typeof(value[0]) == TYPE_INT and typeof(value[1]) == TYPE_INT


static func _distance_squared(left: Array, right: Array) -> int:
	var dx := int(left[0]) - int(right[0])
	var dy := int(left[1]) - int(right[1])
	return dx * dx + dy * dy
