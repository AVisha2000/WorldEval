class_name ArenaRules
extends RefCounted

const VERSION := "arena-v1"
const FACTIONS := ["sol", "terra", "luna"]
const MATCH_ROUNDS := 40
const SUDDEN_DEATH_ROUNDS := 8
const ROUND_TICKS := 150
const TICK_SECONDS := 0.1
const COMMAND_POINTS := 4
const MAX_ORDERS := 3

const UNIT_STATS := {
	"commander": {"hp": 150.0, "dps": 20.0, "supply": 0, "speed": 4.0},
	"worker": {"hp": 30.0, "dps": 2.0, "supply": 1, "speed": 3.2},
	"scout": {"hp": 40.0, "dps": 4.0, "supply": 1, "speed": 5.0},
	"militia": {"hp": 75.0, "dps": 12.0, "supply": 1, "speed": 3.4},
	"guard": {"hp": 110.0, "dps": 18.0, "supply": 1, "speed": 2.8},
	"siege": {"hp": 130.0, "dps_units": 8.0, "dps_structures": 32.0, "supply": 2, "speed": 2.2}
}

const STRUCTURES := {
	"outpost": {"hp": 240.0, "cost": {"wood": 80, "stone": 50}, "rounds": 2},
	"shelter": {"hp": 180.0, "cost": {"wood": 80, "stone": 30}, "rounds": 1},
	"farm": {"hp": 140.0, "cost": {"wood": 60, "stone": 20}, "rounds": 1},
	"storage": {"hp": 180.0, "cost": {"wood": 70, "stone": 35}, "rounds": 1},
	"wall": {"hp": 180.0, "cost": {"wood": 30, "stone": 45}, "rounds": 1},
	"workshop": {"hp": 220.0, "cost": {"wood": 120, "stone": 60, "iron": 40}, "rounds": 2},
	"mine": {"hp": 200.0, "cost": {"wood": 60, "stone": 40}, "rounds": 2},
	"tower": {"hp": 300.0, "cost": {"stone": 70, "iron": 25}, "rounds": 2, "dps": 14.0}
}

const TRAINING := {
	"worker": {"cost": {"food": 30}, "rounds": 1},
	"scout": {"cost": {"food": 25, "wood": 20}, "rounds": 1},
	"militia": {"cost": {"food": 40, "wood": 25}, "rounds": 1},
	"guard": {"cost": {"food": 55, "iron": 20}, "rounds": 2},
	"siege": {"cost": {"food": 60, "wood": 40, "iron": 30, "crystal": 15}, "rounds": 2}
}

const HARVEST := {"forest": {"resource": "wood", "amount": 12}, "stone": {"resource": "stone", "amount": 8}, "iron": {"resource": "iron", "amount": 5}, "crystal": {"resource": "crystal", "amount": 3}, "animals": {"resource": "food", "amount": 10}}
const REGEN := {"home": {"forest": 4, "animals": 5}, "mine": {"forest": 2, "animals": 4}, "wild": {"forest": 6, "animals": 5}, "crown": {"animals": 3}}

static func order_cost(kind: String) -> int:
	return 2 if kind in ["mobilize", "retreat"] else 1

static func crown_weight(sudden_death: bool) -> int:
	return 5 if sudden_death else 3
