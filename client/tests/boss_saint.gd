extends "res://tests/boss_base.gd"
## The Plague Saint on the combat core (the Cloister's boss; archive/old-game:godot/tests/next_bosses/saint_part.gd on today's game, the same numbers and timing). Her rot pools are core zones with her as the
## source (`DmCore.add_zone`), the rot she stands in is the core's list of toxic zones (`DmCore.zones`), her adds are core bodies.
##   - her recorded scenarios are replayed by tests/bosses (not here) (the Plague Doctors' rot scenario among them); the generic parts (boss_base.gd): the summon at the Saint's Litter
##     (its soul shards), thralls, rites, wipe, defeat, rewards;
##   - the censer swing and Rot Rain at the ticks of her brain's opening cooldowns and the numbers of the boss data (`SAINT` in bosses.json); one toxic pool per circle (dps = the rain's damage x poolDpsMult),
##     credited to her, drawn by the zone visual; a hero in the rot is hurt dps x 1 s once a second, with her core id as the source; a thrall too;
##   - Pestilent Blessing (she heals while she stands in any toxic pool, a sac's too) and the Plague Doctors' link (each doctor in the arena feeds her, the link event names them);
##   - the phases: the rain's circles and cooldowns, P3 pools last poolSP3, each wave's bodies on the rim (core bodies of her area), and the doctors the wave called, real bodies of the core, feeding her
##     through the link.
## Run: godot --headless --path client --script res://tests/boss_saint.gd [--fixed-fps 60 before --path runs it faster than real time]

## What her brain does that is in its code and not in the boss data (sim/bosses/saint_brain.gd): her cooldowns are scaled by phase, phase 3 adds two circles to the rain, the waves it calls, and the
## 'blessed' pulse every 0.8 s while she stands in rot.
const FAST := [1.0, 0.88, 0.75]
const RAIN_P3_EXTRA := 2
const WAVE2 := ["plague_doctor", "plague_doctor", "flagellant"]
const WAVE3 := ["rat", "rat", "rat", "flagellant"]
const BLESS_BEAT := 0.8

var S: Dictionary


func _config() -> void:
	boss_id = "saint"
	load_areas = ["cloister"]
	bakes = ["thrall_legionnaire", "skull_rat", "plague_doctor", "flagellant"]


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


## Both waves: P2's and then P3's bodies.
func provoke_waves() -> void:
	set_hp(float(PHASE_AT[1]) + 0.2)
	wound_into(3)
	check(boss.phase == 3 and adds("rat").size() == WAVE3.count("rat") and adds("plague_doctor").size() == WAVE2.count("plague_doctor") and adds("flagellant").size() == WAVE2.count("flagellant") + WAVE3.count("flagellant"), "(both waves are in the core: %d bodies)" % adds().size())


func run_suite() -> void:
	S = DmContent.get_export("bosses", "SAINT")
	await t_summon()
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(WAVE2.size() + WAVE3.size(), provoke_waves)
	await t_defeat(true, provoke_waves)
	await t_real_clock(["swing", "rotRain"], 14.0)
	await t_net_state()


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	var s: Dictionary = boss.brain.state
	check(int(s["level"]) == area_level() and boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre, phase 1, the Cloister's level (%d)" % area_level())
	check(boss.bstate.state == "idle" and boss.bstate.phase == 1, "DmBossView state fed")
	var open_swing: float = boss.brain._swing_cd   # her opening cooldowns, as her brain sets them on waking
	var open_rain: float = boss.brain._rain_cd
	var swing_s := float(S["swing"]["windupMs"]) / 1000.0
	var rain_s := float(S["rain"]["windupMs"]) / 1000.0
	var circles: Array = S["rain"]["circles"]
	# ---- censer swing: opening cd, hero within r + 0.5 of her
	put(arena() + Vector3(minf(3.0, float(S["swing"]["r"]) * 0.6), 0.0, 0.0))
	step(open_swing - 0.1)
	check(events("swing").is_empty(), "no swing before its opening cooldown (%.0f s)" % open_swing)
	step(0.2)
	var sw := telegraphs("swing")
	check(sw.size() == 1 and absf(float(sw[0]["t"]) - open_swing) < 0.05, "censer swing telegraphed at %.1f s" % open_swing)
	if sw.size() == 1:
		var e: Dictionary = sw[0]["ev"]
		check(near(float(e["ms"]), float(S["swing"]["windupMs"])) and near(float(e["r"]), float(S["swing"]["r"])), "swing telegraph %d ms, radius %.1f" % [int(S["swing"]["windupMs"]), float(S["swing"]["r"])])
		check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "cone aimed at the hero")
	step(swing_s + 0.1)
	var sh := impacts("swing")
	check(sh.size() == 1 and absf(float(sh[0]["t"]) - float(sw[0]["t"]) - swing_s) < 0.03, "the swing lands %.1f s after the telegraph" % swing_s)
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - scaled(float(S["swing"]["dmg"]))) < 1e-6, "swing hurts for %d x level x difficulty (%.1f)" % [int(S["swing"]["dmg"]), float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0])
	# ---- Rot Rain: circles on the hero + random ones, then pools
	step_until(func() -> bool: return not telegraphs("rotRain").is_empty(), open_rain + swing_s + 1.0)
	var rr := telegraphs("rotRain")
	check(rr.size() == 1 and absf(float(rr[0]["t"]) - maxf(open_rain, float(sw[0]["t"]) + swing_s)) < 0.1, "Rot Rain telegraphed at %.1f s" % open_rain)
	var n_circles := 0
	if rr.size() == 1:
		var e2: Dictionary = rr[0]["ev"]
		n_circles = e2["targets"].size()
		check(near(float(e2["ms"]), float(S["rain"]["windupMs"])) and near(float(e2["r"]), float(S["rain"]["r"])), "rain telegraph %d ms, circle radius %.0f" % [int(S["rain"]["windupMs"]), float(S["rain"]["r"])])
		check(n_circles >= int(circles[0]) and n_circles <= int(circles[1]) and absf(float(e2["targets"][0][0]) - hb.position.x) < 1e-6 and absf(float(e2["targets"][0][1]) - hb.position.z) < 1e-6, "%d to %d circles, the first on the hero (%d)" % [int(circles[0]), int(circles[1]), n_circles])
	check(core.zones("toxic").is_empty() and zones_made("toxic").is_empty(), "no pool before the rain lands")
	var nh := hurts.size()
	step(rain_s + 0.1)
	var ri := impacts("rotRain")
	check(ri.size() == 1 and absf(float(ri[0]["t"]) - float(rr[0]["t"]) - rain_s) < 0.03, "the rain lands %.1f s later" % rain_s)
	var rain_hurt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(float(S["rain"]["dmg"]))) < 1e-6)
	check(rain_hurt.size() == 1, "standing in a circle hurts once for %d x scale (not per circle)" % int(S["rain"]["dmg"]))
	var made := zones_made("toxic", boss.core_id)
	check(made.size() == n_circles and core.zones("toxic").size() == 3 * n_circles, "one toxic pool per circle (%d), each a core zone with her id as the source" % made.size())
	if made.size() > 0:
		var pz: Array = made[0]
		check(near(pz[5], float(S["rain"]["r"])) and near(pz[6], float(S["rain"]["poolS"])) and near(pz[3], float(rr[0]["ev"]["targets"][0][0]), 1e-5) and near(pz[4], float(rr[0]["ev"]["targets"][0][1]), 1e-5), "pool r %.0f, %.0f s, at the circle, credited to the boss" % [float(S["rain"]["r"]), float(S["rain"]["poolS"])])
	check(boss.world.hostile_toxic_zones().size() == n_circles, "hostile_toxic_zones lists them")
	check(stub.calls.get("decal", 0) > 0 and stub.calls.get("bb", 0) > 0, "pool visuals drawn (zone decals + puddle) from the zone events")
	# the pool ticks on the core's clock: the hero standing in it is hurt once a second, credited to her (her core id is the source)
	boss.brain.state["x"] = arena().x + 6.0   # far from the pools: this part is about the hero
	boss.brain._swing_cd = 1.0e9
	var taken: Array = []
	var cb := func(t: float, src: Variant) -> void: taken.append([t, src])
	hb.hurt.connect(cb)
	step(2.2)
	hb.hurt.disconnect(cb)
	var dps := scaled(float(S["rain"]["dmg"])) * float(S["rain"]["poolDpsMult"])
	var pulses := taken.filter(func(a: Array) -> bool: return absf(float(a[0]) - dps) < dps * 0.05)   # (a blow she had already telegraphed may land in the window too)
	check(pulses.size() >= 1 and pulses.size() <= 6 and pulses.all(func(a: Array) -> bool: return a[1] is int and int(a[1]) == boss.core_id),
		"a hero in the rot is hurt dps x 1 s once a second, credited to the boss (%d pulses of %.2f)" % [pulses.size(), dps])
	# ---- Pestilent Blessing + the doctors' link
	boss.brain._rain_cd = 1.0e9
	boss.brain._swing_cd = 1.0e9
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	put(arena() + Vector3(2.0, 0.0, 0.0))   # near enough that she stands where she is
	wait_zones_out(["toxic"])
	boss.brain.state["hp"] = boss.max_hp * 0.8
	var base_hp: float = boss.brain.state["hp"]
	step(1.0)
	check(near(float(boss.brain.state["hp"]), base_hp), "no healing on clean ground")
	core.add_zone("toxic", Vector2(arena().x + 1.0, arena().z), 2.0, 2.2, 1.0, 0)   # any toxic pool counts (a sac's, a doctor's)
	var n_bl := events("blessed").size()
	step(2.0)
	var gain: float = float(boss.brain.state["hp"]) - base_hp
	check(absf(gain - boss.max_hp * float(S["blessing"]["healPerS"]) * 2.0) < boss.max_hp * 1e-5, "Pestilent Blessing heals maxHp x %.1f %%/s while she stands in rot (+%.0f)" % [float(S["blessing"]["healPerS"]) * 100.0, gain])
	var nb := events("blessed").size() - n_bl
	check(nb >= int(2.0 / BLESS_BEAT) and nb <= int(2.0 / BLESS_BEAT) + 1, "a 'blessed' pulse every %.1f s (%d)" % [BLESS_BEAT, nb])
	wait_zones_out(["toxic"])
	boss.brain.state["hp"] = boss.max_hp * 0.8
	base_hp = boss.max_hp * 0.8
	var docs: Array = []
	for i in 2:   # two real Plague Doctors of the core's, held still (a flask would add rot to the blessing under test)
		var did: int = g.director.spawn("plague_doctor", arena() + Vector3(4.0 + float(i), 0.0, 3.0), [hb], false, {}, {"area": "cloister"})
		core.stun(did, 1.0e6)
		docs.append(did)
	await ticks(2)
	boss.world.refresh()
	check(boss.world.enemies().filter(func(e: Dictionary) -> bool: return e["def"] == "plague_doctor" and e["area"] == "cloister").size() == docs.size(), "the world reports the doctors in the cloister")
	var every: Array = boss.world.enemies().duplicate(true)
	var doctors: Array = boss.world.enemies_of("plague_doctor").duplicate(true)
	check(doctors == every.filter(func(e: Dictionary) -> bool: return e["def"] == "plague_doctor") and doctors.size() >= docs.size() and boss.world.enemies_of("not_a_kind").is_empty(),
		"the world's list of her doctors only is the list of every body filtered to them: the same rows in the same order (%d), and an unknown kind has none" % doctors.size())
	var n_link := events("link").size()
	step(1.0)
	var gain2: float = float(boss.brain.state["hp"]) - base_hp
	check(absf(gain2 - boss.max_hp * float(S["doctors"]["healPerS"]) * float(docs.size())) < boss.max_hp * 1e-5, "%d Plague Doctors in the arena heal %.1f %% each per s (+%.0f)" % [docs.size(), float(S["doctors"]["healPerS"]) * 100.0, gain2])
	var lk := events("link").slice(n_link)
	check(lk.size() >= 1 and lk[0]["ev"]["targets"].size() == docs.size(), "'link' event names the doctors (the view draws a beam from each)")
	for did in docs:
		host.remove_enemy(did)
	# ---- phases, adds
	boss.brain._rain_cd = open_rain
	boss.brain._swing_cd = open_swing
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	boss.take_damage(boss.hp - boss.max_hp * just_into(2), hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "phase 2")
	var rim_r := float(def()["arena"]["r"]) * RIM
	var sm_ev := events("summon")
	check(sm_ev.size() == 1 and sm_ev[0]["ev"]["targets"].size() == WAVE2.size(), "summon event with %d rim spots" % WAVE2.size())
	check(sm_ev[0]["ev"]["targets"].all(func(t: Array) -> bool: return absf(Vector2(float(t[0]) - arena().x, float(t[1]) - arena().z).length() - rim_r) < 0.01), "on the arena rim")
	var wave2 := adds()
	check(adds("plague_doctor").size() == WAVE2.count("plague_doctor") and adds("flagellant").size() == WAVE2.count("flagellant") and wave2.size() == WAVE2.size(), "P2 calls its %d bodies (core bodies)" % WAVE2.size())
	check(wave2.all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "cloister" and absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - rim_r) < 0.01), "on the arena rim, counted as Cloister enemies")
	# the doctors the wave called feed her through the link: held still, real bodies, healPerS of her health each a second
	for id in wave2:
		core.stun(id, 1.0e6)
	boss.brain._rain_cd = 1.0e9
	boss.brain._swing_cd = 1.0e9
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	put(arena() + Vector3(2.0, 0.0, 0.0))
	wait_zones_out(["toxic"])
	boss.brain.state["hp"] = boss.max_hp * 0.5
	var base2: float = boss.brain.state["hp"]
	var n_link2 := events("link").size()
	step(1.0)
	var gain3: float = float(boss.brain.state["hp"]) - base2
	var wave_docs := WAVE2.count("plague_doctor")
	check(absf(gain3 - boss.max_hp * float(S["doctors"]["healPerS"]) * float(wave_docs)) < boss.max_hp * 1e-5, "the wave's %d doctors heal her too (+%.0f in a second)" % [wave_docs, gain3])
	check(events("link").size() > n_link2 and events("link")[events("link").size() - 1]["ev"]["targets"].size() == wave_docs, "and the link event names them")
	clear_adds()
	hb.teleport(arena() + Vector3(6.0, 0.0, 0.0))
	boss.world.refresh()
	boss.brain.pending.clear()
	boss.brain._rain_cd = 0.0
	step(0.1)
	var rr2 := telegraphs("rotRain")
	var last_rain: Dictionary = rr2[rr2.size() - 1]["ev"]
	check(last_rain["targets"].size() >= int(circles[0]) and last_rain["targets"].size() <= int(circles[1]), "P2 rain %d to %d circles" % [int(circles[0]), int(circles[1])])
	check(absf(float(boss.brain._rain_cd) - float(S["rain"]["cd"]) * float(FAST[1])) < 0.15, "P2 rain cooldown %d x %.2f s" % [int(S["rain"]["cd"]), float(FAST[1])])
	step(rain_s + 0.1)
	wait_zones_out(["toxic"])
	boss.take_damage(boss.hp - boss.max_hp * just_into(3), hb)
	boss.brain.pending.clear()
	step(0.1)
	check(boss.phase == 3, "phase 3")
	check(adds("rat").size() == WAVE3.count("rat") and adds("flagellant").size() == WAVE3.count("flagellant") and adds().size() == WAVE3.size(), "P3 calls its %d bodies (core bodies)" % WAVE3.size())
	check(adds().all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "cloister"), "(counted as Cloister enemies)")
	clear_adds()
	boss.brain.pending.clear()
	boss.brain._rain_cd = 0.0
	hb.teleport(arena() + Vector3(6.0, 0.0, 0.0))
	boss.world.refresh()
	zone_log.clear()
	step(0.1)
	var rr3 := telegraphs("rotRain")
	var r3: Dictionary = rr3[rr3.size() - 1]["ev"]
	check(r3["targets"].size() >= int(circles[0]) + RAIN_P3_EXTRA and r3["targets"].size() <= int(circles[1]) + RAIN_P3_EXTRA and absf(float(boss.brain._rain_cd) - float(S["rain"]["cd"]) * float(FAST[2])) < 0.15, "P3 rain %d to %d circles (+%d), cooldown %d x %.2f s (%d)" % [int(circles[0]) + RAIN_P3_EXTRA, int(circles[1]) + RAIN_P3_EXTRA, RAIN_P3_EXTRA, int(S["rain"]["cd"]), float(FAST[2]), r3["targets"].size()])
	step(rain_s + 0.1)
	var p3z := zones_made("toxic", boss.core_id)
	check(p3z.size() == r3["targets"].size() and p3z.all(func(z: Array) -> bool: return near(z[6], float(S["rain"]["poolSP3"]))), "P3 pools last %.0f s" % float(S["rain"]["poolSP3"]))
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	await dismiss()
