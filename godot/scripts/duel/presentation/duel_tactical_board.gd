extends Control
class_name DuelTacticalBoard

## Lightweight projection renderer used until reviewed production meshes are
## installed. All marks are visual; clicks emit requests instead of issuing orders.

signal entity_focus_requested(entity_id: String)
signal map_focus_requested(normalized_position: Vector2)

const SEAT_COLORS := [Color("ffad42"), Color("43c7ff")]
const SEAT_GLYPHS := ["▲", "◆"]
const NEUTRAL := Color("b7c2cb")

var _projection: Dictionary = {}
var _hovered_entity_id := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	tooltip_text = "Read-only tactical projection. Click an entity to inspect it."
	queue_redraw()


func apply_projection(projection: Dictionary) -> void:
	_projection = projection.duplicate(true)
	queue_redraw()


func projection_copy() -> Dictionary:
	return _projection.duplicate(true)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("081622"), true)
	_draw_terrain()
	var entities: Array = _projection.get("entities", [])
	for raw_entity: Variant in entities:
		if raw_entity is Dictionary:
			_draw_entity(raw_entity)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(20, 30), "PROJECTED TACTICAL VIEW", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("91aabd"))
	if _projection.is_empty():
		draw_string(font, Vector2(20, 56), "Waiting for a spectator projection…", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("d7e2e9"))


func _draw_terrain() -> void:
	var spacing := 48.0
	var x := 0.0
	while x <= size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.12, 0.23, 0.30, 0.42), 1.0)
		x += spacing
	var y := 0.0
	while y <= size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.12, 0.23, 0.30, 0.42), 1.0)
		y += spacing
	var map_data: Dictionary = _projection.get("map", {})
	for raw_lane: Variant in map_data.get("display_lanes", []):
		if raw_lane is Array and raw_lane.size() >= 2:
			var previous := _normalized_point(raw_lane[0]) * size
			for index in range(1, raw_lane.size()):
				var next := _normalized_point(raw_lane[index]) * size
				draw_line(previous, next, Color(0.34, 0.37, 0.29, 0.7), 9.0, true)
				previous = next


func _draw_entity(entity: Dictionary) -> void:
	var point := _entity_position(entity) * size
	var slot := int(entity.get("player_slot", entity.get("slot", -1)))
	var color: Color = SEAT_COLORS[slot] if slot >= 0 and slot < SEAT_COLORS.size() else NEUTRAL
	var glyph: String = SEAT_GLYPHS[slot] if slot >= 0 and slot < SEAT_GLYPHS.size() else "•"
	var kind := str(entity.get("kind", entity.get("entity_kind", "unit")))
	var radius := 9.0 if kind in ["structure", "building", "stronghold"] else 6.0
	var stale := bool(entity.get("last_known", false)) or str(entity.get("visibility", "visible")) == "stale"
	if stale:
		draw_circle(point, radius + 2.0, Color(color, 0.15), true)
		draw_dashed_line(point - Vector2(radius + 4, 0), point + Vector2(radius + 4, 0), color, 2.0, 3.0)
	elif kind in ["structure", "building", "stronghold"]:
		draw_rect(Rect2(point - Vector2(radius, radius), Vector2(radius * 2, radius * 2)), Color(color, 0.82), true)
		draw_rect(Rect2(point - Vector2(radius, radius), Vector2(radius * 2, radius * 2)), Color.WHITE, false, 1.0)
	else:
		draw_circle(point, radius, color, true)
		draw_circle(point, radius, Color("f4f8fa"), false, 1.0, true)
	var entity_id := str(entity.get("id", entity.get("entity_id", "")))
	if entity_id == _hovered_entity_id or bool(entity.get("selected", false)):
		draw_arc(point, radius + 6.0, 0.0, TAU, 30, Color("f6f078"), 2.0, true)
	var max_hp := maxi(0, int(entity.get("max_hp", 0)))
	if max_hp > 0:
		var hp := clampi(int(entity.get("hp", max_hp)), 0, max_hp)
		var bar := Rect2(point + Vector2(-10, -radius - 8), Vector2(20, 3))
		draw_rect(bar, Color("351d25"), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(hp) / float(max_hp), bar.size.y)), Color("74e18e"), true)
	var font := ThemeDB.fallback_font
	draw_string(font, point + Vector2(-4, 4), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("07111c"))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hovered_entity_id = _nearest_entity_id(event.position, 18.0)
		queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var entity_id := _nearest_entity_id(event.position, 22.0)
		if not entity_id.is_empty():
			entity_focus_requested.emit(entity_id)
		else:
			map_focus_requested.emit(Vector2(
				clampf(event.position.x / maxf(size.x, 1.0), 0.0, 1.0),
				clampf(event.position.y / maxf(size.y, 1.0), 0.0, 1.0)
			))
		accept_event()


func _nearest_entity_id(canvas_point: Vector2, maximum_distance: float) -> String:
	var nearest_id := ""
	var nearest_distance := maximum_distance
	for raw_entity: Variant in _projection.get("entities", []):
		if not raw_entity is Dictionary:
			continue
		var distance := canvas_point.distance_to(_entity_position(raw_entity) * size)
		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_id = str(raw_entity.get("id", raw_entity.get("entity_id", "")))
	return nearest_id


func _entity_position(entity: Dictionary) -> Vector2:
	var raw: Variant = entity.get("map_position", entity.get("position", entity.get("position_mt", [0, 0])))
	var point := _vector2(raw)
	if bool(entity.get("position_normalized", false)):
		return _normalized_point(point)
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
