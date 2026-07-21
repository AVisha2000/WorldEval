class_name DuelOccupancyGrid
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")

var width: int = 0
var height: int = 0
var cell_size_mt: int = Rules.CELL_SIZE_MT
var revision: int = 0

var _terrain_ids: Array[String] = []
var _elevations := PackedInt32Array()
var _ground_pathable := PackedByteArray()
var _air_pathable := PackedByteArray()
var _terrain_costs := PackedInt32Array()
var _region_ids: Array[String] = []
var _build_site_ids: Array[String] = []
var _los_block_heights := PackedInt32Array()
var _destructible_ids: Array[String] = []

## cell node_id -> sorted Array[int] actor IDs.
var _ground_occupants: Dictionary = {}
## actor ID -> sorted Array[int] occupied cell node IDs.
var _actor_ground_cells: Dictionary = {}
var _minimum_ground_cost: int = Rules.TERRAIN_COST_BASE
var _minimum_ground_cost_dirty: bool = false


func configure(p_width: int, p_height: int, p_cell_size_mt: int = Rules.CELL_SIZE_MT) -> PackedStringArray:
	var errors := PackedStringArray()
	if p_width <= 0 or p_width > Rules.OFFICIAL_GRID_WIDTH:
		errors.append("grid width must be in [1, %d]" % Rules.OFFICIAL_GRID_WIDTH)
	if p_height <= 0 or p_height > Rules.OFFICIAL_GRID_HEIGHT:
		errors.append("grid height must be in [1, %d]" % Rules.OFFICIAL_GRID_HEIGHT)
	if p_cell_size_mt != Rules.CELL_SIZE_MT:
		errors.append("grid cell size must be %d mt" % Rules.CELL_SIZE_MT)
	if not errors.is_empty():
		return errors

	width = p_width
	height = p_height
	cell_size_mt = p_cell_size_mt
	revision = 0
	var count := width * height
	_terrain_ids.resize(count)
	_elevations.resize(count)
	_ground_pathable.resize(count)
	_air_pathable.resize(count)
	_terrain_costs.resize(count)
	_region_ids.resize(count)
	_build_site_ids.resize(count)
	_los_block_heights.resize(count)
	_destructible_ids.resize(count)
	_ground_occupants.clear()
	_actor_ground_cells.clear()
	_minimum_ground_cost = Rules.TERRAIN_COST_BASE
	_minimum_ground_cost_dirty = false
	for node_id: int in count:
		_terrain_ids[node_id] = "plain"
		_elevations[node_id] = 0
		_ground_pathable[node_id] = 1
		_air_pathable[node_id] = 1
		_terrain_costs[node_id] = Rules.TERRAIN_COST_BASE
		_region_ids[node_id] = ""
		_build_site_ids[node_id] = ""
		_los_block_heights[node_id] = 0
		_destructible_ids[node_id] = ""
	return errors


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func node_id(x: int, y: int) -> int:
	return y * width + x


func cell_from_node_id(id: int) -> Vector2i:
	if id < 0 or id >= width * height:
		return Vector2i(-1, -1)
	return Vector2i(id % width, id / width)


func cell_center_mt(x: int, y: int) -> Vector2i:
	return Vector2i(x * cell_size_mt + cell_size_mt / 2, y * cell_size_mt + cell_size_mt / 2)


func set_cell_static(x: int, y: int, data: Dictionary) -> bool:
	if not in_bounds(x, y):
		return false
	var id := node_id(x, y)
	_terrain_ids[id] = str(data.get("terrain_id", "plain"))
	_elevations[id] = int(data.get("elevation", 0))
	_ground_pathable[id] = 1 if bool(data.get("ground_pathable", true)) else 0
	_air_pathable[id] = 1 if bool(data.get("air_pathable", true)) else 0
	_terrain_costs[id] = int(data.get("terrain_cost_permille", Rules.TERRAIN_COST_BASE))
	_region_ids[id] = str(data.get("region_id", ""))
	_build_site_ids[id] = _nullable_string(data.get("buildable_site_id", null))
	_los_block_heights[id] = int(data.get("los_block_height", 0))
	_destructible_ids[id] = _nullable_string(data.get("destructible_id", null))
	_minimum_ground_cost_dirty = true
	revision += 1
	return true


func set_ground_pathable(x: int, y: int, pathable: bool) -> bool:
	if not in_bounds(x, y):
		return false
	_ground_pathable[node_id(x, y)] = 1 if pathable else 0
	_minimum_ground_cost_dirty = true
	revision += 1
	return true


func is_ground_pathable(x: int, y: int) -> bool:
	return in_bounds(x, y) and _ground_pathable[node_id(x, y)] == 1


func is_air_pathable(x: int, y: int) -> bool:
	return in_bounds(x, y) and _air_pathable[node_id(x, y)] == 1


func terrain_cost_permille(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return 0
	return _terrain_costs[node_id(x, y)]


func region_id_at_mt(x_mt: int, y_mt: int) -> String:
	if x_mt < 0 or y_mt < 0:
		return ""
	@warning_ignore("integer_division")
	var x := x_mt / cell_size_mt
	@warning_ignore("integer_division")
	var y := y_mt / cell_size_mt
	if not in_bounds(x, y):
		return ""
	return str(_region_ids[node_id(x, y)])


func minimum_ground_terrain_cost_permille() -> int:
	if not _minimum_ground_cost_dirty:
		return _minimum_ground_cost
	var minimum: int = 9_223_372_036_854_775_807
	for id: int in width * height:
		if _ground_pathable[id] == 1 and _terrain_costs[id] > 0:
			minimum = mini(minimum, int(_terrain_costs[id]))
	_minimum_ground_cost = Rules.TERRAIN_COST_BASE if minimum == 9_223_372_036_854_775_807 else minimum
	_minimum_ground_cost_dirty = false
	return _minimum_ground_cost


func occupied_actor_ids(x: int, y: int) -> Array[int]:
	if not in_bounds(x, y):
		return []
	var id := node_id(x, y)
	if not _ground_occupants.has(id):
		return []
	var result: Array[int] = []
	result.assign(_ground_occupants[id])
	return result


func footprint_cells_for_center_mt(center_x_mt: int, center_y_mt: int, radius_mt: int) -> Array[int]:
	var result: Array[int] = []
	if radius_mt < 0:
		return result
	## Squares are closed for footprint intersection, so a circle touching a
	## cell's maximum boundary occupies both cells on that boundary.
	var min_cell_x := _floor_div(center_x_mt - radius_mt - 1, cell_size_mt)
	var max_cell_x := _floor_div(center_x_mt + radius_mt, cell_size_mt)
	var min_cell_y := _floor_div(center_y_mt - radius_mt - 1, cell_size_mt)
	var max_cell_y := _floor_div(center_y_mt + radius_mt, cell_size_mt)
	min_cell_x = maxi(0, min_cell_x)
	max_cell_x = mini(width - 1, max_cell_x)
	min_cell_y = maxi(0, min_cell_y)
	max_cell_y = mini(height - 1, max_cell_y)
	var radius_squared := radius_mt * radius_mt
	for y: int in range(min_cell_y, max_cell_y + 1):
		for x: int in range(min_cell_x, max_cell_x + 1):
			var cell_min_x := x * cell_size_mt
			var cell_max_x := (x + 1) * cell_size_mt
			var cell_min_y := y * cell_size_mt
			var cell_max_y := (y + 1) * cell_size_mt
			var dx := 0
			var dy := 0
			if center_x_mt < cell_min_x:
				dx = cell_min_x - center_x_mt
			elif center_x_mt > cell_max_x:
				dx = center_x_mt - cell_max_x
			if center_y_mt < cell_min_y:
				dy = cell_min_y - center_y_mt
			elif center_y_mt > cell_max_y:
				dy = center_y_mt - cell_max_y
			if dx * dx + dy * dy <= radius_squared:
				result.append(node_id(x, y))
	result.sort()
	return result


func footprint_cells_at_cell(x: int, y: int, radius_mt: int) -> Array[int]:
	if not in_bounds(x, y):
		return []
	var center := cell_center_mt(x, y)
	return footprint_cells_for_center_mt(center.x, center.y, radius_mt)


func fits_ground_footprint(x: int, y: int, radius_mt: int, ignored_actor_id: int = 0) -> bool:
	if not in_bounds(x, y):
		return false
	var center := cell_center_mt(x, y)
	return fits_ground_footprint_at_position(center.x, center.y, radius_mt, ignored_actor_id)


func fits_ground_footprint_at_position(
	center_x_mt: int,
	center_y_mt: int,
	radius_mt: int,
	ignored_actor_id: int = 0
) -> bool:
	if radius_mt < 0:
		return false
	if center_x_mt < 0 or center_y_mt < 0 \
		or center_x_mt >= width * cell_size_mt or center_y_mt >= height * cell_size_mt:
		return false
	if center_x_mt - radius_mt < 0 or center_y_mt - radius_mt < 0:
		return false
	if center_x_mt + radius_mt > width * cell_size_mt \
		or center_y_mt + radius_mt > height * cell_size_mt:
		return false
	var footprint := footprint_cells_for_center_mt(center_x_mt, center_y_mt, radius_mt)
	if footprint.is_empty():
		return false
	for id: int in footprint:
		if _ground_pathable[id] == 0:
			return false
		if _ground_occupants.has(id):
			var occupants: Array = _ground_occupants[id]
			for actor_id_variant: Variant in occupants:
				if int(actor_id_variant) != ignored_actor_id:
					return false
	return true


func reserve_ground_actor(actor_id: int, center_x_mt: int, center_y_mt: int, radius_mt: int) -> bool:
	if actor_id <= 0 or _actor_ground_cells.has(actor_id):
		return false
	if not fits_ground_footprint_at_position(center_x_mt, center_y_mt, radius_mt, actor_id):
		return false
	var footprint := footprint_cells_for_center_mt(center_x_mt, center_y_mt, radius_mt)
	for id: int in footprint:
		var occupants: Array[int] = []
		if _ground_occupants.has(id):
			occupants.assign(_ground_occupants[id])
		occupants.append(actor_id)
		occupants.sort()
		_ground_occupants[id] = occupants
	_actor_ground_cells[actor_id] = footprint
	return true


## Structures use the exact authored map footprint, not a circular unit proxy.
## Cells may be `[x,y]`, `{x,y}`, or Vector2i values. Invalid, duplicated,
## blocked, or occupied cells reject the whole reservation atomically.
func reserve_ground_actor_cells(actor_id: int, cells: Array) -> bool:
	if actor_id <= 0 or _actor_ground_cells.has(actor_id):
		return false
	var normalized := _normalize_explicit_cells(cells)
	if not bool(normalized["ok"]):
		return false
	var footprint: Array[int] = normalized["node_ids"]
	for id: int in footprint:
		if _ground_pathable[id] == 0 or _ground_occupants.has(id):
			return false
	for id: int in footprint:
		_ground_occupants[id] = [actor_id]
	_actor_ground_cells[actor_id] = footprint
	return true


func explicit_ground_cells_fit(cells: Array, ignored_actor_id: int = 0) -> bool:
	var normalized := _normalize_explicit_cells(cells)
	if not bool(normalized["ok"]):
		return false
	for id: int in normalized["node_ids"]:
		if _ground_pathable[id] == 0:
			return false
		for occupant_variant: Variant in _ground_occupants.get(id, []):
			if int(occupant_variant) != ignored_actor_id:
				return false
	return true


func ground_cells_for_actor(actor_id: int) -> Array[int]:
	var result: Array[int] = []
	if _actor_ground_cells.has(actor_id):
		result.assign(_actor_ground_cells[actor_id])
	return result


func release_ground_actor(actor_id: int) -> bool:
	if not _actor_ground_cells.has(actor_id):
		return false
	var cells: Array = _actor_ground_cells[actor_id]
	for id_variant: Variant in cells:
		var id := int(id_variant)
		if not _ground_occupants.has(id):
			continue
		var occupants: Array = _ground_occupants[id]
		occupants.erase(actor_id)
		if occupants.is_empty():
			_ground_occupants.erase(id)
		else:
			occupants.sort()
			_ground_occupants[id] = occupants
	_actor_ground_cells.erase(actor_id)
	return true


func to_canonical_dict() -> Dictionary:
	var ground_pathable: Array = []
	var air_pathable: Array = []
	var elevations: Array = []
	var terrain_costs: Array = []
	var los_block_heights: Array = []
	for id: int in width * height:
		ground_pathable.append(int(_ground_pathable[id]))
		air_pathable.append(int(_air_pathable[id]))
		elevations.append(int(_elevations[id]))
		terrain_costs.append(int(_terrain_costs[id]))
		los_block_heights.append(int(_los_block_heights[id]))

	var occupancy: Array = []
	var occupied_ids: Array[int] = []
	for id_variant: Variant in _ground_occupants.keys():
		occupied_ids.append(int(id_variant))
	occupied_ids.sort()
	for id: int in occupied_ids:
		var actor_ids: Array = []
		var stored_ids: Array = _ground_occupants[id]
		stored_ids.sort()
		for actor_id_variant: Variant in stored_ids:
			actor_ids.append(int(actor_id_variant))
		occupancy.append({"actor_ids": actor_ids, "node_id": id})

	var terrain_ids: Array = []
	terrain_ids.assign(_terrain_ids)
	var region_ids: Array = []
	region_ids.assign(_region_ids)
	var build_site_ids: Array = []
	build_site_ids.assign(_build_site_ids)
	var destructible_ids: Array = []
	destructible_ids.assign(_destructible_ids)

	return {
		"air_pathable": air_pathable,
		"build_site_ids": build_site_ids,
		"cell_size_mt": cell_size_mt,
		"destructible_ids": destructible_ids,
		"elevations": elevations,
		"ground_occupancy": occupancy,
		"ground_pathable": ground_pathable,
		"height": height,
		"los_block_heights": los_block_heights,
		"region_ids": region_ids,
		"revision": revision,
		"terrain_cost_permille": terrain_costs,
		"terrain_ids": terrain_ids,
		"width": width,
	}


static func _nullable_string(value: Variant) -> String:
	return "" if value == null else str(value)


func _normalize_explicit_cells(cells: Array) -> Dictionary:
	if cells.is_empty():
		return {"node_ids": [], "ok": false}
	var seen: Dictionary = {}
	var result: Array[int] = []
	for value: Variant in cells:
		var x := -1
		var y := -1
		if typeof(value) == TYPE_VECTOR2I:
			x = (value as Vector2i).x
			y = (value as Vector2i).y
		elif typeof(value) == TYPE_ARRAY:
			var pair: Array = value
			if pair.size() != 2 or typeof(pair[0]) != TYPE_INT or typeof(pair[1]) != TYPE_INT:
				return {"node_ids": [], "ok": false}
			x = int(pair[0])
			y = int(pair[1])
		elif typeof(value) == TYPE_DICTIONARY:
			var point: Dictionary = value
			if point.size() != 2 or not point.has("x") or not point.has("y") \
				or typeof(point["x"]) != TYPE_INT or typeof(point["y"]) != TYPE_INT:
				return {"node_ids": [], "ok": false}
			x = int(point["x"])
			y = int(point["y"])
		else:
			return {"node_ids": [], "ok": false}
		if not in_bounds(x, y):
			return {"node_ids": [], "ok": false}
		var id := node_id(x, y)
		if seen.has(id):
			return {"node_ids": [], "ok": false}
		seen[id] = true
		result.append(id)
	result.sort()
	return {"node_ids": result, "ok": true}


static func _floor_div(numerator: int, denominator: int) -> int:
	@warning_ignore("integer_division")
	var quotient: int = numerator / denominator
	var remainder := numerator % denominator
	if remainder != 0 and numerator < 0:
		quotient -= 1
	return quotient
