extends SceneTree
## The in-game benchmark on the combat core (the rebuild's Gates B and C, DECISIONS B50; client/README.md "The benchmark"), headless: `godot --headless --path client --script res://tests/benchmark.gd`.
## Short runs of the real thing, deterministic checks only (timings are printed as INFO and never asserted):
##   - the setup: sizes, today's nine rooms and five classes, the Bell Sanctum as the Standard room, today's enemy health, the budgets are B39's, a room or class the benchmark does not list is refused with a plain message;
##   - the fight is set up as the setup says: 72 enemies held (the farthest extras trimmed without a death), 32 thralls, the Gravedigger King awake, the fixed seed, every enemy on
##     the standard health, the hero holding the centre, no node per creature;
##   - every room: a short Full Party run boots only that room's area, the hero stands on its floor, the director holds the room's whole roster on the core, the enemies that spawn are the room's, the report names the room, and
##     the room's boss is held awake the whole fight exactly where today's benchmark holds one (TODAYS_BOSS), while the Warren and the Coliseum run without;
##   - every class: a short run per class, the kit's family, auto combat casts;
##   - Easy auto combat casts (the gate is closed until opened, it casts, it walks when it may, it reads the corpses and the core's bulk arrays, and nothing is a node);
##   - the report has its lines and its budget section prints, with a verdict for the core and the rest of the main thread, and the HUD's share is measured with the HUD put back after;
##   - a real `--benchmark` launch (--bench-warm / --bench-measure) prints the report and quits by itself; a room or class the benchmark does not list is refused with exit code 2;
##   - nothing is sent anywhere: the run's files (history, queue, last setup, reports) and its baked models live in a folder of this run's own (so no other run's files change a check, and none is left behind),
##     an upload goes to a mock that answers as the test API, a debug build and a trial launch do not upload, and a real transport is never asked to carry a run from a script;
##   - the render breakdown, the history and the setup window work; Esc cancels;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber and the hound into a scratch folder first (the rest of the rosters borrow them: warnings, not errors). About 4 minutes.

const SCRATCH_ROOT := "user://benchmark_test"   ## every run of this suite makes its own folder in here and removes it at the end
const BAKE := ["grave_robber", "bone_hound"]
## The boss today's Full Party fight holds awake in each room (client/next/perf/dm_bench_fight.gd `boss_of`: the boss whose arena is the room); the Warren and the Coliseum have none.
## Kinds the room's own bodies make: a Deacon raises a corpse and a Lich Acolyte unbinds a fallen thrall as a Risen (native/src/core/support.cpp, nave.cpp), today's too.
const MADE_BY := {"risen": ["deacon", "acolyte"]}
const TODAYS_BOSS := {"graves": "gravedigger", "warren": "", "ossuary": "abbess", "nave": "congregation", "coliseum": "", "sanctum": "prelate", "cloister": "saint", "pyre": "regent", "fen": "mire"}
const STD_HP := 272.928627      ## the health every enemy has (today's DmBenchmark.standard_stats at c47c35a1)
const STD_DMG := 10.848627


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var scratch := ""               ## this run's own folder: the baked models, and in `data` every file the benchmark keeps
var data := ""                  ## DmBenchmark.dir for the whole suite: history, queue, last setup, reports


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
	_remove_stale_runs()
	scratch = SCRATCH_ROOT.path_join("%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	data = scratch.path_join("data")
	DirAccess.make_dir_recursive_absolute(data)
	DmBenchmark.dir = data   # every history, queue, setup and report file of the suite lands in this run's folder: no other run's files are read, none is left for a real session to send
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, scratch.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	check(DmBenchmark.dir == data and DmBenchmark.dir != DmBenchmark.DIR and DmBenchHistory.pending_file() == data + "/pending.json" and DmBenchHistory.history_file() == data + "/history.json" and DmBenchmarkSetup.file() == data + "/setup.json",
		"the suite keeps the benchmark's files in its own folder (%s), not in %s" % [data, DmBenchmark.DIR])
	check(DmBenchHistory.pending_count() == 0 and not FileAccess.file_exists(DmBenchmarkSetup.file()) and DmBenchHistory.previous({"clientRunId": "x", "discipline": 2, "room": "graves", "size": "x", "length": "x", "gpu": "x", "preset": "x"}).is_empty(), "and it starts with an empty queue, no history and no setup")
	await the_setup()
	await the_fight_by_hand()
	await auto_combat()
	await frame_split()
	await full_party_run()
	await breakdown_run()
	await every_room()
	await every_class()
	await screen_and_upload()
	await esc_cancels()
	setup_window()
	await nothing_over_the_network()
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
	check(DmBenchmark.ROOMS == ["graves", "warren", "ossuary", "nave", "coliseum", "sanctum", "cloister", "pyre", "fen"] and DmBenchmark.class_indices() == [1, 2, 3, 4, 11],
		"the benchmark has today's nine rooms and five classes (the four necromancers and the Reaper)")
	var every: Array = DmNextWorld.every_area()
	var rooms_ok := true
	for room: String in DmBenchmark.ROOMS:
		var roster: Array = DmContent.area(room)["enemies"]
		rooms_ok = rooms_ok and every.has(room) and not roster.is_empty() and roster.all(func(e: Dictionary) -> bool: return DmWaveDirector.runs_on_core(String(e["id"])))
	check(rooms_ok and not DmBenchmark.ROOMS.has("depths"), "every room is an area the world loads and the core runs its whole roster (the Depths stays out)")
	check(DmBenchmark.BUDGET_CORE_MS == 4.0 and DmBenchmark.BUDGET_REST_MS == 4.0 and DmBenchmark.BUDGET_HUD_MS == 0.5 and DmBenchmark.BUDGET_HUD_DRAWS == 150, "the budgets are B39's: core 4 ms, rest 4 ms, HUD 0.5 ms and 150 draws")
	check(DmBenchmark.normalize_setup({"room": "nowhere", "discipline": 7, "size": "huge"}) == DmBenchmark.STANDARD, "unknown picks fall back to the Standard setup")
	check(DmBenchmark.normalize_setup({"room": "fen", "discipline": 11})["room"] == "fen" and DmBenchmark.normalize_setup({"room": "fen", "discipline": 11})["discipline"] == 11 and DmBenchmark.normalize_setup({"room": "depths"})["room"] == "sanctum"
		and DmBenchmark.normalize_setup({"discipline": 5})["discipline"] == 2, "a listed room and class are taken; the Depths and a greyed-out class fall back to the Standard room and class")
	check(DmBenchmark.STANDARD == {"room": "sanctum", "discipline": 2, "size": "standard", "length": "full"} and DmBenchmark.is_standard(DmBenchmark.STANDARD) and not DmBenchmark.is_standard({"room": "graves", "discipline": 2, "size": "standard", "length": "full"}),
		"Standard is today's: the Bell Sanctum, Gravecaller, Standard, Full")
	# a room or class the benchmark does not list is refused in plain words
	check(DmBenchmark.refusal({"room": "graves", "discipline": 2}) == "" and DmBenchmark.refusal({}) == "" and DmBenchmark.refusal({"room": "fen", "discipline": 11}) == "", "the listed rooms and classes are not refused")
	var why_room := DmBenchmark.refusal({"room": "depths"})
	check(why_room.contains("'depths'") and why_room.contains("graves") and why_room.contains("fen"), "a room outside the nine is refused with a clear message (%s)" % why_room)
	var why_class := DmBenchmark.refusal({"discipline": 5})
	check(why_class.contains("class 5") and why_class.contains("2 Gravecaller") and why_class.contains("11 Reaper"), "a class outside the five is refused with a clear message (%s)" % why_class)
	# the enemies' health and damage are today's: the Bell Sanctum roster's weighted average on Easy, whatever the room
	var std := DmBenchmark.standard_stats()
	check(absf(float(std["hp"]) - STD_HP) < 0.001 and absf(float(std["dmg"]) - STD_DMG) < 0.001, "every enemy has today's health %.3f and damage %.3f (%.3f, %.3f)" % [STD_HP, STD_DMG, std["hp"], std["dmg"]])
	var boss_host := DmBossHost.new()
	var served: Array = boss_host.served_areas.duplicate()
	boss_host.free()
	var todays := true
	var woken := true
	for room: String in DmBenchmark.ROOMS:   # the rooms and their bosses are today's, and the game wakes every one of them
		todays = todays and DmBenchFight.boss_of(room) == TODAYS_BOSS[room]
		woken = woken and (TODAYS_BOSS[room] == "" or served.has(room))
	check(todays and woken and TODAYS_BOSS.size() == DmBenchmark.ROOMS.size(), "every room's boss is today's, and the boss host wakes all seven (%s)" % str(served))
	var sanctum_fp := DmBenchmark.new()
	sanctum_fp.configure({"room": "sanctum", "size": "full_party"})
	check(sanctum_fp.boss_id == "prelate" and sanctum_fp.boss_text().contains("Bell-Sworn Prelate held awake"), "Full Party in the Sanctum holds its Prelate (%s)" % sanctum_fp.boss_text())
	sanctum_fp.free()
	var warren_fp := DmBenchmark.new()
	warren_fp.configure({"room": "warren", "size": "full_party"})
	check(warren_fp.boss_id == "" and warren_fp.boss_text() == ", no boss (this room has none)", "Full Party in the Warren runs without a boss and says the room has none")
	warren_fp.free()
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
	# the crowd's cost settings a launch can change (--bench-crowd=...) and the line that records them
	var pc := DmBenchmark.parse_crowd(PackedStringArray(["--benchmark", "--bench-crowd=cull=off,anim=off,thrall_shadows=off,reserve=64,lod=40/80"]))
	check(pc.opts == {"cull": false, "anim_lod": false, "thrall_shadows": false, "reserve": 64, "lod_distances": PackedFloat32Array([40.0, 80.0])} and pc.unknown.is_empty(), "--bench-crowd: culling, the bands, the thralls' shadows, the reserve and the levels (%s)" % str(pc.opts))
	pc = DmBenchmark.parse_crowd(PackedStringArray(["--bench-crowd=mid_hz=12,far_m=70,thrall_shadows=on"]))
	check(pc.opts == {"anim_lod": {"mid_hz": 12.0, "far_m": 70.0}, "thrall_shadows": true}, "--bench-crowd: band numbers switch the bands on with them (%s)" % str(pc.opts))
	pc = DmBenchmark.parse_crowd(PackedStringArray(["--bench-crowd=anim=on,cull=maybe,bogus=1,reserve=0,lod=a/b,mid_hz=x,novalue"]))
	check(pc.opts == {"anim_lod": true} and pc.unknown.size() == 6, "--bench-crowd: what is not a setting is listed, not applied (%s)" % str(pc.unknown))
	check(DmBenchmark.parse_crowd(PackedStringArray(["--benchmark"])).opts.is_empty(), "no --bench-crowd, no change: the game's own settings")
	check(DmBenchmark.crowd_line({}) == "not in this build" and DmBenchmark.crowd_line({"anim_lod": false, "culling": true, "thrall_shadows": true, "reserve": 128, "lod_distances": PackedFloat32Array([32.0, 60.0]),
		"shadow_casters": 12, "shadow_casters_crowded": 8}).contains("mesh levels at 32 / 60 m; 128 instances reserved a group; animation off") , "the crowd line names the levels, the reserve and the bands")
	var M: GDScript = load("res://main/main.gd")
	var a: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-room=graves", "--bench-class=2", "--bench-size=heavy", "--bench-length=quick"]))
	check(a["room"] == "graves" and int(a["discipline"]) == 2 and a["size"] == "heavy" and a["length"] == "quick", "launch args pick the setup")
	var fa: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-size=full_party"]))
	check(fa["size"] == "full_party" and fa["room"] == "sanctum" and fa["discipline"] == 2, "--bench-size=full_party picks Full Party in the Standard room and class")
	var want: Dictionary = M.bench_wanted_from_args(PackedStringArray(["--benchmark", "--bench-room=depths", "--bench-class=5"]))
	check(want == {"room": "depths", "discipline": 5} and DmBenchmark.refusal(want) != "", "launch args that name a room or class outside the lists are what the refusal is asked about")
	var fen: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-room=fen", "--bench-class=11"]))
	check(fen["room"] == "fen" and fen["discipline"] == 11 and DmBenchmark.refusal(M.bench_wanted_from_args(PackedStringArray(["--bench-room=fen", "--bench-class=11"]))) == "", "launch args pick the Fen and the Reaper")
	check(DmLaunchArgs.options(PackedStringArray(["--benchmark", "--bench-dir=/tmp/x y"]))["bench_dir"] == "/tmp/x y" and not DmLaunchArgs.options(PackedStringArray(["--benchmark"])).has("bench_dir"), "--bench-dir= names the folder a run keeps its files in")


# ------------------------------------------------------------------------------------------------------------------ the fight, by hand

## DmBenchFight on a booted game: the pieces of the held fight one at a time.
func the_fight_by_hand() -> void:
	var f := await DmBenchFight.boot(root, 2, {"audio": false, "baked_dir": scratch}, "graves")
	var g: DmNextGame = f["game"]
	var host: DmCoreHost = g.core_host
	var hero: DmHeroBody = f["hero"]
	var at: Vector3 = f["at"]
	check(g.ready_ and int(g.opts["seed"]) == DmBenchmark.SEED, "the game was built with the fixed seed")
	check(g.world.area_at(at.x, at.z) == "graves" and hero.position.distance_to(at) < 0.1 and g.world.nav_closest(at).distance_to(at) < 0.5, "the hero stands on walkable ground in the Graves (%s)" % str(at))
	check(DmNextWarmup.crowd_rows == host.view.model_slots().size() * 3 * 2 and host.is_physics_processing() and g.is_processing(), "the warm-up fed %d rehearsal rows to the crowd and gave the game back" % DmNextWarmup.crowd_rows)
	check(host.view.stats().bodies == 0, "the rehearsal rows are gone from the crowd (%d bodies)" % int(host.view.stats().bodies))
	var hero_c: DmCreature = hero.avatar.c if hero.avatar != null else null
	check(DmNextWarmup.shots == 4 and hero_c != null and is_equal_approx(hero_c.opacity(), 1.0), "the warm-up drew a shot of each kind and a beam (%d), and the hero's see-through pass ended opaque" % DmNextWarmup.shots)
	var none := PackedStringArray()
	check(DmNextGame._wants_warmup(none, "Windows") and not DmNextGame._wants_warmup(none, "headless") and DmNextGame._wants_warmup(PackedStringArray(["--warmup"]), "headless")
		and not DmNextGame._wants_warmup(PackedStringArray(["--qa"]), "Windows") and not DmNextGame._wants_warmup(PackedStringArray(["--shot-plan=x.json"]), "X11"),
		"a player's game warms up as today's does (on in a window, off headless and on QA or screenshot runs, --warmup forces it)")
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
	var f := await DmBenchFight.boot(root, 2, {"audio": false, "baked_dir": scratch, "warmup": false}, "graves")
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
	check(int(auto.stats["actions"]) > 0 and int(auto.stats["fills"]) == int(auto.stats["actions"]), "holding his ground it reads the core's tables only when an action is due (%d reads, %d actions)" % [int(auto.stats["fills"]), int(auto.stats["actions"])])
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
	check(int(auto.stats["fills"]) > int(auto.stats["actions"]), "and then it reads the tables every move tick, for its steps (%d reads, %d actions)" % [int(auto.stats["fills"]), int(auto.stats["actions"])])
	# a hostile zone is a hazard it leaves
	host.zone.emit(900, 0, 0, hero.position.x, hero.position.z, 3.0, 5.0)
	auto._gather(hero.position, "graves")
	check(auto._hazards.size() >= 1 and auto._hazards.any(func(hz: Dictionary) -> bool: return hz.get("k") == "circle" and absf(float(hz["x"]) - hero.position.x) < 0.01), "a hostile zone under the hero is a hazard")
	host.zone_gone.emit(900)
	check(not auto._zones.has(900), "and the zone ends with its event")
	g.queue_free()
	await process_frame
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the frame split

## A physics callback that holds the tick for `us` microseconds: the split must see at least that in every tick.
class Busy:
	extends Node
	var us := 0

	func _physics_process(_dt: float) -> void:
		var t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t0 < us:
			pass


func frame_split() -> void:
	var split := DmFrameSplit.new()
	root.add_child(split)
	var busy := Busy.new()
	busy.us = 3000
	root.add_child(busy)
	var made0 := Engine.get_physics_frames()
	split.start(self)
	await ticks(12)
	await process_frame
	split.stop()
	var made := Engine.get_physics_frames() - made0
	check(split.frames >= 6 and split.ticks >= 10 and absi(split.ticks - made) <= 1, "the split counts the frames and the ticks the engine ran (%d frames, %d ticks of %d)" % [split.frames, split.ticks, made])
	check(split.worst_tick_us >= float(busy.us) and split.physics_us >= float(busy.us) * float(split.ticks), "a tick that holds 3 ms for itself is at least 3 ms in the physics part (slowest %.2f ms, %.2f ms in all for %d ticks)" % [split.worst_tick_us / 1000.0, split.physics_us / 1000.0, split.ticks])
	check(split.tick_ms() <= split.worst_tick_us / 1000.0 + 1e-9 and split.physics_ms() > 0.0 and split.process_ms() >= 0.0 and split.ticks_per_frame() > 0.0, "the average tick is no slower than the slowest, and the parts are positive")
	var frames := split.frames
	await process_frame
	await process_frame
	check(split.frames == frames, "a stopped split counts nothing more")
	print("INFO frame split: physics %.2f ms and process %.3f ms a frame over %d frames (%.2f ticks a frame, the busy tick 3 ms)" % [split.physics_ms(), split.process_ms(), split.frames, split.ticks_per_frame()])
	split.reset()
	check(split.frames == 0 and split.ticks == 0 and split.physics_us == 0.0 and split.process_us == 0.0 and split.worst_tick_us == 0.0, "reset starts a new window")
	busy.queue_free()
	split.queue_free()
	# the F3 overlay's logic line is the same split (Godot's own monitors are the slowest frame and tick of each second)
	var overlay := DmPerfOverlay.new()
	root.add_child(overlay)
	overlay.set_shown(true)
	check(overlay.get_children().any(func(n: Node) -> bool: return n is DmFrameSplit), "an open overlay counts the frame's parts")
	var t0 := Time.get_ticks_msec()
	while not overlay.label.text.contains("slowest tick") and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	check(overlay.label.text.contains("logic ") and overlay.label.text.contains("slowest tick"), "the overlay's logic line gives the average process and physics and the slowest tick")
	overlay.set_shown(false)
	check(not overlay.get_children().any(func(n: Node) -> bool: return n is DmFrameSplit and not n.is_queued_for_deletion()), "a closed overlay counts nothing")
	overlay.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the Full Party run

var hp_seen := {}
var boss_seen := 0
var samples := 0
var casts_seen := 0
var vsync_setting: Variant = null   ## what the game's perf node was told about V-Sync during the fight
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
	vsync_setting = b.game.perf.settings.get("vsync", true) if b.game.perf != null else null
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
	b.baked_dir = scratch
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
	check(vsync_setting == false, "the fight's graphics settings keep V-Sync off (%s): a run is never capped at the monitor's refresh" % str(vsync_setting))
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
	# the crowd's settings and counters are in the report: the game's own defaults here (nothing asked for)
	var cs: Dictionary = r["meta"]["crowd"]
	check(cs.anim_lod and cs.culling and cs.thrall_shadows and cs.reserve == CrowdView.RESERVE and cs.lod_distances == PackedFloat32Array(CrowdView.LOD_DISTANCES) and cs.anim_mid_hz == 24.0 and cs.anim_far_hz == 10.0,
		"the report records the crowd's settings: %s" % str(cs))
	var cc: Dictionary = ph["crowd"]
	for k in DmBenchmark.CROWD_COUNTERS:
		check(cc.has(k), "the phase has the crowd counter %s" % k)
	check(cc.bodies > 0.0 and cc.drawn > 0.0 and cc.drawn <= cc.bodies and cc.casting_thralls > 0.0 and cc.casting >= cc.casting_thralls and cc.band_near > 0.0, "the crowd counters are sane: %s" % str(cc))
	print("INFO crowd per frame: %s" % str(cc))
	# the core's budget: the numbers exist and add up
	check(float(ph["physics_avg_ms"]) > 0.0 and float(ph["process_avg_ms"]) > 0.0 and float(ph["physics_worst_ms"]) >= float(ph["physics_tick_ms"]) and float(ph["split_ticks_per_frame"]) > 0.0 \
		and float(ph["physics_avg_ms"]) + float(ph["process_avg_ms"]) <= float(ph["avg_ms"]) * 1.1 + 0.1,
		"the frame split adds up: physics %.2f + process %.2f of the frame's %.2f ms (the monitors' peaks are %.2f and %.2f)" % [float(ph["physics_avg_ms"]), float(ph["process_avg_ms"]), float(ph["avg_ms"]), float(ph["physics_ms"]), float(ph["process_ms"])])
	check(float(ph["core_ms"]) > 0.0 and absf(float(ph["core_ms"]) - (float(ph["core_step_ms"]) + float(ph["core_sync_ms"]) + float(ph["core_events_ms"]))) < 1e-6, "the core's tick is its step + crowd sync + event dispatch (%.2f ms)" % float(ph["core_ms"]))
	check(float(ph["ticks_per_frame"]) > 0.0 and absf(float(ph["core_frame_ms"]) - float(ph["core_ms"]) * float(ph["ticks_per_frame"])) < 1e-6, "the core's cost a frame is its tick times the ticks a frame ran (%.2f x %.2f)" % [float(ph["core_ms"]), float(ph["ticks_per_frame"])])
	check(absf(float(ph["rest_ms"]) - maxf(0.0, float(ph["avg_ms"]) - float(ph["core_frame_ms"]))) < 1e-6, "the rest of the frame is the frame less the core's share (%.2f ms)" % float(ph["rest_ms"]))
	check(b.hud_checked and ph.has("hud_ms") and ph.has("hud_noise_ms") and float(ph["hud_ms"]) >= 0.0, "the HUD's share was measured (%.2f ms, samples %.2f ms apart)" % [float(ph.get("hud_ms", -1.0)), float(ph.get("hud_noise_ms", -1.0))])
	# the report
	var text := DmBenchmark.format_text(r)
	for needle in ["Death Muffin benchmark", "Average fps", "Frame ms (p95)", "V-Sync: off during measurement", "Combat core: dmcore", "Setup: The Hollow Graves, Gravecaller, Full Party, Quick (custom",
			"Boss: The Gravedigger King", "held awake", "seed 20261011", "Crowd: mesh levels at 32 / 60 m; 128 instances reserved a group; animation 24.0 Hz beyond 32 m, 10.0 Hz beyond 60 m; culling on; thralls cast shadows",
			"Crowd per frame (average over the measured window", "Process ms (avg)", "Physics ms (Godot peak)", "Frame ", "'Godot peak' rows are Godot's slowest tick"]:
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
	check(path.begins_with(data + "/bench-") and FileAccess.get_file_as_string(path).contains("Combat core per tick"), "the report is saved in the suite's own benchmark folder")
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
	b.baked_dir = scratch
	check(b.breakdown and b.enemies == 15 and b.thralls == 10 and b.boss_id == "", "configure: Light, Full length (render breakdown on)")
	var ui_off := [0]
	var ui_on := [0]
	var steps: Array = []
	b.breakdown_step.connect(func(step: int, _total: int, _what: String) -> void: steps.append(step))
	b.progress.connect(func(t: String) -> void:
		var ui: DmGameUi = b.game.ui if b.game != null else null
		if ui == null:
			return
		if t.contains("HUD costs (off)") and not ui.visible and ui.process_mode == Node.PROCESS_MODE_DISABLED:
			ui_off[0] += 1
		if t.contains("HUD costs (on)") and ui.visible and ui.process_mode == Node.PROCESS_MODE_INHERIT:
			ui_on[0] += 1)
	root.add_child(b)
	var r: Dictionary = await b.run()
	var ph: Dictionary = r["phases"][0]
	check(not r["cancelled"] and b.hud_checked and ph.has("hud_ms"), "a run measures the HUD's share, the panels with it (%.2f ms)" % float(ph.get("hud_ms", -1.0)))
	check(ui_off[0] == b.hud_rounds and ui_on[0] == b.hud_rounds, "the HUD and panels went off and on %d times over (%d, %d)" % [b.hud_rounds, ui_off[0], ui_on[0]])
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
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ every room and every class

## What a short run showed, read off the running game from the progress line (about once a second; the first comes as the warm-up begins, before the first wave).
class Watch:
	extends RefCounted
	var loaded: Array = []                 ## the area ids the world holds
	var director_area := ""
	var director_kinds: Array = []         ## the kinds the director makes in the room
	var family := ""
	var casts := 0
	var defs := {}                         ## def id -> bodies spawned
	var areas := {}                        ## the area ids the spawns carried
	var hooked := false
	var hero_floor := ""                   ## the area the hero stood in once the fight began
	var looks := 0                         ## progress lines with the game up
	var boss_looks := 0                    ## ... of which a boss was awake
	var boss_ids := {}                     ## the boss ids seen awake
	var boss_floors := {}                  ## the areas the awake boss stood in
	var boss_hittable := 0                 ## looks where the awake boss could be hit (a sunk Mire Mother cannot)

	func look(b: DmBenchmark) -> void:
		if b.game == null or not is_instance_valid(b.game) or b.host == null:
			return
		if not hooked:
			hooked = true
			b.host.enemy_spawned.connect(func(_id: int, def: String, _l: int, _e: bool, area: String, _af: int, _x: float, _z: float, _hp: float) -> void:
				defs[def] = int(defs.get(def, 0)) + 1
				areas[area] = true)
			loaded = b.game.world.loaded.duplicate()
			director_area = b.game.director.area_id
			director_kinds = b.game.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))
			family = String(b.game.local_body().family)
		looks += 1
		hero_floor = b.game.world.area_at(b.game.local_body().position.x, b.game.local_body().position.z)
		casts = int(b.game.input.auto.stats["casts"])
		var boss: DmBoss = b.game.bosses.active_boss()
		if boss != null:
			boss_looks += 1
			boss_ids[boss.boss_id] = true
			boss_floors[b.game.world.area_at(boss.position.x, boss.position.z)] = true
			boss_hittable += 1 if boss.is_hittable() else 0


## One short run: `room` and `disc`, `size`, `warm` s of warm-up and `measure` s measured. Returns {r, watch, b, ms}; the caller frees `b` once it has read it.
func short_run(room: String, disc: int, size := "light", warm := 1.0, measure := 2.0) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var b := DmBenchmark.new()
	b.configure({"room": room, "discipline": disc, "size": size, "length": "quick"})
	b.warm_s = warm
	b.measure_s = measure
	b.hud_rounds = 0
	b.baked_dir = scratch
	var w := Watch.new()
	b.progress.connect(func(_t: String) -> void: w.look(b))
	root.add_child(b)
	var r: Dictionary = await b.run()
	return {"r": r, "watch": w, "b": b, "ms": Time.get_ticks_msec() - t0}


## Every room boots alone in a Full Party fight, spawns its own roster on the core, holds its boss awake the whole fight where today's benchmark does (and runs without one where today's does), and reaches the report.
func every_room() -> void:
	var total := 0
	var cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	for room: String in DmBenchmark.ROOMS:
		var o := await short_run(room, 2, "full_party", 2.0, 6.0)
		var r: Dictionary = o["r"]
		var w: Watch = o["watch"]
		var b: DmBenchmark = o["b"]
		total += int(o["ms"])
		var boss: String = TODAYS_BOSS[room]
		var rect: Dictionary = DmContent.area(room)["rect"]
		var roster: Array = (DmContent.area(room)["enemies"] as Array).map(func(e: Dictionary) -> String: return String(e["id"]))
		roster.sort()
		var kinds: Array = w.director_kinds.duplicate()
		kinds.sort()
		var outside: Array = []   # spawned kinds that are not the room's roster nor made by it: a boss's own adds
		for d: String in w.defs.keys():
			if not roster.has(d) and not (MADE_BY.get(d, []) as Array).any(func(k: String) -> bool: return roster.has(k)):
				outside.append(d)
		var ph: Dictionary = r["phases"][0] if not (r["phases"] as Array).is_empty() else {}
		check(not r["cancelled"] and (r["phases"] as Array).size() == 1 and r["setup"]["room"] == room and r["setup"]["size"] == "full_party", "%s: the Full Party run completes" % room)
		check(w.loaded == [room], "%s: only that area is loaded (%s)" % [room, str(w.loaded)])
		check(w.director_area == room and kinds == roster, "%s: the director holds the whole roster on the core (%d kinds of %d)" % [room, kinds.size(), roster.size()])
		check(not w.defs.is_empty() and w.areas.keys() == [room] and (boss != "" or outside.is_empty()), "%s: the enemies that spawned are in the room (%s)" % [room, str(w.defs)])
		check(w.defs.size() >= mini(3, roster.size()) and b.spawns >= cap, "%s: %d bodies of %d kinds spawned" % [room, b.spawns, w.defs.size()])
		check(b.area_nav_on and w.hero_floor == room and b._at.x >= float(rect["x0"]) and b._at.x <= float(rect["x1"]) and b._at.z >= float(rect["z0"]) and b._at.z <= float(rect["z1"]),
			"%s: the room's navmesh is on and the hero stands on its floor (%s)" % [room, str(b._at)])
		check(not ph.is_empty() and float(ph["enemies"]) >= cap * 0.8 and float(ph["thralls"]) >= 31.99, "%s: 72 enemies and 32 thralls are held (%.1f, %.1f)" % [room, float(ph.get("enemies", 0.0)), float(ph.get("thralls", 0.0))])
		# the boss: today's room has one, it is held awake the whole fight (the first look is before the first upkeep wakes it); a room without one runs without
		if boss != "":
			check(b.boss_id == boss and r["boss"]["id"] == boss and w.boss_ids.keys() == [boss], "%s: %s is the boss held (%s)" % [room, boss, str(w.boss_ids.keys())])
			check(b.boss_summons >= 1 and b.boss_summons == 1 + b.boss_defeats and float(ph["boss_awake_pct"]) >= (99.0 if b.boss_defeats == 0 else 85.0) and w.looks > 1 and w.boss_looks >= w.looks - 1,
				"%s: awake the whole fight (%.0f%% of the window; woken %d times, defeated %d; awake in %d of %d looks)" % [room, float(ph.get("boss_awake_pct", 0.0)), b.boss_summons, b.boss_defeats, w.boss_looks, w.looks])
			check(w.boss_floors.keys() == [room], "%s: in its own arena (%s)" % [room, str(w.boss_floors.keys())])
			check(DmBenchmark.format_text(r).contains("Boss: %s   woken" % DmContent.boss(boss)["name"]) and DmBenchmark.format_text(r).contains("%s held awake" % DmContent.boss(boss)["name"]), "%s: the report names the boss" % room)
		else:
			check(b.boss_id == "" and String(r["boss"]["id"]) == "" and b.boss_summons == 0 and w.boss_looks == 0 and not ph.has("boss_awake_pct") and outside.is_empty(), "%s: no boss, none woken, no foreign body (%s)" % [room, str(outside)])
			check(DmBenchmark.format_text(r).contains("no boss (this room has none)") and not DmBenchmark.format_text(r).contains("Boss:"), "%s: the report says the room has none" % room)
		var text := DmBenchmark.format_text(r)
		check(text.contains("Setup: %s, Gravecaller, Full Party, Quick (custom" % DmBenchmark.room_name(room)) and text.contains("Budgets (ROADMAP") and text.contains("Combat core per tick"), "%s: the report names the room and has its budget section" % room)
		check(text.contains("Process ms (avg)") and text.contains("Physics ms (avg)") and text.contains("Slowest tick ms") and text.contains("Process ms (Godot peak)") and text.contains("Physics ms (Godot peak)") and text.contains("\nFrame ")
			and float(ph["physics_avg_ms"]) > 0.0 and float(ph["process_avg_ms"]) > 0.0 and float(ph["physics_worst_ms"]) >= float(ph["physics_tick_ms"]),
			"%s: the report has the frame's physics and process averages beside Godot's peaks (physics %.2f, process %.2f ms)" % [room, float(ph.get("physics_avg_ms", 0.0)), float(ph.get("process_avg_ms", 0.0))])
		var cc: Dictionary = ph.get("crowd", {})
		check(text.contains("Crowd: mesh levels at") and text.contains("Crowd per frame (average over the measured window") and not cc.is_empty() and float(cc["bodies"]) > 0.0 and float(cc["drawn"]) <= float(cc["bodies"]) and float(cc["casting_thralls"]) > 0.0
			and float(cc["triangles"]) > 0.0 and r["meta"]["crowd"].culling and r["meta"]["crowd"].anim_lod, "%s: the report records the crowd's settings and counters (%.0f bodies, %.0f drawn, %.0f outside the view, %.0f casting)" % [room, float(cc.get("bodies", 0.0)), float(cc.get("drawn", 0.0)), float(cc.get("culled", 0.0)), float(cc.get("casting", 0.0))])
		print("INFO bench room %s (%s): %d bodies of %d kinds, boss awake %.0f%% (woken %d, defeated %d, hittable in %d of %d looks), outside the roster %s, avg %.2f ms, core %.2f ms, run took %.1f s" % [
			room, boss if boss != "" else "no boss", b.spawns, w.defs.size(), float(ph.get("boss_awake_pct", 0.0)), b.boss_summons, b.boss_defeats, w.boss_hittable, w.looks, str(outside),
			float(ph.get("avg_ms", 0.0)), float(ph.get("core_ms", 0.0)), float(o["ms"]) / 1000.0])
		b.queue_free()
		await process_frame
	print("INFO bench every room: %.1f s" % (total / 1000.0))


## Every class plays its short run: the kit's family, and auto combat casts.
func every_class() -> void:
	var total := 0
	for disc: int in DmBenchmark.class_indices():
		var o := await short_run("graves", disc)
		var r: Dictionary = o["r"]
		var w: Watch = o["watch"]
		total += int(o["ms"])
		var want := String(DmCharacterBuild.discipline_for(float(disc))["family"])
		var name_ := DmBenchmark.class_name_of(disc)
		check(not r["cancelled"] and r["setup"]["discipline"] == disc and w.family == want, "%s: the short run completes with a %s hero (%s)" % [name_, want, w.family])
		check(w.casts > 0 and (r["phases"] as Array).size() == 1 and int(r["phases"][0]["frames"]) > 0, "%s: auto combat cast %d times" % [name_, w.casts])
		check(DmBenchmark.format_text(r).contains("Setup: The Hollow Graves, %s, Light, Quick" % name_), "%s: the report names the class" % name_)
		print("INFO bench class %s: %d casts, %d kills, avg %.2f ms, run took %.1f s" % [name_, w.casts, int(r["kills"]), float(r["phases"][0]["avg_ms"]) if not (r["phases"] as Array).is_empty() else 0.0, float(o["ms"]) / 1000.0])
		(o["b"] as DmBenchmark).queue_free()
		await process_frame
	print("INFO bench every class: %.1f s" % (total / 1000.0))


# ------------------------------------------------------------------------------------------------------------------ the screen and what it sends

func screen_and_upload() -> void:
	if FileAccess.file_exists(DmBenchHistory.pending_file()):   # (the runs above are queued: this check is about the screen's own run)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DmBenchHistory.pending_file()))
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
	s.baked_dir = scratch
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
	s.baked_dir = scratch
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
	check(w._room.item_count == DmBenchmark.ROOMS.size() and w._room.get_item_text(0).begins_with("The Hollow Graves") and w._room.get_item_text(w._room.item_count - 1).begins_with("The Mourning Fen"),
		"it lists today's nine rooms in order, the Graves first and the Fen last")
	var std_room := w._room.get_item_text(DmBenchmark.ROOMS.find("sanctum"))
	check(std_room.begins_with("The Bell Sanctum") and std_room.ends_with("(standard)") and w._room.get_selected_metadata() == "sanctum", "the Bell Sanctum is marked standard and picked (%s)" % std_room)
	var classes_ok := w._class.item_count == 5
	for i in w._class.item_count:
		classes_ok = classes_ok and w._class.get_item_metadata(i) == [1, 2, 3, 4, 11][i] and w._class.get_item_text(i).begins_with(DmBenchmark.class_name_of(int(w._class.get_item_metadata(i))))
	check(classes_ok and w._class.get_item_text(4).begins_with("Reaper") and w._class.get_selected_metadata() == 2, "it lists the four necromancers and the Reaper, the Gravecaller picked (%s)" % w._class.get_item_text(4))
	check(w._size.item_count == DmBenchmark.SIZES.size() and w._size.get_item_text(w._size.item_count - 1) == "Full Party: 72 enemies, 32 thralls, a boss", "it lists Full Party with its counts and the boss (%s)" % w._size.get_item_text(w._size.item_count - 1))
	w._size.select(DmBenchmark.SIZES.keys().find("full_party"))
	w._size.item_selected.emit(w._size.selected)
	w._room.select(0)
	w._room.item_selected.emit(0)
	check(w._note.text.contains(String(DmContent.boss("gravedigger")["name"])) and w._note.text.contains("held awake") and w._note.text.contains("Custom setup"), "in the Graves the note names the room's boss (%s)" % w._note.text)
	w._room.select(DmBenchmark.ROOMS.find("warren"))
	w._room.item_selected.emit(w._room.selected)
	check(w._note.text.contains("no boss"), "in the Warren the note says the room has no boss (%s)" % w._note.text)
	w._room.select(DmBenchmark.ROOMS.find("sanctum"))
	w._room.item_selected.emit(w._room.selected)
	check(w._note.text.contains(String(DmContent.boss("prelate")["name"])) and w._note.text.contains("held awake"), "in the Sanctum the note names its Prelate, held awake (%s)" % w._note.text)
	w._room.select(DmBenchmark.ROOMS.find("fen"))
	w._room.item_selected.emit(w._room.selected)
	w._class.select(4)
	w._class.item_selected.emit(4)
	w._start()
	check(got.size() == 1 and got[0]["size"] == "full_party" and got[0]["room"] == "fen" and got[0]["discipline"] == 11, "Start hands over the Fen, the Reaper and Full Party")
	var last := DmBenchmarkSetup.load_last()
	check(last["size"] == "full_party" and last["room"] == "fen" and last["discipline"] == 11 and FileAccess.file_exists(data + "/setup.json"), "and the window remembers it, in the suite's own folder")
	var texts := PackedStringArray()
	for l in w.find_children("*", "Label", true, false):
		texts.append((l as Label).text)
	var all_text := "\n".join(texts)
	check(all_text.contains("benchmark page") and not all_text.contains("muffindevelopment.com"), "the window says runs go to the game's benchmark page, and names no address")
	w.queue_free()


# ------------------------------------------------------------------------------------------------------------------ nothing leaves the process

## No test sends a run anywhere but a mock. The one door a run can leave by is DmApi.post_benchmark through DmBenchHistory.flush: from a script, flush refuses a real transport.
func nothing_over_the_network() -> void:
	DmBenchHistory.record(DmBenchHistory.payload(_tiny_result(), "report"))
	var queued := DmBenchHistory.pending_count()
	# a real transport with a login, pointed at an address its own door refuses: flush must stop before it asks (and if it ever did, the transport still sends nothing)
	var t := DmHttpTransport.new()
	root.add_child(t)
	var real := DmApi.new(t.request_callable())
	real.base_url = "https://example.invalid/death-muffin/test-api"
	real.set_token("t")
	var errors_before := errlog.errors.size()
	check(DmBenchHistory.over_the_network_from_a_script(real), "a script run sees a real transport as the network")
	check(await DmBenchHistory.flush(real) == 0 and DmBenchHistory.pending_count() == queued, "flush does not send a run through a real transport from a script: it stays queued (%d)" % queued)
	check(errlog.errors.size() == errors_before and t.get_child_count() == 0, "and the transport was never asked (no request node, no refusal logged)")
	t.queue_free()
	var mock_api := DmApi.new(func(_req: Dictionary) -> Dictionary: return {"status": 200, "text": "{\"success\":true,\"data\":{\"id\":1}}"})
	mock_api.set_token("t")
	check(not DmBenchHistory.over_the_network_from_a_script(mock_api) and await DmBenchHistory.flush(mock_api) == queued and DmBenchHistory.pending_count() == 0, "a mock answers: the queue is sent to it and leaves")
	# the launch path: a trial (its own folder) never gets an api, whatever build it is
	var m := DmMain.new()
	m.mode = "benchmark"
	m.bench_dir = data
	check(m._bench_upload_api() == null, "a --benchmark launch with its own --bench-dir= sends nothing")
	m.free()
	await process_frame


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
	for needle in ["BENCHMARK Death Muffin benchmark", "BENCHMARK Setup: The Hollow Graves, Gravecaller, Full Party, Quick", "BENCHMARK Boss: The Gravedigger King", "BENCHMARK Average fps", "BENCHMARK Budgets (ROADMAP",
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
	check(code_fen == 0 and text_fen.contains("BENCHMARK Setup: The Mourning Fen, Reaper, Light, Quick") and text_fen.contains("BENCHMARK Average fps") and not text_fen.contains("SCRIPT ERROR"), "--bench-room=fen --bench-class=11 runs the Reaper in the Fen (%d)" % code_fen)
	var queued_runs: Array = JSON.parse_string(FileAccess.get_file_as_string(DmBenchHistory.pending_file())) if FileAccess.file_exists(DmBenchHistory.pending_file()) else []
	var rooms_queued := queued_runs.map(func(q: Dictionary) -> String: return "%s/%d" % [q["room"], int(q["discipline"])])
	check(rooms_queued.has("graves/2") and rooms_queued.has("fen/11"), "the two launches queued their runs in the folder they were given and sent nothing (%s)" % str(rooms_queued))
	# the crowd's cost settings from the launch: the report records what was in force, and a setting that is not one is said to be ignored
	var o3: Array = []
	var c3 := OS.execute(exe, ["--headless", "--fixed-fps", "60", "--path", proj, "--", "--benchmark", "--bench-room=graves", "--bench-class=2", "--bench-size=full_party", "--bench-length=quick", "--bench-warm=2",
		"--bench-measure=4", "--baked=" + ProjectSettings.globalize_path(scratch), "--bench-dir=" + own, "--bench-crowd=cull=off,anim=off,thrall_shadows=off,reserve=64,lod=40/80,bogus=1"], o3, true)
	var t3 := "\n".join(PackedStringArray(o3))
	check(c3 == 0 and t3.contains("BENCHMARK Crowd: mesh levels at 40 / 80 m; 64 instances reserved a group; animation off (every body every frame); culling off; thralls do not cast shadows"), "a launch with --bench-crowd records its settings in the report (%d)" % c3)
	check(t3.contains("ignored --bench-crowd setting 'bogus=1'") and not t3.contains("SCRIPT ERROR"), "and says what it ignored")
	check(t3.contains("(0 of them thralls; 0 MultiMeshes, 0 k triangles again in the shadow pass)") or t3.contains("(0 of them thralls;"), "and no thrall cast")
	for pair in [["--bench-room=depths", "'depths'", "graves"], ["--bench-room=nowhere", "'nowhere'", "fen"], ["--bench-class=5", "class 5", "2 Gravecaller"]]:
		var o2: Array = []
		var c2 := OS.execute(exe, ["--headless", "--path", proj, "--", "--benchmark", pair[0]], o2, true)
		var t2 := "\n".join(PackedStringArray(o2))
		check(c2 == 2 and t2.contains("BENCHMARK refused:") and not t2.contains("BENCHMARK Death Muffin benchmark"), "%s is refused with exit code 2 (%d) and no run" % [pair[0], c2])
		check(t2.contains(pair[1]) and t2.contains(pair[2]), "%s: the message names the pick and says what the benchmark has" % pair[0])


# ------------------------------------------------------------------------------------------------------------------ the end

func finish() -> void:
	DmBenchmark.dir = DmBenchmark.DIR
	if scratch != "":   # this run's folder: the baked models, the history, the queue, the reports
		_remove_tree(ProjectSettings.globalize_path(scratch))
	check(errlog.errors.is_empty(), "no script or engine errors in the runs (%d)" % errlog.errors.size())
	for e in errlog.errors.slice(0, 12):
		printerr("ERROR LOG: " + e)
	if fails == 0:
		print("PASS benchmark %d checks" % checks)
	else:
		printerr("FAIL benchmark: %d of %d checks" % [fails, checks])
	quit(1 if fails > 0 else 0)


## The folders of runs of this suite that died before they cleaned up (their process is gone). A folder of a run that is still going stays.
func _remove_stale_runs() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SCRATCH_ROOT)):
		return
	for d in DirAccess.get_directories_at(SCRATCH_ROOT):
		var pid := d.get_slice("_", 0)
		if pid.is_valid_int() and d.contains("_") and int(pid) != OS.get_process_id() and not _pid_alive(int(pid)):
			_remove_tree(ProjectSettings.globalize_path(SCRATCH_ROOT.path_join(d)))


## Whether process `pid` still runs. Not OS.is_process_running: for a process that is not this one's child (another worktree's run of this suite, which
## shares user://) Godot logs an engine error. /proc where there is one; elsewhere the folder is kept.
static func _pid_alive(pid: int) -> bool:
	if not DirAccess.dir_exists_absolute("/proc/self"):
		return true
	return DirAccess.dir_exists_absolute("/proc/%d" % pid)


func _remove_tree(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
