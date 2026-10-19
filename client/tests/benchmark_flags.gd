extends "res://tests/benchmark_base.gd"
## The in-game benchmark, the launch line's flags (client/README.md "The benchmark"), headless: `godot --headless --path client --script res://tests/benchmark_flags.gd`. One of five suites split from the old `benchmark` (see benchmark_base.gd).
##   - the crowd's cost settings from the launch line (`--bench-crowd=`) are recorded, and what is not a setting is said to be ignored; a room, class or graphics preset the benchmark does not list is refused with exit code 2;
##   - the team app's flags in a real launch: `--bench-preset=` puts a graphics preset on loan for the run (the report and the queued run say it, the player's settings file is not touched or changed), and `--bench-quit` ends a
##     run with exit code 0 once it is the last entry of the queue;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber and the hound into a scratch folder first, unless the checkout's setup baked them (the rest of the rosters borrow them: warnings, not errors).


func suite_name() -> String:
	return "benchmark_flags"


func run_suite() -> void:
	await launch_flags()


## The launch line's other settings, as a script or a person starts it: the crowd's cost, the team app's flags, and what a launch refuses.
func launch_flags() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var own := ProjectSettings.globalize_path(data)
	# the crowd's cost settings from the launch: the report records what was in force, and a setting that is not one is said to be ignored
	var o3: Array = []
	var c3 := OS.execute(exe, ["--headless", "--fixed-fps", "60", "--path", proj, "--", "--benchmark", "--bench-room=graves", "--bench-class=2", "--bench-size=full_party", "--bench-length=quick", "--bench-warm=2",
		"--bench-measure=4", "--baked=" + ProjectSettings.globalize_path(scratch), "--bench-dir=" + own, "--bench-crowd=cull=off,anim=off,thrall_shadows=off,reserve=64,lod=40/80,bogus=1"], o3, true)
	var t3 := "\n".join(PackedStringArray(o3))
	check(c3 == 0 and t3.contains("BENCHMARK Crowd: mesh levels at 40 / 80 m; 64 instances reserved a group; animation off (every body every frame); culling off; thralls do not cast shadows"), "a launch with --bench-crowd records its settings in the report (%d)" % c3)
	check(t3.contains("ignored --bench-crowd setting 'bogus=1'") and not t3.contains("SCRIPT ERROR"), "and says what it ignored")
	check(t3.contains("(0 of them thralls; 0 MultiMeshes, 0 k triangles again in the shadow pass)") or t3.contains("(0 of them thralls;"), "and no thrall cast")
	# the team app's launch: a preset on loan and --bench-quit; the player's settings file is not touched, the run is the last entry of its own queue
	var settings_had := FileAccess.file_exists(DmSettings.FILE)
	var settings_was := FileAccess.get_file_as_string(DmSettings.FILE) if settings_had else ""
	var own_preset := String(DmBenchmark.user_settings()["graphics"])
	var asked := "low" if own_preset != "low" else "medium"
	var trial := own.path_join("team-run")
	var o4: Array = []
	var c4 := OS.execute(exe, ["--headless", "--fixed-fps", "60", "--path", proj, "--", "--benchmark", "--bench-room=graves", "--bench-class=2", "--bench-size=light", "--bench-length=quick", "--bench-warm=1",
		"--bench-measure=2", "--baked=" + ProjectSettings.globalize_path(scratch), "--bench-dir=" + trial, "--bench-preset=" + asked, "--bench-quit"], o4, true)
	var t4 := "\n".join(PackedStringArray(o4))
	check(c4 == 0, "--bench-preset=%s --bench-quit: the launch exits 0 once its run is recorded (%d)" % [asked, c4])
	check(t4.contains("Graphics preset: " + asked) and not t4.contains("SCRIPT ERROR"), "the report names the preset that was asked for, not the player's (%s)" % own_preset)
	var trial_queue := trial.path_join("pending.json")
	var trial_runs: Variant = JSON.parse_string(FileAccess.get_file_as_string(trial_queue)) if FileAccess.file_exists(trial_queue) else []
	check(trial_runs is Array and (trial_runs as Array).size() == 1 and (trial_runs as Array)[0] is Dictionary, "the run is the one entry of its folder's queue")
	if trial_runs is Array and (trial_runs as Array).size() == 1:
		var last: Dictionary = (trial_runs as Array)[0]
		check(last.get("preset") == asked and last.get("room") == "graves" and int(last.get("discipline", 0)) == 2 and last.get("size") == "light" and last.get("length") == "quick" and not bool(last.get("cancelled", true)) and (last.get("metrics", {}) as Dictionary).has("avg_fps"),
			"the queued run has the preset and the setup that were asked for and a result (the payload the app sends)")
	check(FileAccess.file_exists(DmSettings.FILE) == settings_had and (not settings_had or FileAccess.get_file_as_string(DmSettings.FILE) == settings_was), "the launch left the player's settings file as it was")
	for pair in [["--bench-room=depths", "'depths'", "graves"], ["--bench-room=nowhere", "'nowhere'", "fen"], ["--bench-class=5", "class 5", "2 Gravecaller"], ["--bench-preset=max", "'max'", "low, medium, high, ultra"]]:
		var o2: Array = []
		var c2 := OS.execute(exe, ["--headless", "--path", proj, "--", "--benchmark", pair[0]], o2, true)
		var t2 := "\n".join(PackedStringArray(o2))
		check(c2 == 2 and t2.contains("BENCHMARK refused:") and not t2.contains("BENCHMARK Death Muffin benchmark"), "%s is refused with exit code 2 (%d) and no run" % [pair[0], c2])
		check(t2.contains(pair[1]) and t2.contains(pair[2]), "%s: the message names the pick and says what the benchmark has" % pair[0])
