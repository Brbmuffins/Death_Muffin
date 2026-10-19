class_name DmPlayReportQueue
extends RefCounted
## The play reports' files and their sending (client/next/perf/README.md "Play reports"), built like DmBenchHistory. Everything is in `dir` (`user://play_reports`), so a test keeps its own:
##   live-<reportId>.json   the session in progress (DmPlayReport.save_live, at 10 s of play and every minute): a crash leaves it behind. The next start (`recover`) turns a live file that
##                          has not been written for STALE_S into a finished report with endReason "crash" (a younger one may be another running window's);
##   queue.json             the finished reports waiting to be sent, oldest first, at most KEEP (the oldest is dropped).
## Quitting never waits for the network: `end_session` only writes files. `flush` sends the queue with the player's login (DmApi.post_play_report -> POST /api/play-reports) when DmMain
## has a logged-in online api: at the character select, and when a session starts. Never from a script run (every test is one), a debug build, the dev-offline backend or the benchmark's own
## game: `records` is DmMain's one gate, and `flush` refuses a real transport from a script run besides.

const KEEP := 10
const STALE_S := 180.0

static var dir := "user://play_reports"
static var _flushing := false


## True while flush() is sending (the log out and the quit wait on it, bounded).
static func flushing() -> bool:
	return _flushing


static func queue_file() -> String:
	return dir.path_join("queue.json")


static func live_path(report_id: String) -> String:
	return dir.path_join("live-%s.json" % report_id)


## The one gate: a play report is recorded and sent only for a player's online session of a release build. Not in the editor or a debug build, not from a script run, not dev-offline,
## not the benchmark (its game is its own and has no DmMain report).
static func records(mode: String, debug_build: bool, args: PackedStringArray) -> bool:
	return mode == "online" and not debug_build and not ("--script" in args)


## The session ends for `reason`: its live file goes, and its report is queued (unless the session was too short to be worth one: DmPlayReport.MIN_SECONDS). True when queued.
static func end_session(rep: DmPlayReport, reason: String) -> bool:
	var body := rep.finish(reason)
	clear_live(rep.report_id)
	if rep.seconds() < DmPlayReport.MIN_SECONDS or rep.count == 0:
		return false
	add(body)
	return true


static func write_live(report_id: String, state: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(live_path(report_id), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state))


static func clear_live(report_id: String) -> void:
	if FileAccess.file_exists(live_path(report_id)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(live_path(report_id)))


## Queues a finished report (a report id already queued is not added twice); only the newest KEEP stay.
static func add(body: Dictionary) -> void:
	var q := _read()
	for e: Dictionary in q:
		if e.get("reportId") == body.get("reportId"):
			return
	q.append(body)
	_write(q.slice(maxi(0, q.size() - KEEP)))


static func pending_count() -> int:
	return _read().size()


static func pending() -> Array:
	return _read()


## At a start: every live file nobody has written to for STALE_S is a session that ended without ending (a crash, a kill, the PC going down): its report is queued with endReason "crash"
## and the file goes. A session under 10 s of play, or a file that is not a report, is only removed. `now` is unix seconds (a test passes its own). Returns how many were queued.
static func recover(now: float = -1.0) -> int:
	if now < 0.0:
		now = Time.get_unix_time_from_system()
	var queued := 0
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		return 0   # (the first start: nothing was ever saved)
	for name in DirAccess.get_files_at(dir):
		if not (name.begins_with("live-") and name.ends_with(".json")):
			continue
		var path := dir.path_join(name)
		if now - float(FileAccess.get_modified_time(path)) < STALE_S:
			continue   # recently written: another window of the game may be playing
		var s: Variant = DmJson.parse(FileAccess.get_file_as_string(path))   # (not JSON.parse_string: a half-written file is expected input, not an engine error)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if not (s is Dictionary) or float(s.get("sumMs", 0.0)) < DmPlayReport.MIN_SECONDS * 1000.0 or int(s.get("count", 0)) == 0 or String(s.get("reportId", "")).length() < 16:
			continue
		add(DmPlayReport.build_payload(s, "crash"))
		queued += 1
	return queued


## Sends the queued reports (oldest first) with `api` (an online, logged-in DmApi). A report the server accepted, or refused as invalid (400 / 413 / 422, or `success: false`), leaves the queue;
## anything else (no network, 401 / 409 login trouble, 429 over the day's limit, 5xx, an older server without the route) stops and keeps the rest for next time. Returns how many were accepted.
static func flush(api: DmApi) -> int:
	if api == null or api.get_token().is_empty() or _flushing or over_the_network_from_a_script(api):
		return 0
	_flushing = true
	var sent := 0
	for _i in KEEP * 2:   # (bounded: a queue file that cannot be written would send the same report again and again)
		var q := _read()   # (read again each round: a session that ended meanwhile has queued its report)
		if q.is_empty():
			break
		var body: Dictionary = q[0]
		var r := await api.post_play_report(body)
		if not (r.ok or r.status in [200, 400, 413, 422]):
			break
		if r.ok:
			sent += 1
		_write(_read().filter(func(e: Dictionary) -> bool: return e.get("reportId") != body.get("reportId")))
	_flushing = false
	return sent


## True when `api` would carry a report over the network (a DmHttpTransport) from a script run: every test is one, and no test sends a report anywhere but a mock.
static func over_the_network_from_a_script(api: DmApi) -> bool:
	return "--script" in OS.get_cmdline_args() and api.transport.is_valid() and api.transport.get_object() is DmHttpTransport


static func _read() -> Array:
	if not FileAccess.file_exists(queue_file()):
		return []
	var v: Variant = DmJson.parse(FileAccess.get_file_as_string(queue_file()))   # (whole numbers come back as ints, as the server's contract has them)
	return v if v is Array else []


static func _write(rows: Array) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(queue_file(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(rows))
