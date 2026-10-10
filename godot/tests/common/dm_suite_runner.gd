extends SceneTree
## Runs several test parts one after another in ONE Godot process (each part is a former stand-alone runner, see dm_suite_part.gd) and prints
## one summary line. A suite's run.gd extends this file and overrides parts() (res:// paths) and suite_name. Between parts the runner removes
## nodes a part left under root and restores Engine time/physics settings, so a part cannot leak into the next.

var suite_name := "suite"


func parts() -> Array:
	return []


func _initialize() -> void:
	_go.call_deferred()


func _count(part: RefCounted, names: Array) -> int:
	for n in names:
		var v = part.get(n)
		if v != null:
			return int(v)
	return 0


func _go() -> void:
	var passed := 0
	var failed := 0
	var code := 0
	var list := parts()
	for path in list:
		var keep := root.get_children()
		var part: RefCounted = load(path).new()
		var t0 := Time.get_ticks_msec()
		part.bind(self)
		await part._initialize()
		var p := _count(part, ["passed", "_pass", "pass_count", "_p"])
		var f := _count(part, ["failed", "_fail", "fail_count", "_f"])
		print("  [%s] %d passed, %d failed (INFO: %.1f s wall)" % [String(path).get_file().get_basename(), p, f, float(Time.get_ticks_msec() - t0) / 1000.0])
		passed += p
		failed += f
		if part.exit_code != 0 or f > 0:
			code = 1
		for c in root.get_children():
			if not keep.has(c):
				root.remove_child(c)
				c.free()
		Engine.time_scale = 1.0
		Engine.physics_ticks_per_second = 60
		paused = false
	print("%s: %d passed, %d failed (%d parts)" % [suite_name, passed, failed, list.size()])
	quit(code)
