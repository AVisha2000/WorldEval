extends SceneTree

const InteractionSystem := preload("res://scripts/embodiment/authority/interaction_system.gd")
const ConstructionSystem := preload("res://scripts/embodiment/authority/construction_system.gd")


class TestAuthority:
	extends RefCounted

	const PARTICIPANT_ID := "participant_0"

	var tick := 0
	var event_seq := 0
	var operator_position_mt := Vector2i.ZERO
	var operator_heading := 0
	var resource_position_mt := Vector2i(0, -1_000)
	var relay_position_mt := Vector2i(0, 1_000)
	var build_pad_position_mt := Vector2i(1_000, 0)
	var resource_units_remaining := 0
	var gather_progress_ticks := 0
	var inventory_material_units := 0
	var deposited_material_units := 0
	var active_interaction := "none"
	var barricade_progress_ticks := 0
	var barricade_complete := false
	var construction_active := false


var _failures := PackedStringArray()


func _init() -> void:
	_test_range_and_eight_sector_alignment()
	_test_gather_interruption_and_resume()
	_test_inventory_limit_and_deposit()
	_test_construction_material_and_resume()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_STAGE_BC_FAILURE: %s" % failure)
		print("EMBODIMENT_STAGE_BC_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("EMBODIMENT_STAGE_BC_OK")
	quit(0)


func _authority() -> TestAuthority:
	var authority := TestAuthority.new()
	InteractionSystem.reset(authority)
	ConstructionSystem.reset(authority)
	return authority


func _test_range_and_eight_sector_alignment() -> void:
	var authority := _authority()
	var events: Array[Dictionary] = []
	var sector_offsets := [
		Vector2i(0, -1_000), Vector2i(900, -900), Vector2i(1_000, 0),
		Vector2i(900, 900), Vector2i(0, 1_000), Vector2i(-900, 900),
		Vector2i(-1_000, 0), Vector2i(-900, -900),
	]
	for heading: int in 8:
		_check(
			InteractionSystem.is_facing(Vector2i.ZERO, heading, sector_offsets[heading]),
			"facing sector %d was not recognized" % heading,
		)
		_check(
			not InteractionSystem.is_facing(
				Vector2i.ZERO, posmod(heading + 1, 8), sector_offsets[heading]
			),
			"adjacent heading incorrectly matched sector %d" % heading,
		)
	authority.resource_position_mt = Vector2i(0, -2_000)
	authority.relay_position_mt = Vector2i(0, 2_000)
	var codes := InteractionSystem.apply_tick(authority, true, false, events)
	_check(InteractionSystem.CODE_OUT_OF_RANGE in codes, "out-of-range interaction was accepted")
	_check(events[-1].kind == InteractionSystem.EVENT_INTERACTION_OUT_OF_RANGE, "range event drifted")
	authority.resource_position_mt = Vector2i(900, -900)
	authority.operator_heading = 0
	codes = InteractionSystem.apply_tick(authority, true, false, events)
	_check(InteractionSystem.CODE_MISALIGNED in codes, "diagonal facing mismatch was accepted")
	authority.operator_heading = 1
	codes = InteractionSystem.apply_tick(authority, true, false, events)
	_check(InteractionSystem.CODE_GATHER_PROGRESS in codes, "north-east facing sector was rejected")
	_check(int(authority.gather_progress_ticks) == 1, "aligned gather did not progress")


func _test_gather_interruption_and_resume() -> void:
	var authority := _authority()
	var events: Array[Dictionary] = []
	for index: int in 2:
		authority.tick = index
		InteractionSystem.apply_tick(authority, true, false, events)
	_check(int(authority.gather_progress_ticks) == 2, "gather progress did not accumulate")
	authority.tick = 2
	var codes := InteractionSystem.apply_tick(authority, false, false, events)
	_check(InteractionSystem.CODE_INTERRUPTED in codes, "released gather was not interrupted")
	_check(int(authority.gather_progress_ticks) == 2, "interruption erased resumable gather progress")
	authority.tick = 3
	codes = InteractionSystem.apply_tick(authority, true, false, events)
	_check(InteractionSystem.CODE_GATHER_PROGRESS in codes, "resumed gather did not progress")
	authority.tick = 4
	codes = InteractionSystem.apply_tick(authority, true, false, events)
	_check(InteractionSystem.CODE_GATHER_COMPLETE in codes, "resumed gather did not complete")
	_check(int(authority.inventory_material_units) == 1, "gather completion did not add inventory")
	_check(int(authority.gather_progress_ticks) == 0, "completed gather did not reset unit progress")
	authority.tick = 5
	InteractionSystem.apply_tick(authority, true, false, events)
	authority.tick = 6
	codes = InteractionSystem.apply_tick(authority, true, true, events)
	_check(InteractionSystem.CODE_CANCELLED in codes, "explicit cancel did not stop gathering")
	_check(int(authority.gather_progress_ticks) == 1, "cancel erased resumable gather progress")


func _test_inventory_limit_and_deposit() -> void:
	var authority := _authority()
	var events: Array[Dictionary] = []
	authority.inventory_material_units = InteractionSystem.CARRY_LIMIT_UNITS
	var codes := InteractionSystem.apply_tick(authority, true, false, events)
	_check(InteractionSystem.CODE_INVENTORY_FULL in codes, "full inventory accepted another gather")
	_check(int(authority.resource_units_remaining) == InteractionSystem.RESOURCE_STARTING_UNITS, "full inventory consumed resource")
	authority.operator_position_mt = Vector2i.ZERO
	authority.operator_heading = 4
	authority.resource_position_mt = Vector2i(0, -4_000)
	authority.relay_position_mt = Vector2i(0, 1_000)
	codes = InteractionSystem.apply_tick(authority, true, false, events)
	_check(InteractionSystem.CODE_DEPOSIT_COMPLETE in codes, "relay deposit did not complete")
	_check(int(authority.inventory_material_units) == 0, "deposit did not clear carried material")
	_check(int(authority.deposited_material_units) == InteractionSystem.CARRY_LIMIT_UNITS, "deposit total drifted")
	_check(events[-1].kind == InteractionSystem.EVENT_MATERIAL_DEPOSITED, "deposit event drifted")


func _test_construction_material_and_resume() -> void:
	var authority := _authority()
	var events: Array[Dictionary] = []
	authority.build_pad_position_mt = Vector2i(2_000, 0)
	var codes := ConstructionSystem.apply_tick(authority, true, false, events)
	_check(ConstructionSystem.CODE_OUT_OF_RANGE in codes, "distant build pad was accepted")
	authority.build_pad_position_mt = Vector2i(1_000, 0)
	authority.operator_heading = 0
	codes = ConstructionSystem.apply_tick(authority, true, false, events)
	_check(ConstructionSystem.CODE_MISALIGNED in codes, "misaligned build interaction was accepted")
	authority.operator_heading = 2
	codes = ConstructionSystem.apply_tick(authority, true, false, events)
	_check(ConstructionSystem.CODE_INSUFFICIENT_MATERIAL in codes, "construction ignored material requirement")
	_check(int(authority.barricade_progress_ticks) == 0, "insufficient material advanced construction")
	authority.deposited_material_units = ConstructionSystem.BARRICADE_MATERIAL_REQUIRED
	for index: int in 3:
		authority.tick = index + 1
		ConstructionSystem.apply_tick(authority, true, false, events)
	_check(int(authority.barricade_progress_ticks) == 3, "construction progress did not accumulate")
	authority.tick = 4
	codes = ConstructionSystem.apply_tick(authority, false, false, events)
	_check(ConstructionSystem.CODE_INTERRUPTED in codes, "released construction was not interrupted")
	_check(int(authority.barricade_progress_ticks) == 3, "interruption erased construction progress")
	authority.tick = 5
	codes = ConstructionSystem.apply_tick(authority, true, false, events)
	_check(ConstructionSystem.CODE_PROGRESS in codes, "construction did not resume before cancel")
	authority.tick = 6
	codes = ConstructionSystem.apply_tick(authority, true, true, events)
	_check(ConstructionSystem.CODE_CANCELLED in codes, "construction cancel code drifted")
	_check(int(authority.barricade_progress_ticks) == 4, "cancel erased construction progress")
	_check(events[-1].kind == ConstructionSystem.EVENT_CONSTRUCTION_CANCELLED, "cancel event drifted")
	for index: int in 2:
		authority.tick = index + 7
		codes = ConstructionSystem.apply_tick(authority, true, false, events)
	_check(ConstructionSystem.CODE_COMPLETE in codes, "resumed construction did not complete")
	_check(bool(authority.barricade_complete), "barricade completion state was not set")
	_check(int(authority.deposited_material_units) == 0, "construction did not spend exact material")
	_check(events[-1].kind == ConstructionSystem.EVENT_BARRICADE_COMPLETED, "completion event drifted")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
