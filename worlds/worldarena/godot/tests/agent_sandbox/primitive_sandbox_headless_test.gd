extends SceneTree

const Authority := preload("res://scripts/agent_sandbox/primitive_sandbox_authority.gd")
const DemoPolicy := preload("res://scripts/agent_sandbox/primitive_sandbox_demo_policy.gd")
const ReplayVerifier := preload(
	"res://scripts/agent_sandbox/primitive_sandbox_replay_verifier.gd"
)
const SCENARIO_ROOT := "res://../games/primitive-sandbox/scenarios/"
const SANDBOX_ROOT := "res://../games/primitive-sandbox/"


func _init() -> void:
	_test_missing_response_is_neutral()
	_test_strict_decision_conformance_fixture()
	_test_profile_aware_leases()
	_test_authority_metrics_are_derived_and_hashed()
	_test_native_replay_verifier_fails_closed_on_tampering()
	_test_nominal_demo()
	_test_interrupted_demo()
	print("PRIMITIVE_SANDBOX_GODOT_TESTS_OK")
	quit(0)


func _test_missing_response_is_neutral() -> void:
	var authority: Variant = _authority("tree-chop-nominal-v0.json")
	var before: String = authority.state_hash()
	var boundary: Dictionary = authority.respond(null)
	assert(boundary["receipt"]["accepted"] == false)
	assert(boundary["receipt"]["fallback"] == "neutral")
	assert(boundary["receipt"]["no_input_reason"] == "missing")
	assert(boundary["receipt"]["applied_ticks"] == 0)
	assert(authority.tick == 0 and authority.state_hash() == before)


func _test_strict_decision_conformance_fixture() -> void:
	var fixture: Dictionary = _read_json(
		SANDBOX_ROOT + "fixtures/decision-conformance.v1.json"
	)
	assert(fixture["format"] == "worldeval-agent/decision-conformance/1.0.0")
	var profiles := {
		"dynamic": _read_json(
			SANDBOX_ROOT + "decision-profiles/dynamic-step-locked-v1.json"
		),
		"static": _read_json(
			SANDBOX_ROOT + "decision-profiles/static-event-gated-v1.json"
		),
	}
	var authorities := {
		"dynamic": _authority("tree-chop-nominal-v0.json", profiles["dynamic"]),
		"static": _authority("tree-chop-nominal-v0.json", profiles["static"]),
	}
	var seen: Dictionary = {}
	for case in fixture["cases"]:
		assert(not seen.has(case["id"]), "duplicate conformance case ID")
		seen[case["id"]] = true
		var document: Dictionary = fixture["bases"][case["base"]].duplicate(true)
		_apply_fixture_mutation(document, case.get("mutation"))
		var status: Dictionary = authorities[case["profile"]].decision_contract_status(document)
		assert(
			status["schema_valid"] == case["schema_valid"],
			"%s schema validity differed" % case["id"],
		)
		assert(
			status["contract_admissible"] == case["contract_admissible"],
			"%s action/profile admission differed" % case["id"],
		)

	var invalid_response: Dictionary = fixture["bases"]["abort"].duplicate(true)
	invalid_response["extra"] = true
	var invalid_authority = authorities["dynamic"]
	var before_hash: String = invalid_authority.state_hash()
	var invalid_boundary: Dictionary = invalid_authority.respond(invalid_response)
	assert(invalid_boundary["receipt"]["fallback"] == "neutral")
	assert(invalid_boundary["receipt"]["no_input_reason"] == "invalid")
	assert(invalid_authority.state_hash() == before_hash)
	assert(invalid_authority.decisions[-1] == null)

	var invalid_action: Dictionary = fixture["bases"]["replace"].duplicate(true)
	invalid_action["plan"]["source"] = invalid_authority.current_source()
	invalid_action["plan"]["steps"][0]["action"]["arguments"]["extra"] = true
	var rejected_boundary: Dictionary = invalid_authority.respond(invalid_action)
	assert(rejected_boundary["receipt"]["disposition"] == "rejected")
	assert(rejected_boundary["receipt"]["codes"].has("invalid_plan"))


func _test_profile_aware_leases() -> void:
	var fixture: Dictionary = _read_json(
		SANDBOX_ROOT + "fixtures/decision-conformance.v1.json"
	)
	var dynamic_authority = _authority(
		"tree-chop-nominal-v0.json",
		_read_json(SANDBOX_ROOT + "decision-profiles/dynamic-step-locked-v1.json"),
	)
	var dynamic_plan: Dictionary = fixture["bases"]["replace"].duplicate(true)
	dynamic_plan["plan"]["source"] = dynamic_authority.current_source()
	dynamic_plan["plan"]["lease_ticks"] = 6
	var dynamic_boundary: Dictionary = dynamic_authority.respond(dynamic_plan)
	assert(dynamic_boundary["receipt"]["accepted"] == false)
	assert(dynamic_boundary["receipt"]["codes"].has("invalid_plan"))
	assert(dynamic_authority.tick == 0)

	var static_authority = _authority(
		"tree-chop-nominal-v0.json",
		_read_json(SANDBOX_ROOT + "decision-profiles/static-event-gated-v1.json"),
	)
	var static_plan: Dictionary = fixture["bases"]["replace"].duplicate(true)
	static_plan["plan"]["source"] = static_authority.current_source()
	static_plan["plan"]["lease_ticks"] = 21
	var static_boundary: Dictionary = static_authority.respond(static_plan)
	assert(static_boundary["receipt"]["accepted"] == true)
	assert(static_boundary["receipt"]["applied_ticks"] == 21)
	assert(static_authority.agent["position"] == {"x": 23, "y": 12})

	var static_wait_authority = _authority(
		"tree-chop-nominal-v0.json",
		_read_json(SANDBOX_ROOT + "decision-profiles/static-event-gated-v1.json"),
	)
	var static_wait: Dictionary = fixture["bases"]["wait"].duplicate(true)
	static_wait["source"] = static_wait_authority.current_source()
	static_wait["maximum_ticks"] = 50
	var wait_boundary: Dictionary = static_wait_authority.respond(static_wait)
	assert(wait_boundary["receipt"]["accepted"] == true)
	assert(wait_boundary["receipt"]["applied_ticks"] == 50)
	assert(static_wait_authority.tick == 50)


func _test_authority_metrics_are_derived_and_hashed() -> void:
	var authority = _authority("tree-chop-nominal-v0.json")
	var before_hash: String = authority.state_hash()
	authority.forbidden_autonomy_count += 1
	authority.hostile_attacks += 2
	var state: Dictionary = authority.state_payload()
	assert(state["forbidden_autonomy_count"] == 1)
	assert(state["hostile_attacks"] == 2)
	assert(authority.state_hash() != before_hash)
	var replay: Dictionary = authority.native_replay("authority-metrics-test")
	assert(replay["authority_metrics"] == {
		"forbidden_autonomy_count": 1,
		"hostile_attacks": 2,
	})


func _test_native_replay_verifier_fails_closed_on_tampering() -> void:
	var scenario := _read_json(SCENARIO_ROOT + "tree-chop-nominal-v0.json")
	var authority: Variant = _authority("tree-chop-nominal-v0.json")
	DemoPolicy.run(authority)
	var replay: Dictionary = authority.native_replay("native-verifier-test", true)
	var verified: Dictionary = ReplayVerifier.verify(scenario, replay)
	assert(verified["verified"] == true)
	assert(verified["provider_calls"] == 0)
	assert(verified["final_state_hash"] == replay["terminal_state_hash"])

	var tampered: Dictionary = replay.duplicate(true)
	tampered["terminal_tick"] = int(tampered["terminal_tick"]) + 1
	var rejected: Dictionary = ReplayVerifier.verify(scenario, tampered)
	assert(rejected["verified"] == false)
	assert(rejected["reason"].begins_with("terminal_tick_mismatch"))


func _test_nominal_demo() -> void:
	var authority: Variant = _authority("tree-chop-nominal-v0.json")
	DemoPolicy.run(authority)
	assert(authority.outcome == "tree_destroyed")
	assert(not authority.objects.has("tree-7"))
	assert(authority.equipped == "axe")
	assert(authority.forbidden_autonomy_count == 0)
	assert(authority.hostile_attacks == 0)


func _test_interrupted_demo() -> void:
	var authority: Variant = _authority("tree-chop-interrupted-v0.json")
	DemoPolicy.run(authority)
	assert(authority.outcome == "safe_return")
	assert(authority.agent["position"]["x"] == 2 and authority.agent["position"]["y"] == 12)
	assert(authority.objects.has("tree-7"))
	assert(authority.objects.has("enemy-1"))
	assert(authority.hostile_attacks == 0)
	assert(authority.forbidden_autonomy_count == 0)
	var event_kinds: Array = []
	for observation in authority.observations:
		for event in observation["events"]:
			event_kinds.append(event["kind"])
	assert(event_kinds.has("movement_blocked"))
	assert(event_kinds.has("hostile_near_target"))
	var response_types: Array = []
	for receipt in authority.receipts:
		response_types.append(receipt["response_type"])
	assert(response_types.has("plan.abort"))


func _authority(filename: String, profile: Dictionary = {}):
	var scenario := _read_json(SCENARIO_ROOT + filename)
	var authority: Variant = Authority.new()
	authority.configure(scenario, "", profile)
	assert(authority.acknowledge_initialization(authority.initialization_hash))
	return authority


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	assert(file != null)
	var value = JSON.parse_string(file.get_as_text())
	assert(value is Dictionary)
	return value


func _apply_fixture_mutation(document: Dictionary, mutation) -> void:
	if mutation == null:
		return
	var path: Array = mutation["path"]
	var parent = document
	for index in range(path.size() - 1):
		var component = path[index]
		parent = parent[int(component)] if parent is Array else parent[component]
	var last = path[-1]
	if mutation["op"] == "set":
		if parent is Array:
			parent[int(last)] = mutation["value"].duplicate(true) if mutation["value"] is Dictionary or mutation["value"] is Array else mutation["value"]
		else:
			parent[last] = mutation["value"].duplicate(true) if mutation["value"] is Dictionary or mutation["value"] is Array else mutation["value"]
	elif mutation["op"] == "remove":
		if parent is Array:
			parent.remove_at(int(last))
		else:
			parent.erase(last)
	elif mutation["op"] == "duplicate_step":
		var steps: Array = parent[int(last)] if parent is Array else parent[last]
		steps.append(steps[0].duplicate(true))
	else:
		assert(false, "unknown conformance fixture mutation")
