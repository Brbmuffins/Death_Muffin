extends SceneTree
## Relative GPU cost of rendering features (rendered, xvfb): the hero fights a Graves wave; average frame time is measured with each
## feature turned off in turn. Software GL numbers are only meaningful relative to each other.
## xvfb-run godot --rendering-driver opengl3 --path godot --script res://tests/perf/render_cost.gd -- [--frames=40]

var game: DmGame

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _measure(n: int) -> Array:
	var rites: Array = DmLoadout.assignable_rites(game.kit)
	var k := 0
	for i in 5:
		await process_frame
	var t := Time.get_ticks_usec()
	var draws := 0
	for i in n:
		game.p["hp"] = game.player.max_hp()
		game.p["resource"]["value"] = 100.0
		for e in game.sim.enemies.values():
			var tgt := {"x": e.x, "z": e.z, "enemyId": e.id}
			game.p["castUntil"] = 0.0
			game.do_cast(String(rites[k % rites.size()]), tgt, game.now_ms)
			game.do_cast(game.primary, tgt, game.now_ms)
			k += 1
			break
		await process_frame
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	return [(Time.get_ticks_usec() - t) / 1000.0 / n, draws / n]

func _run() -> void:
	var n := int(_arg("frames", "40"))
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("rc%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	game = DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 9, "warmup": true})
	game.character["level"] = 30
	game.refresh_stats()
	game.dev_access = true
	game.abilities.dev = true
	game.nav.set_unlocked(DmContent.area_order())
	game.actions.teleport_to(0.0, -16.0)
	game.sim.waveTimers["graves"] = 0.0
	for i in 40:
		await process_frame
	var b := game.builder
	var env: Environment = b.env
	var vp := root.get_viewport()
	var base: Array = await _measure(n)
	print("RCOST baseline              %7.1f ms  draws=%d  enemies=%d" % [base[0], base[1], game.sim.enemies.size()])
	var prop_casters: Array = []
	for gi in b.find_children("*", "GeometryInstance3D", true, false):
		if (gi as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			prop_casters.append(gi)
	print("RCOST world shadow casters=%d" % prop_casters.size())
	var variants := [
		["shadow distance 45 -> 25", func(on): b.moon.directional_shadow_max_distance = 25.0 if on else 45.0],
		["world props cast no shadow", func(on):
			for pc in prop_casters:
				(pc as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON],
		["both", func(on):
			b.moon.directional_shadow_max_distance = 25.0 if on else 45.0
			for pc in prop_casters:
				(pc as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON],
		["moon shadows off", func(on): b.moon.shadow_enabled = not on],
		["baseline again", func(on): pass],
		["prop lights 8 -> 3", func(on): b.light_near = 3 if on else DmWorldBuilder.LIGHT_NEAR],
		["prop lights off", func(on): b.light_near = 0 if on else DmWorldBuilder.LIGHT_NEAR],
		["glow off", func(on): env.glow_enabled = not on],
		["fog off", func(on): env.fog_enabled = not on],
		["binbun off", func(on): game.vfx.binbun.enabled = not on],
		["render scale 0.67", func(on):
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			vp.scaling_3d_scale = 0.67 if on else 1.0],
	]
	for v in variants:
		v[1].call(true)
		var m: Array = await _measure(n)
		v[1].call(false)
		print("RCOST %-22s %7.1f ms  (%+.0f%%) draws=%d" % [v[0], m[0], (m[0] / base[0] - 1.0) * 100.0, m[1]])
	quit(0)
