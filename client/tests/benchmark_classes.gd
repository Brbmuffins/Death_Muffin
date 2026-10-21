extends "res://tests/benchmark_base.gd"
## The in-game benchmark, every class and the screen (client/next/perf/BENCHMARK.md), headless: `godot --headless --path client --script res://tests/benchmark_classes.gd`. One of five suites split from the old `benchmark` (see benchmark_base.gd).
##   - every class: a short run per class, the kit's family, auto combat casts;
##   - the benchmark screen sends its run to a mock as the test API (the history queue, a debug build and a dev-offline run do not upload, no login and a down server keep the queue);
##   - Esc cancels a running benchmark;
##   - nothing is sent anywhere: a real transport is never asked to carry a run from a script, a mock takes the queue, a trial launch with its own folder gets no api;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber and the hound into a scratch folder first, unless the checkout's setup baked them (the rest of the rosters borrow them: warnings, not errors).


func suite_name() -> String:
	return "benchmark_classes"


func run_suite() -> void:
	await every_class()
	await screen_and_upload()
	await esc_cancels()
	await nothing_over_the_network()


## Every class plays its short run: the kit's family, and auto combat casts.
func every_class() -> void:
	var total := 0
	for disc: int in DmBenchmark.class_indices():
		var o := await short_run("graves", disc)
		var r: Dictionary = o["r"]
		var w: Watch = o["watch"]
		total += int(o["ms"])
		var want := String(DmCharacterBuild.discipline_for(float(disc))["family"])
		var name_ := DmBenchmark.class_name_of(disc)
		check(not r["cancelled"] and r["setup"]["discipline"] == disc and w.family == want, "%s: the short run completes with a %s hero (%s)" % [name_, want, w.family])
		check(w.casts > 0 and (r["phases"] as Array).size() == 1 and int(r["phases"][0]["frames"]) > 0, "%s: auto combat cast %d times" % [name_, w.casts])
		check(DmBenchmark.format_text(r).contains("Setup: %s, %s, %s, Quick" % [DmBenchmark.room_name("graves"), name_, DmBenchmark.SIZE_NAMES["light"]]), "%s: the report names the class" % name_)
		print("INFO bench class %s: %d casts, %d kills, avg %.2f ms, run took %.1f s" % [name_, w.casts, int(r["kills"]), float(r["phases"][0]["avg_ms"]) if not (r["phases"] as Array).is_empty() else 0.0, float(o["ms"]) / 1000.0])
		(o["b"] as DmBenchmark).queue_free()
		await process_frame
	print("INFO bench every class: %.1f s" % (total / 1000.0))


# ------------------------------------------------------------------------------------------------------------------ the screen and what it sends

func screen_and_upload() -> void:
	if FileAccess.file_exists(DmBenchHistory.pending_file()):   # (the runs above are queued: this check is about the screen's own run)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DmBenchHistory.pending_file()))
	var posted: Array = []
	var test_api := DmApi.new(func(req: Dictionary) -> Dictionary:
		posted.append(req)
		return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":7}}"})
	test_api.base_url = DmConfig.API_BASE
	test_api.set_token("t")
	check(DmConfig.allows_api_base(test_api.base_url), "the api the run uploads with is the test server's (%s)" % test_api.base_url)
	var top := CanvasLayer.new()
	top.layer = 95
	root.add_child(top)
	var s := DmBenchmarkScreen.new()
	s.warm_s = 1.0
	s.measure_s = 2.0
	s.baked_dir = scratch
	s.setup = {"room": "graves", "discipline": 2, "size": "light", "length": "quick"}
	s.graphics_preset = DmGraphicsPreset.IDS[0] if DmBenchmark.user_settings()["graphics"] != DmGraphicsPreset.IDS[0] else DmGraphicsPreset.IDS[1]   # the run's preset (--bench-preset=), not the player's
	s.api = test_api
	var closed := [false]
	s.closed.connect(func() -> void: closed[0] = true)
	top.add_child(s)
	var t0 := Time.get_ticks_msec()
	while s.uploaded < 0 and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
	check(s.uploaded == 1 and DmBenchHistory.pending_count() == 0, "the screen's run was sent and left the queue (%d accepted)" % s.uploaded)
	check(posted.size() == 1 and String(posted[0]["method"]) == "POST" and String(posted[0]["url"]).begins_with(DmConfig.API_BASE) and String(posted[0]["url"]).ends_with("/api/benchmarks"),
		"it posted once, to the test API's benchmarks (%s)" % [posted.map(func(q: Dictionary) -> String: return String(q["url"]))])
	var all_test := not posted.is_empty()
	for q in posted:
		all_test = all_test and DmConfig.allows_url(String(q["url"])) and String(q["url"]).begins_with(DmConfig.API_BASE)
	check(all_test, "every request stayed on the test server")
	var sent: Variant = JSON.parse_string(String(posted[0].get("body", ""))) if not posted.is_empty() else null
	check(sent is Dictionary and sent.get("room") == "graves" and (sent.get("metrics", {}) as Dictionary).has("core_ms") and String(sent.get("report", "")).contains("Combat core per tick"), "the posted run carries the room, the core's numbers and the report")
	check(s.report.contains("Budgets (ROADMAP") and s.saved_path != "", "the screen kept the report with its budget section, and saved it")
	check(sent is Dictionary and sent.get("preset") == s.graphics_preset and s.report.contains("Graphics preset: " + s.graphics_preset), "the posted run and its report carry the preset the run was asked for (%s), not the player's" % s.graphics_preset)
	check(not has_script_class(root, "DmHttpTransport"), "the screen made no transport of its own")
	# Esc closes the results
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	t0 = Time.get_ticks_msec()
	while not closed[0] and Time.get_ticks_msec() - t0 < 10000:
		await process_frame
	check(closed[0], "Esc closes the results (back to the character select)")
	top.queue_free()
	await process_frame
	# who may upload: the logged-in api from the character select; a debug build's `--benchmark` never
	var m := DmMain.new()
	m.mode = "benchmark"
	check(OS.is_debug_build() and m._bench_upload_api() == null, "a debug build's --benchmark run does not upload")
	m.mode = "online"
	m.api = test_api
	check(m._bench_upload_api() == test_api, "from the character select the run goes out with the logged-in (test server) api")
	m.mode = "dev_offline"
	check(m._bench_upload_api() == null, "a dev-offline run does not upload")
	m.free()
	var n := DmBenchHistory.pending_count()
	check(await DmBenchHistory.flush(DmApi.new()) == 0 and DmBenchHistory.pending_count() == n, "no login: nothing is sent")
	var down := DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": 503, "text": "{\"success\":false,\"error\":\"later\"}"})
	down.set_token("t")
	DmBenchHistory.record(DmBenchHistory.payload(_tiny_result(), "report"))
	check(await DmBenchHistory.flush(down) == 0 and DmBenchHistory.pending_count() == n + 1, "server down: the run stays queued")


func esc_cancels() -> void:
	var top := CanvasLayer.new()
	top.layer = 95
	root.add_child(top)
	var s := DmBenchmarkScreen.new()
	s.warm_s = 60.0
	s.measure_s = 30.0
	s.baked_dir = scratch
	s.setup = {"room": "graves", "discipline": 2, "size": "light", "length": "quick"}
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
	while not closed[0] and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
	check(closed[0], "Esc cancels a running benchmark and closes the screen")
	top.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ nothing leaves the process

## No test sends a run anywhere but a mock. The one door a run can leave by is DmApi.post_benchmark through DmBenchHistory.flush: from a script, flush refuses a real transport.
func nothing_over_the_network() -> void:
	DmBenchHistory.record(DmBenchHistory.payload(_tiny_result(), "report"))
	var queued := DmBenchHistory.pending_count()
	# a real transport with a login, pointed at an address its own door refuses: flush must stop before it asks (and if it ever did, the transport still sends nothing)
	var t := DmHttpTransport.new()
	root.add_child(t)
	var real := DmApi.new(t.request_callable())
	real.base_url = "https://example.invalid/death-muffin/test-api"
	real.set_token("t")
	var errors_before := errlog.errors.size()
	check(DmBenchHistory.over_the_network_from_a_script(real), "a script run sees a real transport as the network")
	check(await DmBenchHistory.flush(real) == 0 and DmBenchHistory.pending_count() == queued, "flush does not send a run through a real transport from a script: it stays queued (%d)" % queued)
	check(errlog.errors.size() == errors_before and t.get_child_count() == 0, "and the transport was never asked (no request node, no refusal logged)")
	t.queue_free()
	var mock_api := DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":1}}"})
	mock_api.set_token("t")
	check(not DmBenchHistory.over_the_network_from_a_script(mock_api) and await DmBenchHistory.flush(mock_api) == queued and DmBenchHistory.pending_count() == 0, "a mock answers: the queue is sent to it and leaves")
	# the launch path: a trial (its own folder) never gets an api, whatever build it is
	var m := DmMain.new()
	m.mode = "benchmark"
	m.bench_dir = data
	check(m._bench_upload_api() == null, "a --benchmark launch with its own --bench-dir= sends nothing")
	m.free()
	await process_frame
