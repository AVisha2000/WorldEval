class_name ArenaShowcasePlayer
extends Node

## Deterministic, presentation-only 90-second replay driver. It reads two secret-free
## JSON files, verifies the replay bytes, and calls presentation adapter methods only.
## This class contains no socket, HTTP, provider, or simulation code.

signal verification_changed(label: String, detail: String, verified: bool)
signal cue_dispatched(cue_id: String, cue_kind: String, at_seconds: float)
signal completed

const DURATION_SECONDS := 90.0
const ALLOWED_CUE_KINDS := ["snapshot", "events", "phase", "message", "perspective", "camera", "chapter", "effect", "result"]
const CAMERA_SHOTS := ["overview", "wide", "medium", "close"]
const CHAPTER_ACCENTS := ["sol", "terra", "luna", "neutral"]
const EFFECT_NAMES := ["build", "gather", "combat", "capture", "trade"]
const FORBIDDEN_KEYS := [
	"api_key", "apikey", "authorization", "client_secret", "credential", "credentials",
	"id_token", "openai_api_key", "password", "refresh_token", "secret", "x-api-key",
	"x_api_key", "access_token"
]

var loaded := false
var verified := false
var verification_label := "UNVERIFIED LOCAL DEMO"
var verification_detail := "No showcase is loaded."
var manifest: Dictionary = {}
var replay: Dictionary = {}
var replay_hash := ""
var elapsed_seconds := 0.0
var playing := false
var is_complete := false
var dispatched_cue_count := 0

var _presentation: Node
var _cues: Array[Dictionary] = []
var _next_cue_index := 0
var _result_shown := false


func load_showcase(manifest_path: String) -> Dictionary:
	_reset()
	var manifest_result := _read_json(manifest_path)
	if not bool(manifest_result.ok):
		return _refuse("Manifest refused: %s" % str(manifest_result.error))
	manifest = manifest_result.value
	if not _is_secret_free(manifest):
		return _refuse("Manifest refused because it contains a secret-bearing field or value.")
	if int(manifest.get("schema_version", 0)) != 1:
		return _refuse("Manifest refused: expected schema_version 1.")
	if str(manifest.get("protocol", "")) != "world-arena/0.2":
		return _refuse("Manifest refused: protocol is not world-arena/0.2.")
	var replay_file := str(manifest.get("replay_file", "")).strip_edges()
	if replay_file.is_empty() or replay_file != replay_file.get_file() or replay_file.contains("..") or replay_file.contains(":"):
		return _refuse("Manifest refused: replay_file must name a file beside the manifest.")
	var replay_path := manifest_path.get_base_dir().path_join(replay_file)
	var replay_result := _read_json(replay_path)
	if not bool(replay_result.ok):
		return _refuse("Replay refused: %s" % str(replay_result.error))
	replay = replay_result.value
	if not _is_secret_free(replay):
		return _refuse("Replay refused because it contains a secret-bearing field or value.")
	if int(replay.get("schema_version", 0)) != 1:
		return _refuse("Replay refused: expected schema_version 1.")
	if not is_equal_approx(float(replay.get("duration_seconds", 0.0)), DURATION_SECONDS):
		return _refuse("Replay refused: showcase duration must be exactly 90 seconds.")

	replay_hash = _sha256_file(replay_path)
	var expected_hash := str(manifest.get("replay_sha256", "")).to_lower()
	var supplied_verified := bool(manifest.get("verified", false))
	verified = supplied_verified and _is_sha256(expected_hash) and expected_hash == replay_hash
	if verified:
		verification_label = "VERIFIED MATCH REPLAY"
		verification_detail = "Replay SHA-256 matches %s…%s." % [replay_hash.left(8), replay_hash.right(6)]
	elif supplied_verified and not _is_sha256(expected_hash):
		verification_label = "UNVERIFIED LOCAL DEMO"
		verification_detail = "Verified flag refused: replay_sha256 is missing or malformed."
	elif supplied_verified:
		verification_label = "UNVERIFIED LOCAL DEMO"
		verification_detail = "Verified flag refused: replay SHA-256 does not match the manifest."
	else:
		verification_label = "UNVERIFIED LOCAL DEMO"
		verification_detail = "Manifest does not claim a verified replay."

	var cue_result := _normalize_cues(replay.get("cues", []))
	if not bool(cue_result.ok):
		return _refuse("Replay refused: %s" % str(cue_result.error))
	_cues = cue_result.cues
	loaded = true
	verification_changed.emit(verification_label, verification_detail, verified)
	return get_status()


func start(presentation_node: Node) -> bool:
	if not loaded or presentation_node == null:
		return false
	_presentation = presentation_node
	elapsed_seconds = 0.0
	_next_cue_index = 0
	dispatched_cue_count = 0
	_result_shown = false
	is_complete = false
	playing = true
	_apply_verification_status()
	var initial_snapshot: Variant = replay.get("initial_snapshot", {})
	if initial_snapshot is Dictionary and not initial_snapshot.is_empty() and _presentation.has_method("configure_from_snapshot"):
		_presentation.call("configure_from_snapshot", initial_snapshot.duplicate(true))
	_dispatch_due_cues()
	return true


func advance(delta_seconds: float) -> void:
	if not playing or is_complete:
		return
	elapsed_seconds = minf(DURATION_SECONDS, elapsed_seconds + maxf(0.0, delta_seconds))
	_dispatch_due_cues()
	if elapsed_seconds >= DURATION_SECONDS:
		_finish()


func advance_to(target_seconds: float) -> void:
	if not playing or is_complete:
		return
	var target := clampf(target_seconds, elapsed_seconds, DURATION_SECONDS)
	advance(target - elapsed_seconds)


func play_to_end() -> void:
	advance_to(DURATION_SECONDS)


func get_status() -> Dictionary:
	return {
		"loaded": loaded,
		"verified": verified,
		"label": verification_label,
		"detail": verification_detail,
		"replay_hash": replay_hash,
		"duration_seconds": DURATION_SECONDS,
		"elapsed_seconds": elapsed_seconds,
		"cue_count": _cues.size(),
		"dispatched_cue_count": dispatched_cue_count,
		"complete": is_complete
	}


func _dispatch_due_cues() -> void:
	while _next_cue_index < _cues.size() and float(_cues[_next_cue_index].at) <= elapsed_seconds + 0.0001:
		var cue: Dictionary = _cues[_next_cue_index]
		_next_cue_index += 1
		_dispatch_cue(cue)


func _dispatch_cue(cue: Dictionary) -> void:
	var kind := str(cue.kind)
	match kind:
		"snapshot":
			var snapshot: Variant = cue.get("snapshot", {})
			if snapshot is Dictionary and _presentation.has_method("configure_from_snapshot"):
				_presentation.call("configure_from_snapshot", snapshot.duplicate(true))
		"events":
			var events: Variant = cue.get("events", [])
			if events is Array and _presentation.has_method("apply_events"):
				_presentation.call("apply_events", events.duplicate(true))
		"phase":
			var statuses: Variant = cue.get("statuses", {})
			if not statuses is Dictionary:
				statuses = {}
			if _presentation.has_method("set_phase"):
				_presentation.call("set_phase", str(cue.get("phase", "replay")), statuses.duplicate(true))
		"message":
			var event: Variant = cue.get("event", {})
			if event is Dictionary and _presentation.has_method("show_message"):
				_presentation.call("show_message", event.duplicate(true))
		"perspective":
			if _presentation.has_method("set_perspective"):
				_presentation.call("set_perspective", str(cue.get("perspective_id", "spectator")))
		"camera":
			if _presentation.has_method("focus_world"):
				_presentation.call(
					"focus_world",
					str(cue.get("target_id", "overview")),
					str(cue.get("shot", "medium")),
					float(cue.get("duration", 1.2)),
					cue.get("target_position", null)
				)
		"chapter":
			if _presentation.has_method("show_chapter"):
				_presentation.call(
					"show_chapter",
					str(cue.get("title", "")),
					str(cue.get("subtitle", "")),
					float(cue.get("duration", 3.0)),
					str(cue.get("accent", "neutral"))
				)
		"effect":
			if _presentation.has_method("show_effect"):
				_presentation.call(
					"show_effect",
					str(cue.get("effect", "")),
					str(cue.get("target_id", "")),
					float(cue.get("duration", 1.1)),
					cue.get("target_position", null)
				)
		"result":
			var result: Variant = cue.get("result", replay.get("result", {}))
			if result is Dictionary:
				_show_result(result)
	dispatched_cue_count += 1
	cue_dispatched.emit(str(cue.cue_id), kind, float(cue.at))


func _show_result(value: Dictionary) -> void:
	if _result_shown or not _presentation.has_method("show_match_result"):
		return
	var result := value.duplicate(true)
	result["verified"] = verified
	result["verification_hash"] = replay_hash if verified else ""
	result["verification_label"] = verification_label
	result["verification_detail"] = verification_detail
	result["replay_mode"] = "verified_artifact" if verified else "unverified_local_demo"
	_presentation.call("show_match_result", result)
	_result_shown = true


func _finish() -> void:
	if is_complete:
		return
	var result: Variant = replay.get("result", {})
	if not _result_shown and result is Dictionary and not result.is_empty():
		_show_result(result)
	playing = false
	is_complete = true
	completed.emit()


func _apply_verification_status() -> void:
	if _presentation.has_method("set_showcase_status"):
		_presentation.call("set_showcase_status", verified, verification_label, verification_detail)


func _normalize_cues(value: Variant) -> Dictionary:
	if not value is Array:
		return {"ok": false, "error": "cues must be an array."}
	if value.size() > 512:
		return {"ok": false, "error": "cue count exceeds the 512-cue presentation limit."}
	var normalized: Array[Dictionary] = []
	var cue_ids: Dictionary = {}
	for index in value.size():
		var cue_variant: Variant = value[index]
		if not cue_variant is Dictionary:
			return {"ok": false, "error": "cue %d is not an object." % index}
		var cue: Dictionary = cue_variant.duplicate(true)
		var cue_id := str(cue.get("cue_id", "cue-%03d" % index))
		var kind := str(cue.get("kind", ""))
		var at := float(cue.get("at", -1.0))
		if cue_ids.has(cue_id):
			return {"ok": false, "error": "duplicate cue_id %s." % cue_id}
		if kind not in ALLOWED_CUE_KINDS:
			return {"ok": false, "error": "cue %s uses unsupported kind %s." % [cue_id, kind]}
		if at < 0.0 or at > DURATION_SECONDS:
			return {"ok": false, "error": "cue %s is outside the 90-second timeline." % cue_id}
		if kind == "camera":
			var camera_error := _validate_camera_cue(cue, cue_id)
			if not camera_error.is_empty():
				return {"ok": false, "error": camera_error}
		if kind == "chapter":
			var chapter_error := _validate_chapter_cue(cue, cue_id)
			if not chapter_error.is_empty():
				return {"ok": false, "error": chapter_error}
		if kind == "effect":
			var effect_error := _validate_effect_cue(cue, cue_id)
			if not effect_error.is_empty():
				return {"ok": false, "error": effect_error}
		cue_ids[cue_id] = true
		cue["cue_id"] = cue_id
		cue["kind"] = kind
		cue["at"] = at
		cue["_ordinal"] = index
		normalized.append(cue)
	normalized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a.at), float(b.at)):
			return float(a.at) < float(b.at)
		return int(a._ordinal) < int(b._ordinal)
	)
	return {"ok": true, "cues": normalized}


func _validate_camera_cue(cue: Dictionary, cue_id: String) -> String:
	var shot := str(cue.get("shot", "medium")).to_lower()
	if shot not in CAMERA_SHOTS:
		return "camera cue %s uses unsupported shot %s." % [cue_id, shot]
	var duration := float(cue.get("duration", 1.2))
	if duration < 0.2 or duration > 12.0:
		return "camera cue %s duration must be between 0.2 and 12 seconds." % cue_id
	var target_id := str(cue.get("target_id", "overview")).strip_edges()
	var target_position: Variant = cue.get("target_position", null)
	if target_id.is_empty() and target_position == null:
		return "camera cue %s requires target_id or target_position." % cue_id
	if target_position != null:
		if not target_position is Array or target_position.size() != 3:
			return "camera cue %s target_position must contain exactly three numbers." % cue_id
		for component in target_position:
			if not (component is int or component is float):
				return "camera cue %s target_position must contain only numbers." % cue_id
	return ""


## Chapter cues are intentionally small, short, and presentation-only.  They make
## the authored demo legible without pretending that text is an agent decision.
func _validate_chapter_cue(cue: Dictionary, cue_id: String) -> String:
	var title := str(cue.get("title", "")).strip_edges()
	var subtitle := str(cue.get("subtitle", "")).strip_edges()
	if title.is_empty() or title.length() > 52:
		return "chapter cue %s title must contain 1 to 52 characters." % cue_id
	if subtitle.length() > 140:
		return "chapter cue %s subtitle must contain at most 140 characters." % cue_id
	var duration := float(cue.get("duration", 3.0))
	if duration < 1.5 or duration > 6.0:
		return "chapter cue %s duration must be between 1.5 and 6 seconds." % cue_id
	var accent := str(cue.get("accent", "neutral")).to_lower()
	if accent not in CHAPTER_ACCENTS:
		return "chapter cue %s uses unsupported accent %s." % [cue_id, accent]
	return ""


func _validate_effect_cue(cue: Dictionary, cue_id: String) -> String:
	var effect_name := str(cue.get("effect", "")).to_lower()
	if effect_name not in EFFECT_NAMES:
		return "effect cue %s uses unsupported effect %s." % [cue_id, effect_name]
	var target_id := str(cue.get("target_id", "")).strip_edges()
	var target_position: Variant = cue.get("target_position", null)
	if target_id.is_empty() and target_position == null:
		return "effect cue %s requires target_id or target_position." % cue_id
	if target_position != null:
		if not target_position is Array or target_position.size() != 3:
			return "effect cue %s target_position must contain exactly three numbers." % cue_id
		for component in target_position:
			if not (component is int or component is float):
				return "effect cue %s target_position must contain only numbers." % cue_id
	var duration := float(cue.get("duration", 1.1))
	if duration < 0.4 or duration > 4.0:
		return "effect cue %s duration must be between 0.4 and 4 seconds." % cue_id
	return ""


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "file not found: %s" % path}
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {"ok": false, "error": "file is empty: %s" % path}
	if bytes.size() > 16 * 1024 * 1024:
		return {"ok": false, "error": "file exceeds the 16 MiB showcase limit."}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "error": "file is not a JSON object: %s" % path}
	return {"ok": true, "value": parsed}


func _sha256_file(path: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(FileAccess.get_file_as_bytes(path))
	return context.finish().hex_encode()


func _is_secret_free(value: Variant, key_name := "") -> bool:
	var normalized_key := key_name.strip_edges().to_lower()
	if normalized_key in FORBIDDEN_KEYS or normalized_key.ends_with("_api_key") or normalized_key.ends_with("_password") or normalized_key.ends_with("_secret"):
		return false
	if value is Dictionary:
		for key in value:
			if not _is_secret_free(value[key], str(key)):
				return false
		return true
	if value is Array:
		for child in value:
			if not _is_secret_free(child):
				return false
		return true
	if value is String:
		var text := str(value)
		var lower := text.to_lower()
		if (lower.contains("bearer ") and text.length() >= 18) or lower.contains("-----begin private key-----"):
			return false
		for prefix in ["sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-"]:
			var position := lower.find(prefix)
			if position >= 0 and lower.length() - position >= 14:
				return false
	return true


func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _refuse(reason: String) -> Dictionary:
	loaded = false
	verified = false
	verification_label = "UNVERIFIED LOCAL DEMO"
	verification_detail = reason
	verification_changed.emit(verification_label, verification_detail, false)
	return get_status()


func _reset() -> void:
	loaded = false
	verified = false
	verification_label = "UNVERIFIED LOCAL DEMO"
	verification_detail = "No showcase is loaded."
	manifest.clear()
	replay.clear()
	replay_hash = ""
	elapsed_seconds = 0.0
	playing = false
	is_complete = false
	dispatched_cue_count = 0
	_cues.clear()
	_next_cue_index = 0
	_result_shown = false
	_presentation = null
