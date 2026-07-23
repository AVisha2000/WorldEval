extends SceneTree

const ProjectionTween := preload(
	"res://scripts/embodiment/presentation/preview/versioned_projection_tween.gd"
)


func _init() -> void:
	var v2_before := _source("participant_0", "position_mt", {"x": 0, "y": 0}, 7,
		{"x": 0, "y": -1000})
	var v2_after := _source("participant_0", "position_mt", {"x": 1000, "y": 2000}, 1,
		{"x": 1000, "y": -1000})
	var v2 := ProjectionTween.interpolate(v2_before, v2_after, 500, "llm-controller/0.2.0")
	if v2.get("operator", {}).get("position_mt") != {"x": 500, "y": 1000} \
			or v2.operator.presentation_heading_milli != 0 \
			or v2.visible_entities[0].position_mt != {"x": 500, "y": -1000}:
		_fail("versioned_v2_projection_tween_invalid")
		return
	var v3_before := _source("participant_2", "position_axial", {"q": 0, "r": 0}, 5,
		{"q": -1000, "r": 0})
	var v3_after := _source("participant_2", "position_axial", {"q": 1000, "r": -1000}, 1,
		{"q": 0, "r": 1000})
	var v3 := ProjectionTween.interpolate(v3_before, v3_after, 500, "llm-controller/0.3.0")
	if v3.get("operator", {}).get("position_axial") != {"q": 500, "r": -500} \
			or v3.operator.presentation_heading_milli != 0 \
			or v3.visible_entities[0].position_axial != {"q": -500, "r": 500}:
		_fail("versioned_v3_projection_tween_invalid")
		return
	if v2_before.operator.position_mt != {"x": 0, "y": 0} \
			or v3_before.operator.position_axial != {"q": 0, "r": 0}:
		_fail("versioned_projection_tween_mutated_safe_source")
		return
	var mismatched := v3_after.duplicate(true)
	mismatched.participant_id = "participant_1"
	if not ProjectionTween.interpolate(
		v3_before, mismatched, 500, "llm-controller/0.3.0"
	).is_empty():
		_fail("versioned_projection_tween_crossed_participant_boundary")
		return
	print("VERSIONED_PROJECTION_TWEEN_OK")
	quit(0)


func _source(
		participant_id: String, position_key: String, operator_position: Dictionary,
		heading: int, entity_position: Dictionary,
) -> Dictionary:
	return {
		"participant_id": participant_id,
		"operator": {
			position_key: operator_position,
			"heading": heading,
			"animation_state": "walk",
		},
		"visible_entities": [{
			"id": "v_relay", "kind": "relay", position_key: entity_position,
		}],
	}


func _fail(code: String) -> void:
	push_error(code)
	quit(1)
