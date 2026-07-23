extends SceneTree

const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const RuntimeCatalog := preload("res://scripts/duel/protocol/duel_runtime_catalog.gd")

const GOLDEN_SCENARIO_HASH := "a5d8dbca60523613910fae86fe3665650b234f2acdb535a6e05c421bbcf106f6"

var _failures := PackedStringArray()
var _rules: Dictionary = {}
var _economy_catalog: Dictionary = {}


func _init() -> void:
	var loaded := CatalogLoader.load_official_catalogs()
	_check(bool(loaded["ok"]), "official catalogs failed to load")
	if bool(loaded["ok"]):
		_rules = loaded["catalogs"]["rules"]
		var compiled := RuntimeCatalog.compile_selected_faction("vanguard-v1", loaded)
		_check(bool(compiled["ok"]), "official runtime catalog failed to compile")
		if bool(compiled["ok"]):
			_economy_catalog = compiled["runtime"]["economy"]
	_test_normal_and_double_destruction()
	_test_draw_clocks()
	_test_external_dispositions()
	var first := _golden(false)
	var second := _golden(true)
	_check(first["hash"] == second["hash"], "terminal outcome depends on insertion order")
	_check(first["terminal"] == second["terminal"], "terminal result depends on insertion order")
	if not GOLDEN_SCENARIO_HASH.is_empty():
		_check(first["hash"] == GOLDEN_SCENARIO_HASH,
			"terminal golden hash changed: %s" % first["hash"])
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_TERMINAL_FAILURE: %s" % failure)
		print("DUEL_TERMINAL_FAILED count=%d hash=%s" % [_failures.size(), first["hash"]])
		quit(1)
		return
	print("DUEL_TERMINAL_OK hash=%s terminal=%s" % [
		first["hash"], JSON.stringify(first["terminal"]),
	])
	quit(0)


func _test_normal_and_double_destruction() -> void:
	if _economy_catalog.is_empty():
		return
	var normal := _duel_sim(_rules)
	normal.state.entities[20].hp = 0
	normal.step_tick()
	_check(bool(normal.state.terminal["ended"]), "stronghold destruction did not end match")
	_check(normal.state.terminal["result"] == "normal" \
		and int(normal.state.terminal["winner_seat"]) == 0,
		"stronghold destruction selected the wrong winner")
	_check(_event_count(normal, "match_ended") == 1,
		"normal terminal transition did not emit one event")
	var stopped_tick := normal.state.tick
	var skipped: Dictionary = normal.step_tick()
	_check(bool(skipped.get("skipped_terminal", false)) and normal.state.tick == stopped_tick,
		"terminal simulation continued advancing")

	var double := _duel_sim(_rules)
	double.state.entities[10].hp = 0
	double.state.entities[20].hp = 0
	double.step_tick()
	_check(double.state.terminal["result"] == "draw" \
		and double.state.terminal["reason"] == "double_stronghold_destruction",
		"same-tick double stronghold destruction was not a draw")


func _test_draw_clocks() -> void:
	if _economy_catalog.is_empty():
		return
	var no_progress_rules := _rules.duplicate(true)
	no_progress_rules["termination"]["no_progress_draw_ticks"] = 2
	var no_progress := _duel_sim(no_progress_rules)
	no_progress.step_tick()
	_check(not bool(no_progress.state.terminal["ended"]),
		"no-progress draw ended one tick too early")
	no_progress.step_tick()
	_check(no_progress.state.terminal["reason"] == "no_progress",
		"no-progress threshold did not draw exactly")

	var time_rules := _rules.duplicate(true)
	time_rules["termination"]["maximum_match_ticks"] = 2
	time_rules["termination"]["no_progress_draw_ticks"] = 100
	var timed := _duel_sim(time_rules)
	timed.step_tick()
	_check(not bool(timed.state.terminal["ended"]), "time limit ended one tick too early")
	timed.step_tick()
	_check(timed.state.terminal["reason"] == "time_limit",
		"maximum match ticks did not draw exactly")


func _test_external_dispositions() -> void:
	if _economy_catalog.is_empty():
		return
	var forfeit := _duel_sim(_rules)
	_check(bool(forfeit.declare_technical_forfeit([1])["accepted"]),
		"single technical forfeit was rejected")
	_check(forfeit.state.terminal["result"] == "technical_forfeit" \
		and int(forfeit.state.terminal["winner_seat"]) == 0,
		"single technical forfeit selected the wrong winner")
	_check(_event_count(forfeit, "match_ended") == 1,
		"technical forfeit did not emit its terminal event immediately")
	var double := _duel_sim(_rules)
	double.declare_technical_forfeit([1, 0, 1])
	_check(double.state.terminal["result"] == "draw" \
		and double.state.terminal["reason"] == "double_technical_forfeit",
		"double technical forfeit was not a draw")
	var invalid := _duel_sim(_rules)
	_check(not bool(invalid.declare_technical_forfeit([2])["accepted"]) \
		and not bool(invalid.state.terminal["ended"]),
		"invalid technical-forfeit seat mutated the match")
	var voided := _duel_sim(_rules)
	voided.declare_infrastructure_void("monotonic_clock_discontinuity")
	_check(voided.state.terminal["result"] == "infrastructure_void" \
		and int(voided.state.terminal["winner_seat"]) == -1,
		"infrastructure void produced a winner")
	_check(_event_count(voided, "match_ended") == 1,
		"infrastructure void did not emit its terminal event immediately")


func _golden(reverse_insertion: bool) -> Dictionary:
	if _economy_catalog.is_empty():
		return {"hash": "", "terminal": {}}
	var sim := _duel_sim(_rules, reverse_insertion)
	sim.state.entities[20].hp = 0
	sim.step_tick()
	return {"hash": sim.checkpoint_hash(), "terminal": sim.terminal_result()}


func _duel_sim(rules: Dictionary, reverse_insertion: bool = false) -> Simulation:
	var sim := Simulation.new({"grid_height": 16, "grid_width": 32, "match_seed": 44})
	_check(sim.configure_economy(_economy_catalog).is_empty(), "economy failed to configure")
	_check(sim.configure_terminal(rules, _economy_catalog).is_empty(),
		"terminal rules failed to configure")
	for seat: int in [0, 1]:
		_check(bool(sim.economy.configure_player(sim.state, seat, 500, 200, 1)["accepted"]),
			"fixture player failed to configure")
	var entities: Array[EntityRecord] = [
		_stronghold(10, 0, 3_250, 3_250),
		_stronghold(20, 1, 12_250, 3_250),
	]
	if reverse_insertion:
		entities.reverse()
	for entity: EntityRecord in entities:
		_check(sim.add_entity(entity) == entity.internal_id,
			"fixture stronghold failed to add")
		_check(sim.economy.register_completed_entity(sim.state, entity.internal_id).is_empty(),
			"fixture stronghold failed to register")
	return sim


func _stronghold(entity_id: int, seat: int, x_mt: int, y_mt: int) -> EntityRecord:
	var definition: Dictionary = _economy_catalog["structures"]["citadel"]
	var entity := EntityRecord.new(entity_id, seat, "structure")
	entity.catalog_id = "citadel"
	entity.max_hp = int(definition["max_hp"])
	entity.hp = entity.max_hp
	entity.radius_mt = 0
	entity.tags.assign(definition["tags"])
	entity.set_position_mt(x_mt, y_mt)
	return entity


func _event_count(sim: Simulation, kind: String) -> int:
	var count := 0
	for event_variant: Variant in sim.state.events:
		if str(event_variant.event_kind) == kind:
			count += 1
	return count


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
