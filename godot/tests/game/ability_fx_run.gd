extends SceneTree
## godot --headless --path godot --script res://tests/game/ability_fx_run.gd
## DmAbilitySystem parity + coverage (see test_ability_fx.gd). Prints "N passed, M failed", exits non-zero on failure.


func _initialize() -> void:
	# Autoloads are children of root by now; give Vfx a frame to build itself before the first effect.
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	await process_frame
	var scr: GDScript = load("res://tests/game/test_ability_fx.gd")
	if scr == null or not scr.can_instantiate():
		print("0 passed, 1 failed (test script does not compile)")
		quit(1)
		return
	var t = scr.new()
	t.run()
	for m in t.messages:
		print(m)
	print("%d passed, %d failed" % [t.passed, t.failed])
	quit(1 if t.failed > 0 else 0)
