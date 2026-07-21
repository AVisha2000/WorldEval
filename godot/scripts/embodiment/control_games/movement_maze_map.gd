class_name EmbodimentMovementMazeMapV2
extends RefCounted


const PROTOCOL_VERSION := "llm-controller/0.2.0"
const TASK_ID := "movement-maze-v0"
const MAP_VERSION := "movement-maze-map/1.0.0"
const TILE_MT := 1000
const START_TILE := Vector2i(1, 5)
const CHECKPOINT_TILES := [
	Vector2i(1, 1),
	Vector2i(5, 1),
	Vector2i(5, 3),
	Vector2i(3, 5),
]
const BEACON_TILE := Vector2i(3, 3)

# Only these tiles are traversable. Each ordered leg is visible along a legal cardinal corridor;
# the final northbound leg makes the operator visibly reverse without crossing a future marker.
const LEGAL_TILES := [
	Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1), Vector2i(5, 1),
	Vector2i(1, 2), Vector2i(3, 2), Vector2i(5, 2),
	Vector2i(1, 3), Vector2i(3, 3), Vector2i(4, 3), Vector2i(5, 3),
	Vector2i(1, 4), Vector2i(3, 4), Vector2i(4, 4), Vector2i(5, 4),
	Vector2i(1, 5), Vector2i(2, 5), Vector2i(3, 5), Vector2i(4, 5), Vector2i(5, 5),
]


static func start_position_mt() -> Vector2i:
	return START_TILE * TILE_MT


static func checkpoint_position_mt(index: int) -> Vector2i:
	assert(index >= 0 and index < CHECKPOINT_TILES.size())
	return CHECKPOINT_TILES[index] * TILE_MT


static func beacon_position_mt() -> Vector2i:
	return BEACON_TILE * TILE_MT


static func is_legal_position_mt(position_mt: Vector2i) -> bool:
	if posmod(position_mt.x, TILE_MT) != 0 or posmod(position_mt.y, TILE_MT) != 0:
		return false
	return (position_mt / TILE_MT) in LEGAL_TILES


static func target_position_mt(checkpoint_index: int) -> Vector2i:
	if checkpoint_index < CHECKPOINT_TILES.size():
		return checkpoint_position_mt(checkpoint_index)
	return beacon_position_mt()


static func target_visible_id(checkpoint_index: int) -> String:
	if checkpoint_index < CHECKPOINT_TILES.size():
		return "v_checkpoint_%d" % (checkpoint_index + 1)
	return "v_final_beacon"


static func target_kind(checkpoint_index: int) -> String:
	return "checkpoint" if checkpoint_index < CHECKPOINT_TILES.size() else "beacon"


static func shortest_legal_route_mt() -> int:
	var total_tiles := 0
	var source := START_TILE
	var ordered_targets: Array[Vector2i] = []
	ordered_targets.assign(CHECKPOINT_TILES)
	ordered_targets.append(BEACON_TILE)
	for target: Vector2i in ordered_targets:
		var leg_tiles := _shortest_leg_tiles(source, target)
		assert(leg_tiles >= 0, "movement-maze ordered target is unreachable")
		total_tiles += leg_tiles
		source = target
	return total_tiles * TILE_MT


static func _shortest_leg_tiles(source: Vector2i, target: Vector2i) -> int:
	var frontier: Array[Vector2i] = [source]
	var distances := {source: 0}
	var cursor := 0
	while cursor < frontier.size():
		var current: Vector2i = frontier[cursor]
		cursor += 1
		if current == target:
			return int(distances[current])
		for delta: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
			var candidate := current + delta
			if candidate in LEGAL_TILES and not distances.has(candidate):
				distances[candidate] = int(distances[current]) + 1
				frontier.append(candidate)
	return -1
