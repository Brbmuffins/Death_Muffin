extends "res://tests/common/dm_suite_runner.gd"
## rules/loot golden fixtures (loot_part), the bag-save rules (bag_save_part) and client / server loot parity (loot_parity_part), one process.
## godot --headless --path godot --script res://tests/rules-loot/run.gd


func _init() -> void:
	suite_name = "rules-loot"


func parts() -> Array:
	return ["res://tests/rules-loot/loot_part.gd", "res://tests/rules-loot/bag_save_part.gd", "res://tests/rules-loot/loot_parity_part.gd"]
