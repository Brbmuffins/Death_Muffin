extends "res://tests/rites/signature_part.gd"
## The Reaper (class index 11, family "reaper"): the class wiring, green energy, the soul bag and its six rites (scythe_sweep, scythe_throw, reap,
## wraith_walk, soul_burst, harvest_spin). Reuses the signature part's doubles (solo session, fake world, recording fx); the host is stepped by hand.
## godot --headless --path godot --script res://tests/rites/run.gd

const REAPER := 11


func _initialize() -> void:
	DmSimData.ensure()
	await _wiring()
	await _rites()
	print("reaper: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Damage a robber has taken.
func _lost(e: DmEnemy, hp := 1.0e7) -> float:
	return hp - e.hp


func _slots() -> Array:
	var out: Array = []
	for i in range(1, 5):
		out.append(DmRiteHotbar.rite_for_slot(i, "reaper"))
	return out


# ---- the class: data, resources, kit, playable ---------------------------------------------------------------------------------------------

func _wiring() -> void:
	var d := DmCharacterBuild.discipline_for(float(REAPER))
	ok(d["id"] == "reaper" and d["family"] == "reaper", "wiring: class index 11 is the Reaper (family reaper); 10 still plays as the fallback")
	ok(DmCharacterBuild.discipline_for(10.0)["id"] == "gravecaller", "wiring: the unknown class index 10 still falls back to the Gravecaller (golden fixtures)")
	ok(DmCharacterBuild.is_playable(float(REAPER)) and DmCharacterBuild.is_playable(2.0) and not DmCharacterBuild.is_playable(9.0), "wiring: the Reaper is playable, the Veilwalker still is not")
	var pd: Array = DmContent.get_export("disciplines", "PLAYABLE_DISCIPLINES").filter(func(x: Dictionary) -> bool: return x["id"] == "reaper")
	ok(pd.size() == 1 and int(pd[0]["classIndex"]) == REAPER, "wiring: the Reaper has a discipline card")
	ok(DmResources.kind_for("reaper") == "reaper" and DmResources.label_for("reaper") == "Reaper Energy" and DmResources.color_for("reaper") == "#6ee7a0", "wiring: green Reaper Energy")
	var st: Dictionary = DmCharacterBuild.build({"class_index": REAPER, "level": 5}, [], {})["stats"]
	var p := DmPlayerRules.new_state(st, "reaper")
	ok(float(p["resource"]["max"]) == 100.0 and float(p["resource"]["value"]) == 100.0 and p["resource"]["kind"] == "reaper", "wiring: energy starts full at 100")
	p["resource"]["value"] = 40.0
	DmPlayerRules.tick_vitals(p, 1.0, 1000.0)
	ok(is_equal_approx(float(p["resource"]["value"]), 50.0), "wiring: energy refills 10 a second (%.1f)" % p["resource"]["value"])
	var base_speed := DmPlayerRules.move_speed(DmPlayerRules.new_state(st, "necromancer"), 0.0)
	ok(is_equal_approx(DmPlayerRules.move_speed(p, 0.0), base_speed * 1.1), "wiring: the Reaper runs 10% faster")
	# the soul bag
	p["soulsMax"] = 30.0
	var sp0 := DmAbilities.sp(p, 0.0)
	ok(DmPlayerRules.bag_add(p, 5) == 5 and p["souls"] == 5, "wiring: five souls bank")
	ok(DmPlayerRules.bag_add(p, 40) == 25 and p["souls"] == 30, "wiring: the bag holds 30 and refuses the rest")
	ok(is_equal_approx(DmAbilities.sp(p, 0.0), sp0 * 1.6), "wiring: a full bag adds 60%% damage (+2%% a soul): %.2f vs %.2f" % [DmAbilities.sp(p, 0.0), sp0])
	ok(DmPlayerRules.bag_spend(p, 10) == 10 and p["souls"] == 20 and DmPlayerRules.bag_spend(p, 99) == 20 and p["souls"] == 0, "wiring: spending takes at most what is there")
	# the kit
	var kit: Dictionary = DmContent.kit("reaper")
	ok(DmAbilities.kit_for("reaper")["defaultPrimary"] == "scythe_sweep" and kit["defaultPrimary"] == "scythe_sweep", "wiring: LMB is Scythe Sweep (both kit copies)")
	var names := ["scythe_throw", "reap", "wraith_walk", "soul_burst"]
	ok(_slots() == names, "wiring: keys 1-4 are throw, reap, wraith walk, soul burst %s" % [_slots()])
	ok(DmRiteHotbar.rite_for_slot(5, "reaper") == "harvest_spin" and DmRiteHotbar.rite_for_slot(6, "reaper", "reaper") == "", "wiring: RMB is Harvest Spin, no signature yet")
	for id in names + ["scythe_sweep", "harvest_spin"]:
		ok(DmRiteRegistry.has(id) and DmRiteGestures.has(id) and String(DmAbilities.def(id)["icon"]) != "" and DmContent.get_export("codex", "CODEX_RITES").has(id), "wiring: %s has a module, a gesture, an icon and a Codex entry" % id)
	var sl := DmLoadout.sanitize_loadout(null, 1.0, DmAbilities.kit_for("reaper"))
	ok(sl.size() == 5 and not sl.has(null) and sl.find("harvest_spin") == 4, "wiring: the default loadout fills all five slots")
	ok(DmContent.get_export("codex", "CODEX_DISCIPLINES").has("reaper"), "wiring: the Reaper has a Codex entry")


# ---- the rites ----------------------------------------------------------------------------------------------------------------------------

func _rites() -> void:
	var s := await _solo("RP", REAPER)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var body: DmSessionBody = s["body"]   # the plain session body: the caster keeps its own vitals (no DmHeroBody here)
	ok(c.p["family"] == "reaper" and c.p["resource"]["kind"] == "reaper", "rites: the caster is built for the reaper family")
	var rej := _rejects(c)

	# Scythe Sweep: the arc hits in front, not behind; free
	var front := _robber(w, h, Vector3(2.5, 0, 0))
	var behind := _robber(w, h, Vector3(-2.5, 0, 0))
	var wide := _robber(w, h, Vector3(0.5, 0, 3.2))   # 81 degrees off the aim: outside the 65 degree half angle
	_ready_cast(c)
	var e0: float = c.essence()
	c.request_cast("scythe_sweep", Vector3(6, 0, 0))
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), "scythe_sweep")
	ok(is_equal_approx(_lost(front), dmg) and _lost(behind) == 0.0 and _lost(wide) == 0.0, "sweep: hits the enemy in front (%.1f of %.1f), not the one behind or off to the side" % [_lost(front), dmg])
	ok(is_equal_approx(e0 - c.essence(), 0.0) and is_equal_approx(c.cooldown_left("scythe_sweep"), 600.0), "sweep: free, 0.6 s")
	ok(not _events(w, "scythe_sweep", "sweep").is_empty() and rej.is_empty(), "sweep: one event, no refusal")
	_ready_cast(c)
	c.request_cast("scythe_sweep", Vector3(0, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "no_target", "sweep: refused with the cursor on her")
	rej.clear()

	# Harvest Spin: a full circle, 16 energy
	_ready_cast(c)
	var before_b := _lost(behind)
	var e1: float = c.essence()
	c.request_cast("harvest_spin", Vector3(5, 0, 0))
	ok(_lost(behind) > before_b and _lost(wide) > 0.0, "spin: hits all round her, including behind")
	ok(is_equal_approx(e1 - c.essence(), 16.0) and is_equal_approx(c.cooldown_left("harvest_spin"), 3500.0), "spin: 16 energy, 3.5 s")

	# Reap: a cone, spends souls, bigger with them
	_ready_cast(c)
	var r1 := _robber(w, h, Vector3(5.0, 0, 0.5))
	c.p["souls"] = 0
	c.request_cast("reap", Vector3(8, 0, 0))
	var plain := _lost(r1)
	ok(plain > 0.0 and is_equal_approx(c.cooldown_left("reap"), 6000.0), "reap: hits 5 m out (%.1f), 6 s" % plain)
	_ready_cast(c)
	c.p["souls"] = 10
	var sp_with := DmAbilities.sp(c.p, c.now_ms)
	c.request_cast("reap", Vector3(8, 0, 0))
	var second := _lost(r1) - plain
	ok(int(c.p["souls"]) == 0, "reap: spends the 10 souls")
	ok(is_equal_approx(second, DmAbilities.rite_damage(sp_with, "reap") * (1.0 + 0.12 * 10.0)) and second > plain * 1.5, "reap: 10 souls hit %.1f against %.1f with none" % [second, plain])

	# Soul Burst: empties the bag
	_ready_cast(c)
	c.p["souls"] = 7
	var sp7 := DmAbilities.sp(c.p, c.now_ms)
	var rb := _robber(w, h, Vector3(0, 0, 5.5))
	c.request_cast("soul_burst", Vector3(0, 0, 0))
	ok(int(c.p["souls"]) == 0 and _lost(rb) > 0.0, "burst: empties the bag and hits 5.5 m out")
	ok(is_equal_approx(_lost(rb), DmAbilities.rite_damage(sp7, "soul_burst") * (1.0 + 0.18 * 7.0)), "burst: 7 souls add 126%% to the base blow (%.1f)" % _lost(rb))

	# Scythe Throw: spins in place, damaging every quarter second for 2 s, only inside 2.6 m
	_ready_cast(c)
	var spot := Vector3(0, 0, -9)
	var inside := _robber(w, h, spot + Vector3(1.5, 0, 0))
	var outside := _robber(w, h, spot + Vector3(5.0, 0, 0))
	var e2: float = c.essence()
	c.request_cast("scythe_throw", spot)
	ok(is_equal_approx(e2 - c.essence(), 22.0) and is_equal_approx(c.cooldown_left("scythe_throw"), 7000.0), "throw: 22 energy, 7 s")
	_step(c, 2.6)
	var ticks := _events(w, "scythe_throw", "tick").size()
	ok(ticks >= 7 and ticks <= 8, "throw: about 8 ticks over 2 s (%d)" % ticks)
	ok(_lost(inside) > 0.0 and _lost(outside) == 0.0, "throw: cuts the enemy inside the ring, not the one outside")
	var after := _lost(inside)
	_step(c, 1.0)
	ok(_lost(inside) == after, "throw: the scythe is gone after 2 s")
	_ready_cast(c)
	w.events.clear()
	c.request_cast("scythe_throw", Vector3(0, 0, -40))
	var cast_ev: Dictionary = _events(w, "scythe_throw", "throw")[0]
	ok(is_equal_approx(float(cast_ev["z"]), -12.0), "throw: an aim past 12 m lands at 12 m (z %.1f)" % cast_ev["z"])

	# Wraith Walk: the enemies in the lane are cursed, the others not; the body dashes
	_ready_cast(c)
	body.teleport(Vector3.ZERO)
	c.p["x"] = 0.0
	c.p["z"] = 0.0
	var lane_a := _robber(w, h, Vector3(4, 0, 0.5))
	var lane_b := _robber(w, h, Vector3(7, 0, -1.0))
	var off_lane := _robber(w, h, Vector3(4, 0, 4.0))
	c.p["souls"] = 8
	var e3: float = c.essence()
	c.request_cast("wraith_walk", Vector3(20, 0, 0))
	var evs := _events(w, "wraith_walk", "walk")
	ok(evs.size() == 1, "walk: one event")
	var ev: Dictionary = evs[0]
	ok(is_equal_approx(e3 - c.essence(), 30.0) and is_equal_approx(c.cooldown_left("wraith_walk"), 11000.0) and int(c.p["souls"]) == 0, "walk: 30 energy, 11 s, spends the 8 souls")
	ok(Vector2(float(ev["tx"]) - float(ev["fx"]), float(ev["tz"]) - float(ev["fz"])).length() <= 9.01 and body.dashing, "walk: dashes at most 9 m and the body glides")
	var sa := DmStatusSet.of(lane_a)
	var sb := DmStatusSet.of(lane_b)
	ok(sa != null and sa.has(&"bleed") and sb != null and sb.has(&"bleed"), "walk: both enemies in the lane are cursed")
	ok(DmStatusSet.of(off_lane) == null or not DmStatusSet.of(off_lane).has(&"bleed"), "walk: the one off the lane is not")
	_step(c, 5.5)
	ok(_lost(lane_a) > 0.0 and _lost(lane_b) > 0.0 and _lost(off_lane) == 0.0, "walk: the curse burns as a damage-over-time (%.0f)" % _lost(lane_a))
	rej.clear()
	_ready_cast(c)
	body.dashing = false
	c.request_cast("wraith_walk", Vector3(c.p["x"], 0, c.p["z"]))
	ok(rej.size() == 1 and rej[0][1] == "no_target", "walk: a cursor on her makes no dash")

	# not enough energy
	_ready_cast(c)
	c.p["resource"]["value"] = 10.0
	rej.clear()
	c.request_cast("reap", Vector3(8, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "essence", "reap: refused below 35 energy")

	await _teardown(s)
