class_name EmbodimentTrioParticipantSceneV3
extends Node3D

## Participant-only presentation for the protocol-v3 trio games.
## The sole input is the authority's participant presentation source plus its ordinary visible
## observation. No checkpoint, map route, hidden station state, or spectator projection is read.

const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")
const EntrantPalette := preload("res://scripts/embodiment/presentation/entrant_palette.gd")

var _operator: Node3D
var _entities := {}
var _entity_root: Node3D
var _hud: Label
var _identity_hud: RichTextLabel
var _last_snapshot := {}
var _task_id := ""
var _participant_id := "participant_0"
var _entrant_id := "sol"
var _seat_rotation := 0


func _ready() -> void:
	_build()


func apply_participant_projection(source: Dictionary, observation: Dictionary) -> bool:
	_build()
	if source.get("participant_id") != _participant_id \
		or observation.get("episode_id") == null \
		or observation.get("profile") not in ["text-visible-v1", "hybrid-visible-v1"] \
		or not source.get("operator") is Dictionary \
		or not source.get("visible_entities") is Array:
		return false
	var operator_source: Dictionary = source.operator
	var source_entrant := EntrantPalette.normalize(
		operator_source.get("presentation_entrant_id", source.get("presentation_entrant_id", "")),
		_entrant_id
	)
	if not source_entrant.is_empty() and source_entrant != _entrant_id:
		_entrant_id = source_entrant
	_apply_entrant_identity(_operator, _entrant_id)
	var position: Variant = _position(operator_source.get("position_axial"))
	var heading := int(operator_source.get("heading", -1))
	if position == null or heading < 0 or heading > 5:
		return false
	_operator.position = _world(position)
	var presentation_heading := int(operator_source.get(
		"presentation_heading_milli", heading * 1000
	))
	_operator.rotation.y = -PI / 6.0 + float(presentation_heading) * PI / 3000.0
	var animation := str(operator_source.get("animation_state", "idle"))
	if animation == "turn":
		animation = "idle"
	_operator.call("play_state", StringName(animation))

	var visible_semantics := {}
	for value: Variant in observation.get("visible_entities", []):
		if value is Dictionary and value.get("id") is String:
			visible_semantics[str(value.id)] = value
	var seen := {}
	for value: Variant in source.visible_entities:
		if not value is Dictionary or not value.get("id") is String \
			or not visible_semantics.has(str(value.id)):
			return false
		var entity: Dictionary = value
		var entity_id := str(entity.id)
		var entity_position: Variant = _position(entity.get("position_axial"))
		if entity_position == null:
			return false
		var node: Node3D = _entities.get(entity_id)
		if node == null:
			node = _marker(entity_id, str(entity.get("kind", "checkpoint")))
			_entity_root.add_child(node)
			_entities[entity_id] = node
		node.position = _world(entity_position)
		if str(entity.get("kind", "")) == "operator":
			_apply_entrant_identity(node, EntrantPalette.normalize(
				entity.get("presentation_entrant_id", ""), _visible_entrant(entity_id)
			))
			var entity_heading := int(entity.get("heading", -1))
			if entity_heading < 0 or entity_heading > 5 or not node.has_method("play_state"):
				return false
			var entity_presentation_heading := int(entity.get(
				"presentation_heading_milli", entity_heading * 1000
			))
			node.rotation.y = (
				-PI / 6.0 + float(entity_presentation_heading) * PI / 3000.0
			)
			var entity_animation := str(entity.get("animation_state", "idle"))
			if entity_animation == "turn":
				entity_animation = "idle"
			node.call("play_state", StringName(entity_animation))
		seen[entity_id] = true
	for entity_id: String in _entities.keys():
		if not seen.has(entity_id):
			var stale: Node3D = _entities[entity_id]
			_entities.erase(entity_id)
			stale.queue_free()
	_hud.text = "%s  |  tick %d  |  %s" % [
		str(observation.get("goal", "WorldArena trio game")),
		int(observation.get("tick", 0)),
		str(observation.get("self", {}).get("status", [])).replace("[", "").replace("]", ""),
	]
	_update_identity_hud(observation)
	_last_snapshot = {
		"episode_id": observation.episode_id,
		"observation_seq": observation.observation_seq,
		"participant_id": source.participant_id,
		"task_id": _task_id,
		"tick": observation.tick,
		"operator": operator_source.duplicate(true),
		"visible_entities": source.visible_entities.duplicate(true),
	}
	return true


func configure_task(
		task_id: String, participant_id: String = "participant_0", presentation_entrant_id: String = "",
		seat_rotation: int = 0,
) -> bool:
	if task_id not in ["trio-relay-v0", "trio-free-for-all-v0"] \
		or participant_id not in ["participant_0", "participant_1", "participant_2"] \
		or seat_rotation < 0 or seat_rotation > 2:
		return false
	_task_id = task_id
	_participant_id = participant_id
	_seat_rotation = seat_rotation
	_entrant_id = EntrantPalette.normalize(
		presentation_entrant_id, _entrant_for_participant(participant_id)
	)
	if _operator != null:
		_apply_entrant_identity(_operator, _entrant_id)
	return true


func snapshot_copy() -> Dictionary:
	return _last_snapshot.duplicate(true)


func participant_camera(participant_id: String) -> Camera3D:
	if participant_id != _participant_id:
		return null
	return _operator.get_node("ParticipantCameraRig/ParticipantCamera") as Camera3D


func _build() -> void:
	if _operator != null:
		return
	var floor := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(28.0, 0.2, 28.0)
	floor.mesh = floor_mesh
	floor.position.y = -0.1
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("24303a")
	floor.material_override = floor_material
	add_child(floor)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -25, 0)
	light.light_energy = 1.4
	light.shadow_enabled = true
	add_child(light)
	_entity_root = Node3D.new()
	_entity_root.name = "ParticipantVisibleEntities"
	add_child(_entity_root)
	_operator = _instantiate_y_bot()
	_operator.name = "ParticipantOperator"
	add_child(_operator)
	_apply_entrant_identity(_operator, _entrant_id)
	var rig := Node3D.new()
	rig.name = "ParticipantCameraRig"
	_operator.add_child(rig)
	var camera := Camera3D.new()
	camera.name = "ParticipantCamera"
	camera.position = Vector3(0, 3.25, 5.4)
	camera.rotation_degrees.x = -17
	camera.fov = 62
	camera.current = true
	rig.add_child(camera)
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(24, 24)
	_hud.size = Vector2(1180, 80)
	_hud.add_theme_font_size_override("font_size", 22)
	_hud.add_theme_color_override("font_color", Color("e9f4ff"))
	layer.add_child(_hud)
	_identity_hud = RichTextLabel.new()
	_identity_hud.name = "ParticipantIdentityHud"
	_identity_hud.position = Vector2(24, 62)
	_identity_hud.size = Vector2(520, 180)
	_identity_hud.bbcode_enabled = true
	_identity_hud.fit_content = true
	_identity_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_identity_hud.add_theme_font_size_override("normal_font_size", 19)
	_identity_hud.add_theme_color_override("default_color", Color("dbeafe"))
	layer.add_child(_identity_hud)


func _update_identity_hud(observation: Dictionary) -> void:
	# The roster display is participant-scoped: it reads only the projected self state and
	# semantic operator entities that are already visible to this participant.
	var self_state: Dictionary = observation.get("self", {})
	var lines: Array[String] = []
	lines.append("[color=#%s][b]YOU · %s[/b][/color]  HP %d%%  %s" % [
		EntrantPalette.color(_entrant_id).to_html(false), EntrantPalette.label(_entrant_id),
		clampi(int(self_state.get("health_percent", 100)), 0, 100),
		_status_text(self_state.get("status", []), "READY"),
	])
	for value: Variant in observation.get("visible_entities", []):
		if not value is Dictionary:
			continue
		var entity: Dictionary = value
		var entity_id := str(entity.get("id", ""))
		# The participant id comes from the public operator semantic, which is already
		# filtered by the authority before this presentation scene receives it.
		if not entity_id.begins_with("v_participant_"):
			continue
		var entrant := EntrantPalette.normalize(_visible_entrant(entity_id))
		if entrant.is_empty():
			continue
		lines.append("[color=#%s][b]VISIBLE · %s[/b][/color]  %s" % [
			EntrantPalette.color(entrant).to_html(false), EntrantPalette.label(entrant),
			_status_text([entity.get("state", "visible")]),
		])
	_identity_hud.text = "\n".join(lines)


func _status_text(values: Variant, fallback: String = "") -> String:
	if not values is Array:
		return fallback
	var labels: Array[String] = []
	for value: Variant in values:
		if value is String:
			var label := str(value).to_upper().replace("_", " ")
			# Observation schemas already validate these short semantic tokens. Keep the
			# presentation bounded without reading any unprojected authority value.
			if label.length() <= 32:
				labels.append(label)
	return " · ".join(labels) if not labels.is_empty() else fallback


func _marker(entity_id: String, kind: String) -> Node3D:
	if kind == "operator":
		var rival := _instantiate_y_bot()
		rival.name = "Visible_%s" % entity_id.replace("-", "_")
		_apply_entrant_identity(rival, _visible_entrant(entity_id))
		return rival
	var root := Node3D.new()
	root.name = "Visible_%s" % entity_id.replace("-", "_")
	var mesh := MeshInstance3D.new()
	var shape := CylinderMesh.new()
	shape.top_radius = 0.45
	shape.bottom_radius = 0.65
	shape.height = 1.2
	mesh.mesh = shape
	mesh.position.y = 0.6
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("65d6ff") if kind == "relay" else Color("f6b94a")
	material.emission_enabled = true
	material.emission = material.albedo_color * 0.35
	mesh.material_override = material
	root.add_child(mesh)
	var label := Label3D.new()
	label.text = entity_id.trim_prefix("v_").replace("_", " ").to_upper()
	label.position.y = 1.7
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)
	return root


func _instantiate_y_bot() -> Node3D:
	var operator := YBot.instantiate() as Node3D
	# The packed scene's state-machine subresource is otherwise shared across instances. Each
	# participant-only viewport and visible rival needs its own presentation state graph.
	var animation_tree := operator.get_node_or_null("AnimationTree") as AnimationTree
	if animation_tree != null and animation_tree.tree_root != null:
		animation_tree.tree_root = animation_tree.tree_root.duplicate(true)
	return operator


func _entrant_for_participant(participant_id: String) -> String:
	var seat_index := ["participant_0", "participant_1", "participant_2"].find(participant_id)
	if seat_index < 0:
		return ""
	# This is the public cyclic trio schedule: entrant[(seat - rotation) mod 3].
	return ["sol", "luna", "terra"][(seat_index - _seat_rotation + 3) % 3]


func _visible_entrant(entity_id: String) -> String:
	if not entity_id.begins_with("v_participant_"):
		return ""
	return _entrant_for_participant(entity_id.trim_prefix("v_"))


func _apply_entrant_identity(avatar: Node3D, entrant_id: String) -> void:
	var resolved := EntrantPalette.normalize(entrant_id, _entrant_id)
	EntrantPalette.tint_avatar(avatar, resolved)
	var label := avatar.get_node_or_null("EntrantLabel") as Label3D
	if label == null:
		label = Label3D.new()
		label.name = "EntrantLabel"
		label.position = Vector3(0.0, 2.8, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.outline_size = 4
		avatar.add_child(label)
	label.text = EntrantPalette.label(resolved)
	label.modulate = EntrantPalette.color(resolved)


func _position(value: Variant) -> Variant:
	if not value is Dictionary or value.size() != 2 \
		or typeof(value.get("q")) != TYPE_INT or typeof(value.get("r")) != TYPE_INT:
		return null
	return Vector2i(value.q, value.r)


func _world(value: Vector2i) -> Vector3:
	return Vector3(
		(float(value.x) + float(value.y) * 0.5) / 1000.0,
		0.0,
		float(value.y) * 0.866025403784 / 1000.0,
	)
