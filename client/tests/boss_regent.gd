extends "res://tests/boss_base.gd"
## The Cinder Regent on the combat core (the Cinder Pyre's boss; archive/old-game:godot/tests/next_bosses/regent_part.gd on today's game, the same numbers and timing). Her coals, the firebreak down the line of
## her cleave and what is left of the floor after a Conflagration are core zones of kind ember with her as the source (`DmCore.add_zone`), drawn by the zone visual.
##   - her recorded scenarios are replayed by tests/bosses (not here) (the thralls scenario among them); the generic parts (boss_base.gd): the summon at the Ember Altar (its soul shards),
##     thralls, rites, wipe, defeat, rewards;
##   - Cinder Cleave (the cone) and its firebreak (ember pools down the line at the data's distances, dps = the cleave's x trailDpsMult), Coals (circles, one on the hero; one pool per circle),
##     the pools burning a hero and a thrall once a second with her core id as the source; every number is the boss data's (`REGENT` in bosses.json), her opening cooldowns the brain's on waking;
##   - Conflagration (the telegraph carries the ash circles, spaced and inside the arena; off the ash it hurts as ember, on it nothing; the floor smoulders in up to `embers` pools, never on the
##     ash), seeded so the circles are exact;
##   - the phases: the ash circles and the cooldowns, the coals' extra circles; each wave's bodies on the rim, core bodies of the Pyre (the data's `adds`).
## Run: godot --headless --path client --script res://tests/boss_regent.gd [--fixed-fps 60 before --path runs it faster than real time]

## What her brain does that is in its code and not in the boss data (sim/bosses/regent_brain.gd): her cooldowns are scaled by phase, phase 3 adds two circles to the Coals, the ash circles keep
## a gap of 1 m (and 0.6 m off the arena's edge), and the floor Conflagration leaves smoulders in pools of radius 1.8.
const FAST := [1.0, 0.88, 0.75]
const COALS_P3_EXTRA := 2
const ASH_GAP := 1.0
const ASH_EDGE := 0.6
const EMBER_R := 1.8

var R: Dictionary


func _config() -> void:
	boss_id = "regent"
	load_areas = ["pyre"]
	bakes = ["thrall_legionnaire", "cinder_husk", "pyre_priest", "cinderhound"]


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
## How many of `kind` the data's waves call, phase 2's and phase 3's together (or one wave's, `wave` "p2" or "p3").
func wave_count(kind: String, wave := "") -> int:
	var n := 0
	for w in ["p2", "p3"]:
		if wave == "" or wave == w:
			n += (R["adds"][w] as Array).count(kind)
	return n


func provoke_waves() -> void:
	set_hp(float(PHASE_AT[1]) + 0.2)
	wound_into(3)
	check(boss.phase == 3 and adds("cinder_husk").size() == wave_count("cinder_husk") and adds("pyre_priest").size() == wave_count("pyre_priest") and adds("cinderhound").size() == wave_count("cinderhound"), "(both waves are in the core: %d bodies)" % adds().size())


func run_suite() -> void:
	R = DmContent.get_export("bosses", "REGENT")
	await t_summon()
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe((R["adds"]["p2"] as Array).size() + (R["adds"]["p3"] as Array).size(), provoke_waves)
	await t_defeat(true, provoke_waves)
	await t_real_clock(["cleave", "coals"], 14.0)
	await t_net_state()


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	var s: Dictionary = boss.brain.state
	check(int(s["level"]) == area_level() and boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre, phase 1, the Pyre's level (%d)" % area_level())
	var open_cleave: float = boss.brain._cleave_cd   # her opening cooldowns, as her brain sets them on waking
	var open_coals: float = boss.brain._coals_cd
	var cleave_s := float(R["cleave"]["windupMs"]) / 1000.0
	var coals_s := float(R["coals"]["windupMs"]) / 1000.0
	var confl_s := float(R["conflagration"]["windupMs"]) / 1000.0
	var arena_r := float(def()["arena"]["r"])
	var C: Dictionary = R["conflagration"]
	var safe_r := float(C["safeR"])
	# ---- Cinder Cleave at its opening cooldown
	put(arena() + Vector3(minf(3.0, float(R["cleave"]["r"]) * 0.6), 0.0, 0.0))
	step(minf(open_cleave, open_coals) - 0.1)
	check(events("cleave").is_empty() and events("coals").is_empty(), "nothing before the opening cooldowns")
	step_until(func() -> bool: return not telegraphs("cleave").is_empty(), open_cleave + 1.0)
	var cl := telegraphs("cleave")
	check(cl.size() == 1 and absf(float(cl[0]["t"]) - open_cleave) < 0.1, "Cinder Cleave telegraphed at %.1f s" % open_cleave)
	if cl.is_empty():
		return
	var e: Dictionary = cl[0]["ev"]
	var dir := float(e["dir"])
	check(near(float(e["ms"]), float(R["cleave"]["windupMs"])) and near(float(e["r"]), float(R["cleave"]["r"])), "cleave telegraph %d ms, radius %.1f" % [int(R["cleave"]["windupMs"]), float(R["cleave"]["r"])])
	check(absf(dir - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "cone aimed at the hero")
	check(embers().is_empty() and core.zones("ember").is_empty(), "no firebreak before the blow")
	var ez0: int = g.enemy_fx.stats["zone"]
	step_until(func() -> bool: return not impacts("cleave").is_empty(), cleave_s + 1.0)
	var ci := impacts("cleave")
	check(ci.size() == 1 and absf(float(ci[0]["t"]) - float(cl[0]["t"]) - cleave_s) < 0.03, "the cleave lands %.1f s later" % cleave_s)
	var ch := hurts.filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(float(R["cleave"]["dmg"]))) < 1e-6)
	check(ch.size() == 1, "cleave hurts for %d x level x difficulty (%.1f)" % [int(R["cleave"]["dmg"]), float(ch[0]["dmg"]) if ch.size() > 0 else -1.0])
	var trail := embers()
	var trail_n: int = (R["cleave"]["trail"] as Array).size()
	check(trail.size() == trail_n and core.zones("ember").size() == 3 * trail_n, "the firebreak is %d ember core zones down the line (%d)" % [trail_n, trail.size()])
	var okp := trail.size() == trail_n
	for i in mini(trail.size(), trail_n):
		var d: float = float(R["cleave"]["trail"][i])
		var zz: Array = trail[i]
		if not (absf(zz[3] - (float(e["x"]) + sin(dir) * d)) < 1e-3 and absf(zz[4] - (float(e["z"]) + cos(dir) * d)) < 1e-3 and near(zz[5], float(R["cleave"]["trailR"])) and near(zz[6], float(R["cleave"]["trailS"]))):
			okp = false
	check(okp, "trail pools at the data's distances down the line, r %.1f, %.0f s, credited to the boss" % [float(R["cleave"]["trailR"]), float(R["cleave"]["trailS"])])
	check(g.enemy_fx.stats["zone"] >= ez0 + trail_n, "the ember pools are drawn by the zone visual of the zone events (%d)" % (g.enemy_fx.stats["zone"] - ez0))
	# ---- Coals at their opening cooldown (or when the cleave is done)
	step_until(func() -> bool: return not telegraphs("coals").is_empty(), open_coals + cleave_s + 1.0)
	var co := telegraphs("coals")
	check(co.size() == 1 and absf(float(co[0]["t"]) - maxf(open_coals, float(cl[0]["t"]) + cleave_s)) < 0.15, "Coals telegraphed right after the cleave (%.1f s)" % (float(co[0]["t"]) if co.size() == 1 else -1.0))
	var nco := 0
	var circles: Array = R["coals"]["circles"]
	if co.size() == 1:
		var e2: Dictionary = co[0]["ev"]
		nco = e2["targets"].size()
		check(near(float(e2["ms"]), float(R["coals"]["windupMs"])) and near(float(e2["r"]), float(R["coals"]["r"])), "coals telegraph %d ms, circle radius %.1f" % [int(R["coals"]["windupMs"]), float(R["coals"]["r"])])
		check(nco >= int(circles[0]) and nco <= int(circles[1]) and absf(float(e2["targets"][0][0]) - hb.position.x) < 1e-6, "%d to %d circles, one on the hero (%d)" % [int(circles[0]), int(circles[1]), nco])
	zone_log.clear()   # (the firebreak still burns; the log now counts the coals)
	var nh := hurts.size()
	step(coals_s + 0.2)
	var coal_t := impacts("coals")
	check(coal_t.size() >= 1, "the coals landed")
	var coal_hurt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(float(R["coals"]["dmg"]))) < 1e-6)
	check(coal_hurt.size() == 1, "standing in a circle hurts once for %d x scale" % int(R["coals"]["dmg"]))
	var cp := embers()
	check(cp.size() == nco and cp.all(func(z: Array) -> bool: return z[1] == "ember" and near(z[5], float(R["coals"]["r"])) and near(z[6], float(R["coals"]["poolS"]))), "one ember pool per circle, r %.1f, %.0f s (%d of %d)" % [float(R["coals"]["r"]), float(R["coals"]["poolS"]), cp.size(), nco])
	# an ember pool burns on the core's clock: the hero in it is hurt dps x 1 s per pulse, credited to the boss; a thrall too
	boss.brain.state["x"] = arena().x - 6.0
	hold_attacks()
	var taken: Array = []
	var cb := func(t: float, src: Variant) -> void: taken.append([t, src])
	hb.hurt.connect(cb)
	step(2.2)
	hb.hurt.disconnect(cb)
	var dps := scaled(float(R["coals"]["dmg"])) * float(R["coals"]["poolDpsMult"])
	var pulses := taken.filter(func(a: Array) -> bool: return absf(float(a[0]) - dps) < dps * 0.05)
	check(pulses.size() >= 1 and pulses.size() <= 6 and pulses.all(func(a: Array) -> bool: return a[1] is int and int(a[1]) == boss.core_id), "a hero on the coals is hurt dps x 1 s per pulse, credited to the boss (%d x %.2f)" % [pulses.size(), dps])
	wait_zones_out(["ember"])   # the coals and the firebreak run out (hold_attacks above: she calls no more)
	var tz := thrall(arena() + Vector3(7.0, 0.0, 7.0))
	step(DmSimConsts.THRALL_RISE_TIME + 0.1)
	core.stun(tz, 1.0e6)
	core.set_thrall_pos(tz, Vector2(arena().x + 7.0, arena().z + 7.0))
	core.add_zone("ember", Vector2(arena().x + 7.0, arena().z + 7.0), 2.0, 5.0, 10.0, boss.core_id)
	var tp := float(core.thrall_info(tz)["hp"])
	step(1.2)
	check(float(core.thrall_info(tz)["hp"]) < tp, "a thrall standing in the coals burns too (%.0f -> %.0f)" % [tp, float(core.thrall_info(tz)["hp"])])
	core.kill_thrall(tz, "crumbled")
	wait_zones_out(["ember"])
	hb.heal(1.0e6)
	# ---- Conflagration: the telegraph carries the ash circles; stand off them = hurt, on one = safe
	evs.clear()
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	hold_attacks()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5   # the ash spots are random with an 80-try spacing rule: seeded so the circles are exact, not "usually"
	put(arena())
	step(0.05)
	var cf := telegraphs("conflagration")
	check(cf.size() == 1, "Conflagration telegraphed")
	var ash: Array = cf[0]["ev"]["targets"]
	var ev0: Dictionary = cf[0]["ev"]
	var safe_n: Array = C["safe"]
	check(near(float(ev0["ms"]), float(C["windupMs"])) and near(float(ev0["r"]), arena_r) and ash.size() == int(safe_n[0]), "%d ms, whole arena (r %.0f), %d ash circles in phase 1 (%d)" % [int(C["windupMs"]), arena_r, int(safe_n[0]), ash.size()])
	var spaced := true
	var inside := true
	for i in ash.size():
		inside = inside and Vector2(float(ash[i][0]) - arena().x, float(ash[i][1]) - arena().z).length() <= arena_r - safe_r - ASH_EDGE + 1e-6
		for j in range(i + 1, ash.size()):
			spaced = spaced and Vector2(float(ash[i][0]) - float(ash[j][0]), float(ash[i][1]) - float(ash[j][1])).length() > safe_r * 2.0 + ASH_GAP
	check(spaced and inside, "ash circles are inside the arena and never touch each other")
	check(absf(float(boss.brain._confl_cd) - float(C["cd"])) < 0.1, "Conflagration cooldown %d s" % int(C["cd"]))
	var off := Vector3.INF   # off the ash: a spot in the arena clear of every circle
	for k in 48:
		var a := float(k) * 0.37
		var r := (arena_r - 1.5) - float(k % 5) * 1.5
		var cand := arena() + Vector3(sin(a) * r, 0.0, cos(a) * r)
		if ash.all(func(t: Array) -> bool: return Vector2(cand.x - float(t[0]), cand.z - float(t[1])).length() > safe_r + 0.5):
			off = cand
			break
	check(off != Vector3.INF, "there is room off the ash")
	put(off)
	zone_log.clear()
	nh = hurts.size()
	step(confl_s + 0.1)
	var ci2 := impacts("conflagration")
	check(ci2.size() == 1 and absf(float(ci2[0]["t"]) - float(cf[0]["t"]) - confl_s) < 0.03, "it erupts %.1f s later" % confl_s)
	var burnt := hurts.slice(nh).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(float(C["dmg"]))) < 1e-6 and h["from"] == "ember")
	check(burnt.size() == 1, "off the ash the eruption hurts for %d x scale" % int(C["dmg"]))
	var emb := embers()
	check(emb.size() >= 1 and emb.size() <= int(C["embers"]) and emb.all(func(z: Array) -> bool: return near(z[5], EMBER_R) and near(z[6], float(C["emberS"]))), "what is left of the floor smoulders in up to %d pools (r %.1f, %.0f s) (%d)" % [int(C["embers"]), EMBER_R, float(C["emberS"]), emb.size()])
	var on_ash_pool := emb.any(func(z: Array) -> bool: return ash.any(func(t: Array) -> bool: return Vector2(z[3] - float(t[0]), z[4] - float(t[1])).length() <= safe_r))
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
	step(confl_s + 0.1)
	check(hurts.slice(nh).filter(func(h: Dictionary) -> bool: return h["from"] == "ember").is_empty(), "on an ash circle the eruption does nothing")
	wait_zones_out(["ember"])
	# ---- phases, adds, tighter ash
	hold_attacks()
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp - boss.max_hp * just_into(2), hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "phase 2")
	var p2: Array = R["adds"]["p2"]
	var p3: Array = R["adds"]["p3"]
	var rim_r := arena_r * RIM
	check(events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == p2.size(), "summon event with %d rim spots" % p2.size())
	check(events("summon")[0]["ev"]["targets"].all(func(t: Array) -> bool: return absf(Vector2(float(t[0]) - arena().x, float(t[1]) - arena().z).length() - rim_r) < 0.01), "on the arena rim")
	var wave2 := adds()
	check(wave2.size() == p2.size() and adds("cinder_husk").size() == wave_count("cinder_husk", "p2") and adds("pyre_priest").size() == wave_count("pyre_priest", "p2"), "P2 calls its %d bodies (core bodies)" % p2.size())
	check(wave2.all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "pyre" and absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - rim_r) < 0.01), "on the arena rim, counted as Pyre enemies")
	clear_adds()
	hold_attacks()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5
	boss.world.refresh()
	step(0.05)
	var cf3 := telegraphs("conflagration")
	check(cf3[cf3.size() - 1]["ev"]["targets"].size() == int(safe_n[1]) and absf(float(boss.brain._confl_cd) - float(C["cd"]) * float(FAST[1])) < 0.15, "P2 has %d ash circles, cooldown %d x %.2f s" % [int(safe_n[1]), int(C["cd"]), float(FAST[1])])
	hold_attacks()
	boss.brain._coals_cd = 0.0
	boss.world.refresh()
	step(0.05)
	check(absf(float(boss.brain._coals_cd) - float(R["coals"]["cd"]) * float(FAST[1])) < 0.15, "P2 coals cooldown %d x %.2f s" % [int(R["coals"]["cd"]), float(FAST[1])])
	hold_attacks()
	boss.take_damage(boss.hp - boss.max_hp * just_into(3), hb)
	step(0.1)
	check(boss.phase == 3, "phase 3")
	check(adds("cinderhound").size() == wave_count("cinderhound", "p3") and adds("cinder_husk").size() == wave_count("cinder_husk", "p3") and adds().size() == p3.size() and events("summon").size() == 2 and events("summon")[1]["ev"]["targets"].size() == p3.size(), "P3 calls its %d bodies (core bodies, their spots told)" % p3.size())
	clear_adds()
	hold_attacks()
	boss.brain._coals_cd = 0.0
	boss.world.refresh()
	step(0.05)
	var co3 := telegraphs("coals")
	var n3: int = co3[co3.size() - 1]["ev"]["targets"].size()
	check(n3 >= int(circles[0]) + COALS_P3_EXTRA and n3 <= int(circles[1]) + COALS_P3_EXTRA and absf(float(boss.brain._coals_cd) - float(R["coals"]["cd"]) * float(FAST[2])) < 0.15, "P3 coals %d to %d circles (+%d), cooldown %d x %.2f s (%d)" % [int(circles[0]) + COALS_P3_EXTRA, int(circles[1]) + COALS_P3_EXTRA, COALS_P3_EXTRA, int(R["coals"]["cd"]), float(FAST[2]), n3])
	hold_attacks()
	boss.brain._confl_cd = 0.0
	g.bosses.rng.seed = 5
	boss.world.refresh()
	step(0.05)
	var cf4 := telegraphs("conflagration")
	check(cf4[cf4.size() - 1]["ev"]["targets"].size() == int(safe_n[2]), "P3 leaves only %d ash circles" % int(safe_n[2]))
	hold_attacks()
	await dismiss()
