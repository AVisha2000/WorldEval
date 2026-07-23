class_name ParticipantPreviewInterpolator
extends RefCounted

## Presentation-only tweening between participant-filtered authority snapshots.
##
## The presentation scene remains the privacy boundary. This helper sees only `snapshot_copy()`
## output and moves only its projection nodes; it never reads authority, advances ticks, or writes
## a snapshot back into the scene. At the next authoritative presentation update, the scene remains
## the source of truth and this helper begins a new visual tween.

const AUTHORITY_TICK_SECONDS := 0.1
const MT_PER_WORLD_UNIT := 1000.0

var _before: Dictionary = {}
var _after: Dictionary = {}
var _elapsed_seconds := 0.0
var _duration_seconds := AUTHORITY_TICK_SECONDS


func advance(scene: Node, delta: float) -> void:
	if scene == null or not scene.has_method("snapshot_copy") or delta < 0.0:
		return
	var candidate: Variant = scene.call("snapshot_copy")
	if not _eligible(candidate):
		return
	var snapshot: Dictionary = candidate
	if _after.is_empty():
		_before = snapshot.duplicate(true)
		_after = snapshot.duplicate(true)
	elif _is_newer(snapshot, _after):
		_before = _after.duplicate(true)
		_after = snapshot.duplicate(true)
		_elapsed_seconds = 0.0
		var tick_delta := maxi(1, int(_after.tick) - int(_before.tick))
		_duration_seconds = float(tick_delta) * AUTHORITY_TICK_SECONDS
	_elapsed_seconds = minf(_duration_seconds, _elapsed_seconds + delta)
	_apply(scene, _elapsed_seconds / _duration_seconds if _duration_seconds > 0.0 else 1.0)


func reset() -> void:
	_before.clear()
	_after.clear()
	_elapsed_seconds = 0.0
	_duration_seconds = AUTHORITY_TICK_SECONDS


func _apply(scene: Node, progress: float) -> void:
	if _before.is_empty() or _after.is_empty():
		return
	var operator := scene.get_node_or_null("OperatorProjection") as Node3D
	if operator != null:
		_apply_projection(operator, _before.operator, _after.operator, progress, true)
	var before_entities := _entities_by_id(_before.entities)
	for after_value: Variant in _after.entities:
		if not after_value is Dictionary:
			continue
		var after_entity: Dictionary = after_value
		var entity_id := str(after_entity.get("id", ""))
		var before_value: Variant = before_entities.get(entity_id)
		if not before_value is Dictionary or str(before_value.get("kind", "")) \
				!= str(after_entity.get("kind", "")):
			continue
		var projection := scene.call("projection_node", entity_id) as Node3D
		if projection != null:
			_apply_projection(projection, before_value, after_entity, progress, false)


func _apply_projection(
		node: Node3D, before: Dictionary, after: Dictionary, progress: float, operator: bool
) -> void:
	var before_position: Array = before.position_mt
	var after_position: Array = after.position_mt
	var x := lerpf(float(before_position[0]), float(after_position[0]), progress)
	var z := lerpf(float(before_position[1]), float(after_position[1]), progress)
	node.position = Vector3(x / MT_PER_WORLD_UNIT, node.position.y, z / MT_PER_WORLD_UNIT)
	var before_heading := int(before.heading_milli)
	var delta := int(after.heading_milli) - before_heading
	while delta > 4000:
		delta -= 8000
	while delta < -4000:
		delta += 8000
	var heading := float(before_heading) + float(delta) * progress
	node.rotation.y = heading * PI / 4000.0 * (-1.0 if operator else 1.0)


func _entities_by_id(entities: Array) -> Dictionary:
	var output := {}
	for value: Variant in entities:
		if value is Dictionary:
			output[str(value.get("id", ""))] = value
	return output


func _is_newer(candidate: Dictionary, previous: Dictionary) -> bool:
	return int(candidate.tick) > int(previous.tick) or (
		int(candidate.tick) == int(previous.tick)
		and int(candidate.observation_seq) > int(previous.observation_seq)
	)


func _eligible(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var snapshot: Dictionary = value
	return snapshot.get("participant_id") == "participant_0" \
		and typeof(snapshot.get("tick")) == TYPE_INT and int(snapshot.tick) >= 0 \
		and typeof(snapshot.get("observation_seq")) == TYPE_INT \
		and int(snapshot.observation_seq) >= 0 \
		and snapshot.get("operator") is Dictionary \
		and snapshot.get("entities") is Array
