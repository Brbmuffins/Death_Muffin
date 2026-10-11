extends "res://tests/common/dm_suite_runner.gd"
## DmRiteCaster + every rite family, one process: caster (needle, miasma, plumbing), control, corpse, projectile, signature rites, the Reaper's kit.
## godot --headless --path godot --script res://tests/rites/run.gd


func _init() -> void:
	suite_name = "rites"


func parts() -> Array:
	return ["res://tests/rites/caster_part.gd", "res://tests/rites/control_part.gd", "res://tests/rites/corpse_part.gd", "res://tests/rites/projectile_part.gd",
		"res://tests/rites/signature_part.gd", "res://tests/rites/reaper_part.gd"]
