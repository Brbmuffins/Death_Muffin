extends "res://tests/boss_base.gd"
## The Gravedigger King on the combat core (client/README.md "The bosses"): the real offline game scene (client/next/next_game.tscn) with a level-20 Gravecaller, no waves, headless, on boss_base.gd
## like the six other bosses' suites (boss_abbess.gd ... boss_mire.gd). The King is today's DmBossHost / DmBoss / DmBossBrain, ported: his body is an external of the core (kind 1), his brain stays GDScript.
## The generic parts every boss gets are boss_base.gd's (the summon and its refusals, thralls, rites, wipe, defeat and rewards, the real clock, the net state); his recorded scenarios are replayed by tests/bosses.
## What is the King's own is here:
##   - the host wakes the boss of every area the boss data names; another area's boss is far from his grave; he stands at the arena centre of the data, in the core's records;
##   - his fight stepped by hand (exact timing, as archive/old-game:godot/tests/next_bosses/gravedigger_part.gd does): Spade Sweep and Burial (numbers, telegraphs, the blows on the hero and on a thrall), the phases at
##     60 / 30 %, Barrow Ghouls on the arena rim and the elite robber (adds are core bodies of the Graves, the boss's area), the four pits, the double sweep;
##   - thralls: he is not a target while he cannot be hurt (the external's `alive`), and his sweep reaches the thrall that stands by him (`core.damage` on its id);
##   - the rites hit him: the host's queries append him after the enemies, the lane, the cone and the circle helpers, Bone Fan, Rot Lance, the Spear's rally, the Scythe's arc count him, a rite's damage goes to his
##     brain with the hero's credit, his statuses are his own DmStatusSet (the brain ignores slow, root and chill), a stun status staggers him, Colossus Mantle's reflect finds him by his core id;
##   - his wipe (the five adds he has called leave silently) and his defeat (the brain on the engine's ticks calls the ghouls; they leave with him) use the generic parts with his own provocations; on the real clock a thrall beside him hits him.
## ZERO script errors or engine errors in the log (an OS Logger counts them).
## Gets the robber, the hound and the Gravecaller's legionnaire into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --path client --script res://tests/boss.gd
## It plays about 60 s of game time: with the engine argument `--fixed-fps 60` before `--path` it runs faster than real time.


func _config() -> void:
	boss_id = "gravedigger"
	load_areas = ["graves"]
	bakes = ["grave_robber", "bone_hound", "thrall_legionnaire"]


func run_suite() -> void:
	king_wire()
	await t_summon(int(def()["shards"]), 22000.0)
	await t_king_summon()
	await t_hand_fight()
	await dismiss()
	await t_wipe(5, provoke_adds)
	await t_thralls()
	await t_king_thralls()
	await t_rites()
	await t_king_rites()
	await t_defeat(true, provoke_ghouls)
	await t_real_clock(["sweep", "bury"], 20.0)
	await t_king_real_clock()
	await t_net_state()


func king_wire() -> void:
	var boss_areas: Array = []
	for bid in DmContent.bosses():
		if not boss_areas.has(String(DmContent.boss(String(bid))["area"])):
			boss_areas.append(String(DmContent.boss(String(bid))["area"]))
	var served: Array = g.bosses.served_areas.duplicate()
	served.sort()
	boss_areas.sort()
	check(not boss_areas.is_empty() and served == boss_areas, "the host wakes the boss of every area the boss data names (the other bosses have their own suites: boss_*.gd)")


## What boss_base.t_summon does not check: another area's boss is far from his grave, and he stands at the arena centre of the data, in the core's records.
func t_king_summon() -> void:
	hb.teleport(near_site())
	await ticks(2)
	check(g.bosses.try_summon(me, "abbess") == "far", "another area's boss is far from here")
	check(wake() == "", "woken for the arena check")
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.is_hittable(), "awake at the arena centre of the data")
	await ticks(2)   # the host writes his place into the core: `step` has run with him registered
	check(host.enemy_alive(boss.core_id) and host.enemy_position(boss.core_id).distance_to(arena()) < 0.01, "he is alive for the queries, at the arena centre")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ the fight, by hand

## One brain tick at a time, by hand and without the core's tick: the exact timing of the brain's clock, the core's bodies stay where the brain put them.
func hand(seconds: float) -> void:
	step(seconds, false)


func t_hand_fight() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for the fight")
	var total0 := host.enemy_total()
	# Spade Sweep: numbers and telegraph timing
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	hand(2.4)
	check(events("sweep", 0.0).is_empty(), "no attack before the opening cooldown (2.5 s)")
	hand(0.3)
	var sw := events("sweep", 0.0)
	check(sw.size() == 1, "Spade Sweep telegraphed at 2.5 s")
	var sweep := {}
	if sw.size() == 1:
		sweep = sw[0]
		var e: Dictionary = sweep["ev"]
		check(near(float(e["ms"]), 900.0) and near(float(e["r"]), 4.5), "the sweep telegraph is 900 ms, radius 4.5")
		check(absf(float(sweep["t"]) - 2.5) < 0.05, "the sweep fires at t=2.5 s (%.3f)" % float(sweep["t"]))
		check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "the cone is aimed at the hero")
	# a thrall in the cone: raised by the core, hurt by the King through the core (his blows on thralls)
	var th := int(core.raise_thrall({"kind": "warrior", "hp": 500.0, "maxHp": 500.0, "damage": 10.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false}, hb.core_id,
		Vector2(boss.global_position.x + 2.0, boss.global_position.z), 0.0, 8.0))
	check(th > 0 and core.thrall_info(th)["hp"] == 500.0, "a thrall stands in the cone, 2 m from the King")
	hand(1.0)
	var sw_hit := impacts("sweep")
	check(sw_hit.size() == 1 and absf(float(sw_hit[0]["t"]) - float(sweep["t"]) - 0.9) < 0.03, "the blow lands 0.9 s after the telegraph")
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - 18.0 * dmg_scale()) < 1e-6 and str(hurts[0]["player"]) == str(me), "the sweep hurts the hero for 18 x level x difficulty (%.2f)" % (float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0))
	check(hero_hurt.size() == 1 and hero_hurt[0][1] is int and int(hero_hurt[0][1]) == boss.core_id and float(hero_hurt[0][0]) > 0.0, "the blow reached the hero's body with the King's core id as its source (%s)" % str(hero_hurt))
	check(sw_hit[0]["ev"]["players"].size() == 1, "the impact event lists who was hit")
	var ti: Dictionary = core.thrall_info(th)
	check(near(float(ti["hp"]), 500.0 - boss.brain._dmg(20.0)), "the thrall in the cone lost 20 x level x difficulty through core.damage on its id (%.2f of 500)" % (500.0 - float(ti["hp"])))
	await ticks(1)   # the core's event for it
	check(thrall_dmg.size() == 1 and thrall_dmg[0][0] == th and thrall_dmg[0][1] == boss.core_id and near(float(thrall_dmg[0][2]), boss.brain._dmg(20.0)), "the core reported it: the King's id as the source (%s)" % str(thrall_dmg))
	core.kill_thrall(th, "crumbled")
	# Burial
	hand(1.3)
	var bu := events("bury", 0.0)
	check(bu.size() == 1 and near(float(bu[0]["ev"]["ms"]), 1400.0) and near(float(bu[0]["ev"]["r"]), 1.2), "Burial telegraph 1400 ms, grave 0.6 x 1.2 half-extent")
	check(bu.size() == 1 and absf(float(bu[0]["t"]) - 4.0) < 0.05 and bu[0]["ev"]["targets"].size() == 1, "Burial at t=4.0 s on the hero's feet")
	var n_hurt := hurts.size()
	hand(1.5)
	var bi := impacts("bury")
	check(bi.size() == 1 and absf(float(bi[0]["t"]) - float(bu[0]["t"]) - 1.4) < 0.03, "the grave closes 1.4 s later")
	check(hurts.size() == n_hurt + 1 and absf(float(hurts[hurts.size() - 1]["dmg"]) - 12.0 * dmg_scale()) < 1e-6, "Burial hurts for 12 x scale")
	check(near(float(bi[0]["ev"]["root"]), 2.0) and bi[0]["ev"]["players"].size() == 1 and float(hb.p["rootedUntil"]) > hb._clock_ms, "Burial roots 2 s and the hero's body is rooted")
	# phases, adds, elite
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	check(boss.take_damage(boss.hp - boss.max_hp * 0.59, hb), "a blow of the hero's takes him to 59 %")
	hand(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1 and int(events("phase")[0]["ev"]["phase"]) == 2, "phase 2 at 60 % (event + signal)")
	check("bossPhase" in astub.sfx, "the phase sound")
	var ghouls0 := bodies("ghoul").size()
	hand(4.2)
	var ghouls := bodies("ghoul")
	check(ghouls.size() - ghouls0 == 2 and host.enemy_total() == total0 + 2, "Exhumation: two Barrow Ghouls are core bodies (%d in the table)" % ghouls.size())
	var on_rim := ghouls.all(func(id: int) -> bool: return absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - 8.5) < 0.01)
	check(on_rim and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 2, "dug up on the arena rim (0.85 r) with the summon telegraph event")
	var gi: Dictionary = core.enemy_info(ghouls[0])
	check(gi["area"] == "graves" and int(gi["level"]) == int(boss.brain.state["level"]) and not bool(gi["elite"]), "the adds belong to the King's area, at its level")
	# the brain's reads of the core's world (the later bosses use them): one body, all bodies, the corpses and their removal
	var wg := boss.world.enemy_get(ghouls[0])
	check(wg["id"] == ghouls[0] and wg["def"] == "ghoul" and wg["area"] == "graves" and wg["state"] == "burrow" and near(float(wg["hp"]), float(wg["max_hp"])) and boss.world.enemy_get(1 << 29).is_empty(),
		"world.enemy_get reads a body of the core (%s)" % str(wg))
	check(boss.world.enemies().size() == host.enemy_total(), "world.enemies lists the core's table (%d)" % host.enemy_total())
	var cid := host.corpses.add_corpse(arena().x + 1.0, arena().z, "normal", "robber", false, 0.0, 1.0, "graves")
	var wc: Array = boss.world.corpses()
	check(wc.size() == 1 and wc[0]["id"] == cid and wc[0]["area"] == "graves" and near(float(wc[0]["x"]), arena().x + 1.0), "world.corpses lists the core's field (%s)" % str(wc))
	boss.world.remove_corpse(cid, "devoured")
	check(boss.world.corpses().is_empty() and host.corpses.get_corpse(cid) == null, "world.remove_corpse consumes it")
	hand(14.0)
	check(bodies("ghoul").size() - ghouls0 == 4, "Exhumation repeats every 14 s")
	boss.take_damage(boss.hp - boss.max_hp * 0.44, hb)
	hand(0.1)
	var elites := bodies("robber").filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"]))
	check(elites.size() == 1, "an elite Grave Robber joins at 45 %")
	hand(2.0)
	check(bodies("robber").filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"])).size() == 1, "only one elite")
	# phase 3: pits, the double sweep
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	hand(0.1)
	var pits := events("pits")
	check(boss.phase == 3 and pits.size() == 1 and pits[0]["ev"]["targets"].size() == 4 and near(float(pits[0]["ev"]["r"]), 1.2), "phase 3 opens four pits (r 1.2)")
	var pit: Array = pits[0]["ev"]["targets"][0]
	var nh := hurts.size()
	hb.teleport(Vector3(pit[0], 0.0, pit[1]))
	boss.world.refresh()
	hand(0.1)
	var pit_hit := hurts.slice(nh)
	check(pit_hit.size() == 1 and absf(float(pit_hit[0]["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6, "walking into an open grave hurts for 0.6 x 12 x scale")
	var nh2 := hurts.size()
	hand(2.5)
	check(hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6).is_empty(), "no re-bury inside the 3 s cooldown")
	hand(0.7)
	check(not hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6).is_empty(), "re-buried after 3 s")
	hb.teleport(arena() + Vector3(4.0, 0.0, 0.0))
	boss.world.refresh()
	var n_sw := events("sweep", 0.0).size()
	hand(6.0)
	var sws := events("sweep", 0.0).slice(n_sw)
	var pair := false
	for i in range(sws.size() - 1):
		if absf(float(sws[i + 1]["t"]) - float(sws[i]["t"])) < 1e-6 and absf(float(sws[i + 1]["ev"]["ms"]) - float(sws[i]["ev"]["ms"]) - 650.0) < 1e-6 and absf(float(sws[i + 1]["ev"]["dir"]) - float(sws[i]["ev"]["dir"]) - PI / 3.0) < 1e-6:
			pair = true
	check(pair, "phase 3 sweeps twice (the second cone +60 degrees, 650 ms later)")


## The adds his phases call (the generic wipe's provocation): Exhumation twice (four ghouls) and the elite Grave Robber, stepped by hand; the core announces each of them.
func provoke_adds() -> void:
	var s0 := spawned_n
	wound(0.59)
	step(4.2)
	step(14.0)
	wound(0.44)
	step(2.0)
	await ticks(1)
	check(spawned_n - s0 == core.enemy_ids().size(), "the core announced each of his adds (%d spawn events)" % (spawned_n - s0))


## The engine-driven brain calls his ghouls into the core (the generic defeat's provocation).
func provoke_ghouls() -> void:
	boss.set_physics_process(true)
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	var got := await until(func() -> bool: return bodies("ghoul").size() >= 2, 8.0)
	check(got, "the engine-driven brain calls his ghouls into the core (%d)" % bodies("ghoul").size())
	boss.set_physics_process(false)


# ------------------------------------------------------------------------------------------------------------------------ thralls

## What boss_base.t_thralls does not check: he is not a target while he cannot be hurt (the external's alive flag), and his sweep reaches the thrall that stands by him.
func t_king_thralls() -> void:
	clear_logs()
	check(wake() == "", "woken for the thralls")
	var toward := Vector3(-1.0, 0.0, 0.0)
	put(arena() + toward * 8.0)
	await ticks(2)
	var t1 := thrall(arena() + toward * 2.6)
	core.set_thrall_stats(t1, {"hp": 4000.0})
	check(await until(func() -> bool: return int(core.thrall_info(t1)["target"]) == boss.core_id, 4.0), "the thrall by him picks him")
	boss.bstate.state = "sunk"
	check(not boss.is_hittable(), "(a sunk body cannot be hurt)")
	await ticks(3)
	check(int(core.thrall_info(t1)["target"]) == 0 and not (boss.core_id in host.enemies_in_radius(arena(), 30.0)), "while he cannot be hurt the thrall lets go and the queries skip him")
	var n_hits := thrall_hits.size()
	await secs(1.0)
	check(thrall_hits.size() == n_hits, "no blow lands on him meanwhile")
	boss.bstate.state = "idle"
	check(await until(func() -> bool: return int(core.thrall_info(t1)["target"]) == boss.core_id, 3.0), "and picks him again when he can")
	# he hits it back: his brain runs on the engine now
	boss.set_physics_process(true)
	put(arena() + toward * 5.0)
	thrall_dmg.clear()
	var struck := await until(func() -> bool: return thrall_dmg.any(func(d: Array) -> bool: return d[0] == t1 and d[1] == boss.core_id), 10.0)
	check(struck, "his sweep reaches the thrall that stands by him: core.damage on its id with his id as the source")
	if struck:
		var d: Array = thrall_dmg.filter(func(x: Array) -> bool: return x[0] == t1 and x[1] == boss.core_id)[0]
		check(near(float(d[2]), boss.brain._dmg(20.0)), "for 20 x level x difficulty (%.2f)" % float(d[2]))
	boss.set_physics_process(false)
	core.kill_thrall(t1, "crumbled")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ rites

## What boss_base.t_rites does not check (it has the edge query, Bone Needle's range, formula and credit, and the stun's cooldown).
func t_king_rites() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for the rites")
	var bid := boss.core_id
	var bp := boss.global_position
	await ticks(2)
	hb.teleport(bp + Vector3(8.0, 0.0, 0.0))
	boss.world.refresh()
	# the queries: his edge, his radius, after the enemies
	var robber := host.spawn_enemy("robber", bp + Vector3(9.0, 0.0, 5.0), 1, 1.0, 0.0, false, "graves", false)
	core.stun(robber, 3600.0)
	await ticks(2)
	var ids := host.enemies_in_radius(bp + Vector3(8.0, 0.0, 0.0), 12.0)
	check(Array(ids) == [robber, bid], "he comes after the enemies though the robber is farther: %s" % str(ids))
	var foes := host.foes_in_radius(bp + Vector3(8.0, 0.0, 0.0), 12.0)
	check(foes.size() == 2 and foes[1].boss and foes[1].id == bid and near(foes[1].radius, 1.6) and not foes[0].boss and foes[1].def == "boss_gravedigger" and foes[1].alive() and foes[1].hittable(), "as DmFoe snapshots: the second is the boss, radius 1.6")
	check(near(foes[1].scale_x(), 1.0), "(the model scale of his def)")
	check(c.foe(bid) != null and c.foe(bid).boss and c.foes_in_radius(bp, 2.0).size() == 1, "the caster's foe queries know him")
	var lane := DmRiteModule.lane(c, bp.x + 8.0, bp.z + 1.5, -1.0, 0.0, 14.0, 0.6, false)
	check(lane.size() == 1 and lane[0]["e"].id == bid and near(float(lane[0]["along"]), 8.0), "a lane 1.5 m beside his centre (half width 0.6 + his radius 1.6) strikes him (along %.1f)" % (float(lane[0]["along"]) if lane.size() > 0 else -1.0))
	check(DmRiteModule.lane(c, bp.x + 8.0, bp.z + 2.3, -1.0, 0.0, 14.0, 0.6, false).is_empty(), "and one 2.3 m beside it misses (2.3 > 2.2)")
	var circle := DmRiteModule.enemies_in_circle(c, bp.x - 8.0, bp.z, 6.5)
	check(circle.size() == 1 and circle[0].id == bid, "a circle of 6.5 m centred 8 m from him reaches his edge (6.4 from his centre to it) and not the robber on the other side")
	check(DmRiteModule.enemies_in_circle(c, bp.x - 8.2, bp.z, 6.5).is_empty(), "and one 8.2 m away (6.6 to his edge) does not")
	# Bone Fan: the cone strikes him and the robber behind
	await ticks(2)
	hb.teleport(bp + Vector3(7.0, 0.0, 0.0))
	boss.world.refresh()
	c.p["resource"]["value"] = 50.0
	var hp0 := boss.hp
	var fan_dmg := DmAbilities.rite_damage(sp_now(), "bone_fan")
	var r := cast("bone_fan", bp, bid)
	await secs(0.8)
	check(bool(r["ok"]) and near(hp0 - boss.hp, fan_dmg), "Bone Fan struck him for %.3f (%.3f)" % [hp0 - boss.hp, fan_dmg])
	# Rot Lance: the lane through him
	hp0 = boss.hp
	var mark := hit_log.size()
	r = cast("rot_lance", bp, bid)
	await secs(0.8)
	var lh := hits_of("rot_lance", mark)
	check(bool(r["ok"]) and lh.any(func(x: Array) -> bool: return x[1] == bid and float(x[2]) > 0.0) and boss.hp < hp0, "Rot Lance struck him (%.1f)" % (hp0 - boss.hp))
	# Marrow Spear with Legion Champion 5: the nearest enemy it struck is marked, the legion turns on it (set_thrall_target takes his id) and hits it harder
	var rally := int(core.raise_thrall({"kind": "warrior", "hp": 4000.0, "maxHp": 4000.0, "damage": 1.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false},
		hb.core_id, Vector2(hb.position.x - 1.0, hb.position.z), 0.0, 8.0))
	hb.teleport(bp + Vector3(7.0, 0.0, 0.0))
	boss.world.refresh()
	await secs(1.0)   # it rises for 0.9 s
	c.mods["spearRally"] = 0.5
	c.p["resource"]["value"] = 50.0
	hp0 = boss.hp
	r = cast("marrow_spear", bp, bid)
	await secs(0.5)
	check(bool(r["ok"]) and boss.hp < hp0 and int(core.thrall_info(rally)["target"]) == bid and near(float(core.thrall_info(rally)["mark_mult"]), 1.5),
		"Marrow Spear struck him and its rally marked him: the legion's thrall fights him with the mark's x1.5 (%s)" % str(core.thrall_info(rally)["mark_mult"]))
	c.mods.erase("spearRally")
	core.kill_thrall(rally, "crumbled")
	DmStatusSet.of(boss).clear()   # the Spear's bleed and the Lance's rot burn him meanwhile
	# the Scythe's arc: he counts with his own reach and one of the arc's hits
	await ticks(2)
	hb.teleport(bp + Vector3(3.5, 0.0, 0.0))
	boss.world.refresh()
	c.p["loadout"]["reap"] = true
	var near_robber := host.spawn_enemy("robber", hb.position + Vector3(-2.0, 0.0, 0.5), 1, 1000.0, 0.0, false, "graves", false)
	core.stun(near_robber, 3600.0)
	await ticks(2)
	hp0 = boss.hp
	var rb0 := hp_of(near_robber)
	var rc := DmAbilities.reap_cast(sp_now(), "", 0.5, 2)
	c.p["resource"]["value"] = 50.0
	r = cast("bone_needle", bp, bid)
	await ticks(3)
	check(bool(r["ok"]) and near(hp0 - boss.hp, float(rc["dmg"])) and near(rb0 - hp_of(near_robber), float(rc["dmg"])), "the Scythe's arc cut him and the robber in front of him for %.3f each (two landed)" % float(rc["dmg"]))
	c.p["loadout"]["reap"] = false
	# statuses are his own set: Withered burns him with the hero's credit; slow, root and chill show but the brain ignores them
	await ticks(2)
	hp0 = boss.hp
	var w0 := c.status_stacks(bid, &"withered")   # Rot Lance left some
	c.apply_status(bid, &"withered", 2.0, -1.0, {"dps": 30.0})
	check(c.has_status(bid, &"withered") and c.status_stacks(bid, &"withered") == w0 + 2 and DmStatusSet.of(boss).stacks(&"withered") == w0 + 2, "Withered sits in his own DmStatusSet (%d stacks)" % c.status_stacks(bid, &"withered"))
	boss.set_physics_process(true)
	await secs(1.0)
	boss.set_physics_process(false)
	check(boss.hp < hp0 - 20.0 and boss.brain.last_hit_by == str(me), "and burns him for the hero (%.1f in a second)" % (hp0 - boss.hp))
	var x0 := boss.global_position
	c.apply_status(bid, &"chill")
	c.apply_status(bid, &"root")
	check(c.has_status(bid, &"chill") and c.has_status(bid, &"root") and c.remove_status(bid, &"chill") and not c.has_status(bid, &"chill") and not c.remove_status(bid, &"chill"), "chill and root are shown and removable")
	check(boss.global_position.is_equal_approx(x0), "(he has not moved)")
	# a stun staggers him once
	c.apply_status(bid, &"stun", 1.0, 5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "a stun status staggers him at most 0.5 s (%.2f; the cooldown is boss_base.t_rites's)" % boss.brain.stagger_t)
	core.damage(robber, 1.0e9, 0)
	core.damage(near_robber, 1.0e9, 0)
	DmStatusSet.of(boss).clear()
	# Colossus Mantle's reflect turns a share of a blow back at its source: the hero is hurt with the King's core id as the source, and the reflect finds him by it
	c.mods["wardReflect"] = 0.5
	hp0 = boss.hp
	(DmRiteRegistry.module("black_litany") as DmRiteModule).call(&"hurt_legend", c, 400.0, 0.5, bid, 0.0)
	var back := DmLegend.ward_reflect_damage(400.0, 0.5, 0.5)
	check(back >= 1.0 and near(hp0 - boss.hp, back), "Colossus Mantle's reflect hit him for %.2f (the formula %.2f)" % [hp0 - boss.hp, back])
	c.mods.erase("wardReflect")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ the real clock

## What boss_base.t_real_clock does not check: a thrall beside him hits him through the core meanwhile, and phase 1 calls nothing.
func t_king_real_clock() -> void:
	clear_logs()
	check(wake() == "", "woken for the thrall on the real clock")
	boss.set_physics_process(true)   # the engine ticks his brain; the host ticks the core and dispatches its events
	put(arena() + Vector3(4.0, 0.0, 0.0))
	var spawned0 := spawned_n
	var t1 := thrall(arena() + Vector3(3.0, 0.0, 0.0), 4000.0, 40.0)
	var hit := await until(func() -> bool: return thrall_hits.size() >= 1, 10.0)
	check(hit and boss.hp < boss.max_hp, "the thrall hit him through the core meanwhile (%d blows)" % thrall_hits.size())
	check(spawned_n == spawned0, "(phase 1 called nothing)")
	core.kill_thrall(t1, "crumbled")
	boss.set_physics_process(false)
	await dismiss()
