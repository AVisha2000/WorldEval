class_name DuelHeadlessCliNode
extends Node

const Cli := preload("res://scripts/duel/match/duel_headless_cli.gd")


func _ready() -> void:
	var exit_code := Cli.run_command()
	get_tree().quit(exit_code)
