class_name DmLegendarySets
extends RefCounted
## Drop rules of server/rules/content/legendarySets.ts (the names/lore live in the web content; only ids and odds matter to rolling).
## `rand` = Callable -> float in [0,1) (empty = randf()). `owned` = a Callable returning the item ids you already hold, as a Dictionary
## {id: true} or an Array, read only when a piece actually drops (TS: `owned?.()`).

const PARTS: Array[String] = ["head", "chest", "hands", "legs", "feet"]

static func _c() -> Dictionary:
	return DmLootData.content()["legendary"]

static func _r(rand: Callable) -> float:
	return randf() if rand.is_null() else float(rand.call())

static func item_id(set_id: String, part: String) -> String:
	return "leg_%s_%s" % [set_id, part]

## The set built for a discipline, or "" (TS: undefined).
static func set_for(discipline_id: String) -> String:
	for id in _c()["setIds"]:
		if _c()["setDiscipline"][id] == discipline_id:
			return id
	return ""

static func boss_chance(area: String) -> float:
	var c := _c()
	if c["bossAreas"].has(area):
		return float(c["bossChance"].get(area, c["drop"]["bossChance"]))
	return float(c["drop"]["starterBossChance"]) if area == c["starterArea"] else 0.0

static func elite_chance(area: String) -> float:
	return float(_c()["eliteChance"].get(area, 0.0))

## Which set a legendary drop is for a player of `discipline_id`: 70% their own, the rest shared evenly.
static func pick_set(discipline_id: String, rand: Callable) -> String:
	var own := set_for(discipline_id)
	var others: Array = []
	for id in _c()["setIds"]:
		if id != own:
			others.append(id)
	if own == "":
		return others[int(floorf(_r(rand) * others.size())) % others.size()]
	if _r(rand) < float(_c()["drop"]["ownShare"]):
		return own
	return others[int(floorf(_r(rand) * others.size())) % others.size()]

static func _has(owned: Variant, id: String) -> bool:
	if owned is Dictionary:
		return owned.has(id)
	if owned is Array:
		return owned.has(id)
	return false

## The item id of one legendary drop. With `owned` the piece is picked among the ones you do NOT have (a duplicate only comes once the set is complete).
static func pick_item(discipline_id: String, rand: Callable, owned: Variant = null) -> String:
	var set_id := pick_set(discipline_id, rand)
	var parts: Array = PARTS.duplicate()
	if owned != null:
		var missing: Array = []
		for p in PARTS:
			if not _has(owned, item_id(set_id, p)):
				missing.append(p)
		if not missing.is_empty():
			parts = missing
	return item_id(set_id, parts[int(floorf(_r(rand) * parts.size())) % parts.size()])

## The roll itself: an item id, or "" for no drop.
static func roll(discipline_id: String, chance: float, rand: Callable, owned: Callable = Callable()) -> String:
	if _r(rand) < chance:
		return pick_item(discipline_id, rand, null if owned.is_null() else owned.call())
	return ""
