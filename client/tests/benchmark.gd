extends SceneTree
## The in-game benchmark on the combat core (ROADMAP: "The Full Party fight in the new client", Gate B), headless: `godot --headless --path client --script res://tests/benchmark.gd`.
## Short runs of the real thing, deterministic checks only (timings are printed as INFO and never asserted):
##   - the setup: sizes, the Gravecaller in the Hollow Graves, today's enemy health, the budgets are the ROADMAP's, any other room or class is refused with a plain message;
##   - the fight is set up as the setup says: 72 enemies held (the farthest extras trimmed without a death), 32 thralls, the Gravedigger King awake, the fixed seed, every enemy on
##     the standard health, the hero holding the centre, no node per creature;
##   - Easy auto combat casts (the gate is closed until opened, it casts, it walks when it may, it reads the corpses and the core's bulk arrays, and nothing is a node);
##   - the report has its lines and its budget section prints, with a verdict for the core and the rest of the main thread, and the HUD's share is measured with the HUD put back after;
##   - a real `--benchmark` launch (--bench-warm / --bench-measure) prints the report and quits by itself; another room or class is refused with exit code 2;
##   - nothing is sent anywhere but the test API or the mock: the benchmark's own backend is the mock, an upload goes to the test API only, a debug build does not upload;
##   - the render breakdown, the history and the setup window work; Esc cancels;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber and the hound into a scratch folder first (the rest of the Graves roster borrows them: warnings, not errors). About 3 minutes.

const OUT := "user://benchmark_test"
const BAKE := ["grave_robber", "bone_hound"]
const STD_HP := 272.928627      ## the health every enemy has (today's DmBenchmark.standard_stats at c47c35a1)
const STD_DMG := 10.848627


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## A stand-in for the panels (`game.ui`, not built): a layer that counts its frames, so the HUD share can be seen switching it off and on with the HUD on the core.
class StubHud:
	extends CanvasLayer
	var frames := 0

	func _process(_d: float) -> void:
		frames += 1

	func panel_open() -> bool:   # (what the game asks of its full HUD: Easy auto combat yields to an open panel)
		return false


var fails := 0
var checks := 0
var errlog := ErrorLog.new()


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL benchmark: " + what)


## True when a node under `from` runs a script whose class_name is `cls` (`find_children` only knows the engine's classes).
func has_script_class(from: Node, cls: String) -> bool:
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		var sc: Script = nd.get_script()
		if sc != null and String(sc.get_global_name()) == cls:
			return true
	return false


func nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	DmSimData.ensure()
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	for f in [DmBenchHistory.FILE, DmBenchHistory.PENDING, DmBenchmarkSetup.FILE]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	await the_setup()
	await the_fight_by_hand()
	await auto_combat()
	await full_party_run()
	await breakdown_run()
	await screen_and_upload()
	await esc_cancels()
	setup_window()
	await real_launches()
	finish()


# ------------------------------------------------------------------------------------------------------------------ the setup

func the_setup() -> void:
	var cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	check(DmBenchmark.SIZES["full_party"] == [cap, 32] and DmBenchmark.BOSS_SIZES == ["full_party"] and DmBenchmark.SIZE_NAMES["full_party"] == "Full Party",
		"Full Party: the global enemy cap (%d) and 32 thralls, the only size with a boss" % cap)
	check(DmBenchmark.SIZES["light"] == [15, 10] and DmBenchmark.SIZES["standard"] == [30, 20] and DmBenchmark.SIZES["heavy"] == [60, 30], "the other sizes are today's")
	check(DmBenchmark.LENGTHS["quick"] == [6.0, 20.0, false] and DmBenchmark.LENGTHS["full"] == [10.0, 30.0, true], "the lengths are today's")
	check(DmBenchmark.ENEMY_LIMIT > cap and DmBenchmark.SEED == 20261011, "the director's body limit leaves room for the corpses; the seed is today's (%d)" % DmBenchmark.SEED)
	check(DmBenchmark.ROOMS == ["graves"] and DmBenchmark.CLASSES == [2] and DmBenchmark.class_indices() == [2], "the client has the Hollow Graves and the Gravecaller")
	check(DmBenchmark.BUDGET_CORE_MS == 4.0 and DmBenchmark.BUDGET_REST_MS == 4.0 and DmBenchmark.BUDGET_HUD_MS == 0.5 and DmBenchmark.BUDGET_HUD_DRAWS == 150, "the budgets are the ROADMAP's: core 4 ms, rest 4 ms, HUD 0.5 ms and 150 draws")
	check(DmBenchmark.normalize_setup({"room": "nowhere", "discipline": 7, "size": "huge"}) == DmBenchmark.STANDARD, "unknown picks fall back to the Standard setup")
	check(DmBenchmark.normalize_setup({"room": "sanctum", "discipline": 3})["room"] == "graves" and DmBenchmark.normalize_setup({"discipline": 3})["discipline"] == 2, "a room or class the client lacks falls back to the Graves and the Gravecaller")
	check(DmBenchmark.is_standard(DmBenchmark.STANDARD) and not DmBenchmark.is_standard({"room": "graves", "discipline": 2, "size": "full_party", "length": "full"}), "Standard is the Graves, Gravecaller, Standard, Full")
	# a room or class the build cannot run is refused in plain words
	check(DmBenchmark.refusal({"room": "graves", "discipline": 2}) == "" and DmBenchmark.refusal({}) == "", "the Graves and the Gravecaller are not refused")
	var why_room := DmBenchmark.refusal({"room": "sanctum"})
	check(why_room.contains("Hollow Graves") and why_room.contains("sanctum") and why_room.contains("comes with its area"), "another room is refused with a clear message (%s)" % why_room)
	var why_class := DmBenchmark.refusal({"discipline": 11})
	check(why_class.contains("Gravecaller") and why_class.contains("class 11"), "another class is refused with a clear message (%s)" % why_class)
	# the enemies' health and damage are today's: the Bell Sanctum roster's weighted average on Easy, whatever the room
	var std := DmBenchmark.standard_stats()
	check(absf(float(std["hp"]) - STD_HP) < 0.001 and absf(float(std["dmg"]) - STD_DMG) < 0.001, "every enemy has today's health %.3f and damage %.3f (%.3f, %.3f)" % [STD_HP, STD_DMG, std["hp"], std["dmg"]])
	check(DmBenchFight.boss_of("graves") == "gravedigger", "the Graves' boss is the Gravedigger King")
	var fp := DmBenchmark.new()
	fp.configure({"room": "graves", "discipline": 2, "size": "full_party", "length": "quick"})
	check(fp.enemies == cap and fp.thralls == 32 and fp.boss_id == "gravedigger" and not fp.breakdown and fp.warm_s == 6.0 and fp.measure_s == 20.0 and fp.boss_text().contains("Gravedigger King"),
		"configure: Full Party in the Graves holds the King (%d, %d, %s)" % [fp.enemies, fp.thralls, fp.boss_id])
	fp.configure({"room": "graves", "size": "heavy"})
	check(fp.boss_id == "" and fp.boss_text() == "", "the other sizes have no boss")
	fp.free()
	check(DmBenchmark.verdict(3.99, 4.0) == "PASS" and DmBenchmark.verdict(4.01, 4.0) == "MISS" and DmBenchmark.verdict(4.0, 4.0) == "PASS", "a verdict is PASS up to the budget")
	check(not DmBenchmark.at_refresh_rate(1000.0) and DmBenchmark.capped_warning({"phases": [{"capped": false}], "meta": {}}) == "", "V-Sync warning: none when not at the refresh rate")
	check(DmBenchmark.capped_warning({"phases": [{"capped": true}], "meta": {"refresh_hz": 170.0}}).contains("170 Hz"), "V-Sync warning: names the refresh rate")
	check(DmBenchmark.core_version().begins_with("dmcore"), "the report names the combat core (%s)" % DmBenchmark.core_version())
	check(DmBenchmark.budget_lines({"phases": []}).is_empty(), "no phase, no budget section")
	var unbaked := {"meta": {"crowd_models": 0, "build": "dev", "version": "dev", "date": "", "gpu": "", "renderer": "", "godot": "", "cpu": "", "cores": 1, "os": "", "resolution": "", "preset": "high", "fps_cap": 0, "vsync": "", "setup": "", "fight": ""},
		"phases": [], "kills": 0}
	check(DmBenchmark.format_text(unbaked).contains("WARNING: no crowd model is baked") and not DmBenchmark.format_text(unbaked.merged({"meta": unbaked["meta"].merged({"crowd_models": 3}, true)}, true)).contains("no crowd model is baked"), "a crowd with nothing baked is warned about")
	var M: GDScript = load("res://main/main.gd")
	var a: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-room=graves", "--bench-class=2", "--bench-size=heavy", "--bench-length=quick"]))
	check(a["room"] == "graves" and int(a["discipline"]) == 2 and a["size"] == "heavy" and a["length"] == "quick", "launch args pick the setup")
	var fa: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-size=full_party"]))
	check(fa["size"] == "full_party" and fa["room"] == "graves", "--bench-size=full_party picks Full Party")
	var want: Dictionary = M.bench_wanted_from_args(PackedStringArray(["--benchmark", "--bench-room=fen", "--bench-class=11"]))
	check(want == {"room": "fen", "discipline": 11} and DmBenchmark.refusal(want) != "", "launch args that name another room or class are what the refusal is asked about")


# ------------------------------------------------------------------------------------------------------------------ the fight, by hand

## DmBenchFight on a booted game: the pieces of the held fight one at a time.
func the_fight_by_hand() -> void:
	var f := await DmBenchFight.boot(root, 2, {"audio": false, "baked_dir": OUT}, "graves")
	var g: DmNextGame = f["game"]
	var host: DmCoreHost = g.core_host
	var hero: DmHeroBody = f["hero"]
	var at: Vector3 = f["at"]
	check(g.ready_ and int(g.opts["seed"]) == DmBenchmark.SEED, "the game was built with the fixed seed")
	check(g.world.area_at(at.x, at.z) == "graves" and hero.position.distance_to(at) < 0.1 and g.world.nav_closest(at).distance_to(at) < 0.5, "the hero stands on walkable ground in the Graves (%s)" % str(at))
	check(DmNextWarmup.crowd_rows == host.view.model_slots().size() * 3 * 2 and host.is_physics_processing() and g.is_processing(), "the warm-up fed %d rehearsal rows to the crowd and gave the game back" % DmNextWarmup.crowd_rows)
	check(host.view.stats().bodies == 0, "the rehearsal rows are gone from the crowd (%d bodies)" % int(host.view.stats().bodies))
	check(bool(hero.p["god"]) and float(f["caster"].p["stats"]["level"]) == 60.0 and g.director.difficulty == "easy" and g.input.auto.allowed(), "a god-mode level 60 hero on Easy, auto combat open")
	check(int(f["stats"]["calls"]) > 0 and g.api.get("base_url") == "", "the backend is the mock (%d requests, no base url)" % int(f["stats"]["calls"]))
	DmBenchFight.arm(g, 72, DmBenchmark.SEED)
	check(g.director.rng.seed == DmBenchmark.SEED and g.director.cap == 72 and g.director.enemy_limit == DmBenchmark.ENEMY_LIMIT and g.input.auto.hold_position
		and g.director.spawn_min == DmBenchmark.SPAWN_MIN_M and g.director.spawn_max == DmBenchmark.SPAWN_MAX_M, "arm: the director's seed, cap, limit and spawn distances, and the hero holds his ground")
	check(absf(float(g.director.fixed_stats["hp"]) - STD_HP) < 0.001, "arm: every enemy takes the standard health")
	g.director.enabled = false
	await ticks(30)
	var n0 := nodes()
	# 72 enemies through the director, and the count is held
	DmBenchFight.top_up(g, hero, 72)
	g.director.flush_spawns()
	var died := [0]
	host.enemy_died.connect(func(_i: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: died[0] += 1)
	await ticks(3)
	check(g.director.alive_count() == 72 and host.enemy_total() == 72, "top-up: 72 enemies alive through the director (%d)" % g.director.alive_count())
	# extras past the cap (a raiser's Risen, the boss's adds): the farthest go quietly
	var far_ids: Array = []
	for i in 6:
		far_ids.append(host.spawn_enemy("robber", g.world.nav_closest(at + Vector3(24.0 + float(i), 0.0, 0.0)), 1, 1.0, 1.0, false, "graves", false))
	await ticks(2)
	var far_ok := true
	for id in far_ids:
		far_ok = far_ok and host.enemy_position(id).distance_to(hero.position) > DmBenchmark.SPAWN_MAX_M + 2.0
	check(far_ok, "the extras stand beyond the waves' spawn ring")
	check(host.alive_count() == 78, "six extra bodies: 78 alive")
	DmBenchFight.trim(g, hero, 72)
	await ticks(2)
	var gone := 0
	for id in far_ids:
		if host.enemy_info(id).is_empty() or not host.enemy_alive(id):
			gone += 1
	check(host.alive_count() == 72 and gone == 6 and died[0] == 0, "trim: the six farthest left without a death, 72 are held (%d alive, %d gone, %d deaths)" % [host.alive_count(), gone, died[0]])
	check(host.corpses.count() == 0, "trim leaves no corpse")
	# 32 thralls, raised straight into the core
	check(DmBenchFight.raise_thralls(g, hero, 32, at) == 32 and host.thrall_count(hero.core_id) == 32 and DmBenchFight.raise_thralls(g, hero, 32, at) == 32, "32 thralls are raised, and raised once")
	await ticks(20)
	var n1 := nodes()
	check(n1 - n0 <= 12, "72 enemies and 32 thralls in the core: the scene tree holds %d nodes, was %d (no node per creature)" % [n1, n0])
	check(get_nodes_in_group("dm_enemy").is_empty() and root.find_children("*", "NavigationAgent3D", true, false).is_empty() and root.find_children("*", "HTTPRequest", true, false).is_empty(),
		"no node is in an enemy group, no agent, no HTTP request")
	var std_ok := true
	for id in host.core.enemy_ids():
		std_ok = std_ok and absf(float(host.core.enemy_info(id)["max_hp"]) - STD_HP) < 0.01
	check(std_ok, "every enemy has the standard health")
	# the King, through the real summon
	check(g.bosses.active_boss() == null, "the King sleeps before the summon")
	hero.teleport(at)
	check(DmBenchFight.hold_boss(g, hero, "gravedigger", at), "hold_boss: the King is summoned")
	await ticks(5)
	var king := g.bosses.active_boss()
	check(king != null and king.boss_id == "gravedigger" and king.is_awake(), "the King is awake")
	check(hero.position.distance_to(at) < 0.1, "the hero is back at the centre after the summon")
	check(not DmBenchFight.hold_boss(g, hero, "gravedigger", at), "an awake King is not summoned twice")
	check(DmBenchFight.upkeep(f, 72, 32, "gravedigger") == 32, "upkeep returns the legion held")
	g.queue_free()
	await process_frame
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ Easy auto combat

func auto_combat() -> void:
	var f := await DmBenchFight.boot(root, 2, {"audio": false, "baked_dir": OUT, "warmup": false}, "graves")
	var g: DmNextGame = f["game"]
	var host: DmCoreHost = g.core_host
	var hero: DmHeroBody = f["hero"]
	var at: Vector3 = f["at"]
	var auto: DmNextAutoCombat = g.input.auto
	g.director.enabled = false
	# closed until something opens it: the rebuilt client has no settings store
	auto.gate_probe = Callable()
	check(not auto.allowed(), "auto combat is closed by default (no settings store opens it)")
	var casts0 := int(auto.stats["casts"])
	for i in 8:
		host.spawn_enemy("robber", at + Vector3(4.0 + float(i) * 0.5, 0.0, float(i % 3) - 1.0), 60, 5.0, 0.0, false, "graves", false)
	await ticks(90)
	check(int(auto.stats["casts"]) == casts0, "a closed gate casts nothing")
	auto.gate_probe = func() -> bool: return true
	auto.hold_position = true
	var hotbar: Array = []
	g.input.hotbar.connect(func(slot: int, _aim: Vector3, enemy_id: int) -> void: hotbar.append([slot, enemy_id]))
	var damaged := [0]
	host.enemy_damaged.connect(func(_i: int, _s: int, _a: float, _h: float) -> void: damaged[0] += 1)
	await ticks(180)
	check(int(auto.stats["casts"]) > casts0 and not hotbar.is_empty(), "auto combat casts (%d casts)" % int(auto.stats["casts"]))
	var intents_ok := true
	for h in hotbar:
		intents_ok = intents_ok and int(h[0]) >= 0 and int(h[0]) <= 6 and (int(h[1]) == 0 or host.enemy_alive(int(h[1])) or true)
	check(intents_ok, "it casts through the hotbar seam, slots 0 to 6, as the keyboard does")
	check(damaged[0] > 0, "and the casts land (%d blows on enemies)" % damaged[0])
	check(hero.position.distance_to(at) < 1.6 and int(auto.stats["moves"]) == 0, "holding position it never walks (moved %.2f m, %d walks)" % [hero.position.distance_to(at), int(auto.stats["moves"])])
	# what it reads: the core's bulk arrays and the facts the host's signals keep
	check(auto._core_wired and auto._facts.size() > 0 and auto._facts.size() <= host.core.enemy_count(), "it keeps %d enemy records, from the core's events" % auto._facts.size())
	auto._gather(hero.position, "graves")
	var live := 0
	for id in host.core.enemy_ids():
		var inf: Dictionary = host.core.enemy_info(id)
		if int(inf["state"]) != DmCoreEvents.State.DEAD and int(inf["state"]) != DmCoreEvents.State.RISING and int(inf["state"]) != DmCoreEvents.State.BURROW and int(inf["state"]) != DmCoreEvents.State.ERUPT \
				and Vector2(inf["pos"].x - hero.position.x, inf["pos"].y - hero.position.z).length() <= DmNextAutoCombat.RANGE_M:
			live += 1
	check(auto._enemies.size() == live, "its gather finds the %d living, hittable enemies in range (%d)" % [live, auto._enemies.size()])
	var rec_ok := not auto._enemies.is_empty()
	for r in auto._enemies:
		var inf2: Dictionary = host.core.enemy_info(int(r["id"]))
		rec_ok = rec_ok and not inf2.is_empty() and absf(float(r["radius"]) - float(inf2["radius"])) < 0.001 and absf(float(r["hp"]) - float(inf2["hp"])) < 0.01 and float(r["maxHp"]) == float(inf2["max_hp"]) \
			and absf(float(r["x"]) - float(inf2["pos"].x)) < 0.01 and String(r["area"]) == "graves"
	check(rec_ok, "each record carries the core's position, radius, health and area")
	# corpses
	for id in host.core.enemy_ids():
		host.damage(int(id), 1.0e9, hero.core_id)
	await ticks(4)
	auto._gather(hero.position, "graves")
	check(host.corpses.count() > 0 and auto._corpses.size() == host.corpses.count(), "the corpses it reads are the core's (%d of %d)" % [auto._corpses.size(), host.corpses.count()])
	var kinds_ok := true
	for c in auto._corpses:
		kinds_ok = kinds_ok and DmCoreEvents.CORPSE_KINDS.has(String(c["kind"])) and String(c["area"]) == "graves" and String(c["seedOwner"]) == ""
	check(kinds_ok, "a corpse record has its kind, area and no seed")
	# it walks when it may, toward a pack out of reach
	auto.hold_position = false
	for id in host.core.enemy_ids():
		host.remove_enemy(int(id))
	var walks0 := int(auto.stats["moves"])
	for i in 8:
		host.spawn_enemy("robber", at + Vector3(0.0, 0.0, -22.0 + float(i) * 0.6), 60, 5.0, 0.0, false, "graves", false)
	await ticks(150)
	check(int(auto.stats["moves"]) > walks0, "not holding its ground it walks toward a pack out of reach (%d walks, moved %.1f m)" % [int(auto.stats["moves"]) - walks0, hero.position.distance_to(at)])
	# a hostile zone is a hazard it leaves
	host.zone.emit(900, 0, 0, hero.position.x, hero.position.z, 3.0, 5.0)
	auto._gather(hero.position, "graves")
	check(auto._hazards.size() >= 1 and auto._hazards.any(func(hz: Dictionary) -> bool: return hz.get("k") == "circle" and absf(float(hz["x"]) - hero.position.x) < 0.01), "a hostile zone under the hero is a hazard")
	host.zone_gone.emit(900)
	check(not auto._zones.has(900), "and the zone ends with its event")
	g.queue_free()
	await process_frame
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the Full Party run

var hp_seen := {}
var boss_seen := 0
var samples := 0
var casts_seen := 0
var nodes_lo := 1 << 30
var nodes_hi := 0
var creature_nodes := 0         ## samples in which a node of a creature kind existed (an enemy group, an agent, a physics body other than the hero's)


func note(b: DmBenchmark) -> void:
	if b.game == null or not is_instance_valid(b.game) or b.game.core_host == null or b.game.core_host.core == null:
		return
	samples += 1
	var core: RefCounted = b.game.core_host.core
	for id in core.enemy_ids():
		hp_seen[round(float(core.enemy_info(id)["max_hp"]) * 1000.0)] = true
	if b.game.bosses.active_boss() != null:
		boss_seen += 1
	casts_seen = int(b.game.input.auto.stats["casts"])
	if b.game.bosses.active_boss() != null:   # (the King's own nodes are there from his summon on)
		nodes_lo = mini(nodes_lo, nodes())
		nodes_hi = maxi(nodes_hi, nodes())
	if not get_nodes_in_group("dm_enemy").is_empty() or not root.find_children("*", "NavigationAgent3D", true, false).is_empty() or root.find_children("*", "CharacterBody3D", true, false).size() > 1:
		creature_nodes += 1


func full_party_run() -> void:
	var cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	var b := DmBenchmark.new()
	b.configure({"room": "graves", "discipline": 2, "size": "full_party", "length": "quick"})
	b.warm_s = 3.0
	b.measure_s = 6.0
	b.hud_rounds = 3
	b.hud_sample_s = 0.5
	b.hud_settle_s = 0.2
	b.baked_dir = OUT
	var lines := PackedStringArray()
	b.progress.connect(func(t: String) -> void:
		lines.append(t)
		note(b))
	root.add_child(b)
	var r: Dictionary = await b.run()
	check(not r["cancelled"] and not bool(r["standard"]) and r["setup"]["size"] == "full_party" and r["setup"]["room"] == "graves", "the Full Party run completes and is a custom setup")
	var ph: Dictionary = r["phases"][0]
	for row in DmBenchmark.ROWS:
		check(ph.has(row[0]), "the phase has %s" % row[0])
	check(int(ph["frames"]) > 0 and float(ph["avg_fps"]) > 0.0 and float(ph["p95_ms"]) >= float(ph["median_ms"]) and float(ph["worst_ms"]) >= float(ph["p99_ms"]), "frame stats are coherent")
	check(float(ph["enemies"]) >= cap * 0.85 and int(ph["enemies_min"]) > 0, "72 enemies held (%.1f on average, fewest %d)" % [ph["enemies"], int(ph["enemies_min"])])
	check(float(ph["thralls"]) >= 32.0 - 0.01, "32 thralls held (%.1f)" % float(ph["thralls"]))
	check(b.boss_summons >= 1 and String(r["boss"]["id"]) == "gravedigger" and int(r["boss"]["summons"]) == b.boss_summons and boss_seen > 0, "the King was woken (%d times, %d defeats, awake in %d of %d samples)" % [b.boss_summons, b.boss_defeats, boss_seen, samples])
	check(float(ph["boss_awake_pct"]) >= 50.0, "and was awake for most of the window (%.0f%%)" % float(ph["boss_awake_pct"]))
	check(hp_seen.size() == 1 and absf(float(hp_seen.keys()[0]) / 1000.0 - STD_HP) < 0.01, "every enemy, the King's adds included, had the standard health (%s)" % str(hp_seen.keys()))
	check(casts_seen > 5 and int(r["kills"]) >= 5, "auto combat cast %d times and %d enemies died: the fight is a fight" % [casts_seen, int(r["kills"])])
	check(float(r["max_drift"]) <= 1.6, "the hero holds the centre (farthest %.2f m between checks)" % float(r["max_drift"]))
	check(b.area_nav_on and bool(r["input_locked"]), "the Graves' navmesh is on and the player's input is switched off")
	print("INFO nodes with the King awake: %d to %d" % [nodes_lo, nodes_hi])
	check(samples > 0 and creature_nodes == 0, "in none of the %d samples of the fight did a node exist for a creature (enemy group, navigation agent, physics body)" % samples)
	check(r["backend_calls"] > 0 and r["meta"]["core"].begins_with("dmcore") and r["meta"]["fight"].contains("seed 20261011") and r["meta"]["fight"].contains("Gravedigger King held awake"), "the mock backend served the run; the meta names the core, the seed and the King")
	for k in ["build", "gpu", "renderer", "resolution", "preset", "fps_cap", "cpu", "cores", "vsync", "setup", "fight", "core"]:
		check(r["meta"].has(k), "meta has %s" % k)
	check(root.find_children("*", "HTTPRequest", true, false).is_empty() and not has_script_class(root, "DmHttpTransport"), "no network node was created")
	check(DmUiConfig.dir == "user://" and DmBuild.version() == "dev", "the UI config dir is restored")
	check(lines.size() >= 2 and lines[0].begins_with("Building"), "progress lines were emitted")
	# the core's budget: the numbers exist and add up
	check(float(ph["core_ms"]) > 0.0 and absf(float(ph["core_ms"]) - (float(ph["core_step_ms"]) + float(ph["core_sync_ms"]) + float(ph["core_events_ms"]))) < 1e-6, "the core's tick is its step + crowd sync + event dispatch (%.2f ms)" % float(ph["core_ms"]))
	check(float(ph["ticks_per_frame"]) > 0.0 and absf(float(ph["core_frame_ms"]) - float(ph["core_ms"]) * float(ph["ticks_per_frame"])) < 1e-6, "the core's cost a frame is its tick times the ticks a frame ran (%.2f x %.2f)" % [float(ph["core_ms"]), float(ph["ticks_per_frame"])])
	check(absf(float(ph["rest_ms"]) - maxf(0.0, float(ph["avg_ms"]) - float(ph["core_frame_ms"]))) < 1e-6, "the rest of the frame is the frame less the core's share (%.2f ms)" % float(ph["rest_ms"]))
	check(b.hud_checked and ph.has("hud_ms") and ph.has("hud_noise_ms") and float(ph["hud_ms"]) >= 0.0, "the HUD's share was measured (%.2f ms, samples %.2f ms apart)" % [float(ph.get("hud_ms", -1.0)), float(ph.get("hud_noise_ms", -1.0))])
	# the report
	var text := DmBenchmark.format_text(r)
	for needle in ["Death Muffin benchmark", "Average fps", "Frame ms (p95)", "V-Sync: off during measurement", "Combat core: dmcore", "Setup: The Hollow Graves, Gravecaller, Full Party, Quick (custom",
			"Boss: The Gravedigger King", "held awake", "seed 20261011"]:
		check(text.contains(needle), "the report has '%s'" % needle)
	var budget := DmBenchmark.budget_lines(r)
	var btext := "\n".join(budget)
	check(budget.size() == 5 and btext.contains("Budgets (ROADMAP") and btext.contains("Combat core per tick") and btext.contains("Rest of the main thread per frame") and btext.contains("HUD per frame") and btext.contains("HUD draw calls"),
		"the budget section prints: the core, the rest, the HUD and its draws")
	var floored := bool(ph["floored"])
	check(btext.contains("Combat core per tick: ") and (btext.contains("of 4.0 ms   PASS") or btext.contains("of 4.0 ms   MISS")) and text.contains(btext), "the core gets a verdict against 4.0 ms, and the section is in the report")
	if floored:   # a plain headless run: every frame waits the engine's pad
		check(btext.contains("Rest of the main thread per frame: not measured") and text.contains("WARNING: the headless frames sat at Godot's idle pad"), "a run at the headless frame pad says so and does not judge the rest of the frame")
	else:
		check(btext.contains("Rest of the main thread per frame: ") and btext.contains("of 4.0 ms   "), "the rest of the main thread gets a verdict against 4.0 ms")
	# both branches by hand
	var pad := float(OS.low_processor_usage_mode_sleep_usec) / 1000.0
	var shape := {"avg_ms": 5.0, "rest_ms": 3.5, "core_ms": 2.0, "core_step_ms": 1.5, "core_sync_ms": 0.2, "core_events_ms": 0.3, "ticks_per_frame": 1.0, "core_frame_ms": 1.5}
	var open_run := {"phases": [shape.merged({"floored": false})], "setup": {"size": "full_party"}}
	var pad_run := {"phases": [shape.merged({"floored": true})], "setup": {"size": "full_party"}, "meta": {}}
	check("\n".join(DmBenchmark.budget_lines(open_run)).contains("Rest of the main thread per frame: 3.50 ms of 4.0 ms   PASS") and DmBenchmark.floor_warning(open_run) == "", "a free frame's rest is judged against 4.0 ms")
	check("\n".join(DmBenchmark.budget_lines(pad_run)).contains("not measured (the headless frames sat at Godot's idle pad") and DmBenchmark.floor_warning(pad_run).contains("--fixed-fps 60"), "a run on the pad is not judged, and the warning names --fixed-fps 60")
	check(not DmBenchmark.at_headless_floor(pad * 0.5) and not DmBenchmark.at_headless_floor(pad * 1.5) and (DmBenchmark.at_headless_floor(pad) == not ("--fixed-fps" in OS.get_cmdline_args())), "only a frame at the pad (%.1f ms) is the pad" % pad)
	check(btext.contains("not measured (the render breakdown runs in a Full-length run)"), "a quick run says the HUD's draw calls come from the render breakdown")
	var path := DmBenchmark.save_text(text)
	check(path.begins_with("user://benchmarks/bench-") and FileAccess.get_file_as_string(path).contains("Combat core per tick"), "the report is saved under user://benchmarks")
	# upload payload and history
	var p := DmBenchHistory.payload(r, text)
	for k in ["clientRunId", "ranAt", "version", "gpu", "cpu", "preset", "room", "discipline", "size", "length", "standard", "vsyncCapped", "cancelled", "metrics", "report"]:
		check(p.has(k), "upload payload has %s" % k)
	check(p["room"] == "graves" and p["size"] == "full_party" and p["standard"] == false and ["low", "medium", "high", "ultra"].has(p["preset"]), "payload: the setup and a preset the server accepts")
	for k in ["avg_fps", "p95_ms", "boss_awake_pct", "core_ms", "rest_ms", "hud_ms"]:
		check((p["metrics"] as Dictionary).has(k), "payload: the metrics have %s" % k)
	check((p["metrics"] as Dictionary).size() <= 60, "payload: at most the 60 metrics the server keeps (%d)" % (p["metrics"] as Dictionary).size())
	check(DmBenchHistory.previous(p).is_empty(), "no earlier run to compare with")
	DmBenchHistory.record(p)
	var p2 := p.duplicate(true)
	p2["clientRunId"] = "second-run-1"
	check(DmBenchHistory.previous(p2).get("clientRunId") == p["clientRunId"], "the previous run of the same setup on the same PC is found")
	print("INFO bench Full Party fps=%.1f avg=%.2f p95=%.2f core=%.2f ms/tick rest=%.2f ms/frame hud=%.2f ms enemies=%.1f thralls=%.1f boss woken %d defeated %d" % [
		ph["avg_fps"], ph["avg_ms"], ph["p95_ms"], ph["core_ms"], ph["rest_ms"], float(ph.get("hud_ms", 0.0)), ph["enemies"], ph["thralls"], b.boss_summons, b.boss_defeats])
	for line in budget:
		print("INFO " + line)
	b.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the render breakdown and the HUD's share

func breakdown_run() -> void:
	var b := DmBenchmark.new()
	b.configure({"room": "graves", "discipline": 2, "size": "light", "length": "full"})
	b.warm_s = 1.0
	b.measure_s = 2.0
	b.break_settle_s = 0.2
	b.break_measure_s = 0.5
	b.hud_rounds = 2
	b.hud_sample_s = 0.4
	b.hud_settle_s = 0.2
	b.baked_dir = OUT
	check(b.breakdown and b.enemies == 15 and b.thralls == 10 and b.boss_id == "", "configure: Light, Full length (render breakdown on)")
	var stub := StubHud.new()
	var stub_off := [0]
	var stub_on := [0]
	var steps: Array = []
	b.breakdown_step.connect(func(step: int, _total: int, _what: String) -> void: steps.append(step))
	b.progress.connect(func(t: String) -> void:
		if b.game != null and b.game.ui == null and t.begins_with("Warming"):
			b.game.ui = stub   # the panels appear (their item): the share and the breakdown handle them with the HUD on the core
			b.game.add_child(stub)
		if t.contains("HUD costs (off)") and not stub.visible and stub.process_mode == Node.PROCESS_MODE_DISABLED and b.game.hud != null and not b.game.hud.visible:
			stub_off[0] += 1
		if t.contains("HUD costs (on)") and stub.visible and stub.process_mode == Node.PROCESS_MODE_INHERIT and b.game.hud.visible:
			stub_on[0] += 1)
	root.add_child(b)
	var r: Dictionary = await b.run()
	var ph: Dictionary = r["phases"][0]
	check(not r["cancelled"] and b.hud_checked and ph.has("hud_ms"), "a run with stand-in panels measures the HUD's share (%.2f ms)" % float(ph.get("hud_ms", -1.0)))
	check(stub_off[0] == b.hud_rounds and stub_on[0] == b.hud_rounds, "the HUD went off and on %d times over, and both HUD nodes switched together (%d, %d)" % [b.hud_rounds, stub_off[0], stub_on[0]])
	var bd: Dictionary = r.get("breakdown", {})
	check(not bd.is_empty() and (bd["rows"] as Array).size() == DmBenchmark.BREAK_CATS.size(), "render breakdown: one row per part (%s)" % str(DmBenchmark.BREAK_CATS))
	check(not bd.is_empty() and not (bd["base_end"] as Dictionary).is_empty() and (bd["rows"] as Array)[-1]["what"] == "HUD", "render breakdown: the HUD measured last and everything-on measured again at the end")
	check(steps.size() == DmBenchmark.BREAK_CATS.size() + 2 and steps[0] == 0 and steps[-1] == DmBenchmark.BREAK_CATS.size() + 1, "the frozen-fight banner is told about every step (%s)" % [steps])
	check(not bd.is_empty() and bool(bd["restored"]) and b.paused_ok and not root.get_tree().paused, "render breakdown: the fight was paused, everything hidden was shown again, the tree runs")
	check(DmBenchmark._part_of(Node.new()) == "", "an unrelated node belongs to no part")
	var text := DmBenchmark.format_text(r)
	check(text.contains("Render breakdown") and text.contains("HUD draw calls: not measured (this run has no renderer)"), "the report has the render breakdown, and says a headless run has no draw calls to count")
	check(DmBenchmark.breakdown_unsteady({"render_cpu_ms": -10.0, "frame_ms": 0.0, "render_gpu_ms": 0.0}) and not DmBenchmark.breakdown_unsteady({"render_cpu_ms": 1.0, "frame_ms": 0.2, "render_gpu_ms": 0.1}), "breakdown rows that got slower when hidden are flagged")
	# a rendered breakdown's HUD row is judged against the 150-draw budget
	var drawn := {"phases": [ph], "setup": {"size": "full_party"}, "breakdown": {"base": {"draws": 900.0}, "rows": [{"what": "HUD", "draws": 140.0}]}}
	var drawn_miss := {"phases": [ph], "setup": {"size": "full_party"}, "breakdown": {"base": {"draws": 900.0}, "rows": [{"what": "HUD", "draws": 151.0}]}}
	check("\n".join(DmBenchmark.budget_lines(drawn)).contains("HUD draw calls: 140 of 150   PASS") and "\n".join(DmBenchmark.budget_lines(drawn_miss)).contains("HUD draw calls: 151 of 150   MISS"), "the HUD's draw calls are judged against 150")
	check("\n".join(DmBenchmark.budget_lines({"phases": [ph], "setup": {"size": "light"}})).contains("not the Full Party fight"), "a run that is not the Full Party fight says its budgets are information")
	b.queue_free()
	if is_instance_valid(stub):
		stub.free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the screen and what it sends

func screen_and_upload() -> void:
	if FileAccess.file_exists(DmBenchmarkSetup.FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DmBenchmarkSetup.FILE))
	if FileAccess.file_exists(DmBenchHistory.PENDING):   # (the Full Party run above is queued: this check is about the screen's own run)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DmBenchHistory.PENDING))
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
	s.baked_dir = OUT
	s.setup = {"room": "graves", "discipline": 2, "size": "light", "length": "quick"}
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


func _tiny_result() -> Dictionary:
	return {"meta": {"version": "dev", "godot": "", "gpu": "", "cpu": "", "cores": 1, "os": "", "renderer": "", "resolution": "", "refresh_hz": 0.0, "preset": "high"}, "setup": DmBenchmark.STANDARD,
		"phases": [{"avg_fps": 50.0}], "breakdown": {}}


func esc_cancels() -> void:
	var top := CanvasLayer.new()
	top.layer = 95
	root.add_child(top)
	var s := DmBenchmarkScreen.new()
	s.warm_s = 60.0
	s.measure_s = 30.0
	s.baked_dir = OUT
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


# ------------------------------------------------------------------------------------------------------------------ the setup window

func setup_window() -> void:
	var w := DmBenchmarkSetup.new()
	var got: Array = []
	w.start.connect(func(s: Dictionary) -> void: got.append(s))
	root.add_child(w)
	check(DmBenchmark.is_standard(w.setup), "the setup window opens on the Standard setup the first time")
	check(w._room.item_count == 1 and w._class.item_count == 1 and w._room.get_item_text(0).begins_with("The Hollow Graves") and w._class.get_item_text(0).begins_with("Gravecaller"), "it offers the Hollow Graves and the Gravecaller, the only ones the client has")
	check(w._size.item_count == DmBenchmark.SIZES.size() and w._size.get_item_text(w._size.item_count - 1) == "Full Party: 72 enemies, 32 thralls, a boss", "it lists Full Party with its counts and the boss (%s)" % w._size.get_item_text(w._size.item_count - 1))
	w._size.select(DmBenchmark.SIZES.keys().find("full_party"))
	w._size.item_selected.emit(w._size.selected)
	check(w._note.text.contains(String(DmContent.boss("gravedigger")["name"])), "the note names the room's boss (%s)" % w._note.text)
	w._start()
	check(got.size() == 1 and got[0]["size"] == "full_party" and got[0]["room"] == "graves" and DmBenchmarkSetup.load_last()["size"] == "full_party", "Start hands over Full Party and the window remembers it")
	var texts := PackedStringArray()
	for l in w.find_children("*", "Label", true, false):
		texts.append((l as Label).text)
	var all_text := "\n".join(texts)
	check(all_text.contains("test server") and not all_text.contains("muffindevelopment.com"), "the window says runs go to the test server's history, and names no live address")
	w.queue_free()


# ------------------------------------------------------------------------------------------------------------------ real launches

## `godot --headless ... -- --benchmark ...` as a script or a person starts it.
func real_launches() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var out: Array = []
	var code := OS.execute(exe, ["--headless", "--fixed-fps", "60", "--path", proj, "--", "--benchmark", "--bench-room=graves", "--bench-class=2", "--bench-size=full_party", "--bench-length=quick", "--bench-warm=2",
		"--bench-measure=4", "--baked=" + ProjectSettings.globalize_path(OUT)], out, true)
	var text := "\n".join(PackedStringArray(out))
	check(code == 0, "a --benchmark launch ends by itself with exit code 0 (%d)" % code)
	for needle in ["BENCHMARK Death Muffin benchmark", "BENCHMARK Setup: The Hollow Graves, Gravecaller, Full Party, Quick", "BENCHMARK Boss: The Gravedigger King", "BENCHMARK Average fps", "BENCHMARK Budgets (ROADMAP",
			"BENCHMARK   Combat core per tick", "BENCHMARK   Rest of the main thread per frame", "BENCHMARK saved to"]:
		check(text.contains(needle), "the launch printed '%s'" % needle)
	check(not text.contains("SCRIPT ERROR") and not text.contains("Parse Error"), "and no script error")
	for pair in [["--bench-room=sanctum", "the Hollow Graves only"], ["--bench-class=3", "the Gravecaller only"]]:
		var o2: Array = []
		var c2 := OS.execute(exe, ["--headless", "--path", proj, "--", "--benchmark", pair[0]], o2, true)
		var t2 := "\n".join(PackedStringArray(o2))
		check(c2 == 2 and t2.contains("BENCHMARK refused:") and not t2.contains("BENCHMARK Death Muffin benchmark"), "%s is refused with exit code 2 (%d) and no run" % [pair[0], c2])
		check(t2.contains("Hollow Graves") or t2.contains("Gravecaller"), "%s: the message says what the client has" % pair[0])


# ------------------------------------------------------------------------------------------------------------------ the end

func finish() -> void:
	for f in [DmBenchHistory.FILE, DmBenchHistory.PENDING, DmBenchmarkSetup.FILE]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	check(errlog.errors.is_empty(), "no script or engine errors in the runs (%d)" % errlog.errors.size())
	for e in errlog.errors.slice(0, 12):
		printerr("ERROR LOG: " + e)
	if fails == 0:
		print("PASS benchmark %d checks" % checks)
	else:
		printerr("FAIL benchmark: %d of %d checks" % [fails, checks])
	quit(1 if fails > 0 else 0)
