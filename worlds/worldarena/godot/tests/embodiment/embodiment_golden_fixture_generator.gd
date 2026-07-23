extends SceneTree

## Emits canonical golden transcripts from the real deterministic authority.  This maintainer tool
## writes nothing: `scripts/build_embodiment_golden_fixtures.py` reviews its named stdout records.

const Authority := preload("res://scripts/embodiment/authority/authority_orchestrator.gd")
const Codec := preload("res://scripts/embodiment/transport/embodiment_frame_codec.gd")

const GOLDEN_SCHEMA_VERSION := "llm-controller/golden-transcript/1.0.0"
const PROTOCOL_VERSION := "llm-controller/0.1.0"


func _init() -> void:
	var transcripts := {
		"stage-a-orientation-forward-v1": _build_orientation(),
		"stage-b-interaction-v1": _build_interaction(),
		"stage-c-construction-v1": _build_construction(),
		"stage-d-neutral-encounter-v1": _build_neutral_encounter(),
	}
	for transcript_id: String in transcripts:
		var payload := Codec.canonical_bytes(transcripts[transcript_id])
		if payload.is_empty():
			push_error("EMBODIMENT_GOLDEN_GENERATION_FAILED: %s" % transcript_id)
			quit(1)
			return
		print(
			"EMBODIMENT_GOLDEN_TRANSCRIPT_BASE64:%s=%s"
			% [transcript_id, Marshalls.raw_to_base64(payload)]
		)
	quit(0)


func _build_orientation() -> Dictionary:
	var run := _start("stage-a-orientation-forward-v1", "orientation-v0")
	while not bool(run.authority.terminal.ended):
		assert(run.steps.size() < 10, "Stage-A golden path failed to terminate")
		_record(run, "golden_forward_%02d" % run.steps.size(), 20, 0, 1000, 0)
	return _seal(run)


func _build_interaction() -> Dictionary:
	var run := _start("stage-b-interaction-v1", "interaction-v0")
	_move_to_resource(run)
	_record(run, "gather_b", 4, 0, 0, 0, {"interact": true})
	_turn_around_and_return(run)
	_record(run, "deposit_b", 1, 0, 0, 0, {"interact": true})
	assert(run.authority.terminal.reason == "resource_deposited")
	return _seal(run)


func _build_construction() -> Dictionary:
	var run := _start("stage-c-construction-v1", "construction-v0")
	_move_to_resource(run)
	_record(run, "turn_miss", 1, 0, 0, 1000)
	_record(run, "miss_resource", 1, 0, 0, 0, {"interact": true})
	_record(run, "correct_resource", 1, 0, 0, -1000)
	_record(run, "gather_c_0", 4, 0, 0, 0, {"interact": true})
	_record(run, "gather_c_1", 4, 0, 0, 0, {"interact": true})
	_turn_around_and_return(run)
	_record(run, "deposit_c", 1, 0, 0, 0, {"interact": true})
	_record(run, "face_pad", 3, 0, 0, -1000)
	_record(run, "approach_pad", 12, 0, 1000, 0)
	_record(run, "align_pad", 1, 0, 0, 1000)
	_record(run, "build_partial", 3, 0, 0, 0, {"interact": true})
	_record(run, "build_interrupt", 1, 0, 0, 0)
	_record(run, "build_complete", 3, 0, 0, 0, {"interact": true})
	assert(run.authority.terminal.reason == "barricade_built")
	return _seal(run)


func _build_neutral_encounter() -> Dictionary:
	var run := _start("stage-d-neutral-encounter-v1", "neutral-encounter-v0")
	_record(run, "approach_d_0", 20, 0, 1000, 0)
	_record(run, "approach_d_1", 10, 0, 1000, 0)
	_record(run, "primary_d_0", 1, 0, 0, 0, {"primary": true})
	_record(run, "guard_d", 5, 0, 0, 0, {"guard": true})
	_record(run, "primary_d_1", 1, 0, 0, 0, {"primary": true})
	_record(run, "pursue_d", 5, 0, 1000, 0, {"guard": true})
	_record(run, "primary_d_2", 1, 0, 0, 0, {"primary": true})
	_record(run, "approach_relay_d", 4, 0, 1000, 0)
	_record(run, "relay_d", 3, 0, 0, 0, {"interact": true})
	assert(run.authority.terminal.reason == "relay_activated")
	return _seal(run)


func _start(transcript_id: String, task_id: String) -> Dictionary:
	var config := {
		"protocol_version": PROTOCOL_VERSION,
		"episode_id": "ep_golden_%s" % transcript_id.replace("-", "_"),
		"mode": "solo-curriculum-v0",
		"task_id": task_id,
		"seed": 0,
		"observation_profile": "text-visible-v1",
		"timing_track": "step-locked-v1",
		"maximum_episode_ticks": 600,
		"participant_ids": ["participant_0"],
	}
	var authority := Authority.new()
	var errors: PackedStringArray = authority.configure(config)
	assert(errors.is_empty(), "%s golden configuration must remain runnable" % task_id)
	return {
		"transcript_id": transcript_id,
		"config": config,
		"authority": authority,
		"initial_boundary": {
			"observations": {"participant_0": authority.observe()},
			"state_hash": authority.checkpoint_hash(),
		},
		"steps": [],
	}


func _record(
	run: Dictionary,
	action_id: String,
	duration_ticks: int,
	move_x: int,
	move_y: int,
	look_x: int,
	button_overrides: Dictionary = {},
) -> void:
	var authority = run.authority
	var buttons := {
		"interact": false, "primary": false, "guard": false, "dash": false,
		"ability_1": false, "ability_2": false, "cycle_item": false, "cancel": false,
	}
	buttons.merge(button_overrides, true)
	var action := {
		"protocol_version": PROTOCOL_VERSION,
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"action_id": action_id,
		"control": {
			"move_x": move_x, "move_y": move_y, "look_x": look_x, "look_y": 0,
			"duration_ticks": duration_ticks, "buttons": buttons,
		},
		"intent_label": action_id,
		"memory_update": action_id,
	}
	var window := {
		"episode_id": authority.episode_id,
		"observation_seq": authority.observation_seq,
		"mode": authority.mode,
		"start_tick": authority.tick,
		"duration_ticks": duration_ticks,
		"decisions": {"participant_0": {
			"disposition": "accepted",
			"action": action,
			"fallback": "none",
			"no_input_reason": null,
		}},
	}
	var result: Dictionary = authority.step_window(window)
	var steps: Array = run.steps
	steps.append({
		"index": steps.size(),
		"decision_window": window,
		"result": result,
		"event_sequence_sha256": Codec.sha256_bytes(
			Codec.canonical_bytes(result.public_events)
		),
		"state_hash": result.state_hash,
	})


func _move_to_resource(run: Dictionary) -> void:
	_record(run, "approach_0", 20, 0, 1000, 0)
	_record(run, "approach_1", 20, 0, 1000, 0)
	_record(run, "approach_2", 3, 0, 1000, 0)


func _turn_around_and_return(run: Dictionary) -> void:
	_record(run, "turn_home", 4, 0, 0, 1000)
	_record(run, "return_0", 20, 0, 1000, 0)
	_record(run, "return_1", 20, 0, 1000, 0)
	_record(run, "return_2", 3, 0, 1000, 0)


func _seal(run: Dictionary) -> Dictionary:
	var authority = run.authority
	assert(bool(authority.terminal.ended), "%s golden path did not terminate" % run.transcript_id)
	var body := {
		"schema_version": GOLDEN_SCHEMA_VERSION,
		"protocol_version": PROTOCOL_VERSION,
		"transcript_id": run.transcript_id,
		"config": run.config,
		"config_sha256": Codec.sha256_bytes(Codec.canonical_bytes(run.config)),
		"initial_boundary": run.initial_boundary,
		"steps": run.steps,
		"terminal_boundary": {
			"terminal": authority.terminal.duplicate(true),
			"state_hash": authority.checkpoint_hash(),
		},
	}
	var transcript := body.duplicate(true)
	transcript["transcript_sha256"] = Codec.sha256_bytes(Codec.canonical_bytes(body))
	return transcript
