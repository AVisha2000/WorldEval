extends Node

var phases: Array[String] = []
var snapshots := 0
var event_batches := 0
var perspectives: Array[String] = []
var results: Array[Dictionary] = []
var showcase_status: Dictionary = {}


func configure_from_snapshot(_snapshot: Dictionary) -> void:
	snapshots += 1


func apply_events(_events: Array) -> void:
	event_batches += 1


func set_phase(phase: String, _statuses: Dictionary = {}) -> void:
	phases.append(phase)


func show_message(_event: Dictionary) -> void:
	pass


func set_perspective(perspective_id: String) -> void:
	perspectives.append(perspective_id)


func show_match_result(result: Dictionary) -> void:
	results.append(result.duplicate(true))


func set_showcase_status(verified: bool, label: String, detail: String) -> void:
	showcase_status = {"verified": verified, "label": label, "detail": detail}
