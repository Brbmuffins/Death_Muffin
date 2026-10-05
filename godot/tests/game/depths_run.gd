extends SceneTree
## Depths controller tests:  godot --headless --path godot --script res://tests/game/depths_run.gd
var _t := preload("res://tests/game/test_depths.gd").new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _t.run(self)
	print("%d passed, %d failed" % [_t.passed, _t.failed])
	quit(1 if _t.failed > 0 else 0)
