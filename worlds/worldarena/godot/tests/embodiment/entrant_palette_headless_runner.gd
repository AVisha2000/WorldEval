extends SceneTree

const DuoScene := preload("res://scripts/embodiment/presentation/v2/control_game_participant_scene_v2.gd")
const TrioScene := preload("res://scripts/embodiment/presentation/v3/trio_participant_scene_v3.gd")
const Palette := preload("res://scripts/embodiment/presentation/entrant_palette.gd")
const V1Scene := preload("res://scenes/embodiment/embodiment_presentation_scene.tscn")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var v1 := V1Scene.instantiate()
	root.add_child(v1)
	v1.configure_presentation_entrant("bravo")
	var v1_avatar := v1.get_node_or_null("OperatorProjection") as Node3D
	if v1_avatar == null or v1_avatar.get_meta("presentation_entrant_id", "") != "bravo" \
		or not v1_avatar.has_node("OperatorLabel"):
		_fail("v1 avatar did not receive its presentation-only Bravo palette")
		return
	var duo := DuoScene.new()
	root.add_child(duo)
	if not duo.configure_task("duo-spar-v0", "participant_0", "bravo"):
		_fail("duo identity configuration rejected")
		return
	var duo_avatar := duo.get_node_or_null("ParticipantOperator") as Node3D
	if duo_avatar == null or duo_avatar.get_meta("presentation_entrant_id", "") != "bravo" \
		or not duo_avatar.has_node("EntrantLabel"):
		_fail("duo avatar did not receive its public entrant palette")
		return
	if not duo.apply_participant_projection({
		"participant_id": "participant_0",
		"operator": {"position_mt": {"x": 0, "y": 0}, "heading": 0,
			"animation_state": "idle", "presentation_entrant_id": "bravo"},
		"visible_entities": [{"id": "v_rival", "kind": "operator",
			"position_mt": {"x": 1000, "y": 0}, "heading": 4, "animation_state": "idle",
			"presentation_entrant_id": "alpha"}],
	}, _observation("participant_0", ["v_rival"])):
		_fail("duo public presentation identity projection rejected")
		return
	if (duo.get_node_or_null("ParticipantVisibleEntities/Visible_v_rival") as Node3D) \
		.get_meta("presentation_entrant_id", "") != "alpha":
		_fail("duo rival did not keep public Alpha palette")
		return
	var duo_hud := duo._identity_hud as RichTextLabel
	if duo_hud == null or not "YOU · BRAVO" in duo_hud.get_parsed_text() \
		or not "VISIBLE · ALPHA" in duo_hud.get_parsed_text():
		_fail("duo participant HUD did not use public visible identities")
		return
	var trio := TrioScene.new()
	root.add_child(trio)
	# Rotation 1 intentionally puts Terra into participant_0.  This is the same public cyclic
	# mapping used by the three-leg series, so colour follows the entrant rather than the seat.
	if not trio.configure_task("trio-free-for-all-v0", "participant_0", "", 1):
		_fail("trio identity configuration rejected")
		return
	var trio_avatar := trio.get_node_or_null("ParticipantOperator") as Node3D
	if trio_avatar == null or trio_avatar.get_meta("presentation_entrant_id", "") != "terra" \
		or trio_avatar.get_meta("presentation_color_hex", "") != Palette.color("terra").to_html(false) \
		or not trio_avatar.has_node("EntrantLabel"):
		_fail("trio rotation did not keep Terra's identity palette")
		return
	var opponents := [
		trio._entrant_for_participant("participant_1"), trio._entrant_for_participant("participant_2"),
	]
	if opponents != ["sol", "luna"]:
		_fail("trio rotation palette mapping drifted")
		return
	if not trio.apply_participant_projection({
		"participant_id": "participant_0",
		"operator": {"position_axial": {"q": 0, "r": 0}, "heading": 0,
			"animation_state": "idle"},
		"visible_entities": [{"id": "v_participant_1", "kind": "operator",
			"position_axial": {"q": 1000, "r": 0}, "heading": 3, "animation_state": "idle"}],
	}, _observation("participant_0", ["v_participant_1"])):
		_fail("trio public presentation identity projection rejected")
		return
	var trio_hud := trio._identity_hud as RichTextLabel
	if trio_hud == null or not "YOU · TERRA" in trio_hud.get_parsed_text() \
		or not "VISIBLE · SOL" in trio_hud.get_parsed_text() \
		or "LUNA" in trio_hud.get_parsed_text():
		_fail("trio participant HUD leaked or omitted a visible roster identity")
		return
	print("ENTRANT_PALETTE_OK")
	quit(0)


func _observation(participant_id: String, visible_ids: Array[String]) -> Dictionary:
	var entities: Array[Dictionary] = []
	for entity_id: String in visible_ids:
		entities.append({"id": entity_id})
	return {
		"episode_id": "ep_entrant_palette", "observation_seq": 0, "participant_id": participant_id,
		"profile": "text-visible-v1", "visible_entities": entities, "goal": "palette test",
		"tick": 0, "self": {"status": []},
	}


func _fail(message: String) -> void:
	push_error("ENTRANT_PALETTE_FAILED: %s" % message)
	print("ENTRANT_PALETTE_FAILED")
	quit(1)
