class_name ConversationalWarehouseAuthority
extends RefCounted

## Deterministic, typed authority for conversational warehouse tasks.  The
## adapter may phrase and ground a task, but only this class changes the world.

const PROTOCOL := "worldeval-agent/0.1.0"
const REPLAY_SCHEMA := "conversational-warehouse-replay.v1"

var scenario: Dictionary = {}
var tick := 0
var agent: Dictionary = {}
var objects: Dictionary = {}
var carrying_id := ""
var barrier_spawned := false
var suspended_for_replan := false
var terminal := false
var outcome = ""
var initialization_hash := ""
var initialization_acknowledged := false
var observation_seq := 0
var receipt_seq := 0
var active_intent: Dictionary = {}
var bindings: Dictionary = {}
var events: Array = []
var observations: Array = []
var receipts: Array = []
var decisions: Array = []
var history: Array = []


func configure(value: Dictionary, expected_initialization_hash := "") -> void:
	assert(value.get("schema_version") == "conversational-warehouse-scenario.v1")
	scenario = _integerize(value)
	tick = 0
	agent = scenario["agent"].duplicate(true)
	objects = {}
	for item in scenario["objects"]:
		objects[item["object_id"]] = item.duplicate(true)
	carrying_id = ""
	barrier_spawned = false
	suspended_for_replan = false
	terminal = false
	outcome = ""
	active_intent = {}
	bindings = {}
	events = []
	observations = []
	receipts = []
	decisions = []
	history = []
	receipt_seq = 0
	observation_seq = 0
	initialization_acknowledged = false
	initialization_hash = expected_initialization_hash if not expected_initialization_hash.is_empty() else _hash({
		"protocol": PROTOCOL,
		"scenario": scenario,
	})
	_record_observation()


func acknowledge_initialization(value: String) -> bool:
	initialization_acknowledged = value == initialization_hash
	return initialization_acknowledged


func current_source() -> Dictionary:
	return {"observation_seq": observation_seq, "tick": tick, "state_hash": state_hash()}


func current_observation() -> Dictionary:
	return observations[-1].duplicate(true)


func begin_intent(intent_id: String, revision: int, text: String) -> Dictionary:
	_record_decision({"kind": "intent.begin", "intent_id": intent_id, "revision": revision, "text": text})
	if not _identifier(intent_id) or revision < 1 or text.is_empty():
		return _emit_receipt("intent.begin", false, "invalid_intent", {})
	if not active_intent.is_empty() and revision <= int(active_intent["revision"]):
		return _emit_receipt("intent.begin", false, "stale_intent_revision", {})
	active_intent = {"intent_id": intent_id, "revision": revision, "text": text, "revoked": false}
	bindings = {}
	return _emit_receipt("intent.begin", true, "intent_active", {"intent_id": intent_id, "revision": revision})


func request_binding(intent_id: String, candidate_ids: Array) -> Dictionary:
	_record_decision({"kind": "binding.request", "intent_id": intent_id, "candidate_ids": candidate_ids.duplicate(true)})
	if not _active_intent(intent_id):
		return _emit_receipt("binding.request", false, "stale_or_revoked_intent", {})
	var visible: Array = []
	for object_id in candidate_ids:
		if objects.has(object_id) and objects[object_id]["state"].get("visible", false):
			visible.append(object_id)
	visible.sort()
	if visible.size() != 1:
		events = [{"kind": "clarification_required", "candidate_ids": visible}]
		return _emit_receipt("binding.request", false, "clarification_required", {"candidate_ids": visible})
	return _bind_target(intent_id, "binding-%03d" % (bindings.size() + 1), visible[0], int(objects[visible[0]]["generation"]))


func bind_target(intent_id: String, binding_id: String, object_id: String, generation: int) -> Dictionary:
	_record_decision({"kind": "binding.resolve", "intent_id": intent_id, "binding_id": binding_id, "object_id": object_id, "generation": generation})
	return _bind_target(intent_id, binding_id, object_id, generation)


func _bind_target(intent_id: String, binding_id: String, object_id: String, generation: int) -> Dictionary:
	if not _active_intent(intent_id):
		return _emit_receipt("binding.resolve", false, "stale_or_revoked_intent", {})
	if not _identifier(binding_id) or not objects.has(object_id):
		return _emit_receipt("binding.resolve", false, "unknown_target", {})
	var target: Dictionary = objects[object_id]
	if int(target["generation"]) != generation or not target["state"].get("visible", false):
		return _emit_receipt("binding.resolve", false, "stale_target", {})
	bindings[binding_id] = {"intent_id": intent_id, "object_id": object_id, "generation": generation, "revoked": false}
	return _emit_receipt("binding.resolve", true, "binding_active", {"binding_id": binding_id, "object_id": object_id})


func revise_intent(intent_id: String, revision: int) -> Dictionary:
	_record_decision({"kind": "intent.revise", "intent_id": intent_id, "revision": revision})
	if not _active_intent(intent_id) or revision <= int(active_intent["revision"]):
		return _emit_receipt("intent.revise", false, "stale_or_revoked_intent", {})
	active_intent["revision"] = revision
	for binding in bindings.values():
		binding["revoked"] = true
	return _emit_receipt("intent.revise", true, "intent_revised", {"revision": revision})


func command(value) -> Dictionary:
	assert(initialization_acknowledged, "environment initialization must be acknowledged")
	_record_decision({"kind": "command", "command": value.duplicate(true) if value is Dictionary else value})
	events = []
	if not value is Dictionary:
		return _emit_receipt("command", false, "invalid_command", {})
	var command_type: String = str(value.get("type", ""))
	if command_type == "replan":
		return _replan(value)
	if not _fresh_source(value.get("source")):
		return _emit_receipt(command_type, false, "stale_source", {})
	if terminal:
		return _emit_receipt(command_type, false, "episode_terminal", {})
	if suspended_for_replan:
		return _emit_receipt(command_type, false, "replan_required", {})
	if not _binding_active(value):
		return _emit_receipt(command_type, false, "stale_or_revoked_binding", {})
	match command_type:
		"move":
			return _move(value)
		"pickup":
			return _pickup(value)
		"place":
			return _place(value)
		_:
			return _emit_receipt(command_type, false, "invalid_command", {})


func state_payload() -> Dictionary:
	var listed: Array = []
	var ids := objects.keys()
	ids.sort()
	for object_id in ids:
		listed.append(objects[object_id].duplicate(true))
	return {
		"tick": tick,
		"agent": {"object_id": agent["object_id"], "position": agent["position"].duplicate(true), "carrying_id": carrying_id},
		"objects": listed,
		"barrier_spawned": barrier_spawned,
		"suspended_for_replan": suspended_for_replan,
		"terminal": terminal,
		"outcome": outcome,
	}


func state_hash() -> String:
	return _hash(state_payload())


func native_replay(run_id: String, offline_verified := false) -> Dictionary:
	return {
		"schema_version": REPLAY_SCHEMA,
		"protocol": PROTOCOL,
		"run_id": run_id,
		"environment_id": scenario["environment_id"],
		"scenario_id": scenario["scenario_id"],
		"initialization_hash": initialization_hash,
		"terminal_state_hash": state_hash(),
		"terminal_tick": tick,
		"terminal_outcome": outcome if terminal else "incomplete",
		"observations": observations.duplicate(true),
		"decisions": decisions.duplicate(true),
		"receipts": receipts.duplicate(true),
		"history": history.duplicate(true),
		"provider_calls": 0,
		"offline_verified": offline_verified,
	}


func _replan(value: Dictionary) -> Dictionary:
	if not _fresh_source(value.get("source")):
		return _emit_receipt("replan", false, "stale_source", {})
	if not _active_intent(str(value.get("intent_id", ""))):
		return _emit_receipt("replan", false, "stale_or_revoked_intent", {})
	suspended_for_replan = false
	return _emit_receipt("replan", true, "replan_accepted", {})


func _move(value: Dictionary) -> Dictionary:
	var target = value.get("target")
	if not target is Dictionary or not target.has("x") or not target.has("y"):
		return _emit_receipt("move", false, "invalid_target", {})
	var destination := {"x": int(target["x"]), "y": int(target["y"])}
	var moved := 0
	while not _same(agent["position"], destination) and tick < int(scenario["tick_budget"]):
		var next := _direct_step(agent["position"], destination)
		if barrier_spawned and _same(next, objects[scenario["barrier"]["object_id"]]["position"]):
			suspended_for_replan = true
			events = [{"kind": "movement_blocked", "object_id": scenario["barrier"]["object_id"], "data": {"at": next}}]
			return _emit_receipt("move", false, "movement_blocked", {"applied_ticks": moved})
		agent["position"] = next
		tick += 1
		moved += 1
	_check_timeout()
	return _emit_receipt("move", not terminal, "target_reached" if not terminal else "timeout", {"applied_ticks": moved})


func _pickup(value: Dictionary) -> Dictionary:
	var binding: Dictionary = bindings[str(value["binding_id"])]
	var target: Dictionary = objects[binding["object_id"]]
	if carrying_id != "":
		return _emit_receipt("pickup", false, "already_carrying", {})
	if _distance(agent["position"], target["position"]) > 0:
		return _emit_receipt("pickup", false, "target_out_of_range", {})
	carrying_id = binding["object_id"]
	target["state"]["carried"] = true
	target["position"] = agent["position"].duplicate(true)
	tick += 1
	if not barrier_spawned:
		barrier_spawned = true
		objects[scenario["barrier"]["object_id"]] = scenario["barrier"].duplicate(true)
		events = [{"kind": "barrier_appeared", "object_id": scenario["barrier"]["object_id"], "data": {}}]
	return _emit_receipt("pickup", true, "pickup_complete", {"object_id": carrying_id})


func _place(value: Dictionary) -> Dictionary:
	var bay_id: String = str(value.get("bay_id", ""))
	if carrying_id == "" or not objects.has(bay_id) or objects[bay_id]["type_id"] != "loading_bay":
		return _emit_receipt("place", false, "invalid_place", {})
	if _distance(agent["position"], objects[bay_id]["position"]) > 0:
		return _emit_receipt("place", false, "bay_out_of_range", {})
	var placed_id := carrying_id
	objects[placed_id]["state"]["carried"] = false
	objects[placed_id]["position"] = objects[bay_id]["position"].duplicate(true)
	carrying_id = ""
	tick += 1
	if placed_id == scenario["success"]["box_id"] and bay_id == scenario["success"]["bay_id"]:
		terminal = true
		outcome = "delivered"
	elif bay_id == scenario["success"]["bay_id"]:
		# A wrong but explicitly selected box is a terminal, replayable failure.
		# The game records the outcome; it does not silently substitute a target.
		terminal = true
		outcome = "wrong_box_delivered"
	return _emit_receipt("place", true, "place_complete", {"object_id": placed_id, "bay_id": bay_id})


func _binding_active(value: Dictionary) -> bool:
	var intent_id: String = str(value.get("intent_id", ""))
	var binding_id: String = str(value.get("binding_id", ""))
	return _active_intent(intent_id) and bindings.has(binding_id) and not bindings[binding_id].get("revoked", true) and bindings[binding_id]["intent_id"] == intent_id


func _active_intent(intent_id: String) -> bool:
	return not active_intent.is_empty() and active_intent["intent_id"] == intent_id and not active_intent.get("revoked", false)


func _fresh_source(value) -> bool:
	# JSON transports may deserialize whole-number grid fields as floats. Compare
	# the typed boundary explicitly so a valid observation reference is not made
	# stale solely by that representation detail.
	if not value is Dictionary:
		return false
	var current := current_source()
	return int(value.get("observation_seq", -1)) == int(current["observation_seq"]) and int(value.get("tick", -1)) == int(current["tick"]) and str(value.get("state_hash", "")) == str(current["state_hash"])


func _emit_receipt(kind: String, accepted: bool, code: String, details: Dictionary) -> Dictionary:
	receipt_seq += 1
	var receipt := {"receipt_id": "warehouse-%06d" % receipt_seq, "kind": kind, "accepted": accepted, "code": code, "tick": tick, "details": details.duplicate(true)}
	receipts.append(receipt.duplicate(true))
	observation_seq += 1
	_record_observation()
	return {"receipt": receipt, "observation": current_observation()}


func _record_decision(value: Dictionary) -> void:
	decisions.append(value.duplicate(true))
	history = decisions.duplicate(true)


func _record_observation() -> void:
	var visible: Array = []
	var ids := objects.keys()
	ids.sort()
	for object_id in ids:
		visible.append(objects[object_id].duplicate(true))
	observations.append({
		"schema_version": "observation.v1", "protocol": PROTOCOL,
		"environment_id": scenario["environment_id"], "observation_seq": observation_seq,
		"tick": tick, "state_hash": state_hash(), "coordinate_frame": scenario["coordinate_frame"],
		"controlled_assets": [{"object_id": agent["object_id"], "position": agent["position"].duplicate(true), "carrying_id": carrying_id}],
		"visible_objects": visible, "events": events.duplicate(true),
		"decision_required": {"replan_required": suspended_for_replan}, "terminal": terminal,
	})


func _direct_step(current: Dictionary, target: Dictionary) -> Dictionary:
	var dx: int = int(target["x"]) - int(current["x"])
	var dy: int = int(target["y"]) - int(current["y"])
	if dx != 0:
		return {"x": int(current["x"]) + (1 if dx > 0 else -1), "y": int(current["y"])}
	return {"x": int(current["x"]), "y": int(current["y"]) + (1 if dy > 0 else -1)}


func _distance(a: Dictionary, b: Dictionary) -> int:
	return absi(int(a["x"]) - int(b["x"])) + absi(int(a["y"]) - int(b["y"]))


func _same(a: Dictionary, b: Dictionary) -> bool:
	return int(a["x"]) == int(b["x"]) and int(a["y"]) == int(b["y"])


func _check_timeout() -> void:
	if tick >= int(scenario["tick_budget"]):
		terminal = true
		outcome = "timeout"


func _identifier(value) -> bool:
	return value is String and value.length() > 0 and value.length() <= 128


func _hash(value) -> String:
	return "sha256:" + JSON.stringify(value, "", true, false).sha256_text()


func _integerize(value):
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = _integerize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for child in value:
			result.append(_integerize(child))
		return result
	if typeof(value) == TYPE_FLOAT and value == floor(value):
		return int(value)
	return value
