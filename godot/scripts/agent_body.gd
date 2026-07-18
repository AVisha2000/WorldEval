extends CharacterBody3D
class_name ArenaAgentBody

signal destination_reached

@export var move_speed: float = 20.0

var _target := Vector3.ZERO
var _has_target := false
var _activity := "AWAITING DIRECTIVE"
var _body_material: StandardMaterial3D
var _activity_label: Label3D


func _ready() -> void:
	_build_visual()


func _build_visual() -> void:
	_body_material = StandardMaterial3D.new()
	_body_material.albedo_color = Color("f4c95d")
	_body_material.metallic = 0.15
	_body_material.roughness = 0.32

	var body := MeshInstance3D.new()
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 1.1
	body_mesh.height = 3.6
	body.mesh = body_mesh
	body.material_override = _body_material
	body.position.y = 2.0
	add_child(body)

	var visor := MeshInstance3D.new()
	var visor_mesh := BoxMesh.new()
	visor_mesh.size = Vector3(1.55, 0.42, 0.24)
	visor.mesh = visor_mesh
	visor.position = Vector3(0, 2.65, -1.02)
	var visor_material := StandardMaterial3D.new()
	visor_material.albedo_color = Color("182f42")
	visor_material.metallic = 0.8
	visor_material.roughness = 0.15
	visor.material_override = visor_material
	add_child(visor)

	var pack := MeshInstance3D.new()
	var pack_mesh := BoxMesh.new()
	pack_mesh.size = Vector3(1.3, 1.65, 0.55)
	pack.mesh = pack_mesh
	pack.position = Vector3(0, 1.65, 0.95)
	var pack_material := StandardMaterial3D.new()
	pack_material.albedo_color = Color("304c45")
	pack_material.roughness = 0.9
	pack.material_override = pack_material
	add_child(pack)

	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 1.65
	ring_mesh.outer_radius = 1.85
	ring.mesh = ring_mesh
	ring.position.y = 0.18
	var ring_material := StandardMaterial3D.new()
	ring_material.albedo_color = Color("69f0d0")
	ring_material.emission_enabled = true
	ring_material.emission = Color("36bfa8")
	ring_material.emission_energy_multiplier = 1.8
	ring.material_override = ring_material
	add_child(ring)

	var name_label := Label3D.new()
	name_label.text = "SOL"
	name_label.font_size = 42
	name_label.outline_size = 10
	name_label.modulate = Color("fff3c4")
	name_label.position.y = 5.25
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(name_label)

	_activity_label = Label3D.new()
	_activity_label.text = _activity
	_activity_label.font_size = 24
	_activity_label.outline_size = 8
	_activity_label.modulate = Color("8ee8d4")
	_activity_label.position.y = 4.55
	_activity_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(_activity_label)


func walk_to(destination: Vector3, activity: String) -> void:
	_target = destination
	_target.y = global_position.y
	_has_target = true
	set_activity(activity)


func set_activity(value: String) -> void:
	_activity = value.to_upper()
	if _activity_label:
		_activity_label.text = _activity


func _physics_process(_delta: float) -> void:
	if not _has_target:
		velocity = Vector3.ZERO
		return

	var offset := _target - global_position
	offset.y = 0
	if offset.length() <= 1.25:
		global_position = Vector3(_target.x, global_position.y, _target.z)
		velocity = Vector3.ZERO
		_has_target = false
		destination_reached.emit()
		return

	var direction := offset.normalized()
	velocity = direction * move_speed
	look_at(Vector3(_target.x, global_position.y, _target.z), Vector3.UP)
	move_and_slide()

