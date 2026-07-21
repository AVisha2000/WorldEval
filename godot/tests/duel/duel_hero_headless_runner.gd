extends SceneTree

const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const RuntimeCatalog := preload("res://scripts/duel/protocol/duel_runtime_catalog.gd")

const GOLDEN_SCENARIO_HASH := "d1741d966fc25aacfc7ed39f91b1924e0eaf11c50e0525406177858b5a376d13"

var _failures := PackedStringArray()
var _loaded: Dictionary = {}
var _runtime: Dictionary = {}


func _init() -> void:
	_loaded = CatalogLoader.load_official_catalogs()
	_check(bool(_loaded["ok"]), "official catalogs failed to load")
	var compiled := RuntimeCatalog.compile_selected_faction("vanguard-v1", _loaded)
	_check(bool(compiled["ok"]), "Vanguard runtime catalog failed to compile")
	if bool(compiled["ok"]):
		_runtime = compiled["runtime"]
	_test_catalog_validation()
	var first := _run_scenario(false)
	var second := _run_scenario(true)
	_check(first["hash"] == second["hash"], "entity insertion order changed Hero checkpoint")
	_check(first["summary"] == second["summary"], "entity insertion order changed Hero outcome")
	if not GOLDEN_SCENARIO_HASH.is_empty():
		_check(first["hash"] == GOLDEN_SCENARIO_HASH,
			"Hero golden hash changed: %s" % first["hash"])
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_HERO_FAILURE: %s" % failure)
		print("DUEL_HERO_FAILED count=%d hash=%s" % [_failures.size(), first.get("hash", "")])
		quit(1)
		return
	print("DUEL_HERO_OK hash=%s summary=%s" % [first["hash"], JSON.stringify(first["summary"])])
	quit(0)


func _test_catalog_validation() -> void:
	if _runtime.is_empty():
		return
	var sim := Simulation.new({"grid_height": 20, "grid_width": 32, "match_seed": 7})
	var invalid_items: Dictionary = _loaded["catalogs"]["items"].duplicate(true)
	invalid_items["inventory_slots_per_hero"] = 5
	var errors := sim.configure_heroes(
		_loaded["catalogs"]["rules"],
		_loaded["catalogs"]["faction:vanguard-v1"],
		invalid_items
	)
	_check(not errors.is_empty() and not sim.state.heroes.enabled,
		"invalid inventory slot count configured Hero authority")


func _run_scenario(reverse_insertion: bool) -> Dictionary:
	if _runtime.is_empty():
		return {"hash": "", "summary": {}}
	var sim := Simulation.new({"grid_height": 24, "grid_width": 40, "match_seed": 91_337})
	_check(sim.configure_economy(_runtime["economy"]).is_empty(),
		"official economy runtime failed to configure")
	_check(sim.configure_heroes(
		_loaded["catalogs"]["rules"],
		_loaded["catalogs"]["faction:vanguard-v1"],
		_loaded["catalogs"]["items"]
	).is_empty(), "official Hero catalogs failed to configure")
	var configured: Dictionary = sim.economy.configure_player(sim.state, 0, 2_000, 500, 1)
	_check(bool(configured["accepted"]), "Hero fixture player failed to configure")

	var altar := _entity(1, 0, "structure", "hall_of_oaths", 2_250, 3_250, 900, 0,
		["ground", "producer", "structure"])
	var marshal := _entity(10, 0, "unit", "marshal", 5_250, 3_250, 1, 450,
		["biological", "ground", "hero", "melee"])
	var arcanist := _entity(20, 0, "unit", "high_arcanist", 7_250, 3_250, 1, 450,
		["biological", "ground", "hero", "ranged"])
	var shop := _entity(30, -1, "structure", "quartermaster", 9_250, 3_250, 700, 0,
		["ground", "shop", "structure"])
	var insertion: Array[EntityRecord] = [altar, marshal, arcanist, shop]
	if reverse_insertion:
		insertion.reverse()
	for entity: EntityRecord in insertion:
		_check(sim.add_entity(entity, entity.owner_seat >= 0) == entity.internal_id,
			"Hero fixture entity %d failed to add" % entity.internal_id)
	_check(sim.economy.register_completed_entity(sim.state, 1).is_empty(),
		"Hero altar failed economy registration")
	_check(sim.register_hero(10, "marshal", "z-marshal").is_empty(),
		"Marshal failed Hero registration")

	var marshal_record: Dictionary = sim.state.heroes.heroes[10]
	_check(marshal.max_hp == 975 and marshal.max_mana == 305,
		"Marshal Strength/Intellect derived pools are wrong")
	_check(int(marshal_record["derived"]["armor_centi"]) == 225,
		"Marshal Agility-derived armor is wrong")
	_check(int(marshal_record["derived"]["attack_damage"]) == 33,
		"Marshal primary-attribute damage is wrong")
	_check(int(marshal_record["derived"]["attack_speed_bp"]) == 1_500,
		"Marshal Agility-derived attack speed is wrong")

	_check(bool(sim.heroes.learn_ability(
		sim.state, 0, 10, "marshal_command_aura"
	)["accepted"]), "level-one normal Hero ability was rejected")
	var xp_receipt: Dictionary = sim.heroes.award_xp(sim.state, 0, [5_250, 3_250], 500)
	_check(bool(xp_receipt["accepted"]) and int(marshal_record["level"]) == 3,
		"Hero XP did not cross levels two and three")
	_check(int(marshal_record["skill_points"]) == 2,
		"multi-level XP did not award one skill point per level")
	_check(bool(sim.heroes.learn_ability(
		sim.state, 0, 10, "marshal_command_aura"
	)["accepted"]), "rank-two normal ability was rejected at level three")
	_check(bool(sim.heroes.learn_ability(
		sim.state, 0, 10, "marshal_shield_strike"
	)["accepted"]), "second normal ability was rejected")
	var early_ultimate: Dictionary = sim.heroes.learn_ability(
		sim.state, 0, 10, "marshal_last_standard"
	)
	_check(not bool(early_ultimate["accepted"]), "ultimate was learnable before level six")

	_check(sim.register_hero(20, "high_arcanist", "a-arcanist").is_empty(),
		"High Arcanist failed Hero registration")
	var marshal_xp_before := int(marshal_record["xp"])
	var arcanist_record: Dictionary = sim.state.heroes.heroes[20]
	var split: Dictionary = sim.heroes.award_xp(sim.state, 0, [6_250, 3_250], 5)
	_check(bool(split["accepted"]), "two-Hero XP split was rejected")
	_check(int(arcanist_record["xp"]) == 3 and int(marshal_record["xp"]) == marshal_xp_before + 2,
		"opaque-key XP remainder ordering is wrong")

	var charm: Dictionary = sim.heroes.grant_item(sim.state, 10, "charm_of_might")
	_check(bool(charm["accepted"]) and marshal.max_hp == 1_160,
		"passive Strength item did not preserve level-scaled derived HP")
	var charm_id := str(charm["details"]["item"]["item_instance_id"])
	var dropped: Dictionary = sim.heroes.drop_item(
		sim.state, 10, charm_id, [marshal.position_x_mt, marshal.position_y_mt], sim.state.tick
	)
	_check(bool(dropped["accepted"]) and marshal.max_hp == 1_110,
		"item drop did not remove passive derived stats")
	_check(bool(sim.heroes.pick_up_item(
		sim.state, 10, int(dropped["details"]["item_entity_id"])
	)["accepted"]), "in-range ground item pickup was rejected")
	_check(marshal.max_hp == 1_160, "item pickup did not restore passive derived stats")

	var edge: Dictionary = sim.heroes.grant_item(sim.state, 10, "edge_stone")
	var edge_id := str(edge["details"]["item"]["item_instance_id"])
	_check(bool(sim.heroes.transfer_item(
		sim.state, 0, 10, 20, edge_id
	)["accepted"]), "in-range Hero item transfer was rejected")
	var gold_before_sale := int(sim.state.economy.players[0]["gold"])
	var sold: Dictionary = sim.heroes.sell_item(sim.state, 0, 20, 30, edge_id)
	_check(bool(sold["accepted"]) and int(sim.state.economy.players[0]["gold"]) == gold_before_sale + 100,
		"item sale did not grant its locked sell value")

	var focus: Dictionary = sim.heroes.grant_item(sim.state, 10, "lesser_focus_draught")
	var focus_id := str(focus["details"]["item"]["item_instance_id"])
	marshal.mana = 0
	_check(bool(sim.heroes.use_item(
		sim.state, 0, 10, focus_id, sim.state.tick
	)["accepted"]), "focus draught was rejected")
	for _tick: int in 4:
		sim.step_tick()
	_check(marshal.mana == 3, "integer-accumulator mana restore schedule is wrong")
	sim.heroes.notify_damage(sim.state, 10)
	_check(sim.state.heroes.periodic_effects.is_empty(),
		"damage did not interrupt a breakable focus draught")

	var vitality: Dictionary = sim.heroes.grant_item(sim.state, 20, "lesser_vitality_draught")
	var vitality_id := str(vitality["details"]["item"]["item_instance_id"])
	arcanist.hp = 100
	_check(bool(sim.heroes.use_item(
		sim.state, 0, 20, vitality_id, sim.state.tick
	)["accepted"]), "vitality draught was rejected")
	_check(arcanist.hp == 300, "immediate vitality restoration is wrong")

	var retained_item_count := (marshal_record["inventory"] as Array).size()
	marshal.hp = 0
	var death_tick := sim.state.tick
	sim.step_tick()
	_check(not marshal.alive and int(marshal_record["death_tick"]) == death_tick,
		"phase-10 Hero death metadata is wrong")
	_check((marshal_record["inventory"] as Array).size() == retained_item_count,
		"Hero death discarded retained inventory")
	var gold_before_revival := int(sim.state.economy.players[0]["gold"])
	var revival: Dictionary = sim.heroes.start_altar_revival(
		sim.state, 0, 1, 10, sim.state.tick
	)
	_check(bool(revival["accepted"]), "altar revival was rejected")
	_check(int(revival["details"]["cost_gold"]) == 255,
		"level-three altar revival cost is wrong")
	_check(int(revival["details"]["duration_ticks"]) == 350,
		"level-three altar revival duration is wrong")
	_check(int(sim.state.economy.players[0]["gold"]) == gold_before_revival - 255,
		"altar revival was not paid at acceptance")
	for _tick: int in 350:
		sim.step_tick()
	_check(marshal.alive and int(marshal_record["death_tick"]) == -1,
		"altar revival did not complete at its exact duration")
	@warning_ignore("integer_division")
	var expected_revival_mana := marshal.max_mana / 4
	_check(marshal.hp == marshal.max_hp and marshal.mana == expected_revival_mana,
		"altar revival return HP/mana percentages are wrong")
	_check(not sim.state.heroes.revivals.has(10), "completed revival remained queued")
	marshal.hp = marshal.max_hp - 100
	marshal.mana = 0
	for _tick: int in 200:
		sim.step_tick()
	_check(marshal.hp == marshal.max_hp - 40,
		"Strength regeneration did not use its 100-tick integer accumulator")
	_check(marshal.mana == 20,
		"Intellect regeneration did not use its 200-tick integer accumulator")

	var validation := sim.validate()
	_check(validation.is_empty(), "Hero scenario validation failed: %s" % "; ".join(validation))
	var counts: Dictionary = {}
	for event_variant: Variant in sim.state.events:
		var kind := str(event_variant.event_kind)
		counts[kind] = int(counts.get(kind, 0)) + 1
	var summary := {
		"arcanist_xp": int(arcanist_record["xp"]),
		"events": sim.state.events.size(),
		"gold": int(sim.state.economy.players[0]["gold"]),
		"hero_deaths": int(counts.get("hero_died", 0)),
		"hero_revivals": int(counts.get("hero_revived", 0)),
		"marshal_hp": marshal.hp,
		"marshal_inventory": (marshal_record["inventory"] as Array).size(),
		"marshal_level": int(marshal_record["level"]),
		"marshal_mana": marshal.mana,
		"marshal_xp": int(marshal_record["xp"]),
		"tick": sim.state.tick,
	}
	return {"hash": sim.checkpoint_hash(), "summary": summary}


func _entity(
	entity_id: int,
	owner_seat: int,
	kind: String,
	catalog_id: String,
	x_mt: int,
	y_mt: int,
	hp: int,
	radius_mt: int,
	tags: Array[String]
) -> EntityRecord:
	var entity := EntityRecord.new(entity_id, owner_seat, kind)
	entity.catalog_id = catalog_id
	entity.max_hp = hp
	entity.hp = hp
	entity.radius_mt = radius_mt
	entity.set_position_mt(x_mt, y_mt)
	entity.tags.assign(tags)
	return entity


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
