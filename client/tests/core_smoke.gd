extends SceneTree
## The combat core loads and answers across the boundary. Run: godot --headless --path client --script res://tests/core_smoke.gd


func _init() -> void:
	if not ClassDB.class_exists("DmCore"):
		printerr("FAIL core_smoke: DmCore is not registered (build it with native/build.sh linux)")
		quit(1)
		return
	var core: RefCounted = ClassDB.instantiate("DmCore")
	var version: String = core.version()
	var sum: int = core.checksum(1000)
	if not version.begins_with("dmcore") or sum != 499500:
		printerr("FAIL core_smoke: version=%s checksum=%d" % [version, sum])
		quit(1)
		return
	print("PASS core_smoke %s" % version)
	quit(0)
