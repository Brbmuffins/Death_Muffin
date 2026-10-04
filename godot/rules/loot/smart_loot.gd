class_name DmSmartLoot
extends RefCounted
## Port of src/gameplay/smartLoot.ts. With a discipline given, 70% of an area's class-armour weight goes to the player's own set (the
## rest is shared by the other disciplines) and necromancer weapons drop at a third of their weight for other families.
## Without a discipline ("") the table is used as listed. Entries are {item:String, weight:float}.

const OWN_ARMOR_SHARE := 0.7
const FOREIGN_WEAPON_MULT := 1.0 / 3.0

static var _cache: Dictionary = {}

static func smart_table(area: String, discipline_id: String) -> Array:
	var key := area + "|" + discipline_id
	if _cache.has(key):
		return _cache[key]
	var table: Array = DmLootData.area(area)["loot"]
	var total := 0.0
	var own_total := 0.0
	for e in table:
		if DmLootData.is_armor(e["item"]):
			total += float(e["weight"])
			if DmLootData.armor_discipline(e["item"]) == discipline_id:
				own_total += float(e["weight"])
	var necro := DmLootData.discipline_family(discipline_id) == "necromancer"
	var out: Array = []
	for e in table:
		var w := float(e["weight"])
		if DmLootData.is_armor(e["item"]) and own_total > 0.0 and own_total < total:
			var mine: bool = DmLootData.armor_discipline(e["item"]) == discipline_id
			out.append({"item": e["item"], "weight": (w / own_total) * total * OWN_ARMOR_SHARE if mine else (w / (total - own_total)) * total * (1.0 - OWN_ARMOR_SHARE)})
		elif not necro and DmLootData.is_necro_weapon(e["item"]):
			out.append({"item": e["item"], "weight": w * FOREIGN_WEAPON_MULT})
		else:
			out.append(e)
	_cache[key] = out
	return out
