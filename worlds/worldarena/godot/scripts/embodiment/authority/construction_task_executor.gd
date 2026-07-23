class_name EmbodimentConstructionTaskExecutor
extends RefCounted

## Converts an approved Construction milestone into ordinary controller input. Exact positions
## never leave Godot; the model only selects a participant-visible task name.

const Visibility := preload("res://scripts/embodiment/authority/visibility.gd")

static func control_for_tick(authority: Object, task_id: String) -> Dictionary:
	if task_id == "wait":
		return _control(0, 0, 0, false)
	var target := _target_position(authority, task_id)
	if not _in_range(authority, target, task_id):
		return _approach(authority, target)
	var turn := _turn_to(authority.operator_heading, Visibility.world_sector(target - authority.operator_position_mt))
	if turn != 0:
		return _control(0, 0, turn, false)
	return _control(0, 0, 0, true)

static func is_complete(authority: Object, task_id: String) -> bool:
	match task_id:
		"gather_materials": return authority.inventory_material_units >= authority.InteractionSystem.CARRY_LIMIT_UNITS or authority.resource_units_remaining <= 0
		"deliver_materials": return authority.inventory_material_units == 0 and authority.deposited_material_units > 0
		"build_barricade": return bool(authority.barricade_complete)
	return false

static func _target_position(authority: Object, task_id: String) -> Vector2i:
	match task_id:
		"gather_materials": return authority.resource_position_mt
		"deliver_materials": return authority.relay_position_mt
		"build_barricade": return authority.build_pad_position_mt
	return authority.operator_position_mt

static func _in_range(authority: Object, target: Vector2i, task_id: String) -> bool:
	var radius: int = authority.ConstructionSystem.BUILD_RANGE_MT if task_id == "build_barricade" else authority.InteractionSystem.INTERACTION_RANGE_MT
	var offset: Vector2i = target - authority.operator_position_mt
	return offset.x * offset.x + offset.y * offset.y <= radius * radius

static func _approach(authority: Object, target: Vector2i) -> Dictionary:
	var turn := _turn_to(authority.operator_heading, Visibility.world_sector(target - authority.operator_position_mt))
	return _control(0, 0, turn, false) if turn != 0 else _control(0, 1000, 0, false)

static func _turn_to(current: int, desired: int) -> int:
	var delta := posmod(desired - current, 8)
	if delta == 0: return 0
	return 1000 if delta <= 4 else -1000

static func _control(move_x: int, move_y: int, look_x: int, interact: bool) -> Dictionary:
	return {"move_x": move_x, "move_y": move_y, "look_x": look_x, "look_y": 0, "duration_ticks": 1, "buttons": {"interact": interact, "primary": false, "guard": false, "dash": false, "ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false}}
