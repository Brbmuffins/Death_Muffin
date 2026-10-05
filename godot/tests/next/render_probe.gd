extends SceneTree
## Rendered perf + screenshot probe for the slice (NOT a pass/fail suite; run under xvfb + the renderer lock):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next/render_probe.gd -- --out=/some/dir [--dressing=0]
## Prints load time, calm frame time in the Chapterhouse, the first-combat frames (first wave appearing), and 25 enemies chasing.

var out := ""
var frames: Array = []
var _last := 0


func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _stats(label: String, arr: Array) -> void:
	if arr.is_empty():
		return
	var s := arr.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	print("%s: n=%d mean %.1f ms  p50 %.1f  p95 %.1f  max %.1f" % [label, s.size(), sum / s.size(), s[s.size() / 2], s[int(s.size() * 0.95)], s[s.size() - 1]])


func _frames(n: int) -> Array:
	var out_a: Array = []
	for i in n:
		var t := Time.get_ticks_usec()
		await process_frame
		out_a.append(float(Time.get_ticks_usec() - t) / 1000.0)
	return out_a


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_viewport().get_texture().get_image()
	if img != null and out != "":
		img.save_png("%s/%s.png" % [out, name])


func _run() -> void:
	out = _arg("out", "")
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("probe%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(int(_arg("class", "2")))
	var t0 := Time.get_ticks_msec()
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": _arg("dressing", "1") == "1"})
	var load_ms := Time.get_ticks_msec() - t0
	print("load: %d ms (start() %d ms: world build %d, navmesh bake %d, nav sync %d)" % [load_ms, g.load_ms, g.world.build_ms, g.world.bake_ms, g.world.sync_ms])
	g.director.enabled = false
	await _frames(20)
	_stats("calm Chapterhouse frames", await _frames(90))
	await _shot("chapterhouse")
	var hb := g.local_body()
	hb.teleport(Vector3(0, 0, -16))
	hb.p["god"] = true   # keep the hero alive for the shots (the robbers still swing)
	await _frames(10)
	_stats("calm Graves frames", await _frames(60))
	# first combat: the first wave appears (models, rise, first swings), no warmup was done
	g.director.enabled = true
	g.director.first_wave_delay = 0.2
	var first := await _frames(150)
	_stats("first-combat frames (first 150 after the first wave)", first)
	# 25 enemies chasing
	var heroes := [hb]
	for i in range(maxi(0, 25 - g.director.alive_count())):
		g.director.spawn("robber", Vector3(sin(i * 0.5) * 11.0, 0.0, -16.0 + cos(i * 0.5) * 11.0), heroes)
	g.director.enabled = false
	await _frames(120)
	hb.heal(1e6)
	var steady: Array = []
	for k in 6:
		hb.heal(1e6)
		steady.append_array(await _frames(40))
	print("alive enemies: %d" % g.director.alive_count())
	_stats("25 chasing frames", steady)
	await _shot("graves_combat")
	quit()
