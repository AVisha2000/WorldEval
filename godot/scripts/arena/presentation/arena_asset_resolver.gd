class_name ArenaAssetResolver
extends RefCounted

## Optional art bridge.  The spectator remains fully functional with procedural
## meshes, but adopts reviewed external scenes when a later asset intake places
## them at one of these stable project paths.

const UNIT_SCENES := {
	"commander": "res://assets/external/quaternius_medieval/units/commander.tscn",
	"worker": "res://assets/external/quaternius_medieval/units/worker.tscn",
	"scout": "res://assets/external/quaternius_medieval/units/scout.tscn",
	"guard": "res://assets/external/quaternius_medieval/units/guard.tscn",
	"militia": "res://assets/external/quaternius_medieval/units/militia.tscn"
}
const STRUCTURE_SCENES := {
	"keep": "res://assets/external/quaternius_medieval_village/buildings_fbx/Bell_Tower.fbx",
	"settlement": "res://assets/external/quaternius_medieval_village/buildings_fbx/Inn.fbx",
	"mine": "res://assets/external/quaternius_medieval_village/buildings_fbx/Blacksmith.fbx"
}


static func instantiate_unit(kind: String) -> Node3D:
	return _instantiate(UNIT_SCENES.get(kind, ""))


static func instantiate_structure(kind: String) -> Node3D:
	return _instantiate(STRUCTURE_SCENES.get(kind, ""))


static func _instantiate(path: String) -> Node3D:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var packed := load(path)
	if packed is PackedScene:
		var node := (packed as PackedScene).instantiate()
		return node if node is Node3D else null
	return null
