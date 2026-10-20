extends "res://tests/boss_base.gd"
## The Mire Mother on the combat core (the Mourning Fen's boss; archive/old-game:godot/tests/next_bosses/mire_part.gd on today's game, the same numbers and timing). She sinks under a hummock (an external of
## the core that is not alive for its queries while she is under: thralls let go, rites and the pick find nothing), her Drowned Rite raises a Risen from every corpse of the Fen (the core's
## corpse field, `raised`) and her Drowned Hands root a wading hero.
##   - her recorded scenarios are replayed by tests/bosses (not here) (the corpses rite among them); the generic parts (boss_base.gd): the summon at the Mire Altar (its soul shards), thralls,
##     rites, wipe, defeat, rewards;
##   - Maul, Drowned Hands (only whoever wades the open water, rooted; a hummock is safe) and Surface at the ticks of her brain's opening cooldowns and the numbers of the boss data (`MIRE` in bosses.json): she hunts
##     the hummock you stand on that share of the time (huntChance), slips under at once (sunk: awake, not hittable, a blow and a stun refused, absent from the rite world, thralls let go, still the active boss
##     and still "busy"), the ripple ring, the eruption under whoever stays, winded;
##   - the phases: the flood shrinks the hummocks (FEN_FLOOD_SCALE), the cooldowns; each wave's bodies (the data's `adds`: core bodies of the Fen); the Drowned Rite: a beam to each corpse of the Fen (at most
##     maxCorpses, the nearest), the Risen made where each lay (core bodies, the Fen's), a corpse claimed meanwhile is not raised, a corpse of another area is untouched, no corpse at all and she reels.
## Run: godot --headless --path client --script res://tests/boss_mire.gd [--fixed-fps 60 before --path runs it faster than real time]

const Geom := preload("res://sim/bosses/boss_geom.gd")
## What her brain does that is in its code and not in the boss data (sim/bosses/mire_brain.gd): her cooldowns are scaled by phase, what she calls climbs out at 0.9 of the arena's radius.
const FAST := [1.0, 0.9, 0.8]
const MIRE_RIM := 0.9

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


## How many of `kind` the data's waves call, phase 2's and phase 3's together (or one wave's, `wave` "p2" or "p3").
func wave_count(kind: String, wave := "") -> int:
	var n := 0
	for w in ["p2", "p3"]:
		if wave == "" or wave == w:
			n += (M["adds"][w] as Array).count(kind)
	return n


## Both waves: P2's and then P3's bodies of the data.
func provoke_waves() -> void:
	set_hp(float(PHASE_AT[1]) + 0.2)
	wound_into(3)
	check(boss.phase == 3 and adds("mire_leech").size() == wave_count("mire_leech") and adds("bog_hag").size() == wave_count("bog_hag"), "(both waves are in the core: %d bodies)" % adds().size())


func run_suite() -> void:
	M = DmContent.get_export("bosses", "MIRE")
	g.bosses.rng.seed = 7
	await t_summon()
	await t_fight()
	await t_thralls()
	await t_rites()
	await t_wipe((M["adds"]["p2"] as Array).size() + (M["adds"]["p3"] as Array).size() + 2, func() -> void:
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
	check(int(s["level"]) == area_level(), "the Fen's level (%d)" % area_level())
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable(), "she rises on the central hummock, phase 1")
	var maul_s := float(M["maul"]["windupMs"]) / 1000.0
	var hands_s := float(M["hands"]["windupMs"]) / 1000.0
	var windup1 := float(M["surface"]["windupMs"][0]) / 1000.0
	var winded := float(M["surface"]["windedS"])
	# ---- Maul at its opening cooldown (the test's own: 2 s)
	var open_maul := 2.0
	quiet(open_maul)
	put(arena() + Vector3(minf(3.0, float(M["maul"]["r"]) * 0.8), 0.0, 0.0))
	step(open_maul - 0.1)
	check(events("maul").is_empty(), "no maul before its opening cooldown (%.0f s)" % open_maul)
	step(0.2)
	var ml := telegraphs("maul")
	check(ml.size() == 1 and absf(float(ml[0]["t"]) - open_maul) < 0.05, "maul telegraphed at %.1f s" % open_maul)
	if ml.is_empty():
		return
	var e: Dictionary = ml[0]["ev"]
	check(near(float(e["ms"]), float(M["maul"]["windupMs"])) and near(float(e["r"]), float(M["maul"]["r"])), "maul telegraph %d ms, radius %.1f" % [int(M["maul"]["windupMs"]), float(M["maul"]["r"])])
	check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "cone aimed at the hero")
	step(maul_s + 0.1)
	var mi := impacts("maul")
	check(mi.size() == 1 and absf(float(mi[0]["t"]) - float(ml[0]["t"]) - maul_s) < 0.03 and hurt_n(0, float(M["maul"]["dmg"])).size() == 1, "the maul lands %.1f s later for %d x level x difficulty (%.0f)" % [maul_s, int(M["maul"]["dmg"]), scaled(float(M["maul"]["dmg"]))])
	check(absf(float(boss.brain._maul_cd) - (float(M["maul"]["cd"]) - (boss.world.t - float(ml[0]["t"])))) < 0.15, "maul cooldown %.1f s (%.2f left)" % [float(M["maul"]["cd"]), float(boss.brain._maul_cd)])
	# ---- Drowned Hands: only whoever wades the open water
	quiet(1.0e9, 0.0)
	put(arena() + Vector3(5.0, 0.0, 0.0))   # off every hummock, in the bog
	check(Geom.in_bog(hb.position.x, hb.position.z) and not Geom.on_hummock(hb.position.x, hb.position.z, 1.0), "the hero is wading")
	var nh := hurts.size()
	step(0.05)
	var hd := telegraphs("hands")
	check(hd.size() == 1, "Drowned Hands telegraphed")
	var rings: Array = M["hands"]["rings"]
	if hd.size() == 1:
		var e2: Dictionary = hd[0]["ev"]
		var tg: Array = e2["targets"]
		check(near(float(e2["ms"]), float(M["hands"]["windupMs"])) and near(float(e2["r"]), float(M["hands"]["r"])) and tg.size() >= int(rings[0]) and tg.size() <= int(rings[1]), "hands %d ms, ring radius %.1f, %d to %d rings (%d)" % [int(M["hands"]["windupMs"]), float(M["hands"]["r"]), int(rings[0]), int(rings[1]), tg.size()])
		check(absf(float(tg[0][0]) - hb.position.x) < 1e-6 and absf(float(tg[0][1]) - hb.position.z) < 1e-6, "a ring under the wading hero")
	check(absf(float(boss.brain._hands_cd) - float(M["hands"]["cd"][0])) < 0.1, "hands cooldown %.1f s" % float(M["hands"]["cd"][0]))
	step(hands_s + 0.1)
	var hi := impacts("hands")
	check(hi.size() == 1 and absf(float(hi[0]["t"]) - float(hd[0]["t"]) - hands_s) < 0.03 and hurt_n(nh, float(M["hands"]["dmg"])).size() == 1, "the hands close %.1f s later: %d x scale, once" % [hands_s, int(M["hands"]["dmg"])])
	check(near(float(hi[0]["ev"]["root"]), float(M["hands"]["rootS"])) and hi[0]["ev"]["players"] == [str(me)] and float(hb.p["rootedUntil"]) > hb._clock_ms, "they root the hero for %d s" % int(M["hands"]["rootS"]))
	# on a hummock nothing reaches for you
	quiet(1.0e9, 0.0)
	put(arena())
	step(0.05)
	var hd2 := telegraphs("hands")
	check(hd2[hd2.size() - 1]["ev"]["targets"].all(func(t: Array) -> bool: return Vector2(float(t[0]) - hb.position.x, float(t[1]) - hb.position.z).length() > 1e-6), "dry ground (a hummock) is safe from the hands: no ring is aimed at it")
	quiet()
	# ---- Surface: sunk = untargetable, ripple ring, then she erupts and is winded
	var spots: Array = DmContent.get_export("fen", "FEN_SURFACE_SPOTS")
	var humm: Array = DmContent.get_export("fen", "FEN_HUMMOCKS")
	var hunted_i := -1   # a hummock she can surface under that is not the central one she rises on
	for i in spots:
		if hunted_i < 0 and Vector2(float(humm[int(i)]["x"]) - arena().x, float(humm[int(i)]["z"]) - arena().z).length() > 1.0:
			hunted_i = int(i)
	var hunted := Vector2(float(humm[hunted_i]["x"]), float(humm[hunted_i]["z"]))
	var hunts := 0
	put(Vector3(hunted.x, 0.0, hunted.y))   # on that hummock
	var tries := 60
	for i in tries:
		quiet(1.0e9, 1.0e9, 0.0)
		boss.brain.state["x"] = arena().x
		boss.brain.state["z"] = arena().z
		step(0.02)
		var sf := telegraphs("surface")
		var last: Dictionary = sf[sf.size() - 1]["ev"]
		if Vector2(float(last["x"]) - hunted.x, float(last["z"]) - hunted.y).length() < 0.01:
			hunts += 1
	# she picks the hummock under a hero with huntChance, else any of the spots (which may be that one too)
	var p_hunt := float(M["surface"]["huntChance"])
	var p_on := p_hunt + (1.0 - p_hunt) / float(spots.size())
	var spread := 4.0 * sqrt(float(tries) * p_on * (1.0 - p_on)) + 1.0
	check(absf(float(hunts) - float(tries) * p_on) <= spread, "she hunts the hummock you stand on %.0f %% of the time and any of the %d otherwise (%d / %d on it)" % [p_hunt * 100.0, spots.size(), hunts, tries])
	quiet(1.0e9, 1.0e9, 0.0)
	put(arena() + Vector3(0.0, 0.0, 9.0))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	var n_sf := telegraphs("surface").size()
	step(0.02)
	var sf2 := telegraphs("surface")
	check(sf2.size() == n_sf + 1, "Surface telegraphed")
	var se: Dictionary = sf2[sf2.size() - 1]["ev"]
	var spot_ok := spots.any(func(i: int) -> bool: return absf(float(humm[i]["x"]) - float(se["x"])) < 1e-6 and absf(float(humm[i]["z"]) - float(se["z"])) < 1e-6)
	check(spot_ok and near(float(se["ms"]), float(M["surface"]["windupMs"][0])) and near(float(se["r"]), float(M["surface"]["r"])), "ripple ring over one of the %d hummocks, %d ms, radius %.1f" % [spots.size(), int(M["surface"]["windupMs"][0]), float(M["surface"]["r"])])
	check(absf(float(boss.brain._surface_cd) - float(M["surface"]["cd"][0])) < 0.1, "surface cooldown %.0f s" % float(M["surface"]["cd"][0]))
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
	step(windup1 - 0.1)
	check(impacts("surface").is_empty() and boss.brain.state["state"] == "sunk", "still under before the ring is full")
	step(0.2)
	var si := impacts("surface")
	check(si.size() == 1 and absf(float(si[0]["t"]) - float(sf2[sf2.size() - 1]["t"]) - windup1) < 0.03, "she erupts %.1f s after the ring appears" % windup1)
	check(hurt_n(nh, float(M["surface"]["dmg"])).size() == 1, "whoever stayed on the hummock takes %d x scale" % int(M["surface"]["dmg"]))
	check(boss.brain.state["state"] == "idle" and boss.is_hittable() and boss.brain.stagger_t > winded - 0.4 and boss.brain.stagger_t <= winded, "surfaced: hittable again and winded for %.1f s (%.2f)" % [winded, boss.brain.stagger_t])
	await ticks(2)
	check(host.enemy_alive(boss.core_id) and boss.core_id in host.enemies_in_radius(boss.global_position, 1.0), "(and the core's external is alive again)")
	check(boss.take_damage(500.0, hb) and boss.hp < hp0, "winded she can be hit")
	# winded: nothing happens until it ends
	boss.brain._maul_cd = 0.0
	put(boss.global_position + Vector3(minf(3.0, float(M["maul"]["r"]) * 0.8), 0.0, 0.0))
	var nm := telegraphs("maul").size()
	step(winded - 0.8)
	check(telegraphs("maul").size() == nm, "no attack while she is winded")
	step(1.2)
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
	step(windup1 + 0.1)
	check(hurt_n(nh, float(M["surface"]["dmg"])).is_empty(), "stepping off the hummock dodges the eruption")
	check(boss.brain.state["state"] != "sunk" and boss.is_hittable(), "surfaced again (%s)" % boss.brain.state["state"])
	# ---- phase 2: flood, tighter timings
	quiet()
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp - boss.max_hp * just_into(2), hb)
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1, "phase 2")
	var p2: Array = M["adds"]["p2"]
	var rim_r := float(def()["arena"]["r"]) * MIRE_RIM
	var fl := events("flood")
	check(fl.size() == 1 and int(fl[0]["ev"]["phase"]) == 2 and fl[0]["ev"]["targets"].size() == p2.size(), "the marsh floods (event phase 2, %d spots)" % p2.size())
	check(fl[0]["ev"]["targets"].all(func(t: Array) -> bool: return absf(Vector2(float(t[0]) - arena().x, float(t[1]) - arena().z).length() - rim_r) < 0.01), "the wave's spots lie on the rim")
	var wave2 := adds()
	check(wave2.size() == p2.size() and adds("mire_leech").size() == wave_count("mire_leech", "p2"), "P2 calls its %d bodies (core bodies)" % p2.size())
	check(wave2.all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "fen" and absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(arena().x, arena().z)) - rim_r) < 0.01), "on the arena rim, counted as Fen enemies")
	clear_adds()
	var flood2 := float(DmContent.get_export("fen", "FEN_FLOOD_SCALE")["2"])
	check(near(float(boss.brain._flood_scale(2)), flood2) and not Geom.on_hummock(hb.position.x, hb.position.z, flood2), "the hummocks shrink to %.2f: the hero's old dry spot is now water" % flood2)
	quiet(1.0e9, 0.0)
	boss.world.refresh()
	step(0.05)
	var hd3 := telegraphs("hands")
	var h3: Dictionary = hd3[hd3.size() - 1]["ev"]
	check(absf(float(h3["targets"][0][0]) - hb.position.x) < 1e-6 and absf(float(boss.brain._hands_cd) - float(M["hands"]["cd"][1])) < 0.1, "in the flood the hands reach the hero, cooldown %.1f s" % float(M["hands"]["cd"][1]))
	quiet(1.0e9, 1.0e9, 0.0)
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	step(0.02)
	var sf4 := telegraphs("surface")
	check(near(float(sf4[sf4.size() - 1]["ev"]["ms"]), float(M["surface"]["windupMs"][1])) and absf(float(boss.brain._surface_cd) - float(M["surface"]["cd"][1])) < 0.1, "P2 surface %d ms, cooldown %.0f s" % [int(M["surface"]["windupMs"][1]), float(M["surface"]["cd"][1])])
	quiet()
	boss.brain.state["x"] = arena().x
	boss.brain.state["z"] = arena().z
	# ---- phase 3: the Drowned Rite
	boss.take_damage(boss.hp - boss.max_hp * just_into(3), hb)
	step(0.1)
	var p3: Array = M["adds"]["p3"]
	check(boss.phase == 3 and events("flood").size() == 2 and int(events("flood")[1]["ev"]["phase"]) == 3, "phase 3, the flood deepens")
	check(adds("bog_hag").size() == wave_count("bog_hag", "p3") and adds("mire_leech").size() == wave_count("mire_leech", "p3") and adds().size() == p3.size() and events("flood")[1]["ev"]["targets"].size() == p3.size(), "P3 calls its %d bodies (core bodies, their spots told)" % p3.size())
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
	var rite_s := float(M["rite"]["windupMs"]) / 1000.0
	var nr := telegraphs("rite").size()
	step(0.05)
	var rt1 := telegraphs("rite")
	check(rt1.size() == nr + 1, "the Drowned Rite is telegraphed")
	var re: Dictionary = rt1[rt1.size() - 1]["ev"]
	check(near(float(re["ms"]), float(M["rite"]["windupMs"])) and re["targets"].size() == 3, "rite %d ms, a beam to each of the 3 corpses in the Fen" % int(M["rite"]["windupMs"]))
	check(absf(float(boss.brain._rite_cd) - float(M["rite"]["cd"]) * float(FAST[2])) < 0.15, "rite cooldown %d x %.1f s" % [int(M["rite"]["cd"]), float(FAST[2])])
	check(host.corpses.consume(ids[0], me, "litany"), "the player claims a corpse before the rite lands")
	step(rite_s + 0.1)
	var rim := impacts("rite")
	check(rim.size() == 1 and rim[0]["ev"]["targets"].size() == 2 and absf(float(rim[0]["t"]) - float(rt1[rt1.size() - 1]["t"]) - rite_s) < 0.03, "the rite raises only what is left (2 of 3) %.1f s later" % rite_s)
	check(adds("risen").size() == 2 and fen_corpses() == 0, "2 Risen stand where the corpses lay (core bodies), the Fen is empty")
	check(adds("risen").all(func(id: int) -> bool: return core.enemy_info(id)["area"] == "fen"), "(counted as Fen enemies)")
	check(host.corpses.corpses_in_radius(Vector3(-14.0, 0.0, -22.0), 5.0, Callable(), "graves").size() == 1, "a corpse in another area is untouched")
	check(boss.brain.stagger_t == 0.0, "a rite that finds the dead does not stagger her")
	clear_adds()
	await ticks(2)
	# more corpses than she can take: the nearest are raised
	var max_c := int(M["rite"]["maxCorpses"])
	var laid := max_c + 3
	for i in laid:
		lay(arena().x - 8.0 + float(i) * 2.0, arena().z + 1.0 + float(i) * 0.5)
	quiet()
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	step(0.05)
	var rt2 := telegraphs("rite")
	check(rt2[rt2.size() - 1]["ev"]["targets"].size() == max_c, "at most %d corpses are drawn into the rite" % max_c)
	step(rite_s + 0.1)
	check(adds("risen").size() == max_c and fen_corpses() == laid - max_c, "%d Risen, the %d farthest corpses remain" % [max_c, laid - max_c])
	clear_adds()
	for id in core.corpse_ids():
		host.corpses.consume(int(id), 0, "consumed")
	await ticks(2)
	# starve the rite: she staggers
	quiet()
	boss.brain._rite_cd = 0.0
	boss.world.refresh()
	step(0.05)
	step(rite_s + 0.1)
	var rfail := impacts("rite")
	var fail_s := float(M["rite"]["failStaggerS"])
	check(rfail.size() == 3 and rfail[2]["ev"]["targets"].is_empty(), "no corpses at all: the rite fails")
	check(boss.brain.stagger_t > fail_s - 0.3 and boss.brain.stagger_t <= fail_s and adds("risen").is_empty(), "starved, she reels for %.0f s (%.2f)" % [fail_s, boss.brain.stagger_t])
	await dismiss()
