extends SceneTree
## The Catacomb Depths on the combat core (ROADMAP "The Depths and gathering"; client/README.md "The Depths"): the game scene as a player gets it (the whole world, the HUD), offline on the
## local mock, headless. Today's tests/next_depths replayed on the core. Checks:
##   A the rules, no game: floors per seed (sound, deterministic, a chest every fifth depth), quota, pacing, affixes, rosters (and the kinds the core does not run yet left out), levels,
##     the first wave, the stair opening once, the loot ground by depth;
##   B the world: the Depths node and the Warren's stair, the Depths' rect in the core's bounds and in no area until a run opens it, nothing on the core before a run;
##   C the way in: the Warren's seal broken, waystone travel, a click on the stair walks the hero to it and starts a run; floor 1 stands (drawn, the hero at its way in, in the Depths,
##     the stairs clickable, the arrival banner, the HUD's readout and map, the prompts), its navmesh is baked, on the navigation map and the core's own copy of it, which answers
##     what the navigation server answers; a run is solo;
##   D the dead: bodies of the core at the depth's level, in the Depths' area and on the floor, hunting the hero across the rooms (aggro 36), fighting back; elites bear the depth's affixes;
##     none of the kinds the core does not run yet;
##   E the quota: the hero's kills (through the core, credited once) open the stair at the 10th, the floor pays (gold, XP, a tape item) and is reported, kills are paid on the Depths' ground;
##   F descending: floor 2 of the same seed, the dead and corpses of floor 1 gone from the core, the hero at the way in, the core's navmesh replaced (not added to), a new quota;
##   G the chest on depth 5: its tape finds on the ground (a claim picks one into the bag on the server), once, off the HUD and the map;
##   H leaving: the exit asks twice, the summary, the Warren's stair, everything torn down (picture, navmesh, the core's copy, interactables), the record on the backend, the stair's offer to
##     resume, a recall (T) out of a run, a second player joining;
##   I death: the run ends and the floor stays behind the death screen, no stairs or waves, the hero rises in the Chapterhouse, nothing taken, a new run possible;
##   ZERO script errors or engine errors in the log.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/depths.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


const OUT := "user://depths_test"
const BAKE := ["grave_robber", "bone_hound"]

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var api: DmApi
var g: DmNextGame
var d: DmDepths
var hero: DmHeroBody
var m: DmRewardsMember
var character: Dictionary
var events: Array = []          ## [id, ctx] of the HUD's game events
var immortal := true            ## re-applied every frame: a level-up (floor XP) rebuilds the stats and would leave the hero mortal
var tri_base := 0               ## the core's navmesh triangles outside a run
var _last_us := 0
var worst_us := 0               ## the longest physics frame since the last reset (INFO only: tests never assert wall-clock time)


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL depths: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_ticks: int) -> bool:
	var end := Engine.get_physics_frames() + limit_ticks
	while not bool(cond.call()) and Engine.get_physics_frames() < end:
		await physics_frame
	return bool(cond.call())


func ev(id: String) -> Array:
	return events.filter(func(e: Array) -> bool: return e[0] == id)


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
	DmSimData.ensure()
	_a_rules()
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var reg := await api.register("depths%d" % (Time.get_ticks_usec() % 100000), "d@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 12)
	character = ch.data
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(character, api, {"name": "tester", "hud": true, "audio": false, "seed": 20261017, "waves": false, "wander": false, "persist": false, "baked_dir": OUT})
	hero = g.local_body()
	d = g.depths
	m = g.my_member()
	print("INFO depths: the game loads in %d ms; the core holds %d navmesh triangles" % [g.load_ms, g.core_host.core.nav_triangle_count()])
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append([id, ctx]))
	physics_frame.connect(func() -> void:
		var now := Time.get_ticks_usec()
		if _last_us > 0:
			worst_us = maxi(worst_us, now - _last_us)
		_last_us = now
		if immortal and g != null and g.local_body() != null and g.local_body().alive and g.local_body().max_hp < 1e8:
			_harden())
	_b_world()
	await _c_way_in()
	await _d_the_dead()
	await _e_quota()
	await _f_descend()
	await _g_chest()
	await _h_leaving()
	await _i_death()
	await _j_many_floors()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s depths %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


## The hero cannot die by accident (the test kills him on purpose).
func _harden() -> void:
	var b := g.local_body()
	b.p["stats"]["maxHp"] = 1e9
	b.p["hp"] = 1e9
	b._mirror_from_state()


# ---- helpers ----------------------------------------------------------------------------------------------------------------------

func _it(id: String) -> Dictionary:
	for it in g.chapterhouse.interactables:
		if it["id"] == id:
			return it
	return {}


func _floor_json(f: Dictionary) -> String:
	return JSON.stringify(f)


func _ids(roster: Array) -> Array:
	return roster.map(func(e: Dictionary) -> String: return String(e["id"]))


func _w(roster: Array, id: String) -> float:
	for e in roster:
		if e["id"] == id:
			return float(e["weight"])
	return 0.0


## The bodies of the Depths that are alive in the core: [{id, def, level, elite, area, pos, ...}] (enemy_info).
func _depths_enemies() -> Array:
	var out: Array = []
	for id in g.core_host.core.enemy_ids():
		var info: Dictionary = g.core_host.core.enemy_info(id)
		if String(info["area"]) == "depths" and int(info["state"]) != DmCoreEvents.State.DEAD:
			out.append(info)
	return out


## Kill every Depths body that can be hurt now (a rising one is immune for about a second) with the hero's blow: credited once, to him.
func _kill_all() -> int:
	var n := 0
	for info in _depths_enemies():
		if bool(g.core_host.damage(int(info["id"]), 1.0e9, hero.core_id, false)["killed"]):
			n += 1
	return n


## Clear a floor's quota through real kills: returns when the stair is open.
func _clear_floor(limit_ticks: int = 60 * 60) -> bool:
	return await until(func() -> bool:
		_kill_all()
		return d.run == null or d.run.stair_open, limit_ticks)


func _exit_run() -> void:
	d.leave()
	d.leave()
	await ticks(3)


# ---- A: the rules --------------------------------------------------------------------------------------------------------------

func _a_rules() -> void:
	var same := true
	var sound := true
	var chests_ok := true
	for depth in range(1, 16):
		var a := DmDepthsRun.generate(1000 + depth, depth)
		var b := DmDepthsRun.generate(1000 + depth, depth)
		same = same and _floor_json(a) == _floor_json(b)
		sound = sound and DmDepthsFloor.floor_problems(a).is_empty()
		chests_ok = chests_ok and ((a["chest"] != null) == (depth % 5 == 0))
	check(same, "a floor is deterministic per (seed, depth)")
	check(sound, "15 generated floors have no unreachable stair / chest / breach")
	check(chests_ok, "a chest on every fifth depth (5, 10, 15) and no other")
	check(_floor_json(DmDepthsRun.generate(1, 3)) != _floor_json(DmDepthsRun.generate(2, 3)) and _floor_json(DmDepthsRun.generate(1, 3)) != _floor_json(DmDepthsRun.generate(1, 4)), "another seed or depth gives another floor")
	var D: Dictionary = DmSimData.DEPTHS
	check(DmSimDepthsRules.floor_kills(1.0) == 10.0 and DmSimDepthsRules.floor_kills(5.0) == 14.0 and DmSimDepthsRules.floor_kills(40.0) == 30.0, "quota: 9 + depth, at most 30")
	check(DmSimDepthsRules.depth_wave_size(1.0) == 5.0 and DmSimDepthsRules.depth_wave_size(12.0) == 7.0 and DmSimDepthsRules.depth_wave_size(60.0) == 9.0, "wave size: 5 + depth / 6, at most 9")
	check(is_equal_approx(DmSimDepthsRules.depth_wave_gap_s(1.0), 4.35) and DmSimDepthsRules.depth_wave_gap_s(60.0) == 2.4, "wave gap: 4.4 - 0.05 depth, at least 2.4 s")
	check(DmSimDepthsRules.extra_affixes(4.0) == 0 and DmSimDepthsRules.extra_affixes(5.0) == 1 and DmSimDepthsRules.extra_affixes(15.0) == 3 and DmSimDepthsRules.extra_affixes(99.0) == 3, "elite affixes: one more every 5 depths, at most 3 extra")
	check(is_equal_approx(DmSimDepthsRules.depth_elite_bonus(10.0), 0.05) and DmSimDepthsRules.depth_elite_bonus(99.0) == 0.14, "elite chance +0.5% per depth, at most +14%")
	check(int(D["cap"]) == 24 and int(D["chestEvery"]) == 5 and float(D["firstWaveDelayS"]) == 1.4, "DEPTHS: cap 24, a chest every 5, first wave after 1.4 s")
	var base := ["rat", "robber", "ghoul", "bat", "sac", "hound"]
	var r1 := _ids(DmSimDepthsRules.depth_roster(1.0))
	var r5 := _ids(DmSimDepthsRules.depth_roster(5.0))
	var r10 := _ids(DmSimDepthsRules.depth_roster(10.0))
	var r15 := _ids(DmSimDepthsRules.depth_roster(15.0))
	check(r1 == base, "depth 1 roster: the six base kinds")
	check(r5.has("penitent") and r5.has("moth") and not r5.has("templar"), "depth 5 adds penitent / deacon / acolyte / wraith / moth")
	check(r10.has("templar") and r10.has("plague_doctor") and not r10.has("golem"), "depth 10 adds templar / censer / gargoyle / seraph / plague doctor / flagellant")
	check(r15.has("golem") and r15.has("drowned_sexton") and r15.size() == 24, "depth 15 adds the Cinder and Fen kinds (24 kinds)")
	var w1 := _w(DmSimDepthsRules.depth_roster(1.0), "rat")
	check(w1 == 30.0 and _w(DmSimDepthsRules.depth_roster(5.0), "rat") == 18.0 and _w(DmSimDepthsRules.depth_roster(15.0), "rat") == 6.0 and _w(DmSimDepthsRules.depth_roster(40.0), "hound") >= 3.0, "base kinds fade 40% per band after the first (30 -> 18 -> ... never under 3)")
	var run := DmDepthsRun.create(7, 1)
	check(run.enemy_level(1.0) == 13.0 and run.enemy_level(30.0) == 31.0, "enemy level: max(12, hero) + depth (1: 13 for a level-1 hero, 31 for level 30)")
	run.depth = 9
	check(run.enemy_level(1.0) == 21.0, "enemy level rises by one per depth (9 -> 21)")
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	run = DmDepthsRun.create(11, 1)
	var f: Dictionary = run.floor_data
	var hero_at := Vector2(float(f["start"]["x"]), float(f["start"]["z"]))
	check(run.plan_wave(0.5, 0, 0, [hero_at], rng, 0.06).is_empty(), "no wave before the first-wave delay")
	var orders := run.plan_wave(1.0, 0, 0, [hero_at], rng, 0.06)
	check(orders.size() == 8, "the first wave is 8 (%d)" % orders.size())
	var in_hero_room := orders.any(func(o: Dictionary) -> bool: return DmDepthsFloor.room_at(f, float(o["x"]), float(o["z"])) == DmDepthsFloor.room_at(f, hero_at.x, hero_at.y))
	check(not in_hero_room or f["breaches"].size() == 0, "waves climb out of other rooms than the hero's")
	check(orders.all(func(o: Dictionary) -> bool: return base.has(String(o["def"]))), "depth-1 waves draw only from the depth-1 roster")
	check(run.plan_wave(0.1, 8, 8, [hero_at], rng, 0.06).is_empty() and run.wave_t > 3.0, "the next wave waits out the gap (%.2f s)" % run.wave_t)
	run.wave_t = 0.0
	check(run.plan_wave(0.1, 8, 8, [hero_at], rng, 0.06).size() == 2, "only as many as the quota still needs (10 - 8 alive = 2)")
	run.wave_t = 0.0
	check(run.plan_wave(0.1, 24, 24, [hero_at], rng, 0.06).is_empty(), "never more than the cap alive")
	# every kind of every band is on the core (a band that gained a kind the core lacks would fail here): the rosters are today's, kind for kind and weight for weight
	var whole := true
	for depth in [1, 4, 5, 9, 10, 14, 15, 30, 60]:
		for e: Dictionary in DmSimDepthsRules.depth_roster(float(depth)):
			whole = whole and DmWaveDirector.runs_on_core(String(e["id"]))
	check(whole, "every kind on every depth's roster is a kind the core runs, so the rosters are today's")
	run = DmDepthsRun.create(11, 15)
	var seen := {}
	var start15 := Vector2(float(run.floor_data["start"]["x"]), float(run.floor_data["start"]["z"]))
	for i in 150:
		run.wave_t = 0.0
		run.waved = false
		run.floor_t = 100.0
		for o: Dictionary in run.plan_wave(0.1, 0, 0, [start15], rng, 0.06):
			seen[String(o["def"])] = true
	check(seen.size() == DmSimDepthsRules.depth_roster(15.0).size(), "150 waves on depth 15 draw all %d kinds of its roster (%d seen)" % [DmSimDepthsRules.depth_roster(15.0).size(), seen.size()])
	run = DmDepthsRun.create(11, 1)
	var opened := 0
	for i in 12:
		if run.record_kill():
			opened += 1
	check(opened == 1 and run.stair_open and run.floors == 1 and run.total_kills == 12, "the 10th kill opens the stair, once")
	run.descend()
	check(run.depth == 2 and run.peak == 2 and run.kills == 0 and not run.stair_open and run.need == 11.0 and run.total_kills == 12, "descending: depth 2, quota 11, the totals carry")
	check(run.summary() == "The descent ends at depth 2 · 12 slain · 1 floor cleared. What you looted is yours.", "the summary line")
	var areas: Array = []
	for depth in [1, 4, 5, 9, 10, 14, 15, 19, 20, 29, 30, 60]:
		areas.append(DmDepthsRewards.depth_loot_area(float(depth)))
	check(areas == ["ossuary", "ossuary", "coliseum", "coliseum", "sanctum", "sanctum", "cloister", "cloister", "pyre", "pyre", "fen", "fen"], "loot ground by depth: ossuary / coliseum / sanctum / cloister / pyre / fen at 1 / 5 / 10 / 15 / 20 / 30")


# ---- B: the world ----------------------------------------------------------------------------------------------------------------

func _b_world() -> void:
	check(d != null and d.ground != null and g.chapterhouse != null and d.get_parent() == g, "the game has its Depths node (host)")
	var rect: Dictionary = DmContent.area("depths")["rect"]
	var b := g.world.bounds(0.0)
	check(b.position.x <= float(rect["x0"]) and b.end.x >= float(rect["x1"]) and b.position.y <= float(rect["z0"]) and b.end.y >= float(rect["z1"]), "the core's bounds cover the Depths' rect (%s)" % str(b))
	var mid := Vector3((float(rect["x0"]) + float(rect["x1"])) * 0.5, 0.0, (float(rect["z0"]) + float(rect["z1"])) * 0.5)
	check(g.world.area_at(mid.x, mid.z) == "" and not g.world.loaded.has("depths") and g.world.area_rect("depths") == rect, "the Depths' rect is no area until a run opens it (and no scene is loaded for it)")
	var tri0: int = g.core_host.core.nav_triangle_count()
	check(g.core_host.core.nav_closest(mid).distance_to(mid) > 20.0, "the core keeps a body off the Depths' rect before a run (no ground there)")
	check(not d.active() and d.hud_state() == null and d.map_floor() == null and d.progress_line() == "" and not d.ground.region.enabled, "no run, no readout, no floor")
	check(not d.is_physics_processing() and not g.core_host.enemy_died.is_connected(d._on_enemy_died), "nothing of the Depths runs per frame or hears the core outside a run")
	var stair: Node3D = g.world.area_node("warren").get_node_or_null("WarrenStair")
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	check(stair != null and Vector2(stair.position.x - float(s["x"]), stair.position.z - float(s["z"])).length() < 0.01, "the Warren has its stair")
	check(g.chapterhouse.interactables.any(func(it: Dictionary) -> bool: return it["id"] == "depths_stair" and it["kind"] == "stair"), "the hub lists the Warren's stair")
	check(g.rewards.loot_area_of.is_valid() and g.rewards.loot_area_of.call("depths") == null, "the rewards ask the Depths for the loot ground (none outside a run)")
	print("INFO depths: %d navmesh triangles before a run" % tri0)


# ---- C: the way in ---------------------------------------------------------------------------------------------------------------

func _c_way_in() -> void:
	g.progress.prog.unlock("warren")
	g.chapterhouse.apply_seals()
	await ticks(5)
	g.chapterhouse.travel("warren")
	await ticks(10)
	check(g.area_of(1) == "warren", "waystone travel takes the hero into the (open) Warren")
	var stair := _it("depths_stair")
	var to := Vector3(float(stair["x"]), 0.0, float(stair["z"]) + 1.4)
	var hold := [PackedVector3Array()]
	await until(func() -> bool:   # the navigation server merges the opened Warren on its own thread, a few frames later
		hold[0] = g.world.nav_path(hero.position, to)
		return hold[0].size() > 1 and Vector2(hold[0][-1].x - to.x, hold[0][-1].z - to.z).length() < 1.0, 600)
	var dist0 := Vector2(hero.position.x - float(stair["x"]), hero.position.z - float(stair["z"])).length()
	check(dist0 > 10.0 and not d.active(), "the stair is across the Warren, no run yet (%.0f m)" % dist0)
	check(d.prompt(stair).begins_with("Descend into the Catacomb Depths") and g.chapterhouse.interact_prompt(stair) == d.prompt(stair), "the stair's prompt: " + d.prompt(stair))
	g.chapterhouse.hover = stair   # the cursor on the stair: the hub's prompt reaches the HUD
	await ticks(12)
	check(g.chapterhouse.prompt_text == "<kbd>Click</kbd> " + d.prompt(stair) and g.ui_host.vm.build()["prompt"] == g.chapterhouse.prompt_text, "the HUD shows the hub's prompt for the stair (%s)" % str(g.chapterhouse.prompt_text))
	g.chapterhouse.hover = null
	var tri_before: int = g.core_host.core.nav_triangle_count()
	tri_base = tri_before
	var thrall := _raise_thrall(hero.position + Vector3(2.0, 0.0, 0.0))
	check(thrall > 0, "a thrall walks with the hero")
	var entered := [0]
	d.floor_loaded.connect(func(_dp: int) -> void: entered[0] += 1)
	events.clear()
	seed(20261017)   # the run's seed is the global stream's next number: the same floors on every run of this test
	g.chapterhouse.click_interactable(stair)   # what a click on it does: walk there, use it on arrival
	var walked := await until(func() -> bool: return d.run != null, 60 * 40)
	check(walked, "clicking the stair walks the hero to it and starts a run (at %s, %.1f m from it; pending %s)" % [str(hero.position), Vector2(hero.position.x - float(stair["x"]), hero.position.z - float(stair["z"])).length(), str(g.chapterhouse.pending)])
	check(not ev("depths_stair_near").is_empty(), "walking up to the stair, the game says it is near (depths_stair_near, %d)" % ev("depths_stair_near").size())
	var loaded := await until(func() -> bool: return entered[0] == 1 and not d._busy, 60 * 20)
	check(loaded, "floor 1 stands (floor_loaded once)")
	await ticks(2)
	var run := d.run
	var f: Dictionary = run.floor_data
	check(run.depth == 1 and _floor_json(f) == _floor_json(DmDepthsRun.generate(run.seed, 1)), "floor 1 is the generated floor of the run's seed")
	check(Vector2(hero.position.x - float(f["start"]["x"]), hero.position.z - float(f["start"]["z"])).length() < 0.5 and g.area_of(1) == "depths" and g.area_id == "depths",
		"the hero stands at the floor's way in, in the Depths (the game's area follows: music, ambience, light)")
	check(g.world.builder.current_area == "depths" and g.world.depths_open, "the lighting follows him: the Depths' ambient")
	var c := hero.get_node("Rites") as DmRiteCaster
	check(thrall > 0 and c.thralls().near(hero.position, 3.0).has(thrall), "his thrall came down with him")
	var root3d: Node = g.world.builder._depths_floor_root
	check(root3d != null and is_instance_valid(root3d) and root3d.get_child_count() > 10, "the floor is drawn (the existing look)")
	var lights := root3d.find_children("*", "OmniLight3D", true, false)
	check(g.world.depths_root.is_ancestor_of(root3d) and not lights.is_empty() and lights.all(func(l: Node) -> bool: return (l as Light3D).visible), "...in the world's Depths node, with its prop lights on (%d)" % lights.size())
	check(not root3d.find_children("*", "MultiMeshInstance3D", true, false).is_empty() and not root3d.find_children("*", "MeshInstance3D", true, false).is_empty(), "...walls, floors and prop batches")
	check(g.world.builder._depths_stair_mat != null and g.world.builder._depths_stair_mat.emission_energy_multiplier < 0.5, "the stair down glows dim while it is sealed")
	var its := g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths")
	check(its.size() == 2 and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_down") and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_up"), "the floor's stairs are clickable things (no chest on depth 1)")
	check(d.prompt(_it("depths_down")).begins_with("The stair is sealed: slay 10 more") and d.prompt(_it("depths_up")) == "Climb out (ends this run at depth 1)", "stair prompts: sealed with the count, the way up")
	var banner := ev("banner").filter(func(e: Array) -> bool: return String(e[1]["title"]) == "Depth 1")
	check(not banner.is_empty() and String(banner[0][1]["sub"]).find("slay 10") >= 0 and String(banner[0][1]["sub"]).find("level 13 dead") >= 0, "the arrival banner names the quota and the dead's level")
	check(d.hud_state() == {"depth": 1, "kills": 0, "need": 10, "open": false, "chest": false}, "HUD readout: depth 1, 0 / 10, sealed, no chest")
	var mf: Variant = d.map_floor()
	check(mf != null and mf["rooms"].size() >= 4 and not mf["down"]["open"] and mf["chest"] == null, "the minimap draws the floor's rooms")
	await ticks(12)   # the HUD refreshes at 20 Hz
	var vm: Dictionary = g.ui_host.vm.build()
	check(vm["depth"] != null and int(vm["depth"]["need"]) == 10 and vm["minimap"]["depths"] != null and String(vm["area_progress"]) == "Level <b>13</b> dead", "the HUD view-model carries the Depths readout, the map and the area line (%s)" % str(vm["area_progress"]))
	# the navmesh: baked, on the navigation map, and the core's own copy of it
	var core: RefCounted = g.core_host.core
	check(d.ground.region.enabled and d.ground.region.navigation_mesh.get_polygon_count() > 20, "the floor's navmesh is baked (%d polygons) and on the region" % d.ground.region.navigation_mesh.get_polygon_count())
	var tri_run: int = core.nav_triangle_count()
	check(tri_run > tri_before and tri_run - tri_before == _triangles(d.ground.region.navigation_mesh), "the core holds the floor's triangles (%d + %d)" % [tri_before, tri_run - tri_before])
	var start := Vector3(float(f["start"]["x"]), 0.0, float(f["start"]["z"]))
	check(core.nav_closest(start).distance_to(start) < 0.05, "the core keeps the way in walkable")
	var inside_wall := _wall_point(f)
	check(inside_wall != Vector3.INF and core.nav_closest(inside_wall).distance_to(inside_wall) > 0.2 and g.world.nav_clamp(inside_wall).distance_to(inside_wall) > 0.2, "...and moves a point inside a wall onto the ground (%s)" % str(inside_wall))
	var map := g.world.nav_map()
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var rect: Dictionary = DmContent.area("depths")["rect"]
	var worst := 0.0
	for i in 600:
		var p := Vector3(rng.randf_range(float(rect["x0"]), float(rect["x1"])), 0.0, rng.randf_range(float(rect["z0"]), float(rect["z1"])))
		var a := NavigationServer3D.map_get_closest_point(map, p)
		var q: Vector3 = core.nav_closest(p)
		worst = maxf(worst, Vector2(a.x - q.x, a.z - q.z).length())
	check(worst < 0.01, "the core's closest point is the navigation server's at 600 points of the floor (worst %.5f m)" % worst)
	check(_reachable(f), "navmesh: the stair down, the way up and the breaches are reachable from the way in")
	print("INFO depths: floor 1: main thread %d ms (bake %d ms on the worker, the whole load %d ms); %d triangles in the core" % [d.ground.build_ms, d.ground.bake_ms, d.ground.nav_ms, tri_run])
	check(d.is_physics_processing() and g.core_host.enemy_died.is_connected(d._on_enemy_died), "the run's tick and its ears are on")
	check(d.can_enter() == "You are already below." and not await d.enter(1), "a second run cannot start inside a run")
	check(d.ground.async_ok, "the navmesh was baked by the worker thread (not the main thread's fallback)")


## A thrall of the hero's legion at `at` (a corpse laid there and raised): its core id, 0 when the rite refused.
func _raise_thrall(at: Vector3) -> int:
	var c := hero.get_node("Rites") as DmRiteCaster
	g.core_host.corpses.add_corpse(at.x, at.z, "normal", "robber", false, 0.0, 1.0, g.area_of(1))
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var raised: Dictionary = c.thralls().raise(ex, at)
	return int((raised["thralls"] as Array)[0]) if bool(raised["ok"]) else 0


func _triangles(nm: NavigationMesh) -> int:
	var n := 0
	for i in nm.get_polygon_count():
		n += nm.get_polygon(i).size() - 2
	return n


## A point inside one of the floor's wall boxes (a wall is not ground).
func _wall_point(f: Dictionary) -> Vector3:
	for w in f["walls"]:
		var o := DmDepthsFloor.wall_obstacle(w)
		if o.x1 - o.x0 > 0.3 and o.z1 - o.z0 > 0.3:
			return Vector3((o.x0 + o.x1) * 0.5, 0.0, (o.z0 + o.z1) * 0.5)
	return Vector3.INF


func _reachable(f: Dictionary) -> bool:
	var from := Vector3(float(f["start"]["x"]), 0.0, float(f["start"]["z"]))
	var targets: Array = [f["stairDown"], f["stairUp"]]
	for br in f["breaches"]:
		targets.append(br)
	if f["chest"] != null:
		targets.append(f["chest"])
	for t in targets:
		var to := Vector3(float(t["x"]), 0.0, float(t["z"]))
		var p := g.world.nav_path(from, to)
		if p.size() < 2 or Vector2(p[p.size() - 1].x - to.x, p[p.size() - 1].z - to.z).length() > 2.0:
			return false
	return true


# ---- D: the dead -----------------------------------------------------------------------------------------------------------------

func _d_the_dead() -> void:
	var core: RefCounted = g.core_host.core
	var run := d.run
	check(await until(func() -> bool: return _depths_enemies().size() >= 8, 60 * 8), "the floor's first wave climbs out (8)")
	var es := _depths_enemies()
	var base := ["rat", "robber", "ghoul", "bat", "sac", "hound"]
	var rect: Dictionary = DmContent.area("depths")["rect"]
	var hp_mult := DmEnemyStats.hp_scale(13.0) * float(DmContent.difficulty(g.director.difficulty)["enemyHpMult"])
	var lvl_ok := true
	var hp_ok := true
	var kind_ok := true
	var pos_ok := true
	var nav_ok := true
	var aggro_ok := true
	for info: Dictionary in es:
		var at: Vector2 = info["pos"]
		lvl_ok = lvl_ok and int(info["level"]) == 13
		hp_ok = hp_ok and (bool(info["elite"]) or is_equal_approx(float(info["max_hp"]), float(DmSimData.ENEMIES[String(info["def"])]["hp"]) * hp_mult))
		kind_ok = kind_ok and base.has(String(info["def"])) and String(info["area"]) == "depths"
		pos_ok = pos_ok and at.x > float(rect["x0"]) and at.x < float(rect["x1"]) and at.y > float(rect["z0"]) and at.y < float(rect["z1"])
		nav_ok = nav_ok and core.nav_closest(Vector3(at.x, 0.0, at.y)).distance_to(Vector3(at.x, 0.0, at.y)) < 0.3
		aggro_ok = aggro_ok and float(info["aggro"]) == DmSimConsts.DEPTHS_AGGRO and float(info["leash"]) == 90.0
	check(lvl_ok and hp_ok, "the dead are level 13 on depth 1 (hp x%.2f, the director's scaling)" % hp_mult)
	check(kind_ok and pos_ok and nav_ok, "kinds from the depth roster, in the Depths' area, standing on the floor's ground")
	check(aggro_ok, "hunters notice the hero across the floor: aggro 36 and leash 90 on their bodies in the core")
	check(d._living.size() == es.size() and _depths_enemies().size() <= int(DmSimData.DEPTHS["cap"]), "the Depths know their living bodies, and never more than the cap alive")
	# they hunt the hero through the doors and hit him
	var near := await until(func() -> bool:
		return _depths_enemies().any(func(info: Dictionary) -> bool: return (info["pos"] as Vector2).distance_to(Vector2(hero.position.x, hero.position.z)) < 4.0), 60 * 30)
	check(near, "the dead find their way to the hero across the floor's rooms")
	var strayed := _depths_enemies().filter(func(info: Dictionary) -> bool:
		var at := Vector3((info["pos"] as Vector2).x, 0.0, (info["pos"] as Vector2).y)
		return core.nav_closest(at).distance_to(at) > 0.3)
	check(strayed.is_empty(), "the hunters stay on the floor's ground as they walk (%d off it)" % strayed.size())
	var hit := await until(func() -> bool: return g.hits_taken.values().reduce(func(a: int, b: int) -> int: return a + b, 0) > 0, 60 * 20)
	check(hit, "and fight back (%s)" % str(g.hits_taken))
	# an elite on depth 15 carries the depth's extra affixes, at level 12 + 15
	var affixes := PackedStringArray([DmSimData.AFFIX_ORDER[0], DmSimData.AFFIX_ORDER[1], DmSimData.AFFIX_ORDER[2], DmSimData.AFFIX_ORDER[3]])
	var el: int = g.director.spawn("robber", hero.position + Vector3(2, 0, 0), [hero], true, {}, {"area": "depths", "depth": 15, "aggro": 36.0, "leash": 90.0, "affix_list": affixes})
	var info: Dictionary = core.enemy_info(el)
	check(el > 0 and bool(info["elite"]) and (info["affixes"] as PackedStringArray).size() == 4 and int(info["level"]) == 27, "an elite on depth 15 bears 4 affixes at level 27 (12 + 15)")
	core.remove_enemy(el)
	await ticks(3)
	check(run.kills == 0, "nothing was killed yet: the quota is untouched")
	# a kill on the floor lays a corpse in the Depths' area, and Exhume raises a thrall from it (the core's field and legion, the area following the hero)
	var vat: Vector3 = core.nav_closest(hero.position + Vector3(4.0, 0.0, 0.0))
	var victim: Dictionary = core.enemy_info(g.core_host.spawn_enemy("robber", vat, 13, 1.0, 1.0, false, "depths", false))
	var killed := bool(g.core_host.damage(int(victim["id"]), 1.0e9, hero.core_id, false)["killed"])
	var corpses: Array = g.corpses.corpses_in_radius(vat, 1.0, Callable(), "depths")
	check(killed and corpses.size() == 1 and corpses[0].area == "depths", "a kill on the floor lays a corpse in the Depths' area (%s: killed %s, %d corpses, state %d)" % [str(victim["def"]), str(killed), corpses.size(), int(victim["state"])])
	var c := hero.get_node("Rites") as DmRiteCaster
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var raised: Dictionary = c.thralls().raise(ex, vat)
	check(bool(raised["ok"]) and g.corpses.corpses_in_radius(vat, 1.0, Callable(), "depths").is_empty(), "the legion raises a thrall from it, in the Depths (%s)" % str(raised.get("why", "")))


# ---- E: the quota ----------------------------------------------------------------------------------------------------------------

func _e_quota() -> void:
	var run := d.run
	var gold0 := int(character["gold"])
	var xp0 := int(character["experience"])
	var lvl0 := int(character["level"])
	events.clear()
	var cleared := [0]
	d.floor_cleared.connect(func(_dp: int) -> void: cleared[0] += 1)
	check(not await d.descend() and ev("toast").any(func(e: Array) -> bool: return String(e[1]["text"]).begins_with("The stair is sealed: slay")), "the stair is sealed until the quota (refused with the count)")
	var credited := []
	g.kill_credited.connect(func(id: int, _d: String, _l: int, _e: bool, a: String, peer: int, _x: float, _z: float) -> void: credited.append([id, a, peer]))
	check(await _clear_floor(), "killing the quota opens the stair (%d / %d)" % [run.kills, int(run.need)])
	await ticks(5)
	check(run.stair_open and cleared[0] == 1 and run.floors == 1 and run.kills >= 10, "the stair opens once, at the 10th kill (kills %d)" % run.kills)
	check(credited.size() >= 10 and credited.all(func(c: Array) -> bool: return c[1] == "depths" and int(c[2]) == g.session.get_my_id()), "each kill was credited once, to the hero, in the Depths (%d)" % credited.size())
	check(d.prompt(_it("depths_down")) == "Descend to depth 2" and d.hud_state()["open"] and d.map_floor()["down"]["open"], "the stair's prompt, the HUD and the minimap show it open")
	check(g.world.builder._depths_stair_mat.emission_energy_multiplier > 1.0, "the stair down glows bright once open")
	check(ev("banner").any(func(e: Array) -> bool: return String(e[1]["title"]) == "The stair opens"), "a banner says so")
	check(await until(func() -> bool: return int(character["gold"]) > gold0 or m.loot_view.count() > 0, 60 * 5), "kills and the floor clear pay gold")
	check(int(character["experience"]) > xp0 or int(character["level"]) > lvl0, "XP was earned (floor clear + kills)")
	await until(func() -> bool: return not g.progress.psync.reporter.has_pending(), 60 * 5)
	check(not g.progress.psync.reporter.has_pending(), "the floor report was sent and acknowledged by the backend")
	await g.rewards.flush()
	check(int(m.stats["kills_earned"]) >= 10 and g.progress.prog.kills("depths") == 0, "kills are paid and reported, but do not count towards an area seal")
	check(String(g.rewards.loot_area_of.call("depths")) == DmDepthsRewards.depth_loot_area(1.0) and g.rewards.loot_area_of.call("graves") == null, "loot of a depth-1 kill rolls from the Ossuary's table")
	var floor_drops: Array = m.loot_view._drops.filter(func(x: Dictionary) -> bool: return (x["item"] as Dictionary).has("claim") and String(x["item"]["claim"]["kind"]) == "floor")
	print("INFO depths: the floor clear's item from the tape: %s" % ("yes" if not floor_drops.is_empty() else "none this time"))
	check(m.loot_view._drops.size() > 0 or int(character["gold"]) > gold0, "something lies on the ground or in the purse")


# ---- F: descending ---------------------------------------------------------------------------------------------------------------

func _f_descend() -> void:
	var core: RefCounted = g.core_host.core
	var run := d.run
	var f1 := _floor_json(run.floor_data)
	var seed := run.seed
	var rect: Dictionary = DmContent.area("depths")["rect"]
	var mid := Vector3((float(rect["x0"]) + float(rect["x1"])) * 0.5, 0.0, (float(rect["z0"]) + float(rect["z1"])) * 0.5)
	var old_living: Array = d._living.keys()
	var corpses1: int = g.corpses.corpses_in_radius(mid, 40.0, Callable(), "depths").size()
	check(corpses1 > 0, "floor 1's dead left corpses (%d)" % corpses1)
	var loaded := [0]
	d.floor_loaded.connect(func(_dp: int) -> void: loaded[0] += 1)
	var far_thrall := _raise_thrall(hero.position + Vector3(0.0, 0.0, 9.0))
	worst_us = 0
	d.descend()
	check(await until(func() -> bool: return loaded[0] == 1, 60 * 20), "clicking the open stair builds floor 2")
	await ticks(3)
	print("INFO depths: the descent to floor 2: the longest frame in it %.0f ms" % (float(worst_us) / 1000.0))
	check(run.depth == 2 and run.peak == 2 and _floor_json(run.floor_data) == _floor_json(DmDepthsRun.generate(seed, 2)) and _floor_json(run.floor_data) != f1, "depth 2: the next floor of the same run seed")
	check(run.kills == 0 and not run.stair_open and run.need == 11.0 and d.hud_state()["need"] == 11, "a new quota (11) and a sealed stair")
	check(old_living.all(func(id: int) -> bool: return core.enemy_info(id).is_empty()) and _depths_enemies().all(func(info: Dictionary) -> bool: return not old_living.has(int(info["id"]))), "the last floor's living dead are out of the core (%d)" % old_living.size())
	check(g.corpses.corpses_in_radius(mid, 40.0, Callable(), "depths").is_empty(), "the last floor's corpses are gone")
	var f: Dictionary = run.floor_data
	check(Vector2(hero.position.x - float(f["start"]["x"]), hero.position.z - float(f["start"]["z"])).length() < 0.5, "the hero stands at floor 2's way in")
	check(far_thrall > 0 and (hero.get_node("Rites") as DmRiteCaster).thralls().near(hero.position, 3.5).has(far_thrall), "a thrall 9 m away came with him (recalled)")
	check(g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths").size() == 2, "the floor's interactables were replaced, not stacked")
	var tri2: int = core.nav_triangle_count()
	check(tri2 - tri_base == _triangles(d.ground.region.navigation_mesh), "the core's navmesh was replaced, not added to (%d + %d triangles)" % [tri_base, tri2 - tri_base])
	check(_reachable(f), "navmesh of floor 2: stair down, way up and breaches reachable")
	check(await until(func() -> bool: return _depths_enemies().size() >= 2, 60 * 8) and _depths_enemies().all(func(info: Dictionary) -> bool: return int(info["level"]) == 14), "floor 2's dead are level 14")
	# floor 3: the real way, a click on the open stair walks the hero across the floor's rooms on the core's navmesh and takes it
	check(await _clear_floor(), "floor 2 quota met")
	var down := _it("depths_down")
	var from_start := hero.position
	var stair_at := Vector3(float(f["stairDown"]["x"]), 0.0, float(f["stairDown"]["z"]))
	g.chapterhouse.click_interactable(down)
	check(await until(func() -> bool: return run.depth == 3 and not d._busy, 60 * 60), "a click on the open stair walks the hero to it and descends (he walked %.0f m, from %s)" % [from_start.distance_to(stair_at), str(from_start)])
	await ticks(3)
	check(run.depth == 3 and run.peak == 3 and core.nav_triangle_count() - tri_base == _triangles(d.ground.region.navigation_mesh), "descended to depth 3, the core holds this floor's triangles only")
	# floor 4
	for target in [4]:
		check(await _clear_floor(), "floor %d quota met" % (target - 1))
		await d.descend()
		await ticks(3)
		check(run.depth == target and run.peak == target and core.nav_triangle_count() - tri_base == _triangles(d.ground.region.navigation_mesh), "descended to depth %d, the core holds this floor's triangles only" % target)
	check(d.hud_state()["chest"] == false, "no chest on depth 4")
	print("INFO depths: floor 2: main thread %d ms, bake %d ms on the worker, the whole load %d ms" % [d.ground.build_ms, d.ground.bake_ms, d.ground.nav_ms])


# ---- G: the chest ----------------------------------------------------------------------------------------------------------------

func _g_chest() -> void:
	var run := d.run
	check(await _clear_floor(), "floor 4 cleared")
	await d.descend()
	await ticks(3)
	check(run.depth == 5 and run.floor_data["chest"] != null, "depth 5 has a chest")
	var its := g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths")
	check(its.size() == 3 and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_chest"), "the chest is a clickable thing")
	check(d.hud_state()["chest"] and d.map_floor()["chest"] != null and d.prompt(_it("depths_chest")) == "Open the chest", "HUD and minimap show the chest")
	check(String(g.rewards.loot_area_of.call("depths")) == "coliseum", "depth 5 loots from the Coliseum")
	check(d.progress_line().ends_with(" · elites bear <b>2</b> affixes") and d.progress_line().begins_with("Level <b>%d</b> dead" % int(run.enemy_level(float(character["level"])))), "the area line names the level and the affixes an elite bears (%s)" % d.progress_line())
	var drops0: int = m.loot_view._drops.size()
	var dropped: Array = []
	g.rewards.loot_dropped.connect(func(_cid: int, dr: Dictionary, _at: Vector3) -> void: dropped.append(dr))
	var opened := [0]
	d.chest_opened.connect(func(_dp: int) -> void: opened[0] += 1)
	events.clear()
	check(d.open_chest() and opened[0] == 1, "opening the chest")
	await until(func() -> bool: return g.rewards.gear_pending() == 0, 60 * 5)
	await ticks(3)
	check(m.loot_view._drops.size() >= drops0 + 2, "the chest drops its finds (gear first) on the ground (%d -> %d)" % [drops0, m.loot_view._drops.size()])
	var found: Array = m.loot_view._drops.filter(func(x: Dictionary) -> bool: return (x["item"] as Dictionary).has("claim") and String(x["item"]["claim"]["kind"]) == "chest")
	var first_id := String(dropped[0].get("item_id", "")) if not dropped.is_empty() else ""
	check(not found.is_empty() and found.size() == dropped.size() and DmAffixRules.is_affix_gear(String(DmLootData.item(first_id).get("type", ""))),
		"the chest's finds (the first is always gear; some of the rest turn to gold) are tape drops, claimed on pickup (%d: %s)" % [found.size(), str(dropped.map(func(dr: Dictionary) -> String: return String(dr.get("item_id", "?"))))])
	check(not d.open_chest() and d.chest_done and not d.hud_state()["chest"] and _it("depths_chest").is_empty() and d.map_floor()["chest"] == null, "a chest opens once; it leaves the HUD, the map and the clickables")
	check(ev("banner").any(func(e: Array) -> bool: return String(e[1]["title"]) == "The chest opens"), "a banner reports the chest")
	check(DmDepthsRewards.chest_drops(5.0) == 3 and DmDepthsRewards.chest_drops(15.0) == 4 and DmDepthsRewards.chest_drops(4.0) == 3, "chest size: 3 at depth 5, one more every ten floors")
	# the server's side: a click on a find walks the hero to it and the server puts its own roll in the bag
	if not found.is_empty():
		var x: Dictionary = found[0]
		var item: Dictionary = x["item"]
		var bag0 := _count_of(String(item["claim"]["expect"]))
		var at: Vector3 = (x["node"] as Node3D).global_position + Vector3(0, 0.7, 0)
		check(g.loot.loot_click(g.camera.unproject_position(at)), "a click on a find picks it (the input's path)")
		var k := 0
		while m.loot_view._drops.has(x) and k < 600:
			await process_frame
			k += 1
		check(not m.loot_view._drops.has(x), "the click and the walk claim the find (%d frames)" % k)
		check(_count_of(String(item["claim"]["expect"])) > bag0, "the server's roll of %s is in the bag" % String(item["claim"]["expect"]))
	var life: Dictionary = d.chronicle.view()["life"]
	check(float(life.get("depths.floors", 0.0)) >= 4.0 and float(life.get("depths.chests", 0.0)) == 1.0 and float(life.get("peak.depth", 0.0)) == 5.0, "the chronicle counts floors (%d), the chest and the deepest floor" % int(life.get("depths.floors", 0.0)))


func _count_of(item_id: String) -> int:
	var n := 0
	for r: Dictionary in g.loot.slots():
		if String(r.get("item_id", "")) == item_id:
			n += int(r.get("quantity", 1))
	return n


# ---- H: leaving ------------------------------------------------------------------------------------------------------------------

func _h_leaving() -> void:
	var core: RefCounted = g.core_host.core
	var run := d.run
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	var rect: Dictionary = DmContent.area("depths")["rect"]
	var mid := Vector3((float(rect["x0"]) + float(rect["x1"])) * 0.5, 0.0, (float(rect["z0"]) + float(rect["z1"])) * 0.5)
	var ended: Array = []
	d.run_ended.connect(func(why: String, note: String) -> void: ended.append([why, note]))
	events.clear()
	check(not d.leave() and d.run != null and ev("toast").any(func(e: Array) -> bool: return String(e[1]["text"]).begins_with("Climbing out ends this run at depth 5")), "the exit asks twice (the first click only warns)")
	check(d.leave() and d.run == null, "the second click ends the run")
	await ticks(3)
	check(ended.size() == 1 and ended[0][0] == "left" and String(ended[0][1]).begins_with("The descent ends at depth 5"), "run_ended(left) with the summary")
	check(Vector2(hero.position.x - float(s["x"]), hero.position.z - (float(s["z"]) + 2.3)).length() < 0.5 and g.area_of(1) == "warren", "back at the Warren's stair")
	check(g.world.builder._depths_floor_root == null or not is_instance_valid(g.world.builder._depths_floor_root), "the floor's picture is torn down")
	check(not d.ground.region.enabled and core.nav_triangle_count() == tri_base, "the floor's navmesh region is off and out of the core (%d triangles, as before the run)" % core.nav_triangle_count())
	check(g.world.area_at(mid.x, mid.z) == "" and core.nav_closest(mid).distance_to(mid) > 20.0, "the Depths are no area again, and no ground for the core")
	check(_depths_enemies().is_empty() and d._living.is_empty() and g.chapterhouse.interactables.all(func(it: Dictionary) -> bool: return String(it["area"]) != "depths"), "no living dead and no stairs are left behind")
	check(d.hud_state() == null and d.map_floor() == null, "the Depths readout is gone")
	# the record: the deepest floor persists on the chronicle (backend)
	await d.flush()
	var ch: DmResult = await api.get_chronicle(int(character["id"]))
	check(ch.ok and float(ch.data["life"].get("peak.depth", 0.0)) == 5.0 and float(ch.data["life"].get("depths.runs", 0.0)) == 1.0, "the backend's chronicle records peak depth 5 and the run")
	check(d.resume_at() == 5, "the stair now offers to resume at depth 5")
	var stair := _it("depths_stair")
	events.clear()
	check(d.stair_clicked() == 5 and ev("depths_stair_offer").size() == 1 and int(ev("depths_stair_offer")[0][1]["deepest"]) == 5 and not d.active(), "the stair offers 'start at 1' or 'resume at 5'")
	check(d.prompt(stair).find("resume at depth 5") >= 0, "the stair's prompt names the resume depth")
	g.ui_host.enter_depths(5)   # what the card's Resume does
	await until(func() -> bool: return d.run != null and not d._busy, 60 * 20)
	await ticks(2)
	check(d.run != null and d.run.depth == 5 and d.run.peak == 5 and d.run.floors == 0 and d.run.floor_data["chest"] != null, "resume: a new run starts at depth 5 (a fifth floor, so a chest waits)")
	check(d.run.enemy_level(1.0) == 17.0, "its dead are level 17 (12 + 5)")
	# a second player ends it: the Depths are a solo descent
	ended.clear()
	events.clear()
	g.session._roster[7] = {"peer_id": 7, "name": "friend", "discipline": "gravecaller"}
	check(d.can_enter() == "The Depths are a solo descent: your party must stay behind.", "a run is solo: the stair refuses a party of two")
	check(g._joiner_spawn() == null, "a player joining while the host is below appears at the origin, not beside him")
	d._on_player_joined(7)
	await ticks(3)
	check(d.run == null and ended.size() == 1 and ended[0][0] == "party" and ev("toast").any(func(e: Array) -> bool: return String(e[1]["text"]).begins_with("A friend appeared on the descent")), "a second player ends the run (party) and the host climbs out")
	check(g.area_of(1) == "warren" and d.can_enter() == "The Depths are a solo descent: your party must stay behind.", "...and the stair refuses while the party is two")
	g.session._roster.erase(7)
	check(d.can_enter() == "" and g._joiner_spawn() != null, "alone again, the stair works")
	# recall (T) out of a run ends it
	await d.enter(3, 99)
	await ticks(2)
	ended.clear()
	check(d.run != null and g.area_of(1) == "depths", "a new run is on (depth 3)")
	g.chapterhouse.finish_recall()
	await until(func() -> bool: return d.run == null, 60 * 3)
	check(d.run == null and ended.size() == 1 and ended[0][0] == "recalled" and g.area_of(1) == "chapterhouse", "recall to the Chapterhouse ends the run (recalled)")
	check(_depths_enemies().is_empty() and core.nav_triangle_count() == tri_base, "nothing is left on the ground or in the core")


# ---- I: death --------------------------------------------------------------------------------------------------------------------

func _i_death() -> void:
	var core: RefCounted = g.core_host.core
	var gold_before := int(character["gold"])
	var bag_before: int = g.loot.slots().size()
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	hero.teleport(Vector3(float(s["x"]), 0.0, float(s["z"]) + 2.0))
	await ticks(2)
	await d.enter(1, 4242)
	await ticks(2)
	await _clear_floor()
	await d.descend()
	await ticks(3)
	var run := d.run
	check(run.depth == 2 and run.floors == 1, "second run: depth 2 reached")
	var kills := run.total_kills
	var ended: Array = []
	d.run_ended.connect(func(why: String, note: String) -> void: ended.append([why, note]))
	immortal = false
	hero.p["stats"]["maxHp"] = 100.0
	hero.p["hp"] = 100.0
	hero._mirror_from_state()
	events.clear()
	hero.take_damage(1.0e9, 0, "melee")
	await ticks(3)
	check(not hero.alive and d.over and ended.size() == 1 and ended[0][0] == "died", "the hero falls: the run is over (died)")
	check(String(ended[0][1]) == "The descent ends at depth 2 · %d slain · 1 floor cleared. What you looted is yours." % kills, "the run summary: " + String(ended[0][1]))
	check(d.run != null and g.world.builder._depths_floor_root != null and d.ground.region.enabled, "the floor stays up behind the death screen")
	check(g.chapterhouse.interactables.all(func(it: Dictionary) -> bool: return String(it["area"]) != "depths") and not await d.descend() and not d.open_chest(), "no stairs or chest answer once the run is over")
	var spawned := _depths_enemies().size()
	await ticks(10 * 60 / 6)
	check(_depths_enemies().size() <= spawned, "no new waves spawn after the death")
	check(await until(func() -> bool: return d.run == null, 60 * 10), "the hero rises in the Chapterhouse and the Depths close")
	await ticks(3)
	check(hero.alive and g.area_of(1) == "chapterhouse" and g.area_id == "chapterhouse", "back in the hub, alive")
	check(ev("toast").any(func(e: Array) -> bool: return String(e[1]["text"]).begins_with("The descent ends at depth 2")), "the summary is told once more on rising")
	check(_depths_enemies().is_empty() and not d.ground.region.enabled and core.nav_triangle_count() == tri_base, "the floor, its dead and its navmesh are gone")
	check(int(character["gold"]) >= gold_before and float(d.chronicle.view()["life"].get("peak.depth", 0.0)) >= 5.0, "death takes nothing: gold kept, the best depth (5) still on record")
	check(g.loot.slots().size() >= bag_before, "death takes nothing: the bag keeps its items")
	check(int((await api.get_character()).data["level"]) >= int(character["level"]) - 1, "the character is intact on the backend")
	hero.teleport(Vector3(float(s["x"]), 0.0, float(s["z"]) + 2.0))
	immortal = true
	_harden()
	await ticks(2)
	check(d.can_enter() == "", "the stair works again after a death")


# ---- J: many floors ---------------------------------------------------------------------------------------------------------------

## A long descent leaves nothing behind: the core holds one floor's triangles, the scene's node count does not climb, every floor loads by the same path.
func _j_many_floors() -> void:
	var core: RefCounted = g.core_host.core
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	hero.teleport(Vector3(float(s["x"]), 0.0, float(s["z"]) + 2.0))
	await ticks(2)
	await d.enter(1, 777)
	await ticks(5)
	var nodes: Array = []
	var builds: Array = []
	var loads: Array = []
	var worst := 0
	var tri_ok := true
	var async_all := true
	var cells_ok := true
	var cells_max := 0
	for i in 14:
		check(await _clear_floor(), "floor %d cleared" % d.run.depth)
		worst_us = 0
		await d.descend()
		await ticks(5)
		worst = maxi(worst, worst_us)
		builds.append(d.ground.build_ms)
		loads.append(d.ground.nav_ms)
		await ticks(20)   # the builder walks its shadow cells every 0.25 s
		nodes.append(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
		var b = g.world.builder
		var root3d: Node = b._depths_floor_root
		cells_ok = cells_ok and b._sc_nodes.size() > 0 and b._sc_nodes.all(func(n: Variant) -> bool: return is_instance_valid(n) and root3d.is_ancestor_of(n))
		for k in b._sc_nodes.size():   # each cell's shadow follows the range rule's flag
			cells_ok = cells_ok and (b._sc_nodes[k] as GeometryInstance3D).cast_shadow == (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if b._sc_on[k] == 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		cells_max = maxi(cells_max, b._sc_nodes.size())
		tri_ok = tri_ok and core.nav_triangle_count() - tri_base == _triangles(d.ground.region.navigation_mesh)
		async_all = async_all and d.ground.async_ok
	var depth := d.run.depth
	check(depth == 15, "descended to depth %d" % depth)
	check(tri_ok, "on every floor the core holds that floor's triangles only")
	check(async_all, "every floor's navmesh came from the worker thread")
	var early := _mean(nodes.slice(0, 3))
	var late := _mean(nodes.slice(-3))
	check(late - early < 60.0, "no node leak over 14 floors: %.0f -> %.0f nodes (bound +60)" % [early, late])
	check(_depths_enemies().size() <= int(DmSimData.DEPTHS["cap"]) and d._living.size() == _depths_enemies().size(), "the Depths' living set agrees with the core (%d)" % d._living.size())
	var kinds := {}
	for info in _depths_enemies():
		kinds[String(info["def"])] = true
	check(kinds.keys().all(func(k: String) -> bool: return DmWaveDirector.runs_on_core(k)), "depth 15's dead are all kinds the core runs (%s)" % str(kinds.keys()))
	check(cells_ok and cells_max < 80, "the builder's shadow-cell list holds only the standing floor's cells on every floor (at most %d), each following the range rule" % cells_max)
	print("INFO depths: 14 floors: main thread %.1f ms a floor (worst %d), load to merge %.0f ms (worst %d), the longest frame in a descent %.0f ms; nodes %.0f -> %.0f; shadow cells at most %d" % [
		_mean(builds), builds.max(), _mean(loads), loads.max(), float(worst) / 1000.0, early, late, cells_max])
	d.end("left")
	await ticks(3)
	check(core.nav_triangle_count() == tri_base and _depths_enemies().is_empty() and not d.is_physics_processing() and not g.core_host.enemy_died.is_connected(d._on_enemy_died), "the run ends clean: the core is as before the first run, the Depths' tick and ears are off")


func _mean(a: Array) -> float:
	var t := 0.0
	for x in a:
		t += float(x)
	return t / maxf(1.0, float(a.size()))
