extends Control
class_name DuelPresentation

## Top-level read-only Duel presentation adapter. Authority supplies immutable
## projection dictionaries and public events; this scene emits spectator/setup
## requests only. It never receives DuelSimulation or DuelState references.

signal setup_submitted(config: Dictionary)
signal launch_requested(request: Dictionary)
signal perspective_requested(perspective_id: String)
signal pause_requested(paused: bool)
signal playback_speed_requested(speed: float)
signal replay_seek_requested(tick: int)
signal event_focus_requested(event_id: String)
signal event_filter_requested(category: String)
signal entity_focus_requested(entity_id: String)
signal map_focus_requested(normalized_position: Vector2)

const SetupPanelScript := preload("res://scripts/duel/presentation/duel_setup_panel.gd")
const HudScript := preload("res://scripts/duel/presentation/duel_hud.gd")
const TacticalBoardScript := preload("res://scripts/duel/presentation/duel_tactical_board.gd")
const AssetResolverScript := preload("res://scripts/duel/presentation/duel_display_asset_resolver.gd")

@export var start_in_live_preview := false

var setup_panel
var hud
var tactical_board
var setup_overlay: Control
var current_perspective := "omniscient"
var _projection_cache: Dictionary = {}
var _built := false
var _asset_resolver


func _ready() -> void:
	_ensure_built()
	if start_in_live_preview or _has_argument("--duel-live-preview"):
		show_live()
		apply_projection("omniscient", mock_projection())
		apply_events(mock_events())
	else:
		show_setup()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_asset_resolver = AssetResolverScript.new()
	_build_theme()
	_build_live_surface()
	_build_setup_surface()


func _build_theme() -> void:
	var duel_theme := Theme.new()
	duel_theme.default_font_size = 13
	duel_theme.set_color("font_color", "Label", Color("e7eef2"))
	duel_theme.set_color("font_color", "Button", Color("e7eef2"))
	duel_theme.set_color("font_hover_color", "Button", Color.WHITE)
	duel_theme.set_color("font_disabled_color", "Button", Color("738a99"))
	duel_theme.set_color("font_color", "LineEdit", Color("f4f7f8"))
	duel_theme.set_color("font_placeholder_color", "LineEdit", Color("849aa8"))
	duel_theme.set_color("font_color", "OptionButton", Color("eaf1f4"))
	duel_theme.set_font_size("font_size", "Label", 13)
	duel_theme.set_font_size("font_size", "Button", 13)
	duel_theme.set_font_size("font_size", "LineEdit", 13)
	duel_theme.set_font_size("font_size", "OptionButton", 13)
	theme = duel_theme


func _build_live_surface() -> void:
	var background := ColorRect.new()
	background.name = "LiveBackground"
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color("050d16")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var accent := TextureRect.new()
	accent.name = "ApprovedUiAccent"
	accent.set_anchors_preset(Control.PRESET_TOP_WIDE)
	accent.offset_bottom = 92
	accent.texture = _asset_resolver.texture("panel_accent")
	accent.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	accent.stretch_mode = TextureRect.STRETCH_TILE
	accent.modulate = Color(0.45, 0.70, 0.86, 0.12)
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	accent.visible = accent.texture != null
	add_child(accent)

	tactical_board = TacticalBoardScript.new()
	tactical_board.name = "TacticalBoard"
	tactical_board.anchor_left = 0.0
	tactical_board.anchor_top = 0.0
	tactical_board.anchor_right = 1.0
	tactical_board.anchor_bottom = 1.0
	tactical_board.offset_left = 276
	tactical_board.offset_top = 92
	tactical_board.offset_right = -276
	tactical_board.offset_bottom = -208
	tactical_board.entity_focus_requested.connect(_on_entity_focus_requested)
	tactical_board.map_focus_requested.connect(func(position: Vector2) -> void: map_focus_requested.emit(position))
	add_child(tactical_board)

	hud = HudScript.new()
	hud.name = "SpectatorHUD"
	hud.perspective_requested.connect(_on_perspective_requested)
	hud.pause_requested.connect(func(paused: bool) -> void: pause_requested.emit(paused))
	hud.playback_speed_requested.connect(func(speed: float) -> void: playback_speed_requested.emit(speed))
	hud.replay_seek_requested.connect(func(tick: int) -> void: replay_seek_requested.emit(tick))
	hud.event_focus_requested.connect(func(event_id: String) -> void: event_focus_requested.emit(event_id))
	hud.event_filter_requested.connect(func(category: String) -> void: event_filter_requested.emit(category))
	hud.minimap_focus_requested.connect(func(position: Vector2) -> void: map_focus_requested.emit(position))
	add_child(hud)


func _build_setup_surface() -> void:
	setup_overlay = Control.new()
	setup_overlay.name = "SetupOverlay"
	setup_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	setup_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(setup_overlay)
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.015, 0.035, 0.055, 0.985)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	setup_overlay.add_child(dim)
	var scroll := ScrollContainer.new()
	scroll.name = "SetupScroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 18
	scroll.offset_top = 12
	scroll.offset_right = -18
	scroll.offset_bottom = -12
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	setup_overlay.add_child(scroll)
	var center := CenterContainer.new()
	center.custom_minimum_size = Vector2(1116, 786)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	setup_panel = SetupPanelScript.new()
	setup_panel.setup_submitted.connect(_on_setup_submitted)
	setup_panel.launch_requested.connect(_on_launch_requested)
	center.add_child(setup_panel)


func show_setup() -> void:
	_ensure_built()
	setup_overlay.visible = true
	hud.visible = false
	tactical_board.visible = false
	setup_panel.player_label_inputs[0].grab_focus()


func show_live() -> void:
	_ensure_built()
	setup_overlay.visible = false
	hud.visible = true
	tactical_board.visible = true


func cache_projection(perspective_id: String, projection: Dictionary) -> bool:
	_ensure_built()
	if not perspective_id in ["omniscient", "seat_0", "seat_1"]:
		return false
	_projection_cache[perspective_id] = projection.duplicate(true)
	if perspective_id == current_perspective:
		_display_projection(_projection_cache[perspective_id])
	return true


func apply_projection(perspective_id: String, projection: Dictionary) -> bool:
	return cache_projection(perspective_id, projection)


func activate_perspective(perspective_id: String, emit_request: bool = true) -> bool:
	_ensure_built()
	if not perspective_id in ["omniscient", "seat_0", "seat_1"]:
		return false
	current_perspective = perspective_id
	if _projection_cache.has(perspective_id):
		_display_projection(_projection_cache[perspective_id])
	if emit_request:
		perspective_requested.emit(perspective_id)
	return true


func _display_projection(projection: Dictionary) -> void:
	var safe_copy := projection.duplicate(true)
	tactical_board.apply_projection(safe_copy)
	hud.apply_projection(safe_copy)


func apply_events(events: Array) -> void:
	_ensure_built()
	var safe_events: Array = events.duplicate(true)
	hud.apply_events(safe_events)


func apply_selected(selected: Dictionary) -> void:
	_ensure_built()
	hud.apply_selected(selected.duplicate(true))


func set_replay_state(replay_state: Dictionary) -> void:
	_ensure_built()
	hud.set_replay_state(replay_state.duplicate(true))


func set_official_setup_locked(locked: bool) -> void:
	_ensure_built()
	setup_panel.set_official_locked(locked)


func set_faction_integrity(content_hash: String, verified_equal: bool) -> void:
	_ensure_built()
	setup_panel.set_faction_integrity(content_hash, verified_equal)


func set_gateway_connection(slot: int, state: String, detail: String = "") -> void:
	_ensure_built()
	setup_panel.set_connection_state(slot, state, detail)


func acknowledge_launch_dispatched() -> void:
	_ensure_built()
	setup_panel.acknowledge_launch_dispatched()


func set_launch_state(state: String, detail: String = "") -> void:
	_ensure_built()
	setup_panel.set_launch_state(state, detail)


func show_launch_error(detail: String) -> void:
	_ensure_built()
	show_setup()
	setup_panel.set_launch_state("error", detail)
	for slot in 2:
		setup_panel.set_connection_state(slot, "error", detail)


func cached_projection_copy(perspective_id: String) -> Dictionary:
	if not _projection_cache.has(perspective_id):
		return {}
	return _projection_cache[perspective_id].duplicate(true)


func display_asset_status() -> Dictionary:
	_ensure_built()
	return {
		"resolved": _asset_resolver.resolved_paths(),
		"packs": _asset_resolver.recommended_pack_status(),
	}


func debug_state() -> Dictionary:
	_ensure_built()
	return {
		"surface": "setup" if setup_overlay.visible else "live",
		"perspective": current_perspective,
		"cached_perspectives": _projection_cache.keys().duplicate(),
		"event_count": hud.event_history_copy().size(),
		"protected_keys_clear": setup_panel.protected_keys_are_clear(),
	}


func _on_setup_submitted(config: Dictionary) -> void:
	setup_submitted.emit(config.duplicate(true))


func _on_launch_requested(request: Dictionary) -> void:
	## This credential-bearing dictionary is passed through without caching,
	## rendering, debug inspection, or duplication.
	launch_requested.emit(request)


func _on_perspective_requested(perspective_id: String) -> void:
	activate_perspective(perspective_id, true)


func _on_entity_focus_requested(entity_id: String) -> void:
	var projection := cached_projection_copy(current_perspective)
	for raw_entity: Variant in projection.get("entities", []):
		if raw_entity is Dictionary and str(raw_entity.get("id", raw_entity.get("entity_id", ""))) == entity_id:
			hud.apply_selected(raw_entity)
			break
	entity_focus_requested.emit(entity_id)


func _has_argument(argument: String) -> bool:
	return OS.get_cmdline_user_args().has(argument) or OS.get_cmdline_args().has(argument)


func mock_projection() -> Dictionary:
	return {
		"tick": 1240,
		"simulation_hz": 10,
		"maximum_match_ticks": 18000,
		"objective": "Destroy the opposing Stronghold",
		"day_phase": "day",
		"decision_mode": "fixed_simultaneous",
		"decision_ticks_remaining": 60,
		"map": {
			"width_mt": 192000,
			"height_mt": 128000,
			"display_lanes": [[[0.10, 0.82], [0.50, 0.50], [0.90, 0.18]]],
		},
		"players": [
			{
				"label": "Atlas Reasoner", "tier": 2, "army_value": 2280,
				"stronghold": {"hp": 2730, "max_hp": 3000},
				"resources": {"gold": 860, "lumber": 410, "food_used": 44, "food_cap": 60, "upkeep": "low"},
				"heroes": [{"name": "Marshal", "level": 3, "hp": 780, "max_hp": 920, "state": "advancing"}],
				"current_intent": "Secure the center", "response": {"state": "accepted", "latency_ms": 2210},
			},
			{
				"label": "Nova Planner", "tier": 2, "army_value": 2190,
				"stronghold": {"hp": 3000, "max_hp": 3000},
				"resources": {"gold": 740, "lumber": 525, "food_used": 41, "food_cap": 60, "upkeep": "low"},
				"heroes": [{"name": "Trail Warden", "level": 3, "hp": 620, "max_hp": 760, "state": "scouting"}],
				"current_intent": "Pressure the west lane", "response": {"state": "thinking", "latency_ms": 0},
			},
		],
		"entities": [
			{"id": "a-keep", "display_name": "Citadel", "kind": "stronghold", "player_slot": 0, "position_mt": [24000, 104000], "hp": 2730, "max_hp": 3000},
			{"id": "b-keep", "display_name": "Citadel", "kind": "stronghold", "player_slot": 1, "position_mt": [168000, 24000], "hp": 3000, "max_hp": 3000},
			{"id": "a-hero", "display_name": "Marshal", "kind": "unit", "player_slot": 0, "position_mt": [86000, 72000], "hp": 780, "max_hp": 920, "current_order": "Attack-move to center"},
			{"id": "b-hero", "display_name": "Trail Warden", "kind": "unit", "player_slot": 1, "position_mt": [108000, 56000], "hp": 620, "max_hp": 760, "current_order": "Scout western approach"},
			{"id": "stale-a", "kind": "unit", "player_slot": 1, "position_mt": [74000, 49000], "last_known": true},
		],
		"selected": {
			"id": "a-hero", "display_name": "Marshal — Level 3", "hp": 780, "max_hp": 920,
			"mana": 140, "max_mana": 250, "armor": "5 Heavy", "current_order": "Attack-move to center",
			"order_queue": ["Hold the crossing"], "abilities": ["Shield Strike", "Command Aura"], "items": ["Town Portal"],
		},
	}


func mock_events() -> Array:
	return [
		{"event_id": "mock-1", "tick": 1210, "category": "hero", "text": "Marshal reached level 3"},
		{"event_id": "mock-2", "tick": 1226, "category": "combat", "text": "Center skirmish began"},
		{"event_id": "mock-3", "tick": 1235, "category": "economy", "text": "Model B completed a Township"},
	]
