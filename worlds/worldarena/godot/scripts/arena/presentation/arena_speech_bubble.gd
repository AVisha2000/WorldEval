extends PanelContainer

signal selected(event_id: String)

var actor_id := ""
var event_id := ""
var expires_at_msec := 0
var _header: Label
var _body: Label
var _privacy: Label
var _event: Dictionary = {}


func configure(event: Dictionary, faction_color: Color) -> void:
	_ensure_ui()
	_event = event.duplicate(true)
	event_id = str(event.get("event_id", ""))
	actor_id = str(event.get("actor_id", ""))
	var targets: Array = event.get("target_ids", [])
	var target_text := "ALL" if targets.is_empty() else ", ".join(targets.map(func(value: Variant) -> String: return str(value).to_upper()))
	var visibility_kind := str(event.get("visibility", "public"))
	var kind := str(event.get("kind", "message"))
	var icon := _kind_icon(kind, visibility_kind)
	_header.text = "%s  %s → %s" % [icon, actor_id.to_upper(), target_text]
	_body.text = str(event.get("summary", event.get("message", ""))).substr(0, 110)
	_privacy.text = "PRIVATE — SPECTATOR ONLY" if visibility_kind != "public" else "PUBLIC CHANNEL"
	_privacy.modulate = Color("ffb35c") if visibility_kind != "public" else Color("9fe3d2")
	expires_at_msec = Time.get_ticks_msec() + int(event.get("duration_ms", 6000))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.055, 0.073, 0.96)
	style.border_color = faction_color
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 13
	style.content_margin_right = 13
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	add_theme_stylebox_override("panel", style)
	tooltip_text = "Open diplomacy event %s" % event_id


func is_expired() -> bool:
	return Time.get_ticks_msec() >= expires_at_msec


func _ensure_ui() -> void:
	if _body != null:
		return
	custom_minimum_size = Vector2(238, 80)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	add_child(box)
	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 12)
	_header.add_theme_color_override("font_color", Color("fff3c4"))
	box.add_child(_header)
	_body = Label.new()
	_body.custom_minimum_size.x = 210
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.max_lines_visible = 2
	_body.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_body.add_theme_font_size_override("font_size", 14)
	_body.add_theme_color_override("font_color", Color("edf7ed"))
	box.add_child(_body)
	_privacy = Label.new()
	_privacy.add_theme_font_size_override("font_size", 10)
	box.add_child(_privacy)


func _gui_input(input_event: InputEvent) -> void:
	if input_event is InputEventMouseButton and input_event.pressed and input_event.button_index == MOUSE_BUTTON_LEFT:
		selected.emit(event_id)
		accept_event()


func _kind_icon(kind: String, visibility_kind: String) -> String:
	match kind:
		"offer", "trade": return "⇄"
		"pact": return "◇"
		"betrayal": return "⚡"
		_:
			return "●" if visibility_kind == "public" else "◆"
