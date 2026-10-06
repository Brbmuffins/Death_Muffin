extends SceneTree
## Rendered probe for the Depths (NOT a pass/fail suite; run under xvfb + the renderer lock):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_depths/shoot.gd -- --out=/some/dir
## Enters the Depths at depth 5 (a chest floor) with the real HUD, prints the floor build cost and frame times with hunters on the floor,
## and saves screenshots: the way in, the floor with its dead, the open chest.

var out := ""


func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _frames(n: int) -> Array:
	var out_a: Array = []
	for i in n:
		var t := Time.get_ticks_usec()
		await process_frame
		out_a.append(float(Time.get_ticks_usec() - t) / 1000.0)
	return out_a


func _stats(label: String, arr: Array) -> void:
	var s := arr.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	print("%s: n=%d mean %.1f ms  p50 %.1f  p95 %.1f  max %.1f" % [label, s.size(), sum / s.size(), s[s.size() / 2], s[int(s.size() * 0.95)], s[s.size() - 1]])


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
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": true, "persist": false})
	print("load: start() %d ms" % g.load_ms)
	await _frames(30)
	var hb := g.local_body()
	hb.p["god"] = true
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	hb.teleport(Vector3(float(s["x"]), 0, float(s["z"]) + 2.5))
	await _frames(20)
	await _shot("warren_stair")
	var t0 := Time.get_ticks_msec()
	await g.depths.enter(5, 77)
	print("enter depth 5: %d ms end to end (main thread %d ms, bake %d ms)" % [Time.get_ticks_msec() - t0, g.depths.ground.build_ms, g.depths.ground.bake_ms])
	await _frames(10)
	await _shot("depth5_start")
	await _frames(240)
	print("hunters alive: %d" % g.depths._alive())
	var steady: Array = []
	for k in 4:
		hb.heal(1e6)
		steady.append_array(await _frames(40))
	_stats("floor frames with hunters", steady)
	await _shot("depth5_hunters")
	var f: Dictionary = g.depths.run.floor_data
	hb.teleport(Vector3(float(f["chest"]["x"]), 0, float(f["chest"]["z"]) + 1.5))
	await _frames(20)
	g.depths.open_chest()
	await _frames(60)
	await _shot("depth5_chest")
	quit()
