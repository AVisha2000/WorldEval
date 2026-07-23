extends SceneTree

const CombatSystem := preload("res://scripts/embodiment/authority/combat_system.gd")
const NeutralController := preload("res://scripts/embodiment/authority/neutral_controller.gd")

var _failures := PackedStringArray()


class StageDState extends RefCounted:
	var operator_position_mt := Vector2i.ZERO
	var operator_heading := 0
	var operator_health := 0
	var operator_energy := 0
	var operator_guarding := false
	var operator_knocked_out := false
	var primary_cooldown_ticks := 0
	var dash_cooldown_ticks := 0
	var neutral_position_mt := Vector2i(0, -1000)
	var neutral_home_position_mt := Vector2i(0, -1000)
	var neutral_health := 0
	var neutral_state := "idle"
	var neutral_state_ticks := 0
	var neutral_attack_cooldown_ticks := 0
	var relay_position_mt := Vector2i.ZERO
	var relay_activation_ticks := 0
	var relay_activated := false


func _init() -> void:
	_test_primary_miss_hit_and_cooldown()
	_test_guard_damage_and_energy_recovery()
	_test_dash_edge_energy_and_cooldown()
	_test_neutral_telegraph_attack_retreat_and_recovery()
	_test_knockout_and_relay_paths()
	_test_public_contract_stability()
	if not _failures.is_empty():
		for failure: String in _failures:
			push_error("STAGE_D_SYSTEMS_FAILURE: %s" % failure)
		print("STAGE_D_SYSTEMS_FAILED count=%d" % _failures.size())
		quit(1)
		return
	print("STAGE_D_SYSTEMS_OK")
	quit(0)


func _state() -> StageDState:
	var authority := StageDState.new()
	CombatSystem.reset(authority)
	NeutralController.reset(authority)
	return authority


func _buttons(overrides: Dictionary = {}) -> Dictionary:
	var buttons := {
		"ability_1": false, "ability_2": false, "cancel": false,
		"cycle_item": false, "dash": false, "guard": false,
		"interact": false, "primary": false,
	}
	buttons.merge(overrides, true)
	return {"buttons": buttons}


func _target(position_mt: Vector2i, health: int = 750) -> Dictionary:
	return {
		"health": health, "id": "neutral_0", "kind": "neutral",
		"position_mt": position_mt,
	}


func _test_primary_miss_hit_and_cooldown() -> void:
	var authority := _state()
	var events: Array[Dictionary] = []
	var distant := _target(Vector2i(0, -2000))
	var miss := CombatSystem.apply_tick(
		authority, _buttons({"primary": true}), true, distant, events
	)
	_check("primary_miss_range" in miss.codes, "out-of-range primary did not emit range miss")
	_check(distant.health == 750, "range miss damaged its target")
	_check(events[-1].kind == "primary_missed" and events[-1].data.reason == "range", "range miss event drifted")

	authority.primary_cooldown_ticks = 0
	var side_target := _target(Vector2i(1000, 0))
	var alignment := CombatSystem.apply_tick(
		authority, _buttons({"primary": true}), true, side_target, events
	)
	_check("primary_miss_alignment" in alignment.codes, "misaligned primary was not rejected")

	authority.primary_cooldown_ticks = 0
	var front_target := _target(Vector2i(0, -1000))
	var hit := CombatSystem.apply_tick(
		authority, _buttons({"primary": true}), true, front_target, events
	)
	_check("primary_hit" in hit.codes, "aligned in-range primary did not hit")
	_check(front_target.health == 500, "primary damage amount drifted")
	var cooldown := CombatSystem.apply_tick(
		authority, _buttons({"primary": true}), true, front_target, events
	)
	_check("primary_cooldown" in cooldown.codes, "cooling primary was not visibly rejected")
	_check(front_target.health == 500, "cooldown rejection damaged target")


func _test_guard_damage_and_energy_recovery() -> void:
	var authority := _state()
	var events: Array[Dictionary] = []
	var guard := CombatSystem.apply_tick(
		authority, _buttons({"guard": true}), false, {}, events
	)
	_check("guard_active" in guard.codes, "held guard did not become active")
	_check(authority.operator_energy == 960, "guard energy cost drifted")
	var damage := CombatSystem.apply_damage(authority, 180, Vector2i(0, -1000), events)
	_check(bool(damage.guarded), "frontal attack was not guarded")
	_check(damage.damage == 90 and authority.operator_health == 910, "guard reduction drifted")
	_check("guard_reduced_damage" in damage.codes, "guard reduction receipt code missing")

	authority.operator_energy = 20
	var depleted := CombatSystem.apply_tick(
		authority, _buttons({"guard": true}), false, {}, events
	)
	_check("guard_energy_depleted" in depleted.codes, "depleted guard was not rejected")
	_check(not authority.operator_guarding, "depleted Operator remained guarded")
	_check(authority.operator_energy == 45, "idle recovery after failed guard drifted")
	var recovery := CombatSystem.apply_tick(authority, _buttons(), false, {}, events)
	_check("energy_recovered" in recovery.codes and authority.operator_energy == 70, "energy did not recover deterministically")


func _test_dash_edge_energy_and_cooldown() -> void:
	var authority := _state()
	var events: Array[Dictionary] = []
	var applied := CombatSystem.apply_tick(
		authority, _buttons({"dash": true}), true, {}, events
	)
	_check("dash_applied" in applied.codes, "available dash was not applied")
	_check(authority.operator_position_mt == Vector2i(0, -900), "dash movement drifted")
	_check(authority.operator_energy == 700, "dash energy cost drifted")
	var held := CombatSystem.apply_tick(authority, _buttons({"dash": true}), false, {}, events)
	_check("dash_cooldown" not in held.codes, "held dash retriggered without an edge")
	_check(authority.operator_position_mt == Vector2i(0, -900), "held dash moved twice")
	var cooldown := CombatSystem.apply_tick(
		authority, _buttons({"dash": true}), true, {}, events
	)
	_check("dash_cooldown" in cooldown.codes, "dash cooldown rejection was not visible")
	authority.dash_cooldown_ticks = 0
	authority.operator_energy = 299
	var low_energy := CombatSystem.apply_tick(
		authority, _buttons({"dash": true}), true, {}, events
	)
	_check("dash_energy_insufficient" in low_energy.codes, "low-energy dash was not rejected")


func _test_neutral_telegraph_attack_retreat_and_recovery() -> void:
	var authority := _state()
	var events: Array[Dictionary] = []
	authority.operator_position_mt = Vector2i.ZERO
	authority.neutral_position_mt = Vector2i(0, -1000)
	authority.neutral_home_position_mt = Vector2i(500, 0)
	authority.neutral_state = "chase"
	NeutralController.apply_tick(authority, _buttons(), false, events)
	_check(authority.neutral_state == "telegraph", "neutral did not telegraph in attack range")
	for _tick: int in NeutralController.NEUTRAL_TELEGRAPH_TICKS:
		NeutralController.apply_tick(authority, _buttons(), false, events)
	_check(authority.neutral_state == "attack", "neutral telegraph duration drifted")
	NeutralController.apply_tick(authority, _buttons(), false, events)
	_check(authority.operator_health == 820, "neutral attack damage drifted")
	_check(authority.neutral_state == "recovery", "neutral did not recover after attack")

	# Damage at low health sends the neutral through a visible retreat and fixed recovery.
	authority.neutral_state = "chase"
	authority.neutral_health = 500
	authority.neutral_position_mt = Vector2i(500, 0)
	authority.neutral_home_position_mt = Vector2i.ZERO
	authority.operator_position_mt = Vector2i.ZERO
	authority.operator_heading = 2
	authority.primary_cooldown_ticks = 0
	var strike := NeutralController.apply_tick(
		authority, _buttons({"primary": true}), true, events
	)
	_check("neutral_retreating" in strike.codes, "low-health neutral did not report retreat")
	_check(authority.neutral_state == "retreat", "neutral retreat state was not retained")
	var retreat_relay := NeutralController.apply_tick(
		authority, _buttons({"interact": true}), false, events
	)
	_check(authority.neutral_state == "recovery", "neutral did not reach recovery at home")
	_check("relay_activation_progress" in retreat_relay.codes, "retreat did not open relay activation")
	for _tick: int in NeutralController.NEUTRAL_RECOVERY_TICKS:
		NeutralController.apply_tick(authority, _buttons(), false, events)
	_check(authority.neutral_health == NeutralController.NEUTRAL_RECOVERY_HEALTH, "neutral recovery health drifted")
	_check(authority.neutral_state == "chase", "recovered neutral did not resume chase")
	_check(_has_event(events, "neutral_recovered"), "neutral recovery event missing")


func _test_knockout_and_relay_paths() -> void:
	var authority := _state()
	var events: Array[Dictionary] = []
	authority.operator_health = 100
	var knockout := CombatSystem.apply_damage(authority, 180, Vector2i(1000, 0), events)
	_check(authority.operator_knocked_out and authority.operator_health == 0, "lethal damage did not knock out Operator")
	_check("operator_knockout" in knockout.codes, "knockout receipt code missing")

	authority = _state()
	events.clear()
	authority.operator_position_mt = Vector2i.ZERO
	authority.operator_heading = 0
	authority.neutral_position_mt = Vector2i(0, -1000)
	authority.neutral_health = CombatSystem.PRIMARY_DAMAGE
	var defeat := NeutralController.apply_tick(
		authority, _buttons({"primary": true, "interact": true}), true, events
	)
	_check("neutral_defeated" in defeat.codes, "lethal primary did not defeat neutral")
	_check(authority.neutral_state == "defeated", "defeated neutral state drifted")
	for _tick: int in NeutralController.RELAY_ACTIVATION_TICKS - 1:
		NeutralController.apply_tick(authority, _buttons({"interact": true}), false, events)
	_check(authority.relay_activated, "relay did not activate after defender defeat")
	_check(_has_event(events, "relay_activated"), "relay activation event missing")


func _test_public_contract_stability() -> void:
	var profile := NeutralController.public_profile()
	_check(profile.states == NeutralController.PUBLIC_STATES, "public state-machine profile drifted")
	_check(profile.telegraph_ticks == 3 and profile.attack_damage == 180, "public neutral timing/damage drifted")
	var authority := _state()
	var events: Array[Dictionary] = []
	CombatSystem.apply_tick(authority, _buttons({"dash": true}), true, {}, events)
	for event: Dictionary in events:
		_check(event.keys() == ["kind", "summary", "data"], "event descriptor keys drifted")
		_check(event.kind is String and event.summary is String and event.data is Dictionary, "event descriptor types drifted")


func _has_event(events: Array[Dictionary], kind: String) -> bool:
	for event: Dictionary in events:
		if event.kind == kind:
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
