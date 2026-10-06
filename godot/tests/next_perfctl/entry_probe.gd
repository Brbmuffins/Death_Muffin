extends SceneTree
## Rendered first-entry probe for the rebuild (NOT a pass/fail suite; xvfb + the renderer lock), the entry_perf.gd method: Mesa dumps every
## shader it compiles (MESA_GLSL=dump) to stderr; markers on stderr bracket each first entry, so the dumps between them are compiles the
## warm-up missed. Frames over --min ms inside the window are printed too.
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" env MESA_GLSL=dump \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_perfctl/entry_probe.gd -- [--areas=graves,nave,pyre] [--warmup=1] [--secs=6]

func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("ep%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	printerr("PROBE_START")
	var t0 := Time.get_ticks_msec()
	await g.start(c.data, api, {"persist": false, "warmup": _arg("warmup", "1") == "1"})
	printerr("PROBE_STARTED")
	print("start() %d ms, warm-up %d ms (warmup=%s)" % [Time.get_ticks_msec() - t0, DmNextWarmup.last_ms if _arg("warmup", "1") == "1" else 0, _arg("warmup", "1")])
	for i in 60:
		await process_frame
	var hb := g.local_body()
	hb.p["god"] = true
	var secs := float(_arg("secs", "6"))
	for area in _arg("areas", "graves,nave,pyre").split(","):
		var rect: Dictionary = DmContent.area(area)["rect"]
		g.director.first_wave_delay = 0.2
		printerr("PROBE_BEGIN " + area)
		var at := Vector3((float(rect["x0"]) + float(rect["x1"])) / 2.0, 0.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
		hb.teleport(at)
		g.camera.snap(at)   # a waystone / door travel snaps the camera (DmChapterhouse)
		var t1 := Time.get_ticks_usec()
		var worst := 0.0
		var n := 0
		while (Time.get_ticks_usec() - t1) / 1e6 < secs:
			var f0 := Time.get_ticks_usec()
			await process_frame
			var ms := (Time.get_ticks_usec() - f0) / 1000.0
			worst = maxf(worst, ms)
			n += 1
			if ms >= float(_arg("min", "60")):
				printerr("PROBE_FRAME %s t=%.2fs %.0f ms" % [area, (f0 - t1) / 1e6, ms])
		printerr("PROBE_END " + area)
		print("%s: area=%s frames=%d worst=%.0f ms enemies=%d" % [area, g.area_id, n, worst, g.director.enemies.size()])
		for e in g.director.enemies.values():
			if is_instance_valid(e):
				e.queue_free()
		g.director.enemies.clear()
	quit(0)
