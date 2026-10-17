extends "res://tests/boss_base.gd"
## The Cinder Regent on the combat core (the Cinder Pyre's boss; godot/tests/next_bosses/regent_part.gd on today's game, the same numbers and timing). Her coals, the firebreak down the line of
## her cleave and what is left of the floor after a Conflagration are core zones of kind ember with her as the source (`DmCore.add_zone`), drawn by the zone visual.
##   - her recorded scenarios replay through the client's copy of the brain (the thralls scenario among them); the generic parts (boss_base.gd): the summon at the Ember Altar (6 soul shards),
##     thralls, rites, wipe, defeat, rewards;
##   - Cinder Cleave (the cone, 28 x scale) and its firebreak (3 ember pools at 1.9 / 3.7 / 5.5 m down the line, r 1.4, 5 s, dps 28 x scale x 0.3), Coals (4-6 circles, one on the hero, 22 x scale;
##     one pool per circle, r 1.8, 4 s), the pools burning a hero and a thrall once a second with her core id as the source;
##   - Conflagration (the telegraph carries the ash circles, spaced and inside the arena; off the ash it hurts 46 x scale as ember, on it nothing; the floor smoulders in up to 4 pools, never on the
##     ash), seeded so the circles are exact;
##   - the phases: the ash circles and the cooldowns, the coals' extra circles; each wave's bodies on the rim, core bodies of the Pyre (P2's 3 Cinder Husks and 2 Pyre Priests, P3's 2 Cinderhounds
##     and 2 Cinder Husks).
## Run: godot --headless --path client --script res://tests/boss_regent.gd [--fixed-fps 60 before --path runs it faster than real time]

var R: Dictionary


func _config() -> void:
	boss_id = "regent"
	load_areas = ["pyre"]
	bakes = ["thrall_legionnaire", "cinder_husk", "pyre_priest", "cinderhound"]
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


func embers() -> Array:
	return zones_made("ember", boss.core_id)


## Hold her cooldowns off so nothing she does is in the way of the step under test.
func hold_attacks() -> void:
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain._coals_cd = 1.0e9
	boss.brain._cleave_cd = 1.0e9
	boss.brain._confl_cd = 1.0e9


## Both waves: P2's 3 Cinder Husks and 2 Pyre Priests, then P3's 2 Cinderhounds and 2 Cinder Husks (nine bodies).
func provoke_waves() -> void:
	set_hp(0.5)
	wound(0.29)
	check(boss.phase == 3 and adds("cinder_husk").size() == 5 and adds("pyre_priest").size() == 2 and adds("cinderhound").size() == 2, "(both waves are in the core: %d bodies)" % adds().size())


func run_suite() -> void:
	R = DmContent.get_export("bosses", "REGENT")
	await t_summon(6, 28000.0)
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(9, provoke_waves)
	await t_defeat(true, provoke_waves)
	await t_real_clock(["cleave", "coals"], 14.0)
	await t_net_state()


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	var s: Dictionary = boss.brain.state
	check(int(s["level"]) == 30 and boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre (90, -117), phase 1, the Pyre's level 30")
	# ---- Cinder Cleave at 2.0 s
	put(arena() + Vector3(3.0, 0.0, 0.0))
	step(1.9)
	check(events("cleave").is_empty() and events("coals").is_empty(), "nothing before the opening cooldowns")
	step(0.2)
	var cl := telegraphs("cleave")
	check(cl.size() == 1 and absf(float(cl[0]["t"]) - 2.0) < 0.05, "Cinder Cleave telegraphed at 2.0 s")
	if cl.is_empty():
		return
	var e: Dictionary = cl[0]["ev"]
	var dir := float(e["dir"])
	check(near(float(e["ms"]), 900.0) and near(float(e["r"]), 5.2), "cleave telegraph 900 ms, radius 5.2")
	check(absf(dir - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "cone aimed at the hero")
	check(embers().is_empty() and core.zones("ember").is_empty(), "no firebreak before the blow")
	var ez0: int = g.enemy_fx.stats["zone"]
	step(1.0)
	var ci := impacts("cleave")
	check(ci.size() == 1 and absf(float(ci[0]["t"]) - float(cl[0]["t"]) - 0.9) < 0.03, "the cleave lands 0.9 s later")
	var ch := hurts.filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(28.0)) < 1e-6)
	check(ch.size() == 1, "cleave hurts for 28 x level x difficulty (%.1f)" % (float(ch[0]["dmg"]) if ch.size() > 0 else -1.0))
	var trail := embers()
	check(trail.size() == 3 and core.zones("ember").size() == 9, "the firebreak is 3 ember core zones down the line (%d)" % trail.size())
	var okp := trail.size() == 3
	for i in trail.size():
		var d: float = float(R["cleave"]["trail"][i])
		var zz: Array = trail[i]
		if not (absf(zz[3] - (float(e["x"]) + sin(dir) * d)) < 1e-3 and absf(zz[4] - (float(e["z"]) + cos(dir) * d)) < 1e-3 and near(zz[5], 1.4) and near(zz[6], 5.0)):
			okp = false
	check(okp, "trail pools at 1.9 / 3.7 / 5.5 m, r 1.4, 5 s, credited to the boss")
	check(g.enemy_fx.stats["zone"] >= ez0 + 3, "the ember pools are drawn by the zone visual of the zone events (%d)" % (g.enemy_fx.stats["zone"] - ez0))
	# ---- Coals at 3.0 s
	step(0.15)
	var co := telegraphs("coals")
	check(co.size() == 1 and absf(float(co[0]["t"]) - 3.0) < 0.1, "Coals telegraphed right after the cleave (3.0 s)")
	var nco := 0
	if co.size() == 1:
		var e2: Dictionary = co[0]["ev"]
		nco = e2["targets"].size()
		check(near(float(e2["ms"]), 1200.0) and near(float(e2["r"]), 1.8), "coals telegraph 1200 ms, circle radius 1.8")
		check(nco >= 4 and nco <= 6 and absf(float(e2["targets"][0][0]) - hb.position.x) < 1e-6, "4-6 circles, one on the hero (%d)" % nco)
	zone_log.clear()   # (the firebreak still burns; the log now counts the coals)
	var nh := hurts.size()
	step(1.4)
	var coal_t := impacts("coals")
	check(coal_t.size() >= 1, "the coals landed")
	var coal_hurt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(22.0)) < 1e-6)
	check(coal_hurt.size() == 1, "standing in a circle hurts once for 22 x scale")
	var cp := embers()
	check(cp.size() == nco and cp.all(func(z: Array) -> bool: return z[1] == "ember" and near(z[5], 1.8) and near(z[6], 4.0)), "one ember pool per circle, r 1.8, 4 s (%d of %d)" % [cp.size(), nco])
	# an ember pool burns on the core's clock: the hero in it is hurt dps x 1 s per pulse, credited to the boss; a thrall too
	boss.brain.state["x"] = arena().x - 6.0
	hold_attacks()
	var taken: Array = []
	var cb := func(t: float, src: Variant) -> void: taken.append([t, src])
	hb.hurt.connect(cb)
	step(2.2)
	hb.hurt.disconnect(cb)
	var dps := scaled(22.0) * 0.3
	var pulses := taken.filter(func(a: Array) -> bool: return absf(float(a[0]) - dps) < dps * 0.05)
	check(pulses.size() >= 1 and pulses.size() <= 6 and pulses.all(func(a: Array) -> bool: return a[1] is int and int(a[1]) == boss.core_id), "a hero on the coals is hurt dps x 1 s per pulse, credited to the boss (%d x %.2f)" % [pulses.size(), dps])
	wait_zones_out(["ember"])   # the coals and the firebreak run out (hold_attacks above: she calls no more)
	var tz := thrall(arena() + Vector3(7.0, 0.0, 7.0))
	step(1.0)
	core.stun(tz, 1.0e6)
	core.set_thrall_pos(tz, Vector2(arena().x + 7.0, arena().z + 7.0))
	core.add_zone("ember", Vector2(arena().x + 7.0, arena().z + 7.0), 2.0, 5.0, 10.0, boss.core_id)
	var tp := float(core.thrall_info(tz)["hp"])
	step(1.2)
	check(float(core.thrall_info(tz)["hp"]) < tp, "a thrall standing in the coals burns too (%.0f -> %.0f)" % [tp, float(core.thrall_info(tz)["hp"])])
	core.kill_thrall(tz, "crumbled")
	wait_zones_out(["ember"])
	hb.heal(1.0e6)
	# ---- Conflagration: the telegraph carries the ash circles; stand off them = 46 x scale, on one = safe
	evs.clear()
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	hold_attacks()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5   # the ash spots are random with an 80-try spacing rule: seeded so 4 / 3 circles are exact, not "usually"
	put(arena())
	step(0.05)
	var cf := telegraphs("conflagration")
	check(cf.size() == 1, "Conflagration telegraphed")
	var ash: Array = cf[0]["ev"]["targets"]
	var ev0: Dictionary = cf[0]["ev"]
	check(near(float(ev0["ms"]), 2700.0) and near(float(ev0["r"]), 11.0) and ash.size() == 4, "2700 ms, whole arena (r 11), 4 ash circles in phase 1 (%d)" % ash.size())
	var spaced := true
	var inside := true
	for i in ash.size():
		inside = inside and Vector2(float(ash[i][0]) - arena().x, float(ash[i][1]) - arena().z).length() <= 11.0 - 2.7 - 0.6 + 1e-6
		for j in range(i + 1, ash.size()):
			spaced = spaced and Vector2(float(ash[i][0]) - float(ash[j][0]), float(ash[i][1]) - float(ash[j][1])).length() > 2.7 * 2.0 + 1.0
	check(spaced and inside, "ash circles are inside the arena and never touch each other")
	check(absf(float(boss.brain._confl_cd) - 15.0) < 0.1, "Conflagration cooldown 15 s")
	var off := Vector3.INF   # off the ash: a spot in the arena clear of every circle
	for k in 48:
		var a := float(k) * 0.37
		var r := 9.5 - float(k % 5) * 1.5
		var cand := arena() + Vector3(sin(a) * r, 0.0, cos(a) * r)
		if ash.all(func(t: Array) -> bool: return Vector2(cand.x - float(t[0]), cand.z - float(t[1])).length() > 2.7 + 0.5):
			off = cand
			break
	check(off != Vector3.INF, "there is room off the ash")
	put(off)
	zone_log.clear()
	nh = hurts.size()
	step(2.8)
	var ci2 := impacts("conflagration")
	check(ci2.size() == 1 and absf(float(ci2[0]["t"]) - float(cf[0]["t"]) - 2.7) < 0.03, "it erupts 2.7 s later")
	var burnt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(46.0)) < 1e-6 and h["from"] == "ember")
	check(burnt.size() == 1, "off the ash the eruption hurts for 46 x scale")
	var emb := embers()
	check(emb.size() >= 1 and emb.size() <= 4 and emb.all(func(z: Array) -> bool: return near(z[5], 1.8) and near(z[6], 4.0)), "what is left of the floor smoulders in up to 4 pools (r 1.8, 4 s) (%d)" % emb.size())
	var on_ash_pool := emb.any(func(z: Array) -> bool: return ash.any(func(t: Array) -> bool: return Vector2(z[3] - float(t[0]), z[4] - float(t[1])).length() <= 2.7))
	check(not on_ash_pool, "never on the ash")
	wait_zones_out(["ember"])
	# on the ash
	hold_attacks()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5
	boss.world.refresh()
	step(0.05)
	var cf2 := telegraphs("conflagration")
	var ash2: Array = cf2[1]["ev"]["targets"]
	put(Vector3(float(ash2[0][0]), 0.0, float(ash2[0][1])))
	nh = hurts.size()
	step(2.8)
	check(hurts.slice(nh).filter(func(h: Dictionary) -> bool: return h["from"] == "ember").is_empty(), "on an ash circle the eruption does nothing")
	wait_zones_out(["ember"])
	# ---- phases, adds, tighter ash
	hold_attacks()
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "phase 2 at 60 %")
	check(events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 5, "summon event with 5 rim spots")
	check(events("summon")[0]["ev"]["targets"].all(func(t: Array) -> bool: return absf(Vector2(float(t[0]) - arena().x, float(t[1]) - arena().z).length() - 11.0 * 0.85) < 0.01), "on the arena rim")
	var wave2 := adds()
	check(adds("cinder_husk").size() == 3 and adds("pyre_priest").size() == 2 and wave2.size() == 5, "P2 calls 3 Cinder Husks + 2 Pyre Priests (core bodies)")
	check(wave2.all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "pyre" and absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - 11.0 * 0.85) < 0.01), "on the arena rim, counted as Pyre enemies")
	clear_adds()
	hold_attacks()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5
	boss.world.refresh()
	step(0.05)
	var cf3 := telegraphs("conflagration")
	check(cf3[cf3.size() - 1]["ev"]["targets"].size() == 3 and absf(float(boss.brain._confl_cd) - 15.0 * 0.88) < 0.15, "P2 has 3 ash circles, cooldown 15 x 0.88 s")
	hold_attacks()
	boss.brain._coals_cd = 0.0
	boss.world.refresh()
	step(0.05)
	check(absf(float(boss.brain._coals_cd) - 7.0 * 0.88) < 0.15, "P2 coals cooldown 7 x 0.88 s")
	hold_attacks()
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	step(0.1)
	check(boss.phase == 3, "phase 3 at 30 %")
	check(adds("cinderhound").size() == 2 and adds("cinder_husk").size() == 2 and adds().size() == 4 and events("summon").size() == 2 and events("summon")[1]["ev"]["targets"].size() == 4, "P3 calls 2 Cinderhounds + 2 Cinder Husks (core bodies, their 4 spots told)")
	clear_adds()
	hold_attacks()
	boss.brain._coals_cd = 0.0
	boss.world.refresh()
	step(0.05)
	var co3 := telegraphs("coals")
	var n3: int = co3[co3.size() - 1]["ev"]["targets"].size()
	check(n3 >= 6 and n3 <= 8 and absf(float(boss.brain._coals_cd) - 7.0 * 0.75) < 0.15, "P3 coals 6-8 circles (+2), cooldown 7 x 0.75 s (%d)" % n3)
	hold_attacks()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5
	boss.world.refresh()
	step(0.05)
	var cf4 := telegraphs("conflagration")
	check(cf4[cf4.size() - 1]["ev"]["targets"].size() == 2, "P3 leaves only 2 ash circles")
	hold_attacks()
	await dismiss()
