class_name DmLootRunes
extends RefCounted
## The rune-drop rules of src/content/runes.ts that loot rolls use (pools, chances, pickRune).

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
