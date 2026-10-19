extends "res://tests/boss_base.gd"
## The Mire Mother on the combat core (the Mourning Fen's boss; archive/old-game:godot/tests/next_bosses/mire_part.gd on today's game, the same numbers and timing). She sinks under a hummock (an external of
## the core that is not alive for its queries while she is under: thralls let go, rites and the pick find nothing), her Drowned Rite raises a Risen from every corpse of the Fen (the core's
## corpse field, `raised`) and her Drowned Hands root a wading hero.
##   - her recorded scenarios are replayed by tests/bosses (not here) (the corpses rite among them); the generic parts (boss_base.gd): the summon at the Mire Altar (7 soul shards), thralls,
##     rites, wipe, defeat, rewards;
##   - Maul, Drowned Hands (only whoever wades the open water, root 1 s; a hummock is safe) and Surface at today's ticks and numbers: she hunts the hummock you stand on 65 % of the time, slips under
##     at once (sunk: awake, not hittable, a blow and a stun refused, absent from the rite world, thralls let go, still the active boss and still "busy"), the ripple ring, the eruption under whoever
##     stays (160 x scale), winded for 2.8 s;
##   - the phases: the flood shrinks the hummocks (0.72), the cooldowns; each wave's bodies (P2's six Mire Leeches on the rim, P3's two Bog Hags and four Leeches: core bodies of the Fen); the Drowned Rite: a beam to each corpse of the Fen (at most 6, the nearest), the Risen made where each lay (core bodies, the Fen's), a
##     corpse claimed meanwhile is not raised, a corpse of another area is untouched, no corpse at all and she reels for 3 s.
## Run: godot --headless --path client --script res://tests/boss_mire.gd [--fixed-fps 60 before --path runs it faster than real time]

const Geom := preload("res://sim/bosses/boss_geom.gd")

var M: Dictionary


func _config() -> void:
	boss_id = "mire"
	load_areas = ["fen"]
	bakes = ["thrall_legionnaire", "skeleton_thrall", "mire_leech", "bog_hag"]


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


func fen_corpses() -> int:
	return host.corpses.corpses_in_radius(arena(), 200.0, Callable(), "fen").size()


func lay(x: float, z: float, area := "fen") -> int:
	return host.corpses.add_corpse(x, z, "normal", "robber", false, 0.0, 1.0, area)


func quiet(maul := 1.0e9, hands := 1.0e9, surf := 1.0e9) -> void:
	boss.brain.pending.clear()
	boss.brain.state["state"] = "idle"
	boss.brain.stagger_t = 0.0
	boss.brain._maul_cd = maul
	boss.brain._hands_cd = hands
	boss.brain._surface_cd = surf
	boss.brain._rite_cd = 1.0e9
	boss.brain._spot = -1
	boss._mirror()


func hurt_n(since: int, base: float) -> Array:
	return hurts.slice(since).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(base)) < 1e-6)


## The point of the arena ring (r 9) farthest from `p`.
func far_from(p: Vector2) -> Vector3:
	var best := arena()
	var bd := -1.0
	for k in 12:
		var a := float(k) * TAU / 12.0
		var c := arena() + Vector3(sin(a) * 9.0, 0.0, cos(a) * 9.0)
		var d := Vector2(c.x, c.z).distance_to(p)
		if d > bd:
			bd = d
			best = c
	return best


## Both waves: P2's six Mire Leeches, then P3's two Bog Hags and four Leeches (twelve bodies).
func provoke_waves() -> void:
	set_hp(0.5)
	wound(0.29)
	check(boss.phase == 3 and adds("mire_leech").size() == 10 and adds("bog_hag").size() == 2, "(both waves are in the core: %d bodies)" % adds().size())


func run_suite() -> void:
	M = DmContent.get_export("bosses", "MIRE")
	g.bosses.rng.seed = 7
	await t_summon(7, 42000.0)
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe(14, func() -> void:
		provoke_waves()
		lay(arena().x - 5.0, arena().z - 4.0)
		lay(arena().x - 3.0, arena().z - 4.0)
		quiet()
		boss.brain._rite_cd = 0.0
		step(2.9)
		check(adds("risen").size() == 2, "(two Risen stand where the corpses lay)"))
	await t_defeat(true, provoke_waves)
	await t_real_clock(["maul", "hands", "surface"], 20.0)
	await t_net_state()


func t_fight() -> void:
	clear_logs()
	check(wake() == "", "woken for the fight")
	var s: Dictionary = boss.brain.state
	check(int(s["level"]) == 45, "the Fen's level 45")
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "she rises on the central hummock (-42, -80), phase 1")
	# ---- Maul at 2.0 s
	quiet(2.0)
	put(arena() + Vector3(3.0, 0.0, 0.0))
	step(1.9)
	check(events("maul").is_empty(), "no maul before its opening cooldown (2 s)")
	step(0.2)
	var ml := telegraphs("maul")
	check(ml.size() == 1 and absf(float(ml[0]["t"]) - 2.0) < 0.05, "maul telegraphed at 2.0 s")
	if ml.is_empty():
		return
	var e: Dictionary = ml[0]["ev"]
	check(near(float(e["ms"]), 900.0) and near(float(e["r"]), 3.4), "maul telegraph 900 ms, radius 3.4")
	check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "cone aimed at the hero")
	step(1.0)
	var mi := impacts("maul")
	check(mi.size() == 1 and absf(float(mi[0]["t"]) - float(ml[0]["t"]) - 0.9) < 0.03 and hurt_n(0, 80.0).size() == 1, "the maul lands 0.9 s later for 80 x level x difficulty (%.0f)" % scaled(80.0))
	check(absf(float(boss.brain._maul_cd) - (3.2 - (3.1 - float(ml[0]["t"])))) < 0.15, "maul cooldown 3.2 s (%.2f left)" % float(boss.brain._maul_cd))
	# ---- Drowned Hands: only whoever wades the open water
	quiet(1.0e9, 0.0)
	put(arena() + Vector3(5.0, 0.0, 0.0))   # off every hummock, in the bog
	check(Geom.in_bog(hb.position.x, hb.position.z) and not Geom.on_hummock(hb.position.x, hb.position.z, 1.0), "the hero is wading")
	var nh := hurts.size()
	step(0.05)
	var hd := telegraphs("hands")
	check(hd.size() == 1, "Drowned Hands telegraphed")
	if hd.size() == 1:
		var e2: Dictionary = hd[0]["ev"]
		var tg: Array = e2["targets"]
		check(near(float(e2["ms"]), 1300.0) and near(float(e2["r"]), 1.5) and tg.size() >= 2 and tg.size() <= 4, "hands 1300 ms, ring radius 1.5, 2-4 rings (%d)" % tg.size())
		check(absf(float(tg[0][0]) - hb.position.x) < 1e-6 and absf(float(tg[0][1]) - hb.position.z) < 1e-6, "a ring under the wading hero")
	check(absf(float(boss.brain._hands_cd) - 9.0) < 0.1, "hands cooldown 9 s")
	step(1.4)
	var hi := impacts("hands")
	check(hi.size() == 1 and absf(float(hi[0]["t"]) - float(hd[0]["t"]) - 1.3) < 0.03 and hurt_n(nh, 45.0).size() == 1, "the hands close 1.3 s later: 45 x scale, once")
	check(near(float(hi[0]["ev"]["root"]), 1.0) and hi[0]["ev"]["players"] == [str(me)] and float(hb.p["rootedUntil"]) > hb._clock_ms, "they root the hero for 1 s")
	# on a hummock nothing reaches for you
	quiet(1.0e9, 0.0)
	put(arena())
	step(0.05)
	var hd2 := telegraphs("hands")
	check(hd2[hd2.size() - 1]["ev"]["targets"].all(func(t: Array) -> bool: return Vector2(float(t[0]) - hb.position.x, float(t[1]) - hb.position.z).length() > 1e-6), "dry ground (a hummock) is safe from the hands: no ring is aimed at it")
	quiet()
	# ---- Surface: sunk = untargetable, ripple ring, then she erupts and is winded
	var hunts := 0
	put(Vector3(-36.3, 0.0, -76.7))   # on hummock 3
	for i in 60:
		quiet(1.0e9, 1.0e9, 0.0)
		boss.brain.state["x"] = arena().x
		boss.brain.state["z"] = arena().z
		step(0.02)
		var sf := telegraphs("surface")
		var last: Dictionary = sf[sf.size() - 1]["ev"]
		if Vector2(float(last["x"]) + 36.3, float(last["z"]) + 76.7).length() < 0.01:
			hunts += 1
	check(hunts >= 30 and hunts <= 55, "she hunts the hummock you stand on 65 %% of the time (%d / 60 on it)" % hunts)
	quiet(1.0e9, 1.0e9, 0.0)
	put(arena() + Vector3(0.0, 0.0, 9.0))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	var spots: Array = DmContent.get_export("fen", "FEN_SURFACE_SPOTS")
	var humm: Array = DmContent.get_export("fen", "FEN_HUMMOCKS")
	var n_sf := telegraphs("surface").size()
	step(0.02)
	var sf2 := telegraphs("surface")
	check(sf2.size() == n_sf + 1, "Surface telegraphed")
	var se: Dictionary = sf2[sf2.size() - 1]["ev"]
	var spot_ok := spots.any(func(i: int) -> bool: return absf(float(humm[i]["x"]) - float(se["x"])) < 1e-6 and absf(float(humm[i]["z"]) - float(se["z"])) < 1e-6)
	check(spot_ok and near(float(se["ms"]), 2300.0) and near(float(se["r"]), 3.7), "ripple ring over one of the six hummocks, 2300 ms, radius 3.7")
	check(absf(float(boss.brain._surface_cd) - 13.0) < 0.1, "surface cooldown 13 s")
	var hp0 := boss.hp
	check(boss.brain.state["state"] == "sunk" and boss.bstate.state == "sunk" and not boss.is_hittable() and boss.is_awake(), "she slips under at once: sunk, awake, not hittable")
	check(absf(boss.global_position.x - float(se["x"])) < 1e-3 and absf(boss.global_position.z - float(se["z"])) < 1e-3, "she is under the hummock the ring fills")
	await ticks(2)   # the core is told she cannot be hurt
	check(host.enemy_info(boss.core_id)["state"] == DmCoreEvents.State.BURROW and not host.foe(boss.core_id).hittable() and not (boss.core_id in host.enemies_in_radius(boss.global_position, 5.0)),
		"sunk: the host reports her as underground (not hittable) and the queries skip her; the core's external is not alive")
	check(not boss.take_damage(5000.0, hb) and boss.hp == hp0, "sunk: take_damage refused")
	boss.brain.damage(5000.0, str(me), 0)
	check(float(boss.brain.state["hp"]) == hp0, "sunk: even the brain refuses damage")
	var rr: Dictionary = host.damage(boss.core_id, 5000.0, hb.core_id)
	check(float(rr["dealt"]) == 0.0 and not bool(rr["killed"]), "sunk: a rite's blow on her id deals nothing")
	boss.stun(2.0)
	check(boss.brain.stagger_t == 0.0, "sunk: a stun does nothing")
	check(g.enemies_in_radius(boss.global_position, 1.0).is_empty() and g.bosses.living().is_empty() and g.bosses.active_boss() == boss, "sunk: absent from the rite world and the pick list, still the active boss (bar, music)")
	check(g.bosses.try_summon(me, "mire") == "busy", "sunk: still counts as awake (no second summon)")
	var tz := thrall(boss.global_position + Vector3(-2.6, 0.0, 0.0), 4000.0, 60.0)
	put(boss.global_position + Vector3(-3.0, 0.0, 3.0))
	await ticks(2)
	var r := cast("bone_needle", boss.global_position, boss.core_id)
	await ticks(60)
	check(int(core.thrall_info(tz)["target"]) != boss.core_id and boss.hp == hp0 and float(boss.brain.state["hp"]) == hp0, "sunk: thralls do not engage her and a rite finds nothing to hit (%s)" % str(r))
	core.kill_thrall(tz, "crumbled")
	# the ring fills, she erupts under whoever stays
	put(Vector3(float(se["x"]) + 1.0, 0.0, float(se["z"])))
	nh = hurts.size()
	step(2.2)
	check(impacts("surface").is_empty() and boss.brain.state["state"] == "sunk", "still under before the ring is full")
	step(0.2)
	var si := impacts("surface")
	check(si.size() == 1 and absf(float(si[0]["t"]) - float(sf2[sf2.size() - 1]["t"]) - 2.3) < 0.03, "she erupts 2.3 s after the ring appears")
	check(hurt_n(nh, 160.0).size() == 1, "whoever stayed on the hummock takes 160 x scale")
	check(boss.brain.state["state"] == "idle" and boss.is_hittable() and boss.brain.stagger_t > 2.4 and boss.brain.stagger_t <= 2.8, "surfaced: hittable again and winded for 2.8 s (%.2f)" % boss.brain.stagger_t)
	await ticks(2)
	check(host.enemy_alive(boss.core_id) and boss.core_id in host.enemies_in_radius(boss.global_position, 1.0), "(and the core's external is alive again)")
	check(boss.take_damage(500.0, hb) and boss.hp < hp0, "winded she can be hit")
	# winded: nothing happens until it ends
	boss.brain._maul_cd = 0.0
	put(boss.global_position + Vector3(3.0, 0.0, 0.0))
	var nm := telegraphs("maul").size()
	step(2.0)
	check(telegraphs("maul").size() == nm, "no attack while she is winded")
	step(1.0)
	check(telegraphs("maul").size() == nm + 1, "she attacks again when the stagger ends")
	# off the hummock the eruption misses
	quiet(1.0e9, 1.0e9, 0.0)
	put(arena() + Vector3(0.0, 0.0, 10.0))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	step(0.02)
	var sf3 := telegraphs("surface")
	var se3: Dictionary = sf3[sf3.size() - 1]["ev"]
	put(far_from(Vector2(float(se3["x"]), float(se3["z"]))))
	nh = hurts.size()
	step(2.4)
	check(hurt_n(nh, 160.0).is_empty(), "stepping off the hummock dodges the eruption")
	check(boss.brain.state["state"] != "sunk" and boss.is_hittable(), "surfaced again (%s)" % boss.brain.state["state"])
	# ---- phase 2: flood, tighter timings
	quiet()
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "phase 2 at 60 %")
	var fl := events("flood")
	check(fl.size() == 1 and int(fl[0]["ev"]["phase"]) == 2 and fl[0]["ev"]["targets"].size() == 6, "the marsh floods (event phase 2, 6 spots)")
	check(fl[0]["ev"]["targets"].all(func(t: Array) -> bool: return absf(Vector2(float(t[0]) - arena().x, float(t[1]) - arena().z).length() - 12.0 * 0.9) < 0.01), "the wave's six spots lie on the rim (0.9 r)")
	var wave2 := adds()
	check(wave2.size() == 6 and adds("mire_leech").size() == 6, "P2 calls six Mire Leeches (core bodies)")
	check(wave2.all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "fen" and absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - 12.0 * 0.9) < 0.01), "on the arena rim (0.9 r), counted as Fen enemies")
	clear_adds()
	check(near(float(boss.brain._flood_scale(2)), 0.72) and not Geom.on_hummock(hb.position.x, hb.position.z, 0.72), "the hummocks shrink to 0.72: the hero's old dry spot is now water")
	quiet(1.0e9, 0.0)
	boss.world.refresh()
	step(0.05)
	var hd3 := telegraphs("hands")
	var h3: Dictionary = hd3[hd3.size() - 1]["ev"]
	check(absf(float(h3["targets"][0][0]) - hb.position.x) < 1e-6 and absf(float(boss.brain._hands_cd) - 7.5) < 0.1, "in the flood the hands reach the hero, cooldown 7.5 s")
	quiet(1.0e9, 1.0e9, 0.0)
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	step(0.02)
	var sf4 := telegraphs("surface")
	check(near(float(sf4[sf4.size() - 1]["ev"]["ms"]), 2000.0) and absf(float(boss.brain._surface_cd) - 11.0) < 0.1, "P2 surface 2000 ms, cooldown 11 s")
	quiet()
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	# ---- phase 3: the Drowned Rite
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	step(0.1)
	check(boss.phase == 3 and events("flood").size() == 2 and int(events("flood")[1]["ev"]["phase"]) == 3, "phase 3 at 30 %, the flood deepens")
	check(adds("bog_hag").size() == 2 and adds("mire_leech").size() == 4 and adds().size() == 6 and events("flood")[1]["ev"]["targets"].size() == 6, "P3 calls 2 Bog Hags + 4 Mire Leeches (core bodies, their 6 spots told)")
	clear_adds()
	# 3 corpses in the Fen (+1 in the Graves, which she must not touch); one is claimed mid-windup
	var ids: Array = []
	for i in 3:
		ids.append(lay(arena().x - 5.0 + float(i) * 2.0, arena().z - 4.0))
	lay(-14.0, -22.0, "graves")
	quiet()
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	var nr := telegraphs("rite").size()
	step(0.05)
	var rt1 := telegraphs("rite")
	check(rt1.size() == nr + 1, "the Drowned Rite is telegraphed")
	var re: Dictionary = rt1[rt1.size() - 1]["ev"]
	check(near(float(re["ms"]), 2600.0) and re["targets"].size() == 3, "rite 2600 ms, a beam to each of the 3 corpses in the Fen")
	check(absf(float(boss.brain._rite_cd) - 13.0 * 0.8) < 0.15, "rite cooldown 13 x 0.8 s")
	check(host.corpses.consume(ids[0], me, "litany"), "the player claims a corpse before the rite lands")
	step(2.7)
	var rim := impacts("rite")
	check(rim.size() == 1 and rim[0]["ev"]["targets"].size() == 2 and absf(float(rim[0]["t"]) - float(rt1[rt1.size() - 1]["t"]) - 2.6) < 0.03, "the rite raises only what is left (2 of 3) 2.6 s later")
	check(adds("risen").size() == 2 and fen_corpses() == 0, "2 Risen stand where the corpses lay (core bodies), the Fen is empty")
	check(adds("risen").all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "fen"), "(counted as Fen enemies)")
	check(host.corpses.corpses_in_radius(Vector3(-14.0, 0.0, -22.0), 5.0, Callable(), "graves").size() == 1, "a corpse in another area is untouched")
	check(boss.brain.stagger_t == 0.0, "a rite that finds the dead does not stagger her")
	clear_adds()
	await ticks(2)
	# nine corpses: the six nearest are raised
	for i in 9:
		lay(arena().x - 8.0 + float(i) * 2.0, arena().z + 1.0 + float(i) * 0.5)
	quiet()
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	step(0.05)
	var rt2 := telegraphs("rite")
	check(rt2[rt2.size() - 1]["ev"]["targets"].size() == 6, "at most 6 corpses are drawn into the rite")
	step(2.7)
	check(adds("risen").size() == 6 and fen_corpses() == 3, "6 Risen, the 3 farthest corpses remain")
	clear_adds()
	for id in core.corpse_ids():
		host.corpses.consume(int(id), 0, "consumed")
	await ticks(2)
	# starve the rite: she staggers
	quiet()
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	step(0.05)
	step(2.7)
	var rfail := impacts("rite")
	check(rfail.size() == 3 and rfail[2]["ev"]["targets"].is_empty(), "no corpses at all: the rite fails")
	check(boss.brain.stagger_t > 2.7 and boss.brain.stagger_t <= 3.0 and adds("risen").is_empty(), "starved, she reels for 3 s (%.2f)" % boss.brain.stagger_t)
	await dismiss()
