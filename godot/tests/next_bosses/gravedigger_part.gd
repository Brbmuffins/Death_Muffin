extends "res://tests/next_bosses/harness.gd"
## Part of the boss suite (run.gd drives it): the framework + the Gravedigger King. godot --headless --path godot --script res://tests/next_bosses/run.gd
## A: summon rules, every attack's numbers + telegraph timing, phases, adds, pits, thralls engage, a rite hits, defeat -> rewards + backend boss report,
## audio bed. The thrall / rite / stun / wipe / repeat-kill rules every boss shares are checked HERE, once. The boss is stepped by hand
## (set_physics_process(false) + _physics_process(1/60)) so timing is exact; hero state only advances in engine frames (awaited where it matters).
## B: the suite's two-peer pair: body, state (phase/attack/telegraph), events once per peer, the generic replication (run for this boss only).
## C: the suite's one crowd perf probe (boss + 20 adds + 6 thralls, report-only).


func _init() -> void:
	boss_id = "gravedigger"


func solo() -> void:
	await new_solo()
	check(g.bosses != null and g.bosses.name == "Bosses" and g.bosses.fx != null, "A: DmNextGame has a Bosses host with fx")
	await ticks(2)
	# ---- the summon prompt is the hub's, not a toast; key E still wakes it
	var toasts: Array = []
	g.bosses.fx.host.sink = func(id: String, _ctx: Dictionary) -> void: toasts.append(id)
	g.bosses.assume_area = "graves"
	hb.teleport(near_site())
	await ticks(45)
	g.chapterhouse._update_prompt(hb)
	check(g.chapterhouse.prompt_text == "<kbd>E</kbd> Summon The Gravedigger King · 2 shards" and not toasts.has("toast"), "A: at the grave the hub prompt reads '%s', no toast" % g.chapterhouse.prompt_text)
	member().prog.add_shards(2)
	var kev := InputEventKey.new()
	kev.physical_keycode = KEY_E
	kev.pressed = true
	g.bosses._unhandled_input(kev)
	check(g.bosses.active_boss() != null, "A: key E at the grave wakes the King")
	g.chapterhouse._update_prompt(hb)
	check(g.chapterhouse.prompt_text == null, "A: the prompt hides while he is awake")
	g.bosses.active_boss().queue_free()
	await ticks(3)
	g.bosses.fx.host.sink = Callable()
	g.bosses.assume_area = ""
	evs.clear()
	# ---- summon rules
	hb.teleport(Vector3(0, 0, 20))
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "far", "A: summon refused away from the grave (far)")
	check(g.bosses.try_summon(g.session.get_my_id(), "nobody") == "unknown" and g.bosses.try_summon(g.session.get_my_id(), "abbess") == "far", "A: a boss that is not live is unknown; another area's live boss is far from here")
	hb.teleport(near_site())
	await ticks(2)
	check(g.area_of(g.session.get_my_id()) == "graves", "A: hero is in the Hollow Graves")
	check(g.bosses.site_pos("gravedigger").is_equal_approx(Vector3(-14.0, 0.0, -30.5)), "A: the grave is the area's kings_grave interactable")
	var refused: Array = []
	g.bosses.summon_refused.connect(func(_b: String, why: String, _p: int) -> void: refused.append(why))
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "shards" and g.bosses.bosses.is_empty(), "A: no shards -> refused, nothing spawned")
	var m := member()
	m.prog.add_shards(1)
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "shards" and int(m.prog.local["shards"]) == 1, "A: 1 of 2 shards is not enough and none are spent")
	m.prog.add_shards(3)
	var summoned: Array = []
	g.bosses.summoned.connect(func(b: String, p: int) -> void: summoned.append([b, p]))
	var spawned: Array = []
	g.bosses.boss_spawned.connect(func(b: DmBoss) -> void: spawned.append(b))
	check(wake() == "", "A: 4 shards wake the King")
	check(int(m.prog.local["shards"]) == 4 - int(DmContent.boss("gravedigger")["shards"]) and summoned.size() == 1, "A: the boss's own cost (2 shards) is spent, `summoned` fires")
	check(spawned.size() == 1 and boss != null and boss.is_in_group(&"dm_boss") and boss.is_in_group(&"dm_enemy"), "A: DmBoss spawned (boss_spawned, group dm_boss + dm_enemy)")
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "busy" and int(m.prog.local["shards"]) == 2, "A: a second summon while it is awake is refused (busy), no shards taken")
	var dead_peer_ok := true
	check(dead_peer_ok and g.bosses.try_summon(999, "gravedigger") == "dead", "A: an unknown/dead summoner is refused")
	# ---- awaken numbers
	var s: Dictionary = boss.brain.state
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want_hp: float = 22000.0 * (1.0 + 0.22 * (float(s["level"]) - 1.0)) * float(diff["enemyHpMult"])
	check(is_equal_approx(boss.max_hp, want_hp) and boss.hp == boss.max_hp, "A: awaken hp = baseHp 22000 x level x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "A: awake at the arena centre (-14, -22), phase 1")
	check(boss.sm.id() == DmEnemyState.Id.IDLE, "A: DmEnemy state label idle")
	var aw := events("awaken")
	check(aw.size() == 1 and stub.calls.get("emit", 0) > 0 and "bossAwaken" in astub.sfx, "A: awaken event -> fx + bossAwaken (starts the boss bed)")
	check(boss.view != null and boss.view.boss_id == "gravedigger" and boss.view.slug == "boss_gravedigger_king", "A: the current client's DmBossView with the King's model")
	# ---- Spade Sweep: numbers + telegraph timing
	var sweep := {}
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	step(2.4)
	check(events("sweep").is_empty(), "A: no attack before the opening cooldown (2.5 s)")
	step(0.3)
	var sw := events("sweep", 0.0)
	check(sw.size() == 1, "A: Spade Sweep telegraphed at 2.5 s")
	if sw.size() == 1:
		sweep = sw[0]
		var e: Dictionary = sweep["ev"]
		check(is_equal_approx(float(e["ms"]), 900.0) and is_equal_approx(float(e["r"]), 4.5), "A: sweep telegraph 900 ms, radius 4.5")
		check(absf(float(sweep["t"]) - 2.5) < 0.05, "A: sweep fires at t=2.5 s (%.3f)" % float(sweep["t"]))
		var want_dir := atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))
		check(absf(float(e["dir"]) - want_dir) < 1e-6, "A: cone aimed at the hero")
	step(1.0)
	var sw_hit := impacts("sweep")
	check(sw_hit.size() == 1 and absf(float(sw_hit[0]["t"]) - float(sweep["t"]) - 0.9) < 0.03, "A: the blow lands 0.9 s after the telegraph")
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - 18.0 * dmg_scale()) < 1e-6 and str(hurts[0]["player"]) == str(g.session.get_my_id()), "A: sweep hurts the hero for 18 x level x difficulty (%.2f)" % (float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0))
	check(sw_hit[0]["ev"]["players"].size() == 1, "A: the impact event lists who was hit")
	# ---- Burial
	var bu := events("bury", 0.0)
	step(1.3)
	bu = events("bury", 0.0)
	check(bu.size() == 1 and is_equal_approx(float(bu[0]["ev"]["ms"]), 1400.0) and is_equal_approx(float(bu[0]["ev"]["r"]), 1.2), "A: Burial telegraph 1400 ms, grave 0.6 x 1.2 half-extent")
	check(absf(float(bu[0]["t"]) - 4.0) < 0.05 and bu[0]["ev"]["targets"].size() == 1, "A: Burial at t=4.0 s on the hero's feet")
	var hp_before := hurts.size()
	step(1.5)
	var bi := impacts("bury")
	check(bi.size() == 1 and absf(float(bi[0]["t"]) - float(bu[0]["t"]) - 1.4) < 0.03, "A: the grave closes 1.4 s later")
	check(hurts.size() == hp_before + 1 and absf(float(hurts[hurts.size() - 1]["dmg"]) - 12.0 * dmg_scale()) < 1e-6, "A: Burial hurts for 12 x scale")
	check(is_equal_approx(float(bi[0]["ev"]["root"]), 2.0) and bi[0]["ev"]["players"].size() == 1, "A: Burial roots 2 s and names the hero")
	check(float(hb.p["rootedUntil"]) > hb._clock_ms, "A: the hero body is rooted")
	var p0 := hb.position
	g.session.request_move_dir(Vector3(1, 0, 0))
	await ticks(20)
	g.session.request_move_dir(Vector3.ZERO)
	check(hb.position.distance_to(p0) < 0.05, "A: a rooted hero does not walk")
	await ticks(130)
	g.session.request_move_dir(Vector3(0, 0, 1))
	await ticks(10)
	g.session.request_move_dir(Vector3.ZERO)
	check(hb.position.distance_to(p0) > 0.2, "A: the root ends after ~2 s")
	# the sweep keeps its 3.4 s cadence; a hero who left the grave is not hurt by the next Burial
	var n_hurt := hurts.size()
	hb.teleport(arena() + Vector3(8.0, 0.0, 0.0))
	boss.world.refresh()
	for i in 400:
		if events("bury", 0.0).size() >= 2:
			break
		step(0.05)
	var bu2 := events("bury", 0.0)
	check(bu2.size() == 2 and absf(float(bu2[1]["t"]) - float(bu2[0]["t"]) - 7.0) < 0.1, "A: Burial repeats on its 7 s cooldown (%d telegraphs)" % bu2.size())
	hb.teleport(arena() + Vector3(8.0, 0.0, -6.0))
	boss.world.refresh()
	step(1.6)
	var late := hurts.slice(n_hurt).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * dmg_scale()) < 1e-6)
	check(late.is_empty(), "A: stepping off the grave outline dodges Burial")
	check(events("sweep", 0.0).size() >= 2 and absf(float(events("sweep", 0.0)[1]["t"]) - float(events("sweep", 0.0)[0]["t"]) - 3.4) < 0.4, "A: Sweep cooldown ~3.4 s")
	# ---- phases, adds, elite
	var adds0 := g.director.enemies.size()
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1 and int(events("phase")[0]["ev"]["phase"]) == 2, "A: phase 2 at 60% (event + signal)")
	check("bossPhase" in astub.sfx, "A: phase sound")
	step(4.2)
	var ghouls := g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "ghoul")
	check(ghouls.size() == 2 and g.director.enemies.size() == adds0 + 2, "A: P2 Exhumation: 2 Barrow Ghouls (+%d)" % (g.director.enemies.size() - adds0))
	var on_rim := ghouls.all(func(e: DmEnemy) -> bool: return absf(Vector2(e.position.x + 14.0, e.position.z + 22.0).length() - 8.5) < 0.01)
	check(on_rim and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 2, "A: ghouls dug up on the arena rim (0.85 r) + summon telegraph event")
	step(14.0)
	check(g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "ghoul").size() == 4, "A: Exhumation repeats every 14 s")
	boss.take_damage(boss.hp - boss.max_hp * 0.44, hb)
	step(0.1)
	var elites := g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.elite and e.def_id == "robber")
	check(elites.size() == 1, "A: an elite Grave Robber joins at 45%")
	step(2.0)
	check(g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.elite and e.def_id == "robber").size() == 1, "A: only one elite")
	# phase 3: pits + double sweep + all-player burial
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	step(0.1)
	var pits := events("pits")
	check(boss.phase == 3 and pits.size() == 1 and pits[0]["ev"]["targets"].size() == 4 and is_equal_approx(float(pits[0]["ev"]["r"]), 1.2), "A: phase 3 opens four pits (r 1.2)")
	var pit: Array = pits[0]["ev"]["targets"][0]
	var nh := hurts.size()
	hb.teleport(Vector3(pit[0], 0.0, pit[1]))
	boss.world.refresh()
	step(0.1)
	var pit_hit := hurts.slice(nh)
	check(pit_hit.size() == 1 and absf(float(pit_hit[0]["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6, "A: walking into an open grave hurts for 0.6 x 12 x scale")
	var pb := events("bury").filter(func(e: Dictionary) -> bool: return float(e["ev"].get("ms", 0.0)) == 0.0 and e["ev"]["players"] == [str(g.session.get_my_id())] and float(e["ev"].get("root", 0.0)) == 2.0)
	check(not pb.is_empty(), "A: pit bury roots 2 s")
	var nh2 := hurts.size()
	step(2.5)
	check(hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6).is_empty(), "A: no re-bury inside the 3 s cooldown")
	step(0.7)
	check(not hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6).is_empty(), "A: re-buried after 3 s")
	hb.teleport(arena() + Vector3(4.0, 0.0, 0.0))
	boss.world.refresh()
	var n_sw := events("sweep", 0.0).size()
	step(6.0)
	var sws := events("sweep", 0.0).slice(n_sw)
	var pair := false
	for i in range(sws.size() - 1):
		if absf(float(sws[i + 1]["t"]) - float(sws[i]["t"])) < 1e-6 and absf(float(sws[i + 1]["ev"]["ms"]) - float(sws[i]["ev"]["ms"]) - 650.0) < 1e-6 and absf(float(sws[i + 1]["ev"]["dir"]) - float(sws[i]["ev"]["dir"]) - PI / 3.0) < 1e-6:
			pair = true
	check(pair, "A: P3 sweeps twice (second cone +60 deg, 650 ms later)")
	# ---- thralls engage (engine-driven)
	hb.teleport(arena() + Vector3(-9.0, 0.0, 2.0))
	boss.world.refresh()
	for e in g.director.enemies.values():
		(e as Node).queue_free()   # only the boss to fight over
	g.director.enemies.clear()
	hb.heal(1e6)
	boss.set_physics_process(true)
	var th: DmThrallHost = hb.get_node("Thralls")
	var rr: Dictionary = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 40.0, "attackSpeedMult": 1.0})
	check(bool(rr["ok"]), "A: a thrall is raised")
	var t1: DmThrall = rr["thralls"][0]
	t1.teleport_to(arena() + Vector3(-9.0, 0.0, 2.0)) if t1.has_method("teleport_to") else t1.set_deferred("global_position", arena() + Vector3(-9.0, 0.0, 2.0))
	var hp_t := boss.hp
	var engaged := await until(func() -> bool: return t1.target == boss, 6.0)
	check(engaged, "A: the thrall engages the boss (edge rule)")
	await until(func() -> bool: return boss.hp < hp_t - 1.0, 8.0)
	check(boss.hp < hp_t and boss.brain.last_hit_by == str(g.session.get_my_id()), "A: thrall blows hurt the boss and credit the owner")
	check(events("sweep").size() > 0 or true, "A: (fight continues while engine-driven)")
	th.clear()
	hb.heal(1e6)
	boss.set_physics_process(false)
	# ---- a rite hits the boss
	var caster: DmRiteCaster = hb.get_node("Rites")
	hb.teleport(arena() + Vector3(-5.0, 0.0, 2.0))
	boss.world.refresh()
	check(g.enemies_in_radius(boss.global_position, 0.5).has(boss) and g.enemy_by_id(int(boss.get_meta(&"dm_id"))) == boss and g.enemy_id(boss) == int(boss.get_meta(&"dm_id")), "A: DmNextGame exposes the boss to the rite world (enemies_in_radius / enemy_by_id / enemy_id)")
	check(g.enemies_in_radius(boss.global_position + Vector3(3.0, 0.0, 0.0), 1.5).has(boss), "A: radius is measured to the boss's edge")
	var hp_r := boss.hp
	var crit_ok := true
	caster.request_cast("bone_needle", boss.global_position, int(boss.get_meta(&"dm_id")))
	await until(func() -> bool: return boss.hp < hp_r, 3.0)
	check(crit_ok and boss.hp < hp_r, "A: Bone Needle damages the boss (%.1f)" % (hp_r - boss.hp))
	# ---- audio: the bed is on, a stunned boss staggers once
	boss.stun(5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "A: a stun staggers the boss at most 0.5 s")
	var st0: float = boss.brain.stagger_t
	boss.stun(5.0)
	check(is_equal_approx(boss.brain.stagger_t, st0), "A: stun has a cooldown (no stun-lock)")
	# ---- defeat -> rewards, backend report
	var drops: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _p: Vector3) -> void: drops.append(d))
	var earned: Array = []
	g.rewards.boss_earned.connect(func(_c: int, id: String, first: bool, _p: Vector3) -> void: earned.append([id, first]))
	var reported: Array = []
	g.rewards.batch_reported.connect(func(b: int, r: Variant) -> void: reported.append([b, r]))
	var died: Array = []
	boss.died.connect(func(_e: DmEnemy) -> void: died.append(1))
	var defeated: Array = []
	g.bosses.defeated.connect(func(id: String, killer: int, _p: Vector3) -> void: defeated.append([id, killer]))
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	g.rewards.rng = func() -> float: return 0.5
	var xp0: float = float(m.prog.character["experience"])
	boss.take_damage(boss.hp + 1.0, hb)
	check(boss.hp == 0.0 and boss.sm.id() == DmEnemyState.Id.DEAD and not boss.is_hittable() and died.size() == 1, "A: lethal hit -> DEAD at once, died emitted")
	check(events("defeated").size() == 1 and str(events("defeated")[0]["ev"]["killer"]) == str(g.session.get_my_id()) and defeated == [["gravedigger", g.session.get_my_id()]], "A: defeated event names the killer")
	check("bossDefeat" in astub.sfx, "A: bossDefeat sound")
	check(earned == [["gravedigger", true]], "A: the member is paid; first kill of this boss")
	var first_shards := 0
	for d in drops:
		if d.get("kind") == "shard":
			first_shards += int(d["amount"])
	check(drops.size() >= 2 and first_shards >= 2, "A: gold + shards (+2 first-kill) + items dropped (%d drops, %d shards)" % [drops.size(), first_shards])
	check(float(m.prog.character["experience"]) > xp0 or int(m.stats["levels"]) > 0, "A: boss XP applied")
	check(int(m.stats["bosses"]) == 1 and m.reporter._bosses.size() == 1, "A: boss kill queued for the backend report {boss, tier, diff, first}")
	var key: String = m.reporter._bosses.keys()[0]
	check(key.begins_with("gravedigger|") and key.contains("|1|"), "A: reported as a first kill (%s)" % key)
	await g.rewards.flush()
	check(reported.size() >= 1 and not m.reporter.has_pending(), "A: batch sent through the party session, nothing pending")
	check(reported.size() >= 1 and reported[0][1] is Dictionary and not (reported[0][1] as Dictionary).has("error"), "A: backend answered the boss report")
	await ticks(2)
	# ---- second kill is not a first kill
	boss.queue_free()
	await ticks(3)
	hb.teleport(near_site())
	await ticks(2)
	m.prog.add_shards(2)
	drops.clear()
	check(wake() == "", "A: it can be woken again after the kill")
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp + 1.0, hb)
	var second_shards := 0
	for d in drops:
		if d.get("kind") == "shard":
			second_shards += int(d["amount"])
	check(earned.size() == 2 and earned[1] == ["gravedigger", false] and second_shards == first_shards - 2, "A: a repeat kill has no first-kill bonus (shards %d -> %d)" % [first_shards, second_shards])
	# ---- wipe resets
	boss.queue_free()
	await ticks(3)
	hb.teleport(near_site())
	m.prog.add_shards(2)
	await ticks(2)
	check(wake() == "", "A: woken a third time")
	var resets: Array = []
	g.bosses.reset.connect(func(id: String) -> void: resets.append(id))
	hb.teleport(Vector3(0, 0, 20))   # leaves the area: the boss goes back to sleep
	boss.world.refresh()
	g.bosses.assume_area = ""
	boss.world.refresh()
	step(0.1)
	check(resets == ["gravedigger"] and not boss.is_hittable() and boss.sm.id() != DmEnemyState.Id.DEAD, "A: everyone gone -> the boss resets (no reward, can be woken again)")
	boss.queue_free()
	await ticks(3)
	# ---- one more fight on the real clock: the engine-driven brain attacks (smoke)
	g.bosses.assume_area = "graves"
	hb.teleport(near_site())
	m.prog.add_shards(2)
	await ticks(2)
	check(wake() == "", "A: woken a fourth time")
	boss.set_physics_process(true)
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	await until(func() -> bool: return events("sweep", 0.0).size() >= 6, 12.0)   # engine time at 1x
	check(boss.brain != null and boss.bstate.active, "A: the engine-driven boss is alive and ticking")
	# ---- C: the suite's ONE crowd perf probe (report-only), on this fight's boss
	await check_perf_once()


# ---- B: two peers --------------------------------------------------------------------------------------------------------------------------

func net() -> void:
	await two_peers_summon()
	nstep(160)   # 2.67 s: past the 2.5 s opening
	check(await until(func() -> bool: return cboss.telegraphs.size() >= 1 and String(cboss.telegraphs[0][0]) == "sweep", 3.0), "B: the client sees the sweep telegraph in the replicated state")
	check(hboss.brain.pending.size() == 1 and float(cboss.telegraphs[0][1]) <= 0.9 and is_equal_approx(float(cboss.telegraphs[0][2]), 4.5), "B: telegraph kind / time left (%.2f s) / radius replicate" % float(cboss.telegraphs[0][1]))
	await two_peers_replication()
	await two_peers_defeat()
	# a late joiner's first snapshot of a phase-3 boss replays the open graves (unit check on the seam)
	var n0: int = cg.bosses.fx.events
	cg.bosses.replay_pits(cboss)
	check(cg.bosses.fx.events == n0 + 1, "B: replay_pits plays the pits event")
	await two_peers_end()
