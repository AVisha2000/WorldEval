class_name DuelHeadlessMatchRunner
extends RefCounted

const Session := preload("res://scripts/duel/match/duel_match_session.gd")
const CatalogLoader := preload("res://scripts/duel/protocol/duel_catalog_loader.gd")
const Codec := preload("res://scripts/duel/protocol/duel_protocol_codec.gd")
const ActionContract := preload("res://scripts/duel/actions/duel_action_contract.gd")
const ObservationContract := preload(
	"res://scripts/duel/observations/duel_observation_contract.gd"
)
const PublicEventProjector := preload(
	"res://scripts/duel/match/duel_public_event_projector.gd"
)

## Render-free, provider-free execution from the official genesis state.
##
## This runner deliberately uses DuelMatchSession rather than DuelReplay. The
## latter currently restores only its tick-0, economy-disabled scope. Every
## action in this runner therefore passes through the same fixed commit/reveal,
## validation, compilation, protected contest, and simulation path as a live
## official match. No checkpoint-restoration claim is made here.

const SPEC_VERSION := "worldeval-rts/headless-run/1.0.0"
const REPLAY_VERSION := "worldeval-rts/replay-manifest/1.0.0"
const ENGINE_BUILD := "4.5.stable.official.876b29033"
const ENGINE_BUILD_ID := "godot-4.5.stable.official.876b29033"
const ENGINE_BUILD_SHA256 := (
	"39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719"
)
const CHECKPOINT_PERIOD_TICKS := 300
const FIXED_PERIOD_TICKS := 100
const FIXED_DEADLINE_MS := 45_000

const ACTION_SCHEMA_PATH := (
	"res://../game/duel_protocol/schemas/action-batch.v1.schema.json"
)
const MAP_PATH := "res://../game/duel_protocol/maps/crossroads-duel-v1.json"
const PROMPT_PATH := "res://../game/duel_protocol/prompts/commander-system.v1.txt"
const VERSION_PATH := "res://../game/duel_protocol/VERSION"

const ROOT_FIELDS: Array[String] = [
	"authority", "completion", "locks", "match_config", "match_init", "schema_version",
]
const LOCK_FIELDS: Array[String] = [
	"match_config_sha256", "match_init_sha256", "transcript_sha256",
]
const AUTHORITY_FIELDS: Array[String] = [
	"alias_salt_seat_0_hex", "alias_salt_seat_1_hex", "default_commit_salt_seat_0_hex",
	"default_commit_salt_seat_1_hex", "tie_key_hex",
]
const COMPLETION_FIELDS: Array[String] = [
	"fill_missing_with_noop", "post_first_application_disposition",
]
const CONFIG_FIELDS: Array[String] = [
	"cadence_profile_id", "control_profile", "decision_mode", "decision_period_ticks",
	"faction_preset_id", "map_id", "maximum_match_ticks", "memory_policy",
	"mirror_faction", "observation_profile", "players", "protocol_version",
	"response_deadline_ms", "ruleset_id", "seed", "simulation_hz", "spectator",
]
const MATCH_INIT_FIELDS: Array[String] = [
	"action_schema", "artifacts", "coordinate_frame", "decision", "draw_rules",
	"faction", "failure_rules", "limits", "map", "map_manifest", "match_id",
	"memory_rules", "message_type", "observation_rules", "perspective", "protocol_version",
	"public_catalogs", "ruleset", "scoring_rules", "starting_state", "victory_rules",
]
const TRANSCRIPT_FIELDS: Array[String] = [
	"activation_tick", "batches", "boundary_tick", "disposition", "observation_seq",
	"opportunity_id",
]
const TERMINAL_DISPOSITIONS: Array[String] = [
	"draw_double_technical_forfeit", "technical_forfeit_slot_0",
	"technical_forfeit_slot_1", "void_infrastructure",
]

var _event_projector := PublicEventProjector.new()
var _accepted_actions: Array[Dictionary] = []
var _compiled_orders: Array[Dictionary] = []
var _public_events: Array[Dictionary] = []
var _action_receipts: Array[Dictionary] = []
var _checkpoints: Array[Dictionary] = []
var _application_cursor: int = 0
var _event_cursor: int = 0


func execute(spec_input: Dictionary, transcript_input: Array) -> Dictionary:
	_reset_evidence()
	var errors := PackedStringArray()
	var context := _validate_inputs(spec_input, transcript_input, errors)
	if not errors.is_empty():
		return _failure(errors)

	var authority: Dictionary = spec_input["authority"]
	var match_config: Dictionary = spec_input["match_config"]
	var match_init: Dictionary = spec_input["match_init"]
	var secrets := _authority_bytes(authority, errors)
	if not errors.is_empty():
		return _failure(errors)
	var authoritative_hashes: Dictionary = context["authoritative_hashes"]
	var session := Session.new()
	var configure_errors := session.configure_official({
		"authoritative_hashes": authoritative_hashes,
		"decision_mode": str(match_config["decision_mode"]),
		"faction_id": str(match_config["faction_preset_id"]),
		"match_id": str(match_init["match_id"]),
		"match_seed": int(match_config["seed"]),
		"scored": true,
	}, {
		"alias_salt_seat_0": secrets["alias_salt_seat_0"],
		"alias_salt_seat_1": secrets["alias_salt_seat_1"],
		"tie_key": secrets["tie_key"],
	})
	for message: String in configure_errors:
		errors.append("official match bootstrap: " + message)
	if not errors.is_empty():
		return _failure(errors)
	if not _canonical_equal(session.map_manifest, match_init["map_manifest"]):
		errors.append("MATCH_INIT map_manifest differs from the configured authority map")
		return _failure(errors)

	var transcript_by_seq: Dictionary = context["transcript_by_seq"]
	var completion: Dictionary = spec_input["completion"]
	var post_disposition: Variant = completion["post_first_application_disposition"]
	var applications_seen := 0
	var consumed_explicit: Dictionary = {}
	while not bool(session.simulation.state.terminal["ended"]):
		var emitted := session.emit_observation_pair()
		_append_result_errors(errors, emitted, "observation")
		if not bool(emitted.get("ok", false)):
			break
		var observation_seq := int(emitted["observation_seq"])
		var entry: Dictionary = {}
		if transcript_by_seq.has(observation_seq):
			entry = transcript_by_seq[observation_seq]
			consumed_explicit[observation_seq] = true
		elif bool(completion["fill_missing_with_noop"]):
			entry = _implicit_noop_entry(emitted, match_init, authority)
		else:
			errors.append(
				"canonical transcript has no fixed decision entry for observation_seq %d"
				% observation_seq
			)
			break
		var applied := _apply_fixed_entry(session, emitted, entry)
		_append_result_errors(errors, applied, "fixed application")
		if not bool(applied.get("ok", false)):
			break
		if str(entry["disposition"]) == "continue":
			var activation_tick := int(entry["activation_tick"])
			var activation_advance := session.advance_ticks(
				activation_tick - int(session.simulation.state.tick)
			)
			_append_result_errors(errors, activation_advance, "activation advance")
			if not bool(activation_advance.get("ok", false)):
				break
			_capture_applications(session, errors)
			_capture_events(session, errors)
			applications_seen += 1
			if post_disposition != null and applications_seen == 1 \
				and not bool(session.simulation.state.terminal["ended"]):
				var forced := session.declare_gateway_disposition(str(post_disposition))
				_append_result_errors(errors, forced, "declared offline terminal disposition")
				_capture_events(session, errors)
			_record_checkpoint(
				int(session.simulation.state.tick), session.checkpoint_hash()
			)
		else:
			_capture_events(session, errors)
			_record_checkpoint(
				int(session.simulation.state.tick), session.checkpoint_hash()
			)
		if not errors.is_empty() or bool(session.simulation.state.terminal["ended"]):
			break
		var target_boundary := int(emitted["boundary_tick"]) + FIXED_PERIOD_TICKS
		_advance_to_boundary(session, target_boundary, errors)
		if not errors.is_empty():
			break

	_capture_applications(session, errors)
	_capture_events(session, errors)
	if errors.is_empty() and not bool(session.simulation.state.terminal["ended"]):
		errors.append("headless execution stopped without an authoritative terminal result")
	for seq_variant: Variant in transcript_by_seq.keys():
		if not consumed_explicit.has(int(seq_variant)):
			errors.append(
				"canonical transcript entry observation_seq %d was not consumed"
				% int(seq_variant)
			)
	if not errors.is_empty():
		return _failure(errors)
	var final_tick := int(session.simulation.state.tick)
	var final_hash := session.checkpoint_hash()
	_record_checkpoint(final_tick, final_hash)
	var artifacts := _build_artifacts(
		spec_input, session.simulation.terminal_result(), final_tick, final_hash, errors
	)
	if not errors.is_empty():
		return _failure(errors)
	return {
		"artifacts": artifacts,
		"errors": errors,
		"ok": true,
		"summary": {
			"accepted_action_count": _accepted_actions.size(),
			"checkpoint_count": _checkpoints.size(),
			"compiled_order_count": _compiled_orders.size(),
			"event_count": _public_events.size(),
			"final_state_sha256": final_hash,
			"match_id": str(match_init["match_id"]),
			"receipt_count": _action_receipts.size(),
			"terminal_tick": final_tick,
		},
	}


func _validate_inputs(
	spec: Dictionary, transcript: Array, errors: PackedStringArray
) -> Dictionary:
	_validate_exact_fields(spec, ROOT_FIELDS, [], "headless run", errors)
	if str(spec.get("schema_version", "")) != SPEC_VERSION:
		errors.append("headless run schema_version is unsupported")
	for field: String in ["authority", "completion", "locks", "match_config", "match_init"]:
		if typeof(spec.get(field)) != TYPE_DICTIONARY:
			errors.append("headless run %s must be an object" % field)
	if not errors.is_empty():
		return {}
	var locks: Dictionary = spec["locks"]
	_validate_exact_fields(locks, LOCK_FIELDS, [], "locks", errors)
	for field: String in LOCK_FIELDS:
		if not _is_sha256(locks.get(field)):
			errors.append("locks.%s must be lowercase SHA-256" % field)
	if not errors.is_empty():
		return {}
	if Codec.sha256_canonical(spec["match_config"]) != str(locks["match_config_sha256"]):
		errors.append("MATCH_CONFIG canonical hash does not match locks.match_config_sha256")
	if Codec.sha256_canonical(spec["match_init"]) != str(locks["match_init_sha256"]):
		errors.append("MATCH_INIT canonical hash does not match locks.match_init_sha256")
	if Codec.sha256_canonical(transcript) != str(locks["transcript_sha256"]):
		errors.append("action transcript canonical hash does not match locks.transcript_sha256")
	_validate_authority(spec["authority"], errors)
	_validate_completion(spec["completion"], errors)
	_validate_match_config(spec["match_config"], errors)
	if not errors.is_empty():
		return {}
	var loaded := CatalogLoader.load_official_catalogs()
	_append_result_errors(errors, loaded, "locked catalogs")
	if not bool(loaded.get("ok", false)):
		return {}
	var hashes := _validate_match_init(
		spec["match_init"], spec["match_config"], spec["authority"], loaded, errors
	)
	var transcript_by_seq := _validate_transcript(transcript, errors)
	var post: Variant = spec["completion"]["post_first_application_disposition"]
	if post != null:
		for seq_variant: Variant in transcript_by_seq.keys():
			if int(seq_variant) > 0:
				errors.append(
					"post-first-application disposition forbids transcript entries after sequence 0"
				)
	return {
		"authoritative_hashes": hashes,
		"transcript_by_seq": transcript_by_seq,
	}


func _validate_authority(value: Dictionary, errors: PackedStringArray) -> void:
	_validate_exact_fields(value, AUTHORITY_FIELDS, [], "authority", errors)
	for field: String in AUTHORITY_FIELDS:
		if not _is_32_byte_hex(value.get(field)):
			errors.append("authority.%s must be exactly 32 lowercase hexadecimal bytes" % field)
	if str(value.get("alias_salt_seat_0_hex", "")) \
		== str(value.get("alias_salt_seat_1_hex", "")):
		errors.append("observer alias salts must be distinct")
	if str(value.get("default_commit_salt_seat_0_hex", "")) \
		== str(value.get("default_commit_salt_seat_1_hex", "")):
		errors.append("default fixed commit salts must be distinct")


func _validate_completion(value: Dictionary, errors: PackedStringArray) -> void:
	_validate_exact_fields(value, COMPLETION_FIELDS, [], "completion", errors)
	if typeof(value.get("fill_missing_with_noop")) != TYPE_BOOL:
		errors.append("completion.fill_missing_with_noop must be boolean")
	var disposition: Variant = value.get("post_first_application_disposition")
	if disposition != null and (
		typeof(disposition) != TYPE_STRING or str(disposition) not in TERMINAL_DISPOSITIONS
	):
		errors.append("completion.post_first_application_disposition is invalid")


func _validate_match_config(config: Dictionary, errors: PackedStringArray) -> void:
	_validate_exact_fields(config, CONFIG_FIELDS, [], "MATCH_CONFIG", errors)
	var constants := {
		"control_profile": "hybrid-v1",
		"decision_mode": "fixed_simultaneous",
		"decision_period_ticks": FIXED_PERIOD_TICKS,
		"map_id": "crossroads-duel-v1",
		"maximum_match_ticks": 18_000,
		"mirror_faction": true,
		"observation_profile": "full-belief-v1",
		"protocol_version": CatalogLoader.PROTOCOL_VERSION,
		"response_deadline_ms": FIXED_DEADLINE_MS,
		"ruleset_id": CatalogLoader.RULESET_ID,
		"simulation_hz": 10,
	}
	for field: String in constants.keys():
		if config.get(field) != constants[field]:
			errors.append("MATCH_CONFIG %s is incompatible with this fixed headless runner" % field)
	if str(config.get("faction_preset_id", "")) not in CatalogLoader.FACTION_IDS:
		errors.append("MATCH_CONFIG faction_preset_id is not official")
	if typeof(config.get("seed")) != TYPE_INT or int(config.get("seed", -1)) < 0 \
		or int(config.get("seed", -1)) > Codec.MAX_SAFE_INTEGER:
		errors.append("MATCH_CONFIG seed is outside the interoperable non-negative range")
	if str(config.get("memory_policy", "")) not in [
		"fresh-match-with-bounded-scratchpad", "adaptive-series",
	]:
		errors.append("MATCH_CONFIG memory_policy is invalid")
	var cadence: Variant = config.get("cadence_profile_id")
	if cadence != null and not _is_identifier(cadence):
		errors.append("MATCH_CONFIG cadence_profile_id must be null or a canonical identifier")
	var spectator: Variant = config.get("spectator")
	if spectator != null:
		if typeof(spectator) != TYPE_DICTIONARY:
			errors.append("MATCH_CONFIG spectator must be null or an object")
		else:
			_validate_exact_fields(
				spectator,
				["enabled", "initial_perspective", "record_replay"],
				[], "MATCH_CONFIG spectator", errors
			)
			if typeof(spectator.get("enabled")) != TYPE_BOOL \
				or typeof(spectator.get("record_replay")) != TYPE_BOOL:
				errors.append("MATCH_CONFIG spectator flags must be boolean")
			if str(spectator.get("initial_perspective", "")) not in [
				"omniscient", "slot_0", "slot_1",
			]:
				errors.append("MATCH_CONFIG spectator perspective is invalid")
	var players: Variant = config.get("players")
	if typeof(players) != TYPE_ARRAY or (players as Array).size() != 2:
		errors.append("MATCH_CONFIG players must contain exactly slots 0 and 1")
		return
	for seat: int in [0, 1]:
		var row_variant: Variant = players[seat]
		if typeof(row_variant) != TYPE_DICTIONARY:
			errors.append("MATCH_CONFIG player %d must be an object" % seat)
			continue
		var row: Dictionary = row_variant
		_validate_exact_fields(
			row, ["model", "provider_adapter", "reasoning", "slot"], [],
			"MATCH_CONFIG player %d" % seat, errors
		)
		if typeof(row.get("slot")) != TYPE_INT or int(row.get("slot", -1)) != seat:
			errors.append("MATCH_CONFIG players must be in canonical slot order")
		var model := str(row.get("model", ""))
		if typeof(row.get("model")) != TYPE_STRING or model.is_empty() or model.length() > 200:
			errors.append("MATCH_CONFIG player %d model length is invalid" % seat)
		var reasoning := str(row.get("reasoning", ""))
		if typeof(row.get("reasoning")) != TYPE_STRING \
			or reasoning.is_empty() or reasoning.length() > 80:
			errors.append("MATCH_CONFIG player %d reasoning length is invalid" % seat)
		var adapter: Variant = row.get("provider_adapter")
		if adapter != null and not _is_identifier(adapter):
			errors.append("MATCH_CONFIG player %d provider_adapter is invalid" % seat)


func _validate_match_init(
	match_init: Dictionary,
	config: Dictionary,
	authority: Dictionary,
	loaded: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	_validate_exact_fields(match_init, MATCH_INIT_FIELDS, [], "MATCH_INIT", errors)
	if not ObservationContract.is_match_id(match_init.get("match_id")):
		errors.append("MATCH_INIT match_id is invalid")
	var expected_scalars := {
		"message_type": "match_init",
		"perspective": "self",
		"protocol_version": CatalogLoader.PROTOCOL_VERSION,
	}
	for field: String in expected_scalars.keys():
		if match_init.get(field) != expected_scalars[field]:
			errors.append("MATCH_INIT %s is invalid" % field)
	for field: String in [
		"action_schema", "artifacts", "coordinate_frame", "decision", "draw_rules",
		"faction", "failure_rules", "limits", "map", "map_manifest", "memory_rules",
		"observation_rules", "public_catalogs", "ruleset", "scoring_rules",
		"starting_state", "victory_rules",
	]:
		if typeof(match_init.get(field)) != TYPE_DICTIONARY:
			errors.append("MATCH_INIT %s must be an object" % field)
	if not errors.is_empty():
		return {}

	var catalogs: Dictionary = loaded["catalogs"]
	var raw_hashes: Dictionary = loaded["raw_hashes"]
	var faction_id := str(config["faction_preset_id"])
	var faction_key := "faction:%s" % faction_id
	var map_result := _read_authoritative_json(MAP_PATH, "official map")
	var schema_result := _read_authoritative_json(ACTION_SCHEMA_PATH, "action schema")
	var prompt_result := _read_authoritative_bytes(PROMPT_PATH, "commander prompt")
	var version_result := _read_authoritative_bytes(VERSION_PATH, "protocol version")
	for result: Dictionary in [map_result, schema_result, prompt_result, version_result]:
		_append_result_errors(errors, result, "locked MATCH_INIT artifact")
	if not errors.is_empty():
		return {}

	var public_catalogs: Dictionary = match_init["public_catalogs"]
	_validate_exact_fields(
		public_catalogs,
		[
			"abilities", "actions", "attack_armor", "buildings", "heroes", "items",
			"neutrals", "rules", "units", "upgrades",
		], [], "MATCH_INIT public_catalogs", errors
	)
	var expected_catalogs := {
		"abilities": catalogs[faction_key]["abilities"],
		"actions": catalogs["actions"],
		"attack_armor": catalogs["attack_armor"],
		"buildings": catalogs[faction_key]["structures"],
		"heroes": catalogs[faction_key]["heroes"],
		"items": catalogs["items"],
		"neutrals": catalogs["neutrals"],
		"rules": catalogs["rules"],
		"units": catalogs[faction_key]["units"],
		"upgrades": catalogs[faction_key]["upgrades"],
	}
	for field: String in expected_catalogs.keys():
		if not _canonical_equal(public_catalogs.get(field), expected_catalogs[field]):
			errors.append("MATCH_INIT public_catalogs.%s differs from locked bytes" % field)
	if not _canonical_equal(match_init["action_schema"], schema_result["value"]):
		errors.append("MATCH_INIT action_schema differs from the locked action schema")
	if not _canonical_equal(match_init["map_manifest"], map_result["value"]):
		errors.append("MATCH_INIT map_manifest differs from the locked official map")

	var artifacts: Dictionary = match_init["artifacts"]
	_validate_exact_fields(
		artifacts,
		["attack_armor", "engine_build", "helper", "items", "neutrals", "prompt", "protocol"],
		[], "MATCH_INIT artifacts", errors
	)
	var artifact_expected := {
		"attack_armor": [str(catalogs["attack_armor"]["catalog_id"]),
			raw_hashes["catalogs/attack-armor.duel-v1.json"]],
		"helper": ["hybrid-helper-v1", raw_hashes["catalogs/actions.hybrid-v1.json"]],
		"items": [str(catalogs["items"]["catalog_id"]),
			raw_hashes["catalogs/items.duel-v1.json"]],
		"neutrals": [str(catalogs["neutrals"]["catalog_id"]),
			raw_hashes["catalogs/neutrals.duel-v1.json"]],
		"prompt": ["commander-system-v1", prompt_result["sha256"]],
		"protocol": ["worldeval-rts-1.0.0", version_result["sha256"]],
	}
	for field: String in artifact_expected.keys():
		_validate_hash_ref(
			artifacts.get(field), str(artifact_expected[field][0]),
			str(artifact_expected[field][1]), "MATCH_INIT artifacts.%s" % field, errors
		)
	_validate_hash_ref(
		artifacts.get("engine_build"), ENGINE_BUILD_ID, ENGINE_BUILD_SHA256,
		"MATCH_INIT artifacts.engine_build", errors
	)
	_validate_hash_ref(
		match_init["ruleset"], "duel-rules-v1",
		raw_hashes["catalogs/rules.duel-v1.json"], "MATCH_INIT ruleset", errors
	)
	var faction_ref: Variant = match_init["faction"]
	if typeof(faction_ref) == TYPE_DICTIONARY:
		_validate_exact_fields(
			faction_ref, ["id", "mirror_faction", "sha256"], [], "MATCH_INIT faction", errors
		)
		if faction_ref.get("mirror_faction") != true:
			errors.append("MATCH_INIT faction must be mirrored")
	_validate_hash_ref(
		faction_ref, faction_id,
		raw_hashes["catalogs/factions/%s.json" % faction_id], "MATCH_INIT faction", errors,
		["mirror_faction"]
	)
	_validate_hash_ref(
		match_init["map"], "crossroads-duel-v1", map_result["sha256"],
		"MATCH_INIT map", errors
	)

	var expected_decision := {
		"control_profile": config["control_profile"],
		"decision_period_ticks": config["decision_period_ticks"],
		"max_in_flight_calls_per_player": 1,
		"mode": config["decision_mode"],
		"observation_profile": config["observation_profile"],
		"response_deadline_ms": config["response_deadline_ms"],
		"simulation_hz": config["simulation_hz"],
		"validity_window_ticks": 1,
	}
	_validate_match_init_invariants(match_init, config, catalogs, expected_decision, errors)
	var starting := _expected_starting_state(
		catalogs["rules"], catalogs[faction_key], map_result["value"], errors
	)
	if not _canonical_equal(match_init["starting_state"], starting):
		errors.append("MATCH_INIT starting_state differs from the locked faction/map genesis")

	var tie_key_hex := str(authority["tie_key_hex"])
	var hashes := {
		"engine_build_hash": str(artifacts["engine_build"]["sha256"]),
		"faction_hash": str(match_init["faction"]["sha256"]),
		"helper_hash": str(artifacts["helper"]["sha256"]),
		"item_hash": str(artifacts["items"]["sha256"]),
		"map_hash": str(match_init["map"]["sha256"]),
		"neutral_hash": str(artifacts["neutrals"]["sha256"]),
		"prompt_hash": str(artifacts["prompt"]["sha256"]),
		"protocol_hash": str(artifacts["protocol"]["sha256"]),
		"ruleset_hash": str(match_init["ruleset"]["sha256"]),
		"tie_key_commitment": Codec.sha256_bytes(tie_key_hex.hex_decode()),
	}
	return hashes


func _validate_match_init_invariants(
	match_init: Dictionary,
	config: Dictionary,
	catalogs: Dictionary,
	expected_decision: Dictionary,
	errors: PackedStringArray
) -> void:
	var rules: Dictionary = catalogs["rules"]
	var actions: Dictionary = catalogs["actions"]
	var expected := {
		"coordinate_frame": {
			"distance_unit": "milli_tile", "facing_unit": "millidegree",
			"kind": "self_canonical", "percentage_unit": "basis_point",
			"position_unit": "milli_tile",
		},
		"decision": expected_decision,
		"draw_rules": {
			"maximum_match_ticks": config["maximum_match_ticks"],
			"no_progress_ticks": rules["termination"]["no_progress_draw_ticks"],
			"time_limit_tiebreak": rules["termination"]["time_limit_result"],
		},
		"failure_rules": {
			"individual_illegal_command_result": "skip_command",
			"infrastructure_failure_result": "void_match",
			"invalid_envelope_result": "no_op_and_strike",
			"no_same_window_retry": true,
			"participant_cumulative_failures_forfeit": rules["model_failure"][
				"cumulative_hard_failures_forfeit"
			],
			"participant_failed_opportunities_forfeit": rules["model_failure"][
				"consecutive_hard_failures_forfeit"
			],
		},
		"limits": {
			"max_actor_ids_per_command": actions["limits"]["max_actor_ids_per_command"],
			"max_atomic_order_cost": actions["limits"]["max_atomic_order_cost"],
			"max_command_objects": actions["limits"]["max_command_objects"],
			"max_input_bytes": rules["observation"]["maximum_canonical_input_bytes"],
			"max_output_bytes": actions["limits"]["max_output_bytes"],
			"max_queue_entries_per_entity": actions["limits"]["max_queue_entries_per_entity"],
			"max_working_memory_bytes": actions["limits"]["max_working_memory_bytes"],
		},
		"memory_rules": {
			"maximum_bytes": actions["limits"]["max_working_memory_bytes"],
			"persistent_field": "working_memory", "policy": config["memory_policy"],
			"provider_memory": "disabled",
		},
		"observation_rules": {
			"knowledge_boundary": "agent_knowledge_state",
			"observation_hash_scope": "legal_observation_without_hash_field",
			"optional_brief": "fixed_templates_only", "profile": "full-belief-v1",
			"remembered_state_is_frozen": true,
		},
		"scoring_rules": {
			"paired_seed_unit": true, "primary": "paired_seed_match_points",
			"tracks_are_separate": true,
		},
		"victory_rules": {
			"primary": rules["termination"]["victory_condition"],
			"simultaneous_stronghold_destruction": rules["termination"][
				"same_tick_double_stronghold_destruction"
			],
		},
	}
	for field: String in expected.keys():
		if not _canonical_equal(match_init[field], expected[field]):
			errors.append("MATCH_INIT %s differs from the frozen official contract" % field)


func _expected_starting_state(
	rules: Dictionary,
	faction: Dictionary,
	map_manifest: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	var self_spawns: Array = []
	for spawn_variant: Variant in map_manifest.get("spawns", []):
		if typeof(spawn_variant) == TYPE_DICTIONARY and int(spawn_variant.get("seat", -1)) == 0:
			self_spawns.append(spawn_variant)
	var workers: Array = []
	for spawn_variant: Variant in self_spawns:
		var spawn: Dictionary = spawn_variant
		if str(spawn.get("kind", "")) == "unit" \
			and str(spawn.get("entity_type", "")) == "faction_worker":
			workers.append(spawn)
	workers.sort_custom(_record_id_less)
	var start: Dictionary = faction["starting_state"]
	var types: Array[String] = []
	for _index: int in int(start["worker_count"]):
		types.append(str(start["worker_type_id"]))
	for special_variant: Variant in start.get("special_units", []):
		var special: Dictionary = special_variant
		for _index: int in int(special["count"]):
			types.append(str(special["type_id"]))
	if types.size() != workers.size():
		errors.append("locked starting worker/special-unit count differs from map spawn count")
		return {}
	var entities: Array = []
	for index: int in workers.size():
		var spawn: Dictionary = workers[index]
		var type_id := types[index]
		entities.append({
			"entity_id": _starting_entity_id(str(spawn["id"]), errors),
			"facing_mdeg": 0,
			"food": int(faction["units"][type_id]["food"]),
			"position_mt": (spawn["position_mt"] as Array).duplicate(),
			"type_id": type_id,
		})
	entities.sort_custom(_record_entity_id_less)
	var structure_by_role: Dictionary = {}
	for definition_variant: Variant in faction["structures"].values():
		var definition: Dictionary = definition_variant
		structure_by_role[str(definition["shared_role"])] = definition
	var spawn_roles := {"food_structure": "food", "stronghold": "stronghold"}
	var structures: Array = []
	var home_region := ""
	for spawn_variant: Variant in self_spawns:
		var spawn: Dictionary = spawn_variant
		var entity_type := str(spawn.get("entity_type", ""))
		if str(spawn.get("kind", "")) != "structure" or not spawn_roles.has(entity_type):
			continue
		var role := str(spawn_roles[entity_type])
		if not structure_by_role.has(role):
			errors.append("selected faction lacks starting structure role %s" % role)
			continue
		var definition: Dictionary = structure_by_role[role]
		structures.append({
			"entity_id": _starting_entity_id(str(spawn["id"]), errors),
			"facing_mdeg": 0,
			"food": 0,
			"position_mt": (spawn["position_mt"] as Array).duplicate(),
			"type_id": str(definition["type_id"]),
		})
		if entity_type == "stronghold":
			home_region = str(spawn["region_id"])
	structures.sort_custom(_record_entity_id_less)
	var home_mines: Array[String] = []
	for site_variant: Variant in map_manifest.get("resource_sites", []):
		var site: Dictionary = site_variant
		if str(site.get("region_id", "")) == home_region \
			and str(site.get("kind", "")) == "gold_mine" \
			and "starting_resource" in site.get("tags", []):
			home_mines.append(str(site["id"]))
	home_mines.sort()
	if home_mines.size() != 1:
		errors.append("locked map must contain exactly one self starting gold mine")
		return {}
	var match_start: Dictionary = rules["match_start"]
	var food_used := 0
	for entity_variant: Variant in entities:
		food_used += int(entity_variant["food"])
	return {
		"entities": entities,
		"food_cap": int(match_start["food_cap"]),
		"food_used": food_used,
		"gold": int(match_start["gold"]),
		"home_mine_site_id": home_mines[0],
		"lumber": int(match_start["lumber"]),
		"structures": structures,
		"tier": int(match_start["technology_tier"]),
	}


func _validate_transcript(transcript: Array, errors: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	var previous_seq := -1
	var terminal_seen := false
	for index: int in transcript.size():
		var entry_variant: Variant = transcript[index]
		if typeof(entry_variant) != TYPE_DICTIONARY:
			errors.append("action transcript entry %d must be an object" % index)
			continue
		var entry: Dictionary = entry_variant
		_validate_exact_fields(
			entry, TRANSCRIPT_FIELDS, [], "action transcript entry %d" % index, errors
		)
		for field: String in ["activation_tick", "boundary_tick", "observation_seq"]:
			if typeof(entry.get(field)) != TYPE_INT or int(entry.get(field, -1)) < 0:
				errors.append("action transcript entry %d %s must be non-negative integer" % [index, field])
		var seq := int(entry.get("observation_seq", -1))
		if seq <= previous_seq:
			errors.append("action transcript observation_seq values must be strictly ascending")
		if seq >= 0 and int(entry.get("boundary_tick", -1)) != seq * FIXED_PERIOD_TICKS:
			errors.append("action transcript boundary_tick does not match fixed cadence")
		if int(entry.get("activation_tick", -1)) != int(entry.get("boundary_tick", -2)) + 1:
			errors.append("action transcript activation_tick must equal boundary_tick + 1")
		if str(entry.get("opportunity_id", "")) != "opp_%08d" % seq:
			errors.append("action transcript opportunity_id does not match observation_seq")
		var disposition := str(entry.get("disposition", ""))
		if disposition != "continue" and disposition not in TERMINAL_DISPOSITIONS:
			errors.append("action transcript disposition is invalid")
		if terminal_seen:
			errors.append("action transcript contains entries after a terminal disposition")
		if disposition != "continue":
			terminal_seen = true
		var batches: Variant = entry.get("batches")
		if typeof(batches) != TYPE_ARRAY or (batches as Array).size() != 2:
			errors.append("action transcript entry must contain exactly two reveal batches")
		else:
			var seats: Array[int] = []
			for row_variant: Variant in batches:
				if typeof(row_variant) != TYPE_DICTIONARY:
					errors.append("action transcript reveal row must be an object")
					continue
				var row: Dictionary = row_variant
				_validate_exact_fields(
					row, ["batch", "player_slot", "salt_hex"], [],
					"action transcript reveal", errors
				)
				if typeof(row.get("player_slot")) != TYPE_INT \
					or int(row.get("player_slot", -1)) not in [0, 1]:
					errors.append("action transcript reveal player_slot is invalid")
				else:
					seats.append(int(row["player_slot"]))
				if not _is_32_byte_hex(row.get("salt_hex")):
					errors.append("action transcript reveal salt_hex is invalid")
				if typeof(row.get("batch")) != TYPE_DICTIONARY:
					errors.append("action transcript reveal batch must be an object")
			seats.sort()
			if seats != [0, 1]:
				errors.append("action transcript reveals must cover seats 0 and 1")
		if seq >= 0:
			result[seq] = entry.duplicate(true)
		previous_seq = seq
	return result


func _implicit_noop_entry(
	emitted: Dictionary, match_init: Dictionary, authority: Dictionary
) -> Dictionary:
	var reveals: Array = []
	for seat: int in [0, 1]:
		var observation: Dictionary = emitted["observations"][str(seat)]
		var batch := {
			"based_on_observation_hash": str(observation["observation_hash"]),
			"client_batch_id": "headless.noop.s%d.%08d" % [seat, int(emitted["observation_seq"])],
			"commands": [],
			"match_id": str(match_init["match_id"]),
			"message_type": "action_batch",
			"observation_seq": int(emitted["observation_seq"]),
			"protocol_version": ActionContract.PROTOCOL_VERSION,
			"valid_until_tick": int(observation["decision"]["valid_until_tick"]),
		}
		reveals.append({
			"batch": batch,
			"player_slot": seat,
			"salt_hex": str(authority["default_commit_salt_seat_%d_hex" % seat]),
		})
	return {
		"activation_tick": int(emitted["boundary_tick"]) + 1,
		"batches": reveals,
		"boundary_tick": int(emitted["boundary_tick"]),
		"disposition": "continue",
		"observation_seq": int(emitted["observation_seq"]),
		"opportunity_id": str(emitted["opportunity_id"]),
	}


func _apply_fixed_entry(
	session: Variant, emitted: Dictionary, entry: Dictionary
) -> Dictionary:
	for field: String in ["boundary_tick", "observation_seq", "opportunity_id"]:
		if entry.get(field) != emitted.get(field):
			return _local_failure("action transcript %s does not match emitted observation" % field)
	var commits: Array = []
	for row_variant: Variant in entry["batches"]:
		var row: Dictionary = row_variant
		var seat := int(row["player_slot"])
		var batch: Dictionary = row["batch"]
		var envelope_code := ActionContract.envelope_structural_code(batch)
		if not envelope_code.is_empty():
			return _local_failure(
				"action transcript batch envelope is invalid: %s" % envelope_code
			)
		var observation: Dictionary = emitted["observations"][str(seat)]
		if str(batch.get("match_id", "")) != str(session.match_id) \
			or int(batch.get("observation_seq", -1)) != int(emitted["observation_seq"]) \
			or str(batch.get("based_on_observation_hash", "")) \
				!= str(observation["observation_hash"]) \
			or int(batch.get("valid_until_tick", -1)) \
				!= int(observation["decision"]["valid_until_tick"]):
			return _local_failure(
				"action transcript batch does not bind to the emitted seat observation"
			)
		var commit_hash := Session.action_batch_commit_hash(
			batch, str(row["salt_hex"])
		)
		if commit_hash.is_empty():
			return _local_failure("action transcript contains a non-canonical reveal batch")
		commits.append({"commit_hash": commit_hash, "player_slot": int(row["player_slot"])})
	commits.sort_custom(_seat_less)
	var locked: Dictionary = session.lock_fixed_commits({
		"boundary_tick": int(entry["boundary_tick"]),
		"commits": commits,
		"match_id": str(session.match_id),
		"observation_seq": int(entry["observation_seq"]),
		"opportunity_id": str(entry["opportunity_id"]),
	})
	if not bool(locked.get("ok", false)):
		return locked
	var reveals: Array = entry["batches"].duplicate(true)
	reveals.sort_custom(_seat_less)
	return session.reveal_fixed_pair({
		"activation_tick": int(entry["activation_tick"]),
		"boundary_tick": int(entry["boundary_tick"]),
		"disposition": str(entry["disposition"]),
		"match_id": str(session.match_id),
		"observation_seq": int(entry["observation_seq"]),
		"opportunity_id": str(entry["opportunity_id"]),
		"reveals": reveals,
	})


func _advance_to_boundary(
	session: Variant, target_tick: int, errors: PackedStringArray
) -> void:
	while int(session.simulation.state.tick) < target_tick \
		and not bool(session.simulation.state.terminal["ended"]):
		var tick := int(session.simulation.state.tick)
		var next_periodic := tick - (tick % CHECKPOINT_PERIOD_TICKS) \
			+ CHECKPOINT_PERIOD_TICKS
		var through := mini(target_tick, next_periodic)
		var advanced: Dictionary = session.advance_ticks(through - tick)
		_append_result_errors(errors, advanced, "fixed simulation advance")
		if not bool(advanced.get("ok", false)):
			return
		_capture_events(session, errors)
		var reached := int(session.simulation.state.tick)
		if reached > 0 and reached % CHECKPOINT_PERIOD_TICKS == 0:
			_record_checkpoint(reached, session.checkpoint_hash())
		if reached <= tick:
			errors.append("fixed simulation made no progress while advancing")
			return


func _capture_applications(session: Variant, errors: PackedStringArray) -> void:
	var protected: Dictionary = session.to_protected_canonical_dict()
	var transcript: Array = protected.get("application_transcript", [])
	if _application_cursor < 0 or _application_cursor > transcript.size():
		errors.append("authority application transcript cursor is invalid")
		return
	for record_index: int in range(_application_cursor, transcript.size()):
		var record_variant: Variant = transcript[record_index]
		if typeof(record_variant) != TYPE_DICTIONARY:
			errors.append("authority application transcript record is invalid")
			return
		var record: Dictionary = record_variant
		var application_tick := int(record.get("application_tick", -1))
		var batches: Variant = record.get("batches")
		if application_tick < 0 or typeof(batches) != TYPE_ARRAY:
			errors.append("authority application transcript record fields are invalid")
			return
		for batch_variant: Variant in batches:
			if typeof(batch_variant) != TYPE_DICTIONARY:
				errors.append("authority application batch record is invalid")
				return
			var batch: Dictionary = batch_variant
			var accepted_index := _accepted_actions.size()
			var accepted := {
				"application_tick": application_tick,
				"batch_digest": str(batch.get("batch_digest", "")),
				"batch_id": str(batch.get("batch_id", "")),
				"player_slot": int(batch.get("player_seat", -1)),
				"receipt": _deep_copy(batch.get("receipt", {})),
				"transcript_index": accepted_index,
			}
			if not _is_sha256(accepted["batch_digest"]) \
				or int(accepted["player_slot"]) not in [0, 1]:
				errors.append("authority accepted-action evidence is invalid")
				return
			_accepted_actions.append(accepted)
			_action_receipts.append({
				"application_tick": application_tick,
				"batch_id": accepted["batch_id"],
				"player_slot": accepted["player_slot"],
				"receipt": _deep_copy(accepted["receipt"]),
				"receipt_index": _action_receipts.size(),
			})
			var intents: Variant = batch.get("compiled_intents")
			if typeof(intents) != TYPE_ARRAY:
				errors.append("authority compiled-intent evidence is invalid")
				return
			for intent_variant: Variant in intents:
				if typeof(intent_variant) != TYPE_DICTIONARY:
					errors.append("authority compiled intent must be an object")
					return
				_compiled_orders.append({
					"application_tick": application_tick,
					"intent": _deep_copy(intent_variant),
					"source_action_index": accepted_index,
					"transcript_index": _compiled_orders.size(),
				})
	_application_cursor = transcript.size()


func _capture_events(session: Variant, errors: PackedStringArray) -> void:
	var result := _event_projector.project_from_cursor(session, _event_cursor)
	_append_result_errors(errors, result, "public event projection")
	if not bool(result.get("ok", false)):
		return
	for event_variant: Variant in result["events"]:
		var event: Dictionary = event_variant
		if int(event["event_seq"]) != _public_events.size() + 1:
			errors.append("projected public event sequence is not contiguous")
			return
		_public_events.append(event)
	_event_cursor = int(result["cursor"])


func _record_checkpoint(tick: int, state_sha256: String) -> void:
	var row := {
		"actions_through_index": _latest_index(_accepted_actions, tick, "application_tick"),
		"events_through_index": _latest_index(_public_events, tick, "tick"),
		"state_sha256": state_sha256,
		"tick": tick,
	}
	if not _checkpoints.is_empty() and int(_checkpoints[-1]["tick"]) == tick:
		_checkpoints[-1] = row
	else:
		_checkpoints.append(row)


func _build_artifacts(
	spec: Dictionary,
	terminal: Dictionary,
	final_tick: int,
	final_hash: String,
	errors: PackedStringArray
) -> Dictionary:
	if not bool(terminal.get("ended", false)):
		errors.append("cannot build replay manifest for non-terminal authority state")
		return {}
	var manifest_terminal := _manifest_terminal(terminal, final_tick, errors)
	if not errors.is_empty():
		return {}
	var state_checkpoints := {
		"checkpoints": _checkpoints.duplicate(true),
		"final_state_sha256": final_hash,
		"terminal_tick": final_tick,
	}
	var artifact_bytes := {
		"accepted-actions.ndjson": _canonical_ndjson(_accepted_actions),
		"compiled-orders.ndjson": _canonical_ndjson(_compiled_orders),
		"public-events.ndjson": _canonical_ndjson(_public_events),
		"state-checkpoints.json": Codec.canonical_bytes(state_checkpoints),
	}
	var role_by_path := {
		"accepted-actions.ndjson": "accepted_actions",
		"compiled-orders.ndjson": "compiled_orders",
		"public-events.ndjson": "public_events",
		"state-checkpoints.json": "state_checkpoints",
	}
	var files: Array = []
	for path: String in artifact_bytes.keys():
		var bytes: PackedByteArray = artifact_bytes[path]
		files.append({
			"bytes": bytes.size(),
			"media_type": (
				"application/json" if path.ends_with(".json") else "application/x-ndjson"
			),
			"path": path,
			"role": role_by_path[path],
			"sha256": _artifact_sha256(bytes),
		})
	files.sort_custom(_role_path_less)
	var config: Dictionary = spec["match_config"]
	var match_init: Dictionary = spec["match_init"]
	var players: Array = []
	for seat: int in [0, 1]:
		var row: Dictionary = config["players"][seat]
		players.append({
			"model_snapshot": str(row["model"]),
			"player_id": "player_a" if seat == 0 else "player_b",
			"provider_tier": "offline-transcript",
			"reasoning": str(row["reasoning"]),
		})
	var zero_usage := {
		"failed_opportunities": 0,
		"input_tokens": 0,
		"latency_ns_total": 0,
		"output_tokens": 0,
		"requests": 0,
	}
	var manifest := {
		"aggregate_usage": {
			"player_a": zero_usage.duplicate(true),
			"player_b": zero_usage.duplicate(true),
		},
		"artifacts": {
			"display_assets": [],
			"engine": match_init["artifacts"]["engine_build"].duplicate(true),
			"faction": {
				"id": str(match_init["faction"]["id"]),
				"sha256": str(match_init["faction"]["sha256"]),
			},
			"helper": match_init["artifacts"]["helper"].duplicate(true),
			"items": match_init["artifacts"]["items"].duplicate(true),
			"map": match_init["map"].duplicate(true),
			"neutrals": match_init["artifacts"]["neutrals"].duplicate(true),
			"prompt": match_init["artifacts"]["prompt"].duplicate(true),
			"protocol": match_init["artifacts"]["protocol"].duplicate(true),
			"rules": match_init["ruleset"].duplicate(true),
		},
		"checkpoints": _checkpoints.duplicate(true),
		"decision": {
			"control_profile": str(config["control_profile"]),
			"decision_period_ticks": int(config["decision_period_ticks"]),
			"mode": str(config["decision_mode"]),
			"observation_profile": str(config["observation_profile"]),
			"response_deadline_ms": int(config["response_deadline_ms"]),
			"simulation_hz": int(config["simulation_hz"]),
		},
		"files": files,
		"final_state_sha256": final_hash,
		"match_id": str(match_init["match_id"]),
		"players": players,
		"replay_guarantees": {
			"checkpoint_interval_ticks": CHECKPOINT_PERIOD_TICKS,
			"orders_use_recorded_application_ticks": true,
			"provider_calls": 0,
			"stop_on_hash_mismatch": true,
			"supports_omniscient": true,
			"supports_player_perspectives": true,
		},
		"schema_version": REPLAY_VERSION,
		"seat_mapping": [
			{"player_id": "player_a", "seat": 0, "world_side": "south"},
			{"player_id": "player_b", "seat": 1, "world_side": "north"},
		],
		"seed": int(config["seed"]),
		"terminal": manifest_terminal,
	}
	artifact_bytes["action-receipts.ndjson"] = _canonical_ndjson(_action_receipts)
	artifact_bytes["terminal-result.json"] = Codec.canonical_bytes({
		"authority": terminal.duplicate(true),
		"final_state_sha256": final_hash,
		"match_id": str(match_init["match_id"]),
		"terminal": manifest_terminal,
		"tick": final_tick,
	})
	artifact_bytes["replay-manifest.json"] = Codec.canonical_bytes(manifest)
	return artifact_bytes


func _manifest_terminal(
	terminal: Dictionary, tick: int, errors: PackedStringArray
) -> Dictionary:
	var result := str(terminal.get("result", ""))
	var reason := str(terminal.get("reason", ""))
	var winner_seat := int(terminal.get("winner_seat", -1))
	if result not in ["normal", "draw", "technical_forfeit", "infrastructure_void"]:
		errors.append("authority terminal result is not publishable")
	if reason.is_empty() or reason.length() > 96:
		errors.append("authority terminal reason is not publishable")
	var winner: Variant = null
	if winner_seat == 0:
		winner = "player_a"
	elif winner_seat == 1:
		winner = "player_b"
	elif winner_seat != -1:
		errors.append("authority terminal winner_seat is invalid")
	if result == "normal" and winner == null:
		errors.append("normal terminal result requires a winner")
	if result != "normal" and result != "technical_forfeit" and winner != null:
		errors.append("draw/void terminal result cannot name a winner")
	return {
		"reason": reason,
		"result": result,
		"tick": tick,
		"winner_player_id": winner,
	}


func _authority_bytes(authority: Dictionary, errors: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	var key_by_field := {
		"alias_salt_seat_0_hex": "alias_salt_seat_0",
		"alias_salt_seat_1_hex": "alias_salt_seat_1",
		"default_commit_salt_seat_0_hex": "default_commit_salt_seat_0",
		"default_commit_salt_seat_1_hex": "default_commit_salt_seat_1",
		"tie_key_hex": "tie_key",
	}
	for field: String in AUTHORITY_FIELDS:
		var bytes := str(authority[field]).hex_decode()
		if bytes.size() != 32:
			errors.append("authority.%s did not decode to 32 bytes" % field)
			continue
		result[key_by_field[field]] = bytes
	return result


func _read_authoritative_json(path: String, label: String) -> Dictionary:
	var bytes_result := _read_authoritative_bytes(path, label)
	if not bool(bytes_result.get("ok", false)):
		return bytes_result
	var bytes: PackedByteArray = bytes_result["bytes"]
	var text := bytes.get_string_from_utf8()
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return _local_failure("%s is not valid JSON" % label)
	var normalized := CatalogLoader.normalize_json_boundary(parser.data)
	if not bool(normalized.get("ok", false)) or typeof(normalized.get("value")) != TYPE_DICTIONARY:
		return {
			"errors": normalized.get("errors", PackedStringArray(["invalid JSON object"])),
			"ok": false,
		}
	return {
		"bytes": bytes,
		"errors": PackedStringArray(),
		"ok": true,
		"sha256": str(bytes_result["sha256"]),
		"value": normalized["value"],
	}


func _read_authoritative_bytes(path: String, label: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _local_failure("%s is missing" % label)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _local_failure("%s could not be opened" % label)
	var bytes := file.get_buffer(file.get_length())
	if bytes.get_string_from_utf8().to_utf8_buffer() != bytes:
		return _local_failure("%s is not exact UTF-8" % label)
	return {
		"bytes": bytes,
		"errors": PackedStringArray(),
		"ok": true,
		"sha256": Codec.sha256_bytes(bytes),
	}


func _validate_hash_ref(
	value: Variant,
	expected_id: String,
	expected_hash: String,
	label: String,
	errors: PackedStringArray,
	extra_fields: Array[String] = []
) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s must be a hash reference object" % label)
		return
	var reference: Dictionary = value
	var required: Array[String] = ["id", "sha256"]
	required.append_array(extra_fields)
	_validate_exact_fields(reference, required, [], label, errors)
	if typeof(reference.get("id")) != TYPE_STRING or str(reference.get("id", "")).is_empty():
		errors.append("%s id is invalid" % label)
	if not _is_sha256(reference.get("sha256")):
		errors.append("%s sha256 is invalid" % label)
	if not expected_id.is_empty() and str(reference.get("id", "")) != expected_id:
		errors.append("%s id differs from the locked artifact" % label)
	if not expected_hash.is_empty() and str(reference.get("sha256", "")) != expected_hash:
		errors.append("%s sha256 differs from the locked artifact bytes" % label)


func _reset_evidence() -> void:
	_accepted_actions.clear()
	_compiled_orders.clear()
	_public_events.clear()
	_action_receipts.clear()
	_checkpoints.clear()
	_application_cursor = 0
	_event_cursor = 0


static func _starting_entity_id(spawn_id: String, errors: PackedStringArray) -> String:
	const PREFIX := "spawn_self_"
	if not spawn_id.begins_with(PREFIX):
		errors.append("self-canonical starting spawn ID is invalid: %s" % spawn_id)
		return ""
	return "e_start_" + spawn_id.trim_prefix(PREFIX)


static func _record_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("id", "")) < str(right.get("id", ""))


static func _record_entity_id_less(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("entity_id", "")) < str(right.get("entity_id", ""))


static func _seat_less(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("player_slot", -1)) < int(right.get("player_slot", -1))


static func _role_path_less(left: Dictionary, right: Dictionary) -> bool:
	var left_role := str(left.get("role", ""))
	var right_role := str(right.get("role", ""))
	if left_role != right_role:
		return left_role < right_role
	return str(left.get("path", "")) < str(right.get("path", ""))


static func _canonical_equal(left: Variant, right: Variant) -> bool:
	return Codec.sha256_canonical(left) == Codec.sha256_canonical(right)


static func _is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var text := str(value)
	if text.length() != 64 or text.to_lower() != text:
		return false
	var decoded := text.hex_decode()
	return decoded.size() == 32 and decoded.hex_encode() == text


static func _is_identifier(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var text := str(value)
	if text.is_empty() or text.length() > 96:
		return false
	for index: int in text.length():
		var code := text.unicode_at(index)
		if index == 0:
			if not ((code >= 97 and code <= 122) or (code >= 48 and code <= 57)):
				return false
		elif not (
			(code >= 97 and code <= 122) or (code >= 48 and code <= 57)
			or code in [45, 46, 58, 95]
		):
			return false
	return true


static func _is_32_byte_hex(value: Variant) -> bool:
	return _is_sha256(value)


static func _latest_index(rows: Array[Dictionary], tick: int, field: String) -> int:
	var result := -1
	for index: int in rows.size():
		if int(rows[index][field]) <= tick:
			result = index
		else:
			break
	return result


static func _canonical_ndjson(rows: Array[Dictionary]) -> PackedByteArray:
	var parts := PackedStringArray()
	for row: Dictionary in rows:
		parts.append(Codec.canonical_json(row))
	if parts.is_empty():
		return PackedByteArray()
	return ("\n".join(parts) + "\n").to_utf8_buffer()


static func _artifact_sha256(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	return Codec.sha256_bytes(bytes)


static func _validate_exact_fields(
	value: Dictionary,
	required: Array[String],
	optional: Array[String],
	label: String,
	errors: PackedStringArray
) -> void:
	for field: String in required:
		if not value.has(field):
			errors.append("%s is missing %s" % [label, field])
	for key_variant: Variant in value.keys():
		if typeof(key_variant) != TYPE_STRING \
			or (str(key_variant) not in required and str(key_variant) not in optional):
			errors.append("%s contains unknown field %s" % [label, str(key_variant)])


static func _append_result_errors(
	errors: PackedStringArray, result: Dictionary, label: String
) -> void:
	var values: Variant = result.get("errors", [])
	if typeof(values) == TYPE_PACKED_STRING_ARRAY:
		for message: String in values:
			errors.append("%s: %s" % [label, message])
	elif typeof(values) == TYPE_ARRAY:
		for message: Variant in values:
			errors.append("%s: %s" % [label, str(message)])


static func _deep_copy(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY or typeof(value) == TYPE_ARRAY:
		return value.duplicate(true)
	return value


static func _local_failure(message: String) -> Dictionary:
	return {"errors": PackedStringArray([message]), "ok": false}


static func _failure(errors: PackedStringArray) -> Dictionary:
	return {"artifacts": {}, "errors": errors, "ok": false, "summary": {}}
