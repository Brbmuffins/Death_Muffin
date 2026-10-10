extends "res://tests/common/dm_suite_runner.gd"
## Every enemy kind, one process: base (robbers), cathedral, cloister, kinds (the rest), pyre / fen. Each part builds its own test arena.
## godot --headless --path godot --script res://tests/enemies/run.gd


func _init() -> void:
	suite_name = "enemies"


func parts() -> Array:
	return ["res://tests/enemies/base_part.gd", "res://tests/enemies/cathedral_part.gd", "res://tests/enemies/cloister_part.gd", "res://tests/enemies/kinds_part.gd",
		"res://tests/enemies/pyre_fen_part.gd"]
