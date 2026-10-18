extends "res://tests/common/dm_suite_runner.gd"
## rules/loot golden fixtures (loot_part), client / server loot-roll parity (loot_parity_part) and the other loot-rule parity fixtures (rules_parity_part), one process.
## godot --headless --path client --script res://tests/rules-loot/run.gd


func _init() -> void:
	suite_name = "rules-loot"


func parts() -> Array:
	return ["res://tests/rules-loot/loot_part.gd", "res://tests/rules-loot/loot_parity_part.gd", "res://tests/rules-loot/rules_parity_part.gd"]
