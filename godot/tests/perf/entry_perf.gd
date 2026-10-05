extends SceneTree
## Area entry with the full UI: settle in the Chapterhouse, then step into a hunting ground; every frame over 25 ms for the next 6 s is
## printed with DmGame.tick sections, sim sections, events and the time outside the game tick.
## godot --headless --path godot --script res://tests/perf/entry_perf.gd -- [--area=graves]

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def

func _run() -> void:
	var area := _arg("area", "graves")
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("ep%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 5, "warmup": _arg("warmup", "1") == "1"})
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	game.ui = ui
	game.nav.set_unlocked(DmContent.area_order())
	for i in 180:
		await process_frame
	var pre := _arg("pre", "")
	if pre == "enter":
		game._enter_area(area)
		for i in 10:
			await process_frame
		game._enter_area("chapterhouse")
		for i in 10:
			await process_frame
	elif pre == "enemies":
		for rr in DmSimData.AREAS[area]["enemies"]:
			game.sim.spawn_enemy(String(rr["id"]), "chapterhouse", game.player.x + randf_range(-3, 3), game.player.z - 3.0, false, true, "")
		game.sim.spawn_enemy(String(DmSimData.AREAS[area]["enemies"][0]["id"]), "chapterhouse", game.player.x, game.player.z - 4.0, true, true, "")
		for i in 15:
			await process_frame
		game.sim.enemies.clear()
		for i in 20:
			await process_frame
	if pre == "wavefx":
		game.handle_event({"t": "wave", "area": "chapterhouse", "count": 9, "x": game.player.x + 2.0, "z": game.player.z - 2.0})
		game.area_id = "chapterhouse"
		for i in 20:
			await process_frame
	elif pre == "nowave":
		game.sim.waveTimers[area] = 999.0
	var off := _arg("off", "")
	var node_off: Node = null
	match off:
		"ui": node_off = ui
		"audio": node_off = root.get_node("AudioDirector")
		"vfx": node_off = root.get_node("Vfx")
	if node_off != null:
		node_off.process_mode = Node.PROCESS_MODE_DISABLED
	game.prof_on = true
	game.sim.prof_on = true
	var rect: Dictionary = DmContent.area(area)["rect"]
	var hide := _arg("hide", "")
	var hidden: Node3D = null
	match hide:
		"views": hidden = game.views
		"vfx": hidden = root.get_node("Vfx")
		"world": hidden = game.builder
		"prims": hidden = game.vfx.prims.group
	if hidden != null:
		hidden.visible = false
	var before := {}
	for ch in game.vfx.prims.group.get_children():
		before[ch.get_instance_id()] = true
	print("ENTRY_MARK_BEGIN")
	game.actions.teleport_to((float(rect["x0"]) + float(rect["x1"])) / 2.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	while (Time.get_ticks_usec() - t0) / 1e6 < 6.0:
		game.p["hp"] = game.player.max_hp()
		var g0: Dictionary = game.prof.duplicate()
		var s0: Dictionary = game.sim.prof.duplicate()
		var e0: Dictionary = game.ev_prof.duplicate()
		var fs := Time.get_ticks_usec()
		await process_frame
		var ms := (Time.get_ticks_usec() - fs) / 1000.0
		worst = maxf(worst, ms)
		if (fs - t0) < 200000:
			var ids0 := {}
			for l in game.vfx.binbun._live:
				ids0[l.id] = true
			print("ENTRY early binbun: ", ids0.keys())
		if hidden != null and (Time.get_ticks_usec() - t0) / 1e6 > 2.0 and not hidden.visible:
			hidden.visible = true
			print("ENTRY unhide %s at %.2fs" % [hide, (Time.get_ticks_usec() - t0) / 1e6])
		if ms < float(_arg("min", "25")):
			continue
		var secs := {}
		var tick := 0.0
		for k in game.prof:
			var d := (int(game.prof[k]) - int(g0.get(k, 0))) / 1000.0
			secs["g." + k] = d
			tick += d
		for k in game.sim.prof:
			secs["s." + k] = (int(game.sim.prof[k]) - int(s0.get(k, 0))) / 1000.0
		for k in game.ev_prof:
			secs[k] = (int(game.ev_prof[k]) - int(e0.get(k, 0))) / 1000.0
		var top: Array = secs.keys()
		top.sort_custom(func(a, b): return secs[a] > secs[b])
		var line := "ENTRY t=%.2fs frame=%.1fms outside-tick=%.1fms enemies=%d:" % [(fs - t0) / 1e6, ms, ms - tick, game.sim.enemies.size()]
		for k in top.slice(0, 7):
			if secs[k] >= 0.5:
				line += " %s=%.1f" % [k, secs[k]]
		print(line)
	print("ENTRY_MARK_END")
	var live_ids := {}
	for l in game.vfx.binbun._live:
		live_ids[l.id] = true
	print("ENTRY binbun live: ", live_ids.keys())
	for ch in game.vfx.prims.group.get_children():
		if not before.has(ch.get_instance_id()):
			var info: String = ch.get_class()
			if ch is MultiMeshInstance3D:
				var mmi := ch as MultiMeshInstance3D
				var mat: Material = mmi.material_override
				info += " mesh=%s mat=%s tex=%s" % [mmi.multimesh.mesh.get_class() if mmi.multimesh and mmi.multimesh.mesh else "-", mat.get_class() if mat else "-", (mat as ShaderMaterial).get_shader_parameter("tex").resource_path if mat is ShaderMaterial and (mat as ShaderMaterial).get_shader_parameter("tex") != null else "-"]
				if mat is ShaderMaterial:
					info += " shader=%s" % String((mat as ShaderMaterial).shader.code).substr(0, 80).replace("\n", " ")
			elif ch is MeshInstance3D:
				info += " mesh=%s" % ((ch as MeshInstance3D).mesh.get_class() if (ch as MeshInstance3D).mesh else "-")
			print("ENTRY new-prims-node %s %s" % [ch.name, info])
	print("ENTRY worst=%.1fms" % worst)
	if _arg("after", "") != "":
		# a second area (first visit) after the first one
		var r2: Dictionary = DmContent.area(_arg("after", ""))["rect"]
		game.actions.teleport_to((float(r2["x0"]) + float(r2["x1"])) / 2.0, (float(r2["z0"]) + float(r2["z1"])) / 2.0)
		var t1 := Time.get_ticks_usec()
		while (Time.get_ticks_usec() - t1) / 1e6 < 6.0:
			var f0 := Time.get_ticks_usec()
			await process_frame
			var m2 := (Time.get_ticks_usec() - f0) / 1000.0
			if m2 >= float(_arg("min", "25")):
				print("ENTRY2 t=%.2fs frame=%.1fms" % [(f0 - t1) / 1e6, m2])
	quit(0)
