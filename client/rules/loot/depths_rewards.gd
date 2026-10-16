class_name DmDepthsRewards
extends RefCounted
## Port of archive/legacy-web:src/gameplay/depthsRewards.ts plus the reward formulas of server/rules/content/depths.ts it reads (floorBonus, chestBonus, chestDrops,
## chest rune odds, depthLootArea, the weighted roster behind averageKill). The Depths' wave/affix/roster logic is the combat/world
## tracks' (not here). Everything comes from loot tables the game already has. `rand` = Callable (empty = randf()).

const CHEST_EVERY := 5
const MIN_LEVEL := 12

static func _r(rand: Callable) -> float:
	return randf() if rand.is_null() else float(rand.call())

static func _d() -> Dictionary:
	return DmLootData.content()["depths"]

## Which hunting ground's table a depth rolls from.
static func depth_loot_area(depth: float) -> String:
	if depth >= 30: return "fen"
	if depth >= 20: return "pyre"
	if depth >= 15: return "cloister"
	if depth >= 10: return "sanctum"
	if depth >= 5: return "coliseum"
	return "ossuary"

## The weighted roster of a floor [{id, weight}] (ordered like the TS Map): exported for the band start depths 0,1,5,10,15.
static func depth_roster(depth: float) -> Array:
	var start := 0
	for b in [1, 5, 10, 15]:
		if depth >= b:
			start = b
	return _d()["rosters"][str(start)]

## Average gold and XP of one kill on a floor at enemy level `level`.
static func average_kill(depth: float, level: float) -> Dictionary:
	var roster := depth_roster(depth)
	var total := 0.0
	for e in roster:
		total += float(e["weight"])
	if total == 0.0:
		total = 1.0
	var gold := 0.0
	var xp := 0.0
	for e in roster:
		var d := DmLootData.enemy(e["id"])
		gold += ((float(e["weight"]) / total) * (float(d["gold"][0]) + float(d["gold"][1]))) / 2.0
		xp += (float(e["weight"]) / total) * float(d["xp"])
	return {"gold": gold * (1.0 + 0.15 * (level - 1.0)), "xp": xp * (1.0 + 0.25 * (level - 1.0))}

static func floor_bonus(depth: float, level: float) -> Dictionary:
	var k := average_kill(depth, level)
	return {"gold": DmAffixRules.js_round(k["gold"] * float(_d()["floorBonusKills"])), "xp": DmAffixRules.js_round(k["xp"] * float(_d()["floorBonusKills"]))}

static func chest_bonus(depth: float, level: float) -> Dictionary:
	var k := average_kill(depth, level)
	var tier := floorf(depth / CHEST_EVERY)
	var mult := 1.0 + 0.12 * (tier - 1.0)
	return {"gold": DmAffixRules.js_round(k["gold"] * float(_d()["chestKills"]) * mult), "xp": DmAffixRules.js_round(k["xp"] * float(_d()["chestKills"]) * mult)}

## A chest holds this many drops (the first is always gear): 3 at depth 5, one more every 10 floors.
static func chest_drops(depth: float) -> int:
	return 3 + int(floorf(maxf(0.0, depth - 5.0) / 10.0))

static func chest_rune_chance(depth: float) -> float:
	return minf(0.7, 0.25 + 0.04 * (floorf(depth / CHEST_EVERY) - 1.0))

static func chest_rune_pool(depth: float) -> Array:
	var out: Array = []
	var rc: Dictionary = DmLootData.content()["runes"]
	for id in rc["order"]:
		if rc["rarity"][id] != "epic" or depth >= 10:
			out.append(id)
	return out

## A floor clear's gold/XP and, most of the time, an item. -> {gold, materialGold, xp, drop|null}
static func roll_floor_clear(depth: float, level: float, rand: Callable = Callable(), discipline_id: String = "") -> Dictionary:
	var bonus := floor_bonus(depth, level)
	if _r(rand) >= float(_d()["floorDropChance"]):
		return {"gold": bonus["gold"], "xp": bonus["xp"], "materialGold": 0, "drop": null}
	var s := DmLoot.settle_combat_drop(DmLoot.roll_item(depth_loot_area(depth), rand, 1, discipline_id), true)
	return {"gold": bonus["gold"], "xp": bonus["xp"], "materialGold": s["gold"], "drop": s["drop"]}

## A piece of gear from the depth's ground (rolled until the table yields some).
static func roll_gear_drop(depth: float, rand: Callable = Callable(), discipline_id: String = "") -> Dictionary:
	var area := depth_loot_area(depth)
	for i in 60:
		var d := DmLoot.roll_item(area, rand, 1, discipline_id)
		var meta := DmLootData.item(d["item_id"])
		if not meta.is_empty() and DmAffixRules.is_affix_gear(meta["type"]):
			return d
	return {"item_id": "helm_gold", "quantity": 1}

## The chest of a fifth floor. -> {gold, materialGold, xp, drops}
static func roll_chest(depth: float, level: float, rand: Callable = Callable(), discipline_id: String = "") -> Dictionary:
	var bonus := chest_bonus(depth, level)
	var area := depth_loot_area(depth)
	var drops: Array = [roll_gear_drop(depth, rand, discipline_id)]
	var material_gold := 0
	for i in range(1, chest_drops(depth)):
		var s := DmLoot.settle_combat_drop(DmLoot.roll_item(area, rand, 1, discipline_id), true)
		if s["drop"] != null:
			drops.append(s["drop"])
		material_gold += s["gold"]
	if _r(rand) < chest_rune_chance(depth):
		var id := DmLootRunes.pick_rune(chest_rune_pool(depth), rand)
		if id != "":
			drops.append({"item_id": id, "quantity": 1})
	return {"gold": bonus["gold"], "materialGold": material_gold, "xp": bonus["xp"], "drops": drops}
