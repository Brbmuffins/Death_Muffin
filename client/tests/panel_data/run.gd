extends "res://tests/common/dm_suite_runner.gd"
## Panel data -> rows, one process: the panels_a family (panels_a_part) and the panels_b family (panels_b_part), both on mocks, no game boot.
## godot --headless --path client --script res://tests/panel_data/run.gd   (the panels_b directory is gone; sheet_sample.json stays here because live code loads it)


func _init() -> void:
	suite_name = "panel_data"


func parts() -> Array:
	return ["res://tests/panel_data/panels_a_part.gd", "res://tests/panel_data/panels_b_part.gd"]
