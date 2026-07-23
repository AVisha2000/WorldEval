class_name EmbodimentCombatSystem
extends RefCounted

## Integer-only combat mechanics shared by the solo neutral encounter and later opponents.
##
## The caller owns tick advancement and event ids. This module mutates the authority-like fields
## documented by `reset`, returns receipt-ready codes/effects, and appends stable public event
## descriptors. A primary target is a Dictionary with `id`, `kind`, `position_mt`, and `health`.

const ArenaMap := preload("res://scripts/embodiment/authority/arena_map.gd")
const EventLedger := preload("res://scripts/embodiment/authority/event_ledger.gd")

const OPERATOR_MAX_HEALTH := 1000
const OPERATOR_MAX_ENERGY := 1000
const ENERGY_RECOVERY_PER_TICK := 25
const GUARD_ENERGY_PER_TICK := 40
const GUARD_DAMAGE_NUMERATOR := 1
const GUARD_DAMAGE_DENOMINATOR := 2

const PRIMARY_DAMAGE := 250
const PRIMARY_RANGE_MT := 1600
const PRIMARY_COOLDOWN_TICKS := 5
# Alignment accepts targets no more than 45 degrees from the current facing vector.
const PRIMARY_ALIGNMENT_CROSS_MULTIPLIER := 1

const DASH_DISTANCE_MT := 900
const DASH_ENERGY_COST := 300
const DASH_COOLDOWN_TICKS := 10

const EVENT_KINDS := [
	"dash_applied", "dash_rejected", "guard_failed", "operator_damaged",
	"operator_knocked_out", "primary_hit", "primary_missed", "primary_rejected",
]
const RECEIPT_CODES := [
	"damage_taken", "dash_applied", "dash_blocked", "dash_cooldown",
	"dash_energy_insufficient", "energy_recovered", "guard_active", "guard_energy_depleted",
	"guard_reduced_damage", "operator_knockout", "primary_cooldown", "primary_hit",
	"primary_miss_alignment", "primary_miss_no_target", "primary_miss_range",
]

const FORWARD_BASIS := [
	Vector2i(0, -1000), Vector2i(707, -707), Vector2i(1000, 0), Vector2i(707, 707),
	Vector2i(0, 1000), Vector2i(-707, 707), Vector2i(-1000, 0), Vector2i(-707, -707),
]


static func reset(authority: Object) -> void:
	authority.operator_health = OPERATOR_MAX_HEALTH
	authority.operator_energy = OPERATOR_MAX_ENERGY
	authority.operator_guarding = false
	authority.operator_knocked_out = false
	authority.primary_cooldown_ticks = 0
	authority.dash_cooldown_ticks = 0


static func apply_tick(
	authority: Object,
	control: Dictionary,
	first_tick: bool,
	target: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var codes: Array[String] = []
	var effects: Array[Dictionary] = []
	var energy_before: int = authority.operator_energy
	var primary_was_cooling: bool = authority.primary_cooldown_ticks > 0
	var dash_was_cooling: bool = authority.dash_cooldown_ticks > 0
	if primary_was_cooling:
		authority.primary_cooldown_ticks -= 1
	if dash_was_cooling:
		authority.dash_cooldown_ticks -= 1

	var buttons: Dictionary = control.get("buttons", {})
	var spent_energy := false
	if first_tick and bool(buttons.get("dash", false)):
		var dash_result := _attempt_dash(authority, dash_was_cooling, events)
		_merge_result(codes, effects, dash_result)
		spent_energy = bool(dash_result.get("spent_energy", false))

	if bool(buttons.get("guard", false)):
		if authority.operator_energy >= GUARD_ENERGY_PER_TICK:
			authority.operator_energy -= GUARD_ENERGY_PER_TICK
			authority.operator_guarding = true
			spent_energy = true
			_append_unique(codes, "guard_active")
		else:
			authority.operator_guarding = false
			_append_unique(codes, "guard_energy_depleted")
			_append_event(events, "guard_failed", "Guard failed because Operator energy was depleted.", {
				"reason": "energy_depleted",
			})
	else:
		authority.operator_guarding = false

	if not spent_energy and authority.operator_energy < OPERATOR_MAX_ENERGY:
		var recovered := mini(ENERGY_RECOVERY_PER_TICK, OPERATOR_MAX_ENERGY - authority.operator_energy)
		authority.operator_energy += recovered
		if recovered > 0:
			_append_unique(codes, "energy_recovered")
			effects.append({"kind": "energy_recovered", "value": recovered})
	if energy_before != authority.operator_energy:
		effects.append({
			"kind": "operator_energy", "value": int(authority.operator_energy),
		})

	if first_tick and bool(buttons.get("primary", false)):
		var primary_result := _attempt_primary(
			authority, target, primary_was_cooling, events
		)
		_merge_result(codes, effects, primary_result)
	return {"codes": codes, "effects": effects}


static func apply_damage(
	authority: Object,
	raw_damage: int,
	source_position_mt: Vector2i,
	events: Array[Dictionary],
) -> Dictionary:
	assert(raw_damage >= 0)
	var applied_damage := raw_damage
	var guarded: bool = authority.operator_guarding and _position_is_aligned(
		authority.operator_position_mt,
		authority.operator_heading,
		source_position_mt,
		PRIMARY_RANGE_MT * 4,
	)
	var codes: Array[String] = []
	if raw_damage > 0:
		codes.append("damage_taken")
	if guarded:
		applied_damage = ArenaMap.divide_toward_zero(
			raw_damage * GUARD_DAMAGE_NUMERATOR, GUARD_DAMAGE_DENOMINATOR
		)
		codes.append("guard_reduced_damage")
	authority.operator_health = maxi(0, authority.operator_health - applied_damage)
	_append_event(events, "operator_damaged", "Operator took %d damage." % applied_damage, {
		"amount": applied_damage,
		"guarded": guarded,
	})
	if authority.operator_health == 0 and not authority.operator_knocked_out:
		authority.operator_knocked_out = true
		codes.append("operator_knockout")
		_append_event(events, "operator_knocked_out", "Operator was knocked out.", {})
	return {
		"codes": codes,
		"effects": [
			{"kind": "damage_taken", "value": applied_damage},
			{"kind": "damage_prevented", "value": raw_damage - applied_damage},
			{"kind": "operator_health", "value": int(authority.operator_health)},
		],
		"damage": applied_damage,
		"guarded": guarded,
	}


static func _attempt_primary(
	authority: Object,
	target: Dictionary,
	was_cooling: bool,
	events: Array[Dictionary],
) -> Dictionary:
	if was_cooling:
		_append_event(events, "primary_rejected", "Primary attack was on cooldown.", {
			"reason": "cooldown", "remaining_ticks": int(authority.primary_cooldown_ticks),
		})
		return _result("primary_cooldown", "primary_damage", 0)
	authority.primary_cooldown_ticks = PRIMARY_COOLDOWN_TICKS
	if target.is_empty() or int(target.get("health", 0)) <= 0:
		_append_event(events, "primary_missed", "Primary attack hit empty space.", {
			"reason": "no_target",
		})
		return _result("primary_miss_no_target", "primary_damage", 0)
	var target_position: Variant = target.get("position_mt")
	if not target_position is Vector2i:
		_append_event(events, "primary_missed", "Primary target had no public position.", {
			"reason": "no_target",
		})
		return _result("primary_miss_no_target", "primary_damage", 0)
	var offset: Vector2i = target_position - authority.operator_position_mt
	if offset.length_squared() > PRIMARY_RANGE_MT * PRIMARY_RANGE_MT:
		_append_event(events, "primary_missed", "Primary attack missed outside tool range.", {
			"reason": "range", "target_id": str(target.get("id", "target")),
		})
		return _result("primary_miss_range", "primary_damage", 0)
	if not _position_is_aligned(
		authority.operator_position_mt,
		authority.operator_heading,
		target_position,
		PRIMARY_RANGE_MT,
	):
		_append_event(events, "primary_missed", "Primary attack missed outside facing alignment.", {
			"reason": "alignment", "target_id": str(target.get("id", "target")),
		})
		return _result("primary_miss_alignment", "primary_damage", 0)
	var applied_damage := mini(PRIMARY_DAMAGE, int(target.health))
	target.health = int(target.health) - applied_damage
	_append_event(events, "primary_hit", "Primary attack hit %s." % str(target.get("kind", "target")), {
		"damage": applied_damage,
		"target_id": str(target.get("id", "target")),
	})
	return _result("primary_hit", "primary_damage", applied_damage)


static func _attempt_dash(
	authority: Object, was_cooling: bool, events: Array[Dictionary]
) -> Dictionary:
	if was_cooling:
		_append_event(events, "dash_rejected", "Dash was on cooldown.", {
			"reason": "cooldown", "remaining_ticks": int(authority.dash_cooldown_ticks),
		})
		return _result("dash_cooldown", "dash_distance_mt", 0)
	if authority.operator_energy < DASH_ENERGY_COST:
		_append_event(events, "dash_rejected", "Dash required more Operator energy.", {
			"reason": "energy_insufficient",
		})
		return _result("dash_energy_insufficient", "dash_distance_mt", 0)
	var forward: Vector2i = FORWARD_BASIS[posmod(authority.operator_heading, 8)]
	var raw_x := ArenaMap.divide_toward_zero(forward.x * DASH_DISTANCE_MT, 1000)
	var raw_y := ArenaMap.divide_toward_zero(forward.y * DASH_DISTANCE_MT, 1000)
	var candidate: Vector2i = authority.operator_position_mt + Vector2i(raw_x, raw_y)
	var clamped := Vector2i(
		clampi(candidate.x, -ArenaMap.ARENA_HALF_EXTENT_MT, ArenaMap.ARENA_HALF_EXTENT_MT),
		clampi(candidate.y, -ArenaMap.ARENA_HALF_EXTENT_MT, ArenaMap.ARENA_HALF_EXTENT_MT),
	)
	var distance: int = abs(clamped.x - authority.operator_position_mt.x) \
		+ abs(clamped.y - authority.operator_position_mt.y)
	authority.operator_position_mt = clamped
	authority.operator_energy -= DASH_ENERGY_COST
	authority.dash_cooldown_ticks = DASH_COOLDOWN_TICKS
	_append_event(events, "dash_applied", "Operator dashed forward.", {
		"distance_mt": distance,
	})
	var result := _result("dash_applied", "dash_distance_mt", distance)
	result.spent_energy = true
	if candidate != clamped:
		result.codes.append("dash_blocked")
	return result


static func _position_is_aligned(
	origin_mt: Vector2i, heading: int, target_mt: Vector2i, maximum_range_mt: int
) -> bool:
	var offset := target_mt - origin_mt
	if offset == Vector2i.ZERO or offset.length_squared() > maximum_range_mt * maximum_range_mt:
		return false
	var forward: Vector2i = FORWARD_BASIS[posmod(heading, 8)]
	var dot := forward.x * offset.x + forward.y * offset.y
	var cross := forward.x * offset.y - forward.y * offset.x
	return dot > 0 and abs(cross) * PRIMARY_ALIGNMENT_CROSS_MULTIPLIER <= dot


static func _append_event(
	events: Array[Dictionary], kind: String, summary: String, data: Dictionary
) -> void:
	assert(kind in EVENT_KINDS)
	events.append(EventLedger.descriptor(kind, summary, data))


static func _result(code: String, effect_kind: String, value: int) -> Dictionary:
	return {
		"codes": [code],
		"effects": [{"kind": effect_kind, "value": value}],
		"spent_energy": false,
	}


static func _merge_result(
	codes: Array[String], effects: Array[Dictionary], result: Dictionary
) -> void:
	for code: String in result.codes:
		_append_unique(codes, code)
	for effect: Dictionary in result.effects:
		effects.append(effect.duplicate(true))


static func _append_unique(codes: Array[String], code: String) -> void:
	assert(code in RECEIPT_CODES)
	if code not in codes:
		codes.append(code)
