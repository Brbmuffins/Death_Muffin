extends "res://tests/boss_base.gd"
## The Bell-Sworn Prelate on the combat core (the Bell Sanctum's boss, woken with the Sundered Bell; archive/old-game:godot/tests/next_bosses/prelate_part.gd on today's game, the same numbers and timing). Her
## Procession is core bodies (the Risen and the Bellbound Penitent), her echoes are the world's vows.
##   - her recorded scenarios are replayed by tests/bosses (not here), Prelate Echoes I, II and III among them; the generic parts (boss_base.gd): the bell (5 soul shards), thralls,
##     rites, wipe, defeat, rewards;
##   - the bell takes its shards through `spend_shards` and owes the run a Prelate summon; Slam, Toll and Bell Rain at today's ticks and numbers; the cooldown scale of each phase; each phase's
##     Procession from the four aisle spots (the last two a step further along in phase 3), not elite, counted as Sanctum enemies;
##   - the defeat pays without a first-kill trophy (the Prelate is the run's boss), the run's Prelate tally and the owed summon settle;
##   - Prelate Echoes (DECISIONS B36: Ascension's vows are not in the rebuild): `echoes()` is the world's, which is none, whoever rang the bell and whatever vows the account saved; with the world
##     sworn to them the brain plays them as today (a second bell on the farthest hero, a longer procession whose first two walkers are elite, a chasing volley of rain).
## Run: godot --headless --path client --script res://tests/boss_prelate.gd [--fixed-fps 60 before --path runs it faster than real time]

const SPAWNS := [[-11.0, -110.0], [11.0, -110.0], [-11.0, -123.0], [11.0, -123.0]]


func _config() -> void:
	boss_id = "prelate"
	load_areas = ["sanctum"]
	bakes = ["thrall_legionnaire", "penitent", "skeleton_thrall"]


func adds(def_id := "") -> Array:
	var out: Array = []
	for id in core.enemy_ids():
		var info: Dictionary = core.enemy_info(id)
		if int(info["state"]) != DmCoreEvents.State.DEAD and (def_id == "" or info["def"] == def_id):
			out.append(int(id))
	return out


func clear_adds() -> void:
	for id in adds():
		host.remove_enemy(id)


## Wait (tick by tick) for the next telegraph of `kind`; returns its log entry.
func next(kind: String, limit: float) -> Dictionary:
	var n := telegraphs(kind).size()
	tick_until(func() -> bool: return telegraphs(kind).size() > n, limit)
	return telegraphs(kind)[n] if telegraphs(kind).size() > n else {"t": -1.0, "ev": {"ms": -1.0, "r": -1.0, "x": 0.0, "z": 0.0, "targets": []}}


func run_suite() -> void:
	await t_summon(5, 26000.0)
	await t_bell()
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(4, func() -> void:
		set_hp(0.7)
		wound(0.59)
		check(boss.phase == 2 and adds().size() == 4, "(phase 2: the Procession)"))
	await t_defeat_prelate()
	await t_echoes()
	await t_real_clock(["slam", "toll"], 12.0)
	await t_net_state()


## The bell takes its shards through spend_shards, which also owes the run a Prelate summon (the area bosses' price is spend_boss_shards).
func t_bell() -> void:
	clear_logs()
	member().prog.local["summonsPending"] = 0
	check(wake() == "", "woken for the bell")
	check(int(member().prog.local.get("summonsPending", 0)) == 1, "the bell owes the run a Prelate summon (spend_shards, not the area bosses' spend_boss_shards)")
	await dismiss()


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	check(boss.global_position.distance_to(Vector3(0.0, 0.0, -120.0)) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake 4 m south of the arena centre (0, -120), phase 1")
	check(adds().is_empty() and boss.brain.world.echoes() == 0, "no procession yet; no vows sworn = no echoes")
	# ---- lumbers toward the hero at 1.6 m/s
	var z0 := boss.global_position.z
	put(Vector3(0.0, 0.0, -108.0))
	step(1.0)
	check(absf((boss.global_position.z - z0) - 1.6) < 0.05, "phase 1 walk 1.6 m/s toward the nearest hero (%.2f m in 1 s)" % (boss.global_position.z - z0))
	# ---- Slam: first at 2.0 s when someone is within 4.5; 2.6 m ahead of her, r 2.6, 900 ms, 20 dmg
	put(Vector3(2.0, 0.0, -118.0))
	step_until(func() -> bool: return not telegraphs("slam").is_empty(), 1.2)
	var sl := telegraphs("slam")
	check(sl.size() == 1 and absf(float(sl[0]["t"]) - 2.0) < 0.05 and near(float(sl[0]["ev"]["ms"]), 900.0) and near(float(sl[0]["ev"]["r"]), 2.6), "Slam at t = 2.0 s, 900 ms, r 2.6")
	if sl.is_empty():
		return
	var bp := boss.global_position
	var se: Dictionary = sl[0]["ev"]
	check(Vector2(float(se["x"]) - bp.x, float(se["z"]) - bp.z).length() < 2.7 and Vector2(float(se["x"]) - bp.x, float(se["z"]) - bp.z).length() > 2.5, "the circle lies 2.6 m ahead of her")
	step(1.0)
	check(impacts("slam").size() == 1 and absf(float(impacts("slam")[0]["t"]) - float(sl[0]["t"]) - 0.9) < 0.03 and hurts_of(20.0).size() == 1, "the Slam lands 0.9 s later for 20 x level x difficulty")
	# ---- Toll: first at 3.5 s, 6.5 m ring on her, 1500 ms, 24 dmg; no second bell without Echoes
	var tl := next("toll", 2.0)
	check(absf(float(tl["t"]) - 3.5) < 0.05 and near(float(tl["ev"]["ms"]), 1500.0) and near(float(tl["ev"]["r"]), 6.5) and telegraphs("toll").size() == 1, "Toll at t = 3.5 s, 1500 ms, r 6.5, a single bell")
	check(boss.brain.state["state"] == "toll" and boss.bstate.state == "toll", "she is in the toll state (the view plays the cast clip)")
	check(boss.brain._toll_cd == 9.0 and boss.brain._slam_cd > 0.0, "Toll cooldown 9 s in phase 1")
	hurts.clear()
	step(1.6)
	check(impacts("toll").size() == 1 and hurts_of(24.0).size() == 1, "standing in the ring the Toll hurts for 24 x scale")
	# ---- Slam cooldown 3.2 s; stepping out of the circle dodges it
	var sl2 := next("slam", 5.0)
	check(absf(float(sl2["t"]) - float(sl[0]["t"]) - 3.2) < 0.25, "Slam repeats on its 3.2 s cooldown (%.2f)" % (float(sl2["t"]) - float(sl[0]["t"])))
	hurts.clear()
	put(Vector3(11.0, 0.0, -108.0))
	step(1.0)
	check(hurts_of(20.0).is_empty(), "leaving the circle dodges the Slam")
	# the second Toll (9 s after the first), hero outside the 6.9 m reach: spared
	var tl2: Dictionary = next("toll", 12.0)
	check(absf(float(tl2["t"]) - float(tl["t"]) - 9.0) < 0.1, "Toll repeats every 9 s (%.2f)" % (float(tl2["t"]) - float(tl["t"])))
	hurts.clear()
	put(Vector3(float(tl2["ev"]["x"]) + 9.0, 0.0, float(tl2["ev"]["z"])))
	step(1.6)
	check(hurts_of(24.0).is_empty(), "9 m from her the Toll misses (reach 6.5 + 0.4)")
	# ---- Phase 2 (60 %): the Procession (4 walkers), Bell Rain, cooldowns x0.82, walk 2.0
	set_hp(0.7)
	put(Vector3(9.0, 0.0, -118.0))
	var n_rain := telegraphs("rain").size()
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	tick_until(func() -> bool: return telegraphs("rain").size() > n_rain, 1.0)   # the Rain is ready the moment phase 2 begins
	check(boss.phase == 2 and events("phase").size() == 1 and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 4, "phase 2 at 60 %: a summon event over the four aisle spots")
	var walkers := adds()
	check(walkers.size() == 4 and adds("risen").size() == 2 and adds("penitent").size() == 2, "the Procession: 2 Risen + 2 Bellbound Penitents (core bodies)")
	var spots_ok := true
	for i in 4:
		var want := "penitent" if i % 2 == 1 else "risen"
		var found := walkers.any(func(id: int) -> bool: return core.enemy_info(id)["def"] == want and Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[i][0], SPAWNS[i][1])) < 0.01)
		spots_ok = spots_ok and found
	check(spots_ok and walkers.all(func(id: int) -> bool: return not bool(core.enemy_info(id)["elite"]) and core.enemy_info(id)["area"] == "sanctum"), "they file in from the four aisle spots, not elite (no Echoes), counted as Sanctum enemies")
	var rn: Dictionary = telegraphs("rain")[n_rain]
	var re: Dictionary = rn["ev"]
	check(float(rn["t"]) > 0.0 and near(float(re["ms"]), 1400.0) and near(float(re["r"]), 2.3) and re["targets"].size() == 3, "Bell Rain: 1400 ms, r 2.3, a circle on the hero + 2 more in the arena")
	check(absf(float(re["targets"][0][0]) - 9.0) < 1e-6 and absf(float(re["targets"][0][1]) + 118.0) < 1e-6, "the first circle is under the hero")
	var rinside := true
	for k in range(1, 3):
		rinside = rinside and Vector2(float(re["targets"][k][0]), float(re["targets"][k][1]) + 116.0).length() <= 13.0
	check(rinside, "the others fall inside the arena")
	check(near(boss.brain._rain_cd, 8.0 * 0.82), "Rain cooldown 8 x 0.82 s in phase 2")
	hurts.clear()
	step(1.5)
	check(impacts("rain").size() == 1 and hurts_of(18.0).size() == 1, "standing under it the Rain hurts for 18 x scale (once, however many circles)")
	next("toll", 12.0)
	check(near(boss.brain._toll_cd, 9.0 * 0.82), "Toll cooldown 9 x 0.82 s in phase 2")
	step(1.6)
	# ---- Phase 3 (30 %): six more walkers (the last two shifted 1.5 m), Toll 1200 ms, Slam 720 ms, 4 extra rain circles, cooldowns x0.62
	clear_adds()
	await ticks(2)
	wound(0.29)
	walkers = adds()
	check(boss.phase == 3 and events("summon").size() == 2 and walkers.size() == 6 and adds("risen").size() == 3 and adds("penitent").size() == 3, "phase 3: six more file in (3 Risen + 3 Penitents)")
	check(walkers.any(func(id: int) -> bool: return core.enemy_info(id)["def"] == "risen" and Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[0][0] + 1.5, SPAWNS[0][1])) < 0.01)
		and walkers.any(func(id: int) -> bool: return core.enemy_info(id)["def"] == "penitent" and Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[1][0] + 1.5, SPAWNS[1][1])) < 0.01), "walkers 5 and 6 stand 1.5 m further along the aisle")
	put(Vector3(2.0, 0.0, -116.0))
	var rn3 := next("rain", 8.0)
	check(rn3["ev"]["targets"].size() == 5 and near(float(rn3["ev"]["ms"]), 1400.0), "phase 3 Bell Rain: one on the hero + 4 more")
	check(near(boss.brain._rain_cd, 8.0 * 0.62), "Rain cooldown 8 x 0.62 s in phase 3")
	step(1.5)
	var tl4: Dictionary = next("toll", 12.0)
	check(near(float(tl4["ev"]["ms"]), 1200.0) and near(boss.brain._toll_cd, 9.0 * 0.62), "phase 3 Toll 1200 ms (x0.8), cooldown 9 x 0.62 s")
	step(1.3)
	put(Vector3(1.0, 0.0, -112.0))
	var sl4 := next("slam", 8.0)
	check(near(float(sl4["ev"]["ms"]), 720.0) and near(boss.brain._slam_cd, 3.2 * 0.62), "phase 3 Slam 720 ms (x0.8), cooldown 3.2 x 0.62 s")
	step(1.0)
	clear_adds()
	await dismiss()


## The defeat pays without a first-kill trophy: the run's Prelate tally and the bell's owed summon settle; the HUD is told the run can Ascend (the Altar is not in the rebuild: DECISIONS B36).
func t_defeat_prelate() -> void:
	var mode: String = member().prog.mode
	member().prog.mode = "local"   # the Prelate's tally is validated by the backend (a summon it was told of); these shards are local, so the state stays local while it is read
	var kills0 := int(member().prog.local["run"]["prelateKills"])
	var boss_kills0 := int(member().prog.local["bossKills"])
	var pending0 := int(member().prog.local["summonsPending"])
	var after: Array = []
	after_kill = func() -> void:
		after.append({"kills": int(member().prog.local["run"]["prelateKills"]), "pending": int(member().prog.local["summonsPending"]), "boss_kills": int(member().prog.local["bossKills"]), "trophy": member().trophies.has("prelate")})
	await t_defeat(false)
	after_kill = Callable()
	check(after.size() == 2 and after[0]["kills"] == kills0 + 1 and after[1]["kills"] == kills0 + 2 and after[1]["boss_kills"] == boss_kills0 + 2, "each kill counts toward the run's Prelate tally and the boss kills (%s)" % str(after))
	check(after.size() == 2 and after[0]["pending"] == pending0 and after[1]["pending"] == pending0, "the bell owes a summon when it rings and the kill settles it (%s -> %s, %s)" % [pending0, after[0]["pending"], after[1]["pending"]])
	check(after.size() == 2 and not after[0]["trophy"] and not after[1]["trophy"] and not member().trophies.has("prelate"), "and there is no first-kill trophy (the Prelate is the run's boss)")
	member().prog.mode = mode
	# the HUD hears that the run can Ascend (today's host says so; the rebuild has no Altar, the counsel's tips come later)
	var flags: Array = []
	g.bosses.fx.host.sink = func(id: String, _ctx: Dictionary) -> void: flags.append(id)
	clear_logs()
	check(wake() == "", "woken once more")
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp + 1.0, hb)
	check(flags.has("can_ascend") == member().prog.can_ascend(), "the HUD is told the run can Ascend exactly when the progression says it can (%s)" % str(flags))
	g.bosses.fx.host.sink = Callable()
	await dismiss()


## Prelate Echoes are a vow of Ascension, which the rebuild does not have: the world's vows are none, so `echoes()` is 0 whatever the summoner saved. With the world sworn to them
## (the host's `vow_fx`, where the redesigned Ascension will put them) the brain's code is today's.
func t_echoes() -> void:
	var neutral: Dictionary = g.bosses.vow_fx
	clear_logs()
	member().prog.local["vows"] = {"prelate_echo": 3}   # what today's game would have read; the rebuild does not
	check(wake() == "" and boss.brain.world.echoes() == 0, "a character with Prelate Echoes III saved on the account still plays none (the world has no vows)")
	member().prog.local.erase("vows")
	await dismiss()
	# Echoes I: a second, smaller bell on the farthest hero, 3.4 s from the first telegraph
	g.bosses.vow_fx = {"echoes": 1}
	clear_logs()
	check(wake() == "" and boss.brain.world.echoes() == 1, "Prelate Echoes I is read from the world's vows")
	put(Vector3(2.0, 0.0, -118.0))
	var tn := telegraphs("toll").size()
	tick_until(func() -> bool: return telegraphs("toll").size() >= tn + 2, 5.0)
	var bells := telegraphs("toll").slice(tn)
	check(bells.size() == 2 and absf(float(bells[0]["t"]) - float(bells[1]["t"])) < 1e-6, "Echoes I: two bells telegraphed together")
	check(near(float(bells[1]["ev"]["r"]), 3.6) and near(float(bells[1]["ev"]["ms"]), 1300.0 + 1500.0 + 600.0), "the second is a 3.6 m ring, 3.4 s out (1300 ms + the first's 1500 ms + 600)")
	check(absf(float(bells[1]["ev"]["x"]) - 2.0) < 1e-6 and absf(float(bells[1]["ev"]["z"]) + 118.0) < 1e-6, "it answers on the farthest hero")
	hurts.clear()
	step(3.6)
	check(hurts_of(24.0).size() == 2, "staying put, both bells hurt (2 x 24 x scale)")
	wound(0.59)
	check(adds().size() == 4 and adds().all(func(id: int) -> bool: return not bool(core.enemy_info(id)["elite"])), "Echoes I does not lengthen the Procession")
	await dismiss()
	# Echoes II + III: elite procession (+2 walkers, the first two elite), chasing rain
	g.bosses.vow_fx = {"echoes": 3}
	clear_logs()
	check(wake() == "" and boss.brain.world.echoes() == 3, "Echoes III from the world's vows")
	put(Vector3(9.0, 0.0, -118.0))
	wound(0.59)
	var walkers := adds()
	var elites := walkers.filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"]))
	check(walkers.size() == 6 and elites.size() == 2 and events("summon").size() == 1, "Echoes II: a longer Procession (6) whose first two walkers are elite (core bodies with the elite roll)")
	var elite_ok := elites.all(func(id: int) -> bool:
		var d: String = core.enemy_info(id)["def"]
		return Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[0][0] if d == "risen" else SPAWNS[1][0], SPAWNS[0][1])) < 0.01)
	check(elite_ok, "...the first Risen and the first Penitent (the ones at the head of the aisle)")
	var r1 := next("rain", 8.0)
	check(r1["ev"]["targets"].size() == 3, "the first volley: the hero + 2 circles")
	var chase_n := telegraphs("rain").size()
	put(Vector3(-8.0, 0.0, -112.0))   # the hero runs
	tick_until(func() -> bool: return telegraphs("rain").size() > chase_n, 2.0)
	var r2: Dictionary = telegraphs("rain")[chase_n]
	check(absf(float(r2["t"]) - float(r1["t"]) - 1.6) < 0.03, "Echoes III: a second volley 1.6 s after the first (%.2f s)" % (float(r2["t"]) - float(r1["t"])))
	check(near(float(r2["ev"]["ms"]), 1100.0) and r2["ev"]["targets"].size() == 1 and absf(float(r2["ev"]["targets"][0][0]) + 8.0) < 1e-6 and absf(float(r2["ev"]["targets"][0][1]) + 112.0) < 1e-6, "1100 ms, aimed at wherever the hero has run to")
	hurts.clear()
	step(1.3)
	check(hurts_of(18.0).size() == 1, "the chasing circle catches a hero who stood still (18 x scale, once)")
	g.bosses.vow_fx = neutral
	await dismiss()
