extends SceneTree

const Director := preload(
	"res://scripts/arena/presentation/crossroads_conquest/crossroads_conquest_broadcast_director.gd"
)
const BroadcastScene := preload(
	"res://scripts/arena/presentation/crossroads_conquest/crossroads_conquest_broadcast_scene.gd"
)


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var replay := _fixture()
	var director := Director.new()
	var status: Dictionary = director.configure_replay(replay)
	if not bool(status.get("ok", false)):
		_fail("valid fixture refused: %s" % str(status.get("error", "")))
		return
	if status.duration_seconds != 180.0 or status.fps != 30 or status.total_frames != 5400 \
			or status.beat_count != 17:
		_fail("exact broadcast profile drifted")
		return
	for probe: Array in [[0.0, "opening_reveal"], [33.0, "terra_claims_crossroads"], [126.0, "terra_eliminated"], [146.0, "luna_strikes"], [169.0, "verified_result"]]:
		if director.beat_at(float(probe[0])).id != probe[1]:
			_fail("broadcast chapter boundary drifted at %s" % str(probe[0]))
			return
	var malformed := replay.duplicate(true)
	malformed.public_timeline[4]["at_seconds"] = 44.0
	if bool(Director.new().configure_replay(malformed).get("ok", true)):
		_fail("out-of-window authority event was accepted")
		return
	var swapped := replay.duplicate(true)
	swapped.public_timeline[13]["event_id"] = "event.luna.strike"
	if bool(Director.new().configure_replay(swapped).get("ok", true)):
		_fail("wrong semantic event binding was accepted")
		return
	var scene := BroadcastScene.new()
	root.add_child(scene)
	await process_frame
	status = scene.configure_replay(replay)
	if not bool(status.get("ok", false)):
		_fail("scene refused the verified fixture: %s" % str(status.get("error", "")))
		return
	if not scene.apply_broadcast_time_msec(33000) or scene.active_beat_id() != "terra_claims_crossroads":
		_fail("scene did not apply the Terra capture chapter")
		return
	var hud := scene.get_node_or_null("CrossroadsBroadcastHud/SafePublicOverlay")
	if hud == null or hud.get_node_or_null("SolFactionChip") == null \
			or hud.get_node_or_null("LunaFactionChip") == null \
			or hud.get_node_or_null("TerraFactionChip") == null \
			or hud.get_node_or_null("CrossroadsIndicator") == null \
			or hud.get_node_or_null("VerifiedReplayBadge") == null:
		_fail("compact public HUD is incomplete")
		return
	if scene.get_node_or_null("CrossroadsBroadcastHud/SafePublicOverlay/ControlDeck") != null \
			or scene.get_node_or_null("CrossroadsBroadcastHud/SafePublicOverlay/Chronicle") != null \
			or scene.get_node_or_null("CrossroadsBroadcastHud/SafePublicOverlay/UnverifiedBanner") != null:
		_fail("legacy broadcast chrome leaked into the scene")
		return
	if not scene.apply_broadcast_time_msec(126000) or scene.get_node("CrossroadsBroadcastHud/SafePublicOverlay/VerifiedResultCard").visible:
		_fail("winner card appeared while Sol remained alive")
		return
	if not scene.apply_broadcast_time_msec(169000) or not scene.get_node("CrossroadsBroadcastHud/SafePublicOverlay/VerifiedResultCard").visible:
		_fail("verified winner card did not appear after both eliminations")
		return
	var snapshot := scene.snapshot_copy()
	if snapshot != {"showcase_id": "crossroads-conquest-v0", "broadcast_msec": 169000, "beat_id": "verified_result", "configured": true}:
		_fail("broadcast scene exposed unexpected replay data")
		return
	print("CROSSROADS_CONQUEST_BROADCAST_OK")
	quit(0)


func _fixture() -> Dictionary:
	var event_specs := [
		["event.terra.capture", "district_captured", "terra", {"district": "crossroads"}],
		["event.sol.prep", "research_completed", "sol", {"technology_id": "ironworking"}],
		["event.luna.observe", "unit_moved", "luna", {"district": "crossroads"}],
		["event.center.clash", "combat_started", "sol", {"district": "crossroads"}],
		["event.sol.capture", "district_captured", "sol", {"district": "crossroads"}],
		["event.two.front", "unit_moved", "terra", {"district": "wild_st"}],
		["event.counter", "core_damaged", "sol", {"victim_id": "sol", "attacker_id": "terra", "remaining_hp": 260}],
		["event.breach", "structure_destroyed", "sol", {"victim_id": "terra", "owner": "terra", "destroyed_by": "sol"}],
		["event.terra.falls", "core_destroyed", "sol", {"victim_id": "terra", "destroyed_by": "sol"}],
		["event.luna.strike", "order_started", "luna", {"action": "Attack", "target_id": "core_sol"}],
		["event.sol.falls", "core_destroyed", "luna", {"victim_id": "sol", "destroyed_by": "luna"}],
	]
	var events: Array = []
	var frames: Array = []
	for index: int in event_specs.size() + 1:
		var frame_events: Array = []
		if index > 0:
			var spec: Array = event_specs[index - 1]
			var event := {
				"event_id": spec[0], "kind": spec[1], "type": spec[1], "faction": spec[2],
				"round": index, "tick": index * 150, "actor_id": spec[2], "target_ids": [],
			}
			for key: String in spec[3]:
				event[key] = spec[3][key]
			events.append(event)
			frame_events.append(event)
		frames.append({
			"index": index, "round": maxi(1, index), "tick": index * 150,
			"round_tick": 150 if index > 0 else 0,
			"snapshot": _snapshot(index), "events": frame_events,
		})
	var event_ids := ["", "", "", "", "event.terra.capture", "event.sol.prep", "event.luna.observe", "event.center.clash", "event.sol.capture", "event.two.front", "event.counter", "event.breach", "event.terra.falls", "event.terra.falls", "event.luna.strike", "event.sol.falls", "event.sol.falls"]
	var event_frames := {"event.terra.capture": 1, "event.sol.prep": 2, "event.luna.observe": 3, "event.center.clash": 4, "event.sol.capture": 5, "event.two.front": 6, "event.counter": 7, "event.breach": 8, "event.terra.falls": 9, "event.luna.strike": 10, "event.sol.falls": 11}
	var timeline: Array = []
	for index: int in Director.BEATS.size():
		var beat: Dictionary = Director.BEATS[index]
		var entry := {"beat_id": beat.id, "at_seconds": beat.start, "event_id": event_ids[index]}
		if event_ids[index].is_empty():
			entry["editorial"] = true
		else:
			entry["frame_index"] = event_frames[event_ids[index]]
		timeline.append(entry)
	return {
		"schema": "worldarena/crossroads-conquest-replay/1",
		"showcase_id": "crossroads-conquest-v0",
		"protocol": "world-arena/0.4",
		"map_id": "tri_13_v1",
		"rules_id": "arena-v0.4",
		"seed": 424242,
		"policy": {"id": "crossroads-conquest-demo-v1", "sha256": "a".repeat(64)},
		"duration_seconds": 180,
		"authority": {"completed_rounds": 11, "normalized_trace_sha256": "b".repeat(64), "final_state_sha256": "c".repeat(64)},
		"initial_snapshot": _snapshot(0),
		"rounds": [{"round": 1, "plans": {"sol": [], "terra": [], "luna": []}, "frames": frames}],
		"events": events,
		"result": {"winner": "luna", "placements": ["luna", "sol", "terra"], "elimination_order": ["terra", "sol"]},
		"public_timeline": timeline,
	}


func _snapshot(index: int) -> Dictionary:
	var terra_eliminated := index >= 9
	var sol_eliminated := index >= 11
	var ended := sol_eliminated
	var owner: Variant = null
	if index >= 1 and index < 5: owner = "terra"
	if index >= 5: owner = "sol"
	return {
		"match": {"round": maxi(1, index), "tick": index * 150, "ended": ended, "winner": "luna" if ended else "", "state_hash": ""},
		"factions": {
			"sol": {"id": "sol", "core_hp": 0.0 if sol_eliminated else 260.0 if index >= 7 else 900.0, "eliminated": sol_eliminated, "stockpile": {"crystal": 22 if index >= 5 else 0}},
			"luna": {"id": "luna", "core_hp": 900.0, "eliminated": false, "stockpile": {"crystal": 0}},
			"terra": {"id": "terra", "core_hp": 0.0 if terra_eliminated else 900.0, "eliminated": terra_eliminated, "stockpile": {"crystal": 18 if index >= 1 else 0}},
		},
		"districts": {
			"core_sol": {"id": "core_sol", "owner": "sol", "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"home_sol": {"id": "home_sol", "owner": "sol", "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 1 if index >= 7 else 0},
			"core_terra": {"id": "core_terra", "owner": "terra", "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"home_terra": {"id": "home_terra", "owner": "terra", "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"core_luna": {"id": "core_luna", "owner": "luna", "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"home_luna": {"id": "home_luna", "owner": "luna", "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"mine_st": {"id": "mine_st", "owner": "sol", "capture": {"faction": null, "progress": 2}, "unsupplied_rounds": 0},
			"mine_tl": {"id": "mine_tl", "owner": "terra", "capture": {"faction": null, "progress": 2}, "unsupplied_rounds": 0},
			"mine_ls": {"id": "mine_ls", "owner": "luna", "capture": {"faction": null, "progress": 2}, "unsupplied_rounds": 0},
			"wild_st": {"id": "wild_st", "owner": null, "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"wild_tl": {"id": "wild_tl", "owner": null, "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"wild_ls": {"id": "wild_ls", "owner": null, "capture": {"faction": null, "progress": 0}, "unsupplied_rounds": 0},
			"crossroads": {"id": "crossroads", "owner": owner, "capture": {"faction": owner, "progress": 2 if owner != null else 0}, "unsupplied_rounds": 0},
		},
		"units": {
			"sol_commander": {"id": "sol_commander", "faction": "sol", "kind": "commander", "hp": 120.0, "district": "core_terra" if index >= 8 else "crossroads" if index >= 4 else "home_sol", "attack_target": "core_terra" if index >= 8 and index < 9 else ""},
			"sol_siege": {"id": "sol_siege", "faction": "sol", "kind": "siege", "hp": 84.0, "district": "core_terra" if index >= 8 else "crossroads", "attack_target": "core_terra" if index >= 8 and index < 9 else ""},
			"luna_commander": {"id": "luna_commander", "faction": "luna", "kind": "commander", "hp": 150.0, "district": "core_sol" if index >= 10 else "mine_ls", "attack_target": "core_sol" if index >= 10 else ""},
			"terra_commander": {"id": "terra_commander", "faction": "terra", "kind": "commander", "hp": 0.0 if terra_eliminated else 100.0, "district": "core_terra" if index >= 8 else "crossroads", "attack_target": ""},
		},
		"structures": {
			"sol_home_outpost": {"id": "sol_home_outpost", "faction": "sol", "kind": "outpost", "hp": 0.0 if index >= 7 else 240.0, "district": "home_sol"},
			"terra_wall": {"id": "terra_wall", "faction": "terra", "kind": "wall", "hp": 0.0 if index >= 8 else 360.0, "district": "home_terra"},
			"crossroads_mine": {"id": "crossroads_mine", "faction": "sol", "kind": "crystal_mine", "hp": 240.0, "district": "crossroads"},
		},
		"tasks": {},
	}


func _fail(message: String) -> void:
	push_error("CROSSROADS_CONQUEST_BROADCAST_FAILED: %s" % message)
	quit(1)
