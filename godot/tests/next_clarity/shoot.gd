extends SceneTree
## Rendered clarity shots of the rebuild (NOT pass/fail; run under the renderer lock + xvfb):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_clarity/shoot.gd -- --out=/some/dir --class=1 --tag=before
## One process: a fight (enemies, corpses, a legion, low essence, a few cooldowns) shot twice, before and just after three casts.

func _initialize() -> void:
	_run.call_deferred()


func _arg(k: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % k):
			return a.substr(k.length() + 3)
	return d


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("cl%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(int(_arg("class", "1")))
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"persist": false, "waves": _arg("mode", "") != "bar"})
	var b := g.local_body()
	b.teleport(Vector3(0, 0, -16))
	b.p["god"] = true
	var caster := b.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 30.0
	await _frames(240)
	if _arg("mode", "") == "bar":
		await _bar(g, b, caster)
		return
	var heroes := [b]
	for i in 8:
		g.director.spawn("robber", Vector3(sin(i * 0.8) * 8.0, 0.0, -16.0 + cos(i * 0.8) * 8.0), heroes)
	await _frames(120)
	for i in 5:
		g.corpses.add_corpse(-3.0 + i * 1.6, -13.0 - (i % 2) * 1.2, "resonant" if i == 2 else "normal", "robber", false, 0.0, 1.0, g.area_of(1))
	var th := b.get_node("Thralls") as DmThrallHost
	var spec := {"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
	for k in 4:
		th._spawn(DmThralls.raise_stats(spec, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, k + 1, 0.0), b.global_position + Vector3(-2.5 + k * 1.6, 0, 2.0), 0.0)
	await _frames(100)
	for t in th.list():
		t.hp = t.max_hp * 0.2 if t.slot == 1 else t.hp   # one thrall nearly dead
	caster.p["resource"]["value"] = 22.0
	var foe: DmEnemy = null
	for e in g.director.enemies.values():
		if is_instance_valid(e) and (foe == null or e.position.distance_to(b.position) < foe.position.distance_to(b.position)):
			foe = e
	g.ui_host._target_id = DmWaveDirector.id_of(foe)
	g.ui_host._target_until = Time.get_ticks_msec() + 60000.0
	g.input.hotbar.emit(1, foe.global_position, DmWaveDirector.id_of(foe))
	await _frames(40)
	var tag := _arg("tag", "x")
	var out := _arg("out", "/tmp")
	root.get_viewport().get_texture().get_image().save_png("%s/%s-class%s-a.png" % [out, tag, _arg("class", "1")])
	caster.p["resource"]["value"] = 300.0
	caster.p["cooldowns"].clear()
	g.input.hotbar.emit(2, foe.global_position, DmWaveDirector.id_of(foe))
	await _frames(10)
	g.input.hotbar.emit(3, foe.global_position, DmWaveDirector.id_of(foe))
	await _frames(10)
	g.input.hotbar.emit(4, foe.global_position, DmWaveDirector.id_of(foe))
	await _frames(25)
	root.get_viewport().get_texture().get_image().save_png("%s/%s-class%s-b.png" % [out, tag, _arg("class", "1")])
	quit()



## `--mode=bar`: no enemies, no corpses, a legion of four (one at 20 % health), 22 essence: the action bar and the legion pips on their own.
func _bar(g: DmNextGame, b: DmHeroBody, caster: DmRiteCaster) -> void:
	var th := b.get_node("Thralls") as DmThrallHost
	var spec := {"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
	for k in 4:
		th._spawn(DmThralls.raise_stats(spec, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, k + 1, 0.0), b.global_position + Vector3(-2.5 + k * 1.6, 0, 2.5), 0.0)
	await _frames(200)
	th.list()[1].hp = th.list()[1].max_hp * 0.2
	th.list()[3].hp = th.list()[3].max_hp * 0.3
	caster.p["resource"]["value"] = 22.0
	await _frames(40)
	root.get_viewport().get_texture().get_image().save_png("%s/%s-bar.png" % [_arg("out", "/tmp"), _arg("tag", "x")])
	quit()
