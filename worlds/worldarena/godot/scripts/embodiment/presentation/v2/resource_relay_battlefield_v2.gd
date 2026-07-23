class_name EmbodimentResourceRelayBattlefieldV2
extends Node3D

## Presentation-only set dressing for the public resource-relay map.
##
## This script deliberately has no authority dependency and receives no snapshots.  Everything it
## draws is a task-level, immutable landmark: grass, a shallow river, paths, trees and rocks.  Live
## resources, relays, barricades, and opponents remain projection nodes supplied by the current
## participant-filtered authority source in `control_game_participant_scene_v2.gd`.

const GRASS := [Color("1d4828"), Color("27542d"), Color("214c29"), Color("326334")]
const DIRT := Color("a67c52")
const WATER := Color("1d6f91")
const WATER_EDGE := Color("70b6bc")
const ROCK := Color("657079")
const TREE_TRUNK := Color("65452e")
const TREE_LEAF := [Color("23593d"), Color("2f6d46"), Color("3e7c4c")]
# Generated Frontier terrain textures are local, reviewed presentation assets. They are used
# only for the immutable map dressing; entity visibility and all game state still comes from the
# participant-filtered projection source.
const FRONTIER_GRASS_TEXTURE_PATH := "res://assets/terrain/frontier/frontier-grass-v1.png"
const FRONTIER_WATER_TEXTURE_PATH := "res://assets/terrain/frontier/frontier-water-v1.png"


func configure_for_task(task_id: String) -> void:
	visible = task_id == "duo-resource-relay-v0"
	if visible and get_child_count() == 0:
		_build()


func _build() -> void:
	name = "ResourceRelayBattlefield"
	_build_ground()
	_build_river_and_paths()
	_build_trees_and_rocks()
	_build_lighting()


func _build_ground() -> void:
	var ground := _box("Grassland", Vector3(28.0, 0.18, 28.0), Color("1c4226"), _terrain_texture(FRONTIER_GRASS_TEXTURE_PATH))
	ground.position.y = -0.12
	add_child(ground)
	var patches := Node3D.new()
	patches.name = "GrassTexturePatches"
	add_child(patches)
	# A fixed mosaic reads as textured grass without shipping an unreviewed bitmap asset.
	for z: int in 7:
		for x: int in 7:
			var patch := _box(
				"Grass_%d_%d" % [x, z], Vector3(3.88, 0.012, 3.88), GRASS[(x * 3 + z * 5) % GRASS.size()]
			)
			patch.position = Vector3(-11.65 + float(x) * 3.88, 0.006, -11.65 + float(z) * 3.88)
			patches.add_child(patch)


func _build_river_and_paths() -> void:
	var river := _box("BluewaterRiver", Vector3(4.1, 0.035, 28.0), Color("3d8eac"), _terrain_texture(FRONTIER_WATER_TEXTURE_PATH))
	river.position = Vector3(0.0, 0.026, 0.0)
	add_child(river)
	for side: int in [-1, 1]:
		var bank := _box("RiverBank%d" % side, Vector3(0.24, 0.065, 28.0), WATER_EDGE)
		bank.position = Vector3(float(side) * 2.16, 0.05, 0.0)
		add_child(bank)
	# Two narrow wooden bridges make the arena navigation legible while remaining cosmetic.
	for z_value: float in [-5.6, 5.6]:
		var bridge := _box("Bridge_%s" % str(z_value).replace("-", "N").replace(".", "_"), Vector3(4.65, 0.16, 1.25), Color("7a5135"))
		bridge.position = Vector3(0.0, 0.11, z_value)
		add_child(bridge)
		for plank_index: int in 5:
			var plank := _box("BridgePlank%d" % plank_index, Vector3(0.68, 0.055, 1.35), Color("b78755"))
			plank.position = Vector3(-1.7 + float(plank_index) * 0.85, 0.22, z_value)
			add_child(plank)
	# The roads are visual wayfinding only. They do not reveal an objective or hidden target.
	for side: int in [-1, 1]:
		var path := _box("SidePath%d" % side, Vector3(1.15, 0.022, 11.0), DIRT)
		path.position = Vector3(float(side) * 5.9, 0.02, 0.0)
		add_child(path)


func _build_trees_and_rocks() -> void:
	var props := Node3D.new()
	props.name = "ForestAndRocks"
	add_child(props)
	# Fixed perimeter placements avoid changing gameplay readability or participant semantics.
	var tree_positions := [
		Vector3(-11.0, 0.0, -11.0), Vector3(-8.7, 0.0, -10.5), Vector3(-5.8, 0.0, -11.3),
		Vector3(11.0, 0.0, 11.0), Vector3(8.7, 0.0, 10.4), Vector3(5.8, 0.0, 11.2),
		Vector3(-11.2, 0.0, 8.4), Vector3(-9.2, 0.0, 10.4), Vector3(11.2, 0.0, -8.4),
		Vector3(9.0, 0.0, -10.4), Vector3(-11.0, 0.0, -2.4), Vector3(11.0, 0.0, 2.4),
	]
	for index: int in tree_positions.size():
		props.add_child(_tree("Tree_%02d" % index, tree_positions[index], index))
	var rock_positions := [
		Vector3(-8.0, 0.0, -6.5), Vector3(-7.2, 0.0, 6.8), Vector3(8.0, 0.0, 6.5),
		Vector3(7.2, 0.0, -6.8), Vector3(-3.5, 0.0, 10.5), Vector3(3.5, 0.0, -10.5),
	]
	for index: int in rock_positions.size():
		props.add_child(_rock("Rock_%02d" % index, rock_positions[index], index))


func _build_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "BattlefieldSun"
	sun.rotation_degrees = Vector3(-52.0, -36.0, 0.0)
	sun.light_color = Color("ffe8bd")
	sun.light_energy = 0.88
	sun.shadow_enabled = true
	add_child(sun)
	var environment := WorldEnvironment.new()
	environment.name = "BattlefieldAtmosphere"
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("5e93b2")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("bcd8b1")
	settings.ambient_light_energy = 0.42
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	settings.tonemap_exposure = 0.62
	settings.glow_enabled = false
	environment.environment = settings
	add_child(environment)


func _tree(tree_name: String, location: Vector3, index: int) -> Node3D:
	var root := Node3D.new()
	root.name = tree_name
	root.position = location
	root.rotation.y = float(index * 37 % 360) * PI / 180.0
	var trunk := _cylinder("Trunk", 0.22, 1.55, TREE_TRUNK, 7)
	trunk.position.y = 0.76
	root.add_child(trunk)
	for crown_index: int in 3:
		var crown := _sphere("Crown%d" % crown_index, 0.8, TREE_LEAF[(index + crown_index) % TREE_LEAF.size()])
		crown.scale = Vector3(0.92, 1.18, 0.92)
		crown.position = Vector3(float(crown_index - 1) * 0.32, 1.85 + float(crown_index % 2) * 0.22, 0.0)
		root.add_child(crown)
	return root


func _rock(rock_name: String, location: Vector3, index: int) -> Node3D:
	var root := Node3D.new()
	root.name = rock_name
	root.position = location
	root.rotation.y = float(index * 51 % 360) * PI / 180.0
	var mesh := MeshInstance3D.new()
	mesh.name = "Stone"
	var stone := SphereMesh.new()
	stone.radius = 0.48
	stone.height = 0.72
	mesh.mesh = stone
	mesh.scale = Vector3(1.25, 0.7, 0.9)
	mesh.position.y = 0.27
	mesh.material_override = _material(ROCK)
	root.add_child(mesh)
	return root


func _box(node_name: String, size: Vector3, color: Color, texture: Texture2D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = _material(color, texture)
	return node


func _cylinder(node_name: String, radius: float, height: float, color: Color, sides: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 1.08
	mesh.height = height
	mesh.radial_segments = sides
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _sphere(node_name: String, radius: float, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 8
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _material(color: Color, texture: Texture2D = null) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.albedo_texture = texture
	material.roughness = 0.84
	return material


func _terrain_texture(path: String) -> Texture2D:
	# ImageTexture keeps these generated PNGs usable in command-line Movie Maker runs even before
	# Godot has produced editor `.import` metadata. A missing optional art file degrades to the
	# same coloured procedural terrain rather than affecting the gameplay presentation boundary.
	var image := Image.load_from_file(path)
	return ImageTexture.create_from_image(image) if image != null and not image.is_empty() else null
