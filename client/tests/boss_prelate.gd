extends "res://tests/boss_base.gd"
## The Bell-Sworn Prelate on the combat core (the Bell Sanctum's boss, woken with the Sundered Bell; archive/old-game:godot/tests/next_bosses/prelate_part.gd on today's game, the same numbers and timing). Her
## Procession is core bodies (the Risen and the Bellbound Penitent), her echoes are the world's vows.
##   - her recorded scenarios are replayed by tests/bosses (not here), Prelate Echoes I, II and III among them; the generic parts (boss_base.gd): the bell (its soul shards), thralls,
##     rites, wipe, defeat, rewards;
##   - the bell takes its shards through `spend_shards` and owes the run a Prelate summon; Slam, Toll and Bell Rain at today's ticks and numbers; the cooldown scale of each phase; each phase's
##     Procession from the four aisle spots (the last two a step further along in phase 3), not elite, counted as Sanctum enemies;
##   - the defeat pays without a first-kill trophy (the Prelate is the run's boss), the run's Prelate tally and the owed summon settle;
##   - Prelate Echoes (DECISIONS B36: Ascension's vows are not in the rebuild): `echoes()` is the world's, which is none, whoever rang the bell and whatever vows the account saved; with the world
##     sworn to them the brain plays them as today (a second bell on the farthest hero, a longer procession whose first two walkers are elite, a chasing volley of rain).
## Run: godot --headless --path client --script res://tests/boss_prelate.gd [--fixed-fps 60 before --path runs it faster than real time]

## The Prelate's brain has no numbers in the boss data (sim/bosses/prelate_brain.gd holds them all): the Procession's four aisle spots, the walkers a phase calls, and the attack numbers below, which are
## its code's, written once here. Her opening cooldowns are read from the brain on waking, her positions from the arena of the boss data.
const SPAWNS := [[-11.0, -110.0], [11.0, -110.0], [-11.0, -123.0], [11.0, -123.0]]
const TOLL := {"dmg": 24.0, "ms": 1500.0, "r": 6.5, "cd": 9.0}
const SLAM := {"dmg": 20.0, "ms": 900.0, "r": 2.6, "cd": 3.2, "reach": 4.5}
const RAIN := {"dmg": 18.0, "ms": 1400.0, "r": 2.3, "cd": 8.0, "extra": [0, 2, 4]}
const FAST := [1.0, 0.82, 0.62]
const WALK := [1.6, 2.0, 2.6]
const PHASE3_QUICK := 0.8   ## in phase 3 her Toll and her Slam wind up in 0.8 of their time
## Prelate Echoes (the vows): the second bell's ring and wind-up (it comes after the first's wind-up and 600 ms more), and the chasing volley's delay and wind-up.
const ECHO_BELL := {"r": 3.6, "ms": 1300.0, "lag": 600.0}
const CHASE := {"after": 1.6, "ms": 1100.0}
const ECHO_WALKERS := 2   ## Prelate Echoes II lengthens the Procession by two walkers
const PROCESSION := [0, 4, 6]   ## the walkers phase 1, 2 and 3 call (phase 3: the last two a step along the aisle)


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
	await t_summon()
	await t_bell()
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(int(PROCESSION[1]), func() -> void:
		set_hp(float(PHASE_AT[0]) + 0.1)
		wound_into(2)
		check(boss.phase == 2 and adds().size() == int(PROCESSION[1]), "(phase 2: the Procession)"))
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
	var open_toll: float = boss.brain._toll_cd   # her opening cooldowns, as her brain sets them on waking
	var open_slam: float = boss.brain._slam_cd
	var open_rain: float = boss.brain._rain_cd
	var a := arena()
	var arena_r := float(def()["arena"]["r"])
	check(boss.global_position.distance_to(a + Vector3(0.0, 0.0, -4.0)) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake 4 m south of the arena centre, phase 1")
	check(adds().is_empty() and boss.brain.world.echoes() == 0, "no procession yet; no vows sworn = no echoes")
	# ---- lumbers toward the hero at her phase 1 walking speed
	var z0 := boss.global_position.z
	put(a + Vector3(0.0, 0.0, 8.0))
	step(1.0)
	check(absf((boss.global_position.z - z0) - float(WALK[0])) < 0.05, "phase 1 walk %.1f m/s toward the nearest hero (%.2f m in 1 s)" % [float(WALK[0]), boss.global_position.z - z0])
	# ---- Slam: first at her opening cooldown when someone is within reach; ahead of her, 900 ms
	put(a + Vector3(2.0, 0.0, -2.0))
	step_until(func() -> bool: return not telegraphs("slam").is_empty(), open_slam)
	var sl := telegraphs("slam")
	check(sl.size() == 1 and absf(float(sl[0]["t"]) - open_slam) < 0.05 and near(float(sl[0]["ev"]["ms"]), float(SLAM["ms"])) and near(float(sl[0]["ev"]["r"]), float(SLAM["r"])), "Slam at t = %.1f s, %.0f ms, r %.1f" % [open_slam, float(SLAM["ms"]), float(SLAM["r"])])
	if sl.is_empty():
		return
	var bp := boss.global_position
	var se: Dictionary = sl[0]["ev"]
	check(Vector2(float(se["x"]) - bp.x, float(se["z"]) - bp.z).length() < float(SLAM["r"]) + 0.1 and Vector2(float(se["x"]) - bp.x, float(se["z"]) - bp.z).length() > float(SLAM["r"]) - 0.1, "the circle lies %.1f m ahead of her" % float(SLAM["r"]))
	step(float(SLAM["ms"]) / 1000.0 + 0.1)
	check(impacts("slam").size() == 1 and absf(float(impacts("slam")[0]["t"]) - float(sl[0]["t"]) - float(SLAM["ms"]) / 1000.0) < 0.03 and hurts_of(float(SLAM["dmg"])).size() == 1, "the Slam lands %.1f s later for %d x level x difficulty" % [float(SLAM["ms"]) / 1000.0, int(SLAM["dmg"])])
	# ---- Toll: first at her opening cooldown, a ring on her; no second bell without Echoes
	var tl := next("toll", open_toll + 1.0)
	check(absf(float(tl["t"]) - open_toll) < 0.05 and near(float(tl["ev"]["ms"]), float(TOLL["ms"])) and near(float(tl["ev"]["r"]), float(TOLL["r"])) and telegraphs("toll").size() == 1, "Toll at t = %.1f s, %.0f ms, r %.1f, a single bell" % [open_toll, float(TOLL["ms"]), float(TOLL["r"])])
	check(boss.brain.state["state"] == "toll" and boss.bstate.state == "toll", "she is in the toll state (the view plays the cast clip)")
	check(boss.brain._toll_cd == float(TOLL["cd"]) and boss.brain._slam_cd > 0.0, "Toll cooldown %.0f s in phase 1" % float(TOLL["cd"]))
	hurts.clear()
	step(float(TOLL["ms"]) / 1000.0 + 0.1)
	check(impacts("toll").size() == 1 and hurts_of(float(TOLL["dmg"])).size() == 1, "standing in the ring the Toll hurts for %d x scale" % int(TOLL["dmg"]))
	# ---- Slam repeats on its cooldown; stepping out of the circle dodges it
	var sl2 := next("slam", 5.0)
	check(absf(float(sl2["t"]) - float(sl[0]["t"]) - float(SLAM["cd"])) < 0.25, "Slam repeats on its %.1f s cooldown (%.2f)" % [float(SLAM["cd"]), float(sl2["t"]) - float(sl[0]["t"])])
	hurts.clear()
	put(a + Vector3(11.0, 0.0, 8.0))
	step(1.0)
	check(hurts_of(float(SLAM["dmg"])).is_empty(), "leaving the circle dodges the Slam")
	# the second Toll (a cooldown after the first), hero outside her reach: spared
	var tl2: Dictionary = next("toll", 12.0)
	check(absf(float(tl2["t"]) - float(tl["t"]) - float(TOLL["cd"])) < 0.1, "Toll repeats every %.0f s (%.2f)" % [float(TOLL["cd"]), float(tl2["t"]) - float(tl["t"])])
	hurts.clear()
	put(Vector3(float(tl2["ev"]["x"]) + float(TOLL["r"]) + 2.5, 0.0, float(tl2["ev"]["z"])))
	step(float(TOLL["ms"]) / 1000.0 + 0.1)
	check(hurts_of(float(TOLL["dmg"])).is_empty(), "%.1f m from her the Toll misses (reach %.1f + 0.4)" % [float(TOLL["r"]) + 2.5, float(TOLL["r"])])
	# ---- Phase 2: the Procession, Bell Rain, cooldowns scaled, her walk faster
	set_hp(float(PHASE_AT[0]) + 0.1)
	put(a + Vector3(9.0, 0.0, -2.0))
	var n_rain := telegraphs("rain").size()
	boss.take_damage(boss.hp - boss.max_hp * just_into(2), hb)
	tick_until(func() -> bool: return telegraphs("rain").size() > n_rain, open_rain)   # the Rain is ready the moment phase 2 begins
	check(boss.phase == 2 and events("phase").size() == 1 and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == SPAWNS.size(), "phase 2: a summon event over the %d aisle spots" % SPAWNS.size())
	var walkers := adds()
	check(walkers.size() == int(PROCESSION[1]) and adds("risen").size() == int(PROCESSION[1]) / 2 and adds("penitent").size() == int(PROCESSION[1]) / 2, "the Procession: %d Risen + %d Bellbound Penitents (core bodies)" % [int(PROCESSION[1]) / 2, int(PROCESSION[1]) / 2])
	var spots_ok := true
	for i in int(PROCESSION[1]):
		var want := "penitent" if i % 2 == 1 else "risen"
		var found := walkers.any(func(id: int) -> bool: return core.enemy_info(id)["def"] == want and Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[i][0], SPAWNS[i][1])) < 0.01)
		spots_ok = spots_ok and found
	check(spots_ok and walkers.all(func(id: int) -> bool: return not bool(core.enemy_info(id)["elite"]) and core.enemy_info(id)["area"] == "sanctum"), "they file in from the aisle spots, not elite (no Echoes), counted as Sanctum enemies")
	var rn: Dictionary = telegraphs("rain")[n_rain]
	var re: Dictionary = rn["ev"]
	check(float(rn["t"]) > 0.0 and near(float(re["ms"]), float(RAIN["ms"])) and near(float(re["r"]), float(RAIN["r"])) and re["targets"].size() == 1 + int(RAIN["extra"][1]), "Bell Rain: %.0f ms, r %.1f, a circle on the hero + %d more in the arena" % [float(RAIN["ms"]), float(RAIN["r"]), int(RAIN["extra"][1])])
	check(absf(float(re["targets"][0][0]) - (a.x + 9.0)) < 1e-6 and absf(float(re["targets"][0][1]) - (a.z - 2.0)) < 1e-6, "the first circle is under the hero")
	var rinside := true
	for k in range(1, re["targets"].size()):
		rinside = rinside and Vector2(float(re["targets"][k][0]) - a.x, float(re["targets"][k][1]) - a.z).length() <= arena_r
	check(rinside, "the others fall inside the arena")
	check(near(boss.brain._rain_cd, float(RAIN["cd"]) * float(FAST[1])), "Rain cooldown %.0f x %.2f s in phase 2" % [float(RAIN["cd"]), float(FAST[1])])
	hurts.clear()
	step(float(RAIN["ms"]) / 1000.0 + 0.1)
	check(impacts("rain").size() == 1 and hurts_of(float(RAIN["dmg"])).size() == 1, "standing under it the Rain hurts for %d x scale (once, however many circles)" % int(RAIN["dmg"]))
	next("toll", 12.0)
	check(near(boss.brain._toll_cd, float(TOLL["cd"]) * float(FAST[1])), "Toll cooldown %.0f x %.2f s in phase 2" % [float(TOLL["cd"]), float(FAST[1])])
	step(float(TOLL["ms"]) / 1000.0 + 0.1)
	# ---- Phase 3: six more walkers (the last two shifted along the aisle), Toll and Slam quicker, more rain circles, cooldowns scaled again
	clear_adds()
	await ticks(2)
	wound_into(3)
	walkers = adds()
	check(boss.phase == 3 and events("summon").size() == 2 and walkers.size() == int(PROCESSION[2]) and adds("risen").size() == int(PROCESSION[2]) / 2 and adds("penitent").size() == int(PROCESSION[2]) / 2, "phase 3: %d more file in (%d Risen + %d Penitents)" % [int(PROCESSION[2]), int(PROCESSION[2]) / 2, int(PROCESSION[2]) / 2])
	check(walkers.any(func(id: int) -> bool: return core.enemy_info(id)["def"] == "risen" and Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[0][0] + 1.5, SPAWNS[0][1])) < 0.01)
		and walkers.any(func(id: int) -> bool: return core.enemy_info(id)["def"] == "penitent" and Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[1][0] + 1.5, SPAWNS[1][1])) < 0.01), "the last walkers stand 1.5 m further along the aisle")
	put(a + Vector3(2.0, 0.0, 0.0))
	var rn3 := next("rain", 2.0 * float(RAIN["cd"]))
	check(rn3["ev"]["targets"].size() == 1 + int(RAIN["extra"][2]) and near(float(rn3["ev"]["ms"]), float(RAIN["ms"])), "phase 3 Bell Rain: one on the hero + %d more" % int(RAIN["extra"][2]))
	check(near(boss.brain._rain_cd, float(RAIN["cd"]) * float(FAST[2])), "Rain cooldown %.0f x %.2f s in phase 3" % [float(RAIN["cd"]), float(FAST[2])])
	step(float(RAIN["ms"]) / 1000.0 + 0.1)
	var tl4: Dictionary = next("toll", 12.0)
	check(near(float(tl4["ev"]["ms"]), float(TOLL["ms"]) * PHASE3_QUICK) and near(boss.brain._toll_cd, float(TOLL["cd"]) * float(FAST[2])), "phase 3 Toll %.0f ms (x%.1f), cooldown %.0f x %.2f s" % [float(TOLL["ms"]) * PHASE3_QUICK, PHASE3_QUICK, float(TOLL["cd"]), float(FAST[2])])
	step(1.3)
	put(a + Vector3(1.0, 0.0, 4.0))
	var sl4 := next("slam", 8.0)
	check(near(float(sl4["ev"]["ms"]), float(SLAM["ms"]) * PHASE3_QUICK) and near(boss.brain._slam_cd, float(SLAM["cd"]) * float(FAST[2])), "phase 3 Slam %.0f ms (x%.1f), cooldown %.1f x %.2f s" % [float(SLAM["ms"]) * PHASE3_QUICK, PHASE3_QUICK, float(SLAM["cd"]), float(FAST[2])])
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
	# Echoes I: a second, smaller bell on the farthest hero, a little after the first's wind-up
	g.bosses.vow_fx = {"echoes": 1}
	clear_logs()
	check(wake() == "" and boss.brain.world.echoes() == 1, "Prelate Echoes I is read from the world's vows")
	var at1 := arena() + Vector3(2.0, 0.0, -2.0)
	put(at1)
	var tn := telegraphs("toll").size()
	tick_until(func() -> bool: return telegraphs("toll").size() >= tn + 2, 5.0)
	var bells := telegraphs("toll").slice(tn)
	var bell_ms: float = float(ECHO_BELL["ms"]) + float(TOLL["ms"]) + float(ECHO_BELL["lag"])
	check(bells.size() == 2 and absf(float(bells[0]["t"]) - float(bells[1]["t"])) < 1e-6, "Echoes I: two bells telegraphed together")
	check(near(float(bells[1]["ev"]["r"]), float(ECHO_BELL["r"])) and near(float(bells[1]["ev"]["ms"]), bell_ms), "the second is a %.1f m ring, %.1f s out (%.0f ms + the first's %.0f ms + %.0f)" % [float(ECHO_BELL["r"]), bell_ms / 1000.0, float(ECHO_BELL["ms"]), float(TOLL["ms"]), float(ECHO_BELL["lag"])])
	check(absf(float(bells[1]["ev"]["x"]) - at1.x) < 1e-6 and absf(float(bells[1]["ev"]["z"]) - at1.z) < 1e-6, "it answers on the farthest hero")
	hurts.clear()
	step(bell_ms / 1000.0 + 0.2)
	check(hurts_of(float(TOLL["dmg"])).size() == 2, "staying put, both bells hurt (2 x %d x scale)" % int(TOLL["dmg"]))
	wound_into(2)
	check(adds().size() == int(PROCESSION[1]) and adds().all(func(id: int) -> bool: return not bool(core.enemy_info(id)["elite"])), "Echoes I does not lengthen the Procession")
	await dismiss()
	# Echoes II + III: elite procession (+2 walkers, the first two elite), chasing rain
	g.bosses.vow_fx = {"echoes": 3}
	clear_logs()
	check(wake() == "" and boss.brain.world.echoes() == 3, "Echoes III from the world's vows")
	put(arena() + Vector3(9.0, 0.0, -2.0))
	wound_into(2)
	var walkers := adds()
	var elites := walkers.filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"]))
	check(walkers.size() == int(PROCESSION[1]) + ECHO_WALKERS and elites.size() == 2 and events("summon").size() == 1, "Echoes II: a longer Procession (%d) whose first two walkers are elite (core bodies with the elite roll)" % (int(PROCESSION[1]) + ECHO_WALKERS))
	var elite_ok := elites.all(func(id: int) -> bool:
		var d: String = core.enemy_info(id)["def"]
		return Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(SPAWNS[0][0] if d == "risen" else SPAWNS[1][0], SPAWNS[0][1])) < 0.01)
	check(elite_ok, "...the first Risen and the first Penitent (the ones at the head of the aisle)")
	var r1 := next("rain", 2.0 * float(RAIN["cd"]))
	check(r1["ev"]["targets"].size() == 1 + int(RAIN["extra"][1]), "the first volley: the hero + %d circles" % int(RAIN["extra"][1]))
	var chase_n := telegraphs("rain").size()
	var ran_to := arena() + Vector3(-8.0, 0.0, 4.0)
	put(ran_to)   # the hero runs
	tick_until(func() -> bool: return telegraphs("rain").size() > chase_n, 2.0)
	var r2: Dictionary = telegraphs("rain")[chase_n]
	check(absf(float(r2["t"]) - float(r1["t"]) - float(CHASE["after"])) < 0.03, "Echoes III: a second volley %.1f s after the first (%.2f s)" % [float(CHASE["after"]), float(r2["t"]) - float(r1["t"])])
	check(near(float(r2["ev"]["ms"]), float(CHASE["ms"])) and r2["ev"]["targets"].size() == 1 and absf(float(r2["ev"]["targets"][0][0]) - ran_to.x) < 1e-6 and absf(float(r2["ev"]["targets"][0][1]) - ran_to.z) < 1e-6, "%.0f ms, aimed at wherever the hero has run to" % float(CHASE["ms"]))
	hurts.clear()
	step(float(CHASE["ms"]) / 1000.0 + 0.2)
	check(hurts_of(float(RAIN["dmg"])).size() == 1, "the chasing circle catches a hero who stood still (%d x scale, once)" % int(RAIN["dmg"]))
	g.bosses.vow_fx = neutral
	await dismiss()
