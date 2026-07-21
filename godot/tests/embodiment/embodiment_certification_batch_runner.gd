extends SceneTree

const SoloAuthority := preload(
	"res://scripts/embodiment/authority/authority_orchestrator.gd"
)
const DuelAuthority := preload(
	"res://scripts/embodiment/duel_authority/embodiment_duel_authority.gd"
)
const CheckpointSerializer := preload(
	"res://scripts/embodiment/authority/checkpoint_serializer.gd"
)

const SOLO_EPISODES := 1000
const PAIRED_SEEDS := 10
const SAMPLE_INTERVAL := 100
const TASKS := [
	"orientation-v0", "interaction-v0", "construction-v0", "neutral-encounter-v0",
]
const TERMINAL_REASON_BY_TASK := {
	"orientation-v0": "beacon_held",
	"interaction-v0": "resource_deposited",
	"construction-v0": "barricade_built",
	"neutral-encounter-v0": "relay_activated",
}
const MIN_WINDOWS_BY_TASK := {
	"orientation-v0": 4,
	"interaction-v0": 10,
	"construction-v0": 18,
	"neutral-encounter-v0": 9,
}

var failures: PackedStringArray = []
var resource_samples: Array[Dictionary] = []
var solo_metrics := {
	"episodes": 0,
	"windows": 0,
	"minimum_windows": 1_000_000,
	"maximum_windows": 0,
	"tasks": {
		"orientation-v0": 0,
		"interaction-v0": 0,
		"construction-v0": 0,
		"neutral-encounter-v0": 0,
	},
	"terminal_reasons": {
		"beacon_held": 0,
		"resource_deposited": 0,
		"barricade_built": 0,
		"relay_activated": 0,
	},
	"transcript_variants": 3,
	"distinct_seed_count": 1000,
	"seed_minimum": 2_147_483_647,
	"seed_maximum": 0,
	"final_state_digest_sha256": "",
}
var duel_metrics := {
	"paired_seeds": 0,
	"legs": 0,
	"windows": 0,
	"accepted_decisions": 0,
	"normalized_pairs": 0,
	"logical_wins": {"contender": 0, "control": 0, "draw": 0},
	"seat_wins": {"participant_0": 0, "participant_1": 0, "draw": 0},
	"terminal_reasons": {"relay_hold": 0, "knockout": 0, "other": 0},
}


func _init() -> void:
	resource_samples.append(_resource_sample("start", 0))
	_certify_one_thousand_solo_episodes()
	_certify_ten_paired_duel_seeds()
	resource_samples.append(_resource_sample("final", SOLO_EPISODES))
	_certify_resource_growth()
	var metrics := {
		"schema_version": "llm-controller/certification-batch-metrics/1.0.0",
		"solo": solo_metrics,
		"paired_duel": duel_metrics,
		"resources": {
			"sample_interval_episodes": SAMPLE_INTERVAL,
			"samples": resource_samples,
		},
		"failure_count": failures.size(),
	}
	print("EMBODIMENT_CERTIFICATION_BATCH_METRICS:%s" % JSON.stringify(metrics))
	if failures.is_empty():
		print("EMBODIMENT_CERTIFICATION_BATCH_OK episodes=1000 paired_seeds=10")
		quit(0)
	else:
		for failure: String in failures:
			push_error(failure)
		quit(1)


func _certify_one_thousand_solo_episodes() -> void:
	var final_hash_material := ""
	for episode_index: int in SOLO_EPISODES:
		var task_id: String = TASKS[episode_index % TASKS.size()]
		var seed := _solo_seed(episode_index)
		var outcome := _run_solo_episode(episode_index, task_id, seed)
		if outcome.is_empty():
			continue
		var windows := int(outcome.windows)
		var reason := str(outcome.reason)
		solo_metrics.episodes += 1
		solo_metrics.windows += windows
		solo_metrics.minimum_windows = mini(int(solo_metrics.minimum_windows), windows)
		solo_metrics.maximum_windows = maxi(int(solo_metrics.maximum_windows), windows)
		solo_metrics.tasks[task_id] += 1
		solo_metrics.terminal_reasons[reason] += 1
		solo_metrics.seed_minimum = mini(int(solo_metrics.seed_minimum), seed)
		solo_metrics.seed_maximum = maxi(int(solo_metrics.seed_maximum), seed)
		final_hash_material += str(outcome.state_hash)
		if (episode_index + 1) % SAMPLE_INTERVAL == 0:
			resource_samples.append(
				_resource_sample("solo_%04d" % (episode_index + 1), episode_index + 1)
			)
	solo_metrics.final_state_digest_sha256 = final_hash_material.sha256_text()
	_check(int(solo_metrics.episodes) == SOLO_EPISODES, "solo certification did not complete 1000 episodes")
	for task_id: String in TASKS:
		_check(
			int(solo_metrics.tasks[task_id]) == SOLO_EPISODES / TASKS.size(),
			"solo certification task coverage drifted for %s" % task_id,
		)


func _run_solo_episode(episode_index: int, task_id: String, seed: int) -> Dictionary:
	var authority := SoloAuthority.new()
	var episode_id := "ep_cert_solo_%04d_%s" % [episode_index, task_id.trim_suffix("-v0")]
	var errors: PackedStringArray = authority.configure({
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": episode_id,
		"mode": "solo-curriculum-v0",
		"task_id": task_id,
		"seed": seed,
		"observation_profile": "text-visible-v1",
		"timing_track": "step-locked-v1",
		"maximum_episode_ticks": 600,
		"participant_ids": ["participant_0"],
	})
	_check(errors.is_empty(), "solo batch configuration failed at episode %d" % episode_index)
	if not errors.is_empty():
		return {}
	var run := {"authority": authority, "windows": 0, "episode_index": episode_index}
	_apply_seeded_prelude(run, seed)
	match task_id:
		"orientation-v0":
			_run_stage_a(run)
		"interaction-v0":
			_run_stage_b(run)
		"construction-v0":
			_run_stage_c(run)
		"neutral-encounter-v0":
			_run_stage_d(run)
	var expected_reason := str(TERMINAL_REASON_BY_TASK[task_id])
	_check(bool(authority.terminal.ended), "solo episode %d did not terminate" % episode_index)
	_check(str(authority.terminal.outcome) == "success", "solo episode %d did not succeed" % episode_index)
	_check(str(authority.terminal.reason) == expected_reason, "solo episode %d terminal reason drifted" % episode_index)
	_check(
		int(run.windows) >= int(MIN_WINDOWS_BY_TASK[task_id]),
		"solo episode %d was not a meaningful multi-window run" % episode_index,
	)
	if not bool(authority.terminal.ended) or str(authority.terminal.reason) != expected_reason:
		return {}
	return {
		"reason": expected_reason,
		"state_hash": authority.checkpoint_hash(),
		"windows": int(run.windows),
	}


func _apply_seeded_prelude(run: Dictionary, seed: int) -> void:
	match seed % 3:
		0:
			_solo_no_input(run, 1, "missing")
		1:
			_solo_step(run, "prelude_turn_right", 1, 0, 0, 1000)
			_solo_step(run, "prelude_turn_left", 1, 0, 0, -1000)
		2:
			_solo_step(run, "prelude_hold", 2, 0, 0, 0)


func _run_stage_a(run: Dictionary) -> void:
	var authority = run.authority
	while not bool(authority.terminal.ended) and int(run.windows) < 12:
		_solo_step(run, "advance_beacon", 20, 0, 1000, 0)


func _run_stage_b(run: Dictionary) -> void:
	_move_to_resource(run)
	_solo_step(run, "gather_b", 4, 0, 0, 0, {"interact": true})
	_turn_around_and_return(run)
	_solo_step(run, "deposit_b", 1, 0, 0, 0, {"interact": true})


func _run_stage_c(run: Dictionary) -> void:
	_move_to_resource(run)
	_solo_step(run, "turn_miss", 1, 0, 0, 1000)
	_solo_step(run, "miss_resource", 1, 0, 0, 0, {"interact": true})
	_solo_step(run, "correct_resource", 1, 0, 0, -1000)
	_solo_step(run, "gather_c_0", 4, 0, 0, 0, {"interact": true})
	_solo_step(run, "gather_c_1", 4, 0, 0, 0, {"interact": true})
	_turn_around_and_return(run)
	_solo_step(run, "deposit_c", 1, 0, 0, 0, {"interact": true})
	_solo_step(run, "face_pad", 3, 0, 0, -1000)
	_solo_step(run, "approach_pad", 12, 0, 1000, 0)
	_solo_step(run, "align_pad", 1, 0, 0, 1000)
	_solo_step(run, "build_partial", 3, 0, 0, 0, {"interact": true})
	_solo_step(run, "build_interrupt", 1, 0, 0, 0)
	_solo_step(run, "build_complete", 3, 0, 0, 0, {"interact": true})


func _run_stage_d(run: Dictionary) -> void:
	_solo_step(run, "approach_d_0", 20, 0, 1000, 0)
	_solo_step(run, "approach_d_1", 10, 0, 1000, 0)
	_solo_step(run, "primary_d_0", 1, 0, 0, 0, {"primary": true})
	_solo_step(run, "guard_d", 5, 0, 0, 0, {"guard": true})
	_solo_step(run, "primary_d_1", 1, 0, 0, 0, {"primary": true})
	_solo_step(run, "pursue_d", 5, 0, 1000, 0, {"guard": true})
	_solo_step(run, "primary_d_2", 1, 0, 0, 0, {"primary": true})
	_solo_step(run, "approach_relay_d", 4, 0, 1000, 0)
	_solo_step(run, "relay_d", 3, 0, 0, 0, {"interact": true})


func _move_to_resource(run: Dictionary) -> void:
	_solo_step(run, "approach_0", 20, 0, 1000, 0)
	_solo_step(run, "approach_1", 20, 0, 1000, 0)
	_solo_step(run, "approach_2", 3, 0, 1000, 0)


func _turn_around_and_return(run: Dictionary) -> void:
	_solo_step(run, "turn_home", 4, 0, 0, 1000)
	_solo_step(run, "return_0", 20, 0, 1000, 0)
	_solo_step(run, "return_1", 20, 0, 1000, 0)
	_solo_step(run, "return_2", 3, 0, 1000, 0)


func _solo_step(
	run: Dictionary,
	action_label: String,
	duration_ticks: int,
	move_x: int,
	move_y: int,
	look_x: int,
	button_overrides: Dictionary = {},
) -> Dictionary:
	var authority = run.authority
	var buttons := _buttons(button_overrides)
	var action_id := "%s_%04d_%03d" % [
		action_label, int(run.episode_index), int(run.windows),
	]
	var before_tick := int(authority.tick)
	var before_seq := int(authority.observation_seq)
	var result: Dictionary = authority.step({
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": authority.episode_id,
		"observation_seq": before_seq,
		"action_id": action_id,
		"control": {
			"move_x": move_x, "move_y": move_y, "look_x": look_x, "look_y": 0,
			"duration_ticks": duration_ticks, "buttons": buttons,
		},
		"intent_label": action_label,
		"memory_update": "",
	})
	run.windows += 1
	_check(bool(result.receipts.participant_0.accepted), "solo accepted action was rejected")
	_check(int(result.receipts.participant_0.observation_seq) == before_seq, "solo receipt sequence drifted")
	_check(int(result.receipts.participant_0.applied_ticks) > 0, "solo accepted action stalled time")
	_check(int(authority.tick) > before_tick, "solo authority tick did not advance")
	_check(str(result.state_hash).length() == 64, "solo state hash was absent")
	return result


func _solo_no_input(run: Dictionary, duration_ticks: int, reason: String) -> Dictionary:
	var authority = run.authority
	var before_tick := int(authority.tick)
	var before_seq := int(authority.observation_seq)
	var result: Dictionary = authority.step_window({
		"episode_id": authority.episode_id,
		"observation_seq": before_seq,
		"mode": authority.mode,
		"start_tick": before_tick,
		"duration_ticks": duration_ticks,
		"decisions": {"participant_0": _no_input(reason)},
	})
	run.windows += 1
	_check(result.receipts.participant_0.disposition == "no_input", "solo fallback disposition drifted")
	_check(int(result.receipts.participant_0.applied_ticks) == duration_ticks, "solo fallback stalled time")
	_check(int(authority.tick) == before_tick + duration_ticks, "solo fallback tick drifted")
	return result


func _certify_ten_paired_duel_seeds() -> void:
	for seed: int in PAIRED_SEEDS:
		var leg_a := _run_duel_leg(seed, 0)
		var leg_b := _run_duel_leg(seed, 1)
		_check(not leg_a.is_empty() and not leg_b.is_empty(), "paired seed %d did not complete" % seed)
		if leg_a.is_empty() or leg_b.is_empty():
			continue
		_check(leg_a.contender_seat != leg_b.contender_seat, "paired seed %d did not swap seats" % seed)
		_check(
			Vector2i(leg_a.contender_spawn) == -Vector2i(leg_b.contender_spawn),
			"paired seed %d did not swap spawn sides" % seed,
		)
		_check(leg_a.precedence_first != leg_b.precedence_first, "paired seed %d did not swap precedence" % seed)
		_check(leg_a.logical_winner == leg_b.logical_winner, "paired seed %d changed logical winner" % seed)
		_check(leg_a.normalized_hash == leg_b.normalized_hash, "paired seed %d side-normalized state drifted" % seed)
		if leg_a.normalized_hash == leg_b.normalized_hash:
			duel_metrics.normalized_pairs += 1
		duel_metrics.paired_seeds += 1
		for leg: Dictionary in [leg_a, leg_b]:
			duel_metrics.legs += 1
			duel_metrics.windows += int(leg.windows)
			duel_metrics.accepted_decisions += int(leg.accepted_decisions)
			duel_metrics.logical_wins[leg.logical_winner] += 1
			duel_metrics.seat_wins[leg.winner_seat] += 1
			var reason := str(leg.reason)
			duel_metrics.terminal_reasons[
				reason if reason in ["relay_hold", "knockout"] else "other"
			] += 1
	_check(int(duel_metrics.paired_seeds) == PAIRED_SEEDS, "paired certification did not cover ten seeds")
	_check(int(duel_metrics.normalized_pairs) == PAIRED_SEEDS, "not every pair was side-normalized")
	_check(int(duel_metrics.logical_wins.contender) == PAIRED_SEEDS * 2, "logical aggregation favored a seat")
	_check(int(duel_metrics.seat_wins.participant_0) == PAIRED_SEEDS, "seat 0 win count drifted")
	_check(int(duel_metrics.seat_wins.participant_1) == PAIRED_SEEDS, "seat 1 win count drifted")


func _run_duel_leg(seed: int, leg_index: int) -> Dictionary:
	var authority := DuelAuthority.new()
	var episode_id := "ep_cert_pair_%02d_leg_%s" % [seed, "a" if leg_index == 0 else "b"]
	var errors: PackedStringArray = authority.configure({
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": episode_id,
		"mode": "scripted-duel-v0",
		"task_id": "central-relay-v0",
		"seed": seed,
		"observation_profile": "text-visible-v1",
		"timing_track": "step-locked-v1",
		"maximum_episode_ticks": DuelAuthority.MAXIMUM_TICKS,
		"participant_ids": ["participant_0", "participant_1"],
	})
	_check(errors.is_empty(), "paired seed %d leg %d configuration failed" % [seed, leg_index])
	if not errors.is_empty():
		return {}
	var contender_seat := "participant_0" if leg_index == 0 else "participant_1"
	var control_seat := "participant_1" if leg_index == 0 else "participant_0"
	var logical_by_seat := {
		contender_seat: "contender",
		control_seat: "control",
	}
	var precedence := ["contender", "control"] if leg_index == 0 else ["control", "contender"]
	var seat_by_logical := {"contender": contender_seat, "control": control_seat}
	var accepted_decisions := 0
	var windows := 0
	var contender_spawn: Vector2i = authority.operators[contender_seat].position_mt
	while not bool(authority.terminal.ended) and windows < 20:
		var actions := {
			"contender": _duel_action(
				authority, contender_seat, "contender", seed, windows, windows < 3
			),
			"control": _duel_action(authority, control_seat, "control", seed, windows, false),
		}
		var decisions := {}
		for logical_id: String in precedence:
			var participant_id: String = seat_by_logical[logical_id]
			decisions[participant_id] = {
				"disposition": "accepted",
				"fallback": "none",
				"no_input_reason": null,
				"action": actions[logical_id],
			}
		var result: Dictionary = authority.step_window({
			"episode_id": authority.episode_id,
			"observation_seq": authority.observation_seq,
			"mode": authority.mode,
			"start_tick": authority.tick,
			"duration_ticks": DuelAuthority.DECISION_TICKS,
			"decisions": decisions,
		})
		windows += 1
		for participant_id: String in DuelAuthority.PARTICIPANTS:
			_check(result.receipts[participant_id].accepted, "paired accepted action was rejected")
			_check(int(result.receipts[participant_id].applied_ticks) > 0, "paired action stalled time")
			if bool(result.receipts[participant_id].accepted):
				accepted_decisions += 1
	_check(bool(authority.terminal.ended), "paired seed %d leg %d did not terminate" % [seed, leg_index])
	if not bool(authority.terminal.ended):
		return {}
	var winner_seat := str(authority.winner_id) if authority.winner_id != null else "draw"
	var logical_winner := str(logical_by_seat[winner_seat]) if winner_seat != "draw" else "draw"
	_check(logical_winner == "contender", "paired seed %d leg %d winner drifted" % [seed, leg_index])
	_check(str(authority.terminal.reason) == "relay_hold", "paired seed %d leg %d reason drifted" % [seed, leg_index])
	return {
		"accepted_decisions": accepted_decisions,
		"contender_seat": contender_seat,
		"contender_spawn": contender_spawn,
		"logical_winner": logical_winner,
		"normalized_hash": _normalized_duel_hash(authority, seat_by_logical),
		"precedence_first": precedence[0],
		"reason": str(authority.terminal.reason),
		"winner_seat": winner_seat,
		"windows": windows,
	}


func _duel_action(
	authority,
	participant_id: String,
	logical_id: String,
	seed: int,
	window_index: int,
	advance: bool,
) -> Dictionary:
	var buttons := _buttons()
	if not advance and (window_index + seed) % (4 if logical_id == "contender" else 5) == 0:
		buttons.guard = true
	return {
		"protocol_version": "llm-controller/0.1.0",
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "%s_%s_%02d_%02d" % [logical_id, participant_id, seed, window_index],
		"control": {
			"move_x": 0,
			"move_y": 1000 if advance else 0,
			"look_x": 0,
			"look_y": 0,
			"duration_ticks": DuelAuthority.DECISION_TICKS,
			"buttons": buttons,
		},
		"intent_label": "advance relay" if advance else "hold formation",
		"memory_update": "",
	}


func _normalized_duel_hash(authority, seat_by_logical: Dictionary) -> String:
	var operators := {}
	for logical_id: String in ["contender", "control"]:
		var seat: String = seat_by_logical[logical_id]
		var value: Dictionary = authority.operators[seat]
		var position: Vector2i = value.position_mt
		var heading := int(value.heading)
		if seat == "participant_1":
			position = -position
			heading = posmod(heading + 4, 8)
		operators[logical_id] = {
			"position_mt": [position.x, position.y],
			"heading": heading,
			"health": int(value.health),
			"energy": int(value.energy),
			"guarding": bool(value.guarding),
			"primary_cooldown_ticks": int(value.primary_cooldown_ticks),
			"dash_cooldown_ticks": int(value.dash_cooldown_ticks),
			"contact": str(value.contact),
		}
	var relay_logical: Variant = null
	if authority.relay_controller != null:
		var relay_seat := str(authority.relay_controller)
		relay_logical = "contender" if relay_seat == seat_by_logical.contender else "control"
	var winner_logical: Variant = null
	if authority.winner_id != null:
		var winner_seat := str(authority.winner_id)
		winner_logical = "contender" if winner_seat == seat_by_logical.contender else "control"
	return CheckpointSerializer.hash_checkpoint({
		"tick": int(authority.tick),
		"observation_seq": int(authority.observation_seq),
		"operators": operators,
		"relay_controller": relay_logical,
		"relay_hold_ticks": int(authority.relay_hold_ticks),
		"winner": winner_logical,
		"terminal": authority.terminal.duplicate(true),
	})


func _buttons(overrides: Dictionary = {}) -> Dictionary:
	var output := {
		"interact": false, "primary": false, "guard": false, "dash": false,
		"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false,
	}
	output.merge(overrides, true)
	return output


func _no_input(reason: String) -> Dictionary:
	return {
		"disposition": "no_input", "fallback": "neutral",
		"no_input_reason": reason, "action": null,
	}


func _solo_seed(episode_index: int) -> int:
	return posmod(episode_index * 7919 + 104729, 2_147_483_647)


func _resource_sample(label: String, completed_episodes: int) -> Dictionary:
	return {
		"label": label,
		"completed_episodes": completed_episodes,
		"object_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resource_count": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"static_memory_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
	}


func _certify_resource_growth() -> void:
	_check(not _has_sustained_growth("object_count", 0), "object count grew across three samples")
	_check(not _has_sustained_growth("resource_count", 0), "resource count grew across three samples")
	_check(
		not _has_sustained_growth("static_memory_bytes", 4096),
		"static memory grew across three samples",
	)
	if resource_samples.size() < 3:
		return
	var warm: Dictionary = resource_samples[1]
	var final: Dictionary = resource_samples[-1]
	_check(int(final.object_count) <= int(warm.object_count) + 16, "batch retained engine objects")
	_check(int(final.resource_count) <= int(warm.resource_count) + 4, "batch retained resources")
	_check(
		int(final.static_memory_bytes) <= int(warm.static_memory_bytes) + 2 * 1024 * 1024,
		"batch retained more than two MiB of static memory",
	)


func _has_sustained_growth(metric: String, minimum_step: int) -> bool:
	var streak := 0
	for index: int in range(1, resource_samples.size()):
		var previous := int(resource_samples[index - 1][metric])
		var current := int(resource_samples[index][metric])
		if current > previous + minimum_step:
			streak += 1
		else:
			streak = 0
	return streak >= 3


func _check(condition: bool, message: String) -> void:
	if not condition and message not in failures:
		failures.append(message)
