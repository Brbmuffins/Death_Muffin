extends SceneTree
## Per-body build cost of DmCreature.new (what a pool miss / area top-up frame pays). Per kind: the first build (resource load), then
## `n` repeat builds; with --rendered (xvfb) the repeat batch is also put on screen and the first drawn frame timed (material/uniform
## upload cost lands there, not in the build), after a warm frame that compiled the shaders.
## godot --headless --path godot --script res://tests/perf/creature_build.gd -- [--n=6]
## xvfb-run godot --rendering-driver opengl3 --path godot --script res://tests/perf/creature_build.gd -- --rendered [--n=6]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var n := 6
	var rendered := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="):
			n = int(a.substr(4))
		elif a == "--rendered":
			rendered = true
	var stage := Node3D.new()
	root.add_child(stage)
	var cam := Camera3D.new()
	stage.add_child(cam)
	cam.position = Vector3(0, 3, 9)
	cam.look_at(Vector3(0, 1, 0))
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	stage.add_child(sun)
	sun.rotation = Vector3(-0.9, 0.4, 0)
	var tot_first := 0.0
	var tot_rep := 0.0
	var tot_draw := 0.0
	var tot_steady := 0.0
	var kinds := 0
	for def in DmEntityViews.ENEMY_SLUG:
		var slug: String = DmEntityViews.ENEMY_SLUG[def]
		var o := {"tint": 0x998877, "rim": {"color": 0xff0000, "strength": 0.0}}
		var t0 := Time.get_ticks_usec()
		var c := DmCreature.new(slug, o)
		var first := (Time.get_ticks_usec() - t0) / 1000.0
		stage.add_child(c.root)
		await process_frame
		await process_frame
		var batch: Array = []
		var t1 := Time.get_ticks_usec()
		for i in n:
			batch.append(DmCreature.new(slug, o))
		var rep := (Time.get_ticks_usec() - t1) / 1000.0 / n
		var draw := 0.0
		var steady := 0.0
		if rendered:
			for i in batch.size():
				stage.add_child(batch[i].root)
				batch[i].root.position = Vector3(float(i) - n / 2.0, 0, 0)
			await process_frame
			var t2 := Time.get_ticks_usec()
			RenderingServer.force_draw(false)
			draw = (Time.get_ticks_usec() - t2) / 1000.0
			var t3 := Time.get_ticks_usec()
			RenderingServer.force_draw(false)
			steady = (Time.get_ticks_usec() - t3) / 1000.0
		tot_first += first
		tot_rep += rep
		tot_draw += draw
		tot_steady += steady
		kinds += 1
		print("BUILD %-16s first=%6.2fms repeat=%5.2fms first-draw(x%d)=%6.2fms steady=%6.2fms" % [def, first, rep, n, draw, steady])
		c.dispose()
		for b in batch:
			b.dispose()
		await process_frame
	print("BUILD-TOTAL kinds=%d first-avg=%.2fms repeat-avg=%.2fms first-draw-avg=%.2fms steady-avg=%.2fms" % [kinds, tot_first / kinds, tot_rep / kinds, tot_draw / kinds, tot_steady / kinds])
	quit()
