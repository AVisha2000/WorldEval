extends Node3D

const AssetResolver := preload("res://scripts/arena/presentation/arena_asset_resolver.gd")

# A deliberately small visual-only actor. The simulation owns this node's state;
# this script only makes sparse map units read as people at the arena camera scale.
var unit_id := ""
var faction_id := "neutral"
var unit_type := "worker"
var _faction_color := Color("687884")
var _body_material: StandardMaterial3D
var _accent_material: StandardMaterial3D
var _ring_material: StandardMaterial3D
var _class_label: Label3D
var _status_label: Label3D
var _health_label: Label3D
var _health_back: MeshInstance3D
var _health_fill: MeshInstance3D
var _model_root: Node3D
var _left_leg: Node3D
var _right_leg: Node3D
var _left_arm: Node3D
var _right_arm: Node3D
var _tool: Node3D
var _head: Node3D
var _move_tween: Tween
var _navigation_agent: NavigationAgent3D
var _target_position := Vector3.ZERO
var _walk_phase := 0.0
var _combat_phase := 0.0
var _action_phase := 0.0
var _damage_reaction := 0.0
var _moving := false
var _is_traversing := false
var _in_combat := false
var _task := ""
var _last_health := 100

# Replay snapshots are deliberately sparse. Keep enough travel on screen for a
# spectator to read an agent as walking across the island, while still allowing
# genuine spawn/reset corrections to land immediately.
const REPLAY_WALK_SPEED := 28.0
const MIN_REPLAY_TRAVEL_TIME := 0.55
const MAX_REPLAY_TRAVEL_TIME := 5.0
const TELEPORT_DISTANCE := 220.0


func setup(state: Dictionary, color: Color) -> void:
	unit_id = str(state.get("id", "unit"))
	faction_id = str(state.get("faction_id", "neutral"))
	unit_type = str(state.get("unit_type", "worker"))
	_faction_color = color
	_target_position = state.get("position", Vector3.ZERO)
	position = _target_position
	_build_visual()
	apply_state(state)


func apply_state(state: Dictionary) -> void:
	var next_position: Vector3 = state.get("position", _target_position)
	_move_to(next_position)
	visible = bool(state.get("visible", true))
	if _status_label == null:
		return

	var health := int(state.get("health", 100))
	var max_health := maxi(1, int(state.get("max_health", 100)))
	var selected := bool(state.get("selected", false))
	var in_combat := bool(state.get("in_combat", false))
	_in_combat = in_combat
	_task = str(state.get("task", state.get("action", ""))).to_lower()
	if health < _last_health:
		# A brief purely visual hit reaction makes damage legible in a replay.
		_damage_reaction = 0.42
	_last_health = health
	# At spectator zoom, health/task glyphs on every worker turn settlements into
	# an unreadable cloud. Keep world labels for selected, fighting, or damaged units.
	var show_health := selected or in_combat or health < max_health * 0.55
	var health_ratio := clampf(float(health) / float(max_health), 0.0, 1.0)
	_health_label.text = "%d / %d" % [health, max_health]
	_health_label.visible = show_health
	_health_back.visible = show_health
	_health_fill.visible = show_health
	_health_fill.scale.x = maxf(0.02, health_ratio)
	_health_fill.position.x = -2.6 + 2.6 * maxf(0.02, health_ratio)
	_class_label.visible = selected or in_combat

	# Status copy is intentionally reserved for truly exceptional conditions.
	_status_label.visible = false
	if bool(state.get("starving", false)):
		_status_label.text = "STARVING"
		_status_label.modulate = Color("ffb35c")
		_status_label.visible = true
	elif not bool(state.get("supplied", true)):
		_status_label.text = "NO SUPPLY"
		_status_label.modulate = Color("ff7a70")
		_status_label.visible = true
	elif selected or in_combat:
		var task_badge := _task_badge(_task)
		if not task_badge.is_empty():
			_status_label.text = task_badge
			_status_label.modulate = _faction_color.lightened(0.32)
			_status_label.visible = true


func bubble_anchor() -> Vector3:
	return global_position + Vector3(0.0, _character_height() + 1.15, 0.0)


func _process(delta: float) -> void:
	if _model_root == null:
		return
	var horizontal_delta := _target_position - position
	horizontal_delta.y = 0.0
	# The tween's completion callback is the source of truth during the final
	# few frames, where interpolation may have already made the remaining delta
	# too small for a position-only test to register.
	_moving = _is_traversing or horizontal_delta.length_squared() > 0.012
	if _moving:
		_walk_phase += delta * 10.0
	if _in_combat:
		_combat_phase += delta * 8.5
	_action_phase += delta * (7.5 if _is_working() else 3.6)
	_damage_reaction = maxf(0.0, _damage_reaction - delta)
	var stride: float = sin(_walk_phase) * (0.34 if _moving else 0.0)
	var bob: float = abs(sin(_walk_phase * 2.0)) * (0.11 if _moving else 0.0)
	var left_arm_swing := -stride * 0.72
	var right_arm_swing := stride * 0.72
	var root_z := 0.0
	var root_x := 0.0
	if _in_combat:
		# A readable attack beat: lean in, strike, recover. This has no simulation
		# meaning; combat still comes entirely from the authoritative snapshot.
		var strike := maxf(0.0, sin(_combat_phase))
		bob += strike * 0.12
		root_z = sin(_combat_phase * 0.5) * 0.09
		root_x = -strike * 0.16
		right_arm_swing = -0.35 - strike * 1.15
		left_arm_swing = 0.18 + strike * 0.34
		if _tool != null:
			_tool.rotation.z = -0.2 - strike * 0.6
	elif not _moving and _is_working():
		var work_beat := maxf(0.0, sin(_action_phase))
		var is_building := _task.contains("build") or _task.contains("repair")
		bob += work_beat * 0.075
		root_x = -work_beat * (0.10 if is_building else 0.16)
		right_arm_swing = -0.22 - work_beat * (1.05 if is_building else 1.30)
		left_arm_swing = 0.12 + work_beat * 0.42
		if _tool != null:
			_tool.rotation.z = -0.18 - work_beat * 0.78
	elif not _moving and _is_scouting():
		# Scouts make a small, deliberate sweep rather than standing as markers.
		root_z = sin(_action_phase * 0.62) * 0.11
		if _head != null:
			_head.rotation.y = sin(_action_phase * 0.62) * 0.42
	elif _tool != null:
		_tool.rotation.z = lerpf(_tool.rotation.z, 0.0, minf(1.0, delta * 7.0))
	if _damage_reaction > 0.0:
		var hit := sin((0.42 - _damage_reaction) * 28.0)
		root_z += hit * 0.12
		root_x += 0.08
		_model_root.scale = Vector3.ONE * (1.0 + abs(hit) * 0.055)
	else:
		_model_root.scale = _model_root.scale.lerp(Vector3.ONE, minf(1.0, delta * 10.0))
	_model_root.rotation.z = lerpf(_model_root.rotation.z, root_z, minf(1.0, delta * 12.0))
	_model_root.rotation.x = lerpf(_model_root.rotation.x, root_x, minf(1.0, delta * 12.0))
	_model_root.position.y = bob
	if _left_leg != null:
		_left_leg.rotation.x = stride
		_right_leg.rotation.x = -stride
	if _left_arm != null:
		_left_arm.rotation.z = left_arm_swing
		_right_arm.rotation.z = right_arm_swing


func _is_working() -> bool:
	if unit_type != "worker":
		return false
	return _task.contains("gather") or _task.contains("collect") or _task.contains("chop") or _task.contains("mine") or _task.contains("build") or _task.contains("repair") or _task.contains("haul")


func _is_scouting() -> bool:
	return unit_type == "scout" and (_task.is_empty() or _task.contains("scout") or _task.contains("explore") or _task.contains("inspect"))


func _task_badge(task: String) -> String:
	var normalized := task.to_lower()
	if normalized.contains("trade") or normalized.contains("negotiate") or normalized.contains("envoy"):
		return "TRADE"
	if normalized.contains("build") or normalized.contains("repair") or normalized.contains("workshop") or normalized.contains("shelter") or normalized.contains("palisade"):
		return "BUILD"
	if normalized.contains("fight") or normalized.contains("attack") or normalized.contains("guard") or normalized.contains("defend") or normalized.contains("ambush") or normalized.contains("counter"):
		return "FIGHT"
	if normalized.contains("scout") or normalized.contains("survey") or normalized.contains("inspect") or normalized.contains("mark"):
		return "SCOUT"
	if normalized.contains("gather") or normalized.contains("collect") or normalized.contains("chop") or normalized.contains("mine") or normalized.contains("haul") or normalized.contains("forage"):
		return "GATHER"
	return ""


func _move_to(next_position: Vector3) -> void:
	if next_position.is_equal_approx(_target_position):
		return
	_target_position = next_position
	if _navigation_agent != null:
		# Authoritative replay positions remain the destination.  The agent is a
		# cosmetic route hook for imported-world navigation meshes when available.
		_navigation_agent.target_position = _target_position
	if _move_tween != null and _move_tween.is_valid():
		_move_tween.kill()
		_is_traversing = false
	var travel := position.distance_to(_target_position)
	if travel > TELEPORT_DISTANCE:
		position = _target_position
		_is_traversing = false
		return
	if travel < 0.08:
		position = _target_position
		_is_traversing = false
		return

	# The low-poly model's forward axis is -Z. Face it toward the next authored
	# presentation position before starting the traversal, so a replay reads as
	# intentional movement rather than a sliding map marker.
	var direction := _target_position - position
	direction.y = 0.0
	if direction.length_squared() > 0.0001 and _model_root != null:
		_model_root.rotation.y = atan2(-direction.x, -direction.z)

	_is_traversing = true
	var destination := _target_position
	_move_tween = create_tween()
	_move_tween.set_trans(Tween.TRANS_SINE)
	_move_tween.set_ease(Tween.EASE_IN_OUT)
	_move_tween.tween_property(self, "position", _target_position, clampf(travel / REPLAY_WALK_SPEED, MIN_REPLAY_TRAVEL_TIME, MAX_REPLAY_TRAVEL_TIME))
	_move_tween.finished.connect(func() -> void:
		if _target_position.is_equal_approx(destination):
			_is_traversing = false
	)


func _build_visual() -> void:
	_body_material = _material(Color("26343a"))
	_accent_material = _material(_faction_color)
	_ring_material = _material(_faction_color.lightened(0.18), true)
	_model_root = Node3D.new()
	add_child(_model_root)
	_navigation_agent = NavigationAgent3D.new()
	_navigation_agent.path_desired_distance = 0.4
	_navigation_agent.target_desired_distance = 0.55
	add_child(_navigation_agent)
	var imported_model := AssetResolver.instantiate_unit(unit_type)
	if imported_model != null:
		_model_root.add_child(imported_model)
		imported_model.scale = Vector3.ONE * (1.35 if unit_type == "commander" else 1.08)
		_build_ground_marker(1.7 if unit_type == "commander" else 1.45)
		_build_labels(_character_height())
		return

	var height := _character_height()
	# The compact battlefield keeps actors hero-sized and readable without UI-only
	# board markers. Commanders remain slightly taller than their squads.
	var scale_factor := 1.92 if unit_type == "commander" else 1.62
	_build_humanoid(height, scale_factor)
	_build_equipment(height, scale_factor)
	_build_ground_marker(scale_factor)
	_build_labels(height)


func _build_humanoid(height: float, scale_factor: float) -> void:
	var leg_length := height * 0.38
	var torso_height := height * 0.38
	var hip_y := leg_length
	var torso_y := hip_y + torso_height * 0.5
	var head_y := hip_y + torso_height + height * 0.12

	_left_leg = _part(_model_root, _box(Vector3(0.28, leg_length, 0.32)), _body_material, Vector3(-0.24 * scale_factor, leg_length * 0.5, 0.0))
	_right_leg = _part(_model_root, _box(Vector3(0.28, leg_length, 0.32)), _body_material, Vector3(0.24 * scale_factor, leg_length * 0.5, 0.0))
	_part(_model_root, _tapered_mesh(0.52 * scale_factor, 0.7 * scale_factor, torso_height), _body_material, Vector3(0.0, torso_y, 0.0))
	_head = _part(_model_root, _sphere(0.42 * scale_factor), _accent_material, Vector3(0.0, head_y, 0.0))

	# Shoulder accents create a faction read without turning each actor into a UI marker.
	_part(_model_root, _box(Vector3(1.16 * scale_factor, 0.13, 0.18)), _accent_material, Vector3(0.0, hip_y + torso_height * 0.78, 0.0))
	_left_arm = _part(_model_root, _box(Vector3(0.18, 0.72 * scale_factor, 0.18)), _body_material, Vector3(-0.72 * scale_factor, hip_y + torso_height * 0.48, 0.0), Vector3(0.0, 0.0, -0.25))
	_right_arm = _part(_model_root, _box(Vector3(0.18, 0.72 * scale_factor, 0.18)), _body_material, Vector3(0.72 * scale_factor, hip_y + torso_height * 0.48, 0.0), Vector3(0.0, 0.0, 0.25))


func _build_equipment(height: float, scale_factor: float) -> void:
	match unit_type:
		"commander":
			_part(_model_root, _box(Vector3(0.82, 1.15, 0.14)), _accent_material, Vector3(0.0, height * 0.53, 0.42))
			_part(_model_root, _box(Vector3(0.14, 1.75, 0.14)), _accent_material, Vector3(0.85, height * 0.65, 0.0), Vector3(0.0, 0.0, -0.16))
		"worker":
			_part(_model_root, _box(Vector3(0.86, 0.72, 0.28)), _accent_material, Vector3(0.0, height * 0.57, 0.46))
			_tool = _part(_model_root, _box(Vector3(0.12, 1.65, 0.12)), _accent_material, Vector3(0.76, height * 0.54, 0.0), Vector3(0.0, 0.0, -0.45))
		"scout":
			_part(_model_root, _box(Vector3(0.62, 0.56, 0.2)), _accent_material, Vector3(0.0, height * 0.62, 0.43))
			_part(_model_root, _box(Vector3(0.06, 0.72, 0.06)), _accent_material, Vector3(0.0, height + 0.28, 0.0))
		"guard":
			_part(_model_root, _box(Vector3(0.18, 1.18, 0.92)), _accent_material, Vector3(-0.88, height * 0.55, 0.0))
			_part(_model_root, _box(Vector3(0.1, 2.1, 0.1)), _accent_material, Vector3(0.88, height * 0.67, 0.0), Vector3(0.0, 0.0, -0.08))
		"militia":
			_part(_model_root, _box(Vector3(0.1, 2.0, 0.1)), _accent_material, Vector3(0.88, height * 0.64, 0.0), Vector3(0.0, 0.0, -0.17))
		"siege":
			_part(_model_root, _box(Vector3(1.42, 0.5, 1.65)), _body_material, Vector3(0.0, height * 0.36, 0.25))
			_part(_model_root, _box(Vector3(0.2, 0.22, 1.55)), _accent_material, Vector3(0.0, height * 0.62, -0.68), Vector3(-0.25, 0.0, 0.0))


func _build_ground_marker(scale_factor: float) -> void:
	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	var ring_radius := 1.24 * scale_factor
	ring_mesh.inner_radius = ring_radius - 0.055
	ring_mesh.outer_radius = ring_radius
	ring_mesh.rings = 20
	ring_mesh.ring_segments = 4
	ring.mesh = ring_mesh
	ring.material_override = _ring_material
	ring.position.y = 0.06
	add_child(ring)


func _build_labels(height: float) -> void:
	_class_label = _label(_class_glyph(), height + 2.35, 18)
	_class_label.modulate = _faction_color.lightened(0.28)
	_class_label.visible = unit_type == "commander"
	_build_health_bar(height + 1.32)
	_health_label = _label("", height + 1.67, 17)
	_health_label.modulate = Color("edf7ed")
	_status_label = _label("", height + 0.72, 17)
	_status_label.modulate = Color("9fe3d2")


func _build_health_bar(y_position: float) -> void:
	_health_back = MeshInstance3D.new()
	var back_mesh := QuadMesh.new()
	back_mesh.size = Vector2(5.2, 0.58)
	_health_back.mesh = back_mesh
	_health_back.position = Vector3(0, y_position, 0)
	_health_back.material_override = _ui_material(Color("091219"))
	_health_back.visible = false
	add_child(_health_back)
	_health_fill = MeshInstance3D.new()
	var fill_mesh := QuadMesh.new()
	fill_mesh.size = Vector2(5.2, 0.64)
	_health_fill.mesh = fill_mesh
	_health_fill.position = Vector3(0, y_position, -0.02)
	_health_fill.material_override = _ui_material(Color("65d681"))
	_health_fill.visible = false
	add_child(_health_fill)


func _part(parent: Node3D, mesh: Mesh, material: Material, part_position: Vector3, part_rotation := Vector3.ZERO) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = part_position
	pivot.rotation = part_rotation
	parent.add_child(pivot)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	pivot.add_child(instance)
	return pivot


func _label(text_value: String, y_position: float, font_size_value: int) -> Label3D:
	var label := Label3D.new()
	label.text = text_value
	label.font_size = font_size_value
	label.outline_size = 4
	label.position.y = y_position
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.055
	label.visible = false
	add_child(label)
	return label


func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	return mesh


func _tapered_mesh(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = 8
	mesh.rings = 1
	return mesh


func _character_height() -> float:
	match unit_type:
		"commander": return 5.15
		"scout": return 3.65
		"guard": return 4.15
		"militia": return 3.85
		"siege": return 4.25
		_: return 3.75


func _class_glyph() -> String:
	match unit_type:
		"commander": return "COMMANDER"
		"worker": return "WORKER"
		"scout": return "SCOUT"
		"militia": return "MILITIA"
		"guard": return "GUARD"
		"siege": return "SIEGE"
		_: return "UNIT"


func _material(color: Color, emissive := false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	material.metallic = 0.04
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 0.72
	return material


func _ui_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.no_depth_test = true
	return material
