extends Node3D

## Arena v1 is a read-only presentation adapter. The authoritative simulation calls
## configure_from_snapshot(), apply_events(), set_phase(), and show_message().
## This node never derives gameplay outcomes from rendered transforms.

signal setup_submitted(config: Dictionary)
signal perspective_requested(perspective_id: String)
signal pause_requested(paused: bool)
signal playback_speed_requested(speed: float)
signal timeline_seek_requested(round_index: int)
signal event_focus_requested(event_id: String)
signal simulation_requested(config: Dictionary)
signal replay_refresh_requested
signal replay_watch_requested(replay_id: String)

const DistrictViewScript := preload("res://scripts/arena/presentation/arena_district_view.gd")
const UnitViewScript := preload("res://scripts/arena/presentation/arena_unit_view.gd")
const SpeechBubbleScript := preload("res://scripts/arena/presentation/arena_speech_bubble.gd")
const RelationshipGraphScript := preload("res://scripts/arena/presentation/relationship_graph.gd")
const ArenaPodiumScript := preload("res://scripts/arena/presentation/arena_podium.gd")
const WorkTaskViewScript := preload("res://scripts/arena/presentation/arena_work_task_view.gd")
const ConstructionViewScript := preload("res://scripts/arena/presentation/arena_construction_view.gd")
const AssetResolver := preload("res://scripts/arena/presentation/arena_asset_resolver.gd")
const ConquestMinimapScript := preload("res://scripts/arena/presentation/arena_conquest_minimap.gd")
const AmbientWildlifeScript := preload("res://scripts/arena/presentation/arena_ambient_wildlife.gd")

const GRASS_TEXTURE := "res://art/textures/grass-warcraft-v1.png"
const WATER_TEXTURE := "res://art/textures/water-warcraft-v1.png"
const DIRT_PATH_TEXTURE := "res://art/textures/dirt-path-warcraft-v1.png"
const WOOD_TEXTURE := "res://art/textures/wood-warcraft-v1.png"
const ROCK_TEXTURE := "res://art/textures/rock-warcraft-v1.png"
const ROOF_TEXTURE := "res://art/textures/roof-warcraft-v1.png"
const CRYSTAL_TEXTURE := "res://art/textures/crystal-warcraft-v1.png"
const KENNEY_PANEL_TEXTURE := "res://assets/external/kenney_ui_pack_adventure/Vector/panel_brown_dark.svg"
const KENNEY_BUTTON_TEXTURE := "res://assets/external/kenney_ui_pack_adventure/Vector/button_brown.svg"
const KENNEY_MINIMAP_RING := "res://assets/external/kenney_ui_pack_adventure/Vector/minimap_ring_brown.svg"

# The simulation still speaks in TRI-13 world coordinates.  Presentation folds
# those coordinates into a tabletop-sized island so the complete match remains
# readable at a single glance during live play and recorded demos.
const COMPACT_MAP_SCALE := 0.46
const COMPACT_RADIUS_SCALE := 0.72

const FACTION_IDS := ["sol", "terra", "luna"]
const FACTION_NAMES := {"sol": "Sol", "terra": "Terra", "luna": "Luna"}
const FACTION_COLORS := {
	"sol": Color("d25530"),
	"terra": Color("2a9a70"),
	"luna": Color("5367cf")
}
const FACTION_GLYPHS := {"sol": "△", "terra": "□", "luna": "○", "neutral": "·"}
const NEUTRAL_COLOR := Color("687884")

const DISTRICT_DEFINITIONS := [
	{"id": "core_sol", "name": "Sol Core", "kind": "core", "position": Vector3(-154, 0, 146), "radius": 28.0, "resources": []},
	{"id": "core_terra", "name": "Terra Core", "kind": "core", "position": Vector3(154, 0, 146), "radius": 28.0, "resources": []},
	{"id": "core_luna", "name": "Luna Core", "kind": "core", "position": Vector3(0, 0, -170), "radius": 28.0, "resources": []},
	{"id": "home_sol", "name": "Sol Homeland", "kind": "homeland", "position": Vector3(-108, 0, 96), "radius": 25.0, "resources": ["tree", "stone", "deer"]},
	{"id": "home_terra", "name": "Terra Homeland", "kind": "homeland", "position": Vector3(108, 0, 96), "radius": 25.0, "resources": ["tree", "stone", "deer"]},
	{"id": "home_luna", "name": "Luna Homeland", "kind": "homeland", "position": Vector3(0, 0, -112), "radius": 25.0, "resources": ["tree", "stone", "deer"]},
	{"id": "mine_st", "name": "Sunfall Mine", "kind": "mid mine", "position": Vector3(0, 0, 92), "radius": 24.0, "resources": ["iron", "stone", "deer"]},
	{"id": "mine_tl", "name": "Ember Mine", "kind": "mid mine", "position": Vector3(74, 0, -32), "radius": 24.0, "resources": ["iron", "stone", "deer"]},
	{"id": "mine_ls", "name": "Moon Mine", "kind": "mid mine", "position": Vector3(-74, 0, -32), "radius": 24.0, "resources": ["iron", "stone", "deer"]},
	{"id": "wild_st", "name": "North Wildwood", "kind": "wildwood", "position": Vector3(0, 0, 151), "radius": 23.0, "resources": ["tree", "tree", "wolf"]},
	{"id": "wild_tl", "name": "East Wildwood", "kind": "wildwood", "position": Vector3(126, 0, 5), "radius": 23.0, "resources": ["tree", "boar", "wolf"]},
	{"id": "wild_ls", "name": "West Wildwood", "kind": "wildwood", "position": Vector3(-126, 0, 5), "radius": 23.0, "resources": ["tree", "boar", "wolf"]},
	{"id": "crossroads", "name": "Crossroads", "kind": "strategic ground", "position": Vector3(0, 0, 3), "radius": 29.0, "resources": ["crystal", "iron", "boar"]}
]

const DISTRICT_LINKS := [
	["core_sol", "home_sol"], ["core_terra", "home_terra"], ["core_luna", "home_luna"],
	["home_sol", "wild_st"], ["home_sol", "wild_ls"], ["home_sol", "mine_st"], ["home_sol", "mine_ls"],
	["home_terra", "wild_st"], ["home_terra", "wild_tl"], ["home_terra", "mine_st"], ["home_terra", "mine_tl"],
	["home_luna", "wild_tl"], ["home_luna", "wild_ls"], ["home_luna", "mine_tl"], ["home_luna", "mine_ls"],
	["mine_st", "crossroads"], ["mine_tl", "crossroads"], ["mine_ls", "crossroads"],
	["wild_st", "mine_st"], ["wild_tl", "mine_tl"], ["wild_ls", "mine_ls"]
]

@export var mock_mode := true
@export var start_in_live_preview := false
@export var run_embedded_mock_on_submit := true

var camera: Camera3D
var world_root: Node3D
var districts_root: Node3D
var units_root: Node3D
var resources_root: Node3D
var links_root: Node3D
var district_views: Dictionary = {}
var district_positions: Dictionary = {}
var unit_views: Dictionary = {}
var commander_views: Dictionary = {}
var work_task_views: Dictionary = {}
var construction_views: Dictionary = {}

var ui_root: Control
var setup_overlay: Control
var setup_status_label: Label
var setup_start_button: Button
var setup_content: Control
var simulation_page: PanelContainer
var lobby_mode_buttons: Dictionary = {}
var simulation_seed_input: LineEdit
var simulation_rounds_input: SpinBox
var simulation_policy_select: OptionButton
var simulation_observation_select: OptionButton
var simulation_run_button: Button
var simulation_status_label: Label
var replay_runs_list: VBoxContainer
var api_key_input: LineEdit
var model_inputs: Dictionary = {}
var reasoning_inputs: Dictionary = {}
var advisor_inputs: Dictionary = {}
var scenario_select: OptionButton
var observation_select: OptionButton
var phase_label: Label
var round_label: Label
var timer_label: Label
var thinking_labels: Dictionary = {}
var faction_cards: Dictionary = {}
var relationship_graph: Control
var relationship_graph_toggle: Button
var diplomacy_panel: PanelContainer
var diplomacy_toggle: Button
var diplomacy_feed: VBoxContainer
var diplomacy_scroll: ScrollContainer
var diplomacy_filter: OptionButton
var selected_title: Label
var selected_intent: Label
var selected_orders: Label
var selected_advisors: Label
var perspective_select: OptionButton
var pause_button: Button
var speed_select: OptionButton
var timeline_slider: HSlider
var timeline_markers: HBoxContainer
var live_status_label: Label
var objective_label: Label
var objective_detail_label: Label
var objective_progress: ProgressBar
var bubble_layer: Control
var showcase_banner: PanelContainer
var showcase_banner_label: Label
var chapter_card: PanelContainer
var chapter_rule: ColorRect
var chapter_title_label: Label
var chapter_subtitle_label: Label
var _chapter_tween: Tween
var podium_overlay: ArenaPodium
var conquest_minimap

var current_snapshot: Dictionary = {}
var event_history: Array[Dictionary] = []
var event_ids: Dictionary = {}
var active_bubbles: Dictionary = {}
var bubble_queues: Dictionary = {}
var current_perspective := "spectator"
var selected_faction := "sol"
var current_round := 0
var max_rounds := 120
var current_phase := "setup"
var live_paused := false
var playback_speed := 1.0
var _updating_timeline := false
var _mock_sequence_id := 0
var _camera_focus := Vector3(0, 0, -4)
var _camera_distance := 184.0
var _camera_yaw := 0.0
var _camera_dragging := false
var _camera_last_mouse := Vector2.ZERO
var _camera_directed := false
var _camera_directed_tween: Tween
var _camera_directed_focus := Vector3.ZERO
var _artifact_timeline := false


func _ready() -> void:
	_build_world()
	_build_interface()
	configure_from_snapshot(_mock_snapshot())
	set_lobby_visible(not start_in_live_preview)
	if start_in_live_preview or _has_argument("--arena-live-preview"):
		call_deferred("_start_mock_demo")


func _process(_delta: float) -> void:
	_update_speech_bubbles()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: _toggle_pause()
			KEY_0: _set_perspective("spectator", true)
			KEY_1: _set_perspective("sol", true)
			KEY_2: _set_perspective("terra", true)
			KEY_3: _set_perspective("luna", true)
	# Replays own the camera during a directed shot.  Keyboard spectator controls
	# stay available, but a stray drag or scroll must not fight the shot tween.
	if _camera_directed and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_camera_dragging = event.pressed
			_camera_last_mouse = event.position
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera_distance = clampf(_camera_distance - 16.0, 150.0, 265.0)
			_update_strategy_camera()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera_distance = clampf(_camera_distance + 16.0, 150.0, 265.0)
			_update_strategy_camera()
	if event is InputEventMouseMotion and _camera_dragging:
		var delta: Vector2 = event.position - _camera_last_mouse
		_camera_last_mouse = event.position
		_camera_yaw += delta.x * 0.004
		_camera_focus += Vector3(-delta.x * 0.22, 0.0, -delta.y * 0.22)
		_camera_focus.x = clampf(_camera_focus.x, -95.0, 95.0)
		_camera_focus.z = clampf(_camera_focus.z, -120.0, 130.0)
		_update_strategy_camera()


## Apply a complete canonical or projected round snapshot. Safe to call repeatedly.
func configure_from_snapshot(snapshot: Dictionary) -> void:
	current_snapshot = snapshot.duplicate(true)
	current_round = int(snapshot.get("round", current_round))
	max_rounds = maxi(1, int(snapshot.get("max_rounds", max_rounds)))
	round_label.text = "ROUND %03d / %03d" % [current_round, max_rounds]
	timer_label.text = str(snapshot.get("sim_time", "00:00"))

	var district_states := _records_by_id(snapshot.get("districts", []))
	for district_id in district_views:
		var state: Dictionary = district_states.get(district_id, {})
		district_views[district_id].apply_state(state)
	_update_objective(snapshot)

	_apply_units(snapshot.get("units", []))
	_apply_persistent_tasks(snapshot)
	_apply_factions(snapshot.get("factions", []))
	if conquest_minimap != null:
		conquest_minimap.apply_snapshot(snapshot)
	if snapshot.has("relationships"):
		relationship_graph.set_relations(snapshot.get("relationships", []))
	set_phase(str(snapshot.get("phase", current_phase)), snapshot.get("thinking_status", {}))

	_updating_timeline = true
	timeline_slider.max_value = max_rounds
	timeline_slider.value = current_round
	_updating_timeline = false
	_refresh_selected_command()


## Apply an ordered batch of presentation events. Duplicate event IDs are ignored.
func apply_events(events: Array) -> void:
	for event_variant in events:
		if event_variant is Dictionary:
			_apply_event(event_variant)


## Update the simultaneous phase bar independently of a full snapshot.
func set_phase(phase: String, statuses: Dictionary = {}) -> void:
	current_phase = phase.to_lower()
	phase_label.text = current_phase.replace("_", " ").to_upper()
	phase_label.add_theme_color_override("font_color", _phase_color(current_phase))
	for faction_id in FACTION_IDS:
		var raw_status: Variant = statuses.get(faction_id, "waiting")
		var status := str(raw_status.get("state", "waiting")) if raw_status is Dictionary else str(raw_status)
		var status_label: Label = thinking_labels[faction_id]
		status_label.text = "%s %s  %s" % [FACTION_GLYPHS[faction_id], faction_id.to_upper(), _status_text(status)]
		status_label.add_theme_color_override("font_color", _status_color(status, FACTION_COLORS[faction_id]))
	live_status_label.text = _phase_explanation(current_phase)


## Display a message over its commander. Use apply_events() when the event should also
## enter the feed and replay timeline.
func show_message(event: Dictionary) -> void:
	if not _event_visible(event):
		return
	# The Battle Chronicle is the spectator communication surface. World bubbles
	# are reserved for faction-view context so they never cover the battlefield.
	if current_perspective == "spectator":
		return
	var actor_id := str(event.get("actor_id", ""))
	if not commander_views.has(actor_id):
		return
	if active_bubbles.has(actor_id):
		if not bubble_queues.has(actor_id):
			bubble_queues[actor_id] = []
		bubble_queues[actor_id].append(event.duplicate(true))
		return
	_create_speech_bubble(event)


func set_lobby_visible(value: bool) -> void:
	setup_overlay.visible = value
	if value:
		api_key_input.grab_focus()


func mark_setup_accepted(initial_snapshot: Dictionary = {}) -> void:
	setup_status_label.text = "Configuration accepted. Sealing round-one observations…"
	setup_status_label.add_theme_color_override("font_color", Color("9fe3d2"))
	set_lobby_visible(false)
	if not initial_snapshot.is_empty():
		configure_from_snapshot(initial_snapshot)


## A showcase replaces the controller's bootstrap snapshot with its own complete
## actor timeline. Clear only projection nodes so bootstrap actors cannot linger
## as zero-health ghosts underneath the replay.
func prepare_showcase() -> void:
	_artifact_timeline = false
	for view in unit_views.values():
		if is_instance_valid(view):
			view.queue_free()
	for view in work_task_views.values():
		if is_instance_valid(view):
			view.queue_free()
	for view in construction_views.values():
		if is_instance_valid(view):
			view.queue_free()
	unit_views.clear()
	commander_views.clear()
	work_task_views.clear()
	construction_views.clear()
	_reset_events()


## Saved artifacts use the same projection path as authored showcases, while
## remaining distinct from the fixed-duration cue player.
func prepare_artifact_replay() -> void:
	prepare_showcase()
	_artifact_timeline = true
	live_paused = false
	pause_button.text = "PAUSE"
	playback_speed = 1.0
	if speed_select != null:
		speed_select.select(1) # 1×; saved replays always begin at normal speed.
	live_status_label.text = "SAVED REPLAY · LOADING FRAME"


func set_artifact_replay_time(elapsed_seconds: float, duration_seconds: float) -> void:
	_artifact_timeline = true
	var duration := maxf(0.001, duration_seconds)
	timer_label.text = "%02d:%02d / %02d:%02d" % [int(elapsed_seconds) / 60, int(elapsed_seconds) % 60, int(duration) / 60, int(duration) % 60]
	_updating_timeline = true
	timeline_slider.min_value = 0
	timeline_slider.max_value = 1000
	timeline_slider.step = 1
	timeline_slider.value = roundi((elapsed_seconds / duration) * 1000.0)
	_updating_timeline = false


func set_simulation_job_status(status: String, detail := "", active := false) -> void:
	if simulation_status_label == null:
		return
	var normalized := status.to_upper()
	simulation_status_label.text = "%s%s" % [normalized, "  ·  " + detail if not detail.is_empty() else ""]
	simulation_status_label.add_theme_color_override("font_color", Color("ff7a70") if normalized == "FAILED" else Color("9fe3d2") if normalized == "COMPLETED" else Color("f4c95d"))
	if simulation_run_button != null:
		simulation_run_button.disabled = active
		simulation_run_button.text = "RUNNING SIMULATION…" if active else "▶  RUN SIMULATION"


func set_replay_list(replays: Array) -> void:
	if replay_runs_list == null:
		return
	for child in replay_runs_list.get_children():
		child.queue_free()
	if replays.is_empty():
		var empty := _caption("No saved runs yet. Run a headless simulation to create one.")
		replay_runs_list.add_child(empty)
		return
	for value in replays.slice(0, 6):
		if not value is Dictionary:
			continue
		var replay: Dictionary = value
		var replay_id := str(replay.get("replay_id", replay.get("id", ""))).strip_edges()
		if replay_id.is_empty():
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var state := str(replay.get("state", replay.get("status", "COMPLETED"))).to_upper()
		label.text = "%s  ·  %s  ·  %s rounds" % [replay_id, state, str(replay.get("max_rounds", replay.get("rounds", "?")))]
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override("font_color", Color("ff7a70") if state == "FAILED" else Color("9fe3d2"))
		row.add_child(label)
		var watch := Button.new()
		watch.text = "WATCH REPLAY" if state == "COMPLETED" else "DETAILS"
		watch.disabled = state != "COMPLETED"
		watch.pressed.connect(func() -> void: replay_watch_requested.emit(replay_id))
		row.add_child(watch)
		replay_runs_list.add_child(row)


func set_simulation_error(message: String) -> void:
	set_simulation_job_status("FAILED", message.substr(0, 180), false)


func _set_lobby_mode(mode: String) -> void:
	var simulation_mode := mode == "simulation" or mode == "replays"
	if simulation_page != null:
		simulation_page.visible = simulation_mode
	if setup_content != null:
		setup_content.visible = not simulation_mode
	for key in lobby_mode_buttons:
		var button: Button = lobby_mode_buttons[key]
		button.button_pressed = (key == mode)
	if mode == "replays":
		replay_refresh_requested.emit()


func set_setup_status(message: String, state := "info") -> void:
	setup_status_label.text = message
	setup_status_label.add_theme_color_override("font_color", Color("ff7a70") if state == "error" else Color("9fe3d2") if state == "success" else Color("f4c95d"))
	setup_start_button.disabled = state == "pending"


func set_perspective(perspective_id: String) -> void:
	_set_perspective(perspective_id, false)


## Show the deterministic score payload supplied by the evaluation/replay layer.
func show_match_result(result: Dictionary) -> void:
	podium_overlay.show_match_result(result)


## Cinematic, presentation-only camera control used by replay cues.  `target_id`
## may be a district ID, a faction commander ID, or "overview".  Callers can
## supply a three-number target_position for a moment that happens between named
## landmarks.  This never feeds data back into the simulation.
func focus_world(target_id := "overview", shot := "medium", duration := 1.2, target_position: Variant = null) -> void:
	if camera == null:
		return
	var requested_focus := _camera_target(str(target_id), target_position)
	# Camera cues now emphasize a front without abandoning the rest of the board.
	# This keeps every surviving character and the win condition in context.
	var focus := Vector3(requested_focus.x * 0.20, 0.7, requested_focus.z * 0.16 - 4.0)
	var shot_name := str(shot).to_lower()
	if shot_name not in ["overview", "wide", "medium", "close"]:
		shot_name = "medium"
	var duration_seconds := clampf(float(duration), 0.2, 12.0)
	var profile := _camera_shot_profile(shot_name)
	_camera_directed = true
	_camera_dragging = false
	_camera_directed_focus = focus
	if _camera_directed_tween != null and _camera_directed_tween.is_valid():
		_camera_directed_tween.kill()
	_camera_directed_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_camera_directed_tween.tween_property(camera, "position", focus + profile["offset"], duration_seconds)
	_camera_directed_tween.parallel().tween_property(camera, "fov", profile["fov"], duration_seconds)
	_camera_directed_tween.parallel().tween_method(_aim_directed_camera, 0.0, 1.0, duration_seconds)
	_camera_directed_tween.tween_callback(_finish_directed_camera.bind(focus))


func _camera_target(target_id: String, target_position: Variant) -> Vector3:
	if target_position is Vector3:
		return target_position
	if target_position is Array and target_position.size() == 3:
		return Vector3(float(target_position[0]), float(target_position[1]), float(target_position[2])) * COMPACT_MAP_SCALE
	if target_position is Dictionary:
		return Vector3(float(target_position.get("x", 0.0)), float(target_position.get("y", 0.0)), float(target_position.get("z", 0.0))) * COMPACT_MAP_SCALE
	if target_id != "overview":
		# Cues address actor IDs such as `sol_commander`, while the speech-bubble
		# lookup below is keyed by faction.  Prefer a concrete body for close shots.
		if unit_views.has(target_id) and is_instance_valid(unit_views[target_id]):
			return unit_views[target_id].global_position + Vector3(0, 1.2, 0)
		if commander_views.has(target_id) and is_instance_valid(commander_views[target_id]):
			return commander_views[target_id].global_position + Vector3(0, 1.0, 0)
		if district_positions.has(target_id):
			return district_positions[target_id] + Vector3(0, 0.6, 0)
	return Vector3(0, 0.7, -4)


func _camera_shot_profile(shot_name: String) -> Dictionary:
	match shot_name:
		"close":
			return {"offset": Vector3(0, 98, 132), "fov": 47.0}
		"medium":
			return {"offset": Vector3(0, 108, 146), "fov": 48.0}
		"wide":
			return {"offset": Vector3(0, 116, 158), "fov": 49.0}
		_:
			return {"offset": Vector3(0, 122, 166), "fov": 49.0}


func _aim_directed_camera(_progress: float) -> void:
	if camera != null:
		camera.look_at(_camera_directed_focus, Vector3.UP)


func _finish_directed_camera(focus: Vector3) -> void:
	_camera_directed = false
	_camera_focus = focus
	var relative := camera.position - focus
	_camera_distance = clampf(relative.length(), 150.0, 265.0)
	_camera_yaw = atan2(relative.x / 0.48, relative.z / 0.80)


## Persistent replay provenance banner. A mismatched hash is deliberately loud.
func set_showcase_status(verified: bool, label: String, detail: String) -> void:
	showcase_banner.visible = true
	showcase_banner.add_theme_stylebox_override(
		"panel",
		_panel_style(
			Color(0.018, 0.06, 0.055, 0.98) if verified else Color(0.09, 0.052, 0.026, 0.98),
			Color("69f0d0") if verified else Color("ffb35c"),
			10,
			8
		)
	)
	showcase_banner_label.text = "%s  ·  %s" % [label, detail]
	showcase_banner_label.add_theme_color_override("font_color", Color("9fe3d2") if verified else Color("ffd0a0"))
	# A showcase is authored playback, not an inactive lobby.  Keep this small
	# status truthful while avoiding an initial wall of "waiting" labels.
	if live_status_label != null and current_phase == "setup":
		live_status_label.text = "SHOWCASE REPLAY · AGENTS ACT IN PARALLEL"


func _build_world() -> void:
	world_root = Node3D.new()
	world_root.name = "ArenaPresentationWorld"
	add_child(world_root)
	links_root = Node3D.new()
	links_root.name = "DistrictGraph"
	world_root.add_child(links_root)
	districts_root = Node3D.new()
	districts_root.name = "Districts"
	world_root.add_child(districts_root)
	resources_root = Node3D.new()
	resources_root.name = "ResourcesAndWildlife"
	world_root.add_child(resources_root)
	units_root = Node3D.new()
	units_root.name = "Units"
	world_root.add_child(units_root)

	_build_environment()
	_build_triangle_ground()
	_build_ambient_landscape()
	_build_landmarks()
	for definition in DISTRICT_DEFINITIONS:
		var compact_definition: Dictionary = definition.duplicate(true)
		var compact_position: Vector3 = definition.position
		compact_definition.position = compact_position * COMPACT_MAP_SCALE
		compact_definition.radius = float(definition.radius) * COMPACT_RADIUS_SCALE
		var district = DistrictViewScript.new()
		district.name = str(definition.id)
		district.setup(compact_definition, FACTION_COLORS, FACTION_GLYPHS)
		districts_root.add_child(district)
		district_views[definition.id] = district
		district_positions[definition.id] = compact_definition.position
		_build_district_resources(compact_definition)
		if str(definition.kind) == "core":
			_build_core_structure(compact_definition)
		elif str(definition.kind) == "homeland":
			_build_settlement_structure(compact_definition)
		elif str(definition.kind) == "mid mine":
			_build_mine_structure(compact_definition)
	_build_graph_lines()

	camera = Camera3D.new()
	camera.name = "StrategyCamera"
	camera.fov = 52.0
	camera.current = true
	add_child(camera)
	_update_strategy_camera()


func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	# A darker atmosphere prevents the sea and sky from visually merging into a
	# single cyan board.
	sky_material.sky_top_color = Color("102a45")
	sky_material.sky_horizon_color = Color("6f9bb2")
	sky_material.ground_bottom_color = Color("071622")
	sky_material.ground_horizon_color = Color("1b3f54")
	sky_material.sun_angle_max = 22.0
	sky.sky_material = sky_material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("91b7a5")
	environment.ambient_light_energy = 0.68
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.08
	environment.glow_enabled = true
	environment.glow_intensity = 0.34
	# Distance fog gives the island a horizon without the cost of volumetric fog,
	# which keeps the presentation compatible with older Apple GPUs.
	environment.fog_enabled = true
	environment.fog_light_color = Color("54788a")
	environment.fog_light_energy = 0.35
	environment.fog_density = 0.00135
	environment.fog_sky_affect = 0.38
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -25, 0)
	sun.light_color = Color("fff0c8")
	sun.light_energy = 1.18
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 280.0
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 150, 0)
	fill.light_color = Color("76b8c5")
	fill.light_energy = 0.42
	add_child(fill)


func _build_triangle_ground() -> void:
	# A single low-poly island reads as terrain at game distance while remaining cheap
	# enough for the compatibility renderer.  The old single triangle made the map
	# look like a debug diagram.
	var water := MeshInstance3D.new()
	var water_mesh := PlaneMesh.new()
	water_mesh.size = Vector2(430, 430)
	water.mesh = water_mesh
	water.position.y = -2.5
	var water_material := _material(Color("b9d8e0"))
	water_material.albedo_texture = load(WATER_TEXTURE)
	water_material.texture_repeat = true
	water_material.uv1_scale = Vector3(9.0, 9.0, 9.0)
	# PlaneMesh and custom terrain need two-sided faces in the compatibility
	# renderer; otherwise the overview back-face culls the whole island.
	water_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	water_material.metallic = 0.16
	water_material.roughness = 0.31
	water_material.emission_enabled = true
	water_material.emission = Color("08283e")
	water_material.emission_energy_multiplier = 0.08
	water.material_override = water_material
	world_root.add_child(water)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	const GRID := 48
	const HALF := 152.0
	var cosmetic_noise := FastNoiseLite.new()
	cosmetic_noise.seed = 2407
	cosmetic_noise.frequency = 0.021
	cosmetic_noise.fractal_octaves = 3
	cosmetic_noise.fractal_gain = 0.48
	for z_index in range(GRID + 1):
		for x_index in range(GRID + 1):
			var x := lerpf(-HALF, HALF, float(x_index) / GRID)
			var z := lerpf(-HALF, HALF, float(z_index) / GRID)
			# An irregular coastline avoids the old rectangular board silhouette.
			var angle := atan2(z + 12.0, x)
			var shoreline := 0.78 + sin(angle * 3.0) * 0.055 + cos(angle * 5.0) * 0.035
			var edge := Vector2(x / HALF, (z + 7.0) / HALF).length()
			var coast := clampf((edge - shoreline) / 0.20, 0.0, 1.0)
			var height := -0.12 + cosmetic_noise.get_noise_2d(x, z) * 0.72 + sin((x - z) * 0.025) * 0.12
			height -= coast * 4.0
			vertices.append(Vector3(x, height, z))
			normals.append(Vector3.UP)
			uvs.append(Vector2(x / 42.0, z / 42.0))
	for z_index in range(GRID):
		for x_index in range(GRID):
			var a := z_index * (GRID + 1) + x_index
			# Godot uses clockwise front faces. This keeps the central landmass visible
			# from the strategy camera rather than showing only sea between roads.
			indices.append_array(PackedInt32Array([a, a + 1, a + GRID + 1, a + 1, a + GRID + 2, a + GRID + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var terrain_mesh := ArrayMesh.new()
	terrain_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var terrain := MeshInstance3D.new()
	terrain.name = "OpenWorldIslandTerrain"
	terrain.mesh = terrain_mesh
	var terrain_material := _material(Color("d9e6bf"))
	terrain_material.albedo_texture = load(GRASS_TEXTURE)
	terrain_material.texture_repeat = true
	terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	terrain_material.roughness = 0.95
	terrain.material_override = terrain_material
	world_root.add_child(terrain)
	_attach_optional_terrain3d_hook()
	# A handful of broad ground patches break up the grass without textures.
	for patch_data in [[Vector3(-118, 0.30, 75), Vector2(42, 28), Color("3d7144")], [Vector3(105, 0.30, 48), Vector2(48, 28), Color("58713f")], [Vector3(0, 0.30, -66), Vector2(58, 30), Color("357154")]]:
		var patch := MeshInstance3D.new()
		var patch_mesh := PlaneMesh.new()
		patch_mesh.size = patch_data[1]
		patch.mesh = patch_mesh
		patch.position = patch_data[0]
		patch.rotation.y = deg_to_rad(18.0)
		var patch_material := _material(patch_data[2])
		patch_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		patch.material_override = patch_material
		world_root.add_child(patch)


func _attach_optional_terrain3d_hook() -> void:
	# Terrain3D is never required for the deterministic compact mesh. If the
	# addon is active, retain a hidden cosmetic hook for later reviewed terrain
	# data rather than constructing or mutating terrain from replay state.
	if not ClassDB.class_exists(&"Terrain3D"):
		return
	var terrain_hook := Node3D.new()
	terrain_hook.name = "OptionalTerrain3DArtHook"
	terrain_hook.visible = false
	terrain_hook.set_meta("terrain3d_class_available", true)
	terrain_hook.set_meta("cosmetic_only", true)
	world_root.add_child(terrain_hook)


func _build_graph_lines() -> void:
	# These links are physical trails now, not a topology overlay.
	for link in DISTRICT_LINKS:
		var start: Vector3 = district_positions[link[0]] + Vector3(0, 0.35, 0)
		var finish: Vector3 = district_positions[link[1]] + Vector3(0, 0.35, 0)
		_build_road_segment(start, finish)


func _build_road_segment(start: Vector3, finish: Vector3) -> void:
	var direction := finish - start
	var length := direction.length()
	var road := MeshInstance3D.new()
	var road_mesh := BoxMesh.new()
	road_mesh.size = Vector3(3.6, 0.10, length)
	road.mesh = road_mesh
	road.position = (start + finish) * 0.5 + Vector3(0, 0.36, 0)
	road.rotation.y = atan2(direction.x, direction.z)
	road.material_override = _material(Color("e2c99b"))
	(road.material_override as StandardMaterial3D).albedo_texture = load(DIRT_PATH_TEXTURE)
	(road.material_override as StandardMaterial3D).texture_repeat = true
	links_root.add_child(road)


func _build_ambient_landscape() -> void:
	# Landmark resources live near districts; these background groves fill the
	# travel space so a cinematic sweep reads as an island rather than a graph.
	var groves := [
		Vector3(-183, 0, 96), Vector3(-160, 0, -62), Vector3(-104, 0, -150),
		Vector3(-34, 0, 154), Vector3(42, 0, 145), Vector3(156, 0, 98),
		Vector3(182, 0, -45), Vector3(118, 0, -138), Vector3(26, 0, -174),
		Vector3(-48, 0, -78), Vector3(54, 0, 58)
	]
	for grove_index in range(groves.size()):
		var center: Vector3 = groves[grove_index] * COMPACT_MAP_SCALE
		for tree_index in range(13):
			var seed := float(grove_index * 37 + tree_index * 13)
			var spread := 6.0 + float(tree_index) * 1.45
			var at := center + Vector3(sin(seed * 0.73) * spread, 0, cos(seed * 1.17) * spread)
			_create_resource_marker("tree", at, seed)
		if grove_index % 2 == 0:
			_create_resource_marker("stone", center + Vector3(11, 0, -7), float(grove_index) * 17.0)
		if grove_index in [1, 5, 8]:
			var wildlife := AmbientWildlifeScript.new()
			wildlife.name = "AmbientWildlife_%d" % grove_index
			wildlife.setup(center + Vector3(4, 0, -3), grove_index * 31)
			resources_root.add_child(wildlife)


func _build_landmarks() -> void:
	# Distant rocky ridges and mine mouths give the island a readable horizon and
	# make the map feel authored rather than a flat graph of districts.
	var landmark_data := [
		[Vector3(-176, 0, 126), 1.15, 11.0],
		[Vector3(-28, 0, 174), 1.35, 29.0],
		[Vector3(158, 0, 112), 1.05, 47.0],
		[Vector3(176, 0, -72), 1.22, 61.0],
		[Vector3(-154, 0, -116), 0.92, 83.0],
		[Vector3(28, 0, -156), 1.08, 101.0]
	]
	for data in landmark_data:
		_create_mountain_cluster(data[0] * COMPACT_MAP_SCALE, float(data[1]) * 0.82, float(data[2]))


func _create_mountain_cluster(center: Vector3, size_factor: float, seed: float) -> void:
	var ridge := Node3D.new()
	ridge.name = "MountainRidge"
	ridge.position = center
	resources_root.add_child(ridge)
	for rock_index in range(7):
		var rock := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		var rock_size := (2.6 + fmod(seed + rock_index * 1.7, 2.8)) * size_factor
		mesh.radius = rock_size
		mesh.height = rock_size * (1.25 + fmod(seed * 0.07 + rock_index, 0.45))
		mesh.radial_segments = 7
		mesh.rings = 3
		rock.mesh = mesh
		var angle := seed * 0.11 + float(rock_index) * 0.88
		var distance := float(rock_index % 3) * 4.0 + fmod(seed + rock_index, 3.0)
		rock.position = Vector3(cos(angle) * distance, rock_size * 0.72, sin(angle) * distance)
		rock.scale = Vector3(1.0 + fmod(rock_index, 2.0) * 0.22, 1.0, 0.78 + fmod(seed, 0.24))
		rock.rotation_degrees = Vector3(fmod(seed * 2.0 + rock_index * 13.0, 20.0), fmod(seed * 3.0 + rock_index * 31.0, 360.0), fmod(seed + rock_index * 9.0, 14.0))
		rock.material_override = _material(Color("d8d2c9").lightened(fmod(seed + rock_index, 0.08)))
		(rock.material_override as StandardMaterial3D).albedo_texture = load(ROCK_TEXTURE)
		ridge.add_child(rock)
	# A dark mine mouth makes the landmark useful, not merely decorative.
	var mouth := MeshInstance3D.new()
	var mouth_mesh := CylinderMesh.new()
	mouth_mesh.top_radius = 1.8 * size_factor
	mouth_mesh.bottom_radius = 2.8 * size_factor
	mouth_mesh.height = 4.0 * size_factor
	mouth_mesh.radial_segments = 10
	mouth.mesh = mouth_mesh
	mouth.scale = Vector3(1.0, 1.0, 0.45)
	mouth.position = Vector3(0, 2.1 * size_factor, 3.3 * size_factor)
	mouth.material_override = _material(Color("101a20"), true)
	ridge.add_child(mouth)


func _update_strategy_camera() -> void:
	if camera == null:
		return
	# Warcraft-like tactical angle: enough horizon and parallax to feel like a place,
	# while preserving the full three-front battlefield in a single demo view.
	var orbit := Vector3(sin(_camera_yaw) * _camera_distance * 0.52, _camera_distance * 0.48, cos(_camera_yaw) * _camera_distance * 0.77)
	camera.position = _camera_focus + orbit
	camera.look_at(_camera_focus + Vector3(0, 0.6, 0), Vector3.UP)


func _build_core_structure(definition: Dictionary) -> void:
	var faction_id := str(definition.id).trim_prefix("core_")
	var core := Node3D.new()
	core.name = "%sCoreStructure" % faction_id.capitalize()
	core.position = definition.position
	resources_root.add_child(core)
	var imported_keep := AssetResolver.instantiate_structure("keep")
	if imported_keep != null:
		_add_imported_structure_pad(core, 8.2, FACTION_COLORS[faction_id].darkened(0.48))
		core.add_child(imported_keep)
		imported_keep.scale = Vector3.ONE * 1.6
		return
	var base := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 6.2
	base_mesh.bottom_radius = 7.5
	base_mesh.height = 3.2
	base.mesh = base_mesh
	base.position.y = 1.6
	base.material_override = _material(FACTION_COLORS[faction_id].darkened(0.28))
	core.add_child(base)
	var tower := MeshInstance3D.new()
	var tower_mesh := BoxMesh.new()
	tower_mesh.size = Vector3(3.8, 6.5, 3.8)
	tower.mesh = tower_mesh
	tower.position.y = 5.7
	tower.material_override = _material(FACTION_COLORS[faction_id], true)
	core.add_child(tower)
	var roof := MeshInstance3D.new()
	var roof_mesh := CylinderMesh.new()
	roof_mesh.top_radius = 0.3
	roof_mesh.bottom_radius = 3.0
	roof_mesh.height = 2.2
	roof_mesh.radial_segments = 4
	roof.mesh = roof_mesh
	roof.position.y = 9.4
	roof.rotation_degrees.y = 45.0
	roof.material_override = _material(Color("29333b"))
	(roof.material_override as StandardMaterial3D).albedo_texture = load(ROOF_TEXTURE)
	core.add_child(roof)
	# A trio of huts gives each faction a legible base silhouette instead of a
	# lone coloured token.
	for index in range(3):
		var hut := MeshInstance3D.new()
		var hut_mesh := BoxMesh.new()
		hut_mesh.size = Vector3(2.8, 1.9, 2.6)
		hut.mesh = hut_mesh
		var angle := float(index) * TAU / 3.0 + 0.35
		hut.position = Vector3(cos(angle) * 9.2, 0.95, sin(angle) * 9.2)
		hut.rotation.y = -angle
		hut.material_override = _material(FACTION_COLORS[faction_id].darkened(0.42))
		core.add_child(hut)
	# Small palisade posts and corner towers make each core read as a lived-in
	# settlement when the camera cuts in, echoing the reference's fortified camps.
	for post_index in range(10):
		var post := MeshInstance3D.new()
		var post_mesh := CylinderMesh.new()
		post_mesh.top_radius = 0.16
		post_mesh.bottom_radius = 0.25
		post_mesh.height = 2.5
		post_mesh.radial_segments = 6
		post.mesh = post_mesh
		var post_angle := float(post_index) * TAU / 10.0
		post.position = Vector3(cos(post_angle) * 12.6, 1.25, sin(post_angle) * 12.6)
		post.material_override = _material(Color("765238").lightened(fmod(float(post_index), 0.14)))
		(post.material_override as StandardMaterial3D).albedo_texture = load(WOOD_TEXTURE)
		core.add_child(post)


func _build_settlement_structure(definition: Dictionary) -> void:
	## Homeland camps mirror the reference image's three readable fortified bases.
	var definition_id := str(definition.id)
	var faction_id := definition_id.get_slice("_", 1)
	if not FACTION_COLORS.has(faction_id):
		return
	var camp := Node3D.new()
	camp.name = "%sSettlement" % faction_id.capitalize()
	camp.position = definition.position
	resources_root.add_child(camp)
	var imported_settlement := AssetResolver.instantiate_structure("settlement")
	if imported_settlement != null:
		_add_imported_structure_pad(camp, 13.5, FACTION_COLORS[faction_id].darkened(0.55))
		camp.add_child(imported_settlement)
		imported_settlement.scale = Vector3.ONE * 1.4
		return
	var floor := MeshInstance3D.new()
	var floor_mesh := CylinderMesh.new()
	floor_mesh.top_radius = 16.0
	floor_mesh.bottom_radius = 18.0
	floor_mesh.height = 0.65
	floor_mesh.radial_segments = 12
	floor.mesh = floor_mesh
	floor.position.y = 0.35
	floor.material_override = _material(FACTION_COLORS[faction_id].darkened(0.55))
	camp.add_child(floor)
	for house_index in range(4):
		var house := Node3D.new()
		var angle := float(house_index) * TAU / 4.0 + 0.35
		house.position = Vector3(cos(angle) * 8.0, 0.0, sin(angle) * 8.0)
		camp.add_child(house)
		var body := MeshInstance3D.new()
		var body_mesh := BoxMesh.new()
		body_mesh.size = Vector3(4.6, 2.8, 4.0)
		body.mesh = body_mesh
		body.position.y = 1.75
		body.material_override = _material(FACTION_COLORS[faction_id].darkened(0.35))
		house.add_child(body)
		var roof := MeshInstance3D.new()
		var roof_mesh := CylinderMesh.new()
		roof_mesh.top_radius = 0.1
		roof_mesh.bottom_radius = 3.4
		roof_mesh.height = 2.2
		roof_mesh.radial_segments = 4
		roof.mesh = roof_mesh
		roof.position.y = 4.25
		roof.rotation_degrees.y = 45.0
		roof.material_override = _material(FACTION_COLORS[faction_id].lightened(0.08), true)
		(roof.material_override as StandardMaterial3D).albedo_texture = load(ROOF_TEXTURE)
		house.add_child(roof)
	for post_index in range(16):
		var post := MeshInstance3D.new()
		var post_mesh := CylinderMesh.new()
		post_mesh.top_radius = 0.18
		post_mesh.bottom_radius = 0.30
		post_mesh.height = 3.0
		post_mesh.radial_segments = 6
		post.mesh = post_mesh
		var post_angle := float(post_index) * TAU / 16.0
		post.position = Vector3(cos(post_angle) * 17.0, 1.5, sin(post_angle) * 17.0)
		post.material_override = _material(Color("835a38"))
		(post.material_override as StandardMaterial3D).albedo_texture = load(WOOD_TEXTURE)
		camp.add_child(post)
	var camp_label := Label3D.new()
	camp_label.text = "%s CAMP" % faction_id.to_upper()
	camp_label.font_size = 15
	camp_label.outline_size = 5
	camp_label.modulate = FACTION_COLORS[faction_id].lightened(0.25)
	camp_label.position.y = 9.0
	camp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	camp_label.pixel_size = 0.018
	camp.add_child(camp_label)


func _build_mine_structure(definition: Dictionary) -> void:
	## Mine entrances and ore carts give the resource districts an immediate purpose.
	var mine := Node3D.new()
	mine.name = "%sMineEntrance" % str(definition.id)
	mine.position = definition.position + Vector3(0, 0.15, 6.0)
	resources_root.add_child(mine)
	var imported_mine := AssetResolver.instantiate_structure("mine")
	if imported_mine != null:
		_add_imported_structure_pad(mine, 6.2, Color("394747"))
		mine.add_child(imported_mine)
		imported_mine.scale = Vector3.ONE * 1.8
		return
	var arch := MeshInstance3D.new()
	var arch_mesh := CylinderMesh.new()
	arch_mesh.top_radius = 4.0
	arch_mesh.bottom_radius = 5.0
	arch_mesh.height = 5.5
	arch_mesh.radial_segments = 10
	arch.mesh = arch_mesh
	arch.scale = Vector3(1.0, 1.0, 0.42)
	arch.position.y = 2.75
	arch.material_override = _material(Color("5b6667"))
	mine.add_child(arch)
	var mouth := MeshInstance3D.new()
	var mouth_mesh := CylinderMesh.new()
	mouth_mesh.top_radius = 2.3
	mouth_mesh.bottom_radius = 2.8
	mouth_mesh.height = 4.1
	mouth_mesh.radial_segments = 10
	mouth.mesh = mouth_mesh
	mouth.scale = Vector3(1.0, 1.0, 0.36)
	mouth.position = Vector3(0, 2.05, -0.35)
	mouth.material_override = _material(Color("11181b"), true)
	mine.add_child(mouth)
	for rail_side in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var rail_mesh := BoxMesh.new()
		rail_mesh.size = Vector3(0.14, 0.12, 10.0)
		rail.mesh = rail_mesh
		rail.position = Vector3(rail_side * 1.15, 0.25, -4.0)
		rail.material_override = _material(Color("9b7347"))
		mine.add_child(rail)
	var mine_label := Label3D.new()
	mine_label.text = str(definition.get("name", "MINE")).to_upper()
	mine_label.font_size = 13
	mine_label.outline_size = 4
	mine_label.modulate = Color("ffd18c")
	mine_label.position = Vector3(0, 7.2, 0)
	mine_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mine_label.pixel_size = 0.016
	mine.add_child(mine_label)


func _add_imported_structure_pad(parent: Node3D, radius: float, color: Color) -> void:
	var pad := MeshInstance3D.new()
	var pad_mesh := CylinderMesh.new()
	pad_mesh.top_radius = radius * 0.92
	pad_mesh.bottom_radius = radius
	pad_mesh.height = 0.65
	pad_mesh.radial_segments = 14
	pad.mesh = pad_mesh
	pad.position.y = 0.32
	pad.material_override = _material(color)
	parent.add_child(pad)


func _build_district_resources(definition: Dictionary) -> void:
	var resources: Array = definition.get("resources", [])
	var offsets := [Vector3(-11, 0, -8), Vector3(10, 0, -8), Vector3(2, 0, 10)]
	for index in range(resources.size()):
		var kind := str(resources[index])
		var count := 7 if kind == "tree" else 5 if kind in ["stone", "iron"] else 4
		for cluster_index in range(count):
			var seed := float(index * 19 + cluster_index * 11 + definition.id.length() * 7)
			var scatter := Vector3(sin(seed) * (4.5 + cluster_index * 0.8), 0, cos(seed * 1.71) * (4.5 + cluster_index * 0.7))
			_create_resource_marker(kind, definition.position + offsets[index % offsets.size()] + scatter, seed)


func _create_resource_marker(kind: String, at: Vector3, seed := 0.0) -> void:
	var marker := Node3D.new()
	marker.name = "%sMarker" % kind.capitalize()
	marker.position = at
	resources_root.add_child(marker)
	var body := MeshInstance3D.new()
	var color := Color("7f9195")
	match kind:
		"tree":
			var mesh := CylinderMesh.new()
			mesh.top_radius = 0.18
			mesh.bottom_radius = 0.35
			mesh.height = 3.0
			body.mesh = mesh
			color = Color("63442b")
		"stone":
			var mesh := BoxMesh.new()
			mesh.size = Vector3(4.5, 3.0, 3.8)
			body.mesh = mesh
			body.rotation_degrees = Vector3(8, 24, 12)
			color = Color("7e8d91")
		"iron":
			var mesh := CylinderMesh.new()
			mesh.top_radius = 2.5
			mesh.bottom_radius = 3.5
			mesh.height = 2.8
			body.mesh = mesh
			color = Color("a85c3c")
		"crystal":
			var mesh := BoxMesh.new()
			mesh.size = Vector3(2.8, 7.0, 2.8)
			body.mesh = mesh
			body.rotation_degrees = Vector3(0, 34, 18)
			color = Color("58e1d2")
		"deer":
			var mesh := CapsuleMesh.new()
			mesh.radius = 0.85
			mesh.height = 2.6
			body.mesh = mesh
			body.rotation_degrees.z = 90
			color = Color("bc9669")
		"boar":
			var mesh := CapsuleMesh.new()
			mesh.radius = 1.1
			mesh.height = 3.1
			body.mesh = mesh
			body.rotation_degrees.z = 90
			color = Color("8d654f")
		"wolf":
			var mesh := CapsuleMesh.new()
			mesh.radius = 0.75
			mesh.height = 3.0
			body.mesh = mesh
			body.rotation_degrees.z = 90
			color = Color("9aa5ab")
		_:
			var mesh := BoxMesh.new()
			mesh.size = Vector3.ONE * 2.0
			body.mesh = mesh
	body.position.y = 1.5 if kind == "tree" else 3.4 if kind == "crystal" else 1.7
	marker.rotation.y = seed * 0.61
	body.material_override = _material(color, kind == "crystal")
	if kind == "crystal":
		(body.material_override as StandardMaterial3D).albedo_texture = load(CRYSTAL_TEXTURE)
	elif kind in ["stone", "iron"]:
		(body.material_override as StandardMaterial3D).albedo_texture = load(ROCK_TEXTURE)
	elif kind in ["deer", "boar", "wolf"]:
		(body.material_override as StandardMaterial3D).albedo_texture = load(WOOD_TEXTURE)
	marker.add_child(body)
	if kind == "tree":
		# Layered low-poly cones read as pines from the strategy camera and give
		# forests the silhouette of the reference showcase instead of round blobs.
		var lower_canopy := MeshInstance3D.new()
		var lower_mesh := CylinderMesh.new()
		lower_mesh.top_radius = 0.45
		lower_mesh.bottom_radius = 2.45 + fmod(seed, 0.7)
		lower_mesh.height = 3.35
		lower_mesh.radial_segments = 8
		lower_canopy.mesh = lower_mesh
		lower_canopy.position.y = 3.55
		lower_canopy.material_override = _material(Color("1b5134").lightened(fmod(seed, 0.2)))
		marker.add_child(lower_canopy)
		var upper_canopy := MeshInstance3D.new()
		var upper_mesh := CylinderMesh.new()
		upper_mesh.top_radius = 0.12
		upper_mesh.bottom_radius = 1.75 + fmod(seed * 0.7, 0.45)
		upper_mesh.height = 2.8
		upper_mesh.radial_segments = 8
		upper_canopy.mesh = upper_mesh
		upper_canopy.position.y = 5.55
		upper_canopy.material_override = _material(Color("2b6a3c").lightened(fmod(seed * 0.3, 0.18)))
		marker.add_child(upper_canopy)
	# Resource silhouettes communicate their type without a persistent wall of text.
	# Crystal remains labelled because it is the rare contested objective.
	if kind == "crystal":
		var label := Label3D.new()
		label.text = "CRYSTAL"
		label.font_size = 13
		label.outline_size = 3
		label.modulate = color.lightened(0.3)
		label.position.y = 7.0
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = false
		label.pixel_size = 0.017
		marker.add_child(label)


func _build_interface() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "ArenaHUD"
	add_child(canvas)
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(ui_root)

	bubble_layer = Control.new()
	bubble_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bubble_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(bubble_layer)

	_build_top_bar()
	_build_showcase_banner()
	_build_chapter_card()
	_build_faction_panel()
	_build_diplomacy_panel()
	_build_command_and_replay_panel()
	_build_conquest_minimap()
	_build_setup_lobby()
	_build_podium()


func _build_showcase_banner() -> void:
	showcase_banner = PanelContainer.new()
	showcase_banner.name = "ShowcaseVerificationBanner"
	showcase_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	showcase_banner.offset_left = -360
	showcase_banner.offset_top = 78
	showcase_banner.offset_right = 360
	showcase_banner.offset_bottom = 116
	showcase_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	showcase_banner.add_theme_stylebox_override("panel", _panel_style(Color(0.09, 0.052, 0.026, 0.98), Color("ffb35c"), 10, 8))
	ui_root.add_child(showcase_banner)
	showcase_banner_label = Label.new()
	showcase_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	showcase_banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	showcase_banner_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	showcase_banner_label.add_theme_font_size_override("font_size", 11)
	showcase_banner_label.add_theme_color_override("font_color", Color("ffd0a0"))
	showcase_banner.add_child(showcase_banner_label)
	showcase_banner.visible = false


## A compact authored-replay identifier.  It deliberately avoids full-screen text:
## the map and moving agents remain the visual subject of every chapter.
func _build_chapter_card() -> void:
	chapter_card = PanelContainer.new()
	chapter_card.name = "CinematicChapterCard"
	chapter_card.set_anchors_preset(Control.PRESET_CENTER_TOP)
	chapter_card.offset_left = -246
	# Sit below the persistent replay provenance banner so the demo remains
	# readable when both are visible during a chapter transition.
	chapter_card.offset_top = 122
	chapter_card.offset_right = 246
	chapter_card.offset_bottom = 188
	chapter_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chapter_card.add_theme_stylebox_override("panel", _panel_style(Color(0.014, 0.035, 0.052, 0.88), Color("55717b"), 9, 7))
	ui_root.add_child(chapter_card)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 1)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chapter_card.add_child(content)
	chapter_rule = ColorRect.new()
	chapter_rule.custom_minimum_size = Vector2(0, 2)
	chapter_rule.color = Color("9caeb4")
	content.add_child(chapter_rule)
	chapter_title_label = Label.new()
	chapter_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chapter_title_label.add_theme_font_size_override("font_size", 17)
	chapter_title_label.add_theme_color_override("font_color", Color("f6f0d7"))
	chapter_title_label.add_theme_constant_override("outline_size", 1)
	chapter_title_label.add_theme_color_override("font_outline_color", Color("061219"))
	content.add_child(chapter_title_label)
	chapter_subtitle_label = Label.new()
	chapter_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chapter_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chapter_subtitle_label.add_theme_font_size_override("font_size", 11)
	chapter_subtitle_label.add_theme_color_override("font_color", Color("b8c8cb"))
	content.add_child(chapter_subtitle_label)
	chapter_card.visible = false


## Replay-only narration.  The game state is never read or changed here.
func show_chapter(title: String, subtitle := "", duration := 3.0, accent := "neutral") -> void:
	if chapter_card == null:
		return
	var accent_color := _chapter_accent_color(accent)
	chapter_rule.color = accent_color
	chapter_card.add_theme_stylebox_override("panel", _panel_style(Color(0.014, 0.035, 0.052, 0.90), accent_color.darkened(0.18), 9, 7))
	chapter_title_label.text = title.strip_edges().to_upper()
	chapter_subtitle_label.text = subtitle.strip_edges()
	chapter_subtitle_label.visible = not chapter_subtitle_label.text.is_empty()
	chapter_card.visible = true
	chapter_card.modulate = Color(1, 1, 1, 0)
	if _chapter_tween != null and _chapter_tween.is_valid():
		_chapter_tween.kill()
	var hold := maxf(0.35, clampf(float(duration), 1.5, 6.0) - 0.55)
	_chapter_tween = create_tween()
	_chapter_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_chapter_tween.tween_property(chapter_card, "modulate:a", 1.0, 0.22)
	_chapter_tween.tween_interval(hold)
	_chapter_tween.set_ease(Tween.EASE_IN)
	_chapter_tween.tween_property(chapter_card, "modulate:a", 0.0, 0.33)
	_chapter_tween.tween_callback(func() -> void:
		if chapter_card != null:
			chapter_card.visible = false
	)


func _chapter_accent_color(accent: String) -> Color:
	var normalized := accent.to_lower()
	if FACTION_COLORS.has(normalized):
		return FACTION_COLORS[normalized]
	return Color("9caeb4")


## A quiet world-space punctuation mark for scripted highlights.  This is a transient
## mesh only; effects neither read nor alter the simulation snapshot.
func show_effect(effect_name: String, target_id := "", duration := 1.1, target_position: Variant = null) -> void:
	if world_root == null:
		return
	var point := _camera_target(str(target_id), target_position)
	var normalized_effect := effect_name.to_lower()
	var color := _effect_color(normalized_effect)
	var burst := Node3D.new()
	burst.name = "ReplayBurst_%s" % normalized_effect
	burst.position = point + Vector3(0, 0.22, 0)
	world_root.add_child(burst)
	var pulse := MeshInstance3D.new()
	pulse.name = "ReplayEffect_%s" % normalized_effect
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.10
	disc.radial_segments = 24
	pulse.mesh = disc
	pulse.position = Vector3.ZERO
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, 0.72)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.25
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	pulse.material_override = material
	burst.add_child(pulse)
	var safe_duration := clampf(float(duration), 0.4, 4.0)
	var final_scale := 5.2 if normalized_effect == "combat" else 4.2
	var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(pulse, "scale", Vector3(final_scale, 1.0, final_scale), safe_duration)
	tween.parallel().tween_property(material, "albedo_color:a", 0.0, safe_duration)
	_build_effect_motif(burst, normalized_effect, color, safe_duration)
	_show_world_action_label(normalized_effect, point, color, safe_duration)
	tween.tween_callback(burst.queue_free)


func _show_world_action_label(effect_name: String, at: Vector3, color: Color, duration: float) -> void:
	var label := Label3D.new()
	label.name = "ReplayAction_%s" % effect_name
	label.text = _effect_action_text(effect_name)
	label.font_size = 22
	label.outline_size = 5
	label.modulate = Color(color.r, color.g, color.b, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = false
	label.pixel_size = 0.016
	label.position = at + Vector3(0, 3.4, 0)
	world_root.add_child(label)
	var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 1.0, 0.14)
	tween.parallel().tween_property(label, "position:y", label.position.y + 1.1, duration * 0.72)
	tween.tween_interval(maxf(0.08, duration * 0.12))
	tween.tween_property(label, "modulate:a", 0.0, duration * 0.24)
	tween.tween_callback(label.queue_free)


func _effect_action_text(effect_name: String) -> String:
	match effect_name:
		"build": return "BUILDING"
		"gather": return "GATHERING"
		"combat": return "CLASH"
		"capture": return "CAPTURED"
		"trade": return "TRADE"
		_: return effect_name.to_upper()


func _build_effect_motif(parent: Node3D, effect_name: String, color: Color, duration: float) -> void:
	## These motifs are deliberately presentation-only: they make the authored
	## replay legible at a glance while all outcomes still come from snapshots.
	var pieces: Array[MeshInstance3D] = []
	match effect_name:
		"build":
			for offset in [Vector3(-1.4, 0.0, -0.7), Vector3(1.4, 0.0, -0.7), Vector3(0.0, 1.2, -0.7)]:
				var post := MeshInstance3D.new()
				var post_mesh := BoxMesh.new()
				post_mesh.size = Vector3(0.16, 2.4 if offset.y > 0.0 else 1.4, 0.16)
				post.mesh = post_mesh
				post.position = offset
				post.material_override = _material(Color(color.r, color.g, color.b, 0.9), true)
				parent.add_child(post)
				pieces.append(post)
		"trade":
			for side in [-1.0, 1.0]:
				var crate := MeshInstance3D.new()
				var crate_mesh := BoxMesh.new()
				crate_mesh.size = Vector3(0.65, 0.65, 0.65)
				crate.mesh = crate_mesh
				crate.position = Vector3(side * 1.25, 0.45, 0.0)
				crate.material_override = _material(Color(color.r, color.g, color.b, 0.92), true)
				parent.add_child(crate)
				pieces.append(crate)
		"combat":
			for index in 3:
				var spark := MeshInstance3D.new()
				var spark_mesh := BoxMesh.new()
				spark_mesh.size = Vector3(0.18, 1.1, 0.18)
				spark.mesh = spark_mesh
				spark.rotation.z = -0.75 + float(index) * 0.75
				spark.position = Vector3(-0.8 + float(index) * 0.8, 1.0, 0.0)
				spark.material_override = _material(Color(color.r, color.g, color.b, 0.95), true)
				parent.add_child(spark)
				pieces.append(spark)
		"capture":
			var beacon := MeshInstance3D.new()
			var beacon_mesh := CylinderMesh.new()
			beacon_mesh.top_radius = 0.18
			beacon_mesh.bottom_radius = 0.42
			beacon_mesh.height = 2.8
			beacon.mesh = beacon_mesh
			beacon.position.y = 1.35
			beacon.material_override = _material(Color(color.r, color.g, color.b, 0.82), true)
			parent.add_child(beacon)
			pieces.append(beacon)
		"gather":
			for index in 3:
				var chip := MeshInstance3D.new()
				var chip_mesh := BoxMesh.new()
				chip_mesh.size = Vector3(0.34, 0.34, 0.34)
				chip.mesh = chip_mesh
				chip.position = Vector3(-0.6 + float(index) * 0.6, 0.35, 0.0)
				chip.material_override = _material(Color(color.r, color.g, color.b, 0.9), true)
				parent.add_child(chip)
				pieces.append(chip)
	var rise := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	for piece in pieces:
		var start := piece.position
		piece.scale = Vector3.ZERO
		rise.parallel().tween_property(piece, "scale", Vector3.ONE, minf(0.38, duration * 0.35))
		if effect_name == "trade":
			rise.parallel().tween_property(piece, "position", Vector3(-start.x, start.y + 0.4, start.z), duration * 0.7)
		else:
			rise.parallel().tween_property(piece, "position", start + Vector3(0, 0.45, 0), duration * 0.7)
	var fade := create_tween()
	fade.tween_interval(maxf(0.1, duration * 0.55))
	for piece in pieces:
		if is_instance_valid(piece) and piece.material_override is StandardMaterial3D:
			fade.parallel().tween_property(piece.material_override, "albedo_color:a", 0.0, duration * 0.45)


func _effect_color(effect_name: String) -> Color:
	match effect_name.to_lower():
		"build":
			return Color("83e3bf")
		"gather":
			return Color("f4c95d")
		"combat":
			return Color("ff735d")
		"capture":
			return Color("b993ff")
		"trade":
			return Color("73cff5")
		_:
			return Color("9caeb4")


func _build_podium() -> void:
	podium_overlay = ArenaPodiumScript.new()
	podium_overlay.name = "EvidencePodium"
	ui_root.add_child(podium_overlay)


func _build_conquest_minimap() -> void:
	conquest_minimap = ConquestMinimapScript.new()
	conquest_minimap.name = "ConquestMinimap"
	conquest_minimap.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	conquest_minimap.offset_left = -194
	conquest_minimap.offset_top = -226
	conquest_minimap.offset_right = -16
	conquest_minimap.offset_bottom = -132
	conquest_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(conquest_minimap)


func _build_top_bar() -> void:
	var panel := PanelContainer.new()
	panel.name = "ConquestObjectiveBar"
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.offset_left = -470
	panel.offset_top = 10
	panel.offset_right = 470
	panel.offset_bottom = 86
	panel.add_theme_stylebox_override("panel", _kenney_panel_style(Color(0.012, 0.029, 0.043, 0.96), Color("c99842"), 14, 10))
	ui_root.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)

	var brand := Label.new()
	brand.text = "WORLD ARENA\nCONQUEST"
	brand.custom_minimum_size.x = 88
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	brand.add_theme_font_size_override("font_size", 15)
	brand.add_theme_color_override("font_color", Color("fff3c4"))
	row.add_child(brand)

	round_label = Label.new()
	round_label.text = "ROUND 00"
	round_label.custom_minimum_size.x = 86
	round_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	round_label.add_theme_font_size_override("font_size", 11)
	round_label.add_theme_color_override("font_color", Color("f4c95d"))
	row.add_child(round_label)

	var objective_box := VBoxContainer.new()
	objective_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	objective_box.add_theme_constant_override("separation", 2)
	row.add_child(objective_box)
	objective_label = Label.new()
	objective_label.text = "OBJECTIVE  ·  DESTROY EVERY RIVAL STRONGHOLD"
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	objective_label.add_theme_font_size_override("font_size", 20)
	objective_label.add_theme_color_override("font_color", Color("f8f2dd"))
	objective_box.add_child(objective_label)
	objective_progress = ProgressBar.new()
	objective_progress.custom_minimum_size = Vector2(0, 10)
	objective_progress.min_value = 0
	objective_progress.max_value = 100
	objective_progress.value = 0
	objective_progress.show_percentage = false
	objective_progress.add_theme_stylebox_override("background", _panel_style(Color("132d3b"), Color("2b5969"), 5, 0))
	objective_progress.add_theme_stylebox_override("fill", _panel_style(Color("70b8ff"), Color("bde4ff"), 5, 0))
	objective_box.add_child(objective_progress)
	objective_detail_label = Label.new()
	objective_detail_label.text = "OPENING  ·  Strongholds alive 3 / 3"
	objective_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	objective_detail_label.add_theme_font_size_override("font_size", 10)
	objective_detail_label.add_theme_color_override("font_color", Color("9dbbc3"))
	objective_box.add_child(objective_detail_label)

	phase_label = Label.new()
	phase_label.text = "LIVE"
	phase_label.visible = false
	row.add_child(phase_label)

	for faction_id in FACTION_IDS:
		var status := Label.new()
		status.text = faction_id.to_upper()
		status.visible = false
		row.add_child(status)
		thinking_labels[faction_id] = status

	timer_label = Label.new()
	timer_label.text = "01:30"
	timer_label.custom_minimum_size.x = 92
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer_label.add_theme_font_size_override("font_size", 24)
	timer_label.add_theme_color_override("font_color", Color("fff3c4"))
	row.add_child(timer_label)

	perspective_select = OptionButton.new()
	perspective_select.visible = false
	perspective_select.add_item("Spectator", 0)
	perspective_select.add_item("View: Sol", 1)
	perspective_select.add_item("View: Terra", 2)
	perspective_select.add_item("View: Luna", 3)
	perspective_select.item_selected.connect(_on_perspective_selected)
	row.add_child(perspective_select)


func set_showcase_time(elapsed_seconds: float, duration_seconds: float) -> void:
	if timer_label == null:
		return
	var remaining := maxi(0, int(ceil(duration_seconds - elapsed_seconds)))
	timer_label.text = "%02d:%02d" % [remaining / 60, remaining % 60]


func _update_objective(snapshot: Dictionary) -> void:
	if objective_progress == null:
		return
	var alive := 0
	var contested := false
	var expanded := false
	for faction_variant in snapshot.get("factions", []):
		if not faction_variant is Dictionary:
			continue
		var faction: Dictionary = faction_variant
		if not bool(faction.get("eliminated", false)) and float(faction.get("core_hp", 1.0)) > 0.0:
			alive += 1
		if float(faction.get("land_percent", 0.0)) >= 28.0:
			expanded = true
	for district_variant in snapshot.get("districts", []):
		if district_variant is Dictionary and bool((district_variant as Dictionary).get("contested", false)):
			contested = true
	var phase := "OPENING"
	if alive <= 1:
		phase = "ENDGAME"
	elif contested or current_phase in ["combat", "war"]:
		phase = "WAR"
	elif expanded:
		phase = "EXPAND"
	elif current_round >= 5:
		phase = "FORTIFY"
	objective_progress.value = float(alive) / 3.0 * 100.0
	objective_progress.add_theme_stylebox_override("fill", _panel_style(Color("c99842"), Color("f2e2bf"), 5, 0))
	objective_detail_label.text = "%s  ·  STRONGHOLDS ALIVE  %d / 3" % [phase, alive]


func _build_faction_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "FactionOverview"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 14
	panel.offset_top = 70
	panel.offset_right = 228
	panel.offset_bottom = 342
	panel.add_theme_stylebox_override("panel", _kenney_panel_style(Color(0.018, 0.045, 0.06, 0.91), Color("79541f"), 12, 8))
	ui_root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	box.add_child(_section_label("FACTIONS  ·  RESOURCES / POP / ACTION"))
	for faction_id in FACTION_IDS:
		box.add_child(_create_faction_card(faction_id))
	relationship_graph_toggle = Button.new()
	relationship_graph_toggle.text = "SHOW DIPLOMACY MAP"
	relationship_graph_toggle.flat = true
	relationship_graph_toggle.add_theme_font_size_override("font_size", 9)
	relationship_graph_toggle.pressed.connect(_toggle_relationship_graph)
	box.add_child(relationship_graph_toggle)
	relationship_graph = RelationshipGraphScript.new()
	relationship_graph.custom_minimum_size = Vector2(190, 76)
	relationship_graph.mouse_filter = Control.MOUSE_FILTER_PASS
	relationship_graph.visible = false
	box.add_child(relationship_graph)


func _create_faction_card(faction_id: String) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(214, 92)
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.026, 0.064, 0.081, 0.92), FACTION_COLORS[faction_id].darkened(0.25), 8, 6))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	panel.add_child(box)

	var title_row := HBoxContainer.new()
	box.add_child(title_row)
	var title := Label.new()
	title.text = "%s  %s" % [FACTION_GLYPHS[faction_id], faction_id.to_upper()]
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", FACTION_COLORS[faction_id].lightened(0.2))
	title_row.add_child(title)
	var state := Label.new()
	state.text = "READY"
	state.add_theme_font_size_override("font_size", 8)
	state.add_theme_color_override("font_color", Color("9fe3d2"))
	title_row.add_child(state)

	var model := Label.new()
	model.text = ""
	model.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	model.add_theme_font_size_override("font_size", 8)
	model.add_theme_color_override("font_color", Color("7899a5"))
	model.visible = false
	box.add_child(model)

	var metrics := Label.new()
	metrics.text = "KEEP 1000/1000  ·  TERRITORY 0%"
	metrics.add_theme_font_size_override("font_size", 9)
	metrics.add_theme_color_override("font_color", Color("edf7ed"))
	box.add_child(metrics)

	var economy := Label.new()
	economy.text = "F120 W90 S70 · POP 0 · SUPPLY 0/0"
	economy.add_theme_font_size_override("font_size", 8)
	economy.add_theme_color_override("font_color", Color("7899a5"))
	box.add_child(economy)

	# Keep the established data bindings, but fold cognition/advisor detail into the
	# compact economy line. They remain available in the focused command strip.
	var cognition_label := economy
	var cognition := ProgressBar.new()
	cognition.visible = false
	panel.add_child(cognition)
	var advisors := economy

	var click_target := Button.new()
	click_target.flat = true
	click_target.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	click_target.tooltip_text = "Inspect %s and focus its commander" % FACTION_NAMES[faction_id]
	click_target.pressed.connect(func() -> void: _select_faction(faction_id))
	panel.add_child(click_target)

	faction_cards[faction_id] = {
		"panel": panel,
		"state": state,
		"model": model,
		"metrics": metrics,
		"economy": economy,
		"cognition": cognition,
		"cognition_label": cognition_label,
		"advisors": advisors
	}
	return panel


func _build_diplomacy_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "DiplomacyDock"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -258
	panel.offset_top = 70
	panel.offset_right = -14
	panel.offset_bottom = 292
	panel.add_theme_stylebox_override("panel", _kenney_panel_style(Color(0.018, 0.045, 0.06, 0.91), Color("79541f"), 12, 8))
	diplomacy_panel = panel
	ui_root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	var header := HBoxContainer.new()
	box.add_child(header)
	var title := _section_label("BATTLE CHRONICLE")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	diplomacy_filter = OptionButton.new()
	diplomacy_filter.custom_minimum_size.x = 76
	for filter_name in ["All", "World", "Comms"]:
		diplomacy_filter.add_item(filter_name)
	diplomacy_filter.item_selected.connect(func(_index: int) -> void: _rebuild_feed())
	header.add_child(diplomacy_filter)

	diplomacy_toggle = Button.new()
	diplomacy_toggle.text = "MINIMIZE"
	diplomacy_toggle.flat = true
	diplomacy_toggle.add_theme_font_size_override("font_size", 8)
	diplomacy_toggle.pressed.connect(_toggle_diplomacy_panel)
	header.add_child(diplomacy_toggle)

	diplomacy_scroll = ScrollContainer.new()
	diplomacy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	diplomacy_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(diplomacy_scroll)
	diplomacy_feed = VBoxContainer.new()
	diplomacy_feed.custom_minimum_size.x = 214
	diplomacy_feed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diplomacy_feed.add_theme_constant_override("separation", 7)
	diplomacy_scroll.add_child(diplomacy_feed)


func _build_command_and_replay_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "CommandReplayStrip"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 14
	panel.offset_top = -118
	panel.offset_right = -14
	panel.offset_bottom = -12
	panel.add_theme_stylebox_override("panel", _kenney_panel_style(Color(0.013, 0.035, 0.049, 0.94), Color("79541f"), 12, 8))
	ui_root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	box.add_child(command_row)
	selected_title = Label.new()
	selected_title.text = "SOL"
	selected_title.custom_minimum_size.x = 52
	selected_title.add_theme_font_size_override("font_size", 11)
	selected_title.add_theme_color_override("font_color", FACTION_COLORS.sol)
	command_row.add_child(selected_title)
	selected_intent = Label.new()
	selected_intent.text = "CURRENT ORDER · Awaiting authoritative command."
	selected_intent.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	selected_intent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selected_intent.add_theme_font_size_override("font_size", 11)
	selected_intent.add_theme_color_override("font_color", Color("edf7ed"))
	command_row.add_child(selected_intent)
	live_status_label = Label.new()
	live_status_label.text = "CONQUEST REPLAY"
	live_status_label.add_theme_font_size_override("font_size", 9)
	live_status_label.add_theme_color_override("font_color", Color("f4c95d"))
	command_row.add_child(live_status_label)
	var action_legend := Label.new()
	action_legend.text = "TASK INSPECTOR   MOVE  ·  GATHER  ·  BUILD  ·  ATTACK  ·  RETREAT  ·  RESEARCH"
	action_legend.add_theme_font_size_override("font_size", 8)
	action_legend.add_theme_color_override("font_color", Color("86a9a8"))
	box.add_child(action_legend)

	selected_orders = Label.new()
	selected_orders.text = ""
	selected_orders.visible = false
	selected_orders.add_theme_font_size_override("font_size", 9)
	selected_orders.add_theme_color_override("font_color", Color("a9c5c5"))
	box.add_child(selected_orders)
	selected_advisors = Label.new()
	selected_advisors.text = ""
	selected_advisors.visible = false
	selected_advisors.add_theme_font_size_override("font_size", 9)
	selected_advisors.add_theme_color_override("font_color", Color("70b8ff"))
	box.add_child(selected_advisors)

	var replay_row := HBoxContainer.new()
	replay_row.add_theme_constant_override("separation", 7)
	box.add_child(replay_row)
	pause_button = Button.new()
	pause_button.text = "PAUSE"
	pause_button.custom_minimum_size.x = 62
	pause_button.add_theme_stylebox_override("normal", _kenney_button_style())
	pause_button.pressed.connect(_toggle_pause)
	replay_row.add_child(pause_button)
	timeline_slider = HSlider.new()
	timeline_slider.min_value = 0
	timeline_slider.max_value = 120
	timeline_slider.step = 1
	timeline_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline_slider.custom_minimum_size.x = 160
	timeline_slider.tooltip_text = "Round timeline — drag to request a deterministic seek"
	timeline_slider.drag_ended.connect(_on_timeline_drag_ended)
	replay_row.add_child(timeline_slider)
	speed_select = OptionButton.new()
	for speed in [0.5, 1.0, 2.0, 4.0, 8.0]:
		speed_select.add_item(str(speed) + "×")
		speed_select.set_item_metadata(speed_select.item_count - 1, speed)
	speed_select.select(1)
	speed_select.item_selected.connect(_on_speed_selected)
	replay_row.add_child(speed_select)

	timeline_markers = HBoxContainer.new()
	timeline_markers.visible = false
	box.add_child(timeline_markers)


func _build_setup_lobby() -> void:
	setup_overlay = Control.new()
	setup_overlay.name = "SetupLobby"
	setup_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	setup_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	ui_root.add_child(setup_overlay)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.007, 0.021, 0.03, 0.86)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	setup_overlay.add_child(shade)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -400
	panel.offset_top = -348
	panel.offset_right = 400
	panel.offset_bottom = 270
	panel.add_theme_stylebox_override("panel", _panel_style(Color("071923"), Color("2b6d72"), 20, 20))
	setup_overlay.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	panel.add_child(content)
	setup_content = content
	content.add_child(_section_label("WORLD ARENA  /  CONQUEST"))
	var title := Label.new()
	title.text = "Configure the commanders."
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color("fff3c4"))
	content.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Collect resources, build a force, and outplay two rival agents on one compact island."
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", Color("a9c5c5"))
	content.add_child(subtitle)

	content.add_child(_caption("OPENAI API KEY  ·  MEMORY ONLY  ·  NEVER WRITTEN TO REPLAY"))
	var key_row := HBoxContainer.new()
	key_row.add_theme_constant_override("separation", 8)
	content.add_child(key_row)
	api_key_input = LineEdit.new()
	api_key_input.placeholder_text = "sk-proj-…"
	api_key_input.secret = true
	api_key_input.secret_character = "•"
	api_key_input.custom_minimum_size.y = 42
	api_key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_row.add_child(api_key_input)
	var reveal_key := CheckButton.new()
	reveal_key.text = "SHOW"
	reveal_key.toggled.connect(func(pressed: bool) -> void: api_key_input.secret = not pressed)
	key_row.add_child(reveal_key)

	content.add_child(_caption("MATCH  ·  WHAT THE AGENTS OBSERVE"))
	var match_row := HBoxContainer.new()
	match_row.add_theme_constant_override("separation", 10)
	content.add_child(match_row)
	scenario_select = OptionButton.new()
	scenario_select.custom_minimum_size = Vector2(0, 40)
	scenario_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scenario_select.add_item("Standard Island Skirmish")
	scenario_select.set_item_metadata(0, "tri_13_v1")
	scenario_select.tooltip_text = "A compact three-base map with crossroads and rival strongholds."
	match_row.add_child(scenario_select)
	observation_select = OptionButton.new()
	observation_select.custom_minimum_size = Vector2(220, 40)
	for observation_mode in ["semantic", "vision", "hybrid"]:
		var label: String = str(observation_mode).capitalize()
		if observation_mode == "semantic":
			label += " · recommended"
		observation_select.add_item(label)
		observation_select.set_item_metadata(observation_select.item_count - 1, observation_mode)
	observation_select.select(0)
	observation_select.tooltip_text = "Semantic is the fair benchmark default; vision and hybrid are separate evaluation tracks."
	match_row.add_child(observation_select)

	content.add_child(_caption("COMMANDERS  ·  INDEPENDENT MODEL AND REASONING BUDGET"))
	var defaults := {"sol": "gpt-5.6-sol", "terra": "gpt-5.6-terra", "luna": "gpt-5.6-luna"}
	for faction_id in FACTION_IDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		content.add_child(row)
		var identity := Label.new()
		identity.text = "%s  %s" % [FACTION_GLYPHS[faction_id], faction_id.to_upper()]
		identity.custom_minimum_size = Vector2(105, 40)
		identity.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		identity.add_theme_font_size_override("font_size", 14)
		identity.add_theme_color_override("font_color", FACTION_COLORS[faction_id])
		row.add_child(identity)
		var model_input := LineEdit.new()
		model_input.text = defaults[faction_id]
		model_input.placeholder_text = "OpenAI model ID"
		model_input.custom_minimum_size = Vector2(0, 40)
		model_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(model_input)
		model_inputs[faction_id] = model_input
		var reasoning := OptionButton.new()
		reasoning.custom_minimum_size.x = 120
		for effort in ["low", "medium", "high", "xhigh"]:
			reasoning.add_item(effort.capitalize())
			reasoning.set_item_metadata(reasoning.item_count - 1, effort)
		reasoning.select(1 if faction_id == "sol" else 0)
		row.add_child(reasoning)
		reasoning_inputs[faction_id] = reasoning
		var advisors := OptionButton.new()
		advisors.custom_minimum_size.x = 116
		for advisor_count in range(4):
			advisors.add_item("%d advisor%s" % [advisor_count, "" if advisor_count == 1 else "s"])
			advisors.set_item_metadata(advisors.item_count - 1, advisor_count)
		advisors.select({"sol": 2, "terra": 1, "luna": 0}.get(faction_id, 0))
		advisors.tooltip_text = "Maximum specialist calls for %s (0–3)." % faction_id.capitalize()
		row.add_child(advisors)
		advisor_inputs[faction_id] = advisors

	var rules := Label.new()
	rules.text = "LAST STRONGHOLD STANDING  ·  120-ROUND CAP  ·  SIMULTANEOUS PLANS  ·  REPLAY ON"
	rules.add_theme_font_size_override("font_size", 11)
	rules.add_theme_color_override("font_color", Color("70b8ff"))
	content.add_child(rules)
	setup_status_label = Label.new()
	setup_status_label.text = "Leave the key blank for the credential-free demo policy." if mock_mode else "Connected. Choose each commander's model and advisor count."
	setup_status_label.add_theme_font_size_override("font_size", 12)
	setup_status_label.add_theme_color_override("font_color", Color("f4c95d"))
	content.add_child(setup_status_label)
	setup_start_button = Button.new()
	setup_start_button.text = "START MATCH"
	setup_start_button.custom_minimum_size.y = 50
	setup_start_button.add_theme_font_size_override("font_size", 15)
	setup_start_button.pressed.connect(_on_setup_start)
	content.add_child(setup_start_button)
	_build_simulation_lobby(panel)


func _build_simulation_lobby(live_panel: PanelContainer) -> void:
	# Keep the established LIVE MATCH form intact underneath this sibling page.
	# Tabs live above both pages, so changing modes never recreates credentials or
	# commander/advisor controls.
	var tabs := HBoxContainer.new()
	tabs.set_anchors_preset(Control.PRESET_CENTER_TOP)
	tabs.offset_left = -400
	tabs.offset_top = 72
	tabs.offset_right = 400
	tabs.offset_bottom = 112
	tabs.add_theme_constant_override("separation", 8)
	tabs.z_index = 4
	setup_overlay.add_child(tabs)
	for entry in [["live", "⚔  LIVE MATCH"], ["simulation", "ϟ  FAST SIMULATION"], ["replays", "▣  REPLAY LIBRARY"]]:
		var mode := str(entry[0])
		var button := Button.new()
		button.text = str(entry[1])
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size.y = 38
		button.add_theme_font_size_override("font_size", 14)
		button.add_theme_color_override("font_color", Color("b7c9cc"))
		button.add_theme_color_override("font_hover_color", Color("fff3c4"))
		button.add_theme_color_override("font_pressed_color", Color("fff3c4"))
		button.add_theme_stylebox_override("normal", _panel_style(Color("0b1821"), Color("203d48"), 7, 7))
		button.add_theme_stylebox_override("hover", _panel_style(Color("132936"), Color("4b7380"), 7, 7))
		button.add_theme_stylebox_override("pressed", _panel_style(Color("5b3c12"), Color("e6a62f"), 7, 7))
		button.add_theme_stylebox_override("hover_pressed", _panel_style(Color("6b4817"), Color("ffc45b"), 7, 7))
		button.button_pressed = mode == "live"
		button.pressed.connect(func() -> void: _set_lobby_mode(mode))
		tabs.add_child(button)
		lobby_mode_buttons[mode] = button

	simulation_page = PanelContainer.new()
	simulation_page.name = "SimulationLab"
	simulation_page.set_anchors_preset(Control.PRESET_CENTER)
	simulation_page.offset_left = -400
	simulation_page.offset_top = -348
	simulation_page.offset_right = 400
	simulation_page.offset_bottom = 270
	simulation_page.add_theme_stylebox_override("panel", _panel_style(Color("071923"), Color("c28b27"), 20, 20))
	simulation_page.visible = false
	setup_overlay.add_child(simulation_page)
	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	simulation_page.add_child(outer)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 9)
	outer.add_child(left)
	left.add_child(_section_label("FAST SIMULATION"))
	var heading := Label.new()
	heading.text = "RUN HEADLESS  →  SAVE REPLAY  →  WATCH & SCRUB"
	heading.add_theme_font_size_override("font_size", 17)
	heading.add_theme_color_override("font_color", Color("fff3c4"))
	left.add_child(heading)
	left.add_child(_caption("Same authoritative rules as a live match. Saved artifacts replay through the compact battlefield."))

	left.add_child(_caption("POLICY SOURCE"))
	simulation_policy_select = OptionButton.new()
	simulation_policy_select.add_item("Deterministic demo")
	simulation_policy_select.set_item_metadata(0, "deterministic_demo")
	simulation_policy_select.add_item("Live AI")
	simulation_policy_select.set_item_metadata(1, "live_ai")
	left.add_child(simulation_policy_select)
	var seed_row := HBoxContainer.new()
	seed_row.add_child(_caption("SEED"))
	simulation_seed_input = LineEdit.new()
	simulation_seed_input.text = "ARENA-2407"
	simulation_seed_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(simulation_seed_input)
	left.add_child(seed_row)
	var rounds_row := HBoxContainer.new()
	rounds_row.add_child(_caption("MAX ROUNDS"))
	simulation_rounds_input = SpinBox.new()
	simulation_rounds_input.min_value = 1
	simulation_rounds_input.max_value = 120
	simulation_rounds_input.step = 1
	simulation_rounds_input.value = 36
	simulation_rounds_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rounds_row.add_child(simulation_rounds_input)
	left.add_child(rounds_row)
	var observation_row := HBoxContainer.new()
	observation_row.add_child(_caption("OBSERVATION"))
	simulation_observation_select = OptionButton.new()
	simulation_observation_select.add_item("Semantic state")
	simulation_observation_select.set_item_metadata(0, "semantic")
	simulation_observation_select.add_item("Vision")
	simulation_observation_select.set_item_metadata(1, "vision")
	simulation_observation_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	observation_row.add_child(simulation_observation_select)
	left.add_child(observation_row)
	left.add_child(_caption("TEAM SUMMARY  ·  Sol 2 advisors  ·  Terra 1  ·  Luna 0  (advisor range remains 0–3)"))
	var note := Label.new()
	note.text = "Headless execution only. The replay is saved before you watch it."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color("a9c5c5"))
	left.add_child(note)
	simulation_status_label = Label.new()
	simulation_status_label.text = "READY  ·  choose a seed and run a simulation"
	simulation_status_label.add_theme_font_size_override("font_size", 11)
	simulation_status_label.add_theme_color_override("font_color", Color("f4c95d"))
	left.add_child(simulation_status_label)
	simulation_run_button = Button.new()
	simulation_run_button.text = "▶  RUN SIMULATION"
	simulation_run_button.custom_minimum_size.y = 52
	simulation_run_button.add_theme_stylebox_override("normal", _kenney_button_style())
	simulation_run_button.add_theme_font_size_override("font_size", 15)
	simulation_run_button.add_theme_color_override("font_color", Color("fff3c4"))
	simulation_run_button.add_theme_color_override("font_hover_color", Color.WHITE)
	simulation_run_button.add_theme_stylebox_override("normal", _panel_style(Color("8a5a12"), Color("e6a62f"), 9, 10))
	simulation_run_button.add_theme_stylebox_override("hover", _panel_style(Color("a76f18"), Color("ffc45b"), 9, 10))
	simulation_run_button.add_theme_stylebox_override("pressed", _panel_style(Color("6c450d"), Color("fff3c4"), 9, 10))
	simulation_run_button.add_theme_stylebox_override("disabled", _panel_style(Color("253039"), Color("52616a"), 9, 10))
	simulation_run_button.pressed.connect(_on_simulation_run)
	left.add_child(simulation_run_button)

	var recent := PanelContainer.new()
	recent.custom_minimum_size.x = 294
	recent.add_theme_stylebox_override("panel", _panel_style(Color("0a1821"), Color("2b5969"), 12, 10))
	outer.add_child(recent)
	var recent_box := VBoxContainer.new()
	recent_box.add_theme_constant_override("separation", 8)
	recent.add_child(recent_box)
	var recent_head := HBoxContainer.new()
	recent_box.add_child(recent_head)
	var recent_title := _section_label("RECENT RUNS")
	recent_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recent_head.add_child(recent_title)
	var refresh := Button.new()
	refresh.text = "REFRESH"
	refresh.pressed.connect(func() -> void: replay_refresh_requested.emit())
	recent_head.add_child(refresh)
	replay_runs_list = VBoxContainer.new()
	replay_runs_list.add_theme_constant_override("separation", 8)
	recent_box.add_child(replay_runs_list)
	set_replay_list([])


func _on_simulation_run() -> void:
	var seed := simulation_seed_input.text.strip_edges()
	if seed.is_empty():
		set_simulation_error("Enter a non-empty seed.")
		return
	var policy := str(simulation_policy_select.get_item_metadata(simulation_policy_select.selected))
	var observation := str(simulation_observation_select.get_item_metadata(simulation_observation_select.selected))
	simulation_requested.emit({"seed": seed, "max_rounds": int(simulation_rounds_input.value), "policy": policy, "observation_mode": observation})


func _apply_units(value: Variant) -> void:
	var records := _record_array(value)
	var seen: Dictionary = {}
	for state_variant in records:
		if not state_variant is Dictionary:
			continue
		var state: Dictionary = state_variant.duplicate(true)
		var unit_id := str(state.get("id", ""))
		if unit_id.is_empty():
			continue
		seen[unit_id] = true
		state["position"] = _unit_position(state)
		var faction_id := str(state.get("faction_id", "neutral"))
		if not unit_views.has(unit_id):
			var unit = UnitViewScript.new()
			unit.name = unit_id
			units_root.add_child(unit)
			unit.setup(state, FACTION_COLORS.get(faction_id, NEUTRAL_COLOR))
			unit_views[unit_id] = unit
		else:
			unit_views[unit_id].apply_state(state)
		if str(state.get("unit_type", "")) == "commander":
			commander_views[faction_id] = unit_views[unit_id]

	# A missing replay row no longer pops a character out of existence. Units stay
	# on the battlefield in a defeated/recovering state, preserving spatial memory.
	var removed: Array = []
	for unit_id in unit_views:
		if not seen.has(unit_id):
			removed.append(unit_id)
	for unit_id in removed:
		var old_unit: Node = unit_views[unit_id]
		old_unit.apply_state({"position": old_unit.position, "visible": true, "health": 0, "max_health": 100, "task": "recovering", "in_combat": false})
	for faction_id in FACTION_IDS:
		if commander_views.has(faction_id) and not is_instance_valid(commander_views[faction_id]):
			commander_views.erase(faction_id)


func _apply_factions(value: Variant) -> void:
	var records := _records_by_id(value)
	var visible_population := {"sol": 0, "terra": 0, "luna": 0}
	for unit_variant in _record_array(current_snapshot.get("units", [])):
		if unit_variant is Dictionary and bool(unit_variant.get("visible", true)):
			var unit_faction := str(unit_variant.get("faction_id", unit_variant.get("faction", "")))
			if visible_population.has(unit_faction):
				visible_population[unit_faction] = int(visible_population[unit_faction]) + 1
	for faction_id in FACTION_IDS:
		var state: Dictionary = records.get(faction_id, {})
		var card: Dictionary = faction_cards[faction_id]
		var land := float(state.get("land_percent", 0.0))
		var army := int(state.get("army_strength", state.get("unit_count", 5)))
		var population := int(state.get("population", state.get("unit_count", visible_population[faction_id])))
		var keep_hp := int(state.get("core_hp", state.get("keep_hp", 1000)))
		var keep_max := maxi(1, int(state.get("max_core_hp", state.get("max_keep_hp", 1000))))
		var eliminated := bool(state.get("eliminated", false)) or keep_hp <= 0
		card.metrics.text = "STRONGHOLD DESTROYED" if eliminated else "KEEP %d/%d  ·  TERRITORY %d%%" % [keep_hp, keep_max, int(land)]
		card.model.text = "" # Model/provider identity belongs to setup, not the spectator hierarchy.
		var current_action := str(state.get("current_action", state.get("active_task", state.get("state", "waiting")))).replace("_", " ").to_upper()
		card.state.text = current_action
		var resources: Dictionary = state.get("resources", {})
		var supply: Dictionary = state.get("supply", {})
		var supply_used := int(supply.get("used", population))
		var supply_capacity := int(supply.get("capacity", state.get("supply_capacity", population)))
		var tech := str(state.get("tech_tier", state.get("tech", "I"))).to_upper()
		card.economy.text = "F%d W%d S%d · POP %d · SUPPLY %d/%d · TIER %s · ARMY %d" % [
			int(resources.get("food", 0)), int(resources.get("wood", 0)),
			int(resources.get("stone", 0)), population, supply_used, supply_capacity, tech, army
		]
		card.state.text = "STRONGHOLD DESTROYED" if eliminated else current_action
		var specialist_records: Array = state.get("specialists", [])
		var advisor_tokens: Array[String] = []
		for specialist_variant in specialist_records:
			if specialist_variant is Dictionary:
				var specialist: Dictionary = specialist_variant
				advisor_tokens.append("%s:%s" % [str(specialist.get("role", "?")).substr(0, 1).to_upper(), str(specialist.get("state", "idle")).substr(0, 1).to_upper()])
		# Advisor detail is intentionally deferred to the focused command strip.
		var border: Color = FACTION_COLORS[faction_id].lightened(0.1) if faction_id == selected_faction else FACTION_COLORS[faction_id].darkened(0.35)
		card.panel.add_theme_stylebox_override("panel", _panel_style(Color(0.026, 0.064, 0.081, 0.96), border, 10, 8))


## Projects persistent simulation tasks without interpreting transforms or outcomes.
## v0.2 queue names and the v0.3 task envelope are both accepted during migration.
func _apply_persistent_tasks(snapshot: Dictionary) -> void:
	var work_records: Array = []
	var construction_records: Array = []
	for key in ["tasks", "work_tasks", "resource_tasks"]:
		work_records.append_array(_record_array(snapshot.get(key, [])))
	for key in ["construction", "construction_tasks", "build_queue"]:
		construction_records.append_array(_record_array(snapshot.get(key, [])))
	for task_variant in _record_array(snapshot.get("tasks", [])):
		if task_variant is Dictionary and _is_construction_task(task_variant):
			construction_records.append(task_variant)
	var seen_work: Dictionary = {}
	for task_variant in work_records:
		if not task_variant is Dictionary or _is_construction_task(task_variant):
			continue
		var task: Dictionary = task_variant
		var task_id := str(task.get("id", task.get("task_id", "")))
		if task_id.is_empty():
			continue
		seen_work[task_id] = true
		var faction_id := str(task.get("faction_id", task.get("faction", "neutral")))
		var view = work_task_views.get(task_id)
		if view == null:
			view = WorkTaskViewScript.new()
			view.name = "WorkTask_%s" % task_id
			resources_root.add_child(view)
			work_task_views[task_id] = view
		view.apply_snapshot(task, _task_position(task), FACTION_COLORS.get(faction_id, NEUTRAL_COLOR))
	var seen_construction: Dictionary = {}
	for job_variant in construction_records:
		if not job_variant is Dictionary:
			continue
		var job: Dictionary = job_variant
		var job_id := str(job.get("id", job.get("job_id", "")))
		if job_id.is_empty():
			job_id = "%s_%s_%s" % [str(job.get("faction", "neutral")), str(job.get("kind", "build")), str(job.get("district", job.get("district_id", "")))]
			job["id"] = job_id
		seen_construction[job_id] = true
		var faction_id := str(job.get("faction_id", job.get("faction", "neutral")))
		var view = construction_views.get(job_id)
		if view == null:
			view = ConstructionViewScript.new()
			view.name = "Construction_%s" % job_id
			resources_root.add_child(view)
			construction_views[job_id] = view
		view.apply_snapshot(job, _task_position(job), FACTION_COLORS.get(faction_id, NEUTRAL_COLOR))
	_remove_missing_task_views(work_task_views, seen_work)
	_remove_missing_task_views(construction_views, seen_construction)


func _is_construction_task(task: Dictionary) -> bool:
	var kind := str(task.get("kind", task.get("action", task.get("task", "")))).to_lower()
	return kind.contains("build") or kind.contains("construct") or task.has("required_work") and task.has("builder_ids")


func _task_position(task: Dictionary) -> Vector3:
	if task.has("position"):
		return _to_vector3(task.position) * COMPACT_MAP_SCALE
	var actor_id := str(task.get("actor_id", task.get("unit_id", "")))
	if unit_views.has(actor_id) and is_instance_valid(unit_views[actor_id]):
		return unit_views[actor_id].global_position
	var district_id := str(task.get("district_id", task.get("district", task.get("target_district_id", ""))))
	return district_positions.get(district_id, Vector3.ZERO)


func _remove_missing_task_views(views: Dictionary, seen: Dictionary) -> void:
	var stale: Array = []
	for view_id in views:
		if not seen.has(view_id):
			stale.append(view_id)
	for view_id in stale:
		var view: Node = views[view_id]
		if is_instance_valid(view):
			view.queue_free()
		views.erase(view_id)


func _refresh_selected_command() -> void:
	if current_snapshot.is_empty():
		return
	var factions := _records_by_id(current_snapshot.get("factions", []))
	var state: Dictionary = factions.get(selected_faction, {})
	selected_title.text = "%s %s NOW" % [FACTION_GLYPHS[selected_faction], selected_faction.to_upper()]
	selected_title.add_theme_color_override("font_color", FACTION_COLORS[selected_faction])
	selected_intent.text = str(state.get("strategic_intent", "Strategic intent will appear after plans lock."))
	var active_task: Dictionary = {}
	for task_variant in _record_array(current_snapshot.get("tasks", current_snapshot.get("construction", []))):
		if task_variant is Dictionary and str((task_variant as Dictionary).get("faction_id", (task_variant as Dictionary).get("faction", ""))) == selected_faction:
			active_task = task_variant
			break
	if not active_task.is_empty():
		var workers: Variant = active_task.get("builder_ids", active_task.get("worker_ids", active_task.get("target_ids", [])))
		var worker_count: int = workers.size() if workers is Array else int(workers)
		var completed := int(active_task.get("completed_work", 0))
		var required := maxi(1, int(active_task.get("required_work", 1)))
		var eta := maxi(0, required - completed) / maxi(1, worker_count)
		selected_intent.text = "TASK · %s  %d%%  ·  %d worker%s  ·  ETA %02d" % [str(active_task.get("structure", active_task.get("resource", active_task.get("kind", "work")))).to_upper(), int(float(completed) / required * 100.0), worker_count, "" if worker_count == 1 else "s", eta]
	var order_summaries: Array[String] = []
	for order_variant in state.get("orders", []):
		if order_variant is Dictionary:
			var order: Dictionary = order_variant
			var target := str(order.get("target", order.get("district_id", "")))
			order_summaries.append("%s%s" % [str(order.get("action", "order")).replace("_", " ").to_upper(), " → " + target if not target.is_empty() else ""])
	selected_orders.text = "ORDERS  %s" % ("—" if order_summaries.is_empty() else "  ·  ".join(order_summaries))
	selected_orders.visible = true
	var advisor_summaries: Array[String] = []
	for advisor_variant in state.get("specialists", []):
		if advisor_variant is Dictionary:
			var advisor: Dictionary = advisor_variant
			advisor_summaries.append("%s %s: %s" % [
				str(advisor.get("role", "advisor")).to_upper(),
				str(advisor.get("disposition", advisor.get("state", "idle"))).to_upper(),
				str(advisor.get("recommendation_summary", "waiting"))
			])
	selected_advisors.text = "ADVISORS  %s" % ("none active" if advisor_summaries.is_empty() else "  |  ".join(advisor_summaries))
	selected_advisors.visible = false


func _apply_event(event: Dictionary) -> void:
	var safe_event := event.duplicate(true)
	var event_id := str(safe_event.get("event_id", "local_%06d" % event_history.size()))
	if event_ids.has(event_id):
		return
	safe_event["event_id"] = event_id
	event_ids[event_id] = true
	event_history.append(safe_event)

	var kind := str(safe_event.get("kind", "system"))
	if kind in ["pact", "betrayal", "offer", "trade"]:
		relationship_graph.apply_relation(safe_event)
	if kind in ["message", "offer", "trade", "pact", "betrayal"]:
		show_message(safe_event)
	if kind in ["territory", "supply"]:
		var payload: Dictionary = safe_event.get("payload", {})
		var district_id := str(payload.get("district_id", ""))
		if district_views.has(district_id) and payload.has("district_state"):
			district_views[district_id].apply_state(payload.district_state)
	if kind in ["gather", "resource", "work", "build", "construction"]:
		_apply_task_event(safe_event)

	_add_timeline_marker(safe_event)
	_rebuild_feed()
	call_deferred("_scroll_feed_to_end")


func _apply_task_event(event: Dictionary) -> void:
	var payload: Dictionary = event.get("payload", {})
	var task: Dictionary = payload.get("task", payload.get("task_state", payload.get("job", payload.get("construction", {}))))
	if task.is_empty():
		task = payload.duplicate(true)
		task["id"] = str(event.get("task_id", event.get("job_id", event.get("event_id", "event_task"))))
		task["kind"] = str(event.get("kind", "work"))
		task["state"] = str(event.get("state", "active"))
		if event.has("actor_id"):
			task["actor_id"] = event.actor_id
	var faction_id := str(task.get("faction_id", task.get("faction", event.get("faction_id", "neutral"))))
	var position := _task_position(task)
	var task_id := str(task.get("id", event.get("event_id", "event_task")))
	if _is_construction_task(task):
		var construction = construction_views.get(task_id)
		if construction == null:
			construction = ConstructionViewScript.new()
			construction.name = "Construction_%s" % task_id
			resources_root.add_child(construction)
			construction_views[task_id] = construction
		construction.apply_event(event, position, FACTION_COLORS.get(faction_id, NEUTRAL_COLOR))
	else:
		var work = work_task_views.get(task_id)
		if work == null:
			work = WorkTaskViewScript.new()
			work.name = "WorkTask_%s" % task_id
			resources_root.add_child(work)
			work_task_views[task_id] = work
		work.apply_event(event, position, FACTION_COLORS.get(faction_id, NEUTRAL_COLOR))


func _rebuild_feed() -> void:
	for child in diplomacy_feed.get_children():
		child.queue_free()
	var filter_name := diplomacy_filter.get_item_text(diplomacy_filter.selected).to_lower()
	var visible_events: Array[Dictionary] = []
	for event in event_history:
		if not _event_visible(event) or not _event_matches_filter(event, filter_name):
			continue
		visible_events.append(event)
	# A live demo needs the latest conversation, not a second full event log.
	for event in visible_events.slice(maxi(0, visible_events.size() - 3)):
		diplomacy_feed.add_child(_create_feed_entry(event))
	if diplomacy_feed.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "No visible events in this channel."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color("7899a5"))
		diplomacy_feed.add_child(empty)


func _create_feed_entry(event: Dictionary) -> Control:
	var actor_id := str(event.get("actor_id", "system"))
	var visibility_kind := str(event.get("visibility", "public"))
	var targets: Array = event.get("target_ids", [])
	var recipient := "ALL" if targets.is_empty() else ", ".join(targets.map(func(value: Variant) -> String: return str(value).to_upper()))
	var kind := str(event.get("kind", "system"))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.024, 0.058, 0.074, 0.95), FACTION_COLORS.get(actor_id, Color("506771")).darkened(0.2), 9, 8))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	var header := Label.new()
	header.text = "R%02d  %s  %s → %s" % [int(event.get("round", current_round)), _event_icon(kind, visibility_kind), actor_id.to_upper(), recipient]
	header.add_theme_font_size_override("font_size", 10)
	header.add_theme_color_override("font_color", FACTION_COLORS.get(actor_id, Color("a9c5c5")).lightened(0.2))
	box.add_child(header)
	var summary := Label.new()
	summary.text = str(event.get("summary", "Event recorded")).substr(0, 120)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_theme_font_size_override("font_size", 10)
	summary.add_theme_color_override("font_color", Color("edf7ed"))
	box.add_child(summary)
	var state := str(event.get("state", event.get("payload", {}).get("state", "")))
	if visibility_kind != "public" or not state.is_empty():
		var meta := Label.new()
		var privacy_text := "PRIVATE — SPECTATOR ONLY" if visibility_kind != "public" and current_perspective == "spectator" else visibility_kind.to_upper()
		meta.text = "%s%s" % [privacy_text, "  ·  " + state.replace("_", " ").to_upper() if not state.is_empty() else ""]
		meta.add_theme_font_size_override("font_size", 9)
		meta.add_theme_color_override("font_color", Color("ffb35c") if visibility_kind != "public" else Color("70b8ff"))
		box.add_child(meta)
	var click_target := Button.new()
	click_target.flat = true
	click_target.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	click_target.tooltip_text = "Focus event %s" % str(event.event_id)
	click_target.pressed.connect(func() -> void: event_focus_requested.emit(str(event.event_id)))
	panel.add_child(click_target)
	return panel


func _event_matches_filter(event: Dictionary, filter_name: String) -> bool:
	if filter_name == "all":
		return true
	var kind := str(event.get("kind", "system"))
	var visibility_kind := str(event.get("visibility", "public"))
	match filter_name:
		"world": return kind in ["move", "gather", "resource", "build", "construction", "train", "combat", "territory", "supply", "capture", "core"]
		"comms": return kind in ["message", "offer", "trade", "pact", "betrayal"]
	return true


func _event_visible(event: Dictionary) -> bool:
	var visibility_kind := str(event.get("visibility", "public"))
	if visibility_kind == "public":
		return true
	if current_perspective == "spectator":
		return true
	var visible_to: Array = event.get("visible_to", [])
	if visible_to.is_empty():
		visible_to = event.get("target_ids", []).duplicate()
		visible_to.append(str(event.get("actor_id", "")))
	return current_perspective in visible_to


func _create_speech_bubble(event: Dictionary) -> void:
	var actor_id := str(event.get("actor_id", ""))
	var bubble = SpeechBubbleScript.new()
	bubble.name = "Speech_%s" % actor_id
	bubble.configure(event, FACTION_COLORS.get(actor_id, NEUTRAL_COLOR))
	bubble.selected.connect(func(event_id: String) -> void: event_focus_requested.emit(event_id))
	bubble_layer.add_child(bubble)
	bubble.size = bubble.get_combined_minimum_size()
	# Speech appears as a quick callout instead of an abrupt UI block.  It stays
	# readable long enough for uploadable captures, then the existing expiry logic
	# removes it without retaining any communication data.
	bubble.modulate = Color(1, 1, 1, 0)
	var enter := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	enter.tween_property(bubble, "modulate:a", 1.0, 0.18)
	active_bubbles[actor_id] = bubble


func _update_speech_bubbles() -> void:
	if camera == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	for actor_id in active_bubbles.keys():
		var bubble: Control = active_bubbles[actor_id]
		if not is_instance_valid(bubble):
			active_bubbles.erase(actor_id)
			continue
		if bubble.is_expired():
			bubble.queue_free()
			active_bubbles.erase(actor_id)
			if bubble_queues.has(actor_id) and not bubble_queues[actor_id].is_empty():
				var next_event: Dictionary = bubble_queues[actor_id].pop_front()
				_create_speech_bubble(next_event)
			continue
		if not commander_views.has(actor_id) or not is_instance_valid(commander_views[actor_id]):
			commander_views.erase(actor_id)
			bubble.visible = false
			continue
		var anchor: Vector3 = commander_views[actor_id].bubble_anchor()
		if camera.is_position_behind(anchor):
			bubble.visible = false
			continue
		bubble.visible = true
		var screen_position := camera.unproject_position(anchor)
		var desired := screen_position - Vector2(bubble.size.x * 0.5, bubble.size.y + 10.0)
		desired.x = clampf(desired.x, 8.0, maxf(8.0, viewport_size.x - bubble.size.x - 8.0))
		desired.y = clampf(desired.y, 76.0, maxf(76.0, viewport_size.y - bubble.size.y - 170.0))
		bubble.position = desired


func _clear_bubbles() -> void:
	for bubble in active_bubbles.values():
		if is_instance_valid(bubble):
			bubble.queue_free()
	active_bubbles.clear()
	bubble_queues.clear()


func _add_timeline_marker(event: Dictionary) -> void:
	var marker := Button.new()
	marker.flat = true
	marker.text = _event_icon(str(event.get("kind", "system")), str(event.get("visibility", "public")))
	marker.tooltip_text = "R%02d · %s" % [int(event.get("round", current_round)), str(event.get("summary", "event"))]
	marker.add_theme_color_override("font_color", FACTION_COLORS.get(str(event.get("actor_id", "")), Color("a9c5c5")))
	marker.pressed.connect(func() -> void: event_focus_requested.emit(str(event.get("event_id", ""))))
	timeline_markers.add_child(marker)


func _scroll_feed_to_end() -> void:
	if is_instance_valid(diplomacy_scroll):
		diplomacy_scroll.scroll_vertical = int(diplomacy_scroll.get_v_scroll_bar().max_value)


func _toggle_relationship_graph() -> void:
	if relationship_graph == null:
		return
	relationship_graph.visible = not relationship_graph.visible
	if relationship_graph_toggle != null:
		relationship_graph_toggle.text = "HIDE DIPLOMACY MAP" if relationship_graph.visible else "SHOW DIPLOMACY MAP"


func _toggle_diplomacy_panel() -> void:
	if diplomacy_panel == null or diplomacy_scroll == null:
		return
	diplomacy_scroll.visible = not diplomacy_scroll.visible
	diplomacy_panel.offset_bottom = 292 if diplomacy_scroll.visible else 104
	if diplomacy_toggle != null:
		diplomacy_toggle.text = "MINIMIZE" if diplomacy_scroll.visible else "COMMS"


func _select_faction(faction_id: String) -> void:
	if not faction_id in FACTION_IDS:
		return
	selected_faction = faction_id
	_apply_factions(current_snapshot.get("factions", []))
	_refresh_selected_command()
	if commander_views.has(faction_id):
		var commander_position: Vector3 = commander_views[faction_id].global_position
		var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		var target_position := commander_position + Vector3(72, 88, 78)
		tween.tween_property(camera, "position", target_position, 0.65)
		tween.parallel().tween_method(func(_value: float) -> void: camera.look_at(commander_position, Vector3.UP), 0.0, 1.0, 0.65)


func _set_perspective(perspective_id: String, emit_request: bool) -> void:
	if perspective_id != "spectator" and not perspective_id in FACTION_IDS:
		return
	current_perspective = perspective_id
	perspective_select.select(0 if perspective_id == "spectator" else FACTION_IDS.find(perspective_id) + 1)
	if perspective_id != "spectator":
		selected_faction = perspective_id
	_clear_bubbles()
	_rebuild_feed()
	_refresh_selected_command()
	if emit_request:
		perspective_requested.emit(perspective_id)


func _on_perspective_selected(index: int) -> void:
	var perspective_id: String = "spectator" if index == 0 else FACTION_IDS[index - 1]
	_set_perspective(perspective_id, true)


func _toggle_pause() -> void:
	live_paused = not live_paused
	pause_button.text = "RESUME" if live_paused else "PAUSE"
	pause_requested.emit(live_paused)


func _on_speed_selected(index: int) -> void:
	playback_speed = float(speed_select.get_item_metadata(index))
	playback_speed_requested.emit(playback_speed)


func _on_timeline_drag_ended(value_changed: bool) -> void:
	if value_changed and not _updating_timeline:
		timeline_seek_requested.emit(int(timeline_slider.value))


func _on_setup_start() -> void:
	var competitors: Array[Dictionary] = []
	for faction_id in FACTION_IDS:
		var model := str(model_inputs[faction_id].text).strip_edges()
		if model.is_empty():
			set_setup_status("Choose a model for every commander.", "error")
			return
		var reasoning: OptionButton = reasoning_inputs[faction_id]
		var advisors: OptionButton = advisor_inputs[faction_id]
		competitors.append({
			"agent_id": faction_id,
			"model": model,
			"reasoning_effort": reasoning.get_item_metadata(reasoning.selected),
			"max_specialists": int(advisors.get_item_metadata(advisors.selected))
		})
	var api_key := api_key_input.text.strip_edges()
	if not mock_mode and api_key.length() < 8:
		set_setup_status("Enter a valid API key. It is held in memory only.", "error")
		return
	var config := {
		"type": "configure_match",
		"protocol": "world-arena/0.4",
		"api_key": api_key,
		"brain_mode": "demo" if api_key.is_empty() else "openai",
		"mode": "demo",
		"track": "agentic",
		"map_id": str(scenario_select.get_item_metadata(scenario_select.selected)),
		"max_rounds": 120,
		"observation_mode": str(observation_select.get_item_metadata(observation_select.selected)),
		"agents": competitors
	}
	setup_submitted.emit(config)
	api_key_input.clear()
	api_key = ""
	if mock_mode and run_embedded_mock_on_submit:
		_start_mock_demo()
	else:
		set_setup_status("Opening the commander sessions…", "pending")


func _start_mock_demo() -> void:
	_mock_sequence_id += 1
	var sequence_id := _mock_sequence_id
	set_lobby_visible(false)
	_reset_events()
	configure_from_snapshot(_mock_snapshot())
	set_phase("thinking", {"sol": "thinking", "terra": "thinking", "luna": "thinking"})
	await get_tree().create_timer(0.8).timeout
	if sequence_id != _mock_sequence_id:
		return
	set_phase("thinking", {"sol": "locked", "terra": "thinking", "luna": "thinking"})
	await get_tree().create_timer(0.65).timeout
	if sequence_id != _mock_sequence_id:
		return
	set_phase("plans_locked", {"sol": "locked", "terra": "locked", "luna": "locked"})
	apply_events(_mock_diplomacy_events())
	await get_tree().create_timer(2.0).timeout
	if sequence_id != _mock_sequence_id:
		return
	set_phase("resolution", {"sol": "executing", "terra": "executing", "luna": "executing"})
	apply_events(_mock_resolution_events())
	await get_tree().create_timer(2.4).timeout
	if sequence_id != _mock_sequence_id:
		return
	var next_snapshot := _mock_snapshot()
	next_snapshot.round = 13
	next_snapshot.phase = "diplomacy"
	next_snapshot.sim_time = "03:15"
	for district in next_snapshot.districts:
		if district.id == "mine_st":
			district.owner = "sol"
			district.supplied = true
			district.contested = false
			district.capture_progress = 1.0
	configure_from_snapshot(next_snapshot)
	apply_events([{
		"event_id": "mock_009",
		"round": 13,
		"kind": "betrayal",
		"actor_id": "luna",
		"target_ids": ["sol"],
		"visibility": "public",
		"summary": "Luna ends the crossroads pact and raids Sol's exposed western supply line.",
		"pact_id": "pact_sol_luna_crossroads",
		"state": "betrayed"
	}])


func _reset_events() -> void:
	event_history.clear()
	event_ids.clear()
	_clear_bubbles()
	for child in timeline_markers.get_children():
		child.queue_free()
	_rebuild_feed()


func _mock_snapshot() -> Dictionary:
	return {
		"match_id": "mock_tri_13",
		"round": 12,
		"max_rounds": 120,
		"phase": "thinking",
		"sim_time": "03:00",
		"thinking_status": {"sol": "thinking", "terra": "thinking", "luna": "thinking"},
		"factions": [
			{
				"id": "sol", "model": "gpt-5.6-sol", "core_hp": 910, "land_percent": 39,
				"army_strength": 9, "state": "negotiating", "resources": {"food": 138, "wood": 62, "stone": 45, "iron": 26, "crystal": 3},
				"cognition": {"round_spent": 72, "round_budget": 100, "match_spent": 814},
				"strategic_intent": "Trade wood to Luna, contain Terra's iron lead, then defend the eastern stronghold road.",
				"orders": [{"action": "Build", "target": "mine_st"}, {"action": "Negotiate", "target": "luna"}, {"action": "Move", "target": "crossroads"}],
				"specialists": [
					{"role": "military", "state": "advice_ready", "disposition": "accepted", "recommendation_summary": "Hold Sunfall Mine instead of chasing Terra."},
					{"role": "diplomacy", "state": "advice_ready", "disposition": "modified", "recommendation_summary": "Offer Luna wood for one-round eastern pressure."}
				]
			},
			{
				"id": "terra", "model": "gpt-5.6-terra", "core_hp": 1000, "land_percent": 34,
				"army_strength": 11, "state": "expanding", "resources": {"food": 104, "wood": 48, "stone": 71, "iron": 44, "crystal": 0},
				"cognition": {"round_spent": 43, "round_budget": 100, "match_spent": 676},
				"strategic_intent": "Exploit the eastern mine advantage and pressure Sol's outer works before rivals coordinate.",
				"orders": [{"action": "Move", "target": "crossroads"}, {"action": "Build", "target": "home_terra"}],
				"specialists": [{"role": "economy", "state": "advice_ready", "disposition": "accepted", "recommendation_summary": "Convert the iron surplus into guards now."}]
			},
			{
			"id": "luna", "model": "gpt-5.6-luna", "core_hp": 870, "land_percent": 27,
				"army_strength": 7, "state": "scouting", "resources": {"food": 126, "wood": 31, "stone": 40, "iron": 13, "crystal": 9},
				"cognition": {"round_spent": 61, "round_budget": 100, "match_spent": 731},
				"strategic_intent": "Accept temporary support, reveal Terra's movement, and preserve a route to a late betrayal.",
				"orders": [{"action": "accept_trade", "target": "sol"}, {"action": "raid", "target": "mine_tl"}],
				"specialists": [{"role": "scout", "state": "advice_ready", "disposition": "accepted", "recommendation_summary": "Terra left Ember Mine lightly defended."}]
			}
		],
		"districts": [
			{"id": "core_sol", "owner": "sol", "supplied": true},
			{"id": "core_terra", "owner": "terra", "supplied": true},
			{"id": "core_luna", "owner": "luna", "supplied": true},
			{"id": "home_sol", "owner": "sol", "supplied": true},
			{"id": "home_terra", "owner": "terra", "supplied": true},
			{"id": "home_luna", "owner": "luna", "supplied": true},
			{"id": "mine_st", "owner": "sol", "supplied": false, "contested": true, "capture_progress": 0.65},
			{"id": "mine_tl", "owner": "terra", "supplied": true},
			{"id": "mine_ls", "owner": "luna", "supplied": true},
			{"id": "wild_st", "owner": "terra", "supplied": false},
			{"id": "wild_tl", "owner": "terra", "supplied": true},
			{"id": "wild_ls", "owner": "sol", "supplied": true},
			{"id": "crossroads", "owner": "neutral", "supplied": true, "contested": true, "capture_progress": 0.35}
		],
		"units": _mock_units(),
		"tasks": [
			{"id": "mock_sol_chop", "faction_id": "sol", "actor_id": "sol_worker_1", "kind": "gather", "resource": "wood", "state": "active", "completed_work": 6, "required_work": 10},
			{"id": "mock_terra_mine", "faction_id": "terra", "actor_id": "terra_worker_1", "kind": "gather", "resource": "iron", "state": "active", "completed_work": 3, "required_work": 10},
			{"id": "mock_luna_store", "faction_id": "luna", "district_id": "home_luna", "kind": "build", "structure": "storage", "state": "active", "completed_work": 14, "required_work": 24, "builder_ids": ["luna_worker_1"]}
		],
		"relationships": [
			{"id": "pact_sol_luna_crossroads", "actor_id": "sol", "target_id": "luna", "state": "pending", "summary": "Proposed coordinated pressure on the eastern road"}
		]
	}


func _mock_units() -> Array:
	return [
		{"id": "sol_commander", "faction_id": "sol", "unit_type": "commander", "district_id": "mine_st", "health": 132, "max_health": 150, "task": "negotiating"},
		{"id": "sol_worker_1", "faction_id": "sol", "unit_type": "worker", "district_id": "wild_ls", "health": 30, "max_health": 30, "task": "harvest wood"},
		{"id": "sol_worker_2", "faction_id": "sol", "unit_type": "worker", "district_id": "mine_st", "health": 24, "max_health": 30, "task": "repair outpost", "in_combat": true},
		{"id": "sol_guard_1", "faction_id": "sol", "unit_type": "guard", "district_id": "mine_st", "health": 92, "max_health": 110, "task": "defend", "in_combat": true},
		{"id": "terra_commander", "faction_id": "terra", "unit_type": "commander", "district_id": "crossroads", "health": 150, "max_health": 150, "task": "advance"},
		{"id": "terra_worker_1", "faction_id": "terra", "unit_type": "worker", "district_id": "mine_tl", "health": 30, "max_health": 30, "task": "mine iron"},
		{"id": "terra_guard_1", "faction_id": "terra", "unit_type": "guard", "district_id": "crossroads", "health": 110, "max_health": 110, "task": "hold crossroads", "in_combat": true},
		{"id": "terra_militia_1", "faction_id": "terra", "unit_type": "militia", "district_id": "mine_st", "health": 41, "max_health": 75, "task": "attack", "in_combat": true},
		{"id": "luna_commander", "faction_id": "luna", "unit_type": "commander", "district_id": "mine_ls", "health": 118, "max_health": 150, "task": "private channel"},
		{"id": "luna_scout_1", "faction_id": "luna", "unit_type": "scout", "district_id": "crossroads", "health": 40, "max_health": 40, "task": "inspect"},
		{"id": "luna_worker_1", "faction_id": "luna", "unit_type": "worker", "district_id": "home_luna", "health": 30, "max_health": 30, "task": "harvest food"},
		{"id": "luna_militia_1", "faction_id": "luna", "unit_type": "militia", "district_id": "mine_tl", "health": 69, "max_health": 75, "task": "raid"}
	]


func _mock_diplomacy_events() -> Array:
	return [
		{
			"event_id": "mock_001", "round": 12, "kind": "message", "actor_id": "sol", "target_ids": [],
			"visibility": "public", "summary": "Terra controls the iron route. Luna, this is the round to contain them."
		},
		{
			"event_id": "mock_002", "round": 12, "kind": "message", "actor_id": "luna", "target_ids": ["sol"],
			"visibility": "participants", "visible_to": ["sol", "luna"], "summary": "Send 20 wood now. I will pressure Ember Mine while you hold Sunfall."
		},
		{
			"event_id": "mock_003", "round": 12, "kind": "offer", "actor_id": "sol", "target_ids": ["luna"],
			"visibility": "participants", "visible_to": ["sol", "luna"], "summary": "20 wood for a coordinated attack on Terra's eastern road.",
			"state": "accepted", "payload": {"give": {"wood": 20}, "request": "attack_east_road", "state": "accepted"}
		},
		{
			"event_id": "mock_004", "round": 12, "kind": "pact", "actor_id": "sol", "target_ids": ["luna"],
			"visibility": "public", "summary": "Sol and Luna acknowledge a one-round crossroads coordination pact.",
			"pact_id": "pact_sol_luna_crossroads", "state": "acknowledged"
		}
	]


func _mock_resolution_events() -> Array:
	return [
		{
			"event_id": "mock_005", "round": 12, "kind": "trade", "actor_id": "sol", "target_ids": ["luna"],
			"visibility": "participants", "visible_to": ["sol", "luna"], "summary": "Atomic trade executed: Sol transfers 20 wood to Luna.", "state": "executed"
		},
		{
			"event_id": "mock_006", "round": 12, "kind": "combat", "actor_id": "terra", "target_ids": ["sol"],
			"visibility": "public", "summary": "Terra's militia collide with Sol's guard at Sunfall Mine."
		},
		{
			"event_id": "mock_007", "round": 12, "kind": "territory", "actor_id": "sol", "target_ids": [],
			"visibility": "public", "summary": "Sol stabilizes Sunfall Mine, but the district remains disconnected.",
			"payload": {"district_id": "mine_st", "district_state": {"owner": "sol", "supplied": false, "contested": true, "capture_progress": 0.82}}
		},
		{
			"event_id": "mock_008", "round": 12, "kind": "advisor", "actor_id": "luna", "target_ids": [],
			"visibility": "spectator", "summary": "Luna's Scout advisor identifies Sol's exposed western supply line."
		}
	]


func _records_by_id(value: Variant) -> Dictionary:
	var result: Dictionary = {}
	if value is Dictionary:
		for key in value:
			var record: Variant = value[key]
			if record is Dictionary:
				var copied: Dictionary = record.duplicate(true)
				if not copied.has("id"):
					copied.id = str(key)
				result[str(copied.id)] = copied
	else:
		for record_variant in _record_array(value):
			if record_variant is Dictionary:
				var record: Dictionary = record_variant
				var record_id := str(record.get("id", record.get("faction_id", "")))
				if not record_id.is_empty():
					result[record_id] = record
	return result


func _record_array(value: Variant) -> Array:
	if value is Array:
		return value
	if value is Dictionary:
		return value.values()
	return []


func _unit_position(state: Dictionary) -> Vector3:
	if state.has("position"):
		return _to_vector3(state.position) * COMPACT_MAP_SCALE
	var district_id := str(state.get("district_id", ""))
	var center: Vector3 = district_positions.get(district_id, Vector3.ZERO)
	var stable_hash := absi(str(state.get("id", "unit")).hash())
	var angle := float(stable_hash % 628) / 100.0
	var distance := 6.0 + float(stable_hash % 7)
	return center + Vector3(cos(angle) * distance, 0.45, sin(angle) * distance)


func _to_vector3(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	if value is Dictionary:
		return Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0)))
	return Vector3.ZERO


func _event_icon(kind: String, visibility_kind: String) -> String:
	match kind:
		"message": return "●" if visibility_kind == "public" else "◆"
		"offer", "trade": return "⇄"
		"pact": return "◇"
		"betrayal": return "⚡"
		"territory": return "⚑"
		"supply": return "⛓"
		"combat": return "×"
		"advisor": return "◎"
		"core": return "⬡"
		_: return "·"


func _phase_color(phase: String) -> Color:
	match phase:
		"diplomacy": return Color("70b8ff")
		"thinking": return Color("f4c95d")
		"plans_locked": return Color("9fe3d2")
		"resolution": return Color("ff7a70")
		"complete": return Color("fff3c4")
		_: return Color("a9c5c5")


func _status_text(status: String) -> String:
	match status.to_lower():
		"thinking": return "● REASONING"
		"locked": return "✓ LOCKED"
		"timeout": return "! TIMEOUT"
		"fallback": return "! FALLBACK"
		"executing": return "▶ ACTING"
		_: return "○ STANDBY"


func _status_color(status: String, faction_color: Color) -> Color:
	match status.to_lower():
		"thinking": return faction_color
		"locked": return Color("9fe3d2")
		"timeout", "fallback": return Color("ff7a70")
		"executing": return faction_color.lightened(0.2)
		_: return Color("7899a5")


func _phase_explanation(phase: String) -> String:
	match phase:
		"diplomacy": return "MESSAGES REVEALED — NEXT ROUND KNOWLEDGE"
		"thinking": return "MODELS REASON IN PARALLEL — NEXT ACTIONS ARE SEALED"
		"plans_locked": return "ALL PLANS LOCKED — SIMULTANEOUS REVEAL"
		"resolution": return "WORLD EXECUTES MOVEMENT, BUILDS, TRADES & CLASHES"
		"complete": return "MATCH COMPLETE — REPLAY READY"
		_: return "SHOWCASE REPLAY ACTIVE" if phase == "replay" else phase.replace("_", " ").to_upper()


func _panel_style(fill: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style


func _kenney_panel_style(fill: Color, border: Color, radius: int, margin: int) -> StyleBox:
	if ResourceLoader.exists(KENNEY_PANEL_TEXTURE):
		var style := StyleBoxTexture.new()
		style.texture = load(KENNEY_PANEL_TEXTURE)
		style.texture_margin_left = 16
		style.texture_margin_top = 16
		style.texture_margin_right = 16
		style.texture_margin_bottom = 16
		style.content_margin_left = margin
		style.content_margin_right = margin
		style.content_margin_top = margin
		style.content_margin_bottom = margin
		return style
	return _panel_style(fill, border, radius, margin)


func _kenney_button_style() -> StyleBox:
	if ResourceLoader.exists(KENNEY_BUTTON_TEXTURE):
		var style := StyleBoxTexture.new()
		style.texture = load(KENNEY_BUTTON_TEXTURE)
		style.texture_margin_left = 12
		style.texture_margin_top = 12
		style.texture_margin_right = 12
		style.texture_margin_bottom = 12
		return style
	return _panel_style(Color("79541f"), Color("c99842"), 5, 6)


func _section_label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color("69f0d0"))
	return label


func _caption(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color("6f9aaa"))
	return label


func _material(color: Color, emissive := false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.3
	return material


func _has_argument(argument: String) -> bool:
	return argument in OS.get_cmdline_user_args()
