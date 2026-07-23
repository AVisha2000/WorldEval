extends SceneTree

const RtsHud := preload("res://scripts/embodiment/presentation/v2/rts_participant_hud_v2.gd")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var camera := Camera3D.new()
	RtsHud.configure_resource_relay_camera(camera)
	_check(camera.position == Vector3(0.0, RtsHud.CAMERA_HEIGHT, RtsHud.CAMERA_DISTANCE),
		"RTS camera position drifted")
	_check(is_equal_approx(camera.rotation_degrees.x, RtsHud.CAMERA_PITCH_DEGREES),
		"RTS camera pitch drifted")
	_check(camera.fov == RtsHud.CAMERA_FOV and camera.current,
		"RTS camera profile did not become current")
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var hud := RtsHud.build(layer)
	_check(hud != null and layer.has_node("RtsObjectiveHud/Content"),
		"RTS HUD was not built")
	var observation := {
		"goal": "Gather visible material, deposit it at your relay, build and defend.",
		"self": {"health_percent": 75, "energy_percent": 60,
			"inventory": [{"kind": "material", "count": 1}]},
		"visible_entities": [
			{"id": "v_resource_0", "state": "available"},
			{"id": "v_friendly_relay", "state": "stocked"},
			{"id": "v_friendly_barricade", "state": "damaged"},
			{"id": "v_rival", "state": "guarding"},
		],
		"previous_receipt": {"disposition": "accepted"},
		"hidden_state": "DO_NOT_RENDER",
		"prompt": "DO_NOT_RENDER",
		"credential": "DO_NOT_RENDER",
	}
	RtsHud.update(hud, observation, {"animation_state": "build"}, "alpha")
	var public_text := hud.get_parsed_text()
	_check("ALPHA COMMAND" in public_text and "HP 75%" in public_text
		and "CARRYING MATERIAL" in public_text and "BUILDING BARRICADE" in public_text,
		"RTS HUD omitted visible self state")
	_check("MATERIAL AVAILABLE" in public_text and "RELAY STOCKED" in public_text
		and "BARRICADE DAMAGED" in public_text and "RIVAL BRAVO GUARDING" in public_text,
		"RTS HUD omitted public visible entity state")
	_check(not "position_mt" in public_text and not "checkpoint" in public_text
		and not "DO_NOT_RENDER" in public_text,
		"RTS HUD exposed non-observation state")
	camera.free()
	print("RTS_PARTICIPANT_HUD_V2_OK")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("RTS_PARTICIPANT_HUD_V2_FAILED: %s" % message)
	print("RTS_PARTICIPANT_HUD_V2_FAILED")
	quit(1)
