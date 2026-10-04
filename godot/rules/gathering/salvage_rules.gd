class_name DmSalvage
extends RefCounted
## Port of src/gameplay/salvageRules.ts (the Bone Grinder). Server-authoritative in the live game (salvage.cjs rolls); the
## client uses salvage_preview for the panel. `rand` = Callable returning [0,1).

const M := preload("res://rules/core/math.gd")

const SALVAGE_SKILL := "salvaging"
const GEAR_TYPES: Array = ["weapon", "offhand", "armor_head", "armor_chest", "armor_legs", "armor_feet", "armor_hands", "ring", "trinket"]
const RARITIES: Array = ["common", "uncommon", "rare", "epic", "legendary", "relic"]
const BONUS_PER_LEVEL := 0.005
const AFFIX_BONUS := 0.12
const ILVL_BONUS := 0.003
const AFFIX_XP := 0.15
const LEVEL_CAP := 99
const RUNE_DUST: Array = [2, 4]
const REAGENT_RARE: Array = ["reagent_plague_bile", "reagent_cinder_ash"]

const TIERS := {
	"common": {"ingots": ["ingot_copper"], "planks": ["plank_oak"], "qty": [1, 1], "xp": 4, "ecto": 0.0, "rare": 0.0, "meal": 0.15},
	"uncommon": {"ingots": ["ingot_iron"], "planks": ["plank_willow"], "qty": [1, 1], "xp": 9, "ecto": 0.2, "rare": 0.0, "meal": 0.2},
	"rare": {"ingots": ["ingot_silver", "ingot_steel"], "planks": ["plank_yew", "plank_ghostwood"], "qty": [1, 2], "xp": 18, "ecto": 0.3, "rare": 0.0, "meal": 0.25},
	"epic": {"ingots": ["ingot_gold"], "planks": ["plank_blackthorn"], "qty": [2, 2], "xp": 36, "ecto": 0.4, "rare": 0.3, "meal": 0.3},
	"legendary": {"ingots": ["ingot_hell"], "planks": ["plank_bone_elder"], "qty": [2, 3], "xp": 64, "ecto": 0.5, "rare": 0.5, "meal": 0.35},
	"relic": {"ingots": ["ingot_moon"], "planks": ["plank_bone_elder"], "qty": [3, 3], "xp": 100, "ecto": 0.6, "rare": 0.7, "meal": 0.4},
}


static func is_salvage_gear(item_type: String) -> bool:
	return GEAR_TYPES.has(item_type)


static func is_salvage_rune(item_type: String) -> bool:
	return item_type == "rune"


static func is_salvageable(item_type: String) -> bool:
	return is_salvage_gear(item_type) or is_salvage_rune(item_type)


static func _tier(rarity: String) -> Dictionary:
	return TIERS[rarity] if RARITIES.has(rarity) else TIERS["common"]


## Staffs, wands, grimoires and kin give planks; everything else gives ingots.
static func yields_planks(item: Dictionary) -> bool:
	var id: String = item["id"]
	for w in ["staff", "wand", "grimoire", "tome", "crozier", "book"]:
		if id.contains(w):
			return true
	return false


## Chance of one more material from a rolled piece (0 for plain gear). item: {ilvl?, affixes?:int}.
static func instance_yield_bonus(item: Dictionary) -> float:
	var aff: int = int(item.get("affixes", 0))
	if not item.has("ilvl") and aff == 0:
		return 0.0
	return minf(0.9, float(aff) * AFFIX_BONUS + float(item.get("ilvl", 0)) * ILVL_BONUS)


static func _between(rand: Callable, r: Array) -> int:
	return int(r[0]) + int(floor(float(rand.call()) * float(int(r[1]) - int(r[0]) + 1)))


static func _pick(rand: Callable, list: Array) -> Variant:
	return list[mini(list.size() - 1, int(floor(float(rand.call()) * float(list.size()))))]


static func item_ids() -> Array:
	var ids: Dictionary = {}
	for id in ["reagent_grave_dust", "reagent_wraith_ectoplasm", "bone_meal"] + REAGENT_RARE:
		ids[id] = true
	for t in TIERS.values():
		for id in t["ingots"] + t["planks"]:
			ids[id] = true
	return ids.keys()


## Panel preview: {materials, materialQty, reagents:[{id,chance,qty}], xp, extraChance}.
static func preview(item: Dictionary) -> Dictionary:
	var t := _tier(item["rarity"])
	var rune := is_salvage_rune(item["item_type"])
	var reagents: Array = [{"id": "reagent_grave_dust", "chance": 1, "qty": RUNE_DUST if rune else [1, 2]}]
	if float(t["ecto"]) != 0.0:
		reagents.append({"id": "reagent_wraith_ectoplasm", "chance": t["ecto"], "qty": [1, 1]})
	if float(t["rare"]) != 0.0:
		for id in REAGENT_RARE:
			reagents.append({"id": id, "chance": float(t["rare"]) / 2.0, "qty": [1, 1]})
	if float(t["meal"]) != 0.0:
		reagents.append({"id": "bone_meal", "chance": t["meal"], "qty": [1, 1]})
	if rune:
		return {"materials": [], "materialQty": [0, 0], "reagents": reagents, "xp": t["xp"], "extraChance": 0}
	return {
		"materials": t["planks"] if yields_planks(item) else t["ingots"],
		"materialQty": t["qty"],
		"reagents": reagents,
		"xp": M.js_round(float(t["xp"]) * (1.0 + float(item.get("affixes", 0)) * AFFIX_XP)),
		"extraChance": instance_yield_bonus(item),
	}


## Roll one piece of gear. Returns {items:[{item_id, quantity}], xp}. Deterministic for a given rand sequence.
static func yield_for(item: Dictionary, salvaging_level: Variant, rand: Callable) -> Dictionary:
	var t := _tier(item["rarity"])
	var lv := int(floor(float(salvaging_level)))
	if lv == 0:
		lv = 1
	var level := maxi(1, mini(LEVEL_CAP, lv))
	var out: Dictionary = {}
	if is_salvage_rune(item["item_type"]):
		_add(out, "reagent_grave_dust", _between(rand, RUNE_DUST))
		if float(t["ecto"]) != 0.0 and float(rand.call()) < float(t["ecto"]):
			_add(out, "reagent_wraith_ectoplasm", 1)
		if float(t["rare"]) != 0.0 and float(rand.call()) < float(t["rare"]):
			_add(out, _pick(rand, REAGENT_RARE), 1)
		if float(t["meal"]) != 0.0 and float(rand.call()) < float(t["meal"]):
			_add(out, "bone_meal", 1)
		return {"items": _list(out), "xp": t["xp"]}
	var material: String = _pick(rand, t["planks"] if yields_planks(item) else t["ingots"])
	_add(out, material, _between(rand, t["qty"]))
	if float(rand.call()) < float(level) * BONUS_PER_LEVEL:
		_add(out, material, 1)
	_add(out, "reagent_grave_dust", _between(rand, [1, 2]))
	if float(t["ecto"]) != 0.0 and float(rand.call()) < float(t["ecto"]):
		_add(out, "reagent_wraith_ectoplasm", 1)
	if float(t["rare"]) != 0.0 and float(rand.call()) < float(t["rare"]):
		_add(out, _pick(rand, REAGENT_RARE), 1)
	if float(t["meal"]) != 0.0 and float(rand.call()) < float(t["meal"]):
		_add(out, "bone_meal", 1)
	var extra := instance_yield_bonus(item)
	if extra > 0.0 and float(rand.call()) < extra:
		_add(out, material, 1)
	return {"items": _list(out), "xp": M.js_round(float(t["xp"]) * (1.0 + float(item.get("affixes", 0)) * AFFIX_XP))}


static func _add(out: Dictionary, id: String, n: int) -> void:
	out[id] = int(out.get(id, 0)) + n


static func _list(out: Dictionary) -> Array:
	var l: Array = []
	for k in out:
		l.append({"item_id": k, "quantity": out[k]})
	return l


## Merge several yield lists into one.
static func merge_grants(lists: Array) -> Array:
	var out: Dictionary = {}
	for l in lists:
		for g in l:
			_add(out, g["item_id"], int(g["quantity"]))
	return _list(out)
