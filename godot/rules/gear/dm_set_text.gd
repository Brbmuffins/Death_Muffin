class_name DmSetText
extends RefCounted
## The words and the full status of armor sets (archive/legacy-web:src/content/setBonuses.ts describeEffect + setStatus's `missing`, archive/legacy-web:src/gameplay/setBonuses.ts
## setDiffText). DmSetBonuses (rules/combat) owns the maths; this adds what the Character sheet and tooltips print.


static func _pct(x: float) -> String:
	return DmJsFmt.plus_fixed(x * 100.0, 1) + "%"


static func _num(v: Variant) -> String:
	return DmJsFmt.num_str(float(v))


static func _truthy(v: Variant) -> bool:
	return DmCombatData.truthy(v)


## Plain-language lines for one effect ("Thralls have +5% health").
static func describe_effect(e: Dictionary) -> Array:
	var out: Array = []
	var m: Dictionary = DmCombatData.nn(e.get("mult"), {})
	var a: Dictionary = DmCombatData.nn(e.get("add"), {})
	var st: Variant = e.get("stats")
	if st is Dictionary:
		for k in st:
			out.append("+%s %s" % [_num(st[k]), String(k).replace("stat_", "").to_upper()])
	if _truthy(m.get("maxHpMult")):
		out.append("+%s maximum health" % _pct(float(m["maxHpMult"]) - 1.0))
	if _truthy(m.get("essenceRegenMult")):
		out.append("+%s essence regeneration" % _pct(float(m["essenceRegenMult"]) - 1.0))
	if _truthy(m.get("thrallHpMult")):
		out.append("Thralls have +%s health" % _pct(float(m["thrallHpMult"]) - 1.0))
	if _truthy(m.get("thrallDamageMult")):
		out.append("Thralls hit +%s harder" % _pct(float(m["thrallDamageMult"]) - 1.0))
	if _truthy(m.get("thrallAttackSpeedMult")):
		out.append("Thralls attack +%s faster" % _pct(float(m["thrallAttackSpeedMult"]) - 1.0))
	if _truthy(m.get("miasmaRadiusMult")):
		out.append("Miasma is +%s wider" % _pct(float(m["miasmaRadiusMult"]) - 1.0))
	if _truthy(a.get("thrallCap")):
		out.append("+%s thrall cap" % _num(a["thrallCap"]))
	if _truthy(a.get("witheredMaxStacks")):
		out.append("+%s max Withered stacks" % _num(a["witheredMaxStacks"]))
	if _truthy(a.get("wardPerThrall")):
		out.append("%s less damage taken per thrall" % _pct(float(a["wardPerThrall"])))
	if _truthy(a.get("corpseHeal")):
		out.append("Consumed corpses heal +%s max health" % _pct(float(a["corpseHeal"])))
	if _truthy(a.get("litanyBarrier")):
		out.append("Black Litany barrier +%s max health per corpse" % _pct(float(a["litanyBarrier"])))
	if _truthy(a.get("thrallDeathBurst")):
		out.append("Thralls burst when they die (%s of their health as damage to enemies around them)" % _pct(float(a["thrallDeathBurst"])))
	if _truthy(a.get("championEvery")):
		out.append("Every %sth thrall you raise is a Champion (bigger, with 2x damage and health)" % _num(a["championEvery"]))
	if _truthy(a.get("spearRally")):
		out.append("Marrow Spear rallies your legion: every thrall charges the target and hits +%s harder for 4 s" % _pct(float(a["spearRally"])))
	if _truthy(a.get("wardReflect")):
		out.append("Bone Ward reflects %s of the damage it blocks back at the attacker" % _pct(float(a["wardReflect"])))
	if _truthy(a.get("colossusGuard")):
		out.append("%s less damage taken while 3 or more thralls stand" % _pct(float(a["colossusGuard"])))
	if _truthy(a.get("litanyShatter")):
		out.append("When the Black Litany barrier breaks it shatters into bone shards for %sx its size" % DmJsFmt.plus_fixed(float(a["litanyShatter"]), 1))
	if _truthy(a.get("corpseWisp")):
		out.append("Consuming a corpse summons a healing wisp for %s s" % _num(a["corpseWisp"]))
	if _truthy(m.get("soulHarvestRateMult")) and float(m["soulHarvestRateMult"]) != 1.0:
		out.append("Soul Harvest fills %sx faster" % DmJsFmt.plus_fixed(float(m["soulHarvestRateMult"]), 2))
	if _truthy(a.get("wraithNova")):
		out.append("When Soul Harvest empowers a rite, every wraith and wisp releases a nova (%s of your spell power)" % _pct(float(a["wraithNova"])))
	if _truthy(a.get("miasmaSpreadsWithered")):
		out.append("Enemies that die in your Miasma spread their Withered stacks to enemies nearby")
	if _truthy(a.get("witheredBurstAt")):
		out.append("An enemy that reaches %s Withered stacks bursts into a new Miasma cloud (stack cap at least %s)" % [_num(a["witheredBurstAt"]), _num(a["witheredBurstAt"])])
	return out


static func _area_name(id: String) -> String:
	return String(DmContent.area(id).get("name", id))


## setStatus(setId, wornParts): DmSetBonuses.set_status plus `missing`, per-bonus `setName` and `lines`.
static func set_status(set_id: String, worn_parts: Array) -> Dictionary:
	var st := DmSetBonuses.set_status(set_id, worn_parts)
	for b: Dictionary in st["bonuses"]:
		b["setName"] = st["setName"]
		b["lines"] = describe_effect(b["effect"])
	var missing: Array = []
	for p: Dictionary in DmSetBonuses._pieces_by_set.get(set_id, []):
		if not worn_parts.has(p["part"]):
			missing.append({"part": p["part"], "name": p["name"], "where": "Area bosses" if int(p["collection"]) == 3 else _area_name(String(p["area"]))})
	st["missing"] = missing
	return st


## resolveSetBonuses with every set's status complete (missing pieces, bonus lines).
static func resolve(slots: Array) -> Dictionary:
	var r := DmSetBonuses.resolve(slots)
	var sets: Array = r["sets"]
	for i in sets.size():
		var s: Dictionary = sets[i]
		var full := set_status(String(s["setId"]), s["wornParts"])
		sets[i] = full
	return r


## "completes Ivory Reliquary 4-piece" / "breaks your Gravecall 2-piece", or "".
static func diff_text(diff: Dictionary) -> String:
	var parts: Array[String] = []
	var g := _top(diff["gained"])
	var l := _top(diff["lost"])
	if g.size() > 0:
		parts.append("completes " + " and ".join(g))
	if l.size() > 0:
		parts.append("breaks your " + " and ".join(l))
	return ", ".join(parts)


static func _top(list: Array) -> Array[String]:
	var best: Dictionary = {}
	for c: Dictionary in list:
		if not best.has(c["setName"]) or int(best[c["setName"]]["pieces"]) < int(c["pieces"]):
			best[c["setName"]] = c
	var out: Array[String] = []
	for k in best:
		out.append("%s %d-piece" % [best[k]["setName"], int(best[k]["pieces"])])
	return out
