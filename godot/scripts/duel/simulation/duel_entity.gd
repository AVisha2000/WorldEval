class_name DuelEntity
extends RefCounted

## Minimal authoritative entity record. Additional mechanics should add explicit
## integer/string fields or catalog references rather than opaque engine objects.

var internal_id: int = 0
var public_id: String = ""
var owner_seat: int = -1
var entity_kind: String = "placeholder"
var catalog_id: String = ""

var position_x_mt: int = 0
var position_y_mt: int = 0
var facing_mdeg: int = 0
var radius_mt: int = 350

var hp: int = 1
var max_hp: int = 1
var mana: int = 0
var max_mana: int = 0
var alive: bool = true

var active_order_id: int = 0
var route: Array[Dictionary] = []
var route_index: int = 0
var segment_numerator: int = 0
var segment_denominator: int = 1
var movement_remainder_mt: int = 0
var next_replan_tick: int = 0

var tags: Array[String] = []
var integer_attributes: Dictionary = {}


func _init(
	p_internal_id: int = 0,
	p_owner_seat: int = -1,
	p_entity_kind: String = "placeholder"
) -> void:
	internal_id = p_internal_id
	owner_seat = p_owner_seat
	entity_kind = p_entity_kind


func set_position_mt(x_mt: int, y_mt: int) -> void:
	position_x_mt = x_mt
	position_y_mt = y_mt


func set_route_cells(cells: Array[Vector2i]) -> void:
	route.clear()
	for cell: Vector2i in cells:
		route.append({"x": cell.x, "y": cell.y})
	route_index = 0
	segment_numerator = 0
	segment_denominator = 1
	movement_remainder_mt = 0


func to_canonical_dict() -> Dictionary:
	var sorted_tags: Array[String] = tags.duplicate()
	sorted_tags.sort()
	var canonical_tags: Array = []
	canonical_tags.assign(sorted_tags)

	var canonical_route: Array = []
	for point: Dictionary in route:
		canonical_route.append({"x": int(point["x"]), "y": int(point["y"])})

	var canonical_attributes: Dictionary = {}
	var attribute_keys: Array = integer_attributes.keys()
	attribute_keys.sort()
	for key_variant: Variant in attribute_keys:
		canonical_attributes[str(key_variant)] = int(integer_attributes[key_variant])

	return {
		"active_order_id": active_order_id,
		"alive": alive,
		"catalog_id": catalog_id,
		"entity_kind": entity_kind,
		"facing_mdeg": facing_mdeg,
		"hp": hp,
		"integer_attributes": canonical_attributes,
		"internal_id": internal_id,
		"mana": mana,
		"max_hp": max_hp,
		"max_mana": max_mana,
		"movement_remainder_mt": movement_remainder_mt,
		"next_replan_tick": next_replan_tick,
		"owner_seat": owner_seat,
		"position_mt": {"x": position_x_mt, "y": position_y_mt},
		"public_id": public_id,
		"radius_mt": radius_mt,
		"route": canonical_route,
		"route_index": route_index,
		"segment_denominator": segment_denominator,
		"segment_numerator": segment_numerator,
		"tags": canonical_tags,
	}


func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if internal_id <= 0:
		errors.append("entity internal_id must be positive")
	if owner_seat < -1 or owner_seat > 1:
		errors.append("entity owner_seat must be -1, 0, or 1")
	if entity_kind.is_empty():
		errors.append("entity_kind must not be empty")
	if radius_mt < 0:
		errors.append("radius_mt must be non-negative")
	if facing_mdeg < 0 or facing_mdeg >= 360_000:
		errors.append("facing_mdeg must be in [0, 360000)")
	if max_hp < 0 or hp < 0 or hp > max_hp:
		errors.append("hp must be in [0, max_hp]")
	if max_mana < 0 or mana < 0 or mana > max_mana:
		errors.append("mana must be in [0, max_mana]")
	if segment_denominator <= 0:
		errors.append("segment_denominator must be positive")
	if segment_numerator < 0 or segment_numerator > segment_denominator:
		errors.append("segment_numerator must be in [0, segment_denominator]")
	if route_index < 0 or route_index > route.size():
		errors.append("route_index must be in [0, route size]")
	var seen_tags: Dictionary = {}
	for tag: String in tags:
		if seen_tags.has(tag):
			errors.append("tags must not contain duplicates")
		else:
			seen_tags[tag] = true
	for key_variant: Variant in integer_attributes.keys():
		if typeof(key_variant) != TYPE_STRING:
			errors.append("integer_attributes keys must be strings")
		elif typeof(integer_attributes[key_variant]) != TYPE_INT:
			errors.append("integer_attributes.%s must be an integer" % str(key_variant))
	for index: int in route.size():
		var point: Dictionary = route[index]
		if not point.has("x") or not point.has("y"):
			errors.append("route[%d] must have x and y" % index)
		elif typeof(point["x"]) != TYPE_INT or typeof(point["y"]) != TYPE_INT:
			errors.append("route[%d] coordinates must be integers" % index)
	return errors
