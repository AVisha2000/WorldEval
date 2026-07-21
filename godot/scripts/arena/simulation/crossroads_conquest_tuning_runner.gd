extends SceneTree

## Developer-only authority diagnostic.  The policy receives only participant
## projections; full snapshots are read after resolution solely to explain tuning
## failures.  This file is intentionally separate from the immutable showcase runner.

const ArenaSimulation := preload("res://scripts/arena/simulation/arena_simulation.gd")
const CrossroadsPolicy := preload("res://scripts/arena/simulation/arena_crossroads_conquest_policy.gd")
const FACTIONS := ["sol", "terra", "luna"]
const SEED := 424242
const MAX_ROUNDS := 29


func _init() -> void:
	var simulation := ArenaSimulation.new(SEED)
	var policy := CrossroadsPolicy.new()
	var rejection_count := 0
	for ignored in MAX_ROUNDS:
		if bool(simulation.state.match.ended): break
		var resolving_round := int(simulation.state.match.round)
		var plans := {}
		for faction in FACTIONS:
			plans[faction] = policy.orders_for(simulation.project_faction_observation(faction))
		var snapshot := simulation.apply_round(plans)
		for event in snapshot.events:
			if str(event.type) == "order_rejected": rejection_count += 1
		_print_round(resolving_round, snapshot, plans)
	var final_snapshot := simulation.get_snapshot()
	print("TUNE_FINAL winner=%s ended=%s eliminations=%s rejects=%d hash=%s" % [
		str(final_snapshot.match.winner),
		str(final_snapshot.match.ended),
		JSON.stringify(final_snapshot.match.get("elimination_order", [])),
		rejection_count,
		simulation.get_state_hash(),
	])
	quit(0)


func _print_round(round_number: int, snapshot: Dictionary, plans: Dictionary) -> void:
	var center: Dictionary = snapshot.districts.crossroads
	var hp := {}
	var units := {}
	for faction in FACTIONS:
		hp[faction] = snappedf(float(snapshot.factions[faction].core_hp), 0.1)
		units[faction] = _unit_counts(snapshot, faction)
	var rejected: Array = snapshot.events.filter(func(event): return str(event.type) == "order_rejected")
	print("TUNE_ROUND round=%d owner=%s capture=%s hp=%s units=%s rejects=%s plans=%s" % [
		round_number,
		str(center.owner),
		JSON.stringify(center.capture),
		JSON.stringify(hp),
		JSON.stringify(units),
		JSON.stringify(rejected),
		JSON.stringify(plans),
	])


func _unit_counts(snapshot: Dictionary, faction: String) -> Dictionary:
	var counts := {}
	for unit in snapshot.units.values():
		if str(unit.faction) != faction: continue
		var kind := str(unit.kind)
		counts[kind] = int(counts.get(kind, 0)) + 1
	return counts
