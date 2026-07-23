class_name EmbodimentEventLedger
extends RefCounted

const AUTHORITY_EVENT_KINDS := [
	"beacon_entered", "beacon_exited", "episode_succeeded", "episode_failed",
	"interaction_cancelled", "interaction_interrupted", "interaction_out_of_range",
	"interaction_misaligned", "gathering_progressed", "resource_gathered",
	"inventory_full", "resource_depleted", "material_deposited", "nothing_to_deposit",
	"construction_cancelled", "construction_interrupted", "construction_out_of_range",
	"construction_misaligned", "construction_insufficient_material",
	"construction_progressed", "barricade_completed",
	"dash_applied", "dash_rejected", "guard_failed", "operator_damaged",
	"operator_knocked_out", "primary_hit", "primary_missed", "primary_rejected",
	"neutral_attack_missed", "neutral_damaged", "neutral_recovered",
	"neutral_state_changed", "relay_activated", "relay_activation_cancelled",
	"relay_out_of_range", "controller_input_unavailable",
]


static func append(
	authority: Object,
	events: Array[Dictionary],
	kind: String,
	summary: String,
	data: Dictionary = {},
) -> void:
	assert(kind in AUTHORITY_EVENT_KINDS, "unregistered authority event kind")
	assert(not summary.is_empty() and summary.to_utf8_buffer().size() <= 240)
	events.append({
		"event_id": "evt_%d_%d" % [authority.tick, authority.event_seq],
		"tick": authority.tick,
		"kind": kind,
		"summary": summary,
		"participant_ids": [authority.PARTICIPANT_ID],
		"data": data.duplicate(true),
	})
	authority.event_seq += 1


static func descriptor(kind: String, summary: String, data: Dictionary = {}) -> Dictionary:
	assert(kind in AUTHORITY_EVENT_KINDS, "unregistered authority event kind")
	assert(not summary.is_empty() and summary.to_utf8_buffer().size() <= 240)
	return {"kind": kind, "summary": summary, "data": data.duplicate(true)}


static func is_registered(kind: String) -> bool:
	return kind in AUTHORITY_EVENT_KINDS
