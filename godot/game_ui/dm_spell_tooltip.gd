class_name DmSpellTooltip
extends RefCounted
## Port of src/ui/spellTooltip.ts: the player-readable data of the HUD spell card (name, control line, status, metrics, per-rite details, combat tip).
## Pure data, golden-tested against the TS (tests/ui_parity). `discipline` is the DISCIPLINES entry ({} = none); `state` mirrors SpellTooltipState:
## {empowered, locked, affordable, left (ms), key, kit (kit dict), auto (canUseAutoCombat)}.

const TARGETING := {
	"enemy": "Aim at an enemy.",
	"direction": "Aim with the mouse; the spell travels along that direction.",
	"corpse": "Aim at a corpse on the ground. Requires an available body.",
	"ground": "Aim at a point on the ground.",
	"self": "Cast around your character; no target needed.",
}
const RADIUS_IDS := ["miasma", "black_litany", "corpse_explosion", "dirge", "plague_bloom", "command_rend", "grave_step", "bone_mantle", "carrion_seed", "rally_dead", "bone_prison", "grave_hands", "bone_storm"]


static func K(name: String) -> Variant:
	return DmContent.get_export("abilities", name)


## `Number(n.toFixed(2)).toString()`
static func _n(x: float) -> String:
	return DmJsFmt.num_str(float(DmJsFmt.to_fixed(x, 2)))


static func _p(x: float) -> String:
	return _n(x * 100.0) + "%"


## String(x) for a plain constant
static func _s(x: Variant) -> String:
	return DmJsFmt.num_str(float(x))


static func _nn(v: Variant, fallback: Variant) -> Variant:
	return fallback if v == null else v


static func build(id: String, discipline: Dictionary = {}, state: Dictionary = {}) -> Dictionary:
	var a: Dictionary = DmContent.get_export("abilities", "ABILITIES")[id]
	var has_d := not discipline.is_empty()
	var m: Dictionary = discipline.get("mods", {}) if has_d else {}
	var has_m := has_d and not m.is_empty()
	var soul: Dictionary = K("SOUL_HARVEST")
	var empowered := bool(state.get("empowered", false)) and (soul["spells"] as Array).has(id)
	var area_mult: float = float(soul["areaMult"]) if empowered else 1.0
	var unlock := float(_nn(a.get("unlockLevel"), 1))
	var locked := bool(state.get("locked", false)) and unlock > 1.0
	var family := String(discipline.get("family", "necromancer")) if has_d else "necromancer"
	var resource_name := "Essence"
	if has_d and family != "necromancer":
		resource_name = DmResources.label_for(family)
	var cost := float(a.get("essenceCost", 0))
	var cost_text: String
	if empowered:
		cost_text = "Free (normally %s)" % _s(cost)
	else:
		cost_text = _n(cost) if cost != 0.0 else "Free"
	var rng := float(a.get("range", 0))
	var metrics: Array = [
		{"label": resource_name, "value": cost_text},
		{"label": "Cooldown", "value": "%ss" % _n(float(a["cooldownMs"]) / 1000.0)},
		{"label": "Range", "value": "%sm" % _n(rng * (area_mult if id == "marrow_spear" else 1.0)) if rng != 0.0 else "Around you"},
	]
	var radius := float(a.get("radius", 0))
	if id == "miasma":
		radius *= float(_nn(m.get("miasmaRadiusMult"), 1)) * area_mult
	if id == "black_litany":
		radius *= area_mult
	if RADIUS_IDS.has(id):
		metrics.append({"label": "Radius", "value": "%sm" % _n(radius)})
	var details: Array = _details(id, a, discipline, m, has_m, empowered, soul)
	if details.is_empty():
		details.append(String(a["description"]))
	if (soul["spells"] as Array).has(id):
		details.append(("Soul Harvest is ready: this cast is free and %s larger. It spends the charged meter." % _p(float(soul["areaMult"]) - 1.0)) if empowered else "A full Soul Harvest meter makes your next cast of this spell free and larger.")
	# HUD passes the equipped slot; elsewhere, describe the default kit position.
	var kit: Dictionary = state.get("kit", {})
	if kit.is_empty():
		kit = DmAbilities.kit_for("necromancer")
	var defaults: Array = (kit["defaultLoadout"] as Array).duplicate()
	defaults.append(kit["rmb"])
	var gkey := ""
	if state.get("key") != null and String(state["key"]) != "":
		gkey = String(state["key"])
	elif defaults.has(id):
		gkey = str(defaults.find(id) + 1)
	var slot := int(a["slot"])
	var control: String
	if slot == 0:
		control = "Click an enemy, or Shift + click to cast in place."
	elif slot == 6:
		control = "Press R or 6, or click this icon.%s" % (" On Easy, Auto may cast it in a suitable fight." if bool(state.get("auto", false)) else "")
	elif gkey == "RMB" or gkey == "5":
		control = "Right-click, press 5 or click this icon. Aim before casting. Change this slot in the Grimoire (L)."
	elif gkey != "":
		control = "Press or hold %s; aim with the mouse. You can also click this icon. Change its key in the Grimoire (L)." % gkey
	else:
		control = "Place it on one of the five slots in the Grimoire (L), then press that key or right-click for slot 5."
	var left := float(state.get("left", 0))
	var status: String
	if locked:
		status = "Locked — unlocks at level %s." % _s(unlock)
	elif left > 0.0:
		status = "Ready in %ss." % _s(ceil(left / 1000.0))
	elif state.get("affordable") != null and not bool(state["affordable"]) and not empowered:
		status = "Not enough %s." % ("Grave Essence" if resource_name == "Essence" else resource_name)
	elif empowered:
		status = "Soul Harvest ready."
	else:
		status = "Ready to cast."
	var tip := String(DmContent.get_export("codex", "CODEX_RITES")[id]["tip"])
	return {"name": a["name"], "description": a["description"], "control": control, "targeting": TARGETING[a["targeting"]], "metrics": metrics, "details": details,
		"tip": tip, "status": status, "empowered": empowered, "locked": locked}


static func _details(id: String, a: Dictionary, discipline: Dictionary, m: Dictionary, has_m: bool, empowered: bool, soul: Dictionary) -> Array:
	var d: Array = []
	var dn := String(discipline.get("name", ""))
	var dis_id := String(discipline.get("id", ""))
	var sig: Dictionary = K("SIGNATURE")
	var hem: Dictionary = DmContent.get_export("statuses", "HEMORRHAGE")
	var chill: Dictionary = DmContent.get_export("statuses", "CHILL")
	match id:
		"bone_needle":
			d.append("Each hit restores %s Grave Essence. Use it between your other spells." % _s(K("NEEDLE_ESSENCE")))
		"marrow_spear":
			var f: Dictionary = K("FRACTURE")
			d.append("Pierces enemies in a line. Fracture makes targets take %s more damage per stack, up to %s stacks for %ss." % [_p(float(f["perStack"])), _s(f["maxStacks"]), _n(float(f["durationMs"]) / 1000.0)])
			d.append("Non-boss enemies also suffer Hemorrhage: bleeding for %ss." % _s(hem["durationS"]))
		"exhume":
			d.append("Consumes one corpse to raise a thrall%s. At the cap, your oldest thrall crumbles." % ("; your %s cap is %s" % [dn, _s(m["thrallCap"])] if has_m else ""))
			d.append("The body determines special thrall types; resonant and elite corpses raise empowered thralls.")
			if has_m:
				var kind: String = m["thrallKind"]
				d.append("Ordinary bodies rise as %s." % ("shieldbearers" if kind == "shieldbearer" else ("ranged wraiths" if kind == "wraith" else "warriors")))
				var hp_mult := float(m["thrallHpMult"])
				if hp_mult != 1.0:
					d.append("%s: thralls have %s %s health." % [dn, _p(absf(hp_mult - 1.0)), "more" if hp_mult > 1.0 else "less"])
				var as_mult := float(m["thrallAttackSpeedMult"])
				if as_mult != 1.0:
					d.append("%s: thralls attack %s faster." % [dn, _p(as_mult - 1.0)])
				if float(m["wardPerThrall"]) != 0.0:
					d.append("%s: take %s less damage per active thrall." % [dn, _p(float(m["wardPerThrall"]))])
				if float(m["corpseHeal"]) != 0.0:
					d.append("%s: consuming this corpse restores %s of your maximum health." % [dn, _p(float(m["corpseHeal"]))])
		"miasma":
			var wmax: Variant = m.get("witheredMaxStacks") if has_m and m.get("witheredMaxStacks") != null else DmContent.get_export("disciplines", "DISCIPLINES")["gravecaller"]["mods"]["witheredMaxStacks"]
			d.append("Slows enemies by %s and builds Withered damage over time, up to %s stacks." % [_p(1.0 - float(K("MIASMA_SLOW"))), _s(wmax)])
			if has_m and bool(m.get("miasmaBurstsCorpses", false)):
				d.append("%s: corpses inside your Miasma burst and spread Withered. These bodies are consumed." % dn)
		"black_litany":
			d.append("Consumes nearby corpses and sacrifices your nearby thralls. More bodies and thralls make the burst stronger.")
			if has_m and bool(m.get("sacrificeLeavesCorpse", false)):
				d.append("%s: sacrificed thralls leave fresh corpses to raise again." % dn)
			if has_m and float(m.get("litanyBarrier", 0)) != 0.0:
				d.append("%s: gain a barrier worth %s of your maximum health per corpse or thrall consumed." % [dn, _p(float(m["litanyBarrier"]))])
			if has_m and float(m.get("corpseHeal", 0)) != 0.0:
				d.append("%s: restore %s of your maximum health per corpse consumed." % [dn, _p(float(m["corpseHeal"]) * 0.5)])
		"corpse_explosion":
			var de: Dictionary = K("DETONATE")
			d.append("Consumes one corpse. Resonant corpses blast %s× wider; elite corpses deal %s× damage." % [_n(float(de["resonantRadiusMult"])), _n(float(de["eliteDamageMult"]))])
			d.append("Toxic corpses leave a friendly rot pool for %ss. A burst body cannot also become a thrall." % _n(float(de["rotDurationMs"]) / 1000.0))
		"bone_fan":
			var bf: Dictionary = K("BONE_FAN")
			d.append("%s slivers, each on a different enemy within %s° of your target; the Prelate counts as one." % [_s(bf["slivers"]), _s(float(bf["coneHalfDeg"]) * 2.0)])
			d.append("+%s Grave Essence per sliver that lands (up to %s per cast). Equip on the Grimoire's LMB socket." % [_s(bf["essencePerHit"]), _s(bf["essenceCap"])])
		"rot_lance":
			var rl: Dictionary = K("ROT_LANCE")
			var cap: Variant = m.get("witheredMaxStacks") if has_m and m.get("witheredMaxStacks") != null else K("DETONATE")["rotWitheredCap"]
			d.append("Pierces the first %s enemies in a narrow line and adds %s Withered stack to each (up to %s)." % [_s(rl["pierce"]), _s(rl["withered"]), _s(cap)])
			d.append("+%s Grave Essence on the first hit. Equip on the Grimoire's LMB socket." % _s(rl["essence"]))
		"grave_offering":
			var go: Dictionary = K("GRAVE_OFFERING")
			d.append("Consumes one corpse: +%s essence (+%s resonant, ×%s elite) and %s of your maximum health." % [_s(go["essence"]), _s(go["resonantBonus"]), _s(go["eliteMult"]), _p(float(go["healFrac"]) + (float(m.get("corpseHeal", 0)) if has_m else 0.0))])
		"ivory_cleave":
			var ic: Dictionary = K("IVORY_CLEAVE")
			d.append("A %s° arc to %sm. Everything cut gains %s Fracture stack." % [_s(float(ic["halfAngleDeg"]) * 2.0), _n(float(ic["reach"])), _s(ic["fracture"])])
		"veil_step":
			d.append("Stops at walls and sealed doors and never leaves the hall you stand in. No damage and no invulnerability. Auto combat never casts it.")
		"rally_dead":
			var ra: Dictionary = K("RALLY")
			var bonus := " (+%ss, Gravecaller)" % _s(ra["gravecallerBonusS"]) if has_m and dis_id == "gravecaller" else ""
			d.append("Requires at least one thrall. For %ss%s thralls deal %s more damage and attack %s faster; each heals %s and turns on the enemy nearest the cursor." % [_s(ra["durationS"]), bonus, _p(float(ra["damageMult"]) - 1.0), _p(float(ra["attackSpeedMult"]) - 1.0), _p(float(ra["healFrac"]))])
		"carrion_seed":
			var cs: Dictionary = K("CARRION_SEED")
			d.append("Arms after %ss; the first enemy within %sm bursts it for %sm and %s Withered stacks. One seed at a time; it withers after %ss." % [_n(float(cs["armS"])), _n(float(cs["triggerR"])), _n(float(cs["burstR"])), _s(cs["withered"]), _s(cs["lifeS"])])
			d.append("If another rite uses the seeded corpse, the seed is lost with it.")
		"wailing_skull":
			var ws: Dictionary = K("WAILING_SKULL")
			d.append("Leaps to %s more enemies within %sm, each bite %s weaker. A bite that kills earns another leap, up to %s in all." % [_s(float(ws["hops"]) - 1.0), _s(ws["leapRange"]), _p(1.0 - float(ws["falloff"])), _s(ws["maxHops"])])
		"grave_step":
			var gs: Dictionary = K("GRAVE_STEP")
			d.append("Blinks you onto a corpse up to %sm away in the area you stand in; it never crosses a sealed door. The corpse is not consumed." % _n(float(a["range"])))
			d.append("Re-forming bursts within %sm and makes enemies bleed (Hemorrhage) for %ss." % [_s(gs["burstRadius"]), _s(hem["durationS"])])
		"grave_frost":
			var gf: Dictionary = K("GRAVE_FROST")
			d.append("A %s° cone. Chills enemies for %ss: %s slower movement and %s slower attacks." % [_s(float(gf["halfAngleDeg"]) * 2.0), _s(gf["chillS"]), _p(1.0 - float(chill["moveMult"])), _p(1.0 - float(chill["attackRateMult"]))])
			d.append("Enemies already Chilled shatter for %s more damage." % _p(float(gf["shatterMult"]) - 1.0))
		"bone_mantle":
			var bm: Dictionary = K("BONE_MANTLE")
			d.append("Consumes up to %s nearby corpses. Barrier: %s of your maximum health plus %s per corpse (at most %s), held for %ss before it fades." % [_s(bm["maxCorpses"]), _p(float(bm["barrierBase"])), _p(float(bm["barrierPerCorpse"])), _p(float(bm["barrierCap"])), _s(bm["durationS"])])
			d.append("Shards hit enemies within %sm every %ss." % [_s(bm["orbitRadius"]), _s(bm["tickS"])])
		"soul_siphon":
			var ss: Dictionary = K("SOUL_SIPHON")
			d.append("Drains every %ss for %ss. Heals %s of each tick and returns %s essence. Snaps beyond %sm." % [_s(ss["tickS"]), _s(ss["durationS"]), _p(float(ss["healFrac"])), _s(ss["essencePerTick"]), _n(float(a["range"]) * float(ss["breakMult"]))])
		"bone_prison":
			var bp: Dictionary = K("BONE_PRISON")
			d.append("Roots everything in the ring for %ss (the Prelate only takes the damage) and adds %s Fracture." % [_s(bp["rootS"]), _s(bp["fracture"])])
		"grave_hands":
			var gh: Dictionary = K("GRAVE_HANDS")
			d.append("Slows and rakes every %ss for %ss. Each corpse in the field adds %s damage (up to %s); corpses are not consumed." % [_s(gh["tickS"]), _s(gh["durationS"]), _p(float(gh["perCorpse"])), _s(gh["maxCorpses"])])
		"bone_storm":
			var bs: Dictionary = K("BONE_STORM")
			d.append("Lasts %ss, +%ss per corpse it starts on (up to +%ss; not consumed). Drifts toward the nearest enemy and hits every %ss." % [_s(bs["durationS"]), _s(bs["perCorpseS"]), _s(bs["maxExtraS"]), _s(bs["tickS"])])
		"ossuary_wall":
			d.append("Creates a %sm wall for %ss. Blocks enemy movement and Penitent cones." % [_s(sig["wall"]["length"]), _s(sig["wall"]["durationS"])])
		"command_rend":
			d.append("Requires at least one thrall. Each commanded thrall pays %s of its health instead of your essence." % _p(float(sig["rend"]["hpCost"])))
		"dirge":
			d.append("Lasts %ss. Mends you and your thralls while Silenced enemies cannot start spells." % _s(sig["dirge"]["durationS"]))
		"hollow_cut":
			var hc: Dictionary = K("HOLLOW_CUT")
			d.append("A %s° arc %sm in front of you. Costs nothing and pays %s Rage for every enemy it cuts, so it is worth lining up two or three." % [_s(float(hc["halfAngleDeg"]) * 2.0), _s(hc["reach"]), _s(hc["rage"])])
		"shield_bash":
			var sb: Dictionary = K("SHIELD_BASH")
			d.append("Charges %sm and stuns the first enemy struck for %ss — only %ss against a boss. Stops at walls and sealed doors." % [_s(sb["dashM"]), _s(sb["stunS"]), _s(sb["bossStunS"])])
		"grave_slam":
			var gsl: Dictionary = K("GRAVE_SLAM")
			d.append("Leaps up to %sm to the cursor and strikes everything within %sm of the landing. It will not leap anywhere you could not walk." % [_s(gsl["leapM"]), _s(gsl["slamR"])])
		"bulwark":
			var bw: Dictionary = K("BULWARK")
			d.append("Held for %ss: %s less damage from the front %s° only — blows from behind land in full." % [_s(bw["holdS"]), _p(float(bw["damageCut"])), _s(float(bw["frontHalfDeg"]) * 2.0)])
			d.append("A blow inside the first %ss is a perfect block: %s of it is reflected and you gain %s Rage." % [_s(bw["perfectWindowS"]), _p(float(bw["reflect"])), _s(K("KNIGHT_RAGE")["perPerfectBlock"])])
		"corpse_vigil":
			var cv: Dictionary = K("CORPSE_VIGIL")
			d.append("Consumes the body and regenerates %s of your maximum health every second for %ss." % [_p(float(cv["regenFracPerS"])), _s(cv["durationS"])])
			d.append("The corpse cannot then be raised or exploded — in co-op, say which one you are taking.")
		"grave_brand":
			var gb: Dictionary = K("GRAVE_BRAND")
			d.append("Brands a body for %ss. The first enemy within %sm of it is rooted for %ss and the corpse is spent." % [_s(gb["lifeS"]), _s(gb["triggerR"]), _s(gb["rootS"])])
			d.append("A rooted enemy can still swing, so do not brand under your own feet.")
		"oath_unbroken":
			var ou: Dictionary = K("OATH_UNBROKEN")
			d.append("For %ss you cannot be reduced below 1 health, you deal %s more damage, and your Rage fills." % [_s(ou["durationS"]), _p(float(ou["damageMult"]) - 1.0)])
			d.append("It does not heal you — when the oath ends you are as hurt as it found you.")
		"plague_bloom":
			var pb: Dictionary = sig["bloom"]
			d.append("The first flower lasts %ss. Every %ss it can consume a corpse to seed another flower, up to %s generations." % [_s(pb["durationS"]), _s(pb["spreadEveryS"]), _s(pb["maxGenerations"])])
			d.append("Builds Withered up to %s stacks. Bodies used to spread cannot be raised." % _s(pb["witheredCap"]))
	return d
