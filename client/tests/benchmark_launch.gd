extends "res://tests/benchmark_base.gd"
## The in-game benchmark, real launches (client/README.md "The benchmark"), headless: `godot --headless --path client --script res://tests/benchmark_launch.gd`. One of five suites split from the old `benchmark` (see benchmark_base.gd).
##   - a real `--benchmark` launch (--bench-warm / --bench-measure) prints the report and quits by itself, keeps its report in the folder it was given, and another room and class queue their run there and send nothing;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber and the hound into a scratch folder first, unless the checkout's setup baked them (the rest of the rosters borrow them: warnings, not errors).


func suite_name() -> String:
	return "benchmark_launch"


func run_suite() -> void:
	await real_launches()


# ------------------------------------------------------------------------------------------------------------------ real launches

## `godot --headless ... -- --benchmark ...` as a script or a person starts it.
func real_launches() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var own := ProjectSettings.globalize_path(data)
	var out: Array = []
	var code := OS.execute(exe, ["--headless", "--fixed-fps", "60", "--path", proj, "--", "--benchmark", "--bench-room=graves", "--bench-class=2", "--bench-size=full_party", "--bench-length=quick", "--bench-warm=2",
		"--bench-measure=4", "--baked=" + ProjectSettings.globalize_path(scratch), "--bench-dir=" + own], out, true)
	var text := "\n".join(PackedStringArray(out))
	check(code == 0, "a --benchmark launch ends by itself with exit code 0 (%d)" % code)
	for needle in ["BENCHMARK Death Muffin benchmark", "BENCHMARK Setup: %s, %s, %s, Quick" % [DmBenchmark.room_name("graves"), DmBenchmark.class_name_of(2), DmBenchmark.SIZE_NAMES["full_party"]], "BENCHMARK Boss: %s" % DmContent.boss(_boss_in("graves"))["name"], "BENCHMARK Average fps", "BENCHMARK Budgets (ROADMAP",
			"BENCHMARK   Combat core per tick", "BENCHMARK   Rest of the main thread per frame", "BENCHMARK saved to"]:
		check(text.contains(needle), "the launch printed '%s'" % needle)
	check(not text.contains("SCRIPT ERROR") and not text.contains("Parse Error"), "and no script error")
	var reports := 0
	for f in DirAccess.get_files_at(own):
		reports += 1 if f.begins_with("bench-") else 0
	check(text.contains(own) and reports >= 1, "the launch kept its report in the folder it was given")
	# another room and class, from the launch line
	var out_fen: Array = []
	var code_fen := OS.execute(exe, ["--headless", "--fixed-fps", "60", "--path", proj, "--", "--benchmark", "--bench-room=fen", "--bench-class=11", "--bench-size=light", "--bench-length=quick", "--bench-warm=1",
		"--bench-measure=2", "--baked=" + ProjectSettings.globalize_path(scratch), "--bench-dir=" + own], out_fen, true)
	var text_fen := "\n".join(PackedStringArray(out_fen))
	check(code_fen == 0 and text_fen.contains("BENCHMARK Setup: %s, %s, %s, Quick" % [DmBenchmark.room_name("fen"), DmBenchmark.class_name_of(11), DmBenchmark.SIZE_NAMES["light"]]) and text_fen.contains("BENCHMARK Average fps") and not text_fen.contains("SCRIPT ERROR"), "--bench-room=fen --bench-class=11 runs the Reaper in the Fen (%d)" % code_fen)
	var queued_runs: Array = JSON.parse_string(FileAccess.get_file_as_string(DmBenchHistory.pending_file())) if FileAccess.file_exists(DmBenchHistory.pending_file()) else []
	var rooms_queued := queued_runs.map(func(q: Dictionary) -> String: return "%s/%d" % [q["room"], int(q["discipline"])])
	check(rooms_queued.has("graves/2") and rooms_queued.has("fen/11"), "the two launches queued their runs in the folder they were given and sent nothing (%s)" % str(rooms_queued))
