class_name EmbodimentTerminalEvaluator
extends RefCounted

const EventLedger := preload("res://scripts/embodiment/authority/event_ledger.gd")


static func update_goal(authority: Object, events: Array[Dictionary]) -> void:
	if authority.task_id == "interaction-v0":
		if authority.deposited_material_units >= 1:
			_succeed(authority, events, "resource_deposited", "The marked material was deposited.")
		return
	if authority.task_id == "construction-v0":
		if authority.barricade_complete:
			_succeed(authority, events, "barricade_built", "The barricade was completed.")
		return
	if authority.task_id == "neutral-encounter-v0":
		if authority.operator_knocked_out:
			authority.terminal = {
				"ended": true, "outcome": "failure", "reason": "operator_knocked_out",
			}
			EventLedger.append(authority, events, "episode_failed", "The Operator was knocked out.")
		elif authority.relay_activated:
			_succeed(authority, events, "relay_activated", "The defended relay was activated.")
		return
	if authority.task_id != "orientation-v0":
		return
	var offset: Vector2i = authority.beacon_position_mt - authority.operator_position_mt
	var radius_squared: int = authority.BEACON_RADIUS_MT * authority.BEACON_RADIUS_MT
	var inside := offset.x * offset.x + offset.y * offset.y <= radius_squared
	if inside:
		if authority.beacon_hold_ticks == 0:
			EventLedger.append(authority, events, "beacon_entered", "The Operator entered the beacon radius.")
		authority.beacon_hold_ticks += 1
		if authority.beacon_hold_ticks >= authority.BEACON_HOLD_TICKS:
			authority.terminal = {"ended": true, "outcome": "success", "reason": "beacon_held"}
			EventLedger.append(authority, events, "episode_succeeded", "The beacon hold completed.")
	else:
		if authority.beacon_hold_ticks > 0:
			EventLedger.append(authority, events, "beacon_exited", "The Operator left before completing the hold.")
		authority.beacon_hold_ticks = 0


static func enforce_time_limit(authority: Object, events: Array[Dictionary]) -> void:
	if authority.tick >= authority.maximum_episode_ticks and not bool(authority.terminal.ended):
		authority.terminal = {"ended": true, "outcome": "failure", "reason": "time_limit"}
		EventLedger.append(authority, events, "episode_failed", "Time expired before the task completed.")


static func _succeed(
	authority: Object, events: Array[Dictionary], reason: String, summary: String
) -> void:
	if bool(authority.terminal.ended):
		return
	authority.terminal = {"ended": true, "outcome": "success", "reason": reason}
	EventLedger.append(authority, events, "episode_succeeded", summary)
