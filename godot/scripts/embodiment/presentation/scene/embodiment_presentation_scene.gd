class_name EmbodimentPresentationScene
extends Node3D

## Compact procedural presentation for one participant-scoped embodiment projection.
##
## `apply_snapshot` is the sole world-update boundary. It deep-copies a validated, JSON-compatible
## dictionary before touching nodes and never writes through to its caller. Missing entities are
## removed: presentation therefore cannot invent or retain an object that the projection omitted.

const MILLITILES_PER_WORLD_UNIT := 1000.0
const ARENA_HALF_EXTENT_WORLD := 10.0
const REQUIRED_ROOT_FIELDS := [
	"episode_id", "observation_seq", "participant_id", "task_id", "tick", "operator", "entities",
	"agency",
]
const REQUIRED_OPERATOR_FIELDS := ["position_mt", "heading_milli", "state"]
const REQUIRED_ENTITY_FIELDS := ["id", "kind", "position_mt", "heading_milli", "state"]
const REQUIRED_AGENCY_FIELDS := ["controller", "receipt", "intent_label"]
const REQUIRED_CONTROLLER_FIELDS := [
	"move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons",
]
const REQUIRED_BUTTON_FIELDS := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
]
const REQUIRED_RECEIPT_FIELDS := [
	"disposition", "accepted", "fallback", "applied_ticks", "codes",
]
const ENTITY_KINDS := [
	"resource", "relay", "build_pad", "barricade", "neutral", "beacon", "operator",
]
const QUATERNIUS_LANDMARK := (
	"res://assets/external/quaternius_medieval_village/buildings_fbx/Stable.fbx"
)
const KENNEY_PANEL := (
	"res://assets/external/kenney_ui_pack_adventure/Vector/panel_grey_blue.svg"
)
const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")

var _built := false
var _snapshot: Dictionary = {}
var _projections: Dictionary = {}
var _operator: Node3D
var _camera_rig: Node3D
var _participant_camera: Camera3D
var _hud_observation: Label
var _hud_action: Label
var _hud_controller: Label
var _hud_receipt: Label
var _hud_intent: Label
var _event_audio: AudioStreamPlayer3D
var _last_error := ""


func _ready() -> void:
	_ensure_built()


## Accepted immutable projection shape:
## {
##   episode_id: String, observation_seq: int, participant_id: String, task_id: String, tick: int,
##   operator: {position_mt: [int, int], heading_milli: int (0..7999), state: String},
##   entities: [{id: String, kind: String, position_mt: [int, int],
##              heading_milli: int (0..7999), state: String}, ...],
##   agency: {controller: Dictionary, receipt: Dictionary|null, intent_label: String}
## }
func apply_snapshot(snapshot: Dictionary) -> bool:
	_ensure_built()
	var error := _validate_snapshot(snapshot)
	if not error.is_empty():
		_last_error = error
		return false
	var accepted := snapshot.duplicate(true)
	_snapshot = accepted
	_apply_operator(accepted["operator"], str(accepted["participant_id"]))
	_apply_entities(accepted["entities"])
	_apply_agency(accepted["agency"])
	_last_error = ""
	return true


func participant_camera(participant_id: String) -> Camera3D:
	if _participant_camera == null or participant_id != str(_participant_camera.get_meta(
		"participant_id", ""
	)):
		return null
	return _participant_camera


func projection_node(entity_id: String) -> Node3D:
	return _projections.get(entity_id) as Node3D


func snapshot_copy() -> Dictionary:
	return _snapshot.duplicate(true)


func last_error() -> String:
	return _last_error


func debug_state() -> Dictionary:
	var ids: Array = _projections.keys()
	ids.sort()
	return {
		"episode_id": str(_snapshot.get("episode_id", "")),
		"observation_seq": int(_snapshot.get("observation_seq", -1)),
		"participant_id": str(_snapshot.get("participant_id", "")),
		"task_id": str(_snapshot.get("task_id", "")),
		"tick": int(_snapshot.get("tick", -1)),
		"agency": _snapshot.get("agency", {}).duplicate(true),
		"entity_ids": ids,
		"camera_current": _participant_camera != null and _participant_camera.current,
	}


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	name = "EmbodimentPresentationScene"
	_build_arena()
	_build_operator()
	_build_hud()
	_build_event_audio()


func _build_arena() -> void:
	var arena := Node3D.new()
	arena.name = "ArenaStatic"
	add_child(arena)

	var floor := _box("Floor", Vector3(20.0, 0.2, 20.0), Color("27323b"))
	floor.position.y = -0.1
	arena.add_child(floor)
	var inset := ARENA_HALF_EXTENT_WORLD + 0.15
	var north := _box("BoundaryNorth", Vector3(20.6, 0.65, 0.3), Color("78909c"))
	north.position = Vector3(0.0, 0.325, -inset)
	arena.add_child(north)
	var south := _box("BoundarySouth", Vector3(20.6, 0.65, 0.3), Color("78909c"))
	south.position = Vector3(0.0, 0.325, inset)
	arena.add_child(south)
	var west := _box("BoundaryWest", Vector3(0.3, 0.65, 20.0), Color("78909c"))
	west.position = Vector3(-inset, 0.325, 0.0)
	arena.add_child(west)
	var east := _box("BoundaryEast", Vector3(0.3, 0.65, 20.0), Color("78909c"))
	east.position = Vector3(inset, 0.325, 0.0)
	arena.add_child(east)

	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-55.0, -28.0, 0.0)
	light.light_color = Color("fff3d6")
	light.light_energy = 1.25
	light.shadow_enabled = true
	arena.add_child(light)

	var fill := OmniLight3D.new()
	fill.name = "ParticipantFill"
	fill.position = Vector3(0.0, 6.0, 2.0)
	fill.omni_range = 18.0
	fill.light_energy = 2.0
	fill.light_color = Color("b8dcff")
	arena.add_child(fill)

	var projections := Node3D.new()
	projections.name = "EntityProjections"
	add_child(projections)
	_add_reviewed_landmark(arena)


func _add_reviewed_landmark(arena: Node3D) -> void:
	var resource := load(QUATERNIUS_LANDMARK) as PackedScene
	if resource == null:
		return
	var landmark := resource.instantiate() as Node3D
	if landmark == null:
		return
	landmark.name = "QuaterniusStableLandmark"
	landmark.position = Vector3(-8.5, 0.0, -8.2)
	landmark.rotation_degrees.y = 35.0
	landmark.scale = Vector3.ONE * 0.7
	landmark.set_meta("asset_source", "quaternius_medieval_village_reviewed_subset")
	arena.add_child(landmark)


func _build_operator() -> void:
	_operator = YBot.instantiate() as Node3D
	assert(_operator != null, "reviewed Y Bot presentation scene must load")
	_operator.name = "OperatorProjection"
	add_child(_operator)
	_operator.set_meta("presentation_placeholder", false)
	_operator.set_meta("asset_identity", "mixamo-y-bot")
	_operator.add_child(_label("OperatorLabel", "OPERATOR", Color("dbe7ff"), Vector3(0, 2.8, 0)))

	_camera_rig = Node3D.new()
	_camera_rig.name = "ParticipantCameraRig"
	_operator.add_child(_camera_rig)
	_participant_camera = Camera3D.new()
	_participant_camera.name = "ParticipantCamera"
	_participant_camera.position = Vector3(0.0, 3.25, 5.4)
	_participant_camera.rotation_degrees.x = -17.0
	_participant_camera.fov = 62.0
	_participant_camera.near = 0.1
	_participant_camera.far = 60.0
	_participant_camera.current = true
	_camera_rig.add_child(_participant_camera)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ParticipantHUD"
	add_child(layer)
	var panel := NinePatchRect.new()
	panel.name = "Panel"
	panel.position = Vector2(24.0, 24.0)
	panel.size = Vector2(620.0, 220.0)
	panel.texture = load(KENNEY_PANEL) as Texture2D
	panel.patch_margin_left = 24
	panel.patch_margin_top = 24
	panel.patch_margin_right = 24
	panel.patch_margin_bottom = 24
	panel.set_meta("asset_source", "kenney_ui_pack_adventure_reviewed_subset")
	layer.add_child(panel)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.position = Vector2(24.0, 18.0)
	content.size = Vector2(572.0, 184.0)
	panel.add_child(content)
	_hud_observation = Label.new()
	_hud_observation.name = "Observation"
	_hud_observation.text = "OBSERVATION —"
	_hud_observation.add_theme_color_override("font_color", Color("e9f4ff"))
	_hud_observation.add_theme_font_size_override("font_size", 20)
	content.add_child(_hud_observation)
	_hud_action = Label.new()
	_hud_action.name = "OperatorState"
	_hud_action.text = "OPERATOR IDLE"
	_hud_action.add_theme_color_override("font_color", Color("9be7ff"))
	_hud_action.add_theme_font_size_override("font_size", 18)
	content.add_child(_hud_action)
	_hud_controller = Label.new()
	_hud_controller.name = "ControllerState"
	_hud_controller.text = "CONTROLLER —"
	_hud_controller.add_theme_color_override("font_color", Color("dbe7ff"))
	_hud_controller.add_theme_font_size_override("font_size", 15)
	content.add_child(_hud_controller)
	_hud_receipt = Label.new()
	_hud_receipt.name = "Receipt"
	_hud_receipt.text = "RECEIPT —"
	_hud_receipt.add_theme_color_override("font_color", Color("a7f3d0"))
	_hud_receipt.add_theme_font_size_override("font_size", 15)
	content.add_child(_hud_receipt)
	_hud_intent = Label.new()
	_hud_intent.name = "NonAuthoritativeIntent"
	_hud_intent.text = "INTENT (NON-AUTHORITATIVE) —"
	_hud_intent.add_theme_color_override("font_color", Color("fcd34d"))
	_hud_intent.add_theme_font_size_override("font_size", 15)
	_hud_intent.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	content.add_child(_hud_intent)


func _build_event_audio() -> void:
	_event_audio = AudioStreamPlayer3D.new()
	_event_audio.name = "EventAudio"
	var cue := AudioStreamWAV.new()
	cue.format = AudioStreamWAV.FORMAT_8_BITS
	cue.mix_rate = 8000
	cue.stereo = false
	var samples := PackedByteArray()
	for index: int in 80:
		samples.append(128 + (28 if index % 8 < 4 else -28))
	cue.data = samples
	_event_audio.stream = cue
	add_child(_event_audio)


func _apply_operator(operator_state: Dictionary, participant_id: String) -> void:
	_operator.position = _world_position(operator_state["position_mt"], 0.0)
	# Authority headings use +X for east and +Z for south. Godot's positive yaw rotates a
	# -Z-facing model toward west, so presentation must invert the authority angle. Keeping
	# this conversion here preserves deterministic controls while making the Y Bot and its
	# third-person camera face the direction of travel.
	_operator.rotation.y = -float(int(operator_state["heading_milli"])) * PI / 4000.0
	var state := str(operator_state["state"])
	_operator.set_meta("state", state)
	_operator.set_meta("participant_id", participant_id)
	_participant_camera.set_meta("participant_id", participant_id)
	_participant_camera.current = true
	_apply_operator_visual_state(state)
	_hud_observation.text = "OBSERVATION %d  •  TICK %d" % [
		int(_snapshot.get("observation_seq", 0)), int(_snapshot.get("tick", 0)),
	]
	_hud_action.text = "OPERATOR %s" % state.to_upper().replace("_", " ")


func _apply_agency(agency: Dictionary) -> void:
	var controller: Dictionary = agency["controller"]
	var pressed := PackedStringArray()
	for button: String in REQUIRED_BUTTON_FIELDS:
		if bool(controller["buttons"][button]):
			pressed.append(button)
	var button_text := ",".join(pressed) if not pressed.is_empty() else "none"
	_hud_controller.text = "CONTROLLER %dt  MOVE %d/%d  LOOK %d/%d  BUTTONS %s" % [
		int(controller["duration_ticks"]), int(controller["move_x"]), int(controller["move_y"]),
		int(controller["look_x"]), int(controller["look_y"]), button_text,
	]
	var receipt: Variant = agency["receipt"]
	if receipt == null:
		_hud_receipt.text = "RECEIPT —"
	else:
		var codes: Array = receipt["codes"]
		_hud_receipt.text = "RECEIPT %s  •  %dt  •  CODES %s" % [
			str(receipt["disposition"]).to_upper(), int(receipt["applied_ticks"]),
			", ".join(PackedStringArray(codes)) if not codes.is_empty() else "none",
		]
	var intent_label := str(agency["intent_label"])
	_hud_intent.text = "INTENT (NON-AUTHORITATIVE) %s" % (
		intent_label if not intent_label.is_empty() else "—"
	)


func _apply_operator_visual_state(state: String) -> void:
	var previous_state := str(_operator.get_meta("visual_state", ""))
	_operator.set_meta("visual_state", state)
	var label := _operator.get_node("OperatorLabel") as Label3D
	label.text = "OPERATOR\n%s" % state.to_upper().replace("_", " ")
	_operator.call("play_state", StringName(state))
	if not previous_state.is_empty() and previous_state != state and state != "idle":
		_event_audio.set_meta("last_cue", state)
		_event_audio.play()


func _apply_entities(entities: Array) -> void:
	var seen := {}
	for entity_value: Variant in entities:
		var entity: Dictionary = entity_value
		var entity_id := str(entity["id"])
		seen[entity_id] = true
		var projection: Node3D = _projections.get(entity_id) as Node3D
		if projection == null:
			projection = _create_entity(entity_id, str(entity["kind"]))
			get_node("EntityProjections").add_child(projection)
			_projections[entity_id] = projection
		_update_entity(projection, entity)
	var stale: Array = []
	for entity_id: String in _projections:
		if not seen.has(entity_id):
			stale.append(entity_id)
	for entity_id: String in stale:
		var projection: Node3D = _projections[entity_id]
		_projections.erase(entity_id)
		projection.get_parent().remove_child(projection)
		projection.queue_free()


func _create_entity(entity_id: String, kind: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Projection_%s" % _safe_node_name(entity_id)
	root.set_meta("entity_id", entity_id)
	root.set_meta("kind", kind)
	match kind:
		"resource":
			var stem := _cylinder("ResourceStem", 0.42, 0.68, Color("ff9f43"), 6)
			stem.position.y = 0.34
			root.add_child(stem)
			var crown := _sphere("ResourceCrown", 0.48, Color("ffd166"))
			crown.position.y = 0.95
			crown.scale = Vector3(0.72, 1.35, 0.72)
			root.add_child(crown)
		"relay":
			var base := _cylinder("RelayBase", 0.85, 0.22, Color("155e75"), 24)
			base.position.y = 0.11
			root.add_child(base)
			var core := _cylinder("RelayCore", 0.35, 1.65, Color("22d3ee"), 16)
			core.position.y = 1.03
			root.add_child(core)
		"build_pad":
			var pad := _cylinder("BuildPad", 1.0, 0.12, Color("fbbf24"), 24)
			pad.position.y = 0.06
			root.add_child(pad)
			var marker_x := _box("PadMarkX", Vector3(1.5, 0.035, 0.16), Color("fff4b8"))
			marker_x.position.y = 0.14
			root.add_child(marker_x)
			var marker_z := _box("PadMarkZ", Vector3(0.16, 0.035, 1.5), Color("fff4b8"))
			marker_z.position.y = 0.14
			root.add_child(marker_z)
			var progress_ring := MeshInstance3D.new()
			progress_ring.name = "ProgressRing"
			var ring_mesh := TorusMesh.new()
			ring_mesh.inner_radius = 1.02
			ring_mesh.outer_radius = 1.13
			progress_ring.mesh = ring_mesh
			progress_ring.position.y = 0.18
			progress_ring.material_override = _material(Color("86efac"))
			progress_ring.visible = false
			root.add_child(progress_ring)
			var decal := Decal.new()
			decal.name = "InteractionDecal"
			decal.size = Vector3(2.4, 0.5, 2.4)
			decal.position.y = 0.2
			decal.texture_albedo = _interaction_decal_texture()
			root.add_child(decal)
			var particles := GPUParticles3D.new()
			particles.name = "ConstructionParticles"
			particles.amount = 10
			particles.lifetime = 0.7
			particles.emitting = false
			var particle_mesh := QuadMesh.new()
			particle_mesh.size = Vector2(0.08, 0.08)
			particles.draw_pass_1 = particle_mesh
			root.add_child(particles)
		"barricade":
			var left := _box("BarricadeLeft", Vector3(0.28, 1.15, 0.32), Color("8b5e3c"))
			left.position = Vector3(-0.85, 0.58, 0.0)
			root.add_child(left)
			var right := _box("BarricadeRight", Vector3(0.28, 1.15, 0.32), Color("8b5e3c"))
			right.position = Vector3(0.85, 0.58, 0.0)
			root.add_child(right)
			for index: int in 3:
				var rail := _box(
					"BarricadeRail%d" % index, Vector3(2.05, 0.24, 0.3), Color("c58b54")
				)
				rail.position = Vector3(0.0, 0.35 + float(index) * 0.36, 0.0)
				root.add_child(rail)
		"neutral":
			var body := _capsule("NeutralBody", 0.46, 1.45, Color("dc3545"))
			body.position.y = 0.9
			root.add_child(body)
			var visor := _box("NeutralVisor", Vector3(0.58, 0.18, 0.18), Color("ffd6dc"))
			visor.position = Vector3(0.0, 1.35, -0.42)
			root.add_child(visor)
		"beacon":
			var beacon := _cylinder("Beacon", 0.55, 1.7, Color("a78bfa"), 16)
			beacon.position.y = 0.85
			root.add_child(beacon)
	var label := _label("StateLabel", kind.to_upper(), _kind_color(kind), Vector3(0, 2.25, 0))
	root.add_child(label)
	return root


func _update_entity(projection: Node3D, entity: Dictionary) -> void:
	var kind := str(entity["kind"])
	projection.position = _world_position(entity["position_mt"], 0.0)
	projection.rotation.y = float(int(entity["heading_milli"])) * PI / 4000.0
	projection.set_meta("state", str(entity["state"]))
	projection.set_meta("kind", kind)
	var label := projection.get_node("StateLabel") as Label3D
	label.text = "%s\n%s" % [kind.to_upper().replace("_", " "), str(entity["state"])]
	if kind == "barricade":
		var completion := _state_fraction(str(entity["state"]), 0.0)
		projection.scale.y = 0.22 + completion * 0.78
		projection.visible = completion > 0.0
	elif kind == "build_pad":
		var pad_fraction := _state_fraction(str(entity["state"]), 0.0)
		var pad := projection.get_node("BuildPad") as MeshInstance3D
		pad.material_override = _material(
			Color("42d392") if str(entity["state"]) == "complete" else Color("fbbf24").lerp(
				Color("86efac"), pad_fraction
			)
		)
		var ring := projection.get_node("ProgressRing") as MeshInstance3D
		ring.visible = pad_fraction > 0.0
		ring.scale = Vector3.ONE * maxf(pad_fraction, 0.05)
		var particles := projection.get_node("ConstructionParticles") as GPUParticles3D
		particles.emitting = str(entity["state"]).begins_with("building_")
	elif kind == "resource":
		var depleted := str(entity["state"]) == "depleted"
		projection.scale = Vector3.ONE * (0.72 if depleted else 1.0)
	elif kind == "neutral":
		projection.visible = not str(entity["state"]).begins_with("defeated")


func _validate_snapshot(snapshot: Dictionary) -> String:
	if not _has_exact_fields(snapshot, REQUIRED_ROOT_FIELDS):
		return "snapshot_fields_invalid"
	for field: String in REQUIRED_ROOT_FIELDS:
		if not snapshot.has(field):
			return "snapshot_missing_%s" % field
	if typeof(snapshot["episode_id"]) != TYPE_STRING or str(snapshot["episode_id"]).is_empty():
		return "snapshot_episode_id_invalid"
	if typeof(snapshot["observation_seq"]) != TYPE_INT or int(snapshot["observation_seq"]) < 0:
		return "snapshot_observation_seq_invalid"
	if typeof(snapshot["participant_id"]) != TYPE_STRING or str(snapshot["participant_id"]).is_empty():
		return "snapshot_participant_id_invalid"
	if typeof(snapshot["task_id"]) != TYPE_STRING or str(snapshot["task_id"]).is_empty():
		return "snapshot_task_id_invalid"
	if typeof(snapshot["tick"]) != TYPE_INT or int(snapshot["tick"]) < 0:
		return "snapshot_tick_invalid"
	if not snapshot["operator"] is Dictionary:
		return "snapshot_operator_invalid"
	var operator: Dictionary = snapshot["operator"]
	if not _has_exact_fields(operator, REQUIRED_OPERATOR_FIELDS):
		return "snapshot_operator_fields_invalid"
	for field: String in REQUIRED_OPERATOR_FIELDS:
		if not operator.has(field):
			return "snapshot_operator_missing_%s" % field
	if not _valid_position(operator["position_mt"]):
		return "snapshot_operator_position_invalid"
	if typeof(operator["heading_milli"]) != TYPE_INT or int(operator["heading_milli"]) < 0 \
		or int(operator["heading_milli"]) > 7999:
		return "snapshot_operator_heading_invalid"
	if typeof(operator["state"]) != TYPE_STRING:
		return "snapshot_operator_state_invalid"
	if not snapshot["entities"] is Array:
		return "snapshot_entities_invalid"
	var ids := {}
	for entity_value: Variant in snapshot["entities"]:
		if not entity_value is Dictionary:
			return "snapshot_entity_invalid"
		var entity: Dictionary = entity_value
		if not _has_exact_fields(entity, REQUIRED_ENTITY_FIELDS):
			return "snapshot_entity_fields_invalid"
		for field: String in REQUIRED_ENTITY_FIELDS:
			if not entity.has(field):
				return "snapshot_entity_missing_%s" % field
		if typeof(entity["id"]) != TYPE_STRING or str(entity["id"]).is_empty():
			return "snapshot_entity_id_invalid"
		if ids.has(str(entity["id"])):
			return "snapshot_entity_id_duplicate"
		ids[str(entity["id"])] = true
		if typeof(entity["kind"]) != TYPE_STRING or str(entity["kind"]) not in ENTITY_KINDS:
			return "snapshot_entity_kind_invalid"
		if not _valid_position(entity["position_mt"]):
			return "snapshot_entity_position_invalid"
		if typeof(entity["heading_milli"]) != TYPE_INT or int(entity["heading_milli"]) < 0 \
			or int(entity["heading_milli"]) > 7999:
			return "snapshot_entity_heading_invalid"
		if typeof(entity["state"]) != TYPE_STRING:
			return "snapshot_entity_state_invalid"
	var agency_error := _validate_agency(snapshot["agency"])
	if not agency_error.is_empty():
		return agency_error
	return ""


func _validate_agency(value: Variant) -> String:
	if not value is Dictionary:
		return "snapshot_agency_invalid"
	var agency: Dictionary = value
	if not _has_exact_fields(agency, REQUIRED_AGENCY_FIELDS):
		return "snapshot_agency_fields_invalid"
	if not agency["controller"] is Dictionary:
		return "snapshot_agency_controller_invalid"
	var controller: Dictionary = agency["controller"]
	if not _has_exact_fields(controller, REQUIRED_CONTROLLER_FIELDS):
		return "snapshot_agency_controller_fields_invalid"
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if typeof(controller[axis]) != TYPE_INT or int(controller[axis]) < -1000 \
			or int(controller[axis]) > 1000:
			return "snapshot_agency_controller_axis_invalid"
	if typeof(controller["duration_ticks"]) != TYPE_INT \
		or int(controller["duration_ticks"]) < 0 or int(controller["duration_ticks"]) > 20:
		return "snapshot_agency_controller_duration_invalid"
	if not controller["buttons"] is Dictionary:
		return "snapshot_agency_buttons_invalid"
	var buttons: Dictionary = controller["buttons"]
	if not _has_exact_fields(buttons, REQUIRED_BUTTON_FIELDS):
		return "snapshot_agency_button_fields_invalid"
	for button: String in REQUIRED_BUTTON_FIELDS:
		if typeof(buttons[button]) != TYPE_BOOL:
			return "snapshot_agency_button_invalid"
	if typeof(agency["intent_label"]) != TYPE_STRING \
		or agency["intent_label"].to_utf8_buffer().size() > 160:
		return "snapshot_agency_intent_invalid"
	if agency["receipt"] == null:
		return ""
	if not agency["receipt"] is Dictionary:
		return "snapshot_agency_receipt_invalid"
	var receipt: Dictionary = agency["receipt"]
	if not _has_exact_fields(receipt, REQUIRED_RECEIPT_FIELDS):
		return "snapshot_agency_receipt_fields_invalid"
	if receipt["disposition"] not in ["accepted", "no_input"] \
		or typeof(receipt["accepted"]) != TYPE_BOOL \
		or receipt["fallback"] not in ["none", "neutral"]:
		return "snapshot_agency_receipt_disposition_invalid"
	if receipt["disposition"] == "accepted" \
		and (receipt["accepted"] != true or receipt["fallback"] != "none"):
		return "snapshot_agency_receipt_consistency_invalid"
	if receipt["disposition"] == "no_input" \
		and (receipt["accepted"] != false or receipt["fallback"] != "neutral"):
		return "snapshot_agency_receipt_consistency_invalid"
	if typeof(receipt["applied_ticks"]) != TYPE_INT or int(receipt["applied_ticks"]) < 0 \
		or int(receipt["applied_ticks"]) > 20:
		return "snapshot_agency_receipt_ticks_invalid"
	if not receipt["codes"] is Array:
		return "snapshot_agency_receipt_codes_invalid"
	for code: Variant in receipt["codes"]:
		if typeof(code) != TYPE_STRING or code.is_empty() or code.to_utf8_buffer().size() > 80:
			return "snapshot_agency_receipt_code_invalid"
	return ""


func _has_exact_fields(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for field: String in expected:
		if not value.has(field):
			return false
	return true


func _valid_position(value: Variant) -> bool:
	return value is Array and value.size() == 2 and typeof(value[0]) == TYPE_INT \
		and typeof(value[1]) == TYPE_INT


func _world_position(position_mt: Array, height: float) -> Vector3:
	return Vector3(
		float(int(position_mt[0])) / MILLITILES_PER_WORLD_UNIT,
		height,
		float(int(position_mt[1])) / MILLITILES_PER_WORLD_UNIT,
	)


func _state_fraction(state: String, default_value: float) -> float:
	if state == "complete":
		return 1.0
	match state:
		"building_started", "gathering_started", "activating_started", "holding_started":
			return 0.25
		"building_mid", "gathering_mid", "activating_mid", "holding_mid":
			return 0.55
		"building_near_complete", "gathering_near_complete", \
			"activating_near_complete", "holding_near_complete":
			return 0.82
	var parts := state.split("_")
	var of_index := parts.find("of")
	if of_index < 1 or of_index + 1 >= parts.size():
		return default_value
	if not parts[of_index - 1].is_valid_int() or not parts[of_index + 1].is_valid_int():
		return default_value
	var required := int(parts[of_index + 1])
	if required <= 0:
		return default_value
	return clampf(float(int(parts[of_index - 1])) / float(required), 0.0, 1.0)


func _interaction_decal_texture() -> Texture2D:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y: int in 64:
		for x: int in 64:
			var distance_squared := (x - 32) * (x - 32) + (y - 32) * (y - 32)
			if distance_squared >= 700 and distance_squared <= 980:
				image.set_pixel(x, y, Color(0.35, 0.95, 0.72, 0.7))
	return ImageTexture.create_from_image(image)


func _safe_node_name(value: String) -> String:
	return value.replace("/", "_").replace(":", "_").replace("@", "_")


func _kind_color(kind: String) -> Color:
	match kind:
		"resource": return Color("ffd166")
		"relay": return Color("67e8f9")
		"build_pad": return Color("fde68a")
		"barricade": return Color("f0b77d")
		"neutral": return Color("ff9aa6")
	return Color("c4b5fd")


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.72
	return material


func _box(node_name: String, size: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _cylinder(
	node_name: String, radius: float, height: float, color: Color, radial_segments: int
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = radial_segments
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _capsule(node_name: String, radius: float, height: float, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _sphere(node_name: String, radius: float, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _label(
	node_name: String, text: String, color: Color, position: Vector3
) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.position = position
	label.modulate = color
	label.outline_modulate = Color("111827")
	label.outline_size = 8
	label.font_size = 30
	label.pixel_size = 0.004
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	return label
