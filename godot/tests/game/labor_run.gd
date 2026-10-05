extends SceneTree
## godot --headless --path godot --script res://tests/game/labor_run.gd
## Laborer views + labor/garden glue tests (test_labor.gd). Prints "N passed, M failed" and exits non-zero on failure.

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var t = load("res://tests/game/test_labor.gd").new()
	await t.run(self)
	print("%d passed, %d failed" % [t.passed, t.failed])
	quit(1 if t.failed > 0 else 0)
