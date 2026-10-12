extends SceneTree
## The in-game benchmark (godot/next/perf/dm_benchmark.gd) with a short run: godot --headless --fixed-fps 60 --path godot --script res://tests/next_bench/run.gd
## Deterministic checks only (completes, result keys, fight targets reached, isolated backend, no settings write); timings are printed
## as INFO and never asserted.

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func _count_class(cls: String) -> int:
	var n := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		if nd.is_class(cls):
			n += 1
	return n


func _run() -> void:
	var settings_before := FileAccess.file_exists(DmSettings.FILE)
	var play_before := DirAccess.get_files_at("user://")
	var b := DmBenchmark.new()
	b.warm_s = 1.0
	b.measure_s = 2.0
	b.enemies = 12
	b.thralls = 6
	var lines := PackedStringArray()
	b.progress.connect(func(t: String) -> void: lines.append(t))
	var steps: Array = []
	b.breakdown_step.connect(func(step: int, _total: int, _what: String) -> void: steps.append(step))
	root.add_child(b)
	var r: Dictionary = await b.run()
	check(not r["cancelled"], "run completes")
	var ph: Array = r["phases"]
	check(ph.size() == 1 and ph[0]["label"] == "Fight", "one measured phase")
	for p in ph:
		for row in DmBenchmark.ROWS:
			check(p.has(row[0]), "phase %s has %s" % [p["label"], row[0]])
		check(int(p["frames"]) > 0 and float(p["avg_fps"]) > 0.0 and float(p["p95_ms"]) >= float(p["median_ms"]) and float(p["worst_ms"]) >= float(p["p99_ms"]), "%s: frame stats are coherent" % p["label"])
		check(float(p["enemies"]) >= 12.0 * 0.9, "%s: enemies reached the target (%.1f)" % [p["label"], p["enemies"]])
		check(float(p["thralls"]) >= 6.0 - 0.01, "%s: thralls reached the target (%.1f)" % [p["label"], p["thralls"]])
		print("INFO bench %s fps=%.1f p95=%.2f" % [p["label"], p["avg_fps"], p["p95_ms"]])
	var bd: Dictionary = r.get("breakdown", {})
	check(not bd.is_empty() and (bd["rows"] as Array).size() == DmBenchmark.BREAK_CATS.size(), "render breakdown: one row per part")
	check(not bd.is_empty() and not (bd["base_end"] as Dictionary).is_empty() and (bd["rows"] as Array)[-1]["what"] == "HUD", "render breakdown: HUD measured last and everything-on re-measured at the end")
	check(steps.size() == DmBenchmark.BREAK_CATS.size() + 2 and steps[0] == 0 and steps[-1] == DmBenchmark.BREAK_CATS.size() + 1, "the frozen-fight banner is told about every breakdown step (%s)" % [steps])
	check(not bd.is_empty() and bool(bd["restored"]), "render breakdown: everything hidden was shown again (geometry count and HUD)")
	check(not root.get_tree().paused, "render breakdown: the tree is unpaused afterwards")
	check(b.paused_ok, "render breakdown: the fight itself was paused while sampling")
	check(float(r["max_drift"]) <= 1.6, "the hero holds the centre (farthest %.2f m between checks)" % float(r["max_drift"]))
	check(DmBenchmark._part_of(Node.new()) == "", "render breakdown: an unrelated node belongs to no part")
	check(not DmBenchmark.at_refresh_rate(1000.0) and DmBenchmark.capped_warning({"phases": [{"capped": false}], "meta": {}}) == "", "V-Sync warning: none when not at the refresh rate")
	check(DmBenchmark.capped_warning({"phases": [{"capped": true}], "meta": {"refresh_hz": 170.0}}).contains("170 Hz"), "V-Sync warning: names the refresh rate")
	for p in ph:
		check(p.has("capped"), "%s reports whether it ran at the refresh rate" % p["label"])
	check(b.area_nav_on, "the benchmark area's navmesh is on (a sealed area left enemies unable to reach the hero)")
	check(int(r.get("kills", 0)) >= 5, "the fight is a fight: enemies spawn within reach and die (%d kills)" % int(r.get("kills", 0)))
	for k in ["build", "gpu", "renderer", "resolution", "preset", "fps_cap", "cpu", "cores", "vsync"]:
		check(r["meta"].has(k), "meta has %s" % k)
	check(r["backend_calls"] > 0, "the mock backend served the run (%d requests)" % r["backend_calls"])
	check(_count_class("HTTPRequest") == 0 and _count_class("WebSocketPeer") == 0 and _count_class("DmHttpTransport") == 0, "no network node was created")
	check(FileAccess.file_exists(DmSettings.FILE) == settings_before, "the settings file was not written")
	check(DirAccess.get_files_at("user://") == play_before, "no file appeared in user:// (%s)" % str(DirAccess.get_files_at("user://")))
	check(DmUiConfig.dir == "user://", "UI config dir restored")
	check(lines.size() >= 2 and lines[0].begins_with("Building"), "progress lines were emitted")
	var text := DmBenchmark.format_text(r)
	check(text.contains("Average fps") and text.contains("Fight") and text.contains("V-Sync: off during measurement") and text.contains("Render breakdown"), "text report (incl. the render breakdown)")
	var path := DmBenchmark.save_text(text)
	check(path.begins_with("user://benchmarks/bench-") and FileAccess.get_file_as_string(path).contains("Frame ms (p95)"), "report saved under user://benchmarks")
	check(DmBenchmark.breakdown_unsteady({"render_cpu_ms": -10.0, "frame_ms": 0.0, "render_gpu_ms": 0.0}) and not DmBenchmark.breakdown_unsteady({"render_cpu_ms": 1.0, "frame_ms": 0.2, "render_gpu_ms": 0.1}), "breakdown rows that got slower when hidden are flagged")
	check(r.has("hitches") and r["phases"][0].has("loot") and r["phases"][0].has("corpses"), "hitch log and loot / corpse counts are reported")
	check(bool(r.get("input_locked", false)), "the player's input is switched off for the fight (walking, hotkeys, panels)")
	b.queue_free()
	await process_frame
	# Esc on the real screen cancels a running benchmark (it used to be swallowed by the fight)
	var top := CanvasLayer.new()
	top.layer = 95
	root.add_child(top)
	var s := DmBenchmarkScreen.new()
	s.warm_s = 60.0
	s.measure_s = 30.0
	var closed := [false]
	s.closed.connect(func() -> void: closed[0] = true)
	top.add_child(s)
	var t0 := Time.get_ticks_msec()
	while (s.runner == null or s.runner.game == null) and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
	for i in 30:
		await process_frame
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	t0 = Time.get_ticks_msec()
	while not closed[0] and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
	check(closed[0], "Esc cancels a running benchmark and closes the screen")
	top.queue_free()
	await process_frame
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
