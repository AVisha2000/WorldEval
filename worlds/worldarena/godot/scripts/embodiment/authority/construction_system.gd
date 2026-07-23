class_name EmbodimentConstructionSystem
extends RefCounted

## Integer-only Stage-C construction authority. Deposited material is checked every tick but is
## consumed atomically only when the repeated, resumable construction channel completes.

const InteractionSystem := preload("res://scripts/embodiment/authority/interaction_system.gd")
const EventLedger := preload("res://scripts/embodiment/authority/event_ledger.gd")

const BUILD_RANGE_MT := 1_400
const BUILD_RANGE_SQUARED := BUILD_RANGE_MT * BUILD_RANGE_MT
const BARRICADE_MATERIAL_REQUIRED := 2
const BARRICADE_BUILD_TICKS_REQUIRED := 6

const CODE_IDLE := "construction_idle"
const CODE_CANCELLED := "construction_cancelled"
const CODE_INTERRUPTED := "construction_interrupted"
const CODE_OUT_OF_RANGE := "construction_out_of_range"
const CODE_MISALIGNED := "construction_misaligned"
const CODE_INSUFFICIENT_MATERIAL := "construction_insufficient_material"
const CODE_PROGRESS := "construction_progress"
const CODE_COMPLETE := "construction_complete"
const CODE_ALREADY_COMPLETE := "construction_already_complete"

const EVENT_CONSTRUCTION_CANCELLED := "construction_cancelled"
const EVENT_CONSTRUCTION_INTERRUPTED := "construction_interrupted"
const EVENT_CONSTRUCTION_OUT_OF_RANGE := "construction_out_of_range"
const EVENT_CONSTRUCTION_MISALIGNED := "construction_misaligned"
const EVENT_CONSTRUCTION_INSUFFICIENT_MATERIAL := "construction_insufficient_material"
const EVENT_CONSTRUCTION_PROGRESSED := "construction_progressed"
const EVENT_BARRICADE_COMPLETED := "barricade_completed"


static func reset(authority: Object) -> void:
	authority.barricade_progress_ticks = 0
	authority.barricade_complete = false
	authority.construction_active = false


static func apply_tick(
	authority: Object, interact_held: bool, cancel_pressed: bool, events: Array[Dictionary]
) -> PackedStringArray:
	if cancel_pressed:
		return _stop_active(authority, events, CODE_CANCELLED, EVENT_CONSTRUCTION_CANCELLED)
	if not interact_held:
		if bool(authority.construction_active):
			return _stop_active(
				authority, events, CODE_INTERRUPTED, EVENT_CONSTRUCTION_INTERRUPTED
			)
		return PackedStringArray([CODE_IDLE])
	if bool(authority.barricade_complete):
		authority.construction_active = false
		return PackedStringArray([CODE_ALREADY_COMPLETE])
	if _distance_squared(authority.operator_position_mt, authority.build_pad_position_mt) \
		> BUILD_RANGE_SQUARED:
		return _fail(
			authority, events, CODE_OUT_OF_RANGE, EVENT_CONSTRUCTION_OUT_OF_RANGE,
			"Build pad is out of range.", {"range_mt": BUILD_RANGE_MT},
		)
	if not InteractionSystem.is_facing(
		authority.operator_position_mt,
		int(authority.operator_heading),
		authority.build_pad_position_mt,
	):
		return _fail(
			authority, events, CODE_MISALIGNED, EVENT_CONSTRUCTION_MISALIGNED,
			"Operator is not facing the build pad.", {},
		)
	if int(authority.deposited_material_units) < BARRICADE_MATERIAL_REQUIRED:
		return _fail(
			authority, events, CODE_INSUFFICIENT_MATERIAL,
			EVENT_CONSTRUCTION_INSUFFICIENT_MATERIAL,
			"Deposited material is insufficient for a barricade.",
			{
				"available_units": int(authority.deposited_material_units),
				"required_units": BARRICADE_MATERIAL_REQUIRED,
			},
		)
	authority.construction_active = true
	authority.barricade_progress_ticks += 1
	_append_event(
		authority, events, EVENT_CONSTRUCTION_PROGRESSED,
		"Barricade construction advanced by one tick.",
		{"progress_band": _progress_band(int(authority.barricade_progress_ticks))},
	)
	if int(authority.barricade_progress_ticks) < BARRICADE_BUILD_TICKS_REQUIRED:
		return PackedStringArray([CODE_PROGRESS])
	authority.barricade_progress_ticks = BARRICADE_BUILD_TICKS_REQUIRED
	authority.deposited_material_units -= BARRICADE_MATERIAL_REQUIRED
	authority.barricade_complete = true
	authority.construction_active = false
	_append_event(
		authority, events, EVENT_BARRICADE_COMPLETED, "Barricade construction completed.",
		{
			"material_units_spent": BARRICADE_MATERIAL_REQUIRED,
			"remaining_deposited_units": int(authority.deposited_material_units),
		},
	)
	return PackedStringArray([CODE_COMPLETE])


static func _fail(
	authority: Object,
	events: Array[Dictionary],
	code: String,
	kind: String,
	summary: String,
	data: Dictionary,
) -> PackedStringArray:
	if bool(authority.construction_active):
		_append_event(
			authority, events, EVENT_CONSTRUCTION_INTERRUPTED,
			"Active construction channel was interrupted.", {"reason": code},
		)
	authority.construction_active = false
	_append_event(authority, events, kind, summary, data)
	return PackedStringArray([code])


static func _stop_active(
	authority: Object, events: Array[Dictionary], code: String, kind: String
) -> PackedStringArray:
	var was_active := bool(authority.construction_active)
	authority.construction_active = false
	if was_active:
		_append_event(authority, events, kind, "Active construction channel stopped.", {})
	return PackedStringArray([code])


static func _distance_squared(left: Vector2i, right: Vector2i) -> int:
	var offset := right - left
	return offset.x * offset.x + offset.y * offset.y


static func _progress_band(progress_ticks: int) -> String:
	if progress_ticks * 3 < BARRICADE_BUILD_TICKS_REQUIRED:
		return "started"
	if progress_ticks * 3 < BARRICADE_BUILD_TICKS_REQUIRED * 2:
		return "mid"
	return "near_complete"


static func _append_event(
	authority: Object, events: Array[Dictionary], kind: String, summary: String, data: Dictionary
) -> void:
	EventLedger.append(authority, events, kind, summary, data)
