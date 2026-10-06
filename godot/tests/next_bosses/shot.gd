extends SceneTree
## Screenshot probe of the Gravedigger fight in the slice (NOT a suite). Run under xvfb + the renderer lock:
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_bosses/shot.gd -- --out=/some/dir
## Summons the King at his grave, stands the hero in the arena and saves a picture when the Sweep / Burial telegraphs are up, and in phase 3.

var out := ""


func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _shot(name_: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_viewport().get_texture().get_image()
	if img != null and out != "":
		img.save_png("%s/%s.png" % [out, name_])


func _until(cond: Callable, limit_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < limit_s * 1000.0:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _run() -> void:
	out = _arg("out", "")
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("shot%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"hud": true, "waves": false})
	var hb := g.local_body()
	hb.teleport(Vector3(-14.0, 0.0, -28.0))
	g.camera.snap(hb.position)
	await _until(func() -> bool: return g.area_id == "graves", 3.0)
	g.rewards.members[int(c.data.get("id", 0))].prog.add_shards(10)
	print("summon: ", g.bosses.try_summon(g.session.get_my_id(), "gravedigger"))
	var b := g.bosses.active_boss()
	hb.teleport(Vector3(-14.0, 0.0, -25.0))
	await _until(func() -> bool: return b.brain.pending.any(func(p) -> bool: return p.kind == "sweep"), 8.0)
	await _until(func() -> bool: return b.brain.pending.any(func(p) -> bool: return p.kind == "sweep") and b.brain.pending[0].at - b.world.t < 0.5, 2.0)
	await _shot("sweep")
	hb.heal(1e6)
	await _until(func() -> bool: return b.brain.pending.any(func(p) -> bool: return p.kind == "bury"), 8.0)
	await create_timer(0.8).timeout
	await _shot("bury")
	hb.heal(1e6)
	b.take_damage(b.hp - b.max_hp * 0.29, hb)
	await create_timer(1.5).timeout
	hb.heal(1e6)
	await _shot("phase3")
	print("shots in ", out)
	quit(0)
