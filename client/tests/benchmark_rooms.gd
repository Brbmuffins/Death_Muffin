extends "res://tests/benchmark_base.gd"
## The in-game benchmark, every room (client/README.md "The benchmark"), headless: `godot --headless --path client --script res://tests/benchmark_rooms.gd`. One of five suites split from the old `benchmark` (see benchmark_base.gd).
##   - every room: a short Full Party run boots only that room's area, the hero stands on its floor, the director holds the room's whole roster on the core, the enemies that spawn are the room's, the report names the room, and
##     the room's boss is held awake the whole fight exactly where today's benchmark holds one (the boss data), while the Warren and the Coliseum run without;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber and the hound into a scratch folder first, unless the checkout's setup baked them (the rest of the rosters borrow them: warnings, not errors).

## The boss today's Full Party fight holds awake in each room (client/next/perf/dm_bench_fight.gd `boss_of`: the boss whose arena is the room); the Warren and the Coliseum have none.
## Kinds the room's own bodies make: a Deacon raises a corpse and a Lich Acolyte unbinds a fallen thrall as a Risen (native/src/core/support.cpp, nave.cpp), today's too.
const MADE_BY := {"risen": ["deacon", "acolyte"]}


func suite_name() -> String:
	return "benchmark_rooms"


func run_suite() -> void:
	await every_room()


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
		var boss: String = _boss_in(room)
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
