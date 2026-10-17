extends SceneTree
## The in-game benchmark (godot/next/perf/dm_benchmark.gd) with a short run: godot --headless --fixed-fps 60 --path godot --script res://tests/next_bench/run.gd
## Three short runs: the Standard setup, a custom one, and a Full Party fight (72 enemies, 32 thralls, the room's boss). Deterministic checks
## only (completes, result keys, fight targets reached, isolated backend, no settings write); timings are printed as INFO and never asserted.

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
	for f in [DmBenchHistory.FILE, DmBenchHistory.PENDING, DmBenchmarkSetup.FILE]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	var std := DmBenchmark.standard_stats()
	check(float(std["hp"]) > 0.0 and float(std["dmg"]) > 0.0, "standard enemy stats (hp %.0f, dmg %.1f)" % [std["hp"], std["dmg"]])
	var b := DmBenchmark.new()
	b.warm_s = 1.0
	b.measure_s = 2.0
	b.enemies = 12
	b.thralls = 6
	var lines := PackedStringArray()
	var hp_seen := {}
	b.progress.connect(func(t: String) -> void:
		lines.append(t)
		_note_hp(b, hp_seen))
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
		# The count is topped up every 0.25 s of REAL time and the kills between top-ups pull the average down, more on a loaded machine (a 4-core CI runner
		# averaged 10.1-10.6 of 12, 2026-10-16); without the upkeep it would fall towards 0, so 80 % proves the fight is held.
		check(float(p["enemies"]) >= 12.0 * 0.8, "%s: enemies reached the target (%.1f)" % [p["label"], p["enemies"]])
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
	var hz := DisplayServer.screen_get_refresh_rate()
	if hz > 0.0:
		var paused_at_cap := {"phases": [{"capped": false}], "meta": {}, "breakdown": {"base": {"frame_ms": 1000.0 / hz}}}
		check(DmBenchmark.capped_warning(paused_at_cap) == "" and DmBenchmark.breakdown_capped(paused_at_cap), "a paused breakdown at the refresh rate does not flag the fight (Helix 2026-10-14: 54 fps fight flagged as V-Sync)")
	check(DmBuild.version() == "dev", "an editor run has no installed build version")
	for p in ph:
		check(p.has("capped"), "%s reports whether it ran at the refresh rate" % p["label"])
	check(b.area_nav_on, "the benchmark area's navmesh is on (a sealed area left enemies unable to reach the hero)")
	check(int(r.get("kills", 0)) >= 3, "the fight is a fight: enemies spawn within reach and die (%d kills; every enemy has the standard health, so the 3 s test sees a few)" % int(r.get("kills", 0)))
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
	check(bool(r["standard"]) and r["setup"]["room"] == "sanctum" and int(r["setup"]["discipline"]) == 2, "default run = the Standard setup")
	check(r["phases"][0].has("kills_per_min") and text.contains("Setup: The Bell Sanctum, Gravecaller, Standard, Full"), "kills per minute + the setup in the report")
	_check_hp(hp_seen, std, "sanctum")
	b.queue_free()
	await process_frame
	# A custom setup: another room's own enemy kinds and another class, with the same enemy health; Quick = no render breakdown
	var c := DmBenchmark.new()
	c.configure({"room": "fen", "discipline": 11, "size": "light", "length": "quick"})
	check(c.area == "fen" and c.discipline == 11 and c.enemies == 15 and not c.breakdown and c.measure_s == 20.0, "configure applies room, class, size and length")
	c.warm_s = 1.0
	c.measure_s = 2.0
	c.enemies = 12
	var hp2 := {}
	c.progress.connect(func(_t: String) -> void: _note_hp(c, hp2))
	root.add_child(c)
	var r2: Dictionary = await c.run()
	check(not r2["cancelled"] and not bool(r2["standard"]) and (r2.get("breakdown", {}) as Dictionary).is_empty(), "custom run completes, not standard, no breakdown")
	# 70 % here, not the Fight phase's 80: the Reaper (discipline 11) kills faster than the Gravecaller between the real-time top-ups, and a loaded 4-core CI runner
	# averaged 9.3 of 12 (2026-10-17); without the upkeep two seconds of the Reaper's kills would still take it far lower.
	check(c.area_nav_on and float(r2["phases"][0]["enemies"]) >= 12.0 * 0.7, "custom room: navmesh on and enemies at the target (%.1f)" % float(r2["phases"][0]["enemies"]))
	check(DmBenchmark.format_text(r2).contains("custom"), "the report marks a custom setup")
	_check_hp(hp2, std, "fen")
	c.queue_free()
	await process_frame
	await _full_party_checks(std)
	_history_checks(r, text)
	await _flush_checks(r, text)
	_setup_checks()
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


## Every live enemy's max hp, keyed by kind (sampled ~1 Hz during the run).
func _note_hp(b: DmBenchmark, seen: Dictionary) -> void:
	if b.game == null or b.game.director == null:
		return
	for e in b.game.director.enemies.values():
		if is_instance_valid(e) and (e as DmEnemy).max_hp > 0.0:
			seen[String((e as DmEnemy).def_id)] = (e as DmEnemy).max_hp


## Full Party: the biggest fight the game makes at its real size, the Bell Sanctum's Prelate held awake, uploads under its own size id.
func _full_party_checks(std: Dictionary) -> void:
	var cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	check(DmBenchmark.SIZES["full_party"] == [cap, 32] and DmBenchmark.BOSS_SIZES == ["full_party"] and DmBenchmark.SIZE_NAMES["full_party"] == "Full Party",
		"Full Party: the global enemy cap (%d) and 32 thralls, the only size with a boss" % cap)
	check(DmBenchmark.ENEMY_LIMIT > cap, "the director's body limit leaves room for the Full Party fight's corpses")
	for room: String in DmBenchmark.ROOMS:
		check((DmBenchFight.boss_of(room) != "") == not (room in ["warren", "coliseum"]), "%s: a boss, except in the Warren and the Coliseum (%s)" % [room, DmBenchFight.boss_of(room)])
	check(DmBenchFight.boss_of("sanctum") == "prelate" and DmBenchFight.boss_of("graves") == "gravedigger", "a room's boss is the one that sleeps in its area")
	var w := DmBenchmark.new()
	w.configure({"room": "warren", "size": "full_party"})
	check(w.boss_id == "" and w.enemies == cap and w.boss_text().contains("no boss"), "a room without a boss runs Full Party without one and says so")
	w.configure({"room": "sanctum", "size": "heavy"})
	check(w.boss_id == "" and w.boss_text() == "", "the other sizes have no boss")
	w.free()
	var fp := DmBenchmark.new()
	fp.configure({"room": "sanctum", "discipline": 2, "size": "full_party", "length": "quick"})
	check(fp.enemies == cap and fp.thralls == 32 and fp.boss_id == "prelate" and not fp.breakdown and fp.boss_text().contains("Prelate"), "configure: Full Party in the Bell Sanctum holds the Prelate")
	fp.warm_s = 2.0
	fp.measure_s = 3.0
	var hp := {}
	fp.progress.connect(func(_t: String) -> void: _note_hp(fp, hp))
	root.add_child(fp)
	var r: Dictionary = await fp.run()
	var text := DmBenchmark.format_text(r)
	var ph: Dictionary = r["phases"][0]
	check(not r["cancelled"] and not bool(r["standard"]) and r["setup"]["size"] == "full_party", "Full Party run completes and is a custom setup")
	check(float(ph["enemies"]) >= cap * 0.85 and float(ph["thralls"]) >= 32.0 - 0.01, "Full Party: enemies (%.1f of %d) and thralls (%.1f of 32) reached" % [ph["enemies"], cap, ph["thralls"]])
	check(fp.boss_summons >= 1 and String(r["boss"]["id"]) == "prelate" and int(r["boss"]["summons"]) == fp.boss_summons, "Full Party: the Prelate was woken (%d times, %d defeats)" % [fp.boss_summons, fp.boss_defeats])
	check(float(ph["boss_awake_pct"]) >= 50.0, "Full Party: the boss was awake for most of the window (%.0f%%)" % float(ph["boss_awake_pct"]))
	check(text.contains("Setup: The Bell Sanctum, Gravecaller, Full Party, Quick") and text.contains("Boss: The Bell-Sworn Prelate") and text.contains("held awake"), "the report names the size and the boss")
	check(fp.area_nav_on, "Full Party: the room's navmesh is on")
	_check_hp(hp, std, "sanctum (Full Party, boss adds included)")
	var p := DmBenchHistory.payload(r, text)
	check(p["size"] == "full_party" and p["standard"] == false and (p["metrics"] as Dictionary).has("boss_awake_pct"), "upload payload: size id full_party, the boss share in the metrics")
	print("INFO bench Full Party fps=%.1f p95=%.2f enemies=%.1f thralls=%.1f boss woken %d defeated %d" % [ph["avg_fps"], ph["p95_ms"], ph["enemies"], ph["thralls"], fp.boss_summons, fp.boss_defeats])
	fp.queue_free()
	await process_frame


func _check_hp(seen: Dictionary, std: Dictionary, room: String) -> void:
	var same := not seen.is_empty()
	for k in seen:
		same = same and absf(float(seen[k]) - float(std["hp"])) < 0.01
	check(same, "%s: every enemy kind has the standard health %.0f (%s)" % [room, std["hp"], seen])


func _history_checks(r: Dictionary, text: String) -> void:
	var p := DmBenchHistory.payload(r, text)
	for k in ["clientRunId", "ranAt", "version", "gpu", "cpu", "preset", "room", "discipline", "size", "length", "standard", "vsyncCapped", "cancelled", "metrics", "report"]:
		check(p.has(k), "upload payload has %s" % k)
	check(p["room"] == "sanctum" and p["standard"] == true and (p["metrics"] as Dictionary).has("avg_fps"), "payload: setup and metrics")
	check(DmBenchHistory.previous(p).is_empty(), "no earlier run to compare with")
	DmBenchHistory.record(p)
	var p2 := p.duplicate(true)
	p2["clientRunId"] = "second-run-1"
	check(DmBenchHistory.previous(p2).get("clientRunId") == p["clientRunId"], "the previous run of the same setup on the same PC is found")
	var p3 := p2.duplicate(true)
	p3["room"] = "fen"
	check(DmBenchHistory.previous(p3).is_empty(), "a different setup is not compared")
	var prev := {"metrics": {"avg_fps": 100.0, "p95_ms": 10.0, "enemies": 30.0}}
	check(absf(DmBenchHistory.change({"avg_fps": 110.0}, prev, "avg_fps") - 0.1) < 0.0001, "change: +10%")
	check(DmBenchHistory.better("avg_fps", 0.1) == 1 and DmBenchHistory.better("p95_ms", 0.1) == -1 and DmBenchHistory.better("enemies", 0.5) == 0 and DmBenchHistory.better("avg_fps", 0.01) == 0, "better / worse / neutral")
	check(not FileAccess.get_file_as_string(DmBenchHistory.FILE).contains("Render breakdown"), "the local history keeps numbers, not the text report")


## The upload queue against fake servers: a 503 keeps the run, an accepted run leaves the queue.
func _flush_checks(r: Dictionary, text: String) -> void:
	var n := DmBenchHistory.pending_count()
	check(n >= 1, "the recorded run is queued for the server")
	var posted: Array = []
	var down := DmApi.new(func(req: Dictionary) -> Dictionary:
		posted.append(req)
		return {"status": 503, "text": "{\"success\":false,\"error\":\"later\"}"})
	down.set_token("t")
	check(await DmBenchHistory.flush(down) == 0 and DmBenchHistory.pending_count() == n, "server down: the run stays queued")
	check(posted.size() == 1 and String(posted[0]["url"]).ends_with("/api/benchmarks") and String(posted[0]["method"]) == "POST", "posts to /api/benchmarks")
	var up := DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":7}}"})
	up.set_token("t")
	check(await DmBenchHistory.flush(up) == n and DmBenchHistory.pending_count() == 0, "server up: every queued run is sent and leaves the queue")
	check(await DmBenchHistory.flush(DmApi.new()) == 0, "no login: nothing is sent")


func _setup_checks() -> void:
	check(DmBenchmark.normalize_setup({"room": "nowhere", "discipline": 7, "size": "huge"}) == DmBenchmark.STANDARD, "unknown picks (and greyed-out classes) fall back to the Standard setup")
	check(11 in DmBenchmark.class_indices() and 2 in DmBenchmark.class_indices() and not (7 in DmBenchmark.class_indices()), "classes: the playable disciplines incl. the Reaper")
	var M: GDScript = load("res://main/main.gd")
	var a: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-room=pyre", "--bench-class=3", "--bench-size=heavy", "--bench-length=quick"]))
	check(a["room"] == "pyre" and int(a["discipline"]) == 3 and a["size"] == "heavy" and a["length"] == "quick", "launch args pick the setup")
	var fa: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-size=full_party"]))
	check(fa["size"] == "full_party" and fa["room"] == "sanctum", "--bench-size=full_party picks Full Party")
	var w := DmBenchmarkSetup.new()
	var got: Array = []
	w.start.connect(func(s: Dictionary) -> void: got.append(s))
	root.add_child(w)
	check(DmBenchmark.is_standard(w.setup), "the setup window opens on the Standard setup the first time")
	w._room.select(DmBenchmark.ROOMS.find("cloister"))
	w._room.item_selected.emit(w._room.selected)
	w._start()
	check(got.size() == 1 and got[0]["room"] == "cloister" and not DmBenchmark.is_standard(got[0]), "Start hands over the pick")
	check(DmBenchmarkSetup.load_last()["room"] == "cloister", "the window remembers the last setup")
	check(w._size.item_count == DmBenchmark.SIZES.size() and w._size.get_item_text(w._size.item_count - 1) == "Full Party: 72 enemies, 32 thralls, a boss", "the window lists Full Party with its counts and the boss (%s)" % w._size.get_item_text(w._size.item_count - 1))
	w._size.select(DmBenchmark.SIZES.keys().find("full_party"))
	w._size.item_selected.emit(w._size.selected)
	check(w._note.text.contains(String(DmContent.boss("saint")["name"])), "the note names the picked room's boss (%s)" % w._note.text)
	w._room.select(DmBenchmark.ROOMS.find("warren"))
	w._room.item_selected.emit(w._room.selected)
	check(w._note.text.contains("no boss"), "the note says a room without a boss runs without one")
	w._start()
	check(got.size() == 2 and got[1]["size"] == "full_party" and got[1]["room"] == "warren", "Start hands over Full Party")
	w.queue_free()
