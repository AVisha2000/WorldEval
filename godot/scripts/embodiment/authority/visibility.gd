class_name EmbodimentVisibility
extends RefCounted

const RELATIVE_BEARINGS := [
	"front", "front_right", "right", "back_right",
	"back", "back_left", "left", "front_left",
]


static func relative_bearing(offset: Vector2i, heading: int) -> String:
	return RELATIVE_BEARINGS[posmod(world_sector(offset) - heading, 8)]


static func world_sector(offset: Vector2i) -> int:
	var x: int = offset.x
	var y: int = offset.y
	var ax: int = abs(x)
	var ay: int = abs(y)
	if ax * 2 < ay:
		return 0 if y < 0 else 4
	if ay * 2 < ax:
		return 2 if x > 0 else 6
	if x >= 0 and y < 0:
		return 1
	if x > 0 and y >= 0:
		return 3
	if x <= 0 and y > 0:
		return 5
	return 7


static func distance_band(offset: Vector2i, touching_radius_mt: int) -> String:
	var distance := maxi(abs(offset.x), abs(offset.y))
	if distance <= touching_radius_mt:
		return "touching"
	if distance <= 3500:
		return "near"
	if distance <= 9000:
		return "medium"
	return "far"
