extends Node3D

signal selected(district_id: String)

const NEUTRAL_COLOR := Color("687884")

var district_id := ""
var district_kind := "district"
var display_name := "DISTRICT"
var radius := 24.0
var faction_colors: Dictionary = {}
var faction_glyphs: Dictionary = {}

var _base_material: StandardMaterial3D
var _ring_material: StandardMaterial3D
var _capture_material: StandardMaterial3D
var _flag_material: StandardMaterial3D
var _base: MeshInstance3D
var _ring: MeshInstance3D
var _capture_ring: MeshInstance3D
var _flag: Node3D
var _name_label: Label3D
var _state_label: Label3D
var _owner_label: Label3D
var _cut_stripes: Array[MeshInstance3D] = []


func setup(definition: Dictionary, colors: Dictionary, glyphs: Dictionary) -> void:
	district_id = str(definition.get("id", "district"))
	display_name = str(definition.get("name", district_id)).to_upper()
	district_kind = str(definition.get("kind", "district"))
	radius = float(definition.get("radius", 24.0))
	faction_colors = colors.duplicate()
	faction_glyphs = glyphs.duplicate()
	position = definition.get("position", Vector3.ZERO)
	_build_visuals()
	apply_state(definition.get("state", {}))


func apply_state(state: Dictionary) -> void:
	if _base == null:
		return
	var owner := str(state.get("owner", "neutral"))
	var supplied := bool(state.get("supplied", owner == "neutral"))
	var contested := bool(state.get("contested", false))
	var capture_progress := clampf(float(state.get("capture_progress", 0.0)), 0.0, 1.0)
	var color: Color = faction_colors.get(owner, NEUTRAL_COLOR)

	# Ownership should sit in the landscape, not turn every district into a floating
	# board-game token.  A faint ground wash, a thin boundary and the field flag are
	# enough to read control from the strategy camera.
	_base_material.albedo_color = Color(color.r, color.g, color.b, 0.06 if owner != "neutral" else 0.02)
	_ring_material.albedo_color = Color(color.r, color.g, color.b, 0.24 if owner != "neutral" else 0.09)
	_ring_material.emission = color.darkened(0.38)
	_ring_material.emission_energy_multiplier = 0.12
	_flag.visible = owner != "neutral"
	_flag_material.albedo_color = color
	_flag_material.emission = color.darkened(0.2)
	_owner_label.text = str(faction_glyphs.get(owner, "·"))
	_owner_label.modulate = color.lightened(0.25)
	_owner_label.visible = owner != "neutral"

	_capture_ring.visible = contested or capture_progress > 0.0
	_capture_material.albedo_color = Color("fff3c4") if contested else color.lightened(0.35)
	_capture_material.emission = _capture_material.albedo_color
	_capture_ring.scale = Vector3.ONE * lerpf(0.62, 1.0, capture_progress)

	for stripe in _cut_stripes:
		stripe.visible = owner != "neutral" and not supplied

	if contested:
		_state_label.text = "CONTESTED  %d%%" % int(capture_progress * 100.0)
		_state_label.modulate = Color("fff3c4")
	elif owner != "neutral" and not supplied:
		_state_label.text = "SUPPLY CUT"
		_state_label.modulate = Color("ff7a70")
	elif capture_progress > 0.0:
		_state_label.text = "CAPTURE  %d%%" % int(capture_progress * 100.0)
		_state_label.modulate = color.lightened(0.3)
	else:
		_state_label.text = ""
		_state_label.modulate = Color("9fb7bd")
	# The ownership ring and physical flag carry normal-state information.  A second
	# label is reserved for situations a spectator needs to react to.
	_state_label.visible = contested or (owner != "neutral" and not supplied) or capture_progress > 0.0


func world_anchor() -> Vector3:
	return global_position + Vector3(0.0, 7.5, 0.0)


func _build_visuals() -> void:
	_base_material = _material(Color(NEUTRAL_COLOR, 0.13), false, true)
	_base = MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = radius
	disk.bottom_radius = radius
	disk.height = 0.045
	disk.radial_segments = 48
	_base.mesh = disk
	_base.material_override = _base_material
	_base.position.y = 0.05
	add_child(_base)

	_ring_material = _material(Color(NEUTRAL_COLOR, 0.12), false, true)
	_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = radius - 0.34
	ring_mesh.outer_radius = radius
	ring_mesh.rings = 48
	ring_mesh.ring_segments = 6
	_ring.mesh = ring_mesh
	_ring.material_override = _ring_material
	_ring.position.y = 0.10
	add_child(_ring)

	_capture_material = _material(Color("fff3c4"), true)
	_capture_ring = MeshInstance3D.new()
	var capture_mesh := TorusMesh.new()
	capture_mesh.inner_radius = radius * 0.47
	capture_mesh.outer_radius = radius * 0.55
	capture_mesh.rings = 40
	capture_mesh.ring_segments = 7
	_capture_ring.mesh = capture_mesh
	_capture_ring.material_override = _capture_material
	_capture_ring.position.y = 0.16
	_capture_ring.visible = false
	add_child(_capture_ring)

	_flag = Node3D.new()
	_flag.position = Vector3(radius * 0.33, 0.08, -radius * 0.18)
	add_child(_flag)
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.13
	pole_mesh.bottom_radius = 0.17
	pole_mesh.height = 3.8
	pole.mesh = pole_mesh
	pole.position.y = 1.9
	pole.material_override = _material(Color("c7d5d3"))
	_flag.add_child(pole)
	var banner := MeshInstance3D.new()
	var banner_mesh := BoxMesh.new()
	banner_mesh.size = Vector3(2.1, 1.0, 0.12)
	banner.mesh = banner_mesh
	banner.position = Vector3(1.0, 3.15, 0.0)
	_flag_material = _material(NEUTRAL_COLOR, true)
	banner.material_override = _flag_material
	_flag.add_child(banner)

	_name_label = Label3D.new()
	_name_label.text = display_name
	_name_label.font_size = 12
	_name_label.outline_size = 2
	_name_label.modulate = Color("c9dcda")
	_name_label.position = Vector3(0.0, 0.75, radius * 0.7)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.fixed_size = false
	_name_label.pixel_size = 0.014
	add_child(_name_label)

	_state_label = Label3D.new()
	_state_label.text = district_kind.to_upper()
	_state_label.font_size = 11
	_state_label.outline_size = 2
	_state_label.modulate = Color("9fb7bd")
	_state_label.position = Vector3(0.0, 0.42, radius * 0.7)
	_state_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_state_label.fixed_size = false
	_state_label.pixel_size = 0.013
	add_child(_state_label)

	_owner_label = Label3D.new()
	_owner_label.font_size = 13
	_owner_label.outline_size = 2
	_owner_label.position = Vector3(radius * 0.33, 4.25, -radius * 0.18)
	_owner_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Flags and coloured territory are sufficient at match distance; retain this
	# subtle glyph only as a close-range ownership cue.
	_owner_label.fixed_size = false
	_owner_label.pixel_size = 0.014
	add_child(_owner_label)

	for stripe_index in range(4):
		var stripe := MeshInstance3D.new()
		var stripe_mesh := BoxMesh.new()
		stripe_mesh.size = Vector3(radius * 1.2, 0.08, 0.75)
		stripe.mesh = stripe_mesh
		stripe.rotation.y = deg_to_rad(35.0)
		stripe.position = Vector3(-radius * 0.32 + stripe_index * radius * 0.22, 0.17, 0.0)
		stripe.material_override = _material(Color("ff7a70"), true)
		stripe.visible = false
		add_child(stripe)
		_cut_stripes.append(stripe)


func _material(color: Color, emissive := false, transparent := false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	if transparent or color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.25
	return material
