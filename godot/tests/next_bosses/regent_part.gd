extends "res://tests/next_bosses/harness.gd"
## Part of the boss suite (run.gd drives it): the Cinder Regent (godot/next/bosses).
## Coals + Cinder Cleave firebreak + Conflagration (ash circles) -> ember DmHostileZone pools (host damaging, visual-only elsewhere), phases 60/30 % with adds,
## thralls + rites, defeat -> rewards + report, net state.

var _R: Dictionary


func _init() -> void:
	boss_id = "regent"
	god_mode = true   # the hero is unkillable by huge hp (the progression resets the stats now and then)


func _embers() -> Array:
	return zones(&"ember")


func solo() -> void:
	_R = DmContent.get_export("bosses", "REGENT")
	await new_solo()
	var m := member()
	check(g.bosses.site_pos("regent").is_equal_approx(site()) and site() != Vector3.INF, "regent: the summon site is the pyre's ember_altar %s" % str(site()))
	hb.teleport(Vector3(0, 0, 20))
	check(g.bosses.try_summon(g.session.get_my_id(), "regent") == "far", "regent: refused away from the altar (far)")
	await at_site(0)
	set_shards(0)   # (the progression may restore the backend's saved count when the hero changes area)
	check(g.area_of(g.session.get_my_id()) == "pyre", "regent: hero is in the Cinder Pyre")
	check(g.bosses.try_summon(g.session.get_my_id(), "regent") == "shards" and g.bosses.bosses.is_empty(), "regent: no shards -> refused")
	var cost := int(DmContent.boss("regent")["shards"])
	m.prog.add_shards(cost - 1)
	check(g.bosses.try_summon(g.session.get_my_id(), "regent") == "shards" and int(m.prog.local["shards"]) == cost - 1, "regent: %d of %d shards is not enough" % [cost - 1, cost])
	m.prog.add_shards(cost + 1)
	check(wake() == "" and int(m.prog.local["shards"]) == cost, "regent: %d shards wake it, its own cost is spent" % cost)
	check(g.bosses.try_summon(g.session.get_my_id(), "regent") == "busy", "regent: busy while awake")
	check(boss.view != null and boss.view.slug == "boss_cinder_regent", "regent: the current client's DmBossView (cinder regent model)")
	var s: Dictionary = boss.brain.state
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want_hp: float = float(DmContent.boss("regent")["baseHp"]) * (1.0 + 0.22 * (float(s["level"]) - 1.0)) * float(diff["enemyHpMult"])
	check(is_equal_approx(boss.max_hp, want_hp) and int(s["level"]) == 30, "regent: awaken hp = baseHp x level 30 x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "regent: awake at the arena centre (90, -117), phase 1")
	check(events("awaken").size() == 1 and "bossAwaken" in astub.sfx, "regent: awaken event + bossAwaken")

	# ---- Cinder Cleave at 2.0 s
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	step(1.9)
	check(events("cleave").is_empty() and events("coals").is_empty(), "regent: nothing before the opening cooldowns")
	step(0.2)
	var cl := telegraphs("cleave")
	check(cl.size() == 1 and absf(float(cl[0]["t"]) - 2.0) < 0.05, "regent: Cinder Cleave telegraphed at 2.0 s")
	var dir := 0.0
	if cl.size() == 1:
		var e: Dictionary = cl[0]["ev"]
		dir = float(e["dir"])
		check(is_equal_approx(float(e["ms"]), 900.0) and is_equal_approx(float(e["r"]), 5.2), "regent: cleave telegraph 900 ms, radius 5.2")
		check(absf(dir - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "regent: cone aimed at the hero")
	check(_embers().is_empty(), "regent: no firebreak before the blow")
	var ez0: int = g.enemy_fx.stats["zone"]
	step(1.0)
	var ci := impacts("cleave")
	check(ci.size() == 1 and absf(float(ci[0]["t"]) - float(cl[0]["t"]) - 0.9) < 0.03, "regent: the cleave lands 0.9 s later")
	var ch := hurts.filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 28.0 * dmg_scale()) < 1e-6)
	check(ch.size() == 1, "regent: cleave hurts for 28 x level x difficulty (%.1f)" % (float(ch[0]["dmg"]) if ch.size() > 0 else -1.0))
	var trail := _embers()
	check(trail.size() == 3, "regent: the firebreak is 3 ember pools down the line (%d)" % trail.size())
	var okp := trail.size() == 3
	for i in trail.size():
		var d: float = float(_R["cleave"]["trail"][i])
		var zz: DmHostileZone = trail[i]
		var bx := float(cl[0]["ev"]["x"])
		var bz := float(cl[0]["ev"]["z"])
		if not (absf(zz.global_position.x - (bx + sin(dir) * d)) < 1e-4 and absf(zz.global_position.z - (bz + cos(dir) * d)) < 1e-4 and is_equal_approx(zz.radius, 1.4) and is_equal_approx(zz.lifetime, 5.0) and absf(zz.dps - 28.0 * dmg_scale() * 0.3) < 1e-6 and zz.damaging and zz.source == boss):
			okp = false
	check(okp, "regent: trail pools at 1.9 / 3.7 / 5.5 m, r 1.4, 5 s, dps 28 x scale x 0.3, credited to the boss")
	check(g.enemy_fx.stats["zone"] >= ez0 + 3, "regent: the ember pools are drawn by the current client's zone visual (%d)" % (g.enemy_fx.stats["zone"] - ez0))

	# ---- Coals at 3.0 s
	step(0.15)
	var co := telegraphs("coals")
	check(co.size() == 1 and absf(float(co[0]["t"]) - 3.0) < 0.1, "regent: Coals telegraphed right after the cleave (3.0 s)")
	var nco := 0
	if co.size() == 1:
		var e2: Dictionary = co[0]["ev"]
		nco = e2["targets"].size()
		check(is_equal_approx(float(e2["ms"]), 1200.0) and is_equal_approx(float(e2["r"]), 1.8), "regent: coals telegraph 1200 ms, circle radius 1.8")
		check(nco >= 4 and nco <= 6 and absf(float(e2["targets"][0][0]) - hb.position.x) < 1e-6, "regent: 4-6 circles, one on the hero (%d)" % nco)
	clear_zones()
	var nh := hurts.size()
	step(1.3)
	check(impacts("coals").size() == 1 and absf(float(impacts("coals")[0]["t"]) - float(co[0]["t"]) - 1.2) < 0.03, "regent: the coals land 1.2 s later")
	var coal_hurt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 22.0 * dmg_scale()) < 1e-6)
	check(coal_hurt.size() == 1, "regent: standing in a circle hurts once for 22 x scale")
	var cp := _embers()
	check(cp.size() == nco and (cp[0] as DmHostileZone).kind == &"ember" and is_equal_approx((cp[0] as DmHostileZone).radius, 1.8) and is_equal_approx((cp[0] as DmHostileZone).lifetime, 4.0) and absf((cp[0] as DmHostileZone).dps - 22.0 * dmg_scale() * 0.3) < 1e-6, "regent: one ember pool per circle, r 1.8, 4 s, dps 22 x scale x 0.3")
	# an ember pool burns on the engine clock: hero + thrall in it are hurt once a second
	boss.brain.state["x"] = arena().x - 6.0
	var taken: Array = []
	var cb := func(t: float, src: Node) -> void: taken.append([t, src])
	hb.hurt.connect(cb)
	await ticks(130)
	hb.hurt.disconnect(cb)
	var dps: float = (cp[0] as DmHostileZone).dps if cp.size() > 0 and is_instance_valid(cp[0]) else 0.0
	check(taken.size() >= 1 and taken.size() <= 6 and taken.all(func(a: Array) -> bool: return absf(float(a[0]) - dps) < dps * 0.05 and a[1] == boss), "regent: a hero on the coals is hurt dps x 1 s per tick, credited to the boss (%d x %.2f)" % [taken.size(), dps])
	var th: DmThrallHost = hb.get_node("Thralls")
	var rt: Dictionary = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 5.0, "attackSpeedMult": 1.0})
	var tz: DmThrall = rt["thralls"][0]
	clear_zones()
	DmHostileZone.spawn(g.bosses, Vector3(arena().x + 7.0, 0.0, arena().z + 7.0), &"ember", 2.0, 5.0, 10.0, boss)
	tz.set_deferred("global_position", Vector3(arena().x + 7.0, 0.0, arena().z + 7.0))
	await ticks(2)
	var tp := tz.hp
	await ticks(70)
	check(tz.hp < tp, "regent: a thrall standing in the coals burns too (%.0f -> %.0f)" % [tp, tz.hp])
	th.clear()
	clear_zones()
	hb.heal(1e6)

	# ---- Conflagration: the telegraph carries the ash circles; stand off them = 46 x scale, on one = safe
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain._coals_cd = 1.0e9
	boss.brain._cleave_cd = 1.0e9
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5   # the ash spots are random with a 80-try spacing rule: seeded so 4 / 3 circles are exact, not "usually"
	hb.teleport(arena() + Vector3(0.0, 0.0, 0.0))
	boss.world.refresh()
	step(0.05)
	var cf := telegraphs("conflagration")
	check(cf.size() == 1, "regent: Conflagration telegraphed")
	var ash: Array = cf[0]["ev"]["targets"]
	var ev0: Dictionary = cf[0]["ev"]
	check(is_equal_approx(float(ev0["ms"]), 2700.0) and is_equal_approx(float(ev0["r"]), 11.0) and ash.size() == 4, "regent: 2700 ms, whole arena (r 11), 4 ash circles in phase 1 (%d)" % ash.size())
	var spaced := true
	var inside := true
	for i in ash.size():
		inside = inside and Vector2(float(ash[i][0]) - arena().x, float(ash[i][1]) - arena().z).length() <= 11.0 - 2.7 - 0.6 + 1e-6
		for j in range(i + 1, ash.size()):
			spaced = spaced and Vector2(float(ash[i][0]) - float(ash[j][0]), float(ash[i][1]) - float(ash[j][1])).length() > 2.7 * 2.0 + 1.0
	check(spaced and inside, "regent: ash circles are inside the arena and never touch each other")
	check(is_equal_approx(float(boss.brain._confl_cd), 15.0) or absf(float(boss.brain._confl_cd) - 15.0) < 0.1, "regent: Conflagration cooldown 15 s")
	# off the ash: find a spot in the arena clear of every circle
	var off := Vector3.INF
	for k in 48:
		var a := float(k) * 0.37
		var r := 9.5 - float(k % 5) * 1.5
		var cand := arena() + Vector3(sin(a) * r, 0.0, cos(a) * r)
		if ash.all(func(t: Array) -> bool: return Vector2(cand.x - float(t[0]), cand.z - float(t[1])).length() > 2.7 + 0.5):
			off = cand
			break
	check(off != Vector3.INF, "regent: there is room off the ash")
	hb.teleport(off)
	boss.world.refresh()
	nh = hurts.size()
	step(2.8)
	var ci2 := impacts("conflagration")
	check(ci2.size() == 1 and absf(float(ci2[0]["t"]) - float(cf[0]["t"]) - 2.7) < 0.03, "regent: it erupts 2.7 s later")
	var burnt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 46.0 * dmg_scale()) < 1e-6 and h["from"] == "ember")
	check(burnt.size() == 1, "regent: off the ash the eruption hurts for 46 x scale")
	var emb := _embers()
	check(emb.size() >= 1 and emb.size() <= 4 and emb.all(func(z: DmHostileZone) -> bool: return is_equal_approx(z.radius, 1.8) and is_equal_approx(z.lifetime, 4.0)), "regent: what is left of the floor smoulders in up to 4 pools, none on the ash (r 1.8, 4 s) (%d)" % emb.size())
	var on_ash_pool := emb.any(func(z: DmHostileZone) -> bool: return ash.any(func(t: Array) -> bool: return Vector2(z.global_position.x - float(t[0]), z.global_position.z - float(t[1])).length() <= 2.7))
	check(not on_ash_pool, "regent: never on the ash")
	clear_zones()
	# on the ash
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5   # the ash spots are random with a 80-try spacing rule: seeded so 4 / 3 circles are exact, not "usually"
	boss.world.refresh()
	step(0.05)
	var cf2 := telegraphs("conflagration")
	var ash2: Array = cf2[1]["ev"]["targets"]
	hb.teleport(Vector3(float(ash2[0][0]), 0.0, float(ash2[0][1])))
	boss.world.refresh()
	nh = hurts.size()
	step(2.8)
	check(hurts.slice(nh).filter(func(h: Dictionary) -> bool: return h["from"] == "ember").is_empty(), "regent: on an ash circle the eruption does nothing")
	clear_zones()

	# ---- phases, adds, tighter ash
	boss.brain._coals_cd = 1.0e9
	boss.brain._cleave_cd = 1.0e9
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	step(0.1)
	await ticks(2)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "regent: phase 2 at 60 %")
	var p2 := g.director.enemies.values()
	var husk := p2.filter(func(e: DmEnemy) -> bool: return e.def_id == "cinder_husk").size()
	var pri := p2.filter(func(e: DmEnemy) -> bool: return e.def_id == "pyre_priest").size()
	check(husk == 3 and pri == 2, "regent: P2 adds 3 Cinder Husks + 2 Pyre Priests (%d/%d)" % [husk, pri])
	check(events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 5, "regent: summon event with 5 rim spots")
	check(p2.all(func(e: DmEnemy) -> bool: return absf(Vector2(e.position.x - arena().x, e.position.z - arena().z).length() - 11.0 * 0.85) < 0.01), "regent: adds on the arena rim")
	clear_adds()
	boss.brain.pending.clear()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5   # the ash spots are random with a 80-try spacing rule: seeded so 4 / 3 circles are exact, not "usually"
	boss.world.refresh()
	step(0.05)
	var cf3 := telegraphs("conflagration")
	check(cf3[cf3.size() - 1]["ev"]["targets"].size() == 3 and absf(float(boss.brain._confl_cd) - 15.0 * 0.88) < 0.15, "regent: P2 has 3 ash circles, cooldown 15 x 0.88 s")
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain._confl_cd = 1.0e9
	boss.brain._coals_cd = 0.0
	boss.world.refresh()
	step(0.05)
	var co2 := telegraphs("coals")
	check(absf(float(boss.brain._coals_cd) - 7.0 * 0.88) < 0.15, "regent: P2 coals cooldown 7 x 0.88 s")
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	step(0.1)
	await ticks(2)
	check(boss.phase == 3, "regent: phase 3 at 30 %")
	var p3 := g.director.enemies.values()
	check(p3.filter(func(e: DmEnemy) -> bool: return e.def_id == "cinderhound").size() == 2 and p3.filter(func(e: DmEnemy) -> bool: return e.def_id == "cinder_husk").size() == 2, "regent: P3 adds 2 Cinderhounds + 2 Cinder Husks")
	clear_adds()
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain._coals_cd = 0.0
	boss.world.refresh()
	step(0.05)
	var co3 := telegraphs("coals")
	var n3: int = co3[co3.size() - 1]["ev"]["targets"].size()
	check(n3 >= 6 and n3 <= 8 and absf(float(boss.brain._coals_cd) - 7.0 * 0.75) < 0.15, "regent: P3 coals 6-8 circles (+2), cooldown 7 x 0.75 s (%d)" % n3)
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5   # the ash spots are random with a 80-try spacing rule: seeded so 4 / 3 circles are exact, not "usually"
	boss.world.refresh()
	step(0.05)
	var cf4 := telegraphs("conflagration")
	check(cf4[cf4.size() - 1]["ev"]["targets"].size() == 2, "regent: P3 leaves only 2 ash circles")
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	clear_zones()

	# ---- thralls / rites
	boss.brain.state["hp"] = boss.max_hp * 0.9
	boss.brain.state["phase"] = 1
	boss.brain._confl_cd = 1.0e9
	boss.brain._coals_cd = 1.0e9
	boss.brain._cleave_cd = 1.0e9
	await check_rites_and_stun()

	# ---- defeat, wipe
	clear_zones()
	await check_defeat(true, 2)
	await check_rewake_and_wipe()

	# ---- the engine-driven run
	await at_site(cost)
	check(wake() == "", "regent: woken for the engine-driven run")
	await check_engine_run(3.0, func() -> void:
		for i in 8:
			g.bosses.spawn_pool(&"ember", arena().x + float(i) - 4.0, arena().z + 5.0, 1.8, 0.4, 20.0, boss))
	await end_fight()


func net() -> void:
	await two_peers_summon()
	await two_peers_first_telegraph("cleave")
	await two_peers_pools(&"ember")
	await two_peers_defeat()
	await two_peers_end()
