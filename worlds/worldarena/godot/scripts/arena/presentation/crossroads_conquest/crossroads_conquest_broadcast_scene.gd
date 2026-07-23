class_name CrossroadsConquestBroadcastScene
extends Node3D

## First-class broadcast-only presentation for the sealed Crossroads Conquest
## trace.  It receives complete public authority snapshots from the director and
## interpolates them; rendered transforms never feed back into game rules.

const DirectorScript := preload(
	"res://scripts/arena/presentation/crossroads_conquest/crossroads_conquest_broadcast_director.gd"
)
const GRASS_TEXTURE := preload("res://art/textures/grass-warcraft-v1.png")
const WATER_TEXTURE := preload("res://art/textures/water-warcraft-v1.png")
const DIRT_TEXTURE := preload("res://art/textures/dirt-path-warcraft-v1.png")
const ROCK_TEXTURE := preload("res://art/textures/rock-warcraft-v1.png")
const WOOD_TEXTURE := preload("res://art/textures/wood-warcraft-v1.png")
const CRYSTAL_TEXTURE := preload("res://art/textures/crystal-warcraft-v1.png")

const FACTIONS := ["sol", "luna", "terra"]
const FACTION_NAMES := {"sol": "SOL", "luna": "LUNA", "terra": "TERRA"}
const FACTION_GLYPHS := {"sol": "△", "luna": "○", "terra": "□", "neutral": "·"}
const FACTION_COLORS := {
	"sol": Color("fbbf24"),
	"luna": Color("a78bfa"),
	"terra": Color("34d399"),
	"neutral": Color("7f8d88"),
}
const CORE_MAX_HP := 900.0
const DISTRICT_POSITIONS := {
	"core_sol": Vector3(-70.8, 0.0, 67.2),
	"home_sol": Vector3(-49.7, 0.0, 44.2),
	"core_terra": Vector3(70.8, 0.0, 67.2),
	"home_terra": Vector3(49.7, 0.0, 44.2),
	"core_luna": Vector3(0.0, 0.0, -78.2),
	"home_luna": Vector3(0.0, 0.0, -51.5),
	"mine_st": Vector3(0.0, 0.0, 42.3),
	"mine_tl": Vector3(34.0, 0.0, -14.7),
	"mine_ls": Vector3(-34.0, 0.0, -14.7),
	"wild_st": Vector3(0.0, 0.0, 69.5),
	"wild_tl": Vector3(58.0, 0.0, 2.3),
	"wild_ls": Vector3(-58.0, 0.0, 2.3),
	"crossroads": Vector3(0.0, 0.0, 1.4),
}
const DISTRICT_NAMES := {
	"core_sol": "SOL STRONGHOLD", "home_sol": "SOL HOMELAND",
	"core_terra": "TERRA STRONGHOLD", "home_terra": "TERRA HOMELAND",
	"core_luna": "LUNA STRONGHOLD", "home_luna": "LUNA HOMELAND",
	"mine_st": "SUNFALL MINE", "mine_tl": "EMBER MINE", "mine_ls": "MOON MINE",
	"wild_st": "NORTH WILDWOOD", "wild_tl": "EAST WILDWOOD", "wild_ls": "WEST WILDWOOD",
	"crossroads": "CROSSROADS",
}
const ROAD_LINKS := [
	["core_sol", "home_sol"], ["core_terra", "home_terra"], ["core_luna", "home_luna"],
	["home_sol", "wild_st"], ["home_sol", "wild_ls"], ["home_sol", "mine_st"], ["home_sol", "mine_ls"],
	["home_terra", "wild_st"], ["home_terra", "wild_tl"], ["home_terra", "mine_st"], ["home_terra", "mine_tl"],
	["home_luna", "wild_tl"], ["home_luna", "wild_ls"], ["home_luna", "mine_tl"], ["home_luna", "mine_ls"],
	["mine_st", "crossroads"], ["mine_tl", "crossroads"], ["mine_ls", "crossroads"],
]
const COMBAT_BEATS := ["crossroads_clash", "terra_counterpunch", "sol_breaches_terra", "luna_strikes", "sol_eliminated"]

var _director := DirectorScript.new()
var _world: Node3D
var _camera: Camera3D
var _units_root: Node3D
var _structures_root: Node3D
var _effects_root: Node3D
var _units: Dictionary = {}
var _structures: Dictionary = {}
var _known_structure_ids: Dictionary = {}
var _district_nodes: Dictionary = {}
var _district_materials: Dictionary = {}
var _core_nodes: Dictionary = {}
var _chip_labels: Dictionary = {}
var _chip_bars: Dictionary = {}
var _stronghold_pips: Dictionary = {}
var _crossroads_label: RichTextLabel
var _event_card: PanelContainer
var _event_title: Label
var _event_subtitle: Label
var _verified_badge: Label
var _chapter_card: PanelContainer
var _chapter_title: Label
var _chapter_subtitle: Label
var _result_card: PanelContainer
var _result_text: RichTextLabel
var _elapsed_msec := 0
var _configured := false
var _last_snapshot: Dictionary = {}
var _last_beat_id := ""


func _ready() -> void:
	_build()


func configure_replay(replay: Dictionary) -> Dictionary:
	_build()
	var status: Dictionary = _director.configure_replay(replay)
	_configured = bool(status.get("ok", false))
	if not _configured:
		return status
	_verified_badge.text = "✓ VERIFIED REPLAY  ·  424242"
	apply_broadcast_time_msec(0)
	return status


func apply_broadcast_time_msec(time_msec: int) -> bool:
	if not _configured or time_msec < 0 or time_msec > 180000:
		return false
	_elapsed_msec = time_msec
	var seconds := minf(179.999999, float(time_msec) / 1000.0)
	var sample: Dictionary = _director.sample_at(seconds)
	if sample.is_empty():
		return false
	var from_snapshot: Dictionary = sample.from_frame.get("snapshot", {})
	var to_snapshot: Dictionary = sample.to_frame.get("snapshot", {})
	if not _valid_snapshot(from_snapshot) or not _valid_snapshot(to_snapshot):
		return false
	_apply_snapshot_pair(from_snapshot, to_snapshot, float(sample.alpha), sample.beat)
	_apply_broadcast_ui(sample)
	_apply_camera(sample)
	_last_snapshot = to_snapshot.duplicate(true)
	return true


func director_status() -> Dictionary:
	return _director.status()


func snapshot_copy() -> Dictionary:
	return {
		"showcase_id": DirectorScript.SHOWCASE_ID,
		"broadcast_msec": _elapsed_msec,
		"beat_id": _last_beat_id,
		"configured": _configured,
	}


func active_beat_id() -> String:
	return _last_beat_id


func _build() -> void:
	if _world != null:
		return
	_world = Node3D.new()
	_world.name = "CrossroadsConquestWorld"
	add_child(_world)
	_units_root = Node3D.new()
	_units_root.name = "Units"
	_world.add_child(_units_root)
	_structures_root = Node3D.new()
	_structures_root.name = "Structures"
	_world.add_child(_structures_root)
	_effects_root = Node3D.new()
	_effects_root.name = "PresentationEffects"
	_world.add_child(_effects_root)
	_build_environment()
	_build_island()
	_build_roads()
	_build_districts()
	_build_clean_landscape()
	_build_camera()
	_build_hud()


func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "PaintedWorldEnvironment"
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("17354b")
	sky_material.sky_horizon_color = Color("78a5ad")
	sky_material.ground_bottom_color = Color("0b1d28")
	sky_material.ground_horizon_color = Color("55767a")
	sky.sky_material = sky_material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b9d1b0")
	environment.ambient_light_energy = 0.72
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.02
	environment.fog_enabled = true
	environment.fog_light_color = Color("638b91")
	environment.fog_density = 0.0018
	environment.fog_sky_affect = 0.32
	world_environment.environment = environment
	_world.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.name = "WarmKeyLight"
	sun.rotation_degrees = Vector3(-57.0, -31.0, 0.0)
	sun.light_color = Color("ffe7b6")
	sun.light_energy = 1.32
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220.0
	_world.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.name = "CoolFillLight"
	fill.rotation_degrees = Vector3(-38.0, 148.0, 0.0)
	fill.light_color = Color("91c9cc")
	fill.light_energy = 0.34
	_world.add_child(fill)


func _build_island() -> void:
	var water := _plane("PaintedWater", Vector2(235.0, 235.0), Color("7cb9c7"), WATER_TEXTURE)
	water.position.y = -2.4
	_world.add_child(water)
	var vertices := PackedVector3Array([Vector3(0.0, -0.12, 0.0)])
	var normals := PackedVector3Array([Vector3.UP])
	var uvs := PackedVector2Array([Vector2(0.5, 0.5)])
	var indices := PackedInt32Array()
	const SIDES := 36
	for index: int in SIDES:
		var angle := TAU * float(index) / float(SIDES)
		var radius := 96.0 + sin(angle * 3.0) * 5.0 + cos(angle * 7.0) * 3.5
		var point := Vector3(cos(angle) * radius, -0.02 + sin(angle * 5.0) * 0.16, sin(angle) * radius * 0.94)
		vertices.append(point)
		normals.append(Vector3.UP)
		uvs.append(Vector2(point.x / 190.0 + 0.5, point.z / 180.0 + 0.5))
	for index: int in SIDES:
		indices.append_array(PackedInt32Array([0, index + 1, (index + 1) % SIDES + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var island := MeshInstance3D.new()
	island.name = "HandPaintedIsland"
	island.mesh = mesh
	var material := _material(Color("d9e4b5"), GRASS_TEXTURE)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.uv1_scale = Vector3(5.0, 5.0, 5.0)
	island.material_override = material
	_world.add_child(island)


func _build_roads() -> void:
	var root := Node3D.new()
	root.name = "ClearRoadNetwork"
	_world.add_child(root)
	for value: Variant in ROAD_LINKS:
		var link: Array = value
		var start: Vector3 = DISTRICT_POSITIONS[link[0]]
		var finish: Vector3 = DISTRICT_POSITIONS[link[1]]
		var direction := finish - start
		var road := _box("Road_%s_%s" % [link[0], link[1]], Vector3(2.9, 0.10, direction.length()), Color("dec58e"), DIRT_TEXTURE)
		road.position = (start + finish) * 0.5 + Vector3(0.0, 0.19, 0.0)
		road.rotation.y = atan2(direction.x, direction.z)
		root.add_child(road)


func _build_districts() -> void:
	var root := Node3D.new()
	root.name = "Districts"
	_world.add_child(root)
	for district_id: String in DISTRICT_POSITIONS:
		var district := Node3D.new()
		district.name = _node_id(district_id)
		district.position = DISTRICT_POSITIONS[district_id]
		root.add_child(district)
		var radius := 10.5 if district_id == "crossroads" else 7.4 if district_id.begins_with("core_") else 5.1
		var pad := _cylinder("GroundPad", radius, 0.14 if district_id == "crossroads" else 0.07, Color("6b7860" if district_id == "crossroads" else "688064"))
		pad.position.y = 0.08
		district.add_child(pad)
		_district_materials[district_id] = pad.material_override
		var label := Label3D.new()
		label.name = "DistrictLabel"
		label.text = DISTRICT_NAMES[district_id]
		label.position.y = 0.35
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 27 if district_id == "crossroads" else 18
		label.outline_size = 5
		label.pixel_size = 0.012
		label.modulate = Color("fff3d3")
		district.add_child(label)
		var supply := Label3D.new()
		supply.name = "SupplyCutFeedback"
		supply.text = "⚠ SUPPLY CUT"
		supply.position.y = 2.2
		supply.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		supply.font_size = 26
		supply.outline_size = 6
		supply.pixel_size = 0.012
		supply.modulate = Color("ff8066")
		supply.visible = false
		district.add_child(supply)
		if district_id == "crossroads":
			_build_crossroads_landmark(district)
		elif district_id.begins_with("core_"):
			_build_stronghold(district_id.trim_prefix("core_"), district)
		elif district_id.begins_with("home_"):
			_build_homeland_huts(district_id.trim_prefix("home_"), district)
		elif district_id.begins_with("mine_"):
			_build_mine_landmark(district)
		_district_nodes[district_id] = district


func _build_crossroads_landmark(district: Node3D) -> void:
	var platform := _cylinder("StonePlatform", 8.7, 0.55, Color("9c9482"), ROCK_TEXTURE)
	platform.position.y = 0.36
	district.add_child(platform)
	for ring_index: int in 3:
		var ring := MeshInstance3D.new()
		ring.name = "CaptureArc_%d" % ring_index
		var torus := TorusMesh.new()
		torus.inner_radius = 7.5 + float(ring_index) * 0.38
		torus.outer_radius = 7.68 + float(ring_index) * 0.38
		torus.rings = 48
		torus.ring_segments = 6
		ring.mesh = torus
		ring.position.y = 0.72 + float(ring_index) * 0.025
		ring.material_override = _material([FACTION_COLORS.sol, FACTION_COLORS.luna, FACTION_COLORS.terra][ring_index], null, true)
		district.add_child(ring)
	var crystal_root := Node3D.new()
	crystal_root.name = "CrystalLandmark"
	crystal_root.position.y = 0.65
	district.add_child(crystal_root)
	for index: int in 5:
		var crystal := _box("Crystal_%d" % index, Vector3(0.75, 3.6 + float(index % 2), 0.75), Color("66e8e1"), CRYSTAL_TEXTURE)
		crystal.position = Vector3(-1.4 + float(index) * 0.7, 2.1 + float(index % 2) * 0.25, sin(float(index) * 1.8) * 0.8)
		crystal.rotation_degrees = Vector3(0.0, float(index) * 31.0, -18.0 + float(index) * 7.0)
		(crystal.material_override as StandardMaterial3D).emission_enabled = true
		(crystal.material_override as StandardMaterial3D).emission = Color("2bbeb7")
		crystal_root.add_child(crystal)
	var flag := Node3D.new()
	flag.name = "CrossroadsOwnerFlag"
	flag.position = Vector3(4.7, 0.7, -2.7)
	district.add_child(flag)
	var pole := _cylinder("Pole", 0.10, 5.7, Color("4c3626"))
	pole.position.y = 2.85
	flag.add_child(pole)
	var banner := _box("Banner", Vector3(2.2, 1.25, 0.12), FACTION_COLORS.neutral)
	banner.position = Vector3(1.1, 4.65, 0.0)
	flag.add_child(banner)


func _build_stronghold(faction: String, district: Node3D) -> void:
	var root := Node3D.new()
	root.name = "%sStronghold" % faction.capitalize()
	district.add_child(root)
	var foundation := _cylinder("Foundation", 5.3, 1.1, FACTION_COLORS[faction].darkened(0.48), ROCK_TEXTURE)
	foundation.position.y = 0.62
	root.add_child(foundation)
	var keep := _box("Keep", Vector3(6.2, 6.8, 5.8), Color("c7b89c"), ROCK_TEXTURE)
	keep.position.y = 4.3
	root.add_child(keep)
	for index: int in 4:
		var tower := _cylinder("Tower_%d" % index, 1.25, 7.8, Color("b5a78f"), ROCK_TEXTURE)
		tower.position = Vector3(-3.0 if index < 2 else 3.0, 4.0, -2.7 if index % 2 == 0 else 2.7)
		root.add_child(tower)
	var crown := _cylinder("FactionCrown", 2.3, 0.52, FACTION_COLORS[faction], null, true)
	crown.position.y = 8.0
	root.add_child(crown)
	var damage := Node3D.new()
	damage.name = "DamageStages"
	root.add_child(damage)
	for index: int in 3:
		var shard := _box("Damage_%d" % index, Vector3(1.5 + index * 0.4, 0.38, 1.0), Color("332f2b"), ROCK_TEXTURE)
		shard.position = Vector3(-2.0 + index * 2.1, 0.35, -3.8 + index * 0.45)
		shard.rotation_degrees.y = 18.0 + index * 37.0
		shard.visible = false
		damage.add_child(shard)
	var rubble := _rubble("StrongholdRubble", 3.6)
	rubble.visible = false
	root.add_child(rubble)
	_core_nodes[faction] = root


func _build_homeland_huts(faction: String, district: Node3D) -> void:
	for index: int in 2:
		var hut := Node3D.new()
		hut.name = "PaintedHut_%d" % index
		hut.position = Vector3(-3.0 + index * 6.0, 0.25, 2.3 - index * 4.5)
		district.add_child(hut)
		var walls := _box("Walls", Vector3(3.4, 2.4, 3.0), Color("c99f68"), WOOD_TEXTURE)
		walls.position.y = 1.25
		hut.add_child(walls)
		var roof := _cylinder("Roof", 2.6, 1.8, FACTION_COLORS[faction].darkened(0.26))
		(roof.mesh as CylinderMesh).top_radius = 0.18
		roof.position.y = 3.0
		hut.add_child(roof)


func _build_mine_landmark(district: Node3D) -> void:
	for index: int in 4:
		var rock := _sphere("MineRock_%d" % index, 1.2 + float(index % 2) * 0.5, Color("7a7971"), ROCK_TEXTURE)
		rock.position = Vector3(-2.6 + index * 1.7, 0.8, -1.5 + sin(index * 1.7) * 1.6)
		rock.scale = Vector3(1.0, 0.75, 1.15)
		district.add_child(rock)
	var seam := _box("IronSeam", Vector3(4.4, 0.24, 0.45), Color("9a6440"), ROCK_TEXTURE)
	seam.position = Vector3(0.0, 0.42, -0.4)
	seam.rotation_degrees.y = 24.0
	district.add_child(seam)


func _build_clean_landscape() -> void:
	## Groves deliberately occupy the outer island only.  Roads, capture rings,
	## build pads, and the Sol–Terra northern battle corridor stay unobstructed.
	var clean_groves := [
		Vector3(-84, 0, 28), Vector3(-80, 0, -26), Vector3(-52, 0, -64),
		Vector3(84, 0, 28), Vector3(80, 0, -26), Vector3(52, 0, -64),
		Vector3(-27, 0, -86), Vector3(27, 0, -86), Vector3(-88, 0, 61), Vector3(88, 0, 61),
	]
	var root := Node3D.new()
	root.name = "RoadSafeLandscapeProps"
	_world.add_child(root)
	for grove_index: int in clean_groves.size():
		var center: Vector3 = clean_groves[grove_index]
		for tree_index: int in 5:
			var angle := float(tree_index) * 1.41 + float(grove_index) * 0.72
			var at := center + Vector3(cos(angle) * (2.0 + tree_index * 0.7), 0.0, sin(angle) * (2.2 + tree_index * 0.65))
			var tree := _low_poly_tree(grove_index * 10 + tree_index)
			tree.position = at
			root.add_child(tree)
		if grove_index % 2 == 0:
			var rocks := _rubble("RockCluster_%d" % grove_index, 1.5)
			rocks.position = center + Vector3(5.8, 0.0, -3.2)
			root.add_child(rocks)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "CrossroadsBroadcastCamera"
	_camera.current = true
	_camera.fov = 48.0
	_camera.near = 0.1
	_camera.far = 320.0
	_camera.position = Vector3(0.0, 108.0, 112.0)
	_world.add_child(_camera)
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "CrossroadsBroadcastHud"
	add_child(canvas)
	var root := Control.new()
	root.name = "SafePublicOverlay"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(root)
	var chip_positions := {"sol": Vector2(28, 26), "luna": Vector2(390, 26), "terra": Vector2(752, 26)}
	for faction: String in FACTIONS:
		var chip := PanelContainer.new()
		chip.name = "%sFactionChip" % faction.capitalize()
		chip.position = chip_positions[faction]
		chip.size = Vector2(334, 76)
		chip.add_theme_stylebox_override("panel", _panel_style(Color("101b22e8"), FACTION_COLORS[faction], 12, 2))
		root.add_child(chip)
		var label := RichTextLabel.new()
		label.position = Vector2(14, 8)
		label.size = Vector2(304, 58)
		label.bbcode_enabled = true
		label.scroll_active = false
		label.add_theme_font_size_override("normal_font_size", 17)
		chip.add_child(label)
		_chip_labels[faction] = label
		var bar := ProgressBar.new()
		bar.name = "CoreHealth"
		bar.position = Vector2(14, 55)
		bar.size = Vector2(304, 8)
		bar.min_value = 0.0
		bar.max_value = CORE_MAX_HP
		bar.show_percentage = false
		bar.add_theme_stylebox_override("background", _flat_style(Color("24303a"), 4))
		bar.add_theme_stylebox_override("fill", _flat_style(FACTION_COLORS[faction], 4))
		chip.add_child(bar)
		_chip_bars[faction] = bar
	var pips := HBoxContainer.new()
	pips.name = "StrongholdPips"
	pips.position = Vector2(1120, 28)
	pips.size = Vector2(242, 48)
	pips.add_theme_constant_override("separation", 14)
	root.add_child(pips)
	for faction: String in FACTIONS:
		var pip := Label.new()
		pip.name = "%sStrongholdPip" % faction.capitalize()
		pip.text = "%s %s" % [FACTION_GLYPHS[faction], FACTION_NAMES[faction]]
		pip.add_theme_font_size_override("font_size", 19)
		pip.add_theme_color_override("font_color", FACTION_COLORS[faction])
		pips.add_child(pip)
		_stronghold_pips[faction] = pip
	var crossroads := PanelContainer.new()
	crossroads.name = "CrossroadsIndicator"
	crossroads.position = Vector2(1388, 24)
	crossroads.size = Vector2(500, 88)
	crossroads.add_theme_stylebox_override("panel", _panel_style(Color("101b22ed"), Color("66e8e1"), 12, 2))
	root.add_child(crossroads)
	_crossroads_label = RichTextLabel.new()
	_crossroads_label.position = Vector2(14, 8)
	_crossroads_label.size = Vector2(470, 70)
	_crossroads_label.bbcode_enabled = true
	_crossroads_label.scroll_active = false
	_crossroads_label.add_theme_font_size_override("normal_font_size", 16)
	crossroads.add_child(_crossroads_label)
	_verified_badge = Label.new()
	_verified_badge.name = "VerifiedReplayBadge"
	_verified_badge.position = Vector2(1640, 1015)
	_verified_badge.size = Vector2(250, 32)
	_verified_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_verified_badge.text = "VERIFYING REPLAY"
	_verified_badge.add_theme_font_size_override("font_size", 13)
	_verified_badge.add_theme_color_override("font_color", Color("9fe3d2"))
	root.add_child(_verified_badge)
	_event_card = PanelContainer.new()
	_event_card.name = "TacticalEventCard"
	_event_card.position = Vector2(28, 872)
	_event_card.size = Vector2(690, 130)
	_event_card.add_theme_stylebox_override("panel", _panel_style(Color("0b151fe6"), Color("d8c69a"), 12, 2))
	root.add_child(_event_card)
	_event_title = Label.new()
	_event_title.position = Vector2(20, 14)
	_event_title.size = Vector2(650, 42)
	_event_title.add_theme_font_size_override("font_size", 28)
	_event_title.add_theme_color_override("font_color", Color("fff0bd"))
	_event_card.add_child(_event_title)
	_event_subtitle = Label.new()
	_event_subtitle.position = Vector2(20, 60)
	_event_subtitle.size = Vector2(650, 54)
	_event_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_event_subtitle.add_theme_font_size_override("font_size", 17)
	_event_subtitle.add_theme_color_override("font_color", Color("d9e4e7"))
	_event_card.add_child(_event_subtitle)
	_chapter_card = PanelContainer.new()
	_chapter_card.name = "BroadcastChapterCard"
	_chapter_card.position = Vector2(730, 132)
	_chapter_card.size = Vector2(460, 110)
	_chapter_card.add_theme_stylebox_override("panel", _panel_style(Color("0b151fdc"), Color("d8c69a"), 12, 2))
	root.add_child(_chapter_card)
	_chapter_title = Label.new()
	_chapter_title.position = Vector2(20, 14)
	_chapter_title.size = Vector2(420, 40)
	_chapter_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chapter_title.add_theme_font_size_override("font_size", 24)
	_chapter_card.add_child(_chapter_title)
	_chapter_subtitle = Label.new()
	_chapter_subtitle.position = Vector2(16, 57)
	_chapter_subtitle.size = Vector2(428, 38)
	_chapter_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chapter_subtitle.add_theme_font_size_override("font_size", 15)
	_chapter_subtitle.add_theme_color_override("font_color", Color("d9e4e7"))
	_chapter_card.add_child(_chapter_subtitle)
	_result_card = PanelContainer.new()
	_result_card.name = "VerifiedResultCard"
	_result_card.position = Vector2(430, 260)
	_result_card.size = Vector2(1060, 535)
	_result_card.add_theme_stylebox_override("panel", _panel_style(Color("08121af5"), FACTION_COLORS.luna, 18, 3))
	root.add_child(_result_card)
	_result_text = RichTextLabel.new()
	_result_text.position = Vector2(46, 35)
	_result_text.size = Vector2(968, 465)
	_result_text.bbcode_enabled = true
	_result_text.scroll_active = false
	_result_text.text = "[center][font_size=20][color=#9fe3d2]VERIFIED RESULT[/color][/font_size]\n[font_size=58][color=#a78bfa][b]○ LUNA WINS[/b][/color][/font_size]\n[font_size=23]Three strongholds. One crossroads. Last faction standing.[/font_size]\n\n[font_size=25][color=#a78bfa][b]1  LUNA ○[/b][/color]     [color=#fbbf24]2  SOL △[/color]     [color=#34d399]3  TERRA □[/color][/font_size]\n\n[font_size=22][color=#fbbf24]Sol eliminated Terra[/color]  ·  [color=#a78bfa]Luna eliminated Sol[/color][/font_size]\n\n[font_size=16][color=#9fb3c8]SEED 424242  ·  CROSSROADS-CONQUEST-DEMO-V1  ·  AUTHORITY REPLAY VERIFIED[/color][/font_size][/center]"
	_result_card.add_child(_result_text)
	_result_card.visible = false


func _apply_snapshot_pair(from_snapshot: Dictionary, to_snapshot: Dictionary, alpha: float, beat: Dictionary) -> void:
	_update_districts(from_snapshot, to_snapshot, alpha)
	_update_cores(from_snapshot, to_snapshot, alpha)
	_update_units(from_snapshot, to_snapshot, alpha, beat)
	_update_structures(from_snapshot, to_snapshot, alpha, beat)


func _update_districts(_from_snapshot: Dictionary, to_snapshot: Dictionary, _alpha: float) -> void:
	var districts := _dictionary(to_snapshot.get("districts", {}), "id")
	var factions := _dictionary(to_snapshot.get("factions", {}), "id")
	for district_id: String in _district_nodes:
		var state: Dictionary = districts.get(district_id, {})
		var raw_owner: Variant = state.get("owner")
		var owner := "neutral" if raw_owner == null or str(raw_owner).is_empty() else str(raw_owner)
		var eliminated := owner != "neutral" and bool((factions.get(owner, {}) as Dictionary).get("eliminated", false))
		var color := FACTION_COLORS.get(owner, FACTION_COLORS.neutral) as Color
		if eliminated:
			color = color.lerp(Color("65706c"), 0.76)
		var material := _district_materials[district_id] as StandardMaterial3D
		material.albedo_color = color.darkened(0.42 if district_id != "crossroads" else 0.28)
		var supply := (_district_nodes[district_id] as Node3D).get_node("SupplyCutFeedback") as Label3D
		supply.visible = int(state.get("unsupplied_rounds", 0)) > 0 and not eliminated
		if supply.visible:
			supply.modulate.a = 0.65 + sin(float(_elapsed_msec) * 0.012) * 0.3
		if district_id == "crossroads":
			var capture: Dictionary = state.get("capture", {})
			var progress := clampf(float(capture.get("progress", 0)) / 2.0, 0.0, 1.0)
			for ring_index: int in 3:
				var arc := (_district_nodes.crossroads as Node3D).get_node("CaptureArc_%d" % ring_index) as MeshInstance3D
				arc.visible = progress > float(ring_index) / 3.0 or owner != "neutral"
			var banner := (_district_nodes.crossroads as Node3D).get_node("CrossroadsOwnerFlag/Banner") as MeshInstance3D
			(banner.material_override as StandardMaterial3D).albedo_color = color


func _update_cores(from_snapshot: Dictionary, to_snapshot: Dictionary, alpha: float) -> void:
	var before := _dictionary(from_snapshot.get("factions", {}), "id")
	var after := _dictionary(to_snapshot.get("factions", {}), "id")
	for faction: String in FACTIONS:
		var before_state: Dictionary = before.get(faction, {})
		var after_state: Dictionary = after.get(faction, {})
		var hp := lerpf(float(before_state.get("core_hp", CORE_MAX_HP)), float(after_state.get("core_hp", CORE_MAX_HP)), alpha)
		var eliminated := bool(after_state.get("eliminated", false)) and alpha > 0.6
		_set_core_damage(faction, hp, eliminated)


func _set_core_damage(faction: String, hp: float, eliminated: bool) -> void:
	var core := _core_nodes[faction] as Node3D
	var keep := core.get_node("Keep") as MeshInstance3D
	var crown := core.get_node("FactionCrown") as MeshInstance3D
	var rubble := core.get_node("StrongholdRubble") as Node3D
	var damage := core.get_node("DamageStages") as Node3D
	var ratio := clampf(hp / CORE_MAX_HP, 0.0, 1.0)
	keep.visible = not eliminated
	crown.visible = not eliminated
	rubble.visible = eliminated
	for index: int in damage.get_child_count():
		damage.get_child(index).visible = ratio <= 0.75 - float(index) * 0.22 and not eliminated
	var keep_material := keep.material_override as StandardMaterial3D
	keep_material.albedo_color = Color("c7b89c").lerp(Color("4f4740"), 1.0 - ratio)


func _update_units(from_snapshot: Dictionary, to_snapshot: Dictionary, alpha: float, beat: Dictionary) -> void:
	var before := _dictionary(from_snapshot.get("units", {}), "id")
	var after := _dictionary(to_snapshot.get("units", {}), "id")
	var ids := {}
	for id: String in before: ids[id] = true
	for id: String in after: ids[id] = true
	for unit_id: String in ids:
		var first: Dictionary = before.get(unit_id, after.get(unit_id, {}))
		var second: Dictionary = after.get(unit_id, first)
		if first.is_empty() or second.is_empty():
			continue
		var faction := str(second.get("faction", first.get("faction", "")))
		var kind := str(second.get("kind", first.get("kind", "worker")))
		if faction not in FACTIONS:
			continue
		var actor := _units.get(unit_id) as Node3D
		if actor == null:
			actor = _new_unit(unit_id, faction, kind)
			_units_root.add_child(actor)
			_units[unit_id] = actor
		var first_position := _unit_position(unit_id, str(first.get("district", "")))
		var second_position := _unit_position(unit_id, str(second.get("district", "")))
		actor.position = first_position.lerp(second_position, _smoothstep(alpha))
		var movement := second_position - first_position
		if movement.length_squared() > 0.001:
			actor.rotation.y = atan2(movement.x, movement.z)
		var first_hp := float(first.get("hp", _unit_max_hp(kind)))
		var second_hp := float(second.get("hp", first_hp))
		var hp := lerpf(first_hp, second_hp, alpha)
		var combat := _unit_in_combat(second, str(beat.id))
		var bar := actor.get_node("HealthBar") as Label3D
		bar.visible = combat
		bar.text = _health_bar(hp, _unit_max_hp(kind))
		var ring := actor.get_node("TeamRing") as MeshInstance3D
		ring.scale = Vector3.ONE * (1.28 if combat else 1.0)
		actor.scale.y = 1.0 + sin(float(_elapsed_msec) * 0.009 + float(_stable_slot(unit_id))) * 0.025 if movement.length_squared() > 0.001 else 1.0
		actor.visible = hp > 0.0 and (after.has(unit_id) or alpha < 0.95)
	for unit_id: String in _units:
		if not ids.has(unit_id):
			(_units[unit_id] as Node3D).visible = false


func _update_structures(from_snapshot: Dictionary, to_snapshot: Dictionary, alpha: float, beat: Dictionary) -> void:
	var before := _dictionary(from_snapshot.get("structures", {}), "id")
	var after := _dictionary(to_snapshot.get("structures", {}), "id")
	var ids := {}
	for id: String in before: ids[id] = true
	for id: String in after: ids[id] = true
	for structure_id: String in ids:
		var first: Dictionary = before.get(structure_id, {})
		var second: Dictionary = after.get(structure_id, first)
		var source: Dictionary = second if not second.is_empty() else first
		var faction := str(source.get("faction", ""))
		var kind := str(source.get("kind", "outpost"))
		if faction not in FACTIONS:
			continue
		var node := _structures.get(structure_id) as Node3D
		if node == null:
			node = _new_structure(structure_id, faction, kind)
			_structures_root.add_child(node)
			_structures[structure_id] = node
		var district := str(source.get("district", ""))
		node.position = _structure_position(structure_id, district)
		var appeared := first.is_empty() and not second.is_empty()
		node.scale = Vector3.ONE * lerpf(0.24, 1.0, _smoothstep(alpha)) if appeared else Vector3.ONE
		node.visible = true
		node.get_node("Model").visible = true
		node.get_node("Rubble").visible = false
		_known_structure_ids[structure_id] = true
		var hp := lerpf(float(first.get("hp", source.get("hp", 240.0))), float(second.get("hp", source.get("hp", 240.0))), alpha)
		var combat := _structure_in_combat(district, str(beat.id))
		var bar := node.get_node("HealthBar") as Label3D
		bar.visible = combat
		bar.text = _health_bar(hp, maxf(1.0, float(node.get_meta("max_hp", 240.0))))
	for structure_id: String in _known_structure_ids:
		if ids.has(structure_id):
			continue
		var node := _structures.get(structure_id) as Node3D
		if node != null:
			node.visible = true
			node.get_node("Model").visible = false
			node.get_node("Rubble").visible = true
			(node.get_node("HealthBar") as Label3D).visible = false


func _apply_broadcast_ui(sample: Dictionary) -> void:
	var beat: Dictionary = sample.beat
	var beat_id := str(beat.id)
	var snapshot: Dictionary = sample.to_frame.snapshot
	var factions := _dictionary(snapshot.get("factions", {}), "id")
	var intents := _director.intents_at(float(sample.broadcast_seconds))
	for faction: String in FACTIONS:
		var state: Dictionary = factions.get(faction, {})
		var hp := clampf(float(state.get("core_hp", CORE_MAX_HP)), 0.0, CORE_MAX_HP)
		var eliminated := bool(state.get("eliminated", false))
		var label := _chip_labels[faction] as RichTextLabel
		label.text = "[color=#%s][b]%s %s[/b][/color]   CORE %d%%\n[color=#cbd7db]%s[/color]" % [FACTION_COLORS[faction].to_html(false), FACTION_GLYPHS[faction], FACTION_NAMES[faction], roundi(hp / CORE_MAX_HP * 100.0), str(intents.get(faction, "WAIT"))]
		(_chip_bars[faction] as ProgressBar).value = hp
		(_stronghold_pips[faction] as Label).modulate = Color("65706c") if eliminated else Color.WHITE
	var districts := _dictionary(snapshot.get("districts", {}), "id")
	var crossroads: Dictionary = districts.get("crossroads", {})
	var raw_owner: Variant = crossroads.get("owner")
	var owner := "neutral" if raw_owner == null or str(raw_owner).is_empty() else str(raw_owner)
	var capture: Dictionary = crossroads.get("capture", {})
	var capture_percent := clampi(int(capture.get("progress", 0)) * 50, 0, 100)
	var owner_stockpile: Dictionary = (factions.get(owner, {}) as Dictionary).get("stockpile", {}) if owner != "neutral" else {}
	var crystal := int(owner_stockpile.get("crystal", 0))
	var siege_ready := _has_unit_kind(snapshot, owner, "siege") if owner != "neutral" else false
	_crossroads_label.text = "[font_size=19][b]CROSSROADS[/b]  [color=#%s]%s %s[/color][/font_size]\nCAPTURE %d%%  ·  CRYSTAL %d  ·  SIEGE %s" % [FACTION_COLORS[owner].to_html(false), FACTION_GLYPHS[owner], FACTION_NAMES.get(owner, "NEUTRAL"), capture_percent, crystal, "READY" if siege_ready else "LOCKED"]
	var local_seconds := float(sample.beat_elapsed)
	_event_title.text = str(beat.title)
	_event_subtitle.text = str(beat.subtitle)
	var accent := FACTION_COLORS.get(str(beat.accent), Color("d8c69a")) as Color
	_event_title.add_theme_color_override("font_color", accent)
	_event_card.modulate.a = clampf(minf(local_seconds / 0.45, (float(beat.end) - float(sample.broadcast_seconds)) / 1.4), 0.0, 1.0)
	_chapter_title.text = str(beat.title)
	_chapter_subtitle.text = str(beat.subtitle)
	_chapter_title.add_theme_color_override("font_color", accent)
	_chapter_card.visible = local_seconds < 4.2 and beat_id not in ["crossroads_clash", "two_front_march", "sol_breaches_terra"]
	_chapter_card.modulate.a = clampf(minf(local_seconds / 0.35, (4.2 - local_seconds) / 0.8), 0.0, 1.0)
	_result_card.visible = beat_id == "verified_result" and _verified_terminal_snapshot(snapshot)
	_last_beat_id = beat_id
	_apply_opening_pulse(float(sample.broadcast_seconds))


func _apply_camera(sample: Dictionary) -> void:
	var beat_index := int(sample.beat_index)
	var beat: Dictionary = sample.beat
	var current := _camera_pose(str(beat.shot), str(beat.focus))
	var previous := current
	if beat_index > 0:
		var previous_beat: Dictionary = DirectorScript.BEATS[beat_index - 1]
		previous = _camera_pose(str(previous_beat.shot), str(previous_beat.focus))
	var progress := clampf(float(sample.beat_elapsed) / float(beat.transition), 0.0, 1.0)
	progress = _smoothstep(progress)
	_camera.position = (previous.position as Vector3).lerp(current.position, progress)
	var target: Vector3 = (previous.target as Vector3).lerp(current.target, progress)
	_camera.look_at(target, Vector3.UP)


func _camera_pose(shot: String, focus: String) -> Dictionary:
	var target := _focus_position(focus)
	match shot:
		"stronghold_close":
			return {"position": target + Vector3(24.0, 25.0, 31.0), "target": target + Vector3(0.0, 2.2, 0.0)}
		"battle_medium":
			return {"position": target + Vector3(18.0, 31.0, 35.0), "target": target + Vector3(0.0, 1.2, 0.0)}
		"two_front_wide":
			return {"position": Vector3(0.0, 82.0, 94.0), "target": Vector3(0.0, 0.0, 30.0)}
		_:
			return {"position": Vector3(0.0, 108.0, 112.0), "target": Vector3(0.0, 0.0, -2.0)}


func _focus_position(focus: String) -> Vector3:
	if DISTRICT_POSITIONS.has(focus):
		return DISTRICT_POSITIONS[focus]
	if focus == "north_fronts":
		return Vector3(0.0, 0.0, 46.0)
	return Vector3.ZERO


func _apply_opening_pulse(seconds: float) -> void:
	var active := seconds < 12.0
	var scale_value := 1.0 + (0.075 * (0.5 + sin(seconds * 3.2) * 0.5) if active else 0.0)
	for faction: String in FACTIONS:
		(_core_nodes[faction] as Node3D).scale = Vector3.ONE * scale_value
	var crystal := (_district_nodes.crossroads as Node3D).get_node("CrystalLandmark") as Node3D
	crystal.scale = Vector3.ONE * scale_value


func _new_unit(unit_id: String, faction: String, kind: String) -> Node3D:
	var root := Node3D.new()
	root.name = _node_id(unit_id)
	root.set_meta("unit_id", unit_id)
	root.set_meta("faction", faction)
	root.set_meta("kind", kind)
	var ring := MeshInstance3D.new()
	ring.name = "TeamRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 1.25 if kind in ["commander", "siege"] else 0.9
	torus.outer_radius = torus.inner_radius + 0.18
	torus.rings = 28
	torus.ring_segments = 6
	ring.mesh = torus
	ring.position.y = 0.15
	ring.material_override = _material(FACTION_COLORS[faction], null, true)
	root.add_child(ring)
	if kind == "siege":
		_build_siege_model(root, faction)
	else:
		_build_unit_model(root, faction, kind)
	var glyph := Label3D.new()
	glyph.name = "Glyph"
	glyph.text = "%s %s" % [FACTION_GLYPHS[faction], kind.to_upper()]
	glyph.position.y = 4.1 if kind == "commander" else 3.35
	glyph.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	glyph.font_size = 25
	glyph.outline_size = 5
	glyph.pixel_size = 0.009
	glyph.modulate = FACTION_COLORS[faction]
	root.add_child(glyph)
	var bar := Label3D.new()
	bar.name = "HealthBar"
	bar.position.y = glyph.position.y + 0.62
	bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bar.font_size = 22
	bar.outline_size = 6
	bar.pixel_size = 0.009
	bar.modulate = Color("fff4d0")
	bar.visible = false
	root.add_child(bar)
	return root


func _build_unit_model(root: Node3D, faction: String, kind: String) -> void:
	var height := 2.75 if kind == "commander" else 2.2 if kind in ["guard", "militia"] else 1.85
	var body := _cylinder("Body", 0.62 if kind == "commander" else 0.48, height, FACTION_COLORS[faction])
	body.position.y = height * 0.5 + 0.22
	root.add_child(body)
	var head := _sphere("Head", 0.47 if kind == "commander" else 0.36, Color("e8c6a2"))
	head.position.y = height + 0.52
	root.add_child(head)
	if kind in ["commander", "guard", "militia"]:
		var weapon := _box("Weapon", Vector3(0.14, 2.2 if kind == "guard" else 1.6, 0.14), Color("8d806e"), ROCK_TEXTURE)
		weapon.position = Vector3(0.72, height * 0.62, 0.0)
		weapon.rotation_degrees.z = -18.0
		root.add_child(weapon)
	if kind == "scout":
		var pennant := _box("ScoutPennant", Vector3(0.12, 1.4, 0.7), FACTION_COLORS[faction].lightened(0.22))
		pennant.position = Vector3(0.55, height * 0.75, 0.0)
		root.add_child(pennant)


func _build_siege_model(root: Node3D, faction: String) -> void:
	var chassis := _box("SiegeChassis", Vector3(3.2, 0.75, 2.2), Color("755033"), WOOD_TEXTURE)
	chassis.position.y = 0.85
	root.add_child(chassis)
	for x: float in [-1.35, 1.35]:
		for z: float in [-0.85, 0.85]:
			var wheel := _cylinder("Wheel", 0.52, 0.28, Color("302820"), WOOD_TEXTURE)
			wheel.position = Vector3(x, 0.5, z)
			wheel.rotation_degrees.x = 90.0
			root.add_child(wheel)
	var arm := _box("SiegeArm", Vector3(0.38, 3.8, 0.38), FACTION_COLORS[faction].darkened(0.18))
	arm.position = Vector3(0.0, 2.15, 0.0)
	arm.rotation_degrees.z = -34.0
	root.add_child(arm)


func _new_structure(structure_id: String, faction: String, kind: String) -> Node3D:
	var root := Node3D.new()
	root.name = _node_id(structure_id)
	root.set_meta("structure_id", structure_id)
	root.set_meta("faction", faction)
	root.set_meta("kind", kind)
	root.set_meta("max_hp", 360.0 if kind == "wall" else 300.0 if kind == "tower" else 240.0)
	var model := Node3D.new()
	model.name = "Model"
	root.add_child(model)
	if kind == "wall":
		var wall := _box("Wall", Vector3(6.5, 2.7, 1.25), Color("968f80"), ROCK_TEXTURE)
		wall.position.y = 1.35
		model.add_child(wall)
	elif kind == "tower":
		var tower := _cylinder("Tower", 1.65, 5.8, Color("9f9787"), ROCK_TEXTURE)
		tower.position.y = 2.9
		model.add_child(tower)
	elif kind in ["mine", "crystal_mine"]:
		var crane := _box("MineCrane", Vector3(0.35, 4.4, 0.35), Color("67452d"), WOOD_TEXTURE)
		crane.position.y = 2.2
		crane.rotation_degrees.z = -17.0
		model.add_child(crane)
		var ore := _sphere("CrystalOre", 0.85, Color("65e4dc"), CRYSTAL_TEXTURE)
		ore.position = Vector3(1.4, 0.85, 0.0)
		model.add_child(ore)
	elif kind == "workshop":
		var shop := _box("Workshop", Vector3(4.3, 3.0, 3.7), Color("a87546"), WOOD_TEXTURE)
		shop.position.y = 1.5
		model.add_child(shop)
	else:
		var outpost := _cylinder("Outpost", 2.15, 3.8, FACTION_COLORS[faction].darkened(0.25), WOOD_TEXTURE)
		outpost.position.y = 1.9
		model.add_child(outpost)
	var flag := _box("FactionMarker", Vector3(1.5, 0.7, 0.12), FACTION_COLORS[faction])
	flag.position = Vector3(1.0, 4.3, 0.0)
	model.add_child(flag)
	var rubble := _rubble("Rubble", 2.4)
	rubble.visible = false
	root.add_child(rubble)
	var bar := Label3D.new()
	bar.name = "HealthBar"
	bar.position.y = 5.4
	bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bar.font_size = 23
	bar.outline_size = 6
	bar.pixel_size = 0.009
	bar.modulate = Color("fff4d0")
	bar.visible = false
	root.add_child(bar)
	return root


func _valid_snapshot(snapshot: Dictionary) -> bool:
	return snapshot.get("match") is Dictionary and snapshot.get("factions") is Dictionary \
		and snapshot.get("districts") is Dictionary and snapshot.get("units") is Dictionary \
		and snapshot.get("structures") is Dictionary and snapshot.get("tasks") is Dictionary


func _dictionary(value: Variant, id_key: String) -> Dictionary:
	if value is Dictionary:
		return value
	var result := {}
	if value is Array:
		for child: Variant in value:
			if child is Dictionary and not str(child.get(id_key, "")).is_empty():
				result[str(child[id_key])] = child
	return result


func _unit_position(unit_id: String, district_id: String) -> Vector3:
	var center: Vector3 = DISTRICT_POSITIONS.get(district_id, Vector3.ZERO)
	var slot := _stable_slot(unit_id)
	var angle := float(slot % 12) / 12.0 * TAU
	var radius := 2.1 + float(slot % 4) * 0.72
	return center + Vector3(cos(angle) * radius, 0.28, sin(angle) * radius)


func _structure_position(structure_id: String, district_id: String) -> Vector3:
	var center: Vector3 = DISTRICT_POSITIONS.get(district_id, Vector3.ZERO)
	var slot := _stable_slot(structure_id)
	var angle := float(slot % 8) / 8.0 * TAU
	var radius := 4.4 if district_id == "crossroads" else 5.8
	return center + Vector3(cos(angle) * radius, 0.28, sin(angle) * radius)


func _stable_slot(value: String) -> int:
	var result := 17
	for index: int in value.length():
		result = (result * 31 + value.unicode_at(index)) % 9973
	return result


func _unit_in_combat(unit: Dictionary, beat_id: String) -> bool:
	if not str(unit.get("attack_target", "")).is_empty():
		return true
	if beat_id not in COMBAT_BEATS:
		return false
	var district := str(unit.get("district", ""))
	if beat_id == "crossroads_clash":
		return district == "crossroads"
	if beat_id in ["terra_counterpunch", "luna_strikes", "sol_eliminated"]:
		return district in ["home_sol", "core_sol"]
	return district in ["home_terra", "core_terra"]


func _structure_in_combat(district: String, beat_id: String) -> bool:
	return (beat_id == "crossroads_clash" and district == "crossroads") \
		or (beat_id in ["terra_counterpunch", "luna_strikes", "sol_eliminated"] and district in ["home_sol", "core_sol"]) \
		or (beat_id == "sol_breaches_terra" and district in ["home_terra", "core_terra"])


func _has_unit_kind(snapshot: Dictionary, faction: String, kind: String) -> bool:
	for unit: Variant in _dictionary(snapshot.get("units", {}), "id").values():
		if unit is Dictionary and unit.get("faction") == faction and unit.get("kind") == kind and float(unit.get("hp", 1.0)) > 0.0:
			return true
	return false


func _verified_terminal_snapshot(snapshot: Dictionary) -> bool:
	var match_state: Dictionary = snapshot.get("match", {})
	var factions := _dictionary(snapshot.get("factions", {}), "id")
	return bool(match_state.get("ended", false)) and str(match_state.get("winner", "")).to_lower() == "luna" \
		and bool((factions.get("sol", {}) as Dictionary).get("eliminated", false)) \
		and bool((factions.get("terra", {}) as Dictionary).get("eliminated", false)) \
		and not bool((factions.get("luna", {}) as Dictionary).get("eliminated", true))


func _unit_max_hp(kind: String) -> float:
	return {"commander": 150.0, "worker": 30.0, "scout": 40.0, "militia": 75.0, "guard": 110.0, "siege": 130.0}.get(kind, 100.0)


func _health_bar(hp: float, maximum: float) -> String:
	var percent := clampi(roundi(hp / maximum * 100.0), 0, 100)
	var filled := clampi(ceili(float(percent) / 20.0), 0, 5)
	return "%s%s %d%%" % ["█".repeat(filled), "░".repeat(5 - filled), percent]


func _low_poly_tree(seed: int) -> Node3D:
	var tree := Node3D.new()
	tree.name = "PaintedTree_%d" % seed
	var trunk := _cylinder("Trunk", 0.28, 2.6, Color("6e4b31"), WOOD_TEXTURE)
	trunk.position.y = 1.3
	tree.add_child(trunk)
	for index: int in 2:
		var canopy := _cylinder("Canopy_%d" % index, 2.0 - index * 0.45, 2.5, Color("285c38").lightened(float((seed + index) % 3) * 0.04))
		(canopy.mesh as CylinderMesh).top_radius = 0.16
		canopy.position.y = 3.0 + index * 1.65
		tree.add_child(canopy)
	return tree


func _rubble(name: String, radius: float) -> Node3D:
	var root := Node3D.new()
	root.name = name
	for index: int in 6:
		var stone := _box("Stone_%d" % index, Vector3(1.0 + (index % 2) * 0.55, 0.45 + (index % 3) * 0.18, 0.85), Color("625d55"), ROCK_TEXTURE)
		var angle := float(index) / 6.0 * TAU
		stone.position = Vector3(cos(angle) * radius * 0.52, stone.mesh.size.y * 0.5, sin(angle) * radius * 0.52)
		stone.rotation_degrees = Vector3(index * 7.0, index * 43.0, index * 4.0)
		root.add_child(stone)
	return root


func _plane(name: String, size: Vector2, color: Color, texture: Texture2D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := PlaneMesh.new()
	mesh.size = size
	node.mesh = mesh
	var material := _material(color, texture)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.uv1_scale = Vector3(7.0, 7.0, 7.0)
	node.material_override = material
	return node


func _box(name: String, size: Vector3, color: Color, texture: Texture2D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = _material(color, texture)
	return node


func _sphere(name: String, radius: float, color: Color, texture: Texture2D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	node.mesh = mesh
	node.material_override = _material(color, texture)
	return node


func _cylinder(name: String, radius: float, height: float, color: Color, texture: Texture2D = null, emission := false) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 1.04
	mesh.height = height
	mesh.radial_segments = 10
	node.mesh = mesh
	node.material_override = _material(color, texture, emission)
	return node


func _material(color: Color, texture: Texture2D = null, emission := false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.albedo_texture = texture
	material.texture_repeat = true
	material.roughness = 0.86
	if emission:
		material.emission_enabled = true
		material.emission = color.darkened(0.38)
		material.emission_energy_multiplier = 0.36
	return material


func _panel_style(background: Color, border: Color, radius: int, border_width: int) -> StyleBoxFlat:
	var style := _flat_style(background, radius)
	style.border_color = border
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.shadow_color = Color("00000066")
	style.shadow_size = 8
	return style


func _flat_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	return style


func _smoothstep(value: float) -> float:
	var clamped := clampf(value, 0.0, 1.0)
	return clamped * clamped * (3.0 - 2.0 * clamped)


func _node_id(value: String) -> String:
	return value.replace("-", "_").replace("/", "_").replace(" ", "_")
