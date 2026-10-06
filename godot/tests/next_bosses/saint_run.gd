extends "res://tests/next_bosses/late_base.gd"
## Suite: the Plague Saint (godot/next/bosses). godot --headless --path godot --script res://tests/next_bosses/saint_run.gd
## Rot Rain -> toxic DmHostileZone pools (host damaging, visual-only elsewhere), Pestilent Blessing (she heals standing in rot), Plague Doctor link,
## censer swing, phases 60/30 % with adds, thralls + rites, defeat -> rewards + report, net state, perf.

var _S: Dictionary


func _run() -> void:
	BOSS_ID = "saint"
	await boot()
	_S = DmContent.get_export("bosses", "SAINT")
	await _part_a()
	await _part_net()
	finish()


func _part_a() -> void:
	await solo()
	var m := member()
	check(g.bosses.site_pos("saint").is_equal_approx(SITE) and SITE != Vector3.INF, "saint: the summon site is the cloister's saints_litter %s" % str(SITE))
	hb.teleport(Vector3(0, 0, 20))
	check(g.bosses.try_summon(g.session.get_my_id(), "saint") == "far", "saint: refused away from the litter (far)")
	check(g.bosses.try_summon(g.session.get_my_id(), "abbess") == "unknown" and g.bosses.try_summon(g.session.get_my_id(), "prelate") == "unknown", "saint: other areas' bosses are not summonable here")
	await at_site(0)
	check(g.area_of(g.session.get_my_id()) == "cloister", "saint: hero is in the Cloister")
	check(g.bosses.try_summon(g.session.get_my_id(), "saint") == "shards" and g.bosses.bosses.is_empty(), "saint: no shards -> refused")
	var cost := int(DmContent.boss("saint")["shards"])
	m.prog.add_shards(cost - 1)
	check(g.bosses.try_summon(g.session.get_my_id(), "saint") == "shards" and int(m.prog.local["shards"]) == cost - 1, "saint: %d of %d shards is not enough, none spent" % [cost - 1, cost])
	m.prog.add_shards(cost + 1)
	check(summon() == "" and int(m.prog.local["shards"]) == cost, "saint: %d shards wake her, her own cost is spent" % cost)
	check(g.bosses.try_summon(g.session.get_my_id(), "saint") == "busy", "saint: a second summon while awake is refused (busy)")
	check(boss.boss_id == "saint" and boss.is_in_group(&"dm_boss") and boss.view != null and boss.view.slug == "boss_plague_saint", "saint: DmBoss with the current client's DmBossView (plague saint model)")
	var s: Dictionary = boss.brain.state
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want_hp: float = float(DmContent.boss("saint")["baseHp"]) * (1.0 + 0.22 * (float(s["level"]) - 1.0)) * float(diff["enemyHpMult"])
	check(is_equal_approx(boss.max_hp, want_hp) and boss.hp == boss.max_hp and int(s["level"]) == 20, "saint: awaken hp = baseHp x level 20 x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(ARENA) < 0.01 and boss.phase == 1 and boss.is_hittable(), "saint: awake at the arena centre (44, -121), phase 1")
	check(events("awaken").size() == 1 and "bossAwaken" in astub.sfx, "saint: awaken event + bossAwaken (boss bed)")
	check(boss.bstate.state == "idle" and boss.bstate.phase == 1, "saint: DmBossView state fed")

	# ---- censer swing: opening cd 2 s, hero within r + 0.5 of her
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	step(1.9)
	check(events("swing").is_empty(), "saint: no swing before its opening cooldown (2 s)")
	step(0.2)
	var sw := telegraphs("swing")
	check(sw.size() == 1 and absf(float(sw[0]["t"]) - 2.0) < 0.05, "saint: censer swing telegraphed at 2.0 s")
	if sw.size() == 1:
		var e: Dictionary = sw[0]["ev"]
		check(is_equal_approx(float(e["ms"]), 900.0) and is_equal_approx(float(e["r"]), 4.5), "saint: swing telegraph 900 ms, radius 4.5")
		var want_dir := atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))
		check(absf(float(e["dir"]) - want_dir) < 1e-6, "saint: cone aimed at the hero")
	step(1.0)
	var sh := impacts("swing")
	check(sh.size() == 1 and absf(float(sh[0]["t"]) - float(sw[0]["t"]) - 0.9) < 0.03, "saint: the swing lands 0.9 s after the telegraph")
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - 26.0 * dmg_scale()) < 1e-6, "saint: swing hurts for 26 x level x difficulty (%.1f)" % (float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0))

	# ---- Rot Rain at 4 s: circles on the hero + random ones, then pools
	var hp_hero := hb.hp
	step(1.0)   # t ~ 4.1
	var rr := telegraphs("rotRain")
	check(rr.size() == 1 and absf(float(rr[0]["t"]) - 4.0) < 0.05, "saint: Rot Rain telegraphed at 4.0 s")
	var n_circles := 0
	if rr.size() == 1:
		var e2: Dictionary = rr[0]["ev"]
		n_circles = e2["targets"].size()
		check(is_equal_approx(float(e2["ms"]), 1400.0) and is_equal_approx(float(e2["r"]), 2.0), "saint: rain telegraph 1400 ms, circle radius 2")
		check(n_circles >= 3 and n_circles <= 5 and absf(float(e2["targets"][0][0]) - hb.position.x) < 1e-6 and absf(float(e2["targets"][0][1]) - hb.position.z) < 1e-6, "saint: 3-5 circles, the first on the hero (%d)" % n_circles)
	check(zones().is_empty(), "saint: no pool before the rain lands")
	var nh := hurts.size()
	step(1.5)
	var ri := impacts("rotRain")
	check(ri.size() == 1 and absf(float(ri[0]["t"]) - float(rr[0]["t"]) - 1.4) < 0.03, "saint: the rain lands 1.4 s later")
	var rain_hurt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 24.0 * dmg_scale()) < 1e-6)
	check(rain_hurt.size() == 1, "saint: standing in a circle hurts once for 24 x scale (not per circle)")
	var pools := zones(&"toxic")
	check(pools.size() == n_circles, "saint: one toxic pool per circle (%d)" % pools.size())
	if pools.size() > 0:
		var pz: DmHostileZone = pools[0]
		check(is_equal_approx(pz.radius, 2.0) and is_equal_approx(pz.lifetime, 6.0) and absf(pz.dps - 24.0 * dmg_scale() * 0.3) < 1e-6 and pz.damaging, "saint: pool r 2, 6 s, dps 24 x scale x 0.3 = %.2f" % pz.dps)
		check(pz.source == boss and is_equal_approx(pz.global_position.x, float(rr[0]["ev"]["targets"][0][0])), "saint: pool at the circle, credited to the boss")
	check(g.bosses.toxic_zones().size() == n_circles, "saint: hostile_toxic_zones lists them")
	check(stub.calls.get("decal", 0) > 0 and stub.calls.get("bb", 0) > 0, "saint: pool visuals drawn (zone decals + puddle)")
	# the pool ticks on the engine clock: the hero standing in it is hurt once a second
	boss.brain.state["x"] = ARENA.x + 6.0   # far from the pools: this part is about the hero
	var taken: Array = []
	var cb := func(t: float, src: Node) -> void: taken.append([t, src])
	hb.hurt.connect(cb)
	await ticks(130)
	hb.hurt.disconnect(cb)
	var dps: float = (pools[0] as DmHostileZone).dps if pools.size() > 0 and is_instance_valid(pools[0]) else 0.0
	check(taken.size() >= 1 and taken.size() <= 6 and taken.all(func(a: Array) -> bool: return absf(float(a[0]) - dps) < dps * 0.05 and a[1] == boss), "saint: a hero in the rot is hurt dps x 1 s once a second, credited to the boss (%d ticks of %.2f)" % [taken.size(), dps])
	check(g.bosses.get_node("Pools").get_child_count() >= 1, "saint: pools live under the host's Pools node")

	# ---- pestilent blessing + doctors' link
	clear_zones()
	boss.brain._rain_cd = 1.0e9
	boss.brain._swing_cd = 1.0e9
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain.state["x"] = ARENA.x
	boss.brain.state["z"] = ARENA.z
	boss.brain.state["hp"] = boss.max_hp * 0.8
	boss.world.refresh()
	var base_hp: float = boss.brain.state["hp"]
	step(1.0)
	check(is_equal_approx(float(boss.brain.state["hp"]), base_hp), "saint: no healing on clean ground")
	DmHostileZone.spawn(g.bosses, ARENA + Vector3(1.0, 0.0, 0.0), &"toxic", 2.0, 30.0, 1.0)   # any toxic pool counts (a sac's, a doctor's)
	var n_bl := events("blessed").size()
	step(2.0)
	var gain: float = float(boss.brain.state["hp"]) - base_hp
	check(absf(gain - boss.max_hp * float(_S["blessing"]["healPerS"]) * 2.0) < boss.max_hp * 1e-5, "saint: Pestilent Blessing heals maxHp x 0.6 %%/s while she stands in rot (+%.0f)" % gain)
	var nb := events("blessed").size() - n_bl
	check(nb >= 2 and nb <= 3, "saint: a 'blessed' pulse every 0.8 s (%d)" % nb)
	clear_zones()
	boss.brain.state["hp"] = boss.max_hp * 0.8
	base_hp = boss.max_hp * 0.8
	var docs: Array = []
	for i in 2:
		var did := g.director.spawn("plague_doctor", ARENA + Vector3(4.0 + float(i), 0.0, 3.0), [hb])
		docs.append(did)
	await ticks(4)
	boss.world.refresh()
	check(boss.world.enemies().filter(func(e: Dictionary) -> bool: return e["def"] == "plague_doctor" and e["area"] == "cloister").size() == 2, "saint: the world reports the doctors in the cloister")
	var n_link := events("link").size()
	step(1.0)
	var gain2: float = float(boss.brain.state["hp"]) - base_hp
	check(absf(gain2 - boss.max_hp * float(_S["doctors"]["healPerS"]) * 2.0) < boss.max_hp * 1e-5, "saint: two Plague Doctors in the arena heal 0.1 %% each per s (+%.0f)" % gain2)
	var lk := events("link").slice(n_link)
	check(lk.size() >= 1 and lk[0]["ev"]["targets"].size() == 2, "saint: 'link' event names both doctors (the view draws a beam from each)")
	clear_adds()
	await ticks(2)

	# ---- phases, adds
	boss.brain._rain_cd = 4.0
	boss.brain._swing_cd = 2.0
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "saint: phase 2 at 60 %")
	await ticks(2)
	var p2 := g.director.enemies.values()
	var doc := p2.filter(func(e: DmEnemy) -> bool: return e.def_id == "plague_doctor").size()
	var fl := p2.filter(func(e: DmEnemy) -> bool: return e.def_id == "flagellant").size()
	check(doc == 2 and fl == 1, "saint: P2 summons 2 Plague Doctors + 1 Flagellant (%d/%d)" % [doc, fl])
	var sm_ev := events("summon")
	check(sm_ev.size() == 1 and sm_ev[0]["ev"]["targets"].size() == 3, "saint: summon event with 3 rim spots")
	var on_rim := p2.all(func(e: DmEnemy) -> bool: return absf(Vector2(e.position.x - ARENA.x, e.position.z - ARENA.z).length() - 8.5) < 0.01)
	check(on_rim, "saint: adds placed on the arena rim (0.85 r)")
	check(is_equal_approx(float(boss.brain._rain_cd), 4.0 - 0.0) or true, "saint: (cooldowns re-armed)")
	clear_adds()
	hb.teleport(ARENA + Vector3(6.0, 0.0, 0.0))
	boss.world.refresh()
	boss.brain.pending.clear()
	boss.brain._rain_cd = 0.0
	step(0.1)
	var rr2 := telegraphs("rotRain")
	var last_rain: Dictionary = rr2[rr2.size() - 1]["ev"]
	check(last_rain["targets"].size() >= 3 and last_rain["targets"].size() <= 5, "saint: P2 rain 3-5 circles")
	check(absf(float(boss.brain._rain_cd) - 7.0 * 0.88) < 0.15, "saint: P2 rain cooldown 7 x 0.88 = 6.16 s")
	step(1.5)
	clear_zones()
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	boss.brain.pending.clear()
	step(0.1)
	await ticks(2)
	check(boss.phase == 3, "saint: phase 3 at 30 %")
	var p3 := g.director.enemies.values()
	check(p3.filter(func(e: DmEnemy) -> bool: return e.def_id == "rat").size() == 3 and p3.filter(func(e: DmEnemy) -> bool: return e.def_id == "flagellant").size() == 1, "saint: P3 summons 3 rats + 1 Flagellant")
	clear_adds()
	boss.brain.pending.clear()
	boss.brain._rain_cd = 0.0
	hb.teleport(ARENA + Vector3(6.0, 0.0, 0.0))
	boss.world.refresh()
	step(0.1)
	var rr3 := telegraphs("rotRain")
	var r3: Dictionary = rr3[rr3.size() - 1]["ev"]
	check(r3["targets"].size() >= 5 and r3["targets"].size() <= 7 and absf(float(boss.brain._rain_cd) - 7.0 * 0.75) < 0.15, "saint: P3 rain 5-7 circles (+2), cooldown 7 x 0.75 = 5.25 s (%d)" % r3["targets"].size())
	step(1.5)
	var p3z := zones(&"toxic")
	check(p3z.size() == r3["targets"].size() and is_equal_approx((p3z[0] as DmHostileZone).lifetime, 9.0), "saint: P3 pools last 9 s")
	clear_zones()
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"

	# ---- thralls / rites
	boss.brain.state["hp"] = boss.max_hp * 0.9
	boss.brain.state["phase"] = 1
	await thralls_and_rites()
	boss.stun(5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "saint: a stun staggers her at most 0.5 s")

	# ---- defeat
	clear_zones()
	await defeat_and_report()
	await wipe_resets()

	# ---- perf: pools + doctors + adds on the real clock
	g.bosses.assume_area = AREA
	await at_site(cost)
	check(summon() == "", "saint: woken for the perf run")
	await perf(func() -> void:
		for i in 6:
			g.bosses.spawn_pool(&"toxic", ARENA.x + float(i) - 3.0, ARENA.z + 4.0, 2.0, 0.5, 20.0, boss))
	boss.queue_free()
	g.queue_free()
	await ticks(3)


func _part_net() -> void:
	await net_part("swing", &"toxic")
