class_name DuelMapLoader
extends RefCounted

const Rules := preload("res://scripts/duel/simulation/duel_rules.gd")
const OccupancyGrid := preload("res://scripts/duel/simulation/duel_occupancy_grid.gd")
const MAX_SAFE_JSON_INTEGER := 9_007_199_254_740_991.0
const CELL_PALETTE_FIELDS: Array[String] = [
	"terrain_id",
	"elevation",
	"ground_pathable",
	"air_pathable",
	"buildable_site_id",
	"region_id",
	"los_block_height",
	"destructible_id",
	"rotated_palette_index",
]

## Boundary between a schema-validated map manifest and the authoritative grid.
## The Phase-1 schema can carry additional sites/regions, but every executable
## cell must be explicit and is validated here again before simulation begins.


static func load_manifest(manifest: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	var grid_block: Dictionary = {}
	if manifest.has("grid") and typeof(manifest["grid"]) == TYPE_DICTIONARY:
		grid_block = manifest["grid"]
	var coordinate_system: Dictionary = {}
	if manifest.has("coordinate_system") and typeof(manifest["coordinate_system"]) == TYPE_DICTIONARY:
		coordinate_system = manifest["coordinate_system"]

	var width_value: Variant = grid_block.get("width", manifest.get("grid_width", null))
	var height_value: Variant = grid_block.get("height", manifest.get("grid_height", null))
	var cell_size_value: Variant = grid_block.get(
		"cell_size_mt", coordinate_system.get("cell_size_mt", manifest.get("cell_size_mt", null))
	)

	if not _is_exact_integer(width_value):
		errors.append("map grid width must be an integer")
	if not _is_exact_integer(height_value):
		errors.append("map grid height must be an integer")
	if not _is_exact_integer(cell_size_value):
		errors.append("map grid cell_size_mt must be an integer")
	if not errors.is_empty():
		return {"errors": errors, "grid": null, "ok": false}

	var width := _exact_int(width_value)
	var height := _exact_int(height_value)
	var cell_size_mt := _exact_int(cell_size_value)
	var cells: Array = []
	var encoding := str(grid_block.get("encoding", ""))
	if encoding == "row_rle_palette_v1":
		var decode_result := _decode_row_rle_palette(manifest, grid_block, width, height)
		errors.append_array(decode_result["errors"])
		cells = decode_result["cells"]
	else:
		var cells_value: Variant = grid_block.get("cells", manifest.get("cells", null))
		if typeof(cells_value) != TYPE_ARRAY:
			errors.append("map grid must provide cells or row_rle_palette_v1 rows")
		else:
			cells = cells_value
	if not errors.is_empty():
		return {"errors": errors, "grid": null, "ok": false}

	var grid := OccupancyGrid.new()
	errors.append_array(grid.configure(width, height, cell_size_mt))
	if not errors.is_empty():
		return {"errors": errors, "grid": null, "ok": false}

	if cells.size() != width * height:
		errors.append("map must define exactly %d cells" % (width * height))

	var seen: Dictionary = {}
	for index: int in cells.size():
		var cell_variant: Variant = cells[index]
		if typeof(cell_variant) != TYPE_DICTIONARY:
			errors.append("cells[%d] must be an object" % index)
			continue
		var cell: Dictionary = cell_variant
		var cell_errors := _validate_cell(cell, index, width, height)
		errors.append_array(cell_errors)
		if not cell_errors.is_empty():
			continue
		var x := int(cell["x"])
		var y := int(cell["y"])
		var id := y * width + x
		if seen.has(id):
			errors.append("cells[%d] duplicates cell (%d,%d)" % [index, x, y])
			continue
		seen[id] = true
		grid.set_cell_static(x, y, cell)

	if seen.size() != width * height:
		errors.append("map has %d unique cells; expected %d" % [seen.size(), width * height])
	if not errors.is_empty():
		return {"errors": errors, "grid": null, "ok": false}
	return {"errors": errors, "grid": grid, "ok": true}


static func _decode_row_rle_palette(
	manifest: Dictionary,
	grid_block: Dictionary,
	width: int,
	height: int
) -> Dictionary:
	var errors := PackedStringArray()
	var cells: Array = []
	if width != Rules.OFFICIAL_GRID_WIDTH or height != Rules.OFFICIAL_GRID_HEIGHT:
		errors.append("row_rle_palette_v1 must declare the official 384 x 256 grid")

	var palette_variant: Variant = manifest.get("cell_palette", null)
	var palette_fields_variant: Variant = manifest.get("cell_palette_fields", null)
	var terrain_catalog_variant: Variant = manifest.get("terrain_catalog", null)
	var rows_variant: Variant = grid_block.get("rows", null)
	if typeof(palette_variant) != TYPE_ARRAY:
		errors.append("cell_palette must be an array")
	if typeof(palette_fields_variant) != TYPE_ARRAY:
		errors.append("cell_palette_fields must be an array")
	if typeof(terrain_catalog_variant) != TYPE_DICTIONARY:
		errors.append("terrain_catalog must be an object")
	if typeof(rows_variant) != TYPE_ARRAY:
		errors.append("grid.rows must be an array")
	if not errors.is_empty():
		return {"cells": cells, "errors": errors}

	var palette: Array = palette_variant
	var palette_fields: Array = palette_fields_variant
	var terrain_catalog: Dictionary = terrain_catalog_variant
	var rows: Array = rows_variant
	if palette.is_empty():
		errors.append("cell_palette must not be empty")
	if palette_fields.size() != CELL_PALETTE_FIELDS.size():
		errors.append("cell_palette_fields has the wrong field count")
	else:
		for field_index: int in CELL_PALETTE_FIELDS.size():
			if typeof(palette_fields[field_index]) != TYPE_STRING \
				or str(palette_fields[field_index]) != CELL_PALETTE_FIELDS[field_index]:
				errors.append("cell_palette_fields[%d] must equal %s" % [
					field_index, CELL_PALETTE_FIELDS[field_index],
				])
	if rows.size() != height:
		errors.append("grid.rows must contain exactly %d rows" % height)

	var decoded_palette: Array[Dictionary] = []
	for palette_index: int in palette.size():
		var entry_variant: Variant = palette[palette_index]
		if typeof(entry_variant) != TYPE_ARRAY:
			errors.append("cell_palette[%d] must be a positional array" % palette_index)
			decoded_palette.append({})
			continue
		var entry_values: Array = entry_variant
		if entry_values.size() != CELL_PALETTE_FIELDS.size():
			errors.append("cell_palette[%d] has the wrong field count" % palette_index)
			decoded_palette.append({})
			continue
		var entry: Dictionary = {}
		for field_index: int in CELL_PALETTE_FIELDS.size():
			entry[CELL_PALETTE_FIELDS[field_index]] = entry_values[field_index]
		var palette_errors := _validate_palette_entry(
			entry, palette_index, palette.size(), terrain_catalog
		)
		errors.append_array(palette_errors)
		if not palette_errors.is_empty():
			decoded_palette.append({})
			continue
		var decoded := entry.duplicate(true)
		var terrain: Dictionary = terrain_catalog[str(entry["terrain_id"])]
		decoded["terrain_cost_permille"] = int(terrain["movement_basis_points"])
		decoded_palette.append(decoded)

	if not errors.is_empty():
		return {"cells": cells, "errors": errors}

	for y: int in rows.size():
		var row_variant: Variant = rows[y]
		if typeof(row_variant) != TYPE_ARRAY:
			errors.append("grid.rows[%d] must be an array" % y)
			continue
		var row: Array = row_variant
		if row.is_empty() or row.size() % 2 != 0:
			errors.append("grid.rows[%d] must contain at least one run" % y)
			continue
		var x := 0
		for run_index: int in range(0, row.size(), 2):
			if not _is_exact_integer(row[run_index]):
				errors.append("grid.rows[%d][%d] palette index must be an integer" % [y, run_index])
				continue
			if not _is_exact_integer(row[run_index + 1]):
				errors.append("grid.rows[%d][%d] count must be an integer" % [y, run_index + 1])
				continue
			var palette_index := _exact_int(row[run_index])
			var count := _exact_int(row[run_index + 1])
			if palette_index < 0 or palette_index >= decoded_palette.size():
				errors.append("grid.rows[%d][%d] palette index is out of bounds" % [y, run_index])
				continue
			if count <= 0:
				errors.append("grid.rows[%d][%d] count must be positive" % [y, run_index + 1])
				continue
			if x + count > width:
				errors.append("grid.rows[%d] expands past %d cells" % [y, width])
				continue
			for offset: int in count:
				var cell := decoded_palette[palette_index].duplicate(true)
				cell["x"] = x + offset
				cell["y"] = y
				cells.append(cell)
			x += count
		if x != width:
			errors.append("grid.rows[%d] expands to %d cells; expected %d" % [y, x, width])
	return {"cells": cells, "errors": errors}


static func _validate_palette_entry(
	entry: Dictionary,
	palette_index: int,
	palette_size: int,
	terrain_catalog: Dictionary
) -> PackedStringArray:
	var errors := PackedStringArray()
	var required_types := {
		"air_pathable": TYPE_BOOL,
		"elevation": TYPE_INT,
		"ground_pathable": TYPE_BOOL,
		"los_block_height": TYPE_INT,
		"region_id": TYPE_STRING,
		"rotated_palette_index": TYPE_INT,
		"terrain_id": TYPE_STRING,
	}
	for key_variant: Variant in required_types.keys():
		var key := str(key_variant)
		var expected_type := int(required_types[key])
		var valid_type := entry.has(key) and (
			_is_exact_integer(entry[key]) if expected_type == TYPE_INT
			else typeof(entry[key]) == expected_type
		)
		if not valid_type:
			errors.append("cell_palette[%d].%s has the wrong type or is missing" % [
				palette_index, key,
			])
	for nullable_key: String in ["buildable_site_id", "destructible_id"]:
		if not entry.has(nullable_key):
			errors.append("cell_palette[%d].%s is required" % [palette_index, nullable_key])
		elif entry[nullable_key] != null and typeof(entry[nullable_key]) != TYPE_STRING:
			errors.append("cell_palette[%d].%s must be a string or null" % [
				palette_index, nullable_key,
			])
	if not errors.is_empty():
		return errors

	var rotated_index := _exact_int(entry["rotated_palette_index"])
	if rotated_index < 0 or rotated_index >= palette_size:
		errors.append("cell_palette[%d].rotated_palette_index is out of bounds" % palette_index)
	var terrain_id := str(entry["terrain_id"])
	if not terrain_catalog.has(terrain_id) or typeof(terrain_catalog[terrain_id]) != TYPE_DICTIONARY:
		errors.append("cell_palette[%d] references unknown terrain %s" % [palette_index, terrain_id])
		return errors
	var terrain: Dictionary = terrain_catalog[terrain_id]
	if not terrain.has("movement_basis_points") \
		or not _is_exact_integer(terrain["movement_basis_points"]):
		errors.append("terrain %s must define integer movement_basis_points" % terrain_id)
	if not terrain.has("ground_pathable") or typeof(terrain["ground_pathable"]) != TYPE_BOOL \
		or bool(terrain["ground_pathable"]) != bool(entry["ground_pathable"]):
		errors.append("cell_palette[%d] ground_pathable disagrees with terrain" % palette_index)
	if not terrain.has("air_pathable") or typeof(terrain["air_pathable"]) != TYPE_BOOL \
		or bool(terrain["air_pathable"]) != bool(entry["air_pathable"]):
		errors.append("cell_palette[%d] air_pathable disagrees with terrain" % palette_index)
	if not terrain.has("los_block_height") or not _is_exact_integer(terrain["los_block_height"]) \
		or _exact_int(terrain["los_block_height"]) != _exact_int(entry["los_block_height"]):
		errors.append("cell_palette[%d] los_block_height disagrees with terrain" % palette_index)
	return errors


static func _validate_cell(
	cell: Dictionary,
	index: int,
	width: int,
	height: int
) -> PackedStringArray:
	var errors := PackedStringArray()
	var required_types := {
		"x": TYPE_INT,
		"y": TYPE_INT,
		"terrain_id": TYPE_STRING,
		"elevation": TYPE_INT,
		"ground_pathable": TYPE_BOOL,
		"air_pathable": TYPE_BOOL,
		"terrain_cost_permille": TYPE_INT,
		"region_id": TYPE_STRING,
		"los_block_height": TYPE_INT,
	}
	var keys: Array = required_types.keys()
	keys.sort()
	for key_variant: Variant in keys:
		var key := str(key_variant)
		if not cell.has(key):
			errors.append("cells[%d].%s is required" % [index, key])
		elif int(required_types[key]) == TYPE_INT and not _is_exact_integer(cell[key]):
			errors.append("cells[%d].%s has the wrong type" % [index, key])
		elif int(required_types[key]) != TYPE_INT and typeof(cell[key]) != int(required_types[key]):
			errors.append("cells[%d].%s has the wrong type" % [index, key])
	if not errors.is_empty():
		return errors
	if not cell.has("buildable_site_id"):
		errors.append("cells[%d].buildable_site_id is required (string or null)" % index)

	var x := int(cell["x"])
	var y := int(cell["y"])
	if x < 0 or x >= width or y < 0 or y >= height:
		errors.append("cells[%d] coordinate is out of bounds" % index)
	if int(cell["elevation"]) < 0 or int(cell["elevation"]) > 2:
		errors.append("cells[%d].elevation must be in [0, 2]" % index)
	var terrain_cost := int(cell["terrain_cost_permille"])
	if terrain_cost < 0 or (bool(cell["ground_pathable"]) and terrain_cost == 0):
		errors.append("cells[%d].terrain_cost_permille must be positive for pathable ground" % index)
	if int(cell["los_block_height"]) < 0 or int(cell["los_block_height"]) > 3:
		errors.append("cells[%d].los_block_height must be in [0, 3]" % index)
	for nullable_key: String in ["buildable_site_id", "destructible_id"]:
		if cell.has(nullable_key) and cell[nullable_key] != null \
			and typeof(cell[nullable_key]) != TYPE_STRING:
			errors.append("cells[%d].%s must be a string or null" % [index, nullable_key])
	return errors


## Godot's JSON parser exposes JSON numbers as floats. The loader accepts only
## finite, mathematically integral values within JSON's exact integer range and
## converts them immediately; no float reaches authoritative grid/state data.
static func _is_exact_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var numeric := float(value)
	return is_finite(numeric) and numeric == floor(numeric) \
		and absf(numeric) <= MAX_SAFE_JSON_INTEGER


static func _exact_int(value: Variant) -> int:
	return int(value)
