extends SceneTree
## Gathering-layer tests (test_gather.gd) and laborer views + labor/garden glue tests (test_labor.gd) in ONE process.
## godot --headless --path godot --script res://tests/game/units_run.gd
## (Formerly gather_run + labor_run.) Prints "N passed, M failed" and exits non-zero on failure.
var _g := preload("res://tests/game/test_gather.gd").new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _g.run(self)
	var t = load("res://tests/game/test_labor.gd").new()
	await t.run(self)
	print("%d passed, %d failed" % [_g.passed + t.passed, _g.failed + t.failed])
	quit(1 if (_g.failed + t.failed) > 0 else 0)
