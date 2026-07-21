extends SceneTree

const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")

const EXPECTED_GOLDEN := "70dd104528372ca36df9a2cc76ee52e37c03da95e5f7f10994273410f3c3916f"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed := load("res://scenes/duel_v1.tscn") as PackedScene
	_check(packed != null, "duel scene did not parse as PackedScene")
	if packed == null:
		_finish("", {})
		return
	var app = packed.instantiate()
	root.add_child(app)
	await process_frame
	await process_frame
	var presentation = app.presentation
	_check(app.match_controller != null and app.launch_client != null, "scene coordinator did not own controller and launch client")
	_check(presentation.debug_state()["surface"] == "setup", "scene did not start on setup surface")
	_check(presentation.setup_panel != null and presentation.hud != null, "presentation surfaces were not constructed")
	_check(presentation.setup_panel.start_button.tooltip_text.length() > 10, "primary setup action lacks an accessible tooltip")
	_check(presentation.hud.perspective_select.tooltip_text.length() > 10, "perspective control lacks an accessible tooltip")

	presentation.show_live()
	var omni: Dictionary = presentation.mock_projection()
	var seat_zero: Dictionary = presentation.mock_projection()
	seat_zero["entities"] = [seat_zero["entities"][0]]
	seat_zero["selected"] = seat_zero["entities"][0]
	_check(presentation.apply_projection("omniscient", omni), "omniscient projection was rejected")
	_check(presentation.apply_projection("seat_0", seat_zero), "seat projection was rejected")
	_check(not presentation.apply_projection("invalid", {}), "invalid perspective was cached")
	omni["entities"].clear()
	seat_zero["entities"][0]["hp"] = 1
	_check(presentation.cached_projection_copy("omniscient")["entities"].size() == 5, "omniscient cache retained caller mutation")
	_check(int(presentation.cached_projection_copy("seat_0")["entities"][0]["hp"]) == 2730, "seat cache retained nested caller mutation")

	var perspective_requests := PackedStringArray()
	presentation.perspective_requested.connect(func(value: String) -> void: perspective_requests.append(value))
	_check(presentation.hud.request_perspective("seat_0"), "seat perspective request failed")
	_check(presentation.current_perspective == "seat_0", "active perspective did not update")
	_check(presentation.tactical_board.projection_copy()["entities"].size() == 1, "seat view did not rebuild from its separate projection")
	_check(perspective_requests == PackedStringArray(["seat_0"]), "perspective request signal changed")

	var continuous: Dictionary = presentation.mock_projection()
	continuous["decision_mode"] = "continuous_realtime"
	presentation.apply_projection("seat_0", continuous)
	var speed_requests: Array[float] = []
	presentation.playback_speed_requested.connect(func(value: float) -> void: speed_requests.append(value))
	_check(not presentation.hud.request_playback_speed(4.0), "continuous live view accepted faster than 1x")
	_check(presentation.hud.request_playback_speed(0.5), "continuous live view rejected a safe speed")
	presentation.set_replay_state({"replay": true, "verified": true, "tick": 1240, "maximum_tick": 18000, "checkpoint_status": "matched"})
	_check(presentation.hud.request_playback_speed(4.0), "verified replay rejected faster playback")
	_check(speed_requests == [0.5, 4.0], "playback request signals changed")

	var pauses: Array[bool] = []
	presentation.pause_requested.connect(func(value: bool) -> void: pauses.append(value))
	presentation.hud.toggle_pause()
	_check(pauses == [true], "pause request signal changed")
	var seeks: Array[int] = []
	presentation.replay_seek_requested.connect(func(value: int) -> void: seeks.append(value))
	_check(presentation.hud.request_replay_seek(1500), "verified replay seek failed")
	_check(seeks == [1500], "seek request signal changed")

	var events: Array = presentation.mock_events()
	presentation.apply_events(events)
	presentation.apply_events([events[0]])
	events[0]["text"] = "caller mutation"
	_check(presentation.hud.event_history_copy().size() == 3, "event deduplication failed")
	_check(str(presentation.hud.event_history_copy()[0]["text"]) != "caller mutation", "event history retained caller mutation")
	var asset_status: Dictionary = presentation.display_asset_status()
	_check(str(asset_status["packs"]["production_family"]) == "kaykit", "production asset family changed")
	_check(str(asset_status["packs"]["fallback"]).contains("procedural"), "display fallback is not explicit")

	var state: Dictionary = presentation.debug_state()
	var summary := {
		"cached_perspectives": state["cached_perspectives"].size(),
		"events": state["event_count"],
		"live_speed_requests": speed_requests.size(),
		"perspective": state["perspective"],
		"scene_size": [root.size.x, root.size.y],
		"surface": state["surface"],
	}
	var golden := Codec.sha256_canonical(summary)
	if not EXPECTED_GOLDEN.is_empty():
		_check(golden == EXPECTED_GOLDEN, "duel presentation golden changed: " + golden)
	app.queue_free()
	await process_frame
	_finish(golden, summary)


func _finish(golden: String, summary: Dictionary) -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("DUEL_PRESENTATION_FAILURE: " + failure)
		print("DUEL_PRESENTATION_FAILED count=%d hash=%s" % [_failures.size(), golden])
		quit(1)
		return
	print("DUEL_PRESENTATION_OK hash=%s summary=%s" % [golden, JSON.stringify(summary)])
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
