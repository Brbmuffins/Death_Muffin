extends SceneTree
## The Catacomb Depths on the combat core (client/README.md "The Depths"): the game scene as a player gets it (the whole world, the HUD), offline on the
## local mock, headless. Today's tests/next_depths replayed on the core. Checks:
##   A the rules, no game: floors per seed (sound, deterministic, a chest every `chestEvery` depths), quota, pacing, affixes (the shape of each formula and the data's numbers; the server rules' own answers for
##     the rosters and the loot ground), levels, the first wave, the stair opening once;
##   B the world: the Depths node and the Warren's stair, the Depths' rect in the core's bounds and in no area until a run opens it, nothing on the core before a run;
##   C the way in: the Warren's seal broken, waystone travel, a click on the stair walks the hero to it and starts a run; floor 1 stands (drawn, the hero at its way in, in the Depths,
##     the stairs clickable, the arrival banner, the HUD's readout and map, the prompts), its navmesh is baked, on the navigation map and the core's own copy of it, which answers
##     what the navigation server answers; a run is solo;
##   D the dead: bodies of the core at the depth's level, in the Depths' area and on the floor, hunting the hero across the rooms (the Depths' aggro), fighting back; elites bear the depth's affixes;
##     none of the kinds the core does not run yet;
##   E the quota: the hero's kills (through the core, credited once) open the stair at the quota, the floor pays (gold, XP, a tape item) and is reported, kills are paid on the Depths' ground;
##   F descending: floor 2 of the same seed, the dead and corpses of floor 1 gone from the core, the hero at the way in, the core's navmesh replaced (not added to), a new quota;
##   G the chest on the first chest depth: its tape finds on the ground (a claim picks one into the bag on the server), once, off the HUD and the map;
##   H leaving: the exit asks twice, the summary, the Warren's stair, everything torn down (picture, navmesh, the core's copy, interactables), the record on the backend, the stair's offer to
##     resume, a recall (T) out of a run, a second player joining;
##   I death: the run ends and the floor stays behind the death screen, no stairs or waves, the hero rises in the Chapterhouse, nothing taken, a new run possible;
##   the counsel's Depths tips: a run begins with the solo tip, every floor tells its tips (the extra affixes from the first depth that has them, the chest on opening it), a party at the stair is told why;
##   ZERO script errors or engine errors in the log.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/depths.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://depths_test"
const BAKE := ["grave_robber", "bone_hound"]
## What the run's code does that is in neither the Depths data nor the server's answers (next/depths/dm_depths_run.gd): the first wave is at least this many, whatever the wave size.
const FIRST_WAVE_MIN := 8

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
var peak := 0                   ## the depth of the first chest the descent reaches (the deepest it goes in section G)
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


## The counsel has the tip: waiting out its delay, queued, on the card or already shown.
func told(tip: String) -> bool:
	var c: DmCounsel = g.ui.counsel
	return c.seen.has(tip) or c.pending.has(tip) or c._queued(tip) or String(c.shown.get("id", "")) == tip


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
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
	check(DmThreadGuard.checks > 0 and DmThreadGuard.violations == 0, "the floor's worker and bake were taken on the main thread (%d taken, %d off it: %s)" % [DmThreadGuard.checks, DmThreadGuard.violations, DmThreadGuard.last_violation])
	check(DmDbWarm.done, "the datasets were all read in loading (DmDbWarm)")
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


## The dead's level on `depth` for a hero of `hero_level`: max(minLevel, hero) + depth x levelsPerDepth, from the Depths data (not through the run).
func _depth_level(depth: float, hero_level: float) -> float:
	var D: Dictionary = DmSimData.DEPTHS
	return maxf(float(D["minLevel"]), floorf(hero_level)) + floorf(maxf(1.0, depth) * float(D["levelsPerDepth"]))


## The floor's clickable things: the stairs down and up, and the chest on a chest depth.
func _stairs_and_chest(f: Dictionary) -> int:
	return 2 + (1 if f["chest"] != null else 0)


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
	var D: Dictionary = DmSimData.DEPTHS
	var every := int(D["chestEvery"])
	var same := true
	var sound := true
	var chests_ok := true
	var floors_n := 3 * every   # three chest depths of floors
	for depth in range(1, floors_n + 1):
		var a := DmDepthsRun.generate(1000 + depth, depth)
		var b := DmDepthsRun.generate(1000 + depth, depth)
		same = same and _floor_json(a) == _floor_json(b)
		sound = sound and DmDepthsFloor.floor_problems(a).is_empty()
		chests_ok = chests_ok and ((a["chest"] != null) == (depth % every == 0))
	check(same, "a floor is deterministic per (seed, depth)")
	check(sound, "%d generated floors have no unreachable stair / chest / breach" % floors_n)
	check(chests_ok, "a chest on every %dth depth and no other" % every)
	check(_floor_json(DmDepthsRun.generate(1, 3)) != _floor_json(DmDepthsRun.generate(2, 3)) and _floor_json(DmDepthsRun.generate(1, 3)) != _floor_json(DmDepthsRun.generate(1, 4)), "another seed or depth gives another floor")
	check(int(D["cap"]) > 0 and every >= 1 and float(D["firstWaveDelayS"]) >= 0.0 and int(D["extraAffixEvery"]) >= 1 and int(D["maxExtraAffixes"]) >= 0, "DEPTHS: a cap, a chest and affix cadence, a first-wave delay")
	# the formulas: their shape (how a quota, a wave and its gap move with the depth, and where they stop), never their numbers; the data's numbers are checked against the data
	var shape_ok := true
	var prev_kills := 0.0
	var prev_size := 0.0
	var prev_gap := INF
	var prev_bonus := 0.0
	var prev_aff := 0
	for depth in range(1, 121):
		var dd := float(depth)
		var q := DmSimDepthsRules.floor_kills(dd)
		var sz := DmSimDepthsRules.depth_wave_size(dd)
		var gp := DmSimDepthsRules.depth_wave_gap_s(dd)
		var eb := DmSimDepthsRules.depth_elite_bonus(dd)
		var af := DmSimDepthsRules.extra_affixes(dd)
		shape_ok = shape_ok and q >= prev_kills and q >= 1.0 and sz >= prev_size and sz >= 1.0 and gp <= prev_gap and gp > 0.0 and eb >= prev_bonus and eb >= 0.0 and af >= prev_aff
		# elite affixes: one more every extraAffixEvery depths, at most maxExtraAffixes (the data's numbers)
		shape_ok = shape_ok and af == mini(int(D["maxExtraAffixes"]), int(floorf(dd / float(D["extraAffixEvery"]))))
		prev_kills = q
		prev_size = sz
		prev_gap = gp
		prev_bonus = eb
		prev_aff = af
	check(shape_ok, "quota, wave size, wave gap and elite chance move one way with the depth, extra affixes follow the data (every %d depths, at most %d)" % [int(D["extraAffixEvery"]), int(D["maxExtraAffixes"])])
	check(DmSimDepthsRules.floor_kills(1000.0) == DmSimDepthsRules.floor_kills(120.0) and DmSimDepthsRules.depth_wave_size(1000.0) == DmSimDepthsRules.depth_wave_size(120.0) and DmSimDepthsRules.depth_wave_gap_s(1000.0) == DmSimDepthsRules.depth_wave_gap_s(120.0)
		and DmSimDepthsRules.depth_elite_bonus(1000.0) == DmSimDepthsRules.depth_elite_bonus(120.0), "each of them stops at a cap or a floor deep enough")
	# the rosters: the server rules' answer for every depth the content holds (client/data/content/computed.json), and the loot ground likewise
	var rosters_ok := true
	var loot_ok := true
	var computed: Dictionary = DmContent.file("computed")
	for depth in range(1, 61):
		var mine := DmSimDepthsRules.depth_roster(float(depth))
		var theirs: Array = DmContent.depth_roster(depth)
		rosters_ok = rosters_ok and mine.size() == theirs.size() and not theirs.is_empty()
		for i in mini(mine.size(), theirs.size()):
			rosters_ok = rosters_ok and String(mine[i]["id"]) == String(theirs[i]["id"]) and float(mine[i]["weight"]) == float(theirs[i]["weight"])
		loot_ok = loot_ok and DmDepthsRewards.depth_loot_area(float(depth)) == String(computed["depthLootAreas"][str(depth)])
	check(rosters_ok, "the roster of every depth is the server rules' (computed.json)")
	check(loot_ok, "the loot ground of every depth is the server rules' (computed.json)")
	var bands: Array = DmSimDepthsRules.BANDS
	var base := _ids(DmSimDepthsRules.depth_roster(1.0))
	var first_band: Array = []
	for e: Array in bands[0]["add"]:
		first_band.append(String(e[0]))
	check(base == first_band, "depth 1 roster: the first band's kinds")
	var all_ids := {}
	for band: Dictionary in bands:
		for e: Array in band["add"]:
			all_ids[String(e[0])] = true
	var deepest := _ids(DmSimDepthsRules.depth_roster(float(bands[-1]["from"])))
	check(deepest.size() == all_ids.size() and deepest.all(func(k: String) -> bool: return all_ids.has(k)), "the deepest band's roster holds every kind of every band (%d)" % all_ids.size())
	var grows := true
	var last_n := 0
	for depth in range(1, 61):
		var n := DmSimDepthsRules.depth_roster(float(depth)).size()
		grows = grows and n >= last_n
		last_n = n
	check(grows, "a deeper floor never has fewer kinds")
	var w_first := _w(DmSimDepthsRules.depth_roster(1.0), String(bands[0]["add"][0][0]))
	var w_deep := _w(DmSimDepthsRules.depth_roster(float(bands[-1]["from"])), String(bands[0]["add"][0][0]))
	var w_deepest := _w(DmSimDepthsRules.depth_roster(60.0), String(bands[0]["add"][1][0]))
	check(w_deep < w_first and w_deepest > 0.0, "the first band's kinds fade as the bands arrive, and never to nothing")
	var run := DmDepthsRun.create(7, 1)
	check(run.enemy_level(1.0) == _depth_level(1.0, 1.0) and run.enemy_level(30.0) == _depth_level(1.0, 30.0), "enemy level on depth 1: max(minLevel, hero) + the depth (%d for a level-1 hero, %d for level 30)" % [int(_depth_level(1.0, 1.0)), int(_depth_level(1.0, 30.0))])
	run.depth = 9
	check(run.enemy_level(1.0) == _depth_level(9.0, 1.0) and run.enemy_level(1.0) == _depth_level(1.0, 1.0) + 8.0 * float(D["levelsPerDepth"]), "enemy level rises by levelsPerDepth a depth (depth 9: %d)" % int(_depth_level(9.0, 1.0)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	run = DmDepthsRun.create(11, 1)
	var f: Dictionary = run.floor_data
	var hero_at := Vector2(float(f["start"]["x"]), float(f["start"]["z"]))
	var delay := float(D["firstWaveDelayS"])
	check(run.plan_wave(delay * 0.5, 0, 0, [hero_at], rng, 0.06).is_empty(), "no wave before the first-wave delay")
	var orders := run.plan_wave(delay, 0, 0, [hero_at], rng, 0.06)
	var first_wave := mini(mini(int(run.need), int(D["cap"])), maxi(int(DmSimDepthsRules.depth_wave_size(1.0)), FIRST_WAVE_MIN))
	check(orders.size() == first_wave, "the first wave is %d (%d)" % [first_wave, orders.size()])
	var in_hero_room := orders.any(func(o: Dictionary) -> bool: return DmDepthsFloor.room_at(f, float(o["x"]), float(o["z"])) == DmDepthsFloor.room_at(f, hero_at.x, hero_at.y))
	check(not in_hero_room or f["breaches"].size() == 0, "waves climb out of other rooms than the hero's")
	check(orders.all(func(o: Dictionary) -> bool: return base.has(String(o["def"]))), "depth-1 waves draw only from the depth-1 roster")
	var alive := maxi(1, int(run.need) - 2)
	check(run.plan_wave(0.1, alive, alive, [hero_at], rng, 0.06).is_empty() and absf(run.wave_t - (DmSimDepthsRules.depth_wave_gap_s(1.0) - 0.1)) < 1e-6, "the next wave waits out the gap (%.2f s)" % run.wave_t)
	run.wave_t = 0.0
	check(run.plan_wave(0.1, alive, alive, [hero_at], rng, 0.06).size() == mini(2, int(run.need) - alive), "only as many as the quota still needs (%d - %d alive = %d)" % [int(run.need), alive, int(run.need) - alive])
	run.wave_t = 0.0
	check(run.plan_wave(0.1, int(D["cap"]), int(D["cap"]), [hero_at], rng, 0.06).is_empty(), "never more than the cap alive")
	# every kind of every band is on the core (a band that gained a kind the core lacks would fail here): the rosters are today's, kind for kind and weight for weight
	var whole := true
	var probe_depths: Array = []
	for band: Dictionary in bands:
		probe_depths.append(maxi(1, int(band["from"]) - 1))
		probe_depths.append(int(band["from"]))
	for depth in probe_depths:
		for e: Dictionary in DmSimDepthsRules.depth_roster(float(depth)):
			whole = whole and DmWaveDirector.runs_on_core(String(e["id"]))
	check(whole, "every kind on every depth's roster is a kind the core runs, so the rosters are today's")
	var top := int(bands[-1]["from"])
	run = DmDepthsRun.create(11, top)
	var seen := {}
	var start_top := Vector2(float(run.floor_data["start"]["x"]), float(run.floor_data["start"]["z"]))
	for i in 150:
		run.wave_t = 0.0
		run.waved = false
		run.floor_t = 100.0
		for o: Dictionary in run.plan_wave(0.1, 0, 0, [start_top], rng, 0.06):
			seen[String(o["def"])] = true
	check(seen.size() == DmSimDepthsRules.depth_roster(float(top)).size(), "150 waves on depth %d draw all %d kinds of its roster (%d seen)" % [top, DmSimDepthsRules.depth_roster(float(top)).size(), seen.size()])
	run = DmDepthsRun.create(11, 1)
	var quota := int(run.need)
	var opened := 0
	for i in quota + 2:
		if run.record_kill():
			opened += 1
	check(opened == 1 and run.stair_open and run.floors == 1 and run.total_kills == quota + 2, "the kill that meets the quota (%d) opens the stair, once" % quota)
	run.descend()
	check(run.depth == 2 and run.peak == 2 and run.kills == 0 and not run.stair_open and run.need == DmSimDepthsRules.floor_kills(2.0) and run.total_kills == quota + 2, "descending: depth 2, its quota, the totals carry")
	check(run.summary() == "The descent ends at depth 2 · %d slain · 1 floor cleared. What you looted is yours." % (quota + 2), "the summary line")
	# the chest's size: never falls with the depth (the first find is always gear)
	var chest_ok := true
	var last_chest := 0
	for depth in range(1, 61):
		var cn := DmDepthsRewards.chest_drops(float(depth))
		chest_ok = chest_ok and cn >= last_chest and cn >= 1
		last_chest = cn
	check(chest_ok, "a chest never holds fewer finds on a deeper floor")


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
	var quota := int(run.need)
	var lvl1 := int(_depth_level(1.0, float(character["level"])))
	check(quota == int(DmSimDepthsRules.floor_kills(1.0)), "depth 1 asks %d kills" % quota)
	check(its.size() == _stairs_and_chest(f) and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_down") and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_up"), "the floor's stairs are clickable things (and the chest, on a chest depth)")
	check(d.prompt(_it("depths_down")).begins_with("The stair is sealed: slay %d more" % quota) and d.prompt(_it("depths_up")) == "Climb out (ends this run at depth 1)", "stair prompts: sealed with the count, the way up")
	check(ev("depths_solo").size() == 1 and ev("depths_floor").size() == 1 and ev("depths_affix").is_empty() and told("depths_solo") and told("depths_floor") and not told("depths_affix"),
		"a run begins: the counsel gets the solo tip and the floor's, and no affix tip on depth 1 (%d, %d, %d)" % [ev("depths_solo").size(), ev("depths_floor").size(), ev("depths_affix").size()])
	var banner := ev("banner").filter(func(e: Array) -> bool: return String(e[1]["title"]) == "Depth 1")
	check(not banner.is_empty() and String(banner[0][1]["sub"]).find("slay %d" % quota) >= 0 and String(banner[0][1]["sub"]).find("level %d dead" % lvl1) >= 0, "the arrival banner names the quota and the dead's level")
	check(d.hud_state() == {"depth": 1, "kills": 0, "need": quota, "open": false, "chest": f["chest"] != null}, "HUD readout: depth 1, 0 / %d, sealed, a chest only on a chest depth" % quota)
	var mf: Variant = d.map_floor()
	check(mf != null and mf["rooms"].size() == f["rooms"].size() and not mf["down"]["open"] and (mf["chest"] != null) == (f["chest"] != null), "the minimap draws the floor's rooms")
	await ticks(12)   # the HUD refreshes at 20 Hz
	var vm: Dictionary = g.ui_host.vm.build()
	check(vm["depth"] != null and int(vm["depth"]["need"]) == quota and vm["minimap"]["depths"] != null and String(vm["area_progress"]) == "Level <b>%d</b> dead" % lvl1, "the HUD view-model carries the Depths readout, the map and the area line (%s)" % str(vm["area_progress"]))
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
	var first_wave := mini(mini(int(run.need), int(DmSimData.DEPTHS["cap"])), maxi(int(DmSimDepthsRules.depth_wave_size(1.0)), FIRST_WAVE_MIN))
	check(await until(func() -> bool: return _depths_enemies().size() >= first_wave, 60 * 8), "the floor's first wave climbs out (%d)" % first_wave)
	var es := _depths_enemies()
	var base := _ids(DmSimDepthsRules.depth_roster(1.0))
	var rect: Dictionary = DmContent.area("depths")["rect"]
	var lvl1 := int(_depth_level(1.0, float(character["level"])))
	var hp_mult := DmEnemyStats.hp_scale(float(lvl1)) * float(DmContent.difficulty(g.director.difficulty)["enemyHpMult"])
	var lvl_ok := true
	var hp_ok := true
	var kind_ok := true
	var pos_ok := true
	var nav_ok := true
	var aggro_ok := true
	for info: Dictionary in es:
		var at: Vector2 = info["pos"]
		lvl_ok = lvl_ok and int(info["level"]) == lvl1
		hp_ok = hp_ok and (bool(info["elite"]) or is_equal_approx(float(info["max_hp"]), float(DmSimData.ENEMIES[String(info["def"])]["hp"]) * hp_mult))
		kind_ok = kind_ok and base.has(String(info["def"])) and String(info["area"]) == "depths"
		pos_ok = pos_ok and at.x > float(rect["x0"]) and at.x < float(rect["x1"]) and at.y > float(rect["z0"]) and at.y < float(rect["z1"])
		nav_ok = nav_ok and core.nav_closest(Vector3(at.x, 0.0, at.y)).distance_to(Vector3(at.x, 0.0, at.y)) < 0.3
		aggro_ok = aggro_ok and float(info["aggro"]) == DmSimConsts.DEPTHS_AGGRO and float(info["leash"]) == DmDepths.LEASH
	check(lvl_ok and hp_ok, "the dead are level %d on depth 1 (hp x%.2f, the director's scaling)" % [lvl1, hp_mult])
	check(kind_ok and pos_ok and nav_ok, "kinds from the depth roster, in the Depths' area, standing on the floor's ground")
	check(aggro_ok, "hunters notice the hero across the floor: aggro %.0f and leash %.0f on their bodies in the core" % [DmSimConsts.DEPTHS_AGGRO, DmDepths.LEASH])
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
	# an elite on depth 15 carries the affixes it is given (the test's own: all the pool), at the depth's level
	var affixes := PackedStringArray(DmSimData.AFFIX_ORDER)
	var el: int = g.director.spawn("robber", hero.position + Vector3(2, 0, 0), [hero], true, {}, {"area": "depths", "depth": 15, "aggro": DmDepths.AGGRO, "leash": DmDepths.LEASH, "affix_list": affixes})
	var info: Dictionary = core.enemy_info(el)
	var lvl15 := int(_depth_level(15.0, float(character["level"])))
	check(el > 0 and bool(info["elite"]) and (info["affixes"] as PackedStringArray).size() == affixes.size() and int(info["level"]) == lvl15, "an elite on depth 15 bears %d affixes at level %d" % [affixes.size(), lvl15])
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
	check(run.stair_open and cleared[0] == 1 and run.floors == 1 and float(run.kills) >= run.need, "the stair opens once, when the quota is met (kills %d of %d)" % [run.kills, int(run.need)])
	check(float(credited.size()) >= run.need and credited.all(func(c: Array) -> bool: return c[1] == "depths" and int(c[2]) == g.session.get_my_id()), "each kill was credited once, to the hero, in the Depths (%d)" % credited.size())
	check(d.prompt(_it("depths_down")) == "Descend to depth 2" and d.hud_state()["open"] and d.map_floor()["down"]["open"], "the stair's prompt, the HUD and the minimap show it open")
	check(g.world.builder._depths_stair_mat.emission_energy_multiplier > 1.0, "the stair down glows bright once open")
	check(ev("banner").any(func(e: Array) -> bool: return String(e[1]["title"]) == "The stair opens"), "a banner says so")
	check(await until(func() -> bool: return int(character["gold"]) > gold0 or m.loot_view.count() > 0, 60 * 5), "kills and the floor clear pay gold")
	check(int(character["experience"]) > xp0 or int(character["level"]) > lvl0, "XP was earned (floor clear + kills)")
	await until(func() -> bool: return not g.progress.psync.reporter.has_pending(), 60 * 5)
	check(not g.progress.psync.reporter.has_pending(), "the floor report was sent and acknowledged by the backend")
	await g.rewards.flush()
	check(float(m.stats["kills_earned"]) >= run.need and g.progress.prog.kills("depths") == 0, "kills are paid and reported, but do not count towards an area seal")
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
	check(run.kills == 0 and not run.stair_open and run.need == DmSimDepthsRules.floor_kills(2.0) and d.hud_state()["need"] == int(run.need), "a new quota (%d) and a sealed stair" % int(run.need))
	check(old_living.all(func(id: int) -> bool: return core.enemy_info(id).is_empty()) and _depths_enemies().all(func(info: Dictionary) -> bool: return not old_living.has(int(info["id"]))), "the last floor's living dead are out of the core (%d)" % old_living.size())
	check(g.corpses.corpses_in_radius(mid, 40.0, Callable(), "depths").is_empty(), "the last floor's corpses are gone")
	var f: Dictionary = run.floor_data
	check(Vector2(hero.position.x - float(f["start"]["x"]), hero.position.z - float(f["start"]["z"])).length() < 0.5, "the hero stands at floor 2's way in")
	check(far_thrall > 0 and (hero.get_node("Rites") as DmRiteCaster).thralls().near(hero.position, 3.5).has(far_thrall), "a thrall 9 m away came with him (recalled)")
	check(g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths").size() == _stairs_and_chest(f), "the floor's interactables were replaced, not stacked")
	var tri2: int = core.nav_triangle_count()
	check(tri2 - tri_base == _triangles(d.ground.region.navigation_mesh), "the core's navmesh was replaced, not added to (%d + %d triangles)" % [tri_base, tri2 - tri_base])
	check(_reachable(f), "navmesh of floor 2: stair down, way up and breaches reachable")
	var lvl2 := int(_depth_level(2.0, float(character["level"])))
	check(await until(func() -> bool: return _depths_enemies().size() >= 2, 60 * 8) and _depths_enemies().all(func(info: Dictionary) -> bool: return int(info["level"]) == lvl2), "floor 2's dead are level %d" % lvl2)
	# floor 3: the real way, a click on the open stair walks the hero across the floor's rooms on the core's navmesh and takes it
	check(await _clear_floor(), "floor 2 quota met")
	var down := _it("depths_down")
	var from_start := hero.position
	var stair_at := Vector3(float(f["stairDown"]["x"]), 0.0, float(f["stairDown"]["z"]))
	g.chapterhouse.click_interactable(down)
	check(await until(func() -> bool: return run.depth == 3 and not d._busy, 60 * 60), "a click on the open stair walks the hero to it and descends (he walked %.0f m, from %s)" % [from_start.distance_to(stair_at), str(from_start)])
	await ticks(3)
	check(run.depth == 3 and run.peak == 3 and core.nav_triangle_count() - tri_base == _triangles(d.ground.region.navigation_mesh), "descended to depth 3, the core holds this floor's triangles only")
	# on down to the floor before the first chest (none if floor 3 is already a chest floor), a chest only where the cadence says
	var every := int(DmSimData.DEPTHS["chestEvery"])
	var chest_rule: bool = (run.floor_data["chest"] != null) == (run.depth % every == 0)
	while run.depth < every - 1:
		check(await _clear_floor(), "floor %d quota met" % run.depth)
		await d.descend()
		await ticks(3)
		chest_rule = chest_rule and (run.floor_data["chest"] != null) == (run.depth % every == 0)
		check(run.peak == run.depth and core.nav_triangle_count() - tri_base == _triangles(d.ground.region.navigation_mesh), "descended to depth %d, the core holds this floor's triangles only" % run.depth)
	check(chest_rule and d.hud_state()["chest"] == (run.floor_data["chest"] != null), "a chest only on every %dth depth" % every)
	print("INFO depths: floor 2: main thread %d ms, bake %d ms on the worker, the whole load %d ms" % [d.ground.build_ms, d.ground.bake_ms, d.ground.nav_ms])


# ---- G: the chest ----------------------------------------------------------------------------------------------------------------

func _g_chest() -> void:
	var run := d.run
	var every := int(DmSimData.DEPTHS["chestEvery"])
	var from_depth := run.depth
	events.clear()
	while run.floor_data["chest"] == null and run.depth < 4 * every:   # down to the first chest floor
		check(await _clear_floor(), "floor %d cleared" % run.depth)
		await d.descend()
		await ticks(3)
	peak = run.depth
	# every floor reached told the counsel; the extra affixes only on the depths that have them, with how many
	var with_extras: Array = []
	for depth in range(from_depth + 1, peak + 1):
		if DmSimDepthsRules.extra_affixes(float(depth)) > 0:
			with_extras.append(DmSimDepthsRules.extra_affixes(float(depth)))
	check(ev("depths_floor").size() == peak - from_depth, "each floor reached tells the counsel (%d)" % ev("depths_floor").size())
	check(not with_extras.is_empty() and ev("depths_affix").map(func(e: Array) -> int: return int(e[1]["extras"])) == with_extras and told("depths_affix"),
		"...and the depths with extra affixes tell their count (%s) and the affix tip is the counsel's" % str(with_extras))
	check(run.depth % every == 0 and run.floor_data["chest"] != null, "depth %d has a chest" % peak)
	var its := g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths")
	check(its.size() == _stairs_and_chest(run.floor_data) and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_chest"), "the chest is a clickable thing")
	check(d.hud_state()["chest"] and d.map_floor()["chest"] != null and d.prompt(_it("depths_chest")) == "Open the chest", "HUD and minimap show the chest")
	var loot_ground := String(DmContent.file("computed")["depthLootAreas"][str(peak)])
	check(String(g.rewards.loot_area_of.call("depths")) == loot_ground, "depth %d loots from the %s's table (the server rules' ground)" % [peak, loot_ground])
	var bear := 1 + DmSimDepthsRules.extra_affixes(float(peak))
	check(d.progress_line().ends_with(" · elites bear <b>%d</b> affixes" % bear) and d.progress_line().begins_with("Level <b>%d</b> dead" % int(run.enemy_level(float(character["level"])))), "the area line names the level and the affixes an elite bears (%s)" % d.progress_line())
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
	check(ev("depths_chest").size() == 1 and told("depths_chest"), "the chest tells the counsel once")
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
	check(float(life.get("depths.floors", 0.0)) >= float(run.floors) and float(life.get("depths.chests", 0.0)) == 1.0 and float(life.get("peak.depth", 0.0)) == float(peak), "the chronicle counts floors (%d), the chest and the deepest floor" % int(life.get("depths.floors", 0.0)))


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
	check(not d.leave() and d.run != null and ev("toast").any(func(e: Array) -> bool: return String(e[1]["text"]).begins_with("Climbing out ends this run at depth %d" % peak)), "the exit asks twice (the first click only warns)")
	check(d.leave() and d.run == null, "the second click ends the run")
	await ticks(3)
	check(ended.size() == 1 and ended[0][0] == "left" and String(ended[0][1]).begins_with("The descent ends at depth %d" % peak), "run_ended(left) with the summary")
	check(Vector2(hero.position.x - float(s["x"]), hero.position.z - (float(s["z"]) + 2.3)).length() < 0.5 and g.area_of(1) == "warren", "back at the Warren's stair")
	check(g.world.builder._depths_floor_root == null or not is_instance_valid(g.world.builder._depths_floor_root), "the floor's picture is torn down")
	check(not d.ground.region.enabled and core.nav_triangle_count() == tri_base, "the floor's navmesh region is off and out of the core (%d triangles, as before the run)" % core.nav_triangle_count())
	check(g.world.area_at(mid.x, mid.z) == "" and core.nav_closest(mid).distance_to(mid) > 20.0, "the Depths are no area again, and no ground for the core")
	check(_depths_enemies().is_empty() and d._living.is_empty() and g.chapterhouse.interactables.all(func(it: Dictionary) -> bool: return String(it["area"]) != "depths"), "no living dead and no stairs are left behind")
	check(d.hud_state() == null and d.map_floor() == null, "the Depths readout is gone")
	# the record: the deepest floor persists on the chronicle (backend)
	await d.flush()
	var ch: DmResult = await api.get_chronicle(int(character["id"]))
	check(ch.ok and float(ch.data["life"].get("peak.depth", 0.0)) == float(peak) and float(ch.data["life"].get("depths.runs", 0.0)) == 1.0, "the backend's chronicle records peak depth %d and the run" % peak)
	check(d.resume_at() == peak, "the stair now offers to resume at depth %d" % peak)
	var stair := _it("depths_stair")
	events.clear()
	check(d.stair_clicked() == peak and ev("depths_stair_offer").size() == 1 and int(ev("depths_stair_offer")[0][1]["deepest"]) == peak and not d.active(), "the stair offers 'start at 1' or 'resume at %d'" % peak)
	check(d.prompt(stair).find("resume at depth %d" % peak) >= 0, "the stair's prompt names the resume depth")
	g.ui_host.enter_depths(peak)   # what the card's Resume does
	await until(func() -> bool: return d.run != null and not d._busy, 60 * 20)
	await ticks(2)
	check(d.run != null and d.run.depth == peak and d.run.peak == peak and d.run.floors == 0 and d.run.floor_data["chest"] != null, "resume: a new run starts at depth %d (a chest floor, so a chest waits)" % peak)
	check(d.run.enemy_level(1.0) == _depth_level(float(peak), 1.0), "its dead are level %d" % int(_depth_level(float(peak), 1.0)))
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
	events.clear()
	check(d.stair_clicked() == 0 and d.run == null and ev("depths_solo").size() == 1 and ev("toast").any(func(e: Array) -> bool: return String(e[1]["text"]) == DmDepths.PARTY_REFUSAL), "...a click on the stair says why, and the solo tip goes to the counsel")
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
	check(int(character["gold"]) >= gold_before and float(d.chronicle.view()["life"].get("peak.depth", 0.0)) >= float(peak), "death takes nothing: gold kept, the best depth (%d) still on record" % peak)
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
	var descents := 14   # (the test's own: floors down)
	for i in descents:
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
	check(depth == 1 + descents, "descended to depth %d" % depth)
	check(tri_ok, "on every floor the core holds that floor's triangles only")
	check(async_all, "every floor's navmesh came from the worker thread")
	var early := _mean(nodes.slice(0, 3))
	var late := _mean(nodes.slice(-3))
	check(late - early < 60.0, "no node leak over %d floors: %.0f -> %.0f nodes (bound +60)" % [descents, early, late])
	check(_depths_enemies().size() <= int(DmSimData.DEPTHS["cap"]) and d._living.size() == _depths_enemies().size(), "the Depths' living set agrees with the core (%d)" % d._living.size())
	var kinds := {}
	for info in _depths_enemies():
		kinds[String(info["def"])] = true
	check(kinds.keys().all(func(k: String) -> bool: return DmWaveDirector.runs_on_core(k)), "depth %d's dead are all kinds the core runs (%s)" % [depth, str(kinds.keys())])
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
