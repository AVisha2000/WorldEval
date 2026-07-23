class_name EmbodimentArenaMap
extends RefCounted

const ARENA_HALF_EXTENT_MT := 10_000
const OPERATOR_SPEED_MT_PER_TICK := 200


static func move(position_mt: Vector2i, raw_x: int, raw_y: int) -> Dictionary:
	var candidate := position_mt + Vector2i(
		divide_toward_zero(raw_x * OPERATOR_SPEED_MT_PER_TICK, 1000),
		divide_toward_zero(raw_y * OPERATOR_SPEED_MT_PER_TICK, 1000)
	)
	var clamped := Vector2i(
		clampi(candidate.x, -ARENA_HALF_EXTENT_MT, ARENA_HALF_EXTENT_MT),
		clampi(candidate.y, -ARENA_HALF_EXTENT_MT, ARENA_HALF_EXTENT_MT)
	)
	return {"position_mt": clamped, "contact": "clear" if candidate == clamped else "blocked_front"}


static func divide_toward_zero(numerator: int, denominator: int) -> int:
	assert(denominator != 0)
	var positive_denominator := absi(denominator)
	@warning_ignore("integer_division")
	var quotient: int = absi(numerator) / positive_denominator
	return -quotient if (numerator < 0) != (denominator < 0) else quotient
