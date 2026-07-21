extends SceneTree

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const KeyedRandom := preload("res://scripts/duel/simulation/duel_keyed_random.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const DeltaRecord := preload("res://scripts/duel/simulation/duel_delta.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")
const MapLoader := preload("res://scripts/duel/simulation/duel_map_loader.gd")
const Pathfinder := preload("res://scripts/duel/simulation/duel_pathfinder.gd")
const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")

const GOLDEN_CANONICAL_HASH := "562e2d659a2093013b935f5f717e20cb92c02f9cc687963f93bfbca5a30f0cf3"
const GOLDEN_CHECKPOINT_HASH := "0e13e7bfa235e9e67fe8e549d52470b42c7774d47aca37b05698bd8277f7f0d1"

var _failures := PackedStringArray()


func _init() -> void:
	_test_rules_and_canonical_codec()
	_test_keyed_randomness()
	_test_map_loading_and_occupancy()
	_test_rle_map_loading()
	_test_official_map_artifact()
	_test_path_ties_and_corner_cutting()
	var stable_hash := _test_tick_order_and_repeatability()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_CORE_FAILURE: %s" % failure)
		print("DUEL_CORE_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("DUEL_CORE_OK hash=%s" % stable_hash)
	quit(0)


func _test_rules_and_canonical_codec() -> void:
	_check(Rules.PROTOCOL_VERSION == "worldeval-rts/1.0.0", "wire protocol version is not frozen")
	var config := Rules.merge_with_defaults({
		"grid_width": 5,
		"grid_height": 4,
		"match_seed": 42,
	})
	_check(Rules.validate_config(config).is_empty(), "valid unscored core config was rejected")
	var bad_config := config.duplicate(true)
	bad_config["tick_hz"] = 20
	_check(not Rules.validate_config(bad_config).is_empty(), "non-10-Hz config was accepted")

	var first := {
		"nested": {"z": true, "x": "line\n"},
		"b": 2,
		"a": 1,
	}
	var second := {
		"a": 1,
		"b": 2,
		"nested": {"x": "line\n", "z": true},
	}
	var expected := "{\"a\":1,\"b\":2,\"nested\":{\"x\":\"line\\n\",\"z\":true}}"
	_check(Codec.canonical_json(first) == expected, "canonical JSON bytes do not match fixture")
	_check(Codec.canonical_json(first) == Codec.canonical_json(second), "dictionary insertion order changed canonical JSON")
	_check(Codec.sha256_canonical(first) == Codec.sha256_canonical(second), "dictionary insertion order changed canonical hash")
	_check(Codec.sha256_canonical(first) == GOLDEN_CANONICAL_HASH, "canonical SHA-256 fixture changed")
	var unicode_keys := {"": 2, "😀": 1}
	_check(
		Codec.canonical_json(unicode_keys) == "{\"😀\":1,\"\":2}",
		"JCS property ordering did not use UTF-16 code units"
	)
	_check(not Codec.validate_canonical_value({"float": 1.5}).is_empty(), "authoritative float was accepted")
	_check(
		not Codec.validate_canonical_value({"unsafe": 9_007_199_254_740_992}).is_empty(),
		"integer outside the restricted JCS range was accepted"
	)


func _test_keyed_randomness() -> void:
	var key := PackedByteArray()
	key.resize(20)
	key.fill(0x0b)
	var rfc_hmac := KeyedRandom.hmac_sha256_hex(key, "Hi There".to_utf8_buffer())
	_check(
		rfc_hmac == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
		"HMAC-SHA256 does not match RFC 4231"
	)
	var digest_a := KeyedRandom.stream_digest("rules", 7, "map", 10, 4, "site-a")
	var digest_b := KeyedRandom.stream_digest("rules", 7, "map", 10, 4, "site-a")
	var digest_other := KeyedRandom.stream_digest("rules", 7, "neutral", 10, 4, "site-a")
	_check(digest_a == digest_b, "keyed stream was not repeatable")
	_check(digest_a != digest_other, "independent keyed streams collided in fixture")


func _test_map_loading_and_occupancy() -> void:
	var cells: Array = []
	for y: int in 2:
		for x: int in 3:
			cells.append({
				"air_pathable": true,
				"buildable_site_id": null,
				"destructible_id": null,
				"elevation": 0,
				"ground_pathable": true,
				"los_block_height": 0,
				"region_id": "test",
				"terrain_cost_permille": 1_000,
				"terrain_id": "plain",
				"x": x,
				"y": y,
			})
	var manifest := {
		"grid": {
			"cell_size_mt": 500,
			"cells": cells,
			"height": 2,
			"width": 3,
		},
		"map_id": "fixture",
	}
	var result := MapLoader.load_manifest(manifest)
	_check(bool(result["ok"]), "complete map manifest was rejected")
	if not bool(result["ok"]):
		return
	var grid: OccupancyGrid = result["grid"]
	_check(grid.reserve_ground_actor(4, 250, 250, 0), "legal occupancy reservation failed")
	_check(not grid.reserve_ground_actor(5, 250, 250, 0), "overlapping occupancy reservation succeeded")
	_check(grid.occupied_actor_ids(0, 0) == [4], "occupancy IDs were not canonical")
	_check(grid.release_ground_actor(4), "occupancy release failed")
	_check(grid.reserve_ground_actor(5, 250, 250, 0), "released occupancy remained blocked")
	_check(grid.release_ground_actor(5), "second occupancy release failed")
	_check(grid.reserve_ground_actor_cells(6, [[0, 0], [1, 0], [0, 1], [1, 1]]),
		"exact authored structure footprint reservation failed")
	_check(grid.ground_cells_for_actor(6) == [0, 1, 3, 4],
		"exact authored footprint node IDs are wrong")
	_check(not grid.explicit_ground_cells_fit([[1, 1], [2, 1]]),
		"overlapping authored structure footprint was accepted")
	_check(not grid.reserve_ground_actor_cells(7, [[2, 1], [2, 1]]),
		"duplicate authored footprint cells were accepted")
	_check(grid.release_ground_actor(6), "authored structure footprint release failed")

	var boundary_grid := OccupancyGrid.new()
	boundary_grid.configure(3, 2)
	_check(
		boundary_grid.footprint_cells_for_center_mt(500, 250, 0) == [0, 1],
		"closed-square boundary footprint did not occupy both touching cells"
	)
	_check(boundary_grid.reserve_ground_actor(9, 500, 250, 0), "boundary reservation failed")
	_check(boundary_grid.occupied_actor_ids(0, 0) == [9], "left boundary cell was not reserved")
	_check(boundary_grid.occupied_actor_ids(1, 0) == [9], "right boundary cell was not reserved")

	var invalid_manifest := manifest.duplicate(true)
	invalid_manifest["grid"]["cells"][5]["x"] = 1
	var invalid_result := MapLoader.load_manifest(invalid_manifest)
	_check(not bool(invalid_result["ok"]), "duplicate/missing map cell was accepted")


func _test_path_ties_and_corner_cutting() -> void:
	var grid := OccupancyGrid.new()
	_check(grid.configure(5, 5).is_empty(), "path test grid failed to configure")
	grid.set_ground_pathable(2, 2, false)
	var pathfinder := Pathfinder.new(grid)
	var tied_path := pathfinder.find_path(Vector2i(1, 2), Vector2i(3, 2), 0)
	var expected: Array[Vector2i] = [
		Vector2i(1, 2), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(3, 2),
	]
	_check(tied_path == expected, "A* did not choose the frozen north-side tie route: %s" % str(tied_path))
	_check(pathfinder.path_cost(tied_path) == 4_000, "tied route cost was incorrect")

	var corner_grid := OccupancyGrid.new()
	corner_grid.configure(3, 3)
	corner_grid.set_ground_pathable(1, 0, false)
	var corner_path := Pathfinder.new(corner_grid).find_path(Vector2i(0, 0), Vector2i(1, 1), 0)
	_check(corner_path.size() == 3, "A* cut a blocked diagonal corner")
	_check(corner_path[1] == Vector2i(0, 1), "corner detour was not deterministic")

	var nearest := pathfinder.nearest_fitting_cell(1_000, 1_000, 0)
	_check(nearest == Vector2i(1, 1), "nearest-goal tie did not use (distance_squared,y,x)")


func _test_rle_map_loading() -> void:
	var rows: Array = []
	rows.append([0, 1, 1, Rules.OFFICIAL_GRID_WIDTH - 1])
	for y: int in range(1, Rules.OFFICIAL_GRID_HEIGHT):
		rows.append([1, Rules.OFFICIAL_GRID_WIDTH])
	var manifest := {
		"cell_palette_fields": [
			"terrain_id", "elevation", "ground_pathable", "air_pathable",
			"buildable_site_id", "region_id", "los_block_height", "destructible_id",
			"rotated_palette_index",
		],
		"cell_palette": [
			["slow", 0, true, true, null, "fixture", 0, null, 0],
			["road", 0, true, true, null, "fixture", 0, null, 1],
		],
		"coordinate_system": {"cell_size_mt": Rules.CELL_SIZE_MT},
		"grid": {
			"encoding": "row_rle_palette_v1",
			"height": Rules.OFFICIAL_GRID_HEIGHT,
			"rows": rows,
			"width": Rules.OFFICIAL_GRID_WIDTH,
		},
		"terrain_catalog": {
			"road": {
				"air_pathable": true,
				"ground_pathable": true,
				"los_block_height": 0,
				"movement_basis_points": 900,
			},
			"slow": {
				"air_pathable": true,
				"ground_pathable": true,
				"los_block_height": 0,
				"movement_basis_points": 1_200,
			},
		},
	}
	var result := MapLoader.load_manifest(manifest)
	_check(bool(result["ok"]), "valid row_rle_palette_v1 fixture was rejected")
	if bool(result["ok"]):
		var grid: OccupancyGrid = result["grid"]
		_check(grid.terrain_cost_permille(0, 0) == 1_200, "RLE first run decoded out of order")
		_check(grid.terrain_cost_permille(1, 0) == 900, "RLE second run decoded out of order")
		_check(grid.terrain_cost_permille(0, 1) == 900, "RLE row order decoded incorrectly")
		_check(grid.minimum_ground_terrain_cost_permille() == 900, "RLE terrain minimum was wrong")
	var invalid := manifest.duplicate(true)
	invalid["grid"]["rows"][0][1] = 0
	_check(not bool(MapLoader.load_manifest(invalid)["ok"]), "non-positive RLE run was accepted")


func _test_official_map_artifact() -> void:
	var path := "res://../game/duel_protocol/maps/crossroads-duel-v1.json"
	_check(FileAccess.file_exists(path), "official map artifact is missing")
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	_check(file != null, "official map artifact could not be opened")
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_check(typeof(parsed) == TYPE_DICTIONARY, "official map artifact is not valid JSON")
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var result := MapLoader.load_manifest(parsed)
	_check(
		bool(result["ok"]),
		"official map artifact could not be decoded by DuelMapLoader: %s" % "; ".join(result["errors"])
	)
	if bool(result["ok"]):
		var grid: OccupancyGrid = result["grid"]
		_check(
			grid.width == Rules.OFFICIAL_GRID_WIDTH and grid.height == Rules.OFFICIAL_GRID_HEIGHT,
			"official map decoded with wrong dimensions"
		)


func _test_tick_order_and_repeatability() -> String:
	var first := _build_repeatability_sim(false)
	var second := _build_repeatability_sim(true)
	_check(first.last_errors.is_empty(), "first simulation reset failed")
	_check(second.last_errors.is_empty(), "second simulation reset failed")
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "shuffled construction changed initial checkpoint")
	var initial_checkpoint := first.checkpoint_hash()

	var first_summary := first.step_tick()
	var second_summary := second.step_tick()
	var expected_phases: Array[int] = []
	for phase: Dictionary in Rules.TICK_PHASES:
		expected_phases.append(int(phase["id"]))
	_check(first_summary["phase_ids"] == expected_phases, "tick phases ran out of normative order")
	_check(first_summary["pre_tick_state_hash"] == initial_checkpoint, "frozen pre-tick hash omitted authority state")
	_check(first_summary == second_summary, "shuffled construction changed tick summary")
	_check(first.checkpoint_hash() == second.checkpoint_hash(), "shuffled construction changed tick checkpoint")

	first.step_tick()
	second.step_tick()
	var stable_hash := first.checkpoint_hash()
	_check(stable_hash == second.checkpoint_hash(), "repeatability diverged on second tick")
	_check(
		stable_hash == GOLDEN_CHECKPOINT_HASH,
		"golden checkpoint hash changed: %s" % stable_hash
	)
	_check(first.state.tick == 2, "tick counter did not advance exactly twice")
	_check(first.state.events.size() == 4, "expected activation and delta events were not emitted")
	_check(first.validate().is_empty(), "completed core simulation failed validation")

	var before_mutation := stable_hash
	var entity: EntityRecord = first.state.entities[10]
	entity.hp -= 1
	_check(first.checkpoint_hash() != before_mutation, "authoritative HP mutation did not change checkpoint")
	return stable_hash


func _build_repeatability_sim(reverse_insertion: bool) -> Simulation:
	var sim := Simulation.new({
		"grid_height": 6,
		"grid_width": 6,
		"match_seed": 91_337,
	})
	var entity_10 := EntityRecord.new(10, 0, "unit")
	entity_10.catalog_id = "placeholder-worker"
	entity_10.radius_mt = 0
	entity_10.max_hp = 100
	entity_10.hp = 100
	entity_10.set_position_mt(750, 750)
	var entity_20 := EntityRecord.new(20, 1, "unit")
	entity_20.catalog_id = "placeholder-worker"
	entity_20.radius_mt = 0
	entity_20.max_hp = 100
	entity_20.hp = 100
	entity_20.set_position_mt(2_750, 2_750)
	if reverse_insertion:
		sim.add_entity(entity_20)
		sim.add_entity(entity_10)
	else:
		sim.add_entity(entity_10)
		sim.add_entity(entity_20)

	var order_10 := OrderRecord.new(7, 0, 10, "hold")
	order_10.issued_tick = 0
	order_10.activation_tick = 0
	order_10.command_index = 1
	order_10.command_digest = Codec.sha256_text("order-10")
	var order_20 := OrderRecord.new(8, 1, 20, "hold")
	order_20.issued_tick = 0
	order_20.activation_tick = 0
	order_20.command_index = 0
	order_20.command_digest = Codec.sha256_text("order-20")
	if reverse_insertion:
		sim.queue_order(order_20)
		sim.queue_order(order_10)
	else:
		sim.queue_order(order_10)
		sim.queue_order(order_20)

	var delta_10 := DeltaRecord.new()
	delta_10.application_tick = 0
	delta_10.entity_id = 10
	delta_10.kind = DeltaRecord.Kind.HP
	delta_10.amount = -9
	delta_10.source_internal_id = 20
	delta_10.local_seq = 1
	var delta_20 := DeltaRecord.new()
	delta_20.application_tick = 0
	delta_20.entity_id = 20
	delta_20.kind = DeltaRecord.Kind.MANA
	delta_20.amount = 0
	delta_20.source_internal_id = 10
	delta_20.local_seq = 2
	if reverse_insertion:
		sim.queue_delta(delta_20)
		sim.queue_delta(delta_10)
	else:
		sim.queue_delta(delta_10)
		sim.queue_delta(delta_20)
	return sim


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
