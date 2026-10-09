class_name DmOfflineCosmetics
extends RefCounted
## Port of server/rules/gameplay/cosmeticRules.ts (capes and pets unlock rules) for the offline backend. Data: content/cosmetics.json (CAPES, PETS).
## levels = {skill_id: level}; missing skills count as level 1.

const LEVEL_CAP := 99


static func capes() -> Array:
	return DmContent.get_export("cosmetics", "CAPES")


static func pets() -> Array:
	return DmContent.get_export("cosmetics", "PETS")


static func cape_def(id: String) -> Dictionary:
	for c in capes():
		if c["id"] == id:
			return c
	return {}


static func pet_def(id: String) -> Dictionary:
	for p in pets():
		if p["id"] == id:
			return p
	return {}


static func _lvl(levels: Dictionary, skill: String) -> int:
	return maxi(1, mini(LEVEL_CAP, int(levels.get(skill, 1))))


## Total level across every skill (each is at least 1).
static func total_level(levels: Dictionary) -> int:
	var n := 0
	for s in DmGathering.SKILL_IDS:
		n += _lvl(levels, s)
	return n


## {unlocked, have, need}
static func cape_progress(cape: Dictionary, levels: Dictionary) -> Dictionary:
	if cape.has("skill") and cape["skill"] != null:
		var have := _lvl(levels, cape["skill"])
		return {"unlocked": have >= LEVEL_CAP, "have": have, "need": LEVEL_CAP}
	var have2 := total_level(levels)
	var need: Variant = cape.get("total")
	return {"unlocked": need != null and have2 >= int(need), "have": have2, "need": need}


static func cape_unlocked(id: String, levels: Dictionary) -> bool:
	var c := cape_def(id)
	return not c.is_empty() and bool(cape_progress(c, levels)["unlocked"])
