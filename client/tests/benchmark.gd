extends "res://tests/benchmark_base.gd"
## The in-game benchmark on the combat core (the rebuild's Gates B and C, DECISIONS B50; client/next/perf/BENCHMARK.md), headless: `godot --headless --path client --script res://tests/benchmark.gd`.
## The first of five suites that split the old one (benchmark_base.gd holds what they share; benchmark_rooms, benchmark_classes, benchmark_launch and benchmark_flags are the others). Deterministic checks only, timings are INFO:
##   - the setup: sizes, the combat areas as rooms and the playable classes, the Bell Sanctum as the Standard room, today's enemy health, the budgets are B39's, a room or class the benchmark does not list is refused with a plain message,
##     the team app's flags (`--bench-preset=`, `--bench-quit`) as the launch line reads them and the exit code they give;
##   - the fight is set up as the setup says: 72 enemies held (the farthest extras trimmed without a death), 32 thralls, the Gravedigger King awake, the fixed seed, every enemy on
##     the standard health, the hero holding the centre, no node per creature;
##   - Easy auto combat casts (the gate is closed until opened, it casts, it walks when it may, it reads the corpses and the core's bulk arrays, and nothing is a node);
##   - the frame split and the F3 overlay's logic line (a tick that holds itself for 3 ms);
##   - the report has its lines and its budget section prints, with a verdict for the core and the rest of the main thread, and the HUD's share is measured with the HUD put back after (a Full Party run in the Graves);
##   - the render breakdown and the HUD's share work;
##   - the setup window lists the rooms, classes and sizes, names the room's boss, and remembers the pick;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber and the hound into a scratch folder first, unless the checkout's setup baked them (the rest of the rosters borrow them: warnings, not errors).


func suite_name() -> String:
	return "benchmark"


func run_suite() -> void:
	check(DmBenchmark.dir == data and DmBenchmark.dir != DmBenchmark.DIR and DmBenchHistory.pending_file() == data + "/pending.json" and DmBenchHistory.history_file() == data + "/history.json" and DmBenchmarkSetup.file() == data + "/setup.json",
		"the suite keeps the benchmark's files in its own folder (%s), not in %s" % [data, DmBenchmark.DIR])
	check(DmBenchHistory.pending_count() == 0 and not FileAccess.file_exists(DmBenchmarkSetup.file()) and DmBenchHistory.previous({"clientRunId": "x", "discipline": 2, "room": "graves", "size": "x", "length": "x", "gpu": "x", "preset": "x"}).is_empty(), "and it starts with an empty queue, no history and no setup")
	await the_setup()
	await the_fight_by_hand()
	await auto_combat()
	await frame_split()
	await full_party_run()
	await breakdown_run()
	setup_window()


# ------------------------------------------------------------------------------------------------------------------ what the data says

## The combat areas: the world's order, the areas that are neither safe hubs nor the Depths instance.
func _combat_areas() -> Array:
	var out: Array = []
	for id in DmData.world()["order"]:
		var a: Dictionary = DmData.world()["areas"][id]
		if not bool(a["instance"]) and not bool(DmContent.area(String(id)).get("safe", false)):
			out.append(String(id))
	return out


## An area of the world the benchmark does not list as a room ("" when it lists them all).
func _area_outside_rooms() -> String:
	for id in DmData.world()["order"]:
		if not DmBenchmark.ROOMS.has(String(id)):
			return String(id)
	return ""


func _sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return b


## The health and damage every benchmark enemy should have, worked out from the data on its own: the Bell Sanctum roster's weighted average at the area's level, on Easy.
func _expected_standard() -> Dictionary:
	var level := DmEnemyStats.area_level("sanctum", [1.0], 0.0)
	var easy := DmContent.difficulty("easy")
	var weights := 0.0
	var hp := 0.0
	var dmg := 0.0
	for e: Dictionary in DmContent.area("sanctum")["enemies"]:
		weights += float(e["weight"])
		hp += float(e["weight"]) * float(DmSimData.ENEMIES[String(e["id"])]["hp"])
		dmg += float(e["weight"]) * float(DmSimData.ENEMIES[String(e["id"])]["damage"])
	return {"hp": hp / weights * DmEnemyStats.hp_scale(level) * float(easy["enemyHpMult"]), "dmg": dmg / weights * DmEnemyStats.damage_scale(level) * float(easy["enemyDamageMult"])}


## The name of the boss the data puts in `room` ("" = none).
func _boss_name(room: String) -> String:
	var id := _boss_in(room)
	return String(DmContent.boss(id)["name"]) if id != "" else ""


## A room of the benchmark's list with no boss of its own ("" = every room has one).
func _room_without_boss() -> String:
	for room: String in DmBenchmark.ROOMS:
		if _boss_in(room) == "":
			return room
	return ""


## The playable disciplines' class indices, ascending (DmCharacterBuild.is_playable over the combat data's disciplines).
func _playable_classes() -> Array:
	var out: Array = []
	for d: Dictionary in (DmCombatData.disciplines()["disciplines"] as Dictionary).values():
		if DmCharacterBuild.is_playable(float(d["classIndex"])):
			out.append(int(d["classIndex"]))
	out.sort()
	return out


## A class index of the character select's list that is not playable (a number no discipline has when all are).
func _unplayable_class() -> int:
	var playable := _playable_classes()
	for d: Dictionary in DmContent.file("disciplines").get("PLAYABLE_DISCIPLINES", []):
		if not playable.has(int(d["classIndex"])):
			return int(d["classIndex"])
	return 99


# ------------------------------------------------------------------------------------------------------------------ the setup

func the_setup() -> void:
	var cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	check(DmBenchmark.SIZES["full_party"] == [cap, 32] and DmBenchmark.BOSS_SIZES == ["full_party"] and DmBenchmark.SIZE_NAMES["full_party"] == "Full Party",
		"Full Party: the global enemy cap (%d) and 32 thralls, the only size with a boss" % cap)
	check(DmBenchmark.SIZES["light"] == [15, 10] and DmBenchmark.SIZES["standard"] == [30, 20] and DmBenchmark.SIZES["heavy"] == [60, 30], "the other sizes are today's")
	check(DmBenchmark.LENGTHS["quick"] == [6.0, 20.0, false] and DmBenchmark.LENGTHS["full"] == [10.0, 30.0, true], "the lengths are today's")
	check(DmBenchmark.ENEMY_LIMIT > cap and DmBenchmark.SEED == 20261011, "the director's body limit leaves room for the corpses; the seed is today's (%d)" % DmBenchmark.SEED)
	check(DmBenchmark.ROOMS == _combat_areas() and not DmBenchmark.ROOMS.is_empty() and _sorted(DmBenchmark.class_indices()) == _playable_classes() and not DmBenchmark.class_indices().is_empty(),
		"the benchmark's rooms are the world's combat areas, in world order, and its classes the playable disciplines of the data")
	var every: Array = DmNextWorld.every_area()
	var rooms_ok := true
	for room: String in DmBenchmark.ROOMS:
		var roster: Array = DmContent.area(room)["enemies"]
		rooms_ok = rooms_ok and every.has(room) and not roster.is_empty() and roster.all(func(e: Dictionary) -> bool: return DmWaveDirector.runs_on_core(String(e["id"])))
	check(rooms_ok and not DmBenchmark.ROOMS.has("depths"), "every room is an area the world loads and the core runs its whole roster (the Depths stays out)")
	check(DmBenchmark.BUDGET_CORE_MS == 4.0 and DmBenchmark.BUDGET_REST_MS == 4.0 and DmBenchmark.BUDGET_HUD_MS == 0.5 and DmBenchmark.BUDGET_HUD_DRAWS == 150, "the budgets are B39's: core 4 ms, rest 4 ms, HUD 0.5 ms and 150 draws")
	var last_room: String = DmBenchmark.ROOMS[DmBenchmark.ROOMS.size() - 1]
	var last_class: int = DmBenchmark.class_indices()[DmBenchmark.class_indices().size() - 1]
	var off_room := _area_outside_rooms()
	var off_class := _unplayable_class()
	check(off_room != "" and off_class >= 0, "the data has an area and a class the benchmark does not list (%s, %d)" % [off_room, off_class])
	check(DmBenchmark.normalize_setup({"room": "nowhere", "discipline": 7, "size": "huge"}) == DmBenchmark.STANDARD, "unknown picks fall back to the Standard setup")
	check(DmBenchmark.normalize_setup({"room": last_room, "discipline": last_class})["room"] == last_room and DmBenchmark.normalize_setup({"room": last_room, "discipline": last_class})["discipline"] == last_class and DmBenchmark.normalize_setup({"room": off_room})["room"] == DmBenchmark.STANDARD["room"]
		and DmBenchmark.normalize_setup({"discipline": off_class})["discipline"] == DmBenchmark.STANDARD["discipline"], "a listed room and class are taken; the Depths and a greyed-out class fall back to the Standard room and class")
	check(DmBenchmark.STANDARD == {"room": "sanctum", "discipline": 2, "size": "standard", "length": "full"} and DmBenchmark.is_standard(DmBenchmark.STANDARD) and not DmBenchmark.is_standard({"room": "graves", "discipline": 2, "size": "standard", "length": "full"}),
		"Standard is today's: the Bell Sanctum, Gravecaller, Standard, Full")
	# a room or class the benchmark does not list is refused in plain words
	check(DmBenchmark.refusal({"room": DmBenchmark.ROOMS[0], "discipline": DmBenchmark.class_indices()[0]}) == "" and DmBenchmark.refusal({}) == "" and DmBenchmark.refusal({"room": last_room, "discipline": last_class}) == "", "the listed rooms and classes are not refused")
	var why_room := DmBenchmark.refusal({"room": off_room})
	check(why_room.contains("'%s'" % off_room) and DmBenchmark.ROOMS.all(func(r: String) -> bool: return why_room.contains(r)), "a room the benchmark does not list is refused with a clear message naming the listed ones (%s)" % why_room)
	var why_class := DmBenchmark.refusal({"discipline": off_class})
	check(why_class.contains("class %d" % off_class) and DmBenchmark.class_indices().all(func(i: int) -> bool: return why_class.contains("%d %s" % [i, DmBenchmark.class_name_of(i)])), "a class the benchmark does not list is refused with a clear message naming the listed ones (%s)" % why_class)
	# the enemies' health and damage are today's: the Bell Sanctum roster's weighted average on Easy, whatever the room
	var std := DmBenchmark.standard_stats()
	var worked := _expected_standard()
	check(absf(float(std["hp"]) - float(worked["hp"])) < 0.001 and absf(float(std["dmg"]) - float(worked["dmg"])) < 0.001 and float(std["hp"]) > 0.0, "every enemy has the Bell Sanctum roster's average health %.3f and damage %.3f (%.3f, %.3f)" % [worked["hp"], worked["dmg"], std["hp"], std["dmg"]])
	var boss_host := DmBossHost.new()
	var served: Array = boss_host.served_areas.duplicate()
	boss_host.free()
	var todays := true
	var woken := true
	for room: String in DmBenchmark.ROOMS:   # the rooms and their bosses are today's, and the game wakes every one of them
		todays = todays and DmBenchFight.boss_of(room) == _boss_in(room)
		woken = woken and (_boss_in(room) == "" or served.has(room))
	check(todays and woken, "every room's boss is the boss the data puts in that area, and the boss host wakes it (%s)" % str(served))
	var sanctum_fp := DmBenchmark.new()
	sanctum_fp.configure({"room": "sanctum", "size": "full_party"})
	check(sanctum_fp.boss_id == _boss_in("sanctum") and sanctum_fp.boss_text().contains("%s held awake" % _boss_name("sanctum")), "Full Party in the Sanctum holds its boss (%s)" % sanctum_fp.boss_text())
	sanctum_fp.free()
	var bossless := _room_without_boss()
	if bossless != "":
		var bossless_fp := DmBenchmark.new()
		bossless_fp.configure({"room": bossless, "size": "full_party"})
		check(bossless_fp.boss_id == "" and bossless_fp.boss_text() == ", no boss (this room has none)", "Full Party in %s runs without a boss and says the room has none" % bossless)
		bossless_fp.free()
	var held: Array = DmBenchmark.SIZES["full_party"]
	var quick: Array = DmBenchmark.LENGTHS["quick"]
	var fp := DmBenchmark.new()
	fp.configure({"room": "graves", "discipline": 2, "size": "full_party", "length": "quick"})
	check(fp.enemies == cap and fp.thralls == int(held[1]) and fp.boss_id == _boss_in("graves") and fp.boss_id != "" and not fp.breakdown and fp.warm_s == float(quick[0]) and fp.measure_s == float(quick[1]) and fp.boss_text().contains(_boss_name("graves")),
		"configure: Full Party in the Graves holds its boss (%d, %d, %s)" % [fp.enemies, fp.thralls, fp.boss_id])
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
	var want: Dictionary = M.bench_wanted_from_args(PackedStringArray(["--benchmark", "--bench-room=" + off_room, "--bench-class=%d" % off_class]))
	check(want == {"room": off_room, "discipline": off_class} and DmBenchmark.refusal(want) != "", "launch args that name a room or class outside the lists are what the refusal is asked about")
	var fen: Dictionary = M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-room=fen", "--bench-class=11"]))
	check(fen["room"] == "fen" and fen["discipline"] == 11 and DmBenchmark.refusal(M.bench_wanted_from_args(PackedStringArray(["--bench-room=fen", "--bench-class=11"]))) == "", "launch args pick the Fen and the Reaper")
	check(DmLaunchArgs.options(PackedStringArray(["--benchmark", "--bench-dir=/tmp/x y"]))["bench_dir"] == "/tmp/x y" and not DmLaunchArgs.options(PackedStringArray(["--benchmark"])).has("bench_dir"), "--bench-dir= names the folder a run keeps its files in")
	# the team app's flags: the preset of the run, and quitting by itself
	var first_preset: String = DmGraphicsPreset.IDS[0]
	var named: Dictionary = M.bench_wanted_from_args(PackedStringArray(["--benchmark", "--bench-preset=" + first_preset, "--bench-room=graves", "--bench-quit"]))
	check(named == {"preset": first_preset, "room": "graves"} and DmBenchmark.refusal(named) == "", "--bench-preset=%s is read with the setup's keys, and refused by nothing" % first_preset)
	check(M.bench_setup_from_args(PackedStringArray(["--benchmark", "--bench-preset=" + first_preset])) == DmBenchmark.STANDARD, "the preset is not part of the setup: it stays the Standard one")
	check(not M.bench_wanted_from_args(PackedStringArray(["--benchmark", "--bench-quit"])).has("preset"), "no --bench-preset= names no preset (the player's own)")
	for id in DmGraphicsPreset.IDS:
		check(DmBenchmark.refusal({"preset": id}) == "", "--bench-preset=%s is something the benchmark can run" % id)
	for bad in ["nopreset", DmGraphicsPreset.IDS[0].capitalize(), "", "%s %s" % [DmGraphicsPreset.IDS[-1], DmGraphicsPreset.IDS[0]], DmGraphicsPreset.IDS[0] + ";rm"]:
		var why := DmBenchmark.refusal(M.bench_wanted_from_args(PackedStringArray(["--benchmark", "--bench-preset=" + bad])))
		check(why.contains("'%s'" % bad) and why.contains(", ".join(DmGraphicsPreset.IDS)) and why.contains("--bench-preset="), "--bench-preset=%s is refused with a message that names the presets (%s)" % [bad, why])
	# the preset is on loan: the run reads it as the player's setting, and the player's own are neither written nor changed
	var settings_before := FileAccess.file_exists(DmSettings.FILE)
	var settings_text := FileAccess.get_file_as_string(DmSettings.FILE) if settings_before else ""
	var own_preset := String(DmBenchmark.user_settings()["graphics"])
	for id in DmGraphicsPreset.IDS:
		check(String(DmBenchmark.user_settings(id)["graphics"]) == id, "the run reads %s as the graphics setting when it is asked for" % id)
	check(String(DmBenchmark.user_settings("")["graphics"]) == own_preset and String(DmSettings.new(DmSettings.FILE, true).values["graphics"]) == own_preset, "no preset asked for: the player's own; and the loan does not leak into the next read")
	check(FileAccess.file_exists(DmSettings.FILE) == settings_before and (not settings_before or FileAccess.get_file_as_string(DmSettings.FILE) == settings_text), "the player's settings file is untouched (%s)" % ("present" if settings_before else "absent"))
	# the exit code of a --bench-quit run
	var done_run := {"phases": [{"avg_fps": 60.0}], "cancelled": false}
	check(DmBenchmarkScreen.exit_code(done_run, true) == 0, "a finished run that is the last entry of the queue exits 0")
	check(DmBenchmarkScreen.exit_code(done_run, false) == 1, "a run the queue did not take exits 1")
	check(DmBenchmarkScreen.exit_code({"phases": [{"avg_fps": 60.0}], "cancelled": true}, true) == 1, "a cancelled run exits 1, though it was queued (flagged)")
	check(DmBenchmarkScreen.exit_code({"phases": [], "cancelled": true}, true) == 1 and DmBenchmarkScreen.exit_code({"phases": []}, false) == 1, "a run with no finished phase exits 1")
	# "recorded" means the run is the last entry of the queue
	var entry_a := DmBenchHistory.payload(_tiny_result(), "report a")
	var entry_b := DmBenchHistory.payload(_tiny_result(), "report b")
	entry_b["clientRunId"] = str(entry_a["clientRunId"]) + "9"
	check(not DmBenchHistory.queued(entry_a), "a run that was not recorded is not in the queue")
	DmBenchHistory.record(entry_a)
	check(DmBenchHistory.queued(entry_a) and not DmBenchHistory.queued(entry_b), "a recorded run is the last entry of the queue")
	DmBenchHistory.record(entry_b)
	check(DmBenchHistory.queued(entry_b) and not DmBenchHistory.queued(entry_a), "the next run is the last entry, the one before it is not")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DmBenchHistory.pending_file()))


# ------------------------------------------------------------------------------------------------------------------ the fight, by hand

## DmBenchFight on a booted game: the pieces of the held fight one at a time.
func the_fight_by_hand() -> void:
	var f := await DmBenchFight.boot(root, 2, {"audio": false, "baked_dir": scratch}, "graves")
	var g: DmNextGame = f["game"]
	var host: DmCoreHost = g.core_host
	var hero: DmHeroBody = f["hero"]
	var at: Vector3 = f["at"]
	var held: int = DmBenchmark.SIZES["full_party"][0]   # the enemies a Full Party fight holds ...
	var legion: int = DmBenchmark.SIZES["full_party"][1] # ... and its thralls
	var boss_id := _boss_in("graves")
	check(boss_id != "", "the Graves have a boss to hold (%s)" % boss_id)
	check(g.ready_ and int(g.opts["seed"]) == DmBenchmark.SEED, "the game was built with the fixed seed")
	check(g.world.area_at(at.x, at.z) == "graves" and hero.position.distance_to(at) < 0.1 and g.world.nav_closest(at).distance_to(at) < 0.5, "the hero stands on walkable ground in the Graves (%s)" % str(at))
	check(DmNextWarmup.crowd_rows == host.view.model_slots().size() * 3 * 2 and host.is_physics_processing() and g.is_processing(), "the warm-up fed %d rehearsal rows to the crowd and gave the game back" % DmNextWarmup.crowd_rows)
	check(host.view.stats().bodies == 0, "the rehearsal rows are gone from the crowd (%d bodies)" % int(host.view.stats().bodies))
	var hero_c: DmCreature = hero.avatar.c if hero.avatar != null else null
	check(DmNextWarmup.shots >= 4 and hero_c != null and is_equal_approx(hero_c.opacity(), 1.0), "the warm-up drew a shot of each kind and a beam (%d), and the hero's see-through pass ended opaque" % DmNextWarmup.shots)
	var none := PackedStringArray()
	check(DmNextGame._wants_warmup(none, "Windows") and not DmNextGame._wants_warmup(none, "headless") and DmNextGame._wants_warmup(PackedStringArray(["--warmup"]), "headless")
		and not DmNextGame._wants_warmup(PackedStringArray(["--qa"]), "Windows") and not DmNextGame._wants_warmup(PackedStringArray(["--shot-plan=x.json"]), "X11"),
		"a player's game warms up as today's does (on in a window, off headless and on QA or screenshot runs, --warmup forces it)")
	check(bool(hero.p["god"]) and float(f["caster"].p["stats"]["level"]) == 60.0 and g.director.difficulty == "easy" and g.input.auto.allowed(), "a god-mode level 60 hero on Easy, auto combat open")
	check(int(f["stats"]["calls"]) > 0 and g.api.get("base_url") == "", "the backend is the mock (%d requests, no base url)" % int(f["stats"]["calls"]))
	DmBenchFight.arm(g, held, DmBenchmark.SEED)
	check(g.director.rng.seed == DmBenchmark.SEED and g.director.cap == held and g.director.enemy_limit == DmBenchmark.ENEMY_LIMIT and g.input.auto.hold_position
		and g.director.spawn_min == DmBenchmark.SPAWN_MIN_M and g.director.spawn_max == DmBenchmark.SPAWN_MAX_M, "arm: the director's seed, cap, limit and spawn distances, and the hero holds his ground")
	var std_hp := float(DmBenchmark.standard_stats()["hp"])
	check(absf(float(g.director.fixed_stats["hp"]) - std_hp) < 0.001, "arm: every enemy takes the standard health")
	g.director.enabled = false
	await ticks(30)
	var n0 := nodes()
	# the full count of enemies through the director, and the count is held
	DmBenchFight.top_up(g, hero, held)
	g.director.flush_spawns()
	var died := [0]
	host.enemy_died.connect(func(_i: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: died[0] += 1)
	await ticks(3)
	check(g.director.alive_count() == held and host.enemy_total() == held, "top-up: %d enemies alive through the director (%d)" % [held, g.director.alive_count()])
	# extras past the cap (a raiser's Risen, the boss's adds): the farthest go quietly
	var far_ids: Array = []
	for i in 6:
		far_ids.append(host.spawn_enemy("robber", g.world.nav_closest(at + Vector3(24.0 + float(i), 0.0, 0.0)), 1, 1.0, 1.0, false, "graves", false))
	await ticks(2)
	var far_ok := true
	for id in far_ids:
		far_ok = far_ok and host.enemy_position(id).distance_to(hero.position) > DmBenchmark.SPAWN_MAX_M + 2.0
	check(far_ok, "the extras stand beyond the waves' spawn ring")
	check(host.alive_count() == held + 6, "six extra bodies: %d alive" % (held + 6))
	DmBenchFight.trim(g, hero, held)
	await ticks(2)
	var gone := 0
	for id in far_ids:
		if host.enemy_info(id).is_empty() or not host.enemy_alive(id):
			gone += 1
	check(host.alive_count() == held and gone == 6 and died[0] == 0, "trim: the six farthest left without a death, %d are held (%d alive, %d gone, %d deaths)" % [held, host.alive_count(), gone, died[0]])
	check(host.corpses.count() == 0, "trim leaves no corpse")
	# the legion, raised straight into the core
	check(DmBenchFight.raise_thralls(g, hero, legion, at) == legion and host.thrall_count(hero.core_id) == legion and DmBenchFight.raise_thralls(g, hero, legion, at) == legion, "%d thralls are raised, and raised once" % legion)
	await ticks(20)
	var n1 := nodes()
	check(n1 - n0 <= 12, "%d enemies and %d thralls in the core: the scene tree holds %d nodes, was %d (no node per creature)" % [held, legion, n1, n0])
	check(get_nodes_in_group("dm_enemy").is_empty() and root.find_children("*", "NavigationAgent3D", true, false).is_empty() and root.find_children("*", "HTTPRequest", true, false).is_empty(),
		"no node is in an enemy group, no agent, no HTTP request")
	var std_ok := true
	for id in host.core.enemy_ids():
		std_ok = std_ok and absf(float(host.core.enemy_info(id)["max_hp"]) - std_hp) < 0.01
	check(std_ok, "every enemy has the standard health")
	# the King, through the real summon
	check(g.bosses.active_boss() == null, "the boss sleeps before the summon")
	hero.teleport(at)
	check(DmBenchFight.hold_boss(g, hero, boss_id, at), "hold_boss: the Graves' boss is summoned")
	await ticks(5)
	var king := g.bosses.active_boss()
	check(king != null and king.boss_id == boss_id and king.is_awake(), "the boss is awake")
	check(hero.position.distance_to(at) < 0.1, "the hero is back at the centre after the summon")
	check(not DmBenchFight.hold_boss(g, hero, boss_id, at), "an awake boss is not summoned twice")
	check(DmBenchFight.upkeep(f, held, legion, boss_id) == legion, "upkeep returns the legion held")
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
		host.spawn_enemy("robber", at + Vector3(0.0, 0.0, -2.0 * float(DmAbilities.def("bone_needle")["range"]) + float(i) * 0.6), 60, 5.0, 0.0, false, "graves", false)
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
	var legion: int = DmBenchmark.SIZES["full_party"][1]
	var boss_id := _boss_in("graves")
	check(float(ph["enemies"]) >= cap * 0.85 and int(ph["enemies_min"]) > 0, "%d enemies held (%.1f on average, fewest %d)" % [cap, ph["enemies"], int(ph["enemies_min"])])
	check(float(ph["thralls"]) >= float(legion) - 0.01, "%d thralls held (%.1f)" % [legion, float(ph["thralls"])])
	check(b.boss_summons >= 1 and String(r["boss"]["id"]) == boss_id and int(r["boss"]["summons"]) == b.boss_summons and boss_seen > 0, "the boss was woken (%d times, %d defeats, awake in %d of %d samples)" % [b.boss_summons, b.boss_defeats, boss_seen, samples])
	check(float(ph["boss_awake_pct"]) >= 50.0, "and was awake for most of the window (%.0f%%)" % float(ph["boss_awake_pct"]))
	check(hp_seen.size() == 1 and absf(float(hp_seen.keys()[0]) / 1000.0 - float(DmBenchmark.standard_stats()["hp"])) < 0.01, "every enemy, the boss's adds included, had the standard health (%s)" % str(hp_seen.keys()))
	check(casts_seen > 5 and int(r["kills"]) >= 5, "auto combat cast %d times and %d enemies died: the fight is a fight" % [casts_seen, int(r["kills"])])
	check(vsync_setting == false, "the fight's graphics settings keep V-Sync off (%s): a run is never capped at the monitor's refresh" % str(vsync_setting))
	check(float(r["max_drift"]) <= 1.6, "the hero holds the centre (farthest %.2f m between checks)" % float(r["max_drift"]))
	check(b.area_nav_on and bool(r["input_locked"]), "the Graves' navmesh is on and the player's input is switched off")
	print("INFO nodes with the King awake: %d to %d" % [nodes_lo, nodes_hi])
	check(samples > 0 and creature_nodes == 0, "in none of the %d samples of the fight did a node exist for a creature (enemy group, navigation agent, physics body)" % samples)
	check(r["backend_calls"] > 0 and r["meta"]["core"].begins_with("dmcore") and r["meta"]["fight"].contains("seed %d" % DmBenchmark.SEED) and r["meta"]["fight"].contains("%s held awake" % _boss_name("graves")), "the mock backend served the run; the meta names the core, the seed and the boss")
	for k in ["build", "gpu", "renderer", "resolution", "preset", "fps_cap", "cpu", "cores", "vsync", "setup", "fight", "core"]:
		check(r["meta"].has(k), "meta has %s" % k)
	check(root.find_children("*", "HTTPRequest", true, false).is_empty() and not has_script_class(root, "DmHttpTransport"), "no network node was created")
	check(DmUiConfig.dir == "user://" and DmBuild.version() == "dev", "the UI config dir is restored")
	check(lines.size() >= 2 and lines[0].begins_with("Building"), "progress lines were emitted")
	# the crowd's settings and counters are in the report: the game's own defaults here (nothing asked for)
	var cs: Dictionary = r["meta"]["crowd"]
	var lod_rule: Dictionary = CrowdView.ANIM_LOD
	check(cs.anim_lod and cs.culling and cs.thrall_shadows and cs.reserve == CrowdView.RESERVE and cs.lod_distances == PackedFloat32Array(CrowdView.LOD_DISTANCES) and cs.anim_mid_hz == float(lod_rule["mid_hz"]) and cs.anim_far_hz == float(lod_rule["far_hz"]),
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
	var lods: Array = CrowdView.LOD_DISTANCES
	for needle in ["Death Muffin benchmark", "Average fps", "Frame ms (p95)", "V-Sync: off during measurement", "Combat core: dmcore", "Setup: %s, %s, %s, Quick (custom" % [DmBenchmark.room_name("graves"), DmBenchmark.class_name_of(2), DmBenchmark.SIZE_NAMES["full_party"]],
			"Boss: %s" % _boss_name("graves"), "held awake", "seed %d" % DmBenchmark.SEED, "Crowd: mesh levels at %d / %d m; %d instances reserved a group; animation %.1f Hz beyond %d m, %.1f Hz beyond %d m; culling on; thralls cast shadows" % [int(lods[0]), int(lods[1]), CrowdView.RESERVE, float(lod_rule["mid_hz"]), int(lod_rule["mid_m"]), float(lod_rule["far_hz"]), int(lod_rule["far_m"])],
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
	var light: Array = DmBenchmark.SIZES["light"]
	check(b.breakdown and b.enemies == int(light[0]) and b.thralls == int(light[1]) and b.boss_id == "", "configure: Light, Full length (render breakdown on)")
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


# ------------------------------------------------------------------------------------------------------------------ the setup window

func setup_window() -> void:
	var w := DmBenchmarkSetup.new()
	var got: Array = []
	w.start.connect(func(s: Dictionary) -> void: got.append(s))
	root.add_child(w)
	check(DmBenchmark.is_standard(w.setup), "the setup window opens on the Standard setup the first time")
	check(w._room.item_count == DmBenchmark.ROOMS.size() and w._room.get_item_text(0).begins_with(DmBenchmark.room_name(DmBenchmark.ROOMS[0])) and w._room.get_item_text(w._room.item_count - 1).begins_with(DmBenchmark.room_name(DmBenchmark.ROOMS[DmBenchmark.ROOMS.size() - 1])),
		"it lists the benchmark's rooms in order, the first and the last by name")
	var std_room := w._room.get_item_text(DmBenchmark.ROOMS.find("sanctum"))
	check(std_room.begins_with(DmBenchmark.room_name("sanctum")) and std_room.ends_with("(standard)") and w._room.get_selected_metadata() == "sanctum", "the Bell Sanctum is marked standard and picked (%s)" % std_room)
	var classes_ok := w._class.item_count == DmBenchmark.class_indices().size()
	for i in w._class.item_count:
		classes_ok = classes_ok and w._class.get_item_metadata(i) == DmBenchmark.class_indices()[i] and w._class.get_item_text(i).begins_with(DmBenchmark.class_name_of(int(w._class.get_item_metadata(i))))
	check(classes_ok and w._class.get_selected_metadata() == DmBenchmark.STANDARD["discipline"], "it lists the playable classes, the Standard class picked (%s)" % w._class.get_item_text(w._class.item_count - 1))
	var full: Array = DmBenchmark.SIZES["full_party"]
	check(w._size.item_count == DmBenchmark.SIZES.size() and w._size.get_item_text(DmBenchmark.SIZES.keys().find("full_party")) == "%s: %d enemies, %d thralls, a boss" % [DmBenchmark.SIZE_NAMES["full_party"], int(full[0]), int(full[1])], "it lists Full Party with its counts and the boss (%s)" % w._size.get_item_text(DmBenchmark.SIZES.keys().find("full_party")))
	w._size.select(DmBenchmark.SIZES.keys().find("full_party"))
	w._size.item_selected.emit(w._size.selected)
	w._room.select(0)
	w._room.item_selected.emit(0)
	check(w._note.text.contains(_boss_name("graves")) and w._note.text.contains("held awake") and w._note.text.contains("Custom setup"), "in the Graves the note names the room's boss (%s)" % w._note.text)
	var bossless := _room_without_boss()
	if bossless != "":
		w._room.select(DmBenchmark.ROOMS.find(bossless))
		w._room.item_selected.emit(w._room.selected)
		check(w._note.text.contains("no boss"), "in %s the note says the room has no boss (%s)" % [bossless, w._note.text])
	w._room.select(DmBenchmark.ROOMS.find("sanctum"))
	w._room.item_selected.emit(w._room.selected)
	check(w._note.text.contains(_boss_name("sanctum")) and w._note.text.contains("held awake"), "in the Sanctum the note names its boss, held awake (%s)" % w._note.text)
	var last_room: String = DmBenchmark.ROOMS[DmBenchmark.ROOMS.size() - 1]
	var last_class: int = DmBenchmark.class_indices()[DmBenchmark.class_indices().size() - 1]
	w._room.select(DmBenchmark.ROOMS.size() - 1)
	w._room.item_selected.emit(w._room.selected)
	w._class.select(w._class.item_count - 1)
	w._class.item_selected.emit(w._class.item_count - 1)
	w._start()
	check(got.size() == 1 and got[0]["size"] == "full_party" and got[0]["room"] == last_room and got[0]["discipline"] == last_class, "Start hands over the last room, the last class and Full Party")
	var last := DmBenchmarkSetup.load_last()
	check(last["size"] == "full_party" and last["room"] == last_room and last["discipline"] == last_class and FileAccess.file_exists(data + "/setup.json"), "and the window remembers it, in the suite's own folder")
	var texts := PackedStringArray()
	for l in w.find_children("*", "Label", true, false):
		texts.append((l as Label).text)
	var all_text := "\n".join(texts)
	check(all_text.contains("benchmark page") and not all_text.contains("muffindevelopment.com"), "the window says runs go to the game's benchmark page, and names no address")
	w.queue_free()
