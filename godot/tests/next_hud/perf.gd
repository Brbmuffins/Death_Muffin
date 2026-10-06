extends SceneTree
## Slice HUD cost probe (NOT a pass/fail suite; run-all-tests only picks up run.gd): headless frame cost with 25 chasing robbers and the hero
## casting, for each HUD mode.   godot --headless --path godot --script res://tests/next_hud/perf.gd -- --hud=real|minimal|none [--rites=needle] [--enemies=N]
## Prints boot time, the first-combat frames (hotbar cast + first damage numbers + target frame) and the steady script+physics ms/frame.

func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _run() -> void:
	var mode := _arg("hud", "real")
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("pf%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var character: Dictionary = (await api.load_or_create_character(2)).data
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	var t0 := Time.get_ticks_msec()
	await g.start(character, api, {"dressing": false, "persist": false, "waves": false, "hud": true if mode == "real" else ("minimal" if mode == "minimal" else false)})
	print("PERF[%s] boot %d ms (hud+panels warm %d ms)" % [mode, Time.get_ticks_msec() - t0, g.ui.warm_ms if g.ui != null else 0])
	var b := g.local_body()
	b.teleport(Vector3(0, 0, -16))
	await physics_frame
	var heroes := [b]
	for i in int(_arg("enemies", "25")):
		g.director.spawn("robber", Vector3(sin(i * 0.5) * 11.0, 0.0, -16.0 + cos(i * 0.5) * 11.0), heroes)
	for i in 150:
		await physics_frame
	var caster := b.get_node("Rites") as DmRiteCaster
	# first-combat frames: first casts, first numbers, target frame, minimap with 25 dots
	var first: Array = []
	for i in 12:
		b.heal(1e6)
		caster.p["resource"]["value"] = 100.0
		var foe: DmEnemy = null
		for e in g.director.enemies.values():
			if is_instance_valid(e) and (foe == null or e.position.distance_to(b.position) < foe.position.distance_to(b.position)):
				foe = e
		if foe != null:
			caster.request_cast("bone_needle" if i % 2 == 0 or _arg("rites", "") == "needle" else "miasma", foe.global_position, DmWaveDirector.id_of(foe))
		var t := Time.get_ticks_usec()
		await process_frame
		first.append((Time.get_ticks_usec() - t) / 1000.0)
	print("PERF[%s] first-combat frames ms: %s" % [mode, ", ".join(first.map(func(v: float) -> String: return "%.1f" % v))])
	var proc := 0.0
	var phys := 0.0
	var worst := 0.0
	var n := 300
	for i in n:
		await physics_frame
		b.heal(1e6)
		if i % 20 == 0:
			caster.p["resource"]["value"] = 100.0
			caster.request_cast("bone_needle" if i % 40 == 0 or _arg("rites", "") == "needle" else "miasma", b.position + Vector3(0, 0, -3), -1)
		var pr := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var ph := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		proc += pr
		phys += ph
		worst = maxf(worst, pr + ph)
	if g.ui != null:
		var tv := 0
		var ta := 0
		for i in 40:
			var t1 := Time.get_ticks_usec()
			var v := g.ui.merged_vm()
			var t2 := Time.get_ticks_usec()
			g.ui.hud.apply(v)
			ta += Time.get_ticks_usec() - t2
			tv += t2 - t1
		print("PERF[%s] merged_vm %.2f ms, hud.apply %.2f ms (each, mean of 40)" % [mode, tv / 40000.0, ta / 40000.0])
	print("PERF[%s] 25 robbers + casting: process %.2f + physics %.2f = %.2f ms/frame (worst %.2f)" % [mode, proc / n, phys / n, (proc + phys) / n, worst])
	await g.leave()
	g.queue_free()
	await process_frame
	quit(0)
