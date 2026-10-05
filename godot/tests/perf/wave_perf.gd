extends SceneTree
## Wave stress (headless): the hero holds the Graves while extra waves are forced in. Prints, per enemy-count band, the average frame
## split (sim sections + DmGame.tick sections), and for every spawn frame its breakdown.
## godot --headless --path godot --script res://tests/perf/wave_perf.gd -- [--waves=8] [--every=2.0] [--area=graves] [--warmup=1]

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _run() -> void:
	var area := _arg("area", "graves")
	var waves := int(_arg("waves", "8"))
	var every := float(_arg("every", "2.0"))
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("wp%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 5, "warmup": _arg("warmup", "1") == "1"})
	game.character["level"] = 30
	game.refresh_stats()
	game.dev_access = true
	game.nav.set_unlocked(DmContent.area_order())
	var rect: Dictionary = DmContent.area(area)["rect"]
	game.player.teleport((float(rect["x0"]) + float(rect["x1"])) / 2.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	game.p["area"] = area
	for i in 30:
		await process_frame
	if _arg("clear", "0") == "1":
		game.sim.clear_area(area)
		game.sim.waveTimers[area] = 999.0
	game.prof_on = true
	game.sim.prof_on = true
	var bands := {}   # band -> {n, frame, sections{}}
	var forced := 0
	var next_force := 0.5
	var t0 := Time.get_ticks_usec()
	var last := t0
	var total := float(waves) * every + 6.0
	while (Time.get_ticks_usec() - t0) / 1e6 < total:
		game.p["hp"] = game.player.max_hp()
		var el := (Time.get_ticks_usec() - t0) / 1e6
		var spawn := false
		if forced < waves and el >= next_force:
			DmSimDirector.spawn_wave(game.sim, area)
			forced += 1
			next_force += every
			spawn = true
		var g0: Dictionary = game.prof.duplicate()
		var s0: Dictionary = game.sim.prof.duplicate()
		var n_before: int = game.sim.enemies.size()
		var fs := Time.get_ticks_usec()
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - fs) / 1000.0
		var secs := {}
		for k in game.prof:
			secs["g." + k] = (int(game.prof[k]) - int(g0.get(k, 0))) / 1000.0
		for k in game.sim.prof:
			secs["s." + k] = (int(game.sim.prof[k]) - int(s0.get(k, 0))) / 1000.0
		if spawn or game.sim.enemies.size() - n_before >= 3:
			var top: Array = secs.keys()
			top.sort_custom(func(a, b): return secs[a] > secs[b])
			var line := "SPAWN +%d (now %d) frame=%.1fms:" % [game.sim.enemies.size() - n_before, game.sim.enemies.size(), ms]
			for k in top.slice(0, 6):
				line += " %s=%.1f" % [k, secs[k]]
			print(line)
			continue
		var band := int(game.sim.enemies.size() / 10) * 10
		if not bands.has(band):
			bands[band] = {"n": 0, "frame": 0.0, "secs": {}, "draws": 0, "objs": 0, "prims": 0}
		var b: Dictionary = bands[band]
		b.n += 1
		b.draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		b.objs += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		b.prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		b.frame += ms
		for k in secs:
			b.secs[k] = float(b.secs.get(k, 0.0)) + secs[k]
		last = now
	var keys: Array = bands.keys()
	keys.sort()
	for band in keys:
		var b: Dictionary = bands[band]
		var top: Array = b.secs.keys()
		top.sort_custom(func(a, c2): return b.secs[a] > b.secs[c2])
		var line := "BAND enemies %d-%d: frames=%d avg=%.2fms draws=%d objs=%d tris=%dk |" % [band, band + 9, b.n, b.frame / b.n, b.draws / b.n, b.objs / b.n, b.prims / b.n / 1000]
		for k in top.slice(0, 7):
			line += " %s=%.2f" % [k, b.secs[k] / b.n]
		print(line)
	quit(0)
