extends Control
class_name DuelMinimap

## Renders only the already-filtered projection supplied by the host. It never
## computes vision or removes omniscient entities on behalf of a faction view.

signal focus_requested(normalized_position: Vector2)

const SEAT_COLORS := [Color("ffad42"), Color("43c7ff")]
const BACKGROUND := Color("07111c")
const GRID := Color("284054")
const NEUTRAL := Color("b7c2cb")

var _projection: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(220.0, 152.0)
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	tooltip_text = "Minimap. Select a point to request spectator focus."
	queue_redraw()


func apply_projection(projection: Dictionary) -> void:
	_projection = projection.duplicate(true)
	queue_redraw()


func projection_copy() -> Dictionary:
	return _projection.duplicate(true)


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, BACKGROUND, true)
	draw_rect(rect.grow(-1.0), Color("5c788d"), false, 2.0)
	for index in range(1, 4):
		var x := size.x * float(index) / 4.0
		var y := size.y * float(index) / 4.0
		draw_line(Vector2(x, 0), Vector2(x, size.y), GRID, 1.0)
		draw_line(Vector2(0, y), Vector2(size.x, y), GRID, 1.0)
	_draw_visibility_patterns()
	var entities: Array = _projection.get("entities", [])
	for raw_entity: Variant in entities:
		if raw_entity is Dictionary:
			_draw_entity(raw_entity)


func _draw_visibility_patterns() -> void:
	var map_data: Dictionary = _projection.get("map", {})
	var explored: Array = map_data.get("explored_regions", [])
	for raw_region: Variant in explored:
		if raw_region is Array and raw_region.size() >= 2:
			var origin := _normalized_point(raw_region[0]) * size
			var extent := _normalized_point(raw_region[1]) * size
			draw_rect(Rect2(origin, extent - origin), Color(0.15, 0.22, 0.28, 0.48), true)
	var visible: Array = map_data.get("visible_regions", [])
	for raw_region: Variant in visible:
		if raw_region is Array and raw_region.size() >= 2:
			var origin := _normalized_point(raw_region[0]) * size
			var extent := _normalized_point(raw_region[1]) * size
			draw_rect(Rect2(origin, extent - origin), Color(0.22, 0.34, 0.38, 0.30), true)


func _draw_entity(entity: Dictionary) -> void:
	var normalized := _entity_position(entity)
	var point := Vector2(normalized.x * size.x, normalized.y * size.y)
	var slot := int(entity.get("player_slot", entity.get("slot", -1)))
	var color: Color = SEAT_COLORS[slot] if slot >= 0 and slot < SEAT_COLORS.size() else NEUTRAL
	var stale := bool(entity.get("last_known", false)) or str(entity.get("visibility", "visible")) == "stale"
	var kind := str(entity.get("kind", entity.get("entity_kind", "unit")))
	if kind in ["structure", "building", "stronghold"]:
		var marker := Rect2(point - Vector2(3.5, 3.5), Vector2(7.0, 7.0))
		if stale:
			draw_rect(marker, color, false, 1.5)
		else:
			draw_rect(marker, color, true)
	else:
		if stale:
			draw_circle(point, 2.8, color, false, 1.25, true)
		else:
			draw_circle(point, 2.8, color, true)
	if stale:
		draw_dashed_line(point - Vector2(5, 0), point + Vector2(5, 0), color, 1.0, 2.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var normalized := Vector2(
			clampf(event.position.x / maxf(size.x, 1.0), 0.0, 1.0),
			clampf(event.position.y / maxf(size.y, 1.0), 0.0, 1.0)
		)
		focus_requested.emit(normalized)
		accept_event()


func _entity_position(entity: Dictionary) -> Vector2:
	var raw: Variant = entity.get("map_position", entity.get("position", entity.get("position_mt", [0, 0])))
	var point := _vector2(raw)
	if bool(entity.get("position_normalized", false)):
		return Vector2(clampf(point.x, 0.0, 1.0), clampf(point.y, 0.0, 1.0))
	var map_data: Dictionary = _projection.get("map", {})
	var width := maxf(float(map_data.get("width", map_data.get("width_mt", 192000))), 1.0)
	var height := maxf(float(map_data.get("height", map_data.get("height_mt", 128000))), 1.0)
	return Vector2(clampf(point.x / width, 0.0, 1.0), clampf(point.y / height, 0.0, 1.0))


func _normalized_point(raw: Variant) -> Vector2:
	var point := _vector2(raw)
	return Vector2(clampf(point.x, 0.0, 1.0), clampf(point.y, 0.0, 1.0))


func _vector2(raw: Variant) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and raw.size() >= 2:
		return Vector2(float(raw[0]), float(raw[1]))
	if raw is Dictionary:
		return Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)))
	return Vector2.ZERO
