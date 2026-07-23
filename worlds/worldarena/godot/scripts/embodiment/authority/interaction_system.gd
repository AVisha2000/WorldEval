class_name EmbodimentInteractionSystem
extends RefCounted

## Integer-only Stage-B interaction authority. The host owns the state fields documented below
## and calls `apply_tick` once per authoritative tick after movement/facing has resolved.

const Visibility := preload("res://scripts/embodiment/authority/visibility.gd")
const EventLedger := preload("res://scripts/embodiment/authority/event_ledger.gd")

const TARGET_NONE := "none"
const TARGET_RESOURCE := "resource"
const TARGET_RELAY := "relay"

const INTERACTION_RANGE_MT := 1_400
const INTERACTION_RANGE_SQUARED := INTERACTION_RANGE_MT * INTERACTION_RANGE_MT
const GATHER_TICKS_PER_UNIT := 4
const CARRY_LIMIT_UNITS := 2
const RESOURCE_STARTING_UNITS := 4
# The local scripted Construction showcase uses the existing long episode horizon rather than a
# hidden presentation flag.  It remains an ordinary deterministic Stage-C scenario: the larger
# visible resource supply simply gives the operator enough material trips to demonstrate walking,
# turning, gathering, carrying, and depositing for roughly two minutes before the final build.
# Standard (including all frozen 600-tick) Construction configurations retain four units.
const LONG_HORIZON_RESOURCE_STARTING_UNITS := 25
const LONG_HORIZON_MINIMUM_EPISODE_TICKS := 1_200

const CODE_IDLE := "interaction_idle"
const CODE_CANCELLED := "interaction_cancelled"
const CODE_INTERRUPTED := "interaction_interrupted"
const CODE_OUT_OF_RANGE := "interaction_out_of_range"
const CODE_MISALIGNED := "interaction_misaligned"
const CODE_GATHER_PROGRESS := "gathering_progress"
const CODE_GATHER_COMPLETE := "gathering_complete"
const CODE_INVENTORY_FULL := "inventory_full"
const CODE_RESOURCE_DEPLETED := "resource_depleted"
const CODE_DEPOSIT_COMPLETE := "deposit_complete"
const CODE_NOTHING_TO_DEPOSIT := "nothing_to_deposit"

const EVENT_INTERACTION_CANCELLED := "interaction_cancelled"
const EVENT_INTERACTION_INTERRUPTED := "interaction_interrupted"
const EVENT_INTERACTION_OUT_OF_RANGE := "interaction_out_of_range"
const EVENT_INTERACTION_MISALIGNED := "interaction_misaligned"
const EVENT_GATHERING_PROGRESSED := "gathering_progressed"
const EVENT_RESOURCE_GATHERED := "resource_gathered"
const EVENT_INVENTORY_FULL := "inventory_full"
const EVENT_RESOURCE_DEPLETED := "resource_depleted"
const EVENT_MATERIAL_DEPOSITED := "material_deposited"
const EVENT_NOTHING_TO_DEPOSIT := "nothing_to_deposit"


static func reset(authority: Object) -> void:
	authority.resource_units_remaining = _starting_resource_units(authority)
	authority.gather_progress_ticks = 0
	authority.inventory_material_units = 0
	authority.deposited_material_units = 0
	authority.active_interaction = TARGET_NONE


static func _starting_resource_units(authority: Object) -> int:
	if str(authority.task_id) == "construction-v0" \
		and int(authority.maximum_episode_ticks) >= LONG_HORIZON_MINIMUM_EPISODE_TICKS:
		return LONG_HORIZON_RESOURCE_STARTING_UNITS
	return RESOURCE_STARTING_UNITS


static func apply_tick(
	authority: Object, interact_held: bool, cancel_pressed: bool, events: Array[Dictionary]
) -> PackedStringArray:
	if cancel_pressed:
		return _stop_active(authority, events, CODE_CANCELLED, EVENT_INTERACTION_CANCELLED)
	if not interact_held:
		if str(authority.active_interaction) != TARGET_NONE:
			return _stop_active(authority, events, CODE_INTERRUPTED, EVENT_INTERACTION_INTERRUPTED)
		return PackedStringArray([CODE_IDLE])

	var target := select_target(authority)
	if target == TARGET_NONE:
		return _fail_interaction(
			authority, events, CODE_OUT_OF_RANGE, EVENT_INTERACTION_OUT_OF_RANGE,
			"No interaction target is in range.", {"range_mt": INTERACTION_RANGE_MT},
		)
	var target_position := _target_position(authority, target)
	if not is_facing(authority.operator_position_mt, int(authority.operator_heading), target_position):
		return _fail_interaction(
			authority, events, CODE_MISALIGNED, EVENT_INTERACTION_MISALIGNED,
			"Operator is not facing the interaction target.", {"target": target},
		)
	if target == TARGET_RELAY:
		return _deposit_tick(authority, events)
	return _gather_tick(authority, events)


static func select_target(authority: Object) -> String:
	var operator_position: Vector2i = authority.operator_position_mt
	var resource_distance := _distance_squared(operator_position, authority.resource_position_mt)
	var relay_distance := _distance_squared(operator_position, authority.relay_position_mt)
	var resource_in_range := resource_distance <= INTERACTION_RANGE_SQUARED
	var relay_in_range := relay_distance <= INTERACTION_RANGE_SQUARED
	if resource_in_range and (not relay_in_range or resource_distance <= relay_distance):
		return TARGET_RESOURCE
	if relay_in_range:
		return TARGET_RELAY
	return TARGET_NONE


static func is_facing(origin_mt: Vector2i, heading: int, target_mt: Vector2i) -> bool:
	var offset := target_mt - origin_mt
	if offset == Vector2i.ZERO:
		return true
	return Visibility.world_sector(offset) == posmod(heading, 8)


static func _gather_tick(authority: Object, events: Array[Dictionary]) -> PackedStringArray:
	if int(authority.inventory_material_units) >= CARRY_LIMIT_UNITS:
		authority.active_interaction = TARGET_NONE
		_append_event(
			authority, events, EVENT_INVENTORY_FULL, "Material inventory is full.",
			{"carry_limit_units": CARRY_LIMIT_UNITS},
		)
		return PackedStringArray([CODE_INVENTORY_FULL])
	if int(authority.resource_units_remaining) <= 0:
		authority.active_interaction = TARGET_NONE
		_append_event(authority, events, EVENT_RESOURCE_DEPLETED, "Resource node is depleted.", {})
		return PackedStringArray([CODE_RESOURCE_DEPLETED])
	authority.active_interaction = TARGET_RESOURCE
	authority.gather_progress_ticks += 1
	_append_event(
		authority, events, EVENT_GATHERING_PROGRESSED, "Gathering advanced by one tick.",
		{"progress_band": _progress_band(int(authority.gather_progress_ticks))},
	)
	if int(authority.gather_progress_ticks) < GATHER_TICKS_PER_UNIT:
		return PackedStringArray([CODE_GATHER_PROGRESS])
	authority.gather_progress_ticks = 0
	authority.resource_units_remaining -= 1
	authority.inventory_material_units += 1
	authority.active_interaction = TARGET_NONE
	_append_event(
		authority, events, EVENT_RESOURCE_GATHERED, "One material unit was gathered.",
		{
			"inventory_units": int(authority.inventory_material_units),
		},
	)
	return PackedStringArray([CODE_GATHER_COMPLETE])


static func _deposit_tick(authority: Object, events: Array[Dictionary]) -> PackedStringArray:
	authority.active_interaction = TARGET_RELAY
	var deposited := int(authority.inventory_material_units)
	if deposited <= 0:
		authority.active_interaction = TARGET_NONE
		_append_event(authority, events, EVENT_NOTHING_TO_DEPOSIT, "No material is carried.", {})
		return PackedStringArray([CODE_NOTHING_TO_DEPOSIT])
	authority.inventory_material_units = 0
	authority.deposited_material_units += deposited
	authority.active_interaction = TARGET_NONE
	_append_event(
		authority, events, EVENT_MATERIAL_DEPOSITED, "Carried material was deposited.",
		{
			"deposited_units": deposited,
			"total_deposited_units": int(authority.deposited_material_units),
		},
	)
	return PackedStringArray([CODE_DEPOSIT_COMPLETE])


static func _fail_interaction(
	authority: Object,
	events: Array[Dictionary],
	code: String,
	kind: String,
	summary: String,
	data: Dictionary,
) -> PackedStringArray:
	if str(authority.active_interaction) != TARGET_NONE:
		_append_event(
			authority, events, EVENT_INTERACTION_INTERRUPTED,
			"Active interaction was interrupted.", {"reason": code},
		)
	authority.active_interaction = TARGET_NONE
	_append_event(authority, events, kind, summary, data)
	return PackedStringArray([code])


static func _stop_active(
	authority: Object, events: Array[Dictionary], code: String, kind: String
) -> PackedStringArray:
	var prior_target := str(authority.active_interaction)
	authority.active_interaction = TARGET_NONE
	if prior_target != TARGET_NONE:
		_append_event(
			authority, events, kind,
			"Active interaction channel stopped.", {"target": prior_target},
		)
	return PackedStringArray([code])


static func _target_position(authority: Object, target: String) -> Vector2i:
	return authority.resource_position_mt if target == TARGET_RESOURCE else authority.relay_position_mt


static func _distance_squared(left: Vector2i, right: Vector2i) -> int:
	var offset := right - left
	return offset.x * offset.x + offset.y * offset.y


static func _progress_band(progress_ticks: int) -> String:
	if progress_ticks * 3 < GATHER_TICKS_PER_UNIT:
		return "started"
	if progress_ticks * 3 < GATHER_TICKS_PER_UNIT * 2:
		return "mid"
	return "near_complete"


static func _append_event(
	authority: Object, events: Array[Dictionary], kind: String, summary: String, data: Dictionary
) -> void:
	EventLedger.append(authority, events, kind, summary, data)
