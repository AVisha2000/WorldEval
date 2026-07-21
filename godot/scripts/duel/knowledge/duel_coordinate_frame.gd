class_name DuelCoordinateFrame
extends RefCounted

## Exact world-seat <-> self-canonical transform.  This class deliberately
## consumes only the immutable public map manifest and produces JSON-safe
## arrays/strings; Vector types never cross the protocol boundary.

const OFFICIAL_WORLD_MAX_X_MT := 191_999
const OFFICIAL_WORLD_MAX_Y_MT := 127_999
const OFFICIAL_CELL_MAX_X := 383
const OFFICIAL_CELL_MAX_Y := 255

var observer_seat: int = -1
var _world_max_x_mt: int = OFFICIAL_WORLD_MAX_X_MT
var _world_max_y_mt: int = OFFICIAL_WORLD_MAX_Y_MT
var _cell_max_x: int = OFFICIAL_CELL_MAX_X
var _cell_max_y: int = OFFICIAL_CELL_MAX_Y
var _rotated_public_ids: Dictionary = {}
var _configured: bool = false


func configure(p_observer_seat: int, map_manifest: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if p_observer_seat < 0 or p_observer_seat > 1:
		errors.append("observer_seat must be 0 or 1")
	if typeof(map_manifest) != TYPE_DICTIONARY:
		errors.append("map_manifest must be a dictionary")
		return errors

	var rotation: Variant = map_manifest.get("rotation_transform", null)
	if typeof(rotation) != TYPE_DICTIONARY:
		errors.append("map_manifest.rotation_transform must be an object")
		return errors
	var rotation_dict: Dictionary = rotation
	if str(rotation_dict.get("kind", "")) != "rotation_180":
		errors.append("rotation_transform.kind must be rotation_180")
	if not bool(rotation_dict.get("self_inverse", false)):
		errors.append("rotation_transform must be self-inverse")

	var world_max: Variant = rotation_dict.get("world_max_inclusive_mt", null)
	var cell_max: Variant = rotation_dict.get("cell_max_inclusive", null)
	if not _is_integer_pair(world_max):
		errors.append("rotation_transform.world_max_inclusive_mt must be an integer pair")
	elif int(world_max[0]) != OFFICIAL_WORLD_MAX_X_MT \
		or int(world_max[1]) != OFFICIAL_WORLD_MAX_Y_MT:
		errors.append("world rotation bounds must be [191999,127999]")
	if not _is_integer_pair(cell_max):
		errors.append("rotation_transform.cell_max_inclusive must be an integer pair")
	elif int(cell_max[0]) != OFFICIAL_CELL_MAX_X or int(cell_max[1]) != OFFICIAL_CELL_MAX_Y:
		errors.append("cell rotation bounds must be [383,255]")
	if not errors.is_empty():
		return errors

	observer_seat = p_observer_seat
	_world_max_x_mt = int(world_max[0])
	_world_max_y_mt = int(world_max[1])
	_cell_max_x = int(cell_max[0])
	_cell_max_y = int(cell_max[1])
	_rotated_public_ids.clear()
	var mirror_groups: Variant = map_manifest.get("mirror_pairs", {})
	if typeof(mirror_groups) != TYPE_DICTIONARY:
		errors.append("map_manifest.mirror_pairs must be an object")
		return errors
	var group_names: Array = (mirror_groups as Dictionary).keys()
	group_names.sort()
	for group_variant: Variant in group_names:
		var group: Variant = mirror_groups[group_variant]
		if typeof(group) != TYPE_ARRAY:
			errors.append("mirror_pairs.%s must be an array" % str(group_variant))
			continue
		for pair_index: int in (group as Array).size():
			var pair_variant: Variant = group[pair_index]
			if typeof(pair_variant) != TYPE_DICTIONARY:
				errors.append("mirror_pairs.%s[%d] must be an object" % [
					str(group_variant), pair_index,
				])
				continue
			var pair: Dictionary = pair_variant
			if typeof(pair.get("a", null)) != TYPE_STRING \
				or typeof(pair.get("b", null)) != TYPE_STRING:
				errors.append("mirror pair endpoints must be strings")
				continue
			var left := str(pair["a"])
			var right := str(pair["b"])
			if _rotated_public_ids.has(left) and _rotated_public_ids[left] != right:
				errors.append("public ID %s has conflicting rotation partners" % left)
			if _rotated_public_ids.has(right) and _rotated_public_ids[right] != left:
				errors.append("public ID %s has conflicting rotation partners" % right)
			_rotated_public_ids[left] = right
			_rotated_public_ids[right] = left
	_configured = errors.is_empty()
	return errors


func is_configured() -> bool:
	return _configured


func world_point_to_self(point_mt: Array) -> Array:
	return _transform_point(point_mt)


func self_point_to_world(point_mt: Array) -> Array:
	## A 180-degree rotation is its own inverse.
	return _transform_point(point_mt)


func world_cell_to_self(cell: Array) -> Array:
	return _transform_cell(cell)


func self_cell_to_world(cell: Array) -> Array:
	return _transform_cell(cell)


func world_facing_to_self(facing_mdeg: int) -> int:
	return _transform_facing(facing_mdeg)


func self_facing_to_world(facing_mdeg: int) -> int:
	return _transform_facing(facing_mdeg)


func world_public_id_to_self(public_id: String) -> String:
	if observer_seat == 1 and _rotated_public_ids.has(public_id):
		return str(_rotated_public_ids[public_id])
	return public_id


func self_public_id_to_world(public_id: String) -> String:
	## The complete mirror-pair mapping is also self-inverse.
	return world_public_id_to_self(public_id)


func _transform_point(point_mt: Array) -> Array:
	if not _is_integer_pair(point_mt):
		return []
	var x := int(point_mt[0])
	var y := int(point_mt[1])
	if x < 0 or x > _world_max_x_mt or y < 0 or y > _world_max_y_mt:
		return []
	if observer_seat == 0:
		return [x, y]
	return [_world_max_x_mt - x, _world_max_y_mt - y]


func _transform_cell(cell: Array) -> Array:
	if not _is_integer_pair(cell):
		return []
	var x := int(cell[0])
	var y := int(cell[1])
	if x < 0 or x > _cell_max_x or y < 0 or y > _cell_max_y:
		return []
	if observer_seat == 0:
		return [x, y]
	return [_cell_max_x - x, _cell_max_y - y]


func _transform_facing(facing_mdeg: int) -> int:
	if facing_mdeg < 0 or facing_mdeg >= 360_000:
		return -1
	if observer_seat == 0:
		return facing_mdeg
	return (facing_mdeg + 180_000) % 360_000


static func _is_integer_pair(value: Variant) -> bool:
	return typeof(value) == TYPE_ARRAY and (value as Array).size() == 2 \
		and typeof(value[0]) == TYPE_INT and typeof(value[1]) == TYPE_INT
