class_name DmQaStutter
extends Node
## The stutter scenario (`-- --dev-offline --stutter --stutter-out=<abs dir>`, QA runs only; it writes `<dir>/stutter.json`; client/main/RELEASE-CHECKS.md): for each playable discipline a fresh isolated offline game on High (DmBenchFight.boot: the HUD
## on, the warm-up that players get, a level 60 hero in the Graves), stand-in enemies in the combat core in front of the hero, then every rite of the discipline's primaries, hotbar and grimoire and its signature cast once, one after
## the other, with what the cast needs laid ready (cooldowns and resources filled, a few corpses, four thralls for a necromancer, raised again before each cast). For each cast: the worst frame in the second after it (ms, real time) and the pipelines the renderer compiled
## in that second, in all and per kind (the engine's counters, DmQaPerf.compilations_by_kind: Godot 4.7 has them; a run with no renderer counts none). A rite the host refuses (it needs a target the stand-ins cannot give) is listed apart, not measured.
## Loaded by DmMain (`_run_qa_scenario`) by path: no other start compiles it. The run is the Node `Scenario` of the boot; `run()` returns the exit code (0 results written, 1 a discipline failed or nothing was cast).
##
## Results file: {"rows": [{"discipline": "reaper", "rite": "scythe_throw", "worst_ms": 14.2, "compilations": 3, "kinds": {"canvas": 0, "mesh": 0, "surface": 0, "draw": 1, "specialization": 2}}, ...], "p50_ms", "p99_ms" (every frame of the cast windows),
##   and beside them "scenario": "stutter", "preset", "renderer", "compilations_counted": true, "refused": [{"discipline", "rite", "reason"}], "errors": [{"discipline", "error"}], "worst_ms", "frames", "ms" (the run's length)}.

const AREA := "graves"
const WINDOW_S := 1.0       ## a cast's window: the worst frame and the compilations are those of this long after it
const GAP_S := 0.5          ## rest between two windows
const SETTLE_S := 1.5       ## the stand-ins stand still this long before the first cast
const STAND_INS := 8
const THRALLS := 4          ## the legion a necromancer's rites (Rally, Command) have to work on
const CORPSES := 3          ## corpses kept near the pack for the rites that raise or burst them

var disciplines: Array = [1, 2, 3, 4, 11]   ## class indices: the playable set (DmQaUiShots.DISCIPLINES); tests narrow it
var max_rites := 0          ## at most this many rites of each discipline (0 = every one; tests)
var results_file := ""
var preset := "high"
var window_s := WINDOW_S    ## (tests shorten these)
var gap_s := GAP_S
var settle_s := SETTLE_S
var boot_opts: Dictionary = {}   ## merged into each game's start options (a probe turns the warm-up off: `{"warmup": false}`)
var rows: Array = []
var refused: Array = []
var errors: Array = []
var results: Dictionary = {}

var _frames := PackedFloat32Array()
var _n := 0
var _last_us := 0
var _window_max := 0.0
var _measuring := false
var _saved_ui_dir := "user://"


func _ready() -> void:
	_frames.resize(65536)


## Every frame: the real time since the one before, kept while a cast's window is open.
func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_us != 0 and _measuring:
		var ms := float(now - _last_us) / 1000.0
		_window_max = maxf(_window_max, ms)
		if _n >= _frames.size():
			_frames.resize(_frames.size() * 2)
		_frames[_n] = ms
		_n += 1
	_last_us = now


## The rites cast for a discipline (class index): its primaries, hotbar and grimoire, the right mouse button's and the signature, once each in that order, those that have a module.
static func rites_of(disc: int) -> Array[String]:
	var did := String(DmCombatData.disciplines()["by_index"][str(disc)])
	var kit := DmAbilities.kit_for(DmHeroBody.family_of(did))
	var want: Array = []
	want.append_array(kit["primaries"])
	want.append_array(kit["hotbar"])
	want.append_array(kit["grimoire"])
	want.append(String(kit.get("rmb", "")))
	want.append(String(kit["signatures"].get(did, "")))
	var out: Array[String] = []
	for r in want:
		if String(r) != "" and not out.has(String(r)) and DmRiteRegistry.has(String(r)):
			out.append(String(r))
	return out


## The discipline's name as the results show it ("reaper", "gravecaller").
static func name_of(disc: int) -> String:
	return String(DmQaUiShots.DISCIPLINES.find_key(disc)) if DmQaUiShots.DISCIPLINES.values().has(disc) else str(disc)


## Runs every discipline, writes the results file and returns the exit code.
func run() -> int:
	var t0 := Time.get_ticks_msec()
	set_process(true)
	_saved_ui_dir = DmUiConfig.dir
	DmUiConfig.dir = ""   # the HUD's per-device files stay in memory: nothing of the PC's own is read or written
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # a headless / xvfb display may refuse; the run goes on
	Engine.max_fps = 0
	var settings := {"graphics": preset, "fps": 0, "auto_res": false, "brightness": 1.0, "ui_scale": 1.0, "vsync": false}
	for disc in disciplines:
		await _discipline(int(disc), settings)
	DmUiConfig.dir = _saved_ui_dir
	var stats := DmQaPerf.frame_stats(_frames, _n)
	results = {"scenario": "stutter", "preset": preset, "renderer": "%s %s" % [DisplayServer.get_name(), DmQaPerf.adapter()], "compilations_counted": true,
		"rows": rows, "refused": refused, "errors": errors, "p50_ms": stats["p50_ms"], "p99_ms": stats["p99_ms"], "worst_ms": stats["worst_ms"], "frames": stats["frames"], "ms": Time.get_ticks_msec() - t0}
	_print_summary()
	var written := results_file == "" or DmQaPerf.write_json(results_file, results)
	if not written:
		print("QA-STUTTER results could not be written to %s" % results_file)
	return 0 if written and errors.is_empty() and not rows.is_empty() else 1


func _discipline(disc: int, settings: Dictionary) -> void:
	var who := name_of(disc)
	var tree := get_tree()
	var fight: Dictionary = await DmBenchFight.boot(self, disc, {"settings": settings}.merged(boot_opts, true), AREA)
	var game: DmNextGame = fight["game"]
	var hero: DmHeroBody = fight["hero"]
	var caster: DmRiteCaster = fight["caster"]
	if game == null or hero == null or caster == null:
		errors.append({"discipline": who, "error": "the game did not start"})
		return
	game.perf.apply(settings)   # the HUD applied the player's own settings while the game started: this run's
	game.input.auto.gate_probe = func() -> bool: return false   # the fight's boot opened Easy auto combat: here the casts are this scenario's alone
	game.director.enabled = false
	game.director.surge = null
	game.core_host.core.set_wander(false)
	var origin := hero.position
	var spots := DmQaClips.layout("pack", STAND_INS, origin)
	var ids := DmQaClips.stand_ins(game, spots)
	var settled := 0.0
	while settled < settle_s or DmQaClips._rising(game.core_host, ids):
		await tree.process_frame
		settled += get_process_delta_time()
		if settled > DmQaClips.SETTLE_MAX_S:
			break
	var rites := rites_of(disc)
	if max_rites > 0 and rites.size() > max_rites:
		rites = rites.slice(0, max_rites)
	var aim := DmQaClips.aim_at(spots, origin)
	print("QA-STUTTER %s: %d rites" % [who, rites.size()])
	for rite in rites:
		ids = _prepare(game, hero, caster, spots, ids, origin)
		await tree.process_frame   # what the preparing cost is not the cast's
		var last := [""]
		var on_refused := func(id: String, why: String) -> void:
			if id == rite:
				last[0] = why
		caster.cast_rejected.connect(on_refused)
		var before := DmQaPerf.compilations_by_kind()
		_window_max = 0.0
		_measuring = true
		var start := Time.get_ticks_usec()
		caster.request_cast(rite, aim, -1)
		while float(Time.get_ticks_usec() - start) < window_s * 1000000.0:
			await tree.process_frame
		_measuring = false
		var kinds := DmQaPerf.kinds_between(before, DmQaPerf.compilations_by_kind())
		caster.cast_rejected.disconnect(on_refused)
		if last[0] != "":
			refused.append({"discipline": who, "rite": rite, "reason": last[0]})
		else:
			rows.append({"discipline": who, "rite": rite, "worst_ms": DmQaPerf.rounded(_window_max), "compilations": kinds.values().reduce(func(sum: int, n: int) -> int: return sum + n, 0), "kinds": kinds})
		await tree.create_timer(gap_s).timeout
	await game.leave()
	game.queue_free()
	await tree.process_frame


## What a cast needs before it: the hero where he began and healed, no cooldown or cast lock, the resource full, the stand-ins alive (a dead one is made again where it stood) and a few corpses lying near them.
func _prepare(game: DmNextGame, hero: DmHeroBody, caster: DmRiteCaster, spots: Array[Vector3], ids: Array[int], origin: Vector3) -> Array[int]:
	hero.teleport(origin)
	hero.heal(1e6)
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	DmQaClips._top_up(caster)
	var host: DmCoreHost = game.core_host
	if hero.get("family") != "reaper":   # a rite before it (Grave Offering, Command) may have used the legion up
		DmBenchFight.raise_thralls(game, hero, THRALLS, origin)
	for i in ids.size():
		if not host.enemy_alive(ids[i]):
			var one: Array[Vector3] = [spots[i]]
			var made := DmQaClips.stand_ins(game, one)
			if not made.is_empty():
				ids[i] = made[0]
	var corpses := host.corpses
	while corpses != null and corpses.count() < CORPSES:
		var at := spots[corpses.count() % spots.size()] if not spots.is_empty() else origin
		if corpses.add_corpse(at.x + 1.0, at.z + 1.0, "normal", DmQaClips.DUMMY, false, 0.0, 1.0, AREA) <= 0:
			break
	return ids


func _print_summary() -> void:
	var worst := rows.duplicate()
	worst.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["worst_ms"]) > float(b["worst_ms"]))
	print("QA-STUTTER %d casts, %d refused, %d errors, p50 %.2f ms, p99 %.2f ms, worst %.2f ms, %d compilations" % [rows.size(), refused.size(), errors.size(), float(results["p50_ms"]),
		float(results["p99_ms"]), float(results["worst_ms"]), rows.reduce(func(sum: int, c: Dictionary) -> int: return sum + int(c["compilations"]), 0)])
	for i in mini(10, worst.size()):
		print("QA-STUTTER worst %s %s %.2f ms, %d compilations" % [worst[i]["discipline"], worst[i]["rite"], float(worst[i]["worst_ms"]), int(worst[i]["compilations"])])
	for r in refused:
		print("QA-STUTTER refused %s %s (%s)" % [r["discipline"], r["rite"], r["reason"]])
