extends SceneTree

## Credential-free deterministic release soak.
##
## This runner deliberately uses direct authority objects in one Godot process.  Every case is
## executed twice from the same seed/action sequence and the checkpoint, replay/trace hash,
## terminal result, receipts, and public authority aggregates are compared.  The first multiplayer
## window contains an explicit no_input seat so the soak also proves neutral fallback advances the
## shared clock.  Only participant observations and allow-listed aggregate output are privacy
## scanned; protected replay/checkpoint material is never treated as a public response.

const SoloAuthority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const DuelAuthority := preload(
	"res://scripts/embodiment/duel_authority/embodiment_duel_authority.gd"
)
const MazeAuthority := preload(
	"res://scripts/embodiment/control_games/movement_maze_authority.gd"
)
const CourseAuthority := preload(
	"res://scripts/embodiment/control_games/operator_action_course_authority.gd"
)
const CheckpointRaceAuthority := preload(
	"res://scripts/embodiment/duo_games/checkpoint_race_authority.gd"
)
const RelayControlAuthority := preload(
	"res://scripts/embodiment/duo_games/relay_control_authority.gd"
)
const SparAuthority := preload("res://scripts/embodiment/duo_games/spar_authority.gd")
const ResourceRelayAuthority := preload(
	"res://scripts/embodiment/duo_games/resource_relay_authority.gd"
)
const TrioRelayAuthority := preload(
	"res://scripts/embodiment/trio_games/trio_relay_authority.gd"
)
const TrioFreeForAllAuthority := preload(
	"res://scripts/embodiment/trio_games/trio_free_for_all_authority.gd"
)
const CheckpointSerializer := preload(
	"res://scripts/embodiment/authority/checkpoint_serializer.gd"
)

const OUTPUT_PREFIX := "EMBODIMENT_RELEASE_SOAK_EVIDENCE="
const DEFAULT_ROUNDS := 22
const SOLO_CASES := [
	{"scenario_id": "orientation-v0", "task_id": "orientation-v0", "kind": "v1"},
	{"scenario_id": "interaction-v0", "task_id": "interaction-v0", "kind": "v1"},
	{"scenario_id": "construction-v0", "task_id": "construction-v0", "kind": "v1"},
	{"scenario_id": "neutral-encounter-v0", "task_id": "neutral-encounter-v0", "kind": "v1"},
	{"scenario_id": "multi-action-demo-v0", "task_id": "construction-v0", "kind": "v1"},
	{"scenario_id": "movement-maze-v0", "task_id": "movement-maze-v0", "kind": "maze"},
	{
		"scenario_id": "operator-action-course-v0",
		"task_id": "operator-action-course-v0",
		"kind": "course",
	},
]
const DUO_CASES := [
	{"task_id": "central-relay-v0", "kind": "central"},
	{"task_id": "duo-checkpoint-race-v0", "kind": "checkpoint"},
	{"task_id": "duo-relay-control-v0", "kind": "relay"},
	{"task_id": "duo-spar-v0", "kind": "spar"},
	{"task_id": "duo-resource-relay-v0", "kind": "resource"},
]
const TRIO_CASES := [
	{"task_id": "trio-relay-v0", "kind": "relay"},
	{"task_id": "trio-free-for-all-v0", "kind": "free_for_all"},
]
const DUO_PARTICIPANTS := ["participant_0", "participant_1"]
const TRIO_PARTICIPANTS := ["participant_0", "participant_1", "participant_2"]
const BUTTONS := [
	"interact", "primary", "guard", "dash", "ability_1", "ability_2", "cycle_item", "cancel",
]
const FORBIDDEN_PUBLIC_TOKENS := [
	"position_mt", "position_axial", "coordinate", "transform", "hidden_state",
	"spectator", "prompt", "raw_output", "raw_model_output", "credential", "api_key",
	"authorization", "session_secret", "attachment_ticket", "resource_stock",
	"barricade_health", "checkpoint_hash", "replay_windows",
]

var _failures := PackedStringArray()
var _case_counts := {}
var _execution_count := 0
var _invalid_neutral_windows := 0
var _memory_samples := PackedInt64Array()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var started_ms := Time.get_ticks_msec()
	_memory_samples.append(OS.get_static_memory_usage())
	var rounds := _requested_rounds()
	for round_index: int in rounds:
		for case: Dictionary in SOLO_CASES:
			_compare_pair("solo", case.scenario_id, round_index, 0, case)
		for case: Dictionary in DUO_CASES:
			for leg_index: int in 2:
				_compare_pair("duo", case.task_id, round_index, leg_index, case)
		for case: Dictionary in TRIO_CASES:
			for rotation: int in 3:
				_compare_pair("trio", case.task_id, round_index, rotation, case)
		_memory_samples.append(OS.get_static_memory_usage())
		await process_frame
	_validate_resource_bounds(rounds)
	var duration_ms := Time.get_ticks_msec() - started_ms
	var summary := {
		"authority_ticks": _sum_case_metric("authority_ticks"),
		"case_counts": _case_counts,
		"duration_ms": duration_ms,
		"execution_count": _execution_count,
		"invalid_neutral_windows": _invalid_neutral_windows,
		"memory": {
			"baseline_bytes": int(_memory_samples[0]),
			"final_bytes": int(_memory_samples[-1]),
			"growth_bytes": int(_memory_samples[-1] - _memory_samples[0]),
			"peak_bytes": _maximum_memory(),
			"sample_count": _memory_samples.size(),
		},
		"privacy_scans": _sum_case_metric("privacy_scans"),
		"rounds": rounds,
		"variant_count": SOLO_CASES.size() + DUO_CASES.size() * 2 + TRIO_CASES.size() * 3,
	}
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("EMBODIMENT_RELEASE_SOAK_FAILURE: %s" % failure)
		print(OUTPUT_PREFIX + JSON.stringify(summary))
		print("EMBODIMENT_RELEASE_SOAK_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print(OUTPUT_PREFIX + JSON.stringify(summary))
	print("EMBODIMENT_RELEASE_SOAK_OK")
	quit(0)


func _requested_rounds() -> int:
	var rounds := DEFAULT_ROUNDS
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--rounds="):
			rounds = int(argument.trim_prefix("--rounds="))
	if rounds < 1 or rounds > 1000:
		_fail("round count must be between 1 and 1000")
		return DEFAULT_ROUNDS
	return rounds


func _compare_pair(
		family: String, identity: String, round_index: int, seat_variant: int, case: Dictionary
) -> void:
	var first := _execute(family, identity, round_index, seat_variant, case)
	var second := _execute(family, identity, round_index, seat_variant, case)
	_execution_count += 2
	var key := "%s:%s:%d" % [family, identity, seat_variant]
	if not _case_counts.has(key):
		_case_counts[key] = {"authority_ticks": 0, "executions": 0, "privacy_scans": 0}
	_case_counts[key].executions += 2
	_case_counts[key].authority_ticks += int(first.get("authority_ticks", 0)) * 2
	_case_counts[key].privacy_scans += int(first.get("privacy_scans", 0)) * 2
	for field: String in ["checkpoint_hash", "replay_hash", "terminal", "public_hash"]:
		_check(
			first.get(field) == second.get(field),
			"%s repeat drift for %s in round %d" % [field, key, round_index],
		)
	_check(bool(first.get("terminal", {}).get("ended", false)), "%s did not terminate" % key)
	_check(int(first.get("authority_ticks", 0)) > 0, "%s did not advance authority" % key)


func _execute(
		family: String, identity: String, round_index: int, seat_variant: int, case: Dictionary
) -> Dictionary:
	var suffix := "%s_%d_%d" % [identity.replace("-", "_"), round_index, seat_variant]
	match family:
		"solo": return _execute_solo(case, suffix, round_index)
		"duo": return _execute_duo(case, suffix, seat_variant)
		"trio": return _execute_trio(case, suffix, seat_variant)
		_:
			_fail("unknown soak family %s" % family)
			return {}


func _execute_solo(case: Dictionary, suffix: String, seed: int) -> Dictionary:
	var authority: Object
	var errors: PackedStringArray
	var replay_hash := ""
	var trace: Array = []
	var privacy_scans := 0
	match str(case.kind):
		"v1":
			authority = SoloAuthority.new()
			errors = authority.configure({
				"episode_id": "ep_soak_%s" % suffix,
				"maximum_episode_ticks": 1,
				"mode": "solo-curriculum-v0",
				"observation_profile": "text-visible-v1",
				"participant_ids": ["participant_0"],
				"task_id": case.task_id,
			})
			_check(errors.is_empty(), "%s configuration failed: %s" % [case.scenario_id, errors])
			var result: Dictionary = authority.step_window(_solo_window(authority))
			trace.append(result.state_hash)
			replay_hash = CheckpointSerializer.hash_checkpoint({"trace": trace})
			_scan_public(authority.observe(), "%s observation" % case.scenario_id)
			_scan_public({"receipts": result.receipts,
				"events": result.get("events", result.get("public_events", [])),
				"terminal": result.terminal}, "%s result" % case.scenario_id)
			privacy_scans += 2
		"maze", "course":
			authority = MazeAuthority.new() if case.kind == "maze" else CourseAuthority.new()
			errors = authority.configure({
				"protocol_version": "llm-controller/0.2.0", "task_id": case.task_id,
				"episode_id": "ep_soak_%s" % suffix, "participant_id": "participant_0",
				"maximum_episode_ticks": 1, "seed": seed,
			})
			_check(errors.is_empty(), "%s configuration failed: %s" % [case.scenario_id, errors])
			var result: Dictionary = authority.step_window(
				_control_action(authority, "participant_0", 1))
			replay_hash = CheckpointSerializer.hash_checkpoint(authority.replay())
			_scan_public(authority.observe(), "%s observation" % case.scenario_id)
			_scan_public(authority.authority_aggregates(), "%s aggregates" % case.scenario_id)
			_scan_public({"receipts": result.receipts,
				"events": result.get("events", result.get("public_events", [])),
				"terminal": result.terminal}, "%s result" % case.scenario_id)
			privacy_scans += 3
		_:
			_fail("unknown solo case kind %s" % case.kind)
			return {}
	var public_value := {"observation": authority.observe(), "terminal": authority.terminal}
	return {
		"authority_ticks": authority.tick,
		"checkpoint_hash": authority.checkpoint_hash(),
		"public_hash": CheckpointSerializer.hash_checkpoint(public_value),
		"privacy_scans": privacy_scans,
		"replay_hash": replay_hash,
		"terminal": authority.terminal.duplicate(true),
	}


func _execute_duo(case: Dictionary, suffix: String, leg_index: int) -> Dictionary:
	var authority: Object
	match str(case.kind):
		"central": authority = DuelAuthority.new()
		"checkpoint": authority = CheckpointRaceAuthority.new()
		"relay": authority = RelayControlAuthority.new()
		"spar": authority = SparAuthority.new()
		"resource": authority = ResourceRelayAuthority.new()
		_:
			_fail("unknown duo kind %s" % case.kind)
			return {}
	var errors: PackedStringArray
	if case.kind == "central":
		errors = authority.configure({
			"episode_id": "ep_soak_%s" % suffix, "mode": "model-duel-v0",
			"task_id": case.task_id, "participant_ids": DUO_PARTICIPANTS,
			"observation_profile": "text-visible-v1", "maximum_episode_ticks": 1800,
		})
	else:
		errors = authority.configure({
			"protocol_version": "llm-controller/0.2.0", "task_id": case.task_id,
			"episode_id": "ep_soak_%s" % suffix, "participant_ids": DUO_PARTICIPANTS,
			"maximum_episode_ticks": 1200,
		})
	_check(errors.is_empty(), "%s leg %d configuration failed: %s" % [case.task_id, leg_index, errors])
	var trace: Array = []
	var privacy_scans := 0
	while not authority.terminal.ended:
		var first_window: bool = int(authority.observation_seq) == 0
		var window: Dictionary = _duo_window(authority, str(case.kind), first_window, leg_index)
		var result: Dictionary = authority.step_window(window)
		if first_window:
			_check(result.receipts.participant_0.disposition == "no_input",
				"%s leg %d did not neutralize missing seat" % [case.task_id, leg_index])
			_check(result.receipts.participant_0.applied_ticks == 10,
				"%s leg %d neutral window stalled time" % [case.task_id, leg_index])
			_invalid_neutral_windows += 1
		_scan_public({"receipts": result.receipts,
			"events": result.get("events", result.get("public_events", [])),
			"terminal": result.terminal}, "%s decision result" % case.task_id)
		privacy_scans += 1
		trace.append(result.state_hash if result.has("state_hash") else authority.checkpoint_hash())
	var replay_hash: String = (
		CheckpointSerializer.hash_checkpoint({"trace": trace})
		if case.kind == "central" else authority.replay_hash()
	)
	var observations := {}
	for participant_id: String in DUO_PARTICIPANTS:
		observations[participant_id] = authority.observe(participant_id)
	_scan_public(observations, "%s participant observations" % case.task_id)
	privacy_scans += 1
	var aggregates: Dictionary = {} if case.kind == "central" else authority.authority_aggregates()
	if not aggregates.is_empty():
		_scan_public(aggregates, "%s aggregates" % case.task_id)
		privacy_scans += 1
	var public_value := {"observations": observations, "terminal": authority.terminal,
		"aggregates": aggregates}
	return {
		"authority_ticks": authority.tick,
		"checkpoint_hash": authority.checkpoint_hash(),
		"public_hash": CheckpointSerializer.hash_checkpoint(public_value),
		"privacy_scans": privacy_scans,
		"replay_hash": replay_hash,
		"terminal": authority.terminal.duplicate(true),
	}


func _execute_trio(case: Dictionary, suffix: String, rotation: int) -> Dictionary:
	var authority: Object = (
		TrioRelayAuthority.new() if case.kind == "relay" else TrioFreeForAllAuthority.new()
	)
	var errors: PackedStringArray = authority.configure({
		"protocol_version": "llm-controller/0.3.0", "task_id": case.task_id,
		"episode_id": "ep_soak_%s" % suffix, "participant_ids": TRIO_PARTICIPANTS,
		"maximum_episode_ticks": 1200, "seat_rotation": rotation,
	})
	_check(errors.is_empty(), "%s rotation %d configuration failed: %s" % [case.task_id, rotation, errors])
	var privacy_scans := 0
	while not authority.terminal.ended:
		var first_window: bool = int(authority.observation_seq) == 0
		var result: Dictionary = authority.step_window(_trio_window(authority, first_window, rotation))
		if first_window:
			_check(result.receipts.participant_0.disposition == "no_input",
				"%s rotation %d did not neutralize missing seat" % [case.task_id, rotation])
			_check(result.receipts.participant_0.applied_ticks == 10,
				"%s rotation %d neutral window stalled time" % [case.task_id, rotation])
			_invalid_neutral_windows += 1
		_scan_public({"receipts": result.receipts,
			"events": result.get("events", result.get("public_events", [])),
			"terminal": result.terminal}, "%s decision result" % case.task_id)
		privacy_scans += 1
	var observations := {}
	for participant_id: String in TRIO_PARTICIPANTS:
		observations[participant_id] = authority.observe(participant_id)
	var aggregates: Dictionary = authority.authority_aggregates()
	_scan_public(observations, "%s participant observations" % case.task_id)
	_scan_public(aggregates, "%s aggregates" % case.task_id)
	privacy_scans += 2
	var public_value := {"observations": observations, "terminal": authority.terminal,
		"aggregates": aggregates}
	return {
		"authority_ticks": authority.tick,
		"checkpoint_hash": authority.checkpoint_hash(),
		"public_hash": CheckpointSerializer.hash_checkpoint(public_value),
		"privacy_scans": privacy_scans,
		"replay_hash": authority.replay_hash(),
		"terminal": authority.terminal.duplicate(true),
	}


func _solo_window(authority: Object) -> Dictionary:
	var action := _control_action(authority, "participant_0", 1)
	return {
		"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"mode": authority.mode, "start_tick": authority.tick, "duration_ticks": 1,
		"decisions": {"participant_0": _accepted(action)},
	}


func _duo_window(authority: Object, kind: String, first_window: bool, leg_index: int) -> Dictionary:
	var decisions := {}
	for participant_id: String in DUO_PARTICIPANTS:
		if first_window and participant_id == "participant_0":
			decisions[participant_id] = _no_input("missing")
		else:
			decisions[participant_id] = _accepted(_control_action(
				authority, participant_id, 10, "leg_%d_%s" % [leg_index, kind]))
	return {
		"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"mode": authority.mode if kind == "central" else "model-duel-v0",
		"start_tick": authority.tick, "duration_ticks": 10, "decisions": decisions,
	}


func _trio_window(authority: Object, first_window: bool, rotation: int) -> Dictionary:
	var decisions := {}
	for participant_id: String in TRIO_PARTICIPANTS:
		if first_window and participant_id == "participant_0":
			decisions[participant_id] = _no_input("missing")
		else:
			decisions[participant_id] = _accepted(_control_action(
				authority, participant_id, 10, "rotation_%d" % rotation))
	return {
		"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"start_tick": authority.tick, "duration_ticks": 10, "decisions": decisions,
	}


func _control_action(
		authority: Object, participant_id: String, duration: int, label: String = "soak_wait"
) -> Dictionary:
	var buttons := {}
	for button: String in BUTTONS:
		buttons[button] = false
	var protocol_version := "llm-controller/0.1.0"
	if authority is MazeAuthority or authority is CourseAuthority \
		or authority is CheckpointRaceAuthority or authority is RelayControlAuthority \
		or authority is SparAuthority or authority is ResourceRelayAuthority:
		protocol_version = "llm-controller/0.2.0"
	elif authority is TrioRelayAuthority or authority is TrioFreeForAllAuthority:
		protocol_version = "llm-controller/0.3.0"
	return {
		"protocol_version": protocol_version, "episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "%s_%s_%d" % [label, participant_id, authority.observation_seq],
		"control": {"move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0,
			"duration_ticks": duration, "buttons": buttons},
		"intent_label": "Demo: wait", "memory_update": "",
	}


func _accepted(action: Dictionary) -> Dictionary:
	return {"disposition": "accepted", "action": action, "fallback": "none",
		"no_input_reason": null}


func _no_input(reason: String) -> Dictionary:
	return {"disposition": "no_input", "action": null, "fallback": "neutral",
		"no_input_reason": reason}


func _scan_public(value: Variant, label: String) -> void:
	var serialized := JSON.stringify(value).to_lower()
	for token: String in FORBIDDEN_PUBLIC_TOKENS:
		_check(token not in serialized, "%s leaked protected token %s" % [label, token])
	_check("sk-proj-" not in serialized, "%s leaked an OpenAI-style credential" % label)
	_check("sk-ant-" not in serialized, "%s leaked an Anthropic-style credential" % label)
	_check("AIza".to_lower() not in serialized, "%s leaked a Gemini-style credential" % label)


func _validate_resource_bounds(rounds: int) -> void:
	var expected := rounds * (SOLO_CASES.size() + DUO_CASES.size() * 2 + TRIO_CASES.size() * 3) * 2
	_check(_execution_count == expected, "execution count drifted from case matrix")
	if rounds >= DEFAULT_ROUNDS:
		_check(_execution_count >= 1000, "release soak executed fewer than 1,000 episodes/legs")
	var growth := int(_memory_samples[-1] - _memory_samples[0])
	_check(growth <= 64 * 1024 * 1024, "static memory grew beyond the 64 MiB soak bound")
	if _memory_samples.size() >= 6:
		var strictly_increasing := true
		for index: int in range(_memory_samples.size() - 5, _memory_samples.size() - 1):
			if _memory_samples[index + 1] <= _memory_samples[index]:
				strictly_increasing = false
		_check(not strictly_increasing, "static memory increased monotonically across the final samples")


func _sum_case_metric(metric: String) -> int:
	var total := 0
	for value: Dictionary in _case_counts.values():
		total += int(value.get(metric, 0))
	return total


func _maximum_memory() -> int:
	var maximum := 0
	for value: int in _memory_samples:
		maximum = maxi(maximum, value)
	return maximum


func _check(condition: bool, message: String) -> void:
	if not condition and message not in _failures:
		_failures.append(message)


func _fail(message: String) -> void:
	_check(false, message)
