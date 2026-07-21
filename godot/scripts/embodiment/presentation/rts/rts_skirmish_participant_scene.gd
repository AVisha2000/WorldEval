class_name EmbodimentRtsSkirmishParticipantScene
extends Node3D

## Participant-only presentation for rts-skirmish-v0.
##
## The scene deliberately knows only the public task theme and the current participant's already
## filtered source/observation. It never imports authority code, reads checkpoints, or creates a
## rival object from an unprojected roster. Terrain dressing is immutable; every town hall, worker,
## unit, resource, return point, barracks, tower, health bar, and victory state is created only
## when its corresponding visible source entity is supplied.

const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")
const EntrantPalette := preload("res://scripts/embodiment/presentation/entrant_palette.gd")
const GRASS_TEXTURE_PATH := "res://assets/terrain/frontier/frontier-grass-v1.png"
const WATER_TEXTURE_PATH := "res://assets/terrain/frontier/frontier-water-v1.png"
const TEAM_COLORS := {"blue": Color("39a9ff"), "red": Color("f05262")}
const TEAM_NAMES := {"blue": "BLUE", "red": "RED"}
const KNOWN_KINDS := ["town_hall", "resource_wood", "resource_ore", "return_point", "central_beacon", "barracks", "tower", "worker", "unit", "operator"]
const HEADINGS_MILLI := [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000]

var _participant_id := "participant_0"
var _team_id := "blue"
var _operator: Node3D
var _entity_root: Node3D
var _camera_anchor: Node3D
var _entities := {}
var _hud: RichTextLabel
var _victory: Label
var _last_snapshot := {}


func _process(delta: float) -> void:
	# Render-only easing between authority boundaries. It neither changes nor reports game state:
	# all targets were already supplied by the participant-filtered source at a boundary.
	if _operator == null:
		return
	_smooth_motion(_operator, delta)
	for entity: Variant in _entities.values():
		if entity is Node3D and is_instance_valid(entity):
			_smooth_motion(entity, delta)
	_camera_anchor.position = _operator.position
	_camera_anchor.rotation.y = _operator.rotation.y


func _ready() -> void:
	_build()


func configure_participant(participant_id: String, team_id: String = "blue") -> bool:
	if participant_id.is_empty() or team_id not in TEAM_COLORS:
		return false
	_participant_id = participant_id
	_team_id = team_id
	if _operator != null:
		_apply_team(_operator, _team_id)
	return true


func participant_camera(participant_id: String) -> Camera3D:
	if participant_id != _participant_id or _camera_anchor == null:
		return null
	return _camera_anchor.get_node_or_null("ParticipantBroadcastCamera") as Camera3D


func apply_participant_projection(source: Dictionary, observation: Dictionary) -> bool:
	_build()
	if source.get("participant_id") != _participant_id \
		or (observation.has("participant_id") and observation.get("participant_id") != _participant_id) \
		or not source.get("operator") is Dictionary or not source.get("visible_entities") is Array \
		or not observation.get("visible_entities") is Array:
		return false
	var operator_source: Dictionary = source.operator
	var position: Variant = _position(operator_source.get("position_mt"))
	var heading := int(operator_source.get("heading", -1))
	if position == null or heading < 0 or heading > 7:
		return false
	_update_operator(operator_source, position, heading)
	var semantic_ids := {}
	for semantic: Variant in observation.visible_entities:
		if semantic is Dictionary and semantic.get("id") is String:
			semantic_ids[str(semantic.id)] = semantic
	var seen := {}
	for raw: Variant in source.visible_entities:
		if not raw is Dictionary:
			return false
		var entity: Dictionary = raw
		var entity_id := str(entity.get("id", ""))
		var kind := str(entity.get("kind", ""))
		if entity_id.is_empty() or kind not in KNOWN_KINDS or not semantic_ids.has(entity_id):
			return false
		var entity_position: Variant = _position(entity.get("position_mt"))
		var entity_heading := int(entity.get("heading", 0))
		if entity_position == null or entity_heading < 0 or entity_heading > 7:
			return false
		var projection: Node3D = _entities.get(entity_id)
		if projection == null:
			projection = _entity_projection(entity_id, kind)
			_entity_root.add_child(projection)
			_entities[entity_id] = projection
		_update_entity(projection, entity, semantic_ids[entity_id], entity_position, entity_heading)
		seen[entity_id] = true
	# `own` is part of the participant's ordinary presentation source. It can make a friendly
	# structure legible even when it is behind the camera; it never imports the rival's structures.
	if source.get("own") is Dictionary:
		for own_entity: Dictionary in _own_entities(source.own):
			var own_position: Variant = _position(own_entity.position_mt)
			if own_position == null:
				continue
			var own_id := str(own_entity.id)
			var own_node: Node3D = _entities.get(own_id)
			if own_node == null:
				own_node = _entity_projection(own_id, str(own_entity.kind))
				_entity_root.add_child(own_node)
				_entities[own_id] = own_node
			_update_entity(own_node, own_entity, own_entity, own_position, 0)
			seen[own_id] = true
	for entity_id: String in _entities.keys():
		if not seen.has(entity_id):
			var stale: Node3D = _entities[entity_id]
			_entities.erase(entity_id)
			stale.queue_free()
	_update_hud(observation, operator_source)
	_last_snapshot = {
		"episode_id": observation.get("episode_id", ""), "observation_seq": observation.get("observation_seq", -1),
		"participant_id": _participant_id, "task_id": "rts-skirmish-v0", "tick": observation.get("tick", -1),
		"operator": operator_source.duplicate(true), "visible_entities": source.visible_entities.duplicate(true),
	}
	return true


func snapshot_copy() -> Dictionary:
	return _last_snapshot.duplicate(true)


func _build() -> void:
	if _operator != null:
		return
	_build_forest_map()
	_entity_root = Node3D.new()
	_entity_root.name = "ParticipantVisibleRtsEntities"
	add_child(_entity_root)
	_operator = _instantiate_y_bot()
	_operator.name = "ParticipantCommander"
	add_child(_operator)
	_apply_team(_operator, _team_id)
	_camera_anchor = Node3D.new()
	_camera_anchor.name = "ParticipantBroadcastCameraAnchor"
	_camera_anchor.set_meta("presentation_only", true)
	add_child(_camera_anchor)
	var camera := Camera3D.new()
	camera.name = "ParticipantBroadcastCamera"
	camera.position = Vector3(0.0, 20.0, 20.0)
	camera.rotation_degrees = Vector3(-46.0, 0.0, 0.0)
	camera.fov = 50.0
	camera.near = 0.1
	camera.far = 90.0
	camera.current = true
	camera.set_meta("presentation_only", true)
	_camera_anchor.add_child(camera)
	_build_hud()


func _build_forest_map() -> void:
	var map := Node3D.new()
	map.name = "FrontierForestMap"
	add_child(map)
	var ground := _box("TexturedGrassland", Vector3(34.0, 0.18, 34.0), Color("214d2d"), _texture(GRASS_TEXTURE_PATH))
	ground.position.y = -0.12
	map.add_child(ground)
	var river := _box("ForestRiver", Vector3(4.2, 0.04, 34.0), Color("3b86a1"), _texture(WATER_TEXTURE_PATH))
	river.position.y = 0.02
	map.add_child(river)
	for bridge_z: float in [-7.0, 0.0, 7.0]:
		var bridge := _box("Bridge_%s" % str(bridge_z).replace("-", "N").replace(".", "_"), Vector3(4.8, 0.2, 1.25), Color("9c6a40"))
		bridge.position = Vector3(0.0, 0.16, bridge_z)
		map.add_child(bridge)
	for index: int in 18:
		var side := -1.0 if index % 2 == 0 else 1.0
		var row := float(index / 2)
		var tree := _tree("ForestTree_%02d" % index, Vector3(side * (11.2 + float(index % 3) * 1.45), 0.0, -13.5 + row * 3.0), index)
		map.add_child(tree)
	for index: int in 8:
		var rock := _rock("ForestRock_%02d" % index, Vector3(-9.0 + float(index) * 2.55, 0.0, -11.0 if index % 2 == 0 else 11.0), index)
		map.add_child(rock)
	var sun := DirectionalLight3D.new()
	sun.name = "FrontierSun"
	sun.rotation_degrees = Vector3(-54.0, -35.0, 0.0)
	sun.light_color = Color("ffe5b5")
	sun.light_energy = 0.8
	sun.shadow_enabled = true
	map.add_child(sun)
	var world := WorldEnvironment.new()
	world.name = "FrontierAtmosphere"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("5b8eae")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b5d7bd")
	environment.ambient_light_energy = 0.42
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 0.62
	world.environment = environment
	map.add_child(world)


func _update_operator(source: Dictionary, position: Vector2i, heading: int) -> void:
	_set_motion_target(_operator, _world(position), -float(HEADINGS_MILLI[heading]) * PI / 4000.0)
	var state := str(source.get("animation_state", "idle"))
	_operator.call("play_state", StringName(_animation(state)))


func _entity_projection(entity_id: String, kind: String) -> Node3D:
	if kind in ["worker", "unit", "operator"]:
		var avatar := _instantiate_y_bot()
		avatar.name = "Visible_%s" % entity_id.replace("-", "_")
		return avatar
	var root := Node3D.new()
	root.name = "Visible_%s" % entity_id.replace("-", "_")
	match kind:
		"town_hall": _build_town_hall(root)
		"resource_wood": _build_wood(root)
		"resource_ore": _build_ore(root)
		"return_point", "central_beacon": _build_return_point(root)
		"barracks": _build_barracks(root)
		"tower": _build_tower(root)
	_add_label(root, kind.to_upper(), Color("e2e8f0"), 2.45)
	return root


func _update_entity(node: Node3D, source: Dictionary, semantic: Dictionary, position: Vector2i, heading: int) -> void:
	_set_motion_target(node, _world(position), -float(HEADINGS_MILLI[heading]) * PI / 4000.0)
	var kind := str(source.kind)
	var team := _team_for(source, kind)
	if kind in ["worker", "unit", "operator"]:
		_apply_team(node, team)
		node.call("play_state", StringName(_animation(str(source.get("animation_state", semantic.get("state", "idle"))))))
	elif kind in ["town_hall", "barracks", "tower", "return_point", "central_beacon"]:
		_tint_building(node, team)
	_update_health(node, semantic)
	var label := node.get_node_or_null("StateLabel") as Label3D
	if label != null:
		label.text = "%s\n%s" % [TEAM_NAMES.get(team, kind.to_upper()), str(semantic.get("state", "active")).to_upper().replace("_", " ")]
		label.modulate = TEAM_COLORS.get(team, Color("e2e8f0"))


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "RtsSkirmishHUD"
	add_child(layer)
	var panel := ColorRect.new()
	panel.name = "CommandPanel"
	panel.position = Vector2(20.0, 20.0)
	panel.size = Vector2(520.0, 146.0)
	panel.color = Color("101923d9")
	layer.add_child(panel)
	_hud = RichTextLabel.new()
	_hud.name = "CommandText"
	_hud.position = Vector2(16.0, 12.0)
	_hud.size = Vector2(488.0, 120.0)
	_hud.bbcode_enabled = true
	_hud.scroll_active = false
	_hud.add_theme_font_size_override("normal_font_size", 17)
	panel.add_child(_hud)
	_victory = Label.new()
	_victory.name = "VictoryBanner"
	_victory.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_victory.position = Vector2(350.0, 22.0)
	_victory.size = Vector2(580.0, 50.0)
	_victory.add_theme_font_size_override("font_size", 26)
	_victory.add_theme_color_override("font_color", Color("ffe29a"))
	_victory.visible = false
	layer.add_child(_victory)


func _update_hud(observation: Dictionary, operator_source: Dictionary) -> void:
	var self_state: Dictionary = observation.get("self", {})
	var health := clampi(int(self_state.get("health_percent", 100)), 0, 100)
	var state := _animation(str(operator_source.get("animation_state", "idle"))).to_upper()
	var visible := 0
	for entity: Variant in observation.get("visible_entities", []):
		if entity is Dictionary:
			visible += 1
	_hud.text = "[color=#%s][b]%s COMMAND[/b][/color]   [color=#9fb3c8]FRONTIER SKIRMISH[/color]\nHP %d%%   ACTION %s\n[b]OBJECTIVE[/b] Gather wood and ore, return resources, raise barracks and towers, then break the rival town hall.\n[color=#a7f3d0]IN VIEW[/color] %d participant-visible battlefield entities" % [TEAM_COLORS[_team_id].to_html(false), TEAM_NAMES[_team_id], health, state, visible]
	var terminal: Dictionary = observation.get("terminal", {})
	var outcome := str(terminal.get("outcome", "running"))
	_victory.visible = outcome not in ["", "running"]
	_victory.text = outcome.to_upper().replace("_", " ") if _victory.visible else ""


func _build_town_hall(root: Node3D) -> void:
	var base := _box("TownHallBase", Vector3(2.8, 1.2, 2.5), Color("8b664b"))
	base.position.y = 0.6
	root.add_child(base)
	var roof := _cylinder("TownHallRoof", 1.85, 0.9, Color("6d3142"), 4)
	roof.position.y = 1.65
	roof.rotation_degrees.y = 45.0
	root.add_child(roof)


func _build_wood(root: Node3D) -> void:
	for index: int in 3:
		var trunk := _cylinder("WoodTrunk%d" % index, 0.16, 1.25, Color("6d472e"), 6)
		trunk.position = Vector3(float(index - 1) * 0.38, 0.62, 0.0)
		root.add_child(trunk)
		var crown := _sphere("WoodCrown%d" % index, 0.5, Color("2e7041"))
		crown.position = trunk.position + Vector3(0.0, 0.82, 0.0)
		root.add_child(crown)


func _build_ore(root: Node3D) -> void:
	for index: int in 4:
		var shard := _cylinder("OreShard%d" % index, 0.26, 0.82, Color("7bb8ff"), 5)
		shard.position = Vector3(float(index % 2) * 0.36 - 0.18, 0.41, float(index / 2) * 0.36 - 0.18)
		shard.material_override = _emissive(Color("74b7ff"), 0.35)
		root.add_child(shard)


func _build_return_point(root: Node3D) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "ReturnRing"
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.9
	mesh.outer_radius = 1.1
	ring.mesh = mesh
	ring.position.y = 0.12
	ring.material_override = _emissive(Color("79e5ff"), 0.5)
	root.add_child(ring)


func _build_barracks(root: Node3D) -> void:
	var hall := _box("BarracksHall", Vector3(2.1, 1.1, 1.6), Color("73513d"))
	hall.position.y = 0.55
	root.add_child(hall)
	var roof := _box("BarracksRoof", Vector3(2.35, 0.35, 1.85), Color("573441"))
	roof.position.y = 1.28
	root.add_child(roof)


func _build_tower(root: Node3D) -> void:
	var tower := _cylinder("Tower", 0.52, 2.7, Color("9a8f82"), 8)
	tower.position.y = 1.35
	root.add_child(tower)
	var cap := _cylinder("TowerCap", 0.78, 0.42, Color("5b394a"), 6)
	cap.position.y = 2.9
	root.add_child(cap)


func _update_health(root: Node3D, semantic: Dictionary) -> void:
	var raw: Variant = semantic.get("health_percent", semantic.get("health", 100))
	if typeof(raw) != TYPE_INT:
		return
	var percent := clampi(int(raw), 0, 100)
	var bar := root.get_node_or_null("HealthBar") as MeshInstance3D
	if bar == null:
		bar = _box("HealthBar", Vector3(1.7, 0.08, 0.12), Color("47d16c"))
		bar.position = Vector3(0.0, 2.35, 0.0)
		root.add_child(bar)
	bar.scale.x = maxf(0.04, float(percent) / 100.0)
	bar.material_override = _simple_material(Color("47d16c").lerp(Color("ef5965"), 1.0 - float(percent) / 100.0))


func _team_for(source: Dictionary, kind: String) -> String:
	var candidate := str(source.get("presentation_team_id", source.get("team", ""))).to_lower()
	if candidate in TEAM_COLORS:
		return candidate
	return _team_id if kind != "operator" or str(source.get("id", "")) != "v_rival" else ("red" if _team_id == "blue" else "blue")


func _own_entities(own: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for structure: String in ["town_hall", "barracks", "tower"]:
		var value: Variant = own.get(structure)
		if not value is Dictionary or _position(value.get("position_mt")) == null:
			continue
		result.append({
			"id": "own_%s" % structure, "kind": structure,
			"position_mt": value.position_mt.duplicate(true), "heading": 0,
			"animation_state": "idle", "state": str(value.get("state", "unbuilt")),
			"health_percent": value.get("health_percent", 100), "presentation_team_id": _team_id,
		})
	return result


func _animation(value: String) -> String:
	var state := value.to_lower()
	return state if state in ["idle", "walk", "run", "attack", "guard", "hit", "defeat", "gather", "build"] else "idle"


func _set_motion_target(node: Node3D, position: Vector3, yaw: float) -> void:
	if not bool(node.get_meta("presentation_motion_initialized", false)):
		node.position = position
		node.rotation.y = yaw
		node.set_meta("presentation_motion_initialized", true)
	node.set_meta("presentation_target_position", position)
	node.set_meta("presentation_target_yaw", yaw)


func _smooth_motion(node: Node3D, delta: float) -> void:
	var target_position: Variant = node.get_meta("presentation_target_position", null)
	var target_yaw: Variant = node.get_meta("presentation_target_yaw", null)
	if target_position is Vector3:
		node.position = node.position.lerp(target_position, minf(1.0, delta * 9.0))
	if typeof(target_yaw) == TYPE_FLOAT:
		node.rotation.y = lerp_angle(node.rotation.y, float(target_yaw), minf(1.0, delta * 11.0))


func _apply_team(avatar: Node3D, team: String) -> void:
	var color: Color = TEAM_COLORS.get(team, Color("cbd5e1"))
	for child: Node in avatar.get_children():
		_tint_meshes(child, color)
	avatar.set_meta("presentation_team_id", team)
	var label := avatar.get_node_or_null("TeamLabel") as Label3D
	if label == null:
		label = Label3D.new()
		label.name = "TeamLabel"
		label.position.y = 2.75
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.outline_size = 4
		avatar.add_child(label)
	label.text = TEAM_NAMES.get(team, "UNIT")
	label.modulate = color


func _tint_building(root: Node3D, team: String) -> void:
	var color: Color = TEAM_COLORS.get(team, Color("e2e8f0"))
	for child: Node in root.get_children():
		_tint_meshes(child, color.darkened(0.22))


func _tint_meshes(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		node.material_override = _simple_material(color)
	for child: Node in node.get_children():
		_tint_meshes(child, color)


func _add_label(root: Node3D, text: String, color: Color, height: float) -> void:
	var label := Label3D.new()
	label.name = "StateLabel"
	label.text = text
	label.position.y = height
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.outline_size = 4
	label.modulate = color
	root.add_child(label)


func _instantiate_y_bot() -> Node3D:
	var avatar := YBot.instantiate() as Node3D
	var tree := avatar.get_node_or_null("AnimationTree") as AnimationTree
	if tree != null and tree.tree_root != null:
		tree.tree_root = tree.tree_root.duplicate(true)
	return avatar


func _position(value: Variant) -> Variant:
	if not value is Dictionary or typeof(value.get("x")) != TYPE_INT or typeof(value.get("y")) != TYPE_INT:
		return null
	return Vector2i(value.x, value.y)


func _world(position: Vector2i) -> Vector3:
	return Vector3(float(position.x) / 1000.0, 0.0, float(position.y) / 1000.0)


func _texture(path: String) -> Texture2D:
	# Optional reviewed terrain art. `load` uses Godot's import pipeline in exported Movie Maker
	# builds; the green/blue material fallback remains deterministic when assets are unavailable.
	return load(path) as Texture2D


func _box(node_name: String, size: Vector3, color: Color, texture: Texture2D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = _simple_material(color, texture)
	return node


func _cylinder(node_name: String, radius: float, height: float, color: Color, sides: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 1.05
	mesh.height = height
	mesh.radial_segments = sides
	node.mesh = mesh
	node.material_override = _simple_material(color)
	return node


func _sphere(node_name: String, radius: float, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 10
	mesh.rings = 7
	node.mesh = mesh
	node.material_override = _simple_material(color)
	return node


func _tree(tree_name: String, position: Vector3, index: int) -> Node3D:
	var tree := Node3D.new()
	tree.name = tree_name
	tree.position = position
	tree.rotation.y = float(index * 37 % 360) * PI / 180.0
	var trunk := _cylinder("Trunk", 0.2, 1.55, Color("69462d"), 7)
	trunk.position.y = 0.77
	tree.add_child(trunk)
	for crown_index: int in 3:
		var crown := _sphere("Crown%d" % crown_index, 0.78, [Color("245b3b"), Color("2d6c43"), Color("3b7948")][(index + crown_index) % 3])
		crown.position = Vector3(float(crown_index - 1) * 0.28, 1.8 + float(crown_index % 2) * 0.2, 0.0)
		tree.add_child(crown)
	return tree


func _rock(rock_name: String, position: Vector3, index: int) -> Node3D:
	var rock := _sphere(rock_name, 0.54, Color("69727a"))
	rock.position = position + Vector3(0.0, 0.25, 0.0)
	rock.scale = Vector3(1.28, 0.65, 0.9)
	rock.rotation.y = float(index * 53 % 360) * PI / 180.0
	return rock


func _simple_material(color: Color, texture: Texture2D = null) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.albedo_texture = texture
	material.roughness = 0.78
	return material


func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var material := _simple_material(color)
	material.emission_enabled = true
	material.emission = color * energy
	return material
