extends SceneTree
## Physics interpolation: the project setting is on, what moves in _physics_process draws smoothly between 60 Hz ticks, teleports do not smear,
## and what is moved in _process (puppets, camera, the effects tree) is NOT interpolated.
## Run: godot --headless --path client --script res://tests/interp/run.gd
## The enemies are bodies of the combat core drawn by the crowd, no node of their own: the old suite's checks of an enemy node's interpolation have nothing left to check.

var passed := 0
var failed := 0
var _ticks := 0


func check(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _initialize() -> void:
	_run.call_deferred()


func _on_tick() -> void:
	_ticks += 1


func _run() -> void:
	await process_frame
	root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # as DmMain does
	check(bool(ProjectSettings.get_setting("physics/common/physics_interpolation", false)), "project setting physics/common/physics_interpolation is on")
	check(Engine.physics_ticks_per_second == 60, "60 Hz physics tick")
	physics_frame.connect(_on_tick)
	await _t_body_smooth()
	await _t_teleport()
	await _t_modes()
	print("%d passed, %d failed" % [passed, failed])
	print("%s interp %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


## A host body stepped once per physics tick draws a value between the last two tick positions on every rendered frame.
func _t_body_smooth() -> void:
	var b := DmSessionBody.new()
	b.simulated = true
	root.add_child(b)
	b.setup(1, "t", "necromancer", Vector3.ZERO)
	await process_frame
	check(b.is_physics_interpolated_and_enabled(), "a host body interpolates")
	var seen := {}
	var mono := true
	var inside := true
	var last := -1.0
	var t0 := _ticks
	var frames := 0
	while _ticks - t0 < 30:
		await process_frame
		frames += 1
		# one 0.2 m step per tick, applied in the tick like step_host does
		if _ticks > int(b.get_meta(&"stepped", 0)):
			b.set_meta(&"stepped", _ticks)
			b.position.x += 0.2
		var vx := b.visual_position().x
		if vx < last - 1e-4:
			mono = false
		if vx > b.position.x + 1e-4 or vx < b.position.x - 0.2 - 1e-4:
			inside = false
		last = vx
		seen[snappedf(vx, 0.0001)] = true
	check(mono, "the drawn position never moves backwards")
	check(inside, "the drawn position stays within one tick step behind the physics position")
	check(seen.size() > 30 * 1.5, "the drawn position advances between ticks (%d distinct values over 30 ticks, %d frames)" % [seen.size(), frames])
	b.queue_free()
	await process_frame


## After teleport() the drawn position IS the new position at once (no streak from the old spot), also before the next tick runs.
func _t_teleport() -> void:
	var b := DmSessionBody.new()
	b.simulated = true
	root.add_child(b)
	b.setup(1, "t", "necromancer", Vector3.ZERO)
	for i in 4:
		await physics_frame
		b.position.x += 1.0
	await physics_frame   # teleports happen inside a tick (rites, respawn); the reset is applied when that tick ends
	b.teleport(Vector3(50.0, 0.0, -30.0))
	await process_frame
	check(b.visual_position().is_equal_approx(Vector3(50.0, 0.0, -30.0)), "teleport: drawn == new position on the next frame (got %s)" % b.visual_position())
	for i in 3:
		await process_frame
		check(b.visual_position().distance_to(b.position) < 1e-3, "teleport: no smear on later frames (tick %d)" % _ticks)
	# a body entering the tree already at its spawn point does not glide from the origin
	var s := DmSessionBody.new()
	s.simulated = true
	s.setup(2, "s", "necromancer", Vector3(40.0, 0.0, 40.0))
	root.add_child(s)
	await process_frame
	check(s.visual_position().distance_to(Vector3(40.0, 0.0, 40.0)) < 1e-3, "spawn: drawn == spawn point")
	b.queue_free()
	s.queue_free()
	await process_frame


## Interpolation is opt-in: authority bodies yes, remote bodies and the camera no.
func _t_modes() -> void:
	var rb := DmSessionBody.new()   # a remote body: moved in _process from snapshots
	root.add_child(rb)
	check(not rb.is_physics_interpolated_and_enabled(), "a non-simulated body is not interpolated")
	rb.queue_free()
	var cam := DmCameraRig.new()
	root.add_child(cam)
	cam.setup({"fov": 40, "near": 0.1, "far": 200})
	check(not cam.is_physics_interpolated_and_enabled(), "the camera rig is not interpolated (it follows the interpolated hero in _process)")
	cam.queue_free()
	await process_frame
