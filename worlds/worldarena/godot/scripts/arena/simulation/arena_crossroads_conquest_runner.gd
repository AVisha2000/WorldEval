extends SceneTree

const ArenaSimulation := preload("res://scripts/arena/simulation/arena_simulation.gd")
const CrossroadsPolicy := preload("res://scripts/arena/simulation/arena_crossroads_conquest_policy.gd")
const SEED := 424242
const MAX_ROUNDS := 29
const TRACE_STRIDE_TICKS := 10


func _init() -> void:
	var output := _output_path(OS.get_cmdline_user_args())
	if output.is_empty():
		quit(2)
		return
	var simulation := ArenaSimulation.new(SEED)
	var policy := CrossroadsPolicy.new()
	var initial_snapshot := simulation.get_snapshot()
	var rounds: Array = []
	var all_events: Array = []
	while int(simulation.state.match.round) <= MAX_ROUNDS and not bool(simulation.state.match.ended):
		var round_number := int(simulation.state.match.round)
		var plans := {}
		for faction in ["sol", "terra", "luna"]:
			plans[faction] = policy.orders_for(simulation.project_faction_observation(faction))
		var resolved: Dictionary = simulation.apply_round_with_trace(plans, TRACE_STRIDE_TICKS)
		var frames: Array = []
		for sample in resolved.trace:
			var frame_snapshot: Dictionary = sample.snapshot.duplicate(true)
			frame_snapshot.events = []
			frames.append({"index": frames.size(), "round": round_number, "tick": int(sample.tick), "round_tick": int(sample.round_tick), "snapshot": frame_snapshot, "events": sample.events})
			all_events.append_array(sample.events)
		rounds.append({"round": round_number, "plans": plans, "frames": frames})
	var final_snapshot := simulation.get_snapshot()
	var bundle := {
		"schema": "worldarena/crossroads-conquest-authority-trace/1",
		"showcase_id": "crossroads-conquest-v0",
		"protocol": "world-arena/0.4",
		"map_id": "tri_13_v1",
		"rules_id": "arena-v0.4",
		"seed": SEED,
		"policy_id": CrossroadsPolicy.POLICY_ID,
		"initial_snapshot": initial_snapshot,
		"rounds": rounds,
		"events": all_events,
		"final_snapshot": final_snapshot,
		"final_state_hash": simulation.get_state_hash()
	}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		printerr("CROSSROADS_AUTHORITY_ERROR cannot open output")
		quit(1)
		return
	file.store_string(JSON.stringify(bundle, "", true))
	file.close()
	print("CROSSROADS_AUTHORITY_OK rounds=%d winner=%s hash=%s output=%s" % [rounds.size(), str(final_snapshot.match.winner), simulation.get_state_hash(), output])
	quit(0)


func _output_path(args: PackedStringArray) -> String:
	for argument in args:
		if str(argument).begins_with("--output="):
			var value := str(argument).trim_prefix("--output=").simplify_path()
			if value.is_absolute_path() and value.get_extension().to_lower() == "json" and not FileAccess.file_exists(value): return value
	printerr("CROSSROADS_AUTHORITY_ERROR pass a new absolute --output=.json")
	return ""
