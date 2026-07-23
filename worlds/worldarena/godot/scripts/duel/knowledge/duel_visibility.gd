class_name DuelVisibility
extends RefCounted

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const CELL_SIZE_MT := 500
const HIGH_TO_LOW_SIGHT_BP := 11_000
const BASIS_POINTS := 10_000

## Pure integer visibility projection.  Inputs are immutable canonical data
## snapshots, never WorldState objects, physics bodies, raycasts, or render
## visibility.  The returned internal IDs are consumed only by phase 12.


static func compute(
	grid_snapshot_input: Dictionary,
	entity_snapshots_input: Array,
	observer_seat: int,
	day_phase: String,
	temporary_vision_sources_input: Array = [],
	revealed_entity_internal_ids_input: Array = []
) -> Dictionary:
	var errors := PackedStringArray()
	if observer_seat < 0 or observer_seat > 1:
		errors.append("observer_seat must be 0 or 1")
	if day_phase not in ["day", "night", "forced_night"]:
		errors.append("day_phase must be day, night, or forced_night")
	for error: String in Codec.validate_canonical_value(grid_snapshot_input, "$.grid_snapshot"):
		errors.append(error)
	for error: String in Codec.validate_canonical_value(entity_snapshots_input, "$.entities"):
		errors.append(error)
	for error: String in Codec.validate_canonical_value(
		temporary_vision_sources_input, "$.temporary_vision_sources"
	):
		errors.append(error)
	for error: String in Codec.validate_canonical_value(
		revealed_entity_internal_ids_input, "$.revealed_entity_internal_ids"
	):
		errors.append(error)
	if not errors.is_empty():
		return _failure(errors)

	var grid := grid_snapshot_input.duplicate(true)
	var entities: Array = entity_snapshots_input.duplicate(true)
	var temporary_sources: Array = temporary_vision_sources_input.duplicate(true)
	var revealed_ids: Array = revealed_entity_internal_ids_input.duplicate()
	errors.append_array(_validate_grid(grid))
	errors.append_array(_validate_entities(entities, grid))
	errors.append_array(_validate_temporary_sources(temporary_sources, grid))
	var revealed_set: Dictionary = {}
	for index: int in revealed_ids.size():
		if typeof(revealed_ids[index]) != TYPE_INT or int(revealed_ids[index]) <= 0:
			errors.append("revealed_entity_internal_ids[%d] must be positive" % index)
			continue
		if revealed_set.has(int(revealed_ids[index])):
			errors.append("revealed_entity_internal_ids contains duplicates")
		else:
			revealed_set[int(revealed_ids[index])] = true
	if not errors.is_empty():
		return _failure(errors)

	entities.sort_custom(_entity_less)
	var sight_sources: Array[Dictionary] = []
	var detection_sources: Array[Dictionary] = []
	for entity_variant: Variant in entities:
		var entity: Dictionary = entity_variant
		if int(entity["owner_seat"]) != observer_seat or not bool(entity["alive"]):
			continue
		var sight_radius := _sight_radius_mt(entity, day_phase)
		if sight_radius > 0:
			sight_sources.append(entity)
		if int(entity.get("detection_radius_mt", 0)) > 0:
			detection_sources.append(entity)
	for source_variant: Variant in temporary_sources:
		var source: Dictionary = source_variant
		var synthetic := {
			"alive": true,
			"detection_radius_mt": int(source["detection_radius_mt"]),
			"elevation": int(source["elevation"]),
			"internal_id": -1,
			"is_air": true,
			"owner_seat": observer_seat,
			"position_mt": (source["position_mt"] as Array).duplicate(),
			"sight_radius_mt": int(source["sight_radius_mt"]),
		}
		if int(synthetic["sight_radius_mt"]) > 0:
			sight_sources.append(synthetic)
		if int(synthetic["detection_radius_mt"]) > 0:
			detection_sources.append(synthetic)

	var visible_set: Dictionary = {}
	for source: Dictionary in sight_sources:
		_rasterize_source(grid, source, day_phase, visible_set)

	var visible_cell_ids: Array[int] = []
	for id_variant: Variant in visible_set.keys():
		visible_cell_ids.append(int(id_variant))
	visible_cell_ids.sort()

	var visible_entity_ids: Array[int] = []
	var detected_entity_ids: Array[int] = []
	for entity_variant: Variant in entities:
		var target: Dictionary = entity_variant
		if not bool(target["alive"]):
			continue
		if int(target["owner_seat"]) == observer_seat:
			continue
		if revealed_set.has(int(target["internal_id"])):
			visible_entity_ids.append(int(target["internal_id"]))
			if bool(target.get("invisible", false)):
				detected_entity_ids.append(int(target["internal_id"]))
			continue
		if not _any_entity_cell_visible(target, grid, visible_set):
			continue
		if not _target_has_legal_sight(grid, target, sight_sources, day_phase):
			continue
		var is_invisible := bool(target.get("invisible", false))
		if is_invisible:
			if not _target_is_detected(grid, target, detection_sources):
				continue
			detected_entity_ids.append(int(target["internal_id"]))
		visible_entity_ids.append(int(target["internal_id"]))
	visible_entity_ids.sort()
	detected_entity_ids.sort()

	return {
		"detected_entity_ids": detected_entity_ids,
		"errors": errors,
		"ok": true,
		"visible_cell_ids": visible_cell_ids,
		"visible_entity_ids": visible_entity_ids,
	}


## Exact entity-only visibility path for authoritative ability candidate
## enumeration. It intentionally skips visible-cell rasterization, which is
## needed for observations but is redundant when only entity IDs are consumed.
## The LOS, high-ground, invisibility, detection, and explicit-reveal rules are
## otherwise identical to compute().
static func compute_entity_ids(
	grid_snapshot_input: Dictionary,
	entity_snapshots_input: Array,
	observer_seat: int,
	day_phase: String,
	temporary_vision_sources_input: Array = [],
	revealed_entity_internal_ids_input: Array = []
) -> Dictionary:
	var errors := PackedStringArray()
	if observer_seat not in [0, 1]:
		errors.append("observer_seat must be 0 or 1")
	if day_phase not in ["day", "night", "forced_night"]:
		errors.append("day_phase must be day, night, or forced_night")
	var grid := grid_snapshot_input.duplicate(true)
	var entities: Array = entity_snapshots_input.duplicate(true)
	var temporary_sources: Array = temporary_vision_sources_input.duplicate(true)
	errors.append_array(_validate_grid(grid))
	errors.append_array(_validate_entities(entities, grid))
	errors.append_array(_validate_temporary_sources(temporary_sources, grid))
	var revealed_set: Dictionary = {}
	for index: int in revealed_entity_internal_ids_input.size():
		var value: Variant = revealed_entity_internal_ids_input[index]
		if typeof(value) != TYPE_INT or int(value) <= 0 \
			or revealed_set.has(int(value)):
			errors.append("revealed_entity_internal_ids is invalid or duplicated")
		else:
			revealed_set[int(value)] = true
	if not errors.is_empty():
		return {"detected_entity_ids": [], "errors": errors, "ok": false,
			"visible_entity_ids": []}
	entities.sort_custom(_entity_less)
	var sight_sources: Array[Dictionary] = []
	var detection_sources: Array[Dictionary] = []
	for entity_variant: Variant in entities:
		var entity: Dictionary = entity_variant
		if int(entity["owner_seat"]) != observer_seat or not bool(entity["alive"]):
			continue
		if _sight_radius_mt(entity, day_phase) > 0:
			sight_sources.append(entity)
		if int(entity.get("detection_radius_mt", 0)) > 0:
			detection_sources.append(entity)
	for source_variant: Variant in temporary_sources:
		var source: Dictionary = source_variant
		var synthetic := {
			"alive": true,
			"detection_radius_mt": int(source["detection_radius_mt"]),
			"elevation": int(source["elevation"]),
			"internal_id": -1,
			"is_air": true,
			"owner_seat": observer_seat,
			"position_mt": (source["position_mt"] as Array).duplicate(),
			"sight_radius_mt": int(source["sight_radius_mt"]),
		}
		if int(synthetic["sight_radius_mt"]) > 0:
			sight_sources.append(synthetic)
		if int(synthetic["detection_radius_mt"]) > 0:
			detection_sources.append(synthetic)
	var visible_ids: Array[int] = []
	var detected_ids: Array[int] = []
	for entity_variant: Variant in entities:
		var target: Dictionary = entity_variant
		var target_id := int(target["internal_id"])
		if not bool(target["alive"]) or int(target["owner_seat"]) == observer_seat:
			continue
		if revealed_set.has(target_id):
			visible_ids.append(target_id)
			if bool(target.get("invisible", false)):
				detected_ids.append(target_id)
			continue
		if not _target_has_legal_sight(grid, target, sight_sources, day_phase):
			continue
		if bool(target.get("invisible", false)):
			if not _target_is_detected(grid, target, detection_sources):
				continue
			detected_ids.append(target_id)
		visible_ids.append(target_id)
	visible_ids.sort()
	detected_ids.sort()
	var visible_untyped: Array = []
	visible_untyped.assign(visible_ids)
	var detected_untyped: Array = []
	detected_untyped.assign(detected_ids)
	return {
		"detected_entity_ids": detected_untyped,
		"errors": errors,
		"ok": true,
		"visible_entity_ids": visible_untyped,
	}


## Source is excluded and target is included.  When a segment touches a grid
## corner, both tied side cells are emitted in ascending (y,x), followed by the
## diagonal cell.  This freezes all octants and both traversal directions.
static func supercover_cells(source_cell: Array, target_cell: Array) -> Array:
	if not _is_integer_pair(source_cell) or not _is_integer_pair(target_cell):
		return []
	var x := int(source_cell[0])
	var y := int(source_cell[1])
	var target_x := int(target_cell[0])
	var target_y := int(target_cell[1])
	var delta_x := target_x - x
	var delta_y := target_y - y
	var step_x := _sign(delta_x)
	var step_y := _sign(delta_y)
	var count_x := absi(delta_x)
	var count_y := absi(delta_y)
	var index_x := 0
	var index_y := 0
	var result: Array = []

	while index_x < count_x or index_y < count_y:
		var lhs := (1 + 2 * index_x) * count_y
		var rhs := (1 + 2 * index_y) * count_x
		if lhs == rhs:
			var side_cells: Array = []
			if index_x < count_x:
				side_cells.append([x + step_x, y])
			if index_y < count_y:
				side_cells.append([x, y + step_y])
			side_cells.sort_custom(_cell_pair_less)
			for side_cell: Array in side_cells:
				_append_unique_cell(result, side_cell)
			if index_x < count_x:
				x += step_x
				index_x += 1
			if index_y < count_y:
				y += step_y
				index_y += 1
			_append_unique_cell(result, [x, y])
		elif lhs < rhs:
			x += step_x
			index_x += 1
			_append_unique_cell(result, [x, y])
		else:
			y += step_y
			index_y += 1
			_append_unique_cell(result, [x, y])
	return result


static func has_line_of_sight(
	grid_snapshot: Dictionary,
	source_cell: Array,
	target_cell: Array,
	source_elevation: int,
	source_is_air: bool,
	target_is_air: bool
) -> bool:
	if not _cell_in_bounds(grid_snapshot, source_cell) \
		or not _cell_in_bounds(grid_snapshot, target_cell):
		return false
	var ray := supercover_cells(source_cell, target_cell)
	if ray.is_empty():
		return true
	## The target cell cannot occlude itself.
	for index: int in maxi(0, ray.size() - 1):
		var cell: Array = ray[index]
		var node_id := _node_id(grid_snapshot, int(cell[0]), int(cell[1]))
		if _cell_blocks_ray(
			grid_snapshot, node_id, source_elevation, source_is_air and target_is_air
		):
			return false
	return true


static func entity_occupied_cell_ids(entity: Dictionary, grid: Dictionary) -> Array[int]:
	var result: Array[int] = []
	if entity.has("occupied_cell_ids") and typeof(entity["occupied_cell_ids"]) == TYPE_ARRAY:
		for id_variant: Variant in entity["occupied_cell_ids"]:
			var id := int(id_variant)
			if id >= 0 and id < int(grid["width"]) * int(grid["height"]) \
				and not result.has(id):
				result.append(id)
	elif entity.has("occupied_cells") and typeof(entity["occupied_cells"]) == TYPE_ARRAY:
		for cell_variant: Variant in entity["occupied_cells"]:
			if _is_integer_pair(cell_variant) and _cell_in_bounds(grid, cell_variant):
				var id := _node_id(grid, int(cell_variant[0]), int(cell_variant[1]))
				if not result.has(id):
					result.append(id)
	else:
		var cell := _entity_cell(entity, grid)
		if not cell.is_empty():
			result.append(_node_id(grid, int(cell[0]), int(cell[1])))
	result.sort()
	return result


static func entity_location_is_visible(
	entity: Dictionary,
	grid: Dictionary,
	visible_cell_ids: Array
) -> bool:
	var visible_set: Dictionary = {}
	for id_variant: Variant in visible_cell_ids:
		visible_set[int(id_variant)] = true
	return _any_entity_cell_visible(entity, grid, visible_set)


static func _rasterize_source(
	grid: Dictionary,
	source: Dictionary,
	day_phase: String,
	visible_set: Dictionary
) -> void:
	var source_cell := _entity_cell(source, grid)
	if source_cell.is_empty():
		return
	var source_id := _node_id(grid, int(source_cell[0]), int(source_cell[1]))
	visible_set[source_id] = true
	var source_is_air := _entity_is_air(source)
	var source_elevation := 2 if source_is_air else _elevation_at(grid, source_id)
	var radius_mt := _sight_radius_mt(source, day_phase)
	@warning_ignore("integer_division")
	var radius_cells := (radius_mt + int(grid["cell_size_mt"]) - 1) / int(grid["cell_size_mt"])
	var source_center := _cell_center_mt(grid, source_cell)
	for y: int in range(
		maxi(0, int(source_cell[1]) - radius_cells),
		mini(int(grid["height"]) - 1, int(source_cell[1]) + radius_cells) + 1
	):
		for x: int in range(
			maxi(0, int(source_cell[0]) - radius_cells),
			mini(int(grid["width"]) - 1, int(source_cell[0]) + radius_cells) + 1
		):
			var target_id := _node_id(grid, x, y)
			var effective_radius := radius_mt
			if not source_is_air and source_elevation > _elevation_at(grid, target_id):
				@warning_ignore("integer_division")
				effective_radius = radius_mt * HIGH_TO_LOW_SIGHT_BP / BASIS_POINTS
			var target_center := _cell_center_mt(grid, [x, y])
			var delta_x := int(target_center[0]) - int(source_center[0])
			var delta_y := int(target_center[1]) - int(source_center[1])
			if delta_x * delta_x + delta_y * delta_y > effective_radius * effective_radius:
				continue
			if has_line_of_sight(
				grid, source_cell, [x, y], source_elevation, source_is_air, false
			):
				visible_set[target_id] = true


static func _target_is_detected(
	grid: Dictionary,
	target: Dictionary,
	detection_sources: Array[Dictionary]
) -> bool:
	var target_position: Array = target["position_mt"]
	var target_cell := _entity_cell(target, grid)
	if target_cell.is_empty():
		return false
	var target_is_air := _entity_is_air(target)
	for source: Dictionary in detection_sources:
		var source_position: Array = source["position_mt"]
		var delta_x := int(target_position[0]) - int(source_position[0])
		var delta_y := int(target_position[1]) - int(source_position[1])
		var radius_mt := int(source.get("detection_radius_mt", 0))
		if delta_x * delta_x + delta_y * delta_y > radius_mt * radius_mt:
			continue
		var source_cell := _entity_cell(source, grid)
		var source_is_air := _entity_is_air(source)
		var source_id := _node_id(grid, int(source_cell[0]), int(source_cell[1]))
		var source_elevation := 2 if source_is_air else _elevation_at(grid, source_id)
		if has_line_of_sight(
			grid, source_cell, target_cell, source_elevation, source_is_air, target_is_air
		):
			return true
	return false


static func _target_has_legal_sight(
	grid: Dictionary,
	target: Dictionary,
	sight_sources: Array[Dictionary],
	day_phase: String
) -> bool:
	var target_is_air := _entity_is_air(target)
	var target_cells := entity_occupied_cell_ids(target, grid)
	for source: Dictionary in sight_sources:
		var source_cell := _entity_cell(source, grid)
		var source_is_air := _entity_is_air(source)
		var source_id := _node_id(grid, int(source_cell[0]), int(source_cell[1]))
		var source_elevation := 2 if source_is_air else _elevation_at(grid, source_id)
		var radius_mt := _sight_radius_mt(source, day_phase)
		var source_center := _cell_center_mt(grid, source_cell)
		for target_id: int in target_cells:
			var target_cell_x := target_id % int(grid["width"])
			@warning_ignore("integer_division")
			var target_cell_y: int = target_id / int(grid["width"])
			var target_center := _cell_center_mt(grid, [target_cell_x, target_cell_y])
			var effective_radius := radius_mt
			if not source_is_air and source_elevation > _elevation_at(grid, target_id):
				@warning_ignore("integer_division")
				effective_radius = radius_mt * HIGH_TO_LOW_SIGHT_BP / BASIS_POINTS
			var delta_x := int(target_center[0]) - int(source_center[0])
			var delta_y := int(target_center[1]) - int(source_center[1])
			if delta_x * delta_x + delta_y * delta_y > effective_radius * effective_radius:
				continue
			if has_line_of_sight(
				grid,
				source_cell,
				[target_cell_x, target_cell_y],
				source_elevation,
				source_is_air,
				target_is_air
			):
				return true
	return false


static func _any_entity_cell_visible(
	entity: Dictionary,
	grid: Dictionary,
	visible_set: Dictionary
) -> bool:
	for id: int in entity_occupied_cell_ids(entity, grid):
		if visible_set.has(id):
			return true
	return false


static func _cell_blocks_ray(
	grid: Dictionary,
	node_id: int,
	source_elevation: int,
	air_to_air: bool
) -> bool:
	var block_height := int((grid["los_block_heights"] as Array)[node_id])
	if block_height <= 0:
		return false
	var terrain_id := str((grid["terrain_ids"] as Array)[node_id])
	var block_kind := ""
	if grid.has("los_block_kinds"):
		block_kind = str((grid["los_block_kinds"] as Array)[node_id])
	if air_to_air:
		## Height-2 cliffs are the one authored exception to the ordinary
		## `height > source elevation` rule for air-to-air sight.
		if block_kind == "cliff" or "cliff" in terrain_id:
			return block_height >= 2
		## Forest/destructible crowns never block air-to-air sight.
		return false
	return block_height > source_elevation


static func _validate_grid(grid: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for key: String in [
		"width", "height", "cell_size_mt", "elevations", "los_block_heights", "terrain_ids",
	]:
		if not grid.has(key):
			errors.append("grid_snapshot.%s is required" % key)
	if not errors.is_empty():
		return errors
	if typeof(grid["width"]) != TYPE_INT or int(grid["width"]) <= 0:
		errors.append("grid_snapshot.width must be a positive integer")
	if typeof(grid["height"]) != TYPE_INT or int(grid["height"]) <= 0:
		errors.append("grid_snapshot.height must be a positive integer")
	if typeof(grid["cell_size_mt"]) != TYPE_INT or int(grid["cell_size_mt"]) != CELL_SIZE_MT:
		errors.append("grid_snapshot.cell_size_mt must be 500")
	if not errors.is_empty():
		return errors
	var count := int(grid["width"]) * int(grid["height"])
	for key: String in ["elevations", "los_block_heights", "terrain_ids"]:
		if typeof(grid[key]) != TYPE_ARRAY or (grid[key] as Array).size() != count:
			errors.append("grid_snapshot.%s must have exactly %d entries" % [key, count])
	if grid.has("region_ids") \
		and (typeof(grid["region_ids"]) != TYPE_ARRAY or (grid["region_ids"] as Array).size() != count):
		errors.append("grid_snapshot.region_ids must have exactly %d entries" % count)
	if grid.has("los_block_kinds") \
		and (typeof(grid["los_block_kinds"]) != TYPE_ARRAY \
		or (grid["los_block_kinds"] as Array).size() != count):
		errors.append("grid_snapshot.los_block_kinds must have exactly %d entries" % count)
	if not errors.is_empty():
		return errors
	for id: int in count:
		if typeof((grid["elevations"] as Array)[id]) != TYPE_INT \
			or int((grid["elevations"] as Array)[id]) < 0 \
			or int((grid["elevations"] as Array)[id]) > 2:
			errors.append("grid_snapshot.elevations[%d] must be in [0,2]" % id)
		if typeof((grid["los_block_heights"] as Array)[id]) != TYPE_INT \
			or int((grid["los_block_heights"] as Array)[id]) < 0:
			errors.append("grid_snapshot.los_block_heights[%d] must be non-negative" % id)
		if typeof((grid["terrain_ids"] as Array)[id]) != TYPE_STRING:
			errors.append("grid_snapshot.terrain_ids[%d] must be a string" % id)
	return errors


static func _validate_entities(entities: Array, grid: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var seen_ids: Dictionary = {}
	for index: int in entities.size():
		var value: Variant = entities[index]
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("entities[%d] must be an object" % index)
			continue
		var entity: Dictionary = value
		for key: String in ["internal_id", "owner_seat", "alive", "position_mt"]:
			if not entity.has(key):
				errors.append("entities[%d].%s is required" % [index, key])
		if not entity.has("internal_id") or typeof(entity["internal_id"]) != TYPE_INT \
			or int(entity["internal_id"]) <= 0:
			errors.append("entities[%d].internal_id must be positive" % index)
			continue
		var internal_id := int(entity["internal_id"])
		if seen_ids.has(internal_id):
			errors.append("entities contain duplicate internal_id %d" % internal_id)
		seen_ids[internal_id] = true
		if typeof(entity.get("owner_seat", null)) != TYPE_INT \
			or int(entity["owner_seat"]) < -1 or int(entity["owner_seat"]) > 1:
			errors.append("entities[%d].owner_seat must be -1, 0, or 1" % index)
		if typeof(entity.get("alive", null)) != TYPE_BOOL:
			errors.append("entities[%d].alive must be boolean" % index)
		if not _is_integer_pair(entity.get("position_mt", null)):
			errors.append("entities[%d].position_mt must be an integer pair" % index)
		elif _entity_cell(entity, grid).is_empty():
			errors.append("entities[%d].position_mt is out of grid bounds" % index)
		for radius_key: String in [
			"sight_radius_mt", "sight_day_mt", "sight_night_mt", "detection_radius_mt",
		]:
			if entity.has(radius_key) and (
				typeof(entity[radius_key]) != TYPE_INT or int(entity[radius_key]) < 0
			):
				errors.append("entities[%d].%s must be a non-negative integer" % [index, radius_key])
	return errors


static func _validate_temporary_sources(
	sources: Array, grid: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	for index: int in sources.size():
		if typeof(sources[index]) != TYPE_DICTIONARY:
			errors.append("temporary_vision_sources[%d] must be an object" % index)
			continue
		var source: Dictionary = sources[index]
		var expected := [
			"detection_radius_mt", "elevation", "position_mt", "sight_radius_mt",
		]
		var keys: Array = source.keys()
		keys.sort()
		if keys != expected:
			errors.append("temporary_vision_sources[%d] has unknown fields" % index)
			continue
		if not _is_integer_pair(source.get("position_mt")) \
			or _entity_cell(source, grid).is_empty():
			errors.append("temporary_vision_sources[%d].position_mt is invalid" % index)
		for field: String in ["detection_radius_mt", "sight_radius_mt", "elevation"]:
			if typeof(source.get(field)) != TYPE_INT or int(source[field]) < 0:
				errors.append("temporary_vision_sources[%d].%s must be non-negative" % [
					index, field,
				])
		if int(source.get("elevation", -1)) > 2:
			errors.append("temporary_vision_sources[%d].elevation exceeds 2" % index)
	return errors


static func _sight_radius_mt(entity: Dictionary, day_phase: String) -> int:
	if entity.has("sight_radius_mt"):
		return int(entity["sight_radius_mt"])
	return int(entity.get(
		"sight_day_mt" if day_phase == "day" else "sight_night_mt", 0
	))


static func _entity_cell(entity: Dictionary, grid: Dictionary) -> Array:
	if not _is_integer_pair(entity.get("position_mt", null)):
		return []
	var point: Array = entity["position_mt"]
	@warning_ignore("integer_division")
	var x: int = int(point[0]) / int(grid["cell_size_mt"])
	@warning_ignore("integer_division")
	var y: int = int(point[1]) / int(grid["cell_size_mt"])
	if x < 0 or x >= int(grid["width"]) or y < 0 or y >= int(grid["height"]):
		return []
	return [x, y]


static func _entity_is_air(entity: Dictionary) -> bool:
	if entity.has("is_air"):
		return bool(entity["is_air"])
	if entity.has("layer"):
		return str(entity["layer"]) == "air"
	if entity.has("tags") and typeof(entity["tags"]) == TYPE_ARRAY:
		return (entity["tags"] as Array).has("air")
	return false


static func _elevation_at(grid: Dictionary, node_id: int) -> int:
	return int((grid["elevations"] as Array)[node_id])


static func _cell_center_mt(grid: Dictionary, cell: Array) -> Array:
	var size := int(grid["cell_size_mt"])
	@warning_ignore("integer_division")
	var offset: int = size / 2
	return [int(cell[0]) * size + offset, int(cell[1]) * size + offset]


static func _node_id(grid: Dictionary, x: int, y: int) -> int:
	return y * int(grid["width"]) + x


static func _cell_in_bounds(grid: Dictionary, cell: Array) -> bool:
	return _is_integer_pair(cell) and int(cell[0]) >= 0 and int(cell[1]) >= 0 \
		and int(cell[0]) < int(grid.get("width", 0)) \
		and int(cell[1]) < int(grid.get("height", 0))


static func _entity_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("internal_id", 0)) < int(right.get("internal_id", 0))


static func _cell_pair_less(left: Array, right: Array) -> bool:
	if int(left[1]) != int(right[1]):
		return int(left[1]) < int(right[1])
	return int(left[0]) < int(right[0])


static func _append_unique_cell(cells: Array, cell: Array) -> void:
	if cells.is_empty() or cells.back() != cell:
		cells.append(cell)


static func _sign(value: int) -> int:
	if value < 0:
		return -1
	if value > 0:
		return 1
	return 0


static func _is_integer_pair(value: Variant) -> bool:
	return typeof(value) == TYPE_ARRAY and (value as Array).size() == 2 \
		and typeof(value[0]) == TYPE_INT and typeof(value[1]) == TYPE_INT


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {
		"detected_entity_ids": [],
		"errors": errors,
		"ok": false,
		"visible_cell_ids": [],
		"visible_entity_ids": [],
	}
