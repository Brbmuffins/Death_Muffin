extends SceneTree
## Screenshot probe of the Abbess / Congregation / Prelate fights in the slice (NOT a suite). Run under xvfb + the renderer lock:
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_bosses/shot_cathedral.gd -- --boss=abbess --out=/some/dir
## Opens the world (every seal, as the areas track will), summons the boss at its site, stands the hero in the arena and saves a picture when its
## first telegraphs are up and in phase 3. Prints the slowest frame in the 3 frames after the first sighting of each event kind (first-draw hitches).

var out := ""
var boss_id := "abbess"
var _frame_ms := 0.0
var _last := 0
var _first: Dictionary = {}
var _watch: Array = []   ## [kind, frames left, worst ms]


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
		img.save_png("%s/%s_%s.png" % [out, boss_id, name_])


func _frames() -> void:
	var now := Time.get_ticks_usec()
	var ms := (now - _last) / 1000.0
	_last = now
	for w in _watch:
		w[2] = maxf(w[2], ms)
		w[1] -= 1
	for i in range(_watch.size() - 1, -1, -1):
		if _watch[i][1] <= 0:
			print("first-draw %s: worst frame %.0f ms in the 3 frames after its first event" % [_watch[i][0], _watch[i][2]])
			_watch.remove_at(i)


func _until(cond: Callable, limit_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < limit_s * 1000.0:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _run() -> void:
	out = _arg("out", "")
	boss_id = _arg("boss", "abbess")
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	var bd: Dictionary = DmContent.boss(boss_id)
	var arena := Vector3(float(bd["arena"]["x"]), 0.0, float(bd["arena"]["z"]))
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("shot%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"hud": true, "waves": false})
	g.world.builder.open_all()
	var hb := g.local_body()
	hb.p["stats"]["maxHp"] = 1.0e5
	hb.heal(1.0e6)
	var site := g.bosses.site_pos(boss_id)
	hb.teleport(site + Vector3(0.0, 0.0, 2.0))
	g.camera.snap(hb.position)
	await _until(func() -> bool: return g.area_id == String(bd["area"]), 4.0)
	await create_timer(1.0).timeout
	if _arg("probe", "") != "":   # --probe=1: the cost of the FIRST draw of every boss event kind (after the load-time warm), in ms
		var at := hb.position
		process_frame.connect(_frames)
		_last = Time.get_ticks_usec()
		for k in ["sweep", "bury", "awaken", "phase", "summon", "rain", "lance", "chorus", "grasp", "hymn", "toll", "slam", "maul", "communion", "nicheBreak", "defeated"]:
			var ev := {"t": "boss", "kind": k, "boss": boss_id, "x": at.x + 2.0, "z": at.z, "phase": 2, "ms": 1200.0, "r": 4.0, "dir": 0.3, "targets": [[at.x + 1.0, at.z + 1.0], [at.x - 2.0, at.z + 2.0]], "players": [], "killer": "1"}
			var t0 := Time.get_ticks_usec()
			_watch.append(["probe-" + String(k), 3, 0.0])
			g.bosses.fx.play(ev)
			print("probe first %-10s %.1f ms" % [k, (Time.get_ticks_usec() - t0) / 1000.0])
			await process_frame
			await process_frame
			await process_frame
			await process_frame
		for def_id in ["risen", "penitent", "wraith", "risen"]:
			_watch.append(["spawn-" + def_id, 3, 0.0])
			var t2 := Time.get_ticks_usec()
			g.director.spawn(def_id, at + Vector3(4.0, 0.0, 0.0), [hb], false, {}, {"area": String(bd["area"])})
			print("spawn %s cpu %.1f ms" % [def_id, (Time.get_ticks_usec() - t2) / 1000.0])
			await process_frame
			await process_frame
			await process_frame
			await process_frame
		for k in ["toll", "lance", "hymn"]:   # a second draw of the same: the steady cost
			var t1 := Time.get_ticks_usec()
			g.bosses.fx.play({"t": "boss", "kind": k, "boss": boss_id, "x": at.x, "z": at.z, "phase": 2, "ms": 1200.0, "r": 4.0, "dir": 0.3, "targets": [], "players": []})
			print("probe again %-10s %.1f ms" % [k, (Time.get_ticks_usec() - t1) / 1000.0])
		quit(0)
		return
	var m: DmRewardsMember = g.rewards.members[int(c.data.get("id", 0))]
	m.prog.mode = "local"
	m.prog.local["shards"] = 20
	g.bosses.brain_event.connect(func(ev: Dictionary, _b: DmBoss) -> void:
		var key := "%s/p%s" % [ev.get("kind", ""), ev.get("phase", 1)]
		if ev["t"] == "boss" and not _first.has(key):
			_first[key] = true
			_watch.append([key, 3, 0.0]))
	process_frame.connect(_frames)
	_last = Time.get_ticks_usec()
	print("summon: ", g.bosses.try_summon(g.session.get_my_id(), boss_id))
	var b := g.bosses.active_boss()
	var spot := arena + Vector3(3.0, 0.0, 0.0) if boss_id != "prelate" else Vector3(2.0, 0.0, -118.0)
	hb.teleport(spot)
	g.camera.snap(hb.position)
	var kinds := {"abbess": ["chorus", "lance"], "congregation": ["hymn", "grasp"], "prelate": ["toll"]}[boss_id] as Array
	# the picture is taken when a long telegraph is half-way (the shapes are up and still unresolved)
	await _until(func() -> bool: return b.brain != null and b.brain.pending.any(func(p) -> bool: return kinds.has(p.kind) and p.at - b.world.t < 0.8), 16.0)
	hb.heal(1e6)
	await _shot("telegraph")
	await create_timer(3.0).timeout
	hb.heal(1e6)
	await _shot("fight")
	b.take_damage(b.hp - b.max_hp * 0.55, hb)   # phase 2 first, so the phase-3 change below is not the first of its kind
	await create_timer(3.0).timeout
	hb.heal(1e6)
	b.take_damage(b.hp - b.max_hp * 0.29, hb)
	await create_timer(2.0).timeout
	hb.heal(1e6)
	await _shot("phase3")
	for k in 8:
		await process_frame
	print("shots in ", out)
	quit(0)
