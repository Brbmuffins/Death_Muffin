extends "res://tests/boss_base.gd"
## The Bone Abbess on the combat core (the Marrow Ossuary's boss; archive/old-game:godot/tests/next_bosses/abbess_part.gd on today's game, the same numbers and timing). Her four Skull Niches are core bodies of
## the new `niche` kind (native/src/core/niche.cpp) whose health she sets (`DmCore.set_enemy_hp`), her Bone Communion eats the core's corpses (`devoured`).
##   - her recorded scenarios are replayed by tests/bosses (not here); the generic parts (boss_base.gd): the summon at the Reliquary (its soul shards), thralls, rites, wipe, defeat, rewards;
##   - the awaken: her niches at the ABBESS_NICHE_SPOTS, each a share of her health (nicheHpFrac), Ossuary enemies, standing after the rise; Grasp, Lance (from a standing niche, a side attack) and
##     Ossuary Chorus (spokes; the hero between two spokes is spared, a thrall on one is hurt) at the ticks of her brain's opening cooldowns and the numbers of the boss data (`ABBESS` in bosses.json);
##   - a niche breaking: a share of her health (nicheBreakFrac), a Fracture stack, the nicheBreak event, no kill credit; her regeneration while one stands; a rite hits a niche; with none standing no Lance and no regen;
##   - phase 2 (the second Chorus set), phase 3 (two niches re-form, once) and Bone Communion over real corpses (the arena's, of her area only; devoured, healed);
##   - the niches leave with her (defeat or wipe) without a death, a corpse or a kill; a fight on the real clock; the net state.
## Run: godot --headless --path client --script res://tests/boss_abbess.gd [--fixed-fps 60 before --path runs it faster than real time]

## What her brain does that is in its code and not in the boss data (sim/bosses/abbess_brain.gd): from phase 2 the Chorus is answered by a second set 900 ms behind, and phase 3 re-forms two niches.
const SECOND_SET_MS := 900.0
const REBUILT := 2

var spots: Array = []
var A: Dictionary                       ## the boss data's ABBESS


func _config() -> void:
	boss_id = "abbess"
	load_areas = ["ossuary"]
	bakes = ["thrall_legionnaire", "skull_niche", "grave_robber"]


## Her niches are enemies the thralls attack and hit instead of her: they break first (each one tearing at her, as always).
func before_thralls() -> void:
	for i in int(A["niches"]):
		kill_niche(i)
	step(DT)


func live_niches() -> Array:
	return bodies("niche").filter(func(id: int) -> bool: return int(core.enemy_info(id)["state"]) != DmCoreEvents.State.DEAD)


func kill_niche(i: int) -> void:
	host.damage(int(boss.brain.niches[i]), 1.0e9, hb.core_id)


func run_suite() -> void:
	A = DmContent.get_export("bosses", "ABBESS")
	for p in DmContent.get_export("bosses", "ABBESS_NICHE_SPOTS"):
		spots.append([float(p[0]), float(p[1])])
	await t_summon()
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(int(A["niches"]))
	await t_defeat(true)
	await t_real_clock(["grasp", "lance"], 9.0)
	await t_net_state()


func t_fight() -> void:
	clear_logs()
	var kills0 := int(member().stats["kills_earned"])
	check(wake() == "", "woken for the fight")
	var s: Dictionary = boss.brain.state
	var n_niche := int(A["niches"])
	var open_grasp: float = boss.brain._grasp_cd   # her opening cooldowns, as her brain sets them on waking
	var open_lance: float = boss.brain._lance_cd
	var open_chorus: float = boss.brain._chorus_cd
	var open_comm: float = boss.brain._communion_cd
	var chorus_s := float(A["chorus"]["windupMs"]) / 1000.0
	var spokes := int(A["chorus"]["spokes"])
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "awake at the arena centre, phase 1")
	# ---- the niches: core bodies of the niche kind at the spots, a share of her health each, Ossuary enemies
	var ns := live_niches()
	check(ns.size() == n_niche and boss.brain.niches.size() == n_niche, "her %d Skull Niches stand (core bodies of the niche kind)" % n_niche)
	var at_spots := true
	var area_ok := true
	var niche_hp := boss.max_hp * float(A["nicheHpFrac"])
	for i in n_niche:
		var info: Dictionary = core.enemy_info(int(boss.brain.niches[i]))
		var p: Vector2 = info["pos"]
		at_spots = at_spots and Vector2(p.x - spots[i][0], p.y - spots[i][1]).length() < 0.01 and absf(float(info["max_hp"]) - niche_hp) < 0.01 and float(info["hp"]) == float(info["max_hp"])
		area_ok = area_ok and info["area"] == "ossuary" and info["def"] == "niche" and int(info["level"]) == int(s["level"])
	check(at_spots, "niches at the ABBESS_NICHE_SPOTS, each %.0f hp = %.0f %% of hers" % [niche_hp, float(A["nicheHpFrac"]) * 100.0])
	check(area_ok, "niches count as Ossuary enemies at her level (the director's spawn with her area)")
	step(DmSimConsts.RISE_TIME + 0.2)   # the niches rise before they can be hit
	check(live_niches().all(func(id: int) -> bool: return int(core.enemy_info(id)["state"]) == DmCoreEvents.State.IDLE), "the niches finished rising")
	var wg := boss.world.enemy_get(int(boss.brain.niches[0]))
	check(wg["def"] == "niche" and wg["area"] == "ossuary" and wg["state"] == "idle" and near(float(wg["hp"]), niche_hp), "world.enemy_get reads a niche of the core (%s)" % str(wg))
	# ---- Bone Grasp: first at her opening cooldown, a cone on the nearest within reach
	clear_logs()
	put(arena() + Vector3(minf(3.0, float(A["grasp"]["r"]) * 0.8), 0.0, 0.0))
	step_until(func() -> bool: return not telegraphs("grasp").is_empty(), open_grasp + 1.0)
	var gr := telegraphs("grasp")
	check(gr.size() == 1 and near(float(gr[0]["ev"]["ms"]), float(A["grasp"]["windupMs"])) and near(float(gr[0]["ev"]["r"]), float(A["grasp"]["r"])), "Grasp telegraph %d ms, r %.1f" % [int(A["grasp"]["windupMs"]), float(A["grasp"]["r"])])
	check(gr.size() == 1 and absf(float(gr[0]["t"]) - open_grasp) < 0.05, "Grasp at t = %.1f s (%.3f)" % [open_grasp, float(gr[0]["t"]) if gr.size() == 1 else -1.0])
	if gr.is_empty():
		return
	var grasp_s := float(A["grasp"]["windupMs"]) / 1000.0
	step(grasp_s + 0.1)
	check(impacts("grasp").size() == 1 and absf(float(impacts("grasp")[0]["t"]) - float(gr[0]["t"]) - grasp_s) < 0.03, "the blow lands %.1f s later" % grasp_s)
	check(hurts_of(float(A["grasp"]["dmg"])).size() == 1, "Grasp hurts the hero for %d x level x difficulty" % int(A["grasp"]["dmg"]))
	check(hero_hurt.any(func(x: Array) -> bool: return x[1] is int and int(x[1]) == boss.core_id and near(float(x[0]), scaled(float(A["grasp"]["dmg"])), 1e-3)), "the blow reached the hero's body with her core id as the source")
	# ---- Bone Lance: a niche fires at the hero (first at her opening cooldown); it is a side attack
	hurts.clear()
	step_until(func() -> bool: return telegraphs("lance").size() >= 1, open_lance + 1.0)
	var ln := telegraphs("lance")
	check(ln.size() == 1 and absf(float(ln[0]["t"]) - open_lance) < 0.05, "first Lance at t = %.1f s (%.3f)" % [open_lance, float(ln[0]["t"]) if ln.size() > 0 else -1.0])
	var le: Dictionary = ln[0]["ev"]
	var from_niche := false
	for sp in spots:
		from_niche = from_niche or (absf(float(le["x"]) - sp[0]) < 1e-6 and absf(float(le["z"]) - sp[1]) < 1e-6)
	check(from_niche and near(float(le["ms"]), float(A["lance"]["windupMs"])) and near(float(le["r"]), float(A["lance"]["len"])), "the Lance flies from a standing niche, %d ms, length %d" % [int(A["lance"]["windupMs"]), int(A["lance"]["len"])])
	check(absf(float(le["dir"]) - atan2(hb.position.x - float(le["x"]), hb.position.z - float(le["z"]))) < 1e-6, "aimed at the hero")
	check(boss.brain.pending.any(func(p) -> bool: return p.kind == "lance" and p.side), "a niche's lance is a side attack (it does not make the Abbess busy)")
	step(float(A["lance"]["windupMs"]) / 1000.0 + 0.1)
	check(impacts("lance").size() == 1 and hurts_of(float(A["lance"]["dmg"])).size() == 1, "standing on the line, the Lance hurts for %d x scale" % int(A["lance"]["dmg"]))
	# ---- Ossuary Chorus: the spokes, first at her opening cooldown; the hero on a spoke is hit
	step_until(func() -> bool: return telegraphs("chorus").size() >= 1, open_chorus + 1.0)
	var ch := telegraphs("chorus")
	check(ch.size() == 1 and absf(float(ch[0]["t"]) - open_chorus) < 0.05 and near(float(ch[0]["ev"]["ms"]), float(A["chorus"]["windupMs"])) and near(float(ch[0]["ev"]["r"]), float(A["chorus"]["len"])), "Chorus at t = %.1f s, %d ms, spokes %d m long" % [open_chorus, int(A["chorus"]["windupMs"]), int(A["chorus"]["len"])])
	var ce: Dictionary = ch[0]["ev"]
	var cdir := float(ce["dir"])
	hurts.clear()
	put(Vector3(float(ce["x"]) + sin(cdir) * 5.0, 0.0, float(ce["z"]) + cos(cdir) * 5.0))
	# a thrall of the hero's: it rises, then it is held on a spoke (the core's thrall, hurt through core.damage on its id)
	var t1 := thrall(arena() + Vector3(-4.0, 0.0, 0.0), 4000.0, 0.0)
	step(chorus_s + 0.1)
	check(impacts("chorus").size() == 1 and hurts_of(float(A["chorus"]["dmg"])).size() == 1, "standing on a spoke, the Chorus hurts for %d x scale" % int(A["chorus"]["dmg"]))
	core.stun(t1, 1.0e6)
	# the second Chorus (its cooldown later): the hero between two spokes is spared, a thrall on a spoke is hurt for a thrall's blow
	step_until(func() -> bool: return telegraphs("chorus").size() >= 2, float(A["chorus"]["cd"]) + 3.0)
	ch = telegraphs("chorus")
	# Due a cooldown after the first; a Grasp she started just before it holds her (busy) until its wind-up ends, and the Chorus comes then (today's rule;
	# whether her chase brings her into Grasp range in time varies with the navigation server's timing).
	var due := float(ch[0]["t"]) + float(A["chorus"]["cd"])
	var held := due
	for e: Dictionary in telegraphs("grasp"):
		var gt := float(e["t"])
		if gt < due and gt + float(e["ev"]["ms"]) / 1000.0 > due:
			held = maxf(held, gt + float(e["ev"]["ms"]) / 1000.0)
	check(ch.size() == 2 and absf(float(ch[1]["t"]) - held) < 0.1, "Chorus repeats on its %d s cooldown, or as soon as a Grasp that holds her ends (%d; at %s, due %.2f, held to %.2f)" % [int(A["chorus"]["cd"]), ch.size(), str(ch.map(func(x) -> float: return snappedf(float(x["t"]), 0.01))), due, held])
	ce = ch[1]["ev"]
	cdir = float(ce["dir"])
	hurts.clear()
	var between := PI / float(spokes)   # half the angle from one spoke to the next
	put(Vector3(float(ce["x"]) + sin(cdir + between) * 5.0, 0.0, float(ce["z"]) + cos(cdir + between) * 5.0))
	core.set_thrall_pos(t1, Vector2(float(ce["x"]) + sin(cdir + 2.0 * between * 2.0) * 6.0, float(ce["z"]) + cos(cdir + 2.0 * between * 2.0) * 6.0))   # a spoke too: two along
	var th_hp := float(core.thrall_info(t1)["hp"])
	step(chorus_s + 0.1)
	check(impacts("chorus").size() == 2 and hurts_of(float(A["chorus"]["dmg"])).is_empty(), "between two spokes (%.1f deg off) the hero is spared" % rad_to_deg(between))
	check(near(th_hp - float(core.thrall_info(t1)["hp"]), scaled(THRALL_BLOW), 1e-4), "a thrall on a spoke is hurt for %d x scale (%.2f) through the core" % [int(THRALL_BLOW), th_hp - float(core.thrall_info(t1)["hp"])])
	core.kill_thrall(t1, "crumbled")
	# ---- a niche breaks: a share of her hp + a Fracture stack, a nicheBreak event, no kill credit; regen only while one stands
	step(0.3)
	var hp0 := boss.hp
	kill_niche(0)
	step(DT)
	var nb := events("nicheBreak")
	check(nb.size() == 1 and absf(float(nb[0]["ev"]["x"]) - spots[0][0]) < 1e-6 and absf(float(nb[0]["ev"]["z"]) - spots[0][1]) < 1e-6, "nicheBreak at the niche's spot")
	check(absf((hp0 - boss.hp) - boss.max_hp * (float(A["nicheBreakFrac"]) - float(A["regenPerS"]) * DT)) < boss.max_hp * 1e-4, "a broken niche tears %.0f %% of her max hp (%.0f)" % [float(A["nicheBreakFrac"]) * 100.0, hp0 - boss.hp])
	check(int(boss.brain.state["fracture"]) == 1 and boss.brain.standing_niches() == n_niche - 1, "...and Fractures her (1 stack), %d niches stand" % (n_niche - 1))
	check(int(member().stats["kills_earned"]) == kills0, "a niche is part of the fight, not a kill (no kill reward)")
	step(0.2)
	check(events("nicheBreak").size() == 1, "each niche breaks once")
	var hp1 := boss.hp
	step(4.0)
	check(absf((boss.hp - hp1) - boss.max_hp * float(A["regenPerS"]) * 4.0) < boss.max_hp * 2e-4, "with niches standing she regenerates %.2f %% of max hp per second (%.0f in 4 s)" % [float(A["regenPerS"]) * 100.0, boss.hp - hp1])
	# ---- a rite hits a niche (they are ordinary enemies to the rite world)
	var nid := int(boss.brain.niches[1])
	put(arena() + Vector3(3.0, 0.0, -2.0))
	c.p["resource"]["value"] = 50.0
	var nhp := hp_of(nid)
	var r := cast("bone_needle", Vector3(spots[1][0], 0.0, spots[1][1]), nid)
	await secs(0.8)
	check(bool(r["ok"]) and hp_of(nid) < nhp and boss.brain.standing_niches() == n_niche - 1, "Bone Needle hits a niche (%.1f)" % (nhp - hp_of(nid)))
	# ---- all niches gone: no regen, no more lances
	for i in range(1, n_niche):
		kill_niche(i)
	step(DT)
	var maxf_ := int(DmContent.get_export("abilities", "FRACTURE")["maxStacks"])
	check(events("nicheBreak").size() == n_niche and boss.brain.standing_niches() == 0 and int(boss.brain.state["fracture"]) == mini(n_niche, maxf_), "all %d break (a Fracture stack each, capped)" % n_niche)
	var n_lance := telegraphs("lance").size()
	var hp2 := boss.hp
	step(float(A["lance"]["everyS"]) + 2.0)
	check(telegraphs("lance").size() == n_lance and boss.hp <= hp2, "with no niche standing: no Lances, no regeneration")
	# ---- phase 2: the Chorus doubles
	set_hp(float(PHASE_AT[0]) + 0.1)
	wound_into(2)
	check(boss.phase == 2 and events("phase").size() == 1, "phase 2")
	var c0 := telegraphs("chorus").size()
	step_until(func() -> bool: return telegraphs("chorus").size() >= c0 + 2, float(A["chorus"]["cd"]) + 3.0)
	var pair := telegraphs("chorus").slice(c0)
	check(pair.size() == 2 and absf(float(pair[1]["t"]) - float(pair[0]["t"])) < 1e-6 and near(float(pair[1]["ev"]["ms"]), float(A["chorus"]["windupMs"]) + SECOND_SET_MS) and absf(float(pair[1]["ev"]["dir"]) - float(pair[0]["ev"]["dir"]) - deg_to_rad(float(A["chorus"]["rotateDeg"]))) < 1e-6,
		"the second Chorus set fires %.1f deg round, %.0f ms later" % [float(A["chorus"]["rotateDeg"]), SECOND_SET_MS])
	# ---- phase 3: two niches rebuilt, once; Bone Communion eats the arena's corpses
	var before := live_niches().size()
	wound_into(3)
	check(boss.phase == 3 and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == spots.size(), "phase 3 with a summon event over the %d spots" % spots.size())
	check(boss.brain.standing_niches() == REBUILT and live_niches().size() == before + REBUILT, "%d broken niches re-form (rebuilt once)" % REBUILT)
	step(0.1)
	check(live_niches().size() == REBUILT and bodies("niche").size() == REBUILT, "(as new core bodies: %d standing, the broken ones were removed after they fell)" % REBUILT)
	# a real corpse: a robber of the Ossuary killed there, then laid ones
	var rid: int = g.director.spawn("robber", arena() + Vector3(-6.0, 0.0, 4.0), [hb], false, {}, {"area": "ossuary"})
	step(DmSimConsts.RISE_TIME + 0.2)
	check(rid > 0 and host.enemy_info(rid)["area"] == "ossuary", "an add spawned for the Ossuary is tagged with that area")
	host.damage(rid, 1.0e9, hb.core_id)
	step(DT)
	var arena_r := float(def()["arena"]["r"])
	var made := host.corpses.corpses_in_radius(arena(), arena_r + 2.0, Callable(), "ossuary")
	check(made.size() == 1, "its corpse lies in the Ossuary (the field's area comes from the director) (%d)" % made.size())
	host.corpses.add_corpse(arena().x + 4.0, arena().z - 3.0, "normal", "robber", false, 0.0, 1.0, "ossuary")
	host.corpses.add_corpse(arena().x - 2.0, arena().z + 5.0, "normal", "ghoul", false, 0.0, 1.0, "ossuary")
	host.corpses.add_corpse(arena().x + arena_r + 4.0, arena().z, "normal", "robber", false, 0.0, 1.0, "ossuary")    # outside the arena
	host.corpses.add_corpse(arena().x + 2.0, arena().z + 2.0, "normal", "robber", false, 0.0, 1.0, "graves")  # another area
	var gone: Array = []
	host.corpse_gone.connect(func(id: int, why: String) -> void: gone.append([id, why]))
	var total := int(core.corpse_count())
	check(boss.world.corpses().size() == total, "the corpses hook serves the core's field (%d)" % total)
	set_hp(0.2)
	put(arena() + Vector3(arena_r * 0.8, 0.0, 0.0))
	boss.brain.pending.clear()
	var comm0 := telegraphs("communion").size()
	step_until(func() -> bool: return telegraphs("communion").size() > comm0, open_comm + float(A["communion"]["cd"]))
	var cm := telegraphs("communion").slice(comm0)
	var channel_s := float(A["communion"]["channelS"])
	check(cm.size() == 1 and near(float(cm[0]["ev"]["ms"]), channel_s * 1000.0) and near(float(cm[0]["ev"]["r"]), arena_r), "Bone Communion telegraph: a %d s channel over the arena (r %.0f)" % [int(channel_s), arena_r])
	check(cm[0]["ev"]["targets"].size() == 3, "the telegraph marks the 3 corpses inside the arena (not the far and foreign-area ones)")
	var hp3 := boss.hp
	step(channel_s + 0.1)
	var cim := impacts("communion")
	check(cim.size() == 1 and int(cim[0]["ev"]["r"]) == 3, "the channel ends: 3 corpses devoured")
	check(absf((boss.hp - hp3) - boss.max_hp * (float(A["communion"]["healPerCorpse"]) * 3.0 + float(A["regenPerS"]) * (channel_s + 0.1))) < boss.max_hp * 1e-3, "she heals %.0f %% of max hp per corpse (%.0f, plus the standing niches' regeneration)" % [float(A["communion"]["healPerCorpse"]) * 100.0, boss.hp - hp3])
	step(DT)
	check(gone.filter(func(x: Array) -> bool: return x[1] == "devoured").size() == 3 and int(core.corpse_count()) == total - 3, "the field consumed them as `devoured` (%d left)" % int(core.corpse_count()))
	check(host.corpses.corpses_in_radius(arena(), arena_r + 6.0, Callable(), "ossuary").size() == 1 and host.corpses.corpses_in_radius(arena(), 4.0, Callable(), "graves").size() == 1, "the far and the foreign-area corpse stay")
	# the niches' health and place are the core's after the rebuild too
	var fresh := live_niches()
	check(fresh.all(func(id: int) -> bool: return absf(float(core.enemy_info(id)["max_hp"]) - niche_hp) < 0.01), "the rebuilt niches are given %.0f %% of her health too" % (float(A["nicheHpFrac"]) * 100.0))
	await dismiss()
