class_name EmbodimentRtsSkirmishBroadcastScene
extends Node3D

## Explicitly public, cinematic RTS presentation. It consumes only already-filtered public
## projections.  New RTS projections contain individually authoritative units; the legacy
## commander/count shape remains accepted only so older sealed replays remain viewable.

const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")
const TownHallModel := preload("res://assets/external/quaternius_medieval_village/buildings_fbx/Mill.fbx")
const BarracksModel := preload("res://assets/external/quaternius_medieval_village/buildings_fbx/Stable.fbx")
const TowerModel := preload("res://assets/external/quaternius_medieval_village/buildings_fbx/Bell_Tower.fbx")
const GRASS_TEXTURE := preload("res://assets/terrain/frontier/frontier-grass-v1.png")
const WATER_TEXTURE := preload("res://assets/terrain/frontier/frontier-water-v1.png")
const TEAM_COLOURS := {"participant_0": Color("34d399"), "participant_1": Color("a78bfa")}
# Public broadcast names deliberately differ from the authority's stable participant ids and
# blue/red internal map keys.  This is presentation-only branding; deterministic authority,
# task ids, replay evidence, and participant filtering remain unchanged.
const TEAM_NAMES := {"participant_0": "TERRA", "participant_1": "LUNA"}
const PUBLIC_TASK := "rts-skirmish-v0"
const SAFE_EVENT_LABELS := {
	"material_deposited": "Materials deposited",
	"rts_material_deposited": "Materials deposited",
	"unit_spawned": "New worker deployed",
	"rts_unit_spawned": "New worker deployed",
	"structure_completed": "Base structure completed",
	"rts_structure_completed": "Base structure completed",
	"unit_armed": "Militia armed",
	"rts_unit_armed": "Militia armed",
	"unit_lost": "Unit defeated",
	"rts_unit_lost": "Unit defeated",
	"rts_unit_hit": "Unit under attack",
	"rts_construction_started": "Construction started",
	"rts_construction_failed": "Construction delayed",
	"rts_structure_built": "Base structure completed",
	"rts_structure_damaged": "Structure under attack",
	"rts_structure_destroyed": "Structure destroyed",
	"rts_material_gathered": "Resources gathered",
	"rts_skirmish_completed": "Victory secured",
	"tower_destroyed": "Tower destroyed",
	"town_hall_destroyed": "Town Hall destroyed",
	"victory": "Victory secured",
}
const LEGACY_FORMATION_OFFSETS := [Vector3(-0.62, 0.0, 0.34), Vector3(0.62, 0.0, 0.34), Vector3(0.0, 0.0, -0.62), Vector3(-0.8, 0.0, -0.46)]
const DEFEAT_PRESENTATION_SECONDS := 1.1
## Authority snapshots are 10 ticks apart. At the RTS showcase speed (80 mt/tick), an
## actor can legally advance at most 800 mt = 0.8 rendered world units per snapshot.
const MAX_SNAPSHOT_TRAVEL_WORLD := 0.8
# These are the public-map counterparts of the seven authority resource ids for each base.
# They deliberately stay inside the ±8,000 mt arena and retain clear individual walk lanes.
# Blue's anchor is (-4,200, +4,100); Red is its exact rotational mirror.
const BLUE_BASE_RESOURCES := [
	Vector2i(-6200, 5000), Vector2i(-7000, 6100), Vector2i(-5700, 6900), Vector2i(-7600, 7100),
	Vector2i(-5200, 6100), Vector2i(-6400, 7400), Vector2i(-7700, 6500),
]

var _root: Node3D
var _actors := {}
var _structures := {}
## Authority retains historical dead units for replay evidence.  Presentation records their
## completed defeat once so later snapshots cannot create a fresh Y Bot for the same corpse.
var _presented_defeats := {}
var _camera: Camera3D
var _camera_target := Vector3.ZERO
var _camera_position := Vector3(0.0, 24.0, 27.0)
var _outro_active := false
var _outro_elapsed_seconds := 0.0
var _snapshot := {"participant_id": "broadcast", "task_id": PUBLIC_TASK, "observation_seq": -1}
var _hud: RichTextLabel
var _beat: Label
var _agent_task_boards := {}


func _ready() -> void:
	_build()


func _process(delta: float) -> void:
	for actor: Variant in _actors.values():
		if actor is Node3D and is_instance_valid(actor):
			_smooth_node(actor, delta)
	for structure: Variant in _structures.values():
		if structure is Node3D and is_instance_valid(structure):
			_smooth_node(structure, delta)
	_animate_resources(delta)
	_advance_defeated_actors(delta)
	if _outro_active:
		_outro_elapsed_seconds += delta
		var angle := -1.17 + minf(_outro_elapsed_seconds, 25.0) * 0.014
		_camera_target = Vector3(5.0, 0.6, -5.0)
		_camera_position = _camera_target + Vector3(cos(angle) * 12.0, 10.5, sin(angle) * 12.0)
	if _camera != null:
		_camera.position = _camera.position.lerp(_camera_position, minf(1.0, delta * 1.9))
		_camera.look_at(_camera_target, Vector3.UP)


func apply_public_sources(sources: Dictionary, observation_seq: int, tick: int) -> bool:
	_build()
	if typeof(observation_seq) != TYPE_INT or observation_seq < 0 or typeof(tick) != TYPE_INT or tick < 0 \
			or sources.size() != 2:
		return false
	var seen := {}
	for participant_id: String in ["participant_0", "participant_1"]:
		var source: Variant = sources.get(participant_id)
		if not source is Dictionary or source.get("participant_id") != participant_id \
				or not source.get("own") is Dictionary:
			return false
		var own: Dictionary = source.own
		var units: Variant = source.get("units", own.get("units", []))
		if units is Array:
			if not _upsert_first_class_units(participant_id, units, seen):
				return false
		elif source.get("operator") is Dictionary:
			# Compatibility path for the original one-operator showcase only.  It is not
			# used for rts-task-plan-v1, where every displayed character has a unit id.
			var operator: Dictionary = source.operator
			if not _upsert_commander(participant_id, operator):
				return false
			seen["%s_commander" % participant_id] = true
			var unit_count := int((units as Dictionary).get("count", 0)) if units is Dictionary else 0
			if unit_count < 0 or unit_count > LEGACY_FORMATION_OFFSETS.size():
				return false
			for unit_index: int in unit_count:
				var unit_key := "%s_unit_%d" % [participant_id, unit_index]
				if not _upsert_unit(unit_key, participant_id, operator, LEGACY_FORMATION_OFFSETS[unit_index]):
					return false
				seen[unit_key] = true
		else:
			return false
		for kind: String in ["town_hall", "barracks", "tower"]:
			var structure: Variant = own.get(kind)
			if structure is Dictionary and _upsert_structure("%s_%s" % [participant_id, kind], kind, participant_id, structure):
				seen["%s_%s" % [participant_id, kind]] = true
		for raw: Variant in source.get("visible_entities", []):
			if not raw is Dictionary:
				return false
			var entity: Dictionary = raw
			var entity_id := str(entity.get("id", ""))
			var kind := str(entity.get("kind", ""))
			# The base-destruction story has no central beacon/disc.  Public scenery is
			# created once in _build_persistent_resources, never from visibility updates.
			if entity_id.is_empty() or kind not in ["resource_wood", "resource_ore"]:
				continue
			_apply_resource_state(participant_id, entity)
	_remove_stale(seen)
	_snapshot = {"participant_id": "broadcast", "task_id": PUBLIC_TASK, "observation_seq": observation_seq, "tick": tick}
	_apply_camera_beat(tick)
	_update_match_hud(sources)
	return true


func snapshot_copy() -> Dictionary:
	return _snapshot.duplicate(true)


func begin_cinematic_intro() -> void:
	_build()
	_outro_active = false
	_camera_position = Vector3(0.0, 24.0, 27.0)
	_camera_target = Vector3.ZERO
	_beat.text = "WORLD ARENA • TWO BASES PREPARE FOR WAR"


func begin_cinematic_outro() -> void:
	_build()
	_outro_active = true
	_outro_elapsed_seconds = 0.0
	_beat.text = "VICTORY • TWO TERRA SURVIVORS STAND"


func _build() -> void:
	if _root != null:
		return
	_root = Node3D.new()
	_root.name = "PublicRtsBroadcastWorld"
	add_child(_root)
	_build_forest()
	_build_persistent_resources()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	sun.light_color = Color("ffe2ad")
	sun.light_energy = 1.45
	sun.shadow_enabled = true
	_root.add_child(sun)
	_camera = Camera3D.new()
	_camera.name = "PublicBroadcastCamera"
	_camera.current = true
	_camera.fov = 45.0
	_camera.near = 0.1
	_camera.far = 110.0
	_camera.position = _camera_position
	_root.add_child(_camera)
	_build_hud()


func _build_forest() -> void:
	var ground := _mesh("ForestGround", BoxMesh.new(), Color("244c30"))
	(ground.mesh as BoxMesh).size = Vector3(34.0, 0.16, 34.0)
	_apply_texture(ground, GRASS_TEXTURE, Vector3(8.0, 8.0, 8.0), Color("d4ead0"))
	ground.position.y = -0.12
	_root.add_child(ground)
	var river := _mesh("River", BoxMesh.new(), Color("2485ad"))
	(river.mesh as BoxMesh).size = Vector3(4.15, 0.04, 34.0)
	_apply_texture(river, WATER_TEXTURE, Vector3(1.5, 8.0, 1.5), Color("b9e5ff"))
	river.position.y = 0.02
	_root.add_child(river)
	for bridge_z: float in [-7.0, 0.0, 7.0]:
		var bridge := _mesh("Bridge_%d" % int(bridge_z), BoxMesh.new(), Color("b57b42"))
		(bridge.mesh as BoxMesh).size = Vector3(4.8, 0.23, 1.25)
		bridge.position = Vector3(0.0, 0.16, bridge_z)
		_root.add_child(bridge)
	for index: int in 24:
		var side := -1.0 if index % 2 == 0 else 1.0
		var tree := Node3D.new()
		tree.position = Vector3(side * (10.4 + float(index % 3) * 1.25), 0.0, -14.4 + float(index / 2) * 2.35)
		var trunk := _mesh("Trunk", CylinderMesh.new(), Color("67422d"))
		(trunk.mesh as CylinderMesh).top_radius = 0.18
		(trunk.mesh as CylinderMesh).bottom_radius = 0.25
		(trunk.mesh as CylinderMesh).height = 1.65
		trunk.position.y = 0.82
		tree.add_child(trunk)
		var crown := _mesh("Crown", SphereMesh.new(), [Color("245a39"), Color("2b7043"), Color("3c824c")][index % 3])
		(crown.mesh as SphereMesh).radial_segments = 8
		(crown.mesh as SphereMesh).rings = 4
		(crown.mesh as SphereMesh).radius = 0.85
		(crown.mesh as SphereMesh).height = 1.7
		crown.position.y = 2.02
		tree.add_child(crown)
		_root.add_child(tree)
	var environment := WorldEnvironment.new()
	var world := Environment.new()
	world.background_mode = Environment.BG_COLOR
	world.background_color = Color("5d91b2")
	world.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.ambient_light_color = Color("bfdac4")
	world.ambient_light_energy = 0.56
	world.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.tonemap_exposure = 0.78
	environment.environment = world
	_root.add_child(environment)


func _build_persistent_resources() -> void:
	# The public arena owns its scenery.  Every base gets four spaced trees and three
	# dark ore seams before the first public projection arrives.  Red is the exact
	# rotational mirror of Blue, so no resource can materialise from visibility.
	for team_index: int in 2:
		var participant_id := "participant_%d" % team_index
		for resource_index: int in BLUE_BASE_RESOURCES.size():
			var base_position: Vector2i = BLUE_BASE_RESOURCES[resource_index]
			var position := base_position if team_index == 0 else -base_position
			var kind := "resource_wood" if resource_index < 4 else "resource_ore"
			var prop := _new_prop("%s_%s_%d" % [participant_id, "tree" if kind == "resource_wood" else "ore", resource_index if kind == "resource_wood" else resource_index - 4], kind)
			prop.position = _world_position({"x": position.x, "y": position.y})
			prop.set_meta("resource_team", participant_id)
			prop.set_meta("resource_kind", kind)
			prop.set_meta("authority_resource_id", _canonical_resource_id(participant_id, kind, resource_index if kind == "resource_wood" else resource_index - 4))
			prop.set_meta("resource_depleted", false)
			prop.set_meta("persistent_resource", true)
			_root.add_child(prop)
			_structures[prop.name] = prop


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PublicRtsHudLayer"
	add_child(layer)
	var panel := ColorRect.new()
	panel.name = "PublicRtsHudPanel"
	panel.position = Vector2(20.0, 20.0)
	panel.size = Vector2(1050.0, 124.0)
	panel.color = Color("0b1320e8")
	layer.add_child(panel)
	_hud = RichTextLabel.new()
	_hud.name = "PublicRtsHudText"
	_hud.position = Vector2(16.0, 10.0)
	_hud.size = Vector2(1018.0, 76.0)
	_hud.bbcode_enabled = true
	_hud.scroll_active = false
	_hud.add_theme_font_size_override("normal_font_size", 17)
	panel.add_child(_hud)
	_beat = Label.new()
	_beat.name = "PublicRtsBeatText"
	_beat.position = Vector2(16.0, 88.0)
	_beat.size = Vector2(1018.0, 26.0)
	_beat.add_theme_font_size_override("font_size", 16)
	_beat.modulate = Color("f7cf75")
	panel.add_child(_beat)
	_build_agent_task_board(layer, "participant_0", Vector2(20.0, 158.0))
	_build_agent_task_board(layer, "participant_1", Vector2(1375.0, 158.0))


func _build_agent_task_board(layer: CanvasLayer, participant_id: String, position: Vector2) -> void:
	var panel := ColorRect.new()
	panel.name = "%sAgentTaskPanel" % TEAM_NAMES[participant_id].capitalize()
	panel.position = position
	panel.size = Vector2(525.0, 136.0)
	panel.color = Color("0b1320d9")
	layer.add_child(panel)
	var text := RichTextLabel.new()
	text.name = "AgentTaskText"
	text.position = Vector2(14.0, 10.0)
	text.size = Vector2(497.0, 116.0)
	text.bbcode_enabled = true
	text.scroll_active = false
	text.add_theme_font_size_override("normal_font_size", 16)
	panel.add_child(text)
	_agent_task_boards[participant_id] = text


func _upsert_commander(participant_id: String, source: Dictionary) -> bool:
	var key := "%s_commander" % participant_id
	var actor := _actors.get(key) as Node3D
	if actor == null:
		actor = _new_y_bot(key, participant_id, "COMMANDER")
		_root.add_child(actor)
		_actors[key] = actor
	return _set_actor(actor, participant_id, source, Vector3.ZERO)


func _upsert_unit(key: String, participant_id: String, source: Dictionary, offset: Vector3) -> bool:
	var actor := _actors.get(key) as Node3D
	if actor == null:
		actor = _new_y_bot(key, participant_id, "SQUAD")
		actor.scale = Vector3(0.93, 0.93, 0.93)
		_root.add_child(actor)
		_actors[key] = actor
	return _set_actor(actor, participant_id, source, offset)


func _upsert_first_class_units(participant_id: String, units: Array, seen: Dictionary) -> bool:
	if units.size() > 3:
		return false
	var ids := {}
	for raw: Variant in units:
		if not raw is Dictionary:
			return false
		var unit: Dictionary = raw
		var unit_id := str(unit.get("unit_id", ""))
		if unit_id.is_empty() or ids.has(unit_id) or not unit.get("position_mt") is Dictionary \
				or typeof(unit.get("heading", -1)) != TYPE_INT:
			return false
		ids[unit_id] = true
		var key := "%s_unit_%s" % [participant_id, _node_safe_id(unit_id)]
		var state := str(unit.get("animation_state", unit.get("state", "idle")))
		var dead := not bool(unit.get("alive", state != "defeat")) or state in ["defeat", "defeated"]
		if _presented_defeats.has(key):
			# A dead authority record remains visible to verification, not the broadcast.
			continue
		var actor := _actors.get(key) as Node3D
		if dead:
			_presented_defeats[key] = true
			if actor != null:
				_set_actor(actor, participant_id, unit, Vector3.ZERO)
				seen[key] = true
			continue
		if actor == null:
			actor = _new_y_bot(key, participant_id, _safe_role_label(unit.get("role", "worker")))
			actor.scale = Vector3(0.93, 0.93, 0.93)
			_root.add_child(actor)
			_actors[key] = actor
		actor.set_meta("presentation_unit_id", unit_id)
		actor.set_meta("presentation_role", _safe_role_label(unit.get("role", "worker")))
		if not _set_actor(actor, participant_id, unit, Vector3.ZERO):
			return false
		seen[key] = true
	return true


func _set_actor(actor: Node3D, participant_id: String, source: Dictionary, offset: Vector3) -> bool:
	var world_position: Variant = _world_position(source.get("position_mt"))
	var heading: Variant = source.get("heading", 0)
	if world_position == null or typeof(heading) != TYPE_INT or int(heading) < 0 or int(heading) > 7:
		return false
	var yaw := -float(int(heading)) * PI / 4.0
	_set_actor_target(actor, world_position + offset.rotated(Vector3.UP, yaw), yaw)
	var state := str(source.get("animation_state", source.get("state", "idle")))
	var alive := bool(source.get("alive", state != "defeat"))
	if not alive:
		state = "defeat"
	if state == "defeat":
		_start_defeat(actor)
	else:
		actor.visible = true
		actor.set_meta("presentation_defeated", false)
	if actor.has_method("play_state"):
		actor.call("play_state", StringName(_animation(state)))
	var label := actor.get_node_or_null("Label") as Label3D
	if label != null:
		var health := clampi(int(source.get("health_percent", 100)), 0, 100)
		var filled := int((health + 19) / 20)
		var bar := "█".repeat(filled) + "░".repeat(5 - filled)
		label.text = "%s • %s  %s %d%%" % [str(actor.get_meta("presentation_team", TEAM_NAMES[participant_id])), str(actor.get_meta("presentation_role", "WORKER")), bar, health]
	var bubble := actor.get_node_or_null("Speech") as Label3D
	if bubble != null:
		# Never display `intent`, memory, prompt, target coordinates, or a provider response.
		# This bounded task summary is derived solely from public structured unit state.
		bubble.text = "TASK • %s" % _safe_agent_task_summary(source, state)
	_set_carrying(actor, str(source.get("carrying", "")))
	return true


func _set_actor_target(actor: Node3D, requested: Vector3, yaw: float) -> void:
	if not bool(actor.get_meta("presentation_has_authority_target", false)):
		# Initial materialisation is the authoritative spawn position; it is not a
		# movement transition and therefore cannot be an interpolation teleport.
		actor.position = requested
		actor.set_meta("presentation_target_position", requested)
		actor.set_meta("presentation_has_authority_target", true)
	else:
		var previous: Vector3 = actor.get_meta("presentation_target_position", actor.position)
		var displacement := requested - previous
		if displacement.length() > MAX_SNAPSHOT_TRAVEL_WORLD:
			requested = previous + displacement.normalized() * MAX_SNAPSHOT_TRAVEL_WORLD
			actor.set_meta("presentation_discontinuity_clamped", true)
		else:
			actor.set_meta("presentation_discontinuity_clamped", false)
		actor.set_meta("presentation_target_position", requested)
	actor.set_meta("presentation_target_yaw", yaw)


func _set_carrying(actor: Node3D, carrying: String) -> void:
	var prop := actor.get_node_or_null("CarryProp") as Node3D
	if carrying.is_empty():
		if prop != null:
			prop.visible = false
		return
	if prop == null:
		prop = Node3D.new()
		prop.name = "CarryProp"
		prop.position = Vector3(0.32, 1.0, 0.18)
		actor.add_child(prop)
	var is_ore := carrying.to_lower().contains("ore")
	if prop.get_child_count() == 0:
		var carried := _mesh("OrePack" if is_ore else "LogBundle", SphereMesh.new() if is_ore else CylinderMesh.new(), Color("33404e") if is_ore else Color("70452f"))
		if carried.mesh is SphereMesh:
			(carried.mesh as SphereMesh).radius = 0.22
			(carried.mesh as SphereMesh).height = 0.32
		else:
			(carried.mesh as CylinderMesh).top_radius = 0.12
			(carried.mesh as CylinderMesh).bottom_radius = 0.15
			(carried.mesh as CylinderMesh).height = 0.55
			carried.rotation_degrees.z = 90.0
		prop.add_child(carried)
	prop.visible = true


func _upsert_structure(key: String, kind: String, participant_id: String, source: Dictionary) -> bool:
	var position: Variant = _world_position(source.get("position_mt"))
	if position == null:
		return false
	var node := _structures.get(key) as Node3D
	if node == null:
		node = _new_structure(key, kind, participant_id)
		_root.add_child(node)
		_structures[key] = node
		node.position = position
	node.set_meta("presentation_target_position", position)
	var structure_state := str(source.get("state", "active"))
	_set_structure_state(node, structure_state, int(source.get("health_percent", 100)))
	var label := node.get_node_or_null("Label") as Label3D
	if label != null:
		var health := clampi(int(source.get("health_percent", 100)), 0, 100)
		var normalized := structure_state.to_lower()
		var destroyed := normalized in ["destroyed", "rubble", "ruined"] or health <= 0
		label.visible = not destroyed
		label.text = "%s • %s" % [kind.to_upper().replace("_", " "), normalized.to_upper().replace("_", " ")] if normalized in ["unbuilt", "building", "construction"] else "%s • %d%%" % [kind.to_upper().replace("_", " "), health]
		label.modulate = TEAM_COLOURS[participant_id]
	return true


func _upsert_prop(key: String, kind: String, source: Dictionary) -> bool:
	var position: Variant = _world_position(source.get("position_mt"))
	if position == null:
		return false
	var node := _structures.get(key) as Node3D
	if node == null:
		node = _new_prop(key, kind)
		_root.add_child(node)
		_structures[key] = node
	node.set_meta("presentation_target_position", position)
	return true


func _new_y_bot(key: String, participant_id: String, role: String) -> Node3D:
	var actor := YBot.instantiate() as Node3D
	actor.name = key
	var tree := actor.get_node_or_null("AnimationTree") as AnimationTree
	if tree != null and tree.tree_root != null:
		tree.tree_root = tree.tree_root.duplicate(true)
	_tint(actor, TEAM_COLOURS[participant_id])
	var label := Label3D.new()
	label.name = "Label"
	label.text = "%s • %s  █████ 100%%" % [TEAM_NAMES[participant_id], role]
	label.position.y = 2.6
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 28
	label.pixel_size = 0.004
	label.outline_size = 5
	label.modulate = TEAM_COLOURS[participant_id]
	actor.add_child(label)
	var bubble := Label3D.new()
	bubble.name = "Speech"
	bubble.position.y = 3.0
	bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bubble.font_size = 24
	bubble.pixel_size = 0.004
	bubble.outline_size = 5
	bubble.modulate = Color("fff2cf")
	actor.add_child(bubble)
	actor.set_meta("presentation_actor", "mixamo-y-bot")
	actor.set_meta("presentation_team", TEAM_NAMES[participant_id])
	actor.set_meta("presentation_role", role)
	return actor


func _new_structure(key: String, kind: String, participant_id: String) -> Node3D:
	var packed: PackedScene = TownHallModel if kind == "town_hall" else BarracksModel if kind == "barracks" else TowerModel
	var node := Node3D.new()
	node.name = key
	var model := packed.instantiate() as Node3D
	model.name = "Model"
	var model_scale := 0.34 if kind == "town_hall" else 0.38 if kind == "barracks" else 0.42
	model.scale = Vector3.ONE * model_scale
	# Keep the authored village materials readable.  Team identity is added as a small
	# banner and ground ring rather than turning every building into a flat colour block.
	node.add_child(model)
	node.add_child(_team_marker(participant_id, kind))
	var site := _construction_site(kind, TEAM_COLOURS[participant_id])
	node.add_child(site)
	var rubble := _rubble(kind)
	node.add_child(rubble)
	var label := Label3D.new()
	label.name = "Label"
	label.position.y = 3.35 if kind == "town_hall" else 2.8
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 26
	label.pixel_size = 0.004
	label.outline_size = 5
	node.add_child(label)
	return node


func _team_marker(participant_id: String, kind: String) -> Node3D:
	var marker := Node3D.new()
	marker.name = "TeamMarker"
	var colour: Color = TEAM_COLOURS[participant_id]
	var ring := _mesh("TeamRing", CylinderMesh.new(), colour)
	var ring_radius := 0.85 if kind == "town_hall" else 0.62 if kind == "barracks" else 0.52
	(ring.mesh as CylinderMesh).top_radius = ring_radius
	(ring.mesh as CylinderMesh).bottom_radius = ring_radius
	(ring.mesh as CylinderMesh).height = 0.035
	ring.position.y = 0.04
	marker.add_child(ring)
	var pole := _mesh("BannerPole", CylinderMesh.new(), Color("4a3527"))
	(pole.mesh as CylinderMesh).top_radius = 0.035
	(pole.mesh as CylinderMesh).bottom_radius = 0.045
	(pole.mesh as CylinderMesh).height = 2.2 if kind == "town_hall" else 1.65
	pole.position = Vector3(0.95 if kind == "town_hall" else 0.72, pole.mesh.height * 0.5, 0.0)
	marker.add_child(pole)
	var banner := _mesh("TeamBanner", BoxMesh.new(), colour)
	(banner.mesh as BoxMesh).size = Vector3(0.06, 0.62, 0.52)
	banner.position = Vector3(pole.position.x, pole.mesh.height - 0.34, 0.0)
	marker.add_child(banner)
	return marker


func _construction_site(kind: String, colour: Color) -> Node3D:
	var site := Node3D.new()
	site.name = "ConstructionSite"
	site.visible = false
	var foundation := _mesh("Foundation", BoxMesh.new(), colour.darkened(0.35))
	(foundation.mesh as BoxMesh).size = Vector3(2.7 if kind == "town_hall" else 2.0, 0.16, 2.3 if kind == "town_hall" else 2.0)
	foundation.position.y = 0.08
	site.add_child(foundation)
	for index: int in 4:
		var stake := _mesh("Stake_%d" % index, CylinderMesh.new(), Color("c7904e"))
		(stake.mesh as CylinderMesh).top_radius = 0.06
		(stake.mesh as CylinderMesh).bottom_radius = 0.08
		(stake.mesh as CylinderMesh).height = 1.15
		stake.position = Vector3(-0.8 if index < 2 else 0.8, 0.58, -0.8 if index % 2 == 0 else 0.8)
		site.add_child(stake)
	return site


func _rubble(kind: String) -> Node3D:
	var rubble := Node3D.new()
	rubble.name = "Rubble"
	rubble.visible = false
	for index: int in 4:
		var stone := _mesh("Rubble_%d" % index, BoxMesh.new(), Color("3a3432"))
		(stone.mesh as BoxMesh).size = Vector3(0.45 + float(index % 2) * 0.18, 0.22, 0.4 + float(index / 2) * 0.16)
		stone.position = Vector3(-0.5 + float(index % 2), 0.11, -0.42 + float(index / 2) * 0.8)
		rubble.add_child(stone)
	return rubble


func _set_structure_state(node: Node3D, state: String, health: int) -> void:
	var normalized := state.to_lower()
	var destroyed := normalized in ["destroyed", "rubble", "ruined"] or health <= 0
	var building := normalized in ["unbuilt", "building", "construction"]
	var model := node.get_node_or_null("Model") as Node3D
	var site := node.get_node_or_null("ConstructionSite") as Node3D
	var rubble := node.get_node_or_null("Rubble") as Node3D
	var marker := node.get_node_or_null("TeamMarker") as Node3D
	if model != null: model.visible = not building and not destroyed
	if site != null: site.visible = building and not destroyed
	if rubble != null: rubble.visible = destroyed
	if marker != null: marker.visible = not building and not destroyed


func _new_prop(key: String, kind: String) -> Node3D:
	var node := Node3D.new()
	node.name = key
	if kind == "resource_wood":
		var trunk := _mesh("HarvestTreeTrunk", CylinderMesh.new(), Color("70452f"))
		(trunk.mesh as CylinderMesh).top_radius = 0.16
		(trunk.mesh as CylinderMesh).bottom_radius = 0.25
		(trunk.mesh as CylinderMesh).height = 1.95
		trunk.position.y = 0.98
		node.add_child(trunk)
		var crown := _mesh("HarvestTreeCrown", SphereMesh.new(), Color("28643c"))
		(crown.mesh as SphereMesh).radial_segments = 8
		(crown.mesh as SphereMesh).rings = 4
		(crown.mesh as SphereMesh).radius = 0.78
		(crown.mesh as SphereMesh).height = 1.5
		crown.position = Vector3(0.0, 2.12, 0.0)
		node.add_child(crown)
	elif kind == "resource_ore":
		var ore := _mesh("Ore", SphereMesh.new(), Color("303944"))
		(ore.mesh as SphereMesh).radial_segments = 8
		(ore.mesh as SphereMesh).rings = 4
		(ore.mesh as SphereMesh).radius = 0.6
		(ore.mesh as SphereMesh).height = 0.9
		ore.position.y = 0.45
		var material := ore.material_override as StandardMaterial3D
		material.metallic = 0.42
		material.roughness = 0.43
		node.add_child(ore)
		for vein_index: int in 2:
			var vein := _mesh("OreVein_%d" % vein_index, BoxMesh.new(), Color("b4773c"))
			(vein.mesh as BoxMesh).size = Vector3(0.08, 0.34, 0.5)
			vein.position = Vector3(-0.15 + float(vein_index) * 0.3, 0.48, -0.42 + float(vein_index) * 0.12)
			vein.rotation_degrees = Vector3(0.0, 32.0 + float(vein_index) * 24.0, -30.0)
			node.add_child(vein)
	return node


func _remove_stale(seen: Dictionary) -> void:
	for key: String in _actors.keys():
		if not seen.has(key):
			var actor: Node3D = _actors[key]
			if "_unit_" in key:
				_start_defeat(actor)
				continue
			_actors.erase(key)
			actor.queue_free()
	for key: String in _structures.keys():
		if not seen.has(key):
			var structure: Node3D = _structures[key]
			if bool(structure.get_meta("persistent_resource", false)):
				continue
			_structures.erase(key)
			structure.queue_free()


func _start_defeat(actor: Node3D) -> void:
	if bool(actor.get_meta("presentation_defeated", false)):
		return
	actor.set_meta("presentation_defeated", true)
	actor.set_meta("presentation_defeat_seconds", DEFEAT_PRESENTATION_SECONDS)
	if actor.has_method("play_state"):
		actor.call("play_state", &"defeat")
	var bubble := actor.get_node_or_null("Speech") as Label3D
	if bubble != null:
		bubble.text = "TASK • Unit down"


func _advance_defeated_actors(delta: float) -> void:
	for key: String in _actors.keys():
		var actor := _actors.get(key) as Node3D
		if actor == null or not bool(actor.get_meta("presentation_defeated", false)):
			continue
		var remaining := float(actor.get_meta("presentation_defeat_seconds", DEFEAT_PRESENTATION_SECONDS)) - delta
		actor.set_meta("presentation_defeat_seconds", remaining)
		if remaining <= 0.0:
			_actors.erase(key)
			actor.queue_free()


func _apply_resource_state(participant_id: String, source: Dictionary) -> void:
	# Authority can safely publish resource ids/states.  An id resolves to a prebuilt
	# node only; an unmatched id is intentionally ignored rather than creating scenery.
	var kind := str(source.get("kind", ""))
	var id := str(source.get("id", ""))
	var resource_key := _resource_key_for_authority_id(participant_id, kind, id)
	var node := _structures.get(resource_key) as Node3D
	if node == null:
		return
	var depleted := str(source.get("state", "")) in ["depleted", "exhausted", "stump", "cracked"]
	node.set_meta("resource_depleted", depleted)
	node.set_meta("resource_harvesting", str(source.get("state", "")) in ["harvesting", "gathering"])
	var crown := node.get_node_or_null("HarvestTreeCrown") as MeshInstance3D
	if crown != null:
		crown.visible = not depleted
	var trunk := node.get_node_or_null("HarvestTreeTrunk") as MeshInstance3D
	if trunk != null:
		trunk.scale.y = 0.24 if depleted else 1.0
		trunk.position.y = 0.24 if depleted else 0.98
	var ore := node.get_node_or_null("Ore") as MeshInstance3D
	if ore != null:
		ore.scale.y = 0.35 if depleted else 1.0
	for vein_index: int in 2:
		var vein := node.get_node_or_null("OreVein_%d" % vein_index) as MeshInstance3D
		if vein != null:
			vein.scale.y = 0.35 if depleted else 1.0


func _canonical_resource_id(participant_id: String, kind: String, index: int) -> String:
	return ("blue" if participant_id == "participant_0" else "red") + ("_tree_" if kind == "resource_wood" else "_ore_") + str(index)


func _resource_key_for_authority_id(participant_id: String, kind: String, raw_id: String) -> String:
	var id := raw_id.trim_prefix("v_")
	var team := participant_id
	if id.begins_with("blue_"):
		team = "participant_0"
	elif id.begins_with("red_"):
		team = "participant_1"
	var index := _trailing_index(id)
	if index < 0:
		return ""
	if id in ["wood_0", "ore_0"]:
		team = "participant_0"
	elif id in ["wood_1", "ore_1"]:
		team = "participant_1"
	var expected_kind := "resource_wood" if ("tree" in id or "wood" in id) else "resource_ore"
	if kind != expected_kind:
		return ""
	return "%s_%s_%d" % [team, "tree" if expected_kind == "resource_wood" else "ore", index]


func _animate_resources(delta: float) -> void:
	for structure: Variant in _structures.values():
		if not structure is Node3D or not bool((structure as Node3D).get_meta("persistent_resource", false)):
			continue
		var node := structure as Node3D
		if not bool(node.get_meta("resource_harvesting", false)):
			node.rotation.z = lerp(node.rotation.z, 0.0, minf(1.0, delta * 6.0))
			continue
		var phase := float(node.get_meta("resource_sway_phase", 0.0)) + delta * 10.0
		node.set_meta("resource_sway_phase", phase)
		node.rotation.z = sin(phase) * 0.075


func _trailing_index(value: String) -> int:
	var digits := ""
	for index: int in value.length():
		var character := value[value.length() - index - 1]
		if character < "0" or character > "9":
			break
		digits = character + digits
	return int(digits) if not digits.is_empty() else -1


func _node_safe_id(value: String) -> String:
	return value.replace("-", "_").replace("/", "_").replace(" ", "_")


func _apply_camera_beat(tick: int) -> void:
	var label := "OPENING ECONOMY"
	if tick < 100:
		_camera_position = Vector3(0.0, 24.0, 27.0)
		_camera_target = Vector3.ZERO
		label = "WORLD ARENA • TWO BASES PREPARE FOR WAR"
	elif tick < 250:
		_camera_position = Vector3(-11.5, 12.5, 17.5)
		_camera_target = Vector3(-6.2, 0.0, 5.6)
		label = "TERRA BASE • FIRST WORKER HARVESTS"
	elif tick < 400:
		_camera_position = Vector3(11.5, 12.5, -17.5)
		_camera_target = Vector3(6.2, 0.0, -5.6)
		label = "LUNA BASE • MATCHING TERRA'S ECONOMY"
	elif tick < 600:
		_camera_position = Vector3(0.0, 24.0, 27.0)
		_camera_target = Vector3(0.0, 0.0, 0.0)
		label = "THREE WORKERS PER SIDE • RESOURCES RETURN HOME"
	elif tick < 750:
		_camera_position = Vector3(-8.8, 13.5, 17.0)
		_camera_target = Vector3(-6.7, 0.0, 5.9)
		label = "BARRACKS RISE • WORKERS ARM"
	elif tick < 800:
		_camera_position = Vector3(0.0, 13.0, 17.5)
		_camera_target = Vector3(0.0, 0.0, 0.0)
		label = "SQUADS MARCH • BRIDGE AHEAD"
	elif tick < 920:
		_camera_position = Vector3(-1.0, 7.0, 12.5)
		_camera_target = Vector3(0.0, 0.6, 0.0)
		label = "BRIDGE BATTLE • THE LINE BREAKS"
	elif tick < 1030:
		_camera_position = Vector3(8.5, 9.5, -13.5)
		_camera_target = Vector3(4.3, 0.7, -4.5)
		label = "LUNA RETREATS • TERRA PURSUES"
	elif tick < 1120:
		_camera_position = Vector3(11.5, 15.5, -18.5)
		_camera_target = Vector3(5.0, 0.4, -4.5)
		label = "LUNA TOWER UNDER SIEGE"
	elif tick < 1190:
		_camera_position = Vector3(11.5, 14.5, -17.5)
		_camera_target = Vector3(5.5, 0.4, -5.0)
		label = "LUNA TOWN HALL FALLS • TERRA VICTORY"
	else:
		_camera_position = Vector3(10.5, 15.0, -18.0)
		_camera_target = Vector3(5.5, 0.4, -5.0)
		label = "VICTORY • TWO TERRA SURVIVORS STAND"
	_beat.text = label


func _update_match_hud(sources: Dictionary) -> void:
	var blue: Dictionary = sources.participant_0
	var red: Dictionary = sources.participant_1
	var blue_own: Dictionary = blue.get("own", {})
	var red_own: Dictionary = red.get("own", {})
	var blue_units := _living_units(blue)
	var red_units := _living_units(red)
	var blue_town := int((blue_own.get("town_hall", {}) as Dictionary).get("health_percent", 100))
	var red_town := int((red_own.get("town_hall", {}) as Dictionary).get("health_percent", 100))
	var blue_tower := _structure_health(blue_own, "tower")
	var red_tower := _structure_health(red_own, "tower")
	var blue_materials := _materials(blue_own)
	var red_materials := _materials(red_own)
	# The broadcast derives editorial copy from its public tick, not a text field that could
	# originate with a provider.  It therefore cannot surface prompt/model text by accident.
	var phase := _phase_for_tick(int(_snapshot.get("tick", 0)))
	var objective := _objective_for_tick(int(_snapshot.get("tick", 0)))
	var event_summary := _safe_recent_event([blue, red])
	_hud.text = "[color=#34d399]TERRA[/color]  Living %d (%s) • Wood %d • Ore %d • Hall %d%% • Tower %d%%     [color=#a78bfa]LUNA[/color]  Living %d (%s) • Wood %d • Ore %d • Hall %d%% • Tower %d%%\n[color=#f7cf75]PHASE[/color] %s  [color=#dbe7f5]OBJECTIVE[/color] %s\n[color=#a7f3d0]EVENT[/color] %s" % [blue_units, _unit_roles(blue), blue_materials.x, blue_materials.y, blue_town, blue_tower, red_units, _unit_roles(red), red_materials.x, red_materials.y, red_town, red_tower, phase, objective, event_summary]
	_update_agent_task_boards({"participant_0": blue, "participant_1": red})


func _update_agent_task_boards(sources: Dictionary) -> void:
	for participant_id: String in ["participant_0", "participant_1"]:
		var board := _agent_task_boards.get(participant_id) as RichTextLabel
		var source: Variant = sources.get(participant_id)
		if board == null or not source is Dictionary:
			continue
		var entries_by_slot := {}
		var units: Variant = (source as Dictionary).get("units", ((source as Dictionary).get("own", {}) as Dictionary).get("units", []))
		if units is Array:
			for index: int in (units as Array).size():
				var raw: Variant = (units as Array)[index]
				if not raw is Dictionary:
					continue
				var unit: Dictionary = raw
				var unit_id := str(unit.get("unit_id", unit.get("id", "")))
				var slot := _trailing_index(unit_id)
				if slot < 0 or slot > 2:
					slot = index
				if slot < 0 or slot > 2:
					continue
				var role := _safe_role_label(unit.get("role", "worker")).capitalize()
				var state := str(unit.get("animation_state", unit.get("state", "idle")))
				var summary := _safe_agent_task_summary(unit, state) if bool(unit.get("alive", true)) else "Unit down"
				entries_by_slot[slot] = "Agent %d • %s — %s" % [slot + 1, role, summary]
		var entries: Array[String] = []
		for slot: int in 3:
			entries.append(str(entries_by_slot.get(slot, "Agent %d • awaiting spawn" % [slot + 1])))
		board.text = "[color=#%s]%s AGENTS • PUBLIC TASKS[/color]\n%s" % [_team_hex(participant_id), TEAM_NAMES[participant_id], "\n".join(entries)]


func _team_hex(participant_id: String) -> String:
	return "34d399" if participant_id == "participant_0" else "a78bfa"


func _living_units(source: Dictionary) -> int:
	var own: Dictionary = source.get("own", {})
	var units: Variant = source.get("units", own.get("units", {}))
	if units is Array:
		var living := 0
		for raw: Variant in units:
			if raw is Dictionary and bool((raw as Dictionary).get("alive", true)):
				living += 1
		return living
	return int((units as Dictionary).get("count", 0)) if units is Dictionary else 0


func _materials(own: Dictionary) -> Vector2i:
	var resources: Dictionary = own.get("resources", own)
	return Vector2i(maxi(0, int(resources.get("wood", 0))), maxi(0, int(resources.get("ore", 0))))


func _structure_health(own: Dictionary, key: String) -> int:
	var structure: Variant = own.get(key, {})
	return clampi(int((structure as Dictionary).get("health_percent", 100)), 0, 100) if structure is Dictionary else 0


func _unit_roles(source: Dictionary) -> String:
	var own: Dictionary = source.get("own", {})
	var units: Variant = source.get("units", own.get("units", {}))
	if not units is Array:
		return "squad" if _living_units(source) > 0 else "none"
	var workers := 0
	var militia := 0
	for raw: Variant in units:
		if not raw is Dictionary or not bool((raw as Dictionary).get("alive", true)):
			continue
		if str((raw as Dictionary).get("role", "worker")).to_lower() == "militia":
			militia += 1
		else:
			workers += 1
	var roles := []
	if workers > 0: roles.append("%d worker%s" % [workers, "s" if workers != 1 else ""])
	if militia > 0: roles.append("%d militia" % militia)
	return ", ".join(roles) if not roles.is_empty() else "none"


func _phase_for_tick(tick: int) -> String:
	if tick < 520: return "Economy"
	if tick < 650: return "Arming"
	if tick < 800: return "March"
	if tick < 920: return "Bridge battle"
	if tick < 1030: return "Pursuit"
	if tick < 1120: return "Tower siege"
	return "Town Hall assault" if tick < 1190 else "Victory"


func _objective_for_tick(tick: int) -> String:
	if tick < 520: return "Harvest, return supplies, and grow each workforce."
	if tick < 650: return "Complete structures and arm the workers as militia."
	if tick < 800: return "Rally both squads at the bridge."
	if tick < 920: return "Break the enemy line at the bridge."
	if tick < 1030: return "Pursue the final Luna fighter."
	if tick < 1120: return "Destroy Luna's defensive tower."
	return "Destroy the Luna Town Hall." if tick < 1190 else "Terra holds the battlefield."


func _safe_recent_event(sources: Array) -> String:
	for source: Variant in sources:
		if not source is Dictionary:
			continue
		var events: Variant = (source as Dictionary).get("recent_events", [])
		if not events is Array or events.is_empty():
			continue
		var latest: Variant = events[events.size() - 1]
		if latest is Dictionary:
			var event: Dictionary = latest
			var event_type := str(event.get("type", event.get("kind", ""))).to_lower()
			if SAFE_EVENT_LABELS.has(event_type):
				return SAFE_EVENT_LABELS[event_type]
	return "Awaiting the next public battlefield event."


func _safe_public_text(value: String, limit: int) -> String:
	var compact := value.replace("\n", " ").replace("\r", " ").strip_edges()
	return compact.substr(0, mini(compact.length(), limit)) if not compact.is_empty() else "—"


func _smooth_node(node: Node3D, delta: float) -> void:
	var target: Variant = node.get_meta("presentation_target_position") if node.has_meta("presentation_target_position") else null
	var yaw: Variant = node.get_meta("presentation_target_yaw") if node.has_meta("presentation_target_yaw") else null
	if target is Vector3:
		node.position = node.position.lerp(target, minf(1.0, delta * 7.0))
	if typeof(yaw) == TYPE_FLOAT:
		node.rotation.y = lerp_angle(node.rotation.y, float(yaw), minf(1.0, delta * 10.0))


func _world_position(value: Variant) -> Variant:
	if not value is Dictionary or typeof(value.get("x")) != TYPE_INT or typeof(value.get("y")) != TYPE_INT:
		return null
	return Vector3(float(value.x) / 1000.0, 0.0, float(value.y) / 1000.0)


func _animation(state: String) -> String:
	return {
		"turn": "idle", "turning": "idle", "dash": "run", "walking": "walk", "returning": "walk",
		"rallying": "walk", "retreating": "run", "deposit": "gather", "depositing": "gather",
		"harvesting": "gather", "gathering": "gather", "train": "build", "building": "build",
		"arming": "build", "attacking": "attack", "defeated": "defeat",
	}.get(state, state) if state in ["idle", "walk", "run", "attack", "guard", "gather", "build", "hit", "celebrate", "defeat", "turn", "turning", "dash", "walking", "returning", "rallying", "retreating", "deposit", "depositing", "harvesting", "gathering", "train", "building", "arming", "attacking", "defeated"] else "idle"


func _intent_for_state(state: String) -> String:
	return {"walk": "Moving to objective", "walking": "Moving to objective", "run": "Rushing to objective", "retreating": "Retreating to base", "gather": "Harvesting", "harvesting": "Harvesting", "build": "Raising barracks", "arming": "Arming militia", "attack": "Attacking", "attacking": "Attacking", "guard": "Holding the line", "hit": "Under attack", "defeat": "Unit defeated", "defeated": "Unit defeated", "celebrate": "Victory"}.get(state, "Assessing the field")


func _safe_agent_task_summary(source: Dictionary, state: String) -> String:
	# This is intentionally an enum-to-copy projection.  It ignores free-form provider-facing
	# fields such as intent_label, memory_update, prompt, output, and target coordinates.
	# It is safe for a public broadcast and remains deterministic for a given public snapshot.
	var task := str(source.get("task", "")).to_lower()
	match task:
		"gather", "harvesting", "gathering": return "Harvesting resources"
		"return_material", "returning": return "Returning materials"
		"deposit", "depositing": return "Depositing materials"
		"build", "building": return "Constructing base"
		"arm", "arming": return "Arming as militia"
		"rally", "rallying": return "Rallying at bridge"
		"attack_unit", "attack_structure", "attacking": return "Attacking target"
		"retreat", "retreating": return "Retreating to base"
		"hold", "guard": return "Holding position"
		"turn", "turning": return "Facing objective"
		"hit": return "Under attack"
		"defeat", "defeated": return "Unit defeated"
		"celebrate", "celebrating": return "Celebrating victory"
		"walking", "walk": return "Moving to task"
	return _intent_for_state(state)


func _safe_role_label(value: Variant) -> String:
	var role := str(value).to_lower()
	return "MILITIA" if role == "militia" else "WORKER" if role == "worker" else "AGENT"


func _tint(node: Node, colour: Color) -> void:
	if node is MeshInstance3D:
		var material := StandardMaterial3D.new()
		material.albedo_color = colour
		material.roughness = 0.72
		node.material_override = material
	for child: Node in node.get_children():
		_tint(child, colour)


func _apply_texture(node: MeshInstance3D, texture: Texture2D, uv_scale: Vector3, tint: Color = Color.WHITE) -> void:
	var material := node.material_override as StandardMaterial3D
	if material == null:
		return
	material.albedo_texture = texture
	material.albedo_color = tint
	material.uv1_scale = uv_scale
	material.roughness = 0.92


func _mesh(node_name: String, mesh: PrimitiveMesh, colour: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.86
	node.material_override = material
	return node
