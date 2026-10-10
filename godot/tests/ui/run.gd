extends "res://tests/common/dm_suite_runner.gd"
## UI suite, one process: the HUD view-model -> widget state (hud_part), the UI kit (ui_part) and the Reliquary sizing (reliquary_part).
## godot --headless --path godot --script res://tests/ui/run.gd


func _init() -> void:
	suite_name = "ui"


func parts() -> Array:
	return ["res://tests/ui/hud_part.gd", "res://tests/ui/ui_part.gd", "res://tests/ui/reliquary_part.gd"]
