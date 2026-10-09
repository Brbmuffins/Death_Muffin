class_name DmNecroRules
extends RefCounted
## Port of server/rules/gameplay/necroRules.ts: the server-authoritative necromancer progression rules.
## A state is a plain Dictionary with exactly the JSON shape the server stores (damageTier, waveTierOwned, waveTierActive,
## legionTier, soulShards, areaKills, unlockedAreas, bossKills, totalKills, ascension, ashes, boons, vows, unlocks, run,
## summonsPending, migrated). Every rule returns a Dictionary: {ok: true, state, ...extras} or {ok: false, error}.
## Parse JSON then run it through DmProgUtil.ints() so whole numbers are ints (error texts print them JS-style).


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


static func blank_state() -> Dictionary:
	return {
		"damageTier": 0,
		"waveTierOwned": 0,
		"waveTierActive": 0,
		"legionTier": 0,
		"soulShards": 0,
		"areaKills": {},
		"unlockedAreas": DmProgContent.get_data()["startAreas"].duplicate(),
		"bossKills": 0,
		"totalKills": 0,
		"ascension": 0,
		"ashes": 0,
		"boons": {},
		"vows": {},
		"unlocks": [],
		"run": {"prelateKills": 0, "peakWaveTier": 0, "kills": 0},
		"summonsPending": 0,
		"migrated": false,
	}


static func copy_state(s: Dictionary) -> Dictionary:
	var c: Dictionary = s.duplicate()
	c["areaKills"] = (s["areaKills"] as Dictionary).duplicate()
	c["unlockedAreas"] = (s["unlockedAreas"] as Array).duplicate()
	c["boons"] = (s["boons"] as Dictionary).duplicate()
	c["vows"] = (s["vows"] as Dictionary).duplicate()
	c["unlocks"] = (s["unlocks"] as Array).duplicate()
	c["run"] = (s["run"] as Dictionary).duplicate()
	return c


# --- Derived rules -----------------------------------------------------------

## -1 = at max tier (the TS null).
static func damage_cost(s: Dictionary) -> int:
	if s["damageTier"] >= DmUpgrades.max_tier("damage"):
		return -1
	return DmProgUtil.js_round(float(DmUpgrades.damage_cost(int(s["damageTier"]))) * float(DmAscension.boon_effects(s["boons"])["damageCostMult"]))


static func wave_cost(s: Dictionary) -> int:
	if s["waveTierOwned"] >= DmUpgrades.max_tier("wave"):
		return -1
	return DmProgUtil.js_round(float(DmUpgrades.wave_cost(int(s["waveTierOwned"]))) * float(DmAscension.boon_effects(s["boons"])["waveCostMult"]))


static func legion_cost(s: Dictionary) -> int:
	if s["legionTier"] >= DmUpgrades.max_tier("legion"):
		return -1
	return DmUpgrades.legion_cost(int(s["legionTier"]))


## Kills needed in the area before `id`'s seal breaks (Swift Seals lowers it); -1 = no seal.
static func unlock_kills(s: Dictionary, id: String) -> int:
	var u: Variant = DmProgContent.areas()[id]["unlock"]
	if u == null:
		return -1
	return maxi(1, DmProgUtil.js_round(float(u["kills"]) * float(DmAscension.boon_effects(s["boons"])["unlockKillsMult"])))


## Staff (dev access) stand past every seal: opts = {"staff": true}.
static func _is_open(s: Dictionary, id: String, opts: Variant) -> bool:
	var staff: bool = typeof(opts) == TYPE_DICTIONARY and bool((opts as Dictionary).get("staff", false))
	return staff or (s["unlockedAreas"] as Array).has(id)


static func _open_seals(s: Dictionary) -> void:
	for id in DmProgContent.area_order():
		var u: Variant = DmProgContent.areas()[id]["unlock"]
		if u == null or (s["unlockedAreas"] as Array).has(id):
			continue
		if float(DmProgUtil.nn(s["areaKills"].get(u["area"]), 0)) >= float(unlock_kills(s, id)) and (s["unlockedAreas"] as Array).has(u["area"]):
			(s["unlockedAreas"] as Array).append(id)


# --- Mutations -----------------------------------------------------------------

## Merge a periodic save: clamped deltas, derived unlocks. Never fails. input: {areaKills, shards, prelateKills, peakWaveTier, waveTierActive}.
static func apply_save(state: Dictionary, input_v: Variant, opts: Variant = null) -> Dictionary:
	var input: Dictionary = DmProgUtil.dict_or_empty(input_v)
	var lim: Dictionary = DmProgContent.limits()
	var s: Dictionary = copy_state(state)
	var budget: int = int(lim["killsPerSave"])
	var kills: int = 0
	var in_kills: Dictionary = DmProgUtil.dict_or_empty(input.get("areaKills"))
	for id in DmProgContent.area_order():
		var n: int = mini(budget, DmProgUtil.clamp_int(in_kills.get(id), 0, budget))
		if n == 0 or DmProgContent.areas()[id]["safe"] or not _is_open(s, id, opts):
			continue
		s["areaKills"][id] = int(DmProgUtil.nn(s["areaKills"].get(id), 0)) + n
		budget -= n
		kills += n
	s["totalKills"] += kills
	s["run"]["kills"] += kills
	s["soulShards"] += DmProgUtil.clamp_int(input.get("shards"), 0, int(lim["shardsPerSave"]))
	var prelate: int = mini(DmProgUtil.clamp_int(input.get("prelateKills"), 0, 10), int(s["summonsPending"]))
	s["summonsPending"] -= prelate
	s["bossKills"] += prelate
	s["run"]["prelateKills"] += prelate
	if kills > 0:
		s["run"]["peakWaveTier"] = maxi(int(s["run"]["peakWaveTier"]), DmProgUtil.clamp_int(input.get("peakWaveTier"), 0, int(s["waveTierOwned"])))
	if input.has("waveTierActive"):
		s["waveTierActive"] = DmProgUtil.clamp_int(input["waveTierActive"], 0, int(s["waveTierOwned"]))
	_open_seals(s)
	return {"ok": true, "state": s}


## upgrade: "damage" | "wave" | "legion". Returns {ok, state, gold, cost}.
static func purchase(state: Dictionary, gold: float, upgrade: Variant) -> Dictionary:
	var s: Dictionary = copy_state(state)
	if typeof(upgrade) != TYPE_STRING or not (upgrade in ["damage", "wave", "legion"]):
		return _err("Unknown upgrade")
	var cost: int = damage_cost(s) if upgrade == "damage" else (wave_cost(s) if upgrade == "wave" else legion_cost(s))
	if cost == -1:
		return _err("Already at max tier")
	if gold < cost:
		return _err("Not enough gold (need %d)" % cost)
	if upgrade == "damage":
		s["damageTier"] += 1
	elif upgrade == "legion":
		s["legionTier"] += 1
	else:
		s["waveTierOwned"] += 1
		s["waveTierActive"] = s["waveTierOwned"]
	return {"ok": true, "state": s, "gold": gold - cost, "cost": cost}


static func summon_prelate(state: Dictionary, opts: Variant = null) -> Dictionary:
	var need: int = int(DmProgContent.get_data()["bossSummonShards"])
	if state["soulShards"] < need:
		return _err("The Sundered Bell demands %d soul shards (you have %s)." % [need, DmProgUtil.fmt(state["soulShards"])])
	if not _is_open(state, "sanctum", opts):
		return _err("The Bell Sanctum is still sealed.")
	var s: Dictionary = copy_state(state)
	s["soulShards"] -= need
	s["summonsPending"] = mini(5, int(s["summonsPending"]) + 1)
	return {"ok": true, "state": s}


## Area bosses: spend that boss's shards; its area must be open. Leaves summonsPending alone.
static func summon_area_boss(state: Dictionary, boss: Variant, opts: Variant = null) -> Dictionary:
	var bosses: Dictionary = DmProgContent.bosses()
	if typeof(boss) != TYPE_STRING or not bosses.has(boss) or boss == "prelate":
		return _err("Unknown boss.")
	var def: Dictionary = bosses[boss]
	if state["soulShards"] < def["shards"]:
		return _err("%s demands %d soul shards (you have %s)." % [def["summonLabel"], int(def["shards"]), DmProgUtil.fmt(state["soulShards"])])
	if not _is_open(state, def["area"], opts):
		return _err("%s is still sealed." % DmProgContent.areas()[def["area"]]["name"])
	var s: Dictionary = copy_state(state)
	s["soulShards"] -= int(def["shards"])
	return {"ok": true, "state": s}


static func run_heat(state: Dictionary) -> int:
	return DmAscension.vow_heat(state["vows"])


static func ashes_on_ascend(state: Dictionary) -> int:
	return DmAscension.ashes_for_run(state["run"], run_heat(state))


## Burn the run: tiers and tally reset, Ashes paid for the heat, best rank rises. Seals, area kills, shards stay.
static func ascend(state: Dictionary) -> Dictionary:
	var earned: int = ashes_on_ascend(state)
	if earned == 0:
		return _err("Slay the Prelate this run before you Ascend.")
	var s: Dictionary = copy_state(state)
	var fx: Dictionary = DmAscension.boon_effects(s["boons"])
	var heat: int = run_heat(s)
	s["ascension"] = maxi(int(s["ascension"]), heat)
	s["ashes"] += earned
	s["damageTier"] = fx["startDamageTier"]
	s["waveTierOwned"] = 0
	s["waveTierActive"] = 0
	s["legionTier"] = 0
	s["soulShards"] = maxi(int(s["soulShards"]), int(fx["startShards"]))
	s["run"] = {"prelateKills": 0, "peakWaveTier": 0, "kills": 0}
	s["summonsPending"] = 0
	return {"ok": true, "state": s, "earned": earned, "heat": heat}


static func _same_vows(a: Dictionary, b: Dictionary) -> bool:
	for id in DmProgContent.vow_order():
		if DmAscension.vow_steps(a, id) != DmAscension.vow_steps(b, id):
			return false
	return true


## Swear the whole set of vows for the next run. Changing them while the run has a tally restarts the tally.
static func swear_vows(state: Dictionary, input: Variant) -> Dictionary:
	if typeof(input) != TYPE_DICTIONARY:
		return _err("Unknown vows.")
	var raw: Dictionary = input
	var defs: Dictionary = DmProgContent.vows()
	var next: Dictionary = {}
	for key in raw:
		if not defs.has(key):
			return _err("Unknown vow.")
		var n: float = DmProgUtil.js_num(raw[key])
		if is_nan(n) or is_inf(n) or n != floorf(n) or n < 0.0 or n > float(defs[key]["maxRank"]):
			return _err("%s can be sworn 0 to %d times." % [defs[key]["name"], int(defs[key]["maxRank"])])
		if n == 0.0:
			continue
		if not DmAscension.is_unlocked(state["unlocks"], DmAscension.vow_key(key)):
			return _err("%s is not unlocked yet (%d soul shards at the Altar)." % [defs[key]["name"], int(defs[key]["unlockShards"])])
		next[key] = int(n)
	var s: Dictionary = copy_state(state)
	var changed: bool = not _same_vows(state["vows"], next)
	s["vows"] = next
	var t: Dictionary = s["run"]
	var restarted: bool = changed and (t["kills"] > 0 or t["prelateKills"] > 0 or t["peakWaveTier"] > 0)
	if restarted:
		s["run"] = {"prelateKills": 0, "peakWaveTier": 0, "kills": 0}
	return {"ok": true, "state": s, "heat": DmAscension.vow_heat(next), "restarted": restarted}


## Open a vow or a boon at the Altar for soul shards. Priced here, never by the client.
static func unlock_entry(state: Dictionary, key: Variant) -> Dictionary:
	if typeof(key) != TYPE_STRING:
		return _err("Unknown unlock.")
	var cost: int = DmAscension.unlock_cost(key)
	if cost <= 0:
		return _err("Nothing to unlock.")
	if (state["unlocks"] as Array).has(key):
		return _err("Already unlocked.")
	if state["soulShards"] < cost:
		return _err("The Altar asks %d soul shards for that (you have %s)." % [cost, DmProgUtil.fmt(state["soulShards"])])
	var s: Dictionary = copy_state(state)
	s["soulShards"] -= cost
	(s["unlocks"] as Array).append(key)
	return {"ok": true, "state": s, "cost": cost}


static func buy_boon(state: Dictionary, id: Variant) -> Dictionary:
	var defs: Dictionary = DmProgContent.boons()
	if typeof(id) != TYPE_STRING or not defs.has(id):
		return _err("Unknown boon")
	var blocked: String = DmAscension.boon_blocked(id, state["boons"], state["ascension"], state["unlocks"])
	if blocked != "":
		if blocked == "Mastered":
			return _err("That boon is already mastered.")
		if blocked.begins_with("Unlock"):
			return _err("%s is not unlocked yet. %s." % [defs[id]["name"], blocked])
		return _err("Requires %s." % blocked)
	var cost: int = DmAscension.boon_cost(id, state["boons"])
	if state["ashes"] < cost:
		return _err("Not enough Ashes (need %d)" % cost)
	var s: Dictionary = copy_state(state)
	s["ashes"] -= cost
	s["boons"][id] = int(DmProgUtil.nn(s["boons"].get(id), 0)) + 1
	if id == "first_rites":
		s["damageTier"] = maxi(int(s["damageTier"]), int(DmAscension.boon_effects(s["boons"])["startDamageTier"]))
	return {"ok": true, "state": s, "cost": cost}


## One-time import of a browser save: everything clamped and cross-checked; seals re-derived from kills.
static func import_local(state: Dictionary, raw_v: Variant) -> Dictionary:
	if state["migrated"]:
		return _err("Progress was already imported.")
	var r: Dictionary = DmProgUtil.dict_or_empty(raw_v)
	var L: Dictionary = DmProgContent.limits()
	var s: Dictionary = blank_state()
	s["migrated"] = true
	s["ascension"] = DmProgUtil.clamp_int(r.get("ascension"), 0, int(L["importMaxAscension"]))
	s["vows"] = DmAscension.legacy_vows(s["ascension"])
	s["ashes"] = DmProgUtil.clamp_int(r.get("ashes"), 0, int(L["importMaxAshes"]))
	var boons: Dictionary = DmProgUtil.dict_or_empty(r.get("boons"))
	var defs: Dictionary = DmProgContent.boons()
	for id in defs:
		var want: int = DmProgUtil.clamp_int(boons.get(id), 0, int(defs[id]["maxRank"]))
		var i: int = 0
		while i < want and DmAscension.boon_blocked(id, s["boons"], s["ascension"], s["unlocks"]) == "":
			s["boons"][id] = int(DmProgUtil.nn(s["boons"].get(id), 0)) + 1
			i += 1
	s["damageTier"] = DmProgUtil.clamp_int(r.get("damageTier"), 0, DmUpgrades.max_tier("damage"))
	s["waveTierOwned"] = DmProgUtil.clamp_int(r.get("waveTierOwned"), 0, DmUpgrades.max_tier("wave"))
	s["waveTierActive"] = DmProgUtil.clamp_int(r.get("waveTierActive"), 0, s["waveTierOwned"])
	var shards_raw: Variant = r.get("shards")
	if shards_raw == null:
		shards_raw = r.get("soulShards")
	s["soulShards"] = DmProgUtil.clamp_int(shards_raw, 0, int(L["importMaxShards"]))
	var kills: Dictionary = DmProgUtil.dict_or_empty(r.get("areaKills"))
	for id in DmProgContent.area_order():
		var n: int = DmProgUtil.clamp_int(kills.get(id), 0, int(L["importMaxAreaKills"]))
		if n != 0 and not DmProgContent.areas()[id]["safe"]:
			s["areaKills"][id] = n
	s["bossKills"] = DmProgUtil.clamp_int(r.get("bossKills"), 0, int(L["importMaxBossKills"]))
	var sum: int = 0
	for id in s["areaKills"]:
		sum += int(s["areaKills"][id])
	s["totalKills"] = maxi(DmProgUtil.clamp_int(r.get("totalKills"), 0, int(L["importMaxAreaKills"]) * DmProgContent.area_order().size()), sum)
	var run: Dictionary = DmProgUtil.dict_or_empty(r.get("run"))
	s["run"] = {
		"prelateKills": DmProgUtil.clamp_int(run.get("prelateKills"), 0, s["bossKills"]),
		"peakWaveTier": DmProgUtil.clamp_int(run.get("peakWaveTier"), 0, s["waveTierOwned"]),
		"kills": DmProgUtil.clamp_int(run.get("kills"), 0, s["totalKills"]),
	}
	_open_seals(s)
	return {"ok": true, "state": s}


## Normalise a stored row (older rows may miss newer fields; unknown fields pass through).
static func normalise(raw: Variant) -> Dictionary:
	var b: Dictionary = blank_state()
	var r: Dictionary = DmProgUtil.dict_or_empty(raw)
	var has_vows: bool = r.has("vows") and typeof(r["vows"]) == TYPE_DICTIONARY
	var best: int = DmProgUtil.clamp_int(r.get("ascension"), 0, 255)
	var vows: Dictionary = {}
	if has_vows:
		for id in DmProgContent.vow_order():
			if DmAscension.vow_steps(r["vows"], id):
				vows[id] = DmAscension.vow_steps(r["vows"], id)
	var unlocks: Array = []
	if typeof(r.get("unlocks")) == TYPE_ARRAY:
		for k in r["unlocks"]:
			if typeof(k) == TYPE_STRING and DmAscension.unlock_cost(k) > 0 and not unlocks.has(k):
				unlocks.append(k)
	var out: Dictionary = b.duplicate()
	for k in r:
		out[k] = DmProgUtil.deep_copy(r[k])
	out["ascension"] = best
	out["legionTier"] = DmProgUtil.clamp_int(r.get("legionTier"), 0, DmUpgrades.max_tier("legion"))
	out["areaKills"] = DmProgUtil.dict_or_empty(r.get("areaKills")).duplicate(true)
	if typeof(r.get("unlockedAreas")) == TYPE_ARRAY and (r["unlockedAreas"] as Array).size() > 0:
		out["unlockedAreas"] = (r["unlockedAreas"] as Array).duplicate()
	else:
		out["unlockedAreas"] = b["unlockedAreas"]
	out["boons"] = DmProgUtil.dict_or_empty(r.get("boons")).duplicate(true)
	out["vows"] = vows if has_vows else DmAscension.legacy_vows(best)
	out["unlocks"] = unlocks
	var run: Dictionary = b["run"].duplicate()
	for k in DmProgUtil.dict_or_empty(r.get("run")):
		run[k] = r["run"][k]
	out["run"] = run
	return out
