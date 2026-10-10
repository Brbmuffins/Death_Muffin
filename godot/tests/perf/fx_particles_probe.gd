extends SceneTree
## Script cost of the mote engines in a saturated fight (headless): DmFxRing update + emit (additive 3500 / smoke 900) and
## DmWfxParticles (brazier fire at its 160 cap, backdrop mist/embers).
##   nice -n 10 godot --headless --path godot --script res://tests/perf/fx_particles_probe.gd
## Headless uses the dummy renderer: mm.buffer uploads cost nothing here, so the real GPU upload is not in these numbers.

const DT := 1.0 / 60.0


func _initialize() -> void:
	_run.call_deferred()


func _stats(label: String, xs: Array, extra: String = "") -> void:
	xs.sort()
	var sum := 0.0
	for x in xs:
		sum += x
	print("FXP %-34s avg %.3f ms  p50 %.3f  p99 %.3f  max %.3f %s" % [label, sum / xs.size(), xs[xs.size() / 2], xs[int(xs.size() * 0.99)], xs[xs.size() - 1], extra])


func _level(fx, prims, bursts: int, smoke_bursts: int) -> void:
	var upd: Array = []
	var emit_ms: Array = []
	var live_a := 0
	var live_s := 0
	var up_a := 0
	var up_s := 0
	seed(7)
	for f in 420:
		var t0 := Time.get_ticks_usec()
		for b in bursts:
			prims.emit({"x": randf() * 20.0 - 10.0, "y": 0.5, "z": randf() * 20.0 - 10.0, "count": 5, "color": 0xff8040, "spread": 0.4, "speed": 2.5, "up": 2.0, "life": 0.9, "size": 0.3, "gravity": 4.0, "drag": 1.5})
		for b in smoke_bursts:
			prims.emit_smoke({"x": randf() * 20.0 - 10.0, "y": 0.3, "z": randf() * 20.0 - 10.0, "count": 5, "color": 0x303030, "life": 1.8, "size": 0.9, "up": 0.6})
		var t1 := Time.get_ticks_usec()
		prims.additive.update(DT)
		prims.smoke.update(DT)
		var t2 := Time.get_ticks_usec()
		if f >= 180:
			emit_ms.append((t1 - t0) / 1000.0)
			upd.append((t2 - t1) / 1000.0)
			live_a = prims.additive.active()
			live_s = prims.smoke.active()
			up_a = prims.additive.get("last_upload_bytes") if prims.additive.get("last_upload_bytes") != null else prims.additive.capacity * 64
			up_s = prims.smoke.get("last_upload_bytes") if prims.smoke.get("last_upload_bytes") != null else prims.smoke.capacity * 64
	_stats("ring update live add~%d" % live_a, upd, "live add=%d smoke=%d upload add=%d B smoke=%d B" % [live_a, live_s, up_a, up_s])
	_stats("ring emit (%d motes/frame)" % (bursts * 5 + smoke_bursts * 5), emit_ms)


func _run() -> void:
	var fx := DmFxRuntime.new()
	root.add_child(fx)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 12, 9)
	cam.look_at(Vector3.ZERO)
	await process_frame
	var prims = fx.prims
	# Fight levels: bursts of 5 additive motes per frame (life 0.9 s = 54 frames) hold the additive ring near 500 / 2000 / 3500 live.
	for lv in [[2, 0], [7, 1], [14, 3]]:
		await _level(fx, prims, lv[0], lv[1])
		for f in 240:
			prims.additive.update(DT)
			prims.smoke.update(DT)
	# Idle after the fight: motes expire, then updates must be ~free.
	for f in 240:
		prims.additive.update(DT)
		prims.smoke.update(DT)
	var idle: Array = []
	for f in 200:
		var t1 := Time.get_ticks_usec()
		prims.additive.update(DT)
		prims.smoke.update(DT)
		idle.append((Time.get_ticks_usec() - t1) / 1000.0)
	_stats("ring update idle", idle, "live add=%d" % prims.additive.active())
	fx.queue_free()
	cam.queue_free()
	# World particles: brazier fire pinned at its cap, and the backdrop pair.
	var fire := DmWfxBrazierFire.new()
	root.add_child(fire)
	fire.setup(DmData.world())
	var fu: Array = []
	for f in 360:
		for k in 3:
			fire.emit(0.0, 1.0, 0.0, Color(0.5, 0.3, 0.9), 0.2, 0.3, 1.5, 1.2, 0.2, 0.0, 0.3)
		var t1 := Time.get_ticks_usec()
		fire._update(DT)
		if f >= 120:
			fu.append((Time.get_ticks_usec() - t1) / 1000.0)
	_stats("brazier fire _update (cap 160)", fu, "live=%d" % fire.active)
	var bd := DmNecroBackdrop.make_layer()
	root.add_child(bd)
	await process_frame
	var b: DmNecroBackdrop = bd.get_meta("backdrop")
	var bu: Array = []
	for f in 900:
		for k in 2:
			b.embers.emit(randf() * 10.0, -2.5, -4.0, Color(1, 0.6, 0.3), 0.5, 0.15, 1.0, 5.0, 0.16, 0.0, 0.2)
			b.mist.emit(randf() * 10.0, -2.5, -8.0, Color(0.2, 0.2, 0.3), 2.0, 0.4, 0.05, 9.0, 9.0, 0.0, 0.1, -0.6)
		var t1 := Time.get_ticks_usec()
		b.mist._update(DT)
		b.embers._update(DT)
		if f >= 600:
			bu.append((Time.get_ticks_usec() - t1) / 1000.0)
	_stats("backdrop mist+embers _update (2x256)", bu, "live=%d+%d" % [b.mist.active, b.embers.active])
	quit(0)
