class_name DuelHttpJsonTransport
extends Node

## Small injectable seam around HTTPRequest. It deliberately transports bytes
## and status only; neither request nor response bodies are retained or logged.

signal completed(result: int, response_code: int, body: PackedByteArray)

var _request: HTTPRequest
var _in_flight := false
var _protected_body := PackedByteArray()


func _ready() -> void:
	_ensure_request()


func dispatch_post(url: String, headers: PackedStringArray, body: PackedByteArray) -> Error:
	_ensure_request()
	if _in_flight:
		return ERR_BUSY
	_in_flight = true
	## Keep exactly one protected transit copy alive until HTTPRequest signals
	## completion, then overwrite it. No debug/status method exposes this field.
	_protected_body = body.duplicate()
	var error := _request.request_raw(url, headers, HTTPClient.METHOD_POST, _protected_body)
	if error != OK:
		_in_flight = false
		_protected_body.fill(0)
		_protected_body.clear()
	return error


func is_in_flight() -> bool:
	return _in_flight


func _ensure_request() -> void:
	if _request != null:
		return
	_request = HTTPRequest.new()
	_request.name = "ProtectedJsonRequest"
	_request.timeout = 70.0
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)


func _on_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	_in_flight = false
	_protected_body.fill(0)
	_protected_body.clear()
	## A claim may be dispatched synchronously by the completion listener. Give
	## it a fresh HTTPRequest instead of relying on engine reuse during a signal.
	var finished_request := _request
	_request = null
	if finished_request != null:
		finished_request.request_completed.disconnect(_on_request_completed)
		finished_request.queue_free()
	completed.emit(result, response_code, body)
