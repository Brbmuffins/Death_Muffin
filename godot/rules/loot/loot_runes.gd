class_name DmLootRunes
extends RefCounted
## The rune-drop rules of server/rules/content/runes.ts that loot rolls use (pools, chances, pickRune).

static func _c() -> Dictionary:
	return DmLootData.content()["runes"]

static func _r(rand: Callable) -> float:
	return randf() if rand.is_null() else float(rand.call())

## Rune ids an area's elites/surges draw from ([] where the ground sheds none).
static func area_pool(area: String) -> Array:
	return _c()["areaPool"].get(area, [])

static func boss_pool(boss: String) -> Array:
	return _c()["bossPool"].get(boss, [])

static func elite_chance(area: String) -> float:
	return float(_c()["eliteChanceByArea"].get(area, _c()["eliteChanceDefault"]))

static func surge_chance() -> float:
	return float(_c()["surgeChance"])

static func boss_repeat_chance() -> float:
	return float(_c()["bossRepeatChance"])

## Weighted by rarity (uncommon 3, rare 2, epic 1). "" when the pool is empty.
static func pick_rune(pool: Array, rand: Callable) -> String:
	if pool.is_empty():
		return ""
	var total := 0.0
	var weights: Array[float] = []
	for id in pool:
		var w := float(_c()["weight"][_c()["rarity"][id]])
		weights.append(w)
		total += w
	var roll := _r(rand) * total
	for i in pool.size():
		roll -= weights[i]
		if roll < 0.0:
			return pool[i]
	return pool[pool.size() - 1]

## Soul shards a known rune pays instead (owner 2026-10-12): by rarity. The kill ledger credits the most of these (killRules.ts KNOWN_RUNE_SHARDS_MAX).
const KNOWN_RUNE_SHARDS := {"uncommon": 1, "rare": 2, "epic": 3}

## Every rune id, in RUNE_ORDER.
static func all_ids() -> Array:
	return _c()["order"]

## What a rune drop becomes for a player who owns `owned` (rune id -> true): the dropped rune when it is new, else another rune of
## `pool` they do not own (weighted like pick_rune), else {"shards": n} (n by the dropped rune's rarity). An empty pool = every rune.
static func resolve(rune_id: String, pool: Array, owned: Dictionary, rand: Callable = Callable()) -> Dictionary:
	if not owned.has(rune_id):
		return {"item_id": rune_id}
	var fresh: Array = []
	for id in (pool if not pool.is_empty() else all_ids()):
		if not owned.has(id) and not fresh.has(id):
			fresh.append(id)
	if not fresh.is_empty():
		return {"item_id": pick_rune(fresh, rand)}
	return {"shards": int(KNOWN_RUNE_SHARDS.get(str(_c()["rarity"].get(rune_id, "uncommon")), 1))}
