extends SceneTree
## Play reports (ROADMAP Phase 1 "New: play reports"; client/next/perf/README.md "Play reports"), headless, against the local mock only: `godot --headless --path client --script res://tests/play_report.gd`
## (about 1 to 2 minutes; deterministic checks only, the cost per frame is printed as INFO and never asserted). It checks:
##   - the numbers on a known sequence of frame times: the 9 buckets (the edges: 8.0 is in the second bucket, 16.7 in the fourth, 50.0 is in the seventh and is not a hitch), count, average, worst, hitches over 50 ms,
##     the p50 and p99 of the histogram against the exact order statistics, time and deaths per area, a frame over 10 s counted as 10 s, a minimized window's frames skipped;
##   - the payload against the contract (the keys, the types, the ranges, the enums, the string and list caps, nothing personal), and what happens to a value outside it;
##   - a real offline game scene: the frames of an attached scene (none before it is attached or after it is detached), the area it follows, a death per area (a fallen hero counted once), the level and
##     discipline, the party's size and who hosted, the backend session ids across two game scenes (a hand-over), the preset, window, V-Sync and fps cap read from the game;
##   - the save and the crash: the autosave at the minimum session length (DmPlayReport.MIN_SECONDS) and then at each DmPlayReport.SAVE_EVERY_MS, a live file found at the next start becomes a "crash" report (a fresh one is left alone, a short or damaged one only removed),
##     a finished session is queued, a short one is dropped, the queue keeps its newest few (DmPlayReportQueue.KEEP);
##   - sending through the mock: in order, a resend of the same reportId is one row, what the server refuses (400) leaves the queue and what it cannot take now (503, 429, 401, an older server's 404, no login) stays,
##     a report queued while another is on its way is not lost;
##   - nothing leaves a script run: the one gate (`DmPlayReportQueue.records`) refuses a debug build, a script run, dev-offline, the benchmark and a test's mode, and `flush` refuses a real transport from a script;
##   - DmMain's wiring on the mock (the gate forced open for the test): the report starts with the first ready scene and never counts a scene that is not ready, a discipline change keeps it (one report id, the
##     backend session ids of both scenes), Switch character queues it as "switch" and the select screen sends it, Log out queues "logout" and sends it before the token goes, quit queues "quit" before it saves and sends it before closing;
##   - zero script errors or engine errors in the log.

const CONTRACT_KEYS := ["reportId", "version", "seconds", "endReason", "endArea", "discipline", "level", "partySize", "host", "preset", "gpu", "driver", "os", "cpuCores", "ramMb", "resolution", "vsync", "fpsCap", "frames", "areas", "sessionIds"]
const FRAME_KEYS := ["count", "avgMs", "p50Ms", "p99Ms", "worstMs", "hitches", "hist"]
const AREA_KEYS := ["seconds", "deaths", "avgMs"]
const FRAME_MS := 16.6   ## the length of the frames a test feeds a collector by hand


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var scratch := "user://play_report_test_%d" % OS.get_process_id()   ## this run's own folder (DmPlayReportQueue.dir): no other run's files change a check
var g: DmNextGame
var api: DmApi
var mock: DmMockBackend
var character: Dictionary
var last_report: DmPlayReport   ## the collector of the last section, for the cost line


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL play_report: " + what)


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	_remove_tree(ProjectSettings.globalize_path(scratch))
	DmPlayReportQueue.dir = scratch
	the_numbers()
	the_payload()
	await a_real_game_scene()
	the_save_and_the_crash()
	the_queue()
	await sending()
	await nothing_leaves_a_script_run()
	await dm_main_wiring()
	cost()
	finish()


# ------------------------------------------------------------------------------------------------------------------ the numbers

## The contract's table read on its own, not through the collector's loop: <8, <12, <16.7, <25, <33.4, <50, <100, <250, >=250.
func ref_bucket(ms: float) -> int:
	if ms < 8.0:
		return 0
	if ms < 12.0:
		return 1
	if ms < 16.7:
		return 2
	if ms < 25.0:
		return 3
	if ms < 33.4:
		return 4
	if ms < 50.0:
		return 5
	if ms < 100.0:
		return 6
	if ms < 250.0:
		return 7
	return 8


## The p-quantile by the textbook rule the collector's comment states: the ceil(q * n)-th smallest frame.
func exact_rank(sorted_ms: Array, q: float) -> float:
	return float(sorted_ms[clampi(ceili(q * sorted_ms.size()), 1, sorted_ms.size()) - 1])


## Frames of FRAME_MS that make `seconds` of play (the session minimum and the autosave interval are the collector's own constants, so these counts follow them).
func frames_for(seconds: float) -> int:
	return ceili(seconds * 1000.0 / FRAME_MS)


func feed(c: DmPlayReport, seconds: float) -> void:
	for i in frames_for(seconds):
		c.frame(FRAME_MS)


func a_collector() -> DmPlayReport:
	var r := DmPlayReport.new()
	root.add_child(r)
	r.begin("20261018.211258-bb6acd8")
	return r


func the_numbers() -> void:
	var r := a_collector()
	check(r.report_id.length() >= 16 and r.report_id.length() <= 64 and RegEx.create_from_string("^[A-Za-z0-9_-]+$").search(r.report_id) != null, "the report id is 16 to 64 of [A-Za-z0-9_-] (%s)" % r.report_id)
	check(DmPlayReport.make_id() != DmPlayReport.make_id(), "ids differ")
	check(r.gpu != "" and r.driver != "" and r.os_name != "" and r.cpu_cores >= 1 and r.ram_mb >= 0, "the PC is read: %s | %s | %s | %d cores | %d MB" % [r.gpu, r.driver, r.os_name, r.cpu_cores, r.ram_mb])
	# the bucket edges, one frame just under and one on each: 8.0 is in the second bucket, 16.7 in the fourth, 50.0 in the seventh (and not a hitch), 250.0 in the last
	var edges := a_collector()
	edges.set_area("graves")
	var edge_ms: Array[float] = [7.999, 8.0, 11.999, 12.0, 16.699, 16.7, 24.999, 25.0, 33.399, 33.4, 49.999, 50.0, 50.001, 99.999, 100.0, 249.999, 250.0, 9999.0]
	for ms in edge_ms:
		edges.frame(ms)
	var edge_hist: Array = [0, 0, 0, 0, 0, 0, 0, 0, 0]
	for ms in edge_ms:
		edge_hist[ref_bucket(ms)] += 1
	check(edges.snapshot()["hist"] == edge_hist and edge_hist == [1, 2, 2, 2, 2, 2, 3, 2, 2], "each edge lands where the contract's table puts it: %s" % [edges.snapshot()["hist"]])
	check(edges.hitches == 6 and edges.worst_ms == 9999.0, "frames over 50 ms are hitches, 50.0 itself is not (%d)" % edges.hitches)
	edges.queue_free()
	# a known sequence: the median lies in a bucket of identical frames, the p99 is the first frame of another
	var seq: Array[float] = []
	for pair: Array in [[7.0, 200], [10.0, 100], [16.6, 600], [20.0, 50], [30.0, 20], [40.0, 10], [60.0, 14], [150.0, 10], [400.0, 1]]:
		for i in int(pair[1]):
			seq.append(float(pair[0]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261018
	for i in range(seq.size() - 1, 0, -1):   # a fixed shuffle: the order must not matter
		var j := rng.randi_range(0, i)
		var t := seq[i]
		seq[i] = seq[j]
		seq[j] = t
	var want_hist: Array = [0, 0, 0, 0, 0, 0, 0, 0, 0]
	var sum := 0.0
	var hitches := 0
	var area_sum := {"graves": 0.0, "warren": 0.0}
	var area_n := {"graves": 0, "warren": 0}
	var cur := "graves"
	r.set_area(cur)
	for k in seq.size():
		if k == seq.size() / 2:
			cur = "warren"
			r.set_area(cur)
			r.died()
			r.died()
		var ms := seq[k]
		r.frame(ms)
		want_hist[ref_bucket(ms)] += 1
		sum += ms
		if ms > 50.0:
			hitches += 1
		area_sum[cur] += ms
		area_n[cur] += 1
	var sorted := seq.duplicate()
	sorted.sort()
	var snap := r.snapshot()
	check(r.count == seq.size() and snap["hist"] == want_hist and want_hist == [200, 100, 600, 50, 20, 10, 14, 10, 1], "every frame is in the bucket the table says (%s)" % [snap["hist"]])
	check(absf(r.sum_ms - sum) < 0.0001 and absf(r.seconds() - sum / 1000.0) < 0.0000001, "the time is the sum of the frames (%.3f s)" % r.seconds())
	check(r.worst_ms == 400.0 and r.hitches == hitches and hitches == 25, "the worst frame and the frames over 50 ms: worst %s, hitches %d" % [r.worst_ms, r.hitches])
	var p := r.finish("quit")
	var f: Dictionary = p["frames"]
	check(int(f["count"]) == seq.size() and absf(float(f["avgMs"]) - sum / seq.size()) < 0.006, "the average is the sum over the count (%s vs %.4f)" % [f["avgMs"], sum / seq.size()])
	check(absf(float(f["p50Ms"]) - 16.6) < 0.0051 and absf(float(f["p99Ms"]) - 150.0) < 0.0051, "p50 and p99 on the sequence (%s, %s)" % [f["p50Ms"], f["p99Ms"]])
	check(absf(float(f["p50Ms"]) - exact_rank(sorted, 0.5)) < 0.0051 and absf(float(f["p99Ms"]) - exact_rank(sorted, 0.99)) < 0.0051, "...which are the exact order statistics (%s, %s)" % [exact_rank(sorted, 0.5), exact_rank(sorted, 0.99)])
	check(float(f["worstMs"]) == 400.0 and int(f["hitches"]) == 25 and f["hist"] == want_hist, "the payload carries the worst frame, the hitches and the histogram")
	var a: Dictionary = p["areas"]
	check(a.keys().size() == 2 and a.has("graves") and a.has("warren") and not a.has(""), "two areas (the empty first one had no frame: it is not listed): %s" % [a.keys()])
	for id: String in ["graves", "warren"]:
		var row: Dictionary = a[id]
		check(absf(float(row["seconds"]) - area_sum[id] / 1000.0) <= 0.05 and absf(float(row["avgMs"]) - area_sum[id] / area_n[id]) < 0.006, "%s: %.1f s, average %.2f ms (%s)" % [id, area_sum[id] / 1000.0, area_sum[id] / area_n[id], row])
	check(int(a["graves"]["deaths"]) == 0 and int(a["warren"]["deaths"]) == 2, "deaths are counted in the area the hero is in (0 and 2)")
	check(p["endArea"] == "warren", "the session ended in the area the last frame was in")
	r.queue_free()
	# the estimate on spread-out frames: every bucket holds many different frame times, and the histogram's p50 and p99 stay within half a millisecond of the exact ones
	var spread := a_collector()
	spread.set_area("graves")
	var ex: Array = []
	for i in 20000:
		var ms := 4.0 + rng.randf() * 36.0 if i % 50 != 0 else 40.0 + rng.randf() * 160.0
		spread.frame(ms)
		ex.append(ms)
	ex.sort()
	var sp := spread.finish("quit")
	var e50 := exact_rank(ex, 0.5)
	var e99 := exact_rank(ex, 0.99)
	check(absf(float(sp["frames"]["p50Ms"]) - e50) < 0.5 and absf(float(sp["frames"]["p99Ms"]) - e99) < 3.0, "on 20,000 spread frames the p50 and p99 are within 0.5 ms (p50) and 3 ms (p99, a sparse tail) of the exact ones (%s vs %.2f, %s vs %.2f)" % [sp["frames"]["p50Ms"], e50, sp["frames"]["p99Ms"], e99])
	spread.queue_free()
	# a frame over 10 s is not play; a negative one is 0; a minimized window's frames are skipped
	var c := a_collector()
	c.set_area("graves")
	c.frame(20000.0)
	c.frame(-5.0)
	check(c.count == 2 and c.worst_ms == 10000.0 and absf(c.sum_ms - 10000.0) < 0.001, "a frame of 20 s counts as 10 s, a negative one as 0")
	c._slow_ms = 0.0
	c.idle = true
	for i in 10:
		c.frame(16.6)
	check(c.count == 2, "a minimized window's frames are not counted")
	c.idle = false
	c.frame(16.6)
	check(c.count == 3, "and counting goes on when it is back")
	c.queue_free()
	var empty := a_collector()
	var ep := empty.finish("quit")
	var finite := true
	for k: String in ["avgMs", "p50Ms", "p99Ms", "worstMs"]:
		finite = finite and is_finite(float(ep["frames"][k]))
	check(finite and int(ep["frames"]["count"]) == 0 and ep["areas"].is_empty(), "a session with no frame has finite numbers and no area")
	empty.queue_free()


# ------------------------------------------------------------------------------------------------------------------ the payload

## Everything the contract (the play-report contract of ROADMAP Phase 1, POST /api/play-reports) says about the body, as problems found.
func contract_problems(p: Dictionary) -> Array:
	var bad: Array = []
	var keys := p.keys()
	keys.sort()
	var want := CONTRACT_KEYS.duplicate()
	want.sort()
	if keys != want:
		bad.append("keys: %s" % [keys])
		return bad
	var ints := {"discipline": [0, 20], "level": [0, 200], "partySize": [1, 4], "cpuCores": [1, 512], "ramMb": [0, 4194304], "fpsCap": [0, 1000]}
	for k: String in ints:
		if typeof(p[k]) != TYPE_INT or p[k] < ints[k][0] or p[k] > ints[k][1]:
			bad.append("%s %s not an int in %s" % [k, p[k], ints[k]])
	var caps := {"version": 40, "endArea": 24, "gpu": 120, "driver": 60, "os": 40, "resolution": 20}
	for k: String in caps:
		if typeof(p[k]) != TYPE_STRING or (p[k] as String).length() > caps[k] or p[k] != (p[k] as String).strip_edges():
			bad.append("%s is not a trimmed string of at most %d" % [k, caps[k]])
		for ch in (p[k] as String):
			if ch.unicode_at(0) < 32 or ch.unicode_at(0) == 127:
				bad.append("%s holds a control character" % k)
				break
	if RegEx.create_from_string("^[A-Za-z0-9_-]{16,64}$").search(String(p["reportId"])) == null:
		bad.append("reportId")
	if not (typeof(p["seconds"]) in [TYPE_FLOAT, TYPE_INT] and is_finite(float(p["seconds"])) and p["seconds"] >= 0.0 and p["seconds"] <= 86400.0):
		bad.append("seconds")
	if not p["endReason"] in ["quit", "logout", "switch", "crash", "disconnect", "unknown"]:
		bad.append("endReason %s" % p["endReason"])
	if not p["preset"] in ["low", "medium", "high", "ultra", "custom"]:
		bad.append("preset %s" % p["preset"])
	if typeof(p["host"]) != TYPE_BOOL or typeof(p["vsync"]) != TYPE_BOOL:
		bad.append("host / vsync are not booleans")
	var f: Variant = p["frames"]
	if not (f is Dictionary) or (f as Dictionary).keys().size() != FRAME_KEYS.size() or FRAME_KEYS.any(func(k: String) -> bool: return not (f as Dictionary).has(k)):
		bad.append("frames keys")
	else:
		for k: String in ["avgMs", "p50Ms", "p99Ms", "worstMs"]:
			if not (typeof(f[k]) in [TYPE_FLOAT, TYPE_INT]) or not is_finite(float(f[k])) or f[k] < 0.0:
				bad.append("frames.%s" % k)
		if typeof(f["count"]) != TYPE_INT or typeof(f["hitches"]) != TYPE_INT or f["hitches"] > f["count"]:
			bad.append("frames.count / hitches")
		var h: Array = f["hist"]
		var n := 0
		for c in h:
			if typeof(c) != TYPE_INT or c < 0:
				bad.append("a histogram count is not an int")
			n += int(c)
		if h.size() != 9 or n != f["count"]:
			bad.append("hist: %d buckets holding %d of %s" % [h.size(), n, f["count"]])
		if f["count"] > 0 and not (f["p50Ms"] <= f["p99Ms"] and f["p99Ms"] <= f["worstMs"]):
			bad.append("p50 <= p99 <= worst does not hold")
	var areas: Dictionary = p["areas"]
	if areas.size() > 24:
		bad.append("more than 24 areas")
	for id: String in areas:
		var row: Dictionary = areas[id]
		if id.length() > 24 or id == "" or row.keys().size() != 3 or AREA_KEYS.any(func(k: String) -> bool: return not row.has(k)) or typeof(row["deaths"]) != TYPE_INT or not (typeof(row["seconds"]) in [TYPE_FLOAT, TYPE_INT]) or not (typeof(row["avgMs"]) in [TYPE_FLOAT, TYPE_INT]):
			bad.append("area %s: %s" % [id, row])
	var sids: Array = p["sessionIds"]
	if sids.size() > 20 or sids.any(func(s: Variant) -> bool: return typeof(s) != TYPE_STRING or (s as String).length() > 64 or (s as String) == ""):
		bad.append("sessionIds")
	return bad


func the_payload() -> void:
	var r := a_collector()
	r.set_area("graves")
	for i in 600:
		r.frame(16.6 + float(i % 7))
	r.session_ids = ["11111111-1111-4111-8111-111111111111"]
	r.level = 12
	r.discipline = 2
	r.preset = "medium"
	var p := r.finish("logout")
	check(contract_problems(p).is_empty(), "a report has exactly the contract's shape: %s" % [contract_problems(p)])
	check(p["endReason"] == "logout" and p["version"] == "20261018.211258-bb6acd8" and p["level"] == 12 and p["discipline"] == 2 and p["preset"] == "medium" and p["sessionIds"] == ["11111111-1111-4111-8111-111111111111"], "it names the build, the end, the hero and the preset")
	var text := JSON.stringify(p)
	var back: Variant = JSON.parse_string(text)
	check(back is Dictionary and JSON.stringify(DmPlayReport.build_payload(r.snapshot(), "logout")) == text, "it is JSON, and a snapshot read back from a file builds the same body")
	check(contract_problems(DmPlayReport.build_payload(JSON.parse_string(JSON.stringify(r.snapshot())), "crash")).is_empty(), "also after the file's round trip (every number a float: JSON.parse_string)")
	check(not text.to_lower().contains("tester") and not text.contains("@") and not text.contains("user://") and not text.to_lower().contains("character"), "nothing personal: no name, no email, no path")
	print("INFO play_report: a report is %d bytes of JSON" % text.length())
	# out of range, over the caps, odd: clamped to the contract, never left out
	var wild := r.snapshot()
	wild["level"] = 999
	wild["discipline"] = -3
	wild["partySize"] = 9
	wild["gpu"] = " " + "G".repeat(300) + " "
	wild["preset"] = "ultra-low"
	wild["cpuCores"] = 0
	wild["ramMb"] = -1
	wild["fpsCap"] = 5000
	wild["sumMs"] = 1.0e12
	wild["sessionIds"] = ["x".repeat(100)]
	for i in 30:
		wild["sessionIds"].append("s%d" % i)
		(wild["areas"] as Dictionary)["area%d" % i] = [1000.0 * (i + 1), 10.0, 1.0]
	var wp := DmPlayReport.build_payload(wild, "bogus")
	check(contract_problems(wp).is_empty(), "a value outside the contract is clamped, capped or named custom / unknown: %s" % [contract_problems(wp)])
	check(wp["level"] == 200 and wp["discipline"] == 0 and wp["partySize"] == 4 and wp["gpu"].length() == 120 and wp["preset"] == "custom" and wp["endReason"] == "unknown" and wp["seconds"] == 86400.0
		and wp["cpuCores"] == 1 and wp["ramMb"] == 0 and wp["fpsCap"] == 1000, "...to the nearest value")
	check(wp["areas"].size() == 24 and wp["areas"].has("area29") and not wp["areas"].has("area0") and wp["sessionIds"].size() == 20, "more than 24 areas keep the 24 longest, more than 20 session ids the first 20")
	var damaged := DmPlayReport.build_payload({"reportId": "damaged-report-0123456789", "count": 5, "hist": [1, 2]}, "crash")
	check(contract_problems(damaged).is_empty(), "a damaged file still builds a body (%s)" % [contract_problems(damaged)])
	r.queue_free()


# ------------------------------------------------------------------------------------------------------------------ a real game scene

func start_game(areas: Array, ch: Dictionary = character) -> DmNextGame:
	var ng: DmNextGame = load("res://next/next_game.tscn").instantiate()
	ng.name = "NextGame"
	root.add_child(ng)
	await ng.start(ch, api, {"areas": areas, "name": "tester", "hud": false, "audio": false, "seed": 20261018, "waves": false, "wander": false, "persist": false})
	return ng


func a_real_game_scene() -> void:
	mock = DmOffline.make_mock("")   # memory only: no file, no server
	api = DmOffline.make_api(mock)
	var reg := await api.register("reporter", "r@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	character = ch.data
	g = await start_game(["graves", "ossuary"])
	check(g.ready_ and g.local_body() != null, "an offline game scene is ready")
	var r := a_collector()
	last_report = r
	check(r.count == 0, "nothing is counted before a scene is attached")
	await process_frame
	await process_frame
	check(r.count == 0, "...even with frames running")
	r.attach(g)
	check(r.count == 0 and r.game == g, "attaching counts nothing by itself (the first frame has no earlier stamp)")
	for i in 30:
		await process_frame
	check(r.count >= 20 and r.count <= 31 and r.sum_ms > 0.0, "the attached scene's frames are counted by _process (%d frames, %.0f ms)" % [r.count, r.sum_ms])
	var area := g.area_id
	check(area == "graves" and r.snapshot()["endArea"] == "graves", "the hero is in the Graves and the report follows it (%s)" % area)
	check(r.party_size == 1 and r.hosted and r.discipline == int(g.character["class_index"]) and r.level == int(g.character["level"]), "alone: a party of one, hosted, the hero's discipline %d and level %d" % [r.discipline, r.level])
	# the backend party session arrives a moment after the scene is ready (its open is not awaited)
	check(await until(func() -> bool: return g.party_session_id() != "", 10.0), "the host's backend session opened (%s)" % g.party_session_id())
	r.poll()
	check(r.session_ids == [g.party_session_id()], "the report names that session: %s" % [r.session_ids])
	r.poll()
	check(r.session_ids.size() == 1, "and only once")
	# the settings are read from the game
	r.read_settings(g)
	var gp := r.snapshot()
	check(gp["preset"] == g.perf.preset and gp["resolution"] == "%dx%d" % [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y] and gp["fpsCap"] == Engine.max_fps
		and gp["vsync"] == (DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED), "the preset, the window, V-Sync and the fps cap are the game's (%s %s vsync %s cap %s)" % [gp["preset"], gp["resolution"], gp["vsync"], gp["fpsCap"]])
	# a death is counted once, in the area the hero is in
	var hero := g.local_body()
	hero.take_damage(1.0e9, 0, "melee")
	r.poll()
	r.poll()
	check(not hero.alive and r.snapshot()["areas"]["graves"][2] == 1.0, "a fallen hero is one death in the Graves, however long he lies there")
	hero._respawn()
	r.poll()
	hero.take_damage(1.0e9, 0, "melee")
	r.poll()
	check(r.snapshot()["areas"]["graves"][2] == 2.0, "getting up and falling again is a second death")
	hero._respawn()
	r.poll()
	# an area change: the frames and the next death are the new area's
	g.world.set_unlocked(DmNextWorld.every_area())
	var rect: Dictionary = DmContent.area("ossuary")["rect"]
	hero.teleport(g.world.nav_closest(Vector3((float(rect["x0"]) + float(rect["x1"])) * 0.5, 0.0, (float(rect["z0"]) + float(rect["z1"])) * 0.5)))
	check(await until(func() -> bool: return g.area_id == "ossuary", 5.0), "the hero walked into the Ossuary (%s)" % g.area_id)
	var graves_ms := float(r.snapshot()["areas"]["graves"][0])
	for i in 20:
		await process_frame
	hero.take_damage(1.0e9, 0, "melee")
	r.poll()
	var s := r.snapshot()
	check(r.snapshot()["endArea"] == "ossuary" and float(s["areas"]["graves"][0]) == graves_ms and float(s["areas"]["ossuary"][1]) >= 15.0 and s["areas"]["ossuary"][2] == 1.0 and s["areas"]["graves"][2] == 2.0,
		"the Ossuary has its own frames and its own death, the Graves kept theirs (%s)" % [s["areas"]])
	hero._respawn()
	# the level and the party
	g.character["level"] = 7
	r.poll()
	check(r.level == 7, "the level is the hero's now")
	r.party_seen(3, false)
	check(r.party_size == 3 and not r.hosted, "a party of 3 that someone else hosted")
	r.party_seen(2, true)
	check(r.party_size == 3 and not r.hosted, "a smaller party later changes nothing")
	r.party_seen(5, true)
	check(r.party_size == 4 and r.hosted, "the party is at most 4 (the contract's), and the host flag is the one at the largest")
	g.session.player_joined.emit(1)
	check(r.party_size == 4, "the session's own roster event reads the roster (one player) without lowering it")
	# detach: nothing more is counted, the last numbers are kept
	r.detach()
	var n := r.count
	for i in 10:
		await process_frame
	check(r.game == null and r.count == n and not g.area_changed.is_connected(r.set_area), "a detached report counts nothing and listens to nothing")
	# a second scene (a hand-over: a party joined, a discipline change): the same report goes on, and names both backend sessions
	var first_id := String(g.party_session_id())
	await g.leave()
	g.queue_free()
	await process_frame
	g = await start_game(["graves"])
	r.attach(g)
	check(await until(func() -> bool: return g.party_session_id() != "", 10.0), "the next scene opened its own backend session")
	r.poll()
	check(r.session_ids.size() == 2 and r.session_ids[0] == first_id and r.session_ids[1] == g.party_session_id() and first_id != g.party_session_id(), "the report names the sessions of both scenes, in order: %s" % [r.session_ids])
	check(r.count >= n and r.snapshot()["areas"].has("ossuary") and r.snapshot()["areas"].has("graves"), "and keeps its numbers (%d frames before, %d now) and its areas" % [n, r.count])
	var ended := r.finish("quit")
	check(contract_problems(ended).is_empty() and ended["sessionIds"].size() == 2 and ended["partySize"] == 4 and ended["level"] == 7 and ended["areas"]["ossuary"]["deaths"] == 1 and ended["areas"]["graves"]["deaths"] == 2,
		"the finished report of two scenes is in the contract's shape, with %s" % [contract_problems(ended)])
	r.queue_free()
	last_report = null
	await g.leave()
	g.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the save and the crash

func the_save_and_the_crash() -> void:
	_remove_tree(ProjectSettings.globalize_path(scratch))
	var r := a_collector()
	r.autosave = true
	r.set_area("graves")
	var live := DmPlayReportQueue.live_path(r.report_id)
	check(not FileAccess.file_exists(live), "a new session has no live file")
	var min_s := DmPlayReport.MIN_SECONDS
	var every_s := DmPlayReport.SAVE_EVERY_MS / 1000.0
	feed(r, min_s * 0.66)
	check(not FileAccess.file_exists(live), "nothing is saved before the minimum session length")
	feed(r, min_s * 0.42)   # a little over it in all
	check(FileAccess.file_exists(live), "at the minimum session length the first save is made")
	var s1: Variant = JSON.parse_string(FileAccess.get_file_as_string(live))
	var count1 := int(s1["count"]) if s1 is Dictionary else -1
	check(s1 is Dictionary and count1 >= frames_for(min_s) and count1 <= frames_for(min_s) + 50 and String(s1["reportId"]) == r.report_id, "it is the session's state at that point (%d of %d frames)" % [count1, r.count])
	feed(r, every_s * 0.8)   # most of the interval
	var s2: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(live))
	check(int(s2["count"]) == count1, "no save at every slow tick: nothing new before the interval after the first save has passed (%d)" % int(s2["count"]))
	feed(r, every_s * 0.2 + min_s * 0.2)   # past the interval
	var s3: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(live))
	check(int(s3["count"]) > count1 and int(s3["count"]) <= r.count, "the next save came an interval after the first (%d, then %d of %d)" % [count1, int(s3["count"]), r.count])
	var count3 := int(s3["count"])
	feed(r, every_s * 0.1)
	s3 = JSON.parse_string(FileAccess.get_file_as_string(live))
	check(int(s3["count"]) == count3, "and none in between (%d)" % int(s3["count"]))
	print("INFO play_report: the live file is %d bytes" % FileAccess.get_file_as_string(live).length())
	# a start that finds it
	var now := Time.get_unix_time_from_system()
	check(DmPlayReportQueue.recover(now) == 0 and FileAccess.file_exists(live), "a live file written a moment ago is left alone (another window of the game may be playing)")
	check(DmPlayReportQueue.pending_count() == 0, "...and nothing is queued")
	# plus the kinds that are only removed: a short session, a file that is no report
	var short := DmPlayReport.new()
	root.add_child(short)
	short.begin("dev")
	short.set_area("graves")
	feed(short, min_s * 0.2)
	short.autosave = true
	short.save_live()
	DmPlayReportQueue.write_live("garbage-file-0123456789", {"x": 1})
	var junk := FileAccess.open(DmPlayReportQueue.live_path("not-json-at-all-0123456789"), FileAccess.WRITE)
	junk.store_string("{{{ not json")
	junk.close()
	var queued := DmPlayReportQueue.recover(now + 1000.0)
	check(queued == 1, "at the next start (the file is old) the unfinished session is queued: %d" % queued)
	var q := DmPlayReportQueue.pending()
	check(q.size() == 1 and q[0]["endReason"] == "crash" and q[0]["reportId"] == r.report_id and int(q[0]["frames"]["count"]) == int(s3["count"]) and q[0]["endArea"] == "graves", "as a \"crash\" report with the last save's numbers")
	check(contract_problems(q[0]).is_empty(), "in the contract's shape: %s" % [contract_problems(q[0])])
	check(not FileAccess.file_exists(live) and not FileAccess.file_exists(DmPlayReportQueue.live_path(short.report_id)) and not FileAccess.file_exists(DmPlayReportQueue.live_path("not-json-at-all-0123456789"))
		and not FileAccess.file_exists(DmPlayReportQueue.live_path("garbage-file-0123456789")), "every live file is gone: the short one, the damaged ones and the queued one were only removed or turned into a report")
	check(DmPlayReportQueue.recover(now + 2000.0) == 0 and DmPlayReportQueue.pending_count() == 1, "a second start finds nothing more")
	# a session that ends: queued and its live file removed; a short one is not worth a report
	var done := a_collector()
	done.autosave = true
	done.set_area("warren")
	feed(done, min_s * 1.1)
	check(FileAccess.file_exists(DmPlayReportQueue.live_path(done.report_id)), "the finished session had a live file")
	check(DmPlayReportQueue.end_session(done, "switch") and not FileAccess.file_exists(DmPlayReportQueue.live_path(done.report_id)), "ending it queues the report and removes the live file")
	var qq := DmPlayReportQueue.pending()
	check(qq.size() == 2 and qq[1]["endReason"] == "switch" and qq[1]["reportId"] == done.report_id and qq[1]["endArea"] == "warren", "it waits behind the crash report")
	var tiny := a_collector()
	tiny.autosave = true
	tiny.set_area("graves")
	feed(tiny, min_s * 0.5)
	check(not DmPlayReportQueue.end_session(tiny, "quit") and DmPlayReportQueue.pending_count() == 2, "a session of half the minimum is not worth a report: nothing is queued")
	var none := a_collector()
	check(not DmPlayReportQueue.end_session(none, "quit") and DmPlayReportQueue.pending_count() == 2, "nor one with no frame")
	for c: DmPlayReport in [r, short, done, tiny, none]:
		c.queue_free()


# ------------------------------------------------------------------------------------------------------------------ the queue

func a_report(i: int) -> Dictionary:
	var c := a_collector()
	c.set_area("graves")
	feed(c, DmPlayReport.MIN_SECONDS * 1.1)
	var p := c.finish("quit")
	p["reportId"] = "queued-report-%04d-abcdef" % i
	c.queue_free()
	return p


func the_queue() -> void:
	_remove_tree(ProjectSettings.globalize_path(scratch))
	var keep := DmPlayReportQueue.KEEP
	for i in keep + 2:
		DmPlayReportQueue.add(a_report(i))
	var q := DmPlayReportQueue.pending()
	check(q.size() == keep, "the queue keeps its newest %d" % keep)
	check(q[0]["reportId"] == "queued-report-0002-abcdef" and q[keep - 1]["reportId"] == "queued-report-%04d-abcdef" % (keep + 1), "the oldest two were dropped, the order is oldest first")
	DmPlayReportQueue.add(a_report(keep + 1))
	check(DmPlayReportQueue.pending_count() == keep, "a report already queued is not queued twice")
	check(FileAccess.get_file_as_string(DmPlayReportQueue.queue_file()).length() < 2000 * keep, "the queue file is small (%d bytes for %d reports)" % [FileAccess.get_file_as_string(DmPlayReportQueue.queue_file()).length(), keep])


# ------------------------------------------------------------------------------------------------------------------ sending

func sending() -> void:
	_remove_tree(ProjectSettings.globalize_path(scratch))
	# the route, directly: a report is accepted and answers its id, the same reportId answers the same id again, a bad one is refused
	var p1 := a_report(1)
	var r1: DmResult = await api.post_play_report(p1)
	check(r1.ok and int(r1.data["id"]) == 1 and mock.play_reports.size() == 1 and mock.play_reports[0]["report"]["reportId"] == p1["reportId"], "the mock takes a report and answers {id}")
	var again: DmResult = await api.post_play_report(p1)
	check(again.ok and int(again.data["id"]) == 1 and mock.play_reports.size() == 1, "a repeated reportId answers the first id and adds no row")
	var bad: DmResult = await api.post_play_report({"reportId": "short"})
	check(not bad.ok and bad.status == 400, "a bad reportId is refused with 400 (%s)" % bad.error)
	mock.play_reports.clear()
	# the queue, in order
	for i in 3:
		DmPlayReportQueue.add(a_report(10 + i))
	check(await DmPlayReportQueue.flush(api) == 3 and DmPlayReportQueue.pending_count() == 0, "flush sends the three queued reports and the queue is empty")
	check(mock.play_reports.map(func(row: Dictionary) -> String: return row["report"]["reportId"]) == ["queued-report-0010-abcdef", "queued-report-0011-abcdef", "queued-report-0012-abcdef"], "oldest first")
	check(contract_problems(mock.play_reports[0]["report"]).is_empty(), "what the server saw is in the contract's shape")
	# a resend after a lost reply is one row
	DmPlayReportQueue.add(a_report(10))
	check(await DmPlayReportQueue.flush(api) == 1 and mock.play_reports.size() == 3 and DmPlayReportQueue.pending_count() == 0, "a report whose answer was lost and is sent again is still one row")
	# what leaves the queue and what stays
	for pair: Array in [[503, true], [429, true], [401, true], [404, true], [500, true], [400, false], [422, false], [413, false]]:
		DmPlayReportQueue.add(a_report(20))
		var code: int = pair[0]
		var down := DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": code, "text": "{\"success\":false,\"code\":\"x\",\"error\":\"later\"}"})
		down.set_token("t")
		var sent := await DmPlayReportQueue.flush(down)
		check(sent == 0 and (DmPlayReportQueue.pending_count() == 1) == bool(pair[1]), "a %d: the report %s" % [code, "stays queued" if pair[1] else "leaves (sending it again would not help)"])
		_remove_tree(ProjectSettings.globalize_path(scratch))
	DmPlayReportQueue.add(a_report(21))
	var unreachable := DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": 0, "text": "", "network_error": true})
	unreachable.set_token("t")
	check(await DmPlayReportQueue.flush(unreachable) == 0 and DmPlayReportQueue.pending_count() == 1, "no network: it stays")
	check(await DmPlayReportQueue.flush(DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":1}}"})) == 0 and DmPlayReportQueue.pending_count() == 1, "no login: nothing is sent")
	check(await DmPlayReportQueue.flush(null) == 0, "no api: nothing is sent")
	# a report queued while another is on its way is not lost
	var posted: Array = []
	var busy := DmApi.new(func(req: Dictionary) -> Dictionary:
		var body: Dictionary = JSON.parse_string(String(req["body"]))
		posted.append(body["reportId"])
		if posted.size() == 1:
			DmPlayReportQueue.add(a_report(22))   # a session ended while this send was in flight
		return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":%d}}" % posted.size()})
	busy.set_token("t")
	check(await DmPlayReportQueue.flush(busy) == 2 and posted == ["queued-report-0021-abcdef", "queued-report-0022-abcdef"] and DmPlayReportQueue.pending_count() == 0, "a report queued during a send is sent in the same round, not overwritten (%s)" % [posted])
	# every request is a POST of JSON to the plays route, with the login
	var seen: Array = []
	var spy := DmApi.new(func(req: Dictionary) -> Dictionary:
		seen.append(req)
		return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":1}}"})
	spy.set_token("tok")
	spy.base_url = DmConfig.API_BASE
	DmPlayReportQueue.add(a_report(23))
	await DmPlayReportQueue.flush(spy)
	check(seen.size() == 1 and seen[0]["method"] == "POST" and String(seen[0]["url"]).ends_with("/api/play-reports") and DmConfig.allows_url(String(seen[0]["url"])) and seen[0]["headers"]["Authorization"] == "Bearer tok"
		and contract_problems(DmJson.parse(String(seen[0]["body"]))).is_empty(), "the request: POST /api/play-reports with the player's login, the body the report as JSON")


# ------------------------------------------------------------------------------------------------------------------ nothing leaves a script run

func nothing_leaves_a_script_run() -> void:
	_remove_tree(ProjectSettings.globalize_path(scratch))
	var none := PackedStringArray()
	check(DmPlayReportQueue.records("online", false, none), "a release build's online session is recorded")
	check(not DmPlayReportQueue.records("online", true, none), "not a debug build's")
	check(not DmPlayReportQueue.records("online", false, PackedStringArray(["--headless", "--script", "res://tests/x.gd"])), "not a script run's")
	for m: String in ["dev_offline", "benchmark", "test", ""]:
		check(not DmPlayReportQueue.records(m, false, none), "not the %s mode's" % ("\"" + m + "\""))
	check(not DmPlayReportQueue.records("dev_offline", true, none) and not DmPlayReportQueue.records("benchmark", true, PackedStringArray(["--script"])), "not in any combination")
	# a real transport with a login: flush must stop before it asks (and if it ever asked, the transport still sends nothing)
	DmPlayReportQueue.add(a_report(30))
	var queued := DmPlayReportQueue.pending_count()
	var t := DmHttpTransport.new()
	root.add_child(t)
	var real := DmApi.new(t.request_callable())
	real.base_url = "https://example.invalid/death-muffin/test-api"
	real.set_token("t")
	var errors_before := errlog.errors.size()
	check(DmPlayReportQueue.over_the_network_from_a_script(real), "a script run sees a real transport as the network")
	check(await DmPlayReportQueue.flush(real) == 0 and DmPlayReportQueue.pending_count() == queued, "flush does not send a report through a real transport from a script: it stays queued (%d)" % queued)
	check(errlog.errors.size() == errors_before and t.get_child_count() == 0, "and the transport was never asked (no request node, no refusal logged)")
	t.queue_free()
	var mock_api := DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":1}}"})
	mock_api.set_token("t")
	check(not DmPlayReportQueue.over_the_network_from_a_script(mock_api) and await DmPlayReportQueue.flush(mock_api) == queued, "a mock answers: the queue is sent to it")
	# DmMain's own gate in this (debug, script) run
	var m := DmMain.new()
	m.mode = "online"
	check(not m.plays_report, "a DmMain starts with the gate shut")
	m.free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ DmMain's wiring

func dm_main_wiring() -> void:
	_remove_tree(ProjectSettings.globalize_path(scratch))
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var m: DmMain = load("res://main/main.tscn").instantiate()
	m.mode = "test"
	m.plays_report = true   # a debug build never records: the wiring is tried with the gate forced open (the gate itself is checked above)
	m.api = api
	m.persist_token = false
	m.start_opts = {"audio": false, "seed": 20261018, "waves": false, "wander": false, "areas": ["graves"], "persist": false}
	var uncounted_ready := [false]   # a report attached to a scene that is not ready
	var watch := func() -> void:
		if m.report != null and m.report.game != null and not m.report.game.ready_:
			uncounted_ready[0] = true
	process_frame.connect(watch)
	root.add_child(m)
	check(m.plays_report and m.report == null, "no report before a game scene is ready")
	await m._dev_quick_start(2)
	check(await until(func() -> bool: return m.slice != null and m.slice.ready_ and DmLoadingScreen.current == null, 90.0), "the boot scene is in its game")
	check(m.report != null and m.report.game == m.slice and m.report.version == DmBuild.version() and m.report.autosave, "the first ready scene starts the session's report, attached to it (%s)" % [m.report.report_id if m.report != null else ""])
	if m.report == null:
		await _drop(m, watch)
		return
	var first_id := m.report.report_id
	for i in 30:
		await process_frame
	check(m.report.count >= 20, "the scene's own frames are counted from the moment it is attached (%d)" % m.report.count)
	feed(m.report, DmPlayReport.MIN_SECONDS * 1.1)   # the headless frames run too fast to make the minimum session: some frames are fed by hand
	check(await until(func() -> bool: return m.slice.party_session_id() != "", 10.0), "the scene's backend session opened")
	var first_scene := m.slice.get_instance_id()
	var sid1 := String(m.slice.party_session_id())
	# a discipline change restarts the game with the changed character: the same report goes on
	m.slice.ui.pa._change_class(11)
	check(await until(func() -> bool: return m.slice != null and m.slice.get_instance_id() != first_scene and m.slice.ready_ and DmLoadingScreen.current == null, 90.0), "a discipline change restarts the game")
	check(m.report != null and m.report.report_id == first_id and m.report.game == m.slice, "the report is the same one and now counts the new scene")
	check(await until(func() -> bool: return m.slice.party_session_id() != "", 10.0), "the new scene's backend session opened")
	m.report.poll()
	check(m.report.session_ids.size() == 2 and m.report.session_ids[0] == sid1 and m.report.discipline == 11, "it names both sessions and the hero is a Reaper now (%s, %d)" % [m.report.session_ids, m.report.discipline])
	check(DmPlayReportQueue.pending_count() == 0 and mock.play_reports.is_empty(), "a hand-over queues and sends nothing")
	feed(m.report, DmPlayReport.MIN_SECONDS * 0.15)
	# Switch character: the report is queued as "switch" at once, and the select screen sends it
	m.slice.ui_host.switch_character()
	check(await until(func() -> bool: return m.slice == null and m.flow != null and m.flow.current_name == "select", 30.0), "Switch character lands on the select screen")
	check(m.report == null, "the session's report is closed")
	check(await until(func() -> bool: return mock.play_reports.size() == 1, 10.0), "the select screen sent it with the login")
	var sent: Dictionary = mock.play_reports[0]["report"] if not mock.play_reports.is_empty() else {}
	print("INFO play_report: a report as the server received it (a Gravecaller turned Reaper, through the real game scenes and the mock; 30 real headless frames, the rest of the time fed by hand; no GPU or window here):\n%s" % JSON.stringify(sent))
	check(sent.get("reportId") == first_id and sent.get("endReason") == "switch" and contract_problems(sent).is_empty() and DmPlayReportQueue.pending_count() == 0,
		"it is the same session, ended \"switch\", in the contract's shape, and the queue is empty (%s)" % [contract_problems(sent)])
	check(sent.get("sessionIds", []).size() == 2 and sent.get("discipline") == 11 and float(sent.get("seconds", 0.0)) >= DmPlayReport.MIN_SECONDS * 1.2, "with both backend sessions, the Reaper and %s s of play" % sent.get("seconds"))
	var sel := m.flow.current as DmCharSelectScreen
	check(sel != null and await sel.choose(11), "picking the Reaper there ...")
	check(await until(func() -> bool: return m.slice != null and m.slice.ready_ and DmLoadingScreen.current == null, 90.0), "... goes back into the game")
	check(m.report != null and m.report.report_id != first_id, "a new session, a new report id")
	feed(m.report, DmPlayReport.MIN_SECONDS * 1.1)
	var second_id := m.report.report_id
	# Log out: queued as "logout" and sent before the token is dropped (2026-10-19: it used to wait for the next login)
	m.slice.ui_host.leave_world()
	check(await until(func() -> bool: return m.slice == null and m.flow != null and m.flow.current_name == "login", 30.0), "Log out lands on the login screen")
	check(m.report == null and DmPlayReportQueue.pending_count() == 0 and mock.play_reports.size() == 2 and mock.play_reports[1]["report"]["reportId"] == second_id
		and mock.play_reports[1]["report"]["endReason"] == "logout", "Log out sent the report as \"logout\" while the login was still good")
	await m._dev_quick_start(2)
	check(await until(func() -> bool: return m.slice != null and m.slice.ready_ and DmLoadingScreen.current == null, 90.0), "a new session starts")
	check(mock.play_reports.size() == 2 and DmPlayReportQueue.pending_count() == 0, "nothing was left to send at the next start")
	check(m.report != null and m.report.report_id != second_id, "...beside a third session")
	var third_id := m.report.report_id
	feed(m.report, DmPlayReport.MIN_SECONDS * 1.1)
	# quit: the report is queued first, before the save
	var last := m.slice
	m.save_all()   # (a coroutine: what runs before its first await is what a quit does first)
	var queued_quit: bool = DmPlayReportQueue.pending_count() == 1 and DmPlayReportQueue.pending()[0]["endReason"] == "quit" and DmPlayReportQueue.pending()[0]["reportId"] == third_id
	var sent_quit: bool = mock.play_reports.size() == 3 and mock.play_reports[2]["report"]["endReason"] == "quit"   # (the mock answers without waiting: the whole quit can run before this line)
	check(m.report == null and (queued_quit or sent_quit), "quit ends the report as \"quit\" at once, before the save (it never waits for the network to write it)")
	check(await until(func() -> bool: return mock.play_reports.size() == 3 and DmPlayReportQueue.pending_count() == 0, 10.0) and mock.play_reports[2]["report"]["reportId"] == third_id,
		"... and sends it before the game closes (the save first, then at most 2 s for the report)")
	await last.leave()
	last.queue_free()
	check(not uncounted_ready[0], "no report was ever attached to a scene that was not ready")
	check(Array(DirAccess.get_files_at(scratch)).filter(func(n: String) -> bool: return n.begins_with("live-")).is_empty(), "no live file is left behind by sessions that ended")
	await _drop(m, watch)


func _drop(m: DmMain, watch: Callable) -> void:
	process_frame.disconnect(watch)
	if m.slice != null:
		var s := m.slice
		m.slice = null
		await s.leave()
		s.queue_free()
	m.queue_free()
	await until(func() -> bool: return DmLoadingScreen.current == null, 5.0)
	await process_frame
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the cost

func cost() -> void:
	var r := a_collector()
	r.set_area("graves")
	var objects_before := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var mem_before := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var n := 200000
	var t0 := Time.get_ticks_usec()
	for i in n:
		r.frame(16.0 + float(i % 7))
	var frame_ns := float(Time.get_ticks_usec() - t0) * 1000.0 / n
	t0 = Time.get_ticks_usec()
	for i in n:
		r._process(0.0)
	var proc_ns := float(Time.get_ticks_usec() - t0) * 1000.0 / n
	var objects_after := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	check(objects_after == objects_before, "400,000 frames made no object (%d before, %d after)" % [objects_before, objects_after])
	check(r.count > n, "the frames were counted")
	print("INFO play_report: the cost of one frame: frame() %.0f ns, the whole _process %.0f ns (%d allocated bytes over 400,000 frames, GDScript on this machine)" % [frame_ns, proc_ns, int(Performance.get_monitor(Performance.MEMORY_STATIC)) - mem_before])
	r.queue_free()


# ------------------------------------------------------------------------------------------------------------------ the end

func finish() -> void:
	DmPlayReportQueue.dir = "user://play_reports"
	_remove_tree(ProjectSettings.globalize_path(scratch))
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	for e in errlog.errors.slice(0, 12):
		printerr("ERROR LOG: " + e)
	if fails == 0:
		print("PASS play_report %d checks" % checks)
	else:
		printerr("FAIL play_report: %d of %d checks" % [fails, checks])
	quit(1 if fails > 0 else 0)


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
