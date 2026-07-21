class_name EmbodimentRtsV1TaskPlanContract
extends RefCounted

## Strict command envelope for the live RTS.  v0's rts-task-plan-v1 remains sealed with
## the showcase; this contract deliberately gets a new identity so old replay evidence can
## never be interpreted as a command for the live authority.

const PROTOCOL := "rts-task-plan-v2"
const MAX_INTENT_BYTES := 160
const MAX_MEMORY_BYTES := 2048
const TASKS := ["gather", "return_material", "build", "train", "arm", "rally", "attack_unit", "attack_structure", "retreat", "hold"]
const PLAN_FIELDS := ["protocol", "episode_id", "observation_seq", "intent_label", "memory_update", "assignments"]
const ASSIGNMENT_FIELDS := ["unit_id", "task", "target_id"]


static func validate(plan: Variant, episode_id: String, observation_seq: int, owned_unit_ids: Array[String], visible_target_ids: Array[String], alive_unit_ids: Array[String]) -> PackedStringArray:
	var errors := PackedStringArray()
	if not plan is Dictionary:
		errors.append("task_plan_invalid")
		return errors
	if not _exact(plan, PLAN_FIELDS) or plan.get("protocol") != PROTOCOL \
		or plan.get("episode_id") != episode_id or plan.get("observation_seq") != observation_seq:
		errors.append("task_plan_identity_invalid")
		return errors
	if not plan.get("intent_label") is String or str(plan.intent_label).to_utf8_buffer().size() > MAX_INTENT_BYTES \
		or not plan.get("memory_update") is String or str(plan.memory_update).to_utf8_buffer().size() > MAX_MEMORY_BYTES:
		errors.append("task_plan_text_invalid")
	if not plan.get("assignments") is Array or plan.assignments.is_empty() or plan.assignments.size() > 3:
		errors.append("task_plan_assignment_count_invalid")
		return errors
	var seen := {}
	for assignment: Variant in plan.assignments:
		if not assignment is Dictionary or not _exact(assignment, ASSIGNMENT_FIELDS):
			errors.append("task_plan_assignment_invalid")
			continue
		var unit_id := str(assignment.get("unit_id", ""))
		var task := str(assignment.get("task", ""))
		var target_id := str(assignment.get("target_id", ""))
		if unit_id not in owned_unit_ids or unit_id not in alive_unit_ids:
			errors.append("task_plan_unit_invalid")
		if seen.has(unit_id):
			errors.append("task_plan_duplicate_unit")
		seen[unit_id] = true
		if task not in TASKS:
			errors.append("task_plan_task_invalid")
		if target_id.is_empty() or target_id not in visible_target_ids:
			errors.append("task_plan_target_invalid")
	return errors


static func _exact(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true
