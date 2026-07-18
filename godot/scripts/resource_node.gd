extends Node3D
class_name ArenaResourceNode

var resource_id := ""
var kind := "wood"
var quantity := 1
var yield_amount := 1
var _base_y := 0.0
var _phase := 0.0


func setup(id_value: String, kind_value: String, count: int, amount: int) -> void:
	resource_id = id_value
	kind = kind_value
	quantity = count
	yield_amount = amount
	name = id_value
	_build_visual()


func _ready() -> void:
	_base_y = position.y
	_phase = float(resource_id.hash() % 100) / 10.0


func _material(color: Color, roughness := 0.8, emission := Color.TRANSPARENT) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	if emission.a > 0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = 1.4
	return material


func _mesh_node(mesh: Mesh, material: Material, offset: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = offset
	add_child(node)
	return node


func _build_visual() -> void:
	match kind:
		"wood":
			var trunk := CylinderMesh.new()
			trunk.top_radius = 0.58
			trunk.bottom_radius = 0.78
			trunk.height = 4.2
			_mesh_node(trunk, _material(Color("76513b")), Vector3(0, 2.1, 0))

			var crown := SphereMesh.new()
			crown.radius = 2.6
			crown.height = 4.6
			_mesh_node(crown, _material(Color("2f7557"), 0.95), Vector3(0, 5.0, 0))

			var crown_top := SphereMesh.new()
			crown_top.radius = 1.8
			crown_top.height = 3.2
			_mesh_node(crown_top, _material(Color("3f9169"), 0.95), Vector3(0.9, 6.1, 0.4))
		"stone":
			var rock := SphereMesh.new()
			rock.radius = 1.9
			rock.height = 2.6
			var node := _mesh_node(rock, _material(Color("70808b"), 0.88), Vector3(0, 1.25, 0))
			node.scale = Vector3(1.15, 0.85, 0.95)

			var seam := BoxMesh.new()
			seam.size = Vector3(1.8, 0.12, 0.18)
			var seam_node := _mesh_node(seam, _material(Color("b4cad1"), 0.45), Vector3(0.15, 1.75, -1.0))
			seam_node.rotation.z = -0.3
		"food":
			var bush := SphereMesh.new()
			bush.radius = 1.75
			bush.height = 2.4
			_mesh_node(bush, _material(Color("316b4b"), 0.9), Vector3(0, 1.1, 0))

			for berry_index in range(7):
				var berry := SphereMesh.new()
				berry.radius = 0.24
				berry.height = 0.45
				var angle := float(berry_index) * TAU / 7.0
				var offset := Vector3(cos(angle) * 1.2, 1.2 + (berry_index % 2) * 0.55, sin(angle) * 1.2)
				_mesh_node(berry, _material(Color("d9566f"), 0.35, Color("802f55")), offset)


func harvest_once() -> int:
	if quantity <= 0:
		return 0
	quantity -= 1
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector3(0.72, 0.72, 0.72), 0.16)
	tween.tween_property(self, "scale", Vector3.ONE, 0.22)
	if quantity == 0:
		tween.tween_property(self, "scale", Vector3.ZERO, 0.3)
		tween.tween_callback(func() -> void: visible = false)
	return yield_amount


func _process(_delta: float) -> void:
	if kind == "food" and visible:
		rotation.y += 0.003

