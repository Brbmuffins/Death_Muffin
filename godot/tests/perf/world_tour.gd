extends SceneTree
## Rendered world tour of the real game (DmGame, all seals open): shots per area at the play camera (centre + two quarter points) and
## zoomed out, to spot unrendered gaps. Needs a renderer (xvfb + opengl3).
## godot --rendering-driver opengl3 --path godot --script res://tests/perf/world_tour.gd -- --shots=/abs/dir [--areas=graves,warren]

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _shot(dir: String, name: String) -> void:
	for i in 8:
		await process_frame
	print("STATS %s draws=%d objs=%d prims=%d" % [name, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [dir, name])

func _run() -> void:
	var dir := _arg("shots", "/tmp/tour")
	DirAccess.make_dir_recursive_absolute(dir)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("tour%d" % (Time.get_ticks_usec() % 100000), "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 3, "warmup": false})
	game.dev_access = true
	game.nav.set_unlocked(DmContent.area_order())
	game.builder.open_all()
	var only := _arg("areas", "")
	var n := 0
	for area in DmContent.area_order():
		if only != "" and not (String(area) in only.split(",")):
			continue
		var rect: Dictionary = DmContent.area(area)["rect"]
		var x0 := float(rect["x0"]); var x1 := float(rect["x1"]); var z0 := float(rect["z0"]); var z1 := float(rect["z1"])
		var pts := [[(x0 + x1) / 2.0, (z0 + z1) / 2.0], [lerpf(x0, x1, 0.25), lerpf(z0, z1, 0.25)], [lerpf(x0, x1, 0.75), lerpf(z0, z1, 0.75)]]
		for i in pts.size():
			game.camera.target_zoom = 1.0
			game.camera.zoom = 1.0
			game.p["hp"] = game.player.max_hp()
			game.actions.teleport_to(pts[i][0], pts[i][1])
			await _shot(dir, "%02d_%s_%d" % [n, area, i])
		game.camera.target_zoom = float(game.camera.cfg.zoomMax)
		game.camera.zoom = game.camera.target_zoom
		game.actions.teleport_to(pts[0][0], pts[0][1])
		await _shot(dir, "%02d_%s_far" % [n, area])
		print("TOUR %s area=%s player=(%.1f,%.1f) in=%s" % [n, area, game.player.x, game.player.z, game.player.area])
		n += 1
	quit(0)
