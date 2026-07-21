class_name EmbodimentProtocolValidator
extends RefCounted

## Bounded strict JSON boundary for embodiment model actions.
##
## Godot's JSON parser represents every JSON number as a float and discards duplicate object keys.
## This preflight preserves the protocol distinction by rejecting non-integer number lexemes and
## duplicate keys before using JSON.parse, then converts the lexically proven integers back to int.

const MAX_ACTION_UTF8_BYTES := 4096
const MAX_MEMORY_UTF8_BYTES := 2048
const MAX_INTENT_UTF8_BYTES := 160
const REQUIRED_ACTION_FIELDS := [
	"protocol_version", "episode_id", "observation_seq", "action_id", "control",
	"intent_label", "memory_update",
]
const REQUIRED_CONTROL_FIELDS := [
	"move_x", "move_y", "look_x", "look_y", "duration_ticks", "buttons",
]
const REQUIRED_BUTTON_FIELDS := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
]

var _text := ""
var _index := 0
var _error := ""


func parse_action(raw: PackedByteArray) -> Dictionary:
	if raw.size() > MAX_ACTION_UTF8_BYTES:
		return _failure("action_too_large")
	if raw.size() >= 3 and raw[0] == 0xef and raw[1] == 0xbb and raw[2] == 0xbf:
		return _failure("utf8_bom_forbidden")
	if not _valid_utf8(raw):
		return _failure("utf8_invalid")
	var decoded := raw.get_string_from_utf8()
	if decoded.to_utf8_buffer() != raw:
		return _failure("utf8_invalid")
	_text = decoded
	_index = 0
	_error = ""
	_skip_whitespace()
	if not _scan_value():
		return _failure(_error if not _error.is_empty() else "json_invalid")
	_skip_whitespace()
	if _index != _text.length():
		return _failure("json_trailing_data")
	var parsed: Variant = JSON.parse_string(_text)
	if not parsed is Dictionary:
		return _failure("action_not_object")
	var action: Dictionary = _restore_integers(parsed)
	var validation_error := _validate_action_shape(action)
	if not validation_error.is_empty():
		return _failure(validation_error)
	return {"valid": true, "instance": action, "codes": []}


func observation_schema_valid(instance: Variant) -> bool:
	if not instance is Dictionary:
		return false
	var common := [
		"protocol_version", "episode_id", "observation_seq", "tick", "profile", "goal",
		"remaining_ticks", "previous_receipt", "terminal",
	]
	var profile: Variant = instance.get("profile")
	var required := common.duplicate()
	if profile == "text-visible-v1":
		required.append_array(["self", "visible_entities", "recent_events", "memory"])
	elif profile == "hybrid-visible-v1":
		required.append_array(["self", "visible_entities", "recent_events", "memory", "frame"])
	elif profile == "rgb-v1":
		required.append("frame")
	else:
		return false
	if not _has_exact_fields(instance, required):
		return false
	if instance.protocol_version != "llm-controller/0.1.0" \
		or typeof(instance.episode_id) != TYPE_STRING or not _valid_episode_id(instance.episode_id) \
		or typeof(instance.observation_seq) != TYPE_INT or instance.observation_seq < 0 \
		or typeof(instance.tick) != TYPE_INT or instance.tick < 0 \
		or typeof(instance.goal) != TYPE_STRING or instance.goal.is_empty() \
		or typeof(instance.remaining_ticks) != TYPE_INT or instance.remaining_ticks < 0 \
		or not instance.terminal is Dictionary:
		return false
	if profile in ["text-visible-v1", "hybrid-visible-v1"]:
		if not instance.self is Dictionary or not instance.visible_entities is Array \
			or not instance.recent_events is Array or typeof(instance.memory) != TYPE_STRING \
			or instance.memory.to_utf8_buffer().size() > MAX_MEMORY_UTF8_BYTES:
			return false
	if profile in ["rgb-v1", "hybrid-visible-v1"] and not _valid_frame(instance.frame):
		return false
	return true


func decision_window_schema_valid(instance: Variant) -> bool:
	if not instance is Dictionary or not _has_exact_fields(instance, [
		"episode_id", "observation_seq", "mode", "start_tick", "duration_ticks", "decisions",
	]):
		return false
	if typeof(instance.episode_id) != TYPE_STRING or not _valid_episode_id(instance.episode_id) \
		or typeof(instance.observation_seq) != TYPE_INT or instance.observation_seq < 0 \
		or typeof(instance.start_tick) != TYPE_INT or instance.start_tick < 0 \
		or typeof(instance.duration_ticks) != TYPE_INT or not instance.decisions is Dictionary:
		return false
	var participant_count := 1
	if instance.mode in ["scripted-duel-v0", "model-duel-v0"]:
		participant_count = 2
		if instance.duration_ticks != 10:
			return false
	elif instance.mode == "solo-curriculum-v0":
		if instance.duration_ticks < 1 or instance.duration_ticks > 20:
			return false
	else:
		return false
	if instance.decisions.size() != participant_count:
		return false
	for index: int in participant_count:
		var participant_id := "participant_%d" % index
		if not instance.decisions.has(participant_id) \
			or not _valid_decision_shape(instance.decisions[participant_id]):
			return false
	return true


func _valid_frame(frame: Variant) -> bool:
	return frame is Dictionary and _has_exact_fields(frame, [
		"sensor_id", "mime_type", "width", "height", "sha256", "transport_ref",
	]) and frame.sensor_id == "operator-follow-v1" and frame.mime_type == "image/png" \
		and typeof(frame.width) == TYPE_INT and frame.width == 1280 \
		and typeof(frame.height) == TYPE_INT and frame.height == 720 \
		and typeof(frame.sha256) == TYPE_STRING and frame.sha256.length() == 64 \
		and typeof(frame.transport_ref) == TYPE_STRING and frame.transport_ref.begins_with("frame:")


func _valid_decision_shape(decision: Variant) -> bool:
	if not decision is Dictionary or not _has_exact_fields(decision, [
		"disposition", "action", "fallback", "no_input_reason",
	]):
		return false
	if decision.disposition == "accepted":
		return decision.action is Dictionary and decision.fallback == "none" \
			and decision.no_input_reason == null \
			and _validate_action_shape(decision.action).is_empty()
	if decision.disposition == "no_input":
		return decision.action == null and decision.fallback == "neutral" \
			and decision.no_input_reason in ["missing", "invalid", "timeout", "stale_observation"]
	return false


func _scan_value() -> bool:
	_skip_whitespace()
	if _index >= _text.length():
		return _fail("json_unexpected_end")
	match _text.unicode_at(_index):
		123:
			return _scan_object()
		91:
			return _scan_array()
		34:
			return _scan_string()
		116:
			return _scan_literal("true")
		102:
			return _scan_literal("false")
		110:
			return _scan_literal("null")
		45, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
			return _scan_integer()
		_:
			return _fail("json_invalid_token")


func _scan_object() -> bool:
	_index += 1
	_skip_whitespace()
	var keys := {}
	if _consume(125):
		return true
	while true:
		var key_start := _index
		if not _scan_string():
			return false
		var key_lexeme := _text.substr(key_start, _index - key_start)
		var key: Variant = JSON.parse_string(key_lexeme)
		if typeof(key) != TYPE_STRING:
			return _fail("json_object_key_invalid")
		if keys.has(key):
			return _fail("json_duplicate_key")
		keys[key] = true
		_skip_whitespace()
		if not _consume(58):
			return _fail("json_colon_expected")
		if not _scan_value():
			return false
		_skip_whitespace()
		if _consume(125):
			return true
		if not _consume(44):
			return _fail("json_comma_expected")
		_skip_whitespace()
	return false


func _scan_array() -> bool:
	_index += 1
	_skip_whitespace()
	if _consume(93):
		return true
	while true:
		if not _scan_value():
			return false
		_skip_whitespace()
		if _consume(93):
			return true
		if not _consume(44):
			return _fail("json_comma_expected")
	return false


func _scan_string() -> bool:
	if not _consume(34):
		return _fail("json_string_expected")
	while _index < _text.length():
		var code := _text.unicode_at(_index)
		_index += 1
		if code == 34:
			return true
		if code < 32:
			return _fail("json_control_character")
		if code != 92:
			continue
		if _index >= _text.length():
			return _fail("json_escape_invalid")
		var escaped := _text.unicode_at(_index)
		_index += 1
		if escaped == 117:
			for _digit: int in 4:
				if _index >= _text.length() or not _is_hex(_text.unicode_at(_index)):
					return _fail("json_unicode_escape_invalid")
				_index += 1
		elif escaped not in [34, 47, 92, 98, 102, 110, 114, 116]:
			return _fail("json_escape_invalid")
	return _fail("json_string_unterminated")


func _scan_integer() -> bool:
	var number_start := _index
	if _consume(45) and _index >= _text.length():
		return _fail("json_number_invalid")
	if _consume(48):
		if _index < _text.length() and _is_digit(_text.unicode_at(_index)):
			return _fail("json_number_leading_zero")
	else:
		if _index >= _text.length() or not _is_digit_one_to_nine(_text.unicode_at(_index)):
			return _fail("json_number_invalid")
		while _index < _text.length() and _is_digit(_text.unicode_at(_index)):
			_index += 1
	if _index < _text.length() and _text.unicode_at(_index) in [46, 69, 101]:
		return _fail("json_number_not_integer")
	var lexeme := _text.substr(number_start, _index - number_start)
	var digits := lexeme.substr(1) if lexeme.begins_with("-") else lexeme
	if digits.length() > 16 or (digits.length() == 16 and digits > "9007199254740991"):
		return _fail("json_integer_outside_interoperable_range")
	return true


func _scan_literal(literal: String) -> bool:
	if _text.substr(_index, literal.length()) != literal:
		return _fail("json_literal_invalid")
	_index += literal.length()
	return true


func _validate_action_shape(action: Dictionary) -> String:
	if not _has_exact_fields(action, REQUIRED_ACTION_FIELDS):
		return "action_shape_invalid"
	if action.protocol_version != "llm-controller/0.1.0":
		return "protocol_version_mismatch"
	if typeof(action.episode_id) != TYPE_STRING or not _valid_episode_id(action.episode_id):
		return "episode_id_invalid"
	if typeof(action.observation_seq) != TYPE_INT or action.observation_seq < 0:
		return "observation_seq_invalid"
	if typeof(action.action_id) != TYPE_STRING or not _valid_action_id(action.action_id):
		return "action_id_invalid"
	if not action.control is Dictionary or not _has_exact_fields(action.control, REQUIRED_CONTROL_FIELDS):
		return "control_shape_invalid"
	for axis: String in ["move_x", "move_y", "look_x", "look_y"]:
		if typeof(action.control[axis]) != TYPE_INT or action.control[axis] < -1000 \
			or action.control[axis] > 1000:
			return "%s_invalid" % axis
	if typeof(action.control.duration_ticks) != TYPE_INT or action.control.duration_ticks < 1 \
		or action.control.duration_ticks > 20:
		return "duration_ticks_invalid"
	if not action.control.buttons is Dictionary \
		or not _has_exact_fields(action.control.buttons, REQUIRED_BUTTON_FIELDS):
		return "buttons_shape_invalid"
	for button: String in REQUIRED_BUTTON_FIELDS:
		if typeof(action.control.buttons[button]) != TYPE_BOOL:
			return "%s_invalid" % button
	if typeof(action.intent_label) != TYPE_STRING \
		or action.intent_label.to_utf8_buffer().size() > MAX_INTENT_UTF8_BYTES:
		return "intent_label_invalid"
	if typeof(action.memory_update) != TYPE_STRING:
		return "memory_update_invalid"
	if action.memory_update.to_utf8_buffer().size() > MAX_MEMORY_UTF8_BYTES:
		return "memory_update_too_large"
	return ""


func _restore_integers(value: Variant) -> Variant:
	if typeof(value) == TYPE_FLOAT:
		return int(value)
	if value is Array:
		var restored: Array = []
		for item: Variant in value:
			restored.append(_restore_integers(item))
		return restored
	if value is Dictionary:
		var restored := {}
		for key: Variant in value:
			restored[key] = _restore_integers(value[key])
		return restored
	return value


func _has_exact_fields(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


func _valid_episode_id(value: String) -> bool:
	if not value.begins_with("ep_") or value.length() < 4 or value.length() > 123:
		return false
	return _is_ascii_token(value.substr(3), 1, 120, true)


func _valid_action_id(value: String) -> bool:
	return _is_ascii_token(value, 1, 64, false)


func _is_ascii_token(value: String, minimum: int, maximum: int, allow_leading_punctuation: bool) -> bool:
	if value.length() < minimum or value.length() > maximum:
		return false
	for index: int in value.length():
		var code := value.unicode_at(index)
		var alphanumeric := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122)
		var punctuation := code in [45, 46, 95]
		if not alphanumeric and not punctuation:
			return false
		if index == 0 and not allow_leading_punctuation and not alphanumeric:
			return false
	return true


func _skip_whitespace() -> void:
	while _index < _text.length() and _text.unicode_at(_index) in [9, 10, 13, 32]:
		_index += 1


func _consume(code: int) -> bool:
	if _index < _text.length() and _text.unicode_at(_index) == code:
		_index += 1
		return true
	return false


func _fail(code: String) -> bool:
	_error = code
	return false


func _failure(code: String) -> Dictionary:
	return {"valid": false, "instance": null, "codes": [code]}


func _is_digit(code: int) -> bool:
	return code >= 48 and code <= 57


func _is_digit_one_to_nine(code: int) -> bool:
	return code >= 49 and code <= 57


func _is_hex(code: int) -> bool:
	return _is_digit(code) or (code >= 65 and code <= 70) or (code >= 97 and code <= 102)


func _valid_utf8(raw: PackedByteArray) -> bool:
	var cursor := 0
	while cursor < raw.size():
		var lead := int(raw[cursor])
		if lead <= 0x7f:
			cursor += 1
			continue
		var continuation_count := 0
		var codepoint := 0
		var minimum := 0
		if lead >= 0xc2 and lead <= 0xdf:
			continuation_count = 1
			codepoint = lead & 0x1f
			minimum = 0x80
		elif lead >= 0xe0 and lead <= 0xef:
			continuation_count = 2
			codepoint = lead & 0x0f
			minimum = 0x800
		elif lead >= 0xf0 and lead <= 0xf4:
			continuation_count = 3
			codepoint = lead & 0x07
			minimum = 0x10000
		else:
			return false
		if cursor + continuation_count >= raw.size():
			return false
		for offset: int in range(1, continuation_count + 1):
			var continuation := int(raw[cursor + offset])
			if continuation < 0x80 or continuation > 0xbf:
				return false
			codepoint = (codepoint << 6) | (continuation & 0x3f)
		if codepoint < minimum or codepoint > 0x10ffff \
			or (codepoint >= 0xd800 and codepoint <= 0xdfff):
			return false
		cursor += continuation_count + 1
	return true
