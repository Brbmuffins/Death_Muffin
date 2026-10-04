class_name DmWeaponLine
extends RefCounted
## Port of src/gameplay/weaponLine.ts: what the necromancer's equipped weapon and off-hand change. Pure.
## Tuning comes from necro_weapons.json (exported from NECRO_WEAPON_TUNING).

static func _data() -> Dictionary:
	return DmCombatData.load_json("necro_weapons")


static func no_loadout() -> Dictionary:
	return {
		"main": null, "mainTier": null, "off": null, "offTier": null,
		"spellMult": 1.0, "needleRangeMult": 1.0, "needlePierce": 0.0, "needleCadenceMult": 1.0, "needleDamageMult": 1.0,
		"needleWithered": 0.0, "reap": false, "exhumeRefund": 0.0, "thrallBonus": 0.0, "riteCooldownMult": 1.0, "bellAllyHeal": 0.0,
	}


static func _weapon_by_id(item_id: String) -> Variant:
	for w: Dictionary in _data()["weapons"]:
		if w["id"] == item_id:
			return w
	return null


static func _tier_at_least(tier: String, min_tier: String) -> bool:
	var tiers: Array = _data()["tiers"]
	return tiers.find(tier) >= tiers.find(min_tier)


## Resolve the loadout from the worn item ids (`worn` = DmGear.equipped_by_slot result, or {main_hand:{item_id}, off_hand:{item_id}}).
static func resolve(worn: Dictionary, discipline_id: String) -> Dictionary:
	var d := _data()
	var T: Dictionary = d["tuning"]
	if not (d["disciplines"] as Array).has(discipline_id):
		return no_loadout()
	var main: Variant = null
	var off: Variant = null
	if worn.get("main_hand") != null:
		main = _weapon_by_id(worn["main_hand"]["item_id"])
	if worn.get("off_hand") != null:
		off = _weapon_by_id(worn["off_hand"]["item_id"])
	if main == null and off == null:
		return no_loadout()
	var l := no_loadout()
	if main != null:
		l["main"] = main["kind"]
		l["mainTier"] = main["tier"]
		match main["kind"]:
			"staff":
				l["needleRangeMult"] = T["staff"]["needleRangeMult"]
				l["needlePierce"] = T["staff"]["pierce"]
				l["spellMult"] = T["staff"]["spellDamageMult"]
			"scythe":
				l["reap"] = true
			"wand":
				l["needleCadenceMult"] = T["wand"]["cadenceMult"]
				l["needleDamageMult"] = T["wand"]["damageMult"]
			"sickle":
				l["needleWithered"] = T["sickle"]["witheredStacks"]
				l["exhumeRefund"] = T["sickle"]["exhumeRefund"]
	if off != null:
		l["off"] = off["kind"]
		l["offTier"] = off["tier"]
		if off["kind"] == "skull_focus" and _tier_at_least(off["tier"], T["skull_focus"]["minTier"]):
			l["thrallBonus"] = T["skull_focus"]["thrallCap"]
		elif off["kind"] == "grimoire":
			l["riteCooldownMult"] = T["grimoire"]["riteCooldownMult"]
		elif off["kind"] == "mourning_bell" and discipline_id == "mourner":
			l["bellAllyHeal"] = T["mourning_bell"]["allyHealFrac"]
	return l


static func is_two_handed(item_id: String) -> bool:
	var w: Variant = _weapon_by_id(item_id)
	return w != null and bool(w["twoHanded"])


## Reach of an ability for this loadout.
static func ability_range(id: String, base_range: float, l: Dictionary, boss: bool = false) -> float:
	if id != "bone_needle":
		return base_range
	var T: Dictionary = _data()["tuning"]
	if l["reap"]:
		return T["scythe"]["bossReach"] if boss else T["scythe"]["reach"]
	return base_range * l["needleRangeMult"]


## Cooldown (ms) of an ability: wand cadence and scythe swing on the needle, grimoire on the rites.
static func ability_cooldown_ms(id: String, base_ms: float, l: Dictionary, is_primary: bool) -> float:
	if id == "bone_needle":
		return _data()["tuning"]["scythe"]["cooldownMs"] if l["reap"] else base_ms / l["needleCadenceMult"]
	return base_ms if is_primary else base_ms * l["riteCooldownMult"]


## Cast lock (ms) after a cast.
static func ability_lock_ms(id: String, base_ms: float, l: Dictionary) -> float:
	if id != "bone_needle":
		return base_ms
	return _data()["tuning"]["scythe"]["lockMs"] if l["reap"] else base_ms / l["needleCadenceMult"]


## The enemies a scythe arc strikes (candidates: [{id?, x, z, radius}]); nearest first, at most maxHits. Stable on ties.
static func reap_targets(caster: Dictionary, aim: Dictionary, candidates: Array, reach: float = -1.0) -> Array:
	var T: Dictionary = _data()["tuning"]["scythe"]
	if reach < 0.0:
		reach = T["reach"]
	var dx: float = aim["x"] - caster["x"]
	var dz: float = aim["z"] - caster["z"]
	var l := hypot2(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	var cos_max := cos(((float(T["arcDeg"]) / 2.0) * PI) / 180.0)
	var hits: Array = []
	var i := 0
	for e: Dictionary in candidates:
		var rx: float = e["x"] - caster["x"]
		var rz: float = e["z"] - caster["z"]
		var d := hypot2(rx, rz)
		i += 1
		if d > reach + float(e["radius"]):
			continue
		if d >= float(e["radius"]) and (rx * dx + rz * dz) / d < cos_max:
			continue
		hits.append({"e": e, "d": d, "i": i})
	hits.sort_custom(func(a, b): return a["d"] < b["d"] if a["d"] != b["d"] else a["i"] < b["i"])
	var out: Array = []
	for h in hits.slice(0, int(T["maxHits"])):
		out.append(h["e"])
	return out


## The enemy(ies) a staff needle pierces into: nearest behind the target, in the needle's lane.
static func pierce_targets(from: Dictionary, target: Dictionary, candidates: Array, count: int) -> Array:
	if count <= 0:
		return []
	var T: Dictionary = _data()["tuning"]["staff"]
	var dx: float = target["x"] - from["x"]
	var dz: float = target["z"] - from["z"]
	var l := hypot2(dx, dz)
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	var behind: Array = []
	var i := 0
	for e: Dictionary in candidates:
		i += 1
		if target.get("id") != null and e.get("id") == target.get("id"):
			continue
		var rx: float = e["x"] - from["x"]
		var rz: float = e["z"] - from["z"]
		var along := rx * dx + rz * dz - l
		if along <= 0.0 or along > float(T["pierceReach"]):
			continue
		if absf(rx * dz - rz * dx) > float(T["pierceLane"]) + float(e["radius"]):
			continue
		behind.append({"e": e, "along": along, "i": i})
	behind.sort_custom(func(a, b): return a["along"] < b["along"] if a["along"] != b["along"] else a["i"] < b["i"])
	var out: Array = []
	for h in behind.slice(0, count):
		out.append(h["e"])
	return out


## Math.hypot for two args.
static func hypot2(a: float, b: float) -> float:
	return sqrt(a * a + b * b)
