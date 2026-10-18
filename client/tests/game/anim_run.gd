extends SceneTree
## Creature animation feel: hit recoil, strike lunge, tip-over, spawn rise, idle desync, allocation-free locomotion plan, scythe swing speed.
## godot --headless --path client --script res://tests/game/anim_run.gd
var passed := 0
var failed := 0

func check(ok: bool, msg: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL ", msg)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var dt := 1.0 / 60.0
	var c := DmCreature.new("grave_robber", {})
	root.add_child(c.root)
	c.update(dt)
	var m: Node3D = c.root.get_child(0)
	check(not c.busy(), "idle body is not busy")
	# hit recoil: a fresh flash kicks the body, then it settles back to identity and stops costing
	c.set_flash(1.0)
	check(c.busy(), "a hit starts the recoil")
	var peak := 0.0
	for i in 8:
		c.update(dt)
		peak = maxf(peak, absf(m.rotation.x))
	check(peak > 0.02, "recoil leans the body (%.3f)" % peak)
	for i in 30:
		c.update(dt)
	check(m.transform.is_equal_approx(Transform3D.IDENTITY) and not c._fx_on, "recoil settles to identity and switches off")
	# strike lunge goes forward at the hit and settles
	c.set_flash(0.0)
	c.play_strike("attack", 0.4)
	var zmax := 0.0
	for i in 40:
		c.update(dt)
		zmax = maxf(zmax, m.position.z)
	check(zmax > 0.05, "strike lunges forward (%.3f)" % zmax)
	for i in 40:
		c.update(dt)
	check(absf(m.position.z) < 0.001, "lunge settles")
	# idle desync: bodies do not start in step
	var phases := {}
	var cs: Array = []
	for i in 6:
		var b := DmCreature.new("grave_robber", {})
		root.add_child(b.root)
		cs.append(b)
		phases[snappedf(b.ap.current_animation_position, 0.01)] = true
	check(phases.size() > 3, "idle phases differ across a crowd (%d distinct)" % phases.size())
	var hero := DmCreature.new("hero_gravecaller", {"in_place": true})
	check(hero._idle_k == 1.0, "heroes idle at the authored rate")
	# locomotion plan does not allocate a new dictionary per call
	c.set_ground_speed(1.2)
	var p1 := c.last_plan
	c.set_ground_speed(2.6)
	check(is_same(p1, c.last_plan), "plan dictionary is reused")
	# rigs with no death clip tip over smoothly, then freeze
	var hound := DmCreature.new("bone_hound", {})
	root.add_child(hound.root)
	hound.update(dt)
	check(not hound.play_death(), "hound has no death clip")
	hound.topple()
	var mid := 0.0
	for i in 12:
		hound.update(dt)
	mid = (hound.root.get_child(0) as Node3D).rotation.x
	check(mid < 0.0 and mid > -PI * 0.5, "tip-over is in progress, not snapped (%.2f)" % mid)
	for i in 40:
		hound.update(dt)
	check(is_equal_approx((hound.root.get_child(0) as Node3D).rotation.x, -PI * 0.5) and hound.has_landed() and not hound.ap.is_playing(), "tipped body holds and stops animating")
	hound.recycle_reset()
	check((hound.root.get_child(0) as Node3D).transform.is_equal_approx(Transform3D.IDENTITY), "reset stands the body up")
	# a clip-less rig still lunges on a strike
	hound.update(dt)
	hound.play_strike("attack", 0.3)
	var hz := 0.0
	for i in 30:
		hound.update(dt)
		hz = maxf(hz, (hound.root.get_child(0) as Node3D).position.z)
	check(hz > 0.1, "clip-less rig lunges (%.2f)" % hz)
	# spawn rise leans and ends clean
	c.set_rise(0.0)
	check(m.rotation.x > 0.3 and c.rising(), "rise leans in")
	c.set_rise(1.0)
	check(m.rotation.x == 0.0 and not c.rising() and not c._fx_on, "rise ends upright")
	# scythe swing on a rig without a sweep clip stays a sane speed
	var av := DmCreature.new("hero_gravecaller", {"in_place": true})
	root.add_child(av.root)
	av.update(dt)
	av.play_strike("attack", 2.6 * 0.45)
	check(av.ap.speed_scale <= 2.2, "squeezed swing is capped (%.1f)" % av.ap.speed_scale)
	print("%d passed, %d failed" % [passed, failed])
	print("%s game/anim_run %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)
