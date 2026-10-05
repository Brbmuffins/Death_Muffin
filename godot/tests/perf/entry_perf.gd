extends SceneTree
## Area entry with the full UI: settle in the Chapterhouse, then step into a hunting ground; every frame over 25 ms for the next 6 s is
## printed with DmGame.tick sections, sim sections, events and the time outside the game tick.
## godot --headless --path godot --script res://tests/perf/entry_perf.gd -- [--area=graves]

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _run() -> void:
	var area := _arg("area", "graves")
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("ep%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 5, "warmup": true})
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	game.ui = ui
	game.nav.set_unlocked(DmContent.area_order())
	for i in 180:
		await process_frame
	var off := _arg("off", "")
	var node_off: Node = null
	match off:
		"ui": node_off = ui
		"audio": node_off = root.get_node("AudioDirector")
		"vfx": node_off = root.get_node("Vfx")
	if node_off != null:
		node_off.process_mode = Node.PROCESS_MODE_DISABLED
	game.prof_on = true
	game.sim.prof_on = true
	var rect: Dictionary = DmContent.area(area)["rect"]
	game.actions.teleport_to((float(rect["x0"]) + float(rect["x1"])) / 2.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	while (Time.get_ticks_usec() - t0) / 1e6 < 6.0:
		game.p["hp"] = game.player.max_hp()
		var g0: Dictionary = game.prof.duplicate()
		var s0: Dictionary = game.sim.prof.duplicate()
		var e0: Dictionary = game.ev_prof.duplicate()
		var fs := Time.get_ticks_usec()
		await process_frame
		var ms := (Time.get_ticks_usec() - fs) / 1000.0
		worst = maxf(worst, ms)
		if ms < 25.0:
			continue
		var secs := {}
		var tick := 0.0
		for k in game.prof:
			var d := (int(game.prof[k]) - int(g0.get(k, 0))) / 1000.0
			secs["g." + k] = d
			tick += d
		for k in game.sim.prof:
			secs["s." + k] = (int(game.sim.prof[k]) - int(s0.get(k, 0))) / 1000.0
		for k in game.ev_prof:
			secs[k] = (int(game.ev_prof[k]) - int(e0.get(k, 0))) / 1000.0
		var top: Array = secs.keys()
		top.sort_custom(func(a, b): return secs[a] > secs[b])
		var line := "ENTRY t=%.2fs frame=%.1fms outside-tick=%.1fms enemies=%d:" % [(fs - t0) / 1e6, ms, ms - tick, game.sim.enemies.size()]
		for k in top.slice(0, 7):
			if secs[k] >= 0.5:
				line += " %s=%.1f" % [k, secs[k]]
		print(line)
	print("ENTRY worst=%.1fms" % worst)
	quit(0)
