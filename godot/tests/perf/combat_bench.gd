extends SceneTree
## Deterministic CPU bench of the real game loop (DmGame + DmGameUi + autoloads) for idle vs heavy combat.
## Run with a fixed timestep so the sim is identical run to run; wall time per frame is what is measured:
##   godot --headless --fixed-fps 60 --path godot --script res://tests/perf/combat_bench.gd -- [--phase=idle|combat|boss] [--area=nave]
##        [--seconds=20] [--level=30] [--ablate=ui,vfx,audio,dress,backdrop] [--ui=1] [--every=1.5] [--legion=1]
## Prints BENCH (frame ms median/p95/p99/avg, entity counts, nodes) + per-section tick cost, and the process-node ablation deltas.

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

## Main-thread on-CPU time in microseconds (/proc/thread-self/schedstat): immune to the box being busy with other jobs.
func _cpu_us() -> int:
	var f := FileAccess.open("/proc/thread-self/schedstat", FileAccess.READ)
	if f == null:
		return 0
	return int(f.get_line().split(" ")[0]) / 1000

func _disable_proc(n: Node) -> void:
	n.set_process(false)
	for c in n.get_children():
		_disable_proc(c)

func _run() -> void:
	var area := _arg("area", "nave")
	var secs := float(_arg("seconds", "20"))
	var phase := _arg("phase", "combat")
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("cb%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 7, "warmup": true})
	if _arg("graphics", "") != "":
		game.settings_store.update({"graphics": _arg("graphics", "")})
	if _arg("ui", "1") == "1":
		var ui := DmGameUi.new()
		game.add_child(ui)
		ui.setup(game)
		game.ui = ui
		await ui.warm()
	game.character["level"] = int(_arg("level", "30"))
	game.refresh_stats()
	game.dev_access = true
	game.prog.dev_access = true
	game.abilities.dev = true
	game.nav.set_unlocked(DmContent.area_order())
	var rites: Array = DmLoadout.assignable_rites(game.kit)
	var rect: Dictionary = DmContent.area(area)["rect"]
	game.player.teleport((float(rect["x0"]) + float(rect["x1"])) / 2.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	game.p["area"] = area
	for i in 30:
		await process_frame
	if phase == "idle":
		game.sim.clear_area(area)
		game.sim.waveTimers[area] = 99999.0
		game.sim.enemies.clear()
	if phase == "boss":
		var bosses := {"graves": "gravedigger", "ossuary": "abbess", "nave": "congregation", "sanctum": "prelate", "cloister": "saint", "pyre": "regent", "fen": "mire"}
		game.actions.summon_boss_normal(bosses[area])
	for ab in _arg("ablate", "").split(",", false):
		match ab:
			"ui": if game.ui != null: _disable_proc(game.ui)
			"vfx": _disable_proc(root.get_node("Vfx"))
			"audio": _disable_proc(root.get_node("AudioDirector"))
			"dress": if game.dressing != null: _disable_proc(game.dressing)
			"backdrop": for n in root.find_children("*", "", true, false):
				if n.get_script() != null and String(n.get_script().resource_path).ends_with("dm_necro_backdrop.gd"): n.set_process(false)
	game.prof_on = true
	game.ev_prof.clear()
	game.sim.prof_on = true
	if ResourceLoader.exists("res://perf_acc_tmp.gd"):
		load("res://perf_acc_tmp.gd").acc.clear()
	var every := float(_arg("every", "1.5"))
	var frames: Array = []
	var cpus: Array = []
	var cpu_last := _cpu_us()
	var peak_e := 0
	var sum_e := 0
	var sum_t := 0
	var sum_nodes := 0
	var sum_draw := 0
	var sum_phys := 0.0
	var phys_active := 0
	var sum_obj := 0
	var sum_prim := 0
	var warm := 2.0
	var t0 := Time.get_ticks_usec()
	var last := t0
	var next_wave := 0.0
	var k := 0
	var game_t := 0.0
	var frame_i := 0
	var cast_every := 8   # frames between casts: ~7.5 casts/s at 60 Hz fixed step
	while game_t < secs + warm:
		game_t += 1.0 / 60.0
		frame_i += 1
		game.p["hp"] = game.player.max_hp()
		game.p["resource"]["value"] = 100.0
		if phase != "idle":
			if game_t >= next_wave:
				DmSimDirector.spawn_wave(game.sim, area)
				next_wave += every
			if _arg("legion", "1") == "1" and frame_i % 15 == 0 and game.sim.thralls.size() < 12:
				var m: Dictionary = game.discipline["mods"]
				var ang := float(frame_i)
				game.send_intent({"t": "exhume", "by": game.self_id, "x": game.player.x + sin(ang) * 2.0, "z": game.player.z + cos(ang) * 2.0, "r": 0.8, "kind": m["thrallKind"], "cap": 12, "hp": game.p["stats"]["thrallHp"] * 3.0, "damage": game.p["stats"]["thrallDamage"], "attackSpeedMult": m["thrallAttackSpeedMult"], "bond": true})
			if frame_i % cast_every == 0:
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
		await process_frame
		var now := Time.get_ticks_usec()
		var cpu_now := _cpu_us()
		if game_t > warm:
			frames.append((now - last) / 1000.0)
			cpus.append((cpu_now - cpu_last) / 1000.0)
			peak_e = maxi(peak_e, game.sim.enemies.size())
			sum_e += game.sim.enemies.size()
			sum_t += game.sim.thralls.size()
			sum_nodes += int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
			sum_phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			phys_active = maxi(phys_active, int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)))
			sum_draw += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			sum_obj += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
			sum_prim += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		else:
			game.prof.clear()
			game.sim.prof.clear()
		last = now
		cpu_last = cpu_now
	if _arg("census", "0") == "1":
		_census(game)
	if _arg("probe", "0") == "1" and DisplayServer.get_name() != "headless":
		await _probe(game)
	var n := frames.size()
	var sorted := frames.duplicate()
	sorted.sort()
	var cs := cpus.duplicate()
	cs.sort()
	var csum := 0.0
	for f in cpus:
		csum += f
	var sum := 0.0
	for f in frames:
		sum += f
	print("BENCH cpu(main thread) median=%.2f p95=%.2f p99=%.2f avg=%.2f" % [cs[n / 2], cs[int(n * 0.95)], cs[int(n * 0.99)], csum / n])
	print("BENCH phase=%s area=%s ablate=%s frames=%d median=%.2f p95=%.2f p99=%.2f avg=%.2f worst=%.1f | enemies avg=%.1f peak=%d thralls avg=%.1f nodes avg=%d" % [phase, area, _arg("ablate", "-"), n, sorted[n / 2], sorted[int(n * 0.95)], sorted[int(n * 0.99)], sum / n, sorted[-1], float(sum_e) / n, peak_e, float(sum_t) / n, sum_nodes / n])
	var keys: Array = game.prof.keys()
	keys.sort_custom(func(a, b): return game.prof[a] > game.prof[b])
	var tot := 0
	for key in keys:
		tot += int(game.prof[key])
	if sum_draw > 0:
		print("BENCH render draw_calls=%d objects=%d prims=%dk (avg per frame, rendered only)" % [sum_draw / n, sum_obj / n, sum_prim / n / 1000])
	print("BENCH physics step cost avg=%.3f ms/frame, active 3D bodies max=%d, physics_ticks_per_second=%d" % [sum_phys / n, phys_active, Engine.physics_ticks_per_second])
	print("BENCH tick total %.2f ms/frame" % [tot / 1000.0 / n])
	for key in keys:
		print("BENCH   %-18s %.3f" % [key, game.prof[key] / 1000.0 / n])
	var sk: Array = game.sim.prof.keys()
	sk.sort_custom(func(a, b): return game.sim.prof[a] > game.sim.prof[b])
	for key in sk.slice(0, 8):
		print("BENCH   sim.%-14s %.3f" % [key, game.sim.prof[key] / 1000.0 / n])
	var evk: Array = game.ev_prof.keys()
	evk.sort_custom(func(a, b): return game.ev_prof[a] > game.ev_prof[b])
	for key in evk.slice(0, 8):
		print("BENCH   event.%-16s %.3f ms/frame" % [key, game.ev_prof[key] / 1000.0 / n])
	if ResourceLoader.exists("res://perf_acc_tmp.gd"):   # optional per-node _process accounting (temporary instrumentation, never committed)
		var pa: GDScript = load("res://perf_acc_tmp.gd")
		var ak: Array = pa.acc.keys()
		ak.sort_custom(func(a, b): return pa.acc[a] > pa.acc[b])
		for key in ak:
			print("BENCH   node %-44s self %.3f ms/frame (%d calls/frame %.1f)" % [key, pa.acc[key] / 1000.0 / n, pa.cnt[key], float(pa.cnt[key]) / n])
	quit(0)


## Visible 3D render items by owning subtree: instances, draw surfaces (each surface of each visible mesh = at least one draw), shadow casters.
func _census(game: Node) -> void:
	var inst := {}
	var surf := {}
	var shad := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is GeometryInstance3D) or not (n as GeometryInstance3D).is_visible_in_tree():
			continue
		var gi := n as GeometryInstance3D
		var s := 1
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			s = (gi as MeshInstance3D).mesh.get_surface_count()
		elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
			var mm: MultiMesh = (gi as MultiMeshInstance3D).multimesh
			s = mm.mesh.get_surface_count() if mm.mesh != null else 1
			if mm.visible_instance_count == 0:
				continue
		elif gi is GPUParticles3D:
			s = (gi as GPUParticles3D).draw_passes
		# owner key: the first two named ancestors below the root
		var path := String(root.get_path_to(gi)).split("/")
		var key := "/".join(path.slice(0, mini(path.size() - 1, 3))) if path.size() > 1 else path[0]
		var cls := gi.get_class()
		key = "%s [%s]" % [key, cls]
		inst[key] = int(inst.get(key, 0)) + 1
		surf[key] = int(surf.get(key, 0)) + s
		if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			shad[key] = int(shad.get(key, 0)) + 1
	var keys: Array = surf.keys()
	keys.sort_custom(func(a, b): return surf[a] > surf[b])
	var ti := 0
	var ts := 0
	for k in keys:
		ti += inst[k]
		ts += surf[k]
	print("BENCH   census total instances=%d surfaces=%d" % [ti, ts])
	for k in keys.slice(0, 14):
		print("BENCH   census %-70s inst=%d surf=%d shadow=%d" % [k, inst[k], surf[k], int(shad.get(k, 0))])


## Rendered only: draw calls / objects with each subtree hidden in turn (what each system costs the renderer in the middle of a fight).
func _probe(game: Node) -> void:
	var targets: Array = []
	for c in game.get_children():
		targets.append(c)
	targets.append(root.get_node("Vfx"))
	if game.builder != null:
		targets.append(game.builder)
	await process_frame
	await process_frame
	var base_d := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var base_o := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var base_p := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	print("BENCH probe base draws=%d objects=%d prims=%dk" % [base_d, base_o, base_p / 1000])
	for t in targets:
		if not (t is Node3D) and not (t is CanvasItem):
			continue
		var was: bool = t.visible
		t.visible = false
		await process_frame
		await process_frame
		var d := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var o := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		var pr := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		print("BENCH probe hide %-40s draws -%d objects -%d prims -%dk" % [t.name, base_d - d, base_o - o, (base_p - pr) / 1000])
		t.visible = was
