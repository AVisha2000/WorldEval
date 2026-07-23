class_name ArenaConquestMinimap
extends Control

## Compact spectator minimap.  It is intentionally a projection of snapshots,
## not a visibility authority: the dim outer ring is a cosmetic fog boundary.

const COLORS := {"sol": Color("d25530"), "terra": Color("2a9a70"), "luna": Color("5367cf"), "neutral": Color("536d72")}
const KENNEY_RING := "res://assets/external/kenney_ui_pack_adventure/Vector/minimap_ring_brown.svg"
var districts: Array = []
var units: Array = []


func apply_snapshot(snapshot: Dictionary) -> void:
	districts = snapshot.get("districts", []).duplicate(true)
	units = snapshot.get("units", []).duplicate(true)
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2(3, 3), size - Vector2(6, 6))
	draw_style_box(_panel(), rect)
	if ResourceLoader.exists(KENNEY_RING):
		draw_texture_rect(load(KENNEY_RING), rect, false, Color(1, 1, 1, 0.72))
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.41
	draw_circle(center, radius, Color("102631"))
	draw_arc(center, radius, 0.0, TAU, 48, Color("c99842"), 1.0)
	for raw in districts:
		if not raw is Dictionary: continue
		var district: Dictionary = raw
		var id := str(district.get("id", ""))
		var position := _district_position(id)
		var color: Color = COLORS.get(str(district.get("owner", "neutral")), COLORS.neutral)
		draw_circle(center + position * radius, 4.0 if id.begins_with("core_") else 2.4, color)
	for raw in units:
		if not raw is Dictionary: continue
		var unit: Dictionary = raw
		var district_position := _district_position(str(unit.get("district_id", "")))
		draw_circle(center + district_position * radius, 1.4, COLORS.get(str(unit.get("faction_id", "neutral")), COLORS.neutral).lightened(0.35))
	# Stable spectator fog edge: communicates exploration pressure without claiming
	# an authoritative per-faction visibility result.
	draw_arc(center, radius * 1.05, -0.5, 0.95, 18, Color("071018cc"), radius * 0.24)


func _district_position(id: String) -> Vector2:
	if id.ends_with("sol"): return Vector2(-0.58, 0.48)
	if id.ends_with("terra"): return Vector2(0.58, 0.48)
	if id.ends_with("luna"): return Vector2(0.0, -0.60)
	if id == "crossroads": return Vector2.ZERO
	if id.ends_with("st"): return Vector2(0.0, 0.42)
	if id.ends_with("tl"): return Vector2(0.42, -0.12)
	return Vector2(-0.42, -0.12)


func _panel() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("061016e8")
	style.border_color = Color("79541f")
	style.set_border_width_all(1)
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 5
	return style
