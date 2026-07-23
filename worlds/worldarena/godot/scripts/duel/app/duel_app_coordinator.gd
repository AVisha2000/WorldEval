class_name DuelAppCoordinator
extends Control

## Process-local orchestration only. Presentation never receives authority
## objects, while DuelMatchController never receives UI labels or widgets.

signal setup_submitted(config: Dictionary)
signal match_launch_failed(code: String)
signal live_match_started(mode: String, faction_id: String)

@export var start_in_live_preview := false
@export var launch_service_url := "http://127.0.0.1:8000"

@onready var presentation: DuelPresentation = $Presentation
@onready var match_controller: DuelMatchController = $DuelMatchController
@onready var launch_client: DuelLaunchClient = $DuelLaunchClient

var _controller_configured := false
var _controller_started := false


func _ready() -> void:
	launch_client.base_http_url = launch_service_url
	presentation.setup_submitted.connect(func(config: Dictionary) -> void:
		setup_submitted.emit(config.duplicate(true))
	)
	presentation.launch_requested.connect(_on_launch_requested)
	launch_client.create_request_dispatched.connect(_on_create_request_dispatched)
	launch_client.claim_request_dispatched.connect(_on_claim_request_dispatched)
	launch_client.launch_ready.connect(_on_launch_ready)
	launch_client.launch_failed.connect(_on_launch_failed)
	match_controller.authority_ready.connect(_on_authority_ready)
	match_controller.match_failed.connect(_on_match_failed)
	match_controller.match_closed.connect(_on_match_closed)
	if start_in_live_preview:
		presentation.show_live()
		presentation.apply_projection("omniscient", presentation.mock_projection())
		presentation.apply_events(presentation.mock_events())


func _exit_tree() -> void:
	## DuelMatchController parents its gateway client only when start_match runs.
	## An app closed on the setup screen must still release that unparented Node.
	if match_controller != null and is_instance_valid(match_controller) \
		and is_instance_valid(match_controller.client) \
		and match_controller.client.get_parent() == null:
		match_controller.client.free()


func _on_launch_requested(request: Dictionary) -> void:
	for slot in 2:
		presentation.set_gateway_connection(slot, "checking", "local launch")
	presentation.set_launch_state("dispatching")
	var errors: PackedStringArray = launch_client.start_launch(request)
	## The coordinator never retains the credential-bearing request. If the
	## dispatch failed, the protected LineEdit remains populated for retry.
	request.clear()
	if not errors.is_empty():
		_on_launch_failed("duel_launch_request_invalid", errors[0])
	else:
		presentation.set_launch_state("creating")


func _on_create_request_dispatched() -> void:
	presentation.acknowledge_launch_dispatched()
	presentation.set_launch_state("creating")


func _on_claim_request_dispatched() -> void:
	presentation.set_launch_state("claiming")


func _on_launch_ready(fields: Dictionary) -> void:
	presentation.set_launch_state("connecting")
	var errors := match_controller.configure_launch(fields)
	if not errors.is_empty():
		_on_launch_failed("duel_controller_configuration_failed", errors[0])
		return
	_controller_configured = true
	errors = match_controller.start_match()
	if not errors.is_empty():
		_on_launch_failed("duel_controller_start_failed", errors[0])
		return
	_controller_started = true


func _on_authority_ready(mode: String, faction_id: String) -> void:
	for slot in 2:
		presentation.set_gateway_connection(slot, "ready", "authenticated")
	presentation.set_launch_state("ready")
	presentation.show_live()
	live_match_started.emit(mode, faction_id)


func _on_launch_failed(code: String, message: String) -> void:
	presentation.show_launch_error(message)
	match_launch_failed.emit(code)


func _on_match_failed(code: String, message: String) -> void:
	_on_launch_failed(code, message)


func _on_match_closed() -> void:
	if not _controller_started:
		return
	## A normal terminal closes after artifact acknowledgement; the terminal
	## surface remains visible. An early close is already reported by the
	## controller's match_failed signal.


func debug_state() -> Dictionary:
	var state := presentation.debug_state()
	state["launch"] = launch_client.debug_state()
	state["controller_configured"] = _controller_configured
	state["controller_started"] = _controller_started
	return state
