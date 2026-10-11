class_name DmCharacterBuild
extends RefCounted
## The one place a character's combat numbers are assembled, in the order WorldScene does it:
##   base discipline -> boons + vows (applyBoons) -> Legion kit -> armor set bonuses + worn affixes -> deriveStats.
## Port of WorldScene.applyBoons / refreshStats (the pure parts) so the Godot scene just calls build().

static var _by_index: Dictionary = {}


## disciplineFor(classIndex): unknown indices play as the fallback (gravecaller). Returns a deep copy.
static func discipline_for(class_index: float) -> Dictionary:
	var d := DmCombatData.disciplines()
	var id: String = d["by_index"].get(str(int(class_index)), d["fallback"])
	return (d["disciplines"][id] as Dictionary).duplicate(true)


## Owner 2026-10-09 (baseline): only the four necromancer disciplines are playable, plus the Reaper (approved 2026-10-11, the first class with a new
## kit). The other five are shown greyed out until their kits are rebuilt; a character of one of them is asked to switch to a playable discipline
## before entering the world.
static func is_playable(class_index: float) -> bool:
	var family := String(discipline_for(class_index)["family"])
	return family == "necromancer" or family == "reaper"


## applyBoons(): returns the boon/vow/legion/set-adjusted discipline {id, family, mods}.
##   boons = boon_effects(...), vows = vow_effects(...), both Dictionaries from DmVowsBoons.
static func apply_boons(base: Dictionary, boons: Dictionary, vows: Dictionary, weapon_thrall_bonus: float, legion: Dictionary, slots: Array) -> Dictionary:
	var m: Dictionary = base["mods"]
	var mods := m.duplicate(true)
	mods["thrallCap"] = float(m["thrallCap"]) + float(boons["extraThralls"]) + weapon_thrall_bonus
	mods["maxHpMult"] = float(m["maxHpMult"]) * float(boons["maxHpMult"]) * float(vows["maxHpMult"])
	mods["essenceRegenMult"] = float(m["essenceRegenMult"]) * float(boons["essenceRegenMult"]) * float(vows["essenceRegenMult"])
	mods["thrallHpMult"] = float(m["thrallHpMult"]) * float(vows["thrallHpMult"])
	mods["corpseHeal"] = float(m["corpseHeal"]) + float(boons["corpseHeal"])
	mods["wardPerThrall"] = float(m["wardPerThrall"]) + float(boons["wardPerThrall"])
	mods["sacrificeLeavesCorpse"] = bool(m["sacrificeLeavesCorpse"]) or bool(boons["sacrificeLeavesCorpse"])
	mods["miasmaBurstsCorpses"] = bool(m["miasmaBurstsCorpses"]) or bool(boons["miasmaBurstsCorpses"])
	var d := base.duplicate()
	d["mods"] = mods
	# The Legion kit folds in before the armor sets (withSetBonuses peels the sets off again, so the legion must sit beneath them).
	if base["family"] == "necromancer":
		d["mods"] = DmLegion.apply_legion_mods(d["mods"], legion)
	# Armor set bonuses + worn affixes fold in last.
	d["mods"] = DmSetBonuses.apply_set_mods(d["mods"], DmSetBonuses.resolve(slots)["totals"])
	return d


## Everything for one character: {discipline, stats, loadout, legion, boons, vows}.
## `local` = {damageTier, legionTier, boons:{boon_id: rank}, vows:{vow_id: rank}}.
static func build(character: Dictionary, slots: Array, local: Dictionary) -> Dictionary:
	var base := discipline_for(float(character["class_index"]))
	var boons := DmVowsBoons.boon_effects(DmCombatData.nn(local.get("boons"), {}))
	var vows := DmVowsBoons.vow_effects(DmCombatData.nn(local.get("vows"), {}))
	var loadout := DmWeaponLine.resolve(DmGear.equipped_by_slot(slots), base["id"])
	var legion := DmLegion.legion_of(slots, float(DmCombatData.nn(local.get("legionTier"), 0)))
	var discipline := apply_boons(base, boons, vows, float(loadout["thrallBonus"]), legion, slots)
	var stats := DmStats.derive_stats(character, slots, discipline, float(DmCombatData.nn(local.get("damageTier"), 0)))
	return {"discipline": discipline, "stats": stats, "loadout": loadout, "legion": legion, "boons": boons, "vows": vows}
