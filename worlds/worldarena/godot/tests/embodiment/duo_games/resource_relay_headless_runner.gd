extends SceneTree

const Authority := preload(
	"res://scripts/embodiment/duo_games/resource_relay_authority.gd"
)

var failures := PackedStringArray()


func _init() -> void:
	_test_gather_carry_deposit_build_and_defend()
	_test_combat_guard_dash_barricade_and_drop()
	_test_independent_invalid_fallback()
	_test_simultaneous_resource_conflict_and_objective()
	_test_dictionary_order_determinism_and_seat_symmetry()
	_test_mirrored_seat_swap_and_time_priority()
	_test_participant_observation_privacy()
	_finish()


func _authority():
	var authority := Authority.new()
	var errors := authority.configure({"protocol_version": "llm-controller/0.2.0",
		"task_id": "duo-resource-relay-v0", "episode_id": "ep_duo_resource_relay_test",
		"participant_ids": ["participant_0", "participant_1"], "maximum_episode_ticks": 1200})
	_check(errors.is_empty(), "configuration failed: %s" % str(errors))
	return authority


func _test_gather_carry_deposit_build_and_defend() -> void:
	var authority = _authority()
	authority.operators.participant_0.position_mt = authority.RESOURCE_POSITIONS.resource_0
	authority.step_window(_window(authority,
		_action(authority, "participant_0", {"interact": true}, "gather"),
		_action(authority, "participant_1")))
	_check(authority.operators.participant_0.carrying, "ten-tick gather did not fill carry slot")
	_check(authority.operators.participant_0.resources_gathered == 1,
		"gather aggregate did not increment")
	authority.operators.participant_0.position_mt = authority.RELAY_POSITIONS.participant_0
	var deposit := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"interact": true}, "deposit"),
		_action(authority, "participant_1")))
	_check(not authority.operators.participant_0.carrying, "deposit did not empty carry slot")
	_check(authority.operators.participant_0.objective_score == 100,
		"deposit did not award deterministic objective score")
	_check("material_deposited" in deposit.receipts.participant_0.codes,
		"deposit receipt was missing")
	for index: int in 2:
		authority.step_window(_window(authority,
			_action(authority, "participant_0", {"ability_1": true}, "build_%d" % index),
			_action(authority, "participant_1")))
	_check(authority.barricade_health.participant_0 == authority.BARRICADE_MAX_HEALTH,
		"two-window build did not complete barricade")
	var before_defend: int = int(authority.operators.participant_0.defend_ticks)
	authority.step_window(_window(authority,
		_action(authority, "participant_0", {"guard": true}, "defend"),
		_action(authority, "participant_1")))
	_check(authority.operators.participant_0.defend_ticks > before_defend,
		"guarding at the friendly relay did not count as defense")


func _test_combat_guard_dash_barricade_and_drop() -> void:
	var authority = _authority()
	authority.operators.participant_0.position_mt = Vector2i(0, 500)
	authority.operators.participant_0.heading = 0
	authority.operators.participant_1.position_mt = Vector2i(0, -500)
	authority.operators.participant_1.heading = 4
	var guarded := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"primary": true, "dash": true}, "strike"),
		_action(authority, "participant_1", {"guard": true}, "guard")))
	_check("dash_applied" in guarded.receipts.participant_0.codes, "limited dash was not applied")
	# Dash can move through the target before the strike; restore a direct combat setup for damage.
	authority.operators.participant_0.position_mt = Vector2i(0, 500)
	authority.operators.participant_1.position_mt = Vector2i(0, -500)
	authority.operators.participant_0.primary_cooldown_ticks = 0
	authority.operators.participant_1.health = 1000
	authority.operators.participant_0.hits_landed = 0
	authority.operators.participant_1.hits_received = 0
	authority.step_window(_window(authority,
		_action(authority, "participant_0", {"primary": true}, "guarded_hit"),
		_action(authority, "participant_1", {"guard": true}, "guard_again")))
	_check(authority.operators.participant_1.health == 875,
		"front guard did not reduce primary damage")
	_check(authority.operators.participant_0.hits_landed == 1,
		"operator hit aggregate did not increment")

	var barrier = _authority()
	barrier.barricade_health.participant_1 = barrier.BARRICADE_MAX_HEALTH
	barrier.operators.participant_1.position_mt = barrier.RELAY_POSITIONS.participant_1
	barrier.operators.participant_1.heading = 4
	barrier.operators.participant_0.position_mt = barrier.RELAY_POSITIONS.participant_1 + Vector2i(0, 1000)
	barrier.operators.participant_0.heading = 0
	barrier.step_window(_window(barrier,
		_action(barrier, "participant_0", {"primary": true}, "barrier_hit"),
		_action(barrier, "participant_1")))
	_check(barrier.barricade_health.participant_1 == 250,
		"barricade did not absorb a visible primary hit")
	_check(barrier.operators.participant_1.health == 1000,
		"protected operator took damage through a live barricade")

	var knockout = _authority()
	knockout.operators.participant_0.position_mt = Vector2i(0, 500)
	knockout.operators.participant_0.heading = 0
	knockout.operators.participant_1.position_mt = Vector2i(0, -500)
	knockout.operators.participant_1.heading = 4
	knockout.operators.participant_1.health = 250
	knockout.operators.participant_1.carrying = true
	knockout.step_window(_window(knockout,
		_action(knockout, "participant_0", {"primary": true}, "knockout"),
		_action(knockout, "participant_1")))
	_check(knockout.terminal.reason == "knockout" and knockout.winner_id == "participant_0",
		"deterministic knockout did not take terminal priority")
	_check(knockout.dropped_resources.size() == 1 \
		and knockout.operators.participant_1.resources_dropped == 1,
		"knocked-out carrier did not drop its resource")


func _test_independent_invalid_fallback() -> void:
	var authority = _authority()
	var invalid := _action(authority, "participant_1", {"move_y": 1000})
	invalid.control.move_y = 1.0
	var result := authority.step_window(_window(authority,
		_action(authority, "participant_0", {"move_y": 1000}), invalid))
	_check(result.receipts.participant_0.accepted, "valid participant was rejected beside invalid input")
	_check(not result.receipts.participant_1.accepted \
		and result.receipts.participant_1.fallback == "neutral",
		"invalid participant did not receive independent neutral fallback")
	_check(authority.tick == 10 and result.receipts.participant_1.applied_ticks == 10,
		"invalid input stalled fixed ten-tick authority time")
	_check(authority.operators.participant_1.position_mt == authority.START_POSITIONS.participant_1,
		"neutral fallback moved the invalid participant")


func _test_simultaneous_resource_conflict_and_objective() -> void:
	var contested = _authority()
	contested.resource_stock.resource_0 = 1
	for participant_id: String in contested.PARTICIPANTS:
		contested.operators[participant_id].position_mt = contested.RESOURCE_POSITIONS.resource_0
	contested.step_window(_window(contested,
		_action(contested, "participant_0", {"interact": true}, "contest"),
		_action(contested, "participant_1", {"interact": true}, "contest")))
	_check(not contested.operators.participant_0.carrying \
		and not contested.operators.participant_1.carrying,
		"arrival-order-sensitive gather granted a contested final resource")
	_check(contested.resource_stock.resource_0 == 1,
		"contested gather consumed the unresolved resource")

	var simultaneous = _authority()
	for participant_id: String in simultaneous.PARTICIPANTS:
		simultaneous.operators[participant_id].position_mt = simultaneous.RELAY_POSITIONS[participant_id]
		simultaneous.operators[participant_id].carrying = true
		simultaneous.operators[participant_id].objective_score = 200
		simultaneous.operators[participant_id].deposits = 2
	simultaneous.step_window(_window(simultaneous,
		_action(simultaneous, "participant_0", {"interact": true}, "final"),
		_action(simultaneous, "participant_1", {"interact": true}, "final")))
	_check(simultaneous.terminal.outcome == "draw" \
		and simultaneous.terminal.reason == "simultaneous_objective",
		"simultaneous objective claims were not a seat-neutral draw")


func _test_dictionary_order_determinism_and_seat_symmetry() -> void:
	var first = _authority()
	var second = _authority()
	for index: int in 2:
		first.step_window(_window(first,
			_action(first, "participant_0", {"move_x": 250}, "repeat_%d" % index),
			_action(first, "participant_1", {"move_x": 250}, "repeat_%d" % index)))
		var reversed := {}
		reversed["participant_1"] = _decision(
			_action(second, "participant_1", {"move_x": 250}, "repeat_%d" % index))
		reversed["participant_0"] = _decision(
			_action(second, "participant_0", {"move_x": 250}, "repeat_%d" % index))
		second.step_window({"episode_id": second.episode_id,
			"observation_seq": second.observation_seq, "start_tick": second.tick,
			"duration_ticks": 10, "decisions": reversed})
	_check(first.replay_hash() == second.replay_hash(),
		"decision dictionary insertion order changed replay evidence")
	_check(first.operators.participant_0.position_mt == -first.operators.participant_1.position_mt,
		"mirrored movement diverged across seats")
	_check(first.RESOURCE_POSITIONS.resource_0 == -first.RESOURCE_POSITIONS.resource_1 \
		and first.RELAY_POSITIONS.participant_0 == -first.RELAY_POSITIONS.participant_1,
		"resource-relay map is not an integer mirrored layout")


func _test_mirrored_seat_swap_and_time_priority() -> void:
	var seat_zero = _authority()
	var seat_one = _authority()
	seat_zero.operators.participant_0.position_mt = seat_zero.RESOURCE_POSITIONS.resource_0
	seat_one.operators.participant_1.position_mt = seat_one.RESOURCE_POSITIONS.resource_1
	seat_zero.step_window(_window(seat_zero,
		_action(seat_zero, "participant_0", {"interact": true}, "seat_gather"),
		_action(seat_zero, "participant_1")))
	seat_one.step_window(_window(seat_one,
		_action(seat_one, "participant_0"),
		_action(seat_one, "participant_1", {"interact": true}, "seat_gather")))
	seat_zero.operators.participant_0.position_mt = seat_zero.RELAY_POSITIONS.participant_0
	seat_one.operators.participant_1.position_mt = seat_one.RELAY_POSITIONS.participant_1
	seat_zero.step_window(_window(seat_zero,
		_action(seat_zero, "participant_0", {"interact": true}, "seat_deposit"),
		_action(seat_zero, "participant_1")))
	seat_one.step_window(_window(seat_one,
		_action(seat_one, "participant_0"),
		_action(seat_one, "participant_1", {"interact": true}, "seat_deposit")))
	var zero_summary: Dictionary = seat_zero.authority_aggregates().participants.participant_0
	var one_summary: Dictionary = seat_one.authority_aggregates().participants.participant_1
	for key: String in ["resources_gathered", "deposits", "objective_score",
		"builds_completed", "hits_landed", "hits_received", "knockouts"]:
		_check(zero_summary[key] == one_summary[key],
			"seat-swapped aggregate diverged for %s" % key)
	_check(seat_zero.operators.participant_0.position_mt \
		== -seat_one.operators.participant_1.position_mt,
		"seat-swapped authority position did not mirror")

	var timed = _authority()
	timed.tick = 1199
	timed.operators.participant_0.objective_score = 100
	var result := timed.step_window(_window(timed,
		_action(timed, "participant_0"), _action(timed, "participant_1")))
	_check(result.terminal.outcome == "win" and result.terminal.reason == "time_limit_score" \
		and timed.winner_id == "participant_0" and timed.tick == 1200,
		"time terminal did not deterministically prioritize objective score")


func _test_participant_observation_privacy() -> void:
	var authority = _authority()
	var observation: Dictionary = authority.observe("participant_0")
	var serialized := JSON.stringify(observation).to_lower()
	for forbidden: String in ["position_mt", "coordinate", "transform", "hidden_state",
		"spectator", "prompt", "raw_output", "credential", "resource_stock", "barricade_health"]:
		_check(forbidden not in serialized, "participant observation leaked protected key: %s" % forbidden)
	_check(not observation.has("authority_aggregates"), "participant observation leaked authority aggregate")
	_check(observation.self.inventory.is_empty(), "empty carry state was not participant-local")


func _window(authority, action_0: Dictionary, action_1: Dictionary) -> Dictionary:
	return {"episode_id": authority.episode_id, "observation_seq": authority.observation_seq,
		"start_tick": authority.tick, "duration_ticks": 10,
		"decisions": {"participant_0": _decision(action_0), "participant_1": _decision(action_1)}}


func _decision(action: Dictionary) -> Dictionary:
	return {"disposition": "accepted", "action": action, "fallback": "none",
		"no_input_reason": null}


func _action(
	authority, participant_id: String, overrides: Dictionary = {}, label: String = "resource_relay",
) -> Dictionary:
	var buttons := {"interact": false, "primary": false, "guard": false, "dash": false,
		"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false}
	for key: String in buttons:
		buttons[key] = bool(overrides.get(key, false))
	return {"protocol_version": "llm-controller/0.2.0", "episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": "%s_%s_%d" % [label, participant_id, authority.observation_seq],
		"control": {"move_x": int(overrides.get("move_x", 0)),
			"move_y": int(overrides.get("move_y", 0)),
			"look_x": int(overrides.get("look_x", 0)), "look_y": 0,
			"duration_ticks": 10, "buttons": buttons},
		"intent_label": label, "memory_update": ""}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("DUO_RESOURCE_RELAY_OK")
		quit(0)
		return
	for failure: String in failures:
		push_error("DUO_RESOURCE_RELAY_FAILURE: %s" % failure)
	quit(1)
