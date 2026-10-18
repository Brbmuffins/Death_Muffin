class_name DmPlayReport
extends Node
## The play report of one play session (ROADMAP Phase 1, "New: play reports"; what is sent and when: client/next/perf/README.md "Play reports"). DmMain owns one from the first
## ready game scene of a player's session until Log out, Switch character or quit: a party hand-over or a discipline change swaps the game scene but not the session, so the
## report is not a child of the scene. `attach(game)` starts counting that scene's frames, `detach()` stops (before the scene leaves), `finish(reason)` closes it.
##
## What it keeps, all as plain numbers (`snapshot()` is the whole state and the autosave file; `build_payload` turns a snapshot into the body of POST /api/play-reports):
##   - every frame of an attached, ready scene (the loading cover and the warm-up end inside `DmNextGame.start`, DmMain attaches only a ready scene, and a hand-over is detached): count, sum, worst,
##     frames over 50 ms and a 9-bucket histogram (the buckets below), with the smallest and largest frame of each bucket (what `quantile` needs);
##   - per area the hero stands in (`area_changed`): the frames' time and count, and the deaths;
##   - the largest party (the session's roster) and whether the player hosted it, the backend party session ids (`DmNextGame.party_session_id`), the hero's level and discipline;
##   - the PC (GPU, driver, OS, cores, memory: read once) and the settings (preset, window size, V-Sync, fps cap: read at each save and at the end).
## Nothing personal: no account, name, character id or chat is read.
##
## Cost per frame: one `Time.get_ticks_usec` read and a few float and int operations on preallocated arrays and members, no allocation and no call (tests/play_report.gd prints it as INFO). The slow
## tick (every 250 ms of counted frame time) reads the hero's `alive` flag, the party session id, the level and whether the window is minimized; the autosave (at 10 s of play, then every 60 s)
## writes about 0.6 KB.

const BUCKETS := 9
## The histogram's buckets, in ms: <8, <12, <16.7, <25, <33.4, <50, <100, <250, >=250 (the contract's; 16.7 and 33.4 keep a 60 Hz and a 30 Hz frame in the bucket of their own rate). `frame` is the
## only place the edges are written (three comparisons, inline: a call costs more than the comparisons).
const HITCH_MS := 50.0         ## a hitch is a frame over this (the F3 overlay's and the benchmark's number)
const MAX_FRAME_MS := 10000.0  ## a longer frame (the PC slept, the window was held by the system) counts as this: it is not play
const SLOW_MS := 250.0         ## the slow tick, in counted frame time
const MIN_SECONDS := 10.0      ## a session shorter than this is not worth a report (DmPlayReportQueue.end_session drops it)
const SAVE_EVERY_MS := 60000.0
const MAX_AREAS := 24          ## the contract's limits
const MAX_SESSIONS := 20
const END_REASONS := ["quit", "logout", "switch", "crash", "disconnect", "unknown"]

var report_id := ""            ## made once per session (`begin`); a resend carries the same one, so the server counts it once
var version := ""
var game: DmNextGame           ## the scene being counted (null while detached)
var autosave := false          ## DmMain turns it on: the state goes to DmPlayReportQueue.write_live at 10 s of play and every minute after
var idle := false              ## the window is minimized: its frames are not play (set by the slow tick; a test may set it)
var started_at := 0            ## unix seconds
var count := 0                 ## counted frames
var sum_ms := 0.0
var worst_ms := 0.0
var hitches := 0
var party_size := 1
var hosted := true             ## whether the player hosted (or played alone) when the party was at its largest
var session_ids: Array = []
var discipline := 0
var level := 1
var gpu := ""
var driver := ""
var os_name := ""
var cpu_cores := 1
var ram_mb := 0
var preset := ""
var resolution := ""
var vsync := true
var fps_cap := 0

var _hist := PackedInt32Array()
var _bmin := PackedFloat64Array()
var _bmax := PackedFloat64Array()
var _areas := {}               ## area id -> [ms, frames, deaths]
var _area_id := ""
var _cur: Array = [0.0, 0.0, 0.0]   ## the current area's record [ms, frames, deaths] (shared with _areas: a write here is a write there)
var _a_ms := 0.0               ## the frames of the current area not yet added to its record (`_commit_area`): two members are cheaper than an array in the hot path
var _a_n := 0
var _headless := false
var _was_alive := true
var _slow_ms := 0.0
var _save_at_ms := MIN_SECONDS * 1000.0
var _last_us := 0


func _init() -> void:
	_hist.resize(BUCKETS)
	_bmin.resize(BUCKETS)
	_bmax.resize(BUCKETS)
	_bmin.fill(INF)
	_headless = DisplayServer.get_name() == "headless"
	set_area("")


func _ready() -> void:
	set_process(false)   # (a node with a _process starts it on ready: `attach` turns it on)


## Starts the session: its id, the build, the PC.
func begin(version_: String) -> void:
	report_id = make_id()
	version = version_
	started_at = int(Time.get_unix_time_from_system())
	var m := machine()
	gpu = m["gpu"]
	driver = m["driver"]
	os_name = m["os"]
	cpu_cores = m["cores"]
	ram_mb = m["ram_mb"]
	read_settings(null)


## A report id: 16 to 64 characters of [A-Za-z0-9_-] (the contract's); the clock and two random numbers, nothing that names a player.
static func make_id() -> String:
	return "%x-%08x%08x" % [int(Time.get_unix_time_from_system()), randi(), randi()]


## The PC, as the contract wants it: the GPU's name, the rendering driver and its API version, the OS and its version, logical cores, memory in MB.
static func machine() -> Dictionary:
	var drv := RenderingServer.get_current_rendering_driver_name()
	var shown: String = {"vulkan": "Vulkan", "d3d12": "D3D12", "metal": "Metal", "opengl3": "OpenGL 3"}.get(drv, drv)
	var mem: Dictionary = OS.get_memory_info()
	return {
		"gpu": _or_unknown(RenderingServer.get_video_adapter_name()),
		"driver": _or_unknown(("%s %s" % [shown, RenderingServer.get_video_adapter_api_version()]).strip_edges()),
		"os": _or_unknown(("%s %s" % [OS.get_name(), OS.get_version()]).strip_edges()),
		"cores": maxi(1, OS.get_processor_count()),
		"ram_mb": maxi(0, int(mem.get("physical", 0)) / 1048576),
	}


static func _or_unknown(s: String) -> String:
	return s if s.strip_edges() != "" else "unknown"


# ------------------------------------------------------------------------------------------------------------------ the scene being counted

## Counts the frames of `g` (a ready game scene) from the next one on, and follows its area, its roster and its backend session.
func attach(g: DmNextGame) -> void:
	detach()
	game = g
	g.area_changed.connect(set_area)
	g.session.player_joined.connect(_on_roster)
	set_area(g.area_id)
	_on_roster(0)
	_was_alive = true
	_last_us = 0   # the first frame has no earlier stamp
	poll()
	set_process(true)


## Stops counting (call it before the scene leaves): one last slow tick, so the final level, deaths and party are in.
func detach() -> void:
	set_process(false)
	if game == null:
		return
	if is_instance_valid(game):
		if game.is_inside_tree():   # (not when the whole tree is going down: its nodes cannot be read then)
			poll()
			read_settings(game)
		if game.area_changed.is_connected(set_area):
			game.area_changed.disconnect(set_area)
		if game.session != null and game.session.player_joined.is_connected(_on_roster):
			game.session.player_joined.disconnect(_on_roster)
	game = null
	_last_us = 0


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_us == 0:
		_last_us = now
		return
	var ms := (now - _last_us) * 0.001
	_last_us = now
	frame(ms)


## One frame of `ms` (the wall clock between two `_process` calls; tests feed their own). The hot path: no allocation, no call, the current area's sums kept in two members.
func frame(ms: float) -> void:
	if ms > MAX_FRAME_MS:
		ms = MAX_FRAME_MS
	elif ms < 0.0:
		ms = 0.0
	_slow_ms += ms
	if _slow_ms >= SLOW_MS:
		_slow_ms = 0.0
		_slow()
	if idle:
		return
	count += 1
	sum_ms += ms
	_a_ms += ms
	_a_n += 1
	if ms > worst_ms:
		worst_ms = ms
	var b: int
	if ms < 16.7:
		b = 0 if ms < 8.0 else (1 if ms < 12.0 else 2)
	elif ms < 50.0:
		b = 3 if ms < 25.0 else (4 if ms < 33.4 else 5)
	else:
		if ms > HITCH_MS:
			hitches += 1   # (only a frame of 50 ms or more gets here)
		b = 6 if ms < 100.0 else (7 if ms < 250.0 else 8)
	_hist[b] += 1
	if ms < _bmin[b]:
		_bmin[b] = ms
	if ms > _bmax[b]:
		_bmax[b] = ms


func _slow() -> void:
	idle = not _headless and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED   # (the headless server reports every window as minimized)
	poll()
	if autosave and sum_ms >= _save_at_ms:
		_save_at_ms = sum_ms + SAVE_EVERY_MS
		save_live()


## What a slow tick reads from the scene: a death (the hero's `alive` went false: guests see it too), the backend party session, the level and discipline, the area.
func poll() -> void:
	if game == null or not is_instance_valid(game):
		return
	var b := game.local_body()
	var alive := b == null or b.alive
	if _was_alive and not alive:
		died()
	_was_alive = alive
	var sid := game.party_session_id()
	if sid != "" and not session_ids.has(sid) and session_ids.size() < MAX_SESSIONS:
		session_ids.append(sid)
	level = int(game.character.get("level", level))
	discipline = int(game.character.get("class_index", discipline))


## The hero fell, in the area he stands in.
func died() -> void:
	_cur[2] += 1.0


## The hero is in area `id` from now on (the game's `area_changed`; "" before any).
func set_area(id: String) -> void:
	_commit_area()
	_area_id = id.left(24)
	var rec: Variant = _areas.get(_area_id)
	if rec == null:
		rec = [0.0, 0.0, 0.0]
		_areas[_area_id] = rec
	_cur = rec


func _commit_area() -> void:
	_cur[0] += _a_ms
	_cur[1] += float(_a_n)
	_a_ms = 0.0
	_a_n = 0


func _on_roster(_peer_id: int) -> void:
	if game != null and is_instance_valid(game) and game.session != null:
		party_seen(game.session.get_roster().size(), game.session.is_host())


## A roster of `n` players, `is_host` when this player hosts it: the largest party of the session and whether the player hosted when it was that big (the first time it was).
func party_seen(n: int, is_host: bool) -> void:
	if n > party_size:
		party_size = mini(n, 4)
		hosted = is_host


## Time in counted frames, in seconds.
func seconds() -> float:
	return sum_ms / 1000.0


# ------------------------------------------------------------------------------------------------------------------ save and send

## The settings the report names, read now: the preset of the game `g` (the last one kept when null), the window size, V-Sync and the fps cap.
func read_settings(g: DmNextGame) -> void:
	var p: Variant = g.perf if g != null else null
	preset = String(p.preset) if p != null else (preset if preset != "" else DmGraphicsPreset.DEFAULT)
	var win := DisplayServer.window_get_size()
	resolution = "%dx%d" % [win.x, win.y]
	vsync = DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	fps_cap = Engine.max_fps


## The whole state as JSON-able plain values: the autosave file, and what `build_payload` reads (also after a crash, from the file).
func snapshot() -> Dictionary:
	_commit_area()
	var areas := {}
	for id: String in _areas:
		areas[id] = (_areas[id] as Array).duplicate()
	var lo: Array = []
	for b in BUCKETS:
		lo.append(_bmin[b] if _hist[b] > 0 else 0.0)   # (an empty bucket's INF is not JSON)
	return {
		"v": 1, "reportId": report_id, "version": version, "startedAt": started_at,
		"count": count, "sumMs": sum_ms, "worstMs": worst_ms, "hitches": hitches, "hist": Array(_hist), "bmin": lo, "bmax": Array(_bmax),
		"areas": areas, "endArea": _area_id, "partySize": party_size, "host": hosted, "sessionIds": session_ids.duplicate(),
		"discipline": discipline, "level": level, "gpu": gpu, "driver": driver, "os": os_name, "cpuCores": cpu_cores, "ramMb": ram_mb,
		"preset": preset, "resolution": resolution, "vsync": vsync, "fpsCap": fps_cap,
	}


## Writes the in-progress state to user:// (DmPlayReportQueue.write_live): a crash leaves it behind, and the next start sends it as a "crash" report.
func save_live() -> void:
	if game != null and is_instance_valid(game):
		read_settings(game)
	DmPlayReportQueue.write_live(report_id, snapshot())


## The session is over: the contract's body, ended by `reason` (one of END_REASONS). The scene is detached first.
func finish(reason: String) -> Dictionary:
	detach()
	return build_payload(snapshot(), reason)


## The p-quantile (0..1) of the frames in a histogram, by nearest rank: the rank-th smallest frame (rank = ceil(q * count), counted from 1) lies in the first bucket whose running count
## reaches it, and is placed inside that bucket by its rank among the bucket's frames, evenly between the smallest and the largest frame seen in it (so a bucket of identical frames,
## as a V-Sync locked 16.67 ms is, gives exactly that frame, and the first and last frame of a bucket are exact). It never leaves the bucket's own span.
static func quantile(hist: Array, bmin: Array, bmax: Array, q: float) -> float:
	var n := 0
	for c in hist:
		n += int(c)
	if n == 0:
		return 0.0
	var rank := clampi(ceili(q * n), 1, n)
	var before := 0
	for b in hist.size():
		var c := int(hist[b])
		if rank <= before + c:
			if c == 1:
				return float(bmin[b])
			return float(bmin[b]) + (float(bmax[b]) - float(bmin[b])) * float(rank - before - 1) / float(c - 1)
		before += c
	return float(bmax[hist.size() - 1])


## The body of POST /api/play-reports (client/net/dm_api.gd `post_play_report`) from a snapshot: every value in the contract's range, strings capped, numbers rounded.
## `reason` is one of END_REASONS ("unknown" otherwise). Numbers read back from a JSON file are floats: everything is converted.
static func build_payload(s: Dictionary, reason: String) -> Dictionary:
	var hist: Array = (s.get("hist", []) as Array).duplicate()   # (copies: the snapshot is not changed)
	var bmin: Array = (s.get("bmin", []) as Array).duplicate()
	var bmax: Array = (s.get("bmax", []) as Array).duplicate()
	hist.resize(BUCKETS)   # (a damaged file: the buckets it lacks are empty)
	bmin.resize(BUCKETS)
	bmax.resize(BUCKETS)
	var counts: Array = []
	var n := 0
	for i in BUCKETS:
		var c := maxi(0, int(hist[i]) if hist[i] != null else 0)
		counts.append(c)
		n += c
		bmin[i] = float(bmin[i]) if bmin[i] != null else 0.0
		bmax[i] = float(bmax[i]) if bmax[i] != null else 0.0
	var areas := {}
	var rows: Array = []
	var raw: Dictionary = s.get("areas", {})
	for id: String in raw:
		var r: Array = raw[id]
		if id != "" and r.size() >= 3 and (float(r[1]) > 0.0 or float(r[2]) > 0.0):
			rows.append([id, float(r[0]), float(r[1]), int(r[2])])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])   # the longest areas stay if there were ever more than the contract takes
	for r: Array in rows.slice(0, MAX_AREAS):
		areas[String(r[0]).left(24)] = {"seconds": snappedf(r[1] / 1000.0, 0.1), "deaths": clampi(r[3], 0, 100000), "avgMs": snappedf(r[1] / maxf(1.0, r[2]), 0.01)}
	var ids: Array = []
	for sid in s.get("sessionIds", []):
		if String(sid) != "" and ids.size() < MAX_SESSIONS:
			ids.append(String(sid).left(64))
	var worst := float(s.get("worstMs", 0.0))
	return {
		"reportId": String(s.get("reportId", "")).left(64),
		"version": String(s.get("version", "")).left(40),
		"seconds": snappedf(clampf(float(s.get("sumMs", 0.0)) / 1000.0, 0.0, 86400.0), 0.1),
		"endReason": reason if reason in END_REASONS else "unknown",
		"endArea": String(s.get("endArea", "")).left(24),
		"discipline": clampi(int(s.get("discipline", 0)), 0, 20),
		"level": clampi(int(s.get("level", 1)), 0, 200),
		"partySize": clampi(int(s.get("partySize", 1)), 1, 4),
		"host": bool(s.get("host", true)),
		"preset": String(s.get("preset", "")) if String(s.get("preset", "")) in ["low", "medium", "high", "ultra"] else "custom",
		"gpu": String(s.get("gpu", "")).strip_edges().left(120),
		"driver": String(s.get("driver", "")).strip_edges().left(60),
		"os": String(s.get("os", "")).strip_edges().left(40),
		"cpuCores": clampi(int(s.get("cpuCores", 1)), 1, 512),
		"ramMb": clampi(int(s.get("ramMb", 0)), 0, 4194304),
		"resolution": String(s.get("resolution", "")).left(20),
		"vsync": bool(s.get("vsync", true)),
		"fpsCap": clampi(int(s.get("fpsCap", 0)), 0, 1000),
		"frames": {
			"count": n, "avgMs": snappedf(float(s.get("sumMs", 0.0)) / maxf(1.0, n), 0.01),
			"p50Ms": snappedf(quantile(counts, bmin, bmax, 0.5), 0.01), "p99Ms": snappedf(quantile(counts, bmin, bmax, 0.99), 0.01),
			"worstMs": snappedf(worst, 0.01), "hitches": maxi(0, int(s.get("hitches", 0))), "hist": counts,
		},
		"areas": areas,
		"sessionIds": ids,
	}
