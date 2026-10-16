class_name DmVowsBoons
extends RefCounted
## Numeric half of server/rules/content/ascension.ts: vow effects (frail vessel, brittle thralls, famished ...), boon effects, heat, ashes,
## reward multiplier. (The rules-progression track owns the save/ascend state machine in necroRules.ts; these are the pure effect folds
## the stat pipeline needs, ported here so the two tracks do not block each other.)

static func _p() -> Dictionary:
	return DmCombatData.progression()


## Steps of a vow actually sworn (clamped to the vow's cap; unknown ids give 0). `vows` is {vow_id: rank}.
static func vow_steps(vows: Variant, id: String) -> float:
	var def: Variant = _p()["vows"].get(id)
	if def == null:
		return 0.0
	var raw: Variant = vows.get(id) if vows is Dictionary else null
	var n := 0.0
	if raw != null and (raw is float or raw is int):
		n = floorf(float(raw))
		if is_nan(n):
			n = 0.0
	return maxf(0.0, minf(float(def["maxRank"]), n))


static func vow_heat(vows: Variant) -> float:
	var h := 0.0
	for id: String in _p()["vow_order"]:
		h += vow_steps(vows, id) * float(_p()["vows"][id]["heat"])
	return h


static func world_vows(vows: Variant) -> Dictionary:
	var out := {}
	for id: String in _p()["vow_order"]:
		if _p()["vows"][id]["scope"] == "world" and vow_steps(vows, id) != 0.0:
			out[id] = vow_steps(vows, id)
	return out


static func vow_effects(vows: Variant) -> Dictionary:
	var A: Dictionary = _p()["ascension"]
	var s := func(id: String) -> float: return vow_steps(vows, id)
	return {
		"levels": float(A["levelsPerRank"]) * s.call("elder_dead"),
		"enemyHpMult": 1.0 + 0.25 * s.call("iron_dead"),
		"waveSizeMult": 1.0 + 0.25 * s.call("swollen_waves"),
		"deaconMult": 1.0 + s.call("deacon_host"),
		"eliteBonus": 0.08 * s.call("elite_surge"),
		"echoes": s.call("prelate_echo"),
		"corpseLifeMult": 1.0 - 0.25 * s.call("thin_graves"),
		"maxHpMult": 1.0 - 0.12 * s.call("frail_vessel"),
		"essenceRegenMult": 1.0 - 0.2 * s.call("famished"),
		"thrallHpMult": 1.0 - 0.2 * s.call("brittle_thralls"),
		"noFlasks": s.call("dry_cellar") > 0.0,
	}


## Gold and XP multiplier for a run at `heat`.
static func ascension_reward_mult(heat: float) -> float:
	var A: Dictionary = _p()["ascension"]
	var h := floorf(heat) if not is_nan(heat) else 0.0
	return 1.0 + float(A["rewardPerRank"]) * maxf(0.0, minf(float(A["rewardHeatCap"]), h))


static func ascension_levels(rank: float) -> float:
	var A: Dictionary = _p()["ascension"]
	var r := floorf(rank) if not is_nan(rank) else 0.0
	return maxf(0.0, minf(float(_p()["vows"]["elder_dead"]["maxRank"]), r)) * float(A["levelsPerRank"])


static func legacy_vows(rank: float) -> Dictionary:
	var r := floorf(rank) if not is_nan(rank) else 0.0
	var n := maxf(0.0, minf(float(_p()["vows"]["elder_dead"]["maxRank"]), r))
	return {"elder_dead": n} if n != 0.0 else {}


static func boon_effects(ranks: Dictionary) -> Dictionary:
	var r := func(id: String) -> float:
		return maxf(0.0, minf(float(_p()["boons"][id]["maxRank"]), float(DmCombatData.nn(ranks.get(id), 0))))
	return {
		"maxHpMult": 1.0 + 0.08 * r.call("vigil"),
		"essenceRegenMult": 1.0 + 0.12 * r.call("marrow_font"),
		"damageCostMult": 1.0 - 0.1 * r.call("bone_tithe"),
		"waveCostMult": 1.0 - 0.12 * r.call("quickened_coin"),
		"startDamageTier": 2.0 * r.call("first_rites"),
		"startShards": 2.0 * r.call("shard_keeper"),
		"soulsDiscount": 8.0 * r.call("soul_hunger"),
		"unlockKillsMult": 1.0 - 0.2 * r.call("swift_seals"),
		"extraThralls": r.call("legion_pact"),
		"corpseLifeMult": 1.0 + 0.5 * r.call("lingering_dead"),
		"corpseHeal": 0.03 * r.call("grave_feast"),
		"wardPerThrall": 0.02 * r.call("bone_ward"),
		"bondedDead": r.call("bonded_dead") > 0.0,
		"sacrificeLeavesCorpse": r.call("hollow_sacrifice") > 0.0,
		"miasmaBurstsCorpses": r.call("carrion_bloom") > 0.0,
	}


## Ashes the Altar pays for a run carrying `heat`. run = {prelateKills, peakWaveTier, kills}.
static func ashes_for_run(run: Dictionary, heat: float) -> float:
	var A: Dictionary = _p()["ascension"]
	if float(run["prelateKills"]) < float(A["prelateKillsRequired"]):
		return 0.0
	var base := 10.0 + 5.0 * minf(4.0, float(run["prelateKills"]) - 1.0) + 2.0 * maxf(0.0, minf(8.0, float(run["peakWaveTier"]))) + minf(15.0, floorf(float(run["kills"]) / 300.0))
	var h := floorf(heat) if not is_nan(heat) else 0.0
	return float(DmMath.js_round(base * (1.0 + float(A["ashesPerHeat"]) * maxf(0.0, h))))


## Why a boon cannot take another rank ("" when it can). `unlocks` null = everything open.
static func boon_blocked(id: String, ranks: Dictionary, best_rank: float, unlocks: Variant = null) -> String:
	var def: Dictionary = _p()["boons"][id]
	var owned: float = float(DmCombatData.nn(ranks.get(id), 0))
	if owned >= float(def["maxRank"]):
		return "Mastered"
	if unlocks != null and not is_unlocked(unlocks, "boon:" + id):
		return "Unlock it with %d soul shards" % int(def["unlockShards"])
	if def.has("requires") and best_rank < float(def["requires"]):
		return "Ascension " + roman(float(def["requires"]))
	return ""


## Ashes for the next rank of a boon, or -1 (JS null) when mastered.
static func boon_cost(id: String, ranks: Dictionary) -> float:
	var def: Dictionary = _p()["boons"][id]
	var owned := int(float(DmCombatData.nn(ranks.get(id), 0)))
	return -1.0 if float(owned) >= float(def["maxRank"]) else float(def["cost"][owned])


static func is_unlocked(unlocks: Variant, key: String) -> bool:
	if key.begins_with("vow:"):
		var d: Variant = _p()["vows"].get(key.substr(4))
		return d != null and (float(d["unlockShards"]) == 0.0 or (unlocks != null and (unlocks as Array).has(key)))
	if key.begins_with("boon:"):
		var d2: Variant = _p()["boons"].get(key.substr(5))
		return d2 != null and (float(d2["unlockShards"]) == 0.0 or (unlocks != null and (unlocks as Array).has(key)))
	return false


static func unlock_cost(key: String) -> float:
	if key.begins_with("vow:"):
		var d: Variant = _p()["vows"].get(key.substr(4))
		return float(d["unlockShards"]) if d != null else -1.0
	if key.begins_with("boon:"):
		var d2: Variant = _p()["boons"].get(key.substr(5))
		return float(d2["unlockShards"]) if d2 != null else -1.0
	return -1.0


static func roman(n: float) -> String:
	if n <= 0.0:
		return "0"
	var m: Array = [[50, "L"], [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]]
	var out := ""
	var v := int(n)
	for pair in m:
		while v >= pair[0]:
			out += pair[1]
			v -= pair[0]
	return out
