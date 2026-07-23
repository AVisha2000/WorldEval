extends SceneTree

const Authority := preload("res://scripts/conversational_sandbox/conversational_warehouse_authority.gd")
const ReplayVerifier := preload("res://scripts/conversational_sandbox/conversational_warehouse_replay_verifier.gd")
const SCENARIO := "res://../games/conversational-warehouse/scenario.json"

func _init() -> void:
	_test_ambiguity_requires_clarification()
	_test_bound_delivery_requires_explicit_replan()
	_test_wrong_bound_box_is_a_terminal_failure()
	_test_revoked_binding_is_rejected()
	print("CONVERSATIONAL_WAREHOUSE_GODOT_TESTS_OK")
	quit(0)

func _test_ambiguity_requires_clarification() -> void:
	var authority = _authority()
	authority.begin_intent("intent-blue", 1, "pick up the blue box")
	var result: Dictionary = authority.request_binding("intent-blue", ["box-blue-large-1", "box-blue-small-1"])
	assert(result["receipt"]["accepted"] == false)
	assert(result["receipt"]["code"] == "clarification_required")
	assert(authority.carrying_id == "")
	assert(authority.tick == 0)

func _test_bound_delivery_requires_explicit_replan() -> void:
	var authority = _authority()
	authority.begin_intent("intent-delivery", 1, "take the large blue box to bay B")
	assert(authority.bind_target("intent-delivery", "binding-large-blue", "box-blue-large-1", 1)["receipt"]["accepted"])
	_move(authority, "intent-delivery", "binding-large-blue", {"x": 4, "y": 3})
	assert(authority.command(_command(authority, "pickup", "intent-delivery", "binding-large-blue"))["receipt"]["code"] == "pickup_complete")
	var blocked: Dictionary = authority.command(_command(authority, "move", "intent-delivery", "binding-large-blue", {"x": 13, "y": 5}))
	assert(blocked["receipt"]["code"] == "movement_blocked")
	assert(authority.command(_command(authority, "move", "intent-delivery", "binding-large-blue", {"x": 6, "y": 2}))["receipt"]["code"] == "replan_required")
	assert(authority.command({"type": "replan", "intent_id": "intent-delivery", "source": authority.current_source()})["receipt"]["accepted"])
	_move(authority, "intent-delivery", "binding-large-blue", {"x": 6, "y": 2})
	_move(authority, "intent-delivery", "binding-large-blue", {"x": 8, "y": 2})
	_move(authority, "intent-delivery", "binding-large-blue", {"x": 13, "y": 5})
	assert(authority.command(_command(authority, "place", "intent-delivery", "binding-large-blue", {}, "loading-bay-b"))["receipt"]["accepted"])
	assert(authority.terminal and authority.outcome == "delivered")
	var replay: Dictionary = authority.native_replay("warehouse-delivery", true)
	assert(replay["provider_calls"] == 0 and replay["terminal_outcome"] == "delivered")
	assert(ReplayVerifier.verify(_scenario(), replay)["verified"])
	var tampered := replay.duplicate(true)
	tampered["terminal_tick"] = int(tampered["terminal_tick"]) + 1
	assert(not ReplayVerifier.verify(_scenario(), tampered)["verified"])

func _test_revoked_binding_is_rejected() -> void:
	var authority = _authority()
	authority.begin_intent("intent-revise", 1, "pick the blue box")
	authority.bind_target("intent-revise", "binding-old", "box-blue-large-1", 1)
	authority.revise_intent("intent-revise", 2)
	var result: Dictionary = authority.command(_command(authority, "move", "intent-revise", "binding-old", {"x": 4, "y": 3}))
	assert(result["receipt"]["code"] == "stale_or_revoked_binding")

func _test_wrong_bound_box_is_a_terminal_failure() -> void:
	var authority = _authority()
	authority.begin_intent("intent-small", 1, "take the small blue box to bay B")
	assert(authority.bind_target("intent-small", "binding-small-blue", "box-blue-small-1", 1)["receipt"]["accepted"])
	_move(authority, "intent-small", "binding-small-blue", {"x": 4, "y": 6})
	assert(authority.command(_command(authority, "pickup", "intent-small", "binding-small-blue"))["receipt"]["accepted"])
	_move(authority, "intent-small", "binding-small-blue", {"x": 13, "y": 5})
	assert(authority.command(_command(authority, "place", "intent-small", "binding-small-blue", {}, "loading-bay-b"))["receipt"]["accepted"])
	assert(authority.terminal and authority.outcome == "wrong_box_delivered")

func _authority():
	var authority = Authority.new()
	authority.configure(_scenario())
	assert(authority.acknowledge_initialization(authority.initialization_hash))
	return authority

func _scenario() -> Dictionary:
	var file := FileAccess.open(SCENARIO, FileAccess.READ)
	return JSON.parse_string(file.get_as_text())

func _move(authority, intent_id: String, binding_id: String, target: Dictionary) -> void:
	var result: Dictionary = authority.command(_command(authority, "move", intent_id, binding_id, target))
	assert(result["receipt"]["accepted"])

func _command(authority, kind: String, intent_id: String, binding_id: String, target := {}, bay_id := "") -> Dictionary:
	var value := {"type": kind, "intent_id": intent_id, "binding_id": binding_id, "source": authority.current_source()}
	if kind == "move": value["target"] = target
	if kind == "place": value["bay_id"] = bay_id
	return value
