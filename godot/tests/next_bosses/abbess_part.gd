extends "res://tests/next_bosses/harness.gd"
## The Bone Abbess in the slice: part of the boss suite (run.gd drives it)
## The boss is stepped by hand (set_physics_process(false) + _physics_process(1/60)) so timing is exact; engine frames are awaited where nodes
## (niche rise, corpses, thralls) need them. The Ossuary is not opened by the slice yet: the hero is teleported into the arena, which is
## area-agnostic (the brain reads the area from the player dict: `assume_area` / the world's own rects).
## A: summon rules, niches (4 director enemies, 7 % hp), Grasp / Lance / Chorus numbers + telegraph timing, niche breaks (4 % hp + Fracture), regen,
##    phases (double chorus, rebuild 2 niches once), Bone Communion over REAL corpses (devoured, healed), thralls hurt / engage, rites hit it and a niche,
##    defeat -> reward + report (niches leave without a kill), a repeat kill, a wipe reset.   B: two ENet peers.   C: perf.

const SPOTS := [[53.30330085889911, -18.696699141100893], [53.30330085889911, -29.303300858899107], [42.69669914110089, -29.303300858899107], [42.69669914110089, -18.696699141100893]]


func _init() -> void:
	boss_id = "abbess"


func _niches() -> Array:
	return g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "niche" and is_instance_valid(e) and e.sm.id() != DmEnemyState.Id.DEAD)


func _kill_niche(i: int) -> void:
	var e: DmEnemy = g.director.enemy_by_id(int(boss.brain.niches[i]))
	e.take_damage(1e9, hb)


func solo() -> void:
	await new_solo()
	g.corpses.visuals = false   # records only: the headless dummy renderer logs an error when a faded corpse body is freed (the field's own view is its suite's)
	await check_prompt_and_key()
	await check_summon_rules(3, "nobody")
	# ---- awaken: hp, niches
	var s: Dictionary = boss.brain.state
	check(awaken_hp_ok(17000.0), "A: awaken hp = baseHp 17000 x level x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "A: awake at the arena centre (48, -24), phase 1")
	check(boss.view != null and boss.view.slug == "boss_bone_abbess", "A: the current client's DmBossView with the Abbess's model")
	check(events("awaken").size() == 1 and "bossAwaken" in astub.sfx, "A: awaken event + bossAwaken sound")
	var ns := _niches()
	check(ns.size() == 4 and boss.brain.niches.size() == 4 and ns.all(func(e: DmEnemy) -> bool: return e is DmEnemyNiche), "A: four Skull Niches stand (director enemies of the new niche kind)")
	var at_spots := true
	for i in 4:
		var e: DmEnemy = g.director.enemy_by_id(int(boss.brain.niches[i]))
		at_spots = at_spots and Vector2(e.position.x - SPOTS[i][0], e.position.z - SPOTS[i][1]).length() < 0.01 and absf(e.max_hp - boss.max_hp * 0.07) < 0.01 and e.hp == e.max_hp
	check(at_spots, "A: niches at the four ABBESS_NICHE_SPOTS, each %.0f hp = 7 %% of hers" % (boss.max_hp * 0.07))
	check(String((ns[0] as DmEnemy).get_meta(&"dm_area")) == "ossuary", "A: niches count as Ossuary enemies (director.spawn area)")
	await ticks(75)   # the niches rise (1.1 s) before they can be hit
	check(ns.all(func(e: DmEnemy) -> bool: return e.sm.id() == DmEnemyState.Id.IDLE), "A: niches finished rising")
	# ---- Bone Grasp: first at 2.0 s, a cone on the nearest within reach
	put(arena() + Vector3(3.0, 0.0, 0.0))
	step(1.9)
	check(events("grasp", 0.0).is_empty(), "A: no attack before the opening cooldown")
	step(0.2)
	var gr := telegraphs("grasp")
	check(gr.size() == 1 and is_equal_approx(float(gr[0]["ev"]["ms"]), 700.0) and is_equal_approx(float(gr[0]["ev"]["r"]), 3.5), "A: Grasp telegraph 700 ms, r 3.5")
	check(absf(float(gr[0]["t"]) - 2.0) < 0.05, "A: Grasp at t = 2.0 s (%.3f)" % float(gr[0]["t"]))
	step(0.8)
	check(impacts("grasp").size() == 1 and absf(float(impacts("grasp")[0]["t"]) - float(gr[0]["t"]) - 0.7) < 0.03, "A: the blow lands 0.7 s later")
	check(hurts_of(18.0).size() == 1, "A: Grasp hurts the hero for 18 x level x difficulty")
	# ---- Bone Lance: a niche fires at the hero every 8 s (first at 4 s), 1200 ms, a 1.6 m line 11 m long
	hurts.clear()
	step_until(func() -> bool: return telegraphs("lance").size() >= 1, 3.0)
	var ln := telegraphs("lance")
	check(ln.size() == 1 and absf(float(ln[0]["t"]) - 4.0) < 0.05, "A: first Lance at t = 4.0 s (%.3f)" % (float(ln[0]["t"]) if ln.size() > 0 else -1.0))
	var le: Dictionary = ln[0]["ev"]
	var from_niche := false
	for sp in SPOTS:
		from_niche = from_niche or (absf(float(le["x"]) - sp[0]) < 1e-6 and absf(float(le["z"]) - sp[1]) < 1e-6)
	check(from_niche and is_equal_approx(float(le["ms"]), 1200.0) and is_equal_approx(float(le["r"]), 11.0), "A: Lance flies from a standing niche, 1200 ms, length 11")
	check(absf(float(le["dir"]) - atan2(hb.position.x - float(le["x"]), hb.position.z - float(le["z"]))) < 1e-6, "A: aimed at the hero")
	check(boss.brain.pending.any(func(p) -> bool: return p.kind == "lance" and p.side), "A: a niche's lance is a side attack (it does not make the Abbess busy)")
	step(1.3)
	check(impacts("lance").size() == 1 and hurts_of(20.0).size() == 1, "A: standing on the line, the Lance hurts for 20 x scale")
	# ---- Ossuary Chorus: 8 spokes, 9 m, 1200 ms, first at 5.0 s; the hero on a spoke is hit, between two spokes is not
	step_until(func() -> bool: return telegraphs("chorus").size() >= 1, 2.0)
	var ch := telegraphs("chorus")
	check(ch.size() == 1 and absf(float(ch[0]["t"]) - 5.0) < 0.05 and is_equal_approx(float(ch[0]["ev"]["ms"]), 1200.0) and is_equal_approx(float(ch[0]["ev"]["r"]), 9.0), "A: Chorus at t = 5.0 s, 1200 ms, spokes 9 m long")
	var ce: Dictionary = ch[0]["ev"]
	var cdir := float(ce["dir"])
	hurts.clear()
	put(Vector3(float(ce["x"]) + sin(cdir) * 5.0, 0.0, float(ce["z"]) + cos(cdir) * 5.0))
	step(1.3)
	check(impacts("chorus").size() == 1 and hurts_of(22.0).size() == 1, "A: standing on a spoke, the Chorus hurts for 22 x scale")
	# ---- a thrall on a spoke is hurt too (20 x scale); the second Chorus: hero between two spokes (22.5 deg off) is spared
	var th: DmThrallHost = hb.get_node("Thralls")
	th.clear()
	var rr: Dictionary = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 5.0, "attackSpeedMult": 1.0})
	var t1: DmThrall = rr["thralls"][0]
	step_until(func() -> bool: return telegraphs("chorus").size() >= 2, 12.0)
	ch = telegraphs("chorus")
	check(ch.size() == 2 and absf(float(ch[1]["t"]) - float(ch[0]["t"]) - 9.0) < 0.1, "A: Chorus repeats on its 9 s cooldown (%d)" % ch.size())
	ce = ch[1]["ev"]
	cdir = float(ce["dir"])
	hurts.clear()
	put(Vector3(float(ce["x"]) + sin(cdir + PI / 8.0) * 5.0, 0.0, float(ce["z"]) + cos(cdir + PI / 8.0) * 5.0))
	t1.global_position = Vector3(float(ce["x"]) + sin(cdir + PI / 2.0) * 6.0, 0.0, float(ce["z"]) + cos(cdir + PI / 2.0) * 6.0)   # a spoke too
	var th_hp := t1.hp
	step(1.3)
	check(impacts("chorus").size() == 2 and hurts_of(22.0).is_empty(), "A: between two spokes (22.5 deg off) the hero is spared")
	check(absf(th_hp - t1.hp - 20.0 * dmg_scale()) < 1e-3, "A: a thrall on a spoke is hurt for 20 x scale (%.2f)" % (th_hp - t1.hp))
	th.clear()
	# ---- niche breaks: 4 % of her hp + a Fracture stack, a nicheBreak event; no kill credit for the niche; regen only while one stands
	var kills0 := int(member().stats["kills_earned"])
	step(0.3)
	var hp0 := boss.hp
	_kill_niche(0)
	step(DT)
	var nb := events("nicheBreak")
	check(nb.size() == 1 and absf(float(nb[0]["ev"]["x"]) - SPOTS[0][0]) < 1e-6 and absf(float(nb[0]["ev"]["z"]) - SPOTS[0][1]) < 1e-6, "A: nicheBreak at the niche's spot")
	check(absf((hp0 - boss.hp) - boss.max_hp * (0.04 - 0.0025 * DT)) < boss.max_hp * 1e-4, "A: a broken niche tears 4 %% of her max hp (%.0f)" % (hp0 - boss.hp))
	check(int(boss.brain.state["fracture"]) == 1 and boss.brain.standing_niches() == 3, "A: ...and Fractures her (1 stack), 3 niches stand")
	check(int(member().stats["kills_earned"]) == kills0, "A: a niche is part of the fight, not a kill (no kill reward)")
	step(0.2)
	check(events("nicheBreak").size() == 1, "A: each niche breaks once")
	var hp1 := boss.hp
	step(4.0)
	check(absf((boss.hp - hp1) - boss.max_hp * 0.0025 * 4.0) < boss.max_hp * 2e-4, "A: with niches standing she regenerates 0.25 %% of max hp per second (%.0f in 4 s)" % (boss.hp - hp1))
	# ---- a rite hits a niche (they are ordinary enemies to the rite world)
	var caster: DmRiteCaster = hb.get_node("Rites")
	var ne: DmEnemy = g.director.enemy_by_id(int(boss.brain.niches[1]))
	put(arena() + Vector3(3.0, 0.0, -2.0))
	var nhp := ne.hp
	caster.request_cast("bone_needle", ne.global_position, g.enemy_id(ne))
	await until(func() -> bool: return ne.hp < nhp, 3.0)
	check(ne.hp < nhp and boss.brain.standing_niches() == 3, "A: Bone Needle hits a niche (%.1f)" % (nhp - ne.hp))
	# ---- all niches gone: no regen, no more lances
	_kill_niche(1)
	_kill_niche(2)
	_kill_niche(3)
	step(DT)
	check(events("nicheBreak").size() == 4 and boss.brain.standing_niches() == 0 and int(boss.brain.state["fracture"]) == mini(4, int(DmContent.get_export("abilities", "FRACTURE")["maxStacks"])), "A: all four break (a Fracture stack each, capped)")
	var n_lance := telegraphs("lance").size()
	var hp2 := boss.hp
	step(10.0)
	check(telegraphs("lance").size() == n_lance and boss.hp <= hp2, "A: with no niche standing: no Lances, no regeneration")
	# ---- Phase 2 (60 %): the Chorus doubles; cooldowns x0.9
	set_hp(0.7)
	wound(0.59)
	check(boss.phase == 2 and events("phase").size() == 1, "A: phase 2 at 60 %")
	var c0 := telegraphs("chorus").size()
	step_until(func() -> bool: return telegraphs("chorus").size() >= c0 + 2, 12.0)
	var pair := telegraphs("chorus").slice(c0)
	check(pair.size() == 2 and absf(float(pair[1]["t"]) - float(pair[0]["t"])) < 1e-6 and is_equal_approx(float(pair[1]["ev"]["ms"]), 2100.0) and absf(float(pair[1]["ev"]["dir"]) - float(pair[0]["ev"]["dir"]) - PI / 8.0) < 1e-6, "A: P2 Chorus fires a second set 22.5 deg round, 900 ms later")
	# ---- Phase 3 (30 %): two niches rebuilt, once; Bone Communion (channel 4 s) eats the corpses of the arena
	var before := _niches().size()
	wound(0.29)
	check(boss.phase == 3 and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 4, "A: phase 3 (30 %) with a summon event over the four spots")
	check(boss.brain.standing_niches() == 2 and _niches().size() == before + 2, "A: two broken niches re-form (rebuilt once)")
	# real corpses: a robber killed in the Ossuary (director.spawn with the area) + laid ones
	var rid: int = DmWaveDirector.id_of(g.director.spawn("robber", arena() + Vector3(-6.0, 0.0, 4.0), [hb], false, {}, {"area": "ossuary"}))
	await ticks(75)
	var robber: DmEnemy = g.director.enemy_by_id(rid)
	check(robber != null and String(robber.get_meta(&"dm_area")) == "ossuary", "A: an add spawned for the Ossuary is tagged with that area")
	robber.take_damage(1e9, hb)
	await ticks(2)
	var made := g.corpses.corpses_in_radius(arena(), 12.0, Callable(), "ossuary")
	check(made.size() == 1 and made[0].area == "ossuary", "A: its corpse lies in the Ossuary (the field's area comes from the director)")
	g.corpses.add_corpse(arena().x + 4.0, arena().z - 3.0, "normal", "robber", false, 0.0, 1.0, "ossuary")
	g.corpses.add_corpse(arena().x - 2.0, arena().z + 5.0, "normal", "ghoul", false, 0.0, 1.0, "ossuary")
	g.corpses.add_corpse(arena().x + 14.0, arena().z, "normal", "robber", false, 0.0, 1.0, "ossuary")    # outside the arena (r 10)
	g.corpses.add_corpse(arena().x + 2.0, arena().z + 2.0, "normal", "robber", false, 0.0, 1.0, "graves")  # another area
	g.corpses.echo_enabled = true
	var echo := g.corpses.add_corpse(arena().x + 1.0, arena().z + 1.0, "normal", "robber", false, 0.0, 0.65, "ossuary")
	echo.echoOwner = "*"
	var gone: Array = []
	g.corpses.corpse_gone.connect(func(c: DmSimCorpse, why: String) -> void: gone.append([c.id, why]))
	var total := g.corpses.count()
	check(boss.world.corpses().size() == total - 1, "A: the corpses hook serves the field's real corpses (echoes are not corpses)")
	set_hp(0.2)
	put(arena() + Vector3(8.0, 0.0, 0.0))
	boss.brain.pending.clear()
	var comm0 := telegraphs("communion").size()
	step_until(func() -> bool: return telegraphs("communion").size() > comm0, 14.0)
	var cm := telegraphs("communion").slice(comm0)
	check(cm.size() == 1 and is_equal_approx(float(cm[0]["ev"]["ms"]), 4000.0) and is_equal_approx(float(cm[0]["ev"]["r"]), 10.0), "A: Bone Communion telegraph: a 4 s channel over the arena (r 10)")
	check(cm[0]["ev"]["targets"].size() == 3, "A: the telegraph marks the 3 corpses inside the arena (not the far, foreign-area or echo ones)")
	var hp3 := boss.hp
	step(4.1)
	var cim := impacts("communion")
	check(cim.size() == 1 and int(cim[0]["ev"]["r"]) == 3, "A: the channel ends: 3 corpses devoured")
	check(absf((boss.hp - hp3) - boss.max_hp * (0.01 * 3.0 + 0.0025 * 4.1)) < boss.max_hp * 1e-3, "A: she heals 1 %% of max hp per corpse (%.0f, plus the 2 niches' regeneration)" % (boss.hp - hp3))
	check(gone.filter(func(x: Array) -> bool: return x[1] == "devoured").size() == 3 and g.corpses.count() == total - 3, "A: the field consumed them as `devoured` (%d left)" % g.corpses.count())
	check(g.corpses.corpses_in_radius(arena(), 16.0, Callable(), "ossuary").size() == 1 and g.corpses.corpses_in_radius(arena(), 4.0, Callable(), "graves").size() == 1, "A: the far and the foreign-area corpse stay")
	g.corpses.echo_enabled = false
	# ---- the rest: rites + thralls (engine-driven), stun
	hb.heal(1e6)
	for e in _niches():   # (their regeneration would out-heal a thrall's blows)
		e.take_damage(1e9, hb)
	step(DT)
	await check_thralls()
	await check_rites_and_stun()
	# ---- defeat: reward + report; the niches leave without a death
	var kills1 := int(member().stats["kills_earned"])
	await check_defeat(true, 2)
	await ticks(3)
	check(_niches().is_empty() and int(member().stats["kills_earned"]) == kills1, "A: the niches crumble with her: removed, no kill credit")
	# ---- a repeat kill is not a first kill
	await end_fight()
	check(await _summon_again() == "", "A: it can be woken again after the kill")
	var drops: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _p: Vector3) -> void: drops.append(d))
	var earned: Array = []
	g.rewards.boss_earned.connect(func(_c: int, id: String, f: bool, _p: Vector3) -> void: earned.append([id, f]))
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp + 1.0, hb)
	check(earned == [["abbess", false]], "A: a repeat kill has no first-kill bonus")
	# ---- wipe
	await end_fight()
	check(await _summon_again() == "", "A: woken a third time")
	await ticks(75)
	var n_before := _niches().size()
	check_wipe()
	await ticks(3)
	check(n_before == 4 and _niches().is_empty(), "A: a reset removes the niches too")
	await end_fight()
	# ---- an engine-driven fight (the real clock)
	check(await _summon_again() == "", "A: woken a fourth time")
	boss.set_physics_process(true)
	put(arena() + Vector3(3.0, 0.0, 0.0))
	await until(func() -> bool: return telegraphs("grasp").size() >= 1 and telegraphs("lance").size() >= 1, 8.0)
	check(boss.bstate.active and not telegraphs("lance").is_empty(), "A: the engine-driven Abbess fights (grasp + lance on the real clock)")
	boss.set_physics_process(false)
	await end_fight()


func _summon_again() -> String:
	await ticks(2)
	var why := summon(5)
	await ticks(2)
	return why


# ---- B: two peers --------------------------------------------------------------------------------------------------------------------------

func net() -> void:
	await two_peers_summon()
	var hh := hg.local_body()
	check(await until(func() -> bool: return cg.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "niche").size() == 4, 6.0), "B: the four niches spawn on the client (director spawner)")
	for i in 250:   # 4.17 s: past the first Lance (4.0 s)
		hboss._physics_process(DT)
		hh.heal(1e6)
	check(await until(func() -> bool: return cboss.telegraphs.any(func(t: Array) -> bool: return String(t[0]) == "lance"), 3.0), "B: the client sees the Lance telegraph in the replicated state")
	var tl: Array = cboss.telegraphs.filter(func(t: Array) -> bool: return String(t[0]) == "lance")[0]
	check(float(tl[1]) <= 1.2 and is_equal_approx(float(tl[2]), 11.0), "B: telegraph kind / time left (%.2f s) / length replicate" % float(tl[1]))
	await until(func() -> bool: return cg.director.enemies.values().all(func(e: DmEnemy) -> bool: return e.sm.id() == DmEnemyState.Id.IDLE), 3.0)
	var ev0: int = cg.bosses.fx.events
	var host_niche: DmEnemy = hg.director.enemy_by_id(int(hboss.brain.niches[0]))
	host_niche.take_damage(1e9, hh)
	hboss._physics_process(DT)
	check(await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events and cg.bosses.fx.events > ev0, 3.0), "B: the nicheBreak event reaches the client once")
	check(await until(func() -> bool: return cg.director.enemy_by_id(int(host_niche.get_meta(&"dm_id"))) != null and cg.director.enemy_by_id(int(host_niche.get_meta(&"dm_id"))).sm.id() == DmEnemyState.Id.DEAD, 3.0), "B: the broken niche is dead on the client too")
	await two_peers_replication()
	await two_peers_defeat()
	await two_peers_end()
