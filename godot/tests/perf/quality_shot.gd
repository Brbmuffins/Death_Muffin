extends SceneTree
## Rendered ground-marking shots for the graphics quality pass: chapterhouse + graves sigils at the play camera, under a chosen preset.
## Needs a renderer (xvfb + opengl3); VPS = llvmpipe, so draw stats / sharpness are meaningful, timings only relative.
## godot --rendering-driver opengl3 --path godot --script res://tests/perf/quality_shot.gd -- --shots=/abs/dir [--graphics=high] [--gscale=0.6] [--tag=before]
## --gscale forces the resolution governor's worst case (clamped to the preset floor when the floor exists), like a GPU that cannot keep up.

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
	var vp := root.get_viewport()
	var t0 := Time.get_ticks_usec()
	for i in 30:
		await process_frame
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 30.0
	print("STATS %s frame=%.1fms draws=%d prims=%d scale=%.2f msaa=%d aniso=%d" % [name, ms,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME), vp.scaling_3d_scale, vp.msaa_3d, vp.anisotropic_filtering_level])
	vp.get_texture().get_image().save_png("%s/%s.png" % [dir, name])

func _run() -> void:
	var dir := _arg("shots", "/tmp/qshots")
	var tag := _arg("tag", "x")
	DirAccess.make_dir_recursive_absolute(dir)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("qs%d" % (Time.get_ticks_usec() % 100000), "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 3, "warmup": false})
	game.dev_access = true
	game.nav.set_unlocked(DmContent.area_order())
	game.builder.open_all()
	var g := _arg("graphics", "")
	if g != "":
		game.settings_store.update({"graphics": g})
	var gs := float(_arg("gscale", "1.0"))
	if gs < 1.0:
		game.governor.scale = maxf(gs, float(game.governor.get("floor_scale")) if game.governor.get("floor_scale") != null else 0.0)
		game._apply_render_scale()
	for spot in [["chapterhouse", 0.0, 17.5], ["graves", 0.0, -19.5]]:
		game.camera.target_zoom = 1.0
		game.camera.zoom = 1.0
		game.actions.teleport_to(spot[1], spot[2])
		await _shot(dir, "%s_%s_%s" % [tag, spot[0], g if g != "" else "default"])
	quit(0)
