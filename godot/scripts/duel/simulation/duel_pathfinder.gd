class_name DuelPathfinder
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")

var grid: OccupancyGrid


func _init(p_grid: OccupancyGrid = null) -> void:
	grid = p_grid


func set_grid(p_grid: OccupancyGrid) -> void:
	grid = p_grid


## Returns traversal-order cells including start and goal, or an empty array
## when no legal route exists. Every comparison uses the frozen A* key:
## (f_cost, h_cost, turn_count, node_y, node_x, node_id).
func find_path(
	start: Vector2i,
	goal: Vector2i,
	radius_mt: int = 0,
	ignored_actor_id: int = 0
) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if grid == null:
		return empty
	if not grid.in_bounds(start.x, start.y) or not grid.in_bounds(goal.x, goal.y):
		return empty
	if not grid.fits_ground_footprint(start.x, start.y, radius_mt, ignored_actor_id):
		return empty
	if not grid.fits_ground_footprint(goal.x, goal.y, radius_mt, ignored_actor_id):
		return empty
	if start == goal:
		return [start]

	var start_id := grid.node_id(start.x, start.y)
	var goal_id := grid.node_id(goal.x, goal.y)
	var open_heap: Array[Dictionary] = []
	var g_score: Dictionary = {start_id: 0}
	var turn_score: Dictionary = {start_id: 0}
	var incoming_direction: Dictionary = {start_id: -1}
	var came_from: Dictionary = {}
	var closed: Dictionary = {}
	var heuristic_terrain_cost := grid.minimum_ground_terrain_cost_permille()

	var start_h := _scaled_octile_heuristic(start, goal, heuristic_terrain_cost)
	_heap_push(open_heap, _record(start_id, start, 0, start_h, 0, -1))

	while not open_heap.is_empty():
		var current_record := _heap_pop(open_heap)
		var current_id := int(current_record["node_id"])
		if closed.has(current_id):
			continue
		if not g_score.has(current_id):
			continue
		if int(current_record["g_cost"]) != int(g_score[current_id]) \
			or int(current_record["turn_count"]) != int(turn_score[current_id]):
			continue

		var current := Vector2i(int(current_record["node_x"]), int(current_record["node_y"]))
		if current_id == goal_id:
			return _reconstruct(came_from, current_id)
		closed[current_id] = true

		var current_direction := int(incoming_direction[current_id])
		for neighbor: Dictionary in Rules.NEIGHBORS:
			var next := Vector2i(
				current.x + int(neighbor["dx"]),
				current.y + int(neighbor["dy"])
			)
			if not grid.fits_ground_footprint(next.x, next.y, radius_mt, ignored_actor_id):
				continue
			if bool(neighbor["diagonal"]) and not _diagonal_is_legal(
				current, int(neighbor["dx"]), int(neighbor["dy"]), radius_mt, ignored_actor_id
			):
				continue

			var next_id := grid.node_id(next.x, next.y)
			if closed.has(next_id):
				continue
			var step_cost := _scaled_step_cost(
				int(neighbor["base_cost"]), grid.terrain_cost_permille(next.x, next.y)
			)
			var tentative_g := int(g_score[current_id]) + step_cost
			var next_direction := int(neighbor["direction"])
			var tentative_turns := int(turn_score[current_id])
			if current_direction >= 0 and current_direction != next_direction:
				tentative_turns += 1

			var is_better := not g_score.has(next_id)
			if not is_better and tentative_g < int(g_score[next_id]):
				is_better = true
			elif not is_better and tentative_g == int(g_score[next_id]) \
				and tentative_turns < int(turn_score[next_id]):
				is_better = true
			if not is_better:
				continue

			came_from[next_id] = current_id
			g_score[next_id] = tentative_g
			turn_score[next_id] = tentative_turns
			incoming_direction[next_id] = next_direction
			var h_cost := _scaled_octile_heuristic(next, goal, heuristic_terrain_cost)
			_heap_push(
				open_heap,
				_record(next_id, next, tentative_g, h_cost, tentative_turns, next_direction)
			)
	return empty


func nearest_fitting_cell(
	requested_x_mt: int,
	requested_y_mt: int,
	radius_mt: int = 0,
	ignored_actor_id: int = 0
) -> Vector2i:
	if grid == null:
		return Vector2i(-1, -1)
	var best := Vector2i(-1, -1)
	var best_distance_squared: int = 9_223_372_036_854_775_807
	for y: int in grid.height:
		for x: int in grid.width:
			if not grid.fits_ground_footprint(x, y, radius_mt, ignored_actor_id):
				continue
			var center := grid.cell_center_mt(x, y)
			var dx := center.x - requested_x_mt
			var dy := center.y - requested_y_mt
			var distance_squared := dx * dx + dy * dy
			if distance_squared < best_distance_squared:
				best_distance_squared = distance_squared
				best = Vector2i(x, y)
			elif distance_squared == best_distance_squared and (
				y < best.y or (y == best.y and x < best.x)
			):
				best = Vector2i(x, y)
	return best


func path_cost(path: Array[Vector2i]) -> int:
	if grid == null or path.size() < 2:
		return 0
	var result := 0
	for index: int in range(1, path.size()):
		var previous := path[index - 1]
		var current := path[index]
		var diagonal := absi(current.x - previous.x) == 1 and absi(current.y - previous.y) == 1
		var base_cost := Rules.DIAGONAL_COST if diagonal else Rules.CARDINAL_COST
		result += _scaled_step_cost(base_cost, grid.terrain_cost_permille(current.x, current.y))
	return result


static func octile_heuristic(from_cell: Vector2i, to_cell: Vector2i) -> int:
	var dx := absi(to_cell.x - from_cell.x)
	var dy := absi(to_cell.y - from_cell.y)
	var diagonal_steps := mini(dx, dy)
	var cardinal_steps := maxi(dx, dy) - diagonal_steps
	return diagonal_steps * Rules.DIAGONAL_COST + cardinal_steps * Rules.CARDINAL_COST


static func _scaled_octile_heuristic(
	from_cell: Vector2i,
	to_cell: Vector2i,
	terrain_cost_permille: int
) -> int:
	var dx := absi(to_cell.x - from_cell.x)
	var dy := absi(to_cell.y - from_cell.y)
	var diagonal_steps := mini(dx, dy)
	var cardinal_steps := maxi(dx, dy) - diagonal_steps
	return diagonal_steps * _scaled_step_cost(Rules.DIAGONAL_COST, terrain_cost_permille) \
		+ cardinal_steps * _scaled_step_cost(Rules.CARDINAL_COST, terrain_cost_permille)


static func canonical_path(path: Array[Vector2i]) -> Array:
	var result: Array = []
	for cell: Vector2i in path:
		result.append({"x": cell.x, "y": cell.y})
	return result


func _diagonal_is_legal(
	current: Vector2i,
	dx: int,
	dy: int,
	radius_mt: int,
	ignored_actor_id: int
) -> bool:
	return grid.fits_ground_footprint(
		current.x + dx, current.y, radius_mt, ignored_actor_id
	) and grid.fits_ground_footprint(
		current.x, current.y + dy, radius_mt, ignored_actor_id
	)


static func _record(
	node_id: int,
	cell: Vector2i,
	g_cost: int,
	h_cost: int,
	turn_count: int,
	direction: int
) -> Dictionary:
	return {
		"direction": direction,
		"f_cost": g_cost + h_cost,
		"g_cost": g_cost,
		"h_cost": h_cost,
		"node_id": node_id,
		"node_x": cell.x,
		"node_y": cell.y,
		"turn_count": turn_count,
	}


static func _record_less(left: Dictionary, right: Dictionary) -> bool:
	for key: String in ["f_cost", "h_cost", "turn_count", "node_y", "node_x", "node_id"]:
		var left_value := int(left[key])
		var right_value := int(right[key])
		if left_value != right_value:
			return left_value < right_value
	return false


static func _heap_push(heap: Array[Dictionary], record: Dictionary) -> void:
	heap.append(record)
	var index := heap.size() - 1
	while index > 0:
		@warning_ignore("integer_division")
		var parent: int = (index - 1) / 2
		if not _record_less(heap[index], heap[parent]):
			break
		var swap := heap[parent]
		heap[parent] = heap[index]
		heap[index] = swap
		index = parent


static func _heap_pop(heap: Array[Dictionary]) -> Dictionary:
	var root: Dictionary = heap[0]
	var tail: Dictionary = heap.pop_back()
	if heap.is_empty():
		return root
	heap[0] = tail
	var index := 0
	while true:
		var left := index * 2 + 1
		var right := left + 1
		var smallest := index
		if left < heap.size() and _record_less(heap[left], heap[smallest]):
			smallest = left
		if right < heap.size() and _record_less(heap[right], heap[smallest]):
			smallest = right
		if smallest == index:
			break
		var swap := heap[index]
		heap[index] = heap[smallest]
		heap[smallest] = swap
		index = smallest
	return root


func _reconstruct(came_from: Dictionary, goal_id: int) -> Array[Vector2i]:
	var reversed: Array[Vector2i] = [grid.cell_from_node_id(goal_id)]
	var current_id := goal_id
	while came_from.has(current_id):
		current_id = int(came_from[current_id])
		reversed.append(grid.cell_from_node_id(current_id))
	reversed.reverse()
	return reversed


static func _scaled_step_cost(base_cost: int, terrain_cost_permille: int) -> int:
	@warning_ignore("integer_division")
	return (base_cost * terrain_cost_permille) / Rules.TERRAIN_COST_BASE
