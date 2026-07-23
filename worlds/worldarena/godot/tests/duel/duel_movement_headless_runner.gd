extends SceneTree

const Simulation := preload("res://scripts/duel/simulation/duel_simulation.gd")
const EntityRecord := preload("res://scripts/duel/simulation/duel_entity.gd")
const OrderRecord := preload("res://scripts/duel/simulation/duel_order.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")

const GOLDEN_SCENARIO_HASH := "ce9d9e262c79ed534fec28dad2d73add01c4745df4fbf00e8a16d9e6f5cce5f3"
const TIE_KEY_TEXT := "worldarena-movement-protected-test-key-v1"

var _failures := PackedStringArray()
var _faction: Dictionary = {}
var _tie_key := PackedByteArray()


func _init() -> void:
	_faction = _load_json("res://../game/duel_protocol/catalogs/factions/vanguard-v1.json")
	_tie_key = TIE_KEY_TEXT.to_utf8_buffer()
	_test_integer_speed_remainder_and_terrain()
	_test_diagonal_corner_and_chokepoint()
	_test_head_on_swap_waits_without_overlap()
	_test_multi_claim_keyed_resolution()
	_test_air_altitude_capacity_and_terrain_independence()
	_test_route_invalidation_and_replan_offsets()
	_test_durable_order_executors()
	_test_closed_footprints_and_mirrored_motion()
	var first := _run_golden_scenario(false)
	var second := _run_golden_scenario(true)
	_check(first["hash"] == second["hash"], "shuffled insertion changed movement checkpoint")
	_check(first["summary"] == second["summary"], "shuffled insertion changed movement outcome")
	if not GOLDEN_SCENARIO_HASH.is_empty():
		_check(first["hash"] == GOLDEN_SCENARIO_HASH, "movement golden hash changed: %s" % first["hash"])
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_MOVEMENT_FAILURE: %s" % failure)
		print("DUEL_MOVEMENT_FAILED count=%d hash=%s" % [_failures.size(), first["hash"]])
		quit(1)
		return
	print("DUEL_MOVEMENT_OK hash=%s summary=%s" % [first["hash"], JSON.stringify(first["summary"])])
	quit(0)


func _test_integer_speed_remainder_and_terrain() -> void:
	var sim := _new_sim(10, 6)
	_add_mobile(sim, 10, 0, Vector2i(1_250, 1_250), "ground", 0, 333)
	sim.state.entities[10].integer_attributes["movement_speed_bp"] = -5_000
	_queue_point_order(sim, 101, 10, 0, "move", Vector2i(3_250, 1_250))
	sim.step_tick()
	_check(sim.state.entities[10].position_x_mt == 1_416, "first half-speed remainder tick rounded incorrectly")
	_check(int(sim.state.movement.actors[10]["speed_remainder_bp"]) == 5_000, "speed basis-point remainder was not checkpointed")
	sim.step_tick()
	_check(sim.state.entities[10].position_x_mt == 1_583, "second half-speed remainder tick did not recover the fractional mt")
	_check(int(sim.state.movement.actors[10]["speed_remainder_bp"]) == 0, "speed remainder did not cycle exactly")

	var road := _new_sim(8, 6)
	_set_terrain(road, 3, 2, "road", 900, true, true)
	_add_mobile(road, 10, 0, Vector2i(1_250, 1_250), "ground", 0, 250)
	_queue_point_order(road, 101, 10, 0, "move", Vector2i(1_750, 1_250))
	road.step_tick()
	_check(road.state.entities[10].position_x_mt == 1_527, "road movement did not use the 900 bp segment cost")

	var water := _new_sim(8, 6)
	_set_terrain(water, 3, 2, "shallow_water", 1_250, true, true)
	_add_mobile(water, 10, 0, Vector2i(1_250, 1_250), "ground", 0, 250)
	_queue_point_order(water, 101, 10, 0, "move", Vector2i(1_750, 1_250))
	water.step_tick()
	_check(water.state.entities[10].position_x_mt == 1_450, "shallow water did not use the 1250 bp segment cost")


func _test_diagonal_corner_and_chokepoint() -> void:
	var sim := _new_sim(7, 7)
	_set_terrain(sim, 2, 1, "wall", 1_000, false, true)
	_set_terrain(sim, 1, 2, "wall", 1_000, false, true)
	var blocked := sim.movement.static_find_path(
		sim.grid, Vector2i(1, 1), Vector2i(2, 2), 0, "ground"
	)
	_check(blocked.size() > 2 and blocked[1] != Vector2i(2, 2), "ground A* cut a tied diagonal corner")
	var air_path := sim.movement.static_find_path(
		sim.grid, Vector2i(1, 1), Vector2i(2, 2), 0, "air"
	)
	_check(air_path == [Vector2i(1, 1), Vector2i(2, 2)], "air pathing incorrectly obeyed ground corner blockers")

	var choke := _new_sim(9, 7)
	for y: int in choke.grid.height:
		if y != 3:
			_set_terrain(choke, 4, y, "wall", 1_000, false, true)
	var route := choke.movement.static_find_path(
		choke.grid, Vector2i(1, 3), Vector2i(7, 3), 0, "ground"
	)
	_check(not route.is_empty() and Vector2i(4, 3) in route, "deterministic route did not use the only chokepoint")


func _test_head_on_swap_waits_without_overlap() -> void:
	var sim := _new_sim(8, 5)
	_add_mobile(sim, 10, 0, Vector2i(1_250, 1_250), "ground", 0, 500)
	_add_mobile(sim, 20, 1, Vector2i(1_750, 1_250), "ground", 0, 500)
	_queue_point_order(sim, 101, 10, 0, "move", Vector2i(1_750, 1_250))
	_queue_point_order(sim, 102, 20, 1, "move", Vector2i(1_250, 1_250))
	for _tick: int in 3:
		sim.step_tick()
	_check(sim.state.entities[10].position_x_mt == 1_250, "head-on swap moved actor 10 into occupied space")
	_check(sim.state.entities[20].position_x_mt == 1_750, "head-on swap moved actor 20 into occupied space")
	_check(sim.state.movement.conflicts.is_empty(), "three-tick head-on conflict did not reset after keyed resolution")
	_check(_event_count(sim, "movement_conflict_ranked") == 1, "head-on conflict did not invoke the protected tie interface exactly once")
	_check(not _ground_overlap(sim, 10, 20), "head-on swap produced logical occupancy overlap")


func _test_multi_claim_keyed_resolution() -> void:
	var first := _multi_claim_sim(false)
	var second := _multi_claim_sim(true)
	for _tick: int in 3:
		first.step_tick()
		second.step_tick()
	var first_positions := [first.state.entities[10].position_x_mt, first.state.entities[20].position_x_mt]
	var second_positions := [second.state.entities[10].position_x_mt, second.state.entities[20].position_x_mt]
	_check(first_positions == second_positions, "multi-claim keyed result depended on insertion order")
	var arrivals := 0
	for position: int in first_positions:
		if position == 1_250:
			arrivals += 1
	_check(arrivals == 1, "three-tick multi-claim did not grant exactly one legal request")
	_check(not _ground_overlap(first, 10, 20), "multi-claim resolution created overlap")


func _test_air_altitude_capacity_and_terrain_independence() -> void:
	var capacity := _new_sim(8, 6)
	for index: int in 5:
		var entity_id := 10 + index
		var entity := _entity(entity_id, index % 2, Vector2i(1_250, 1_250), "air", 0)
		_check(capacity.add_entity(entity) == entity_id, "air entity failed core registration")
		var errors := capacity.register_movement_entity(
			entity_id, "unit", "footguard", {"layer": "air", "radius_mt": 0, "speed_mt_per_tick": 250}
		)
		if index < 4:
			_check(errors.is_empty(), "one of four altitude lanes was rejected")
		else:
			_check(not errors.is_empty(), "fifth actor entered a four-slot air cell")
	_check(capacity.state.movement.air_occupancy.size() == 1, "air occupancy did not use one logical cell")
	_check((capacity.state.movement.air_occupancy.values()[0] as Dictionary).size() == 4, "air cell did not reserve all four distinct lanes")

	var flying := _new_sim(8, 6)
	_set_terrain(flying, 3, 2, "deep_water", 1_400, false, true)
	_add_mobile(flying, 10, 0, Vector2i(1_250, 1_250), "air", 0, 250)
	_queue_point_order(flying, 101, 10, 0, "move", Vector2i(1_750, 1_250))
	flying.step_tick()
	_check(flying.state.entities[10].position_x_mt == 1_500, "flying movement used ground terrain cost")
	flying.step_tick()
	_check(flying.state.entities[10].position_x_mt == 1_750, "flying actor did not arrive across ground-unpathable terrain")


func _test_route_invalidation_and_replan_offsets() -> void:
	var invalidated := _new_sim(10, 7)
	_add_mobile(invalidated, 10, 0, Vector2i(750, 1_250), "ground", 0, 100)
	_queue_point_order(invalidated, 101, 10, 0, "move", Vector2i(3_750, 1_250))
	invalidated.step_tick()
	var blocked_point: Dictionary = invalidated.state.entities[10].route[invalidated.state.entities[10].route_index]
	_set_terrain(invalidated, int(blocked_point["x"]), int(blocked_point["y"]), "rubble_wall", 1_400, false, true)
	invalidated.step_tick()
	_check(int(invalidated.state.movement.actors[10]["path_generation"]) == 2, "closed next footprint did not force a pre-movement replan")
	var route_contains_blocked := false
	for point: Dictionary in invalidated.state.entities[10].route:
		if int(point["x"]) == int(blocked_point["x"]) and int(point["y"]) == int(blocked_point["y"]):
			route_contains_blocked = true
	_check(not route_contains_blocked, "forced route retained the newly closed cell")

	var offset := _new_sim(12, 8)
	_add_mobile(offset, 1, 0, Vector2i(750, 1_250), "ground", 0, 10)
	_add_mobile(offset, 2, 1, Vector2i(750, 2_750), "ground", 0, 10)
	_queue_point_order(offset, 101, 1, 0, "move", Vector2i(5_250, 1_250))
	_queue_point_order(offset, 102, 2, 1, "move", Vector2i(5_250, 2_750))
	offset.step_tick()
	_check(offset.state.entities[1].next_replan_tick == 1, "entity 1 replan offset is wrong")
	_check(offset.state.entities[2].next_replan_tick == 2, "entity 2 replan offset is wrong")
	offset.step_tick()
	_check(int(offset.state.movement.actors[1]["path_generation"]) == 2, "entity 1 did not replan on its offset tick")
	_check(int(offset.state.movement.actors[2]["path_generation"]) == 1, "entity 2 replanned before its offset tick")
	offset.step_tick()
	_check(int(offset.state.movement.actors[2]["path_generation"]) == 2, "entity 2 did not replan on its offset tick")


func _test_durable_order_executors() -> void:
	var attack_move := _new_sim(10, 6)
	_add_mobile(attack_move, 10, 0, Vector2i(750, 1_250), "ground", 0, 500)
	_queue_point_order(attack_move, 101, 10, 0, "attack_move", Vector2i(1_750, 1_250), [0, 500])
	for _tick: int in 3:
		attack_move.step_tick()
	_check(attack_move.state.entities[10].position_x_mt == 1_750 and attack_move.state.entities[10].position_y_mt == 1_750, "attack-move did not honor the compiled formation offset")
	_check(attack_move.state.orders[101].status == OrderRecord.Status.COMPLETED, "attack-move did not complete at the exact goal center")

	var patrol := _new_sim(10, 6)
	_add_mobile(patrol, 10, 0, Vector2i(750, 1_250), "ground", 0, 500)
	var patrol_order := OrderRecord.new(101, 0, 10, "patrol")
	patrol_order.activation_tick = 0
	patrol_order.command_digest = Codec.sha256_text("patrol")
	patrol_order.target = {"targets": [
		{"kind": "point", "xy_mt": [1_250, 1_250]},
		{"kind": "point", "xy_mt": [1_750, 1_250]},
	]}
	patrol.queue_order(patrol_order)
	for _tick: int in 3:
		patrol.step_tick()
	_check(patrol.state.orders[101].status == OrderRecord.Status.ACTIVE, "patrol was not durable")
	_check(int(patrol.state.movement.actors[10]["patrol_index"]) != 0, "patrol did not advance its traversal index")

	var follow := _new_sim(12, 6)
	_add_mobile(follow, 10, 0, Vector2i(750, 1_250), "ground", 0, 500)
	_add_mobile(follow, 20, 0, Vector2i(2_750, 1_250), "ground", 0, 0)
	var follow_order := OrderRecord.new(101, 0, 10, "follow")
	follow_order.activation_tick = 0
	follow_order.command_digest = Codec.sha256_text("follow")
	follow_order.target = {"distance_mt": 1_000, "entity_id": 20}
	follow.queue_order(follow_order)
	for _tick: int in 3:
		follow.step_tick()
	_check(follow.state.orders[101].status == OrderRecord.Status.ACTIVE, "follow was not durable")
	_check(follow.state.entities[10].position_x_mt == 1_750, "follow did not stop at the explicit distance")


func _test_closed_footprints_and_mirrored_motion() -> void:
	var closed := _new_sim(10, 7)
	_add_mobile(closed, 10, 0, Vector2i(1_250, 1_250), "ground", 350, 100)
	var touching := _entity(20, 1, Vector2i(2_250, 1_250), "ground", 350)
	_check(closed.add_entity(touching) == 0, "closed radius footprints allowed a shared logical boundary cell")
	_check((closed.state.movement.actors[10]["occupied_cells"] as Array).size() == 5, "350 mt closed circle did not reserve its exact cross footprint")

	var forward := _new_sim(10, 7)
	var mirrored := _new_sim(10, 7)
	_add_mobile(forward, 10, 0, Vector2i(1_250, 1_250), "ground", 0, 137)
	_add_mobile(mirrored, 10, 1, Vector2i(3_750, 1_250), "ground", 0, 137)
	_queue_point_order(forward, 101, 10, 0, "move", Vector2i(3_250, 1_250))
	_queue_point_order(mirrored, 101, 10, 1, "move", Vector2i(1_750, 1_250))
	for _tick: int in 2:
		forward.step_tick()
		mirrored.step_tick()
	var forward_distance: int = forward.state.entities[10].position_x_mt - 1_250
	var mirrored_distance: int = 3_750 - mirrored.state.entities[10].position_x_mt
	_check(forward_distance == mirrored_distance, "mirrored direction or owner changed integer movement distance")
	_check(forward.state.entities[10].segment_numerator == mirrored.state.entities[10].segment_numerator, "mirrored interpolation remainder diverged")


func _run_golden_scenario(reverse_insertion: bool) -> Dictionary:
	var sim := _new_sim(16, 10)
	_set_terrain(sim, 5, 2, "road", 900, true, true)
	_set_terrain(sim, 5, 6, "shallow_water", 1_250, true, true)
	var entities := [
		_entity(10, 0, Vector2i(750, 1_250), "ground", 0),
		_entity(20, 1, Vector2i(750, 3_250), "ground", 0),
		_entity(30, 0, Vector2i(750, 4_250), "air", 0),
	]
	if reverse_insertion:
		entities.reverse()
	for entity: EntityRecord in entities:
		_check(sim.add_entity(entity) == entity.internal_id, "golden entity failed to add")
		var layer := "air" if "air" in entity.tags else "ground"
		_check(sim.register_movement_entity(
			entity.internal_id, "unit", "footguard",
			{"layer": layer, "radius_mt": 0, "speed_mt_per_tick": 275 + entity.internal_id}
		).is_empty(), "golden movement entity failed to register")
	var orders := [
		_point_order(101, 10, 0, "move", Vector2i(3_750, 1_250)),
		_point_order(102, 20, 1, "attack_move", Vector2i(3_750, 3_250)),
		_point_order(103, 30, 0, "retreat", Vector2i(3_750, 4_250)),
	]
	if reverse_insertion:
		orders.reverse()
	for order: OrderRecord in orders:
		_check(sim.queue_order(order) == order.internal_order_id, "golden movement order failed to queue")
	for _tick: int in 12:
		sim.step_tick()
	var summary := {
		"air_lanes": sim.state.movement.air_occupancy.size(),
		"events": sim.state.events.size(),
		"p10": [sim.state.entities[10].position_x_mt, sim.state.entities[10].position_y_mt],
		"p20": [sim.state.entities[20].position_x_mt, sim.state.entities[20].position_y_mt],
		"p30": [sim.state.entities[30].position_x_mt, sim.state.entities[30].position_y_mt],
		"tick": sim.state.tick,
	}
	_check(sim.validate().is_empty(), "golden movement state failed validation")
	return {"hash": sim.checkpoint_hash(), "summary": summary}


func _multi_claim_sim(reverse_insertion: bool) -> Simulation:
	var sim := _new_sim(8, 5)
	var entities := [
		_entity(10, 0, Vector2i(750, 1_250), "ground", 0),
		_entity(20, 1, Vector2i(1_750, 1_250), "ground", 0),
	]
	if reverse_insertion:
		entities.reverse()
	for entity: EntityRecord in entities:
		sim.add_entity(entity)
		sim.register_movement_entity(entity.internal_id, "unit", "footguard", {"radius_mt": 0, "speed_mt_per_tick": 500})
	var orders := [
		_point_order(101, 10, 0, "move", Vector2i(1_250, 1_250)),
		_point_order(102, 20, 1, "move", Vector2i(1_250, 1_250)),
	]
	if reverse_insertion:
		orders.reverse()
	for order: OrderRecord in orders:
		sim.queue_order(order)
	return sim


func _new_sim(width: int, height: int) -> Simulation:
	var sim := Simulation.new({
		"grid_height": height,
		"grid_width": width,
		"match_seed": 73_901,
		"tie_key_commitment": Codec.sha256_bytes(_tie_key),
	})
	_check(sim.last_errors.is_empty(), "movement simulation reset failed")
	var movement_errors := sim.configure_movement(_faction, _tie_key)
	_check(movement_errors.is_empty(), "movement catalog configuration failed: %s" % "; ".join(movement_errors))
	return sim


func _add_mobile(
	sim: Simulation,
	entity_id: int,
	owner: int,
	position: Vector2i,
	layer: String,
	radius_mt: int,
	speed_mt_per_tick: int
) -> void:
	var entity := _entity(entity_id, owner, position, layer, radius_mt)
	_check(sim.add_entity(entity) == entity_id, "movement entity %d failed to add" % entity_id)
	_check(sim.register_movement_entity(
		entity_id,
		"unit",
		"footguard",
		{"layer": layer, "radius_mt": radius_mt, "speed_mt_per_tick": speed_mt_per_tick}
	).is_empty(), "movement entity %d failed to register" % entity_id)


func _entity(
	entity_id: int,
	owner: int,
	position: Vector2i,
	layer: String,
	radius_mt: int
) -> EntityRecord:
	var entity := EntityRecord.new(entity_id, owner, "unit")
	entity.catalog_id = "vanguard-footguard"
	entity.max_hp = 100
	entity.hp = 100
	entity.radius_mt = radius_mt
	entity.tags = [layer]
	entity.set_position_mt(position.x, position.y)
	return entity


func _queue_point_order(
	sim: Simulation,
	order_id: int,
	actor_id: int,
	owner: int,
	kind: String,
	target: Vector2i,
	formation_offset: Array[int] = []
) -> void:
	var order := _point_order(order_id, actor_id, owner, kind, target)
	if not formation_offset.is_empty():
		order.target["formation_offset_mt"] = formation_offset
	_check(sim.queue_order(order) == order_id, "movement point order failed to queue")


func _point_order(
	order_id: int,
	actor_id: int,
	owner: int,
	kind: String,
	target: Vector2i
) -> OrderRecord:
	var order := OrderRecord.new(order_id, owner, actor_id, kind)
	order.issued_tick = 0
	order.activation_tick = 0
	order.command_index = 0
	order.command_digest = Codec.sha256_text("%d|%d|%s" % [order_id, actor_id, kind])
	order.target = {"kind": "point", "xy_mt": [target.x, target.y]}
	return order


func _set_terrain(
	sim: Simulation,
	x: int,
	y: int,
	terrain_id: String,
	cost: int,
	ground_pathable: bool,
	air_pathable: bool
) -> void:
	sim.grid.set_cell_static(x, y, {
		"air_pathable": air_pathable,
		"elevation": 0,
		"ground_pathable": ground_pathable,
		"terrain_cost_permille": cost,
		"terrain_id": terrain_id,
	})


func _ground_overlap(sim: Simulation, left_id: int, right_id: int) -> bool:
	var left: Array = sim.state.movement.actors[left_id]["occupied_cells"]
	var right: Array = sim.state.movement.actors[right_id]["occupied_cells"]
	for cell_variant: Variant in left:
		if int(cell_variant) in right:
			return true
	return false


func _event_count(sim: Simulation, kind: String) -> int:
	var result := 0
	for event_variant: Variant in sim.state.events:
		if event_variant.event_kind == kind:
			result += 1
	return result


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	_check(file != null, "could not open %s" % path)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_check(typeof(parsed) == TYPE_DICTIONARY, "could not parse %s" % path)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var normalized := CatalogLoader.normalize_json_boundary(parsed)
	_check(bool(normalized["ok"]), "could not integer-normalize %s" % path)
	return normalized["value"] if bool(normalized["ok"]) else {}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
