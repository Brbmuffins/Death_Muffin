class_name DmOfflineEmpower
extends RefCounted
## The Empowered-boss prize rules of server/rules/gameplay/goldSinkRules.ts that the gold-sink port (DmGoldSink) leaves out:
## empoweredLegendaryChance, rollEmpoweredPrize, rollEmpoweredInstance. `rand` is a Callable returning [0,1).


static func boss_area(boss: String) -> String:
	return String(DmContent.boss(boss).get("area", ""))


## Gold for an Empowered summon: goldPerShardSq x shards^2 (BOSSES[boss].shards).
static func empower_gold(boss: String) -> int:
	return DmGoldSink.empower_gold(int(DmContent.boss(boss)["shards"]))


static func legendary_chance(boss: String) -> float:
	return minf(float(DmGoldSink.EMPOWER["legendaryCap"]), DmLegendarySets.boss_chance(boss_area(boss)) * float(DmGoldSink.EMPOWER["legendaryMult"]))


static func _is_gear(e: Dictionary) -> bool:
	var it: Dictionary = DmContent.items().get(e["item"], {})
	return not it.is_empty() and DmAffixRules.is_affix_gear(String(it["type"]))


## {item_id, legendary}. `owned` = Dictionary {item_id: true} of the ids the player already holds.
static func roll_prize(boss: String, discipline_id: String, rand: Callable, owned: Dictionary) -> Dictionary:
	if float(rand.call()) < legendary_chance(boss):
		return {"item_id": DmLegendarySets.pick_item(discipline_id, rand, owned), "legendary": true}
	var area := boss_area(boss)
	var smart: Array = DmSmartLoot.smart_table(area, discipline_id).filter(_is_gear)
	var src: Array = smart if smart.size() > 0 else DmLootData.area(area)["loot"].filter(_is_gear)
	var pool: Array = []
	var total := 0.0
	for e in src:
		var rar: String = String(DmContent.items()[e["item"]]["rarity"])
		var w: float = float(e["weight"]) * (4.0 if (rar == "rare" or rar == "epic") else 1.0)
		pool.append({"item": e["item"], "w": w})
		total += w
	var r := float(rand.call()) * total
	for e in pool:
		r -= float(e["w"])
		if r < 0.0:
			return {"item_id": e["item"], "legendary": false}
	return {"item_id": pool[pool.size() - 1]["item"], "legendary": false}


static func roll_instance(prize: Dictionary, base_rarity: String, level: int, rand: Callable) -> Dictionary:
	var inst: Dictionary = DmAffixRules.roll_instance("legendary" if prize["legendary"] else base_rarity, level, "boss", rand)
	if prize["legendary"]:
		return inst
	var want := int(DmGoldSink.EMPOWER["prizeAffixes"])
	var i := 0
	while i < 80 and inst["affixes"].size() < want:
		inst = DmAffixRules.roll_instance("epic", level, "boss", rand)
		i += 1
	var affixes: Array = inst["affixes"].duplicate()
	var used: Dictionary = {}
	for a in affixes:
		used[DmAffixRules.affix_def(a["id"]).get("group")] = true
	for d in DmAffixRules.AFFIXES:
		if affixes.size() >= mini(want, DmAffixRules.MAX_AFFIXES):
			break
		if used.has(d["group"]):
			continue
		used[d["group"]] = true
		affixes.append({"id": d["id"], "v": DmGoldSink.reforge_value(d["id"], int(inst["ilvl"]), rand, Callable(DmAffixRules, "affix_range"))})
	return {"ilvl": inst["ilvl"], "affixes": affixes}
