class_name DuelNeutralWorld
extends RefCounted

const NeutralState := preload("res://scripts/duel/neutrals/duel_neutral_state.gd")
const NeutralMarket := preload("res://scripts/duel/neutrals/duel_neutral_market.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")

const MAP_PATH := "res://../game/duel_protocol/maps/crossroads-duel-v1.json"
const MAP_RELATIVE_PATH := "maps/crossroads-duel-v1.json"
const PROTOCOL_LOCK_PATH := "res://../game/duel_protocol/protocol-lock.json"

var state := NeutralState.new()
var market := NeutralMarket.new()
var rules: Dictionary = {}
var neutrals: Dictionary = {}
var items: Dictionary = {}
var map_manifest: Dictionary = {}
var protected_tie_key := PackedByteArray()


## Loads only allowlisted, protocol-locked artifacts. No caller-provided path or
## catalog can enter this authority boundary.
func configure_official(match_seed: int, tie_key: PackedByteArray) -> PackedStringArray:
	var errors := PackedStringArray()
	if match_seed < 0:
		errors.append("match_seed must be non-negative")
	if tie_key.is_empty():
		errors.append("protected tie key must not be empty")
	if not errors.is_empty():
		return errors
	var loaded := CatalogLoader.load_official_catalogs()
	if not bool(loaded["ok"]):
		errors.append_array(loaded["errors"])
		return errors
	var map_result := _load_locked_map()
	if not bool(map_result["ok"]):
		errors.append_array(map_result["errors"])
		return errors

	state.reset()
	rules = loaded["catalogs"]["rules"].duplicate(true)
	neutrals = loaded["catalogs"]["neutrals"].duplicate(true)
	items = loaded["catalogs"]["items"].duplicate(true)
	map_manifest = map_result["manifest"].duplicate(true)
	protected_tie_key = tie_key.duplicate()
	state.enabled = true
	state.match_seed = match_seed
	state.ruleset_hash = str(loaded["canonical_hashes"]["rules"])
	state.protected_tie_key_commitment = Codec.sha256_bytes(tie_key)
	state.map_id = str(map_manifest["map_id"])
	state.map_raw_hash = str(map_result["raw_hash"])
	state.catalog_hashes = {
		"items": str(loaded["canonical_hashes"]["items"]),
		"neutrals": str(loaded["canonical_hashes"]["neutrals"]),
		"rules": str(loaded["canonical_hashes"]["rules"]),
	}
	_initialize_camps(errors)
	_initialize_expansions(errors)
	errors.append_array(_validate_locked_neutral_data())
	if not errors.is_empty():
		state.enabled = false
		return errors
	errors.append_array(market.configure(
		state, rules, neutrals, items, map_manifest, protected_tie_key
	))
	return errors


func advance_phase2(tick: int) -> PackedStringArray:
	return market.advance_phase2(tick)


func day_phase(tick: int) -> Dictionary:
	var schedule: Dictionary = rules["day_night"]
	var cycle_ticks := int(schedule["cycle_ticks"])
	var cycle_tick := (tick + int(schedule["start_cycle_tick"])) % cycle_ticks
	var underlying := "day" if cycle_tick < int(schedule["day_ticks"]) else "night"
	var forcing_effects: Array[String] = []
	for effect_id: String in NeutralState._sorted_string_keys(state.forced_night_effects):
		var effect: Dictionary = state.forced_night_effects[effect_id]
		if tick >= int(effect["start_tick"]) and tick < int(effect["end_tick_exclusive"]):
			forcing_effects.append(effect_id)
	return {
		"cycle_index": tick / cycle_ticks,
		"cycle_tick": cycle_tick,
		"forced": not forcing_effects.is_empty(),
		"forcing_effect_ids": forcing_effects,
		"phase": "night" if not forcing_effects.is_empty() else underlying,
		"underlying_phase": underlying,
	}


func add_forced_night(effect_id: String, start_tick: int, end_tick_exclusive: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if effect_id.is_empty() or state.forced_night_effects.has(effect_id):
		errors.append("forced-night effect ID is empty or already exists")
	if start_tick < state.tick or end_tick_exclusive <= start_tick:
		errors.append("forced-night interval is invalid")
	if not errors.is_empty():
		return errors
	state.forced_night_effects[effect_id] = {
		"effect_id": effect_id,
		"end_tick_exclusive": end_tick_exclusive,
		"start_tick": start_tick,
	}
	return errors


func creep_spawn_descriptors() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for camp_id: String in state.sorted_camp_ids():
		var camp: Dictionary = state.camps[camp_id]
		for member_id: String in NeutralState._sorted_string_keys(camp["members"]):
			var member: Dictionary = camp["members"][member_id]
			result.append({
				"camp_id": camp_id,
				"catalog_definition": neutrals["units"][str(member["neutral_id"])].duplicate(true),
				"formation": str(camp["formation"]),
				"member_id": member_id,
				"neutral_id": str(member["neutral_id"]),
				"owner_seat": -1,
				"position_mt": member["spawn_position_mt"].duplicate(),
				"region_id": str(camp["region_id"]),
			})
	return result


func camp_registry(include_dynamic_state: bool = true) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for camp_id: String in state.sorted_camp_ids():
		var camp: Dictionary = state.camps[camp_id]
		var record := {
			"anchor_cell": camp["anchor_cell"].duplicate(),
			"camp_id": camp_id,
			"formation": str(camp["formation"]),
			"gold_bounty": int(camp["gold_bounty"]),
			"leash_radius_mt": int(camp["leash_radius_mt"]),
			"position_mt": camp["position_mt"].duplicate(),
			"region_id": str(camp["region_id"]),
			"tier": str(camp["tier"]),
			"total_level": int(camp["total_level"]),
		}
		if include_dynamic_state:
			record["clear_tick"] = int(camp["clear_tick"])
			record["status"] = str(camp["status"])
		result.append(record)
	return result


func bind_member_entity(camp_id: String, member_id: String, internal_id: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if not state.camps.has(camp_id) or not state.camps[camp_id]["members"].has(member_id):
		errors.append("unknown camp member")
	elif internal_id <= 0:
		errors.append("neutral member internal ID must be positive")
	else:
		for other_camp_id: String in state.sorted_camp_ids():
			for other_member_id: String in NeutralState._sorted_string_keys(state.camps[other_camp_id]["members"]):
				if int(state.camps[other_camp_id]["members"][other_member_id]["internal_id"]) == internal_id:
					errors.append("neutral member internal ID is already bound")
	if errors.is_empty():
		state.camps[camp_id]["members"][member_id]["internal_id"] = internal_id
	return errors


func relocate_bound_member_spawn(
	camp_id: String,
	member_id: String,
	internal_id: int,
	position_mt: Array
) -> PackedStringArray:
	## Authored formation anchors can have overlapping catalog footprints. The
	## protected bootstrap deterministically expands only those colliding members
	## outward, then records the resolved spawn here so leash/reset behavior and
	## checkpoints use the actual legal authoritative position.
	var errors := PackedStringArray()
	if state.tick != 0:
		errors.append("neutral spawn relocation is only legal at tick zero")
	if not state.camps.has(camp_id) or not state.camps[camp_id]["members"].has(member_id):
		errors.append("unknown camp member")
	elif int(state.camps[camp_id]["members"][member_id].get("internal_id", 0)) != internal_id:
		errors.append("neutral spawn relocation binding does not match")
	if not _valid_position(position_mt):
		errors.append("neutral spawn relocation position is invalid")
	elif int(position_mt[0]) < 0 or int(position_mt[1]) < 0 \
		or int(position_mt[0]) >= int(map_manifest["coordinate_system"]["bounds_mt"]["max_exclusive"][0]) \
		or int(position_mt[1]) >= int(map_manifest["coordinate_system"]["bounds_mt"]["max_exclusive"][1]):
		errors.append("neutral spawn relocation position is outside the map")
	if not errors.is_empty():
		return errors
	var member: Dictionary = state.camps[camp_id]["members"][member_id]
	member["position_mt"] = position_mt.duplicate()
	member["spawn_position_mt"] = position_mt.duplicate()
	return errors


## Synchronizes the frozen combat/movement snapshot before phase 3. Only
## explicit integer fields are accepted; no engine Transform enters state.
func synchronize_member(camp_id: String, member_id: String, snapshot: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not state.camps.has(camp_id) or not state.camps[camp_id]["members"].has(member_id):
		errors.append("unknown camp member")
		return errors
	for field: String in ["hp", "max_hp"]:
		if not snapshot.has(field) or typeof(snapshot[field]) != TYPE_INT:
			errors.append("member snapshot %s must be an integer" % field)
	if not snapshot.has("alive") or typeof(snapshot["alive"]) != TYPE_BOOL:
		errors.append("member snapshot alive must be boolean")
	if not _valid_position(snapshot.get("position_mt", [])):
		errors.append("member snapshot position_mt is invalid")
	if not errors.is_empty():
		return errors
	var member: Dictionary = state.camps[camp_id]["members"][member_id]
	var hp := int(snapshot["hp"])
	var maximum := int(snapshot["max_hp"])
	if maximum <= 0 or hp < 0 or hp > maximum or (not bool(snapshot["alive"]) and hp != 0):
		errors.append("member snapshot HP/alive combination is invalid")
		return errors
	member["alive"] = bool(snapshot["alive"])
	member["hp"] = hp
	member["max_hp"] = maximum
	member["position_mt"] = [int(snapshot["position_mt"][0]), int(snapshot["position_mt"][1])]
	return errors


func note_member_damaged(camp_id: String, member_id: String, tick: int) -> void:
	if state.camps.has(camp_id) and state.camps[camp_id]["members"].has(member_id):
		state.camps[camp_id]["members"][member_id]["last_damaged_tick"] = tick


func record_camp_damage(
	camp_id: String,
	owner_seat: int,
	source_internal_id: int,
	post_mitigation_damage: int,
	command_digest: String
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not state.camps.has(camp_id):
		errors.append("unknown camp")
	if owner_seat not in [0, 1] or source_internal_id <= 0 or post_mitigation_damage <= 0:
		errors.append("camp damage attribution is invalid")
	if command_digest.length() != 64:
		errors.append("camp damage command digest must be SHA-256 hex")
	if not errors.is_empty():
		return errors
	var damage: Dictionary = state.camps[camp_id]["damage_by_seat"][owner_seat]
	damage["total"] += post_mitigation_damage
	damage["records"].append({
		"amount": post_mitigation_damage,
		"command_digest": command_digest,
		"source_internal_id": source_internal_id,
	})
	return errors


func register_camp_summon(camp_id: String, internal_id: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if not state.camps.has(camp_id) or internal_id <= 0:
		errors.append("camp summon registration is invalid")
		return errors
	state.camps[camp_id]["summons"][str(internal_id)] = {
		"alive": true, "internal_id": internal_id,
	}
	return errors


func synchronize_camp_summon(camp_id: String, internal_id: int, alive: bool) -> void:
	if state.camps.has(camp_id) and state.camps[camp_id]["summons"].has(str(internal_id)):
		state.camps[camp_id]["summons"][str(internal_id)]["alive"] = alive


## Phase-3 API. Contacts must come from the authoritative world snapshot and
## include position/path facts. Returned intents are applied by movement/combat;
## this subsystem never calls those systems directly.
func compile_camp_intents(tick: int, contacts_by_camp: Dictionary) -> Array[Dictionary]:
	if tick < state.tick:
		return []
	advance_phase2(tick)
	var phase := day_phase(tick)
	var intents: Array[Dictionary] = []
	for camp_id: String in state.sorted_camp_ids():
		var camp: Dictionary = state.camps[camp_id]
		if str(camp["status"]) == "cleared":
			continue
		var contacts: Array[Dictionary] = _legal_contacts(camp, contacts_by_camp.get(camp_id, []))
		var damaged_now := _camp_damaged_at(camp, tick)
		var is_night := str(phase["phase"]) == "night"
		var wake_radius := int(neutrals["camp_behavior"]["night_sleeping_wake_radius_mt"])
		var aggro_radius := int(neutrals["camp_behavior"]["day_aggro_radius_mt"])
		var initial_radius := wake_radius if is_night else aggro_radius
		var wake_contact := _has_contact_inside(camp["position_mt"], contacts, initial_radius)
		var was_engaged := str(camp["status"]) == "engaged"
		var was_returning := str(camp["status"]) == "returning"
		var group_awake := not is_night or damaged_now or wake_contact or was_engaged
		if is_night and not group_awake and not was_returning:
			camp["awake"] = false
			camp["status"] = "sleeping"
			_append_member_state_intents(camp, intents, "sleep")
			continue

		camp["awake"] = true
		var acquisition_contacts := contacts
		if not was_engaged and not was_returning:
			acquisition_contacts = _contacts_inside(camp["position_mt"], contacts, initial_radius)
		if not acquisition_contacts.is_empty():
			camp["status"] = "engaged"
			camp["last_legal_hostile_tick"] = tick
			for member_id: String in NeutralState._sorted_string_keys(camp["members"]):
				var member: Dictionary = camp["members"][member_id]
				if not bool(member["alive"]):
					continue
				if _outside_radius(member["position_mt"], camp["position_mt"], int(camp["leash_radius_mt"])):
					intents.append(_member_intent(camp_id, member, "return_to_spawn", {
						"position_mt": member["spawn_position_mt"].duplicate(),
					}))
					continue
				var target := _select_target(member, acquisition_contacts)
				intents.append(_member_intent(camp_id, member, "attack_entity", {
					"target_internal_id": int(target["internal_id"]),
				}))
			continue

		if str(camp["status"]) == "engaged" \
			and tick - int(camp["last_legal_hostile_tick"]) >= int(neutrals["camp_behavior"]["return_after_no_legal_hostile_ticks"]):
			camp["status"] = "returning"
		if str(camp["status"]) == "returning":
			var all_home_and_full := true
			for member_id: String in NeutralState._sorted_string_keys(camp["members"]):
				var member: Dictionary = camp["members"][member_id]
				if not bool(member["alive"]):
					continue
				if member["position_mt"] != member["spawn_position_mt"]:
					all_home_and_full = false
					intents.append(_member_intent(camp_id, member, "return_to_spawn", {
						"position_mt": member["spawn_position_mt"].duplicate(),
					}))
				elif int(member["hp"]) < int(member["max_hp"]):
					all_home_and_full = false
					if tick % 10 == 0:
						intents.append(_member_intent(camp_id, member, "regenerate", {
							"max_hp_basis_points": int(neutrals["camp_behavior"]["return_regeneration_max_hp_bp_per_10_ticks"]),
						}))
			if all_home_and_full:
				camp["last_legal_hostile_tick"] = -1
				camp["awake"] = not is_night
				camp["status"] = "sleeping" if is_night else "idle"
			continue
		camp["status"] = "idle"
		_append_member_state_intents(camp, intents, "idle")
	return intents


func mark_member_dead(camp_id: String, member_id: String, death_tick: int) -> Dictionary:
	if not state.camps.has(camp_id) or not state.camps[camp_id]["members"].has(member_id):
		return {"accepted": false, "code": "invalid_target", "handoff": {}}
	var member: Dictionary = state.camps[camp_id]["members"][member_id]
	if not bool(member["alive"]):
		return {"accepted": false, "code": "already_completed", "handoff": {}}
	member["alive"] = false
	member["hp"] = 0
	member["death_tick"] = death_tick
	var definition: Dictionary = neutrals["units"][str(member["neutral_id"])]
	var handoff := {
		"camp_id": camp_id,
		"kind": "award_neutral_death_xp",
		"position_mt": member["position_mt"].duplicate(),
		"xp_bounty": int(definition["xp_bounty"]),
	}
	state.append_event("neutral_member_died", member_id, camp_id, {
		"neutral_id": str(member["neutral_id"]), "xp_bounty": int(definition["xp_bounty"]),
	})
	return {"accepted": true, "code": "accepted", "handoff": handoff}


## Phase-10 API. The caller invokes this after all member/summon deaths for the
## tick are synchronized. Drop creation therefore cannot precede death resolution.
func resolve_camp_clear(tick: int, camp_id: String) -> Dictionary:
	if not state.camps.has(camp_id):
		return {"cleared": false, "code": "invalid_target", "handoffs": []}
	if tick < state.tick:
		return {"cleared": false, "code": "tick_moved_backwards", "handoffs": []}
	advance_phase2(tick)
	var camp: Dictionary = state.camps[camp_id]
	if str(camp["status"]) == "cleared":
		return {"cleared": false, "code": "already_completed", "handoffs": []}
	for member_id: String in NeutralState._sorted_string_keys(camp["members"]):
		if bool(camp["members"][member_id]["alive"]):
			return {"cleared": false, "code": "target_unavailable", "handoffs": []}
	for summon_id: String in NeutralState._sorted_string_keys(camp["summons"]):
		if bool(camp["summons"][summon_id]["alive"]):
			return {"cleared": false, "code": "target_unavailable", "handoffs": []}
	camp["status"] = "cleared"
	camp["awake"] = false
	camp["clear_tick"] = tick
	var owner := _camp_gold_owner(tick, camp)
	camp["gold_owner_seat"] = owner
	var handoffs: Array[Dictionary] = []
	if owner in [0, 1]:
		handoffs.append({
			"amount": int(camp["gold_bounty"]),
			"kind": "award_camp_clear_gold",
			"owner_seat": owner,
		})
	var drop_result := _create_camp_drop(tick, camp)
	if bool(drop_result["created"]):
		camp["item_drop_id"] = str(drop_result["drop"]["drop_id"])
		handoffs.append({"drop": drop_result["drop"].duplicate(true), "kind": "spawn_ground_item"})
	state.append_event("neutral_camp_cleared", camp_id, str(camp["item_drop_id"]), {
		"gold_bounty": int(camp["gold_bounty"]),
		"gold_owner_seat": owner,
		"item_tier": str(drop_result["tier"]),
	})
	_refresh_expansion_clear_flags()
	return {
		"cleared": true,
		"code": "accepted",
		"gold_owner_seat": owner,
		"handoffs": handoffs,
		"item_tier": str(drop_result["tier"]),
	}


func expansion_registry() -> Array[Dictionary]:
	_refresh_expansion_clear_flags()
	var result: Array[Dictionary] = []
	for expansion_id: String in state.sorted_expansion_ids():
		result.append(state.expansions[expansion_id].duplicate(true))
	return result


func validate_expansion_start(expansion_id: String, facts: Dictionary) -> Dictionary:
	_refresh_expansion_clear_flags()
	if not state.expansions.has(expansion_id):
		return {"code": "invalid_target", "ok": false}
	var expansion: Dictionary = state.expansions[expansion_id]
	if bool(expansion["claimed"]):
		return {"code": "target_unavailable", "ok": false}
	if not bool(expansion["camps_cleared"]):
		return {"code": "prerequisite_missing", "ok": false}
	if bool(facts.get("hostile_ground_visible_within_8000_mt", true)):
		return {"code": "target_unavailable", "ok": false}
	if not bool(facts.get("site_explored", false)) or not bool(facts.get("route_explored", false)):
		return {"code": "not_visible", "ok": false}
	if not bool(facts.get("footprint_unoccupied", false)):
		return {"code": "placement_blocked", "ok": false}
	var cost: Dictionary = rules["shared_structures"]["expansion_hall"]
	if int(facts.get("available_gold", 0)) < int(cost["cost_gold"]) \
		or int(facts.get("available_lumber", 0)) < int(cost["cost_lumber"]):
		return {"code": "insufficient_resources", "ok": false}
	return {
		"code": "accepted",
		"cost_gold": int(cost["cost_gold"]),
		"cost_lumber": int(cost["cost_lumber"]),
		"ok": true,
	}


func resolve_expansion_claims(tick: int, claims: Array) -> Dictionary:
	if tick < state.tick:
		return {"accepted": [], "rejected": [], "errors": ["tick_moved_backwards"]}
	advance_phase2(tick)
	var candidates_by_expansion: Dictionary = {}
	var results: Dictionary = {}
	var ordered: Array[Dictionary] = []
	for claim: Dictionary in claims:
		ordered.append(claim.duplicate(true))
	ordered.sort_custom(_expansion_claim_less)
	for claim: Dictionary in ordered:
		var claim_id := str(claim.get("claim_id", ""))
		var expansion_id := str(claim.get("expansion_id", ""))
		if claim_id.is_empty() or results.has(claim_id) \
			or typeof(claim.get("actor_internal_id")) != TYPE_INT \
			or str(claim.get("canonical_command_digest", "")).length() != 64:
			if not claim_id.is_empty():
				results[claim_id] = _simple_result(claim_id, false, "invalid_request", {})
			continue
		var validation := validate_expansion_start(expansion_id, claim.get("facts", {}))
		if not bool(validation["ok"]):
			results[claim_id] = _simple_result(claim_id, false, str(validation["code"]), {})
			continue
		var candidate := claim.duplicate(true)
		candidate["internal_actor_id"] = int(claim["actor_internal_id"])
		if not candidates_by_expansion.has(expansion_id):
			candidates_by_expansion[expansion_id] = []
		candidates_by_expansion[expansion_id].append(candidate)
	for expansion_id: String in NeutralState._sorted_string_keys(candidates_by_expansion):
		var group_key := "%d|expansion_or_build_site|%s|0" % [tick, expansion_id]
		var typed_candidates: Array[Dictionary] = []
		for candidate_variant: Variant in candidates_by_expansion[expansion_id]:
			typed_candidates.append(candidate_variant as Dictionary)
		var ranked := KeyedRandom.rank_claimants(
			protected_tie_key, group_key, typed_candidates
		)
		var winner: Dictionary = ranked[0]
		var winner_id := str(winner["claim_id"])
		var expansion: Dictionary = state.expansions[expansion_id]
		expansion["claimed"] = true
		expansion["claimed_by_seat"] = int(winner["owner_seat"])
		expansion["claim_tick"] = tick
		var handoff := {
			"build_site_id": str(expansion["build_site_id"]),
			"cost_gold": int(rules["shared_structures"]["expansion_hall"]["cost_gold"]),
			"cost_lumber": int(rules["shared_structures"]["expansion_hall"]["cost_lumber"]),
			"expansion_id": expansion_id,
			"kind": "begin_expansion_hall",
			"owner_seat": int(winner["owner_seat"]),
		}
		results[winner_id] = _simple_result(winner_id, true, "accepted", handoff)
		var ranking: Array = []
		for ranked_claim: Dictionary in ranked:
			var ranked_id := str(ranked_claim["claim_id"])
			ranking.append({"claim_id": ranked_id, "rank_digest": str(ranked_claim["rank_digest"])})
			if ranked_id != winner_id:
				results[ranked_id] = _simple_result(ranked_id, false, "target_unavailable", {})
		state.contest_audit.append({
			"charge_index": 0,
			"claim_kind": "expansion_or_build_site",
			"group_key": group_key,
			"object_id": expansion_id,
			"ranking": ranking,
			"tick": tick,
			"winner_claim_id": winner_id,
		})
	var accepted: Array[Dictionary] = []
	var rejected: Array[Dictionary] = []
	for claim_id: String in NeutralState._sorted_string_keys(results):
		var result: Dictionary = results[claim_id]
		(accepted if bool(result["accepted"]) else rejected).append(result)
	return {"accepted": accepted, "errors": [], "rejected": rejected}


func release_expansion_claim(expansion_id: String) -> void:
	if state.expansions.has(expansion_id):
		state.expansions[expansion_id]["claimed"] = false
		state.expansions[expansion_id]["claimed_by_seat"] = -1
		state.expansions[expansion_id]["claim_tick"] = -1


func mirror_pairs(category: String) -> Array[Dictionary]:
	var all_pairs: Dictionary = map_manifest.get("mirror_pairs", {})
	if all_pairs.has(category):
		var result: Array[Dictionary] = []
		for pair_variant: Variant in all_pairs[category]:
			result.append((pair_variant as Dictionary).duplicate(true))
		return result
	return []


func canonical_hash() -> String:
	return Codec.sha256_canonical(state.to_canonical_dict())


func _initialize_camps(errors: PackedStringArray) -> void:
	for camp_variant: Variant in map_manifest["creep_camps"]:
		var source: Dictionary = camp_variant
		var camp_id := str(source["id"])
		var camp := {
			"anchor_cell": source["anchor_cell"].duplicate(),
			"awake": true,
			"camp_id": camp_id,
			"clear_tick": -1,
			"damage_by_seat": {0: {"records": [], "total": 0}, 1: {"records": [], "total": 0}},
			"gold_bounty": int(source["gold_bounty"]),
			"gold_owner_seat": -1,
			"formation": str(source["formation"]),
			"item_drop_id": "",
			"item_tier_distribution_percent": source["item_tier_distribution_percent"].duplicate(true),
			"last_legal_hostile_tick": -1,
			"leash_radius_mt": int(source["leash_radius_mt"]),
			"members": {},
			"position_mt": source["position_mt"].duplicate(),
			"region_id": str(source["region_id"]),
			"status": "idle",
			"summons": {},
			"tier": str(source["tier"]),
			"total_level": int(source["total_level"]),
		}
		var anchor: Array = source["anchor_cell"]
		var cell_size_mt := int(map_manifest["coordinate_system"]["cell_size_mt"])
		for member_variant: Variant in source["member_spawns"]:
			var member_source: Dictionary = member_variant
			var neutral_id := str(member_source["neutral_id"])
			if not neutrals["units"].has(neutral_id):
				errors.append("camp %s references unknown neutral %s" % [camp_id, neutral_id])
				continue
			var definition: Dictionary = neutrals["units"][neutral_id]
			var cell: Array = member_source["cell"]
			var position := [
				int(source["position_mt"][0]) + (int(cell[0]) - int(anchor[0])) * cell_size_mt,
				int(source["position_mt"][1]) + (int(cell[1]) - int(anchor[1])) * cell_size_mt,
			]
			var member_id := str(member_source["id"])
			camp["members"][member_id] = {
				"alive": true,
				"death_tick": -1,
				"hp": int(definition["hp"]),
				"internal_id": 0,
				"last_damaged_tick": -1,
				"level": int(member_source["level"]),
				"max_hp": int(definition["hp"]),
				"member_id": member_id,
				"neutral_id": neutral_id,
				"position_mt": position.duplicate(),
				"spawn_position_mt": position.duplicate(),
			}
		state.camps[camp_id] = camp


func _initialize_expansions(errors: PackedStringArray) -> void:
	var hall_by_region: Dictionary = {}
	for site_variant: Variant in map_manifest["build_sites"]:
		var site: Dictionary = site_variant
		if str(site["category"]) == "hall" and site["starts_occupied_by"] == null:
			hall_by_region[str(site["region_id"])] = str(site["id"])
	for resource_variant: Variant in map_manifest["resource_sites"]:
		var resource: Dictionary = resource_variant
		if str(resource["kind"]) != "gold_mine":
			continue
		var tags: Array = resource["tags"]
		if "natural_expansion" not in tags and "contested_expansion" not in tags:
			continue
		var region_id := str(resource["region_id"])
		if not hall_by_region.has(region_id):
			errors.append("expansion region %s has no public Hall site" % region_id)
			continue
		var camp_ids: Array[String] = []
		for camp_id: String in state.sorted_camp_ids():
			if str(state.camps[camp_id]["region_id"]) == region_id:
				camp_ids.append(camp_id)
		if camp_ids.is_empty():
			errors.append("expansion region %s has no guarding camp" % region_id)
			continue
		var expansion_id := str(resource["id"])
		state.expansions[expansion_id] = {
			"build_site_id": str(hall_by_region[region_id]),
			"camp_ids": camp_ids,
			"camps_cleared": false,
			"claim_tick": -1,
			"claimed": false,
			"claimed_by_seat": -1,
			"expansion_id": expansion_id,
			"initial_gold": int(resource["initial_amount"]),
			"position_mt": resource["position_mt"].duplicate(),
			"region_id": region_id,
			"resource_site_id": expansion_id,
		}


func _validate_locked_neutral_data() -> PackedStringArray:
	var errors := PackedStringArray()
	if str(map_manifest.get("ruleset_id", "")) != str(rules["ruleset_id"]):
		errors.append("map/rules ruleset IDs differ")
	if not rules.has("day_night"):
		errors.append("rules catalog is missing day/night authority")
	else:
		var schedule: Dictionary = rules["day_night"]
		if int(schedule["day_ticks"]) + int(schedule["night_ticks"]) != int(schedule["cycle_ticks"]) \
			or int(schedule["start_cycle_tick"]) != 0 or str(schedule["start_phase"]) != "day" \
			or not bool(schedule["forced_night_underlying_clock_continues"]):
			errors.append("rules catalog day/night schedule is unsupported or inconsistent")
	if state.camps.size() != 16 or state.expansions.size() != 4:
		errors.append("official map must expose 16 camps and four expansions")
	for camp_id: String in state.sorted_camp_ids():
		var camp: Dictionary = state.camps[camp_id]
		var level_sum := 0
		for member_id: String in NeutralState._sorted_string_keys(camp["members"]):
			var member: Dictionary = camp["members"][member_id]
			var definition: Dictionary = neutrals["units"][str(member["neutral_id"])]
			if int(member["level"]) != int(definition["level"]):
				errors.append("camp member level disagrees with neutral catalog: %s" % member_id)
			level_sum += int(member["level"])
		if level_sum != int(camp["total_level"]):
			errors.append("camp %s total level is not its member sum" % camp_id)
		var tier: Dictionary = neutrals["camp_tiers"][str(camp["tier"])]
		if level_sum < int(tier["minimum_total_level"]) or level_sum > int(tier["maximum_total_level"]):
			errors.append("camp %s total level is outside its tier" % camp_id)
		if camp["item_tier_distribution_percent"] != tier["drop_percent"]:
			errors.append("camp %s drop table differs from the neutral catalog" % camp_id)
		if int(camp["leash_radius_mt"]) != int(neutrals["camp_behavior"]["leash_radius_mt"]):
			errors.append("camp %s leash differs from the neutral catalog" % camp_id)
		if int(camp["gold_bounty"]) != level_sum * int(neutrals["camp_behavior"]["clear_gold_per_total_level"]):
			errors.append("camp %s gold bounty is not catalog-derived" % camp_id)
	for tier_number: int in [1, 2, 3, 4]:
		if _drop_candidates(tier_number).is_empty():
			errors.append("item catalog has no creep-drop-only item for tier %d" % tier_number)
	errors.append_array(_validate_mirror_pairs("creep_camps"))
	errors.append_array(_validate_mirror_pairs("neutral_buildings"))
	return errors


func _validate_mirror_pairs(category: String) -> PackedStringArray:
	var errors := PackedStringArray()
	var source_index: Dictionary = {}
	for entry_variant: Variant in map_manifest[category]:
		var entry: Dictionary = entry_variant
		source_index[str(entry["id"])] = entry
	var world_max: Array = map_manifest["rotation_transform"]["world_max_inclusive_mt"]
	for pair: Dictionary in mirror_pairs(category):
		var a_id := str(pair["a"])
		var b_id := str(pair["b"])
		if not source_index.has(a_id) or not source_index.has(b_id):
			errors.append("%s mirror pair references a missing ID" % category)
			continue
		var a: Dictionary = source_index[a_id]
		var b: Dictionary = source_index[b_id]
		if a_id != b_id and (int(a["position_mt"][0]) + int(b["position_mt"][0]) != int(world_max[0]) \
			or int(a["position_mt"][1]) + int(b["position_mt"][1]) != int(world_max[1])):
			errors.append("%s mirror positions are not exact: %s/%s" % [category, a_id, b_id])
		if category == "creep_camps":
			if str(a["tier"]) != str(b["tier"]) or int(a["total_level"]) != int(b["total_level"]) \
				or int(a["gold_bounty"]) != int(b["gold_bounty"]):
				errors.append("mirrored camps differ semantically: %s/%s" % [a_id, b_id])
			var a_roster: Array[String] = []
			var b_roster: Array[String] = []
			for member: Dictionary in a["member_spawns"]:
				a_roster.append(str(member["neutral_id"]))
			for member: Dictionary in b["member_spawns"]:
				b_roster.append(str(member["neutral_id"]))
			a_roster.sort()
			b_roster.sort()
			if a_roster != b_roster:
				errors.append("mirrored camp rosters differ: %s/%s" % [a_id, b_id])
		elif str(a["building_type"]) != str(b["building_type"]):
			errors.append("mirrored neutral building types differ: %s/%s" % [a_id, b_id])
	return errors


func _legal_contacts(camp: Dictionary, contacts_variant: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if typeof(contacts_variant) != TYPE_ARRAY:
		return result
	var start_regions := ["r_self_home", "r_opponent_home"]
	for contact_variant: Variant in contacts_variant:
		if typeof(contact_variant) != TYPE_DICTIONARY:
			continue
		var contact: Dictionary = contact_variant
		if typeof(contact.get("internal_id")) != TYPE_INT or int(contact["internal_id"]) <= 0 \
			or not _valid_position(contact.get("position_mt", [])) \
			or not bool(contact.get("alive", false)) \
			or not bool(contact.get("hostile", false)) \
			or not bool(contact.get("targetable", false)) \
			or str(contact.get("region_id", "")) in start_regions:
			continue
		if _outside_radius(contact["position_mt"], camp["position_mt"], int(camp["leash_radius_mt"])):
			continue
		var normalized := contact.duplicate(true)
		normalized["path_cost"] = int(contact.get("path_cost", 9_007_199_254_740_991))
		normalized["attacked_camp"] = bool(contact.get("attacked_camp", false))
		result.append(normalized)
	result.sort_custom(_contact_id_less)
	return result


func _select_target(member: Dictionary, contacts: Array[Dictionary]) -> Dictionary:
	var ranked: Array[Dictionary] = []
	for contact: Dictionary in contacts:
		var candidate := contact.duplicate(true)
		candidate["_distance_squared"] = _distance_squared(member["position_mt"], contact["position_mt"])
		ranked.append(candidate)
	ranked.sort_custom(_target_less)
	return ranked[0]


func _camp_gold_owner(tick: int, camp: Dictionary) -> int:
	var best := maxi(
		int(camp["damage_by_seat"][0]["total"]),
		int(camp["damage_by_seat"][1]["total"])
	)
	if best <= 0:
		return -1
	var tied: Array[int] = []
	for seat: int in [0, 1]:
		if int(camp["damage_by_seat"][seat]["total"]) == best:
			tied.append(seat)
	if tied.size() == 1:
		return tied[0]
	var claims: Array[Dictionary] = []
	for seat: int in tied:
		var records: Array = camp["damage_by_seat"][seat]["records"].duplicate(true)
		records.sort_custom(NeutralState._damage_record_less)
		var representative: Dictionary = records[0]
		claims.append({
			"canonical_command_digest": str(representative["command_digest"]),
			"claim_id": "camp_gold_seat_%d" % seat,
			"internal_actor_id": int(representative["source_internal_id"]),
			"seat": seat,
		})
	var group_key := "%d|camp_clear_gold|%s|0" % [tick, camp["camp_id"]]
	var ranked := KeyedRandom.rank_claimants(protected_tie_key, group_key, claims)
	var ranking: Array = []
	for claim: Dictionary in ranked:
		ranking.append({"claim_id": str(claim["claim_id"]), "rank_digest": str(claim["rank_digest"])})
	state.contest_audit.append({
		"charge_index": 0,
		"claim_kind": "camp_clear_gold",
		"group_key": group_key,
		"object_id": str(camp["camp_id"]),
		"ranking": ranking,
		"tick": tick,
		"winner_claim_id": str(ranked[0]["claim_id"]),
	})
	return int(ranked[0]["seat"])


func _create_camp_drop(tick: int, camp: Dictionary) -> Dictionary:
	var tier := _roll_drop_tier(camp)
	if tier == "none":
		return {"created": false, "drop": {}, "tier": tier}
	var tier_number := int(tier.trim_prefix("tier_"))
	var candidates := _drop_candidates(tier_number)
	var digest := KeyedRandom.stream_digest(
		state.ruleset_hash, state.match_seed, "item_drop", 0, 0,
		"%s|%s|item" % [camp["camp_id"], tier]
	)
	var candidate_index := digest.substr(0, 8).hex_to_int() % candidates.size()
	var item_type_id := candidates[candidate_index]
	var drop_id := "neutral_drop:%s" % camp["camp_id"]
	var drop := {
		"despawn_tick": tick + int(items["dropped_despawn_ticks"]),
		"drop_id": drop_id,
		"item_type_id": item_type_id,
		"position_mt": camp["position_mt"].duplicate(),
		"source_camp_id": str(camp["camp_id"]),
		"spawn_tick": tick,
		"tier": tier_number,
	}
	state.ground_drops[drop_id] = drop
	return {"created": true, "drop": drop, "tier": tier}


func _roll_drop_tier(camp: Dictionary) -> String:
	var digest := KeyedRandom.stream_digest(
		state.ruleset_hash, state.match_seed, "item_drop", 0, 0, str(camp["camp_id"])
	)
	var roll := digest.substr(0, 8).hex_to_int() % 100
	var cumulative := 0
	for tier: String in ["none", "tier_1", "tier_2", "tier_3", "tier_4"]:
		if camp["item_tier_distribution_percent"].has(tier):
			cumulative += int(camp["item_tier_distribution_percent"][tier])
			if roll < cumulative:
				return tier
	return "none"


func _drop_candidates(tier_number: int) -> Array[String]:
	var result: Array[String] = []
	var item_ids: Array = items["items"].keys()
	item_ids.sort()
	for item_id_variant: Variant in item_ids:
		var item_id := str(item_id_variant)
		var definition: Dictionary = items["items"][item_id]
		if int(definition["tier"]) == tier_number and not bool(definition["purchasable"]):
			result.append(item_id)
	return result


func _refresh_expansion_clear_flags() -> void:
	for expansion_id: String in state.sorted_expansion_ids():
		var expansion: Dictionary = state.expansions[expansion_id]
		var cleared := true
		for camp_id: String in expansion["camp_ids"]:
			if str(state.camps[camp_id]["status"]) != "cleared":
				cleared = false
		expansion["camps_cleared"] = cleared


func _load_locked_map() -> Dictionary:
	var errors := PackedStringArray()
	if not FileAccess.file_exists(MAP_PATH) or not FileAccess.file_exists(PROTOCOL_LOCK_PATH):
		errors.append("official map or protocol lock is missing")
		return {"errors": errors, "manifest": {}, "ok": false, "raw_hash": ""}
	var map_file := FileAccess.open(MAP_PATH, FileAccess.READ)
	if map_file == null:
		errors.append("official map could not be opened")
		return {"errors": errors, "manifest": {}, "ok": false, "raw_hash": ""}
	var map_bytes := map_file.get_buffer(map_file.get_length())
	var map_hash := Codec.sha256_bytes(map_bytes)
	var lock_result := _parse_normalized_json(PROTOCOL_LOCK_PATH)
	var map_result := _parse_normalized_bytes(map_bytes)
	if not bool(lock_result["ok"]):
		errors.append_array(lock_result["errors"])
	if not bool(map_result["ok"]):
		errors.append_array(map_result["errors"])
	if not errors.is_empty():
		return {"errors": errors, "manifest": {}, "ok": false, "raw_hash": map_hash}
	var expected: Dictionary = {}
	for artifact_variant: Variant in lock_result["value"]["artifacts"]:
		var artifact: Dictionary = artifact_variant
		if str(artifact["path"]) == MAP_RELATIVE_PATH:
			expected = artifact
			break
	if expected.is_empty():
		errors.append("protocol lock does not contain the official map")
	elif map_hash != str(expected["sha256"]) or map_bytes.size() != int(expected["size_bytes"]):
		errors.append("official map bytes differ from protocol lock")
	var manifest: Dictionary = map_result["value"]
	for field: String in [
		"build_sites", "coordinate_system", "creep_camps", "map_id", "mirror_pairs",
		"neutral_buildings", "resource_sites", "rotation_transform", "ruleset_id",
	]:
		if not manifest.has(field):
			errors.append("official map is missing %s" % field)
	if str(manifest.get("map_id", "")) != "crossroads-duel-v1":
		errors.append("unexpected official map ID")
	return {"errors": errors, "manifest": manifest, "ok": errors.is_empty(), "raw_hash": map_hash}


static func _parse_normalized_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"errors": PackedStringArray(["could not open %s" % path]), "ok": false, "value": {}}
	return _parse_normalized_bytes(file.get_buffer(file.get_length()))


static func _parse_normalized_bytes(bytes: PackedByteArray) -> Dictionary:
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return {"errors": PackedStringArray(["locked JSON is not valid UTF-8"]), "ok": false, "value": {}}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {"errors": PackedStringArray(["invalid locked JSON"]), "ok": false, "value": {}}
	return CatalogLoader.normalize_json_boundary(parser.data)


static func _append_member_state_intents(camp: Dictionary, intents: Array[Dictionary], kind: String) -> void:
	for member_id: String in NeutralState._sorted_string_keys(camp["members"]):
		var member: Dictionary = camp["members"][member_id]
		if bool(member["alive"]):
			intents.append(_member_intent(str(camp["camp_id"]), member, kind, {}))


static func _member_intent(camp_id: String, member: Dictionary, kind: String, payload: Dictionary) -> Dictionary:
	return {
		"camp_id": camp_id,
		"kind": kind,
		"member_id": str(member["member_id"]),
		"neutral_internal_id": int(member["internal_id"]),
		"payload": payload.duplicate(true),
	}


static func _camp_damaged_at(camp: Dictionary, tick: int) -> bool:
	for member_id: String in NeutralState._sorted_string_keys(camp["members"]):
		if int(camp["members"][member_id]["last_damaged_tick"]) == tick:
			return true
	return false


static func _contacts_inside(center: Array, contacts: Array[Dictionary], radius_mt: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for contact: Dictionary in contacts:
		if _distance_squared(center, contact["position_mt"]) <= radius_mt * radius_mt:
			result.append(contact)
	return result


static func _has_contact_inside(center: Array, contacts: Array[Dictionary], radius_mt: int) -> bool:
	return not _contacts_inside(center, contacts, radius_mt).is_empty()


static func _outside_radius(point: Array, center: Array, radius_mt: int) -> bool:
	return _distance_squared(point, center) > radius_mt * radius_mt


static func _distance_squared(left: Array, right: Array) -> int:
	var dx := int(left[0]) - int(right[0])
	var dy := int(left[1]) - int(right[1])
	return dx * dx + dy * dy


static func _valid_position(value: Variant) -> bool:
	return typeof(value) == TYPE_ARRAY and (value as Array).size() == 2 \
		and typeof(value[0]) == TYPE_INT and typeof(value[1]) == TYPE_INT


static func _contact_id_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left["internal_id"]) < int(right["internal_id"])


static func _target_less(left: Dictionary, right: Dictionary) -> bool:
	var left_key := [
		0 if bool(left["attacked_camp"]) else 1,
		int(left["_distance_squared"]),
		int(left["path_cost"]),
		int(left["internal_id"]),
	]
	var right_key := [
		0 if bool(right["attacked_camp"]) else 1,
		int(right["_distance_squared"]),
		int(right["path_cost"]),
		int(right["internal_id"]),
	]
	return left_key < right_key


static func _expansion_claim_less(left: Dictionary, right: Dictionary) -> bool:
	var left_key := [int(left.get("owner_seat", -1)), int(left.get("command_index", 0)), str(left.get("claim_id", ""))]
	var right_key := [int(right.get("owner_seat", -1)), int(right.get("command_index", 0)), str(right.get("claim_id", ""))]
	return left_key < right_key


static func _simple_result(claim_id: String, accepted: bool, code: String, handoff: Dictionary) -> Dictionary:
	return {"accepted": accepted, "claim_id": claim_id, "code": code, "handoff": handoff.duplicate(true)}
