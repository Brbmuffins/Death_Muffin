extends SceneTree
## Golden-fixture runner for godot/rules/combat.
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/rules-combat/run.gd
## Fixtures: committed golden files, generated from the retired web game (the generators were removed 2026-10-09).
## Each fixture file is {fn, cases:[{in, out}]}; HANDLERS maps fn -> a method here taking the case input and returning the expected output.

const DIR := "res://tests/rules-combat/fixtures/"
var passed := 0
var failed := 0
var per_file: Dictionary = {}
var _shown := 0


func _initialize() -> void:
	var dir := DirAccess.open(DIR)
	if dir == null or not FileAccess.file_exists(DIR + "build.json"):
		print("fixtures missing: they are committed in git (restore with git checkout)")
		quit(1)
		return
	var names: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".json"):
			names.append(f.get_basename())
	names.sort()
	for n in names:
		run_file(n)
	var total := passed + failed
	print("--- rules-combat: %d / %d passed, %d failed ---" % [passed, total, failed])
	for k in per_file:
		print("  %-24s %s" % [k, per_file[k]])
	quit(0 if failed == 0 else 1)


func eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		var x := float(a)
		var y := float(b)
		return absf(x - y) <= 1e-9 or absf(x - y) <= 1e-12 * maxf(absf(x), absf(y))
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not eq(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not eq(a[k], b[k]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


## First differing path, for the failure message.
func diff(a: Variant, b: Variant, path: String = "") -> String:
	if (a is int or a is float) and (b is int or b is float):
		return "" if eq(a, b) else "%s: got %s want %s" % [path, a, b]
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: array size got %d want %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a is Dictionary and b is Dictionary:
		for k in b:
			if not a.has(k):
				return "%s.%s: missing in got" % [path, k]
			var d := diff(a[k], b[k], "%s.%s" % [path, k])
			if d != "":
				return d
		for k in a:
			if not b.has(k):
				return "%s.%s: unexpected in got" % [path, k]
		return ""
	return "" if (typeof(a) == typeof(b) and a == b) else "%s: got %s (%s) want %s (%s)" % [path, a, type_string(typeof(a)), b, type_string(typeof(b))]


func run_file(name: String) -> void:
	var text := FileAccess.get_file_as_string(DIR + name + ".json")
	var fx: Dictionary = JSON.parse_string(text)
	var fn: String = fx["fn"]
	if not has_method("h_" + fn):
		print("no handler for ", fn)
		failed += 1
		per_file[name] = "NO HANDLER"
		return
	var ok := 0
	var cases: Array = fx["cases"]
	for i in cases.size():
		var got: Variant = call("h_" + fn, cases[i]["in"])
		var d := diff(got, cases[i]["out"])
		if d == "":
			ok += 1
			passed += 1
		else:
			failed += 1
			if _shown < 40:
				_shown += 1
				print(("FAIL %s #%d  %s" % [name, i, d]).substr(0, 300))
	per_file[name] = "%d / %d" % [ok, cases.size()]


func strip(mods: Dictionary) -> Dictionary:
	return DmSetBonuses.strip_applied(mods)


# --------------------------------------------------------------------------------------------------------------------
func h_build(i: Dictionary) -> Variant:
	var r := DmCharacterBuild.build(i["character"], i["slots"], i["local"])
	return {"mods": strip(r["discipline"]["mods"]), "stats": r["stats"], "loadout": r["loadout"], "legion": r["legion"], "boons": r["boons"], "vows": r["vows"]}


func h_with_set_bonuses(i: Dictionary) -> Variant:
	var c: Dictionary = i["character"]
	var d0 := DmCharacterBuild.discipline_for(float(c["class_index"]))
	var d := d0
	if i["pre"]:
		d = d0.duplicate()
		d["mods"] = DmSetBonuses.apply_set_mods(d0["mods"], DmSetBonuses.resolve(i["slotsA"])["totals"])
	var d1 := DmSetBonuses.with_set_bonuses(d, i["slotsB"])
	return {
		"mods": strip(d1["mods"]), "stats": DmStats.derive_stats(c, i["slotsB"], d1, float(i["tier"])),
		"computed": DmStats.compute_stats(c, i["slotsB"]), "bare": strip(DmSetBonuses.without_set_bonuses(d1)["mods"]), "resolvedEq": is_same(d1, d),
	}


func h_set_bonuses(i: Dictionary) -> Variant:
	var r := DmSetBonuses.resolve(i["a"])
	var active: Array = []
	for b in r["active"]:
		active.append({"setId": b["setId"], "pieces": b["pieces"]})
	var sets: Array = []
	for s in r["sets"]:
		sets.append({"setId": s["setId"], "worn": s["worn"], "wornParts": s["wornParts"], "next": s["next"]})
	var roll: Dictionary = i["roll"]
	return {
		"totals": r["totals"], "setTotals": r["setTotals"], "affixTotals": r["affixTotals"], "active": active, "sets": sets,
		"setSig": DmSetBonuses.set_signature(i["a"]), "outfitSig": DmSetBonuses.outfit_signature(i["a"]), "affixSig": DmAffixTotals.affix_signature(i["a"]),
		"diff": DmSetBonuses.diff_set_bonuses(i["a"], i["b"], i["fam"]),
		"relevant": DmSetBonuses.effect_relevant(DmAffixTotals.effect(roll), i["fam"]),
		"wornAffix": DmAffixTotals.worn_affix_totals(i["a"]),
		"fold": strip(DmSetBonuses.fold_effect(DmCharacterBuild.discipline_for(1.0)["mods"], DmAffixTotals.effect(roll))),
	}


func h_weapon_line(i: Dictionary) -> Variant:
	var l := DmWeaponLine.resolve(i["worn"], i["disc"])
	var id: String = i["id"]
	var d := DmAbilities.def(id)
	return {
		"l": l, "range": DmWeaponLine.ability_range(id, d["range"], l, false), "rangeBoss": DmWeaponLine.ability_range(id, d["range"], l, true),
		"cd": DmWeaponLine.ability_cooldown_ms(id, d["cooldownMs"], l, false), "cdP": DmWeaponLine.ability_cooldown_ms(id, d["cooldownMs"], l, true),
		"lock": DmWeaponLine.ability_lock_ms(id, DmAbilities.cast_flow(id)["lockMs"], l),
	}


func _ids(a: Array) -> Array:
	var out: Array = []
	for e in a:
		out.append(e["id"])
	return out


func h_weapon_geometry(i: Dictionary) -> Variant:
	var reach: float = -1.0 if i["reach"] == null else float(i["reach"])
	return {
		"reap": _ids(DmWeaponLine.reap_targets(i["caster"], i["aim"], i["foes"], reach)),
		"pierce": _ids(DmWeaponLine.pierce_targets(i["caster"], i["tgt"], i["foes"], int(i["count"]))),
	}


func h_legion(i: Dictionary) -> Variant:
	var lb := DmLegion.legion_bonus({"weapon": i["wp"], "armor": i["ar"]}, float(i["tier"]))
	var before: Dictionary = i["before"]
	var after: Dictionary = i["after"]
	var rf := DmLegion.thrall_refresh(before, after)
	return {
		"lb": lb, "pw": DmLegion.piece_bonus("weapon", i["wp"]), "pa": DmLegion.piece_bonus("armor", i["ar"]), "rb": DmLegion.reinforce_bonus(float(i["tier"])),
		"refresh": rf if not rf.is_empty() else null, "applied": strip(DmLegion.apply_legion_mods(i["mods"], lb)),
		"value": DmLegion.piece_value(DmLegion.piece_bonus("weapon", i["wp"])), "noLegion": DmLegion.no_legion(),
	}


func h_legion_slots(i: Dictionary) -> Variant:
	return {"lo": DmLegion.legion_of(i["slots"], float(i["t"])), "sig": DmLegion.legion_signature(i["slots"], float(i["t"]))}


func h_vows_boons(i: Dictionary) -> Variant:
	var heat: float = float(i["heat"])
	var id: String = i["id"]
	var cost := DmVowsBoons.boon_cost(id, i["boons"])
	var blocked := DmVowsBoons.boon_blocked(id, i["boons"], float(i["best"]), i.get("unl"))
	return {
		"vowFx": DmVowsBoons.vow_effects(i["vows"]), "boonFx": DmVowsBoons.boon_effects(i["boons"]), "heat": DmVowsBoons.vow_heat(i["vows"]),
		"world": DmVowsBoons.world_vows(i["vows"]), "reward": DmVowsBoons.ascension_reward_mult(heat), "levels": DmVowsBoons.ascension_levels(float(i["rank"])),
		"legacy": DmVowsBoons.legacy_vows(float(i["rank"])), "ashes": DmVowsBoons.ashes_for_run(i["run"], heat),
		"blocked": blocked if blocked != "" else null, "cost": cost if cost >= 0.0 else null,
		"wave": DmWaveUpgrades.wave_modifiers(float(i["tier"])), "pct": DmWaveUpgrades.damage_bonus_pct(float(i["tier"])), "miles": DmWaveUpgrades.milestones(float(i["tier"]), 8.0),
		"san": _sanitize(i["vows"]),
		"costs": {"damage": _nn(DmWaveUpgrades.damage_cost(float(i["dmgTier"]), i["boons"])), "wave": _nn(DmWaveUpgrades.wave_cost(float(i["waveTier"]), i["boons"])), "legion": _nn(DmWaveUpgrades.legion_cost(float(i["legTier"])))},
	}


func _nn(v: float) -> Variant:
	return null if v < 0.0 else v


func _sanitize(vows: Dictionary) -> Dictionary:
	var out := {}
	for id: String in DmCombatData.progression()["vow_order"]:
		var n := DmVowsBoons.vow_steps(vows, id)
		if n != 0.0:
			out[id] = n
	return out


func h_brews(i: Dictionary) -> Variant:
	var brews := DmBrews.empty_brews()
	var log: Array = []
	for d in i["drinks"]:
		var r := DmBrews.apply_brew(brews, d["id"], float(d["now"]))
		log.append({"r": r, "brews": brews.duplicate(true)})
	var at: float = float(i["at"])
	var values := {}
	for k in ["damage", "ward", "lifesteal", "haste", "resist_fire", "resist_rot", "speed", "essence", "wisdom", "fortune"]:
		values[k] = DmBrews.brew_value(brews, k, at)
	return {
		"log": log, "values": values, "ward": DmBrews.brew_ward(brews, i["from"], at), "brews": brews,
		"lifesteal": DmBrews.lifesteal_heal(float(i["dmg"]), float(i["targets"]), float(i["frac"]), float(i["maxHp"])),
	}


func h_flasks(i: Dictionary) -> Variant:
	return DmBrews.flask_heal_frac(i["id"])


func h_resources(i: Dictionary) -> Variant:
	var f: String = i["fam"]
	var ctx: Dictionary = i["ctx"]
	return {
		"kind": DmResources.kind_for(f), "label": DmResources.label_for(f), "color": DmResources.color_for(f), "max": DmResources.max_for(f, i["stats"]),
		"initial": DmResources.initial(f, float(i["stats"]["maxEssence"])), "revive": DmResources.on_revive(f, float(i["stats"]["maxEssence"])), "passive": DmResources.passive(f, ctx),
	}


func h_player(i: Dictionary) -> Variant:
	var p := DmPlayerRules.new_state(i["stats"], i["fam"])
	var snaps: Array = []
	for a: Dictionary in i["acts"]:
		var now: float = float(a["now"])
		match a["kind"]:
			"hit": DmPlayerRules.take_damage(p, a["raw"], a["ward"], now, a["from"], a["source"], a["guard"])
			"tick": DmPlayerRules.tick_vitals(p, a["dt"], now)
			"heal": DmPlayerRules.heal(p, a["amount"])
			"barrier":
				p["barrier"] += float(a["amount"])
				p["barrierPeak"] = maxf(p["barrierPeak"], p["barrier"])
				if a.has("hold"):
					p["barrierHoldUntil"] = float(a["hold"])
			"bulwark":
				p["bulwarkUntil"] = now + 2000.0
				p["bulwarkPerfectUntil"] = a["perfect"]
				p["facing"] = a["facing"]
			"oath": p["unbreakableUntil"] = a["until"]
			"souls":
				p["soulRateMult"] = a["rate"]
				DmPlayerRules.add_souls(p, a["n"])
				if a["spend"]:
					DmPlayerRules.spend_souls(p)
			"veil":
				p["veilForm"] = a["v"]
				p["betweenUntil"] = a["between"]
			"brew": DmBrews.apply_brew(p["brews"], a["id"], now)
			"revive": DmPlayerRules.revive(p)
			"stats": DmPlayerRules.set_stats(p, a["stats"])
			"res": DmPlayerRules.add_resource(p, a["amount"])
			"speed":
				p["moveMult"] = a["moveMult"]
				p["chilledUntil"] = a["chill"]
		snaps.append({
			"hp": p["hp"], "alive": p["alive"], "res": p["resource"].duplicate(), "barrier": p["barrier"], "peak": p["barrierPeak"], "broke": p["barrierBroke"],
			"lastBlock": p["lastBlock"], "souls": p["souls"], "veil": p["veilForm"], "lastHurtAt": p["lastHurtAt"], "chilledUntil": p["chilledUntil"],
		})
	return {"snaps": snaps}


# ===================================================================== part 2
func _nan_or(v: Variant) -> float:
	return NAN if v == null else float(v)


func h_legend(i: Dictionary) -> Variant:
	var m: Dictionary = i["mods"]
	var clampd: Variant = DmLegend.clamp_sim_legend(i["raw"])
	return {
		"clamp": clampd, "simOf": DmLegend.sim_legend_of(m), "dtm": DmLegend.damage_taken_mult(float(i["ward"]), float(i["guard"])),
		"cap": DmLegend.effective_withered_cap(m), "col": DmLegend.colossus_active(m, float(i["thr"])),
		"refl": DmLegend.ward_reflect_damage(float(i["raw2"]), float(i["bw"]), float(i["refl"])),
		"shatter": DmLegend.shatter_damage(float(i["barrier"]), float(i["shat"])),
	}


func _impale(r: Variant) -> Variant:
	return null if r == null else {"id": r["foe"]["id"], "along": r["along"]}


func h_runes(i: Dictionary) -> Variant:
	var c: Dictionary = i["caster"]
	var sp: Variant = DmRunes.splinter_target(i["first"], i["foes"])
	return {
		"splinter": sp["id"] if sp != null else null, "volley": _ids(DmRunes.volley_targets(c, i["first"], i["foes"])), "ring": _ids(DmRunes.ring_hits(c, 3.0, i["foes"])),
		"centre": DmRunes.ring_center(c, i["aim"], 12.0), "impale": _impale(DmRunes.impale_target(c, float(i["d"]["dx"]), float(i["d"]["dz"]), 12.0, 1.1, i["foes"])),
		"within": _ids(DmRunes.corpses_within(c, 6.0, i["corpses"])), "sockets": DmRunes.sockets_of(i["rows"]), "owned": DmRunes.owned_runes(i["rows"]),
		"fits": DmRunes.rune_fits(i["rid"], i["rite"]), "centre2": DmRunes.ring_center(c, i["aim"], float(i["reach"])),
		"ring2": _ids(DmRunes.ring_hits(i["pt"], float(i["ringR"]), i["foes"])), "within2": _ids(DmRunes.corpses_within(i["pt"], float(i["r"]), i["corpses"])),
	}


func h_scaling(i: Dictionary) -> Variant:
	var def: String = i["def"]
	var lvl: float = float(i["lvl"])
	return {
		"xp": DmEnemyStats.kill_xp_base(def, lvl, i["elite"], float(i["tier"]), i["diff"]), "gold": DmEnemyStats.kill_gold_max(def, lvl, i["elite"], float(i["tier"]), i["diff"]),
		"nbx": DmEnemyStats.new_blood_xp_mult(i["fam"], lvl), "nbd": DmEnemyStats.new_blood_damage_mult(i["fam"]),
		"hp": DmEnemyStats.hp_scale(lvl), "dm": DmEnemyStats.damage_scale(lvl), "dl": DmEnemyStats.depth_enemy_level(float(i["depth"]), float(i["hero"])),
		"hn": DmEnemyStats.hit_number_scale(float(i["f"]["fracture"]), i["f"]["sanct"], i["f"]["shrouded"], i["f"]["rot"]),
	}


func h_enemy_spawn(i: Dictionary) -> Variant:
	var vfx := DmVowsBoons.vow_effects(i["vows"])
	var level := DmEnemyStats.area_level(i["area"], i["hero"], float(vfx["levels"]))
	var since: float = INF if i["since"] == null else float(i["since"])
	var ramp := DmEnemyStats.ramp_tier(float(i["waveTier"]), since)
	var s := DmEnemyStats.spawn_stats(i["def"], i["elite"], {"level": level, "rampTier": ramp, "difficulty": i["difficulty"], "vowHpMult": vfx["enemyHpMult"], "players": i["nplayers"]})
	var adopt := DmEnemyStats.adopt_damage(i["def"], i["elite"], float(i["adoptLevel"]), float(i["waveTier"]), i["difficulty"])
	return {
		"level": s["level"], "hp": s["hp"], "damage": s["damage"], "radius": s["radius"], "scale": s["scale"], "areaLevel": level, "ramp": ramp,
		"adoptDamage": adopt, "adoptRadius": s["radius"], "blow": DmEnemyStats.blow(s["damage"], true), "blow0": DmEnemyStats.blow(s["damage"], false),
	}


func h_damage_enemy(i: Dictionary) -> Variant:
	var def: Dictionary = DmCombatData.enemies()["enemies"][i["def"]]
	var from: Variant = i.get("from")
	var diff := 0.0
	if from != null:
		diff = atan2(from["x"] - float(i["ex"]), from["z"] - float(i["ez"])) - float(i["facing"])
	var shield := DmEnemyStats.shield_mult(bool(def["shield"]), from != null, float(i["fracture"]), diff)
	var taken := DmEnemyStats.damage_taken_mult(i["shrouded"], i["rot"], i["sanct"])
	var dealt := DmEnemyStats.damage_dealt(float(i["amount"]), float(i["fracture"]), taken, shield)
	return {"dealt": dealt, "takenMult": taken}


func _th_out(t: Dictionary) -> Dictionary:
	return {"kind": t["kind"], "hp": t["hp"], "maxHp": t["maxHp"], "damage": t["damage"], "attackInterval": t["attackInterval"], "range": t["range"], "speed": t["speed"],
		"empowered": t["empowered"], "champion": t["champion"], "allyHeal": t["allyHeal"]}


func h_thralls(i: Dictionary) -> Variant:
	var corpses: Array = []
	for c: Dictionary in i["corpses"]:
		var cc := c.duplicate()
		cc["area"] = "graves"
		corpses.append(cc)
	var thralls: Array = []
	var seq := 0
	var raised_n := 0
	var every: float = float(i["every"])
	var steps: Array = []
	for st: Dictionary in i["steps"]:
		var intent: Dictionary = st["intent"]
		var cap: float = float(intent["cap"])
		if intent.get("colossus", false):
			var near := DmThralls.colossus_picks(intent, corpses)
			if not near.is_empty():
				for c in near:
					corpses.erase(c)
				var keep: Array = []
				for t in thralls:
					if t["kind"] != "colossus":
						keep.append(t)
				thralls = keep
				var owned: Array = []
				for t in thralls:
					owned.append({"id": t["id"], "kind": t["kind"], "bornAt": 0.0})
				var crumbled := DmThralls.make_room(owned, cap, DmThralls.weight("colossus"))
				thralls = thralls.filter(func(t): return not crumbled.has(t["id"]))
				var cs := DmThralls.colossus_stats(intent, near)
				seq += 1
				var th: Dictionary = {"id": seq, "kind": "colossus", "champion": false, "allyHeal": 0.0}
				th.merge(cs)
				thralls.append(th)
		else:
			var pk := DmThralls.exhume_picks(intent, corpses, "graves")
			for c in pk["picks"]:
				corpses.erase(c)
				var owned2: Array = []
				for t in thralls:
					owned2.append({"id": t["id"], "kind": t["kind"], "bornAt": 0.0})
				var crumbled2 := DmThralls.make_room(owned2, cap, 1.0)
				thralls = thralls.filter(func(t): return not crumbled2.has(t["id"]))
				raised_n += 1
				var ts := DmThralls.raise_stats(intent, c, pk["statMult"], raised_n, every)
				seq += 1
				ts["id"] = seq
				thralls.append(ts)
		var rf: Variant = st["refresh"]
		if rf != null:
			var nt: Array = []
			for t in thralls:
				nt.append(DmThralls.apply_refresh(t, _nan_or(rf.get("hpMult")), _nan_or(rf.get("damageMult")), _nan_or(rf.get("speedMult"))))
			thralls = nt
		var snap: Array = []
		for t in thralls:
			snap.append(_th_out(t))
		steps.append(snap)
	return {"steps": steps}


func h_litany_detonate(i: Dictionary) -> Variant:
	var lit: Dictionary = i["lit"]
	var lx: float = lit["x"]
	var lz: float = lit["z"]
	var lr: float = lit["r"]
	var corpses: int = 0
	var resonant: int = 0
	var first_alive := true
	var kept: Array = []
	var idx := 0
	for c: Dictionary in i["corpses"]:
		var within := DmWeaponLine.hypot2(c["x"] - lx, c["z"] - lz) <= lr
		if within:
			if c["kind"] == "resonant":
				resonant += 1
			else:
				corpses += 1
			if idx == 0:
				first_alive = false
		else:
			kept.append(c)
		idx += 1
	var thr := 0
	for t: Dictionary in i["thr"]:
		if DmWeaponLine.hypot2(t["x"] - lx, t["z"] - lz) <= lr:
			thr += 1
	var dmg := DmAbilities.litany_damage(float(lit["spellPower"]), corpses, resonant, thr)
	var lit_dmg: Array = []
	var targets := 0
	for f: Dictionary in i["foePos"]:
		if DmWeaponLine.hypot2(f["x"] - lx, f["z"] - lz) > lr + float(f["radius"]):
			lit_dmg.append(0.0)
		else:
			lit_dmg.append(dmg)
			targets += 1
	var spare: bool = lit.get("spare", false)
	var res := {"corpses": corpses, "resonant": resonant, "thralls": 0 if spare else thr, "spared": thr if spare else 0, "targets": targets}
	var det: Variant = null
	var d: Variant = i.get("det")
	if d != null:
		var c: Dictionary = d["corpse"]
		var claim: float = _nan_or(d["claim"])
		var b := DmAbilities.detonate_blast(claim, c)
		var dd: Array = []
		var tg := 0
		for f: Dictionary in i["foePos"]:
			var hit: bool = DmWeaponLine.hypot2(f["x"] - c["x"], f["z"] - c["z"]) <= b["radius"] + float(f["radius"])
			dd.append(hit)
			if hit:
				tg += 1
		det = {"r": b["radius"], "targets": tg, "dmg": float(DmMath.js_round(b["dmg"])), "zone": {"r": b["rotRadius"], "dps": b["rotDps"]} if c["kind"] == "toxic" else null}
	return {"res": res, "litDmg": lit_dmg, "det": det}


func _p_from(i: Dictionary) -> Dictionary:
	var p := DmPlayerRules.new_state(i["stats"], i["fam"])
	p["loadout"] = i["loadout"]
	p["resource"]["value"] = float(i["resource"])
	p["castUntil"] = float(i["castUntil"])
	var cd: float = float(i["cooldown"])
	if cd != 0.0:
		p["cooldowns"][i["id"]] = cd
	p["souls"] = float(i["souls"])
	p["brews"] = i["brews"]
	p["unbreakableUntil"] = float(i["unbreakableUntil"])
	p["alive"] = i["alive"]
	return p


func h_ability_cast(i: Dictionary) -> Variant:
	var p := _p_from(i)
	var id: String = i["id"]
	var now: float = float(i["now"])
	var level: float = float(i["level"])
	var verdict := DmAbilities.cast_check(p, id, level, now)
	var emp := DmAbilities.empowered(p, id)
	var sp := DmAbilities.sp(p, now)
	var nb := DmAbilities.new_blood_power(p, now)
	var before := {"essence": p["resource"]["value"]}
	if verdict == "ok":
		DmAbilities.apply_cast_cost(p, id, now, emp, i["colossus"])
	return {
		"verdict": verdict, "empowered": emp, "castUntil": p["castUntil"], "rootedUntil": p["rootedUntil"], "essence": p["resource"]["value"],
		"cooldown": float(p["cooldowns"].get(id, 0.0)), "souls": p["souls"], "sp": sp, "nbPower": nb, "unlock": DmAbilities.unlock_level(id), "before": before,
	}


func h_ability_damage(i: Dictionary) -> Variant:
	var sp: float = float(i["sp"])
	var rune: String = i["rune"]
	var mods: Dictionary = i["mods"]
	var mult: float = float(i["mult"])
	var lo: Dictionary = i["loadout"]
	var g := DmAbilities.grave_hands(sp, float(i["gcorp"]))
	var gains := DmAbilities.litany_gains(float(i["maxHp"]), i["mm"], {"corpses": i["corp"], "resonant": i["res"], "thralls": i["thr"]})
	var mp := DmPlayerRules.new_state({"maxHp": 1.0, "maxEssence": 100.0, "essenceRegen": 0.0}, "necromancer")
	DmAbilities.mantle_apply(mp, float(i["mantleCorp"]), 0.0)
	return {
		"needle": DmAbilities.needle_cast(sp, lo, rune, int(i["castIdx"]), float(i["jitter"])),
		"reap": DmAbilities.reap_cast(sp, rune, float(i["jitter"]), int(i["landed"])),
		"spear": DmAbilities.spear(sp, rune, mult),
		"miasma": DmAbilities.miasma(sp, mods, rune, mult, i["caster"], i["aim"]),
		"litMult": DmAbilities.litany_mult(float(i["corp"]), float(i["res"]), float(i["thr"])),
		"litDmg": DmAbilities.litany_damage(sp, float(i["corp"]), float(i["res"]), float(i["thr"])),
		"litSp": DmAbilities.litany_spell_power(sp, rune), "gains": gains, "hands": g,
		"storm": DmAbilities.bone_storm_life_s(float(i["gcorp"])), "mantle": mp["barrier"],
		"skull": DmAbilities.skull_leap_damage(DmAbilities.rite_damage(sp, "wailing_skull"), int(i["hop"])), "claim": DmAbilities.detonate_claim(sp),
	}


func h_new_blood(i: Dictionary) -> Variant:
	var p := DmPlayerRules.new_state(i["stats"], i["fam"])
	p["veilForm"] = i["veilForm"]
	p["betweenUntil"] = float(i["between"])
	p["resource"]["value"] = float(i["value"])
	var now: float = float(i["now"])
	var tc := DmAbilities.toll_cast(p, i["id"], now)
	var pm := DmAbilities.palm_strike(p, now)
	var hk := DmAbilities.hook_throw(p, now)
	return {
		"power": DmAbilities.new_blood_power(p, now), "toll": tc, "palm": pm, "hook": hk,
		"choir": DmAbilities.choir_beat_power(p, now), "crow": DmAbilities.crow_peck_damage(p, now),
	}
