class_name EmbodimentTrioMazeBroadcastScene
extends Node3D

const YBot := preload("res://scenes/embodiment/y_bot_operator.tscn")
const EntrantPalette := preload("res://scripts/embodiment/presentation/entrant_palette.gd")
const MazeMap := preload("res://scripts/embodiment/trio_games/trio_maze_map.gd")
const PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]
const LANE_OFFSETS := {"participant_0": -18.0, "participant_1": 0.0, "participant_2": 18.0}
const LANE_TONES := {
	"participant_0": Color("8b6a18"),
	"participant_1": Color("684b8f"),
	"participant_2": Color("23775b"),
}

var _world: Node3D
var _camera: Camera3D
var _racers := {}
var _replay := {}
var _tick_milli := -1000
var _hud: RichTextLabel
var _beat: Label
var _event_feed: Label
var _title_card: Control
var _winner_card: Control


func _ready() -> void:
	_build()


func configure_replay(replay: Dictionary) -> bool:
	_build()
	if replay.get("task_id") != MazeMap.TASK_ID or replay.get("protocol_version") != MazeMap.PROTOCOL_VERSION \
			or not replay.get("racers") is Array or replay.racers.size() != 3:
		return false
	var seen := {}
	for value: Variant in replay.racers:
		if not value is Dictionary or value.get("participant_id") not in PARTICIPANTS \
				or not value.get("keyframes") is Array or value.keyframes.is_empty():
			return false
		seen[value.participant_id] = value
	if seen.size() != 3:
		return false
	_replay = replay.duplicate(true)
	return apply_race_time(-1000)


func apply_race_time(tick_milli: int) -> bool:
	if _replay.is_empty() or tick_milli < -1000 or tick_milli > 600000:
		return false
	_tick_milli = tick_milli
	var authority_tick := clampi(tick_milli / 1000, 0, 600)
	for value: Variant in _replay.racers:
		var racer: Dictionary = value
		var participant_id := str(racer.participant_id)
		var pose := _pose_at(racer.keyframes, maxi(0, tick_milli))
		if pose.is_empty():
			return false
		var actor: Node3D = _racers[participant_id]
		actor.position = _world_position(participant_id, pose.position)
		actor.rotation.y = -float(pose.heading) * PI / 2.0
		if actor.has_method("play_state"):
			actor.call("play_state", StringName(pose.animation))
		var label := actor.get_node("RacerLabel") as Label3D
		label.text = "%s\n%s" % [str(racer.display_name).to_upper(), str(pose.task).to_upper().replace("_", " ")]
		var bubble := actor.get_node("Speech") as Label3D
		bubble.text = _safe_event_label(participant_id, authority_tick)
	_update_hud(authority_tick)
	_apply_camera_beat(authority_tick)
	_title_card.visible = tick_milli < 0
	_winner_card.visible = authority_tick >= int(_replay.result.completion_tick)
	return true


func snapshot_copy() -> Dictionary:
	return {"task_id": MazeMap.TASK_ID, "tick_milli": _tick_milli, "configured": not _replay.is_empty()}


func _build() -> void:
	if _world != null:
		return
	_world = Node3D.new()
	_world.name = "LabyrinthRunWorld"
	add_child(_world)
	_build_environment()
	for participant_id: String in PARTICIPANTS:
		_build_lane(participant_id)
		_build_racer(participant_id)
	_camera = Camera3D.new()
	_camera.name = "LabyrinthBroadcastCamera"
	_camera.current = true
	_camera.fov = 58.0
	_camera.near = 0.1
	_camera.far = 140.0
	_camera.position = Vector3(0.0, 38.0, 32.0)
	_world.add_child(_camera)
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_build_hud()


func _build_environment() -> void:
	var ground := _box("GrassGround", Vector3(58.0, 0.18, 22.0), Color("214b35"))
	ground.position.y = -0.12
	_world.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-56.0, -28.0, 0.0)
	sun.light_color = Color("ffe1ab")
	sun.light_energy = 1.45
	sun.shadow_enabled = true
	_world.add_child(sun)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("638aa0")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("b8d7c0")
	settings.ambient_light_energy = 0.7
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	settings.tonemap_exposure = 0.9
	environment.environment = settings
	_world.add_child(environment)
	for index: int in 28:
		var x := -28.0 + float(index % 14) * 4.3
		var z := -10.2 if index < 14 else 10.2
		var trunk := _box("BoundaryTreeTrunk", Vector3(0.32, 1.6, 0.32), Color("61442f"))
		trunk.position = Vector3(x, 0.8, z)
		_world.add_child(trunk)
		var crown := _sphere("BoundaryTreeCrown", 0.82, Color("2f7043"))
		crown.position = Vector3(x, 2.0, z)
		_world.add_child(crown)


func _build_lane(participant_id: String) -> void:
	var offset: float = LANE_OFFSETS[participant_id]
	var lane_floor := _box("%sLaneFloor" % participant_id, Vector3(15.4, 0.08, 15.4), LANE_TONES[participant_id].darkened(0.42))
	lane_floor.position = Vector3(offset, -0.01, 0.0)
	_world.add_child(lane_floor)
	for y: int in MazeMap.ROWS.size():
		for x: int in MazeMap.ROWS[y].length():
			if MazeMap.ROWS[y][x] != "#":
				continue
			var wall := _box("MazeWall", Vector3(0.92, 1.1, 0.92), Color("51614f"))
			wall.position = Vector3(offset + float(x - 7), 0.55, float(y - 7))
			_world.add_child(wall)
			if (x + y) % 4 == 0:
				var hedge := _box("MazeHedge", Vector3(0.78, 0.35, 0.78), LANE_TONES[participant_id].lightened(0.12))
				hedge.position = wall.position + Vector3(0.0, 0.67, 0.0)
				_world.add_child(hedge)
	var start_banner := _lane_banner(participant_id)
	start_banner.position = Vector3(offset, 0.0, 7.6)
	_world.add_child(start_banner)
	var exit_arch := _exit_arch(participant_id)
	exit_arch.position = Vector3(offset, 0.0, -6.0)
	_world.add_child(exit_arch)
	_build_landmarks(participant_id)


func _build_landmarks(participant_id: String) -> void:
	var offset: float = LANE_OFFSETS[participant_id]
	for cell: Vector2i in MazeMap.LANDMARKS:
		var marker := _sphere("Landmark", 0.22, Color("62d9ff"))
		marker.position = Vector3(offset + float(cell.x - 7), 0.35, float(cell.y - 7))
		var material := marker.material_override as StandardMaterial3D
		material.emission_enabled = true
		material.emission = Color("2d8ca8")
		_world.add_child(marker)


func _build_racer(participant_id: String) -> void:
	var actor := YBot.instantiate() as Node3D
	actor.name = "%sRacer" % participant_id
	var tree := actor.get_node_or_null("AnimationTree") as AnimationTree
	if tree != null and tree.tree_root != null:
		tree.tree_root = tree.tree_root.duplicate(true)
	var entrant_id: String = {"participant_0": "sol", "participant_1": "luna", "participant_2": "terra"}[participant_id]
	EntrantPalette.tint_avatar(actor, entrant_id)
	actor.scale = Vector3(0.72, 0.72, 0.72)
	actor.position = _world_position(participant_id, Vector2(7, 13))
	var label := Label3D.new()
	label.name = "RacerLabel"
	label.position.y = 3.2
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.outline_size = 5
	label.font_size = 34
	label.modulate = EntrantPalette.color(entrant_id)
	actor.add_child(label)
	var speech := Label3D.new()
	speech.name = "Speech"
	speech.position.y = 4.15
	speech.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	speech.outline_size = 5
	speech.font_size = 28
	speech.modulate = Color("fff5d8")
	actor.add_child(speech)
	_world.add_child(actor)
	_racers[participant_id] = actor


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var top := ColorRect.new()
	top.position = Vector2(18, 16)
	top.size = Vector2(1404, 150)
	top.color = Color("08121eea")
	layer.add_child(top)
	_hud = RichTextLabel.new()
	_hud.position = Vector2(22, 12)
	_hud.size = Vector2(1360, 132)
	_hud.bbcode_enabled = true
	_hud.scroll_active = false
	_hud.add_theme_font_size_override("normal_font_size", 18)
	top.add_child(_hud)
	_beat = Label.new()
	_beat.position = Vector2(28, 175)
	_beat.size = Vector2(980, 40)
	_beat.add_theme_font_size_override("font_size", 21)
	_beat.add_theme_color_override("font_color", Color("ffe38c"))
	layer.add_child(_beat)
	_event_feed = Label.new()
	_event_feed.position = Vector2(1040, 175)
	_event_feed.size = Vector2(370, 170)
	_event_feed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_event_feed.add_theme_font_size_override("font_size", 16)
	_event_feed.add_theme_color_override("font_color", Color("e8f1f8"))
	layer.add_child(_event_feed)
	_title_card = _overlay_card(layer, Vector2(260, 285), Vector2(920, 240), Color("07111cf4"))
	var title := RichTextLabel.new()
	title.position = Vector2(42, 28)
	title.size = Vector2(836, 190)
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[center][font_size=22][color=#8be9fd]WORLDARENA HIGHLIGHT[/color][/font_size]\n[font_size=50][b]LABYRINTH RUN[/b][/font_size]\n[font_size=22]Three agents · the same maze · no shared vision[/font_size][/center]"
	_title_card.add_child(title)
	_winner_card = _overlay_card(layer, Vector2(210, 245), Vector2(1020, 410), Color("07111cf7"))
	var winner := RichTextLabel.new()
	winner.position = Vector2(48, 34)
	winner.size = Vector2(924, 350)
	winner.bbcode_enabled = true
	winner.fit_content = true
	winner.text = "[center][font_size=20][color=#8be9fd]VERIFIED RESULT[/color][/font_size]\n[font_size=50][color=#fbbf24][b]SOL WINS[/b][/color][/font_size]\n[font_size=24]44.8 seconds · 64 cells · 93.75% path efficiency[/font_size]\n\n[font_size=20][color=#fbbf24]1  Sol  44.8s[/color]     [color=#34d399]2  Terra  53.6s[/color]     [color=#a78bfa]3  Luna  58.4s[/color]\n\nSol eliminated exhausted branches most efficiently.\nTerra recovered from two wrong branches.\nLuna finished, but travelled the longest route.[/font_size]\n\n[font_size=16][color=#9fb3c8]DETERMINISTIC REPLAY VERIFIED · MAZE-TASK-PLAN-V1[/color][/font_size][/center]"
	_winner_card.add_child(winner)
	_winner_card.visible = false


func _update_hud(tick: int) -> void:
	var remaining := maxi(0, 600 - tick)
	var remaining_seconds := ceili(float(remaining) / 10.0)
	var lines := "[font_size=22][b]LABYRINTH RUN[/b]  [color=#8be9fd]%02d:%02d[/color][/font_size]     " % [remaining_seconds / 60, remaining_seconds % 60]
	lines += "[color=#fbbf24][b]● SOL[/b][/color] demo-sol-v1     [color=#a78bfa][b]● LUNA[/b][/color] demo-luna-v1     [color=#34d399][b]● TERRA[/b][/color] demo-terra-v1\n"
	for value: Variant in _replay.racers:
		var racer: Dictionary = value
		var progress := _progress_at(racer, tick)
		var color := str(racer.color)
		lines += "[color=%s][b]%-5s[/b][/color] %-12s  passages %2d  dead ends %d  distance %3d  efficiency %5.2f%%\n" % [color, str(racer.display_name).to_upper(), str(progress.task).replace("_", " "), progress.passages, progress.dead_ends, progress.distance, float(racer.path_efficiency_basis_points) / 100.0]
	_hud.text = lines
	var recent: Array[String] = []
	for value: Variant in _replay.events:
		if int(value.tick) <= tick and int(value.tick) >= tick - 55:
			recent.append("%s · %s" % [_display_name(str(value.participant_id)), str(value.label)])
	_event_feed.text = "EVENT FEED\n" + "\n".join(recent.slice(maxi(0, recent.size() - 4)))


func _progress_at(racer: Dictionary, tick: int) -> Dictionary:
	var keyframes: Array = racer.keyframes
	var distance := 0
	var task := "exploring"
	for value: Variant in keyframes:
		if int(value.tick) > tick:
			break
		distance += 1 if int(value.tick) > 0 else 0
		task = str(value.task)
	var passages := 0
	var dead_ends := 0
	for event: Variant in _replay.events:
		if event.participant_id == racer.participant_id and int(event.tick) <= tick:
			passages += 1 if event.kind in ["junction_choice", "backtrack"] else 0
			dead_ends += 1 if event.kind == "dead_end" else 0
	return {"distance": distance, "task": task, "passages": passages, "dead_ends": dead_ends}


func _pose_at(keyframes: Array, tick_milli: int) -> Dictionary:
	var before: Dictionary = keyframes[0]
	var after: Dictionary = before
	for value: Variant in keyframes:
		if int(value.tick) * 1000 <= tick_milli:
			before = value
			after = value
			continue
		after = value
		break
	var before_position := Vector2(float(before.cell[0]), float(before.cell[1]))
	var after_position := Vector2(float(after.cell[0]), float(after.cell[1]))
	var span := maxi(1, (int(after.tick) - int(before.tick)) * 1000)
	var progress := clampf(float(tick_milli - int(before.tick) * 1000) / float(span), 0.0, 1.0)
	var moving := before_position != after_position and tick_milli < int(after.tick) * 1000
	var state := str(after.state if not moving else "walk")
	return {
		"position": before_position.lerp(after_position, progress),
		"heading": int(after.heading),
		"animation": "hit" if state == "surprised" else "celebrate" if state == "celebrate" else "walk" if moving or state == "walk" else "idle",
		"task": str(after.task if moving else before.task),
	}


func _safe_event_label(participant_id: String, tick: int) -> String:
	var label := "Exploring"
	for value: Variant in _replay.events:
		if value.participant_id == participant_id and int(value.tick) <= tick:
			label = str(value.label)
	return label if label.length() <= 40 else label.left(40)


func _apply_camera_beat(tick: int) -> void:
	var position := Vector3(0.0, 38.0, 32.0)
	var target := Vector3(0.0, 0.0, 0.0)
	var label := "IDENTICAL LANES · EQUAL MOVEMENT SPEED · PRIVATE VISION"
	if tick < 100:
		position = Vector3(0.0, 22.0, 26.0)
		target = Vector3(0.0, 0.0, 5.0)
		label = "THE GATES OPEN · THREE INDEPENDENT SEARCHES"
	elif tick < 300:
		label = "OVERHEAD COMPARISON · POLICIES DIVERGE"
	elif tick < 420:
		position = Vector3(9.0, 15.0, 14.0)
		target = Vector3(9.0, 0.0, 0.0)
		label = "LUNA AND TERRA TEST WRONG PASSAGES"
	elif tick < 480:
		position = Vector3(-18.0, 10.0, -13.0)
		target = Vector3(-18.0, 0.0, -5.0)
		label = "SOL FINDS THE EXIT FIRST"
	elif tick < 550:
		position = Vector3(18.0, 10.0, -13.0)
		target = Vector3(18.0, 0.0, -5.0)
		label = "TERRA RECOVERS · SECOND PLACE"
	else:
		position = Vector3(0.0, 11.0, -13.0)
		target = Vector3(0.0, 0.0, -5.0)
		label = "LUNA BACKTRACKS AND ESCAPES BEFORE TIME"
	if tick >= int(_replay.result.completion_tick):
		position = Vector3(0.0, 31.0, 29.0)
		target = Vector3(0.0, 0.0, -2.0)
		label = "FINAL PODIUM · SOL WINS ON PATH EFFICIENCY"
	_camera.position = position
	_camera.look_at(target, Vector3.UP)
	_beat.text = label


func _lane_banner(participant_id: String) -> Node3D:
	var root := Node3D.new()
	var post := _box("BannerPost", Vector3(0.18, 2.5, 0.18), Color("5a4431"))
	post.position.y = 1.25
	root.add_child(post)
	var banner := _box("Banner", Vector3(1.8, 0.9, 0.1), LANE_TONES[participant_id].lightened(0.18))
	banner.position = Vector3(0.0, 2.0, 0.0)
	root.add_child(banner)
	var label := Label3D.new()
	label.text = _display_name(participant_id).to_upper()
	label.position = Vector3(0.0, 2.0, -0.08)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.outline_size = 4
	label.font_size = 42
	root.add_child(label)
	return root


func _exit_arch(participant_id: String) -> Node3D:
	var root := Node3D.new()
	for x: float in [-0.7, 0.7]:
		var pillar := _box("ExitPillar", Vector3(0.3, 2.6, 0.35), Color("728070"))
		pillar.position = Vector3(x, 1.3, 0.0)
		root.add_child(pillar)
	var lintel := _box("ExitLintel", Vector3(1.7, 0.35, 0.4), Color("8d9a87"))
	lintel.position.y = 2.55
	root.add_child(lintel)
	var glow := _sphere("ExitGlow", 0.42, LANE_TONES[participant_id].lightened(0.42))
	glow.position.y = 2.0
	var material := glow.material_override as StandardMaterial3D
	material.emission_enabled = true
	material.emission = LANE_TONES[participant_id]
	root.add_child(glow)
	return root


func _overlay_card(layer: CanvasLayer, position: Vector2, size: Vector2, color: Color) -> Control:
	var panel := ColorRect.new()
	panel.position = position
	panel.size = size
	panel.color = color
	layer.add_child(panel)
	return panel


func _world_position(participant_id: String, cell: Vector2) -> Vector3:
	return Vector3(float(LANE_OFFSETS[participant_id]) + cell.x - 7.0, 0.0, cell.y - 7.0)


func _display_name(participant_id: String) -> String:
	return {"participant_0": "Sol", "participant_1": "Luna", "participant_2": "Terra"}.get(participant_id, "Agent")


func _box(name: String, size: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _sphere(name: String, radius: float, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	node.mesh = mesh
	node.material_override = _material(color)
	return node


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	return material
