extends SceneTree

const Interpolator := preload(
	"res://scripts/embodiment/presentation/preview/participant_preview_interpolator.gd"
)
const Publisher := preload(
	"res://scripts/embodiment/presentation/preview/embodiment_preview_publisher.gd"
)


class SceneStub extends Node:
	var snapshot: Dictionary
	var entity: Node3D

	func _init(initial: Dictionary) -> void:
		snapshot = initial
		var operator := Node3D.new()
		operator.name = "OperatorProjection"
		add_child(operator)
		entity = Node3D.new()
		entity.name = "VisibleEntity"
		add_child(entity)

	func snapshot_copy() -> Dictionary:
		return snapshot.duplicate(true)

	func projection_node(entity_id: String) -> Node3D:
		return entity if entity_id == "visible_resource" else null


func _init() -> void:
	if not is_equal_approx(Publisher.FRAME_INTERVAL_SECONDS, 1.0 / 30.0):
		_fail("preview_publisher_target_rate_invalid")
		return
	if Publisher.MAX_RECONNECT_ATTEMPTS != 5 \
			or not is_equal_approx(Publisher._reconnect_delay_seconds(0), 0.25) \
			or not is_equal_approx(Publisher._reconnect_delay_seconds(4), 4.0) \
			or not is_equal_approx(Publisher._reconnect_delay_seconds(40), 4.0):
		_fail("preview_publisher_reconnect_bounds_invalid")
		return
	var ticket := "T".repeat(43)
	if Publisher._endpoint_for(
		"ws://127.0.0.1:8000/ws/embodiment/%s" % ticket, ticket
	) != "ws://127.0.0.1:8000/internal/embodiment/preview/%s/stream" % ticket:
		_fail("preview_publisher_persistent_endpoint_invalid")
		return
	if not Publisher._endpoint_for(
		"https://127.0.0.1:8000/ws/embodiment/%s" % ticket, ticket
	).is_empty():
		_fail("preview_publisher_accepted_non_websocket_gateway")
		return
	var before := _snapshot(10, 1, [0, 0], 0, [0, -1000])
	var after := _snapshot(11, 1, [1000, 0], 2000, [1000, -1000])
	var scene := SceneStub.new(before)
	root.add_child(scene)
	var interpolator = Interpolator.new()
	interpolator.advance(scene, 0.0)
	scene.snapshot = after
	interpolator.advance(scene, 0.0)
	var operator := scene.get_node("OperatorProjection") as Node3D
	if not is_equal_approx(operator.position.x, 0.0):
		_fail("preview_interpolation_did_not_start_at_previous_projection")
		return
	interpolator.advance(scene, 0.05)
	if not is_equal_approx(operator.position.x, 0.5) \
			or not is_equal_approx(operator.rotation.y, -PI * 0.25):
		_fail("preview_operator_interpolation_invalid")
		return
	if not is_equal_approx(scene.entity.position.x, 0.5):
		_fail("preview_visible_entity_interpolation_invalid")
		return
	# Source snapshots remain untouched: interpolation is presentation-only and cannot feed back
	# into authority, evidence, or the next participant observation.
	if scene.snapshot != after:
		_fail("preview_interpolation_mutated_safe_snapshot")
		return
	print("participant_preview_interpolator_headless_runner: PASS")
	quit(0)


func _snapshot(
		tick: int, observation_seq: int, operator_position: Array, operator_heading: int,
		entity_position: Array,
) -> Dictionary:
	return {
		"participant_id": "participant_0",
		"tick": tick,
		"observation_seq": observation_seq,
		"operator": {
			"position_mt": operator_position,
			"heading_milli": operator_heading,
		},
		"entities": [{
			"id": "visible_resource",
			"kind": "resource",
			"position_mt": entity_position,
			"heading_milli": 0,
		}],
	}


func _fail(code: String) -> void:
	push_error(code)
	quit(1)
