extends SceneTree
## Per-preset cost probe for the rebuild (NOT pass/fail): DmNextGame in an area with waves, each Graphics preset in turn; mean / p95 frame ms,
## draw calls, primitives. Headless = CPU only (dummy renderer); rendered under xvfb = llvmpipe (relative numbers only; hold the renderer lock):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver opengl3 --path godot \
##     --script res://tests/next_perfctl/preset_perf.gd -- [--area=graves] [--secs=8] [--presets=low,medium,high,ultra] [--shots=/abs/dir]
## --auto_res=1 leaves the governor on (default off, so each preset is measured at the same resolution).

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
	var r := await api.register("pp%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"persist": false, "warmup": true, "dressing": true, "hud": true})
	for i in 60:
		await process_frame
	var hb := g.local_body()
	hb.p["god"] = true
	var area := _arg("area", "graves")
	var rect: Dictionary = DmContent.area(area)["rect"]
	g.director.first_wave_delay = 0.2
	var at := Vector3((float(rect["x0"]) + float(rect["x1"])) / 2.0, 0.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	hb.teleport(at)
	g.camera.snap(at)
	var secs := float(_arg("secs", "8"))
	var shots := _arg("shots", "")
	if shots != "":
		DirAccess.make_dir_recursive_absolute(shots)
	var rendered := DisplayServer.get_name() != "headless"
	print("renderer=%s area=%s secs=%.0f" % ["rendered" if rendered else "headless", area, secs])
	for id in _arg("presets", "low,medium,high,ultra").split(","):
		g.ui_host.settings_store.update({"graphics": id, "auto_res": _arg("auto_res", "0") == "1", "fps": 0})
		for i in 90:
			await process_frame
		var times: Array = []
		var t1 := Time.get_ticks_usec()
		var draws := 0
		var prims := 0
		var n := 0
		while (Time.get_ticks_usec() - t1) / 1e6 < secs:
			var f0 := Time.get_ticks_usec()
			await process_frame
			times.append((Time.get_ticks_usec() - f0) / 1000.0)
			draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			n += 1
		var sum := 0.0
		for t in times:
			sum += float(t)
		times.sort()
		var vp := root.get_viewport()
		print("PRESET %-6s frames=%d mean=%.2fms p95=%.2fms max=%.1fms draws=%d prims=%d enemies=%d msaa=%d aniso=%d scale=%.2f" % [id, n, sum / maxf(n, 1), times[int(n * 0.95)], times[n - 1],
			draws / maxi(n, 1), prims / maxi(n, 1), g.director.enemies.size(), vp.msaa_3d, vp.anisotropic_filtering_level, vp.scaling_3d_scale])
		if shots != "" and rendered:
			vp.get_texture().get_image().save_png("%s/%s_%s.png" % [shots, area, id])
	quit(0)
