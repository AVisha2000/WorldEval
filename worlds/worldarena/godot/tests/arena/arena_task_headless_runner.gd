extends SceneTree

const ArenaSimulation := preload("res://scripts/arena/simulation/arena_simulation.gd")


func _init() -> void:
	var gather := ArenaSimulation.new(300)
	var gather_worker: String = str(_worker_ids(gather, "sol")[0])
	var initial_wood := int(gather.state.factions.sol.stockpile.wood)
	gather.apply_round({"sol": [{"kind": "assign_workers", "district": "home_sol", "node": "forest", "unit_ids": [gather_worker]}]})
	assert(_worker_ids(gather, "sol").size() == 1, "v0.4 default must start one worker")
	assert(_unit_ids(gather, "sol", "militia").is_empty(), "v0.4 default must not grant militia")
	assert(int(gather.state.factions.sol.stockpile.wood) > initial_wood, "one worker must gather through tick work")
	var gather_task := _first_task(gather, "gather")
	assert(int(gather_task.required_work) == 10 and gather_task.worker_ids == [gather_worker], "gather task work contract missing")
	var impact := _first_event(gather.get_events(), "task_impact")
	assert(not impact.is_empty() and int(impact.tick) == 10 and int(impact.resource_delta) == 12, "gather impact must be a deterministic tenth-tick event")

	var one_builder := ArenaSimulation.new(301)
	var one_worker: String = str(_worker_ids(one_builder, "sol")[0])
	one_builder.state.factions.sol.stockpile.wood = 100
	one_builder.state.factions.sol.stockpile.stone = 100
	one_builder.apply_round({"sol": [{"kind": "build", "structure": "farm", "district": "home_sol", "worker_ids": [one_worker]}]})
	var one_complete := _first_event(one_builder.get_events(), "task_completed")
	assert(not one_complete.is_empty() and int(one_complete.tick) == 150, "one worker must take 150 work ticks to build a farm")

	var two_builders := ArenaSimulation.new(301)
	two_builders._add_unit_to(two_builders.state, "sol", "worker", "home_sol")
	two_builders.state.factions.sol.stockpile.wood = 100
	two_builders.state.factions.sol.stockpile.stone = 100
	var two_workers := _worker_ids(two_builders, "sol")
	two_builders.apply_round({"sol": [{"kind": "build", "structure": "farm", "district": "home_sol", "worker_ids": two_workers}]})
	var two_complete := _first_event(two_builders.get_events(), "task_completed")
	assert(not two_complete.is_empty() and int(two_complete.tick) == 75, "two builders must finish a two-worker-cap job in half the time")
	assert(int(two_complete.required_work) == 150 and int(two_complete.completed_work) == 150, "build completion must expose authoritative work totals")
	assert(str(two_complete.event_id).begins_with("event.") and str(two_complete.kind) == "task_completed", "tick events must be replay-addressable")
	print("ARENA_TASK_HEADLESS_OK gather_tick=%d one_builder_tick=%d two_builder_tick=%d" % [impact.tick, one_complete.tick, two_complete.tick])
	quit(0)


func _unit_ids(sim: ArenaSimulation, faction: String, kind: String) -> Array:
	var ids: Array = []
	for unit_id in sim.state.units.keys():
		if sim.state.units[unit_id].faction == faction and sim.state.units[unit_id].kind == kind: ids.append(unit_id)
	ids.sort()
	return ids


func _worker_ids(sim: ArenaSimulation, faction: String) -> Array:
	return _unit_ids(sim, faction, "worker")


func _first_task(sim: ArenaSimulation, kind: String) -> Dictionary:
	for task in sim.state.tasks.values():
		if task.kind == kind: return task
	return {}


func _first_event(events: Array, kind: String) -> Dictionary:
	for event in events:
		if event.kind == kind: return event
	return {}
