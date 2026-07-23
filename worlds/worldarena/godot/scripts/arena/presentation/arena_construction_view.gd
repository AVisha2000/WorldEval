extends Node3D

## Read-only staged scaffold for construction jobs. The authoritative task owns
## cost, builders and timing; this node only projects its supplied progress.

var construction_id := ""
var _label: Label3D
var _scaffold: Node3D
var _fill: MeshInstance3D


func apply_snapshot(job: Dictionary, world_position: Vector3, faction_color: Color) -> void:
	if construction_id.is_empty():
		construction_id = str(job.get("id", job.get("job_id", "construction")))
	position = world_position
	visible = not _is_terminal(job)
	_ensure_visuals(faction_color)
	var progress := _progress_ratio(job)
	visible = not _is_terminal(job) and progress < 0.995
	var stage := mini(3, int(floor(progress * 3.0)) + 1)
	var kind := str(job.get("structure", job.get("kind", "construction"))).replace("_", " ").to_upper()
	var builders: Variant = job.get("builder_ids", job.get("builders", []))
	var builder_count: int = builders.size() if builders is Array else int(builders)
	_label.text = "%s · STAGE %d/3 · %d%% · %d BUILDER%s" % [kind, stage, int(progress * 100.0), builder_count, "" if builder_count == 1 else "S"]
	_label.modulate = Color("ffb35c") if str(job.get("pause_reason", "")).is_empty() else Color("ff7a70")
	_fill.scale.y = maxf(0.03, progress)
	_fill.position.y = 3.25 * maxf(0.03, progress)
	for child in _scaffold.get_children():
		if child is MeshInstance3D:
			child.visible = child.get_meta("stage", 1) <= stage


func apply_event(event: Dictionary, world_position: Vector3, faction_color: Color) -> void:
	var payload: Dictionary = event.get("payload", {})
	var job: Dictionary = payload.get("construction", payload.get("job", payload.get("task", {})))
	if job.is_empty():
		job = payload.duplicate(true)
		job["id"] = str(event.get("job_id", event.get("event_id", "construction_event")))
		job["kind"] = str(event.get("kind", "build"))
		job["state"] = str(event.get("state", "active"))
	apply_snapshot(job, world_position, faction_color)


func _ensure_visuals(faction_color: Color) -> void:
	if _scaffold != null:
		return
	_scaffold = Node3D.new()
	add_child(_scaffold)
	for index in range(3):
		var beam := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(7.4 - index * 0.92, 0.38, 0.38)
		beam.mesh = mesh
		beam.position = Vector3(0, 0.88 + index * 2.10, 0)
		beam.rotation.z = 0.26 if index % 2 == 0 else -0.26
		beam.material_override = _material(Color("9b7347"))
		beam.set_meta("stage", index + 1)
		_scaffold.add_child(beam)
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.36, 7.1, 0.36)
		post.mesh = post_mesh
		post.position = Vector3(side * 2.85, 3.55, 0)
		post.material_override = _material(Color("765238"))
		post.set_meta("stage", 1)
		_scaffold.add_child(post)
	_fill = MeshInstance3D.new()
	var fill_mesh := BoxMesh.new()
	fill_mesh.size = Vector3(5.0, 6.5, 3.4)
	_fill.mesh = fill_mesh
	_fill.position = Vector3(0, 3.25, 0)
	_fill.material_override = _material(faction_color.darkened(0.20))
	_scaffold.add_child(_fill)
	_label = Label3D.new()
	_label.position = Vector3(0, 5.2, 0)
	_label.font_size = 13
	_label.outline_size = 3
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.pixel_size = 0.018
	add_child(_label)


func _progress_ratio(job: Dictionary) -> float:
	if job.has("progress"):
		return clampf(float(job.progress), 0.0, 1.0)
	var completed := float(job.get("completed_work", job.get("work_completed", 0.0)))
	var required := maxf(1.0, float(job.get("required_work", job.get("work_required", 1.0))))
	return clampf(completed / required, 0.0, 1.0)


func _is_terminal(job: Dictionary) -> bool:
	return str(job.get("state", "")).to_lower() in ["complete", "completed", "cancelled", "canceled", "failed"]


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material
