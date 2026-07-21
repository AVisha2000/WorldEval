extends SceneTree

const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const SnapshotFilter := preload(
	"res://scripts/embodiment/presentation/privacy/presentation_snapshot_filter.gd"
)
const HybridAdapter := preload(
	"res://scripts/embodiment/presentation/embodiment_hybrid_presentation_adapter.gd"
)
const PresentationScene := preload(
	"res://scenes/embodiment/embodiment_presentation_scene.tscn"
)

var _failures := PackedStringArray()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var authority := Authority.new()
	var errors := authority.configure_managed_hybrid({
		"episode_id": "ep_replay_presentation",
		"mode": "solo-curriculum-v0",
		"task_id": "orientation-v0",
		"observation_profile": "hybrid-visible-v1",
		"participant_ids": ["participant_0"],
		"maximum_episode_ticks": 600,
	})
	_check(errors.is_empty(), "interpolation authority fixture was rejected")
	var before_result := _filtered(authority)
	_check(bool(before_result.get("ok", false)), "before snapshot filter failed")
	if not bool(before_result.get("ok", false)):
		_finish()
		return
	var before: Dictionary = before_result.snapshot
	var action := _action(authority)
	var step_result: Dictionary = authority.step(action)
	_check(step_result.receipts.participant_0.accepted, "interpolation action was rejected")
	var after_hash: String = authority.checkpoint_hash()
	var after_result := _filtered(authority)
	_check(bool(after_result.get("ok", false)), "after snapshot filter failed")
	if not bool(after_result.get("ok", false)):
		_finish()
		return
	var after: Dictionary = after_result.snapshot.duplicate(true)
	# The orientation authority keeps its beacon static, so move and turn this already-filtered
	# participant-safe projection to exercise entity interpolation independently of authority.
	_check(not after.visible_entities.is_empty(), "entity interpolation fixture is empty")
	if not after.visible_entities.is_empty():
		after.visible_entities[0].position_mt[0] += 1200
		after.visible_entities[0].position_mt[1] -= 800
		after.visible_entities[0].heading_sector = 2

	var midpoint := HybridAdapter.interpolated_scene_snapshot(before, after, 500)
	_check(bool(midpoint.get("ok", false)), "valid midpoint interpolation was rejected")
	if bool(midpoint.get("ok", false)):
		var snapshot: Dictionary = midpoint.snapshot
		_check(
			snapshot.operator.position_mt == _midpoint(
				before.self.position_mt, after.self.position_mt
			),
			"operator position did not interpolate at frame midpoint",
		)
		_check(snapshot.operator.heading_milli == 1000, "operator facing did not interpolate")
		if not snapshot.entities.is_empty():
			_check(
				snapshot.entities[0].position_mt == _midpoint(
					before.visible_entities[0].position_mt, after.visible_entities[0].position_mt
				),
				"visible entity position did not interpolate",
			)
			_check(snapshot.entities[0].heading_milli == 1000, "visible entity facing did not interpolate")
		_check(snapshot.agency == after.agency, "HUD agency was interpolated or replaced")
		_check(
			snapshot.agency.intent_label == "Turn and advance toward the beacon.",
			"accepted controller intent was not retained",
		)
		var scene := PresentationScene.instantiate()
		root.add_child(scene)
		await process_frame
		_check(scene.apply_snapshot(snapshot), "interpolated scene snapshot was rejected")
		var operator_position: Vector3 = scene.get_node("OperatorProjection").position
		_check(
			is_equal_approx(operator_position.x, float(snapshot.operator.position_mt[0]) / 1000.0)
				and is_equal_approx(operator_position.z, float(snapshot.operator.position_mt[1]) / 1000.0),
			"scene did not apply interpolated operator position",
		)
		_check(
			is_equal_approx(scene.get_node("OperatorProjection").rotation.y, PI / 4.0),
			"scene did not apply interpolated facing",
		)
		if not snapshot.entities.is_empty():
			var entity_projection: Node3D = scene.projection_node(str(snapshot.entities[0].id))
			_check(
				entity_projection != null and is_equal_approx(entity_projection.rotation.y, PI / 4.0),
				"scene did not apply interpolated entity facing",
			)
		_check(
			str(scene.get_node("ParticipantHUD/Panel/Content/NonAuthoritativeIntent").text)
				.contains("Turn and advance"),
			"interpolated frame lost exact HUD agency",
		)
		var first_operator := scene.get_node("OperatorProjection")
		_check(scene.apply_snapshot(snapshot), "idempotent interpolation frame was rejected")
		_check(scene.get_node("OperatorProjection") == first_operator, "interpolation rebuilt operator")
		scene.free()

	_test_visibility_intersection(before, after)
	var wrong_participant: Dictionary = after.duplicate(true)
	wrong_participant.participant_id = "participant_1"
	_check(
		HybridAdapter.interpolated_scene_snapshot(before, wrong_participant, 500).get("ok") == false,
		"interpolation accepted a cross-participant boundary",
	)
	_check(authority.checkpoint_hash() == after_hash, "presentation interpolation changed authority hash")
	_finish()


func _test_visibility_intersection(before: Dictionary, after: Dictionary) -> void:
	_check(not before.visible_entities.is_empty(), "privacy fixture lacks a visible entity")
	if before.visible_entities.is_empty():
		return
	var entity_id := str(before.visible_entities[0].id)
	var hidden_after: Dictionary = after.duplicate(true)
	hidden_after.visible_entities = []
	var disappearing := HybridAdapter.interpolated_scene_snapshot(before, hidden_after, 500)
	_check(bool(disappearing.get("ok", false)), "safe disappearance interpolation failed")
	if bool(disappearing.get("ok", false)):
		_check(disappearing.snapshot.entities.is_empty(), "after-hidden entity remained in tween frames")
		_check(entity_id not in JSON.stringify(disappearing.snapshot), "hidden entity leaked by interpolation")

	var hidden_before: Dictionary = before.duplicate(true)
	hidden_before.visible_entities = []
	var appearing_early := HybridAdapter.interpolated_scene_snapshot(hidden_before, after, 999)
	var appearing_exact := HybridAdapter.interpolated_scene_snapshot(hidden_before, after, 1000)
	_check(bool(appearing_early.get("ok", false)), "safe appearance interpolation failed")
	_check(bool(appearing_exact.get("ok", false)), "exact after-boundary projection failed")
	if bool(appearing_early.get("ok", false)):
		_check(appearing_early.snapshot.entities.is_empty(), "new entity appeared before safe boundary")
	if bool(appearing_exact.get("ok", false)):
		_check(
			appearing_exact.snapshot == HybridAdapter.scene_snapshot(after),
			"1000-milli endpoint did not remain exact",
		)
		_check(
			appearing_exact.snapshot.entities.any(
				func(entity: Dictionary) -> bool: return str(entity.id) == str(after.visible_entities[0].id)
			),
			"after-visible entity did not appear at exact boundary",
		)


func _filtered(authority: Object) -> Dictionary:
	var hash_before: String = authority.checkpoint_hash()
	var source: Dictionary = authority.presentation_source_snapshot()
	var result := SnapshotFilter.filter_for_participant(
		source, "participant_0", authority.presentation_visible_entity_ids()
	)
	_check(authority.checkpoint_hash() == hash_before, "privacy filtering changed authority hash")
	return result


func _action(authority: Object) -> Dictionary:
	return {
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "replay_presentation_action",
		"control": {
			"move_x": 0, "move_y": 1000, "look_x": 1000, "look_y": 0,
			"duration_ticks": 2,
			"buttons": {
				"interact": false, "primary": false, "guard": false, "dash": false,
				"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false,
			},
		},
		"intent_label": "Turn and advance toward the beacon.",
		"memory_update": "",
	}


func _midpoint(before: Array, after: Array) -> Array:
	return [
		int(before[0]) + int((int(after[0]) - int(before[0])) * 500 / 1000),
		int(before[1]) + int((int(after[1]) - int(before[1])) * 500 / 1000),
	]


func _finish() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_REPLAY_PRESENTATION_FAILURE: %s" % failure)
		print("EMBODIMENT_REPLAY_PRESENTATION_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_REPLAY_PRESENTATION_OK")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
