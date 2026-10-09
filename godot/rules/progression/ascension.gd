class_name DmAscension
extends RefCounted
## Port of server/rules/content/ascension.ts logic: vows (heat, effects), boons, Ashes, unlock keys.
## Pure statics. Vow/boon rank maps are plain Dictionaries ({vow_id: steps}) exactly as stored in the save JSON.


static func vow_steps(vows: Variant, id: String) -> int:
	var def: Dictionary = DmProgContent.vows()[id]
	var n: float = 0.0
	if typeof(vows) == TYPE_DICTIONARY and (vows as Dictionary).has(id):
		n = DmProgUtil.floor_or_zero(vows[id])
	return int(maxf(0.0, minf(float(def["maxRank"]), n)))


static func sanitize_vows(raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for id in DmProgContent.vow_order():
		var n: int = vow_steps(raw, id)
		if n:
			out[id] = n
	return out


static func vow_heat(vows: Variant) -> int:
	var h: int = 0
	var defs: Dictionary = DmProgContent.vows()
	for id in DmProgContent.vow_order():
		h += vow_steps(vows, id) * int(defs[id]["heat"])
	return h


static func world_vows(vows: Variant) -> Dictionary:
	var out: Dictionary = {}
	var defs: Dictionary = DmProgContent.vows()
	for id in DmProgContent.vow_order():
		if defs[id]["scope"] == "world" and vow_steps(vows, id):
			out[id] = vow_steps(vows, id)
	return out


static func vow_effects(vows: Variant) -> Dictionary:
	var asc: Dictionary = DmProgContent.ascension()
	var elder: int = vow_steps(vows, "elder_dead")
	return {
		"levels": int(asc["levelsPerRank"]) * elder,
		"enemyHpMult": 1 + 0.25 * vow_steps(vows, "iron_dead"),
		"waveSizeMult": 1 + 0.25 * vow_steps(vows, "swollen_waves"),
		"deaconMult": 1 + vow_steps(vows, "deacon_host"),
		"eliteBonus": 0.08 * vow_steps(vows, "elite_surge"),
		"echoes": vow_steps(vows, "prelate_echo"),
		"corpseLifeMult": 1 - 0.25 * vow_steps(vows, "thin_graves"),
		"maxHpMult": 1 - 0.12 * vow_steps(vows, "frail_vessel"),
		"essenceRegenMult": 1 - 0.2 * vow_steps(vows, "famished"),
		"thrallHpMult": 1 - 0.2 * vow_steps(vows, "brittle_thralls"),
		"noFlasks": vow_steps(vows, "dry_cellar") > 0,
	}


## Gold and XP multiplier for a run at `heat`.
static func ascension_reward_mult(heat: Variant) -> float:
	var asc: Dictionary = DmProgContent.ascension()
	var h: float = DmProgUtil.floor_or_zero(heat)
	return 1.0 + float(asc["rewardPerRank"]) * maxf(0.0, minf(float(asc["rewardHeatCap"]), h))


static func ascension_levels(rank: Variant) -> int:
	var asc: Dictionary = DmProgContent.ascension()
	var cap: int = int(DmProgContent.vows()["elder_dead"]["maxRank"])
	var n: float = DmProgUtil.floor_or_zero(rank)
	return int(maxf(0.0, minf(float(cap), n))) * int(asc["levelsPerRank"])


## The older single-number world (old saves) is N steps of Elder Dead.
static func legacy_vows(rank: Variant) -> Dictionary:
	var cap: int = int(DmProgContent.vows()["elder_dead"]["maxRank"])
	var n: int = int(maxf(0.0, minf(float(cap), DmProgUtil.floor_or_zero(rank))))
	return {"elder_dead": n} if n else {}


static func vow_key(id: String) -> String:
	return "vow:" + id


static func boon_key(id: String) -> String:
	return "boon:" + id


static func is_unlocked(unlocks: Variant, key: String) -> bool:
	var has: bool = typeof(unlocks) == TYPE_ARRAY and (unlocks as Array).has(key)
	if key.begins_with("vow:"):
		var vd: Dictionary = DmProgContent.vows()
		var vid: String = key.substr(4)
		return vd.has(vid) and (int(vd[vid]["unlockShards"]) == 0 or has)
	if key.begins_with("boon:"):
		var bd: Dictionary = DmProgContent.boons()
		var bid: String = key.substr(5)
		return bd.has(bid) and (int(bd[bid]["unlockShards"]) == 0 or has)
	return false


## Shards the Altar asks for an unlock key; -1 = unknown key (the TS null).
static func unlock_cost(key: String) -> int:
	if key.begins_with("vow:"):
		var vd: Dictionary = DmProgContent.vows()
		var vid: String = key.substr(4)
		return int(vd[vid]["unlockShards"]) if vd.has(vid) else -1
	if key.begins_with("boon:"):
		var bd: Dictionary = DmProgContent.boons()
		var bid: String = key.substr(5)
		return int(bd[bid]["unlockShards"]) if bd.has(bid) else -1
	return -1


static func boon_effects(ranks: Variant) -> Dictionary:
	var defs: Dictionary = DmProgContent.boons()
	var r := func(id: String) -> float:
		var raw: Variant = null
		if typeof(ranks) == TYPE_DICTIONARY and (ranks as Dictionary).has(id):
			raw = ranks[id]
		# `ranks[id] ?? 0` then clamp (no Number() coercion in the TS)
		var n: float = 0.0 if raw == null else float(raw)
		return maxf(0.0, minf(float(defs[id]["maxRank"]), n))
	return DmProgUtil.ints({
		"maxHpMult": 1 + 0.08 * r.call("vigil"),
		"essenceRegenMult": 1 + 0.12 * r.call("marrow_font"),
		"damageCostMult": 1 - 0.1 * r.call("bone_tithe"),
		"waveCostMult": 1 - 0.12 * r.call("quickened_coin"),
		"startDamageTier": 2 * r.call("first_rites"),
		"startShards": 2 * r.call("shard_keeper"),
		"soulsDiscount": 8 * r.call("soul_hunger"),
		"unlockKillsMult": 1 - 0.2 * r.call("swift_seals"),
		"extraThralls": r.call("legion_pact"),
		"corpseLifeMult": 1 + 0.5 * r.call("lingering_dead"),
		"corpseHeal": 0.03 * r.call("grave_feast"),
		"wardPerThrall": 0.02 * r.call("bone_ward"),
		"bondedDead": r.call("bonded_dead") > 0,
		"sacrificeLeavesCorpse": r.call("hollow_sacrifice") > 0,
		"miasmaBurstsCorpses": r.call("carrion_bloom") > 0,
	})


## Ashes the Altar pays for a run carrying `heat`.
static func ashes_for_run(run: Dictionary, heat: Variant) -> int:
	var asc: Dictionary = DmProgContent.ascension()
	var pk: float = float(run["prelateKills"])
	if pk < float(asc["prelateKillsRequired"]):
		return 0
	var base: float = (
		10.0
		+ 5.0 * minf(4.0, pk - 1.0)
		+ 2.0 * maxf(0.0, minf(8.0, float(run["peakWaveTier"])))
		+ minf(15.0, floorf(float(run["kills"]) / 300.0))
	)
	var h: float = DmProgUtil.floor_or_zero(heat)
	return DmProgUtil.js_round(base * (1.0 + float(asc["ashesPerHeat"]) * maxf(0.0, h)))


## Why this boon can't take another rank (ignoring cost); "" = it can. `unlocks` null = "everything open".
static func boon_blocked(id: String, ranks: Dictionary, best_rank: Variant, unlocks: Variant = null) -> String:
	var def: Dictionary = DmProgContent.boons()[id]
	var owned: float = float(DmProgUtil.nn(ranks.get(id), 0))
	if owned >= float(def["maxRank"]):
		return "Mastered"
	if unlocks != null and not is_unlocked(unlocks, boon_key(id)):
		return "Unlock it with %s soul shards" % DmProgUtil.fmt(def["unlockShards"])
	if def.has("requires") and float(best_rank) < float(def["requires"]):
		return "Ascension " + roman(int(def["requires"]))
	return ""


## Ashes for the next rank; -1 when mastered (the TS null).
static func boon_cost(id: String, ranks: Dictionary) -> int:
	var owned: float = float(DmProgUtil.nn(ranks.get(id), 0))
	var def: Dictionary = DmProgContent.boons()[id]
	if owned >= float(def["maxRank"]):
		return -1
	var idx: int = int(owned)
	if idx < 0 or idx >= (def["cost"] as Array).size():
		return -1
	return int((def["cost"] as Array)[idx])


static func roman(n_in: int) -> String:
	var n: int = n_in
	if n <= 0:
		return "0"
	var map: Array = [[50, "L"], [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]]
	var out: String = ""
	for pair in map:
		while n >= int(pair[0]):
			out += String(pair[1])
			n -= int(pair[0])
	return out
