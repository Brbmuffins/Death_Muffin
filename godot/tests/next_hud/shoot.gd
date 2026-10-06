extends SceneTree
## Rendered screenshot of the slice HUD in a fight (under the renderer lock + xvfb):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_hud/shoot.gd -- --out=/some/dir

func _initialize() -> void:
	_run.call_deferred()


func _out() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			return a.substr(6)
	return "/tmp"


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("sh%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"persist": false})
	var b := g.local_body()
	b.teleport(Vector3(0, 0, -16))
	b.p["god"] = true
	var caster := b.get_node("Rites") as DmRiteCaster
	await _frames(240)
	var heroes := [b]
	for i in 7:
		g.director.spawn("robber", Vector3(sin(i * 0.9) * 7.0, 0.0, -16.0 + cos(i * 0.9) * 7.0), heroes)
	await _frames(200)
	caster.p["resource"]["value"] = 60.0
	var foe: DmEnemy = null
	for e in g.director.enemies.values():
		if is_instance_valid(e) and (foe == null or e.position.distance_to(b.position) < foe.position.distance_to(b.position)):
			foe = e
	g.input.hotbar.emit(3, foe.global_position, DmWaveDirector.id_of(foe))
	await _frames(20)
	g.input.hotbar.emit(0, foe.global_position, DmWaveDirector.id_of(foe))
	g.ui_host._target_id = DmWaveDirector.id_of(foe)
	g.ui_host._target_until = Time.get_ticks_msec() + 30000.0
	await _frames(14)
	b.take_damage(30.0, foe)
	await _frames(12)
	root.get_viewport().get_texture().get_image().save_png(_out() + "/slice-hud-fight.png")
	quit()
