extends "res://tests/common/dm_suite_runner.gd"
## Backend suite, one process: everything that exercises DmApi / DmMockBackend / DmSessionRewards without a live server, in sequence:
## offline (route sweep + relaunch persistence + session paths), net (request/scenario goldens + DmMockBackend), session_report, online_local.
## No server or child process is started here (online_live is the opt-in live check). DM_LIVE_SMOKE=1 still enables net_part's live smoke.
## godot --headless --path godot --script res://tests/backend/run.gd


func _init() -> void:
	suite_name = "backend"


func parts() -> Array:
	return ["res://tests/backend/offline_part.gd", "res://tests/backend/net_part.gd", "res://tests/backend/session_report_part.gd", "res://tests/backend/online_local_part.gd"]
