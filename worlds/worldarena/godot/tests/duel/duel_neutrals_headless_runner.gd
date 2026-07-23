extends SceneTree

const NeutralWorld := preload("res://scripts/duel/neutrals/duel_neutral_world.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const TIE_KEY_TEXT := "worldarena-neutral-protected-test-key-v1"
const GOLDEN_SCENARIO_HASH := "fa33238be4bd15397926988a160ada4c29b3b0fb2219ba8be8e1982cd16468df"

var _failures := PackedStringArray()


func _init() -> void:
	_test_locked_registries_and_mirrors()
	_test_day_night_and_forced_night()
	_test_sleep_aggro_target_leash_return_and_regeneration()
	_test_clear_reward_drop_and_summon_gate()
	_test_stock_restock_and_purchase_contest()
	_test_reveal_and_field_revival_claims()
	_test_expansion_registry_and_contest()
	var first := _run_golden_scenario(false)
	var second := _run_golden_scenario(true)
	_check(first["summary"] == second["summary"], "neutral golden summary depends on insertion order")
	_check(first["hash"] == second["hash"], "neutral golden state depends on insertion order")
	if not GOLDEN_SCENARIO_HASH.is_empty():
		_check(first["hash"] == GOLDEN_SCENARIO_HASH, "neutral golden hash changed: %s" % first["hash"])
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_NEUTRALS_FAILURE: %s" % failure)
		print("DUEL_NEUTRALS_FAILED count=%d hash=%s" % [_failures.size(), first["hash"]])
		quit(1)
		return
	print("DUEL_NEUTRALS_OK hash=%s summary=%s" % [first["hash"], JSON.stringify(first["summary"])])
	quit(0)


func _test_locked_registries_and_mirrors() -> void:
	var world := _new_world()
	_check(world.state.camps.size() == 16, "official neutral camp registry count changed")
	_check(world.state.buildings.size() == 5, "official neutral building registry count changed")
	_check(world.state.expansions.size() == 4, "official expansion registry count changed")
	_check(world.camp_registry(false).size() == 16, "public camp registry is incomplete")
	_check(world.mirror_pairs("creep_camps").size() == 8, "official creep mirror pairs are incomplete")
	_check(world.mirror_pairs("neutral_buildings").size() == 3, "official neutral-building mirror pairs are incomplete")
	var descriptors := world.creep_spawn_descriptors()
	var expected_members := 0
	for camp_id: String in world.state.sorted_camp_ids():
		expected_members += world.state.camps[camp_id]["members"].size()
	_check(descriptors.size() == expected_members, "creep spawn descriptors do not cover every authored member")
	for descriptor: Dictionary in descriptors:
		_check(descriptor["catalog_definition"].has("attack"), "creep spawn descriptor omitted locked combat stats")
	var west: Dictionary = world.state.camps["camp_west_contested_hard"]
	var east: Dictionary = world.state.camps["camp_east_contested_hard"]
	_check(int(west["position_mt"][0]) + int(east["position_mt"][0]) == 191_999, "mirrored camp X coordinates are not exact")
	_check(int(west["position_mt"][1]) + int(east["position_mt"][1]) == 127_999, "mirrored camp Y coordinates are not exact")
	_check(world.state.validate().is_empty(), "fresh neutral state failed validation")


func _test_day_night_and_forced_night() -> void:
	var world := _new_world()
	_check(world.day_phase(0)["phase"] == "day", "match did not begin during day")
	_check(world.day_phase(2_399)["phase"] == "day", "day ended one tick early")
	_check(world.day_phase(2_400)["phase"] == "night", "night began one tick late")
	_check(world.day_phase(4_799)["phase"] == "night", "night ended one tick early")
	_check(world.day_phase(4_800)["phase"] == "day", "second cycle did not resume day")
	_check(world.add_forced_night("test_force", 100, 200).is_empty(), "legal forced night was rejected")
	var forced := world.day_phase(150)
	_check(forced["phase"] == "night" and forced["underlying_phase"] == "day" and forced["forced"], "forced night stopped the wrong clock or phase")
	world.advance_phase2(200)
	_check(world.day_phase(200)["phase"] == "day" and not world.day_phase(200)["forced"], "forced night did not expire at its exclusive end")


func _test_sleep_aggro_target_leash_return_and_regeneration() -> void:
	var world := _new_world()
	var camp_id := "camp_self_west_approach_easy"
	var camp: Dictionary = world.state.camps[camp_id]
	var members: Array = camp["members"].keys()
	members.sort()
	for index: int in members.size():
		world.bind_member_entity(camp_id, str(members[index]), 100 + index)
	var anchor: Array = camp["position_mt"]
	var far_night := [_contact(900, [int(anchor[0]) + 4_000, int(anchor[1])], false, 200, "r_self_west_approach")]
	var intents := world.compile_camp_intents(2_400, {camp_id: far_night})
	_check(_all_intents_kind(intents, "sleep"), "sleeping night camp woke outside its 3-tile radius")
	var near := [_contact(901, [int(anchor[0]) + 2_500, int(anchor[1])], false, 300, "r_self_west_approach")]
	intents = world.compile_camp_intents(2_401, {camp_id: near})
	_check(_all_intents_kind(_for_camp(intents, camp_id), "attack_entity"), "sleeping camp did not wake as a group at close range")

	var contacts := [
		_contact(800, [int(anchor[0]) + 1_000, int(anchor[1])], false, 50, "r_self_west_approach"),
		_contact(950, [int(anchor[0]) + 5_000, int(anchor[1])], true, 500, "r_self_west_approach"),
		_contact(700, [int(anchor[0]) + 500, int(anchor[1])], true, 1, "r_self_home"),
	]
	intents = world.compile_camp_intents(2_402, {camp_id: contacts})
	_check(_all_attack_target(_for_camp(intents, camp_id), 950), "creep priority ignored attacker precedence or chased into a starting base")

	for member_id_variant: Variant in members:
		var member_id := str(member_id_variant)
		var member: Dictionary = camp["members"][member_id]
		world.synchronize_member(camp_id, member_id, {
			"alive": true,
			"hp": int(member["max_hp"]) / 2,
			"max_hp": int(member["max_hp"]),
			"position_mt": [int(anchor[0]) + 15_000, int(anchor[1])],
		})
	intents = world.compile_camp_intents(2_432, {})
	_check(_all_intents_kind(_for_camp(intents, camp_id), "return_to_spawn"), "camp did not return after 30 hostile-free ticks")
	for member_id_variant: Variant in members:
		var member_id := str(member_id_variant)
		var member: Dictionary = camp["members"][member_id]
		world.synchronize_member(camp_id, member_id, {
			"alive": true,
			"hp": int(member["max_hp"]) / 2,
			"max_hp": int(member["max_hp"]),
			"position_mt": member["spawn_position_mt"].duplicate(),
		})
	intents = world.compile_camp_intents(2_440, {})
	var regen_intents := _for_camp(intents, camp_id)
	_check(_all_intents_kind(regen_intents, "regenerate"), "returned camp did not schedule 2%-per-10-tick regeneration")
	if not regen_intents.is_empty() and regen_intents[0]["payload"].has("max_hp_basis_points"):
		_check(int(regen_intents[0]["payload"]["max_hp_basis_points"]) == 200, "camp regeneration basis points differ from locked catalog")

	var leash_world := _new_world()
	var leash_camp: Dictionary = leash_world.state.camps[camp_id]
	var leash_members: Array = leash_camp["members"].keys()
	leash_members.sort()
	for index: int in leash_members.size():
		var member_id := str(leash_members[index])
		leash_world.bind_member_entity(camp_id, member_id, 200 + index)
		var member: Dictionary = leash_camp["members"][member_id]
		leash_world.synchronize_member(camp_id, member_id, {
			"alive": true, "hp": int(member["max_hp"]), "max_hp": int(member["max_hp"]),
			"position_mt": [int(leash_camp["position_mt"][0]) + 14_001, int(leash_camp["position_mt"][1])],
		})
	intents = leash_world.compile_camp_intents(0, {camp_id: [
		_contact(990, [int(leash_camp["position_mt"][0]) + 7_000, int(leash_camp["position_mt"][1])], false, 10, "r_self_west_approach")
	]})
	_check(_all_intents_kind(_for_camp(intents, camp_id), "return_to_spawn"), "creep beyond 14-tile leash continued chasing")


func _test_clear_reward_drop_and_summon_gate() -> void:
	var first := _cleared_hard_camp(false, 500)
	var second := _cleared_hard_camp(true, 500)
	_check(first["result"] == second["result"], "camp clear result depends on damage insertion order")
	_check(first["hash"] == second["hash"], "camp clear state depends on damage insertion order")
	_check(int(first["result"]["gold_owner_seat"]) in [0, 1], "tied camp clear did not select one keyed gold owner")
	_check(str(first["result"]["item_tier"]) in ["tier_2", "tier_3", "tier_4"], "hard camp rolled outside its locked distribution")
	var different_tick := _cleared_hard_camp(false, 777)
	_check(_drop_item_type(first["world"]) == _drop_item_type(different_tick["world"]), "camp item roll depended on kill tick")


func _test_stock_restock_and_purchase_contest() -> void:
	var world := _new_world()
	var merchant_id := "neutral_west_merchant"
	var offers := world.market.public_offers(merchant_id, 0)
	_check(_offer_stock(offers, "lesser_vitality_draught") == 2, "Merchant launch potion stock is wrong")
	_check(_offer_stock(offers, "pathfinder_boots") == 0, "Merchant boots appeared before tick 600")
	_check(_offer_available(offers, "pathfinder_boots") == false, "unavailable Merchant stock was marked available")
	_check(world.market.register_faction_shop("owned_shop_0", 0, [90_000, 100_000], 100).is_empty(), "faction shop registration failed")
	world.advance_phase2(600)
	_check(_offer_stock(world.market.public_offers(merchant_id, 600), "pathfinder_boots") == 1, "Merchant boots did not appear at tick 600")
	_check(_offer_stock(world.market.public_offers("neutral_west_laboratory", 600), "sky_barge") == 1, "Laboratory hire did not appear at tick 600")
	_check(_offer_stock(world.market.public_offers("neutral_center_tavern", 600), "field_revival") == 1, "Tavern public field-revival offer is missing")
	_check(_offer_stock(world.market.public_offers("owned_shop_0", 600), "recall_scroll") == 2, "completed faction shop did not expose locked stock")

	var first := _purchase_boot_contest(false)
	var second := _purchase_boot_contest(true)
	_check(first["result"] == second["result"], "shop contest result depends on claim insertion order")
	_check(first["hash"] == second["hash"], "shop contest state depends on claim insertion order")
	_check(first["result"]["accepted"].size() == 1 and first["result"]["rejected"].size() == 1, "one-stock contest did not accept exactly one claim")
	_check(int(first["result"]["resource_deltas"][0]["gold"]) + int(first["result"]["resource_deltas"][1]["gold"]) == -250, "shop charged other than the accepted boots cost")
	var contested_world: NeutralWorld = first["world"]
	_check(_offer_stock(contested_world.market.public_offers(merchant_id, 2_399), "pathfinder_boots") == 0, "Merchant restocked one tick early")
	_check(_offer_stock(contested_world.market.public_offers(merchant_id, 2_400), "pathfinder_boots") == 1, "Merchant did not restock at the exact charge tick")


func _test_reveal_and_field_revival_claims() -> void:
	var world := _new_world()
	var reveal_claims := [
		_shop_claim("reveal_b", 0, 1, 101, "neutral_west_laboratory", "laboratory_reveal", [10_250, 68_250], [180_000, 100_000]),
		_shop_claim("reveal_a", 0, 0, 100, "neutral_west_laboratory", "laboratory_reveal", [10_250, 68_250], [180_000, 100_000]),
	]
	var reveal := world.market.resolve_shop_claims(0, reveal_claims, _resources(1_000, 1_000))
	_check(reveal["accepted"].size() == 1 and reveal["rejected"].size() == 1, "same-player Reveal cooldown did not reserve in model order")
	_check(str(reveal["accepted"][0]["claim_id"]) == "reveal_a", "Reveal budget/cooldown order ignored command_index")
	var sources := world.market.active_reveal_sources(49, 0)
	_check(sources.size() == 1 and int(sources[0]["radius_mt"]) == 12_000 and sources[0]["detection"], "Reveal source omitted exact sight/detection semantics")
	world.advance_phase2(50)
	_check(world.market.active_reveal_sources(50, 0).is_empty(), "Reveal source lasted past apply_tick + 49")

	var first := _field_revival_contest(false)
	var second := _field_revival_contest(true)
	_check(first["result"] == second["result"], "field revival contest depends on insertion order")
	_check(first["hash"] == second["hash"], "field revival state depends on insertion order")
	_check(first["result"]["accepted"].size() == 1 and first["result"]["rejected"].size() == 1, "Tavern did not expose one exclusive field-revival slot")
	var accepted: Dictionary = first["result"]["accepted"][0]
	_check(int(accepted["charge"]["gold"]) in [382, 435], "field revival cost is not 150% of exact altar cost")
	_check(int(accepted["handoff"]["return_hp_bp"]) == 5_000 and int(accepted["handoff"]["mana_bp"]) == 0, "field revival return state is wrong")
	var offer: Dictionary = first["world"].market.public_field_revival_offer("neutral_center_tavern", 300, 3, 0, true)
	_check(not offer["available"] and int(offer["cost_gold"]) == 382, "Tavern public offer did not expose exact dynamic cost/claimed stock")


func _test_expansion_registry_and_contest() -> void:
	var world := _new_world()
	var registry := world.expansion_registry()
	_check(registry.size() == 4, "expansion registry omitted natural/contested sites")
	var expansion_id := "res_self_natural_gold"
	var camp_id := "camp_self_natural_medium"
	var blocked := world.validate_expansion_start(expansion_id, _expansion_facts())
	_check(not blocked["ok"] and blocked["code"] == "prerequisite_missing", "uncleared camp allowed an expansion")
	world.state.camps[camp_id]["status"] = "cleared"
	var legal := world.validate_expansion_start(expansion_id, _expansion_facts())
	_check(legal["ok"] and int(legal["cost_gold"]) == 450 and int(legal["cost_lumber"]) == 250, "legal expansion did not use exact shared cost")
	var claims := [
		_expansion_claim("expand_b", 1, 202, expansion_id),
		_expansion_claim("expand_a", 0, 101, expansion_id),
	]
	var resolved := world.resolve_expansion_claims(20, claims)
	_check(resolved["accepted"].size() == 1 and resolved["rejected"].size() == 1, "expansion build site contest did not choose one claimant")
	_check(world.state.expansions[expansion_id]["claimed"], "winning expansion claim did not lock the public site")


func _run_golden_scenario(reverse_insertion: bool) -> Dictionary:
	var world := _new_world(8_675_309)
	world.add_forced_night("golden_night", 600, 700)
	var camp_id := "camp_center_west_medium"
	var member_ids: Array = world.state.camps[camp_id]["members"].keys()
	member_ids.sort()
	for index: int in member_ids.size():
		world.bind_member_entity(camp_id, str(member_ids[index]), 300 + index)
	var anchor: Array = world.state.camps[camp_id]["position_mt"]
	world.compile_camp_intents(0, {camp_id: [
		_contact(501, [int(anchor[0]) + 2_000, int(anchor[1])], true, 400, "r_center")
	]})
	var claims := [
		_shop_claim("golden_buy_a", 0, 0, 11, "neutral_west_merchant", "lesser_vitality_draught", [10_250, 60_250], []),
		_shop_claim("golden_buy_b", 1, 0, 22, "neutral_west_merchant", "lesser_vitality_draught", [10_250, 60_250], []),
	]
	if reverse_insertion:
		claims.reverse()
	var purchase := world.market.resolve_shop_claims(1, claims, _resources(500, 500))
	var clear_camp := "camp_west_contested_hard"
	var damage_records := [
		{"digest": Codec.sha256_text("golden-damage-a"), "seat": 0, "source": 41},
		{"digest": Codec.sha256_text("golden-damage-b"), "seat": 1, "source": 52},
	]
	if reverse_insertion:
		damage_records.reverse()
	for record: Dictionary in damage_records:
		world.record_camp_damage(clear_camp, int(record["seat"]), int(record["source"]), 500, str(record["digest"]))
	for member_id: String in _sorted_string_keys(world.state.camps[clear_camp]["members"]):
		world.mark_member_dead(clear_camp, member_id, 20)
	var clear := world.resolve_camp_clear(20, clear_camp)
	var summary := {
		"camp_gold_owner": int(clear["gold_owner_seat"]),
		"drop_item": _drop_item_type(world),
		"drop_tier": str(clear["item_tier"]),
		"events": world.state.events.size(),
		"purchase_winners": purchase["accepted"].size(),
		"tick": world.state.tick,
	}
	_check(world.state.validate().is_empty(), "golden neutral state failed validation: %s" % "; ".join(world.state.validate()))
	return {"hash": world.canonical_hash(), "summary": summary}


func _cleared_hard_camp(reverse_insertion: bool, clear_tick: int) -> Dictionary:
	var world := _new_world(9_004)
	var camp_id := "camp_west_contested_hard"
	var records := [
		{"digest": Codec.sha256_text("clear-a"), "seat": 0, "source": 10},
		{"digest": Codec.sha256_text("clear-b"), "seat": 1, "source": 20},
	]
	if reverse_insertion:
		records.reverse()
	for record: Dictionary in records:
		world.record_camp_damage(camp_id, int(record["seat"]), int(record["source"]), 400, str(record["digest"]))
	for member_id: String in _sorted_string_keys(world.state.camps[camp_id]["members"]):
		world.mark_member_dead(camp_id, member_id, clear_tick)
	world.register_camp_summon(camp_id, 777)
	var gated := world.resolve_camp_clear(clear_tick, camp_id)
	_check(not gated["cleared"], "living camp summon did not block camp clear")
	world.synchronize_camp_summon(camp_id, 777, false)
	var result := world.resolve_camp_clear(clear_tick, camp_id)
	return {"hash": world.canonical_hash(), "result": result, "world": world}


func _purchase_boot_contest(reverse_insertion: bool) -> Dictionary:
	var world := _new_world(44_001)
	var claims := [
		_shop_claim("boots_a", 0, 0, 101, "neutral_west_merchant", "pathfinder_boots", [10_250, 60_250], []),
		_shop_claim("boots_b", 1, 0, 202, "neutral_west_merchant", "pathfinder_boots", [10_250, 60_250], []),
	]
	if reverse_insertion:
		claims.reverse()
	var result := world.market.resolve_shop_claims(600, claims, _resources(1_000, 1_000))
	return {"hash": world.canonical_hash(), "result": result, "world": world}


func _field_revival_contest(reverse_insertion: bool) -> Dictionary:
	var world := _new_world(82_021)
	var claims := [
		_field_claim("revive_a", 0, 1001, 3),
		_field_claim("revive_b", 1, 2002, 4),
	]
	if reverse_insertion:
		claims.reverse()
	var result := world.market.resolve_field_revival_claims(300, claims, _resources(2_000, 2_000))
	var repeated := world.market.resolve_field_revival_claims(300, claims, _resources(2_000, 2_000))
	_check(repeated["accepted"].is_empty(), "a second field-revival resolver call reused the same tick slot")
	return {"hash": world.canonical_hash(), "result": result, "world": world}


func _new_world(seed: int = 7_771) -> NeutralWorld:
	var world := NeutralWorld.new()
	var errors := world.configure_official(seed, TIE_KEY_TEXT.to_utf8_buffer())
	_check(errors.is_empty(), "official neutral configuration failed: %s" % "; ".join(errors))
	return world


func _contact(internal_id: int, position_mt: Array, attacked: bool, path_cost: int, region_id: String) -> Dictionary:
	return {
		"alive": true,
		"attacked_camp": attacked,
		"hostile": true,
		"internal_id": internal_id,
		"path_cost": path_cost,
		"position_mt": position_mt,
		"region_id": region_id,
		"targetable": true,
	}


func _shop_claim(
	claim_id: String,
	seat: int,
	command_index: int,
	actor_id: int,
	building_id: String,
	offer_id: String,
	buyer_position: Array,
	service_target: Array
) -> Dictionary:
	var claim := {
		"buyer_alive": true,
		"buyer_internal_id": actor_id,
		"buyer_owned": true,
		"buyer_position_mt": buyer_position,
		"buyer_tags": ["hero"],
		"building_id": building_id,
		"canonical_command_digest": Codec.sha256_text(claim_id),
		"claim_id": claim_id,
		"command_index": command_index,
		"interaction_legal": true,
		"offer_id": offer_id,
		"owner_seat": seat,
		"shop_visible": true,
	}
	if not service_target.is_empty():
		claim["service_target_xy_mt"] = service_target
	return claim


func _field_claim(claim_id: String, seat: int, hero_id: int, level: int) -> Dictionary:
	return {
		"already_reviving": false,
		"canonical_command_digest": Codec.sha256_text(claim_id),
		"claim_id": claim_id,
		"command_index": 0,
		"death_tick": 0,
		"hero_alive": false,
		"hero_internal_id": hero_id,
		"hero_level": level,
		"hero_owner_seat": seat,
		"owner_seat": seat,
		"tavern_id": "neutral_center_tavern",
		"tavern_visible": true,
	}


func _expansion_claim(claim_id: String, seat: int, actor_id: int, expansion_id: String) -> Dictionary:
	return {
		"actor_internal_id": actor_id,
		"canonical_command_digest": Codec.sha256_text(claim_id),
		"claim_id": claim_id,
		"command_index": 0,
		"expansion_id": expansion_id,
		"facts": _expansion_facts(),
		"owner_seat": seat,
	}


func _expansion_facts() -> Dictionary:
	return {
		"available_gold": 1_000,
		"available_lumber": 1_000,
		"footprint_unoccupied": true,
		"hostile_ground_visible_within_8000_mt": false,
		"route_explored": true,
		"site_explored": true,
	}


func _resources(gold_0: int, gold_1: int) -> Dictionary:
	return {0: {"gold": gold_0, "lumber": 1_000}, 1: {"gold": gold_1, "lumber": 1_000}}


func _offer_stock(offers: Array[Dictionary], offer_id: String) -> int:
	for offer: Dictionary in offers:
		if str(offer["offer_id"]) == offer_id:
			return int(offer["current_stock"])
	return -99


func _offer_available(offers: Array[Dictionary], offer_id: String) -> bool:
	for offer: Dictionary in offers:
		if str(offer["offer_id"]) == offer_id:
			return bool(offer["available"])
	return false


func _drop_item_type(world: NeutralWorld) -> String:
	var ids: Array = world.state.ground_drops.keys()
	ids.sort()
	return "" if ids.is_empty() else str(world.state.ground_drops[ids[0]]["item_type_id"])


func _all_intents_kind(intents: Array[Dictionary], kind: String) -> bool:
	if intents.is_empty():
		return false
	for intent: Dictionary in intents:
		if str(intent["kind"]) != kind:
			return false
	return true


func _for_camp(intents: Array[Dictionary], camp_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for intent: Dictionary in intents:
		if str(intent["camp_id"]) == camp_id:
			result.append(intent)
	return result


func _all_attack_target(intents: Array[Dictionary], target_id: int) -> bool:
	if intents.is_empty():
		return false
	for intent: Dictionary in intents:
		if str(intent["kind"]) != "attack_entity" \
			or int(intent["payload"].get("target_internal_id", 0)) != target_id:
			return false
	return true


func _sorted_string_keys(value: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_variant: Variant in value.keys():
		result.append(str(key_variant))
	result.sort()
	return result


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
