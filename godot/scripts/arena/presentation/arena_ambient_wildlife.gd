class_name ArenaAmbientWildlife
extends Node3D

## Cosmetic-only wildlife. It never reads or writes ArenaSimulation state.
## LimboAI is optional: when its BTPlayer class is available the adapter exposes
## a child hook for a later reviewed behavior tree; deterministic wandering is
## always the fallback and remains replay-independent.

var anchor := Vector3.ZERO
var phase := 0.0
var _body: MeshInstance3D
var _limbo_hook: Node


func setup(world_anchor: Vector3, seed: int) -> void:
	anchor = world_anchor
	phase = float(seed % 97) * 0.31
	position = anchor
	_build_visual()
	if ClassDB.class_exists(&"BTPlayer"):
		# A BTPlayer without a reviewed tree logs an execution error. Keep a
		# deterministic adapter marker until a tree resource is explicitly wired.
		_limbo_hook = Node.new()
		_limbo_hook.name = "LimboAIAvailableCosmeticAdapter"
		_limbo_hook.set_meta("limboai_class_available", true)
		_limbo_hook.set_meta("cosmetic_only", true)
		add_child(_limbo_hook)


func _process(delta: float) -> void:
	phase += delta * 0.45
	# Stable analytic movement: no pathfinding, RNG, collision, or simulation IO.
	position = anchor + Vector3(sin(phase) * 1.8, 0.12 + abs(sin(phase * 1.7)) * 0.08, cos(phase * 0.77) * 1.2)
	rotation.y = phase + PI * 0.5


func _build_visual() -> void:
	_body = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.38
	mesh.height = 0.72
	mesh.radial_segments = 8
	_body.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("a8865b")
	material.roughness = 0.95
	_body.material_override = material
	add_child(_body)
	for side in [-1.0, 1.0]:
		var leg := MeshInstance3D.new()
		var leg_mesh := CylinderMesh.new()
		leg_mesh.top_radius = 0.055
		leg_mesh.bottom_radius = 0.07
		leg_mesh.height = 0.42
		leg.mesh = leg_mesh
		leg.position = Vector3(side * 0.2, -0.30, 0.12)
		leg.material_override = material
		add_child(leg)
