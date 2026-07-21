class_name EmbodimentControlGameParticipantSceneV2
extends Node3D

## Participant-only presentation for the protocol-v2 control-validation games.
## The sole input is the authority's participant presentation source plus its ordinary visible
## observation. No checkpoint, map route, hidden station state, or spectator projection is read.

const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")
const EntrantPalette := preload("res://scripts/embodiment/presentation/entrant_palette.gd")
const ResourceRelayBattlefield := preload(
	"res://scripts/embodiment/presentation/v2/resource_relay_battlefield_v2.gd"
)
const RtsHud := preload("res://scripts/embodiment/presentation/v2/rts_participant_hud_v2.gd")
const HEADINGS_MILLI := [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000]
const FORWARD_MT := [
	Vector2i(0, -2000), Vector2i(1414, -1414), Vector2i(2000, 0), Vector2i(1414, 1414),
	Vector2i(0, 2000), Vector2i(-1414, 1414), Vector2i(-2000, 0), Vector2i(-1414, -1414),
]

var _operator: Node3D
var _entities := {}
var _entity_root: Node3D
var _hud: Label
var _identity_hud: RichTextLabel
var _battlefield: Node3D
var _legacy_floor: MeshInstance3D
var _rts_objective_hud: RichTextLabel
var _last_snapshot := {}
var _task_id := ""
var _participant_id := "participant_0"
var _entrant_id := "alpha"


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
	var position: Variant = _position(operator_source.get("position_mt"))
	var heading := int(operator_source.get("heading", -1))
	if position == null or heading < 0 or heading > 7:
		return false
	_operator.position = _world(position)
	var presentation_heading := int(operator_source.get(
		"presentation_heading_milli", HEADINGS_MILLI[heading]
	))
	_operator.rotation.y = -float(presentation_heading) * PI / 4000.0
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
		var entity_position: Variant = _position(entity.get("position_mt"))
		if entity_position == null:
			# The action-course source deliberately exposes only the visible station identity.
			# Its visual marker is placed ahead of the participant from the same visible bearing.
			entity_position = position + FORWARD_MT[heading]
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
			if entity_heading < 0 or entity_heading > 7 or not node.has_method("play_state"):
				return false
			var entity_presentation_heading := int(entity.get(
				"presentation_heading_milli", HEADINGS_MILLI[entity_heading]
			))
			node.rotation.y = -float(entity_presentation_heading) * PI / 4000.0
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
		str(observation.get("goal", "WorldArena control game")),
		int(observation.get("tick", 0)),
		str(observation.get("self", {}).get("status", [])).replace("[", "").replace("]", ""),
	]
	_update_identity_hud(observation)
	if _task_id == "duo-resource-relay-v0":
		RtsHud.update(_rts_objective_hud, observation, operator_source, _entrant_id)
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
		task_id: String, participant_id: String = "participant_0", presentation_entrant_id: String = ""
) -> bool:
	if task_id not in [
		"movement-maze-v0", "operator-action-course-v0", "duo-checkpoint-race-v0",
		"duo-relay-control-v0", "duo-spar-v0",
		"duo-resource-relay-v0",
	] or participant_id not in ["participant_0", "participant_1"]:
		return false
	_task_id = task_id
	_participant_id = participant_id
	_entrant_id = EntrantPalette.normalize(
		presentation_entrant_id, "alpha" if participant_id == "participant_0" else "bravo"
	)
	if _operator != null:
		_apply_entrant_identity(_operator, _entrant_id)
		_configure_camera_for_task()
	if _battlefield != null:
		_battlefield.configure_for_task(_task_id)
	if _legacy_floor != null:
		_legacy_floor.visible = _task_id != "duo-resource-relay-v0"
	_configure_hud_for_task()
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
	_battlefield = ResourceRelayBattlefield.new()
	_battlefield.configure_for_task(_task_id)
	add_child(_battlefield)
	var floor := MeshInstance3D.new()
	floor.name = "LegacyControlFloor"
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(28.0, 0.2, 28.0)
	floor.mesh = floor_mesh
	floor.position.y = -0.1
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("24303a")
	floor.material_override = floor_material
	_legacy_floor = floor
	floor.visible = _task_id != "duo-resource-relay-v0"
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
	_configure_camera_for_task()
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
	_identity_hud.size = Vector2(520, 150)
	_identity_hud.bbcode_enabled = true
	_identity_hud.fit_content = true
	_identity_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_identity_hud.add_theme_font_size_override("normal_font_size", 19)
	_identity_hud.add_theme_color_override("default_color", Color("dbeafe"))
	layer.add_child(_identity_hud)
	_rts_objective_hud = RtsHud.build(layer)
	_configure_hud_for_task()


func _configure_camera_for_task() -> void:
	if _operator == null:
		return
	var camera := _operator.get_node_or_null("ParticipantCameraRig/ParticipantCamera") as Camera3D
	if camera == null:
		return
	if _task_id == "duo-resource-relay-v0":
		# A high trailing isometric view makes route, river crossings, visible resource nodes, and
		# friendly relay play legible while still following this participant only.
		camera.position = Vector3(0.0, 13.5, 12.5)
		camera.rotation_degrees = Vector3(-47.0, 0.0, 0.0)
		camera.fov = 52.0
		camera.far = 82.0
	else:
		camera.position = Vector3(0.0, 3.25, 5.4)
		camera.rotation_degrees = Vector3(-17.0, 0.0, 0.0)
		camera.fov = 62.0
		camera.far = 60.0


func _configure_hud_for_task() -> void:
	if _hud == null or _identity_hud == null or _rts_objective_hud == null:
		return
	var is_resource_relay := _task_id == "duo-resource-relay-v0"
	_hud.visible = not is_resource_relay
	_identity_hud.visible = not is_resource_relay
	var rts_panel := _rts_objective_hud.get_parent() as Control
	if rts_panel != null:
		rts_panel.visible = is_resource_relay


func _update_identity_hud(observation: Dictionary) -> void:
	# This HUD is deliberately built from the current participant's ordinary observation only.
	# In particular, an opponent is listed only while its semantic entity is visible; opponent
	# state is its already-visible health/status band, not an authority-side exact value.
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
		# v2's public semantic rival id is sufficient even for the small, older replay
		# fixtures that did not include a redundant `kind` field.
		if entity_id != "v_rival":
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
	if kind == "resource" or kind == "dropped_resource":
		_build_resource_marker(root, kind == "dropped_resource")
		return root
	if kind == "relay":
		_build_relay_marker(root)
		return root
	if kind == "barricade":
		_build_barricade_marker(root)
		return root
	var mesh := MeshInstance3D.new()
	var shape := CylinderMesh.new()
	shape.top_radius = 0.45
	shape.bottom_radius = 0.65
	shape.height = 1.2
	mesh.mesh = shape
	mesh.position.y = 0.6
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("65d6ff") if kind in ["checkpoint", "beacon"] else Color("f6b94a")
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


func _build_resource_marker(root: Node3D, dropped: bool) -> void:
	var ore := MeshInstance3D.new()
	ore.name = "MaterialCrystals"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.2 if dropped else 0.45
	mesh.bottom_radius = 0.42 if dropped else 0.72
	mesh.height = 0.5 if dropped else 1.35
	mesh.radial_segments = 6
	ore.mesh = mesh
	ore.position.y = 0.3 if dropped else 0.68
	ore.material_override = _emissive_material(Color("f6c453") if dropped else Color("e7a83b"), 0.4)
	root.add_child(ore)
	if not dropped:
		for index: int in 3:
			var shard := MeshInstance3D.new()
			shard.name = "CrystalShard%d" % index
			var shard_mesh := CylinderMesh.new()
			shard_mesh.top_radius = 0.1
			shard_mesh.bottom_radius = 0.24
			shard_mesh.height = 0.74
			shard_mesh.radial_segments = 5
			shard.mesh = shard_mesh
			shard.position = Vector3(float(index - 1) * 0.42, 0.37, 0.22 if index % 2 == 0 else -0.22)
			shard.rotation_degrees.z = float(index - 1) * 16.0
			shard.material_override = _emissive_material(Color("ffd77b"), 0.32)
			root.add_child(shard)
	_add_marker_label(root, "MATERIAL" if not dropped else "DROPPED MATERIAL", Color("ffd166"), 1.9 if not dropped else 1.0)


func _build_relay_marker(root: Node3D) -> void:
	var base := MeshInstance3D.new()
	base.name = "RelayPlatform"
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 1.05
	base_mesh.bottom_radius = 1.2
	base_mesh.height = 0.28
	base_mesh.radial_segments = 8
	base.mesh = base_mesh
	base.position.y = 0.14
	base.material_override = _emissive_material(Color("215d77"), 0.12)
	root.add_child(base)
	var core := MeshInstance3D.new()
	core.name = "RelayCore"
	var core_mesh := CylinderMesh.new()
	core_mesh.top_radius = 0.22
	core_mesh.bottom_radius = 0.38
	core_mesh.height = 2.25
	core_mesh.radial_segments = 6
	core.mesh = core_mesh
	core.position.y = 1.25
	core.material_override = _emissive_material(Color("4de3f4"), 0.65)
	root.add_child(core)
	_add_marker_label(root, "FRIENDLY RELAY", Color("78e8f4"), 2.9)


func _build_barricade_marker(root: Node3D) -> void:
	for post_index: int in 2:
		var post := MeshInstance3D.new()
		post.name = "BarricadePost%d" % post_index
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.28, 1.35, 0.34)
		post.mesh = post_mesh
		post.position = Vector3(-0.88 if post_index == 0 else 0.88, 0.67, 0.0)
		post.material_override = _simple_material(Color("6d442d"))
		root.add_child(post)
	for rail_index: int in 3:
		var rail := MeshInstance3D.new()
		rail.name = "BarricadeRail%d" % rail_index
		var rail_mesh := BoxMesh.new()
		rail_mesh.size = Vector3(2.05, 0.21, 0.3)
		rail.mesh = rail_mesh
		rail.position = Vector3(0.0, 0.34 + float(rail_index) * 0.38, 0.0)
		rail.material_override = _simple_material(Color("a76c3d"))
		root.add_child(rail)
	_add_marker_label(root, "BARRICADE", Color("f1bd75"), 1.9)


func _add_marker_label(root: Node3D, text: String, color: Color, height: float) -> void:
	var label := Label3D.new()
	label.name = "StateLabel"
	label.text = text
	label.position.y = height
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.outline_size = 4
	label.modulate = color
	root.add_child(label)


func _simple_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.65
	return material


func _emissive_material(color: Color, strength: float) -> StandardMaterial3D:
	var material := _simple_material(color)
	material.emission_enabled = true
	material.emission = color * strength
	return material


func _instantiate_y_bot() -> Node3D:
	var operator := YBot.instantiate() as Node3D
	# The packed scene's state-machine subresource is otherwise shared across instances. Each
	# participant-only viewport and visible rival needs its own presentation state graph.
	var animation_tree := operator.get_node_or_null("AnimationTree") as AnimationTree
	if animation_tree != null and animation_tree.tree_root != null:
		animation_tree.tree_root = animation_tree.tree_root.duplicate(true)
	return operator


func _visible_entrant(entity_id: String) -> String:
	# The actual roster mapping is supplied as public presentation metadata for a seat-swapped
	# series.  This fallback keeps old standalone v2 replays visibly distinct.
	if entity_id == "v_rival":
		return "bravo" if _entrant_id == "alpha" else "alpha"
	return ""


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
		or typeof(value.get("x")) != TYPE_INT or typeof(value.get("y")) != TYPE_INT:
		return null
	return Vector2i(value.x, value.y)


func _world(value: Vector2i) -> Vector3:
	return Vector3(float(value.x) / 1000.0, 0.0, float(value.y) / 1000.0)
