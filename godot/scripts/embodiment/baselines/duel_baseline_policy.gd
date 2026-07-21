class_name EmbodimentDuelBaselinePolicy
extends RefCounted

## Deterministic scripted-duel controller. The policy deliberately consumes only the
## participant-scoped observation contract; callers must not pass authority state.

const PROTOCOL_VERSION := "llm-controller/0.1.0"
const DUEL_WINDOW_TICKS := 10
const TIER_SCOUT_V1 := "scout-v1"
const TIER_BALANCED_V1 := "balanced-v1"
const TIER_CHALLENGER_V1 := "challenger-v1"
const TIERS := [TIER_SCOUT_V1, TIER_BALANCED_V1, TIER_CHALLENGER_V1]

const _BEARING_MOVEMENT := {
	"front": Vector2i(0, 1000),
	"front_right": Vector2i(707, 707),
	"right": Vector2i(1000, 0),
	"back_right": Vector2i(707, -707),
	"back": Vector2i(0, -1000),
	"back_left": Vector2i(-707, -707),
	"left": Vector2i(-1000, 0),
	"front_left": Vector2i(-707, 707),
}


static func make_action(tier_id: String, observation: Dictionary) -> Dictionary:
	assert(tier_id in TIERS, "unknown deterministic baseline tier")
	var observation_seq := int(observation.get("observation_seq", 0))
	return {
		"protocol_version": PROTOCOL_VERSION,
		"episode_id": str(observation.get("episode_id", "")),
		"observation_seq": observation_seq,
		"action_id": "baseline_%s_%06d" % [tier_id.trim_suffix("-v1"), observation_seq],
		"control": choose_control(tier_id, observation),
		"intent_label": _intent(tier_id, observation),
		"memory_update": "",
	}


static func choose_control(tier_id: String, observation: Dictionary) -> Dictionary:
	assert(tier_id in TIERS, "unknown deterministic baseline tier")
	var control := _neutral_control()
	var self_state: Dictionary = observation.get("self", {})
	var opponent := _first_entity_with_affordance(observation, "hostile")
	var relay := _first_entity_kind(observation, "relay")
	var health_percent := int(self_state.get("health_percent", 100))
	var observation_seq := int(observation.get("observation_seq", 0))

	if tier_id == TIER_SCOUT_V1:
		_navigate_to(relay, control, 600)
		control.buttons.interact = _is_touching(relay)
		return control

	var opponent_close := not opponent.is_empty() \
		and str(opponent.get("distance", "far")) in ["touching", "near"]
	var opponent_ahead := not opponent.is_empty() \
		and str(opponent.get("bearing", "back")) in ["front", "front_left", "front_right"]
	if opponent_close and health_percent <= (40 if tier_id == TIER_BALANCED_V1 else 55):
		control.buttons.guard = true
		_navigate_to(opponent, control, -450)
		return control
	if opponent_close and opponent_ahead:
		control.buttons.primary = true
		return control

	var target := opponent if tier_id == TIER_CHALLENGER_V1 and not opponent.is_empty() else relay
	_navigate_to(target, control, 1000 if tier_id == TIER_CHALLENGER_V1 else 800)
	control.buttons.interact = _is_touching(relay) and target == relay
	if tier_id == TIER_CHALLENGER_V1 and not target.is_empty():
		var distance := str(target.get("distance", "far"))
		control.buttons.dash = distance in ["medium", "far"] and observation_seq % 3 == 0
	return control


static func _neutral_control() -> Dictionary:
	return {
		"move_x": 0,
		"move_y": 0,
		"look_x": 0,
		"look_y": 0,
		"duration_ticks": DUEL_WINDOW_TICKS,
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
	}


static func _navigate_to(entity: Dictionary, control: Dictionary, magnitude: int) -> void:
	if entity.is_empty():
		return
	var direction: Vector2i = _BEARING_MOVEMENT.get(str(entity.get("bearing", "front")), Vector2i.ZERO)
	control.move_x = _scale_axis(direction.x, magnitude)
	control.move_y = _scale_axis(direction.y, magnitude)


static func _scale_axis(axis: int, magnitude: int) -> int:
	@warning_ignore("integer_division")
	return axis * magnitude / 1000


static func _first_entity_kind(observation: Dictionary, kind: String) -> Dictionary:
	for raw_entity: Variant in observation.get("visible_entities", []):
		if raw_entity is Dictionary and str(raw_entity.get("kind", "")) == kind:
			return raw_entity
	return {}


static func _first_entity_with_affordance(observation: Dictionary, affordance: String) -> Dictionary:
	for raw_entity: Variant in observation.get("visible_entities", []):
		if raw_entity is Dictionary and affordance in raw_entity.get("affordances", []):
			return raw_entity
	return {}


static func _is_touching(entity: Dictionary) -> bool:
	return not entity.is_empty() and str(entity.get("distance", "far")) == "touching"


static func _intent(tier_id: String, observation: Dictionary) -> String:
	var control := choose_control(tier_id, observation)
	if bool(control.buttons.guard):
		return "guard and disengage"
	if bool(control.buttons.primary):
		return "attack visible rival"
	if bool(control.buttons.interact):
		return "contest central relay"
	if int(control.move_x) != 0 or int(control.move_y) != 0:
		return "advance toward visible objective"
	return "hold position"
