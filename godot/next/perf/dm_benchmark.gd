class_name DmBenchmark
extends Node
## The in-game benchmark (character select "Benchmark" button, launch arg `--benchmark`): the same held fight on every PC so builds and machines
## compare. An ISOLATED offline game (DmBenchFight: mock backend with an in-memory db, nothing persisted, no network); the player's settings
## file is only READ (graphics preset, fps cap for the report; the run itself is uncapped with V-Sync off and auto resolution off).
## Setup (`configure`, the setup window DmBenchmarkSetup): room (ROOMS), class, fight size (SIZES) and length (LENGTHS); STANDARD is the setup
## that compares PCs. Fight: the room's own enemy kinds at the walkable point nearest its centre, every enemy with the same hp / damage in every room
## (`standard_stats`, no elites), a god-mode level 60 hero on auto combat, thralls raised directly, enemies topped up to the size's count, fixed seed and camera zoom. Warm-up (not measured; the first frames compile shaders), then the measured window, then the render breakdown.
## Per-frame cost: one float appended to a preallocated PackedFloat32Array plus a handful of engine counter reads; the fight upkeep (top-up,
## counts, progress text) runs at TICK_S. Wiring: `var b := DmBenchmark.new(); add_child(b); var r := await b.run()`; `progress(text)` fires ~1 Hz.
## Text report: `format_text(results)`; `save_text(text)` writes user://benchmarks/bench-<datetime>.txt.
## Render breakdown (`breakdown`, after the measured window): the fight is paused (the picture stays) and each of BREAK_CATS is hidden in turn for
## BREAK_MEASURE_S; the drop in draw calls / objects / render CPU / GPU / frame time against the everything-on sample is what that part costs
## on this PC. Hiding is visibility only (restored after each sample); nothing is freed or rebuilt.

signal progress(text: String)
signal breakdown_step(step: int, total: int, what: String)   ## the render breakdown froze the fight: step 0 = everything on, total + 1 = the re-measure
signal _step

const SEED := 20261011
## The setup that compares PCs: the Bell Sanctum (36 x 28 m: a small room keeps the pack on screen and the waves coming), Gravecaller (thrall master).
const STANDARD := {"room": "sanctum", "discipline": 2, "size": "standard", "length": "full"}
const ROOMS := ["graves", "warren", "ossuary", "nave", "coliseum", "sanctum", "cloister", "pyre", "fen"]   ## the combat areas (not the Depths instance)
const SIZES := {"light": [15, 10], "standard": [30, 20], "heavy": [60, 30]}   ## [enemies held, thralls]
const SIZE_NAMES := {"light": "Light", "standard": "Standard", "heavy": "Heavy"}
const LENGTHS := {"quick": [6.0, 20.0, false], "full": [10.0, 30.0, true]}   ## [warm-up s, measured s, render breakdown]
const LENGTH_NAMES := {"quick": "Quick (about 30 s)", "full": "Full (about 90 s)"}
const ENEMY_LIMIT := 100        ## bodies alive or dying at once (play: GLOBAL_ENEMY_CAP 72, which a Heavy fight's corpses would hit)
const ZOOM := 1.0
const TICK_S := 0.25
const DIR := "user://benchmarks"
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
const BREAK_CATS := ["Shadows", "Thralls", "Enemies", "World", "Effects", "HUD"]   ## HUD last: re-showing the whole interface is the biggest change
const BREAK_SETTLE_S := 1.0
const SPAWN_MIN_M := 6.0        ## the benchmark's wave spawn distance (m from the hero)
const SPAWN_MAX_M := 14.0

const BREAK_MEASURE_S := 5.0

var setup: Dictionary = STANDARD.duplicate()
var area: String = STANDARD["room"]
var discipline: int = STANDARD["discipline"]
var breakdown := true
var warm_s := 10.0
var measure_s := 30.0
var enemies := 30
var thralls := 20
var kills_measured := 0         ## enemies killed in the measured window (kills per minute in the report)
var game: DmNextGame
var results: Dictionary = {}
var cancelled := false
var backend_calls := 0
var area_nav_on := false        ## the fight area's navmesh was enabled (its seal broken for the throwaway character)
var paused_ok := false          ## the render breakdown froze the fight (tests)
var hitches: Array = []          ## frames over HITCH_MS in the measured window: {t, ms, kills, spawns, cold} (what happened in that frame)
var spawns := 0
var max_drift := 0.0            ## farthest the hero got from the centre between checks (m)
var kills := 0                  ## enemies killed during the run (proof the fight is a fight; in the report)

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
var _label := ""
var _shown_s := -1
var _vp: RID
var _saved_vsync := DisplayServer.VSYNC_ENABLED
var _saved_fps := 0
var _saved_ui_dir := "user://"
var _saved_scale := 1.0
var _hero: DmHeroBody
var _at := Vector3.ZERO


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
## benchmark's enemies had before rooms could be picked), so a kill costs the same hits whatever the room or the kind.
static func standard_stats() -> Dictionary:
	DmSimData.ensure()
	var def: Dictionary = DmContent.area(STANDARD["room"])
	var level := DmEnemyStats.area_level(STANDARD["room"], [1.0], 0.0)
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
	var settings := {"graphics": DmGraphicsPreset.normalize(user.get("graphics", DmGraphicsPreset.DEFAULT)), "fps": 0, "auto_res": false,
		"brightness": user.get("brightness", 1.0), "ui_scale": user.get("ui_scale", 1.0)}
	_fight = await DmBenchFight.boot(self, discipline, {"settings": settings, "audio": false, "waves": true}, settings, area)
	game = _fight["game"]
	_hero = _fight["hero"]
	_at = _fight["at"]
	game.director.rng.seed = SEED
	# The small room needs the waves close (play spawns at 18 m+, outside aggro: here that is the far corners), and tougher enemies keep
	# the density steady instead of a god-mode legion emptying the room between top-ups. The run's director is thrown away afterwards.
	game.director.spawn_min = SPAWN_MIN_M
	game.director.spawn_max = SPAWN_MAX_M
	game.director.cap = enemies
	game.director.enemy_limit = ENEMY_LIMIT
	game.director.fixed_stats = standard_stats()
	game.director.enemy_died.connect(func(_e: DmEnemy) -> void: kills += 1)
	game.director.enemy_spawned.connect(func(_e: DmEnemy) -> void: spawns += 1)
	# Hands off: the player's mouse and keys never reach the fight (no walking, hotkeys or panels; Esc stays the screen's), and auto combat
	# casts without walking, so the hero holds the room's centre (a dash is undone in _tick).
	game.input.auto.hold_position = true
	game.process_mode = Node.PROCESS_MODE_PAUSABLE   # explicit: the screen and the runner process always (Esc), the fight must still pause
	_lock_input(game)
	get_tree().node_added.connect(_on_node_added)
	var reg: NavigationRegion3D = game.world.builder.nav_regions.get("area:" + area) if game.world != null and game.world.builder != null else null
	area_nav_on = reg != null and reg.enabled   # a sealed area has its navmesh off: enemies could not reach the hero
	Engine.max_fps = 0
	results = {"meta": _meta(user), "phases": []}
	_label = "Fight"
	_frames = PackedFloat32Array()
	_frames.resize(int(measure_s * 1000.0) + 256)   # up to 1000 fps; later frames of a faster machine are only counted (`frames`)
	await _stage(1, warm_s)
	var kills_at := kills
	if not cancelled:
		_reset_acc()
		await _stage(2, measure_s)
	kills_measured = kills - kills_at
	if not cancelled:
		var ph := _summary()
		ph["kills"] = kills_measured
		ph["kills_per_min"] = kills_measured / maxf(measure_s, 0.001) * 60.0
		results["phases"].append(ph)
	if breakdown and not cancelled:
		results["breakdown"] = await _breakdown()
	results["kills"] = kills
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


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _fresh:
		_fresh = false
		_last_us = now
		return
	var ms := (now - _last_us) * 0.001
	_last_us = now
	_phase_t += ms * 0.001
	_tick_t += ms * 0.001
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


## Fight upkeep + progress, at TICK_S: enemies and thralls held at their targets, the hero unkillable, the camera at the fixed zoom.
func _tick() -> void:
	if get_tree().paused:   # the render breakdown holds the picture still
		return
	game.director.cap = enemies   # (configure_area resets it when the director follows the hero into the room)
	DmBenchFight.top_up(game, _hero, enemies)
	DmBenchFight.trim(game, _hero, enemies)
	var host := DmBenchFight.raise_thralls(_fight["caster"], thralls, _at)
	_hero.heal(1e6)
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
		_corpse_sum += game.corpses.count() if game.corpses != null else 0
		if game.rewards != null:
			for m in game.rewards.members.values():
				if m.loot_view != null:
					_loot_sum += m.loot_view.count()
		_en_min = mini(_en_min, game.director.alive_count())
		_th_sum += host.list().size()
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
	return {
		"label": "Fight", "frames": _n,
		"avg_fps": 1000.0 / maxf(avg, 0.001), "avg_ms": avg, "median_ms": sorted[n / 2] if n > 0 else 0.0,
		"p95_ms": sorted[mini(n - 1, int(n * 0.95))] if n > 0 else 0.0, "p99_ms": sorted[mini(n - 1, int(n * 0.99))] if n > 0 else 0.0,
		"worst_ms": worst, "hitches": hitches, "draw_calls": _calls / d, "objects": _objs / d, "primitives": _prims / d,
		"render_cpu_ms": _rcpu / d, "render_gpu_ms": _rgpu / d, "process_ms": _proc / d * 1000.0, "physics_ms": _phys / d * 1000.0,
		"loot": _loot_sum / maxf(1.0, _ticks), "corpses": _corpse_sum / maxf(1.0, _ticks),
		"enemies": _en_sum / maxf(1.0, _ticks), "enemies_min": _en_min if _ticks > 0 else 0, "thralls": _th_sum / maxf(1.0, _ticks), "capped": at_refresh_rate(1000.0 / maxf(avg, 0.001)),
	}


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
	restored = restored and (game.ui == null or game.ui.visible)
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
	await _stage(1, BREAK_SETTLE_S)
	_reset_acc()
	await _stage(3, BREAK_MEASURE_S)
	var d := float(maxi(1, _n))
	return {"draws": _calls / d, "objects": _objs / d, "render_cpu_ms": _rcpu / d, "render_gpu_ms": _rgpu / d, "frame_ms": _ms_sum / d}


## Hides one breakdown part; returns the Callable that shows it again.
func _hide(cat: String) -> Callable:
	match cat:
		"HUD":
			var ui: CanvasLayer = game.ui
			if ui == null:
				return func() -> void: pass
			var was := ui.visible
			ui.visible = false
			return func() -> void: ui.visible = was
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
		if p is DmThrall:
			return "Thralls"
		if p is DmEnemy:
			return "Enemies"
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


## The installed build's version ("20261013.225809-36e80e1"): the launcher installs each build in a folder of its own with the manifest
## it came from (launcher/windows/ClientInstaller.cs), so it is read from the manifest.json next to the exe; "dev" for an editor or hand-run build.
static func client_version() -> String:
	var mf := OS.get_executable_path().get_base_dir().path_join("manifest.json")
	if FileAccess.file_exists(mf):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(mf))
		if j is Dictionary and j.get("version") is String and String(j["version"]) != "":
			return String(j["version"])
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	return ver if ver != "" else "dev"


func _meta(user: Dictionary) -> Dictionary:
	var ver := client_version()
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
		"fight": "%d enemies (same health and damage in every room, no elites), %d thralls, level 60 god mode, auto combat, seed %d, warm-up %d s, measured %d s" % [enemies, thralls, SEED, int(warm_s), int(measure_s)],
	}


## Plain-text report: header, then one column per phase (ON | OFF side by side when both ran).
static func format_text(r: Dictionary) -> String:
	var m: Dictionary = r["meta"]
	var L: PackedStringArray = []
	L.append("Death Muffin benchmark")
	L.append("Build: %s (game %s)   %s" % [m["build"], m["version"], m["date"]])
	L.append("GPU: %s   Renderer: %s   Godot %s" % [m["gpu"], m["renderer"], m["godot"]])
	L.append("CPU: %s (%d threads)   OS: %s" % [m["cpu"], m["cores"], m["os"]])
	L.append("Resolution: %s   Graphics preset: %s   Fps cap (setting): %s   V-Sync: %s" % [m["resolution"], m["preset"], str(m["fps_cap"]) if int(m["fps_cap"]) > 0 else "none", m["vsync"]])
	L.append("Setup: %s" % m.get("setup", ""))
	L.append("Fight: %s   kills during the run: %d" % [m["fight"], int(r.get("kills", 0))])
	if bool(r.get("cancelled", false)):
		L.append("(cancelled: only finished phases are listed)")
	var ph: Array = r["phases"]
	var warn := capped_warning(r)
	if warn != "":
		L.append("WARNING: " + warn)
	var head := "%-26s" % ""
	for p in ph:
		head += "%-30s" % p["label"]
	L.append(head)
	for row in DmBenchmark.ROWS:
		var line := "%-26s" % row[1]
		for p in ph:
			line += "%-30s" % (row[2] % p[row[0]])
		L.append(line)
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


static func breakdown_capped(r: Dictionary) -> bool:
	var bd: Dictionary = r.get("breakdown", {})
	return not bd.is_empty() and float(bd["base"]["frame_ms"]) > 0.0 and at_refresh_rate(1000.0 / float(bd["base"]["frame_ms"]))


## Writes the report to user://benchmarks/bench-<datetime>.txt; returns the path ("" on failure).
static func save_text(text: String) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := "%s/bench-%s.txt" % [DIR, Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(text + "\n")
	return path


static func log_text(text: String) -> void:
	for line in text.split("\n"):
		print("BENCHMARK ", line)
