extends SceneTree

## Deterministic, provider-free Construction demo evidence.
##
## This runner deliberately drives the exact managed-hybrid authority path one authoritative tick
## at a time.  It captures the participant-filtered frame at observation zero and after every
## step, so a failure can be inspected frame-by-frame without an API key, browser, or provider.
##
## Optional invocation:
##   Godot --headless --path godot --script \
##     res://tests/embodiment/embodiment_scripted_construction_demo_headless_runner.gd -- \
##     --evidence-dir=/absolute/empty/directory
##
## In headless mode Godot's Dummy renderer cannot read a SubViewport texture.  EvidenceRenderer
## therefore emits deterministic 1280x720 participant-pixel PNGs from the already filtered render
## snapshot, while the real presentation scene is still applied and validated on every boundary.
## A normal managed Godot run uses the actual third-person viewport instead.

const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const HybridAdapter := preload(
	"res://scripts/embodiment/presentation/embodiment_hybrid_presentation_adapter.gd"
)
const PresentationScene := preload(
	"res://scenes/embodiment/embodiment_presentation_scene.tscn"
)

const OUTPUT_PREFIX := "EMBODIMENT_SCRIPTED_CONSTRUCTION_EVIDENCE="
const PARTICIPANT_ID := "participant_0"
const EPISODE_ID := "ep_scripted_construction_demo"
const TASKS := ["gather_materials", "deliver_materials", "build_barricade"]
const MAX_TICKS_PER_TASK := 180

var _failures := PackedStringArray()
var _evidence_dir := ""
var _evidence_frames: Array[Dictionary] = []
var _transcript: Array[Dictionary] = []
var _state_hashes := PackedStringArray()
var _observed_animation_states := PackedStringArray()
var _observed_headings := PackedInt32Array()


class EvidenceRenderer:
	extends RefCounted

	## This renderer only receives the participant-filtered render snapshot from HybridAdapter.
	## It deliberately draws no text, metadata, hidden state, or semantic payload into the pixels.
	func render_participant_png(
		snapshot: Dictionary, _participant_id: String, observation_sequence: int
	) -> PackedByteArray:
		var image := Image.create(1280, 720, false, Image.FORMAT_RGBA8)
		image.fill(Color("09111d"))
		image.fill_rect(Rect2i(112, 72, 1056, 576), Color("14253a"))
		_draw_grid(image)
		for entity: Dictionary in snapshot.visible_entities:
			_draw_entity(image, entity, _entity_color(str(entity.kind)), 18)
		_draw_operator(image, snapshot.self, observation_sequence)
		if bool(snapshot.terminal.ended):
			var color := Color("54d38a") if str(snapshot.terminal.outcome) == "success" else Color("e95858")
			image.fill_rect(Rect2i(112, 72, 1056, 8), color)
		return image.save_png_to_buffer()

	func _draw_grid(image: Image) -> void:
		for x: int in range(160, 1168, 96):
			image.fill_rect(Rect2i(x, 72, 1, 576), Color("20364d"))
		for y: int in range(120, 648, 72):
			image.fill_rect(Rect2i(112, y, 1056, 1), Color("20364d"))

	func _draw_entity(image: Image, entity: Dictionary, color: Color, radius: int) -> void:
		var point := _point(entity.position_mt)
		image.fill_rect(
			Rect2i(point.x - radius, point.y - radius, radius * 2 + 1, radius * 2 + 1), color
		)
		image.fill_rect(
			Rect2i(point.x - radius + 4, point.y - radius + 4, radius * 2 - 7, radius * 2 - 7),
			Color("14253a")
		)

	func _draw_operator(image: Image, entity: Dictionary, observation_sequence: int) -> void:
		var point := _point(entity.position_mt)
		var pulse := 23 + observation_sequence % 4
		image.fill_rect(Rect2i(point.x - pulse, point.y - pulse, pulse * 2 + 1, pulse * 2 + 1), Color("4d7cff"))
		image.fill_rect(Rect2i(point.x - 13, point.y - 13, 27, 27), Color("dbe7ff"))
		var heading: int = int(entity.heading_sector)
		var arrows: Array[Vector2i] = [
			Vector2i(0, -34), Vector2i(24, -24), Vector2i(34, 0), Vector2i(24, 24),
			Vector2i(0, 34), Vector2i(-24, 24), Vector2i(-34, 0), Vector2i(-24, -24),
		]
		var arrow: Vector2i = arrows[posmod(heading, 8)]
		image.fill_rect(Rect2i(point + arrow - Vector2i(5, 5), Vector2i(11, 11)), Color("ffffff"))

	func _point(position_mt: Array) -> Vector2i:
		return Vector2i(
			640 + int(int(position_mt[0]) * 0.05),
			360 + int(int(position_mt[1]) * 0.025),
		)

	func _entity_color(kind: String) -> Color:
		match kind:
			"resource": return Color("ffd166")
			"relay": return Color("22d3ee")
			"build_pad": return Color("f59e0b")
			"barricade": return Color("f97316")
		return Color("a78bfa")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_evidence_dir = _argument_value("--evidence-dir=")
	if not _evidence_dir.is_empty():
		_prepare_evidence_directory()
	if not _failures.is_empty():
		_finish()
		return

	var authority := Authority.new()
	var errors: PackedStringArray = authority.configure_managed_hybrid(_config())
	_check(errors.is_empty(), "scripted Construction configuration failed: %s" % str(errors))
	if not errors.is_empty():
		_finish()
		return

	var viewport := SubViewport.new()
	viewport.name = "ScriptedConstructionEvidenceViewport"
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	root.add_child(viewport)
	var presentation := PresentationScene.instantiate()
	viewport.add_child(presentation)
	await process_frame

	var adapter := HybridAdapter.new(
		authority, presentation, viewport, EvidenceRenderer.new(), 256, 128 * 1024 * 1024
	)
	await _capture_boundary(adapter, authority, "initial")
	for task: String in TASKS:
		await _run_task(authority, adapter, presentation, task)
		if bool(authority.terminal.ended):
			break

	_check(bool(authority.terminal.ended), "scripted Construction did not terminate")
	_check(str(authority.terminal.outcome) == "success", "scripted Construction did not succeed")
	_check(str(authority.terminal.reason) == "barricade_built", "scripted Construction reason drifted")
	_check(
		_evidence_frames.size() == authority.observation_seq + 1,
		"a participant frame was not captured at every observation boundary",
	)
	_check("walk" in _observed_animation_states, "scripted demo never presented walking")
	_check("gather" in _observed_animation_states, "scripted demo never presented gathering")
	_check("build" in _observed_animation_states, "scripted demo never presented building")
	_check("celebrate" in _observed_animation_states, "scripted demo never presented completion")
	_check(_unique_heading_count() >= 4, "scripted demo never visibly rotated the operator")
	_verify_replay(authority)
	_write_manifest(authority)
	adapter.close()
	viewport.queue_free()
	_finish()


func _config() -> Dictionary:
	return {
		"episode_id": EPISODE_ID,
		"maximum_episode_ticks": 600,
		"mode": "solo-curriculum-v0",
		"observation_profile": "hybrid-visible-v1",
		"participant_ids": [PARTICIPANT_ID],
		"protocol_version": "llm-controller/0.1.0",
		"seed": 20240520,
		"task_id": "construction-v0",
		"timing_track": "step-locked-v1",
	}


func _run_task(authority: Object, adapter: Object, presentation: Node, task: String) -> void:
	var completed := false
	for ignored_tick: int in MAX_TICKS_PER_TASK:
		var window := _task_window(authority, task)
		var result: Dictionary = authority.step_window(window)
		_transcript.append(window.duplicate(true))
		_state_hashes.append(str(result.state_hash))
		var receipt: Dictionary = result.receipts[PARTICIPANT_ID]
		_check(bool(receipt.accepted), "%s task action was rejected" % task)
		for failure_code: String in [
			"interaction_out_of_range", "interaction_misaligned", "construction_out_of_range",
			"construction_misaligned", "construction_insufficient_material",
		]:
			_check(failure_code not in receipt.codes, "%s task emitted %s" % [task, failure_code])
		await _capture_boundary(adapter, authority, task)
		var operator := presentation.get_node_or_null("OperatorProjection")
		if operator != null:
			_observed_animation_states.append(str(operator.call("animation_state")))
		var scene_snapshot: Dictionary = presentation.snapshot_copy()
		_observed_headings.append(int(scene_snapshot.operator.heading_milli))
		if "autonomous_task_complete" in receipt.codes:
			completed = true
			break
	_check(completed, "%s task exceeded its deterministic safety horizon" % task)


func _task_window(authority: Object, task: String) -> Dictionary:
	var action := {
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "script_%s_%04d" % [task, authority.observation_seq],
		"control": {
			"move_x": 0,
			"move_y": 0,
			"look_x": 0,
			"look_y": 0,
			"duration_ticks": 1,
			"autonomous_task": task,
			"buttons": {
				"interact": false,
				"primary": false,
				"guard": false,
				"dash": false,
				"ability_1": false,
				"ability_2": false,
				"cycle_item": false,
				"cancel": false,
			},
		},
		"intent_label": task.replace("_", " "),
		"memory_update": "",
	}
	return {
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"mode": authority.mode,
		"start_tick": authority.tick,
		"duration_ticks": 1,
		"decisions": {PARTICIPANT_ID: {
			"disposition": "accepted",
			"action": action,
			"fallback": "none",
			"no_input_reason": null,
		}},
	}


func _capture_boundary(adapter: Object, authority: Object, milestone: String) -> void:
	var captured: Dictionary = await adapter.capture_boundary(PARTICIPANT_ID)
	_check(bool(captured.get("ok", false)), "hybrid capture failed at observation %d: %s" % [
		authority.observation_seq, str(captured.get("code", captured)),
	])
	if not bool(captured.get("ok", false)):
		return
	var observation: Dictionary = captured.observation
	_check(observation.profile == "hybrid-visible-v1", "capture lost hybrid profile")
	_check(observation.has("frame"), "capture omitted participant frame metadata")
	_check(not observation.has("operator_position_mt"), "participant observation leaked exact position")
	var file_name := ""
	if not _evidence_dir.is_empty():
		file_name = "observation_%04d.png" % int(observation.observation_seq)
		var frame_file := FileAccess.open(_evidence_dir.path_join(file_name), FileAccess.WRITE)
		_check(frame_file != null, "could not write %s" % file_name)
		if frame_file != null:
			frame_file.store_buffer(captured.frame_bytes)
			frame_file.close()
	_evidence_frames.append({
		"frame": file_name,
		"milestone": milestone,
		"observation_seq": int(observation.observation_seq),
		"receipt_codes": _receipt_codes(observation),
		"sha256": str(captured.binding.frame_sha256),
		"terminal": observation.terminal.duplicate(true),
		"tick": int(observation.tick),
	})


func _receipt_codes(observation: Dictionary) -> Array:
	var receipt: Variant = observation.get("previous_receipt")
	return receipt.codes.duplicate() if receipt is Dictionary else []


func _verify_replay(authority: Object) -> void:
	var replay := Authority.new()
	var errors: PackedStringArray = replay.configure_managed_hybrid(_config())
	_check(errors.is_empty(), "deterministic replay configuration failed")
	if not errors.is_empty():
		return
	for index: int in _transcript.size():
		var result: Dictionary = replay.step_window(_transcript[index])
		_check(
			str(result.state_hash) == _state_hashes[index],
			"replay checkpoint drifted at observation %d" % index,
		)
	_check(replay.checkpoint_hash() == authority.checkpoint_hash(), "scripted replay final hash drifted")
	_check(replay.terminal == authority.terminal, "scripted replay terminal drifted")


func _prepare_evidence_directory() -> void:
	if not _evidence_dir.is_absolute_path():
		_fail("evidence directory must be absolute")
		return
	if DirAccess.dir_exists_absolute(_evidence_dir):
		var directory := DirAccess.open(_evidence_dir)
		if directory == null:
			_fail("could not inspect evidence directory")
			return
		directory.list_dir_begin()
		var entry := directory.get_next()
		while not entry.is_empty():
			if entry != "." and entry != "..":
				_fail("evidence directory must be empty")
				return
			entry = directory.get_next()
		return
	var error := DirAccess.make_dir_recursive_absolute(_evidence_dir)
	if error != OK:
		_fail("could not create evidence directory")


func _write_manifest(authority: Object) -> void:
	if _evidence_dir.is_empty() or not _failures.is_empty():
		return
	var manifest := {
		"episode_id": authority.episode_id,
		"frames": _evidence_frames,
		"frame_count": _evidence_frames.size(),
		"result": {
			"outcome": authority.terminal.outcome,
			"reason": authority.terminal.reason,
		},
		"schema_version": "worldarena/scripted-construction-evidence/1",
		"task_id": authority.task_id,
	}
	var file := FileAccess.open(_evidence_dir.path_join("manifest.json"), FileAccess.WRITE)
	_check(file != null, "could not write evidence manifest")
	if file != null:
		file.store_string(JSON.stringify(manifest, "\t") + "\n")
		file.close()


func _unique_heading_count() -> int:
	var headings := {}
	for heading: int in _observed_headings:
		headings[heading] = true
	return headings.size()


func _argument_value(prefix: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.substr(prefix.length())
	return ""


func _finish() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_SCRIPTED_CONSTRUCTION_FAILURE: %s" % failure)
		print("EMBODIMENT_SCRIPTED_CONSTRUCTION_FAILED count=%d" % _failures.size())
		quit(1)
		return
	var summary := {
		"evidence_dir": _evidence_dir,
		"frame_count": _evidence_frames.size(),
		"outcome": "success",
		"reason": "barricade_built",
		"tick_count": _state_hashes.size(),
	}
	print(OUTPUT_PREFIX + JSON.stringify(summary))
	print("EMBODIMENT_SCRIPTED_CONSTRUCTION_OK")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if message not in _failures:
		_failures.append(message)
