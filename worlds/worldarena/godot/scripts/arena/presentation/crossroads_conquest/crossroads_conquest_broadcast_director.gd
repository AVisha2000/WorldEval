class_name CrossroadsConquestBroadcastDirector
extends RefCounted

## Editorially maps one sealed Crossroads Conquest authority trace onto an exact
## three-minute broadcast.  The director never changes a snapshot or invents a
## result: every gameplay chapter is anchored to a real public authority event.

const REPLAY_SCHEMA := "worldarena/crossroads-conquest-replay/1"
const SHOWCASE_ID := "crossroads-conquest-v0"
const POLICY_ID := "crossroads-conquest-demo-v1"
const MAP_ID := "tri_13_v1"
const PROTOCOL := "world-arena/0.4"
const RULES_ID := "arena-v0.4"
const SEED := 424242
const DURATION_SECONDS := 180.0
const CAPTURE_FPS := 30
const TOTAL_FRAMES := 5400
const CAMERA_TRANSITION_MIN_SECONDS := 0.8
const CAMERA_TRANSITION_MAX_SECONDS := 1.5
const MINIMUM_SHOT_HOLD_SECONDS := 4.0

## The fixed boundaries are the public edit.  ``at_seconds`` in the sealed
## timeline may move within its assigned window, but the on-screen transition
## remains exact.  This tolerates small authority-round shifts without allowing
## a packager to silently move a required story event to another chapter.
const BEATS := [
	{"id": "opening_reveal", "start": 0.0, "end": 12.0, "shot": "overview", "focus": "overview", "transition": 1.2, "title": "LAST STRONGHOLD STANDING", "subtitle": "CROSSROADS CRYSTAL → SIEGE", "accent": "neutral", "event": false},
	{"id": "sol_introduction", "start": 12.0, "end": 19.0, "shot": "stronghold_close", "focus": "core_sol", "transition": 1.0, "title": "SOL △", "subtitle": "SCALE FAST · BUILD SIEGE · BREAK TERRA", "accent": "sol", "event": false},
	{"id": "terra_introduction", "start": 19.0, "end": 26.0, "shot": "stronghold_close", "focus": "core_terra", "transition": 1.0, "title": "TERRA □", "subtitle": "TAKE THE CENTER · FORTIFY · COUNTERPUNCH", "accent": "terra", "event": false},
	{"id": "luna_introduction", "start": 26.0, "end": 33.0, "shot": "stronghold_close", "focus": "core_luna", "transition": 1.0, "title": "LUNA ○", "subtitle": "SCOUT · PRESERVE · STRIKE LAST", "accent": "luna", "event": false},
	{"id": "terra_claims_crossroads", "start": 33.0, "end": 44.0, "shot": "battle_medium", "focus": "crossroads", "transition": 1.2, "title": "TERRA CLAIMS THE CENTER", "subtitle": "Two completed capture ticks raise Terra's flag.", "accent": "terra", "event": true},
	{"id": "sol_prepares_assault", "start": 44.0, "end": 55.0, "shot": "stronghold_close", "focus": "home_sol", "transition": 1.0, "title": "SOL BUILDS THE ANSWER", "subtitle": "Workshop · Fieldcraft · Ironworking · guards", "accent": "sol", "event": true},
	{"id": "luna_observes", "start": 55.0, "end": 65.0, "shot": "battle_medium", "focus": "crossroads", "transition": 1.0, "title": "NO ATTACK YET", "subtitle": "Luna's scout watches. The reserve stays fresh.", "accent": "luna", "event": true},
	{"id": "crossroads_clash", "start": 65.0, "end": 78.0, "shot": "battle_medium", "focus": "crossroads", "transition": 0.9, "title": "THE CROSSROADS ERUPTS", "subtitle": "Terra's outpost absorbs Sol's opening assault.", "accent": "neutral", "event": true},
	{"id": "sol_takes_crossroads", "start": 78.0, "end": 90.0, "shot": "battle_medium", "focus": "crossroads", "transition": 0.9, "title": "SOL TAKES THE CENTER", "subtitle": "Crystal secured. Real siege production completes.", "accent": "sol", "event": true},
	{"id": "two_front_march", "start": 90.0, "end": 102.0, "shot": "two_front_wide", "focus": "north_fronts", "transition": 1.4, "title": "TWO FRONTS OPEN", "subtitle": "Sol marches east. Terra slips a counterforce north.", "accent": "neutral", "event": true},
	{"id": "terra_counterpunch", "start": 102.0, "end": 114.0, "shot": "stronghold_close", "focus": "core_sol", "transition": 1.0, "title": "TERRA'S COUNTERPUNCH LANDS", "subtitle": "Sol's outer defense falls. The exposed core buckles.", "accent": "terra", "event": true},
	{"id": "sol_breaches_terra", "start": 114.0, "end": 126.0, "shot": "stronghold_close", "focus": "core_terra", "transition": 1.0, "title": "SOL BREACHES TERRA", "subtitle": "Outpost · wall · tower · core", "accent": "sol", "event": true},
	{"id": "terra_eliminated", "start": 126.0, "end": 137.0, "shot": "stronghold_close", "focus": "core_terra", "transition": 0.8, "title": "TERRA ELIMINATED", "subtitle": "Sol gets the stronghold kill. Two factions remain.", "accent": "terra", "event": true},
	{"id": "exposed_sol_overview", "start": 137.0, "end": 146.0, "shot": "two_front_wide", "focus": "overview", "transition": 1.3, "title": "ONE ARMY FAR EAST", "subtitle": "Sol is depleted. Luna is fresh. The core is near 27%.", "accent": "neutral", "event": true},
	{"id": "luna_strikes", "start": 146.0, "end": 158.0, "shot": "battle_medium", "focus": "home_sol", "transition": 1.0, "title": "LUNA STRIKES", "subtitle": "Only after Terra falls does Luna cross the border.", "accent": "luna", "event": true},
	{"id": "sol_eliminated", "start": 158.0, "end": 169.0, "shot": "stronghold_close", "focus": "core_sol", "transition": 0.8, "title": "SOL'S CORE FALLS", "subtitle": "The eastern army cannot return in time.", "accent": "luna", "event": true},
	{"id": "verified_result", "start": 169.0, "end": 180.0, "shot": "overview", "focus": "overview", "transition": 1.2, "title": "LUNA WINS", "subtitle": "Sol eliminated Terra · Luna eliminated Sol", "accent": "luna", "event": true},
]

const INTENTS := {
	"opening_reveal": {"sol": "ECONOMY", "terra": "ECONOMY", "luna": "SCOUT"},
	"sol_introduction": {"sol": "SCALE FAST", "terra": "GATHER", "luna": "SCOUT"},
	"terra_introduction": {"sol": "GATHER", "terra": "TAKE CENTER", "luna": "SCOUT"},
	"luna_introduction": {"sol": "PREPARE", "terra": "CAPTURE", "luna": "PRESERVE"},
	"terra_claims_crossroads": {"sol": "TECH UP", "terra": "HOLD CENTER", "luna": "OBSERVE"},
	"sol_prepares_assault": {"sol": "BUILD GUARDS", "terra": "FORTIFY", "luna": "PRESERVE"},
	"luna_observes": {"sol": "MARCH", "terra": "DEFEND", "luna": "NO ATTACK"},
	"crossroads_clash": {"sol": "BREAK GARRISON", "terra": "HOLD CENTER", "luna": "OBSERVE"},
	"sol_takes_crossroads": {"sol": "MINE CRYSTAL", "terra": "RETREAT", "luna": "RESERVE"},
	"two_front_march": {"sol": "MARCH EAST", "terra": "COUNTER-RAID", "luna": "HOLD"},
	"terra_counterpunch": {"sol": "SIEGE TERRA", "terra": "DAMAGE CORE", "luna": "HOLD"},
	"sol_breaches_terra": {"sol": "BREACH CORE", "terra": "FINAL DEFENSE", "luna": "STAGE WEST"},
	"terra_eliminated": {"sol": "SECURE KILL", "terra": "ELIMINATED", "luna": "CONFIRM"},
	"exposed_sol_overview": {"sol": "REPAIR", "terra": "ELIMINATED", "luna": "READY"},
	"luna_strikes": {"sol": "HOLD HOME", "terra": "ELIMINATED", "luna": "ATTACK"},
	"sol_eliminated": {"sol": "ELIMINATED", "terra": "ELIMINATED", "luna": "BREAK CORE"},
	"verified_result": {"sol": "SECOND", "terra": "THIRD", "luna": "WINNER"},
}

var _replay: Dictionary = {}
var _frames: Array[Dictionary] = []
var _events_by_id: Dictionary = {}
var _event_frame_by_id: Dictionary = {}
var _timeline_by_beat: Dictionary = {}
var _anchors: Array[int] = []
var _error := ""


func configure_replay(replay: Dictionary) -> Dictionary:
	_reset()
	var shape_error := _validate_replay_shape(replay)
	if not shape_error.is_empty():
		return _refuse(shape_error)
	_replay = replay.duplicate(true)
	_frames = _flatten_frames(replay)
	var frame_error := _index_public_events()
	if not frame_error.is_empty():
		return _refuse(frame_error)
	var timeline_error := _validate_timeline(replay.public_timeline)
	if not timeline_error.is_empty():
		return _refuse(timeline_error)
	var story_error := _validate_terminal_story()
	if not story_error.is_empty():
		return _refuse(story_error)
	return status()


func status() -> Dictionary:
	return {
		"ok": _error.is_empty() and not _replay.is_empty(),
		"error": _error,
		"duration_seconds": DURATION_SECONDS,
		"fps": CAPTURE_FPS,
		"total_frames": TOTAL_FRAMES,
		"authority_frames": _frames.size(),
		"beat_count": BEATS.size(),
	}


func replay_copy() -> Dictionary:
	return _replay.duplicate(true)


func beat_at(seconds: float) -> Dictionary:
	var clamped := clampf(seconds, 0.0, DURATION_SECONDS - 0.000001)
	for value: Variant in BEATS:
		var beat: Dictionary = value
		if clamped >= float(beat.start) and clamped < float(beat.end):
			return beat.duplicate(true)
	return (BEATS[-1] as Dictionary).duplicate(true)


func beat_elapsed(seconds: float) -> float:
	var beat := beat_at(seconds)
	return clampf(seconds - float(beat.start), 0.0, float(beat.end) - float(beat.start))


func intents_at(seconds: float) -> Dictionary:
	var beat_id := str(beat_at(seconds).id)
	return (INTENTS.get(beat_id, {}) as Dictionary).duplicate(true)


func sample_at(seconds: float) -> Dictionary:
	if _frames.is_empty() or not _error.is_empty():
		return {}
	var beat_index := _beat_index(seconds)
	var beat: Dictionary = BEATS[beat_index]
	var first_index := _anchors[beat_index]
	var next_index := first_index
	if beat_index + 1 < _anchors.size():
		next_index = _anchors[beat_index + 1]
	var span := maxf(0.001, float(beat.end) - float(beat.start))
	var progress := clampf((seconds - float(beat.start)) / span, 0.0, 1.0)
	var authority_position := lerpf(float(first_index), float(next_index), _smoothstep(progress))
	var from_index := clampi(int(floor(authority_position)), 0, _frames.size() - 1)
	var to_index := clampi(from_index + 1, 0, _frames.size() - 1)
	return {
		"beat": beat.duplicate(true),
		"beat_index": beat_index,
		"beat_elapsed": clampf(seconds - float(beat.start), 0.0, span),
		"from_frame": _frames[from_index].duplicate(true),
		"to_frame": _frames[to_index].duplicate(true),
		"alpha": authority_position - float(from_index),
		"broadcast_seconds": clampf(seconds, 0.0, DURATION_SECONDS),
		"timeline": (_timeline_by_beat.get(str(beat.id), {}) as Dictionary).duplicate(true),
	}


func public_event_for_beat(beat_id: String) -> Dictionary:
	var timeline: Dictionary = _timeline_by_beat.get(beat_id, {})
	var event_id := str(timeline.get("event_id", ""))
	return (_events_by_id.get(event_id, {}) as Dictionary).duplicate(true)


func _validate_replay_shape(replay: Dictionary) -> String:
	var schema := str(replay.get("schema", replay.get("schema_version", "")))
	if schema != REPLAY_SCHEMA:
		return "crossroads_replay_schema_invalid"
	if replay.get("showcase_id") != SHOWCASE_ID:
		return "crossroads_replay_showcase_invalid"
	if replay.get("protocol") != PROTOCOL or replay.get("map_id") != MAP_ID \
			or replay.get("rules_id") != RULES_ID:
		return "crossroads_replay_authority_binding_invalid"
	if typeof(replay.get("seed")) != TYPE_INT or int(replay.seed) != SEED:
		return "crossroads_replay_seed_invalid"
	var policy: Variant = replay.get("policy")
	if not policy is Dictionary or policy.get("id") != POLICY_ID or not _is_sha256(str(policy.get("sha256", ""))):
		return "crossroads_replay_policy_invalid"
	if typeof(replay.get("duration_seconds")) not in [TYPE_INT, TYPE_FLOAT] \
			or not is_equal_approx(float(replay.duration_seconds), DURATION_SECONDS):
		return "crossroads_replay_duration_invalid"
	var authority: Variant = replay.get("authority")
	if not authority is Dictionary or not _is_sha256(str(authority.get("normalized_trace_sha256", ""))) \
			or not _is_sha256(str(authority.get("final_state_sha256", ""))):
		return "crossroads_replay_authority_hash_invalid"
	if typeof(authority.get("completed_rounds")) != TYPE_INT or int(authority.completed_rounds) < 1 \
			or int(authority.completed_rounds) > 29:
		return "crossroads_replay_round_count_invalid"
	if not replay.get("initial_snapshot") is Dictionary or not replay.get("rounds") is Array \
			or replay.rounds.is_empty() or not replay.get("events") is Array \
			or not replay.get("public_timeline") is Array:
		return "crossroads_replay_shape_invalid"
	var frames := _flatten_frames(replay)
	if frames.size() < 2:
		return "crossroads_replay_frames_invalid"
	var previous_tick := -1
	for frame_index: int in frames.size():
		var frame: Dictionary = frames[frame_index]
		if typeof(frame.get("tick")) != TYPE_INT or int(frame.tick) < previous_tick \
				or not frame.get("snapshot") is Dictionary or not frame.get("events") is Array:
			return "crossroads_replay_frame_invalid"
		previous_tick = int(frame.tick)
	return ""


func _flatten_frames(replay: Dictionary) -> Array[Dictionary]:
	var frames: Array[Dictionary] = []
	for raw_round: Variant in replay.get("rounds", []):
		if not raw_round is Dictionary or not raw_round.get("frames") is Array:
			continue
		for raw_frame: Variant in raw_round.frames:
			if raw_frame is Dictionary:
				frames.append(raw_frame.duplicate(true))
	frames.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("tick", -1)) != int(b.get("tick", -1)):
			return int(a.get("tick", -1)) < int(b.get("tick", -1))
		return int(a.get("index", -1)) < int(b.get("index", -1))
	)
	return frames


func _index_public_events() -> String:
	var top_level_ids := {}
	for raw: Variant in _replay.get("events", []):
		if not raw is Dictionary:
			return "crossroads_replay_event_invalid"
		var event: Dictionary = raw
		var event_id := str(event.get("event_id", ""))
		if event_id.is_empty() or top_level_ids.has(event_id):
			return "crossroads_replay_event_id_invalid"
		top_level_ids[event_id] = true
		_events_by_id[event_id] = event.duplicate(true)
	for frame_index: int in _frames.size():
		for raw: Variant in _frames[frame_index].get("events", []):
			if not raw is Dictionary:
				return "crossroads_replay_frame_event_invalid"
			var event: Dictionary = raw
			var event_id := str(event.get("event_id", ""))
			if event_id.is_empty():
				return "crossroads_replay_event_id_invalid"
			if _events_by_id.has(event_id) and _events_by_id[event_id] != event:
				return "crossroads_replay_event_mismatch"
			_events_by_id[event_id] = event.duplicate(true)
			_event_frame_by_id[event_id] = frame_index
	for event_id: String in _events_by_id:
		if not _event_frame_by_id.has(event_id):
			return "crossroads_replay_event_unframed"
	return ""


func _validate_timeline(value: Array) -> String:
	if value.size() != BEATS.size():
		return "crossroads_timeline_beat_count_invalid"
	var previous_time := -1.0
	var previous_anchor := -1
	for beat_index: int in BEATS.size():
		var raw: Variant = value[beat_index]
		if not raw is Dictionary:
			return "crossroads_timeline_entry_invalid"
		var timeline: Dictionary = raw
		var expected: Dictionary = BEATS[beat_index]
		var beat_id := str(timeline.get("beat_id", timeline.get("id", "")))
		var at_value: Variant = timeline.get("at_seconds")
		if beat_id != str(expected.id) or typeof(at_value) not in [TYPE_INT, TYPE_FLOAT]:
			return "crossroads_timeline_identity_invalid"
		var at_seconds := float(at_value)
		if at_seconds < float(expected.start) or at_seconds >= float(expected.end) \
				or at_seconds < previous_time:
			return "crossroads_timeline_window_invalid"
		previous_time = at_seconds
		var event_id := str(timeline.get("event_id", ""))
		var anchor := 0
		if bool(expected.event):
			if event_id.is_empty() or not _events_by_id.has(event_id):
				return "crossroads_timeline_event_missing"
			anchor = int(_event_frame_by_id[event_id])
			# The package validator owns semantic event acceptance.  The renderer only
			# requires a sealed, framed authority event for each editorial anchor.
		else:
			if not event_id.is_empty():
				if not _events_by_id.has(event_id):
					return "crossroads_timeline_event_missing"
				anchor = int(_event_frame_by_id[event_id])
			elif not bool(timeline.get("editorial", false)):
				return "crossroads_timeline_editorial_marker_invalid"
		if timeline.has("frame_index"):
			if typeof(timeline.frame_index) != TYPE_INT or int(timeline.frame_index) != anchor:
				return "crossroads_timeline_frame_binding_invalid"
		# Editorial chapters may revisit an earlier witnessed action (for example,
		# Luna's scout view after the Sol prep card).  The public event remains
		# authoritative; presentation time is intentionally independent of tick order.
		previous_anchor = max(previous_anchor, anchor)
		_timeline_by_beat[beat_id] = timeline.duplicate(true)
		_anchors.append(anchor)
	for beat_index: int in BEATS.size():
		var beat: Dictionary = BEATS[beat_index]
		if float(beat.end) - float(beat.start) < MINIMUM_SHOT_HOLD_SECONDS:
			return "crossroads_timeline_shot_too_short"
		if float(beat.transition) < CAMERA_TRANSITION_MIN_SECONDS \
				or float(beat.transition) > CAMERA_TRANSITION_MAX_SECONDS:
			return "crossroads_timeline_camera_transition_invalid"
	return ""


func _event_matches_beat(beat_id: String, event: Dictionary) -> bool:
	var kind := str(event.get("kind", event.get("type", ""))).to_lower()
	var faction := str(_field(event, "faction", _field(event, "attacker_id", ""))).to_lower()
	var victim := str(_field(event, "victim_id", _field(event, "owner", ""))).to_lower()
	var destroyed_by := str(_field(event, "destroyed_by", _field(event, "attacker_id", faction))).to_lower()
	var district := str(_field(event, "district", _field(event, "district_id", ""))).to_lower()
	match beat_id:
		"terra_claims_crossroads":
			return kind in ["capture_ready", "district_captured"] and faction == "terra" and district == "crossroads"
		"sol_prepares_assault":
			return faction == "sol" and kind in ["research_completed", "task_completed", "structure_built", "unit_trained", "train_completed"]
		"luna_observes":
			return faction == "luna" and kind in ["unit_moved", "think_recorded", "task_started", "task_completed"]
		"crossroads_clash":
			return kind in ["combat", "combat_started", "unit_damaged", "unit_hit", "structure_damaged", "order_started"] and (district == "crossroads" or _targets(event).has("crossroads"))
		"sol_takes_crossroads":
			return kind in ["capture_ready", "district_captured"] and faction == "sol" and district == "crossroads"
		"two_front_march":
			return kind == "unit_moved" and faction in ["sol", "terra"]
		"terra_counterpunch":
			return kind == "core_damaged" and (victim == "sol" or faction == "sol") and str(_field(event, "attacker_id", destroyed_by)).to_lower() == "terra"
		"sol_breaches_terra":
			return (kind == "structure_destroyed" and victim == "terra" and destroyed_by == "sol") \
				or (kind == "core_damaged" and (victim == "terra" or faction == "terra") and str(_field(event, "attacker_id", destroyed_by)).to_lower() == "sol")
		"terra_eliminated", "exposed_sol_overview":
			return kind == "core_destroyed" and victim == "terra" and destroyed_by == "sol"
		"luna_strikes":
			var action := str(_field(event, "action", _field(event, "order", ""))).to_lower()
			return faction == "luna" and (kind in ["attack_started", "hostile_order", "order_started"]) \
				and (action in ["", "attack"] or action.contains("attack"))
		"sol_eliminated":
			return kind == "core_destroyed" and victim == "sol" and destroyed_by == "luna"
		"verified_result":
			return (kind == "core_destroyed" and victim == "sol" and destroyed_by == "luna") \
				or kind in ["match_completed", "conquest_completed", "match_ended"]
	return false


func _validate_terminal_story() -> String:
	var result: Variant = _replay.get("result")
	if not result is Dictionary or str(result.get("winner", "")).to_lower() != "luna":
		return "crossroads_result_winner_invalid"
	if result.get("placements") != ["luna", "sol", "terra"] \
			or result.get("elimination_order") != ["terra", "sol"]:
		return "crossroads_result_placement_invalid"
	var terra_event := public_event_for_beat("terra_eliminated")
	var sol_event := public_event_for_beat("sol_eliminated")
	if terra_event.is_empty() or sol_event.is_empty() or int(terra_event.get("tick", -1)) >= int(sol_event.get("tick", -1)):
		return "crossroads_result_elimination_order_invalid"
	var luna_strike := public_event_for_beat("luna_strikes")
	if luna_strike.is_empty() or int(luna_strike.get("tick", -1)) <= int(terra_event.get("tick", -1)):
		return "crossroads_result_luna_attack_timing_invalid"
	var final_snapshot: Dictionary = _frames[-1].get("snapshot", {})
	var factions: Variant = final_snapshot.get("factions")
	if not factions is Dictionary:
		return "crossroads_result_final_state_invalid"
	for faction: String in ["sol", "terra", "luna"]:
		if not factions.get(faction) is Dictionary:
			return "crossroads_result_final_state_invalid"
	if not bool(factions.sol.get("eliminated", false)) or not bool(factions.terra.get("eliminated", false)) \
			or bool(factions.luna.get("eliminated", true)):
		return "crossroads_result_survivor_invalid"
	var final_hash := str(_replay.authority.final_state_sha256)
	var snapshot_hash := str(final_snapshot.get("match", {}).get("state_hash", ""))
	if not snapshot_hash.is_empty() and snapshot_hash != final_hash:
		return "crossroads_result_final_hash_invalid"
	return ""


func _field(event: Dictionary, key: String, fallback: Variant = "") -> Variant:
	if event.has(key):
		return event[key]
	var payload: Variant = event.get("payload")
	if payload is Dictionary and payload.has(key):
		return payload[key]
	var data: Variant = event.get("data")
	if data is Dictionary and data.has(key):
		return data[key]
	return fallback


func _targets(event: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for value: Variant in event.get("target_ids", []):
		result.append(str(value).to_lower())
	return result


func _beat_index(seconds: float) -> int:
	var clamped := clampf(seconds, 0.0, DURATION_SECONDS - 0.000001)
	for index: int in BEATS.size():
		if clamped >= float(BEATS[index].start) and clamped < float(BEATS[index].end):
			return index
	return BEATS.size() - 1


func _smoothstep(value: float) -> float:
	var clamped := clampf(value, 0.0, 1.0)
	return clamped * clamped * (3.0 - 2.0 * clamped)


func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _refuse(code: String) -> Dictionary:
	_error = code
	_replay.clear()
	_frames.clear()
	_events_by_id.clear()
	_event_frame_by_id.clear()
	_timeline_by_beat.clear()
	_anchors.clear()
	return status()


func _reset() -> void:
	_replay.clear()
	_frames.clear()
	_events_by_id.clear()
	_event_frame_by_id.clear()
	_timeline_by_beat.clear()
	_anchors.clear()
	_error = ""
