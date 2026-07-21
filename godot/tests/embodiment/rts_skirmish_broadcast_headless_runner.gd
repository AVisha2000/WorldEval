extends SceneTree

const BroadcastScene := preload(
	"res://scripts/embodiment/presentation/rts/rts_skirmish_broadcast_scene.gd"
)


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := BroadcastScene.new()
	root.add_child(scene)
	await process_frame
	if not scene.apply_public_sources(_sources(), 8, 80):
		_fail("publicly filtered RTS sources were rejected")
		return
	if not scene.has_node("PublicRtsBroadcastWorld/participant_0_town_hall") \
			or not scene.has_node("PublicRtsBroadcastWorld/participant_1_town_hall"):
		_fail("both team bases are absent from the public judge camera")
		return
	var blue_hall := scene.get_node("PublicRtsBroadcastWorld/participant_0_town_hall") as Node3D
	if blue_hall.position != Vector3(-7.6, 0.0, 6.5):
		_fail("new structures did not materialise at their first authority position")
		return
	if scene.has_node("PublicRtsBroadcastWorld/public_central"):
		_fail("obsolete central beacon leaked into the base-destruction presentation")
		return
	for resource_name: String in ["participant_0_tree_0", "participant_0_tree_3", "participant_0_ore_0", "participant_0_ore_2", "participant_1_tree_0", "participant_1_ore_2"]:
		if not scene.has_node("PublicRtsBroadcastWorld/%s" % resource_name):
			_fail("persistent spread resource is absent: %s" % resource_name)
			return
	if not scene.has_node("PublicRtsBroadcastWorld/participant_0_unit_blue_0") \
			or not scene.has_node("PublicRtsBroadcastWorld/participant_1_unit_red_0"):
		_fail("first-class units did not map to individual Y Bots")
		return
	var hud := scene.get_node_or_null("PublicRtsHudLayer/PublicRtsHudPanel/PublicRtsHudText") as RichTextLabel
	if hud == null or not hud.text.contains("Tower") or not hud.text.contains("PHASE") or not hud.text.contains("material_deposited"):
		_fail("public HUD omitted tower, phase, or safe event summary")
		return
	var moved_sources := _sources()
	var moved_unit: Dictionary = moved_sources.participant_0.units[0]
	moved_unit["position_mt"] = {"x": 7000, "y": -7000}
	moved_sources.participant_0.units[0] = moved_unit
	moved_sources.participant_0.visible_entities[1]["state"] = "stump"
	var red_own: Dictionary = moved_sources.participant_1.own
	var red_barracks: Dictionary = red_own.barracks
	red_barracks["state"] = "building"
	red_own["barracks"] = red_barracks
	var red_tower: Dictionary = red_own.tower
	red_tower["state"] = "destroyed"
	red_tower["health_percent"] = 0
	red_own["tower"] = red_tower
	if not scene.apply_public_sources(moved_sources, 9, 90):
		_fail("discontinuity fixture was rejected")
		return
	var blue_worker := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_0_unit_blue_0") as Node3D
	if blue_worker == null or not bool(blue_worker.get_meta("presentation_discontinuity_clamped", false)):
		_fail("unsafe authority discontinuity was not clamped")
		return
	var stump_crown := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_0_tree_0/HarvestTreeCrown") as MeshInstance3D
	if stump_crown == null or stump_crown.visible:
		_fail("canonical stump resource state did not persist as a stump")
		return
	var construction_site := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_1_barracks/ConstructionSite") as Node3D
	var barracks_model := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_1_barracks/Model") as Node3D
	var barracks_marker := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_1_barracks/TeamMarker") as Node3D
	var tower_rubble := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_1_tower/Rubble") as Node3D
	var tower_marker := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_1_tower/TeamMarker") as Node3D
	var tower_label := scene.get_node_or_null("PublicRtsBroadcastWorld/participant_1_tower/Label") as Label3D
	if construction_site == null or not construction_site.visible or barracks_model == null or barracks_model.visible \
			or tower_rubble == null or not tower_rubble.visible:
		_fail("structure state did not render distinct construction or rubble visuals")
		return
	if barracks_marker == null or barracks_marker.visible or tower_marker == null or tower_marker.visible \
			or tower_label == null or tower_label.visible:
		_fail("construction/destroyed markers or destroyed labels cluttered the public base view")
		return
	var dead_sources := moved_sources.duplicate(true)
	var dead_unit: Dictionary = dead_sources.participant_0.units[1]
	dead_unit["alive"] = false
	dead_unit["animation_state"] = "defeat"
	dead_sources.participant_0.units[1] = dead_unit
	if not scene.apply_public_sources(dead_sources, 10, 100):
		_fail("dead-unit projection was rejected")
		return
	if not scene.has_node("PublicRtsBroadcastWorld/participant_0_unit_blue_1"):
		_fail("dead unit did not receive its one defeat presentation")
		return
	scene._process(1.2)
	await process_frame
	if scene.has_node("PublicRtsBroadcastWorld/participant_0_unit_blue_1"):
		_fail("defeated unit was not removed after its animation window")
		return
	if not scene.apply_public_sources(dead_sources, 11, 110) \
			or scene.has_node("PublicRtsBroadcastWorld/participant_0_unit_blue_1"):
		_fail("dead authority unit respawned after presentation removal")
		return
	var snapshot := scene.snapshot_copy()
	if snapshot != {
		"participant_id": "broadcast",
		"task_id": "rts-skirmish-v0",
		"observation_seq": 11,
		"tick": 110,
	}:
		_fail("public camera snapshot contains unexpected presentation data")
		return
	if JSON.stringify(snapshot).contains("private") or JSON.stringify(snapshot).contains("hidden"):
		_fail("public camera snapshot leaked source data")
		return
	var camera_before: Vector3 = scene._camera_position
	scene.begin_cinematic_outro()
	scene._process(1.0)
	if not scene._outro_active or scene._camera_position == camera_before:
		_fail("victory outro camera did not begin its deterministic orbit")
		return
	print("RTS_SKIRMISH_BROADCAST_OK")
	quit(0)


func _sources() -> Dictionary:
	return {
		"participant_0": _source("participant_0", -7600, "private_blue_note"),
		"participant_1": _source("participant_1", 7600, "private_red_note"),
	}


func _source(participant_id: String, x: int, private_field: String) -> Dictionary:
	return {
		"participant_id": participant_id,
		"public_phase": "Economy",
		"public_objective": "Return supplies and build the force.",
		"recent_events": [{"type": "material_deposited", "public_summary": "material_deposited"}],
		"units": [
			{"unit_id": "blue_0" if participant_id == "participant_0" else "red_0", "position_mt": {"x": x, "y": 4400}, "heading": 4, "health_percent": 82, "alive": true, "role": "worker", "animation_state": "gather", "intent": "Harvest Tree 0", "carrying": "wood"},
			{"unit_id": "blue_1" if participant_id == "participant_0" else "red_1", "position_mt": {"x": x + 450, "y": 4000}, "heading": 3, "health_percent": 100, "alive": true, "role": "worker", "animation_state": "walk", "intent": "Returning ore", "carrying": "ore"},
		],
		"own": {
			"town_hall": {"position_mt": {"x": x, "y": 6500}, "state": "intact"},
			"barracks": {"position_mt": {"x": x + 1000, "y": 5600}, "state": "active"},
			"tower": {"position_mt": {"x": x - 900, "y": 5200}, "state": "active"}, "resources": {"wood": 2, "ore": 1},
		},
		"visible_entities": [
			{"id": "central", "kind": "central_beacon", "position_mt": {"x": 0, "y": 0}, "state": "contested"},
			{"id": "tree_0", "kind": "resource_wood", "position_mt": {"x": int(x / 2), "y": 1900}, "state": "available"},
			{"id": "ignored_%s" % participant_id, "kind": "operator", "position_mt": {"x": 0, "y": 0}, "hidden": true},
		],
	}


func _fail(message: String) -> void:
	push_error("RTS_SKIRMISH_BROADCAST_FAILED: %s" % message)
	quit(1)
