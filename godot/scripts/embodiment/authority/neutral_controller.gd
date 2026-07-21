class_name EmbodimentNeutralController
extends RefCounted

## Public deterministic Stage-D neutral profile.
##
## State transitions are predictable and observation-safe:
## idle -> chase -> telegraph -> attack -> recovery -> chase, with low health causing
## retreat -> recovery. Defeat is terminal for the neutral. Relay activation is allowed while the
## defender is retreating, recovering, or defeated; the model never receives a hidden target or
## navigation state from this module.

const CombatSystem := preload("res://scripts/embodiment/authority/combat_system.gd")
const ArenaMap := preload("res://scripts/embodiment/authority/arena_map.gd")
const EventLedger := preload("res://scripts/embodiment/authority/event_ledger.gd")

const NEUTRAL_MAX_HEALTH := 750
const NEUTRAL_RETREAT_HEALTH := 250
const NEUTRAL_RECOVERY_HEALTH := 500
const NEUTRAL_SPEED_MT_PER_TICK := 150
const NEUTRAL_DETECTION_RANGE_MT := 6000
const NEUTRAL_ATTACK_RANGE_MT := 1300
const NEUTRAL_ATTACK_DAMAGE := 180
const NEUTRAL_TELEGRAPH_TICKS := 3
const NEUTRAL_RECOVERY_TICKS := 5
const NEUTRAL_ATTACK_COOLDOWN_TICKS := 4
const NEUTRAL_HOME_RADIUS_MT := 300

const RELAY_RADIUS_MT := 1200
const RELAY_ACTIVATION_TICKS := 3

const PUBLIC_STATES := [
	"idle", "chase", "telegraph", "attack", "retreat", "recovery", "defeated",
]
const RELAY_SAFE_STATES := ["retreat", "recovery", "defeated"]
const EVENT_KINDS := [
	"neutral_attack_missed", "neutral_damaged", "neutral_recovered", "neutral_state_changed",
	"relay_activated", "relay_activation_cancelled", "relay_out_of_range",
]
const RECEIPT_CODES := [
	"neutral_attack_missed", "neutral_defeated", "neutral_recovered", "neutral_retreating",
	"relay_activated", "relay_activation_cancelled", "relay_activation_progress",
	"relay_defended", "relay_out_of_range",
]


static func reset(authority: Object) -> void:
	authority.neutral_position_mt = authority.neutral_home_position_mt
	authority.neutral_health = NEUTRAL_MAX_HEALTH
	authority.neutral_state = "idle"
	authority.neutral_state_ticks = 0
	authority.neutral_attack_cooldown_ticks = 0
	authority.relay_activation_ticks = 0
	authority.relay_activated = false


static func apply_tick(
	authority: Object,
	control: Dictionary,
	first_tick: bool,
	events: Array[Dictionary],
) -> Dictionary:
	var target := {
		"health": int(authority.neutral_health),
		"id": "neutral_0",
		"kind": "neutral",
		"position_mt": authority.neutral_position_mt,
	}
	var result: Dictionary = CombatSystem.apply_tick(
		authority, control, first_tick, target, events
	)
	var health_before: int = authority.neutral_health
	authority.neutral_health = int(target.health)
	if authority.neutral_health < health_before:
		_on_neutral_damaged(authority, health_before - authority.neutral_health, events, result)
	_update_neutral(authority, events, result)
	_update_relay(authority, bool(control.get("buttons", {}).get("interact", false)), events, result)
	return result


static func public_profile() -> Dictionary:
	return {
		"attack_damage": NEUTRAL_ATTACK_DAMAGE,
		"attack_range_mt": NEUTRAL_ATTACK_RANGE_MT,
		"detection_range_mt": NEUTRAL_DETECTION_RANGE_MT,
		"recovery_ticks": NEUTRAL_RECOVERY_TICKS,
		"retreat_health": NEUTRAL_RETREAT_HEALTH,
		"states": PUBLIC_STATES.duplicate(),
		"telegraph_ticks": NEUTRAL_TELEGRAPH_TICKS,
	}


static func _update_neutral(
	authority: Object, events: Array[Dictionary], result: Dictionary
) -> void:
	if authority.neutral_state == "defeated":
		return
	if authority.neutral_attack_cooldown_ticks > 0:
		authority.neutral_attack_cooldown_ticks -= 1
	match authority.neutral_state:
		"idle":
			if _within(authority.neutral_position_mt, authority.operator_position_mt, NEUTRAL_DETECTION_RANGE_MT):
				_transition(authority, "chase", events)
		"chase":
			if authority.neutral_health <= NEUTRAL_RETREAT_HEALTH:
				_transition(authority, "retreat", events)
			elif _within(authority.neutral_position_mt, authority.operator_position_mt, NEUTRAL_ATTACK_RANGE_MT) \
				and authority.neutral_attack_cooldown_ticks == 0:
				_transition(authority, "telegraph", events)
			else:
				authority.neutral_position_mt = _move_toward(
					authority.neutral_position_mt, authority.operator_position_mt
				)
		"telegraph":
			authority.neutral_state_ticks += 1
			if authority.neutral_state_ticks >= NEUTRAL_TELEGRAPH_TICKS:
				_transition(authority, "attack", events)
		"attack":
			if _within(authority.neutral_position_mt, authority.operator_position_mt, NEUTRAL_ATTACK_RANGE_MT):
				var damage := CombatSystem.apply_damage(
					authority, NEUTRAL_ATTACK_DAMAGE, authority.neutral_position_mt, events
				)
				_merge(result, damage)
			else:
				_append_code(result, "neutral_attack_missed")
				_append_event(events, "neutral_attack_missed", "Neutral attack missed outside range.", {})
			authority.neutral_attack_cooldown_ticks = NEUTRAL_ATTACK_COOLDOWN_TICKS
			_transition(authority, "recovery", events)
		"retreat":
			authority.neutral_position_mt = _move_toward(
				authority.neutral_position_mt, authority.neutral_home_position_mt
			)
			if _within(authority.neutral_position_mt, authority.neutral_home_position_mt, NEUTRAL_HOME_RADIUS_MT):
				_transition(authority, "recovery", events)
		"recovery":
			authority.neutral_state_ticks += 1
			if authority.neutral_state_ticks >= NEUTRAL_RECOVERY_TICKS:
				if authority.neutral_health <= NEUTRAL_RETREAT_HEALTH:
					authority.neutral_health = NEUTRAL_RECOVERY_HEALTH
					_append_code(result, "neutral_recovered")
					result.effects.append({
						"kind": "neutral_health", "value": int(authority.neutral_health),
					})
					_append_event(events, "neutral_recovered", "Neutral recovered at its home point.", {
						"health_band": "damaged",
					})
				_transition(authority, "chase", events)


static func _update_relay(
	authority: Object, interact: bool, events: Array[Dictionary], result: Dictionary
) -> void:
	if authority.relay_activated:
		return
	var permitted: bool = authority.neutral_state in RELAY_SAFE_STATES
	var in_range := _within(
		authority.operator_position_mt, authority.relay_position_mt, RELAY_RADIUS_MT
	)
	if interact and not in_range:
		if authority.relay_activation_ticks > 0:
			authority.relay_activation_ticks = 0
			_append_code(result, "relay_activation_cancelled")
			_append_event(events, "relay_activation_cancelled", "Relay activation was interrupted.", {
				"reason": "out_of_range",
			})
		_append_code(result, "relay_out_of_range")
		_append_event(events, "relay_out_of_range", "Relay interaction was outside range.", {
			"range_mt": RELAY_RADIUS_MT,
		})
		return
	if interact and permitted and in_range:
		authority.relay_activation_ticks += 1
		_append_code(result, "relay_activation_progress")
		result.effects.append({
			"kind": "relay_activation_ticks", "value": int(authority.relay_activation_ticks),
		})
		if authority.relay_activation_ticks >= RELAY_ACTIVATION_TICKS:
			authority.relay_activated = true
			_append_code(result, "relay_activated")
			_append_event(events, "relay_activated", "Operator activated the defended relay.", {})
	elif authority.relay_activation_ticks > 0:
		authority.relay_activation_ticks = 0
		_append_code(result, "relay_activation_cancelled")
		_append_event(events, "relay_activation_cancelled", "Relay activation was interrupted.", {
			"reason": "defended" if not permitted else "input_or_range",
		})
	elif interact and not permitted:
		_append_code(result, "relay_defended")


static func _on_neutral_damaged(
	authority: Object,
	damage: int,
	events: Array[Dictionary],
	result: Dictionary,
) -> void:
	result.effects.append({"kind": "neutral_health", "value": int(authority.neutral_health)})
	_append_event(events, "neutral_damaged", "Neutral took %d damage." % damage, {
		"amount": damage,
	})
	if authority.neutral_health == 0:
		_transition(authority, "defeated", events)
		_append_code(result, "neutral_defeated")
	elif authority.neutral_health <= NEUTRAL_RETREAT_HEALTH:
		_transition(authority, "retreat", events)
		_append_code(result, "neutral_retreating")


static func _transition(authority: Object, next_state: String, events: Array[Dictionary]) -> void:
	assert(next_state in PUBLIC_STATES)
	if authority.neutral_state == next_state:
		return
	authority.neutral_state = next_state
	authority.neutral_state_ticks = 0
	_append_event(events, "neutral_state_changed", "Neutral entered %s state." % next_state, {
		"state": next_state,
	})


static func _move_toward(position_mt: Vector2i, target_mt: Vector2i) -> Vector2i:
	var delta := target_mt - position_mt
	var greatest := maxi(abs(delta.x), abs(delta.y))
	if greatest == 0:
		return position_mt
	var step_x := ArenaMap.divide_toward_zero(delta.x * NEUTRAL_SPEED_MT_PER_TICK, greatest)
	var step_y := ArenaMap.divide_toward_zero(delta.y * NEUTRAL_SPEED_MT_PER_TICK, greatest)
	if abs(delta.x) < abs(step_x):
		step_x = delta.x
	if abs(delta.y) < abs(step_y):
		step_y = delta.y
	return position_mt + Vector2i(step_x, step_y)


static func _within(first: Vector2i, second: Vector2i, radius_mt: int) -> bool:
	return (first - second).length_squared() <= radius_mt * radius_mt


static func _merge(target: Dictionary, addition: Dictionary) -> void:
	for code: String in addition.codes:
		_append_code(target, code)
	for effect: Dictionary in addition.effects:
		target.effects.append(effect.duplicate(true))


static func _append_code(result: Dictionary, code: String) -> void:
	assert(code in RECEIPT_CODES or code in CombatSystem.RECEIPT_CODES)
	if code not in result.codes:
		result.codes.append(code)


static func _append_event(
	events: Array[Dictionary], kind: String, summary: String, data: Dictionary
) -> void:
	assert(kind in EVENT_KINDS)
	events.append(EventLedger.descriptor(kind, summary, data))
