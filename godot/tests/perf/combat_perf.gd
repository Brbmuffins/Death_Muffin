extends SceneTree
## Combat CPU profile (headless dummy renderer or --rendered under xvfb): the hero stands in a hunting ground with waves + thralls and casts
## the kit on cooldown; prints frame-time stats and DmGame.tick per-section cost.
## godot --headless --path godot --script res://tests/perf/combat_perf.gd -- [--area=graves] [--seconds=20] [--level=12] [--boss=1] [--graphics=low|medium|high|ultra]

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _run() -> void:
	var area := _arg("area", "graves")
	var secs := float(_arg("seconds", "20"))
	var dbp := "user://perf_offline_db.json" if _arg("db", "0") == "1" else ""
	if dbp != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dbp))
	var mock := DmOffline.make_mock(dbp)
	var api := DmOffline.make_api(mock)
	var r := await api.register("perf%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": _arg("db", "0") == "1", "local_progress": _arg("db", "0") != "1", "seed": 7, "warmup": _arg("warmup", "1") == "1"})
	if _arg("graphics", "") != "":
		game.settings_store.update({"graphics": _arg("graphics", "")})
	if _arg("ui", "0") == "1":
		var ui := DmGameUi.new()
		game.add_child(ui)
		ui.setup(game)
		game.ui = ui
		await ui.warm()
	game.character["level"] = int(_arg("level", "12"))
	game.refresh_stats()
	game.dev_access = true
	game.prog.dev_access = true
	game.abilities.dev = true
	game.nav.set_unlocked(DmContent.area_order())
	var rites: Array = DmLoadout.assignable_rites(game.kit)
	var rect: Dictionary = DmContent.area(area)["rect"]
	game.player.teleport((float(rect["x0"]) + float(rect["x1"])) / 2.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	game.p["area"] = area
	if _arg("boss", "0") == "1":
		var bosses := {"graves": "gravedigger", "ossuary": "abbess", "nave": "congregation", "sanctum": "prelate", "cloister": "saint", "pyre": "regent", "fen": "mire"}
		game.actions.summon_boss_normal(bosses[area])
	game.prof_on = true
	var frames: Array = []
	var t0 := Time.get_ticks_usec()
	var last := t0
	var k := 0
	var warm := 3.0
	var peak_e := 0
	var peak_t := 0
	var proc_sum := 0.0
	while (Time.get_ticks_usec() - t0) / 1e6 < secs + warm:
		game.p["hp"] = game.player.max_hp()
		game.p["resource"]["value"] = 100.0
		var best: DmSimEnemy = null
		var bd := 1e9
		for e in game.sim.enemies.values():
			var d: float = DmSimMath.hypot(e.x - game.player.x, e.z - game.player.z)
			if d < bd:
				bd = d
				best = e
		if best != null:
			var tgt := {"x": best.x, "z": best.z, "enemyId": best.id}
			game.input.set_ground(tgt["x"], tgt["z"])
			game.do_cast(String(rites[k % rites.size()]), tgt, game.now_ms)
			game.do_cast(game.primary, tgt, game.now_ms)
			k += 1
		var snap: Dictionary = game.prof.duplicate()
		var ne0: int = game.sim.enemies.size()
		var fs := Time.get_ticks_usec()
		await process_frame
		var now := Time.get_ticks_usec()
		if game.sim.enemies.size() - ne0 >= 3:
			var top := ""
			for key in game.prof:
				var dv2: int = int(game.prof[key]) - int(snap.get(key, 0))
				if dv2 > 2000:
					top += "%s=%.1f " % [key, dv2 / 1000.0]
			print("SPAWN t=%.1fs +%d enemies frame=%.1fms  %s" % [(now - t0) / 1e6, game.sim.enemies.size() - ne0, (now - fs) / 1000.0, top])
		if (now - fs) / 1000.0 > 40.0:
			var worst_k := ""
			var worst_v := 0
			for key in game.prof:
				var dv: int = int(game.prof[key]) - int(snap.get(key, 0))
				if dv > worst_v:
					worst_v = dv
					worst_k = key
			print("HITCH t=%.1fs frame=%.1fms  tick-top=%s %.1fms  enemies=%d thralls=%d" % [(now - t0) / 1e6, (now - fs) / 1000.0, worst_k, worst_v / 1000.0, game.sim.enemies.size(), game.sim.thralls.size()])
		var el := (now - t0) / 1e6
		if el > warm:
			frames.append((now - last) / 1000.0)
			proc_sum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			peak_e = maxi(peak_e, game.sim.enemies.size())
			peak_t = maxi(peak_t, game.sim.thralls.size())
		else:
			game.prof.clear()
		last = now
	var n := frames.size()
	var sorted := frames.duplicate()
	sorted.sort()
	var sum := 0.0
	for f in frames:
		sum += f
	print("PERF area=%s frames=%d avg=%.2fms p50=%.2f p95=%.2f p99=%.2f worst=%.2f  peak enemies=%d thralls=%d  nodes=%d objs=%d" % [area, n, sum / n, sorted[n / 2], sorted[int(n * 0.95)], sorted[int(n * 0.99)], sorted[-1], peak_e, peak_t,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_COUNT)])
	var keys: Array = game.prof.keys()
	keys.sort_custom(func(a, b): return game.prof[a] > game.prof[b])
	var tot := 0
	for key in keys:
		tot += int(game.prof[key])
	if game.views != null:
		print("PERF views ", game.views.counts(), " ", game.views.pool_counts())
	print("PERF tick total %.2f ms/frame (process monitor avg %.2f ms)" % [tot / 1000.0 / n, proc_sum / n])
	for key in keys:
		print("  %-18s %7.3f ms/frame" % [key, game.prof[key] / 1000.0 / n])
	print("OFFLINE requests=%d route=%.1fms save=%.1fms writes=%d db_json=%dKB over %.0fs" % [mock.stat_requests, mock.stat_route_us / 1000.0, mock.stat_save_us / 1000.0, mock.stat_writes, JSON.stringify(mock.db).length() / 1024, secs])
	var ek: Array = game.ev_prof.keys()
	ek.sort_custom(func(a, b): return game.ev_prof[a] > game.ev_prof[b])
	for k2 in ek.slice(0, 30):
		print("EVPROF %-18s total=%.1fms n=%d per=%.3fms" % [k2, game.ev_prof[k2] / 1000.0, game.ev_count[k2], game.ev_prof[k2] / 1000.0 / game.ev_count[k2]])
	if game.ui != null:
		var ui = game.ui
		var parts := {"hud_state": func(): game.hud_state(), "merged_vm": func(): ui.merged_vm(), "hud.apply": func(): ui.hud.apply(ui._vm),
			"counsel.tick": func(): ui.counsel.tick(0.016, ui.counsel_busy()), "cues.tick": func(): ui.cues.tick(0.016),
			"guidance": func(): ui._tick_guidance(0.016), "pa.process": func(): ui.pa.process(0.016)}
		parts["ev.codex"] = func(): game.emit_game_event("codex", {"kind": "dead", "id": "robber"})
		parts["ev.enemy_spawned"] = func(): game.emit_game_event("enemy_spawned", {"def": "robber", "elite": false, "near": true, "area_safe": false})
		var h = ui.hud
		var vm: Dictionary = ui._vm
		for nm in ["_apply_flags", "_apply_vitals", "_apply_slots", "_refresh_spell_tip", "_apply_souls_thralls", "_apply_economy", "_apply_upgrades",
				"_apply_left_readouts", "_apply_target_boss", "_apply_map_column", "_apply_misc", "_update_toast_top"]:
			var argc: int = 0
			for m in h.get_method_list():
				if m["name"] == nm:
					argc = m["args"].size()
			parts["hud." + nm] = (func(n2: String, a2: int): h.call(n2, vm) if a2 > 0 else h.call(n2)).bind(nm, argc)
		for part in parts:
			var t := Time.get_ticks_usec()
			for i in 200:
				parts[part].call()
			print("UIPART %-14s %.3f ms/call" % [part, (Time.get_ticks_usec() - t) / 1000.0 / 200.0])
	game.queue_free()
	await process_frame
	quit(0)
