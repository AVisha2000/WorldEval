extends Node3D

## Owns the world-arena/0.2 match lifecycle. ArenaSimulation is authoritative;
## the presentation consumes projections only and the Python backend plans only.

const PROTOCOL := "world-arena/0.2"
const SERVER_URL := "ws://127.0.0.1:8000/ws/arena"
const FACTIONS := ["sol", "terra", "luna"]
const ArenaSimulationScript := preload("res://scripts/arena/simulation/arena_simulation.gd")
const ArenaShowcasePlayerScript := preload("res://scripts/arena/presentation/arena_showcase_player.gd")
const BENCHMARK_CONTRACT_PATH := "res://data/arena/benchmark_contract.json"
const NORMAL_ROUND_LIMIT := 40
const ABSOLUTE_ROUND_LIMIT := 48

@onready var presentation: Node3D = $Presentation

var simulation: ArenaSimulation
var socket := WebSocketPeer.new()
var socket_state := WebSocketPeer.STATE_CLOSED
var backend_connected := false
var backend_configured := false
var configure_sent := false
var round_in_flight := false
var current_round_request: Dictionary = {}
var pending_commits: Dictionary = {}
var pending_commit_statuses: Dictionary = {}
var group_members: Dictionary = {}
var latest_plans: Dictionary = {}
var configured_models := {
	"sol": "gpt-5.6-sol",
	"terra": "gpt-5.6-terra",
	"luna": "gpt-5.6-luna"
}
var active_specialists := {"sol": [], "terra": [], "luna": []}
var specialist_metadata := {"sol": {}, "terra": {}, "luna": {}}
var cognition_remaining := {"sol": 120, "terra": 120, "luna": 120}
var message_history: Array[Dictionary] = []
var pending_offers: Array[Dictionary] = []
var pending_diplomacy_effects: Array[Dictionary] = []
var relationship_history: Array[Dictionary] = []
var recent_event_summaries: Array[String] = []
var event_sequence := 0
var rounds_completed := 0
var verified_commit_count := 0
var executed_trade_count := 0
var failed_trade_count := 0
var activated_pact_count := 0
var betrayal_count := 0
var match_seed := 424242
var requested_pause := false
var playback_speed := 1.0
var _offline_mode := false
var _autostart_demo := false
var _test_round_limit := 0
var _quit_after_test := false
var _retry_at_msec := 0
var _next_round_generation := 0
var _showcase_path := ""
var _showcase_mode := false
var _showcase_capture_mode := false
var _showcase_player: ArenaShowcasePlayer
var _match_result_presented := false
var _benchmark_contract_cache: Dictionary = {}


func _ready() -> void:
	_parse_arguments()
	simulation = ArenaSimulationScript.new(match_seed)
	_connect_presentation()
	presentation.configure_from_snapshot(_presentation_snapshot(simulation.get_snapshot(), "setup", {}))
	if _showcase_mode:
		presentation.set_lobby_visible(false)
		call_deferred("_start_showcase")
	elif _offline_mode:
		presentation.set_lobby_visible(false)
		call_deferred("_run_offline_demo")
	else:
		_connect_backend()


func _process(delta: float) -> void:
	if _showcase_mode:
		# Movie capture must be deterministic and non-interactive. A stray mouse
		# click on the recording window previously paused the replay while Godot
		# continued writing 2,700 identical frames.
		if _showcase_player != null and (_showcase_capture_mode or not requested_pause):
			_showcase_player.advance(delta if _showcase_capture_mode else delta * playback_speed)
		return
	if _offline_mode:
		return
	socket.poll()
	var next_state := socket.get_ready_state()
	if next_state != socket_state:
		socket_state = next_state
		_handle_socket_state(next_state)
	if next_state == WebSocketPeer.STATE_OPEN:
		while socket.get_available_packet_count() > 0:
			var parsed: Variant = JSON.parse_string(socket.get_packet().get_string_from_utf8())
			if parsed is Dictionary:
				_handle_backend_message(parsed)
	elif next_state == WebSocketPeer.STATE_CLOSED and Time.get_ticks_msec() >= _retry_at_msec:
		_connect_backend()


func _connect_presentation() -> void:
	presentation.connect("setup_submitted", Callable(self, "_on_setup_submitted"))
	presentation.connect("pause_requested", Callable(self, "_on_pause_requested"))
	presentation.connect("playback_speed_requested", Callable(self, "_on_speed_requested"))
	presentation.connect("perspective_requested", Callable(self, "_on_perspective_requested"))


func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--arena-offline-demo":
			_offline_mode = true
		elif argument == "--arena-autostart-demo":
			_autostart_demo = true
		elif argument == "--arena-quit-after-test":
			_quit_after_test = true
		elif argument.begins_with("--arena-showcase="):
			_showcase_path = argument.trim_prefix("--arena-showcase=").strip_edges()
			_showcase_mode = not _showcase_path.is_empty()
		elif argument == "--arena-capture":
			_showcase_capture_mode = true
		elif argument.begins_with("--arena-test-rounds="):
			_test_round_limit = maxi(1, int(argument.trim_prefix("--arena-test-rounds=")))
			_autostart_demo = true
		elif argument.begins_with("--arena-seed="):
			match_seed = maxi(1, int(argument.trim_prefix("--arena-seed=")))
	if _offline_mode and _test_round_limit == 0:
		_test_round_limit = 4
	# Test limits stop after the requested resolved-round count; they do not alter the
	# production 40+8 lifecycle or the 40-round cognition budget sent to the backend.


func _connect_backend() -> void:
	socket = WebSocketPeer.new()
	socket_state = WebSocketPeer.STATE_CONNECTING
	var result := socket.connect_to_url(SERVER_URL)
	if result != OK:
		_retry_at_msec = Time.get_ticks_msec() + 1000
		presentation.set_setup_status("Waiting for the local Arena backend…", "info")


func _handle_socket_state(state: WebSocketPeer.State) -> void:
	match state:
		WebSocketPeer.STATE_OPEN:
			presentation.set_setup_status("Arena controller connected. Waiting for protocol handshake…", "info")
		WebSocketPeer.STATE_CLOSED:
			backend_connected = false
			backend_configured = false
			configure_sent = false
			round_in_flight = false
			_retry_at_msec = Time.get_ticks_msec() + 1000
			presentation.set_setup_status("Local Arena backend disconnected. Retrying…", "error")


func _handle_backend_message(message: Dictionary) -> void:
	match str(message.get("type", "")):
		"connected":
			if str(message.get("protocol", "")) != PROTOCOL:
				_fail_match("Backend protocol mismatch; expected world-arena/0.2.")
				return
			backend_connected = true
			presentation.set_setup_status("Connected. Configure the three commanders.", "success")
			if _autostart_demo and not configure_sent:
				_send_configure(_default_demo_config())
		"configured", "match_ready":
			_handle_configured(message)
		"thinking_status":
			presentation.set_phase("thinking", message.get("statuses", {}))
		"round_commit_hashes":
			_handle_round_commit_hashes(message)
		"round_plan_reveal":
			_handle_round_plan_reveal(message)
		"match_result":
			_handle_match_result(message)
		"error":
			var detail_text := str(message.get("details", ""))
			var safe_error := str(message.get("error", "Arena backend rejected the request."))
			if not detail_text.is_empty():
				safe_error += " · " + detail_text.substr(0, 320)
			_fail_match(safe_error)


func _on_setup_submitted(config: Dictionary) -> void:
	if not backend_connected:
		presentation.set_setup_status("The local Arena backend is not connected yet.", "error")
		return
	_send_configure(config)


func _send_configure(config: Dictionary) -> void:
	if configure_sent:
		return
	var api_key := str(config.get("api_key", ""))
	var brain_mode := "openai" if not api_key.is_empty() else "demo"
	var outbound := {
		"type": "configure_match",
		"protocol": PROTOCOL,
		"match_id": str(simulation.state.match.id),
		"seed": match_seed,
		"brain_mode": brain_mode,
		"mode": str(config.get("mode", "demo")),
		"track": str(config.get("track", "agentic")),
		"map_id": "tri_13_v1",
		"max_rounds": NORMAL_ROUND_LIMIT,
		"agents": config.get("agents", _default_agents())
	}
	if not api_key.is_empty():
		outbound["api_key"] = api_key
	configure_sent = true
	presentation.set_setup_status("Creating three independent commander runtimes…", "pending")
	_send_json(outbound)
	api_key = ""
	outbound.erase("api_key")


func _handle_configured(message: Dictionary) -> void:
	if str(message.get("protocol", PROTOCOL)) != PROTOCOL:
		_fail_match("Configured response used an unsupported protocol.")
		return
	backend_configured = true
	var agents: Variant = message.get("agents", message.get("models", {}))
	if agents is Dictionary:
		for faction in FACTIONS:
			if agents.has(faction):
				var value: Variant = agents[faction]
				configured_models[faction] = str(value.get("model", value)) if value is Dictionary else str(value)
	elif agents is Array:
		for agent_variant in agents:
			if agent_variant is Dictionary:
				var faction := str(agent_variant.get("agent_id", agent_variant.get("faction_id", "")))
				if faction in FACTIONS:
					configured_models[faction] = str(agent_variant.get("model", configured_models[faction]))
	presentation.mark_setup_accepted(_presentation_snapshot(simulation.get_snapshot(), "thinking", _all_status("waiting")))
	_send_round_request()


func _send_round_request() -> void:
	if not backend_configured or round_in_flight or requested_pause:
		return
	var snapshot := simulation.get_snapshot()
	if bool(snapshot.match.ended) or int(snapshot.match.round) > ABSOLUTE_ROUND_LIMIT:
		_finish_terminal_match(snapshot)
		return
	current_round_request = _build_round_request(snapshot)
	round_in_flight = true
	pending_commits.clear()
	pending_commit_statuses.clear()
	presentation.set_phase("thinking", _all_status("thinking"))
	_send_json(current_round_request)


func _handle_round_commit_hashes(message: Dictionary) -> void:
	if not _matches_pending_round(message):
		_fail_match("Commit hashes did not match the pending authoritative round.")
		return
	if str(message.get("snapshot_hash", "")) != str(current_round_request.snapshot_hash):
		_fail_match("Commit hashes referenced a different frozen snapshot.")
		return
	var commits: Array = message.get("commits", [])
	if commits.size() != 3:
		_fail_match("Backend did not commit exactly three faction plans.")
		return
	for commit_variant in commits:
		if not commit_variant is Dictionary:
			_fail_match("Backend returned a malformed plan commitment.")
			return
		var commit: Dictionary = commit_variant
		var faction := str(commit.get("faction_id", ""))
		var commit_hash := str(commit.get("commit_hash", ""))
		if not faction in FACTIONS or not _is_hash(commit_hash) or pending_commits.has(faction):
			_fail_match("Backend returned an invalid or duplicate commitment.")
			return
		pending_commits[faction] = commit_hash
		pending_commit_statuses[faction] = "fallback" if str(commit.get("status", "planned")) == "fallback" else "locked"
	if pending_commits.size() != 3:
		_fail_match("Backend commitments did not cover every faction.")
		return
	presentation.set_phase("plans_locked", pending_commit_statuses)
	_send_json({
		"type": "round_commits_locked",
		"protocol": PROTOCOL,
		"match_id": str(message.match_id),
		"round": int(message.round),
		"commit_hashes": pending_commits.duplicate(true)
	})


func _handle_round_plan_reveal(message: Dictionary) -> void:
	if not _matches_pending_round(message) or pending_commits.size() != 3:
		_fail_match("Plan reveal arrived without matching locked commitments.")
		return
	var revealed: Array = message.get("plans", [])
	if revealed.size() != 3:
		_fail_match("Backend did not reveal exactly three faction plans.")
		return
	var plans: Dictionary = {}
	for item_variant in revealed:
		if not item_variant is Dictionary:
			_fail_match("Backend returned a malformed plan reveal.")
			return
		var item: Dictionary = item_variant
		var faction := str(item.get("faction_id", ""))
		var plan: Variant = item.get("plan", {})
		var salt := str(item.get("salt", ""))
		var reveal_hash := str(item.get("commit_hash", ""))
		if not faction in FACTIONS or plans.has(faction) or not plan is Dictionary:
			_fail_match("Backend reveal contained a duplicate or invalid faction.")
			return
		if reveal_hash != str(pending_commits.get(faction, "")) or _plan_commit_hash(plan, salt) != reveal_hash:
			_fail_match("A revealed plan failed commit verification.")
			return
		verified_commit_count += 1
		if str(plan.get("match_id", "")) != str(message.match_id) or int(plan.get("round", 0)) != int(message.round) or str(plan.get("faction_id", "")) != faction:
			_fail_match("A revealed plan envelope did not match its locked round.")
			return
		plans[faction] = plan.duplicate(true)
	if plans.size() != 3:
		_fail_match("Backend reveal did not cover every faction.")
		return
	latest_plans = plans.duplicate(true)
	_update_specialist_state(plans)
	var communication_events := _communication_events(plans, int(message.round))
	presentation.set_phase("plans_locked", pending_commit_statuses)
	presentation.apply_events(communication_events)
	call_deferred("_resolve_network_round", plans, communication_events, int(message.round))


func _resolve_network_round(plans: Dictionary, communication_events: Array, round_number: int) -> void:
	await get_tree().create_timer(0.18 / maxf(0.5, playback_speed)).timeout
	var receipt := _resolve_plans(plans, communication_events, round_number)
	_send_json(receipt)
	round_in_flight = false
	if bool(simulation.state.match.ended) or rounds_completed >= ABSOLUTE_ROUND_LIMIT:
		_finish_terminal_match(simulation.get_snapshot())
		return
	if _test_round_limit > 0 and rounds_completed >= _test_round_limit:
		_finish_test()
		return
	_schedule_next_round()


func _resolve_plans(plans: Dictionary, communication_events: Array, round_number: int) -> Dictionary:
	var previous_hash := simulation.get_state_hash()
	var translation := _translate_plans(plans)
	var diplomacy_result := _apply_pending_diplomacy_effects(plans, round_number)
	presentation.set_phase("resolution", _all_status("executing"))
	var snapshot := simulation.apply_round(translation.orders)
	rounds_completed += 1
	var simulation_events := _simulation_events(simulation.get_events(), round_number)
	var resolution_events: Array = diplomacy_result.events
	resolution_events.append_array(simulation_events)
	var all_events: Array = []
	all_events.append_array(communication_events)
	all_events.append_array(resolution_events)
	_update_recent_events(all_events)
	presentation.configure_from_snapshot(_presentation_snapshot(snapshot, str(snapshot.match.phase), _all_status("waiting")))
	presentation.apply_events(resolution_events)
	var receipts: Array = translation.receipts
	receipts.append_array(diplomacy_result.receipts)
	var receipt := {
		"type": "round_receipts",
		"protocol": PROTOCOL,
		"match_id": str(snapshot.match.id),
		"round": round_number,
		"previous_state_hash": previous_hash,
		"state_hash": str(snapshot.match.state_hash),
		"events": all_events,
		"validation_receipts": receipts
	}
	if bool(snapshot.match.ended):
		receipt["terminal_outcome"] = _terminal_outcome(snapshot)
	return receipt


func _schedule_next_round() -> void:
	if requested_pause:
		return
	_next_round_generation += 1
	var generation := _next_round_generation
	await get_tree().create_timer(0.32 / maxf(0.5, playback_speed)).timeout
	if generation == _next_round_generation and not requested_pause:
		_send_round_request()


func _on_pause_requested(paused: bool) -> void:
	if _showcase_mode and _showcase_capture_mode:
		requested_pause = false
		return
	requested_pause = paused
	if not paused and backend_configured and not round_in_flight:
		_send_round_request()


func _on_speed_requested(speed: float) -> void:
	if _showcase_mode and _showcase_capture_mode:
		playback_speed = 1.0
		return
	playback_speed = clampf(speed, 0.5, 8.0)


func _on_perspective_requested(_perspective_id: String) -> void:
	# Projection switching is presentation-only in this local omniscient prototype.
	pass


func _send_json(message: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(message))


func _matches_pending_round(message: Dictionary) -> bool:
	return (
		round_in_flight
		and str(message.get("protocol", "")) == PROTOCOL
		and str(message.get("match_id", "")) == str(current_round_request.get("match_id", ""))
		and int(message.get("round", 0)) == int(current_round_request.get("round", -1))
	)


func _fail_match(message: String) -> void:
	round_in_flight = false
	push_error("Arena match stopped: %s" % message.substr(0, 420))
	presentation.set_phase("error", _all_status("fallback"))
	presentation.set_setup_status(message.substr(0, 240), "error")


func _handle_match_result(message: Dictionary) -> void:
	var result_variant: Variant = message.get("result", message)
	if not result_variant is Dictionary:
		_fail_match("Backend returned a malformed match result.")
		return
	var result: Dictionary = result_variant.duplicate(true)
	# Transport envelope fields are not evaluation evidence.
	result.erase("type")
	result.erase("protocol")
	presentation.set_phase("complete", _all_status("waiting"))
	presentation.show_match_result(result)
	_match_result_presented = true


func _finish_local_match(snapshot: Dictionary) -> void:
	round_in_flight = false
	presentation.configure_from_snapshot(_presentation_snapshot(snapshot, "complete", _all_status("waiting")))
	presentation.set_phase("complete", _all_status("waiting"))
	if not _match_result_presented:
		presentation.show_match_result(_local_mock_match_result(snapshot))
		_match_result_presented = true


func _finish_terminal_match(snapshot: Dictionary) -> void:
	# A test run must always emit its machine-readable completion marker and quit,
	# even when the authoritative simulation ends before the requested round cap.
	if _test_round_limit > 0:
		_finish_test()
		return
	if backend_connected and backend_configured:
		# The final receipt is already in flight. Keep the world visible while the
		# backend derives the official deterministic score from sealed evidence.
		round_in_flight = false
		presentation.configure_from_snapshot(_presentation_snapshot(snapshot, "complete", _all_status("waiting")))
		presentation.set_phase("finalizing", _all_status("waiting"))
		return
	_finish_local_match(snapshot)


func _terminal_outcome(snapshot: Dictionary) -> Dictionary:
	var winner := str(snapshot.match.winner)
	var placements := _terminal_placements(snapshot, winner)
	var draw_factions: Array = placements.get("draw_factions", [])
	var faction_outcomes: Array[Dictionary] = []
	for faction in FACTIONS:
		var faction_state: Dictionary = snapshot.factions[faction]
		var completed_structures := 0
		var completed_structure_value := 0
		for structure_variant in snapshot.structures.values():
			var structure: Dictionary = structure_variant
			if str(structure.get("faction", "")) != faction:
				continue
			completed_structures += 1
			completed_structure_value += simulation.get_structure_value(str(structure.kind))
		var supplied_districts: Array = faction_state.supply.supplied_districts
		faction_outcomes.append({
			"faction_id": faction,
			"placement": int(placements[faction]),
			"won": winner != "draw" and winner == faction,
			"draw": winner == "draw" and faction in draw_factions,
			"core_health": clampi(int(round(float(faction_state.core_hp))), 0, 1000),
			"supplied_points": clampi(maxi(0, supplied_districts.size() - 1), 0, 13),
			"territory_time": maxi(0, int(faction_state.territory.control_point_rounds)),
			"crown_hold_rounds": clampi(int(faction_state.territory.get("crown_hold_rounds", 0)), 0, 48),
			"completed_structure_value": completed_structure_value,
			"completed_structures": completed_structures
		})
	var contract := _benchmark_contract()
	return {
		"ended": true,
		"winner": winner,
		"completed_rounds": rounds_completed,
		"rules_hash": str(contract.rules.hash),
		"map_hash": str(contract.map.hash),
		"tool_hash": str(contract.tools.hash),
		"factions": faction_outcomes
	}


func _terminal_placements(snapshot: Dictionary, winner: String) -> Dictionary:
	var result: Dictionary = {"draw_factions": []}
	if winner != "draw":
		var remaining: Array = []
		for faction in FACTIONS:
			if faction != winner:
				remaining.append(faction)
		remaining.sort_custom(func(left: String, right: String) -> bool:
			return _terminal_rank_precedes(left, right)
		)
		result[winner] = 1
		for index in remaining.size():
			result[remaining[index]] = index + 2
		return result

	var eligible: Array = []
	for faction in FACTIONS:
		if not bool(snapshot.factions[faction].eliminated):
			eligible.append(faction)
	var leaders: Array = []
	var best_metrics: Array = []
	for faction in eligible:
		var metrics := simulation.get_faction_ranking_metrics(faction)
		if leaders.is_empty() or _rank_metrics_greater(metrics, best_metrics):
			leaders = [faction]
			best_metrics = metrics
		elif metrics == best_metrics:
			leaders.append(faction)
	if leaders.size() < 2:
		# Simultaneous destruction can leave no surviving faction to rank. It is an
		# authoritative three-way draw rather than an invented tie-break.
		leaders = FACTIONS.duplicate()
	result.draw_factions = leaders.duplicate()
	var lower_place := mini(3, leaders.size() + 1)
	for faction in FACTIONS:
		result[faction] = 1 if faction in leaders else lower_place
	return result


func _terminal_rank_precedes(left: String, right: String) -> bool:
	var left_metrics := simulation.get_faction_ranking_metrics(left)
	var right_metrics := simulation.get_faction_ranking_metrics(right)
	if left_metrics == right_metrics:
		return FACTIONS.find(left) < FACTIONS.find(right)
	return _rank_metrics_greater(left_metrics, right_metrics)


func _rank_metrics_greater(left: Array, right: Array) -> bool:
	for index in mini(left.size(), right.size()):
		if int(left[index]) != int(right[index]):
			return int(left[index]) > int(right[index])
	return false


func _benchmark_contract() -> Dictionary:
	if not _benchmark_contract_cache.is_empty():
		return _benchmark_contract_cache
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BENCHMARK_CONTRACT_PATH))
	assert(parsed is Dictionary, "Arena benchmark contract is malformed")
	for section in ["rules", "map", "tools"]:
		assert(parsed.has(section) and parsed[section] is Dictionary, "Arena benchmark contract is missing %s" % section)
		assert(_is_hash(str(parsed[section].get("hash", ""))), "Arena benchmark contract has an invalid %s hash" % section)
	_benchmark_contract_cache = parsed.duplicate(true)
	return _benchmark_contract_cache


func _finish_test() -> void:
	var summary := "ARENA_MATCH_CONTROLLER_OK rounds=%d hash=%s" % [rounds_completed, simulation.get_state_hash()]
	print(summary)
	print("ARENA_PROTOCOL_METRICS commits=%d trades=%d failed_trades=%d pacts=%d betrayals=%d" % [verified_commit_count, executed_trade_count, failed_trade_count, activated_pact_count, betrayal_count])
	presentation.set_phase("complete", _all_status("waiting"))
	if _quit_after_test:
		get_tree().quit(0)


func _start_showcase() -> void:
	_showcase_player = ArenaShowcasePlayerScript.new()
	_showcase_player.name = "ArenaShowcasePlayer"
	add_child(_showcase_player)
	_showcase_player.verification_changed.connect(
		func(label: String, detail: String, verified: bool) -> void:
			presentation.set_showcase_status(verified, label, detail)
	)
	_showcase_player.completed.connect(func() -> void:
		presentation.set_phase("complete", _all_status("waiting"))
		if _quit_after_test:
			print("ARENA_SHOWCASE_CONTROLLER_OK cues=%d label=%s" % [_showcase_player.dispatched_cue_count, _showcase_player.verification_label])
			get_tree().quit(0)
	)
	var status := _showcase_player.load_showcase(_showcase_path)
	presentation.set_showcase_status(bool(status.verified), str(status.label), str(status.detail))
	if bool(status.loaded):
		presentation.set_phase("replay", _all_status("waiting"))
		_showcase_player.start(presentation)
	elif _quit_after_test:
		print("ARENA_SHOWCASE_REFUSED label=%s detail=%s" % [str(status.label), str(status.detail)])
		get_tree().quit(2)


func _local_mock_match_result(snapshot: Dictionary) -> Dictionary:
	var factions: Array[Dictionary] = []
	for faction in FACTIONS:
		var state: Dictionary = snapshot.factions[faction]
		var supplied_land := maxi(0, state.supply.supplied_districts.size() - 1)
		var territory_time := maxi(0, int(state.territory.control_point_rounds))
		var core_health := maxi(0, int(float(state.core_hp)))
		var crown_rounds := 1 if snapshot.districts.crown.get("owner", null) == faction else 0
		var pact_count := 0
		var faction_betrayals := 0
		for relationship in relationship_history:
			if faction in [str(relationship.get("actor_id", "")), str(relationship.get("target_id", ""))]:
				pact_count += 1
			if str(relationship.get("actor_id", "")) == faction and str(relationship.get("state", "")) == "betrayed":
				faction_betrayals += 1
		var category_values := {
			"objective_control": clampf(18.0 + supplied_land * 9.0 + territory_time * 0.45 + crown_rounds * 12.0 + core_health * 0.015, 0.0, 100.0),
			"planning_adaptation": clampf(38.0 + supplied_land * 5.0 + territory_time * 0.25, 0.0, 100.0),
			"resource_combat_efficiency": clampf(32.0 + supplied_land * 4.0 + core_health * 0.02, 0.0, 100.0),
			"social_intelligence": clampf(35.0 + pact_count * 10.0 - faction_betrayals * 8.0, 0.0, 100.0),
			"delegation_cognition": clampf(42.0 + active_specialists[faction].size() * 12.0, 0.0, 100.0),
			"reliability_safety": clampf(72.0 - faction_betrayals * 18.0, 0.0, 100.0)
		}
		var weights := {
			"objective_control": 0.35, "planning_adaptation": 0.20,
			"resource_combat_efficiency": 0.15, "social_intelligence": 0.15,
			"delegation_cognition": 0.10, "reliability_safety": 0.05
		}
		var categories: Array[Dictionary] = []
		var worldarena_score := 0.0
		for category in weights:
			var score := snappedf(float(category_values[category]), 0.01)
			var contribution := snappedf(score * float(weights[category]), 0.01)
			worldarena_score += contribution
			categories.append({
				"category": category, "score": score, "weight": weights[category],
				"weighted_contribution": contribution, "measurement_count": 1,
				"event_ids": ["mock-evidence.%s.%s" % [faction, category]],
				"action_ids": ["mock-action.%s.r%d" % [faction, maxi(1, rounds_completed)]]
			})
		factions.append({
			"faction_id": faction,
			"model_id": configured_models[faction],
			"placement": 0,
			"worldarena_score": snappedf(worldarena_score, 0.01),
			"categories": categories,
			"metrics": {
				"core": core_health, "territory": supplied_land, "crown": crown_rounds,
				"trades": executed_trade_count, "tokens": 120 - int(cognition_remaining[faction]),
				"invalid": 0, "pacts": pact_count, "betrayals": faction_betrayals
			},
			"best_decision": {
				"round": maxi(1, rounds_completed),
				"summary": "Retained %d supplied districts and %d cumulative territory points in demo telemetry." % [supplied_land, territory_time]
			},
			"biggest_failure": {
				"round": maxi(1, rounds_completed),
				"summary": "Mock-only evidence: %d core health lost; inspect replay events for the physical cause." % maxi(0, 1000 - core_health)
			},
			"_ranking_points": territory_time * 10000 + core_health * 10 + (2 - FACTIONS.find(faction))
		})
	factions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a._ranking_points) > int(b._ranking_points)
	)
	for index in factions.size():
		factions[index].placement = index + 1
		factions[index].erase("_ranking_points")
	return {
		"schema_version": 2,
		"formula_version": "worldarena-score/1.0.0",
		"match_id": str(snapshot.match.id),
		"completed_rounds": rounds_completed,
		"verified": false,
		"verification_label": "UNVERIFIED LOCAL DEMO",
		"verification_detail": "Credential-free local policy with clearly labeled mock evaluation evidence.",
		"evidence_mode": "mock",
		"weights": {
			"objective_control": 0.35, "planning_adaptation": 0.20,
			"resource_combat_efficiency": 0.15, "social_intelligence": 0.15,
			"delegation_cognition": 0.10, "reliability_safety": 0.05
		},
		"factions": factions
	}


func _is_hash(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if not character in "0123456789abcdef":
			return false
	return true


func _plan_commit_hash(plan: Dictionary, salt: String) -> String:
	if salt.length() != 32:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	# Godot's JSON parser may represent integer JSON tokens as floats. Arena plans contain
	# no real-valued fields, so normalize integral floats back to integers before reproducing
	# Python's sorted compact canonical JSON.
	var canonical_plan: Variant = _canonical_plan_value(plan)
	context.update((JSON.stringify(canonical_plan, "", true) + "\n" + salt).to_utf8_buffer())
	return context.finish().hex_encode()


func _canonical_plan_value(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[str(key)] = _canonical_plan_value(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_canonical_plan_value(item))
		return result
	if typeof(value) == TYPE_FLOAT and is_finite(float(value)) and floor(float(value)) == float(value):
		return int(value)
	return value


func _all_status(status: String) -> Dictionary:
	return {"sol": status, "terra": status, "luna": status}


func _default_agents() -> Array:
	return [
		{"agent_id": "sol", "model": "gpt-5.6-sol", "reasoning_effort": "medium", "max_specialists": 3},
		{"agent_id": "terra", "model": "gpt-5.6-terra", "reasoning_effort": "low", "max_specialists": 3},
		{"agent_id": "luna", "model": "gpt-5.6-luna", "reasoning_effort": "low", "max_specialists": 3}
	]


func _default_demo_config() -> Dictionary:
	return {
		"type": "configure_match",
		"protocol": PROTOCOL,
		"api_key": "",
		"brain_mode": "demo",
		"mode": "demo",
		"track": "agentic",
		"agents": _default_agents()
	}


func _build_round_request(snapshot: Dictionary) -> Dictionary:
	group_members.clear()
	var observations: Array = []
	for faction in FACTIONS:
		observations.append(_observation_for_faction(snapshot, faction))
	return {
		"type": "round_request",
		"protocol": PROTOCOL,
		"match_id": str(snapshot.match.id),
		"round": int(snapshot.match.round),
		"snapshot_hash": str(snapshot.match.state_hash),
		"observations": observations
	}


func _observation_for_faction(snapshot: Dictionary, faction: String) -> Dictionary:
	var faction_state: Dictionary = snapshot.factions[faction]
	var visible_districts := _visible_district_ids(snapshot, faction)
	var groups := _friendly_groups(snapshot, faction)
	var structures: Array = []
	var structure_ids: Array = snapshot.structures.keys()
	structure_ids.sort()
	for structure_id in structure_ids:
		var structure: Dictionary = snapshot.structures[structure_id]
		if str(structure.faction) != faction:
			continue
		structures.append({
			"structure_id": str(structure_id),
			"structure_kind": str(structure.kind),
			"district_id": str(structure.district),
			"health": maxi(0, int(float(structure.hp))),
			"complete": true
		})

	var districts: Array = []
	for district_id in visible_districts:
		var district: Dictionary = snapshot.districts[district_id]
		var owner: Variant = district.get("owner", null)
		var record := {
			"district_id": str(district_id),
			"owner_id": owner,
			"supplied": _district_supplied(snapshot, str(owner), str(district_id)) if owner != null else null,
			"contested": _district_contested(snapshot, str(district_id)),
			"last_seen_round": int(snapshot.match.round),
			"resources": _resource_bundle_from_nodes(district.resources)
		}
		districts.append(record)

	var public_scores: Array = []
	for score_faction in FACTIONS:
		var score_state: Dictionary = snapshot.factions[score_faction]
		var supplied_count := maxi(0, score_state.supply.supplied_districts.size() - 1)
		public_scores.append({
			"faction_id": score_faction,
			"core_health": maxi(0, int(float(score_state.core_hp))),
			"supplied_land": supplied_count,
			"territory_time": int(score_state.territory.control_point_rounds),
			"eliminated": float(score_state.core_hp) <= 0.0
		})

	var specialist_ids: Array = specialist_metadata[faction].keys()
	specialist_ids.sort()
	return {
		"match_id": str(snapshot.match.id),
		"round": int(snapshot.match.round),
		"faction_id": faction,
		"snapshot_hash": str(snapshot.match.state_hash),
		"inventory": _resource_bundle_from_stockpile(faction_state.stockpile),
		"groups": groups,
		"structures": structures,
		"districts": districts,
		"enemy_contacts": _enemy_contacts(snapshot, faction, visible_districts),
		"wildlife": _wildlife_observations(snapshot, visible_districts),
		"public_scores": public_scores,
		"messages": _messages_for_faction(faction, int(snapshot.match.round)),
		"pending_offers": _offers_for_faction(faction, int(snapshot.match.round)),
		"recent_events": recent_event_summaries.duplicate(),
		"cognition": {
			"track": "agentic",
			"remaining_units": maxi(0, int(cognition_remaining[faction])),
			"commander_cost": 2,
			"specialist_cost": 1,
			"active_specialist_ids": specialist_ids
		},
		"available_actions": ["assign_workers", "hunt", "scout", "build", "train", "mobilize", "reinforce", "retreat"]
	}


func _friendly_groups(snapshot: Dictionary, faction: String) -> Array:
	var buckets: Dictionary = {}
	var unit_ids: Array = snapshot.units.keys()
	unit_ids.sort()
	for unit_id in unit_ids:
		var unit: Dictionary = snapshot.units[unit_id]
		if str(unit.faction) != faction:
			continue
		var key := "%s|%s" % [str(unit.kind), str(unit.district)]
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(str(unit_id))
	var faction_groups: Dictionary = {}
	var records: Array = []
	var keys: Array = buckets.keys()
	keys.sort()
	for key in keys:
		var members: Array = buckets[key]
		var group_index := 0
		while not members.is_empty():
			var first_member: Dictionary = snapshot.units[members[0]]
			var chunk_limit := 1 if str(first_member.kind) == "worker" else 4
			var chunk: Array = members.slice(0, mini(chunk_limit, members.size()))
			members = members.slice(chunk.size())
			var first: Dictionary = snapshot.units[chunk[0]]
			var group_id := "%s.%s.%s.%d" % [faction, str(first.kind), str(first.district), group_index]
			group_index += 1
			faction_groups[group_id] = chunk.duplicate()
			var health := 0
			var jobs: Array[String] = []
			for member_id in chunk:
				var member: Dictionary = snapshot.units[member_id]
				health += maxi(0, int(float(member.hp)))
				if member.has("harvest"):
					jobs.append("harvest %s" % str(member.harvest))
				elif not str(member.get("target", "")).is_empty():
					jobs.append("move %s" % str(member.target))
			var record := {
				"group_id": group_id,
				"unit_kind": str(first.kind),
				"count": chunk.size(),
				"district_id": str(first.district),
				"health": health
			}
			if not jobs.is_empty():
				record["job"] = jobs[0]
			records.append(record)
	group_members[faction] = faction_groups
	return records


func _visible_district_ids(snapshot: Dictionary, faction: String) -> Array:
	var visible: Dictionary = {}
	for district_id in snapshot.factions[faction].territory.owned:
		visible[str(district_id)] = true
	for unit in snapshot.units.values():
		if str(unit.faction) != faction:
			continue
		var district_id := str(unit.district)
		visible[district_id] = true
		for adjacent in snapshot.map.adjacency.get(district_id, []):
			visible[str(adjacent)] = true
	var result: Array = visible.keys()
	result.sort()
	return result


func _enemy_contacts(snapshot: Dictionary, faction: String, visible_districts: Array) -> Array:
	var buckets: Dictionary = {}
	for unit in snapshot.units.values():
		if str(unit.faction) == faction or not visible_districts.has(str(unit.district)):
			continue
		var key := "%s|%s|%s" % [str(unit.faction), str(unit.kind), str(unit.district)]
		buckets[key] = int(buckets.get(key, 0)) + 1
	var contacts: Array = []
	var keys: Array = buckets.keys()
	keys.sort()
	for key in keys:
		var parts := str(key).split("|")
		contacts.append({
			"contact_id": "contact.%s.%s.%s" % [parts[0], parts[1], parts[2]],
			"faction_id": parts[0],
			"unit_kind": parts[1],
			"approximate_count": int(buckets[key]),
			"district_id": parts[2],
			"last_seen_round": int(snapshot.match.round)
		})
	return contacts


func _wildlife_observations(snapshot: Dictionary, visible_districts: Array) -> Array:
	var result: Array = []
	for district_id in visible_districts:
		var district: Dictionary = snapshot.districts[district_id]
		if district.has("wildlife"):
			var species_ids: Array = district.wildlife.keys()
			species_ids.sort()
			for species in species_ids:
				var count := int(district.wildlife[species].get("count", 0))
				if count <= 0:
					continue
				result.append({
					"wildlife_id": "wildlife.%s.%s" % [district_id, species],
					"species": str(species),
					"approximate_count": count,
					"district_id": district_id,
					"alert": str(species) in ["boar", "wolves"]
				})
		else:
			var animal_food := int(district.resources.get("animals", 0))
			if animal_food > 0:
				var fallback_species := "wolves" if str(district.kind) == "wild" else "boar" if str(district.kind) == "crown" else "deer"
				result.append({
					"wildlife_id": "wildlife.%s" % district_id, "species": fallback_species,
					"approximate_count": clampi(animal_food / 10, 1, 24), "district_id": district_id,
					"alert": fallback_species in ["boar", "wolves"]
				})
	return result


func _messages_for_faction(faction: String, round_number: int) -> Array:
	var result: Array = []
	for message in message_history:
		if int(message.sent_round) >= round_number:
			continue
		if str(message.visibility) == "public" or str(message.sender_id) == faction or message.recipients.has(faction):
			result.append(message.duplicate(true))
	if result.size() > 24:
		result = result.slice(result.size() - 24)
	return result


func _offers_for_faction(faction: String, round_number: int) -> Array:
	var result: Array = []
	for offer in pending_offers:
		if int(offer.expires_round) < round_number:
			continue
		if faction in [str(offer.sender_id), str(offer.recipient_id)]:
			result.append({
				"offer_id": offer.offer_id,
				"kind": offer.kind,
				"sender_id": offer.sender_id,
				"recipient_id": offer.recipient_id,
				"expires_round": offer.expires_round,
				"summary": offer.summary
			})
	return result.slice(0, mini(12, result.size()))


func _resource_bundle_from_stockpile(stockpile: Dictionary) -> Dictionary:
	return {
		"food": maxi(0, int(stockpile.get("food", 0))),
		"wood": maxi(0, int(stockpile.get("wood", 0))),
		"stone": maxi(0, int(stockpile.get("stone", 0))),
		"iron": maxi(0, int(stockpile.get("iron", 0))),
		"crystal": maxi(0, int(stockpile.get("crystal", 0)))
	}


func _resource_bundle_from_nodes(nodes: Dictionary) -> Dictionary:
	return {
		"food": maxi(0, int(nodes.get("animals", 0))),
		"wood": maxi(0, int(nodes.get("forest", 0))),
		"stone": maxi(0, int(nodes.get("stone", 0))),
		"iron": maxi(0, int(nodes.get("iron", 0))),
		"crystal": maxi(0, int(nodes.get("crystal", 0)))
	}


func _district_supplied(snapshot: Dictionary, faction: String, district_id: String) -> bool:
	return faction in FACTIONS and snapshot.factions[faction].supply.supplied_districts.has(district_id)


func _district_contested(snapshot: Dictionary, district_id: String) -> bool:
	var factions_present: Dictionary = {}
	for unit in snapshot.units.values():
		if str(unit.district) == district_id:
			factions_present[str(unit.faction)] = true
	return factions_present.size() > 1


func _translate_plans(plans: Dictionary) -> Dictionary:
	var translated: Dictionary = {}
	var receipts: Array = []
	for faction in FACTIONS:
		var simulation_orders: Array = []
		var plan: Dictionary = plans.get(faction, {})
		for order_variant in plan.get("orders", []):
			if not order_variant is Dictionary:
				continue
			var order: Dictionary = order_variant
			var result := _translate_order(faction, order)
			receipts.append({
				"faction_id": faction,
				"order_id": str(order.get("order_id", "unknown")),
				"accepted": not result.is_empty(),
				"reason": "translated" if not result.is_empty() else "unsupported_or_stale_reference"
			})
			if not result.is_empty():
				simulation_orders.append(result)
		var supply_priority: Array = plan.get("supply_priority", [])
		if not supply_priority.is_empty() and simulation_orders.size() < 3:
			simulation_orders.append({"kind": "set_supply_priority", "districts": supply_priority.duplicate()})
		translated[faction] = simulation_orders
	return {"orders": translated, "receipts": receipts}


func _translate_order(faction: String, order: Dictionary) -> Dictionary:
	var action := str(order.get("action", ""))
	var actors := _expand_actor_ids(faction, order.get("actor_ids", []))
	var target := _resolve_target_district(str(order.get("target_id", "")))
	match action:
		"assign_workers":
			var node: String = {"wood": "forest", "stone": "stone", "iron": "iron", "food": "animals", "crystal": "iron"}.get(str(order.get("resource", "")), "")
			if actors.is_empty() or target.is_empty() or node.is_empty():
				return {}
			return {"kind": "assign_workers", "district": target, "node": node, "unit_ids": actors}
		"hunt":
			if actors.is_empty() or target.is_empty():
				return {}
			var species := _hunt_species(target, str(order.get("option", "")))
			if species.is_empty():
				return {}
			return {"kind": "hunt", "unit_ids": actors, "district": target, "species": species}
		"scout":
			if actors.is_empty() or target.is_empty():
				return {}
			return {"kind": "mobilize", "unit_ids": actors, "target": target, "stance": "avoid"}
		"build":
			var structure := str(order.get("option", ""))
			if target.is_empty() or structure.is_empty():
				return {}
			return {"kind": "build", "structure": structure, "district": target, "unit_ids": actors}
		"train":
			var unit_kind := str(order.get("option", ""))
			if unit_kind.is_empty():
				return {}
			return {"kind": "train", "unit": unit_kind}
		"mobilize", "reinforce":
			if actors.is_empty() or target.is_empty():
				return {}
			return {"kind": "mobilize", "unit_ids": actors, "target": target, "stance": str(order.get("stance", "hold"))}
		"retreat":
			if actors.is_empty():
				return {}
			if target.is_empty():
				target = "core_%s" % faction
			return {"kind": "retreat", "unit_ids": actors, "target": target, "stance": str(order.get("stance", "avoid"))}
		_:
			return {}


func _expand_actor_ids(faction: String, actor_refs: Variant) -> Array:
	var result: Array = []
	if not actor_refs is Array:
		return result
	for actor_ref_variant in actor_refs:
		var actor_ref := str(actor_ref_variant)
		if simulation.state.units.has(actor_ref) and str(simulation.state.units[actor_ref].faction) == faction:
			if not result.has(actor_ref):
				result.append(actor_ref)
		elif group_members.has(faction) and group_members[faction].has(actor_ref):
			for unit_id in group_members[faction][actor_ref]:
				if not result.has(unit_id):
					result.append(unit_id)
	return result


func _resolve_target_district(target_id: String) -> String:
	if simulation.state.districts.has(target_id):
		return target_id
	if simulation.state.units.has(target_id):
		return str(simulation.state.units[target_id].district)
	if simulation.state.structures.has(target_id):
		return str(simulation.state.structures[target_id].district)
	return ""


func _hunt_species(district_id: String, requested: String) -> String:
	if not simulation.state.districts.has(district_id):
		return ""
	var wildlife: Dictionary = simulation.state.districts[district_id].get("wildlife", {})
	if wildlife.has(requested) and int(wildlife[requested].get("count", 0)) > 0:
		return requested
	var species_ids: Array = wildlife.keys()
	species_ids.sort()
	for species in species_ids:
		if int(wildlife[species].get("count", 0)) > 0:
			return str(species)
	return ""


func _communication_events(plans: Dictionary, round_number: int) -> Array:
	var events: Array = []
	for faction in FACTIONS:
		var plan: Dictionary = plans[faction]
		var public_intent := _clean_text(str(plan.get("public_intent", "Commander plan locked.")), 240)
		var intent_event := _arena_event(
			"message", faction, [], "public", [], public_intent, round_number,
			{"channel": "public_intent"}
		)
		events.append(intent_event)
		message_history.append({
			"message_id": intent_event.event_id,
			"sender_id": faction,
			"visibility": "public",
			"recipients": [],
			"text": public_intent,
			"sent_round": round_number
		})

		var communication: Dictionary = plan.get("communication", {})
		var utterance_index := 0
		for utterance_variant in communication.get("utterances", []):
			if not utterance_variant is Dictionary:
				continue
			var utterance: Dictionary = utterance_variant
			var visibility := str(utterance.get("visibility", "public"))
			var recipients: Array = utterance.get("recipients", [])
			var visible_to: Array = [] if visibility == "public" else recipients.duplicate()
			if visibility != "public" and not visible_to.has(faction):
				visible_to.append(faction)
			var text := _clean_text(str(utterance.get("text", "")), 320)
			if text.is_empty():
				continue
			var event := _arena_event(
				"message", faction, recipients,
				"public" if visibility == "public" else "participants",
				visible_to, text, round_number,
				{"client_ref": str(utterance.get("client_ref", "utterance.%d" % utterance_index))}
			)
			events.append(event)
			message_history.append({
				"message_id": event.event_id,
				"sender_id": faction,
				"visibility": visibility,
				"recipients": recipients.duplicate(),
				"text": text,
				"sent_round": round_number
			})
			utterance_index += 1

		var new_offer: Variant = communication.get("new_offer", null)
		if new_offer is Dictionary:
			var offer_event := _register_offer(faction, new_offer, round_number)
			if not offer_event.is_empty():
				events.append(offer_event)
		for response_variant in communication.get("responses", []):
			if response_variant is Dictionary:
				var response_event := _register_offer_response(faction, response_variant, round_number)
				if not response_event.is_empty():
					events.append(response_event)

		for operation_variant in plan.get("specialist_ops", []):
			if not operation_variant is Dictionary:
				continue
			var operation: Dictionary = operation_variant
			var operation_name := str(operation.get("operation", "update"))
			var specialist_id := str(operation.get("specialist_id", "specialist"))
			events.append(_arena_event(
				"advisor", faction, [], "faction", [faction],
				"%s specialist %s: %s" % [faction.capitalize(), specialist_id, operation_name],
				round_number, {"operation": operation_name, "specialist_id": specialist_id}
			))
	return events


func _register_offer(faction: String, offer: Dictionary, round_number: int) -> Dictionary:
	var recipient := str(offer.get("recipient", ""))
	var kind := str(offer.get("kind", ""))
	if not recipient in FACTIONS or recipient == faction or not kind in ["trade", "non_aggression", "coordinate_attack"]:
		return {}
	var offer_id := "offer.r%d.%s" % [round_number, faction]
	var expires_round := int(offer.get("expires_round", round_number + int(offer.get("duration_rounds", 1))))
	var summary := _offer_summary(faction, offer)
	var record := {
		"offer_id": offer_id,
		"kind": kind,
		"sender_id": faction,
		"recipient_id": recipient,
		"expires_round": clampi(expires_round, round_number + 1, 48),
		"summary": summary,
		"state": "offered",
		"terms": offer.duplicate(true)
	}
	pending_offers.append(record)
	return _arena_event(
		"offer", faction, [recipient], "participants", [faction, recipient],
		summary, round_number, {"offer_id": offer_id, "kind": kind, "state": "offered"}
	)


func _register_offer_response(faction: String, response: Dictionary, round_number: int) -> Dictionary:
	var offer_id := str(response.get("offer_id", ""))
	var decision := str(response.get("decision", "reject"))
	for index in range(pending_offers.size()):
		var offer: Dictionary = pending_offers[index]
		if str(offer.offer_id) != offer_id or faction not in [str(offer.sender_id), str(offer.recipient_id)]:
			continue
		var counterpart := str(offer.sender_id) if faction == str(offer.recipient_id) else str(offer.recipient_id)
		if decision == "accept" and faction != str(offer.recipient_id):
			decision = "reject"
		offer.state = decision
		var kind := "pact" if str(offer.kind) == "non_aggression" else "offer"
		var event := _arena_event(
			kind, faction, [counterpart], "participants", [faction, counterpart],
			"%s %s offer %s." % [faction.capitalize(), decision, str(offer.kind).replace("_", " ")],
			round_number, {"offer_id": offer_id, "state": decision, "kind": offer.kind}
		)
		if decision == "accept":
			pending_diplomacy_effects.append({"round": round_number, "acceptor": faction, "offer": offer.duplicate(true)})
		if decision in ["reject", "withdraw", "accept"]:
			pending_offers.remove_at(index)
		return event
	return {}


func _apply_pending_diplomacy_effects(plans: Dictionary, round_number: int) -> Dictionary:
	var events: Array = []
	var receipts: Array = []
	var remaining_effects: Array[Dictionary] = []
	for effect in pending_diplomacy_effects:
		if int(effect.get("round", -1)) != round_number:
			remaining_effects.append(effect)
			continue
		var offer: Dictionary = effect.offer
		var terms: Dictionary = offer.get("terms", {})
		var offer_kind := str(offer.get("kind", ""))
		var sender := str(offer.get("sender_id", ""))
		var recipient := str(offer.get("recipient_id", ""))
		var state := "executed"
		if offer_kind == "trade":
			var give: Dictionary = terms.get("give", {})
			var receive: Dictionary = terms.get("receive", {})
			if not _bundle_available(sender, give) or not _bundle_available(recipient, receive):
				state = "failed_insufficient_resources"
				failed_trade_count += 1
			else:
				_transfer_bundle(sender, recipient, give)
				_transfer_bundle(recipient, sender, receive)
				executed_trade_count += 1
			events.append(_arena_event(
				"offer", sender, [recipient], "participants", [sender, recipient],
				"Trade %s between %s and %s." % [state.replace("_", " "), sender.capitalize(), recipient.capitalize()],
				round_number, {"offer_id": offer.offer_id, "kind": "trade", "state": state, "give": give, "receive": receive}
			))
		elif offer_kind in ["non_aggression", "coordinate_attack"]:
			var relationship := {
				"id": str(offer.offer_id), "actor_id": sender, "target_id": recipient,
				"state": "active", "kind": offer_kind, "expires_round": int(offer.expires_round),
				"summary": str(offer.summary)
			}
			relationship_history.append(relationship)
			activated_pact_count += 1
			var event_kind := "pact" if offer_kind == "non_aggression" else "offer"
			var visibility := "public" if offer_kind == "non_aggression" and str(terms.get("visibility", "private")) == "public_on_accept" else "participants"
			var visible_to: Array = [] if visibility == "public" else [sender, recipient]
			var pact_event := _arena_event(
				event_kind, sender, [recipient], visibility, visible_to,
				"%s and %s activate %s until round %d." % [sender.capitalize(), recipient.capitalize(), offer_kind.replace("_", " "), int(offer.expires_round)],
				round_number, {"offer_id": offer.offer_id, "kind": offer_kind, "state": "active", "expires_round": offer.expires_round}
			)
			events.append(pact_event)
		receipts.append({
			"type": "diplomacy_effect", "offer_id": str(offer.get("offer_id", "")),
			"kind": offer_kind, "state": state, "round": round_number
		})
	pending_diplomacy_effects = remaining_effects
	var betrayal_result := _detect_pact_betrayals(plans, round_number)
	events.append_array(betrayal_result.events)
	receipts.append_array(betrayal_result.receipts)
	for relationship in relationship_history:
		if str(relationship.get("state", "")) == "active" and int(relationship.get("expires_round", 0)) < round_number:
			relationship.state = "expired"
	return {"events": events, "receipts": receipts}


func _detect_pact_betrayals(plans: Dictionary, round_number: int) -> Dictionary:
	var events: Array = []
	var receipts: Array = []
	for relationship in relationship_history:
		if str(relationship.get("kind", "")) != "non_aggression" or str(relationship.get("state", "")) != "active" or int(relationship.get("expires_round", 0)) < round_number:
			continue
		var first := str(relationship.actor_id)
		var second := str(relationship.target_id)
		for faction in [first, second]:
			var counterpart := second if faction == first else first
			for order_variant in plans.get(faction, {}).get("orders", []):
				if not order_variant is Dictionary or str(order_variant.get("action", "")) not in ["mobilize", "reinforce"]:
					continue
				var district_id := _resolve_target_district(str(order_variant.get("target_id", "")))
				if district_id.is_empty() or simulation.state.districts[district_id].get("owner", null) != counterpart:
					continue
				relationship.state = "betrayed"
				betrayal_count += 1
				var event := _arena_event(
					"betrayal", faction, [counterpart, district_id], "public", [],
					"%s breaks non-aggression with %s by mobilizing into %s." % [faction.capitalize(), counterpart.capitalize(), district_id],
					round_number, {"pact_id": relationship.id, "district_id": district_id, "state": "betrayed"}
				)
				events.append(event)
				receipts.append({"type": "pact_betrayal", "pact_id": relationship.id, "actor_id": faction, "district_id": district_id})
				break
	return {"events": events, "receipts": receipts}


func _bundle_available(faction: String, bundle: Dictionary) -> bool:
	if not faction in FACTIONS:
		return false
	var stockpile: Dictionary = simulation.state.factions[faction].stockpile
	for resource in ["food", "wood", "stone", "iron", "crystal"]:
		if int(stockpile.get(resource, 0)) < int(bundle.get(resource, 0)):
			return false
	return true


func _transfer_bundle(sender: String, recipient: String, bundle: Dictionary) -> void:
	var sender_stock: Dictionary = simulation.state.factions[sender].stockpile
	var recipient_stock: Dictionary = simulation.state.factions[recipient].stockpile
	for resource in ["food", "wood", "stone", "iron", "crystal"]:
		var amount := int(bundle.get(resource, 0))
		if amount <= 0:
			continue
		sender_stock[resource] = int(sender_stock.get(resource, 0)) - amount
		recipient_stock[resource] = int(recipient_stock.get(resource, 0)) + amount


func _offer_summary(faction: String, offer: Dictionary) -> String:
	match str(offer.get("kind", "")):
		"trade":
			return "%s offers %s for %s." % [
				faction.capitalize(), _bundle_text(offer.get("give", {})), _bundle_text(offer.get("receive", {}))
			]
		"non_aggression":
			return "%s proposes non-aggression for %d rounds." % [faction.capitalize(), int(offer.get("duration_rounds", 1))]
		"coordinate_attack":
			return "%s proposes a coordinated attack on %s at %s." % [faction.capitalize(), str(offer.get("target_faction", "opponent")).capitalize(), str(offer.get("target_district", "target"))]
	return "%s proposes an agreement." % faction.capitalize()


func _bundle_text(bundle: Dictionary) -> String:
	var values: Array[String] = []
	for resource in ["food", "wood", "stone", "iron", "crystal"]:
		var amount := int(bundle.get(resource, 0))
		if amount > 0:
			values.append("%d %s" % [amount, resource])
	return ", ".join(values) if not values.is_empty() else "nothing"


func _update_specialist_state(plans: Dictionary) -> void:
	for faction in FACTIONS:
		for operation_variant in plans[faction].get("specialist_ops", []):
			if not operation_variant is Dictionary:
				continue
			var operation: Dictionary = operation_variant
			var specialist_id := str(operation.get("specialist_id", ""))
			if specialist_id.is_empty():
				continue
			match str(operation.get("operation", "")):
				"create":
					specialist_metadata[faction][specialist_id] = {
						"id": specialist_id, "role": str(operation.get("role", "advisor")),
						"state": "active", "disposition": "created", "recommendation_summary": str(operation.get("brief", "Awaiting first advisory call."))
					}
				"update":
					if specialist_metadata[faction].has(specialist_id):
						specialist_metadata[faction][specialist_id].recommendation_summary = str(operation.get("brief", "Updated brief."))
						specialist_metadata[faction][specialist_id].disposition = "updated"
				"pause", "resume":
					if specialist_metadata[faction].has(specialist_id):
						specialist_metadata[faction][specialist_id].state = "paused" if str(operation.operation) == "pause" else "active"
				"dismiss":
					specialist_metadata[faction].erase(specialist_id)


func _arena_event(kind: String, actor_id: String, target_ids: Array, visibility: String, visible_to: Array, summary: String, round_number: int, payload: Dictionary = {}) -> Dictionary:
	event_sequence += 1
	return {
		"schema_version": 1,
		"event_id": "evt.%06d" % event_sequence,
		"match_id": str(simulation.state.match.id),
		"sequence": event_sequence,
		"round": round_number,
		"tick": 0,
		"kind": kind,
		"actor_id": actor_id,
		"target_ids": target_ids.duplicate(),
		"visibility": visibility,
		"visible_to": visible_to.duplicate(),
		"summary": _clean_text(summary, 320),
		"payload": payload.duplicate(true),
		"related_event_ids": []
	}


func _clean_text(value: String, max_length: int) -> String:
	var cleaned := value.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip_edges()
	while "  " in cleaned:
		cleaned = cleaned.replace("  ", " ")
	return cleaned.substr(0, max_length)


func _presentation_snapshot(snapshot: Dictionary, phase: String, statuses: Dictionary) -> Dictionary:
	var faction_records: Array = []
	for faction in FACTIONS:
		var faction_state: Dictionary = snapshot.factions[faction]
		var supplied_land := maxi(0, faction_state.supply.supplied_districts.size() - 1)
		var army_strength := 0
		for unit in snapshot.units.values():
			if str(unit.faction) == faction and str(unit.kind) not in ["worker"]:
				army_strength += 1
		var plan: Dictionary = latest_plans.get(faction, {})
		var order_records: Array = []
		for order_variant in plan.get("orders", []):
			if order_variant is Dictionary:
				order_records.append({
					"action": str(order_variant.get("action", "order")),
					"target": str(order_variant.get("target_id", ""))
				})
		var specialists: Array = specialist_metadata[faction].values()
		faction_records.append({
			"id": faction,
			"model": configured_models[faction],
			"core_hp": maxi(0, int(float(faction_state.core_hp))),
			"land_percent": float(supplied_land) / 10.0 * 100.0,
			"army_strength": army_strength,
			"state": _faction_state_label(snapshot, faction),
			"resources": _resource_bundle_from_stockpile(faction_state.stockpile),
			"cognition": {
				"round_spent": 120 - int(cognition_remaining[faction]),
				"round_budget": 120,
				"match_spent": 120 - int(cognition_remaining[faction])
			},
			"strategic_intent": str(plan.get("public_intent", "Awaiting the first sealed plan.")),
			"orders": order_records,
			"specialists": specialists
		})

	var district_records: Array = []
	var district_ids: Array = snapshot.districts.keys()
	district_ids.sort()
	for district_id in district_ids:
		var state := _district_presentation_state(snapshot, str(district_id))
		state.id = str(district_id)
		district_records.append(state)

	var unit_records: Array = []
	var unit_ids: Array = snapshot.units.keys()
	unit_ids.sort()
	for unit_id in unit_ids:
		var unit: Dictionary = snapshot.units[unit_id]
		unit_records.append({
			"id": str(unit_id),
			"faction_id": str(unit.faction),
			"unit_type": str(unit.kind),
			"district_id": str(unit.district),
			"health": maxi(0, int(float(unit.hp))),
			"max_health": _unit_max_health(str(unit.kind)),
			"task": _unit_task(unit),
			"supplied": _district_supplied(snapshot, str(unit.faction), str(unit.district)),
			"in_combat": _district_contested(snapshot, str(unit.district)),
			"starving": int(snapshot.factions[unit.faction].starving_rounds) > 0
		})

	var elapsed_seconds := maxi(0, (int(snapshot.match.round) - 1) * 15)
	return {
		"match_id": str(snapshot.match.id),
		"round": int(snapshot.match.round),
		"max_rounds": NORMAL_ROUND_LIMIT,
		"phase": phase,
		"sim_time": "%02d:%02d" % [elapsed_seconds / 60, elapsed_seconds % 60],
		"thinking_status": statuses.duplicate(true),
		"factions": faction_records,
		"districts": district_records,
		"units": unit_records,
		"relationships": relationship_history.duplicate(true),
		"state_hash": str(snapshot.match.state_hash),
		"winner": str(snapshot.match.winner)
	}


func _district_presentation_state(snapshot: Dictionary, district_id: String) -> Dictionary:
	var district: Dictionary = snapshot.districts[district_id]
	var owner: Variant = district.get("owner", null)
	var capture: Dictionary = district.get("capture", {})
	return {
		"owner": "neutral" if owner == null else str(owner),
		"supplied": true if owner == null else _district_supplied(snapshot, str(owner), district_id),
		"contested": _district_contested(snapshot, district_id),
		"capture_progress": clampf(float(capture.get("progress", 0)) / 2.0, 0.0, 1.0),
		"capture_faction": capture.get("faction", null)
	}


func _unit_max_health(kind: String) -> int:
	return {"commander": 150, "worker": 30, "scout": 40, "militia": 75, "guard": 110, "siege": 130}.get(kind, 100)


func _unit_task(unit: Dictionary) -> String:
	if unit.has("harvest"):
		return "harvest %s" % str(unit.harvest)
	if not str(unit.get("target", "")).is_empty():
		return "move %s" % str(unit.target)
	return "hold"


func _faction_state_label(snapshot: Dictionary, faction: String) -> String:
	if float(snapshot.factions[faction].core_hp) <= 0.0:
		return "eliminated"
	for unit in snapshot.units.values():
		if str(unit.faction) == faction and _district_contested(snapshot, str(unit.district)):
			return "in combat"
	var plan: Dictionary = latest_plans.get(faction, {})
	if not plan.get("communication", {}).get("utterances", []).is_empty():
		return "negotiating"
	return "expanding"


func _simulation_events(raw_events: Array, round_number: int) -> Array:
	var events: Array = []
	for raw_variant in raw_events:
		if not raw_variant is Dictionary:
			continue
		var raw: Dictionary = raw_variant
		var raw_type := str(raw.get("type", "system"))
		var actor := str(raw.get("faction", ""))
		var kind := "system"
		var targets: Array = []
		var summary := "Arena state updated."
		var payload := raw.duplicate(true)
		match raw_type:
			"order_accepted":
				kind = "order"
				summary = "%s order accepted: %s." % [actor.capitalize(), str(raw.get("kind", "order")).replace("_", " ")]
			"order_rejected":
				kind = "order"
				summary = "%s order rejected by physical reality: %s." % [actor.capitalize(), str(raw.get("kind", "order")).replace("_", " ")]
			"unit_moved":
				kind = "order"
				targets = [str(raw.get("district", ""))]
				summary = "%s forces move into %s." % [actor.capitalize(), str(raw.get("district", "unknown district"))]
			"unit_killed":
				kind = "combat"
				targets = [str(raw.get("unit_id", ""))]
				summary = "%s loses %s in simultaneous combat." % [actor.capitalize(), str(raw.get("unit_id", "a unit"))]
			"starvation":
				kind = "resource"
				summary = "%s cannot feed %d units." % [actor.capitalize(), int(raw.get("units", 0))]
			"capture_ready":
				kind = "territory"
				targets = [str(raw.get("district", ""))]
				summary = "%s completes control pressure in %s." % [actor.capitalize(), str(raw.get("district", "a district"))]
			"district_neutralized":
				kind = "supply"
				targets = [str(raw.get("district", ""))]
				summary = "%s is neutralized after its supply line collapses." % str(raw.get("district", "A district"))
			"match_ended":
				kind = "core"
				summary = "%s wins WorldArena." % actor.capitalize()
		var event := _arena_event(kind, actor, targets, "public", [], summary, round_number, payload)
		event.tick = 150
		if kind in ["territory", "supply"] and not targets.is_empty() and simulation.state.districts.has(targets[0]):
			event.payload["district_id"] = targets[0]
			event.payload["district_state"] = _district_presentation_state(simulation.get_snapshot(), targets[0])
		events.append(event)
	return events


func _update_recent_events(events: Array) -> void:
	for event_variant in events:
		if event_variant is Dictionary and str(event_variant.get("visibility", "public")) == "public":
			recent_event_summaries.append(str(event_variant.get("summary", "Event")))
	while recent_event_summaries.size() > 24:
		recent_event_summaries.pop_front()
	while message_history.size() > 72:
		message_history.pop_front()


func _run_offline_demo() -> void:
	configured_models = {"sol": "demo-policy", "terra": "demo-policy", "luna": "demo-policy"}
	presentation.mark_setup_accepted(_presentation_snapshot(simulation.get_snapshot(), "thinking", _all_status("thinking")))
	var target_rounds := _test_round_limit if _test_round_limit > 0 else 4
	while rounds_completed < target_rounds and not bool(simulation.state.match.ended):
		var snapshot := simulation.get_snapshot()
		current_round_request = _build_round_request(snapshot)
		presentation.set_phase("thinking", _all_status("thinking"))
		await get_tree().create_timer(0.03).timeout
		var plans: Dictionary = {}
		for faction in FACTIONS:
			plans[faction] = _offline_plan(faction, int(snapshot.match.round), current_round_request.observations)
		latest_plans = plans.duplicate(true)
		presentation.set_phase("plans_locked", _all_status("locked"))
		var communication_events := _communication_events(plans, int(snapshot.match.round))
		presentation.apply_events(communication_events)
		_resolve_plans(plans, communication_events, int(snapshot.match.round))
		await get_tree().create_timer(0.03).timeout
	_finish_test()


func _offline_plan(faction: String, round_number: int, observations: Array) -> Dictionary:
	var observation: Dictionary = {}
	for candidate_variant in observations:
		if candidate_variant is Dictionary and str(candidate_variant.get("faction_id", "")) == faction:
			observation = candidate_variant
			break
	var workers := _first_group_of_kind(observation.get("groups", []), "worker")
	var militia := _first_group_of_kind(observation.get("groups", []), "militia")
	var commander := _first_group_of_kind(observation.get("groups", []), "commander")
	var orders: Array = []
	var intent := "Secure production and observe both opponents."
	if round_number == 1 and not workers.is_empty():
		orders.append({
			"order_id": "%s.r1.gather" % faction, "action": "assign_workers",
			"actor_ids": [workers.group_id], "target_id": "home_%s" % faction,
			"resource": "wood", "option": null, "stance": null
		})
		intent = "Build a wood reserve before the first territorial clash."
	elif round_number == 2 and not militia.is_empty():
		var mine := "mine_st" if faction in ["sol", "terra"] else "mine_ls"
		orders.append({
			"order_id": "%s.r2.move" % faction, "action": "mobilize",
			"actor_ids": [militia.group_id], "target_id": mine,
			"resource": null, "option": null, "stance": "assault"
		})
		intent = "Contest the nearest iron mine before rivals can fortify it."
	elif round_number >= 3:
		var actor := militia if not militia.is_empty() else commander
		if not actor.is_empty():
			var objective := "home_luna" if faction == "sol" and round_number == 3 else "crown"
			orders.append({
				"order_id": "%s.r%d.crown" % [faction, round_number], "action": "mobilize",
				"actor_ids": [actor.group_id], "target_id": objective,
				"resource": null, "option": null, "stance": "raid"
			})
		intent = "Pressure the Crown while retaining the supplied homeland."

	var utterances: Array = []
	if round_number == 1 and faction == "sol":
		utterances.append({"client_ref": "sol.r1.luna", "visibility": "private", "recipients": ["luna"], "text": "Terra shares our mine. Coordinate pressure next round?"})
	elif round_number == 1 and faction == "luna":
		utterances.append({"client_ref": "luna.r1.sol", "visibility": "private", "recipients": ["sol"], "text": "Agreed for one round. I will scout the Crown route."})
	elif round_number == 2 and faction == "terra":
		utterances.append({"client_ref": "terra.r2.all", "visibility": "public", "recipients": [], "text": "The mine is open. Any coalition against me will pay for every metre."})

	var new_offer: Variant = null
	var responses: Array = []
	if round_number == 1 and faction == "sol":
		new_offer = {
			"kind": "trade", "recipient": "luna", "visibility": "private",
			"give": {"food": 0, "wood": 10, "stone": 0, "iron": 0, "crystal": 0},
			"receive": {"food": 5, "wood": 0, "stone": 0, "iron": 0, "crystal": 0},
			"expires_round": 3
		}
	elif round_number == 1 and faction == "luna":
		new_offer = {
			"kind": "non_aggression", "recipient": "sol", "visibility": "public_on_accept",
			"duration_rounds": 3, "regions": ["*"], "expires_round": 4
		}
	elif round_number == 2 and faction == "luna":
		responses.append({"offer_id": "offer.r1.sol", "decision": "accept"})
	elif round_number == 2 and faction == "sol":
		responses.append({"offer_id": "offer.r1.luna", "decision": "accept"})
	return {
		"schema_version": "arena-v1",
		"match_id": str(simulation.state.match.id),
		"round": round_number,
		"faction_id": faction,
		"public_intent": intent,
		"orders": orders,
		"communication": {"utterances": utterances, "new_offer": new_offer, "responses": responses},
		"specialist_ops": [],
		"supply_priority": ["home_%s" % faction]
	}


func _first_group_of_kind(groups: Array, kind: String) -> Dictionary:
	for group_variant in groups:
		if group_variant is Dictionary and str(group_variant.get("unit_kind", "")) == kind:
			return group_variant
	return {}
