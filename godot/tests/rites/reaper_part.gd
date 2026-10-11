extends "res://tests/rites/signature_part.gd"
## The Reaper (class index 11, family "reaper"): the class wiring, the soul bag (her only resource) and its six rites (scythe_sweep, scythe_throw, reap,
## wraith_walk, soul_burst, harvest_spin). Reuses the signature part's doubles (solo session, fake world, recording fx); the host is stepped by hand.
## godot --headless --path godot --script res://tests/rites/run.gd

const REAPER := 11


func _initialize() -> void:
	DmSimData.ensure()
	await _wiring()
	await _rites()
	print("reaper: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Ready to cast, with a full bag (her souls are her resource).
func _ready_cast(c: DmRiteCaster) -> void:
	super._ready_cast(c)
	c.p["souls"] = 30


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
	ok(DmResources.kind_for("reaper") == "reaper" and DmResources.label_for("reaper") == "Soul Bag" and DmResources.color_for("reaper") == "#6ee7a0", "wiring: the green resource is the Soul Bag")
	var st: Dictionary = DmCharacterBuild.build({"class_index": REAPER, "level": 5}, [], {})["stats"]
	var p := DmPlayerRules.new_state(st, "reaper")
	ok(int(p["souls"]) == 10 and p["resource"]["kind"] == "reaper", "wiring: she starts with 10 souls in the bag")
	p["resource"]["value"] = 40.0
	DmPlayerRules.tick_vitals(p, 1.0, 1000.0)
	ok(is_equal_approx(float(p["resource"]["value"]), 40.0) and int(p["souls"]) == 10, "wiring: no energy refills on its own, souls only come from kills")
	p["alive"] = false
	p["souls"] = 2
	DmPlayerRules.revive(p)
	ok(int(p["souls"]) == 10, "wiring: coming back from the dead refills a poor bag to 10 souls")
	p["souls"] = 0
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
	# built to stand in the pack: more health, a share of every blow shrugged off, nothing lands during Wraith Walk's rush
	var mst: Dictionary = DmCharacterBuild.build({"class_index": 3, "level": 5}, [], {})["stats"]
	ok(absf(float(st["maxHp"]) / float(mst["maxHp"]) - 1.3) < 0.02, "survival: 30%% more health than a Mourner (%.0f vs %.0f)" % [st["maxHp"], mst["maxHp"]])
	var rp := DmPlayerRules.new_state(st, "reaper")
	var np := DmPlayerRules.new_state(st, "necromancer")
	var rt := DmPlayerRules.take_damage(rp, 100.0, 0.0, 1000.0)
	var nt := DmPlayerRules.take_damage(np, 100.0, 0.0, 1000.0)
	ok(is_equal_approx(rt, nt * 0.85), "survival: she takes 15%% less from a blow (%.1f vs %.1f)" % [rt, nt])
	rp["phasedUntil"] = 2000.0
	ok(DmPlayerRules.take_damage(rp, 100.0, 0.0, 1500.0) == 0.0 and DmPlayerRules.take_damage(rp, 100.0, 0.0, 2000.0) > 0.0, "survival: untouchable until phasedUntil, hit again after")


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
	var s0 := int(c.p["souls"])
	c.request_cast("scythe_sweep", Vector3(6, 0, 0))
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), "scythe_sweep")
	ok(is_equal_approx(_lost(front), dmg) and _lost(behind) == 0.0 and _lost(wide) == 0.0, "sweep: hits the enemy in front (%.1f of %.1f), not the one behind or off to the side" % [_lost(front), dmg])
	ok(int(c.p["souls"]) == s0 and is_equal_approx(c.cooldown_left("scythe_sweep"), 600.0), "sweep: costs no souls, 0.6 s")
	_ready_cast(c)
	c.p["souls"] = 0
	c.request_cast("scythe_sweep", Vector3(6, 0, 0))
	ok(rej.is_empty() and c.cooldown_left("scythe_sweep") > 0.0, "sweep: swings with an empty bag")
	ok(not _events(w, "scythe_sweep", "sweep").is_empty() and rej.is_empty(), "sweep: one event, no refusal")
	_ready_cast(c)
	c.request_cast("scythe_sweep", Vector3(0, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "no_target", "sweep: refused with the cursor on her")
	rej.clear()

	# Harvest Spin: a full circle, 2 souls
	_ready_cast(c)
	var before_b := _lost(behind)
	c.request_cast("harvest_spin", Vector3(5, 0, 0))
	ok(_lost(behind) > before_b and _lost(wide) > 0.0, "spin: hits all round her, including behind")
	ok(int(c.p["souls"]) == 28 and is_equal_approx(c.cooldown_left("harvest_spin"), 3500.0), "spin: 2 souls, 3.5 s")

	# Reap: a cone, costs 5 souls, every soul paid adds damage
	_ready_cast(c)
	var r1 := _robber(w, h, Vector3(5.0, 0, 0.5))
	c.p["souls"] = 4
	rej.clear()
	c.request_cast("reap", Vector3(8, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "souls" and int(c.p["souls"]) == 4 and _lost(r1) == 0.0, "reap: refused with 4 souls, nothing spent")
	rej.clear()
	c.p["souls"] = 0
	var sp_empty := DmAbilities.sp(c.p, c.now_ms)   # what is left in the bag once the price is paid
	c.p["souls"] = 5
	c.request_cast("reap", Vector3(8, 0, 0))
	var plain := _lost(r1)
	ok(int(c.p["souls"]) == 0 and plain > 0.0 and is_equal_approx(c.cooldown_left("reap"), 6000.0), "reap: 5 souls pay for it, hits 5 m out (%.1f), 6 s" % plain)
	ok(is_equal_approx(plain, DmAbilities.rite_damage(sp_empty, "reap") * (1.0 + 0.12 * 5.0)), "reap: the 5 souls paid add 60%% damage")
	_ready_cast(c)
	c.p["souls"] = 5
	var sp_five := DmAbilities.sp(c.p, c.now_ms)
	c.p["souls"] = 10
	c.request_cast("reap", Vector3(8, 0, 0))
	var second := _lost(r1) - plain
	ok(int(c.p["souls"]) == 5, "reap: 10 souls in the bag leave 5")
	ok(is_equal_approx(second, DmAbilities.rite_damage(sp_five, "reap") * (1.0 + 0.12 * 5.0)) and second > plain, "reap: a fuller bag hits harder (%.1f against %.1f)" % [second, plain])

	# Soul Burst: needs 6 souls, empties the bag
	_ready_cast(c)
	c.p["souls"] = 5
	var rb := _robber(w, h, Vector3(0, 0, 5.5))
	rej.clear()
	c.request_cast("soul_burst", Vector3(0, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "souls" and int(c.p["souls"]) == 5 and _lost(rb) == 0.0, "burst: refused with 5 souls")
	rej.clear()
	c.p["souls"] = 1
	var sp1 := DmAbilities.sp(c.p, c.now_ms)   # one soul left once the price is paid
	c.p["souls"] = 7
	c.request_cast("soul_burst", Vector3(0, 0, 0))
	ok(int(c.p["souls"]) == 0 and _lost(rb) > 0.0, "burst: empties the bag and hits 5.5 m out")
	ok(is_equal_approx(_lost(rb), DmAbilities.rite_damage(sp1, "soul_burst") * (1.0 + 0.18 * 7.0)), "burst: 7 souls add 126%% to the base blow (%.1f)" % _lost(rb))

	# Scythe Throw: spins in place, damaging every quarter second for 2 s, only inside 2.6 m
	_ready_cast(c)
	var spot := Vector3(0, 0, -9)
	var inside := _robber(w, h, spot + Vector3(1.5, 0, 0))
	var outside := _robber(w, h, spot + Vector3(5.0, 0, 0))
	c.request_cast("scythe_throw", spot)
	ok(int(c.p["souls"]) == 27 and is_equal_approx(c.cooldown_left("scythe_throw"), 7000.0), "throw: 3 souls, 7 s")
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
	var cast_at := c.now_ms
	c.request_cast("wraith_walk", Vector3(20, 0, 0))
	ok(is_equal_approx(float(c.p["phasedUntil"]), cast_at + 320.0), "walk: untouchable for the 0.32 s rush")
	var evs := _events(w, "wraith_walk", "walk")
	ok(evs.size() == 1, "walk: one event")
	var ev: Dictionary = evs[0]
	ok(is_equal_approx(c.cooldown_left("wraith_walk"), 11000.0) and int(c.p["souls"]) == 4, "walk: 4 souls (8 become 4), 11 s")
	ok(Vector2(float(ev["tx"]) - float(ev["fx"]), float(ev["tz"]) - float(ev["fz"])).length() <= 9.01 and body.dashing, "walk: dashes at most 9 m and the body glides")
	var sa := DmStatusSet.of(lane_a)
	var sb := DmStatusSet.of(lane_b)
	ok(sa != null and sa.has(&"wraithfire") and sb != null and sb.has(&"wraithfire"), "walk: both enemies in the lane are set alight")
	ok(DmStatusSet.of(off_lane) == null or not DmStatusSet.of(off_lane).has(&"wraithfire"), "walk: the one off the lane is not")
	_step(c, 5.5)
	ok(_lost(lane_a) > 0.0 and _lost(lane_b) > 0.0 and _lost(off_lane) == 0.0, "walk: the green flame burns as a damage-over-time (%.0f)" % _lost(lane_a))
	rej.clear()
	_ready_cast(c)
	body.dashing = false
	c.request_cast("wraith_walk", Vector3(c.p["x"], 0, c.p["z"]))
	ok(rej.size() == 1 and rej[0][1] == "no_target", "walk: a cursor on her makes no dash")


	# life steal: each enemy a swing strikes heals 1.5% of her health, at most 6% a swing; the thrown scythe heals nothing
	var mx := float(c.p["stats"]["maxHp"])
	_ready_cast(c)
	c.p["hp"] = mx * 0.5
	var lone := _robber(w, h, Vector3(0, 0, 30))
	body.teleport(Vector3(0, 0, 28))
	c.p["x"] = 0.0
	c.p["z"] = 28.0
	c.request_cast("scythe_sweep", Vector3(0, 0, 34))
	ok(_lost(lone) > 0.0 and is_equal_approx(float(c.p["hp"]), mx * 0.515), "leech: one enemy struck heals 1.5%% (%.1f of %.1f)" % [c.p["hp"], mx])
	for i in 6:
		_robber(w, h, Vector3(1.5 * cos(i), 0, 28.0 + 1.5 * sin(i)))
	_ready_cast(c)
	c.p["hp"] = mx * 0.5
	c.request_cast("harvest_spin", Vector3(0, 0, 34))
	ok(is_equal_approx(float(c.p["hp"]), mx * 0.56), "leech: a spin through 7 enemies heals the 6%% cap (%.1f)" % c.p["hp"])
	_ready_cast(c)
	c.p["hp"] = mx * 0.5
	c.request_cast("scythe_throw", Vector3(0, 0, 30))
	_step(c, 2.6)
	ok(is_equal_approx(float(c.p["hp"]), mx * 0.5), "leech: the thrown scythe heals nothing (%.1f)" % c.p["hp"])

	# every rite but the sweep needs its souls, and energy no longer matters
	for pair: Array in [["scythe_throw", 3], ["wraith_walk", 4], ["harvest_spin", 2]]:
		_ready_cast(c)
		c.p["souls"] = int(pair[1]) - 1
		c.p["resource"]["value"] = 100.0
		rej.clear()
		c.request_cast(String(pair[0]), Vector3(8, 0, 0))
		ok(rej.size() == 1 and rej[0][1] == "souls" and int(c.p["souls"]) == int(pair[1]) - 1, "%s: refused one soul short" % pair[0])
	_ready_cast(c)
	c.p["resource"]["value"] = 0.0
	rej.clear()
	c.request_cast("scythe_sweep", Vector3(8, 0, 0))
	ok(rej.is_empty(), "sweep: needs neither energy nor souls")

	await _teardown(s)
