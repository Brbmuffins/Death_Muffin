extends SceneTree
## Golden-fixture runner for godot/rules/combat.
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/rules-combat/run.gd
## Fixtures: tools/godot/fixtures-combat.ts (npx vite-node tools/godot/fixtures-combat.ts, or tools/godot/gen-fixtures.sh) -> tests/rules-combat/fixtures/*.json
## Each fixture file is {fn, cases:[{in, out}]}; HANDLERS maps fn -> a method here taking the case input and returning the expected output.

const DIR := "res://tests/rules-combat/fixtures/"
var passed := 0
var failed := 0
var per_file: Dictionary = {}
var _shown := 0


func _initialize() -> void:
	var dir := DirAccess.open(DIR)
	if dir == null or not FileAccess.file_exists(DIR + "build.json"):
		print("fixtures missing: run tools/godot/gen-fixtures.sh")
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
