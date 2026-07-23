extends SceneTree

const PrivacyFilter := preload(
	"res://scripts/embodiment/presentation/privacy/presentation_snapshot_filter.gd"
)
const FrameCapture := preload(
	"res://scripts/embodiment/presentation/capture/participant_frame_capture.gd"
)

const CHECKPOINT_HASH := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const EXPECTED_RENDER_DIGEST := "0c4ce3fbbeddf0a073f682adcadb9f7981d56862fe088df9dbfca4996be87150"
const EXPECTED_TEXT_DIGEST := "8e89d449833b64234096602febf52cae9c3d4464e134c59763f6dd542b234fc3"

var _failures := PackedStringArray()


class PixelAuditRenderer:
	extends RefCounted

	const BACKGROUND := Color("101820")
	const VISIBLE := Color("45d483")

	func render_participant_png(
		snapshot: Dictionary, _participant_id: String, _observation_sequence: int
	) -> PackedByteArray:
		var image := Image.create(1280, 720, false, Image.FORMAT_RGBA8)
		image.fill(BACKGROUND)
		_draw(image, snapshot.self)
		for entity: Dictionary in snapshot.visible_entities:
			_draw(image, entity)
		return image.save_png_to_buffer()

	func _draw(image: Image, entity: Dictionary) -> void:
		var x: int = 640 + int(int(entity.position_mt[0]) / 20.0)
		var y: int = 360 + int(int(entity.position_mt[1]) / 20.0)
		image.fill_rect(Rect2i(x - 6, y - 6, 12, 12), VISIBLE)


func _init() -> void:
	_test_hidden_entities_are_absent_and_input_is_unchanged()
	_test_hidden_entities_are_absent_from_pixels()
	_test_strict_rejections()
	_test_digest_binding_is_deterministic()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_PRESENTATION_PRIVACY_FAILURE: %s" % failure)
		print("EMBODIMENT_PRESENTATION_PRIVACY_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_PRESENTATION_PRIVACY_OK")
	quit(0)


func _test_hidden_entities_are_absent_and_input_is_unchanged() -> void:
	var internal := _internal_snapshot()
	var before := PrivacyFilter.canonical_json(internal)
	var result := PrivacyFilter.filter_for_participant(
		internal, "participant_0", ["operator_0", "resource_visible"]
	)
	_check(result.get("ok") == true, "valid presentation input was rejected: %s" % str(result))
	if result.get("ok") != true:
		return
	var render: Dictionary = result["snapshot"]
	_check(render.is_read_only(), "render snapshot root is mutable")
	_check(render["self"].is_read_only(), "render snapshot self entity is mutable")
	_check(render["visible_entities"].is_read_only(), "render entity array is mutable")
	_check(render["agency"].is_read_only(), "participant agency projection is mutable")
	_check(render["visible_entities"].size() == 1, "filter did not retain exactly one visible entity")
	_check(render["visible_entities"][0]["id"] == "resource_visible", "visible entity order drifted")
	var render_text := PrivacyFilter.canonical_json(render)
	_check("resource_hidden_secret" not in render_text, "hidden resource leaked into render snapshot")
	_check("neutral_hidden_secret" not in render_text, "hidden neutral leaked into render snapshot")
	_check("[1111,-2222]" in render_text, "visible exact position missing from internal render snapshot")
	_check(render["authority_checkpoint_hash"] == CHECKPOINT_HASH, "opaque checkpoint hash drifted")
	_check(PrivacyFilter.canonical_json(internal) == before, "filter mutated its authority input")

	var text_result := PrivacyFilter.project_visible_text(render)
	_check(text_result.get("ok") == true, "visible-text projection failed: %s" % str(text_result))
	if text_result.get("ok") != true:
		return
	var projection: Dictionary = text_result["projection"]
	var semantic_text: String = text_result["canonical_text"]
	_check(projection.is_read_only(), "text projection root is mutable")
	_check("position_mt" not in semantic_text, "exact position field leaked into semantic observation")
	_check("1111" not in semantic_text, "exact x coordinate leaked into semantic observation")
	_check("-2222" not in semantic_text, "exact y coordinate leaked into semantic observation")
	_check("authority_checkpoint_hash" not in semantic_text, "authority hash leaked into player semantics")
	_check("resource_hidden_secret" not in semantic_text, "hidden resource leaked into visible text")
	_check("neutral_hidden_secret" not in semantic_text, "hidden neutral leaked into visible text")
	_check("Continue building" not in semantic_text, "non-authoritative intent entered semantic text")
	_check("resource_visible" in semantic_text, "visible resource missing from visible text")
	_check(not _contains_float(render), "render snapshot contains a float")
	_check(not _contains_float(projection), "text projection contains a float")


func _test_hidden_entities_are_absent_from_pixels() -> void:
	var first_input := _internal_snapshot()
	first_input.entities[2].position_mt = [5000, 5000]
	var second_input := first_input.duplicate(true)
	second_input.entities[2].position_mt = [-5000, 5000]
	second_input.entities[2].semantic.state = "hidden_changed"
	var first := PrivacyFilter.filter_for_participant(
		first_input, "participant_0", ["operator_0", "resource_visible"]
	)
	var second := PrivacyFilter.filter_for_participant(
		second_input, "participant_0", ["operator_0", "resource_visible"]
	)
	_check(first.get("ok") == true and second.get("ok") == true, "pixel privacy fixtures rejected")
	if first.get("ok") != true or second.get("ok") != true:
		return
	_check(
		PrivacyFilter.safe_snapshot_digest(first.snapshot)
			== PrivacyFilter.safe_snapshot_digest(second.snapshot),
		"hidden authority changes altered the render projection",
	)
	var renderer := PixelAuditRenderer.new()
	var first_capture := FrameCapture.new().capture(first.snapshot, "participant_0", 4, renderer)
	var second_capture := FrameCapture.new().capture(second.snapshot, "participant_0", 4, renderer)
	_check(bool(first_capture.get("ok", false)), "first pixel audit capture failed")
	_check(bool(second_capture.get("ok", false)), "second pixel audit capture failed")
	if not bool(first_capture.get("ok", false)) or not bool(second_capture.get("ok", false)):
		return
	_check(first_capture.bytes == second_capture.bytes, "hidden authority changes altered frame pixels")
	var image := Image.new()
	_check(image.load_png_from_buffer(first_capture.bytes) == OK, "pixel audit PNG failed to decode")
	if image.is_empty():
		return
	_check(
		image.get_pixel(890, 610).is_equal_approx(PixelAuditRenderer.BACKGROUND),
		"hidden entity marker appeared in participant pixels",
	)
	_check(
		image.get_pixel(695, 249).is_equal_approx(PixelAuditRenderer.VISIBLE),
		"visible entity marker was missing from participant pixels",
	)


func _test_strict_rejections() -> void:
	var spectator := _internal_snapshot()
	spectator["spectator_camera"] = {"position_mt": [0, 0]}
	_expect_rejected(spectator, ["operator_0"], "spectator-only root field was accepted")

	var entity_spectator := _internal_snapshot()
	entity_spectator["entities"][0]["spectator_alias"] = "omniscient_operator"
	_expect_rejected(entity_spectator, ["operator_0"], "spectator-only entity field was accepted")

	var float_position := _internal_snapshot()
	float_position["entities"][1]["position_mt"][0] = 1111.0
	_expect_rejected(float_position, ["operator_0", "resource_visible"], "float coordinate was accepted")

	var float_nested := _internal_snapshot()
	float_nested["entities"][1]["semantic"]["state"] = 0.5
	_expect_rejected(float_nested, ["operator_0", "resource_visible"], "float semantic value was accepted")

	var bad_hash := _internal_snapshot()
	bad_hash["authority_checkpoint_hash"] = {"exact_state": true}
	_expect_rejected(bad_hash, ["operator_0"], "structured authority checkpoint was accepted")

	var unknown_visibility := _internal_snapshot()
	_expect_rejected(unknown_visibility, ["operator_0", "spectator_only_id"], "unknown visibility ID was accepted")

	var wrong_type := _internal_snapshot()
	wrong_type["tick"] = "12"
	_expect_rejected(wrong_type, ["operator_0"], "string tick was accepted")

	var rival_agency := _internal_snapshot()
	rival_agency["agency"]["opponent_intent"] = "secret rival plan"
	_expect_rejected(rival_agency, ["operator_0"], "opponent agency crossed exact projection boundary")

	var oversized_intent := _internal_snapshot()
	oversized_intent["agency"]["intent_label"] = "é".repeat(81)
	_expect_rejected(oversized_intent, ["operator_0"], "agency intent UTF-8 byte limit was ignored")


func _test_digest_binding_is_deterministic() -> void:
	var first_result := PrivacyFilter.filter_for_participant(
		_internal_snapshot(), "participant_0", ["operator_0", "resource_visible"]
	)
	var second_input := _internal_snapshot()
	# Dictionary insertion order must not influence canonical digests.
	var reordered_terminal := {
		"reason": second_input["terminal"]["reason"],
		"outcome": second_input["terminal"]["outcome"],
		"ended": second_input["terminal"]["ended"],
	}
	second_input["terminal"] = reordered_terminal
	var second_result := PrivacyFilter.filter_for_participant(
		second_input, "participant_0", ["operator_0", "resource_visible"]
	)
	_check(first_result.get("ok") == true and second_result.get("ok") == true, "digest fixtures rejected")
	if first_result.get("ok") != true or second_result.get("ok") != true:
		return
	var first_text := PrivacyFilter.project_visible_text(first_result["snapshot"])
	var second_text := PrivacyFilter.project_visible_text(second_result["snapshot"])
	var first_binding := PrivacyFilter.bind_digests(first_result["snapshot"], first_text["projection"])
	var second_binding := PrivacyFilter.bind_digests(second_result["snapshot"], second_text["projection"])
	_check(first_binding.get("ok") == true, "first digest binding failed")
	_check(second_binding.get("ok") == true, "second digest binding failed")
	if first_binding.get("ok") != true or second_binding.get("ok") != true:
		return
	var first: Dictionary = first_binding["binding"]
	var second: Dictionary = second_binding["binding"]
	_check(first.is_read_only(), "digest binding is mutable")
	_check(first == second, "canonical digests depend on dictionary insertion order")
	_check(first["authority_checkpoint_hash"] == CHECKPOINT_HASH, "binding altered checkpoint hash")
	_check(first["render_snapshot_sha256"].length() == 64, "render digest is not SHA-256")
	_check(first["text_projection_sha256"].length() == 64, "text digest is not SHA-256")
	_check(
		first["render_snapshot_sha256"] == EXPECTED_RENDER_DIGEST,
		"render digest drifted: %s" % first["render_snapshot_sha256"],
	)
	_check(first["text_projection_sha256"] == EXPECTED_TEXT_DIGEST, "text digest drifted")

	var mismatched_text: Dictionary = first_text["projection"].duplicate(true)
	mismatched_text["tick"] = 13
	var mismatch := PrivacyFilter.bind_digests(first_result["snapshot"], mismatched_text)
	_check(mismatch.get("ok") == false, "digest binding accepted mismatched boundaries")


func _internal_snapshot() -> Dictionary:
	return {
		"schema_version": PrivacyFilter.INPUT_SCHEMA,
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": "ep_privacy_fixture",
		"task_id": "construction-v0",
		"observation_seq": 4,
		"tick": 12,
		"remaining_ticks": 588,
		"goal": "Build the visible barricade.",
		"authority_checkpoint_hash": CHECKPOINT_HASH,
		"self_entity_id": "operator_0",
		"agency": _agency(),
		"entities": [
			_entity("operator_0", "operator", [0, 7000], 0, "idle", "self", []),
			_entity(
				"resource_visible", "resource", [1111, -2222], 0, "gather", "units_2",
				["interactable", "gather"],
			),
			_entity(
				"resource_hidden_secret", "resource", [987654, -456789], 0, "idle",
				"hidden_units_9", ["interactable", "gather"],
			),
			_entity(
				"neutral_hidden_secret", "neutral", [-765432, 345678], 4, "attack",
				"hidden_health_100", ["hostile"],
			),
		],
		"terminal": {"ended": false, "outcome": "running", "reason": "running"},
	}


func _agency() -> Dictionary:
	return {
		"controller": {
			"move_x": 250, "move_y": -500, "look_x": 0, "look_y": 0,
			"duration_ticks": 10,
			"buttons": {
				"interact": true, "primary": false, "guard": false, "dash": false,
				"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false,
			},
		},
		"receipt": {
			"disposition": "accepted", "accepted": true, "fallback": "none",
			"applied_ticks": 10, "codes": ["applied", "construction_progressed"],
		},
		"intent_label": "Continue building the visible barricade.",
	}


func _entity(
	id: String,
	kind: String,
	position_mt: Array,
	heading_sector: int,
	animation: String,
	state: String,
	affordances: Array,
) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"position_mt": position_mt,
		"heading_sector": heading_sector,
		"animation": animation,
		"animation_progress_milli": 0,
		"health_percent": 100,
		"energy_percent": 100,
		"status": [],
		"semantic": {
			"bearing": "front",
			"distance": "near",
			"affordances": affordances,
			"state": state,
		},
	}


func _expect_rejected(snapshot: Dictionary, visibility_ids: Array, message: String) -> void:
	var result := PrivacyFilter.filter_for_participant(snapshot, "participant_0", visibility_ids)
	_check(result.get("ok") == false, message)


func _contains_float(value: Variant) -> bool:
	if typeof(value) == TYPE_FLOAT:
		return true
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			if _contains_float(item):
				return true
	if typeof(value) == TYPE_DICTIONARY:
		for item: Variant in value.values():
			if _contains_float(item):
				return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
