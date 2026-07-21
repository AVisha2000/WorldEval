extends SceneTree

## Authoritative, render-free ArenaSimulation batch runner.  This script owns no
## game rules: policies only submit orders to ArenaSimulation, which validates and
## resolves every 10 Hz tick synchronously.

const ArenaSimulation := preload("res://scripts/arena/simulation/arena_simulation.gd")
const Rules := preload("res://scripts/arena/simulation/arena_rules.gd")
const ALLOWED_POLICIES := ["deterministic_demo"]
const MIN_ROUNDS := 1
const MAX_ROUNDS := 200
const PRESENTATION_SECONDS_PER_ROUND := 2.5
const TRACE_STRIDE_TICKS := 10
const RNG_MOD := 2147483647


func _init() -> void:
	var started_msec := Time.get_ticks_msec()
	var options := _parse_options(OS.get_cmdline_user_args())
	if options.is_empty():
		quit(2)
		return
	var simulation := ArenaSimulation.new(int(options.numeric_seed))
	var initial_snapshot := simulation.get_snapshot()
	var frames: Array = []
	var completed_rounds := 0
	while completed_rounds < int(options.max_rounds) and not bool(simulation.state.match.ended):
		var resolving_round := int(simulation.state.match.round)
		var plans := _plans_for_round(simulation, resolving_round, str(options.policy))
		var resolved: Dictionary = simulation.apply_round_with_trace(plans, TRACE_STRIDE_TICKS)
		var trace: Array = resolved.trace
		var sample_duration := PRESENTATION_SECONDS_PER_ROUND / maxf(1.0, float(trace.size()))
		var round_start := float(completed_rounds) * PRESENTATION_SECONDS_PER_ROUND
		for sample_index in trace.size():
			var sample: Dictionary = trace[sample_index]
			# Trace snapshots contain ArenaSimulation's cumulative round event list,
			# while frame.events already carries this sample's raw event partition.
			# Keep the snapshot shape but clear the redundant copy to avoid replay bloat.
			var frame_snapshot: Dictionary = sample.snapshot.duplicate(true)
			frame_snapshot["events"] = []
			frames.append({
				"index": frames.size(),
				"round": resolving_round,
				"tick": int(sample.tick),
				"round_tick": int(sample.round_tick),
				"at_seconds": round_start + float(sample_index) * sample_duration,
				"duration_seconds": sample_duration,
				"snapshot": frame_snapshot,
				"events": sample.events
			})
		completed_rounds += 1
	var runtime_seconds := float(Time.get_ticks_msec() - started_msec) / 1000.0
	var bundle := {
		"protocol": "world-arena-replay/1",
		"run_id": options.run_id,
		"created_at": Time.get_datetime_string_from_system(true, true),
		"source": "headless",
		"seed": options.seed,
		"numeric_seed": int(options.numeric_seed),
		"policy": options.policy,
		"max_rounds": int(options.max_rounds),
		"completed_rounds": completed_rounds,
		"simulated_seconds": float(completed_rounds * Rules.ROUND_TICKS) * Rules.TICK_SECONDS,
		"duration_seconds": float(completed_rounds) * PRESENTATION_SECONDS_PER_ROUND,
		"runtime_seconds": runtime_seconds,
		"initial_snapshot": initial_snapshot,
		"frames": frames,
		"result": _result_summary(simulation, completed_rounds, int(options.max_rounds))
	}
	if FileAccess.file_exists(str(options.summary_output)):
		printerr("ARENA_BATCH_ERROR Refusing to overwrite existing summary: %s" % str(options.summary_output))
		quit(1)
		return
	var save_error := _write_bundle_atomically(str(options.output), bundle)
	if not save_error.is_empty():
		printerr("ARENA_BATCH_ERROR %s" % save_error)
		quit(1)
		return
	var summary := bundle.duplicate(true)
	summary.erase("initial_snapshot")
	summary.erase("frames")
	summary["replay_id"] = options.run_id
	summary["frame_count"] = frames.size()
	summary["duration_seconds"] = float(completed_rounds) * PRESENTATION_SECONDS_PER_ROUND
	var summary_error := _write_bundle_atomically(str(options.summary_output), summary)
	if not summary_error.is_empty():
		printerr("ARENA_BATCH_ERROR %s" % summary_error)
		quit(1)
		return
	print("ARENA_BATCH_OK run_id=%s rounds=%d simulated_seconds=%.1f runtime_seconds=%.3f output=%s winner=%s" % [options.run_id, completed_rounds, float(bundle.simulated_seconds), runtime_seconds, options.output, str(bundle.result.winner)])
	quit(0)


func _parse_options(args: PackedStringArray) -> Dictionary:
	var raw := {}
	var allowed := ["output", "output-dir", "run-id", "seed", "seed-label", "max-rounds", "policy"]
	var index := 0
	while index < args.size():
		var argument := str(args[index])
		if not argument.begins_with("--"):
			return _argument_error("Expected an option, got '%s'." % argument)
		var key := ""
		var value := ""
		var divider := argument.find("=")
		if divider >= 3:
			key = argument.substr(2, divider - 2)
			value = argument.substr(divider + 1)
		else:
			key = argument.substr(2)
			index += 1
			if index >= args.size():
				return _argument_error("Missing value for --%s." % key)
			value = str(args[index])
		if key not in allowed or value.is_empty() or raw.has(key):
			return _argument_error("Invalid, empty, duplicate, or unsupported argument '--%s'." % key)
		raw[key] = value
		index += 1
	if raw.has("output") == raw.has("output-dir"):
		return _argument_error("Provide exactly one of --output or --output-dir.")
	for required in ["seed", "max-rounds", "policy"]:
		if not raw.has(required):
			return _argument_error("Missing required --%s argument." % required)
	var output := str(raw.get("output", ""))
	if raw.has("output-dir"):
		var output_dir := str(raw["output-dir"])
		if not output_dir.is_absolute_path() or output_dir != output_dir.simplify_path():
			return _argument_error("--output-dir must be a clean absolute path.")
		output = output_dir.path_join("bundle.json")
	var clean_output := output.simplify_path()
	if not output.is_absolute_path() or output != clean_output or output.get_extension().to_lower() != "json":
		return _argument_error("--output must be a clean absolute .json path.")
	var run_id := str(raw.get("run-id", output.get_base_dir().get_file()))
	if not _is_safe_run_id(run_id):
		return _argument_error("--run-id must match [a-z0-9][a-z0-9_-]{0,63}.")
	if not str(raw["max-rounds"]).is_valid_int():
		return _argument_error("--max-rounds must be an integer from %d to %d." % [MIN_ROUNDS, MAX_ROUNDS])
	var max_rounds := int(str(raw["max-rounds"]))
	if max_rounds < MIN_ROUNDS or max_rounds > MAX_ROUNDS:
		return _argument_error("--max-rounds must be from %d to %d." % [MIN_ROUNDS, MAX_ROUNDS])
	if not ALLOWED_POLICIES.has(str(raw.policy)):
		return _argument_error("--policy must be one of: %s." % ", ".join(ALLOWED_POLICIES))
	if not _is_safe_seed_label(str(raw.seed)):
		return _argument_error("--seed may contain only letters, digits, '.', '_', ':', or '-'.")
	var seed_label := str(raw.get("seed-label", raw.seed))
	if not _is_safe_seed_label(seed_label):
		return _argument_error("--seed-label may contain only letters, digits, '.', '_', ':', or '-'.")
	return {"output": clean_output, "summary_output": clean_output.get_base_dir().path_join("summary.json"), "run_id": run_id, "seed": seed_label, "numeric_seed": _numeric_seed(str(raw.seed)), "max_rounds": max_rounds, "policy": str(raw.policy)}


func _argument_error(message: String) -> Dictionary:
	printerr("ARENA_BATCH_ERROR %s" % message)
	return {}


func _is_safe_run_id(value: String) -> bool:
	if value.length() < 1 or value.length() > 64:
		return false
	if not _is_ascii_lowercase_or_digit(value.unicode_at(0)):
		return false
	for character in value:
		var code := character.unicode_at(0)
		if not (_is_ascii_lowercase_or_digit(code) or code in [95, 45]):
			return false
	return true


func _is_safe_seed_label(value: String) -> bool:
	if value.length() < 1 or value.length() > 96:
		return false
	for character in value:
		var code := character.unicode_at(0)
		if not (_is_ascii_alphanumeric(code) or code in [95, 46, 58, 45]):
			return false
	return true


func _is_ascii_alphanumeric(code: int) -> bool:
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


func _is_ascii_lowercase_or_digit(code: int) -> bool:
	return (code >= 48 and code <= 57) or (code >= 97 and code <= 122)


func _numeric_seed(label: String) -> int:
	# Decimal values are already backend-authoritative numeric seeds. Other labels
	# use the same SHA-256 first-four-bytes mapping as the Python/backend entrypoints.
	if label.is_valid_int():
		var decimal := int(label)
		return decimal if decimal > 0 else 1
	var digest := label.sha256_text()
	var value := 0
	for index in 8:
		var code := digest.unicode_at(index)
		var digit := code - 48 if code <= 57 else code - 87
		value = value * 16 + digit
	return value % 2147483648


func _plans_for_round(simulation: ArenaSimulation, round_number: int, policy: String) -> Dictionary:
	assert(policy == "deterministic_demo")
	var plans := {}
	for faction in Rules.FACTIONS:
		plans[faction] = _deterministic_demo_orders(simulation, faction, round_number)
	return plans


func _deterministic_demo_orders(simulation: ArenaSimulation, faction: String, round_number: int) -> Array:
	var state: Dictionary = simulation.state
	if bool(state.factions[faction].eliminated):
		return []
	var home := "home_%s" % faction
	var workers := _unit_ids_at(state, faction, "worker", home)
	var all_workers := _unit_ids(state, faction, "worker")
	var combatants := _combat_unit_ids(state, faction)
	var orders: Array = []
	var rival: String = str({"sol": "terra", "terra": "luna", "luna": "sol"}[faction])
	# Opening establishes scarcity-driven work, then fortifies and expands before war.
	if round_number == 1 and not workers.is_empty():
		orders.append({"type": "Gather", "district": home, "node": "forest", "unit_ids": workers})
		orders.append({"kind": "train", "unit": "worker"})
		return orders
	# A newly trained worker spawns at the core. Move it to the home economy before
	# assigning the two-worker build orders below.
	var workers_away := _unit_ids_not_at(state, faction, "worker", home)
	if not workers_away.is_empty() and orders.size() < Rules.MAX_ORDERS:
		orders.append({"type": "Move", "unit_ids": workers_away, "target": home})
	# Build tasks consume up to two co-located workers and advance through all 150
	# authoritative ticks. Farm then storage creates visible multi-step work evidence.
	var build_kind := ""
	if workers.size() >= 2:
		if not _has_structure_or_task(state, faction, home, "farm"):
			build_kind = "farm"
		elif not _has_structure_or_task(state, faction, home, "storage"):
			build_kind = "storage"
	if not build_kind.is_empty() and _can_afford(state.factions[faction].stockpile, Rules.STRUCTURES[build_kind].cost) and orders.size() < Rules.MAX_ORDERS:
		orders.append({"type": "Build", "structure": build_kind, "district": home, "worker_ids": workers.slice(0, 2)})
	else:
		# Do not replace an active gather task every round: task ownership is
		# authoritative state and should remain persistent until a build needs it.
		var idle_workers := _idle_worker_ids_at(state, faction, home)
		if not idle_workers.is_empty() and orders.size() < Rules.MAX_ORDERS:
			orders.append({"type": "Gather", "district": home, "node": "forest", "unit_ids": idle_workers})
	if round_number >= 6 and not state.factions[faction].tech.completed.has("fieldcraft") and orders.size() < Rules.MAX_ORDERS and _can_afford(state.factions[faction].stockpile, Rules.RESEARCH.fieldcraft.cost):
		orders.append({"type": "Research", "technology_id": "fieldcraft", "district": home, "worker_ids": workers.slice(0, 1)})
	# Recruit affordable militia while the task/economy continues. Its target is set
	# on later rounds by the persistent combat order above.
	if orders.size() < Rules.MAX_ORDERS and _can_afford(state.factions[faction].stockpile, Rules.TRAINING.militia.cost):
		orders.append({"kind": "train", "unit": "militia"})
	if round_number >= 8 and orders.size() < Rules.MAX_ORDERS and not combatants.is_empty():
		orders.append({"type": "Attack", "unit_ids": combatants, "target_id": "core_%s" % rival})
	return orders


func _unit_ids(state: Dictionary, faction: String, kind: String) -> Array:
	var ids: Array = []
	for unit_id in state.units.keys():
		var unit: Dictionary = state.units[unit_id]
		if str(unit.faction) == faction and str(unit.kind) == kind:
			ids.append(str(unit_id))
	ids.sort()
	return ids


func _unit_ids_at(state: Dictionary, faction: String, kind: String, district: String) -> Array:
	return _unit_ids(state, faction, kind).filter(func(unit_id): return str(state.units[unit_id].district) == district)


func _unit_ids_not_at(state: Dictionary, faction: String, kind: String, district: String) -> Array:
	return _unit_ids(state, faction, kind).filter(func(unit_id): return str(state.units[unit_id].district) != district)


func _idle_worker_ids_at(state: Dictionary, faction: String, district: String) -> Array:
	var ids: Array = []
	for unit_id in _unit_ids_at(state, faction, "worker", district):
		if str(state.units[unit_id].get("task_id", "")).is_empty():
			ids.append(unit_id)
	return ids


func _combat_unit_ids(state: Dictionary, faction: String) -> Array:
	var ids: Array = []
	for unit_id in state.units.keys():
		var unit: Dictionary = state.units[unit_id]
		if str(unit.faction) == faction and str(unit.kind) != "worker":
			ids.append(str(unit_id))
	ids.sort()
	return ids


func _has_structure_or_task(state: Dictionary, faction: String, district: String, kind: String) -> bool:
	for structure in state.structures.values():
		if str(structure.faction) == faction and str(structure.district) == district and str(structure.kind) == kind:
			return true
	for task in state.tasks.values():
		if str(task.faction) == faction and str(task.district) == district and str(task.get("structure_kind", "")) == kind:
			return true
	return false


func _can_afford(stockpile: Dictionary, cost: Dictionary) -> bool:
	for resource in cost.keys():
		if int(stockpile.get(resource, 0)) < int(cost[resource]):
			return false
	return true


func _result_summary(simulation: ArenaSimulation, completed_rounds: int, max_rounds: int) -> Dictionary:
	var snapshot := simulation.get_snapshot()
	var factions := {}
	for faction in Rules.FACTIONS:
		var state: Dictionary = snapshot.factions[faction]
		factions[faction] = {
			"eliminated": bool(state.eliminated),
			"core_hp": float(state.core_hp),
			"ranking_metrics": simulation.get_faction_ranking_metrics(faction),
			"territory_control_rounds": int(state.territory.control_point_rounds),
			"tech_tier": int(state.tech.get("tier", 0))
		}
	return {
		"terminal": bool(snapshot.match.ended),
		"winner": str(snapshot.match.winner),
		"reason": "terminal" if bool(snapshot.match.ended) else "max_rounds_reached",
		"completed_rounds": completed_rounds,
		"objective": {"id": "conquest", "strongholds_alive": Rules.FACTIONS.filter(func(faction): return not bool(snapshot.factions[faction].eliminated)).size()},
		"reward": {"factions": factions, "note": "Authoritative conquest evidence; no scalar reward is defined by ArenaSimulation."}
	}


func _write_bundle_atomically(output: String, bundle: Dictionary) -> String:
	if FileAccess.file_exists(output):
		return "Refusing to overwrite existing output: %s" % output
	var parent := output.get_base_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(parent)
	if directory_error != OK:
		return "Could not create output directory '%s' (error %d)." % [parent, directory_error]
	var temporary := "%s.tmp.%d" % [output, OS.get_process_id()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return "Could not open temporary output '%s'." % temporary
	file.store_string(JSON.stringify(bundle, "", true))
	file.flush()
	file.close()
	var rename_error := DirAccess.rename_absolute(temporary, output)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary)
		return "Could not atomically rename replay output (error %d)." % rename_error
	return ""
