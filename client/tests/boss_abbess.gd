extends "res://tests/boss_base.gd"
## The Bone Abbess on the combat core (the Marrow Ossuary's boss; archive/old-game:godot/tests/next_bosses/abbess_part.gd on today's game, the same numbers and timing). Her four Skull Niches are core bodies of
## the new `niche` kind (native/src/core/niche.cpp) whose health she sets (`DmCore.set_enemy_hp`), her Bone Communion eats the core's corpses (`devoured`).
##   - her recorded scenarios are replayed by tests/bosses (not here); the generic parts (boss_base.gd): the summon at the Reliquary (3 soul shards), thralls, rites, wipe, defeat, rewards;
##   - the awaken: four niches at the four ABBESS_NICHE_SPOTS, each 7 % of her health, Ossuary enemies, standing after the rise; Grasp, Lance (from a standing niche, a side attack) and
##     Ossuary Chorus (spokes; the hero between two spokes is spared, a thrall on one is hurt) at today's ticks and numbers;
##   - a niche breaking: 4 % of her health, a Fracture stack, the nicheBreak event, no kill credit; her regeneration while one stands; a rite hits a niche; with none standing no Lance and no regen;
##   - phase 2 (the second Chorus set), phase 3 (two niches re-form, once) and Bone Communion over real corpses (the arena's, of her area only; devoured, healed);
##   - the niches leave with her (defeat or wipe) without a death, a corpse or a kill; a fight on the real clock; the net state.
## Run: godot --headless --path client --script res://tests/boss_abbess.gd [--fixed-fps 60 before --path runs it faster than real time]

var spots: Array = []


func _config() -> void:
	boss_id = "abbess"
	load_areas = ["ossuary"]
	bakes = ["thrall_legionnaire", "skull_niche", "grave_robber"]


## Her niches are enemies the thralls attack and hit instead of her: they break first (each one tearing at her, as always).
func before_thralls() -> void:
	for i in 4:
		kill_niche(i)
	step(DT)


func live_niches() -> Array:
	return bodies("niche").filter(func(id: int) -> bool: return int(core.enemy_info(id)["state"]) != DmCoreEvents.State.DEAD)


func kill_niche(i: int) -> void:
	host.damage(int(boss.brain.niches[i]), 1.0e9, hb.core_id)


func run_suite() -> void:
	for p in DmContent.get_export("bosses", "ABBESS_NICHE_SPOTS"):
		spots.append([float(p[0]), float(p[1])])
	await t_summon(3, 17000.0)
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(4)
	await t_defeat(true)
	await t_real_clock(["grasp", "lance"], 9.0)
	await t_net_state()


func t_fight() -> void:
	clear_logs()
	var kills0 := int(member().stats["kills_earned"])
	check(wake(10) == "", "woken for the fight")
	var s: Dictionary = boss.brain.state
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre (48, -24), phase 1")
	# ---- the niches: four core bodies of the niche kind at the four spots, 7 % of her health each, Ossuary enemies
	var ns := live_niches()
	check(ns.size() == 4 and boss.brain.niches.size() == 4, "four Skull Niches stand (core bodies of the niche kind)")
	var at_spots := true
	var area_ok := true
	for i in 4:
		var info: Dictionary = core.enemy_info(int(boss.brain.niches[i]))
		var p: Vector2 = info["pos"]
		at_spots = at_spots and Vector2(p.x - spots[i][0], p.y - spots[i][1]).length() < 0.01 and absf(float(info["max_hp"]) - boss.max_hp * 0.07) < 0.01 and float(info["hp"]) == float(info["max_hp"])
		area_ok = area_ok and info["area"] == "ossuary" and info["def"] == "niche" and int(info["level"]) == int(s["level"])
	check(at_spots, "niches at the four ABBESS_NICHE_SPOTS, each %.0f hp = 7 %% of hers" % (boss.max_hp * 0.07))
	check(area_ok, "niches count as Ossuary enemies at her level (the director's spawn with her area)")
	step(1.3)   # the niches rise (1.1 s) before they can be hit
	check(live_niches().all(func(id: int) -> bool: return int(core.enemy_info(id)["state"]) == DmCoreEvents.State.IDLE), "the niches finished rising")
	var wg := boss.world.enemy_get(int(boss.brain.niches[0]))
	check(wg["def"] == "niche" and wg["area"] == "ossuary" and wg["state"] == "idle" and near(float(wg["hp"]), boss.max_hp * 0.07), "world.enemy_get reads a niche of the core (%s)" % str(wg))
	# ---- Bone Grasp: first at 2.0 s, a cone on the nearest within reach
	clear_logs()
	put(arena() + Vector3(3.0, 0.0, 0.0))
	step(0.8)   # the brain's clock is at 2.1 s: the opening cooldown (2.0 s) is over
	var gr := telegraphs("grasp")
	check(gr.size() == 1 and near(float(gr[0]["ev"]["ms"]), 700.0) and near(float(gr[0]["ev"]["r"]), 3.5), "Grasp telegraph 700 ms, r 3.5")
	check(gr.size() == 1 and absf(float(gr[0]["t"]) - 2.0) < 0.05, "Grasp at t = 2.0 s (%.3f)" % (float(gr[0]["t"]) if gr.size() == 1 else -1.0))
	if gr.is_empty():
		return
	step(0.8)
	check(impacts("grasp").size() == 1 and absf(float(impacts("grasp")[0]["t"]) - float(gr[0]["t"]) - 0.7) < 0.03, "the blow lands 0.7 s later")
	check(hurts_of(18.0).size() == 1, "Grasp hurts the hero for 18 x level x difficulty")
	check(hero_hurt.any(func(x: Array) -> bool: return x[1] is int and int(x[1]) == boss.core_id and near(float(x[0]), scaled(18.0), 1e-3)), "the blow reached the hero's body with her core id as the source")
	# ---- Bone Lance: a niche fires at the hero (first at 4 s), 1200 ms, a 1.6 m line 11 m long; it is a side attack
	hurts.clear()
	step_until(func() -> bool: return telegraphs("lance").size() >= 1, 3.0)
	var ln := telegraphs("lance")
	check(ln.size() == 1 and absf(float(ln[0]["t"]) - 4.0) < 0.05, "first Lance at t = 4.0 s (%.3f)" % (float(ln[0]["t"]) if ln.size() > 0 else -1.0))
	var le: Dictionary = ln[0]["ev"]
	var from_niche := false
	for sp in spots:
		from_niche = from_niche or (absf(float(le["x"]) - sp[0]) < 1e-6 and absf(float(le["z"]) - sp[1]) < 1e-6)
	check(from_niche and near(float(le["ms"]), 1200.0) and near(float(le["r"]), 11.0), "the Lance flies from a standing niche, 1200 ms, length 11")
	check(absf(float(le["dir"]) - atan2(hb.position.x - float(le["x"]), hb.position.z - float(le["z"]))) < 1e-6, "aimed at the hero")
	check(boss.brain.pending.any(func(p) -> bool: return p.kind == "lance" and p.side), "a niche's lance is a side attack (it does not make the Abbess busy)")
	step(1.3)
	check(impacts("lance").size() == 1 and hurts_of(20.0).size() == 1, "standing on the line, the Lance hurts for 20 x scale")
	# ---- Ossuary Chorus: 8 spokes, 9 m, 1200 ms, first at 5.0 s; the hero on a spoke is hit
	step_until(func() -> bool: return telegraphs("chorus").size() >= 1, 2.0)
	var ch := telegraphs("chorus")
	check(ch.size() == 1 and absf(float(ch[0]["t"]) - 5.0) < 0.05 and near(float(ch[0]["ev"]["ms"]), 1200.0) and near(float(ch[0]["ev"]["r"]), 9.0), "Chorus at t = 5.0 s, 1200 ms, spokes 9 m long")
	var ce: Dictionary = ch[0]["ev"]
	var cdir := float(ce["dir"])
	hurts.clear()
	put(Vector3(float(ce["x"]) + sin(cdir) * 5.0, 0.0, float(ce["z"]) + cos(cdir) * 5.0))
	# a thrall of the hero's: it rises, then it is held on a spoke (the core's thrall, hurt through core.damage on its id)
	var t1 := thrall(arena() + Vector3(-4.0, 0.0, 0.0), 4000.0, 0.0)
	step(1.3)
	check(impacts("chorus").size() == 1 and hurts_of(22.0).size() == 1, "standing on a spoke, the Chorus hurts for 22 x scale")
	core.stun(t1, 1.0e6)
	# the second Chorus (9 s later): the hero between two spokes (22.5 deg off) is spared, a thrall on a spoke is hurt for 20 x scale
	step_until(func() -> bool: return telegraphs("chorus").size() >= 2, 12.0)
	ch = telegraphs("chorus")
	# Due 9 s after the first; a Grasp she started just before it holds her (busy) until its wind-up ends, and the Chorus comes then (today's rule;
	# whether her chase brings her into Grasp range in time varies with the navigation server's timing).
	var due := float(ch[0]["t"]) + 9.0
	var held := due
	for e: Dictionary in telegraphs("grasp"):
		var gt := float(e["t"])
		if gt < due and gt + float(e["ev"]["ms"]) / 1000.0 > due:
			held = maxf(held, gt + float(e["ev"]["ms"]) / 1000.0)
	check(ch.size() == 2 and absf(float(ch[1]["t"]) - held) < 0.1, "Chorus repeats on its 9 s cooldown, or as soon as a Grasp that holds her ends (%d; at %s, due %.2f, held to %.2f)" % [ch.size(), str(ch.map(func(x) -> float: return snappedf(float(x["t"]), 0.01))), due, held])
	ce = ch[1]["ev"]
	cdir = float(ce["dir"])
	hurts.clear()
	put(Vector3(float(ce["x"]) + sin(cdir + PI / 8.0) * 5.0, 0.0, float(ce["z"]) + cos(cdir + PI / 8.0) * 5.0))
	core.set_thrall_pos(t1, Vector2(float(ce["x"]) + sin(cdir + PI / 2.0) * 6.0, float(ce["z"]) + cos(cdir + PI / 2.0) * 6.0))   # a spoke too
	var th_hp := float(core.thrall_info(t1)["hp"])
	step(1.3)
	check(impacts("chorus").size() == 2 and hurts_of(22.0).is_empty(), "between two spokes (22.5 deg off) the hero is spared")
	check(near(th_hp - float(core.thrall_info(t1)["hp"]), scaled(20.0), 1e-4), "a thrall on a spoke is hurt for 20 x scale (%.2f) through the core" % (th_hp - float(core.thrall_info(t1)["hp"])))
	core.kill_thrall(t1, "crumbled")
	# ---- a niche breaks: 4 % of her hp + a Fracture stack, a nicheBreak event, no kill credit; regen only while one stands
	step(0.3)
	var hp0 := boss.hp
	kill_niche(0)
	step(DT)
	var nb := events("nicheBreak")
	check(nb.size() == 1 and absf(float(nb[0]["ev"]["x"]) - spots[0][0]) < 1e-6 and absf(float(nb[0]["ev"]["z"]) - spots[0][1]) < 1e-6, "nicheBreak at the niche's spot")
	check(absf((hp0 - boss.hp) - boss.max_hp * (0.04 - 0.0025 * DT)) < boss.max_hp * 1e-4, "a broken niche tears 4 %% of her max hp (%.0f)" % (hp0 - boss.hp))
	check(int(boss.brain.state["fracture"]) == 1 and boss.brain.standing_niches() == 3, "...and Fractures her (1 stack), 3 niches stand")
	check(int(member().stats["kills_earned"]) == kills0, "a niche is part of the fight, not a kill (no kill reward)")
	step(0.2)
	check(events("nicheBreak").size() == 1, "each niche breaks once")
	var hp1 := boss.hp
	step(4.0)
	check(absf((boss.hp - hp1) - boss.max_hp * 0.0025 * 4.0) < boss.max_hp * 2e-4, "with niches standing she regenerates 0.25 %% of max hp per second (%.0f in 4 s)" % (boss.hp - hp1))
	# ---- a rite hits a niche (they are ordinary enemies to the rite world)
	var nid := int(boss.brain.niches[1])
	put(arena() + Vector3(3.0, 0.0, -2.0))
	c.p["resource"]["value"] = 50.0
	var nhp := hp_of(nid)
	var r := cast("bone_needle", Vector3(spots[1][0], 0.0, spots[1][1]), nid)
	await secs(0.8)
	check(bool(r["ok"]) and hp_of(nid) < nhp and boss.brain.standing_niches() == 3, "Bone Needle hits a niche (%.1f)" % (nhp - hp_of(nid)))
	# ---- all niches gone: no regen, no more lances
	kill_niche(1)
	kill_niche(2)
	kill_niche(3)
	step(DT)
	var maxf_ := int(DmContent.get_export("abilities", "FRACTURE")["maxStacks"])
	check(events("nicheBreak").size() == 4 and boss.brain.standing_niches() == 0 and int(boss.brain.state["fracture"]) == mini(4, maxf_), "all four break (a Fracture stack each, capped)")
	var n_lance := telegraphs("lance").size()
	var hp2 := boss.hp
	step(10.0)
	check(telegraphs("lance").size() == n_lance and boss.hp <= hp2, "with no niche standing: no Lances, no regeneration")
	# ---- phase 2 (60 %): the Chorus doubles; cooldowns x0.9
	set_hp(0.7)
	wound(0.59)
	check(boss.phase == 2 and events("phase").size() == 1, "phase 2 at 60 %")
	var c0 := telegraphs("chorus").size()
	step_until(func() -> bool: return telegraphs("chorus").size() >= c0 + 2, 12.0)
	var pair := telegraphs("chorus").slice(c0)
	check(pair.size() == 2 and absf(float(pair[1]["t"]) - float(pair[0]["t"])) < 1e-6 and near(float(pair[1]["ev"]["ms"]), 2100.0) and absf(float(pair[1]["ev"]["dir"]) - float(pair[0]["ev"]["dir"]) - PI / 8.0) < 1e-6,
		"the second Chorus set fires 22.5 deg round, 900 ms later")
	# ---- phase 3 (30 %): two niches rebuilt, once; Bone Communion (channel 4 s) eats the arena's corpses
	var before := live_niches().size()
	wound(0.29)
	check(boss.phase == 3 and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 4, "phase 3 (30 %) with a summon event over the four spots")
	check(boss.brain.standing_niches() == 2 and live_niches().size() == before + 2, "two broken niches re-form (rebuilt once)")
	step(0.1)
	check(live_niches().size() == 2 and bodies("niche").size() == 2, "(as new core bodies: two standing, the four broken ones were removed 4 s after they fell)")
	# a real corpse: a robber of the Ossuary killed there, then laid ones
	var rid: int = g.director.spawn("robber", arena() + Vector3(-6.0, 0.0, 4.0), [hb], false, {}, {"area": "ossuary"})
	step(1.3)
	check(rid > 0 and host.enemy_info(rid)["area"] == "ossuary", "an add spawned for the Ossuary is tagged with that area")
	host.damage(rid, 1.0e9, hb.core_id)
	step(DT)
	var made := host.corpses.corpses_in_radius(arena(), 12.0, Callable(), "ossuary")
	check(made.size() == 1, "its corpse lies in the Ossuary (the field's area comes from the director) (%d)" % made.size())
	host.corpses.add_corpse(arena().x + 4.0, arena().z - 3.0, "normal", "robber", false, 0.0, 1.0, "ossuary")
	host.corpses.add_corpse(arena().x - 2.0, arena().z + 5.0, "normal", "ghoul", false, 0.0, 1.0, "ossuary")
	host.corpses.add_corpse(arena().x + 14.0, arena().z, "normal", "robber", false, 0.0, 1.0, "ossuary")    # outside the arena (r 10)
	host.corpses.add_corpse(arena().x + 2.0, arena().z + 2.0, "normal", "robber", false, 0.0, 1.0, "graves")  # another area
	var gone: Array = []
	host.corpse_gone.connect(func(id: int, why: String) -> void: gone.append([id, why]))
	var total := int(core.corpse_count())
	check(boss.world.corpses().size() == total, "the corpses hook serves the core's field (%d)" % total)
	set_hp(0.2)
	put(arena() + Vector3(8.0, 0.0, 0.0))
	boss.brain.pending.clear()
	var comm0 := telegraphs("communion").size()
	step_until(func() -> bool: return telegraphs("communion").size() > comm0, 14.0)
	var cm := telegraphs("communion").slice(comm0)
	check(cm.size() == 1 and near(float(cm[0]["ev"]["ms"]), 4000.0) and near(float(cm[0]["ev"]["r"]), 10.0), "Bone Communion telegraph: a 4 s channel over the arena (r 10)")
	check(cm[0]["ev"]["targets"].size() == 3, "the telegraph marks the 3 corpses inside the arena (not the far and foreign-area ones)")
	var hp3 := boss.hp
	step(4.1)
	var cim := impacts("communion")
	check(cim.size() == 1 and int(cim[0]["ev"]["r"]) == 3, "the channel ends: 3 corpses devoured")
	check(absf((boss.hp - hp3) - boss.max_hp * (0.01 * 3.0 + 0.0025 * 4.1)) < boss.max_hp * 1e-3, "she heals 1 %% of max hp per corpse (%.0f, plus the 2 niches' regeneration)" % (boss.hp - hp3))
	step(DT)
	check(gone.filter(func(x: Array) -> bool: return x[1] == "devoured").size() == 3 and int(core.corpse_count()) == total - 3, "the field consumed them as `devoured` (%d left)" % int(core.corpse_count()))
	check(host.corpses.corpses_in_radius(arena(), 16.0, Callable(), "ossuary").size() == 1 and host.corpses.corpses_in_radius(arena(), 4.0, Callable(), "graves").size() == 1, "the far and the foreign-area corpse stay")
	# the niches' health and place are the core's after the rebuild too
	var fresh := live_niches()
	check(fresh.all(func(id: int) -> bool: return absf(float(core.enemy_info(id)["max_hp"]) - boss.max_hp * 0.07) < 0.01), "the rebuilt niches are given 7 %% of her health too")
	await dismiss()
