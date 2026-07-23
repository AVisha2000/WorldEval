class_name EmbodimentControllerExecutor
extends RefCounted

const ArenaMap := preload("res://scripts/embodiment/authority/arena_map.gd")
const FORWARD_BASIS := [
	Vector2i(0, -1000), Vector2i(707, -707), Vector2i(1000, 0), Vector2i(707, 707),
	Vector2i(0, 1000), Vector2i(-707, 707), Vector2i(-1000, 0), Vector2i(-707, -707),
]


static func apply_tick(authority: Object, control: Dictionary, first_tick: bool) -> void:
	authority.look_accumulator += int(control.look_x)
	while authority.look_accumulator >= 1000:
		authority.operator_heading = posmod(authority.operator_heading + 1, 8)
		authority.look_accumulator -= 1000
	while authority.look_accumulator <= -1000:
		authority.operator_heading = posmod(authority.operator_heading - 1, 8)
		authority.look_accumulator += 1000
	var buttons: Dictionary = control.buttons
	if bool(buttons.cancel):
		authority.beacon_hold_ticks = 0
	var forward: Vector2i = FORWARD_BASIS[authority.operator_heading]
	var right: Vector2i = FORWARD_BASIS[posmod(authority.operator_heading + 2, 8)]
	var raw_x := ArenaMap.divide_toward_zero(right.x * int(control.move_x) + forward.x * int(control.move_y), 1000)
	var raw_y := ArenaMap.divide_toward_zero(right.y * int(control.move_x) + forward.y * int(control.move_y), 1000)
	var greatest := maxi(abs(raw_x), abs(raw_y))
	if greatest > 1000:
		raw_x = ArenaMap.divide_toward_zero(raw_x * 1000, greatest)
		raw_y = ArenaMap.divide_toward_zero(raw_y * 1000, greatest)
	var movement := ArenaMap.move(authority.operator_position_mt, raw_x, raw_y)
	authority.operator_position_mt = movement.position_mt
	authority.contact = movement.contact
	# Edge buttons are sampled only on the first tick. Stage A has no unlocked edge ability.
	if first_tick and bool(buttons.dash):
		pass
