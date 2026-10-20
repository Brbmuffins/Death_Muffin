extends "res://tests/boss_base.gd"
## The Gravedigger King on the combat core (client/README.md "The bosses"): the real offline game scene (client/next/next_game.tscn) with a level-20 Gravecaller, no waves, headless, on boss_base.gd
## like the six other bosses' suites (boss_abbess.gd ... boss_mire.gd). The King is today's DmBossHost / DmBoss / DmBossBrain, ported: his body is an external of the core (kind 1), his brain stays GDScript.
## The generic parts every boss gets are boss_base.gd's (the summon and its refusals, thralls, rites, wipe, defeat and rewards, the real clock, the net state); his recorded scenarios are replayed by tests/bosses.
## What is the King's own is here:
##   - the host wakes the boss of every area the boss data names; another area's boss is far from his grave; he stands at the arena centre of the data, in the core's records;
##   - his fight stepped by hand (exact timing, as archive/old-game:godot/tests/next_bosses/gravedigger_part.gd does): Spade Sweep and Burial (numbers, telegraphs, the blows on the hero and on a thrall), the phases
##     (boss_base.gd's PHASE_AT), Barrow Ghouls on the arena rim and the elite robber (adds are core bodies of the Graves, the boss's area), the pits, the double sweep; his numbers are the boss data's
##     (`GRAVEDIGGER` in bosses.json), his opening cooldowns the brain's on waking;
##   - thralls: he is not a target while he cannot be hurt (the external's `alive`), and his sweep reaches the thrall that stands by him (`core.damage` on its id);
##   - the rites hit him: the host's queries append him after the enemies, the lane, the cone and the circle helpers, Bone Fan, Rot Lance, the Spear's rally, the Scythe's arc count him, a rite's damage goes to his
##     brain with the hero's credit, his statuses are his own DmStatusSet (the brain ignores slow, root and chill; Fracture and Sanctified scale the blows he takes), a stun status staggers him, Colossus Mantle's reflect finds him by his core id;
##   - his wipe (the adds he has called leave silently) and his defeat (the brain on the engine's ticks calls the ghouls; they leave with him) use the generic parts with his own provocations; on the real clock a thrall beside him hits him.
## ZERO script errors or engine errors in the log (an OS Logger counts them).
## Gets the robber, the hound and the Gravecaller's legionnaire into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --path client --script res://tests/boss.gd
## It plays about 60 s of game time: with the engine argument `--fixed-fps 60` before `--path` it runs faster than real time.


func _config() -> void:
	boss_id = "gravedigger"
	load_areas = ["graves"]
	bakes = ["grave_robber", "bone_hound", "thrall_legionnaire"]


func run_suite() -> void:
	king_wire()
	await t_summon()
	await t_king_summon()
	await t_hand_fight()
	await dismiss()
	await t_wipe(2 * int(DmContent.get_export("bosses", "GRAVEDIGGER")["exhume"]["ghouls"]) + 1, provoke_adds)
	await t_thralls()
	await t_king_thralls()
	await t_rites()
	await t_king_rites()
	await t_defeat(true, provoke_ghouls)
	await t_real_clock(["sweep", "bury"], 20.0)
	await t_king_real_clock()
	await t_net_state()


## What the King's brain does that is in its code and not in the boss data (sim/bosses/gravedigger_brain.gd): the elite robber joins below 45 % of his health, a pit hurts for 0.6 of a Burial, and in
## phase 3 a sweep is answered by a second cone a turn of PI / 3 later and 650 ms behind.
const ELITE_AT := 0.45
const PIT_HURT := 0.6
const DOUBLE_SWEEP_MS := 650.0
const DOUBLE_SWEEP_TURN := PI / 3.0


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


## One brain tick at a time (by hand, without the core's tick) until `cond` holds, at most `limit` seconds.
func hand_until(cond: Callable, limit: float) -> void:
	for i in int(limit / DT):
		if cond.call():
			return
		hand(DT)


func t_hand_fight() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for the fight")
	var G: Dictionary = DmContent.get_export("bosses", "GRAVEDIGGER")
	var open_sweep: float = boss.brain._sweep_cd   # his opening cooldowns, as his brain sets them on waking
	var open_bury: float = boss.brain._bury_cd
	var open_exhume: float = boss.brain._exhume_cd
	var sweep_s := float(G["sweep"]["windupMs"]) / 1000.0
	var bury_s := float(G["burial"]["windupMs"]) / 1000.0
	var total0 := host.enemy_total()
	# Spade Sweep: numbers and telegraph timing
	hb.teleport(arena() + Vector3(minf(3.0, float(G["sweep"]["r"]) * 0.6), 0.0, 0.0))
	boss.world.refresh()
	hand(open_sweep - 0.1)
	check(events("sweep", 0.0).is_empty(), "no attack before the opening cooldown (%.1f s)" % open_sweep)
	hand(0.3)
	var sw := events("sweep", 0.0)
	check(sw.size() == 1, "Spade Sweep telegraphed at the opening cooldown")
	var sweep := {}
	if sw.size() == 1:
		sweep = sw[0]
		var e: Dictionary = sweep["ev"]
		check(near(float(e["ms"]), float(G["sweep"]["windupMs"])) and near(float(e["r"]), float(G["sweep"]["r"])), "the sweep telegraph is %d ms, radius %.1f (the boss data's)" % [int(G["sweep"]["windupMs"]), float(G["sweep"]["r"])])
		check(absf(float(sweep["t"]) - open_sweep) < 0.05, "the sweep fires at t=%.1f s (%.3f)" % [open_sweep, float(sweep["t"])])
		check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "the cone is aimed at the hero")
	# a thrall in the cone: raised by the core, hurt by the King through the core (his blows on thralls)
	var th_off := float(G["sweep"]["r"]) * 0.4
	var th := int(core.raise_thrall({"kind": "warrior", "hp": 500.0, "maxHp": 500.0, "damage": 10.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false}, hb.core_id,
		Vector2(boss.global_position.x + th_off, boss.global_position.z), 0.0, 8.0))
	check(th > 0 and core.thrall_info(th)["hp"] == 500.0, "a thrall stands in the cone, %.1f m from the King" % th_off)
	hand(sweep_s + 0.1)
	var sw_hit := impacts("sweep")
	check(sw_hit.size() == 1 and absf(float(sw_hit[0]["t"]) - float(sweep["t"]) - sweep_s) < 0.03, "the blow lands %.1f s after the telegraph" % sweep_s)
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - float(G["sweep"]["dmg"]) * dmg_scale()) < 1e-6 and str(hurts[0]["player"]) == str(me), "the sweep hurts the hero for %d x level x difficulty (%.2f)" % [int(G["sweep"]["dmg"]), float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0])
	check(hero_hurt.size() == 1 and hero_hurt[0][1] is int and int(hero_hurt[0][1]) == boss.core_id and float(hero_hurt[0][0]) > 0.0, "the blow reached the hero's body with the King's core id as its source (%s)" % str(hero_hurt))
	check(sw_hit[0]["ev"]["players"].size() == 1, "the impact event lists who was hit")
	var ti: Dictionary = core.thrall_info(th)
	check(near(float(ti["hp"]), 500.0 - boss.brain._dmg(THRALL_BLOW)), "the thrall in the cone lost %d x level x difficulty through core.damage on its id (%.2f of 500)" % [int(THRALL_BLOW), 500.0 - float(ti["hp"])])
	await ticks(1)   # the core's event for it
	check(thrall_dmg.size() == 1 and thrall_dmg[0][0] == th and thrall_dmg[0][1] == boss.core_id and near(float(thrall_dmg[0][2]), boss.brain._dmg(THRALL_BLOW)), "the core reported it: the King's id as the source (%s)" % str(thrall_dmg))
	core.kill_thrall(th, "crumbled")
	# Burial (it waits for a sweep in its wind-up)
	hand_until(func() -> bool: return not events("bury", 0.0).is_empty(), open_bury + sweep_s + 1.0)
	var bu := events("bury", 0.0)
	check(bu.size() == 1 and near(float(bu[0]["ev"]["ms"]), float(G["burial"]["windupMs"])) and near(float(bu[0]["ev"]["r"]), float(G["burial"]["hd"])), "Burial telegraph %d ms, grave %.1f x %.1f half-extent" % [int(G["burial"]["windupMs"]), float(G["burial"]["hw"]), float(G["burial"]["hd"])])
	check(bu.size() == 1 and absf(float(bu[0]["t"]) - maxf(open_bury, float(sweep["t"]) + sweep_s)) < 0.1 and bu[0]["ev"]["targets"].size() == 1, "Burial at its opening cooldown (or when the sweep is done) on the hero's feet")
	var n_hurt := hurts.size()
	hand(bury_s + 0.1)
	var bi := impacts("bury")
	check(bi.size() == 1 and absf(float(bi[0]["t"]) - float(bu[0]["t"]) - bury_s) < 0.03, "the grave closes %.1f s later" % bury_s)
	check(hurts.size() == n_hurt + 1 and absf(float(hurts[hurts.size() - 1]["dmg"]) - float(G["burial"]["dmg"]) * dmg_scale()) < 1e-6, "Burial hurts for %d x scale" % int(G["burial"]["dmg"]))
	check(near(float(bi[0]["ev"]["root"]), float(G["burial"]["rootS"])) and bi[0]["ev"]["players"].size() == 1 and float(hb.p["rootedUntil"]) > hb._clock_ms, "Burial roots %d s and the hero's body is rooted" % int(G["burial"]["rootS"]))
	# phases, adds, elite
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	var ghoul_n := int(G["exhume"]["ghouls"])
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	check(boss.take_damage(boss.hp - boss.max_hp * just_into(2), hb), "a blow of the hero's takes him just under phase 2's threshold")
	hand(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1 and int(events("phase")[0]["ev"]["phase"]) == 2, "phase 2 (event + signal)")
	check("bossPhase" in astub.sfx, "the phase sound")
	var ghouls0 := bodies("ghoul").size()
	hand(open_exhume + 0.2)
	var ghouls := bodies("ghoul")
	check(ghouls.size() - ghouls0 == ghoul_n and host.enemy_total() == total0 + ghoul_n, "Exhumation: %d Barrow Ghouls are core bodies (%d in the table)" % [ghoul_n, ghouls.size()])
	var rim_r := float(def()["arena"]["r"]) * RIM
	var on_rim := ghouls.all(func(id: int) -> bool: return absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - rim_r) < 0.01)
	check(on_rim and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == ghoul_n, "dug up on the arena rim with the summon telegraph event")
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
	hand(float(G["exhume"]["everyS"]))
	check(bodies("ghoul").size() - ghouls0 == 2 * ghoul_n, "Exhumation repeats every %d s" % int(G["exhume"]["everyS"]))
	boss.take_damage(boss.hp - boss.max_hp * (ELITE_AT - 0.01), hb)
	hand(0.1)
	var elites := bodies("robber").filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"]))
	check(elites.size() == 1, "an elite Grave Robber joins at %.0f %%" % (ELITE_AT * 100.0))
	hand(2.0)
	check(bodies("robber").filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"])).size() == 1, "only one elite")
	# phase 3: pits, the double sweep
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * just_into(3), hb)
	hand(0.1)
	var pits := events("pits")
	var pit_spots: Array = DmContent.get_export("bosses", "GRAVEDIGGER_PITS")
	check(boss.phase == 3 and pits.size() == 1 and pits[0]["ev"]["targets"].size() == pit_spots.size() and near(float(pits[0]["ev"]["r"]), float(G["pits"]["r"])), "phase 3 opens the %d pits (r %.1f)" % [pit_spots.size(), float(G["pits"]["r"])])
	var pit: Array = pits[0]["ev"]["targets"][0]
	var pit_dmg := float(G["burial"]["dmg"]) * PIT_HURT * dmg_scale()
	var nh := hurts.size()
	hb.teleport(Vector3(pit[0], 0.0, pit[1]))
	boss.world.refresh()
	hand(0.1)
	var pit_hit := hurts.slice(nh)
	check(pit_hit.size() == 1 and absf(float(pit_hit[0]["dmg"]) - pit_dmg) < 1e-6, "walking into an open grave hurts for %.1f x a Burial's blow" % PIT_HURT)
	var rebury := float(G["pits"]["reburyS"])
	var nh2 := hurts.size()
	hand(rebury - 0.5)
	check(hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - pit_dmg) < 1e-6).is_empty(), "no re-bury inside the %d s cooldown" % int(rebury))
	hand(0.7)
	check(not hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - pit_dmg) < 1e-6).is_empty(), "re-buried after %d s" % int(rebury))
	hb.teleport(arena() + Vector3(minf(4.0, float(G["sweep"]["r"]) * 0.8), 0.0, 0.0))
	boss.world.refresh()
	var n_sw := events("sweep", 0.0).size()
	hand(float(G["sweep"]["cd"]) * 2.0)
	var sws := events("sweep", 0.0).slice(n_sw)
	var pair := false
	for i in range(sws.size() - 1):
		if absf(float(sws[i + 1]["t"]) - float(sws[i]["t"])) < 1e-6 and absf(float(sws[i + 1]["ev"]["ms"]) - float(sws[i]["ev"]["ms"]) - DOUBLE_SWEEP_MS) < 1e-6 and absf(float(sws[i + 1]["ev"]["dir"]) - float(sws[i]["ev"]["dir"]) - DOUBLE_SWEEP_TURN) < 1e-6:
			pair = true
	check(pair, "phase 3 sweeps twice (the second cone a turn of %.0f degrees on, %.0f ms later)" % [rad_to_deg(DOUBLE_SWEEP_TURN), DOUBLE_SWEEP_MS])


## The adds his phases call (the generic wipe's provocation): Exhumation twice (four ghouls) and the elite Grave Robber, stepped by hand; the core announces each of them.
func provoke_adds() -> void:
	var s0 := spawned_n
	var G: Dictionary = DmContent.get_export("bosses", "GRAVEDIGGER")
	var first_exhume: float = boss.brain._exhume_cd
	wound_into(2)
	step(first_exhume + 0.2)
	step(float(G["exhume"]["everyS"]))
	wound(ELITE_AT - 0.01)
	step(2.0)
	await ticks(1)
	check(spawned_n - s0 == core.enemy_ids().size(), "the core announced each of his adds (%d spawn events)" % (spawned_n - s0))


## The engine-driven brain calls his ghouls into the core (the generic defeat's provocation).
func provoke_ghouls() -> void:
	boss.set_physics_process(true)
	boss.take_damage(boss.hp - boss.max_hp * just_into(2), hb)
	var got := await until(func() -> bool: return bodies("ghoul").size() >= int(DmContent.get_export("bosses", "GRAVEDIGGER")["exhume"]["ghouls"]), 8.0 + float(boss.brain._exhume_cd))
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
		check(near(float(d[2]), boss.brain._dmg(THRALL_BLOW)), "for %d x level x difficulty (%.2f)" % [int(THRALL_BLOW), float(d[2])])
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
	check(foes.size() == 2 and foes[1].boss and foes[1].id == bid and near(foes[1].radius, DmSimConsts.BOSS_RADIUS) and not foes[0].boss and foes[1].def == "boss_gravedigger" and foes[1].alive() and foes[1].hittable(), "as DmFoe snapshots: the second is the boss, radius %.1f" % DmSimConsts.BOSS_RADIUS)
	check(near(foes[1].scale_x(), 1.0), "(the model scale of his def)")
	check(c.foe(bid) != null and c.foe(bid).boss and c.foes_in_radius(bp, 2.0).size() == 1, "the caster's foe queries know him")
	var br := DmSimConsts.BOSS_RADIUS
	var half := 0.6   # the lane's half width, the test's own
	var lane := DmRiteModule.lane(c, bp.x + 8.0, bp.z + half + br - 0.7, -1.0, 0.0, 14.0, half, false)
	check(lane.size() == 1 and lane[0]["e"].id == bid and near(float(lane[0]["along"]), 8.0), "a lane %.1f m beside his centre (half width %.1f + his radius %.1f, less 0.7) strikes him (along %.1f)" % [half + br - 0.7, half, br, float(lane[0]["along"]) if lane.size() > 0 else -1.0])
	check(DmRiteModule.lane(c, bp.x + 8.0, bp.z + half + br + 0.1, -1.0, 0.0, 14.0, half, false).is_empty(), "and one %.1f m beside it misses (> %.1f)" % [half + br + 0.1, half + br])
	var cr := 6.5   # a circle's radius, the test's own
	var circle := DmRiteModule.enemies_in_circle(c, bp.x - (cr + br - 0.1), bp.z, cr)
	check(circle.size() == 1 and circle[0].id == bid, "a circle of %.1f m centred %.1f m from him reaches his edge (%.1f from his centre to it) and not the robber on the other side" % [cr, cr + br - 0.1, cr - 0.1])
	check(DmRiteModule.enemies_in_circle(c, bp.x - (cr + br + 0.1), bp.z, cr).is_empty(), "and one %.1f m away (%.1f to his edge) does not" % [cr + br + 0.1, cr + 0.1])
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
	var rally_bonus := 0.5   # the Spear's rally the test gives the hero (the legion's blows on the marked body are +50 %)
	c.mods["spearRally"] = rally_bonus
	c.p["resource"]["value"] = 50.0
	hp0 = boss.hp
	r = cast("marrow_spear", bp, bid)
	await secs(0.5)
	check(bool(r["ok"]) and boss.hp < hp0 and int(core.thrall_info(rally)["target"]) == bid and near(float(core.thrall_info(rally)["mark_mult"]), 1.0 + rally_bonus),
		"Marrow Spear struck him and its rally marked him: the legion's thrall fights him with the mark's x%.1f (%s)" % [1.0 + rally_bonus, str(core.thrall_info(rally)["mark_mult"])])
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
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "a stun status staggers him at most %.1f s (%.2f; the cooldown is boss_base.t_rites's)" % [DmBoss.STUN_CAP_S, boss.brain.stagger_t])
	core.damage(robber, 1.0e9, 0)
	core.damage(near_robber, 1.0e9, 0)
	DmStatusSet.of(boss).clear()
	# a player's Fracture and Sanctified change the blows he takes, as any body's (DmStatusSet.scale_taken), and the damage call reports the blow after them
	var fr: Dictionary = DmSimData.FRACTURE
	c.apply_status(bid, &"fracture", 2.0)
	var want := 1.0 + 2.0 * float(fr["perStack"])
	hp0 = boss.hp
	var rr: Dictionary = host.damage(bid, 100.0, hb.core_id)
	check(near(float(rr["dealt"]), 100.0 * want) and near(hp0 - boss.hp, 100.0 * want), "two Fracture stacks: a blow of 100 takes %.1f off him (x%.2f) and the call reports %.1f" % [hp0 - boss.hp, want, float(rr["dealt"])])
	c.apply_status(bid, &"sanctified")   # (an enemy priest's blessing: it protects)
	var both := want * float(DmSimData.SANCTIFIED["damageTakenMult"])
	hp0 = boss.hp
	host.damage(bid, 100.0, hb.core_id)
	check(both < want and near(hp0 - boss.hp, 100.0 * both), "and Sanctified on top protects him: x%.2f (%.1f)" % [both, hp0 - boss.hp])
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
