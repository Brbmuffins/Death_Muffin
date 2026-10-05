class_name DmProgression
extends RefCounted
## Port of the pure state logic of src/gameplay/progression.ts (the local progression state: XP/levels, gold, upgrade tiers,
## kills, seals, shards, vows, boons, Ascension). No networking: server-mode calls that the TS fires at the API are queued in
## `outbox` for the net layer (godot/net) to send, in order, as {"type": ..., ...}. Persistence: connect `changed` and store
## to_json(); load with DmProgression.new(character, saved_dict_or_null).
##
## `local` has the exact LocalProgress JSON shape of the TS / browser save. `character` = {level, experience, gold, ...}.

signal changed
signal synced
signal error(message: String)

var character: Dictionary
var local: Dictionary
## 'local' or 'server' (server: the server owns the record; we cache and queue).
var _boons_fx: Dictionary = {}
var _boons_src: Variant = null
var mode: String = "local"
## The dev-access overlay (TS devAccess.active): seals are open to staff and their kills bank.
var dev_access: bool = false
## Optional DmChronicle (lifetime stats); gold/kill counters feed it.
var chronicle: DmChronicle = null
var pending: Dictionary = DmProgression.empty_pending()
var pending_wave_active: bool = false
## Server calls the TS would make, drained by the net layer.
var outbox: Array = []
## Set when the TS would start an urgent / lazy server save (net layer: flush now / within 45 s).
var save_dirty: bool = false
var save_urgent: bool = false


static func empty_pending() -> Dictionary:
	return {"areaKills": {}, "shards": 0, "prelateKills": 0, "peakWaveTier": 0}


static func blank() -> Dictionary:
	return {
		"v": 1,
		"damageTier": 0,
		"waveTierOwned": 0,
		"waveTierActive": 0,
		"legionTier": 0,
		"shards": 0,
		"areaKills": {},
		"unlocked": DmProgContent.get_data()["startAreas"].duplicate(),
		"bossKills": 0,
		"totalKills": 0,
		"ascension": 0,
		"ashes": 0,
		"boons": {},
		"vows": {},
		"unlocks": [],
		"run": {"prelateKills": 0, "peakWaveTier": 0, "kills": 0},
	}


## A saved LocalProgress (any vintage) -> a complete one. null/empty -> blank.
static func load_local(saved_v: Variant) -> Dictionary:
	var p: Dictionary = blank()
	if typeof(saved_v) != TYPE_DICTIONARY:
		return p
	var saved: Dictionary = DmProgUtil.ints(saved_v)
	for k in saved:
		p[k] = saved[k]
	# Saves from before Vows: rank N = N steps of Elder Dead.
	if not _truthy(saved.get("vows")):
		p["vows"] = DmAscension.legacy_vows(p["ascension"])
	# Saves from before Ascension: everything so far counts as the current run.
	if not _truthy(saved.get("run")):
		p["run"] = {"prelateKills": p["bossKills"], "peakWaveTier": p["waveTierOwned"], "kills": p["totalKills"]}
	return p


static func _truthy(v: Variant) -> bool:
	if v == null:
		return false
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING:
			return v != ""
	return true


## LocalProgress -> the shared NecroState (server/rules shape).
static func to_necro(l: Dictionary) -> Dictionary:
	return DmNecroRules.normalise({
		"damageTier": l["damageTier"],
		"waveTierOwned": l["waveTierOwned"],
		"waveTierActive": l["waveTierActive"],
		"legionTier": DmProgUtil.nn(l.get("legionTier"), 0),
		"soulShards": l["shards"],
		"areaKills": l["areaKills"],
		"unlockedAreas": l["unlocked"],
		"bossKills": l["bossKills"],
		"totalKills": l["totalKills"],
		"ascension": l["ascension"],
		"ashes": l["ashes"],
		"boons": l["boons"],
		"vows": DmProgUtil.nn(l.get("vows"), DmAscension.legacy_vows(l["ascension"])),
		"unlocks": DmProgUtil.nn(l.get("unlocks"), []),
		"run": l.get("run"),
		"summonsPending": DmProgUtil.nn(l.get("summonsPending"), 0),
		"migrated": _truthy(l.get("serverBacked")),
	})


func _init(character_: Dictionary = {}, saved: Variant = null) -> void:
	character = character_
	local = DmProgression.load_local(saved)


func to_json() -> String:
	return JSON.stringify(local)


func _copy_into(s: Dictionary) -> void:
	local["damageTier"] = s["damageTier"]
	local["waveTierOwned"] = s["waveTierOwned"]
	local["waveTierActive"] = s["waveTierActive"]
	local["legionTier"] = s["legionTier"]
	local["shards"] = s["soulShards"]
	local["areaKills"] = s["areaKills"].duplicate()
	local["unlocked"] = s["unlockedAreas"].duplicate()
	local["bossKills"] = s["bossKills"]
	local["totalKills"] = s["totalKills"]
	local["ascension"] = s["ascension"]
	local["ashes"] = s["ashes"]
	local["boons"] = s["boons"].duplicate()
	local["vows"] = s["vows"].duplicate()
	local["unlocks"] = s["unlocks"].duplicate()
	local["run"] = s["run"].duplicate()
	local["summonsPending"] = s["summonsPending"]
	local["serverBacked"] = true


## Replace local with the server's NecroState plus anything gathered since the request left.
func adopt(server_state: Dictionary) -> void:
	var input: Dictionary = pending.duplicate(true)
	if pending_wave_active:
		input["waveTierActive"] = local["waveTierActive"]
	var merged: Dictionary = DmNecroRules.apply_save(DmNecroRules.normalise(server_state), input)
	if merged["ok"]:
		_copy_into(merged["state"])
	save_local()
	synced.emit()


func save_local() -> void:
	changed.emit()


func _mark_server_dirty(urgent: bool) -> void:
	save_dirty = true
	if urgent:
		save_urgent = true
	changed.emit()


# --- XP / level / gold ----------------------------------------------------------

static func xp_to_next(level: int) -> int:
	return level * 100


## Returns the number of levels gained.
func add_xp(amount: float) -> int:
	var c: Dictionary = character
	c["experience"] = int(DmProgUtil.nn(c.get("experience"), 0)) + DmProgUtil.js_round(amount)
	var gained: int = 0
	while c["experience"] >= xp_to_next(int(c["level"])):
		c["experience"] -= xp_to_next(int(c["level"]))
		c["level"] += 1
		gained += 1
	_mark_server_dirty(gained > 0)
	return gained


func add_gold(amount: float) -> void:
	if amount > 0:
		if chronicle != null:
			chronicle.add("gold.earned", DmProgUtil.js_round(amount))
	character["gold"] = int(DmProgUtil.nn(character.get("gold"), 0)) + DmProgUtil.js_round(amount)
	_mark_server_dirty(false)


func can_afford(cost: int) -> bool:
	return int(DmProgUtil.nn(character.get("gold"), 0)) >= cost


# --- Upgrades ----------------------------------------------------------------------

## Cached per boon-rank snapshot (unlock checks, costs and stats ask for it many times per kill; callers only read it).
func boons() -> Dictionary:
	var ranks: Variant = local["boons"]
	if _boons_fx.is_empty() or ranks != _boons_src:
		_boons_src = ranks.duplicate() if ranks is Dictionary else ranks
		_boons_fx = DmAscension.boon_effects(ranks)
	return _boons_fx


## -1 = at max tier.
func damage_cost() -> int:
	if local["damageTier"] >= DmUpgrades.max_tier("damage"):
		return -1
	return DmProgUtil.js_round(float(DmUpgrades.damage_cost(int(local["damageTier"]))) * float(boons()["damageCostMult"]))


func wave_cost() -> int:
	if local["waveTierOwned"] >= DmUpgrades.max_tier("wave"):
		return -1
	return DmProgUtil.js_round(float(DmUpgrades.wave_cost(int(local["waveTierOwned"]))) * float(boons()["waveCostMult"]))


func legion_cost() -> int:
	var tier: int = int(DmProgUtil.nn(local.get("legionTier"), 0))
	return -1 if tier >= DmUpgrades.max_tier("legion") else DmUpgrades.legion_cost(tier)


func _spend_gold(cost: int) -> void:
	character["gold"] -= cost
	if chronicle != null:
		chronicle.add("gold.spent", cost)


func buy_damage() -> bool:
	var cost: int = damage_cost()
	if cost == -1 or not can_afford(cost):
		return false
	_spend_gold(cost)
	local["damageTier"] += 1
	save_local()
	_server_purchase("damage", cost)
	return true


func buy_wave() -> bool:
	var cost: int = wave_cost()
	if cost == -1 or not can_afford(cost):
		return false
	_spend_gold(cost)
	local["waveTierOwned"] += 1
	local["waveTierActive"] = local["waveTierOwned"]
	save_local()
	_server_purchase("wave", cost)
	return true


func buy_legion() -> bool:
	var cost: int = legion_cost()
	if cost == -1 or not can_afford(cost):
		return false
	_spend_gold(cost)
	local["legionTier"] = int(DmProgUtil.nn(local.get("legionTier"), 0)) + 1
	save_local()
	_server_purchase("legion", cost)
	return true


## Server mode: gold stays client-authoritative, so the net layer first saves the gold we had BEFORE this purchase
## (gold_before), then calls the purchase rule. Local mode just marks the save dirty.
func _server_purchase(upgrade: String, cost: int) -> void:
	if mode != "server":
		_mark_server_dirty(true)
		return
	outbox.append({"type": "purchase", "upgrade": upgrade, "gold_before": int(DmProgUtil.nn(character.get("gold"), 0)) + cost})


func set_active_wave_tier(tier: float) -> void:
	local["waveTierActive"] = DmProgUtil.ints(maxf(0.0, minf(float(local["waveTierOwned"]), tier)))
	pending_wave_active = true
	save_local()
	if mode == "server":
		_mark_server_dirty(false)


# --- Ascension -----------------------------------------------------------------------

func vows() -> Dictionary:
	if not local.has("vows") or local["vows"] == null:
		local["vows"] = DmAscension.legacy_vows(local["ascension"])
	return local["vows"]


func vow_fx() -> Dictionary:
	return DmAscension.vow_effects(vows())


## The rank this run plays at: the heat of the vows sworn.
func heat() -> int:
	return DmAscension.vow_heat(vows())


func ashes_on_ascend() -> int:
	return DmAscension.ashes_for_run(local["run"], heat())


func can_ascend() -> bool:
	return ashes_on_ascend() > 0


## Burn the run. Returns Ashes earned (0 = not ready).
func ascend() -> int:
	var earned: int = ashes_on_ascend()
	if earned == 0:
		return 0
	var l: Dictionary = local
	var fx: Dictionary = boons()
	var h: int = heat()
	l["ascension"] = maxi(int(l["ascension"]), h)
	l["ashes"] += earned
	l["damageTier"] = fx["startDamageTier"]
	l["waveTierOwned"] = 0
	l["waveTierActive"] = 0
	l["legionTier"] = 0
	l["shards"] = maxi(int(l["shards"]), int(fx["startShards"]))
	l["run"] = {"prelateKills": 0, "peakWaveTier": 0, "kills": 0}
	if chronicle != null:
		chronicle.ascend(h)
	l["summonsPending"] = 0
	pending = DmProgression.empty_pending()
	save_local()
	if mode == "server":
		outbox.append({"type": "ascend"})
	else:
		_mark_server_dirty(true)
	return earned


## Why these vows can't be sworn ("" = they can).
func vows_problem(next: Dictionary) -> String:
	var defs: Dictionary = DmProgContent.vows()
	for id in next:
		var n: float = float(DmProgUtil.nn(next[id], 0))
		if not defs.has(id) or n < 0 or n > float(defs[id]["maxRank"]):
			return "Unknown vow."
		if n != 0 and not DmAscension.is_unlocked(local.get("unlocks"), DmAscension.vow_key(id)):
			return "%s is not unlocked yet." % defs[id]["name"]
	return ""


## Would swearing `next` restart this run's tally?
func vows_restart_run(next: Dictionary) -> bool:
	var r: Dictionary = local["run"]
	var differs: bool = false
	var mine: Dictionary = vows()
	for id in DmProgContent.vows():
		if float(DmProgUtil.nn(next.get(id), 0)) != float(DmProgUtil.nn(mine.get(id), 0)):
			differs = true
			break
	return differs and (r["kills"] > 0 or r["prelateKills"] > 0 or r["peakWaveTier"] > 0)


func swear_vows(next: Dictionary) -> bool:
	if vows_problem(next) != "":
		return false
	var clean: Dictionary = {}
	for id in next:
		if _truthy(next[id]):
			clean[id] = next[id]
	var restart: bool = vows_restart_run(clean)
	local["vows"] = clean
	if restart:
		local["run"] = {"prelateKills": 0, "peakWaveTier": 0, "kills": 0}
	save_local()
	if mode == "server":
		outbox.append({"type": "vows", "vows": clean.duplicate()})
	else:
		_mark_server_dirty(true)
	changed.emit()
	return true


## Why a vow or boon can't be unlocked with shards ("" = it can).
func unlock_problem(key: String) -> String:
	var cost: int = DmAscension.unlock_cost(key)
	if cost <= 0:
		return "Nothing to unlock."
	if local.get("unlocks") != null and (local["unlocks"] as Array).has(key):
		return "Already unlocked."
	return "Needs %d soul shards" % cost if local["shards"] < cost else ""


func unlock_at_altar(key: String) -> bool:
	if unlock_problem(key) != "":
		return false
	local["shards"] -= DmAscension.unlock_cost(key)
	if local.get("unlocks") == null:
		local["unlocks"] = []
	(local["unlocks"] as Array).append(key)
	save_local()
	if mode == "server":
		outbox.append({"type": "unlock", "key": key})
	else:
		_mark_server_dirty(true)
	changed.emit()
	return true


## Why a boon can't be bought ("" = it can).
func boon_problem(id: String) -> String:
	var blocked: String = DmAscension.boon_blocked(id, local["boons"], local["ascension"], DmProgUtil.nn(local.get("unlocks"), []))
	if blocked != "":
		return blocked
	var cost: int = DmAscension.boon_cost(id, local["boons"])
	return "Needs %d Ashes" % cost if local["ashes"] < cost else ""


func buy_boon(id: String) -> bool:
	if boon_problem(id) != "":
		return false
	var cost: int = DmAscension.boon_cost(id, local["boons"])
	local["ashes"] -= cost
	local["boons"][id] = int(DmProgUtil.nn(local["boons"].get(id), 0)) + 1
	if id == "first_rites":
		local["damageTier"] = maxi(int(local["damageTier"]), int(boons()["startDamageTier"]))
	save_local()
	if mode == "server":
		outbox.append({"type": "boon", "id": id})
	return true


## Kills needed to open the next seal (Swift Seals lowers it).
func unlock_kills(base: float) -> int:
	return maxi(1, DmProgUtil.js_round(base * float(boons()["unlockKillsMult"])))


func record_prelate_kill() -> void:
	local["bossKills"] += 1
	local["run"]["prelateKills"] += 1
	local["summonsPending"] = maxi(0, int(DmProgUtil.nn(local.get("summonsPending"), 0)) - 1)
	pending["prelateKills"] += 1
	save_local()
	if mode == "server":
		_mark_server_dirty(true)


# --- Kills / unlocks / shards -----------------------------------------------------

## wave_tier < 0 = use the active tier (the TS default argument).
func record_kill(area: String, wave_tier: float = -1.0) -> void:
	if wave_tier < 0:
		wave_tier = float(local["waveTierActive"])
	# Dev access banks kills in sealed halls; without it a sealed hall cannot be entered.
	if not dev_access and not really_unlocked(area):
		return
	local["areaKills"][area] = int(DmProgUtil.nn(local["areaKills"].get(area), 0)) + 1
	local["totalKills"] += 1
	local["run"]["kills"] += 1
	local["run"]["peakWaveTier"] = DmProgUtil.ints(maxf(float(local["run"]["peakWaveTier"]), wave_tier))
	if chronicle != null:
		chronicle.add("kills")
		chronicle.add("kills." + area)
		chronicle.max_("peak.wave", wave_tier)
	pending["areaKills"][area] = int(DmProgUtil.nn(pending["areaKills"].get(area), 0)) + 1
	pending["peakWaveTier"] = DmProgUtil.ints(maxf(float(pending["peakWaveTier"]), wave_tier))
	if mode == "server":
		_mark_server_dirty(false)


func kills(area: String) -> int:
	return int(DmProgUtil.nn(local["areaKills"].get(area), 0))


func is_unlocked(area: String) -> bool:
	return dev_access or really_unlocked(area)


## The saved truth, ignoring the dev overlay.
func really_unlocked(area: String) -> bool:
	return DmProgContent.is_always_open(area) or (local["unlocked"] as Array).has(area)


func unlock(area: String) -> bool:
	if really_unlocked(area):
		return false
	(local["unlocked"] as Array).append(area)
	save_local()
	return true


func add_shards(n: int) -> void:
	local["shards"] += n
	pending["shards"] += n
	save_local()
	if mode == "server":
		_mark_server_dirty(false)


## Pay soul shards at the Sundered Bell.
func spend_shards(n: int) -> bool:
	if local["shards"] < n:
		return false
	local["shards"] -= n
	local["summonsPending"] = int(DmProgUtil.nn(local.get("summonsPending"), 0)) + 1
	save_local()
	if mode == "server":
		outbox.append({"type": "summon_prelate"})
	return true


## Area bosses: the boss's own cost (no Prelate summon is owed).
func spend_boss_shards(boss: String) -> bool:
	var n: int = int(DmProgContent.bosses()[boss]["shards"])
	if local["shards"] < n:
		return false
	local["shards"] -= n
	save_local()
	if mode == "server":
		outbox.append({"type": "summon_boss", "boss": boss})
	return true


## Give shards back when a summon never happened.
func refund_boss_shards(boss: String) -> void:
	add_shards(int(DmProgContent.bosses()[boss]["shards"]))
