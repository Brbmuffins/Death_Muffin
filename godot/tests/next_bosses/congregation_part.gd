extends "res://tests/next_bosses/harness.gd"
## The Drowned Congregation in the slice: part of the boss suite (run.gd drives it)
## The Nave is not opened by the slice yet: the hero is teleported into the arena (area-agnostic brain; the world's own rects say "nave").
## A: summon rules (4 shards at the Drowned Font), Maul / Drowning Grasp (rings + root) / Flood Hymn (arc, chill) numbers + timing, the pews as cover
##    (players and thralls), the rising water (wading slow in P2 / P3, soaked x1.2 off the dais in P3), each phase's six climbers, thralls + rites,
##    defeat -> reward + report, repeat kill, wipe.   B: two ENet peers.   C: perf.

var _adds_seen := 0


func _init() -> void:
	boss_id = "congregation"


func _adds(def_id: String = "") -> Array:
	return g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return is_instance_valid(e) and (def_id == "" or e.def_id == def_id) and e.sm.id() != DmEnemyState.Id.DEAD)


## The Flood Hymn's telegraph #n (0-based) and the spot it was aimed from.
func _hymn(n: int) -> Dictionary:
	return telegraphs("hymn")[n]["ev"]


func solo() -> void:
	await new_solo()
	await check_prompt_and_key()
	await check_summon_rules(4, "nobody")
	check(awaken_hp_ok(19000.0), "A: awaken hp = baseHp 19000 x level x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "A: awake at the arena centre (0, -61), phase 1")
	check(boss.view != null and boss.view.slug == "boss_drowned_congregation", "A: the current client's DmBossView with the Congregation's model")
	check(events("awaken").size() == 1 and "bossAwaken" in astub.sfx, "A: awaken event + bossAwaken sound")
	check(_adds().is_empty() and hb.wade_mult == 1.0, "A: nothing climbs out and the water is still in phase 1")
	# ---- Maul: first at 2.0 s when someone is within r + 0.5
	put(arena() + Vector3(3.0, 0.0, 0.0))
	step(1.9)
	check(telegraphs("maul").is_empty(), "A: no attack before the opening cooldown")
	step(0.2)
	var ml := telegraphs("maul")
	check(ml.size() == 1 and absf(float(ml[0]["t"]) - 2.0) < 0.05 and is_equal_approx(float(ml[0]["ev"]["ms"]), 800.0) and is_equal_approx(float(ml[0]["ev"]["r"]), 3.0), "A: Maul at t = 2.0 s, 800 ms, r 3")
	check(absf(float(ml[0]["ev"]["dir"]) - atan2(hb.position.x - float(ml[0]["ev"]["x"]), hb.position.z - float(ml[0]["ev"]["z"]))) < 1e-6, "A: aimed at the nearest hero")
	step(0.8)
	check(impacts("maul").size() == 1 and absf(float(impacts("maul")[0]["t"]) - float(ml[0]["t"]) - 0.8) < 0.03 and hurts_of(18.0).size() == 1, "A: the Maul lands 0.8 s later for 18 x level x difficulty")
	# ---- Drowning Grasp: first at 3.0 s, 3-5 rings (one on every player first, the rest 2.5 m around), 1300 ms, r 1.4, 14 dmg + root 1 s
	step_until(func() -> bool: return not telegraphs("grasp").is_empty(), 2.0)
	var gr := telegraphs("grasp")
	check(gr.size() == 1 and absf(float(gr[0]["t"]) - 3.0) < 0.05 and is_equal_approx(float(gr[0]["ev"]["ms"]), 1300.0) and is_equal_approx(float(gr[0]["ev"]["r"]), 1.4), "A: Grasp at t = 3.0 s, 1300 ms, rings r 1.4")
	var tg: Array = gr[0]["ev"]["targets"]
	check(tg.size() >= 3 and tg.size() <= 5 and absf(float(tg[0][0]) - hb.position.x) < 1e-6 and absf(float(tg[0][1]) - hb.position.z) < 1e-6, "A: %d rings, the first under the hero" % tg.size())
	var ring_ok := true
	for k in range(1, tg.size()):
		ring_ok = ring_ok and absf(Vector2(float(tg[k][0]) - hb.position.x, float(tg[k][1]) - hb.position.z).length() - 2.5) < 1e-6
	check(ring_ok, "A: the others 2.5 m round a hero")
	var hr0 := hurts.size()
	step(1.4)
	check(impacts("grasp").size() == 1 and hurts_of(14.0, hr0).size() == 1, "A: the ring that holds the hero hurts for 14 x scale")
	check(is_equal_approx(float(impacts("grasp")[0]["ev"]["root"]), 1.0) and impacts("grasp")[0]["ev"]["players"] == [str(g.session.get_my_id())], "A: Grasp roots 1 s and names the hero")
	check(float(hb.p["rootedUntil"]) > hb._clock_ms, "A: the hero body is rooted")
	# ---- Flood Hymn: first at 6.0 s, 2200 ms, a 15 m / 120 degree arc, 18 x 1.8; a pew between her and you is cover (players and thralls)
	var pew: Dictionary = boss.world.cover()[0]
	check(boss.world.cover().size() == 4, "A: the cover hook serves the four pews of the sim world")
	var th: DmThrallHost = hb.get_node("Thralls")
	th.clear()
	var t_open: DmThrall = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 5.0, "attackSpeedMult": 1.0})["thralls"][0]
	var spot := arena() + Vector3(0.0, 0.0, 8.0)
	g.corpses.add_corpse(spot.x, spot.z, "normal", "robber", false, 0.0, 1.0, g.area_of(g.session.get_my_id()))
	put(spot)
	var t_pew: DmThrall = th.raise({"kind": "warrior", "cap": 99.0, "hp": 4000.0, "damage": 5.0, "attackSpeedMult": 1.0}, spot)["thralls"][0]
	# behind the first pew, seen from the dais: hero and one thrall
	var behind := Vector3((float(pew["x0"]) + float(pew["x1"])) * 0.5, 0.0, float(pew["z1"]) + 3.0)
	put(behind)
	t_pew.global_position = behind + Vector3(-0.8, 0.0, 0.6)
	t_open.global_position = Vector3(0.0, 0.0, -50.0)   # through the aisle between the two pews
	boss.world.refresh()
	step_until(func() -> bool: return not telegraphs("hymn").is_empty(), 6.0)
	var hy := _hymn(0)
	check(absf(float(telegraphs("hymn")[0]["t"]) - 6.0) < 0.1 and is_equal_approx(float(hy["ms"]), 2200.0) and is_equal_approx(float(hy["r"]), 15.0), "A: Hymn at t = 6.0 s, 2200 ms, reach 15")
	check(absf(float(hy["dir"]) - atan2(behind.x - float(hy["x"]), behind.z - float(hy["z"]))) < 1e-6, "A: aimed at the nearest hero")
	var cov_hero: bool = boss.brain.covered(behind.x, behind.z, float(hy["x"]), float(hy["z"]))
	var cov_thrall: bool = boss.brain.covered(t_pew.global_position.x, t_pew.global_position.z, float(hy["x"]), float(hy["z"]))
	var cov_open: bool = boss.brain.covered(t_open.global_position.x, t_open.global_position.z, float(hy["x"]), float(hy["z"]))
	check(cov_hero and cov_thrall and not cov_open, "A: (the pew covers the hero and one thrall, the aisle does not)")
	hurts.clear()
	var hp_o := t_open.hp
	var hp_p := t_pew.hp
	step(2.3)
	check(impacts("hymn").size() == 1 and hurts_of(18.0 * 1.8).is_empty() and hurts.is_empty(), "A: behind a pew the Hymn does not touch the hero")
	check(t_pew.hp == hp_p and absf(hp_o - t_open.hp - 20.0 * dmg_scale()) < 1e-3, "A: nor the thrall behind it; the thrall in the aisle is hurt for 20 x scale (%.1f)" % (hp_o - t_open.hp))
	# ---- the next Grasp: stepping 9 m off the rings dodges it
	step_until(func() -> bool: return telegraphs("grasp").size() >= 2, 6.0)
	hurts.clear()
	var g2: Dictionary = telegraphs("grasp")[1]
	check(absf(float(g2["t"]) - float(telegraphs("grasp")[0]["t"]) - 7.0) < 0.1, "A: Grasp repeats on its 7 s cooldown")
	put(arena() + Vector3(9.5, 0.0, 0.0))
	step(1.4)
	check(impacts("grasp").size() == 2 and hurts_of(14.0).is_empty(), "A: moving off the rings dodges the Grasp")
	# ---- Hymn in the open: 18 x 1.8 x scale + chill; the second Hymn is 11 s after the first
	put(arena() + Vector3(7.0, 0.0, 0.0))
	step_until(func() -> bool: return telegraphs("hymn").size() >= 2, 12.0)
	check(telegraphs("hymn").size() == 2 and absf(float(telegraphs("hymn")[1]["t"]) - float(telegraphs("hymn")[0]["t"]) - 11.0) < 0.1, "A: Hymn repeats on its 11 s cooldown")
	hurts.clear()
	step(2.3)
	check(hurts_of(18.0 * 1.8).size() == 1, "A: in the open the Hymn hurts for 18 x 1.8 x scale")
	check(DmStatusSet.of(hb) != null and DmStatusSet.of(hb).has(&"chill"), "A: ...and chills the hero (2 s)")
	th.clear()
	# ---- Phase 2 (60 %): six climb out (4 wraiths, 2 penitents) on the rim; the water slows wading (x0.85 off the dais)
	set_hp(0.7)
	var adds0 := _adds().size()
	wound(0.59)
	check(boss.phase == 2 and events("phase").size() == 1, "A: phase 2 at 60 %")
	var sm := events("summon")
	check(sm.size() == 1 and sm[0]["ev"]["targets"].size() == 6 and _adds().size() == adds0 + 6 and _adds("wraith").size() == 4 and _adds("penitent").size() == 2, "A: six climb out: 4 Choir Wraiths + 2 Bellbound Penitents")
	var on_rim := _adds().all(func(e: DmEnemy) -> bool: return absf(Vector2(e.position.x, e.position.z + 61.0).length() - 9.35) < 0.01)
	check(on_rim and String(_adds()[0].get_meta(&"dm_area")) == "nave", "A: on the arena rim (0.85 r), counted as Nave enemies")
	put(arena() + Vector3(8.0, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, 0.85), "A: the water slows wading outside the dais in phase 2 (x%.2f)" % hb.wade_mult)
	put(arena() + Vector3(2.0, 0.0, 0.0))
	await ticks(15)
	check(hb.wade_mult == 1.0, "A: on the dais the hero is not slowed")
	var h_n := telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() >= h_n + 2, 30.0)
	var p2h := telegraphs("hymn").slice(h_n)
	check(p2h.size() == 2 and absf(float(p2h[1]["t"]) - float(p2h[0]["t"]) - 11.0 * 0.9) < 0.1, "A: P2 cooldowns x0.9 (Hymn every %.1f s)" % (float(p2h[1]["t"]) - float(p2h[0]["t"])))
	# ---- Phase 3 (30 %): six more; wading x0.7; the Hymn is x1.2 on whoever stands in the water, x1.0 on the dais
	for e in _adds():
		e.queue_free()
	await ticks(2)
	wound(0.29)
	check(boss.phase == 3 and events("summon").size() == 2 and _adds("wraith").size() == 4 and _adds("penitent").size() == 2, "A: phase 3: six more climb out")
	put(arena() + Vector3(8.0, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, 0.7), "A: wading x0.7 in phase 3 (x%.2f)" % hb.wade_mult)
	h_n = telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() > h_n, 12.0)
	hurts.clear()
	step(2.3)
	check(hurts_of(18.0 * 1.8 * 1.2).size() == 1, "A: standing in the water in phase 3 the Hymn is x1.2 (soaked)")
	put(arena() + Vector3(2.0, 0.0, 0.0))
	h_n = telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() > h_n, 12.0)
	hurts.clear()
	step(2.3)
	check(hurts_of(18.0 * 1.8).size() == 1 and hurts_of(18.0 * 1.8 * 1.2).is_empty(), "A: on the dais it is the plain 18 x 1.8")
	var p3h := telegraphs("hymn").slice(telegraphs("hymn").size() - 2)
	check(absf(float(p3h[1]["t"]) - float(p3h[0]["t"]) - 11.0 * 0.78) < 0.15, "A: P3 cooldowns x0.78 (Hymn every %.2f s)" % (float(p3h[1]["t"]) - float(p3h[0]["t"])))
	# ---- thralls + rites; defeat; the water drains
	for e in _adds():
		e.queue_free()
	g.director.enemies.clear()
	hb.heal(1e6)
	await check_thralls()
	await check_rites_and_stun()
	await check_defeat(true, 2)
	await ticks(10)
	check(hb.wade_mult == 1.0 and _adds().is_empty(), "A: defeated: the water drains (no slow) and the climbers are gone")
	# ---- repeat kill, wipe
	await end_fight()
	await ticks(2)
	check(summon(5) == "", "A: it can be woken again after the kill")
	var earned: Array = []
	g.rewards.boss_earned.connect(func(_c: int, id: String, f: bool, _p: Vector3) -> void: earned.append([id, f]))
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp + 1.0, hb)
	check(earned == [["congregation", false]], "A: a repeat kill has no first-kill bonus")
	await end_fight()
	await ticks(2)
	check(summon(5) == "", "A: woken a third time")
	wound(0.55)
	check(_adds().size() == 6, "A: (six climbers at phase 2)")
	check_wipe()
	await ticks(3)
	check(_adds().is_empty(), "A: a reset sends the climbers back under")
	await end_fight()
	# ---- engine-driven fight + perf
	await ticks(2)
	check(summon(5) == "", "A: woken a fourth time")
	boss.set_physics_process(true)
	put(arena() + Vector3(3.0, 0.0, 0.0))
	await until(func() -> bool: return telegraphs("maul").size() >= 1 and telegraphs("grasp").size() >= 1 and telegraphs("hymn").size() >= 1, 10.0)
	check(boss.bstate.active and not telegraphs("hymn").is_empty(), "A: the engine-driven Congregation fights (maul + grasp + hymn on the real clock)")
	boss.set_physics_process(false)
	await end_fight()


# ---- B: two peers --------------------------------------------------------------------------------------------------------------------------

func net() -> void:
	await two_peers_summon()
	var hh := hg.local_body()
	for i in 370:   # 6.17 s: past the first Hymn (6.0 s)
		hboss._physics_process(DT)
		hh.heal(1e6)
	check(await until(func() -> bool: return cboss.telegraphs.any(func(t: Array) -> bool: return String(t[0]) == "hymn"), 3.0), "B: the client sees the Hymn telegraph in the replicated state")
	var tl: Array = cboss.telegraphs.filter(func(t: Array) -> bool: return String(t[0]) == "hymn")[0]
	check(float(tl[1]) <= 2.2 and is_equal_approx(float(tl[2]), 15.0), "B: telegraph kind / time left (%.2f s) / reach replicate" % float(tl[1]))
	hboss.take_damage(hboss.hp - hboss.max_hp * 0.59, hh)
	for i in 10:
		hboss._physics_process(DT)
	check(await until(func() -> bool: return cg.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "wraith").size() == 4 and cg.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "penitent").size() == 2, 6.0), "B: phase 2's six climbers exist on the client too (director spawner)")
	await two_peers_replication()
	await two_peers_defeat()
	await two_peers_end()
