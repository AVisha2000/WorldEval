extends Node3D

## Read-only world-space projection of a persistent gather / work task.
## `apply_snapshot()` and `apply_event()` deliberately consume dictionaries so this
## stays compatible with both the round adapter and the upcoming tick stream.

var task_id := ""
var _label: Label3D
var _progress: MeshInstance3D
var _fill_material: StandardMaterial3D


func apply_snapshot(task: Dictionary, world_position: Vector3, faction_color: Color) -> void:
	if task_id.is_empty():
		task_id = str(task.get("id", task.get("task_id", "work_task")))
	position = world_position + Vector3(0, 3.6, 0)
	_ensure_visuals(faction_color)
	var action := str(task.get("action", task.get("kind", task.get("task", "working")))).replace("_", " ").to_upper()
	var resource := str(task.get("resource", task.get("resource_type", ""))).to_upper()
	var state := str(task.get("state", "active")).replace("_", " ").to_upper()
	var progress := _progress_ratio(task)
	# Completed/near-complete jobs belong in the chronicle and task inspector,
	# not as large world labels over every settlement.
	visible = not _is_terminal(task) and progress < 0.995
	_label.text = "%s%s  %d%%" % [action, " · " + resource if not resource.is_empty() else "", int(progress * 100.0)]
	_label.modulate = faction_color.lightened(0.20) if state in ["ACTIVE", "WORKING", "GATHERING"] else Color("ffb35c")
	_progress.scale.x = maxf(0.02, progress)
	_progress.position.x = -1.6 + 1.6 * maxf(0.02, progress)


func apply_event(event: Dictionary, world_position: Vector3, faction_color: Color) -> void:
	var payload: Dictionary = event.get("payload", {})
	var task: Dictionary = payload.get("task", payload.get("task_state", {}))
	if task.is_empty():
		task = payload.duplicate(true)
		task["id"] = str(event.get("task_id", event.get("event_id", "work_event")))
		task["kind"] = str(event.get("kind", "work"))
		task["state"] = str(event.get("state", "active"))
	apply_snapshot(task, world_position, faction_color)


func _ensure_visuals(faction_color: Color) -> void:
	if _label != null:
		return
	_label = Label3D.new()
	_label.font_size = 13
	_label.outline_size = 3
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.pixel_size = 0.019
	add_child(_label)
	var background := MeshInstance3D.new()
	var bg_mesh := BoxMesh.new()
	bg_mesh.size = Vector3(3.2, 0.18, 0.10)
	background.mesh = bg_mesh
	background.position = Vector3(0, -0.32, 0)
	background.material_override = _material(Color("0b1a21"))
	add_child(background)
	_progress = MeshInstance3D.new()
	var fill_mesh := BoxMesh.new()
	fill_mesh.size = Vector3(3.2, 0.20, 0.11)
	_progress.mesh = fill_mesh
	_progress.position = Vector3(-1.568, -0.32, -0.01)
	_fill_material = _material(faction_color)
	_progress.material_override = _fill_material
	add_child(_progress)


func _progress_ratio(task: Dictionary) -> float:
	if task.has("progress"):
		return clampf(float(task.progress), 0.0, 1.0)
	var completed := float(task.get("completed_work", task.get("work_completed", 0.0)))
	var required := maxf(1.0, float(task.get("required_work", task.get("work_required", 1.0))))
	return clampf(completed / required, 0.0, 1.0)


func _is_terminal(task: Dictionary) -> bool:
	return str(task.get("state", "")).to_lower() in ["complete", "completed", "cancelled", "canceled", "failed"]


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	return material
