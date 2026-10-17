class_name DmBenchmark
extends Node
## The in-game benchmark of the rebuilt client (character select "Benchmark" button, launch arg `--benchmark`), a port of godot/next/perf/dm_benchmark.gd
## (client/code.list "Ported"): the same held fight on every PC so builds and machines compare, and the same fight as today's game so the rebuild can be measured
## against it (ROADMAP Gate B). An ISOLATED offline game (DmBenchFight: mock backend with an in-memory db, nothing persisted, no network); the player's settings
## file is only READ (graphics preset, fps cap for the report; the run itself is uncapped with V-Sync off).
## Setup (`configure`, the setup window DmBenchmarkSetup): room (ROOMS: today's nine combat areas), class (`class_indices`: the four necromancers and the Reaper), fight size (SIZES)
## and length (LENGTHS); STANDARD is the setup that compares PCs, today's. Fight: only the room's area is loaded, the room's own enemy kinds at the walkable point nearest its centre,
## every enemy with the same hp / damage in every room (`standard_stats`, no elites), a god-mode level 60 hero on auto combat, thralls raised directly, enemies topped up to the size's
## count, the room's boss held awake in a Full Party fight (BOSS_SIZES), fixed seed and camera zoom. Warm-up (not measured; the first frames compile shaders), then
## the measured window, then the HUD's share, then the render breakdown.
## What the creatures cost is the combat core's: `DmCoreHost.measure` times its step, the crowd's sync and the event dispatch per tick during the measured window, and the report's
## budget section sets them (and the rest of the main thread) against the ROADMAP budgets (BUDGET_*).
## Per-frame cost: one float appended to a preallocated PackedFloat32Array plus a handful of engine counter reads; the fight upkeep (top-up,
## counts, progress text) runs at TICK_S. Wiring: `var b := DmBenchmark.new(); add_child(b); var r := await b.run()`; `progress(text)` fires ~1 Hz.
## Text report: `format_text(results)`; `save_text(text)` writes bench-<datetime>.txt into `dir` (user://benchmarks).
## Render breakdown (`breakdown`, after the measured window): the fight is paused (the picture stays) and each of BREAK_CATS is hidden in turn for
## BREAK_MEASURE_S; the drop in draw calls / objects / render CPU / GPU / frame time against the everything-on sample is what that part costs
## on this PC. Hiding is visibility only (restored after each sample); nothing is freed or rebuilt.
## The fight plays at the player's graphics preset (DmNextPerf, as today's: uncapped, at full resolution), with rewards, loot drops and the kill ledger against the run's mock as
## today's. Not in the rebuilt client yet, so not in the fight (client/README.md "The benchmark"): the guests' hero bodies.

signal progress(text: String)
signal breakdown_step(step: int, total: int, what: String)   ## the render breakdown froze the fight: step 0 = everything on, total + 1 = the re-measure
signal _step

const SEED := 20261011
## The setup that compares PCs, today's: the Bell Sanctum (36 x 28 m: a small room keeps the pack on screen and the waves coming), Gravecaller (thrall master), Standard size, Full length.
## Gate B's Full Party fight is `--bench-room=graves --bench-size=full_party`.
const STANDARD := {"room": "sanctum", "discipline": 2, "size": "standard", "length": "full"}
const ROOMS := ["graves", "warren", "ossuary", "nave", "coliseum", "sanctum", "cloister", "pyre", "fen"]   ## the combat areas, today's list (not the Depths instance)
const STATS_ROOM := "sanctum"   ## the room whose roster fixes every enemy's health and damage (`standard_stats`), in every room, as today's
## [enemies held, thralls]. Full Party is the biggest fight the game makes: the global enemy cap (DmSimData.GLOBAL_ENEMY_CAP, a test keeps the two equal)
## and 4 necromancers' legions (4 x 8 thralls, all raised by the one hero here), plus the room's boss (BOSS_SIZES).
const SIZES := {"light": [15, 10], "standard": [30, 20], "heavy": [60, 30], "full_party": [72, 32]}
const SIZE_NAMES := {"light": "Light", "standard": "Standard", "heavy": "Heavy", "full_party": "Full Party"}
const BOSS_SIZES := ["full_party"]   ## sizes that hold the room's boss awake (DmBenchFight.boss_of; a room without one runs without)
const LENGTHS := {"quick": [6.0, 20.0, false], "full": [10.0, 30.0, true]}   ## [warm-up s, measured s, render breakdown]
const LENGTH_NAMES := {"quick": "Quick (about 30 s)", "full": "Full (about 90 s)"}
const ENEMY_LIMIT := 100        ## bodies alive or dying at once (play: GLOBAL_ENEMY_CAP 72, which a Heavy or Full Party fight's corpses would hit)
const ZOOM := 1.0
const TICK_S := 0.25
const DIR := "user://benchmarks"   ## where the report, the history, the queue of runs to send and the last setup are kept
const HITCH_MS := 50.0
const HITCH_KEEP := 40
## [key, label, printf format] of the per-phase result rows (the text report and the results panel both read this).
const ROWS := [
	["avg_fps", "Average fps", "%.1f"], ["avg_ms", "Frame ms (avg)", "%.2f"], ["median_ms", "Frame ms (median)", "%.2f"],
	["p95_ms", "Frame ms (p95)", "%.2f"], ["p99_ms", "Frame ms (p99)", "%.2f"], ["worst_ms", "Worst frame ms", "%.1f"],
	["hitches", "Hitches > 50 ms", "%d"], ["draw_calls", "Draw calls (avg)", "%.0f"], ["objects", "Objects (avg)", "%.0f"],
	["primitives", "Primitives (avg)", "%.0f"], ["render_cpu_ms", "Render CPU ms", "%.2f"], ["render_gpu_ms", "Render GPU ms", "%.2f"],
	["process_ms", "Process ms (script+anim)", "%.2f"], ["physics_ms", "Physics ms", "%.2f"],
	["kills_per_min", "Kills per minute", "%.0f"], ["loot", "Loot on the ground (avg)", "%.1f"], ["corpses", "Corpses (avg)", "%.1f"], ["enemies", "Enemies (avg)", "%.1f"], ["enemies_min", "Enemies (fewest)", "%d"], ["thralls", "Thralls (avg)", "%.1f"],
]

## The render breakdown's parts, in order: HUD (the in-game interface layer), moon shadows, thralls, enemies, the world (ground, props, area
## meshes), effects (Vfx, particles, decals).
const BREAK_CATS := ["Shadows", "Creatures", "World", "Effects", "HUD"]   ## HUD last: re-showing the whole interface is the biggest change. Creatures: the crowd of enemies and thralls (one MultiMesh per model, not per kind) and the boss
const BREAK_SETTLE_S := 1.0
const SPAWN_MIN_M := 6.0        ## the benchmark's wave spawn distance (m from the hero)
const SPAWN_MAX_M := 14.0

const BREAK_MEASURE_S := 5.0
## The ROADMAP's budgets (B39; starting points, set in the test build): in the headless Full Party fight on the VPS, the combat core's step + the crowd's sync + the event
## dispatch per 60 Hz tick, and the rest of the main thread per frame; on Helix's PC the HUD's main-thread cost per frame and its draw calls.
const BUDGET_CORE_MS := 4.0
const BUDGET_REST_MS := 4.0
const BUDGET_HUD_MS := 0.5
const BUDGET_HUD_DRAWS := 150
const HUD_ROUNDS := 8           ## the HUD's share: the fight with the HUD off, then on, this many times over ...
const HUD_SAMPLE_S := 0.5       ## ... each sample this long, after a short settle: the fight's own slow swings (a boss attack, a wave) fall on both kinds alike
const HUD_SETTLE_S := 0.1

## Where a run keeps its files. Tests and `--bench-dir=` point it at a folder of their own, so a run never reads or leaves behind another run's history, queue or setup.
static var dir := DIR

var setup: Dictionary = STANDARD.duplicate()
var area: String = STANDARD["room"]
var discipline: int = STANDARD["discipline"]
var breakdown := true
var warm_s := 10.0
var measure_s := 30.0
var enemies := 30
var thralls := 20
var boss_id := ""               ## the boss held awake ("" = none); set by `configure` for a Full Party fight in a room that has one
var kills_measured := 0         ## enemies killed in the measured window (kills per minute in the report)
var game: DmNextGame
var host: DmCoreHost            ## the game's combat core host (timed during the measured window)
var baked_dir := ""             ## where the baked crowd models are ("" = the project's res://crowd/baked; tests bake into a scratch folder)
var break_settle_s := BREAK_SETTLE_S      ## the render breakdown's timings (tests shorten them)
var break_measure_s := BREAK_MEASURE_S
var hud_rounds := HUD_ROUNDS              ## the HUD share's timings
var hud_sample_s := HUD_SAMPLE_S
var hud_settle_s := HUD_SETTLE_S
var hud_checked := false        ## the HUD share ran (tests)
var results: Dictionary = {}
var cancelled := false
var backend_calls := 0
var area_nav_on := false        ## the fight area's navmesh was enabled (its seal broken for the throwaway character)
var paused_ok := false          ## the render breakdown froze the fight (tests)
var hitches: Array = []          ## frames over HITCH_MS in the measured window: {t, ms, kills, spawns, cold} (what happened in that frame)
var spawns := 0
var max_drift := 0.0            ## farthest the hero got from the centre between checks (m)
var kills := 0                  ## enemies killed during the run (proof the fight is a fight; in the report)
var boss_summons := 0           ## times the boss was woken (again after each defeat)
var boss_defeats := 0           ## times it was killed

var _fight: Dictionary = {}
var _state := 0                 ## 0 idle, 1 warm-up / settle, 2 measuring a phase, 3 measuring a render-breakdown sample (no frame list)
var _target_s := 0.0
var _phase_t := 0.0
var _tick_t := 0.0
var _last_us := 0
var _fresh := false             ## the first frame of a stage has no interval yet
var _frames := PackedFloat32Array()
var _n := 0
var _calls := 0.0
var _objs := 0.0
var _prims := 0.0
var _rcpu := 0.0
var _rgpu := 0.0
var _proc := 0.0
var _phys := 0.0
var _ms_sum := 0.0
var _hidden: Array = []         ## the render breakdown's currently hidden nodes (its restore check)
var _ticks := 0
var _en_sum := 0.0
var _loot_sum := 0.0
var _corpse_sum := 0.0
var _last_kills := 0
var _last_spawns := 0
var _last_cold := 0
var _en_min := 1 << 30
var _th_sum := 0.0
var _boss_ticks := 0            ## measured upkeep ticks with the boss awake
var _label := ""
var _shown_s := -1
var _vp: RID
var _saved_vsync := DisplayServer.VSYNC_ENABLED
var _saved_fps := 0
var _saved_ui_dir := "user://"
var _saved_scale := 1.0
var _hero: DmHeroBody
var _at := Vector3.ZERO
var _core_ticks0 := 0           ## the host's tick count when the measured window began
var _core := {}                 ## the measured window's core timing: {ticks, step_us, sync_us, dispatch_us}
var _held_thralls := 0          ## the legion's size at the last upkeep


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	_restore()


## The plain-data settings the run reads from the player's file (read-only: no update() is ever called on this store).
static func user_settings() -> Dictionary:
	return DmSettings.new(DmSettings.FILE, true).values


## Applies a setup ({room, discipline, size, length}; missing or unknown keys fall back to STANDARD's) to the run's fields.
func configure(want: Dictionary) -> void:
	setup = normalize_setup(want)
	area = setup["room"]
	discipline = setup["discipline"]
	enemies = SIZES[setup["size"]][0]
	thralls = SIZES[setup["size"]][1]
	boss_id = DmBenchFight.boss_of(area) if BOSS_SIZES.has(setup["size"]) else ""
	warm_s = LENGTHS[setup["length"]][0]
	measure_s = LENGTHS[setup["length"]][1]
	breakdown = LENGTHS[setup["length"]][2]


static func normalize_setup(want: Dictionary) -> Dictionary:
	var out := STANDARD.duplicate()
	if String(want.get("room", "")) in ROOMS:
		out["room"] = String(want["room"])
	if int(want.get("discipline", 0)) in class_indices():
		out["discipline"] = int(want["discipline"])
	if SIZES.has(String(want.get("size", ""))):
		out["size"] = String(want["size"])
	if LENGTHS.has(String(want.get("length", ""))):
		out["length"] = String(want["length"])
	return out


static func is_standard(s: Dictionary) -> bool:
	return String(s.get("room", "")) == STANDARD["room"] and int(s.get("discipline", 0)) == STANDARD["discipline"] \
		and String(s.get("size", "")) == STANDARD["size"] and String(s.get("length", "")) == STANDARD["length"]


## The playable disciplines' indices (the four necromancers + the Reaper), in the character select's order.
static func class_indices() -> Array:
	var out: Array = []
	for d: Dictionary in DmContent.file("disciplines").get("PLAYABLE_DISCIPLINES", []):
		if DmCharacterBuild.is_playable(float(d["classIndex"])):
			out.append(int(d["classIndex"]))
	return out


## "" when `want` ({room, discipline}, as a launch asked for them) is something this build can run, else a plain-words refusal naming what it can. Keys that are missing are not
## refused (they take the Standard setup's).
static func refusal(want: Dictionary) -> String:
	if want.has("room") and not ROOMS.has(String(want["room"])):
		return "There is no benchmark room '%s' (--bench-room=): the rooms are %s." % [want["room"], ", ".join(ROOMS)]
	if want.has("discipline") and not class_indices().has(int(want["discipline"])):
		return "There is no benchmark class %d (--bench-class=): the classes are %s." % [int(want["discipline"]), ", ".join(class_indices().map(func(i: int) -> String: return "%d %s" % [i, class_name_of(i)]))]
	return ""


static func class_name_of(index: int) -> String:
	for d: Dictionary in DmContent.file("disciplines").get("PLAYABLE_DISCIPLINES", []):
		if int(d["classIndex"]) == index:
			return String(d["name"])
	return "Class %d" % index


static func room_name(id: String) -> String:
	return String(DmContent.area(id).get("name", id))


## "The Bell Sanctum, Gravecaller, Standard, Full" (+ ", custom" off the standard setup).
static func setup_label(s: Dictionary) -> String:
	return "%s, %s, %s, %s%s" % [room_name(s["room"]), class_name_of(int(s["discipline"])), SIZE_NAMES[s["size"]], String(s["length"]).capitalize(),
		"" if is_standard(s) else " (custom: compare only with the same setup)"]


## The hp / damage every benchmark enemy gets, in every room: the Bell Sanctum roster's weighted average at its level on Easy (what the
## benchmark's enemies had before rooms could be picked; STATS_ROOM, so the fight is as tough as today's), so a kill costs the same hits whatever the room or the kind.
static func standard_stats() -> Dictionary:
	DmSimData.ensure()
	var def: Dictionary = DmContent.area(STATS_ROOM)
	var level := DmEnemyStats.area_level(STATS_ROOM, [1.0], 0.0)
	var easy := DmContent.difficulty("easy")
	var w := 0.0
	var hp := 0.0
	var dmg := 0.0
	for e: Dictionary in def.get("enemies", []):
		var d: Dictionary = DmSimData.ENEMIES[String(e["id"])]
		w += float(e["weight"])
		hp += float(e["weight"]) * float(d["hp"])
		dmg += float(e["weight"]) * float(d["damage"])
	w = maxf(w, 1.0)
	return {"hp": hp / w * DmEnemyStats.hp_scale(level) * float(easy["enemyHpMult"]), "dmg": dmg / w * DmEnemyStats.damage_scale(level) * float(easy["enemyDamageMult"])}


func cancel() -> void:
	cancelled = true
	_step.emit()


func run() -> Dictionary:
	var user := user_settings()
	_saved_ui_dir = DmUiConfig.dir
	DmUiConfig.dir = ""   # the HUD's per-device files (dm_ui.json: keybinds, belt, locks; guidance) stay in memory: the player's own are never read or written
	_saved_vsync = DisplayServer.window_get_vsync_mode()
	_saved_fps = Engine.max_fps
	_vp = get_viewport().get_viewport_rid()
	_saved_scale = get_viewport().scaling_3d_scale
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # headless / xvfb may refuse; the run goes on
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	seed(SEED)
	progress.emit("Building the fight...")
	# Today's: the player's preset, uncapped, at full resolution, V-Sync off (2026-10-16: the game scene turned it back on, so Helix's runs read his
	# monitor's 170 fps and the server flagged them).
	var settings := {"graphics": DmGraphicsPreset.normalize(user.get("graphics", DmGraphicsPreset.DEFAULT)), "fps": 0, "auto_res": false,
		"brightness": user.get("brightness", 1.0), "ui_scale": user.get("ui_scale", 1.0), "vsync": false}
	var opts := {"audio": false, "settings": settings}
	if baked_dir != "":
		opts["baked_dir"] = baked_dir
	_fight = await DmBenchFight.boot(self, discipline, opts, area)
	game = _fight["game"]
	game.perf.apply(settings)   # the HUD applied the player's own settings while the game started (their V-Sync included): the run's win
	host = game.core_host
	_hero = _fight["hero"]
	_at = _fight["at"]
	# The small room needs the waves close (play spawns at 18 m+, outside aggro: here that is the far corners), and tougher enemies keep
	# the density steady instead of a god-mode legion emptying the room between top-ups. The run's director is thrown away afterwards.
	# Hands off: the player's mouse and keys never reach the fight (no walking, hotkeys or panels; Esc stays the screen's), and auto combat
	# casts without walking, so the hero holds the room's centre (a dash is undone in _tick).
	DmBenchFight.arm(game, enemies, SEED)
	host.enemy_died.connect(func(_id: int, _def: String, _level: int, _elite: bool, _area: String, _source: int, _x: float, _z: float) -> void: kills += 1)
	host.enemy_spawned.connect(func(_id: int, _def: String, _level: int, _elite: bool, _area: String, _affixes: int, _x: float, _z: float, _hp: float) -> void: spawns += 1)
	game.bosses.summoned.connect(func(_b: String, _p: int) -> void: boss_summons += 1)
	game.bosses.defeated.connect(func(_b: String, _k: int, _pos: Vector3) -> void: boss_defeats += 1)
	game.process_mode = Node.PROCESS_MODE_PAUSABLE   # explicit: the screen and the runner process always (Esc), the fight must still pause
	_lock_input(game)
	get_tree().node_added.connect(_on_node_added)
	var reg := game.world.get_node_or_null("area_%s/Navigation/area_%s" % [area, area]) as NavigationRegion3D
	area_nav_on = reg != null and reg.enabled   # the area's baked navmesh region is on: enemies can reach the hero
	Engine.max_fps = 0
	results = {"meta": _meta(user), "phases": []}
	_label = "Fight"
	_frames = PackedFloat32Array()
	_frames.resize(int(measure_s * 1000.0) + 256)   # up to 1000 fps; later frames of a faster machine are only counted (`frames`)
	await _stage(1, warm_s)
	var kills_at := kills
	if not cancelled:
		_reset_acc()
		_core_begin()
		await _stage(2, measure_s)
		_core_end()
	kills_measured = kills - kills_at
	if not cancelled:
		var ph := _summary()
		ph["kills"] = kills_measured
		ph["kills_per_min"] = kills_measured / maxf(measure_s, 0.001) * 60.0
		if boss_id != "":
			ph["boss_awake_pct"] = 100.0 * _boss_ticks / maxf(1.0, _ticks)   # (not a table row: the report's Boss line and the upload carry it)
		await _hud_share(ph)
		results["phases"].append(ph)
	if breakdown and not cancelled:
		results["breakdown"] = await _breakdown()
	results["kills"] = kills
	results["boss"] = {"id": boss_id, "name": String(DmContent.boss(boss_id)["name"]) if boss_id != "" else "", "summons": boss_summons, "defeats": boss_defeats}
	results["setup"] = setup.duplicate()
	results["standard"] = is_standard(setup)
	results["max_drift"] = max_drift
	results["hitches"] = hitches
	results["input_locked"] = game != null and not game.input.is_processing_unhandled_input() and (game.ui == null or not game.ui.is_processing_unhandled_key_input())
	results["cancelled"] = cancelled
	results["backend_calls"] = int(_fight["stats"]["calls"])
	backend_calls = results["backend_calls"]
	await _teardown()
	return results


## The combat core's timing for the measured window: the host sums the microseconds of its step, the crowd's sync and the event dispatch per tick while `measure` is on.
func _core_begin() -> void:
	host.step_us = 0
	host.sync_us = 0
	host.dispatch_us = 0
	_core_ticks0 = host.ticks
	host.measure = true


func _core_end() -> void:
	host.measure = false
	_core = {"ticks": host.ticks - _core_ticks0, "step_us": host.step_us, "sync_us": host.sync_us, "dispatch_us": host.dispatch_us}


## The HUD nodes the game has: today's HUD and panels (`ui`, DmGameUi on the core, DECISIONS B46).
func _hud_nodes() -> Array:
	return [game.ui] if game.ui != null and is_instance_valid(game.ui) else []


## The HUD's share of the main thread: the same fight with the HUD off and on, `hud_rounds` times over (`hud_sample_s` each after a short settle), the average frame with it less
## the average without it, round by round. Frames are not steady on a shared machine and a fight swings (a wave, a boss attack): `hud_noise_ms` is twice the standard error of the
## round differences, and a share below it is not a measurement. The picture is not part of it (the headless run has none): its draw calls come from the render breakdown's HUD row.
func _hud_share(ph: Dictionary) -> void:
	var nodes := _hud_nodes()
	if nodes.is_empty() or cancelled:
		return
	hud_checked = true
	var modes: Array = nodes.map(func(n: Node) -> int: return n.process_mode)
	var shown: Array = nodes.map(func(n: Node) -> bool: return n.get("visible") if n.get("visible") != null else true)
	var diffs: Array = []
	for _round in hud_rounds:
		var pair: Array = []
		for want in [false, true]:
			if cancelled:
				break
			for i in nodes.size():
				(nodes[i] as Node).set("visible", want and shown[i])
				(nodes[i] as Node).process_mode = modes[i] if want else Node.PROCESS_MODE_DISABLED
			progress.emit("Measuring what the HUD costs (%s)" % ("on" if want else "off"))
			await _stage(1, hud_settle_s)
			if cancelled:
				break
			_reset_acc()
			await _stage(3, hud_sample_s)
			pair.append(_ms_sum / maxf(1.0, _n))
		if pair.size() == 2:
			diffs.append(pair[1] - pair[0])   # (off first, then on)
	for i in nodes.size():
		if is_instance_valid(nodes[i]):
			(nodes[i] as Node).set("visible", shown[i])
			(nodes[i] as Node).process_mode = modes[i]
	if diffs.size() >= 2:
		var mean := 0.0
		for d: float in diffs:
			mean += d
		mean /= diffs.size()
		var var_sum := 0.0
		for d: float in diffs:
			var_sum += (d - mean) * (d - mean)
		var stderr := sqrt(var_sum / (diffs.size() - 1) / diffs.size())
		ph["hud_ms"] = maxf(0.0, mean)
		ph["hud_noise_ms"] = 2.0 * stderr
		ph["hud_rounds"] = diffs.size()


## Switches every input callback of `n`'s subtree off (and of anything added to the game later: HUD panels are built lazily).
func _lock_input(n: Node) -> void:
	var st: Array[Node] = [n]
	while not st.is_empty():
		var nd: Node = st.pop_back()
		for c in nd.get_children():
			st.append(c)
		nd.set_process_input(false)
		nd.set_process_unhandled_input(false)
		nd.set_process_unhandled_key_input(false)
		nd.set_process_shortcut_input(false)


func _on_node_added(nd: Node) -> void:
	if game != null and is_instance_valid(game) and game.is_ancestor_of(nd):
		nd.set_process_input.call_deferred(false)   # (its own _ready may turn processing on after this signal)
		nd.set_process_unhandled_input.call_deferred(false)
		nd.set_process_unhandled_key_input.call_deferred(false)
		nd.set_process_shortcut_input.call_deferred(false)


func _teardown() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if host != null:
		host.measure = false
	_state = 0
	set_process(false)
	if game != null and is_instance_valid(game):
		await game.leave()
		game.queue_free()
		await get_tree().process_frame
	game = null
	_restore()


func _restore() -> void:
	if _vp.is_valid():
		RenderingServer.viewport_set_measure_render_time(_vp, false)
		_vp = RID()
		DisplayServer.window_set_vsync_mode(_saved_vsync)
		Engine.max_fps = _saved_fps
		DmUiConfig.dir = _saved_ui_dir
		get_viewport().scaling_3d_scale = _saved_scale


func _stage(state: int, secs: float) -> void:
	_state = state
	_target_s = secs
	_phase_t = 0.0
	_tick_t = 0.0
	_shown_s = -1
	_fresh = true
	set_process(true)
	await _step
	_state = 0


func _reset_acc() -> void:
	_n = 0
	_calls = 0.0
	_objs = 0.0
	_prims = 0.0
	_rcpu = 0.0
	_rgpu = 0.0
	_proc = 0.0
	_phys = 0.0
	_ms_sum = 0.0
	_en_min = 1 << 30
	_loot_sum = 0.0
	_corpse_sum = 0.0
	_ticks = 0
	_en_sum = 0.0
	_th_sum = 0.0
	_boss_ticks = 0


func _process(dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _fresh:
		_fresh = false
		_last_us = now
		return
	var ms := (now - _last_us) * 0.001
	_last_us = now
	_phase_t += dt   # the engine's frame time: the wall clock at real time, 1/60 s a frame when the game runs faster than real time (--fixed-fps), so a window is seconds of fight either way
	_tick_t += dt
	if _state >= 2:
		if _state == 2 and _n < _frames.size():
			_frames[_n] = ms
		if _state == 2:
			var cold := DmModels.cold_loads + DmFxBinbun.cold_loads + DmGearModels.cold_loads
			if ms > HITCH_MS and hitches.size() < HITCH_KEEP:
				hitches.append({"t": _phase_t, "ms": ms, "kills": kills - _last_kills, "spawns": spawns - _last_spawns, "cold": cold - _last_cold})
			_last_kills = kills
			_last_spawns = spawns
			_last_cold = cold
		_n += 1
		_ms_sum += ms
		_calls += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		_objs += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		_prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		_rcpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp)
		_rgpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
		_proc += Performance.get_monitor(Performance.TIME_PROCESS)
		_phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if _tick_t >= TICK_S:
		_tick_t = 0.0
		_tick()
	if _phase_t >= _target_s:
		set_process(false)
		_step.emit()


## Fight upkeep + progress, at TICK_S: enemies, thralls and the boss held (DmBenchFight.upkeep), the hero unkillable, the camera at the fixed zoom.
func _tick() -> void:
	if get_tree().paused:   # the render breakdown holds the picture still
		return
	_held_thralls = DmBenchFight.upkeep(_fight, enemies, thralls, boss_id)
	var drift := Vector2(_hero.global_position.x - _at.x, _hero.global_position.z - _at.z).length()
	max_drift = maxf(max_drift, drift)
	if drift > 1.5:
		_hero.teleport(_at)   # a rite that moves the hero (a dash): back to the centre
	game.camera.zoom = ZOOM
	game.camera.target_zoom = ZOOM
	var whole := int(_phase_t)
	if _state == 2:
		_ticks += 1
		_en_sum += game.director.alive_count()
		_corpse_sum += host.corpses.count()
		if game.rewards != null:
			for m in game.rewards.members.values():
				if m.loot_view != null:
					_loot_sum += m.loot_view.count()
		_en_min = mini(_en_min, game.director.alive_count())
		_th_sum += _held_thralls
		if boss_id != "" and game.bosses.active_boss() != null:
			_boss_ticks += 1
	if whole != _shown_s:
		_shown_s = whole
		var kind := "Warming up..." if _state == 1 else "Measuring %d/%d s" % [whole, int(_target_s)]
		progress.emit("%s  %s" % [kind, _label])


func _summary() -> Dictionary:
	var n := mini(_n, _frames.size())
	var sorted := _frames.slice(0, n)
	sorted.sort()
	var total := 0.0
	var worst := 0.0
	var hitches := 0
	for i in n:
		var f := _frames[i]
		total += f
		worst = maxf(worst, f)
		if f > 50.0:
			hitches += 1
	var avg := total / maxf(1.0, n)
	var d := float(maxi(1, _n))
	var ticks := maxi(1, int(_core.get("ticks", 0)))
	var step_ms := float(_core.get("step_us", 0)) / 1000.0 / ticks
	var sync_ms := float(_core.get("sync_us", 0)) / 1000.0 / ticks
	var events_ms := float(_core.get("dispatch_us", 0)) / 1000.0 / ticks
	var per_frame := float(_core.get("ticks", 0)) / d   # 60 Hz ticks per rendered frame: under 1 on a fast frame, 2 or 3 on a slow one (catch-up)
	return {
		"label": "Fight", "frames": _n,
		"avg_fps": 1000.0 / maxf(avg, 0.001), "avg_ms": avg, "median_ms": sorted[n / 2] if n > 0 else 0.0,
		"p95_ms": sorted[mini(n - 1, int(n * 0.95))] if n > 0 else 0.0, "p99_ms": sorted[mini(n - 1, int(n * 0.99))] if n > 0 else 0.0,
		"worst_ms": worst, "hitches": hitches, "draw_calls": _calls / d, "objects": _objs / d, "primitives": _prims / d,
		"render_cpu_ms": _rcpu / d, "render_gpu_ms": _rgpu / d, "process_ms": _proc / d * 1000.0, "physics_ms": _phys / d * 1000.0,
		"loot": _loot_sum / maxf(1.0, _ticks), "corpses": _corpse_sum / maxf(1.0, _ticks),
		"enemies": _en_sum / maxf(1.0, _ticks), "enemies_min": _en_min if _ticks > 0 else 0, "thralls": _th_sum / maxf(1.0, _ticks), "capped": at_refresh_rate(1000.0 / maxf(avg, 0.001)), "floored": at_headless_floor(sorted[n / 2] if n > 0 else 0.0),
		# the budget section (not table rows): the combat core per tick, how many ticks a frame ran, and what is left of the frame for everything else
		"core_step_ms": step_ms, "core_sync_ms": sync_ms, "core_events_ms": events_ms, "core_ms": step_ms + sync_ms + events_ms, "ticks_per_frame": per_frame,
		"core_frame_ms": (step_ms + sync_ms + events_ms) * per_frame, "rest_ms": maxf(0.0, avg - (step_ms + sync_ms + events_ms) * per_frame),
	}


## True when a headless frame of `median_ms` is the engine's idle pad, not work: with no window to draw, Godot pads every frame to `low_processor_usage_mode_sleep_usec` (6.9 ms),
## so a frame that took less shows 6.9 (within 3%) and the cost hides under it. `--fixed-fps 60` (before `--path`) has no pad, runs a tick with every frame, and is the headless processor test.
static func at_headless_floor(median_ms: float) -> bool:
	if DisplayServer.get_name() != "headless" or "--fixed-fps" in OS.get_cmdline_args():
		return false
	var pad := float(OS.low_processor_usage_mode_sleep_usec) / 1000.0
	return absf(median_ms - pad) <= pad * 0.03


## True when `fps` sits within 3% of the screen's refresh rate: V-Sync is still holding the frame rate (the driver can force it, e.g.
## NVIDIA Control Panel -> Vertical sync = On), so the true frame cost is hidden under the cap.
static func at_refresh_rate(fps: float) -> bool:
	var hz := DisplayServer.screen_get_refresh_rate()
	return hz > 0.0 and absf(fps - hz) / hz < 0.03


## Everything-on sample, then one sample per BREAK_CATS part hidden. Returns {base: {...}, rows: [{what, draws, objects, render_cpu_ms,
## render_gpu_ms, frame_ms}]} where each row value is how much hiding that part saved.
func _breakdown() -> Dictionary:
	var tree := get_tree()
	process_mode = Node.PROCESS_MODE_ALWAYS
	tree.paused = true
	_label = "Render breakdown"
	var restored := true
	breakdown_step.emit(0, BREAK_CATS.size(), "everything on")
	var base := await _sample()
	var held := not game.can_process()   # the fight really is paused (the screen and this runner keep processing)
	var rows: Array = []
	var nth := 0
	for cat in BREAK_CATS:
		if cancelled:
			break
		nth += 1
		progress.emit("Fight paused on purpose: measuring what each part costs (%d/%d: without %s)" % [nth, BREAK_CATS.size(), cat])
		breakdown_step.emit(nth, BREAK_CATS.size(), "without " + cat)
		_hidden.clear()
		var undo := _hide(cat)
		var m := await _sample()
		undo.call()
		for g in _hidden:   # (bodies may still be freed meanwhile: SceneTree timers run while paused)
			if is_instance_valid(g) and not (g as GeometryInstance3D).visible:
				restored = false
		rows.append({"what": cat, "draws": base["draws"] - m["draws"], "objects": base["objects"] - m["objects"],
			"render_cpu_ms": base["render_cpu_ms"] - m["render_cpu_ms"], "render_gpu_ms": base["render_gpu_ms"] - m["render_gpu_ms"],
			"frame_ms": base["frame_ms"] - m["frame_ms"]})
	for n in _hud_nodes():
		restored = restored and bool(n.get("visible"))
	var base_end := {}
	if not cancelled:
		progress.emit("Fight paused on purpose: measuring everything on again (drift check)")
		breakdown_step.emit(BREAK_CATS.size() + 1, BREAK_CATS.size(), "everything on again")
		base_end = await _sample()
	paused_ok = held
	tree.paused = false
	process_mode = Node.PROCESS_MODE_INHERIT
	return {"base": base, "base_end": base_end, "rows": rows, "restored": restored}




func _sample() -> Dictionary:
	await _stage(1, break_settle_s)
	_reset_acc()
	await _stage(3, break_measure_s)
	var d := float(maxi(1, _n))
	return {"draws": _calls / d, "objects": _objs / d, "render_cpu_ms": _rcpu / d, "render_gpu_ms": _rgpu / d, "frame_ms": _ms_sum / d}


## Hides one breakdown part; returns the Callable that shows it again.
func _hide(cat: String) -> Callable:
	match cat:
		"HUD":
			var nodes := _hud_nodes()
			if nodes.is_empty():
				return func() -> void: pass
			var was: Array = nodes.map(func(n: Node) -> bool: return bool(n.get("visible")))
			for n in nodes:
				(n as Node).set("visible", false)
			return func() -> void:
				for i in nodes.size():
					if is_instance_valid(nodes[i]):
						(nodes[i] as Node).set("visible", was[i])
		"Shadows":
			var moon: DirectionalLight3D = game.world.builder.moon if game.world != null and game.world.builder != null else null
			if moon == null:
				return func() -> void: pass
			var was_s := moon.shadow_enabled
			moon.shadow_enabled = false
			return func() -> void: moon.shadow_enabled = was_s
	var hid: Array = []
	var st: Array[Node] = [game]
	while not st.is_empty():
		var nd: Node = st.pop_back()
		for c in nd.get_children():
			st.append(c)
		if nd is GeometryInstance3D and (nd as GeometryInstance3D).visible and _part_of(nd) == cat:
			(nd as GeometryInstance3D).visible = false
			hid.append(nd)
			_hidden.append(nd)
	return func() -> void:
		for g in hid:
			if is_instance_valid(g):
				(g as GeometryInstance3D).visible = true


## Which breakdown part a 3D node belongs to (by the scripts above it, else by where the world builder put it).
static func _part_of(nd: Node) -> String:
	if nd is Decal or nd is GPUParticles3D or nd is CPUParticles3D:
		return "Effects"
	var p: Node = nd
	while p != null:
		if p is CrowdView or p is DmBoss:
			return "Creatures"
		if p is DmHeroBody:
			return "Hero"
		var s: Script = p.get_script()
		if s != null:
			var gn := String(s.get_global_name())
			if gn.begins_with("DmFx") or gn == "DmBossFx" or gn == "DmEnemyFx":
				return "Effects"
			if gn == "DmWorldBuilder" or gn == "DmNextWorld":
				return "World"
		p = p.get_parent()
	return ""


func _meta(user: Dictionary) -> Dictionary:
	var ver := DmBuild.version()
	var build := ver
	var win := DisplayServer.window_get_size()
	return {
		"build": build, "version": ver, "date": Time.get_datetime_string_from_system(false, true),
		"gpu": RenderingServer.get_video_adapter_name(), "renderer": "%s / %s" % [RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name()],
		"resolution": "%dx%d" % [win.x, win.y], "preset": DmGraphicsPreset.normalize(user.get("graphics", DmGraphicsPreset.DEFAULT)),
		"fps_cap": int(user.get("fps", 0)),
		"cpu": OS.get_processor_name(), "cores": OS.get_processor_count(), "os": OS.get_name(),
		"godot": Engine.get_version_info()["string"], "vsync": "off during measurement", "refresh_hz": DisplayServer.screen_get_refresh_rate(),
		"setup": setup_label(setup),
		"core": core_version(),
		"crowd_models": host.view.model_slots().size() if host != null and host.view != null else 0,
		"fight": "%d enemies (same health and damage in every room, no elites), %d thralls%s, level 60 god mode, auto combat, seed %d, warm-up %d s, measured %d s" % [
			enemies, thralls, boss_text(), SEED, int(warm_s), int(measure_s)],
	}


## The combat core's name and version ("dmcore 0.9"), "" when the extension is not there.
static func core_version() -> String:
	if not ClassDB.class_exists("DmCore"):
		return ""
	var c: Variant = ClassDB.instantiate("DmCore")
	return String(c.version())


## ", <boss> held awake" for a fight with a boss, ", no boss (this room has none)" for a boss size in a room without one, else "".
func boss_text() -> String:
	if boss_id != "":
		return ", %s held awake" % DmContent.boss(boss_id)["name"]
	return ", no boss (this room has none)" if BOSS_SIZES.has(setup["size"]) else ""


## Plain-text report: header, then one column per phase (ON | OFF side by side when both ran).
static func format_text(r: Dictionary) -> String:
	var m: Dictionary = r["meta"]
	var L: PackedStringArray = []
	L.append("Death Muffin benchmark")
	L.append("Build: %s (game %s)   %s" % [m["build"], m["version"], m["date"]])
	L.append("GPU: %s   Renderer: %s   Godot %s   Combat core: %s" % [m["gpu"], m["renderer"], m["godot"], m.get("core", "")])
	L.append("CPU: %s (%d threads)   OS: %s" % [m["cpu"], m["cores"], m["os"]])
	L.append("Resolution: %s   Graphics preset: %s   Fps cap (setting): %s   V-Sync: %s" % [m["resolution"], m["preset"], str(m["fps_cap"]) if int(m["fps_cap"]) > 0 else "none", m["vsync"]])
	L.append("Setup: %s" % m.get("setup", ""))
	L.append("Fight: %s   kills during the run: %d" % [m["fight"], int(r.get("kills", 0))])
	var bo: Dictionary = r.get("boss", {})
	if String(bo.get("id", "")) != "":
		var awake: Array = (r["phases"] as Array).map(func(p: Dictionary) -> float: return float(p.get("boss_awake_pct", 0.0)))
		L.append("Boss: %s   woken %d times, defeated %d times%s" % [bo["name"], int(bo["summons"]), int(bo["defeats"]),
			", awake %.0f%% of the measured window" % awake[0] if not awake.is_empty() else ""])
	if bool(r.get("cancelled", false)):
		L.append("(cancelled: only finished phases are listed)")
	var ph: Array = r["phases"]
	var warn := capped_warning(r)
	if warn != "":
		L.append("WARNING: " + warn)
	var floor_w := floor_warning(r)
	if floor_w != "":
		L.append("WARNING: " + floor_w)
	if int(m.get("crowd_models", 1)) == 0:
		L.append("WARNING: no crowd model is baked (bash client/tools/bake_crowd.sh): nothing is drawn and the crowd's view work is not done, so these numbers are too good.")
	var head := "%-26s" % ""
	for p in ph:
		head += "%-30s" % p["label"]
	L.append(head)
	for row in DmBenchmark.ROWS:
		var line := "%-26s" % row[1]
		for p in ph:
			line += "%-30s" % (row[2] % p[row[0]])
		L.append(line)
	var bl := budget_lines(r)
	if not bl.is_empty():
		L.append("")
		L.append_array(bl)
	var hl: Array = r.get("hitches", [])
	if not hl.is_empty():
		var with_k := 0
		var with_s := 0
		var with_c := 0
		for h: Dictionary in hl:
			with_k += 1 if int(h["kills"]) > 0 else 0
			with_s += 1 if int(h["spawns"]) > 0 else 0
			with_c += 1 if int(h["cold"]) > 0 else 0
		L.append("")
		L.append("Hitches over %d ms: %d%s  (in the same frame: a kill %d, a spawn %d, a first-time model/effect load %d)" % [int(HITCH_MS), hl.size(),
			"+" if hl.size() >= HITCH_KEEP else "", with_k, with_s, with_c])
		for h: Dictionary in hl.slice(0, 12):
			L.append("  at %5.1f s  %6.0f ms   kills %d  spawns %d  first-time loads %d" % [float(h["t"]), float(h["ms"]), int(h["kills"]), int(h["spawns"]), int(h["cold"])])
	var bd: Dictionary = r.get("breakdown", {})
	if not bd.is_empty():
		var b: Dictionary = bd["base"]
		L.append("")
		L.append("Render breakdown (fight paused, everything on: %.0f draw calls, %.0f objects, render CPU %.2f ms, GPU %.2f ms, frame %.2f ms)" % [
			b["draws"], b["objects"], b["render_cpu_ms"], b["render_gpu_ms"], b["frame_ms"]])
		L.append("%-14s%12s%12s%16s%14s%14s" % ["Hiding", "draws", "objects", "render CPU ms", "GPU ms", "frame ms"])
		for row: Dictionary in bd["rows"]:
			L.append("%-14s%12s%12s%16s%14s%14s%s" % [row["what"], "%.0f" % -row["draws"], "%.0f" % -row["objects"], "%.2f" % -row["render_cpu_ms"],
				"%.2f" % -row["render_gpu_ms"], "%.2f" % -row["frame_ms"], "   (unsteady: ms not reliable)" if breakdown_unsteady(row) else ""])
		var be: Dictionary = bd.get("base_end", {})
		if not be.is_empty():
			var drift := absf(float(be["frame_ms"]) - float(b["frame_ms"]))
			L.append("Everything on again at the end: %.0f draw calls, render CPU %.2f ms, GPU %.2f ms, frame %.2f ms%s" % [be["draws"], be["render_cpu_ms"], be["render_gpu_ms"], be["frame_ms"],
				"   (drifted %.1f ms from the start: the ms columns are not reliable, the draw calls are)" % drift if drift > maxf(1.0, float(b["frame_ms"]) * 0.2) else ""])
		if breakdown_capped(r):
			L.append("(the paused picture ran at your screen's refresh rate: V-Sync is on in the GPU driver, so the ms columns are capped; the draw calls are exact)")
		if float(b["render_gpu_ms"]) > float(b["render_cpu_ms"]) * 1.5:
			L.append("(GPU-bound: frame times jitter with the GPU queue; the draw-call column is exact, trust the ms columns less)")
	return "\n".join(L)


## "PASS" or "MISS": `value` within `budget`.
static func verdict(value: float, budget: float) -> String:
	return "PASS" if value <= budget else "MISS"


## The report's budget section: what the combat core costs per tick and what the rest of the main thread costs per frame, each against its ROADMAP budget (BUDGET_*), and the
## HUD's share when the build has a HUD. The budgets are set for the headless Full Party fight on the VPS (a stand-in for a weaker processor); in another fight, or on a PC with
## a renderer, the lines are information (the rest then includes drawing). Empty when the run measured no phase.
static func budget_lines(r: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var ph: Array = r.get("phases", [])
	if ph.is_empty() or not (ph[0] as Dictionary).has("core_ms"):
		return out
	var p: Dictionary = ph[0]
	var s: Dictionary = r.get("setup", {})
	var rendered := DisplayServer.get_name() != "headless"
	var full := String(s.get("size", "")) == "full_party"
	out.append("Budgets (ROADMAP: set for the headless Full Party fight on the VPS%s)" % ("" if full and not rendered else "; this run is %s, so they are information" % (
		"not the Full Party fight" if not full else "rendered, where the rest includes drawing")))
	out.append("  Combat core per tick: %.2f ms of %.1f ms   %s   (step %.2f + crowd sync %.2f + event dispatch %.2f; %.2f ticks a frame, %.2f ms a frame)" % [
		p["core_ms"], BUDGET_CORE_MS, verdict(p["core_ms"], BUDGET_CORE_MS), p["core_step_ms"], p["core_sync_ms"], p["core_events_ms"], p["ticks_per_frame"], p["core_frame_ms"]])
	if bool(p.get("floored", false)):
		out.append("  Rest of the main thread per frame: not measured (the headless frames sat at Godot's idle pad: run with --fixed-fps 60 before --path)")
	else:
		out.append("  Rest of the main thread per frame: %.2f ms of %.1f ms   %s   (frame %.2f ms less the core's %.2f ms)" % [
			p["rest_ms"], BUDGET_REST_MS, verdict(p["rest_ms"], BUDGET_REST_MS), p["avg_ms"], p["core_frame_ms"]])
	if p.has("hud_ms"):
		var noisy := float(p["hud_noise_ms"]) > maxf(float(p["hud_ms"]), 0.1)
		out.append("  HUD per frame (main thread): %.2f ms of %.1f ms   %s   (HUD on less off over %d rounds, give or take %.2f ms%s)" % [
			p["hud_ms"], BUDGET_HUD_MS, verdict(p["hud_ms"], BUDGET_HUD_MS), int(p.get("hud_rounds", 0)), p["hud_noise_ms"], ": below that the number is noise" if noisy else ""])
	else:
		out.append("  HUD per frame: no HUD in this run")
	var bd: Dictionary = r.get("breakdown", {})
	var hud_row := {}
	for row: Dictionary in bd.get("rows", []):
		if row["what"] == "HUD":
			hud_row = row
	if hud_row.is_empty():
		out.append("  HUD draw calls: not measured (the render breakdown runs in a Full-length run)")
	elif float(bd["base"]["draws"]) <= 0.0:
		out.append("  HUD draw calls: not measured (this run has no renderer)")
	else:
		out.append("  HUD draw calls: %.0f of %d   %s" % [hud_row["draws"], BUDGET_HUD_DRAWS, verdict(float(hud_row["draws"]), float(BUDGET_HUD_DRAWS))])
	return out


## A breakdown row whose ms went UP by more than noise when the part was hidden: GPU-queue jitter, not a real cost.
static func breakdown_unsteady(row: Dictionary) -> bool:
	return float(row["render_cpu_ms"]) < -0.5 or float(row["frame_ms"]) < -0.5 or float(row["render_gpu_ms"]) < -0.5


## "" or the V-Sync warning when the measured fight ran at the screen's refresh rate (a run the history flags). The paused breakdown is
## light enough to reach the cap on a fast PC while the fight is far below it: that only gets `breakdown_capped` (its ms columns are capped).
static func capped_warning(r: Dictionary) -> String:
	var capped := false
	for p: Dictionary in r.get("phases", []):
		capped = capped or bool(p.get("capped", false))
	if not capped:
		return ""
	return "the frame rate sat at your screen's refresh rate (%.0f Hz): V-Sync is still on (often forced in the GPU driver: NVIDIA Control Panel -> Manage 3D settings -> Vertical sync -> Use the 3D application setting / Off). Numbers at the cap hide the real frame cost; fix it and run again." % float(r["meta"].get("refresh_hz", 0.0))


## "" or the headless-floor warning: the measured frames sat at the engine's idle pad, so their times are not the cost.
static func floor_warning(r: Dictionary) -> String:
	var floored := false
	for p: Dictionary in r.get("phases", []):
		floored = floored or bool(p.get("floored", false))
	if not floored:
		return ""
	return "the headless frames sat at Godot's idle pad (%.1f ms: no window can draw, so every frame waits that long): the frame times above are that pad, not the cost, and the rest of the main thread cannot be read from them. Run the processor test with --fixed-fps 60 before --path (a tick with every frame, no pad)." % (float(OS.low_processor_usage_mode_sleep_usec) / 1000.0)


static func breakdown_capped(r: Dictionary) -> bool:
	var bd: Dictionary = r.get("breakdown", {})
	return not bd.is_empty() and float(bd["base"]["frame_ms"]) > 0.0 and at_refresh_rate(1000.0 / float(bd["base"]["frame_ms"]))


## Writes the report to `dir`/bench-<datetime>.txt (user://benchmarks by default); returns the path ("" on failure).
static func save_text(text: String) -> String:
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/bench-%s.txt" % [dir, Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(text + "\n")
	return path


static func log_text(text: String) -> void:
	for line in text.split("\n"):
		print("BENCHMARK ", line)
