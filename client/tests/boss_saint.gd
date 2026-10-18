extends "res://tests/boss_base.gd"
## The Plague Saint on the combat core (the Cloister's boss; archive/old-game:godot/tests/next_bosses/saint_part.gd on today's game, the same numbers and timing). Her rot pools are core zones with her as the
## source (`DmCore.add_zone`), the rot she stands in is the core's list of toxic zones (`DmCore.zones`), her adds are core bodies.
##   - her recorded scenarios replay through the client's copy of the brain (the Plague Doctors' rot scenario among them); the generic parts (boss_base.gd): the summon at the Saint's Litter
##     (5 soul shards), thralls, rites, wipe, defeat, rewards;
##   - the censer swing and Rot Rain at today's ticks and numbers; one toxic pool per circle (r 2, 6 s, dps = the rain's damage x 0.3), credited to her, drawn by the zone visual; a hero in the rot
##     is hurt dps x 1 s once a second, with her core id as the source; a thrall too;
##   - Pestilent Blessing (she heals while she stands in any toxic pool, a sac's too) and the Plague Doctors' link (each doctor in the arena feeds her, the link event names them);
##   - the phases: the rain's circles and cooldowns, P3 pools last 9 s, each wave's bodies on the rim (P2's 2 Plague Doctors and a Flagellant, P3's 3 rats and a Flagellant: core bodies of her
##     area), and the doctors the wave called, real bodies of the core, feeding her through the link.
## Run: godot --headless --path client --script res://tests/boss_saint.gd [--fixed-fps 60 before --path runs it faster than real time]

var S: Dictionary


func _config() -> void:
	boss_id = "saint"
	load_areas = ["cloister"]
	bakes = ["thrall_legionnaire", "skull_rat", "plague_doctor", "flagellant"]
	replay_count = 6


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


## Both waves: P2's two Plague Doctors and a Flagellant, then P3's three rats and a Flagellant (seven bodies).
func provoke_waves() -> void:
	set_hp(0.5)
	wound(0.29)
	check(boss.phase == 3 and adds("rat").size() == 3 and adds("plague_doctor").size() == 2 and adds("flagellant").size() == 2, "(both waves are in the core: %d bodies)" % adds().size())


func run_suite() -> void:
	S = DmContent.get_export("bosses", "SAINT")
	await t_summon(5, 24000.0)
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(7, provoke_waves)
	await t_defeat(true, provoke_waves)
	await t_real_clock(["swing", "rotRain"], 14.0)
	await t_net_state()


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	var s: Dictionary = boss.brain.state
	check(int(s["level"]) == 20 and boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre (44, -121), phase 1, the Cloister's level")
	check(boss.bstate.state == "idle" and boss.bstate.phase == 1, "DmBossView state fed")
	# ---- censer swing: opening cd 2 s, hero within r + 0.5 of her
	put(arena() + Vector3(3.0, 0.0, 0.0))
	step(1.9)
	check(events("swing").is_empty(), "no swing before its opening cooldown (2 s)")
	step(0.2)
	var sw := telegraphs("swing")
	check(sw.size() == 1 and absf(float(sw[0]["t"]) - 2.0) < 0.05, "censer swing telegraphed at 2.0 s")
	if sw.size() == 1:
		var e: Dictionary = sw[0]["ev"]
		check(near(float(e["ms"]), 900.0) and near(float(e["r"]), 4.5), "swing telegraph 900 ms, radius 4.5")
		check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "cone aimed at the hero")
	step(1.0)
	var sh := impacts("swing")
	check(sh.size() == 1 and absf(float(sh[0]["t"]) - float(sw[0]["t"]) - 0.9) < 0.03, "the swing lands 0.9 s after the telegraph")
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - scaled(26.0)) < 1e-6, "swing hurts for 26 x level x difficulty (%.1f)" % (float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0))
	# ---- Rot Rain at 4 s: circles on the hero + random ones, then pools
	step(1.0)   # t ~ 4.1
	var rr := telegraphs("rotRain")
	check(rr.size() == 1 and absf(float(rr[0]["t"]) - 4.0) < 0.05, "Rot Rain telegraphed at 4.0 s")
	var n_circles := 0
	if rr.size() == 1:
		var e2: Dictionary = rr[0]["ev"]
		n_circles = e2["targets"].size()
		check(near(float(e2["ms"]), 1400.0) and near(float(e2["r"]), 2.0), "rain telegraph 1400 ms, circle radius 2")
		check(n_circles >= 3 and n_circles <= 5 and absf(float(e2["targets"][0][0]) - hb.position.x) < 1e-6 and absf(float(e2["targets"][0][1]) - hb.position.z) < 1e-6, "3-5 circles, the first on the hero (%d)" % n_circles)
	check(core.zones("toxic").is_empty() and zones_made("toxic").is_empty(), "no pool before the rain lands")
	var nh := hurts.size()
	step(1.5)
	var ri := impacts("rotRain")
	check(ri.size() == 1 and absf(float(ri[0]["t"]) - float(rr[0]["t"]) - 1.4) < 0.03, "the rain lands 1.4 s later")
	var rain_hurt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(24.0)) < 1e-6)
	check(rain_hurt.size() == 1, "standing in a circle hurts once for 24 x scale (not per circle)")
	var made := zones_made("toxic", boss.core_id)
	check(made.size() == n_circles and core.zones("toxic").size() == 3 * n_circles, "one toxic pool per circle (%d), each a core zone with her id as the source" % made.size())
	if made.size() > 0:
		var pz: Array = made[0]
		check(near(pz[5], 2.0) and near(pz[6], 6.0) and near(pz[3], float(rr[0]["ev"]["targets"][0][0]), 1e-5) and near(pz[4], float(rr[0]["ev"]["targets"][0][1]), 1e-5), "pool r 2, 6 s, at the circle, credited to the boss")
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
	var dps := scaled(24.0) * 0.3
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
	check(absf(gain - boss.max_hp * float(S["blessing"]["healPerS"]) * 2.0) < boss.max_hp * 1e-5, "Pestilent Blessing heals maxHp x 0.6 %%/s while she stands in rot (+%.0f)" % gain)
	var nb := events("blessed").size() - n_bl
	check(nb >= 2 and nb <= 3, "a 'blessed' pulse every 0.8 s (%d)" % nb)
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
	check(boss.world.enemies().filter(func(e: Dictionary) -> bool: return e["def"] == "plague_doctor" and e["area"] == "cloister").size() == 2, "the world reports the doctors in the cloister")
	var every: Array = boss.world.enemies().duplicate(true)
	var doctors: Array = boss.world.enemies_of("plague_doctor").duplicate(true)
	check(doctors == every.filter(func(e: Dictionary) -> bool: return e["def"] == "plague_doctor") and doctors.size() >= 2 and boss.world.enemies_of("not_a_kind").is_empty(),
		"the world's list of her doctors only is the list of every body filtered to them: the same rows in the same order (%d), and an unknown kind has none" % doctors.size())
	var n_link := events("link").size()
	step(1.0)
	var gain2: float = float(boss.brain.state["hp"]) - base_hp
	check(absf(gain2 - boss.max_hp * float(S["doctors"]["healPerS"]) * 2.0) < boss.max_hp * 1e-5, "two Plague Doctors in the arena heal 0.1 %% each per s (+%.0f)" % gain2)
	var lk := events("link").slice(n_link)
	check(lk.size() >= 1 and lk[0]["ev"]["targets"].size() == 2, "'link' event names both doctors (the view draws a beam from each)")
	for did in docs:
		host.remove_enemy(did)
	# ---- phases, adds
	boss.brain._rain_cd = 4.0
	boss.brain._swing_cd = 2.0
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "phase 2 at 60 %")
	var sm_ev := events("summon")
	check(sm_ev.size() == 1 and sm_ev[0]["ev"]["targets"].size() == 3, "summon event with 3 rim spots")
	check(sm_ev[0]["ev"]["targets"].all(func(t: Array) -> bool: return absf(Vector2(float(t[0]) - arena().x, float(t[1]) - arena().z).length() - 8.5) < 0.01), "on the arena rim (0.85 r)")
	var wave2 := adds()
	check(adds("plague_doctor").size() == 2 and adds("flagellant").size() == 1 and wave2.size() == 3, "P2 calls 2 Plague Doctors + 1 Flagellant (core bodies)")
	check(wave2.all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "cloister" and absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - 8.5) < 0.01), "on the arena rim (0.85 r), counted as Cloister enemies")
	# the doctors the wave called feed her through the link: held still, two real bodies, 0.1 % of her health each a second
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
	check(absf(gain3 - boss.max_hp * float(S["doctors"]["healPerS"]) * 2.0) < boss.max_hp * 1e-5, "the wave's two doctors heal her too (+%.0f in a second)" % gain3)
	check(events("link").size() > n_link2 and events("link")[events("link").size() - 1]["ev"]["targets"].size() == 2, "and the link event names them")
	clear_adds()
	hb.teleport(arena() + Vector3(6.0, 0.0, 0.0))
	boss.world.refresh()
	boss.brain.pending.clear()
	boss.brain._rain_cd = 0.0
	step(0.1)
	var rr2 := telegraphs("rotRain")
	var last_rain: Dictionary = rr2[rr2.size() - 1]["ev"]
	check(last_rain["targets"].size() >= 3 and last_rain["targets"].size() <= 5, "P2 rain 3-5 circles")
	check(absf(float(boss.brain._rain_cd) - 7.0 * 0.88) < 0.15, "P2 rain cooldown 7 x 0.88 = 6.16 s")
	step(1.5)
	wait_zones_out(["toxic"])
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	boss.brain.pending.clear()
	step(0.1)
	check(boss.phase == 3, "phase 3 at 30 %")
	check(adds("rat").size() == 3 and adds("flagellant").size() == 1 and adds().size() == 4, "P3 calls 3 rats + a Flagellant (core bodies)")
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
	check(r3["targets"].size() >= 5 and r3["targets"].size() <= 7 and absf(float(boss.brain._rain_cd) - 7.0 * 0.75) < 0.15, "P3 rain 5-7 circles (+2), cooldown 7 x 0.75 = 5.25 s (%d)" % r3["targets"].size())
	step(1.5)
	var p3z := zones_made("toxic", boss.core_id)
	check(p3z.size() == r3["targets"].size() and p3z.all(func(z: Array) -> bool: return near(z[6], 9.0)), "P3 pools last 9 s")
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	await dismiss()
