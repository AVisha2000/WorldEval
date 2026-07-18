extends Node3D

const WORLD_SIZE := 500.0
const MAX_DAYS := 20
const SERVER_URL := "ws://127.0.0.1:8000/ws/world"
const AGENT_IDS := ["sol", "terra", "luna"]
const AGENT_NAMES := {"sol": "Sol", "terra": "Terra", "luna": "Luna"}
const AGENT_COLORS := {
	"sol": Color("f4c95d"),
	"terra": Color("ff7a70"),
	"luna": Color("70b8ff")
}
const AGENT_SPAWNS := {
	"sol": Vector3(-42, 2.1, 18),
	"terra": Vector3(45, 2.1, 28),
	"luna": Vector3(3, 2.1, -52)
}
const AgentBodyScript := preload("res://scripts/agent_body.gd")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")

var socket := WebSocketPeer.new()
var socket_state := WebSocketPeer.STATE_CLOSED
var hello_sent := false
var server_ready := false
var run_started := false
var action_in_progress := false
var pending_action: Dictionary = {}
var command_line_autostart := false
var capture_on_finish_path := ""

var day := 0
var turn := 0
var health := 100.0
var food := 50.0
var inventory := {"wood": 0, "stone": 0, "iron": 0, "crystal": 0}
var structures := {"shelter": 0, "farm": 0, "storage": 0, "wall": 0, "workshop": 0}
var last_event := "Sol entered an unknown world."
var collected_total := 0
var spent_total := 0
var active_agent_id := "sol"
var active_agent_index := 0
var agent_states: Dictionary = {}
var agents: Dictionary = {}
var configured_models: Dictionary = {}

var agent: ArenaAgentBody
var camera: Camera3D
var resource_nodes: Array[ArenaResourceNode] = []
var built_nodes: Array[Node3D] = []

var status_label: Label
var day_label: Label
var health_label: Label
var food_label: Label
var wood_label: Label
var stone_label: Label
var shelter_label: Label
var brain_label: Label
var agent_title: Label
var intent_label: Label
var action_label: Label
var event_label: Label
var start_button: Button
var end_panel: PanelContainer
var end_title: Label
var end_details: Label
var setup_overlay: Control
var setup_status: Label
var setup_start_button: Button
var api_key_input: LineEdit
var model_inputs: Dictionary = {}


func _ready() -> void:
	_build_world()
	_build_interface()
	_connect_backend()
	_schedule_capture_if_requested()


func _schedule_capture_if_requested() -> void:
	var timed_capture_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			timed_capture_path = argument.trim_prefix("--capture=")
		elif argument.begins_with("--capture-on-finish="):
			capture_on_finish_path = argument.trim_prefix("--capture-on-finish=")
			command_line_autostart = true
		elif argument == "--autostart":
			command_line_autostart = true
	if command_line_autostart:
		Engine.time_scale = 4.0
	if not timed_capture_path.is_empty():
		_capture_after_flyover(timed_capture_path)


func _capture_after_flyover(output_path: String) -> void:
	await get_tree().create_timer(4.6).timeout
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(output_path)
	if error != OK:
		push_error("Unable to save capture to %s" % output_path)
	get_tree().quit()


func _process(_delta: float) -> void:
	socket.poll()
	var current_state := socket.get_ready_state()
	if current_state != socket_state:
		socket_state = current_state
		_handle_socket_state(current_state)

	if current_state == WebSocketPeer.STATE_OPEN:
		while socket.get_available_packet_count() > 0:
			var raw := socket.get_packet().get_string_from_utf8()
			var message = JSON.parse_string(raw)
			if typeof(message) == TYPE_DICTIONARY:
				_handle_server_message(message)

	if camera:
		camera.look_at(Vector3(0, 2, 0), Vector3.UP)


func _connect_backend() -> void:
	_set_connection_status("CONNECTING TO BRAIN", Color("f4c95d"))
	var error := socket.connect_to_url(SERVER_URL)
	if error != OK:
		_set_connection_status("BACKEND UNAVAILABLE", Color("ff6b6b"))


func _handle_socket_state(state: WebSocketPeer.State) -> void:
	match state:
		WebSocketPeer.STATE_OPEN:
			_set_connection_status("BRAIN LINK ONLINE", Color("69f0d0"))
			if not hello_sent:
				hello_sent = true
				_send({"type": "hello", "client": "godot", "protocol": "genesis-arena/0.1"})
		WebSocketPeer.STATE_CLOSING:
			_set_connection_status("BRAIN LINK CLOSING", Color("f4c95d"))
		WebSocketPeer.STATE_CLOSED:
			if hello_sent:
				_set_connection_status("BRAIN LINK OFFLINE", Color("ff6b6b"))


func _handle_server_message(message: Dictionary) -> void:
	match str(message.get("type", "")):
		"connected":
			brain_label.text = str(message.get("brain", "brain"))
		"ready":
			server_ready = true
			brain_label.text = str(message.get("brain", "brain"))
			setup_start_button.disabled = false
			setup_status.text = "Backend online — choose the three competitors."
			intent_label.text = "Brain link ready. The world is waiting for an observer."
			if command_line_autostart:
				_on_start_pressed.call_deferred()
		"configured":
			configured_models = message.get("agents", {}).duplicate(true)
			brain_label.text = str(message.get("brain", "3 OpenAI competitors"))
			setup_status.text = "Configuration accepted. Starting arena…"
			setup_overlay.visible = false
			_on_start_pressed.call_deferred()
		"thinking":
			action_label.text = "THINKING"
			brain_label.text = str(message.get("brain", configured_models.get(active_agent_id, "brain")))
			intent_label.text = "%s is evaluating needs, resources, and future risk…" % AGENT_NAMES[active_agent_id]
			agent.set_activity("reasoning")
		"action_command":
			_begin_action(message)
		"error":
			action_in_progress = false
			action_label.text = "CONTROLLER ERROR"
			intent_label.text = str(message.get("error", "Unknown controller error"))
			if setup_overlay.visible:
				setup_status.text = "Configuration error: " + str(message.get("error", "unknown error"))
				setup_start_button.disabled = false


func _send(message: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(message))


func _new_agent_state() -> Dictionary:
	return {
		"health": 100.0,
		"food": 50.0,
		"inventory": {"wood": 0, "stone": 0, "iron": 0, "crystal": 0},
		"structures": {"shelter": 0, "farm": 0, "storage": 0, "wall": 0, "workshop": 0}
	}


func _save_active_state() -> void:
	agent_states[active_agent_id] = {
		"health": health,
		"food": food,
		"inventory": inventory.duplicate(true),
		"structures": structures.duplicate(true)
	}


func _load_active_state() -> void:
	var state: Dictionary = agent_states[active_agent_id]
	health = float(state["health"])
	food = float(state["food"])
	inventory = state["inventory"].duplicate(true)
	structures = state["structures"].duplicate(true)
	agent = agents[active_agent_id]


func _build_world() -> void:
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("08131c")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b9d7cf")
	environment.ambient_light_energy = 0.72
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment_node.environment = environment
	add_child(environment_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_color = Color("ffe2a8")
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-28, 145, 0)
	fill.light_color = Color("7cbad0")
	fill.light_energy = 0.42
	add_child(fill)

	var water_mesh := PlaneMesh.new()
	water_mesh.size = Vector2(WORLD_SIZE, WORLD_SIZE)
	var water := MeshInstance3D.new()
	water.mesh = water_mesh
	water.position.y = -2.15
	var water_material := StandardMaterial3D.new()
	water_material.albedo_color = Color(0.035, 0.26, 0.34, 0.88)
	water_material.metallic = 0.42
	water_material.roughness = 0.18
	water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.material_override = water_material
	add_child(water)

	var island_mesh := CylinderMesh.new()
	island_mesh.top_radius = 112
	island_mesh.bottom_radius = 120
	island_mesh.height = 4
	island_mesh.radial_segments = 96
	var island := MeshInstance3D.new()
	island.mesh = island_mesh
	var earth_material := StandardMaterial3D.new()
	earth_material.albedo_color = Color("315f45")
	earth_material.roughness = 0.96
	island.material_override = earth_material
	add_child(island)

	_add_river()
	_add_mountains()
	_add_resources()

	for agent_id in AGENT_IDS:
		var body: ArenaAgentBody = AgentBodyScript.new()
		body.configure(AGENT_NAMES[agent_id], AGENT_COLORS[agent_id])
		body.position = AGENT_SPAWNS[agent_id]
		body.destination_reached.connect(_on_agent_arrived.bind(agent_id))
		add_child(body)
		agents[agent_id] = body
		agent_states[agent_id] = _new_agent_state()
	agent = agents[active_agent_id]

	camera = Camera3D.new()
	camera.position = Vector3(168, 174, 168)
	camera.fov = 45
	add_child(camera)
	var camera_tween := create_tween().set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	camera_tween.tween_property(camera, "position", Vector3(108, 116, 120), 4.2)


func _add_river() -> void:
	var river_mesh := PlaneMesh.new()
	river_mesh.size = Vector2(18, 190)
	var river := MeshInstance3D.new()
	river.mesh = river_mesh
	river.position = Vector3(24, 2.08, 0)
	river.rotation.y = -0.12
	var river_material := StandardMaterial3D.new()
	river_material.albedo_color = Color(0.08, 0.48, 0.56, 0.9)
	river_material.metallic = 0.32
	river_material.roughness = 0.2
	river_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	river.material_override = river_material
	add_child(river)

	for z_position in [-78.0, -32.0, 18.0, 67.0]:
		var bridge_mesh := BoxMesh.new()
		bridge_mesh.size = Vector3(24, 0.55, 6)
		var bridge := MeshInstance3D.new()
		bridge.mesh = bridge_mesh
		bridge.position = Vector3(24, 2.6, z_position)
		bridge.rotation.y = -0.12
		var bridge_material := StandardMaterial3D.new()
		bridge_material.albedo_color = Color("856343")
		bridge_material.roughness = 0.92
		bridge.material_override = bridge_material
		add_child(bridge)


func _add_mountains() -> void:
	var peaks := [
		Vector3(-79, 0, -55), Vector3(-62, 0, -76), Vector3(-92, 0, -27),
		Vector3(76, 0, 56), Vector3(91, 0, 32)
	]
	for index in range(peaks.size()):
		var mountain_mesh := CylinderMesh.new()
		mountain_mesh.top_radius = 1.5
		mountain_mesh.bottom_radius = 13.0 + float(index % 3) * 3.0
		mountain_mesh.height = 24.0 + float(index % 2) * 12.0
		mountain_mesh.radial_segments = 9
		var mountain := MeshInstance3D.new()
		mountain.mesh = mountain_mesh
		mountain.position = peaks[index] + Vector3(0, mountain_mesh.height / 2.0 + 2.0, 0)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("52676a") if index % 2 == 0 else Color("465b58")
		material.roughness = 0.98
		mountain.material_override = material
		add_child(mountain)


func _add_resources() -> void:
	var trees := [
		Vector3(-30, 2.1, 18), Vector3(-40, 2.1, 3), Vector3(-48, 2.1, 27),
		Vector3(-25, 2.1, -9), Vector3(-58, 2.1, 10), Vector3(-44, 2.1, 44),
		Vector3(51, 2.1, -49), Vector3(66, 2.1, -36), Vector3(54, 2.1, -69)
	]
	for index in range(trees.size()):
		_add_resource("tree_%02d" % index, "wood", trees[index], 2, 4)

	var rocks := [
		Vector3(-7, 2.1, -25), Vector3(-18, 2.1, -35), Vector3(1, 2.1, -40),
		Vector3(61, 2.1, 30), Vector3(77, 2.1, 14)
	]
	for index in range(rocks.size()):
		_add_resource("rock_%02d" % index, "stone", rocks[index], 3, 2)

	var food_sources := [
		Vector3(-8, 2.1, 27), Vector3(7, 2.1, 36), Vector3(-22, 2.1, 44),
		Vector3(50, 2.1, 9), Vector3(70, 2.1, -4), Vector3(-68, 2.1, 59)
	]
	for index in range(food_sources.size()):
		_add_resource("berries_%02d" % index, "food", food_sources[index], 4, 18)


func _add_resource(id_value: String, kind: String, at: Vector3, count: int, amount: int) -> void:
	var node: ArenaResourceNode = ResourceNodeScript.new()
	node.position = at
	node.setup(id_value, kind, count, amount)
	add_child(node)
	resource_nodes.append(node)


func _build_interface() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var header := PanelContainer.new()
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_left = 22
	header.offset_top = 20
	header.offset_right = -22
	header.offset_bottom = 94
	header.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.073, 0.94), Color("254d58"), 18))
	root.add_child(header)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 18)
	header.add_child(header_row)

	var brand := Label.new()
	brand.text = "GENESIS  /  ARENA"
	brand.add_theme_font_size_override("font_size", 26)
	brand.add_theme_color_override("font_color", Color("fff3c4"))
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(brand)

	day_label = Label.new()
	day_label.text = "DAY 00 / 20"
	day_label.add_theme_font_size_override("font_size", 18)
	day_label.add_theme_color_override("font_color", Color("f4c95d"))
	header_row.add_child(day_label)

	status_label = Label.new()
	status_label.text = "CONNECTING TO BRAIN"
	status_label.add_theme_font_size_override("font_size", 14)
	status_label.add_theme_color_override("font_color", Color("f4c95d"))
	header_row.add_child(status_label)

	start_button = Button.new()
	start_button.text = "WAITING FOR BACKEND"
	start_button.disabled = true
	start_button.custom_minimum_size = Vector2(210, 44)
	start_button.add_theme_font_size_override("font_size", 14)
	start_button.pressed.connect(_on_start_pressed)
	header_row.add_child(start_button)

	var stats_panel := PanelContainer.new()
	stats_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	stats_panel.offset_left = 22
	stats_panel.offset_top = 112
	stats_panel.offset_right = 292
	stats_panel.offset_bottom = 414
	stats_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.073, 0.92), Color("1b3d49"), 16))
	root.add_child(stats_panel)
	var stats_box := VBoxContainer.new()
	stats_box.add_theme_constant_override("separation", 13)
	stats_panel.add_child(stats_box)
	agent_title = _section_title("SOL  /  COMPETITOR")
	stats_box.add_child(agent_title)
	health_label = _stat_row(stats_box, "HEALTH", "100")
	food_label = _stat_row(stats_box, "FOOD", "50")
	wood_label = _stat_row(stats_box, "WOOD", "0")
	stone_label = _stat_row(stats_box, "STONE", "0")
	shelter_label = _stat_row(stats_box, "SHELTERS", "0")
	stats_box.add_child(HSeparator.new())
	var model_caption := Label.new()
	model_caption.text = "BRAIN PROVIDER"
	model_caption.add_theme_font_size_override("font_size", 11)
	model_caption.add_theme_color_override("font_color", Color("6f9aaa"))
	stats_box.add_child(model_caption)
	brain_label = Label.new()
	brain_label.text = "awaiting link"
	brain_label.add_theme_font_size_override("font_size", 16)
	brain_label.add_theme_color_override("font_color", Color("69f0d0"))
	stats_box.add_child(brain_label)

	var event_panel := PanelContainer.new()
	event_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	event_panel.offset_left = -360
	event_panel.offset_top = 112
	event_panel.offset_right = -22
	event_panel.offset_bottom = 286
	event_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.073, 0.92), Color("1b3d49"), 16))
	root.add_child(event_panel)
	var event_box := VBoxContainer.new()
	event_box.add_theme_constant_override("separation", 10)
	event_panel.add_child(event_box)
	event_box.add_child(_section_title("WORLD EVENT STREAM"))
	event_label = Label.new()
	event_label.text = last_event
	event_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	event_label.add_theme_font_size_override("font_size", 15)
	event_label.add_theme_color_override("font_color", Color("c2d8d2"))
	event_box.add_child(event_label)

	var decision_panel := PanelContainer.new()
	decision_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	decision_panel.offset_left = -400
	decision_panel.offset_top = -182
	decision_panel.offset_right = 400
	decision_panel.offset_bottom = -24
	decision_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.018, 0.045, 0.06, 0.96), Color("2b6d72"), 18))
	root.add_child(decision_panel)
	var decision_box := VBoxContainer.new()
	decision_box.add_theme_constant_override("separation", 9)
	decision_panel.add_child(decision_box)
	var decision_header := HBoxContainer.new()
	decision_box.add_child(decision_header)
	var decision_title := _section_title("AGENT DECISION")
	decision_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	decision_header.add_child(decision_title)
	action_label = Label.new()
	action_label.text = "AWAITING START"
	action_label.add_theme_font_size_override("font_size", 14)
	action_label.add_theme_color_override("font_color", Color("f4c95d"))
	decision_header.add_child(action_label)
	intent_label = Label.new()
	intent_label.text = "The brain observes semantic state. Godot executes physical reality."
	intent_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intent_label.add_theme_font_size_override("font_size", 20)
	intent_label.add_theme_color_override("font_color", Color("edf7ed"))
	decision_box.add_child(intent_label)

	end_panel = PanelContainer.new()
	end_panel.set_anchors_preset(Control.PRESET_CENTER)
	end_panel.offset_left = -330
	end_panel.offset_top = -180
	end_panel.offset_right = 330
	end_panel.offset_bottom = 180
	end_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.018, 0.045, 0.06, 0.98), Color("f4c95d"), 24))
	end_panel.visible = false
	root.add_child(end_panel)
	var end_box := VBoxContainer.new()
	end_box.alignment = BoxContainer.ALIGNMENT_CENTER
	end_box.add_theme_constant_override("separation", 22)
	end_panel.add_child(end_box)
	end_title = Label.new()
	end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_title.add_theme_font_size_override("font_size", 36)
	end_title.add_theme_color_override("font_color", Color("fff3c4"))
	end_box.add_child(end_title)
	end_details = Label.new()
	end_details.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_details.add_theme_font_size_override("font_size", 19)
	end_details.add_theme_color_override("font_color", Color("c2d8d2"))
	end_box.add_child(end_details)

	_build_setup_overlay(root)


func _build_setup_overlay(root: Control) -> void:
	setup_overlay = Control.new()
	setup_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	setup_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(setup_overlay)

	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.015, 0.035, 0.05, 0.97)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	setup_overlay.add_child(shade)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -390
	panel.offset_top = -340
	panel.offset_right = 390
	panel.offset_bottom = 340
	panel.add_theme_stylebox_override("panel", _panel_style(Color("071923"), Color("2b6d72"), 24))
	setup_overlay.add_child(panel)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 13)
	panel.add_child(content)

	var eyebrow := Label.new()
	eyebrow.text = "WORLD ARENA  /  MATCH SETUP"
	eyebrow.add_theme_font_size_override("font_size", 13)
	eyebrow.add_theme_color_override("font_color", Color("69f0d0"))
	content.add_child(eyebrow)

	var title := Label.new()
	title.text = "Choose the minds entering the arena."
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("fff3c4"))
	content.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Each competitor gets an independent OpenAI brain. The engine controls movement, resources, construction, and consequences."
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_font_size_override("font_size", 15)
	subtitle.add_theme_color_override("font_color", Color("a9c5c5"))
	content.add_child(subtitle)

	content.add_child(_setup_caption("OPENAI API KEY  ·  STORED LOCALLY ONLY"))
	api_key_input = LineEdit.new()
	api_key_input.placeholder_text = "sk-proj-…"
	api_key_input.secret = true
	api_key_input.secret_character = "•"
	api_key_input.text = OS.get_environment("OPENAI_API_KEY")
	api_key_input.custom_minimum_size = Vector2(0, 44)
	api_key_input.add_theme_font_size_override("font_size", 15)
	content.add_child(api_key_input)

	var defaults := {
		"sol": "gpt-5.6-sol",
		"terra": "gpt-5.6-terra",
		"luna": "gpt-5.6-terra"
	}
	for agent_id in AGENT_IDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		content.add_child(row)
		var identity := Label.new()
		identity.text = AGENT_NAMES[agent_id].to_upper()
		identity.custom_minimum_size = Vector2(92, 42)
		identity.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		identity.add_theme_font_size_override("font_size", 15)
		identity.add_theme_color_override("font_color", AGENT_COLORS[agent_id])
		row.add_child(identity)
		var model_input := LineEdit.new()
		model_input.text = defaults[agent_id]
		model_input.placeholder_text = "OpenAI model ID"
		model_input.custom_minimum_size = Vector2(0, 42)
		model_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		model_input.add_theme_font_size_override("font_size", 15)
		row.add_child(model_input)
		model_inputs[agent_id] = model_input

	setup_status = Label.new()
	setup_status.text = "Connecting to the local arena controller…"
	setup_status.add_theme_font_size_override("font_size", 13)
	setup_status.add_theme_color_override("font_color", Color("f4c95d"))
	content.add_child(setup_status)

	setup_start_button = Button.new()
	setup_start_button.text = "START 3-AGENT SIMULATION"
	setup_start_button.disabled = true
	setup_start_button.custom_minimum_size = Vector2(0, 52)
	setup_start_button.add_theme_font_size_override("font_size", 16)
	setup_start_button.pressed.connect(_on_configure_pressed)
	content.add_child(setup_start_button)


func _setup_caption(value: String) -> Label:
	var caption := Label.new()
	caption.text = value
	caption.add_theme_font_size_override("font_size", 11)
	caption.add_theme_color_override("font_color", Color("6f9aaa"))
	return caption


func _panel_style(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 17
	style.content_margin_bottom = 17
	return style


func _section_title(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color("69f0d0"))
	return label


func _stat_row(parent: VBoxContainer, caption: String, value: String) -> Label:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var name_node := Label.new()
	name_node.text = caption
	name_node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_node.add_theme_font_size_override("font_size", 13)
	name_node.add_theme_color_override("font_color", Color("7899a5"))
	row.add_child(name_node)
	var value_node := Label.new()
	value_node.text = value
	value_node.add_theme_font_size_override("font_size", 19)
	value_node.add_theme_color_override("font_color", Color("edf7ed"))
	row.add_child(value_node)
	return value_node


func _set_connection_status(value: String, color: Color) -> void:
	if status_label:
		status_label.text = "●  " + value
		status_label.add_theme_color_override("font_color", color)


func _on_configure_pressed() -> void:
	if not server_ready:
		setup_status.text = "The local backend is not connected yet."
		return
	var api_key := api_key_input.text.strip_edges()
	if api_key.length() < 8:
		setup_status.text = "Enter an OpenAI API key to start the live match."
		return
	var competitors: Array[Dictionary] = []
	for agent_id in AGENT_IDS:
		var model := str(model_inputs[agent_id].text).strip_edges()
		if model.is_empty():
			setup_status.text = "Choose a model for every competitor."
			return
		competitors.append({
			"agent_id": agent_id,
			"model": model,
			"reasoning_effort": "medium" if agent_id == "sol" else "low"
		})
	setup_start_button.disabled = true
	setup_status.text = "Creating three independent agent brains…"
	_send({"type": "configure", "api_key": api_key, "agents": competitors})


func _on_start_pressed() -> void:
	if not server_ready or run_started:
		return
	run_started = true
	start_button.disabled = true
	start_button.text = "BENCHMARK RUNNING"
	action_label.text = "OBSERVING"
	intent_label.text = "%s receives the first world observation." % AGENT_NAMES[active_agent_id]
	agent.set_activity("observing")
	_send_observation()


func _send_observation() -> void:
	if not run_started or action_in_progress or day >= MAX_DAYS or health <= 0:
		return
	var visible_resources: Array[Dictionary] = []
	for resource in resource_nodes:
		if resource.quantity <= 0 or not resource.visible:
			continue
		var distance := agent.global_position.distance_to(resource.global_position)
		if distance <= 155:
			visible_resources.append({
				"id": resource.resource_id,
				"kind": resource.kind,
				"distance": snappedf(distance, 0.1),
				"direction": _cardinal_direction(resource.global_position - agent.global_position),
				"quantity": resource.quantity
			})

	var observation := {
		"type": "observation",
		"turn": turn,
		"day": day,
		"max_days": MAX_DAYS,
		"agent_id": active_agent_id,
		"agent": {
			"health": health,
			"food": food,
			"inventory": inventory,
			"structures": structures,
			"technology": 0,
			"population": 1
		},
		"visible_resources": visible_resources,
		"visible_world": [
			{"type": "river", "distance": snappedf(agent.global_position.distance_to(Vector3(24, 2.1, 0)), 0.1)},
			{"type": "mountains", "direction": "north-west"},
			{"type": "camp", "owner": active_agent_id, "sheltered": structures["shelter"] > 0},
			{"type": "competitors", "agents": AGENT_IDS, "active_agent": active_agent_id}
		],
		"events": [last_event],
		"available_actions": ["collect", "build", "inspect", "rest"]
	}
	_send(observation)


func _cardinal_direction(offset: Vector3) -> String:
	if abs(offset.x) > abs(offset.z):
		return "east" if offset.x > 0 else "west"
	return "south" if offset.z > 0 else "north"


func _begin_action(message: Dictionary) -> void:
	if action_in_progress or not run_started:
		return
	action_in_progress = true
	pending_action = message.duplicate(true)
	var action := str(message.get("action", ""))
	var parameters: Dictionary = message.get("parameters", {})
	intent_label.text = str(message.get("intent", "No intent supplied"))
	action_label.text = action.to_upper()

	match action:
		"collect":
			var kind := str(parameters.get("resource", ""))
			var target := _nearest_resource(kind)
			if target == null:
				_complete_action(false, "Collection failed: no %s source remained." % kind)
				return
			pending_action["target"] = target
			agent.walk_to(target.global_position, "walking to " + kind)
		"build":
			var structure := str(parameters.get("structure", ""))
			if not _can_afford(structure):
				_complete_action(false, "Construction failed: the required materials were unavailable.")
				return
			var build_site := _next_build_site()
			pending_action["build_site"] = build_site
			agent.walk_to(build_site, "moving to build site")
		"inspect":
			var area := str(parameters.get("area", "camp"))
			agent.walk_to(_inspection_point(area), "scouting " + area)
		"rest":
			agent.set_activity("recovering")
			_resolve_rest()
		_:
			_complete_action(false, "The world rejected an unknown action.")


func _nearest_resource(kind: String) -> ArenaResourceNode:
	var nearest: ArenaResourceNode = null
	var nearest_distance := INF
	for resource in resource_nodes:
		if resource.kind != kind or resource.quantity <= 0 or not resource.visible:
			continue
		var distance := agent.global_position.distance_to(resource.global_position)
		if distance < nearest_distance:
			nearest = resource
			nearest_distance = distance
	return nearest


func _inspection_point(area: String) -> Vector3:
	match area:
		"north": return Vector3(-4, 2.1, -69)
		"east": return Vector3(76, 2.1, 2)
		"south": return Vector3(3, 2.1, 73)
		"west": return Vector3(-73, 2.1, 4)
		_: return Vector3(-13, 2.1, 10)


func _next_build_site() -> Vector3:
	var index := built_nodes.size()
	var angle := float(index) * 1.35
	var spawn: Vector3 = AGENT_SPAWNS[active_agent_id]
	return spawn + Vector3(cos(angle) * (11 + index * 1.2), 0, sin(angle) * (11 + index * 1.2))


func _on_agent_arrived(agent_id: String) -> void:
	if agent_id != active_agent_id:
		return
	if pending_action.is_empty():
		return
	match str(pending_action.get("action", "")):
		"collect": _resolve_collection()
		"build": _resolve_construction()
		"inspect": _resolve_inspection()


func _resolve_collection() -> void:
	agent.set_activity("gathering")
	await get_tree().create_timer(0.75).timeout
	var target: ArenaResourceNode = pending_action.get("target")
	if target == null or target.quantity <= 0:
		_complete_action(false, "The resource was depleted before %s arrived." % AGENT_NAMES[active_agent_id])
		return
	var amount := target.harvest_once()
	if target.kind == "food":
		food = min(100.0, food + float(amount))
	else:
		inventory[target.kind] = int(inventory.get(target.kind, 0)) + amount
	collected_total += amount
	_complete_action(true, "Collected %d %s; the source now holds %d gathering units." % [amount, target.kind, target.quantity])


func _resolve_construction() -> void:
	var parameters: Dictionary = pending_action.get("parameters", {})
	var structure := str(parameters.get("structure", "shelter"))
	if not _can_afford(structure):
		_complete_action(false, "Construction failed because materials changed during travel.")
		return
	agent.set_activity("constructing " + structure)
	_pay_cost(structure)
	var site: Vector3 = pending_action.get("build_site", agent.global_position)
	var structure_node := _create_structure(structure, site)
	structure_node.scale = Vector3(0.08, 0.08, 0.08)
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(structure_node, "scale", Vector3.ONE, 1.25)
	await tween.finished
	structures[structure] = int(structures.get(structure, 0)) + 1
	built_nodes.append(structure_node)
	_complete_action(true, "Built %s. The world now contains a new permanent structure." % structure)


func _resolve_inspection() -> void:
	agent.set_activity("inspecting terrain")
	await get_tree().create_timer(0.65).timeout
	var parameters: Dictionary = pending_action.get("parameters", {})
	var area := str(parameters.get("area", "camp"))
	_complete_action(true, "Inspected the %s sector and updated the local resource view." % area)


func _resolve_rest() -> void:
	await get_tree().create_timer(1.0).timeout
	var recovery := 12.0 if int(structures["shelter"]) > 0 else 5.0
	health = min(100.0, health + recovery)
	_complete_action(true, "Recovered %.0f health%s." % [recovery, " under shelter" if int(structures["shelter"]) > 0 else " in the open"])


func _cost_for(structure: String) -> Dictionary:
	match structure:
		"shelter": return {"wood": 12, "stone": 4}
		"farm": return {"wood": 8, "stone": 2}
		"storage": return {"wood": 10, "stone": 4}
		"wall": return {"wood": 6, "stone": 6}
		"workshop": return {"wood": 15, "stone": 10}
		_: return {}


func _can_afford(structure: String) -> bool:
	var cost := _cost_for(structure)
	if cost.is_empty():
		return false
	for resource in cost:
		if int(inventory.get(resource, 0)) < int(cost[resource]):
			return false
	return true


func _pay_cost(structure: String) -> void:
	var cost := _cost_for(structure)
	for resource in cost:
		inventory[resource] = int(inventory.get(resource, 0)) - int(cost[resource])
		spent_total += int(cost[resource])


func _create_structure(kind: String, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "%s_%02d" % [kind, built_nodes.size()]
	root.position = at
	add_child(root)

	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color("a17245")
	timber.roughness = 0.9
	var dark_timber := StandardMaterial3D.new()
	dark_timber.albedo_color = Color("563d32")
	dark_timber.roughness = 0.94
	var field_material := StandardMaterial3D.new()
	field_material.albedo_color = Color("735a34")
	field_material.roughness = 1.0

	if kind == "farm":
		var field := BoxMesh.new()
		field.size = Vector3(10, 0.35, 8)
		_add_structure_mesh(root, field, field_material, Vector3(0, 0.2, 0))
		for row_index in range(4):
			var row := BoxMesh.new()
			row.size = Vector3(0.45, 0.32, 7)
			_add_structure_mesh(root, row, timber, Vector3(-3 + row_index * 2, 0.55, 0))
	elif kind == "wall":
		var wall := BoxMesh.new()
		wall.size = Vector3(10, 4.5, 1.2)
		_add_structure_mesh(root, wall, dark_timber, Vector3(0, 2.25, 0))
	else:
		var body := BoxMesh.new()
		body.size = Vector3(7.5, 4.2, 6.5)
		_add_structure_mesh(root, body, timber, Vector3(0, 2.1, 0))
		var roof := PrismMesh.new()
		roof.size = Vector3(8.7, 3.0, 7.5)
		_add_structure_mesh(root, roof, dark_timber, Vector3(0, 5.05, 0))
		var door := BoxMesh.new()
		door.size = Vector3(1.6, 2.8, 0.25)
		_add_structure_mesh(root, door, dark_timber, Vector3(0, 1.4, -3.35))
	return root


func _add_structure_mesh(parent: Node3D, mesh: Mesh, material: Material, offset: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = offset
	parent.add_child(node)


func _complete_action(success: bool, event: String) -> void:
	last_event = "%s: %s" % [AGENT_NAMES[active_agent_id], event]
	event_label.text = ("✓  " if success else "!  ") + last_event
	turn += 1
	food = max(0.0, food - 4.0)

	if food <= 0:
		health = max(0.0, health - 9.0)
		last_event += " Starvation caused 9 health damage."
	elif int(structures["shelter"]) == 0:
		health = max(0.0, health - 1.5)
	else:
		health = min(100.0, health + 0.5)

	_save_active_state()
	pending_action.clear()
	action_in_progress = false
	agent.set_activity("awaiting observation")
	_advance_agent()
	_update_hud()

	if _all_agents_defeated():
		_finish_run(false)
	elif day >= MAX_DAYS:
		_finish_run(true)
	else:
		await get_tree().create_timer(0.75).timeout
		_send_observation()


func _advance_agent() -> void:
	for _attempt in range(AGENT_IDS.size()):
		active_agent_index = (active_agent_index + 1) % AGENT_IDS.size()
		if active_agent_index == 0:
			day += 1
		active_agent_id = AGENT_IDS[active_agent_index]
		_load_active_state()
		if health > 0:
			return


func _all_agents_defeated() -> bool:
	for agent_id in AGENT_IDS:
		if float(agent_states[agent_id]["health"]) > 0:
			return false
	return true


func _update_hud() -> void:
	day_label.text = "DAY %02d / %02d" % [day, MAX_DAYS]
	agent_title.text = "%s  /  COMPETITOR" % AGENT_NAMES[active_agent_id].to_upper()
	agent_title.add_theme_color_override("font_color", AGENT_COLORS[active_agent_id])
	health_label.text = "%d" % roundi(health)
	food_label.text = "%d" % roundi(food)
	wood_label.text = str(inventory["wood"])
	stone_label.text = str(inventory["stone"])
	shelter_label.text = str(structures["shelter"])
	health_label.add_theme_color_override("font_color", Color("ff6b6b") if health < 35 else Color("edf7ed"))
	food_label.add_theme_color_override("font_color", Color("f4c95d") if food < 30 else Color("edf7ed"))


func _finish_run(survived: bool) -> void:
	run_started = false
	start_button.text = "BENCHMARK COMPLETE"
	action_label.text = "RUN COMPLETE"
	end_panel.visible = true
	if survived:
		var winner := _winner_agent()
		end_title.text = "%s WINS" % AGENT_NAMES[winner].to_upper()
		end_details.text = "20 days of three-agent competition completed\n\n%s used %s\n%d resources gathered across the arena\n\nIntelligence measured through consequences." % [AGENT_NAMES[winner], configured_models.get(winner, "the configured brain"), collected_total]
	else:
		end_title.text = "NO AGENT SURVIVED"
		end_details.text = "The world defeated all three competitors by day %d.\n\nEvery failed strategy remains evaluation evidence." % day
	if not capture_on_finish_path.is_empty():
		_capture_finished_run()


func _winner_agent() -> String:
	var winner := AGENT_IDS[0]
	var best_score := -INF
	for agent_id in AGENT_IDS:
		var state: Dictionary = agent_states[agent_id]
		var state_inventory: Dictionary = state["inventory"]
		var state_structures: Dictionary = state["structures"]
		var score := float(state["health"]) + float(state["food"])
		for value in state_inventory.values():
			score += float(value)
		for value in state_structures.values():
			score += float(value) * 20.0
		if score > best_score:
			best_score = score
			winner = agent_id
	return winner


func _capture_finished_run() -> void:
	await get_tree().create_timer(0.4).timeout
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(capture_on_finish_path)
	if error != OK:
		push_error("Unable to save completed-run capture to %s" % capture_on_finish_path)
	get_tree().quit()
