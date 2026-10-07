extends SceneTree
## Rendered lighting QA: per area, 3 shots at the play camera (centre + two quarter points) under a graphics preset, with the frame time of each.
## Needs a renderer (use lighting_shot.sh). VPS = llvmpipe, so timings are only relative.
## args after `--`: --shots=/abs/dir  --tag=before  --graphics=high  --areas=graves,nave  --brightness=1.0

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _shot(dir: String, name: String) -> void:
	for i in 12:
		await process_frame
	var t0 := Time.get_ticks_usec()
	for i in 20:
		await process_frame
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 20.0
	print("STATS %s frame=%.1fms amb=%.2f exp=%.2f" % [name, ms, _amb(), _exp()])
	root.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])

func _run() -> void:
	var dir := _arg("shots", "/tmp/lshots")
	var tag := _arg("tag", "x")
	DirAccess.make_dir_recursive_absolute(dir)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("ls%d" % (Time.get_ticks_usec() % 100000), "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 3, "warmup": false})
	game.dev_access = true
	game.nav.set_unlocked(DmContent.area_order())
	game.builder.open_all()
	var patch := {}
	var g := _arg("graphics", "")
	if g != "":
		patch["graphics"] = g
	var b := _arg("brightness", "")
	if b != "":
		patch["brightness"] = float(b)
	if not patch.is_empty():
		game.settings_store.update(patch)
	var only := _arg("areas", "")
	for area in DmContent.area_order():
		if only != "" and not (String(area) in only.split(",")):
			continue
		if String(area) == "depths":
			# an instanced run: its rect overlaps the Coliseum, so it is entered, not walked to
			game.player.teleport(0.0, -2.0)
			game.depths.enter(1)
			for k in 30:
				await process_frame
			game.set_process(false)
			for i in 3:
				await _shot(dir, "%s_%s_%d" % [tag, area, i])
			game.set_process(true)
			game.depths.leave()
			for k in 30:
				await process_frame
			continue
		var rect: Dictionary = DmContent.area(area)["rect"]
		var x0 := float(rect["x0"]); var x1 := float(rect["x1"]); var z0 := float(rect["z0"]); var z1 := float(rect["z1"])
		var pts := [[(x0 + x1) / 2.0, (z0 + z1) / 2.0], [lerpf(x0, x1, 0.25), lerpf(z0, z1, 0.25)], [lerpf(x0, x1, 0.75), lerpf(z0, z1, 0.75)]]
		for i in pts.size():
			game.camera.target_zoom = 1.0
			game.camera.zoom = 1.0
			game.p["hp"] = game.player.max_hp()
			for attempt in 4:
				game.actions.teleport_to(pts[i][0], pts[i][1])
				for k in 6:
					await process_frame
				if String(game.player.area) == String(area):
					break
				print("RETRY %s_%d in=%s" % [area, i, game.player.area])
			game.set_process(false)   # freeze the sim so waves/enemies do not make two runs differ: the shot measures light, not content
			await _shot(dir, "%s_%s_%d" % [tag, area, i])
			game.set_process(true)
	quit(0)

func _amb() -> float:
	var we := root.find_children("*", "WorldEnvironment", true, false)
	return (we[0] as WorldEnvironment).environment.ambient_light_energy if not we.is_empty() else -1.0

func _exp() -> float:
	var we := root.find_children("*", "WorldEnvironment", true, false)
	return (we[0] as WorldEnvironment).environment.tonemap_exposure if not we.is_empty() else -1.0
