extends "res://tests/next_bosses/harness.gd"
## Part of the boss suite (run.gd drives it): the Mire Mother (godot/next/bosses).
## Maul, Drowned Hands (root, wading only), Surface (sinks = untargetable for rites / thralls / the pick, ripple ring, winded), P2 flood, P3 Drowned Rite
## (raises a Risen from every corpse in the Fen through DmCorpseField; no corpses = she staggers), thralls + rites, defeat -> rewards + report, net state.

var _M: Dictionary


func _init() -> void:
	boss_id = "mire"
	god_mode = true   # the hero is unkillable by huge hp (the progression resets the stats now and then)


func _quiet(maul: float = 1.0e9, hands: float = 1.0e9, surf: float = 1.0e9) -> void:
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain.stagger_t = 0.0
	boss.brain._maul_cd = maul
	boss.brain._hands_cd = hands
	boss.brain._surface_cd = surf
	boss.brain._rite_cd = 1.0e9
	boss.brain._spot = -1
	boss._mirror()


func _hurt_n(since: int, base: float) -> Array:
	return hurts.slice(since).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - base * dmg_scale()) < 1e-6)


func _risen() -> Array:
	return g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "risen")


func _fen_corpses() -> int:
	return g.corpses.corpses.values().filter(func(c: DmSimCorpse) -> bool: return c.area == "fen").size()


func solo() -> void:
	_M = DmContent.get_export("bosses", "MIRE")
	await new_solo()
	g.bosses.rng.seed = 7
	var m := member()
	check(g.bosses.site_pos("mire").is_equal_approx(site()) and site() != Vector3.INF, "mire: the summon site is the fen's mire_altar %s" % str(site()))
	hb.teleport(Vector3(0, 0, 20))
	check(g.bosses.try_summon(g.session.get_my_id(), "mire") == "far", "mire: refused away from the altar (far)")
	await at_site(0)
	set_shards(0)   # (the progression may restore the backend's saved count when the hero changes area)
	check(g.area_of(g.session.get_my_id()) == "fen", "mire: hero is in the Mourning Fen")
	check(g.bosses.try_summon(g.session.get_my_id(), "mire") == "shards" and g.bosses.bosses.is_empty(), "mire: no shards -> refused")
	var cost := int(DmContent.boss("mire")["shards"])
	m.prog.add_shards(cost - 1)
	check(g.bosses.try_summon(g.session.get_my_id(), "mire") == "shards" and int(m.prog.local["shards"]) == cost - 1, "mire: %d of %d shards is not enough" % [cost - 1, cost])
	m.prog.add_shards(cost + 1)
	check(wake() == "" and int(m.prog.local["shards"]) == cost, "mire: %d shards wake her, her own cost is spent" % cost)
	check(g.bosses.try_summon(g.session.get_my_id(), "mire") == "busy", "mire: busy while awake")
	check(boss.view != null and boss.view.slug == "boss_mire_mother", "mire: the current client's DmBossView (mire mother model)")
	var s: Dictionary = boss.brain.state
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want_hp: float = 42000.0 * (1.0 + 0.22 * (float(s["level"]) - 1.0)) * float(diff["enemyHpMult"])
	check(is_equal_approx(boss.max_hp, want_hp) and int(s["level"]) == 45, "mire: awaken hp = baseHp 42000 x level 45 x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "mire: she rises on the central hummock (-42, -80), phase 1")
	check(events("awaken").size() == 1 and "bossAwaken" in astub.sfx, "mire: awaken event + bossAwaken")

	# ---- Maul at 2.0 s
	_quiet(2.0)
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	step(1.9)
	check(events("maul").is_empty(), "mire: no maul before its opening cooldown (2 s)")
	step(0.2)
	var ml := telegraphs("maul")
	check(ml.size() == 1 and absf(float(ml[0]["t"]) - 2.0) < 0.05, "mire: maul telegraphed at 2.0 s")
	if ml.size() == 1:
		var e: Dictionary = ml[0]["ev"]
		check(is_equal_approx(float(e["ms"]), 900.0) and is_equal_approx(float(e["r"]), 3.4), "mire: maul telegraph 900 ms, radius 3.4")
		check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "mire: cone aimed at the hero")
	step(1.0)
	var mi := impacts("maul")
	check(mi.size() == 1 and absf(float(mi[0]["t"]) - float(ml[0]["t"]) - 0.9) < 0.03 and _hurt_n(0, 80.0).size() == 1, "mire: the maul lands 0.9 s later for 80 x level x difficulty (%.0f)" % (80.0 * dmg_scale()))
	check(absf(float(boss.brain._maul_cd) - (3.2 - (3.1 - float(ml[0]["t"]))) ) < 0.15, "mire: maul cooldown 3.2 s (%.2f left)" % float(boss.brain._maul_cd))

	# ---- Drowned Hands: only whoever wades the open water
	_quiet(1.0e9, 0.0)
	hb.teleport(arena() + Vector3(5.0, 0.0, 0.0))   # off every hummock, in the bog
	boss.world.refresh()
	check(DmBossGeom_in_bog(hb.position) and not DmBossGeom_on_hummock(hb.position, 1.0), "mire: the hero is wading")
	var nh := hurts.size()
	step(0.05)
	var hd := telegraphs("hands")
	check(hd.size() == 1, "mire: Drowned Hands telegraphed")
	if hd.size() == 1:
		var e2: Dictionary = hd[0]["ev"]
		var tg: Array = e2["targets"]
		check(is_equal_approx(float(e2["ms"]), 1300.0) and is_equal_approx(float(e2["r"]), 1.5) and tg.size() >= 2 and tg.size() <= 4, "mire: hands 1300 ms, ring radius 1.5, 2-4 rings (%d)" % tg.size())
		check(absf(float(tg[0][0]) - hb.position.x) < 1e-6 and absf(float(tg[0][1]) - hb.position.z) < 1e-6, "mire: a ring under the wading hero")
	check(absf(float(boss.brain._hands_cd) - 9.0) < 0.1, "mire: hands cooldown 9 s")
	step(1.4)
	var hi := impacts("hands")
	check(hi.size() == 1 and absf(float(hi[0]["t"]) - float(hd[0]["t"]) - 1.3) < 0.03 and _hurt_n(nh, 45.0).size() == 1, "mire: the hands close 1.3 s later: 45 x scale, once")
	check(is_equal_approx(float(hi[0]["ev"]["root"]), 1.0) and hi[0]["ev"]["players"] == [str(g.session.get_my_id())] and float(hb.p["rootedUntil"]) > hb._clock_ms, "mire: they root the hero for 1 s")
	# on a hummock nothing reaches for you
	_quiet(1.0e9, 0.0)
	hb.teleport(arena())
	boss.world.refresh()
	step(0.05)
	var hd2 := telegraphs("hands")
	var none_on_hero: bool = hd2[hd2.size() - 1]["ev"]["targets"].all(func(t: Array) -> bool: return Vector2(float(t[0]) - hb.position.x, float(t[1]) - hb.position.z).length() > 1e-6)
	check(none_on_hero, "mire: dry ground (a hummock) is safe from the hands: no ring is aimed at it")
	_quiet()

	# ---- Surface: sunk = untargetable, ripple ring, then she erupts and is winded
	var th: DmThrallHost = hb.get_node("Thralls")
	var hunts := 0
	hb.teleport(Vector3(-36.3, 0.0, -76.7))   # on hummock 3
	boss.world.refresh()
	for i in 60:
		_quiet(1.0e9, 1.0e9, 0.0)
		boss.brain.state["x"] = arena().x
		boss.brain.state["z"] = arena().z
		step(0.02)
		var sf := telegraphs("surface")
		var last: Dictionary = sf[sf.size() - 1]["ev"]
		if Vector2(float(last["x"]) + 36.3, float(last["z"]) + 76.7).length() < 0.01:
			hunts += 1
	check(hunts >= 30 and hunts <= 55, "mire: she hunts the hummock you stand on 65 %% of the time (%d / 60 on it)" % hunts)
	_quiet(1.0e9, 1.0e9, 0.0)
	hb.teleport(arena() + Vector3(0.0, 0.0, 9.0))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	boss.world.refresh()
	var spots: Array = DmContent.get_export("fen", "FEN_SURFACE_SPOTS")
	var humm: Array = DmContent.get_export("fen", "FEN_HUMMOCKS")
	var n_sf := telegraphs("surface").size()
	step(0.02)
	var sf2 := telegraphs("surface")
	check(sf2.size() == n_sf + 1, "mire: Surface telegraphed")
	var se: Dictionary = sf2[sf2.size() - 1]["ev"]
	var spot_ok := spots.any(func(i: int) -> bool: return absf(float(humm[i]["x"]) - float(se["x"])) < 1e-6 and absf(float(humm[i]["z"]) - float(se["z"])) < 1e-6)
	check(spot_ok and is_equal_approx(float(se["ms"]), 2300.0) and is_equal_approx(float(se["r"]), 3.7), "mire: ripple ring over one of the six hummocks, 2300 ms, radius 3.7")
	check(absf(float(boss.brain._surface_cd) - 13.0) < 0.1, "mire: surface cooldown 13 s")
	var hp0 := boss.hp
	check(boss.brain.state["state"] == "sunk" and boss.bstate.state == "sunk" and not boss.is_hittable() and boss.is_awake(), "mire: she slips under at once: sunk, awake, not hittable")
	check(absf(boss.global_position.x - float(se["x"])) < 1e-3 and absf(boss.global_position.z - float(se["z"])) < 1e-3, "mire: she is under the hummock the ring fills")
	check(not boss.take_damage(5000.0, hb) and boss.hp == hp0, "mire: sunk: take_damage refused")
	boss.brain.damage(5000.0, str(g.session.get_my_id()), 0)
	check(float(boss.brain.state["hp"]) == hp0, "mire: sunk: even the brain refuses damage")
	boss.stun(2.0)
	check(boss.brain.stagger_t == 0.0, "mire: sunk: a stun does nothing")
	check(g.enemies_in_radius(boss.global_position, 1.0).is_empty() and g.bosses.living().is_empty() and g.bosses.active_boss() == boss, "mire: sunk: absent from the rite world and the pick list, still the active boss (bar, music)")
	check(g.bosses.try_summon(g.session.get_my_id(), "mire") == "busy", "mire: sunk: still counts as awake (no second summon)")
	var rt: Dictionary = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 60.0, "attackSpeedMult": 1.0})
	var tz: DmThrall = rt["thralls"][0]
	tz.set_deferred("global_position", boss.global_position + Vector3(-2.6, 0.0, 0.0))
	var caster: DmRiteCaster = hb.get_node("Rites")
	hb.teleport(boss.global_position + Vector3(-3.0, 0.0, 3.0))
	await ticks(2)
	caster.request_cast("bone_needle", boss.global_position, int(boss.get_meta(&"dm_id")))
	await ticks(60)
	check(tz.target != boss and boss.hp == hp0 and float(boss.brain.state["hp"]) == hp0, "mire: sunk: thralls do not engage her and a rite finds nothing to hit")
	th.clear()
	# the ring fills, she erupts under whoever stays
	hb.teleport(Vector3(float(se["x"]) + 1.0, 0.0, float(se["z"])))
	boss.world.refresh()
	nh = hurts.size()
	step(2.2)
	check(impacts("surface").is_empty() and boss.brain.state["state"] == "sunk", "mire: still under before the ring is full")
	step(0.2)
	var si := impacts("surface")
	check(si.size() == 1 and absf(float(si[0]["t"]) - float(sf2[sf2.size() - 1]["t"]) - 2.3) < 0.03, "mire: she erupts 2.3 s after the ring appears")
	check(_hurt_n(nh, 160.0).size() == 1, "mire: whoever stayed on the hummock takes 160 x scale")
	check(boss.brain.state["state"] == "idle" and boss.is_hittable() and boss.brain.stagger_t > 2.4 and boss.brain.stagger_t <= 2.8, "mire: surfaced: hittable again and winded for 2.8 s (%.2f)" % boss.brain.stagger_t)
	check(boss.take_damage(500.0, hb) and boss.hp < hp0, "mire: winded she can be hit")
	# winded: nothing happens until it ends
	boss.brain._maul_cd = 0.0
	hb.teleport(boss.global_position + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	var nm := telegraphs("maul").size()
	step(2.0)
	check(telegraphs("maul").size() == nm, "mire: no attack while she is winded")
	step(1.0)
	check(telegraphs("maul").size() == nm + 1, "mire: she attacks again when the stagger ends")
	# off the hummock the eruption misses
	_quiet(1.0e9, 1.0e9, 0.0)
	hb.teleport(arena() + Vector3(0.0, 0.0, 10.0))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	boss.world.refresh()
	step(0.02)
	var sf3 := telegraphs("surface")
	var se3: Dictionary = sf3[sf3.size() - 1]["ev"]
	hb.teleport(_far_from(Vector2(float(se3["x"]), float(se3["z"]))))
	boss.world.refresh()
	nh = hurts.size()
	step(2.4)
	check(_hurt_n(nh, 160.0).is_empty(), "mire: stepping off the hummock dodges the eruption")
	check(boss.brain.state["state"] != "sunk" and boss.is_hittable(), "mire: surfaced again (%s, active %s, hero alive %s)" % [boss.brain.state["state"], boss.brain.state["active"], hb.alive])

	# ---- phase 2: flood + leeches, tighter timings
	_quiet()
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	step(0.1)
	await ticks(2)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "mire: phase 2 at 60 %")
	var fl := events("flood")
	check(fl.size() == 1 and int(fl[0]["ev"]["phase"]) == 2 and fl[0]["ev"]["targets"].size() == 6, "mire: the marsh floods (event phase 2, 6 spots)")
	var lee := g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "mire_leech")
	check(lee.size() == 6 and lee.all(func(e: DmEnemy) -> bool: return absf(Vector2(e.position.x - arena().x, e.position.z - arena().z).length() - 12.0 * 0.9) < 0.01), "mire: P2 six Mire Leeches on the rim (0.9 r)")
	check(is_equal_approx(float(boss.brain._flood_scale(2)), 0.72) and not DmBossGeom_on_hummock(hb.position, 0.72), "mire: the hummocks shrink to 0.72: the hero's old dry spot is now water")
	clear_adds()
	_quiet(1.0e9, 0.0)
	boss.world.refresh()
	step(0.05)
	var hd3 := telegraphs("hands")
	var h3: Dictionary = hd3[hd3.size() - 1]["ev"]
	check(absf(float(h3["targets"][0][0]) - hb.position.x) < 1e-6 and absf(float(boss.brain._hands_cd) - 7.5) < 0.1, "mire: in the flood the hands reach the hero, cooldown 7.5 s")
	_quiet(1.0e9, 1.0e9, 0.0)
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	step(0.02)
	var sf4 := telegraphs("surface")
	check(is_equal_approx(float(sf4[sf4.size() - 1]["ev"]["ms"]), 2000.0) and absf(float(boss.brain._surface_cd) - 11.0) < 0.1, "mire: P2 surface 2000 ms, cooldown 11 s")
	_quiet()
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z

	# ---- phase 3: the Drowned Rite
	var tk := boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	step(0.1)
	await ticks(2)
	check(boss.phase == 3 and events("flood").size() == 2 and int(events("flood")[1]["ev"]["phase"]) == 3, "mire: phase 3 at 30 %, the flood deepens")
	var p3 := g.director.enemies.values()
	check(p3.filter(func(e: DmEnemy) -> bool: return e.def_id == "bog_hag").size() == 2 and p3.filter(func(e: DmEnemy) -> bool: return e.def_id == "mire_leech").size() == 4, "mire: P3 adds 2 Bog Hags + 4 Mire Leeches")
	clear_adds()
	await ticks(2)
	# 3 corpses in the Fen (+1 in the Graves, which she must not touch); one is claimed mid-windup
	var ids: Array = []
	for i in 3:
		ids.append(g.corpses.add_corpse(arena().x - 5.0 + float(i) * 2.0, arena().z - 4.0, "normal", "robber", false, 0.0, 1.0, "fen").id)
	g.corpses.add_corpse(-14.0, -22.0, "normal", "robber", false, 0.0, 1.0, "graves")
	_quiet()
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	var nr := telegraphs("rite").size()
	step(0.05)
	var rt1 := telegraphs("rite")
	check(rt1.size() == nr + 1, "mire: the Drowned Rite is telegraphed")
	var re: Dictionary = rt1[rt1.size() - 1]["ev"]
	check(is_equal_approx(float(re["ms"]), 2600.0) and re["targets"].size() == 3, "mire: rite 2600 ms, a beam to each of the 3 corpses in the Fen")
	check(absf(float(boss.brain._rite_cd) - 13.0 * 0.8) < 0.15, "mire: rite cooldown 13 x 0.8 s")
	check(g.corpses.consume(ids[0], g.session.get_my_id(), "litany"), "mire: the player claims a corpse before the rite lands")
	step(2.7)
	var rim := impacts("rite")
	check(rim.size() == 1 and rim[0]["ev"]["targets"].size() == 2 and absf(float(rim[0]["t"]) - float(rt1[rt1.size() - 1]["t"]) - 2.6) < 0.03, "mire: the rite raises only what is left (2 of 3) 2.6 s later")
	check(_risen().size() == 2 and _fen_corpses() == 0, "mire: 2 Risen stand where the corpses lay, the Fen is empty")
	check(g.corpses.corpses.values().filter(func(c: DmSimCorpse) -> bool: return c.area == "graves").size() == 1, "mire: a corpse in another area is untouched")
	check(boss.brain.stagger_t == 0.0, "mire: a rite that finds the dead does not stagger her")
	clear_adds()
	await ticks(2)
	# nine corpses: the six nearest are raised
	for i in 9:
		g.corpses.add_corpse(arena().x - 8.0 + float(i) * 2.0, arena().z + 1.0 + float(i) * 0.5, "normal", "robber", false, 0.0, 1.0, "fen")
	_quiet()
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	step(0.05)
	var rt2 := telegraphs("rite")
	check(rt2[rt2.size() - 1]["ev"]["targets"].size() == 6, "mire: at most 6 corpses are drawn into the rite")
	step(2.7)
	check(_risen().size() == 6 and _fen_corpses() == 3, "mire: 6 Risen, the 3 farthest corpses remain")
	clear_adds()
	for c in g.corpses.corpses.values().duplicate():
		g.corpses.consume((c as DmSimCorpse).id, 0, "consumed")
	await ticks(2)
	# starve the rite: she staggers
	_quiet()
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	step(0.05)
	step(2.7)
	var rfail := impacts("rite")
	check(rfail.size() == 3 and rfail[2]["ev"]["targets"].is_empty(), "mire: no corpses at all: the rite fails")
	check(boss.brain.stagger_t > 2.7 and boss.brain.stagger_t <= 3.0 and _risen().is_empty(), "mire: starved, she reels for 3 s (%.2f)" % boss.brain.stagger_t)

	# ---- thralls / rites on a surfaced boss
	_quiet()
	boss.brain.state["hp"] = boss.max_hp * 0.9
	boss.brain.state["phase"] = 1
	await check_rites_and_stun()

	# ---- defeat (even a hit at the very end while sunk is refused: she must surface to die), wipe
	await check_defeat(true, 2)
	await check_rewake_and_wipe()

	# ---- the engine-driven run
	await at_site(cost)
	check(wake() == "", "mire: woken for the engine-driven run")
	await check_engine_run(3.0, func() -> void:
		for i in 6:
			g.corpses.add_corpse(arena().x - 5.0 + float(i), arena().z - 3.0, "normal", "robber", false, 0.0, 1.0, "fen"))
	await end_fight()


func DmBossGeom_in_bog(p: Vector3) -> bool:
	return load("res://sim/bosses/boss_geom.gd").in_bog(p.x, p.z)


func DmBossGeom_on_hummock(p: Vector3, scale: float) -> bool:
	return load("res://sim/bosses/boss_geom.gd").on_hummock(p.x, p.z, scale)


## The point of the arena ring (r 9) farthest from `p`.
func _far_from(p: Vector2) -> Vector3:
	var best := arena()
	var bd := -1.0
	for k in 12:
		var a := float(k) * TAU / 12.0
		var c := arena() + Vector3(sin(a) * 9.0, 0.0, cos(a) * 9.0)
		var d := Vector2(c.x, c.z).distance_to(p)
		if d > bd:
			bd = d
			best = c
	return best


func net() -> void:
	await two_peers_summon()
	await two_peers_first_telegraph("maul")
	# sunk replicates: the client's puppet is awake but not hittable, absent from the pick list
	hboss.brain.state["state"] = "sunk"
	hboss._mirror()
	check(await until(func() -> bool: return cboss.bstate.state == "sunk", 3.0) and not cboss.is_hittable() and cboss.is_awake() and cg.bosses.active_boss() == cboss and cg.bosses.living().is_empty(), "net: sunk replicates, the client's puppet is awake but not hittable")
	hboss.brain.state["state"] = "idle"
	hboss._mirror()
	await two_peers_defeat()
	await two_peers_end()
