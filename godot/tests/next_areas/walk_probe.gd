extends SceneTree
## Rendered walk through every area (NOT a pass/fail suite; run under xvfb + the renderer lock, few runs, software GL is slow):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_areas/walk_probe.gd -- --out=/some/dir
## Per area: worst of the first 8 frames after arriving (first-entry hitch: shaders, models, banner) and the mean of the next 60, plus a screenshot.

const ORDER := ["chapterhouse", "acre", "alchemist_wing", "graves", "warren", "ossuary", "nave", "coliseum", "sanctum", "cloister", "pyre", "fen"]


func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _run() -> void:
	var out := _arg("out", "")
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("walk%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	var t0 := Time.get_ticks_msec()
	await g.start(c.data, api, {"hud": "minimal", "persist": false, "waves": true})
	print("load %d ms (world %d ms, navmesh bake %d ms)" % [Time.get_ticks_msec() - t0, g.world.build_ms, g.world.bake_ms])
	g.world.builder.open_all()   # seals open: the probe walks every area
	for i in 30:
		await process_frame
	var hb := g.local_body()
	for id in ORDER:
		var rect: Dictionary = DmContent.area(id)["rect"]
		var x := (float(rect["x0"]) + float(rect["x1"])) * 0.5
		var z := (float(rect["z0"]) + float(rect["z1"])) * 0.5
		g.chapterhouse.teleport_to(x, z)
		var first: Array = []
		for i in 8:
			var t := Time.get_ticks_usec()
			await process_frame
			first.append(float(Time.get_ticks_usec() - t) / 1000.0)
			hb.heal(1e6)
		var rest: Array = []
		for i in 60:
			var t := Time.get_ticks_usec()
			await process_frame
			rest.append(float(Time.get_ticks_usec() - t) / 1000.0)
			hb.heal(1e6)
		var sum := 0.0
		for v in rest:
			sum += v
		first.sort()
		print("%-15s first-8 worst %6.1f ms | next-60 mean %5.1f ms | enemies %d" % [id, first[first.size() - 1], sum / rest.size(), g.director.alive_count()])
		if out != "":
			await process_frame
			var img := root.get_viewport().get_texture().get_image()
			if img != null:
				img.save_png("%s/area_%s.png" % [out, id])
	g.queue_free()
	await process_frame
	quit(0)
