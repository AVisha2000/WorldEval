extends SceneTree

const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const HybridAdapter := preload(
	"res://scripts/embodiment/presentation/embodiment_hybrid_presentation_adapter.gd"
)
const PresentationScene := preload(
	"res://scenes/embodiment/embodiment_presentation_scene.tscn"
)
const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")


class TestRenderer:
	extends RefCounted

	func render_participant_png(
		snapshot: Dictionary, _participant_id: String, _observation_sequence: int
	) -> PackedByteArray:
		var image := Image.create(1280, 720, false, Image.FORMAT_RGBA8)
		image.fill(Color("14202b"))
		image.fill_rect(Rect2i(100, 80, 1080, 560), Color("27323b"))
		_draw_entity(image, snapshot.self, Color("6f83e8"), 22)
		for entity: Dictionary in snapshot.visible_entities:
			var colors := {
				"resource": Color("ffd166"), "relay": Color("22d3ee"),
				"build_pad": Color("fbbf24"), "neutral": Color("dc3545"),
				"beacon": Color("a78bfa"),
			}
			_draw_entity(image, entity, colors.get(entity.kind, Color.WHITE), 30)
		return image.save_png_to_buffer()

	func _draw_entity(image: Image, entity: Dictionary, color: Color, radius: int) -> void:
		var x := 640 + int(float(int(entity.position_mt[0])) * 0.04)
		var y := 360 + int(float(int(entity.position_mt[1])) * 0.025)
		image.fill_rect(Rect2i(x - radius, y - radius, radius * 2, radius * 2), color)

var _failures := PackedStringArray()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var fixture := _load_fixture()
	if fixture.is_empty():
		_fail("Stage-C golden fixture could not be loaded")
		_finish()
		return
	var authority := Authority.new()
	var errors: PackedStringArray = authority.configure(fixture.config)
	_check(errors.is_empty(), "Stage-C authority rejected golden config")
	for index: int in 17:
		var actual: Dictionary = authority.step_window(fixture.steps[index].decision_window)
		_check(actual == fixture.steps[index].result, "Stage-C setup diverged at step %d" % index)
	var hash_before: String = authority.checkpoint_hash()

	var viewport := SubViewport.new()
	viewport.name = "ParticipantViewport"
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	root.add_child(viewport)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("14202b")
	viewport.add_child(environment)
	var presentation = PresentationScene.instantiate()
	viewport.add_child(presentation)
	var renderer: Variant = null if "--real-viewport" in OS.get_cmdline_user_args() \
		else TestRenderer.new()
	var adapter := HybridAdapter.new(
		authority, presentation, viewport, renderer, 4, 16 * 1024 * 1024
	)
	var captured: Dictionary = await adapter.capture_boundary("participant_0")
	_check(bool(captured.get("ok", false)), "hybrid capture failed: %s" % str(captured))
	if bool(captured.get("ok", false)):
		var observation: Dictionary = captured.observation
		_check(observation.profile == "hybrid-visible-v1", "hybrid profile was not attached")
		_check(observation.has("frame"), "hybrid observation omitted frame metadata")
		_check(observation.visible_entities.size() == 3, "Stage-C visible text entity count drifted")
		_check(captured.binding.digests.authority_checkpoint_hash == hash_before, "binding hash drifted")
		_check(
			captured.binding.digests.render_snapshot_sha256
				== captured.capture_record.visible_snapshot_sha256,
			"frame and text were not bound to one visible snapshot",
		)
		var image := Image.new()
		_check(image.load_png_from_buffer(captured.frame_bytes) == OK, "captured PNG did not decode")
		_check(image.get_width() == 1280 and image.get_height() == 720, "captured frame size drifted")
		_check(not image.is_invisible(), "captured frame was visually empty")
		print(
			"EMBODIMENT_HYBRID_OBSERVATION_BASE64=%s"
			% Marshalls.raw_to_base64(Codec.canonical_bytes(observation))
		)
		for entity_id: String in [
			"v_resource_1", "v_relay_1", "v_build_pad_1", "v_build_pad_1_barricade",
		]:
			_check(presentation.projection_node(entity_id) != null, "%s was not projected" % entity_id)
		_check(authority.checkpoint_hash() == hash_before, "capture presentation changed authority hash")
		# The managed executor may retain the canonical frame bytes between autonomous ticks.  Its
		# scene must nevertheless advance using the latest participant-filtered authority snapshot;
		# only the PNG transport reference remains stable.
		var continued: Dictionary = authority.step_window(fixture.steps[17].decision_window)
		_check(continued == fixture.steps[17].result, "Stage-C cached-scene setup diverged")
		var hash_after_continued: String = authority.checkpoint_hash()
		var reused: Dictionary = adapter.observe_with_cached_frame("participant_0", observation.frame)
		_check(bool(reused.get("ok", false)), "cached hybrid observation failed: %s" % str(reused))
		if bool(reused.get("ok", false)):
			var latest_scene: Dictionary = presentation.snapshot_copy()
			_check(
				int(latest_scene.tick) == authority.tick
				and int(latest_scene.observation_seq) == authority.observation_seq,
				"cached hybrid observation did not apply the latest safe snapshot",
			)
			_check(
				latest_scene.operator.position_mt == [
					authority.operator_position_mt.x, authority.operator_position_mt.y,
				],
				"cached hybrid observation projected a stale operator position",
			)
			_check(
				reused.observation.frame == observation.frame,
				"cached hybrid observation changed canonical frame metadata",
			)
			_check(
				int(reused.observation.observation_seq) == authority.observation_seq,
				"cached hybrid observation did not retain current visible semantics",
			)
		_check(
			viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
			"hybrid capture disabled continuous participant viewport rendering",
		)
		_check(
			authority.checkpoint_hash() == hash_after_continued,
			"cached presentation changed authority hash",
		)
	else:
		_check(authority.checkpoint_hash() == hash_before, "presentation changed authority hash")
	adapter.close()
	viewport.queue_free()
	_finish()


func _load_fixture() -> Dictionary:
	var path := ProjectSettings.globalize_path(
		"res://../game/embodiment_protocol/golden/stage-c-construction-v1.json"
	)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var payload := file.get_buffer(file.get_length())
	if not payload.is_empty() and payload[payload.size() - 1] == 10:
		payload.resize(payload.size() - 1)
	var parsed: Dictionary = Codec.parse_canonical(payload, 16 * 1024 * 1024)
	return parsed.value if bool(parsed.get("ok", false)) else {}


func _finish() -> void:
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_HYBRID_FAILURE: %s" % failure)
		print("EMBODIMENT_HYBRID_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_HYBRID_OK")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
