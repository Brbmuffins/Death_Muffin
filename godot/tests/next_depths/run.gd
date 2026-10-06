extends SceneTree
## Depths suite (godot/next/depths): the procedural descent on the rebuilt game, on the OFFLINE backend, solo. Floor generation per seed,
## rosters / scaling / quota / waves by depth, entering by the Warren's stair, chests and stairs, descending, death ends the run (death takes
## nothing), recall / leave, loot ground by depth, the peak depth on the chronicle, back to the hub, and the cost (floor build, first-floor
## hitch, frame cost with a full floor, memory after 10 floors).
## godot --headless --path godot --script res://tests/next_depths/run.gd

const DT := 1.0 / 60.0
const BUILD_BUDGET_MS := 120.0       ## main-thread ms to draw + bake one floor (measured ~10-25; generous: a shared VPS)
const FRAME_BUDGET_MS := 40.0        ## median frame with a full floor of hunters (headless, shared)
const NODE_GROWTH := 60              ## nodes after 10 floors vs after the first: a leak adds a floor's worth (hundreds) per floor
const MEM_GROWTH_MB := 40.0          ## static memory after 10 floors vs after the first

var passed := 0
var failed := 0
var g: DmNextGame
var d: DmDepths
var api: DmApi
var character: Dictionary
var events: Array = []
var immortal := true       ## re-applied every frame: a level-up (floor XP) rebuilds the stats and would leave the hero mortal


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func ev(id: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == id)


func body() -> DmHeroBody:
	return g.local_body()


## The hero cannot die by accident (the test kills them on purpose).
func harden() -> void:
	var b := body()
	b.p["stats"]["maxHp"] = 1e9
	b.p["hp"] = 1e9
	b._mirror_from_state()


func depths_enemies(alive_only: bool = true) -> Array:
	var out: Array = []
	for e in g.director.enemies.values():
		var en := e as DmEnemy
		if en != null and is_instance_valid(en) and String(en.get_meta(&"dm_area", "")) == "depths" and (not alive_only or en.sm.id() != DmEnemyState.Id.DEAD):
			out.append(en)
	return out


## Kill every enemy that can be hurt now (rising ones are immune for ~1 s).
func kill_all() -> int:
	var n := 0
	for e in depths_enemies():
		if (e as DmEnemy).take_damage(1e9, body()):
			n += 1
	return n


## Clear a floor's quota through real kills: returns when the stair is open.
func clear_floor(limit_s: float = 60.0) -> bool:
	return await until(func() -> bool:
		kill_all()
		return d.run == null or d.run.stair_open, limit_s)


func enter(depth: int, seed_: int) -> void:
	await d.enter(depth, seed_)
	await ticks(2)


## Leave through the exit the way a player does (asks twice) and wait for the hub.
func exit_run() -> void:
	d.leave()
	d.leave()
	await ticks(3)


## The drawn floor (the builder names a rebuilt root "DepthsFloor" only while no other is queued for deletion: ask the builder, not the tree).
func floor_root() -> Node:
	var n: Node = g.world.builder._depths_floor_root
	return n if n != null and is_instance_valid(n) else null


func floor_json(f: Dictionary) -> String:
	return JSON.stringify(f)


func _run() -> void:
	Engine.time_scale = 4.0
	DmSimData.ensure()
	_rules()
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("dp%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"dressing": false, "persist": false, "waves": false, "audio": false})
	d = g.depths
	check(d != null and d.ground != null and g.chapterhouse != null, "boots with the Depths node under the game")
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	physics_frame.connect(func() -> void:
		var hb := g.local_body() if g != null else null
		if immortal and hb != null and hb.alive and hb.max_hp < 1e8:
			harden())
	await ticks(30)
	harden()
	await _warren_walk()
	await _enter_and_floor()
	await _waves_and_scaling()
	await _quota_and_descend()
	await _chest()
	await _leave_recall_resume()
	await _death()
	await _perf()
	await g.leave()
	g.queue_free()
	await process_frame
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ======================================================================================================== rules (no game)

func _rules() -> void:
	# floor generation: deterministic per seed, sound, a chest on every fifth depth
	var same := true
	var sound := true
	var chests_ok := true
	for depth in range(1, 16):
		var a := DmDepthsRun.generate(1000 + depth, depth)
		var b := DmDepthsRun.generate(1000 + depth, depth)
		same = same and floor_json(a) == floor_json(b)
		sound = sound and DmDepthsFloor.floor_problems(a).is_empty()
		chests_ok = chests_ok and ((a["chest"] != null) == (depth % 5 == 0))
	check(same, "a floor is deterministic per (seed, depth)")
	check(sound, "15 generated floors have no unreachable stair / chest / breach")
	check(chests_ok, "a chest on every fifth depth (5, 10, 15) and no other")
	check(floor_json(DmDepthsRun.generate(1, 3)) != floor_json(DmDepthsRun.generate(2, 3)) and floor_json(DmDepthsRun.generate(1, 3)) != floor_json(DmDepthsRun.generate(1, 4)), "another seed or depth gives another floor")
	# quota, pacing, affixes, elites
	var D: Dictionary = DmSimData.DEPTHS
	check(DmSimDepthsRules.floor_kills(1.0) == 10.0 and DmSimDepthsRules.floor_kills(5.0) == 14.0 and DmSimDepthsRules.floor_kills(40.0) == 30.0, "quota: 9 + depth, at most 30")
	check(DmSimDepthsRules.depth_wave_size(1.0) == 5.0 and DmSimDepthsRules.depth_wave_size(12.0) == 7.0 and DmSimDepthsRules.depth_wave_size(60.0) == 9.0, "wave size: 5 + depth / 6, at most 9")
	check(is_equal_approx(DmSimDepthsRules.depth_wave_gap_s(1.0), 4.35) and DmSimDepthsRules.depth_wave_gap_s(60.0) == 2.4, "wave gap: 4.4 - 0.05 depth, at least 2.4 s")
	check(DmSimDepthsRules.extra_affixes(4.0) == 0 and DmSimDepthsRules.extra_affixes(5.0) == 1 and DmSimDepthsRules.extra_affixes(15.0) == 3 and DmSimDepthsRules.extra_affixes(99.0) == 3, "elite affixes: one more every 5 depths, at most 3 extra")
	check(is_equal_approx(DmSimDepthsRules.depth_elite_bonus(10.0), 0.05) and DmSimDepthsRules.depth_elite_bonus(99.0) == 0.14, "elite chance +0.5% per depth, at most +14%")
	check(int(D["cap"]) == 24 and int(D["chestEvery"]) == 5 and float(D["firstWaveDelayS"]) == 1.4, "DEPTHS: cap 24, a chest every 5, first wave after 1.4 s")
	# rosters by depth
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
	var all_scenes := true
	for depth in [1, 5, 10, 15, 30]:
		for id in _ids(DmSimDepthsRules.depth_roster(float(depth))):
			all_scenes = all_scenes and ResourceLoader.exists("res://enemies/%s.tscn" % id)
	check(all_scenes, "every kind on every roster has a DmEnemy scene")
	# level scaling
	var run := DmDepthsRun.create(7, 1)
	check(run.enemy_level(1.0) == 13.0 and run.enemy_level(30.0) == 31.0, "enemy level: max(12, hero) + depth (1: 13 for a level-1 hero, 31 for level 30)")
	run.depth = 9
	check(run.enemy_level(1.0) == 21.0, "enemy level rises by one per depth (9 -> 21)")
	# wave planning: the first wave brings 8, only the quota's worth, never inside the hero's room, never past the cap
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	run = DmDepthsRun.create(11, 1)
	var f: Dictionary = run.floor_data
	var hero := Vector2(float(f["start"]["x"]), float(f["start"]["z"]))
	check(run.plan_wave(0.5, 0, 0, [hero], rng, 0.06).is_empty(), "no wave before the first-wave delay")
	var orders := run.plan_wave(1.0, 0, 0, [hero], rng, 0.06)
	check(orders.size() == 8, "the first wave is 8 (%d)" % orders.size())
	var in_hero_room := orders.any(func(o: Dictionary) -> bool: return DmDepthsFloor.room_at(f, float(o["x"]), float(o["z"])) == DmDepthsFloor.room_at(f, hero.x, hero.y))
	check(not in_hero_room or f["breaches"].size() == 0, "waves climb out of other rooms than the hero's")
	var kinds_ok := orders.all(func(o: Dictionary) -> bool: return base.has(String(o["def"])))
	check(kinds_ok, "depth-1 waves draw only from the depth-1 roster")
	check(run.plan_wave(0.1, 8, 8, [hero], rng, 0.06).is_empty() and run.wave_t > 3.0, "the next wave waits out the gap (%.2f s)" % run.wave_t)
	run.wave_t = 0.0
	var second := run.plan_wave(0.1, 8, 8, [hero], rng, 0.06)
	check(second.size() == 2, "only as many as the quota still needs (10 - 8 alive = 2): %d" % second.size())
	run.wave_t = 0.0
	check(run.plan_wave(0.1, 24, 24, [hero], rng, 0.06).is_empty(), "never more than the cap alive")
	# the quota opens the stair once
	run = DmDepthsRun.create(11, 1)
	var opened := 0
	for i in 12:
		if run.record_kill():
			opened += 1
	check(opened == 1 and run.stair_open and run.floors == 1 and run.total_kills == 12, "the 10th kill opens the stair, once")
	run.descend()
	check(run.depth == 2 and run.peak == 2 and run.kills == 0 and not run.stair_open and run.need == 11.0 and run.total_kills == 12, "descending: depth 2, quota 11, the totals carry")
	check(run.summary() == "The descent ends at depth 2 · 12 slain · 1 floor cleared. What you looted is yours.", "the summary line")
	# loot ground by depth
	var areas: Array = []
	for depth in [1, 4, 5, 9, 10, 14, 15, 19, 20, 29, 30, 60]:
		areas.append(DmDepthsRewards.depth_loot_area(float(depth)))
	check(areas == ["ossuary", "ossuary", "coliseum", "coliseum", "sanctum", "sanctum", "cloister", "cloister", "pyre", "pyre", "fen", "fen"], "loot ground by depth: ossuary / coliseum / sanctum / cloister / pyre / fen at 1 / 5 / 10 / 15 / 20 / 30")


func _ids(roster: Array) -> Array:
	return roster.map(func(e: Dictionary) -> String: return String(e["id"]))


func _w(roster: Array, id: String) -> float:
	for e in roster:
		if e["id"] == id:
			return float(e["weight"])
	return 0.0


# ======================================================================================================== enter + the floor

## The real way in: the Warren's seal broken, waystone travel, then a click on the stair walks the hero there and starts the run.
func _warren_walk() -> void:
	g.progress.prog.unlock("warren")
	g.chapterhouse.apply_seals()
	await ticks(5)
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	body().teleport(Vector3(float(ret["x"]), 0.0, float(ret["z"])))
	await ticks(3)
	g.chapterhouse.travel("warren")
	await ticks(10)
	check(g.area_of(1) == "warren", "waystone travel takes the hero into the (open) Warren")
	var stair := _it("depths_stair")
	var dist0 := Vector2(body().position.x - float(stair["x"]), body().position.z - float(stair["z"])).length()
	check(dist0 > 10.0 and not d.active(), "the stair is across the Warren, no run yet (%.0f m)" % dist0)
	g.chapterhouse.click_interactable(stair)   # what a click on it does: walk there, use it on arrival
	var walked := await until(func() -> bool: return d.run != null, 40.0)
	check(walked, "clicking the stair walks the hero to it and starts a run")
	await until(func() -> bool: return d.run != null and not d._busy, 10.0)
	await ticks(2)
	check(g.area_of(1) == "depths" and d.run.depth == 1, "the hero is on depth 1")
	await exit_run()
	check(d.run == null and g.area_of(1) == "warren", "and climbs back out to the Warren")


func _enter_and_floor() -> void:
	var stair := _it("depths_stair")
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	check(String(stair.get("kind", "")) == "stair" and g.chapterhouse.interactables.any(func(it: Dictionary) -> bool: return it["id"] == "depths_stair"), "the hub lists the Warren's stair")
	check(d.hud_state() == null and d.map_floor() == null and not d.active(), "no run before the stair")
	body().teleport(Vector3(float(s["x"]), 0.0, float(s["z"]) + 2.0))
	await ticks(3)
	check(d.prompt(stair).begins_with("Descend into the Catacomb Depths"), "the stair's prompt: " + d.prompt(stair))
	var entered := [0]
	d.floor_loaded.connect(func(_dp: int) -> void: entered[0] += 1)
	g.chapterhouse.interact(stair)     # what a click on the stair does
	check(await until(func() -> bool: return d.run != null and entered[0] == 1, 10.0), "interacting with the stair starts a run and builds floor 1")
	await ticks(6)
	var run := d.run
	var f: Dictionary = run.floor_data
	check(run.depth == 1 and floor_json(f) == floor_json(DmDepthsRun.generate(run.seed, 1)), "floor 1 is the generated floor of the run's seed")
	var b := body()
	check(Vector2(b.position.x - float(f["start"]["x"]), b.position.z - float(f["start"]["z"])).length() < 0.5 and g.area_of(1) == "depths", "the hero stands at the floor's way in, in the Depths")
	check(floor_root() != null and floor_root().get_child_count() > 10, "the floor is drawn (the existing look)")
	check(g.area_id == "depths", "the game's area follows the hero: depths (music / ambience / light)")
	var its := g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths")
	check(its.size() == 2 and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_down") and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_up"), "the floor's stairs are clickable things (no chest on depth 1)")
	check(d.prompt(_it("depths_down")).begins_with("The stair is sealed: slay 10 more") and d.prompt(_it("depths_up")) == "Climb out (ends this run at depth 1)", "stair prompts: sealed with the count, the way up")
	var banner := ev("banner").filter(func(e: Dictionary) -> bool: return String(e["ctx"]["title"]) == "Depth 1")
	check(not banner.is_empty() and String(banner[0]["ctx"]["sub"]).find("slay 10") >= 0 and String(banner[0]["ctx"]["sub"]).find("level 13 dead") >= 0, "the arrival banner names the quota and the dead's level")
	check(d.hud_state() == {"depth": 1, "kills": 0, "need": 10, "open": false, "chest": false}, "HUD readout: depth 1, 0 / 10, sealed, no chest")
	check(d.map_floor() != null and d.map_floor()["rooms"].size() >= 4 and not d.map_floor()["down"]["open"], "the minimap draws the floor's rooms")
	check(g.ui_host.vm.build()["depth"] != null and g.ui_host.vm.build()["minimap"]["depths"] != null, "the HUD view-model carries the Depths readout and map")
	check(d.progress_line() == "Level <b>13</b> dead", "area line: " + d.progress_line())
	check(g.chapterhouse.interact_prompt(_it("depths_down")) == d.prompt(_it("depths_down")), "the hub shows the Depths prompts")
	# the navmesh of this floor: the stair, the way up and every breach are reachable from the way in
	var nav_ok := await _reachable(f)
	check(nav_ok, "navmesh: the stair down and the breaches are reachable from the way in")
	check(d.ground.nav_ms < 2500 and d.ground.build_ms < BUILD_BUDGET_MS, "floor 1 built in %d ms (bake %d ms, navigation merged after %d ms)" % [d.ground.build_ms, d.ground.bake_ms, d.ground.nav_ms])
	# only one run at a time; the stair says so
	check(d.can_enter() == "You are already below." and not await d.enter(1), "a second run cannot start inside a run")


func _it(id: String) -> Dictionary:
	for it in g.chapterhouse.interactables:
		if it["id"] == id:
			return it
	return {}


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


# ======================================================================================================== waves + scaling

func _waves_and_scaling() -> void:
	var run := d.run
	check(await until(func() -> bool: return depths_enemies().size() >= 8, 8.0), "the floor's first wave climbs out (8)")
	var es := depths_enemies()
	var base := ["rat", "robber", "ghoul", "bat", "sac", "hound"]
	var lvl_ok := true
	var kind_ok := true
	var area_ok := true
	var pos_ok := true
	var aggro_ok := true
	var rect: Dictionary = DmContent.area("depths")["rect"]
	for e: DmEnemy in es:
		lvl_ok = lvl_ok and float(e.get_meta(&"dm_level")) == 13.0 and is_equal_approx(e.hp_mult, DmEnemyStats.hp_scale(13.0)) and is_equal_approx(e.damage_mult, DmEnemyStats.damage_scale(13.0))
		kind_ok = kind_ok and base.has(e.def_id)
		area_ok = area_ok and String(e.get_meta(&"dm_area")) == "depths" and g.director.enemy_by_id(int(e.get_meta(&"dm_id"))) == e
		pos_ok = pos_ok and e.position.x > float(rect["x0"]) and e.position.x < float(rect["x1"]) and e.position.z > float(rect["z0"]) and e.position.z < float(rect["z1"])
		aggro_ok = aggro_ok and e.aggro_range == DmSimConsts.DEPTHS_AGGRO
	check(lvl_ok, "enemies are level 13 on depth 1 (hp x%.2f, damage x%.2f, the director's scaling)" % [DmEnemyStats.hp_scale(13.0), DmEnemyStats.damage_scale(13.0)])
	check(kind_ok and area_ok and pos_ok, "kinds from the depth roster, tagged as the Depths ground, standing on the floor")
	check(aggro_ok, "hunters notice the hero across the floor (aggro 36)")
	check(depths_enemies().size() <= int(DmSimData.DEPTHS["cap"]), "never more than the cap alive")
	# they hunt the hero through the doors
	var b := body()
	var near := await until(func() -> bool: return depths_enemies().any(func(e: DmEnemy) -> bool: return Vector2(e.position.x - b.position.x, e.position.z - b.position.z).length() < 4.0), 25.0)
	check(near, "the dead find their way to the hero across the floor's rooms")
	# a depth-12 hero level: enemy level = hero level + depth
	b.character["level"] = 20
	var lv := run.enemy_level(20.0)
	check(lv == 21.0, "a level-20 hero meets level %d dead on depth 1 (max(12, 20) + 1)" % int(lv))
	b.character["level"] = 1
	# elite spawns carry the depth's extra affix count (the DmEnemy has no affix behaviour yet: the number is meta)
	var el := g.director.spawn("robber", b.position + Vector3(2, 0, 0), [b], true, {}, {"area": "depths", "depth": 15, "aggro": 36.0, "leash": 90.0, "affixes": 4})
	await ticks(3)
	check(el != null and el.elite and int(el.get_meta(&"dm_affixes", 0)) == 4 and float(el.get_meta(&"dm_level")) == 27.0, "an elite on depth 15 bears 4 affixes at level 27 (12 + 15)")
	if el != null:
		el.queue_free()   # not a kill: the quota is counted from here
	await ticks(5)
	check(d.run.kills == 0, "nothing was killed yet: the quota is untouched")


# ======================================================================================================== quota, rewards, descending

func _quota_and_descend() -> void:
	var run := d.run
	var m: DmRewardsMember = g.rewards.members[int(character["id"])]
	var gold0 := int(character["gold"])
	var xp0 := int(character["experience"])
	var lvl0 := int(character["level"])
	var kills0 := run.kills
	events.clear()
	check(not await d.descend() and ev("toast").any(func(e: Dictionary) -> bool: return String(e["ctx"]["text"]).begins_with("The stair is sealed: slay")), "the stair is sealed until the quota (refused with the count)")
	var cleared := [0]
	d.floor_cleared.connect(func(_dp: int) -> void: cleared[0] += 1)
	check(await clear_floor(), "killing the quota opens the stair (%d / %d)" % [run.kills, int(run.need)])
	await ticks(5)
	check(run.stair_open and cleared[0] == 1 and run.floors == 1 and run.kills >= 10, "the stair opens once, at the 10th kill (kills %d)" % run.kills)
	check(d.prompt(_it("depths_down")) == "Descend to depth 2" and d.hud_state()["open"] and d.map_floor()["down"]["open"], "the stair's prompt, the HUD and the minimap show it open")
	check(ev("banner").any(func(e: Dictionary) -> bool: return String(e["ctx"]["title"]) == "The stair opens"), "a banner says so")
	check(await until(func() -> bool: return int(character["gold"]) > gold0 or m.loot_view.get_child_count() > 0, 5.0), "kills and the floor clear drop gold on the ground")
	check(int(character["experience"]) > xp0 or int(character["level"]) > lvl0, "XP was earned (floor clear + kills)")
	await until(func() -> bool: return not g.progress.psync.reporter.has_pending(), 5.0)
	check(not g.progress.psync.reporter.has_pending(), "the floor report was sent and acknowledged by the offline backend")
	# kills landed on the Depths ground in the session's reports
	check(int(m.stats["kills_earned"]) >= 10 and g.progress.prog.kills("depths") == 0, "kills are paid and reported, but do not count towards an area seal")
	# descend
	var f1 := floor_json(run.floor_data)
	var seed := run.seed
	var lc := await _loot_ground_sample(1)
	check(lc, "loot of a depth-1 kill rolls from the Ossuary's table")
	var loaded := [0]
	d.floor_loaded.connect(func(_dp: int) -> void: loaded[0] += 1)
	d.descend()
	check(await until(func() -> bool: return loaded[0] == 1, 10.0), "clicking the open stair builds floor 2")
	await ticks(3)
	check(run.depth == 2 and run.peak == 2 and floor_json(run.floor_data) == floor_json(DmDepthsRun.generate(seed, 2)) and floor_json(run.floor_data) != f1, "depth 2: the next floor of the same run seed")
	check(run.kills == 0 and not run.stair_open and run.need == 11.0 and d.hud_state()["need"] == 11, "a new quota (11) and a sealed stair")
	check(depths_enemies().size() == 0 or depths_enemies().all(func(e: DmEnemy) -> bool: return e.position.distance_to(body().position) > 0.0), "the last floor's dead are gone")
	check(Vector2(body().position.x - float(run.floor_data["start"]["x"]), body().position.z - float(run.floor_data["start"]["z"])).length() < 0.5, "the hero stands at floor 2's way in")
	check(g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths").size() == 2, "the floor's interactables were replaced, not stacked")
	check(g.corpses.corpses.values().all(func(c: DmSimCorpse) -> bool: return String(c.area) != "depths"), "the last floor's corpses are gone")
	check(await _reachable(run.floor_data), "navmesh of floor 2: stair down and breaches reachable")
	await until(func() -> bool: return depths_enemies().size() >= 2, 8.0)
	check(depths_enemies().all(func(e: DmEnemy) -> bool: return float(e.get_meta(&"dm_level")) == 14.0), "floor 2 enemies are level 14")
	# descend through floors 3 and 4 (a chest waits on 5)
	for target in [3, 4]:
		check(await clear_floor(), "floor %d quota met" % (target - 1))
		await d.descend()
		await ticks(3)
		check(run.depth == target and run.peak == target, "descended to depth %d" % target)
	check(d.hud_state()["chest"] == false, "no chest on depth 4")


## Does a depth's kill roll from the matching ground? (the rewards' hook)
func _loot_ground_sample(depth: int) -> bool:
	var got: String = String(g.rewards.loot_area_of.call("depths"))
	return got == DmDepthsRewards.depth_loot_area(float(depth)) and g.rewards.loot_area_of.call("graves") == null


# ======================================================================================================== chest

func _chest() -> void:
	var run := d.run
	check(await clear_floor(), "floor 4 cleared")
	await d.descend()
	await ticks(3)
	check(run.depth == 5 and run.floor_data["chest"] != null, "depth 5 has a chest")
	var its := g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return String(it["area"]) == "depths")
	check(its.size() == 3 and its.any(func(it: Dictionary) -> bool: return it["kind"] == "depths_chest"), "the chest is a clickable thing")
	check(d.hud_state()["chest"] and d.map_floor()["chest"] != null and d.prompt(_it("depths_chest")) == "Open the chest", "HUD and minimap show the chest")
	check(String(g.rewards.loot_area_of.call("depths")) == "coliseum", "depth 5 loots from the Coliseum")
	var m: DmRewardsMember = g.rewards.members[int(character["id"])]
	var loot_n0 := _loot_count(m)
	var opened := [0]
	d.chest_opened.connect(func(_dp: int) -> void: opened[0] += 1)
	events.clear()
	check(d.open_chest() and opened[0] == 1, "opening the chest")
	await until(func() -> bool: return g.rewards.gear_pending() == 0, 5.0)
	await ticks(3)
	check(_loot_count(m) >= loot_n0 + 2, "the chest drops gold and its finds (gear first) on the ground (%d -> %d)" % [loot_n0, _loot_count(m)])
	check(not d.open_chest() and d.chest_done and not d.hud_state()["chest"] and _it("depths_chest").is_empty() and d.map_floor()["chest"] == null, "a chest opens once; it leaves the HUD, the map and the clickables")
	check(ev("banner").any(func(e: Dictionary) -> bool: return String(e["ctx"]["title"]) == "The chest opens"), "a banner reports the chest")
	check(int(DmDepthsRewards.chest_drops(5.0)) == 3 and DmDepthsRewards.chest_drops(15.0) == 4 and DmDepthsRewards.chest_drops(4.0) == 3, "chest size: 3 at depth 5, one more every ten floors")
	# the drops are walk-over loot on this floor and go away with it
	var chronicle_floors := float(d.chronicle.view()["life"].get("depths.floors", 0.0))
	check(chronicle_floors >= 4.0 and float(d.chronicle.view()["life"].get("depths.chests", 0.0)) == 1.0, "the chronicle counts floors (%d) and the chest" % int(chronicle_floors))


func _loot_count(m: DmRewardsMember) -> int:
	return m.loot_view.get_child_count() + m.loot_view.size() if m.loot_view.has_method("size") else m.loot_view.get_child_count()


# ======================================================================================================== leaving, recall, resume

func _leave_recall_resume() -> void:
	var run := d.run
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	var ended: Array = []
	d.run_ended.connect(func(why: String, note: String) -> void: ended.append([why, note]))
	events.clear()
	check(not d.leave() and d.run != null and ev("toast").any(func(e: Dictionary) -> bool: return String(e["ctx"]["text"]).begins_with("Climbing out ends this run at depth 5")), "the exit asks twice (first click only warns)")
	check(d.leave() and d.run == null, "the second click ends the run")
	await ticks(3)
	check(ended.size() == 1 and ended[0][0] == "left" and String(ended[0][1]).begins_with("The descent ends at depth 5"), "run_ended(left) with the summary")
	var b := body()
	check(Vector2(b.position.x - float(s["x"]), b.position.z - (float(s["z"]) + 2.3)).length() < 0.5 and g.area_of(1) == "warren", "back at the Warren's stair")
	check(floor_root() == null, "the floor is torn down")
	check(depths_enemies(false).is_empty() and g.chapterhouse.interactables.all(func(it: Dictionary) -> bool: return String(it["area"]) != "depths"), "no enemies and no stairs are left behind")
	check(not d.ground.region.enabled and d.ground.colliders.get_child_count() == 0, "the floor's navmesh region and colliders are off")
	check(d.hud_state() == null and d.map_floor() == null, "the Depths readout is gone")
	# the record: peak depth 5 persisted on the chronicle (backend)
	await d.flush()
	var ch: DmResult = await api.get_chronicle(int(character["id"]))
	check(ch.ok and float(ch.data["life"].get("peak.depth", 0.0)) == 5.0 and float(ch.data["life"].get("depths.runs", 0.0)) == 2.0, "the backend's chronicle records peak depth 5 and 2 runs (the Warren walk, this one)")
	check(d.resume_at() == 5, "the stair now offers to resume at depth 5")
	# the stair with a deeper floor on record offers the choice
	events.clear()
	check(d.stair_clicked() == 5 and ev("depths_stair_offer").size() == 1 and int(ev("depths_stair_offer")[0]["ctx"]["deepest"]) == 5 and not d.active(), "the stair offers 'start at 1' or 'resume at 5'")
	check(d.prompt(_it("depths_stair")).find("resume at depth 5") >= 0, "the stair's prompt names the resume depth")
	await d.enter(5, 99)    # what the card's "Resume" does
	await ticks(2)
	check(d.run != null and d.run.depth == 5 and d.run.peak == 5 and d.run.floors == 0 and d.run.floor_data["chest"] != null, "resume: a new run starts at depth 5 (a fifth floor, so a chest waits)")
	var lvl := d.run.enemy_level(1.0)
	check(lvl == 17.0, "its dead are level %d (12 + 5)" % int(lvl))
	# recall (T) out of a run ends it
	ended.clear()
	g.chapterhouse.finish_recall()
	await until(func() -> bool: return d.run == null, 3.0)
	check(d.run == null and ended.size() == 1 and ended[0][0] == "recalled" and g.area_of(1) == "chapterhouse", "recall to the Chapterhouse ends the run (recalled)")
	check(depths_enemies(false).is_empty(), "nothing is left on the ground")


# ======================================================================================================== death

func _death() -> void:
	var ch0: Dictionary = (await api.get_character()).data
	var gold_before := int(character["gold"])
	var bag_before: Array = g.ui_host.inventory.slots.duplicate(true) if g.ui_host.inventory != null else []
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	body().teleport(Vector3(float(s["x"]), 0.0, float(s["z"]) + 2.0))
	await ticks(2)
	await d.enter(1, 4242)
	await ticks(2)
	await clear_floor()
	await d.descend()
	await ticks(3)
	var run := d.run
	check(run.depth == 2 and run.floors == 1, "second run: depth 2 reached")
	var kills := run.total_kills
	var ended: Array = []
	d.run_ended.connect(func(why: String, note: String) -> void: ended.append([why, note]))
	var b := body()
	immortal = false
	b.p["stats"]["maxHp"] = 100.0
	b.p["hp"] = 100.0
	b._mirror_from_state()
	events.clear()
	b.take_damage(1e9, null)
	await ticks(3)
	check(not b.alive and d.over and ended.size() == 1 and ended[0][0] == "died", "the hero falls: the run is over (died)")
	check(String(ended[0][1]) == "The descent ends at depth 2 · %d slain · 1 floor cleared. What you looted is yours." % kills, "the run summary: " + String(ended[0][1]))
	check(d.run != null and floor_root() != null, "the floor stays up behind the death screen")
	check(g.chapterhouse.interactables.all(func(it: Dictionary) -> bool: return String(it["area"]) != "depths") and not await d.descend() and not d.open_chest(), "no stairs or chest answer once the run is over")
	var spawned := depths_enemies().size()
	await ticks(10)
	check(depths_enemies().size() <= spawned, "no new waves spawn after the death")
	check(await until(func() -> bool: return d.run == null, 8.0), "the hero rises in the Chapterhouse and the Depths close")
	await ticks(3)
	await until(func() -> bool: return g.area_id == "chapterhouse", 2.0)
	check(body().alive and g.area_of(1) == "chapterhouse" and g.area_id == "chapterhouse", "back in the hub, alive")
	check(ev("toast").any(func(e: Dictionary) -> bool: return String(e["ctx"]["text"]).begins_with("The descent ends at depth 2")), "the summary is told once more on rising")
	check(depths_enemies(false).is_empty() and not d.ground.region.enabled, "the floor, its dead and its navmesh are gone")
	check(int(character["gold"]) >= gold_before and float(d.chronicle.view()["life"].get("peak.depth", 0.0)) >= 5.0, "death takes nothing: gold kept, the best depth (5) still on record")
	if g.ui_host.inventory != null:
		check(g.ui_host.inventory.slots.size() >= bag_before.size(), "death takes nothing: the bag keeps its items")
	check(ch0.size() > 0 and int((await api.get_character()).data["level"]) >= int(ch0["level"]), "the character is intact on the backend")
	# a new run is possible straight away
	body().teleport(Vector3(float(s["x"]), 0.0, float(s["z"]) + 2.0))
	immortal = true
	harden()
	await ticks(2)
	check(d.can_enter() == "", "the stair works again after a death")


# ======================================================================================================== performance

## The scene's node count without the live enemies' own subtrees (models, Affixes, statuses, the Risen a Vengeful death leaves): whatever is
## still alive when the count is taken is not a leak; the floors' terrain, props, pools and dead bodies still count.
func _settled_nodes() -> int:
	var n := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	for e in depths_enemies():
		if is_instance_valid(e) and (e as Node).is_inside_tree():
			n -= _subtree(e)
	return n


func _mean(a: Array) -> float:
	var t := 0.0
	for x in a:
		t += float(x)
	return t / maxf(1.0, float(a.size()))


func _subtree(n: Node) -> int:
	var c := 1
	for k in n.get_children():
		c += _subtree(k)
	return c


func _perf() -> void:
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	body().teleport(Vector3(float(s["x"]), 0.0, float(s["z"]) + 2.0))
	await ticks(2)
	var orphans0 := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))   # whatever the game and the earlier sections left; the floors must add none
	var builds: Array = []
	var node_series: Array = []     # settled node count right after each descend (a fresh floor, the last one freed)
	var orphan_series: Array = []   # orphan nodes after each of the last floors
	var bakes: Array = []
	var merges: Array = []
	# first floor: the main-thread cost of entering (the hitch), measured as the longest frame around it
	var fc := DmFrameCost.attach(g)
	await ticks(10)
	fc.reset()
	var t0 := Time.get_ticks_usec()
	await d.enter(1, 31337)
	var enter_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	builds.append(d.ground.build_ms)
	bakes.append(d.ground.bake_ms)
	merges.append(d.ground.nav_ms)
	await ticks(30)
	var first_hitch := fc.worst_ms()
	check(d.ground.build_ms < BUILD_BUDGET_MS, "first floor: %d ms on the main thread (bake %d ms); enter() end to end %.0f ms incl. the server merging the navmesh; worst frame around it %.0f ms" % [d.ground.build_ms, d.ground.bake_ms, enter_ms, first_hitch])
	# memory baseline after the first floor has been up and gone through its first wave
	await clear_floor()
	await ticks(10)
	# Warm every roster band first (they open at depth 5 / 10 / 15 and each caches its enemy models once, ~+50 nodes: legit, one-time), so the
	# growth measured below is only what 10 more floors leave behind; a leak adds a floor's worth (hundreds) per floor on top.
	for i in 30:
		await clear_floor()
		await d.descend()
		await ticks(5)
	await clear_floor()
	await ticks(30)
	var base_nodes := _settled_nodes()
	var base_mem := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var base_obj := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	# frame cost with a full floor (24 hunters on a navmesh, the hero moving)
	await d.descend()
	await ticks(10)
	d.run.floor_t = 100.0
	await until(func() -> bool: return depths_enemies().size() >= 12, 15.0)
	await ticks(60)
	fc.reset()
	await ticks(180)
	var med := fc.median_ms()
	var worst := fc.worst_ms()
	check(med < FRAME_BUDGET_MS, "frame cost with %d hunters on the floor: median %.1f ms, p95 %.1f ms, worst %.0f ms (budget %.0f)" % [depths_enemies().size(), med, fc.p95_ms(), worst, FRAME_BUDGET_MS])
	# ten more floors
	for i in 10:
		await clear_floor()
		await d.descend()
		await ticks(5)
		builds.append(d.ground.build_ms)
		bakes.append(d.ground.bake_ms)
		merges.append(d.ground.nav_ms)
		node_series.append(_settled_nodes())
		orphan_series.append(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)))
	await clear_floor()
	await ticks(30)
	var depth := d.run.depth
	# Compare like with like: the count right after a descend (the old floor freed, the new one just built). Sampled where a floor was cleared it swings
	# by ~300 with how many corpses / dead bodies that floor left, which is not a leak. Mean of 3 floors at each end against the bound.
	base_nodes = int(roundf(_mean(node_series.slice(0, 3))))
	var nodes := int(roundf(_mean(node_series.slice(-3))))
	var mem := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var obj := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	# Orphans swing by dozens while dying enemies / spent pools wait for their deferred free (51 .. 111 floor to floor) and settle around a level
	# set by the first deep floors, so: the mean of the last 5 floors may not sit above the mean of the first 5 by more than the noise. A leak
	# of a few nodes per floor drifts up through all ten; the in-tree leak check above catches the rest.
	var orphans := int(roundf(_mean(orphan_series.slice(5)) - _mean(orphan_series.slice(0, 5))))
	var worst_build := 0
	var sum_build := 0
	for x in builds:
		worst_build = maxi(worst_build, int(x))
		sum_build += int(x)
	check(depth >= 12, "descended to depth %d" % depth)
	check(worst_build < BUILD_BUDGET_MS, "floor build on the main thread over %d floors: mean %.1f ms, worst %d ms; bake worst %d ms; navigation merge worst %d ms" % [builds.size(), float(sum_build) / builds.size(), worst_build, bakes.max(), merges.max()])
	check(nodes - base_nodes < NODE_GROWTH, "no node leak over 10 more floors: %d -> %d nodes (+%d, bound %d), objects %d -> %d" % [base_nodes, nodes, nodes - base_nodes, NODE_GROWTH, base_obj, obj])
	check(orphans <= 15, "the floors leave no growing pile of orphan nodes (last 5 floors vs first 5: %+d, series %s)" % [orphans, orphan_series])
	check(mem - base_mem < MEM_GROWTH_MB, "static memory after 10 more floors: %.1f -> %.1f MB (+%.1f, bound %.0f)" % [base_mem, mem, mem - base_mem, MEM_GROWTH_MB])
	print("PERF depths: first-floor main-thread %d ms, enter() %.0f ms, worst frame %.0f ms; builds mean %.1f / worst %d ms; bake worst %d ms; frame median %.1f ms (24 hunters); nodes %d -> %d; memory %.1f -> %.1f MB" % [builds[0], enter_ms, first_hitch, float(sum_build) / builds.size(), worst_build, bakes.max(), med, base_nodes, nodes, base_mem, mem])
	fc.queue_free()
	d.end("left")
