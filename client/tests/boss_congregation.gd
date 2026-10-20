extends "res://tests/boss_base.gd"
## The Drowned Congregation on the combat core (the Drowned Nave's boss; archive/old-game:godot/tests/next_bosses/congregation_part.gd on today's game, the same numbers and timing). Her climbers are core
## bodies (the Choir Wraith and the Bellbound Penitent), the pews are cover (`DmDb.sim_world()["cover"]`), her grasp roots and her hymn chills the hero.
##   - her recorded scenarios are replayed by tests/bosses (not here) (the pews scenario among them); the generic parts (boss_base.gd): the summon at the Drowned Font (its soul shards),
##     thralls, rites, wipe, defeat, rewards;
##   - Maul, Drowning Grasp (the rings, the root) and Flood Hymn (the arc, the chill) at the ticks of her brain's opening cooldowns and the numbers of the boss data (`CONGREGATION` in bosses.json); a pew
##     between her and a hero or a thrall is cover (the thrall in the aisle is hurt);
##   - the rising water: wading slower in phase 2 and 3 off her dais (the host's wade clock), the soaked Hymn in phase 3; each phase's climbers (wraiths and penitents) on the rim;
##   - when she is gone the water drains and the climbers are back under (a wipe takes them out silently, a defeat likewise: the generic parts).
## Run: godot --headless --path client --script res://tests/boss_congregation.gd [--fixed-fps 60 before --path runs it faster than real time]


## What her brain does that is in its code and not in the boss data (sim/bosses/congregation_brain.gd): each phase six climb out (four Choir Wraiths, two Bellbound Penitents), her cooldowns are
## scaled by phase, and a Grasp's extra rings fall 2.5 m round a hero.
const WRAITHS := 4
const PENITENTS := 2
const FAST := [1.0, 0.9, 0.78]
const RING_OFFSET := 2.5

var C: Dictionary                      ## the boss data's CONGREGATION


func _config() -> void:
	boss_id = "congregation"
	load_areas = ["nave"]
	bakes = ["thrall_legionnaire", "choir_wraith", "penitent"]


func adds(def_id := "") -> Array:
	var out: Array = []
	for id in core.enemy_ids():
		var info: Dictionary = core.enemy_info(id)
		if int(info["state"]) != DmCoreEvents.State.DEAD and (def_id == "" or info["def"] == def_id):
			out.append(int(id))
	return out


func hymn(n: int) -> Dictionary:
	return telegraphs("hymn")[n]["ev"]


## When the next `kind` comes after one cast at `first_t` whose cooldown is `cd`: a Maul, a Grasp or a Hymn in its wind-up at that moment holds her (busy) until it ends, and the next one comes then.
## (Her cooldowns are the data's: how they fall against each other is not for a test to assume.)
func due_after(kind: String, first_t: float, cd: float) -> float:
	var due := first_t + cd
	var held := due
	for k in ["hymn", "grasp", "maul"]:
		if k == kind:
			continue
		for e: Dictionary in telegraphs(k):
			var start := float(e["t"])
			var end := start + float(e["ev"]["ms"]) / 1000.0
			if start < due and end > due:
				held = maxf(held, end)
	return held


func run_suite() -> void:
	C = DmContent.get_export("bosses", "CONGREGATION")
	await t_summon()
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(WRAITHS + PENITENTS, func() -> void:
		wound_to_phase_two())
	await t_defeat(true)
	await t_real_clock(["maul", "grasp", "hymn"], 12.0)
	await t_net_state()


func wound_to_phase_two() -> void:
	set_hp(float(PHASE_AT[0]) + 0.1)
	wound_into(2)
	check(boss.phase == 2 and adds().size() == WRAITHS + PENITENTS, "(phase 2: the climbers)")


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	var open_maul: float = boss.brain._melee_cd   # her opening cooldowns, as her brain sets them on waking
	var open_grasp: float = boss.brain._grasp_cd
	var open_hymn: float = boss.brain._hymn_cd
	var maul_s := float(C["melee"]["windupMs"]) / 1000.0
	var grasp_s := float(C["grasp"]["windupMs"]) / 1000.0
	var hymn_s := float(C["hymn"]["windupMs"]) / 1000.0
	var hymn_dmg := float(C["hymn"]["base"]) * float(C["hymn"]["dmgMult"])
	var dais := float(C["water"]["dais"])
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre, phase 1")
	check(adds().is_empty() and hb.wade_mult == 1.0, "nothing climbs out and the water is still in phase 1")
	# ---- Maul: first at her opening cooldown when someone is within r + 0.5
	put(arena() + Vector3(minf(3.0, float(C["melee"]["r"]) * 0.8), 0.0, 0.0))
	step(open_maul - 0.1)
	check(telegraphs("maul").is_empty(), "no attack before the opening cooldown")
	step(0.2)
	var ml := telegraphs("maul")
	check(ml.size() == 1 and absf(float(ml[0]["t"]) - open_maul) < 0.05 and near(float(ml[0]["ev"]["ms"]), float(C["melee"]["windupMs"])) and near(float(ml[0]["ev"]["r"]), float(C["melee"]["r"])), "Maul at t = %.1f s, %d ms, r %.0f" % [open_maul, int(C["melee"]["windupMs"]), float(C["melee"]["r"])])
	check(absf(float(ml[0]["ev"]["dir"]) - atan2(hb.position.x - float(ml[0]["ev"]["x"]), hb.position.z - float(ml[0]["ev"]["z"]))) < 1e-6, "aimed at the nearest hero")
	step(maul_s)
	check(impacts("maul").size() == 1 and absf(float(impacts("maul")[0]["t"]) - float(ml[0]["t"]) - maul_s) < 0.03 and hurts_of(float(C["melee"]["dmg"])).size() == 1, "the Maul lands %.1f s later for %d x level x difficulty" % [maul_s, int(C["melee"]["dmg"])])
	# ---- Drowning Grasp: first at her opening cooldown, the rings (one on every player first, the rest round them), root
	step_until(func() -> bool: return not telegraphs("grasp").is_empty(), open_grasp + 1.0)
	var gr := telegraphs("grasp")
	check(gr.size() == 1 and absf(float(gr[0]["t"]) - open_grasp) < 0.05 and near(float(gr[0]["ev"]["ms"]), float(C["grasp"]["windupMs"])) and near(float(gr[0]["ev"]["r"]), float(C["grasp"]["r"])), "Grasp at t = %.1f s, %d ms, rings r %.1f" % [open_grasp, int(C["grasp"]["windupMs"]), float(C["grasp"]["r"])])
	var tg: Array = gr[0]["ev"]["targets"]
	var rings: Array = C["grasp"]["rings"]
	check(tg.size() >= int(rings[0]) and tg.size() <= int(rings[1]) and absf(float(tg[0][0]) - hb.position.x) < 1e-6 and absf(float(tg[0][1]) - hb.position.z) < 1e-6, "%d rings (%d to %d), the first under the hero" % [tg.size(), int(rings[0]), int(rings[1])])
	var ring_ok := true
	for k in range(1, tg.size()):
		ring_ok = ring_ok and absf(Vector2(float(tg[k][0]) - hb.position.x, float(tg[k][1]) - hb.position.z).length() - RING_OFFSET) < 1e-6
	check(ring_ok, "the others %.1f m round a hero" % RING_OFFSET)
	var hr0 := hurts.size()
	step(grasp_s + 0.1)
	check(impacts("grasp").size() == 1 and hurts_of(float(C["grasp"]["dmg"]), hr0).size() == 1, "the ring that holds the hero hurts for %d x scale" % int(C["grasp"]["dmg"]))
	check(near(float(impacts("grasp")[0]["ev"]["root"]), float(C["grasp"]["rootS"])) and impacts("grasp")[0]["ev"]["players"] == [str(me)], "Grasp roots %d s and names the hero" % int(C["grasp"]["rootS"]))
	check(float(hb.p["rootedUntil"]) > hb._clock_ms, "the hero body is rooted")
	# ---- Flood Hymn: first at her opening cooldown, an arc; a pew between her and you is cover (players and thralls)
	var pew: Dictionary = boss.world.cover()[0]
	check(boss.world.cover().size() == DmDb.sim_world()["cover"].size(), "the cover hook serves the pews of the sim world (%d)" % boss.world.cover().size())
	var t_open := thrall(arena() + Vector3(0.0, 0.0, 12.0))
	var t_pew := thrall(arena() + Vector3(2.0, 0.0, 12.0))
	step(DmSimConsts.THRALL_RISE_TIME + 0.1)   # they rise; stunned they stay where they are
	core.stun(t_open, 1.0e6)
	core.stun(t_pew, 1.0e6)
	# behind the first pew, seen from the dais: the hero and one thrall; the other thrall in the aisle between the two pews
	var behind := Vector3((float(pew["x0"]) + float(pew["x1"])) * 0.5, 0.0, float(pew["z1"]) + 3.0)
	put(behind)
	core.set_thrall_pos(t_pew, Vector2(behind.x - 0.8, behind.z + 0.6))
	core.set_thrall_pos(t_open, Vector2(0.0, -50.0))   # through the aisle between the two pews
	boss.world.refresh()
	step_until(func() -> bool: return not telegraphs("hymn").is_empty(), open_hymn + 1.0)
	var hy := hymn(0)
	check(absf(float(telegraphs("hymn")[0]["t"]) - open_hymn) < 0.1 and near(float(hy["ms"]), float(C["hymn"]["windupMs"])) and near(float(hy["r"]), float(C["hymn"]["reach"])), "Hymn at t = %.1f s, %d ms, reach %d" % [open_hymn, int(C["hymn"]["windupMs"]), int(C["hymn"]["reach"])])
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
	step(hymn_s + 0.1)
	check(impacts("hymn").size() == 1 and hurts_of(hymn_dmg).is_empty() and hurts.is_empty(), "behind a pew the Hymn does not touch the hero")
	check(float(core.thrall_info(t_pew)["hp"]) == hp_p and absf(hp_o - float(core.thrall_info(t_open)["hp"]) - scaled(THRALL_BLOW)) < 1e-3, "nor the thrall behind it; the thrall in the aisle is hurt for %d x scale (%.1f)" % [int(THRALL_BLOW), hp_o - float(core.thrall_info(t_open)["hp"])])
	core.kill_thrall(t_open, "crumbled")
	core.kill_thrall(t_pew, "crumbled")
	# ---- the next Grasp: stepping off the rings dodges it
	step_until(func() -> bool: return telegraphs("grasp").size() >= 2, float(C["grasp"]["cd"]) + 3.0)
	hurts.clear()
	var g2: Dictionary = telegraphs("grasp")[1]
	check(absf(float(g2["t"]) - due_after("grasp", float(telegraphs("grasp")[0]["t"]), float(C["grasp"]["cd"]))) < 0.1, "Grasp repeats on its %d s cooldown (or when an attack that holds her ends)" % int(C["grasp"]["cd"]))
	put(arena() + Vector3(9.5, 0.0, 0.0))
	step(grasp_s + 0.1)
	check(impacts("grasp").size() == 2 and hurts_of(float(C["grasp"]["dmg"])).is_empty(), "moving off the rings dodges the Grasp")
	# ---- Hymn in the open: the arc's damage + chill; the second Hymn is a cooldown after the first
	put(arena() + Vector3(7.0, 0.0, 0.0))
	step_until(func() -> bool: return telegraphs("hymn").size() >= 2, float(C["hymn"]["cd"]) + 3.0)
	check(telegraphs("hymn").size() == 2 and absf(float(telegraphs("hymn")[1]["t"]) - due_after("hymn", float(telegraphs("hymn")[0]["t"]), float(C["hymn"]["cd"]))) < 0.1, "Hymn repeats on its %d s cooldown (or when an attack that holds her ends)" % int(C["hymn"]["cd"]))
	hurts.clear()
	step(hymn_s + 0.1)
	check(hurts_of(hymn_dmg).size() == 1, "in the open the Hymn hurts for %d x %.1f x scale" % [int(C["hymn"]["base"]), float(C["hymn"]["dmgMult"])])
	check(DmStatusSet.of(hb) != null and DmStatusSet.of(hb).has(&"chill"), "...and chills the hero")
	# ---- Phase 2: the climbers come out on the rim; the water slows wading off the dais
	set_hp(float(PHASE_AT[0]) + 0.1)
	var adds0 := adds().size()
	wound_into(2)
	check(boss.phase == 2 and events("phase").size() == 1, "phase 2")
	var sm := events("summon")
	check(sm.size() == 1 and sm[0]["ev"]["targets"].size() == WRAITHS + PENITENTS and adds().size() == adds0 + WRAITHS + PENITENTS and adds("wraith").size() == WRAITHS and adds("penitent").size() == PENITENTS, "%d climb out: %d Choir Wraiths + %d Bellbound Penitents (core bodies)" % [WRAITHS + PENITENTS, WRAITHS, PENITENTS])
	var rim_r := float(def()["arena"]["r"]) * RIM
	var on_rim := adds().all(func(id: int) -> bool: return absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - rim_r) < 0.01 and core.enemy_info(id)["area"] == "nave")
	check(on_rim, "on the arena rim, counted as Nave enemies")
	put(arena() + Vector3(dais + 4.8, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, float(C["water"]["slowP2"])), "the water slows wading outside the dais in phase 2 (x%.2f)" % hb.wade_mult)
	put(arena() + Vector3(dais * 0.6, 0.0, 0.0))
	await ticks(15)
	check(hb.wade_mult == 1.0, "on the dais the hero is not slowed")
	var h_n := telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() >= h_n + 2, 3.0 * float(C["hymn"]["cd"]))
	var p2h := telegraphs("hymn").slice(h_n)
	check(p2h.size() == 2 and absf(float(p2h[1]["t"]) - due_after("hymn", float(p2h[0]["t"]), float(C["hymn"]["cd"]) * float(FAST[1]))) < 0.1, "P2 cooldowns x%.1f (Hymn every %.1f s)" % [float(FAST[1]), float(p2h[1]["t"]) - float(p2h[0]["t"])])
	# ---- Phase 3: climbers again; wading slower; the Hymn is more on whoever stands in the water, plain on the dais
	for id in adds():
		host.remove_enemy(id)
	await ticks(2)
	wound_into(3)
	check(boss.phase == 3 and events("summon").size() == 2 and adds("wraith").size() == WRAITHS and adds("penitent").size() == PENITENTS, "phase 3: the climbers come out again")
	put(arena() + Vector3(dais + 4.8, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, float(C["water"]["slowP3"])), "wading x%.2f in phase 3 (x%.2f)" % [float(C["water"]["slowP3"]), hb.wade_mult])
	h_n = telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() > h_n, float(C["hymn"]["cd"]) + 3.0)
	hurts.clear()
	step(hymn_s + 0.1)
	check(hurts_of(hymn_dmg * float(C["hymn"]["soakedMult"])).size() == 1, "standing in the water in phase 3 the Hymn is x%.1f (soaked)" % float(C["hymn"]["soakedMult"]))
	put(arena() + Vector3(dais * 0.6, 0.0, 0.0))
	h_n = telegraphs("hymn").size()
	step_until(func() -> bool: return telegraphs("hymn").size() > h_n, float(C["hymn"]["cd"]) + 3.0)
	hurts.clear()
	step(hymn_s + 0.1)
	check(hurts_of(hymn_dmg).size() == 1 and hurts_of(hymn_dmg * float(C["hymn"]["soakedMult"])).is_empty(), "on the dais it is the plain Hymn")
	var p3h := telegraphs("hymn").slice(telegraphs("hymn").size() - 2)
	check(absf(float(p3h[1]["t"]) - due_after("hymn", float(p3h[0]["t"]), float(C["hymn"]["cd"]) * float(FAST[2]))) < 0.15, "P3 cooldowns x%.2f (Hymn every %.2f s)" % [float(FAST[2]), float(p3h[1]["t"]) - float(p3h[0]["t"])])
	# ---- the water drains when she is gone (the party left: she goes back to sleep; the defeat comes in the generic part)
	put(arena() + Vector3(dais + 4.8, 0.0, 0.0))
	await ticks(15)
	check(is_equal_approx(hb.wade_mult, float(C["water"]["slowP3"])), "(still wading)")
	hb.teleport(Vector3(0.0, 0.0, 20.0))
	boss.world.refresh()
	step(0.1)
	await ticks(15)
	check(hb.wade_mult == 1.0 and adds().is_empty(), "gone: the water drains (no slow) and the climbers are back under")
	await dismiss()
