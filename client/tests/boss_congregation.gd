extends "res://tests/boss_base.gd"
## The Drowned Congregation on the combat core (the Drowned Nave's boss; archive/old-game:godot/tests/next_bosses/congregation_part.gd on today's game, the same numbers and timing). Her climbers are core
## bodies (the Choir Wraith and the Bellbound Penitent), the pews are cover (`DmDb.sim_world()["cover"]`), her grasp roots and her hymn chills the hero.
##   - her recorded scenarios replay through the client's copy of the brain (the pews scenario among them); the generic parts (boss_base.gd): the summon at the Drowned Font (4 soul shards),
##     thralls, rites, wipe, defeat, rewards;
##   - Maul, Drowning Grasp (the rings, the root) and Flood Hymn (the arc, the chill) at today's ticks and numbers; a pew between her and a hero or a thrall is cover (the thrall in the aisle is hurt);
##   - the rising water: wading slower in phase 2 and 3 off her dais (the host's wade clock), the soaked Hymn x1.2 in phase 3; each phase's six climbers (4 wraiths, 2 penitents) on the rim;
##   - when she is gone the water drains and the climbers are back under (a wipe takes them out silently, a defeat likewise: the generic parts).
## Run: godot --headless --path client --script res://tests/boss_congregation.gd [--fixed-fps 60 before --path runs it faster than real time]


func _config() -> void:
	boss_id = "congregation"
	load_areas = ["nave"]
	bakes = ["thrall_legionnaire", "choir_wraith", "penitent"]
	replay_count = 6


func adds(def_id := "") -> Array:
	var out: Array = []
	for id in core.enemy_ids():
		var info: Dictionary = core.enemy_info(id)
		if int(info["state"]) != DmCoreEvents.State.DEAD and (def_id == "" or info["def"] == def_id):
			out.append(int(id))
	return out


func hymn(n: int) -> Dictionary:
	return telegraphs("hymn")[n]["ev"]


func run_suite() -> void:
	await t_summon(4, 19000.0)
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(6, func() -> void:
		wound_to_phase_two())
	await t_defeat(true)
	await t_real_clock(["maul", "grasp", "hymn"], 12.0)
	await t_net_state()


func wound_to_phase_two() -> void:
	set_hp(0.7)
	wound(0.55)
	check(boss.phase == 2 and adds().size() == 6, "(phase 2: six climbers)")


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre (0, -61), phase 1")
	check(adds().is_empty() and hb.wade_mult == 1.0, "nothing climbs out and the water is still in phase 1")
	# ---- Maul: first at 2.0 s when someone is within r + 0.5
	put(arena() + Vector3(3.0, 0.0, 0.0))
	step(1.9)
	check(telegraphs("maul").is_empty(), "no attack before the opening cooldown")
	step(0.2)
	var ml := telegraphs("maul")
	check(ml.size() == 1 and absf(float(ml[0]["t"]) - 2.0) < 0.05 and near(float(ml[0]["ev"]["ms"]), 800.0) and near(float(ml[0]["ev"]["r"]), 3.0), "Maul at t = 2.0 s, 800 ms, r 3")
	check(absf(float(ml[0]["ev"]["dir"]) - atan2(hb.position.x - float(ml[0]["ev"]["x"]), hb.position.z - float(ml[0]["ev"]["z"]))) < 1e-6, "aimed at the nearest hero")
	step(0.8)
	check(impacts("maul").size() == 1 and absf(float(impacts("maul")[0]["t"]) - float(ml[0]["t"]) - 0.8) < 0.03 and hurts_of(18.0).size() == 1, "the Maul lands 0.8 s later for 18 x level x difficulty")
	# ---- Drowning Grasp: first at 3.0 s, 3-5 rings (one on every player first, the rest 2.5 m around), 1300 ms, r 1.4, 14 dmg + root 1 s
	step_until(func() -> bool: return not telegraphs("grasp").is_empty(), 2.0)
	var gr := telegraphs("grasp")
	check(gr.size() == 1 and absf(float(gr[0]["t"]) - 3.0) < 0.05 and near(float(gr[0]["ev"]["ms"]), 1300.0) and near(float(gr[0]["ev"]["r"]), 1.4), "Grasp at t = 3.0 s, 1300 ms, rings r 1.4")
	var tg: Array = gr[0]["ev"]["targets"]
	check(tg.size() >= 3 and tg.size() <= 5 and absf(float(tg[0][0]) - hb.position.x) < 1e-6 and absf(float(tg[0][1]) - hb.position.z) < 1e-6, "%d rings, the first under the hero" % tg.size())
	var ring_ok := true
	for k in range(1, tg.size()):
		ring_ok = ring_ok and absf(Vector2(float(tg[k][0]) - hb.position.x, float(tg[k][1]) - hb.position.z).length() - 2.5) < 1e-6
	check(ring_ok, "the others 2.5 m round a hero")
	var hr0 := hurts.size()
	step(1.4)
	check(impacts("grasp").size() == 1 and hurts_of(14.0, hr0).size() == 1, "the ring that holds the hero hurts for 14 x scale")
	check(near(float(impacts("grasp")[0]["ev"]["root"]), 1.0) and impacts("grasp")[0]["ev"]["players"] == [str(me)], "Grasp roots 1 s and names the hero")
	check(float(hb.p["rootedUntil"]) > hb._clock_ms, "the hero body is rooted")
	# ---- Flood Hymn: first at 6.0 s, 2200 ms, a 15 m / 120 degree arc, 18 x 1.8; a pew between her and you is cover (players and thralls)
	var pew: Dictionary = boss.world.cover()[0]
	check(boss.world.cover().size() == 4, "the cover hook serves the four pews of the sim world")
	var t_open := thrall(arena() + Vector3(0.0, 0.0, 12.0))
	var t_pew := thrall(arena() + Vector3(2.0, 0.0, 12.0))
	step(1.0)   # they rise; stunned they stay where they are
	core.stun(t_open, 1.0e6)
	core.stun(t_pew, 1.0e6)
	# behind the first pew, seen from the dais: the hero and one thrall; the other thrall in the aisle between the two pews
	var behind := Vector3((float(pew["x0"]) + float(pew["x1"])) * 0.5, 0.0, float(pew["z1"]) + 3.0)
	put(behind)
	core.set_thrall_pos(t_pew, Vector2(behind.x - 0.8, behind.z + 0.6))
	core.set_thrall_pos(t_open, Vector2(0.0, -50.0))   # through the aisle between the two pews
	boss.world.refresh()
	step_until(func() -> bool: return not telegraphs("hymn").is_empty(), 6.0)
	var hy := hymn(0)
	check(absf(float(telegraphs("hymn")[0]["t"]) - 6.0) < 0.1 and near(float(hy["ms"]), 2200.0) and near(float(hy["r"]), 15.0), "Hymn at t = 6.0 s, 2200 ms, reach 15")
	check(absf(float(hy["dir"]) - atan2(behind.x - float(hy["x"]), behind.z - float(hy["z"]))) < 1e-6, "aimed at the nearest hero")
	var tp: Vector2 = core.thrall_info(t_pew)["pos"]
	var to: Vector2 = core.thrall_info(t_open)["pos"]
	var cov_hero: bool = boss.brain.covered(behind.x, behind.z, float(hy["x"]), float(hy["z"]))
	var cov_thrall: bool = boss.brain.covered(tp.x, tp.y, float(hy["x"]), float(hy["z"]))
	var cov_open: bool = boss.brain.covered(to.x, to.y, float(hy["x"]), float(hy["z"]))
	check(cov_hero and cov_thrall and not cov_open, "(the pew covers the hero and one thrall, the aisle does not)")
	hurts.clear()
	var hp_o := float(core.thrall_info(t_open)["hp"])
	var hp_p := float(core.thrall_info(t_pew)["hp"])
	step(2.3)
	check(impacts("hymn").size() == 1 and hurts_of(18.0 * 1.8).is_empty() and hurts.is_empty(), "behind a pew the Hymn does not touch the hero")
	check(float(core.thrall_info(t_pew)["hp"]) == hp_p and absf(hp_o - float(core.thrall_info(t_open)["hp"]) - scaled(20.0)) < 1e-3, "nor the thrall behind it; the thrall in the aisle is hurt for 20 x scale (%.1f)" % (hp_o - float(core.thrall_info(t_open)["hp"])))
	core.kill_thrall(t_open, "crumbled")
	core.kill_thrall(t_pew, "crumbled")
	# ---- the next Grasp: stepping 9 m off the rings dodges it
	step_until(func() -> bool: return telegraphs("grasp").size() >= 2, 6.0)
	hurts.clear()
	var g2: Dictionary = telegraphs("grasp")[1]
	check(absf(float(g2["t"]) - float(telegraphs("grasp")[0]["t"]) - 7.0) < 0.1, "Grasp repeats on its 7 s cooldown")
	put(arena() + Vector3(9.5, 0.0, 0.0))
	step(1.4)
	check(impacts("grasp").size() == 2 and hurts_of(14.0).is_empty(), "moving off the rings dodges the Grasp")
	# ---- Hymn in the open: 18 x 1.8 x scale + chill; the second Hymn is 11 s after the first
	put(arena() + Vector3(7.0, 0.0, 0.0))
	step_until(func() -> bool: return telegraphs("hymn").size() >= 2, 12.0)
	check(telegraphs("hymn").size() == 2 and absf(float(telegraphs("hymn")[1]["t"]) - float(telegraphs("hymn")[0]["t"]) - 11.0) < 0.1, "Hymn repeats on its 11 s cooldown")
	hurts.clear()
	step(2.3)
	check(hurts_of(18.0 * 1.8).size() == 1, "in the open the Hymn hurts for 18 x 1.8 x scale")
	check(DmStatusSet.of(hb) != null and DmStatusSet.of(hb).has(&"chill"), "...and chills the hero (2 s)")
	# ---- Phase 2 (60 %): six climb out (4 wraiths, 2 penitents) on the rim; the water slows wading (x0.85 off the dais)
	set_hp(0.7)
	var adds0 := adds().size()
	wound(0.59)
	check(boss.phase == 2 and events("phase").size() == 1, "phase 2 at 60 %")
	var sm := events("summon")
	check(sm.size() == 1 and sm[0]["ev"]["targets"].size() == 6 and adds().size() == adds0 + 6 and adds("wraith").size() == 4 and adds("penitent").size() == 2, "six climb out: 4 Choir Wraiths + 2 Bellbound Penitents (core bodies)")
	var on_rim := adds().all(func(id: int) -> bool: return absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - 9.35) < 0.01 and core.enemy_info(id)["area"] == "nave")
	check(on_rim, "on the arena rim (0.85 r), counted as Nave enemies")
	put(arena() + Vector3(8.0, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, 0.85), "the water slows wading outside the dais in phase 2 (x%.2f)" % hb.wade_mult)
	put(arena() + Vector3(2.0, 0.0, 0.0))
	await ticks(15)
	check(hb.wade_mult == 1.0, "on the dais the hero is not slowed")
	var h_n := telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() >= h_n + 2, 30.0)
	var p2h := telegraphs("hymn").slice(h_n)
	check(p2h.size() == 2 and absf(float(p2h[1]["t"]) - float(p2h[0]["t"]) - 11.0 * 0.9) < 0.1, "P2 cooldowns x0.9 (Hymn every %.1f s)" % (float(p2h[1]["t"]) - float(p2h[0]["t"])))
	# ---- Phase 3 (30 %): six more; wading x0.7; the Hymn is x1.2 on whoever stands in the water, x1.0 on the dais
	for id in adds():
		host.remove_enemy(id)
	await ticks(2)
	wound(0.29)
	check(boss.phase == 3 and events("summon").size() == 2 and adds("wraith").size() == 4 and adds("penitent").size() == 2, "phase 3: six more climb out")
	put(arena() + Vector3(8.0, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, 0.7), "wading x0.7 in phase 3 (x%.2f)" % hb.wade_mult)
	h_n = telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() > h_n, 12.0)
	hurts.clear()
	step(2.3)
	check(hurts_of(18.0 * 1.8 * 1.2).size() == 1, "standing in the water in phase 3 the Hymn is x1.2 (soaked)")
	put(arena() + Vector3(2.0, 0.0, 0.0))
	h_n = telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() > h_n, 12.0)
	hurts.clear()
	step(2.3)
	check(hurts_of(18.0 * 1.8).size() == 1 and hurts_of(18.0 * 1.8 * 1.2).is_empty(), "on the dais it is the plain 18 x 1.8")
	var p3h := telegraphs("hymn").slice(telegraphs("hymn").size() - 2)
	check(absf(float(p3h[1]["t"]) - float(p3h[0]["t"]) - 11.0 * 0.78) < 0.15, "P3 cooldowns x0.78 (Hymn every %.2f s)" % (float(p3h[1]["t"]) - float(p3h[0]["t"])))
	# ---- the water drains when she is gone (the party left: she goes back to sleep; the defeat comes in the generic part)
	put(arena() + Vector3(8.0, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, 0.7), "(still wading)")
	hb.teleport(Vector3(0.0, 0.0, 20.0))
	boss.world.refresh()
	step(0.1)
	await ticks(15)
	check(hb.wade_mult == 1.0 and adds().is_empty(), "gone: the water drains (no slow) and the climbers are back under")
	await dismiss()
