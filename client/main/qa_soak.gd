class_name DmQaSoak
extends Node
## The soak scenario (`-- --dev-offline --soak[=<minutes>] --soak-out=<abs dir>`, QA runs only; it writes `<dir>/soak.json`; client/README.md "Release checks"): one fresh isolated offline game on High (DmBenchFight.boot: the HUD on, the warm-up, a level 60
## hero in the Graves, Easy auto combat) left to fight with the Graves' waves on for that many minutes (30 when none is given; `--class=N` picks the discipline, default the Gravecaller). The hero holds the middle of the area and casts
## on its own (auto combat never walks), the waves and Grave Surges are play's. Once a minute (real time) a row: the frame times of that minute (p50, p99, worst), the engine's static memory, object and node counts and video memory.
## The results file is written after every row (a PC that stops halfway still leaves what it measured; `complete` says whether the run finished). Loaded by DmMain (`_run_qa_scenario`) by path: no other start compiles it.
## `run()` returns the exit code (0 every row written and the file written, 1 not).
##
## Results file: {"rows": [{"minute": 1, "p50_ms", "p99_ms", "static_mb", "objects", "video_mb", and beside them "frames", "worst_ms", "nodes", "kills"}, ...],
##   "growth": {"static_mb", "objects", "video_mb", "p99_ms"} (each the mean of the last 5 rows minus the mean of the first 5; with fewer than 10 rows, half the rows each, and at least 1),
##   and beside them "scenario": "soak", "preset", "discipline", "renderer", "minutes", "complete", "growth_detail": {"window_min", "p50_ms": {"first", "last", "delta"}, "p99_ms", "static_mb", "objects", "video_mb"}}.

const AREA := "graves"
const ROW_S := 60.0                          ## the length of a row (real seconds); tests shorten it
const GROWTH_KEYS := ["p50_ms", "p99_ms", "static_mb", "objects", "video_mb"]

var minutes := DmMain.QA_SOAK_MINUTES
var row_s := ROW_S
var discipline := 2
var results_file := ""
var preset := "high"
var rows: Array = []
var results: Dictionary = {}
var kills := 0

var _frames := PackedFloat32Array()
var _n := 0
var _last_us := 0
var _saved_ui_dir := "user://"


func _ready() -> void:
	_frames.resize(65536)


## Every frame: the real time since the one before, kept for the row in progress.
func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_us != 0:
		if _n >= _frames.size():
			_frames.resize(_frames.size() * 2)
		_frames[_n] = float(now - _last_us) / 1000.0
		_n += 1
	_last_us = now


## The growth of the rows, flat as the report reads it: {static_mb, objects, video_mb, p99_ms}, each the mean over the last rows minus the mean over the first (`growth_detail`). {} with no rows.
static func growth(rows_: Array) -> Dictionary:
	var d := growth_detail(rows_)
	var out := {}
	for key: String in ["static_mb", "objects", "video_mb", "p99_ms"]:
		if d.has(key):
			out[key] = d[key]["delta"]
	return out


## The same with what it is made of: {window_min, and for each metric {first, last, delta}}: the mean of each metric over the last `window_min` rows against the first `window_min` (5, or half the rows when
## there are fewer than ten, at least 1). {} with no rows.
static func growth_detail(rows_: Array) -> Dictionary:
	if rows_.is_empty():
		return {}
	var k := mini(5, maxi(1, rows_.size() / 2))
	var out := {"window_min": k}
	for key: String in GROWTH_KEYS:
		var first := 0.0
		var last := 0.0
		for i in k:
			first += float(rows_[i][key]) / k
			last += float(rows_[rows_.size() - 1 - i][key]) / k
		out[key] = {"first": DmQaPerf.rounded(first), "last": DmQaPerf.rounded(last), "delta": DmQaPerf.rounded(last - first)}
	return out


func run() -> int:
	var tree := get_tree()
	_saved_ui_dir = DmUiConfig.dir
	DmUiConfig.dir = ""   # the HUD's per-device files stay in memory: nothing of the PC's own is read or written
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # a headless / xvfb display may refuse; the run goes on
	Engine.max_fps = 0
	var settings := {"graphics": preset, "fps": 0, "auto_res": false, "brightness": 1.0, "ui_scale": 1.0, "vsync": false}
	var fight: Dictionary = await DmBenchFight.boot(self, discipline, {"settings": settings}, AREA)
	var game: DmNextGame = fight["game"]
	if game == null:
		DmUiConfig.dir = _saved_ui_dir
		print("QA-SOAK the game did not start")
		return 1
	game.perf.apply(settings)   # the HUD applied the player's own settings while the game started: this run's
	game.director.enabled = true   # the Graves' waves and Grave Surges as play has them (the benchmark's tight room is not used)
	game.input.auto.hold_position = true
	game.core_host.enemy_died.connect(func(_id: int, _def: String, _level: int, _elite: bool, _area: String, _source: int, _x: float, _z: float) -> void: kills += 1)
	var total := maxi(1, int(ceil(minutes * 60.0 / row_s)))
	print("QA-SOAK %s for %s min: %d rows of %s s" % [DmQaUiShots.DISCIPLINES.find_key(discipline), DmQaTune.fmt(minutes), total, DmQaTune.fmt(row_s)])
	var kills_at := kills
	_n = 0
	var began := Time.get_ticks_msec()
	var row_start := began
	while rows.size() < total:
		await tree.process_frame
		if float(Time.get_ticks_msec() - row_start) >= row_s * 1000.0:
			row_start = Time.get_ticks_msec()
			var row := DmQaPerf.frame_stats(_frames, _n)
			row.merge(DmQaPerf.memory())
			row["minute"] = rows.size() + 1
			row["kills"] = kills - kills_at
			kills_at = kills
			_n = 0
			rows.append(row)
			print("QA-SOAK minute %d: p50 %.2f ms, p99 %.2f ms, worst %.2f ms, static %.1f MB, %d objects, video %.1f MB, %d kills" % [row["minute"], float(row["p50_ms"]), float(row["p99_ms"]),
				float(row["worst_ms"]), float(row["static_mb"]), int(row["objects"]), float(row["video_mb"]), int(row["kills"])])
			_write(rows.size() >= total, minutes)
	await game.leave()
	game.queue_free()
	await tree.process_frame
	DmUiConfig.dir = _saved_ui_dir
	var g := growth_detail(rows)
	for key: String in GROWTH_KEYS:
		if g.has(key):
			print("QA-SOAK growth %s: %s -> %s (%s)" % [key, DmQaTune.fmt(g[key]["first"]), DmQaTune.fmt(g[key]["last"]), DmQaTune.fmt(g[key]["delta"])])
	return 0 if results_file == "" or results.get("complete", false) == true else 1


## The results so far, written to the results file (when there is one).
func _write(complete: bool, minutes_: float) -> void:
	results = {"scenario": "soak", "preset": preset, "discipline": String(DmQaUiShots.DISCIPLINES.find_key(discipline)), "renderer": "%s %s" % [DisplayServer.get_name(), DmQaPerf.adapter()],
		"minutes": minutes_, "complete": complete, "rows": rows, "growth": growth(rows), "growth_detail": growth_detail(rows)}
	if results_file != "" and not DmQaPerf.write_json(results_file, results):
		print("QA-SOAK results could not be written to %s" % results_file)
		results["complete"] = false
