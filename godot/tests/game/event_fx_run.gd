extends SceneTree
## godot --headless --path godot --script res://tests/game/event_fx_run.gd

const T := preload("res://tests/game/test_event_fx.gd")


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	var t := T.new()
	await t.run(self)
	print("%d passed, %d failed" % [t.passed, t.failed])
	quit(1 if t.failed > 0 else 0)
