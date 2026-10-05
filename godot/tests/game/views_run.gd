extends SceneTree
## godot --headless --path godot --script res://tests/game/views_run.gd
## Entity / avatar / boss view tests (test_views.gd). Prints "N passed, M failed" and exits non-zero on failure.

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var t = load("res://tests/game/test_views.gd").new()
	await t.run(self)
	quit(1 if t.failed > 0 else 0)
