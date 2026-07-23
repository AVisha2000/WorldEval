extends Control
class_name DuelHud

## Read-only spectator HUD. It exposes user intent as signals; no control invokes
## simulation methods or edits the projection that supplied its display values.

signal perspective_requested(perspective_id: String)
signal pause_requested(paused: bool)
signal playback_speed_requested(speed: float)
signal replay_seek_requested(tick: int)
signal event_focus_requested(event_id: String)
signal event_filter_requested(category: String)
signal minimap_focus_requested(normalized_position: Vector2)

const MinimapScript := preload("res://scripts/duel/presentation/duel_minimap.gd")
const SEAT_COLORS := [Color("ffad42"), Color("43c7ff")]
const SEAT_GLYPHS := ["▲", "◆"]
const EVENT_COLORS := {
	"combat": Color("ff9c8d"),
	"hero": Color("dcb4ff"),
	"economy": Color("ffd27a"),
	"tech": Color("8bd8ff"),
	"creep": Color("b6d58b"),
	"item": Color("f4dd8f"),
	"protocol": Color("a9bac5"),
	"terminal": Color("ffffff"),
}

var _built := false
var _projection: Dictionary = {}
var _event_history: Array[Dictionary] = []
var _seen_event_ids: Dictionary = {}
var _paused := false
var _replay_mode := false
var _selected_speed := 1.0
var _updating_controls := false

var objective_label: Label
var clock_label: Label
var mode_label: Label
var countdown_label: Label
var perspective_select: OptionButton
var player_name_labels: Array[Label] = []
var stronghold_bars: Array[ProgressBar] = []
var resource_labels: Array[Label] = []
var hero_labels: Array[Label] = []
var intent_labels: Array[Label] = []
var response_labels: Array[Label] = []
var event_feed: VBoxContainer
var event_filter_select: OptionButton
var selected_title: Label
var selected_stats: Label
var selected_order: Label
var selected_queue: Label
var selected_abilities: Label
var minimap
var pause_button: Button
var speed_select: OptionButton
var seek_slider: HSlider
var replay_status_label: Label


func _ready() -> void:
	_ensure_built()
	_apply_empty_state()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	name = "SpectatorHUD"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top_bar()
	_build_player_card(0)
	_build_player_card(1)
	_build_minimap_panel()
	_build_event_panel()
	_build_selection_panel()
	_build_replay_bar()


func _build_top_bar() -> void:
	var panel := PanelContainer.new()
	panel.name = "TopBar"
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_left = 12
	panel.offset_top = 10
	panel.offset_right = -12
	panel.offset_bottom = 78
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _style_box(Color(0.035, 0.08, 0.12, 0.97), Color("3c6076"), 8, 1))
	add_child(panel)
	var margin := _margin(14, 14, 8, 8)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	margin.add_child(row)
	var objective_stack := VBoxContainer.new()
	objective_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(objective_stack)
	objective_stack.add_child(_label("OBJECTIVE", 10, Color("6fcdf3")))
	objective_label = _label("Destroy the opposing Stronghold", 17, Color("f1f6f8"))
	objective_stack.add_child(objective_label)
	var clock_stack := VBoxContainer.new()
	clock_stack.custom_minimum_size.x = 160
	clock_stack.add_child(_label("SIMULATED TIME", 10, Color("7f9bad")))
	clock_label = _label("00:00  •  TICK 00000  •  DAY", 14, Color("e3ebef"))
	clock_stack.add_child(clock_label)
	row.add_child(clock_stack)
	var mode_stack := VBoxContainer.new()
	mode_stack.custom_minimum_size.x = 185
	mode_stack.add_child(_label("DECISION WINDOW", 10, Color("7f9bad")))
	mode_label = _label("FIXED & SIMULTANEOUS", 13, Color("98e0ff"))
	mode_stack.add_child(mode_label)
	countdown_label = _label("Next boundary in 100 ticks", 11, Color("b2c3cd"))
	mode_stack.add_child(countdown_label)
	row.add_child(mode_stack)
	var perspective_stack := VBoxContainer.new()
	perspective_stack.custom_minimum_size.x = 180
	perspective_stack.add_child(_label("PERSPECTIVE", 10, Color("7f9bad")))
	perspective_select = OptionButton.new()
	perspective_select.name = "PerspectiveSelect"
	perspective_select.tooltip_text = "Switch between a separate omniscient projection and either model's legal knowledge projection. Keys: O, 1, 2."
	for option in [
		{"label": "Omniscient", "id": "omniscient"},
		{"label": "▲ Model A knowledge", "id": "seat_0"},
		{"label": "◆ Model B knowledge", "id": "seat_1"},
	]:
		perspective_select.add_item(option["label"])
		perspective_select.set_item_metadata(perspective_select.item_count - 1, option["id"])
	perspective_select.item_selected.connect(_on_perspective_selected)
	perspective_stack.add_child(perspective_select)
	row.add_child(perspective_stack)


func _build_player_card(slot: int) -> void:
	var panel := PanelContainer.new()
	panel.name = "PlayerCard%d" % slot
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_top = 92
	panel.offset_bottom = 295
	if slot == 0:
		panel.anchor_left = 0.0
		panel.anchor_right = 0.0
		panel.offset_left = 12
		panel.offset_right = 260
	else:
		panel.anchor_left = 1.0
		panel.anchor_right = 1.0
		panel.offset_left = -260
		panel.offset_right = -12
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _style_box(Color(0.04, 0.09, 0.13, 0.96), SEAT_COLORS[slot], 8, 2))
	add_child(panel)
	var margin := _margin(12, 12, 10, 10)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	margin.add_child(body)
	var name_label := _label("%s MODEL %s" % [SEAT_GLYPHS[slot], "A" if slot == 0 else "B"], 16, SEAT_COLORS[slot])
	player_name_labels.append(name_label)
	body.add_child(name_label)
	var stronghold_row := HBoxContainer.new()
	stronghold_row.add_child(_label("STRONGHOLD", 10, Color("8ba4b3")))
	var bar := ProgressBar.new()
	bar.name = "StrongholdBar%d" % slot
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.max_value = 3000
	bar.value = 3000
	bar.show_percentage = false
	bar.custom_minimum_size.y = 12
	bar.tooltip_text = "Starting Stronghold health; destruction ends the match."
	bar.add_theme_stylebox_override("background", _style_box(Color("301b22"), Color("633743"), 3, 0))
	bar.add_theme_stylebox_override("fill", _style_box(SEAT_COLORS[slot].darkened(0.12), SEAT_COLORS[slot], 3, 0))
	stronghold_bars.append(bar)
	stronghold_row.add_child(bar)
	body.add_child(stronghold_row)
	var resources := _label("G  500   L  200   FOOD  5 / 20   TIER  1", 12, Color("edf3f5"))
	resources.tooltip_text = "Gold, lumber, food used/cap, upkeep, and tech tier."
	resources.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	resource_labels.append(resources)
	body.add_child(resources)
	var heroes := _label("HEROES  None hired", 11, Color("c4d2da"))
	heroes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hero_labels.append(heroes)
	body.add_child(heroes)
	var intent := _label("INTENT  Waiting for first decision", 11, Color("d3e0e6"))
	intent.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intent_labels.append(intent)
	body.add_child(intent)
	var response := _label("●  WAITING", 11, Color("a7bac6"))
	response_labels.append(response)
	body.add_child(response)


func _build_minimap_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "MinimapPanel"
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12
	panel.offset_top = -338
	panel.offset_right = 260
	panel.offset_bottom = -126
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _style_box(Color(0.035, 0.08, 0.12, 0.97), Color("3c6076"), 8, 1))
	add_child(panel)
	var margin := _margin(10, 10, 8, 8)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	margin.add_child(body)
	var header := HBoxContainer.new()
	header.add_child(_label("TACTICAL MAP", 11, Color("90dafa")))
	var legend := _label("▲ A   ◆ B   □ structure   — stale", 10, Color("9fb2be"))
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	legend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(legend)
	body.add_child(header)
	minimap = MinimapScript.new()
	minimap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	minimap.focus_requested.connect(func(position: Vector2) -> void: minimap_focus_requested.emit(position))
	body.add_child(minimap)


func _build_event_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "EventPanel"
	panel.anchor_left = 1.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -260
	panel.offset_top = 310
	panel.offset_right = -12
	panel.offset_bottom = -126
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _style_box(Color(0.035, 0.08, 0.12, 0.97), Color("3c6076"), 8, 1))
	add_child(panel)
	var margin := _margin(10, 10, 8, 8)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	margin.add_child(body)
	var header := HBoxContainer.new()
	header.add_child(_label("MATCH EVENTS", 11, Color("90dafa")))
	event_filter_select = OptionButton.new()
	event_filter_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	event_filter_select.tooltip_text = "Filter the spectator feed by event category."
	for category in ["all", "combat", "hero", "economy", "tech", "creep", "item", "protocol", "terminal"]:
		event_filter_select.add_item(category.capitalize())
		event_filter_select.set_item_metadata(event_filter_select.item_count - 1, category)
	event_filter_select.item_selected.connect(_on_event_filter_selected)
	header.add_child(event_filter_select)
	body.add_child(header)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	event_feed = VBoxContainer.new()
	event_feed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	event_feed.add_theme_constant_override("separation", 5)
	scroll.add_child(event_feed)


func _build_selection_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "SelectionPanel"
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 276
	panel.offset_top = -194
	panel.offset_right = -276
	panel.offset_bottom = -126
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _style_box(Color(0.035, 0.08, 0.12, 0.97), Color("3c6076"), 8, 1))
	add_child(panel)
	var margin := _margin(12, 12, 8, 8)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	margin.add_child(row)
	var identity := VBoxContainer.new()
	identity.custom_minimum_size.x = 180
	identity.add_child(_label("SELECTED", 10, Color("7f9bad")))
	selected_title = _label("Nothing selected", 15, Color("f0f4f6"))
	identity.add_child(selected_title)
	selected_stats = _label("Choose a projected entity to inspect", 11, Color("b3c4cd"))
	identity.add_child(selected_stats)
	row.add_child(identity)
	var order_stack := VBoxContainer.new()
	order_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_stack.add_child(_label("CURRENT ORDER & QUEUE", 10, Color("7f9bad")))
	selected_order = _label("—", 12, Color("dce6eb"))
	order_stack.add_child(selected_order)
	selected_queue = _label("Queue: —", 11, Color("9fb2be"))
	order_stack.add_child(selected_queue)
	row.add_child(order_stack)
	var ability_stack := VBoxContainer.new()
	ability_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ability_stack.add_child(_label("ABILITIES & ITEMS", 10, Color("7f9bad")))
	selected_abilities = _label("—", 11, Color("c8d5dc"))
	selected_abilities.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ability_stack.add_child(selected_abilities)
	row.add_child(ability_stack)


func _build_replay_bar() -> void:
	var panel := PanelContainer.new()
	panel.name = "ReplayBar"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 12
	panel.offset_top = -112
	panel.offset_right = -12
	panel.offset_bottom = -10
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _style_box(Color(0.025, 0.06, 0.095, 0.98), Color("4e7187"), 8, 1))
	add_child(panel)
	var margin := _margin(12, 12, 8, 8)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	margin.add_child(body)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	pause_button = Button.new()
	pause_button.name = "PauseButton"
	pause_button.text = "Ⅱ  PAUSE"
	pause_button.tooltip_text = "Pause/resume spectator playback (Space). Does not pause a live authoritative continuous match."
	pause_button.custom_minimum_size.x = 112
	pause_button.pressed.connect(toggle_pause)
	row.add_child(pause_button)
	speed_select = OptionButton.new()
	speed_select.name = "SpeedSelect"
	speed_select.tooltip_text = "Playback speed. Continuous live viewing is restricted to 1× or slower."
	for speed in [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]:
		speed_select.add_item("%s×" % str(speed))
		speed_select.set_item_metadata(speed_select.item_count - 1, speed)
		if speed == 1.0:
			speed_select.select(speed_select.item_count - 1)
	speed_select.item_selected.connect(_on_speed_selected)
	row.add_child(speed_select)
	replay_status_label = _label("LIVE • playback controls request spectator actions only", 11, Color("8fa8b7"))
	replay_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(replay_status_label)
	var key_legend := _label("O/1/2 view   Space pause   ←/→ seek", 10, Color("8199a8"))
	row.add_child(key_legend)
	seek_slider = HSlider.new()
	seek_slider.name = "ReplaySeekSlider"
	seek_slider.min_value = 0
	seek_slider.max_value = 18000
	seek_slider.step = 1
	seek_slider.tooltip_text = "Replay timeline. Seeking is enabled only for verified replay playback."
	seek_slider.editable = false
	seek_slider.drag_ended.connect(_on_seek_drag_ended)
	body.add_child(seek_slider)


func apply_projection(projection: Dictionary) -> void:
	_ensure_built()
	_projection = projection.duplicate(true)
	objective_label.text = str(_projection.get("objective", "Destroy the opposing Stronghold"))
	var tick := int(_projection.get("tick", 0))
	var hz := maxi(1, int(_projection.get("simulation_hz", 10)))
	var total_seconds := tick / hz
	clock_label.text = "%02d:%02d  •  TICK %05d  •  %s" % [
		total_seconds / 60, total_seconds % 60, tick,
		str(_projection.get("day_phase", "day")).to_upper()]
	var mode := str(_projection.get("decision_mode", _projection.get("mode", "fixed_simultaneous")))
	mode_label.text = "CONTINUOUS REAL TIME" if mode == "continuous_realtime" else "FIXED & SIMULTANEOUS"
	var remaining := int(_projection.get("decision_ticks_remaining", _projection.get("application_ticks_remaining", 0)))
	countdown_label.text = "%s in %d ticks" % ["Next opportunity" if mode == "continuous_realtime" else "Next boundary", remaining]
	var players: Array = _projection.get("players", [])
	for slot in 2:
		var player: Dictionary = players[slot] if slot < players.size() and players[slot] is Dictionary else {}
		_apply_player(slot, player)
	minimap.apply_projection(_projection)
	apply_selected(_projection.get("selected", {}))
	_refresh_playback_policy()


func _apply_player(slot: int, player: Dictionary) -> void:
	var label := str(player.get("label", "Model %s" % ["A" if slot == 0 else "B"]))
	player_name_labels[slot].text = "%s  %s" % [SEAT_GLYPHS[slot], label.to_upper()]
	var stronghold: Dictionary = player.get("stronghold", {})
	var max_hp := maxi(1, int(stronghold.get("max_hp", 3000)))
	stronghold_bars[slot].max_value = max_hp
	stronghold_bars[slot].value = clampi(int(stronghold.get("hp", max_hp)), 0, max_hp)
	stronghold_bars[slot].tooltip_text = "Stronghold %d / %d HP" % [int(stronghold_bars[slot].value), max_hp]
	var resources: Dictionary = player.get("resources", player)
	var upkeep := str(resources.get("upkeep", "none"))
	resource_labels[slot].text = "G  %d   L  %d   FOOD  %d / %d\n%s UPKEEP  •  TIER %d" % [
		int(resources.get("gold", 0)), int(resources.get("lumber", 0)),
		int(resources.get("food_used", 0)), int(resources.get("food_cap", 0)),
		upkeep.to_upper(), int(player.get("tier", resources.get("tier", 1)))]
	var hero_parts := PackedStringArray()
	for raw_hero: Variant in player.get("heroes", []):
		if raw_hero is Dictionary:
			hero_parts.append("%s L%d %d/%d HP %s" % [
				str(raw_hero.get("name", raw_hero.get("type", "Hero"))),
				int(raw_hero.get("level", 1)), int(raw_hero.get("hp", 0)),
				int(raw_hero.get("max_hp", 0)), str(raw_hero.get("state", "ready"))])
	hero_labels[slot].text = "HEROES  %s" % ["None hired" if hero_parts.is_empty() else "  •  ".join(hero_parts)]
	intent_labels[slot].text = "INTENT  %s  •  ARMY %d" % [
		str(player.get("current_intent", "Waiting")), int(player.get("army_value", 0))]
	var response: Dictionary = player.get("response", {})
	var state := str(response.get("state", "waiting")).to_lower()
	var response_color := Color("a7bac6")
	if state in ["accepted", "ready", "received"]:
		response_color = Color("8ce6a3")
	elif state in ["thinking", "in_flight"]:
		response_color = Color("ffcf6b")
	elif state in ["late", "rejected", "error"]:
		response_color = Color("ff8c87")
	var latency := int(response.get("latency_ms", 0))
	response_labels[slot].text = "●  %s%s" % [state.to_upper(), "  %d ms" % latency if latency > 0 else ""]
	response_labels[slot].add_theme_color_override("font_color", response_color)


func apply_selected(selected: Dictionary) -> void:
	_ensure_built()
	var copy := selected.duplicate(true)
	if copy.is_empty():
		selected_title.text = "Nothing selected"
		selected_stats.text = "Choose a projected entity to inspect"
		selected_order.text = "—"
		selected_queue.text = "Queue: —"
		selected_abilities.text = "—"
		return
	selected_title.text = str(copy.get("display_name", copy.get("type", copy.get("id", "Selected entity"))))
	selected_stats.text = "HP %d / %d   MP %d / %d   Armor %s" % [
		int(copy.get("hp", 0)), int(copy.get("max_hp", 0)), int(copy.get("mana", 0)),
		int(copy.get("max_mana", 0)), str(copy.get("armor", "—"))]
	selected_order.text = str(copy.get("current_order", "Idle"))
	var queue_parts := PackedStringArray()
	for raw_order: Variant in copy.get("order_queue", []):
		queue_parts.append(str(raw_order.get("label", raw_order.get("kind", "order"))) if raw_order is Dictionary else str(raw_order))
	selected_queue.text = "Queue: %s" % ["—" if queue_parts.is_empty() else " → ".join(queue_parts)]
	var capabilities := PackedStringArray()
	for raw_ability: Variant in copy.get("abilities", []):
		capabilities.append(str(raw_ability.get("name", raw_ability.get("id", "ability"))) if raw_ability is Dictionary else str(raw_ability))
	for raw_item: Variant in copy.get("items", []):
		capabilities.append(str(raw_item.get("name", raw_item.get("id", "item"))) if raw_item is Dictionary else str(raw_item))
	selected_abilities.text = "—" if capabilities.is_empty() else "  •  ".join(capabilities)


func apply_events(events: Array) -> void:
	_ensure_built()
	for raw_event: Variant in events:
		if not raw_event is Dictionary:
			continue
		var event: Dictionary = raw_event.duplicate(true)
		var event_id := str(event.get("event_id", event.get("id", "event-%d-%d" % [int(event.get("tick", 0)), _event_history.size()])))
		if _seen_event_ids.has(event_id):
			continue
		event["event_id"] = event_id
		_seen_event_ids[event_id] = true
		_event_history.append(event)
	while _event_history.size() > 40:
		var removed: Dictionary = _event_history.pop_front()
		_seen_event_ids.erase(str(removed.get("event_id", "")))
	_refresh_event_feed()


func event_history_copy() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for event: Dictionary in _event_history:
		copy.append(event.duplicate(true))
	return copy


func _refresh_event_feed() -> void:
	for child in event_feed.get_children():
		child.queue_free()
	var filter_id := str(event_filter_select.get_item_metadata(event_filter_select.selected))
	var visible_count := 0
	for index in range(_event_history.size() - 1, -1, -1):
		var event := _event_history[index]
		var category := str(event.get("category", event.get("kind", "protocol"))).to_lower()
		if filter_id != "all" and category != filter_id:
			continue
		var button := Button.new()
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text = "T%05d  %s" % [int(event.get("tick", 0)), str(event.get("text", event.get("summary", category.capitalize())))]
		button.tooltip_text = "Focus event %s" % str(event["event_id"])
		button.add_theme_font_size_override("font_size", 11)
		button.add_theme_color_override("font_color", EVENT_COLORS.get(category, Color("c2d0d8")))
		var event_id := str(event["event_id"])
		button.pressed.connect(func() -> void: event_focus_requested.emit(event_id))
		event_feed.add_child(button)
		visible_count += 1
		if visible_count >= 12:
			break
	if visible_count == 0:
		var empty := _label("No matching events yet.", 11, Color("7890a0"))
		event_feed.add_child(empty)


func set_replay_state(replay_state: Dictionary) -> void:
	_ensure_built()
	var copy := replay_state.duplicate(true)
	_replay_mode = bool(copy.get("replay", false))
	seek_slider.editable = _replay_mode and bool(copy.get("verified", false))
	seek_slider.max_value = maxi(1, int(copy.get("maximum_tick", _projection.get("maximum_match_ticks", 18000))))
	_updating_controls = true
	seek_slider.value = clampi(int(copy.get("tick", _projection.get("tick", 0))), 0, int(seek_slider.max_value))
	_updating_controls = false
	if _replay_mode:
		replay_status_label.text = "%s REPLAY  •  checkpoint %s" % [
			"VERIFIED" if bool(copy.get("verified", false)) else "UNVERIFIED",
			str(copy.get("checkpoint_status", "pending"))]
	else:
		replay_status_label.text = "LIVE • playback controls request spectator actions only"
	_refresh_playback_policy()


func toggle_pause() -> void:
	_ensure_built()
	_paused = not _paused
	pause_button.text = "▶  RESUME" if _paused else "Ⅱ  PAUSE"
	pause_requested.emit(_paused)


func request_perspective(perspective_id: String) -> bool:
	_ensure_built()
	for index in perspective_select.item_count:
		if str(perspective_select.get_item_metadata(index)) == perspective_id:
			_updating_controls = true
			perspective_select.select(index)
			_updating_controls = false
			perspective_requested.emit(perspective_id)
			return true
	return false


func request_playback_speed(speed: float) -> bool:
	_ensure_built()
	var mode := str(_projection.get("decision_mode", _projection.get("mode", "fixed_simultaneous")))
	if not _replay_mode and mode == "continuous_realtime" and speed > 1.0:
		return false
	for index in speed_select.item_count:
		if is_equal_approx(float(speed_select.get_item_metadata(index)), speed):
			_updating_controls = true
			speed_select.select(index)
			_updating_controls = false
			_selected_speed = speed
			playback_speed_requested.emit(speed)
			return true
	return false


func request_replay_seek(tick: int) -> bool:
	_ensure_built()
	if not seek_slider.editable:
		return false
	var bounded := clampi(tick, 0, int(seek_slider.max_value))
	seek_slider.value = bounded
	replay_seek_requested.emit(bounded)
	return true


func projection_copy() -> Dictionary:
	return _projection.duplicate(true)


func _on_perspective_selected(index: int) -> void:
	if not _updating_controls:
		perspective_requested.emit(str(perspective_select.get_item_metadata(index)))


func _on_speed_selected(index: int) -> void:
	if _updating_controls:
		return
	var requested := float(speed_select.get_item_metadata(index))
	if not request_playback_speed(requested):
		request_playback_speed(_selected_speed)


func _on_seek_drag_ended(value_changed: bool) -> void:
	if value_changed and not _updating_controls:
		request_replay_seek(int(seek_slider.value))


func _on_event_filter_selected(index: int) -> void:
	var category := str(event_filter_select.get_item_metadata(index))
	_refresh_event_feed()
	event_filter_requested.emit(category)


func _refresh_playback_policy() -> void:
	var continuous_live := not _replay_mode and str(_projection.get("decision_mode", _projection.get("mode", ""))) == "continuous_realtime"
	for index in speed_select.item_count:
		var speed := float(speed_select.get_item_metadata(index))
		speed_select.set_item_disabled(index, continuous_live and speed > 1.0)
	if continuous_live and _selected_speed > 1.0:
		request_playback_speed(1.0)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			toggle_pause()
			get_viewport().set_input_as_handled()
		KEY_O:
			request_perspective("omniscient")
			get_viewport().set_input_as_handled()
		KEY_1:
			request_perspective("seat_0")
			get_viewport().set_input_as_handled()
		KEY_2:
			request_perspective("seat_1")
			get_viewport().set_input_as_handled()
		KEY_LEFT:
			if seek_slider.editable:
				request_replay_seek(int(seek_slider.value) - 100)
				get_viewport().set_input_as_handled()
		KEY_RIGHT:
			if seek_slider.editable:
				request_replay_seek(int(seek_slider.value) + 100)
				get_viewport().set_input_as_handled()


func _apply_empty_state() -> void:
	apply_projection({
		"tick": 0,
		"simulation_hz": 10,
		"decision_mode": "fixed_simultaneous",
		"decision_ticks_remaining": 100,
		"players": [{"label": "Model A"}, {"label": "Model B"}],
		"map": {"width_mt": 192000, "height_mt": 128000},
		"entities": [],
	})
	_refresh_event_feed()


func _margin(left: int, right: int, top: int, bottom: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_bottom", bottom)
	return margin


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", maxi(12, font_size))
	label.add_theme_color_override("font_color", color)
	return label


func _style_box(fill: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style
