extends SceneTree
## Relative render cost of each Binbun effect (rendered, xvfb): the real game camera over the Graves, the effect played at the hero's feet,
## average frame time vs an empty baseline. Also reports particle amounts and depth/screen-texture use per effect.
## xvfb-run godot --rendering-driver opengl3 --path godot --script res://tests/perf/fx_cost.gd -- [--frames=12]

var game: DmGame

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _avg(n: int) -> float:
	await process_frame
	await process_frame
	var t := Time.get_ticks_usec()
	for i in n:
		await process_frame
	return (Time.get_ticks_usec() - t) / 1000.0 / n

func _run() -> void:
	var n := int(_arg("frames", "12"))
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("fc%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	game = DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 9, "warmup": true})
	game.actions.teleport_to(0.0, 18.0)   # Chapterhouse: no waves
	for i in 30:
		await process_frame
	var bb: DmFxBinbun = game.vfx.binbun
	var ids: Array = DmFxData.data().get("effects", {}).keys()
	if _arg("ids", "") != "":
		ids = Array(_arg("ids", "").split(","))
	var shot := _arg("shot", "")
	var base := await _avg(n)
	print("FXCOST baseline %.1f ms" % base)
	var rows: Array = []
	for id in ids:
		var h = game.vfx.play(String(id), Vector3(game.player.x, 0.0, game.player.z), {"duration": 30.0, "once": false})
		var ms := await _avg(n)
		if shot != "":
			root.get_viewport().get_texture().get_image().save_png("%s_%s.png" % [shot, id])
		var parts := 0
		var depth := false
		var screen := false
		for l in bb._live:
			if l.inst != null and not l.dead:
				for p in l.inst.particles:
					parts += int((p as GPUParticles3D).amount)
				for m in l.inst.mats:
					var code := String((m as ShaderMaterial).shader.code) if (m as ShaderMaterial).shader != null else ""
					depth = depth or code.contains("depth_texture") or code.contains("DEPTH_TEXTURE")
					screen = screen or code.contains("screen_texture") or code.contains("SCREEN_TEXTURE")
		rows.append([String(id), ms - base, parts, depth, screen])
		game.vfx.stop(h)
		bb.clear()
		await _avg(2)
	rows.sort_custom(func(a, b): return a[1] > b[1])
	for row in rows:
		print("FXCOST %-28s +%6.1f ms  particles=%5d  depth=%s screen=%s" % row)
	quit(0)
