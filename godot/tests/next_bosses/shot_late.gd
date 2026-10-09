extends SceneTree
## Screenshot probe of the late bosses in the slice (NOT a suite). One boss per run:
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_bosses/shot_late.gd -- --boss=saint --out=/some/dir
## Summons the boss at its altar, stands the hero in the arena and saves a picture while the signature telegraph is up (saint: Rot Rain, regent: Conflagration,
## mire: Surface ring) and again after the pools / eruption.

var out := ""
var boss_id := "saint"
var _hero: DmHeroBody


## The picture is about the telegraph, not the hero's death: stay unkillable (the progression resets the stats now and then).
func _god() -> void:
	if _hero != null and float(_hero.p["stats"]["maxHp"]) < 9.0e8:
		_hero.p["stats"]["maxHp"] = 1.0e9
		_hero.p["hp"] = 1.0e9
		_hero._mirror_from_state()


func _wait(secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < secs * 1000.0:
		_god()
		await process_frame


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


func _until(cond: Callable, limit_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < limit_s * 1000.0:
		_god()
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _run() -> void:
	out = _arg("out", "")
	boss_id = _arg("boss", "saint")
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
	var bd: Dictionary = DmContent.boss(boss_id)
	var arena := Vector3(float(bd["arena"]["x"]), 0.0, float(bd["arena"]["z"]))
	var hb := g.local_body()
	var site: Vector3 = g.bosses.site_pos(boss_id)
	hb.teleport(site + Vector3(0.0, 0.0, 2.0))
	g.camera.snap(hb.position)
	await _until(func() -> bool: return g.area_id == String(bd["area"]), 3.0)
	g.rewards.members[int(c.data.get("id", 0))].prog.add_shards(20)
	print("summon: ", g.bosses.try_summon(g.session.get_my_id(), boss_id))
	var b := g.bosses.active_boss()
	_hero = hb
	var kind: String = {"saint": "rotRain", "regent": "conflagration", "mire": "surface"}[boss_id]
	hb.teleport(arena + Vector3(2.0, 0.0, 6.0))
	g.camera.snap(hb.position)
	if boss_id == "regent":
		b.brain._confl_cd = 0.0
	elif boss_id == "mire":
		b.brain._surface_cd = 0.0
	elif boss_id == "saint":
		b.brain._rain_cd = 0.0
	await _until(func() -> bool: return b.brain.pending.any(func(p) -> bool: return p.kind == kind), 8.0)
	await _wait(0.8)
	await _shot("telegraph")
	await _wait(2.4)
	await _shot("after")
	print("shots in ", out)
	quit(0)
