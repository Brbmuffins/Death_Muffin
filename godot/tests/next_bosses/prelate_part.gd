extends "res://tests/next_bosses/harness.gd"
## The Bell-Sworn Prelate in the slice: part of the boss suite (run.gd drives it)
## The Sanctum is not opened by the slice yet: the hero is teleported into the arena (area-agnostic brain; the world's own rects say "sanctum").
## A: the bell (5 shards through spend_shards: a Prelate summon is owed), Toll / Slam / Bell Rain numbers + timing, the cooldown scale per phase, the
##    Procession of each phase, Prelate Echoes I / II / III through the real vow state (second bell, elite procession, chasing rain), thralls + rites,
##    defeat -> reward (no trophy) + report + the run's Prelate tally / Ascend flag, a wipe.   B: two ENet peers.   C: perf.

const SPAWNS := [[-11.0, -110.0], [11.0, -110.0], [-11.0, -123.0], [11.0, -123.0]]


func _init() -> void:
	boss_id = "prelate"


func _adds(def_id: String = "") -> Array:
	return g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return is_instance_valid(e) and (def_id == "" or e.def_id == def_id) and e.sm.id() != DmEnemyState.Id.DEAD)


func _vows(echo: int) -> void:
	member().prog.local["vows"] = {"prelate_echo": echo}


## Wait (tick by tick) for the next telegraph of `kind`; returns its log entry.
func _next(kind: String, limit: float) -> Dictionary:
	var n := telegraphs(kind).size()
	tick_until(func() -> bool: return telegraphs(kind).size() > n, limit)
	return telegraphs(kind)[n] if telegraphs(kind).size() > n else {"t": -1.0, "ev": {"ms": -1.0, "r": -1.0, "x": 0.0, "z": 0.0, "targets": []}}


func solo() -> void:
	await new_solo()
	member().prog.mode = "local"   # the Prelate's tally is validated by the backend (a summon it was told of); these shards are local, so keep the state local
	await check_prompt_and_key()
	member().prog.local["summonsPending"] = 0   # (the prompt test's bell owed one; the rules below count from here)
	await check_summon_rules(5, "nobody")
	check(int(member().prog.local.get("summonsPending", 0)) == 1, "A: the bell owes the run a Prelate summon (spend_shards, not the area bosses' spend_boss_shards)")
	# ---- awaken
	check(awaken_hp_ok(26000.0), "A: awaken hp = baseHp 26000 x level x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(Vector3(0.0, 0.0, -120.0)) < 0.01 and boss.phase == 1 and boss.is_hittable(), "A: awake 4 m south of the arena centre (0, -120), phase 1")
	check(boss.view != null and boss.view.slug == "prelate", "A: the current client's DmBossView with the Prelate's model")
	check(events("awaken").size() == 1 and "bossAwaken" in astub.sfx, "A: awaken event + bossAwaken sound")
	check(_adds().is_empty() and boss.brain.world.echoes() == 0, "A: no procession yet; no vows sworn = no echoes")
	# ---- lumbers toward the hero at 1.6 m/s
	var z0 := boss.global_position.z
	put(Vector3(0.0, 0.0, -108.0))
	step(1.0)
	check(absf((boss.global_position.z - z0) - 1.6) < 0.05, "A: phase 1 walk 1.6 m/s toward the nearest hero (%.2f m in 1 s)" % (boss.global_position.z - z0))
	# ---- Slam: first at 2.0 s when someone is within 4.5; 2.6 m ahead of her, r 2.6, 900 ms, 20 dmg
	put(Vector3(2.0, 0.0, -118.0))
	step_until(func() -> bool: return not telegraphs("slam").is_empty(), 1.2)
	var sl := telegraphs("slam")
	check(sl.size() == 1 and absf(float(sl[0]["t"]) - 2.0) < 0.05 and is_equal_approx(float(sl[0]["ev"]["ms"]), 900.0) and is_equal_approx(float(sl[0]["ev"]["r"]), 2.6), "A: Slam at t = 2.0 s, 900 ms, r 2.6")
	var bp := boss.global_position
	var se: Dictionary = sl[0]["ev"]
	check(Vector2(float(se["x"]) - bp.x, float(se["z"]) - bp.z).length() < 2.7 and Vector2(float(se["x"]) - bp.x, float(se["z"]) - bp.z).length() > 2.5, "A: the circle lies 2.6 m ahead of her")
	step(1.0)
	check(impacts("slam").size() == 1 and absf(float(impacts("slam")[0]["t"]) - float(sl[0]["t"]) - 0.9) < 0.03 and hurts_of(20.0).size() == 1, "A: the Slam lands 0.9 s later for 20 x level x difficulty")
	# ---- Toll: first at 3.5 s, 6.5 m ring on her, 1500 ms, 24 dmg; no second bell without Echoes
	var tl := _next("toll", 2.0)
	check(absf(float(tl["t"]) - 3.5) < 0.05 and is_equal_approx(float(tl["ev"]["ms"]), 1500.0) and is_equal_approx(float(tl["ev"]["r"]), 6.5) and telegraphs("toll").size() == 1, "A: Toll at t = 3.5 s, 1500 ms, r 6.5, a single bell")
	check(boss.brain.state["state"] == "toll" and boss.bstate.state == "toll", "A: she is in the toll state (the view plays the cast clip)")
	check(boss.brain._toll_cd == 9.0 and boss.brain._slam_cd > 0.0, "A: Toll cooldown 9 s in phase 1")
	hurts.clear()
	step(1.6)
	check(impacts("toll").size() == 1 and hurts_of(24.0).size() == 1, "A: standing in the ring the Toll hurts for 24 x scale")
	# ---- Slam cooldown 3.2 s; stepping out of the circle dodges it
	var sl2 := _next("slam", 5.0)
	check(absf(float(sl2["t"]) - float(sl[0]["t"]) - 3.2) < 0.25, "A: Slam repeats on its 3.2 s cooldown (%.2f)" % (float(sl2["t"]) - float(sl[0]["t"])))
	hurts.clear()
	put(Vector3(11.0, 0.0, -108.0))
	step(1.0)
	check(hurts_of(20.0).is_empty(), "A: leaving the circle dodges the Slam")
	# the second Toll (9 s after the first), hero outside the 6.9 m reach: spared
	var tl2: Dictionary = _next("toll", 12.0)
	check(absf(float(tl2["t"]) - float(tl["t"]) - 9.0) < 0.1, "A: Toll repeats every 9 s (%.2f)" % (float(tl2["t"]) - float(tl["t"])))
	hurts.clear()
	put(Vector3(float(tl2["ev"]["x"]) + 9.0, 0.0, float(tl2["ev"]["z"])))
	step(1.6)
	check(hurts_of(24.0).is_empty(), "A: 9 m from her the Toll misses (reach 6.5 + 0.4)")
	# ---- Phase 2 (60 %): the Procession (4 walkers), Bell Rain, cooldowns x0.82, walk 2.0
	set_hp(0.7)
	put(Vector3(9.0, 0.0, -118.0))
	var n_rain := telegraphs("rain").size()
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	tick_until(func() -> bool: return telegraphs("rain").size() > n_rain, 1.0)   # the Rain is ready the moment phase 2 begins
	var before := _adds().size()
	check(boss.phase == 2 and events("phase").size() == 1 and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 4, "A: phase 2 at 60 %: a summon event over the four aisle spots")
	var adds: Array = _adds()
	check(adds.size() == before + 0 and adds.size() == 4 and _adds("risen").size() == 2 and _adds("penitent").size() == 2, "A: the Procession: 2 Risen + 2 Bellbound Penitents")
	var spots_ok := true
	for i in 4:
		var found := adds.any(func(e: DmEnemy) -> bool: return e.def_id == ("penitent" if i % 2 == 1 else "risen") and Vector2(e.position.x - SPAWNS[i][0], e.position.z - SPAWNS[i][1]).length() < 0.01)
		spots_ok = spots_ok and found
	check(spots_ok and adds.all(func(e: DmEnemy) -> bool: return not e.elite and String(e.get_meta(&"dm_area")) == "sanctum"), "A: they file in from the four aisle spots, not elite (no Echoes), counted as Sanctum enemies")
	var rn: Dictionary = telegraphs("rain")[n_rain]
	var re: Dictionary = rn["ev"]
	check(float(rn["t"]) > 0.0 and is_equal_approx(float(re["ms"]), 1400.0) and is_equal_approx(float(re["r"]), 2.3) and re["targets"].size() == 3, "A: Bell Rain: 1400 ms, r 2.3, a circle on the hero + 2 more in the arena")
	check(absf(float(re["targets"][0][0]) - 9.0) < 1e-6 and absf(float(re["targets"][0][1]) + 118.0) < 1e-6, "A: the first circle is under the hero")
	var rinside := true
	for k in range(1, 3):
		rinside = rinside and Vector2(float(re["targets"][k][0]), float(re["targets"][k][1]) + 116.0).length() <= 13.0
	check(rinside, "A: the others fall inside the arena")
	check(is_equal_approx(boss.brain._rain_cd, 8.0 * 0.82), "A: Rain cooldown 8 x 0.82 s in phase 2")
	hurts.clear()
	step(1.5)
	check(impacts("rain").size() == 1 and hurts_of(18.0).size() == 1, "A: standing under it the Rain hurts for 18 x scale (once, however many circles)")
	# a Toll in phase 2 sets its cooldown to 9 x 0.82
	_next("toll", 12.0)
	check(is_equal_approx(boss.brain._toll_cd, 9.0 * 0.82), "A: Toll cooldown 9 x 0.82 s in phase 2")
	step(1.6)
	# ---- Phase 3 (30 %): six more walkers (the last two shifted 1.5 m), Toll 1200 ms, Slam 720 ms, 4 extra rain circles, cooldowns x0.62
	for e in _adds():
		e.queue_free()
	await ticks(2)
	wound(0.29)
	adds = _adds()
	check(boss.phase == 3 and events("summon").size() == 2 and adds.size() == 6 and _adds("risen").size() == 3 and _adds("penitent").size() == 3, "A: phase 3: six more file in (3 Risen + 3 Penitents)")
	check(adds.any(func(e: DmEnemy) -> bool: return e.def_id == "risen" and Vector2(e.position.x - (SPAWNS[0][0] + 1.5), e.position.z - SPAWNS[0][1]).length() < 0.01) and adds.any(func(e: DmEnemy) -> bool: return e.def_id == "penitent" and Vector2(e.position.x - (SPAWNS[1][0] + 1.5), e.position.z - SPAWNS[1][1]).length() < 0.01), "A: walkers 5 and 6 stand 1.5 m further along the aisle")
	put(Vector3(2.0, 0.0, -116.0))
	var rn3 := _next("rain", 8.0)
	check(rn3["ev"]["targets"].size() == 5 and is_equal_approx(float(rn3["ev"]["ms"]), 1400.0), "A: phase 3 Bell Rain: one on the hero + 4 more")
	check(is_equal_approx(boss.brain._rain_cd, 8.0 * 0.62), "A: Rain cooldown 8 x 0.62 s in phase 3")
	step(1.5)
	var tl4: Dictionary = _next("toll", 12.0)
	check(is_equal_approx(float(tl4["ev"]["ms"]), 1200.0) and is_equal_approx(boss.brain._toll_cd, 9.0 * 0.62), "A: phase 3 Toll 1200 ms (x0.8), cooldown 9 x 0.62 s")
	step(1.3)
	put(Vector3(1.0, 0.0, -112.0))
	var sl4 := _next("slam", 8.0)
	check(is_equal_approx(float(sl4["ev"]["ms"]), 720.0) and is_equal_approx(boss.brain._slam_cd, 3.2 * 0.62), "A: phase 3 Slam 720 ms (x0.8), cooldown 3.2 x 0.62 s")
	step(1.0)
	# ---- thralls + rites; defeat: paid, no trophy, the run's Prelate tally and the Ascend flag
	for e in _adds():
		e.queue_free()
	g.director.enemies.clear()
	hb.heal(1e6)
	await check_thralls()
	await check_rites_and_stun()
	var flags: Array = []
	g.bosses.fx.host.sink = func(id: String, _ctx: Dictionary) -> void: flags.append(id)
	var kills0 := int(member().prog.local["run"]["prelateKills"])
	var pending0 := int(member().prog.local["summonsPending"])
	var after := {}
	after_kill = func() -> void:
		after.merge({"kills": int(member().prog.local["run"]["prelateKills"]), "pending": int(member().prog.local["summonsPending"]), "boss_kills": int(member().prog.local["bossKills"]),
			"trophy": member().trophies.has("prelate"), "flags": flags.duplicate()})
	await check_defeat(false, 0)
	after_kill = Callable()
	check(after["kills"] == kills0 + 1 and after["pending"] == pending0 - 1 and after["boss_kills"] >= 1, "A: the kill counts toward the run's Prelate tally and settles the bell's owed summon (%s)" % [after])
	check(not after["trophy"] and after["flags"].has("can_ascend"), "A: no first-kill trophy (the Prelate is the run's boss); the HUD is told the run can Ascend")
	g.bosses.fx.host.sink = Callable()
	# ---- Echoes I: a second, smaller bell on the farthest hero, 3.4 s from the first telegraph
	await end_fight()
	await ticks(2)
	_vows(1)
	check(summon(5) == "" and boss.brain.world.echoes() == 1, "A: Prelate Echoes I is read from the summoner's vows")
	put(Vector3(2.0, 0.0, -118.0))
	var tn := telegraphs("toll").size()
	tick_until(func() -> bool: return telegraphs("toll").size() >= tn + 2, 5.0)
	var bells := telegraphs("toll").slice(tn)
	check(bells.size() == 2 and absf(float(bells[0]["t"]) - float(bells[1]["t"])) < 1e-6, "A: Echoes I: two bells telegraphed together")
	check(is_equal_approx(float(bells[1]["ev"]["r"]), 3.6) and is_equal_approx(float(bells[1]["ev"]["ms"]), 1300.0 + 1500.0 + 600.0), "A: the second is a 3.6 m ring, 3.4 s out (1300 ms + the first's 1500 ms + 600)")
	check(absf(float(bells[1]["ev"]["x"]) - 2.0) < 1e-6 and absf(float(bells[1]["ev"]["z"]) + 118.0) < 1e-6, "A: it answers on the farthest hero")
	hurts.clear()
	step(3.6)
	check(hurts_of(24.0).size() == 2, "A: staying put, both bells hurt (2 x 24 x scale)")
	check(boss.brain.pending.is_empty() or not boss.brain.pending.any(func(p) -> bool: return p.kind == "toll"), "A: (both bells resolved)")
	wound(0.59)
	check(_adds().size() == 4 and _adds().all(func(e: DmEnemy) -> bool: return not e.elite), "A: Echoes I does not lengthen the Procession")
	check_wipe()
	await ticks(3)
	check(_adds().is_empty(), "A: a reset sends the procession home")
	await end_fight()
	# ---- Echoes II + III: elite procession (+2 walkers, the first two elite), chasing rain
	await ticks(2)
	_vows(3)
	check(summon(5) == "" and boss.brain.world.echoes() == 3, "A: Echoes III from the vows")
	put(Vector3(9.0, 0.0, -118.0))
	wound(0.59)
	adds = _adds()
	check(adds.size() == 6 and adds.filter(func(e: DmEnemy) -> bool: return e.elite).size() == 2 and events("summon").size() == 1, "A: Echoes II: a longer Procession (6) whose first two walkers are elite")
	var elite_ok := adds.filter(func(e: DmEnemy) -> bool: return e.elite).all(func(e: DmEnemy) -> bool: return Vector2(e.position.x - (SPAWNS[0][0] if e.def_id == "risen" else SPAWNS[1][0]), e.position.z - SPAWNS[0][1]).length() < 0.01)
	check(elite_ok, "A: ...the first Risen and the first Penitent (the ones at the head of the aisle)")
	var r1 := _next("rain", 8.0)
	check(r1["ev"]["targets"].size() == 3, "A: the first volley: the hero + 2 circles")
	var chase_n := telegraphs("rain").size()
	put(Vector3(-8.0, 0.0, -112.0))   # the hero runs
	tick_until(func() -> bool: return telegraphs("rain").size() > chase_n, 2.0)
	var r2: Dictionary = telegraphs("rain")[chase_n]
	check(absf(float(r2["t"]) - float(r1["t"]) - 1.6) < 0.03, "A: Echoes III: a second volley 1.6 s after the first (%.2f s)" % (float(r2["t"]) - float(r1["t"])))
	check(is_equal_approx(float(r2["ev"]["ms"]), 1100.0) and r2["ev"]["targets"].size() == 1 and absf(float(r2["ev"]["targets"][0][0]) + 8.0) < 1e-6 and absf(float(r2["ev"]["targets"][0][1]) + 112.0) < 1e-6, "A: 1100 ms, aimed at wherever the hero has run to")
	hurts.clear()
	step(1.3)
	check(hurts_of(18.0).size() == 1, "A: the chasing circle catches a hero who stood still (18 x scale, once)")
	# ---- engine-driven fight + perf
	await end_fight()
	await ticks(2)
	check(summon(5) == "", "A: woken again")
	boss.set_physics_process(true)
	put(Vector3(2.0, 0.0, -118.0))
	await until(func() -> bool: return telegraphs("slam").size() >= 1 and telegraphs("toll").size() >= 1, 10.0)
	check(boss.bstate.active and not telegraphs("toll").is_empty(), "A: the engine-driven Prelate fights (slam + toll on the real clock)")
	boss.set_physics_process(false)
	await end_fight()


# ---- B: two peers --------------------------------------------------------------------------------------------------------------------------

func net() -> void:
	await two_peers_summon()
	var hh := hg.local_body()
	hh.teleport(Vector3(2.0, 0.0, -118.0))
	hboss.world.refresh()
	for i in 215:   # 3.58 s: past the first Toll (3.5 s)
		hboss._physics_process(DT)
		hh.heal(1e6)
	check(await until(func() -> bool: return cboss.telegraphs.any(func(t: Array) -> bool: return String(t[0]) == "toll"), 3.0), "B: the client sees the Toll telegraph in the replicated state")
	var tl: Array = cboss.telegraphs.filter(func(t: Array) -> bool: return String(t[0]) == "toll")[0]
	check(float(tl[1]) <= 1.5 and is_equal_approx(float(tl[2]), 6.5), "B: telegraph kind / time left (%.2f s) / radius replicate" % float(tl[1]))
	hboss.take_damage(hboss.hp - hboss.max_hp * 0.59, hh)
	for i in 10:
		hboss._physics_process(DT)
	check(await until(func() -> bool: return cg.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "risen").size() == 2 and cg.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "penitent").size() == 2, 6.0), "B: phase 2's Procession exists on the client too (director spawner)")
	await two_peers_replication()
	await two_peers_defeat()
	await two_peers_end()
