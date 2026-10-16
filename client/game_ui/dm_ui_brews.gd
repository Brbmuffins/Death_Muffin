class_name DmUiBrews
extends RefCounted
## Text helpers the Reliquary and the belt need: content/brews.ts (brewSummary, effect text), gameplay/beltRules.ts (empty hints) and
## content/necroWeapons.ts (necroWeaponTooltip). Numbers come from the exported data, never retyped.

const EFFECT_TEXT := {
	"damage": "+%s spell damage", "ward": "%s less damage taken", "lifesteal": "heal %s of damage dealt", "haste": "+%s cooldown recovery",
	"resist_fire": "%s less fire damage", "resist_rot": "%s less rot and plague damage", "speed": "+%s move speed", "essence": "+%s essence regeneration",
	"wisdom": "+%s experience from kills", "fortune": "+%s item drop chance",
}


static func pct(v: float) -> String:
	return "%d%%" % DmMath.js_round(v * 100.0)


static func effect_text(e: Dictionary) -> String:
	return String(EFFECT_TEXT[e["kind"]]) % pct(float(e["value"]))


static func effects_text(def: Dictionary) -> String:
	return " · ".join((def["effects"] as Array).map(func(e: Dictionary) -> String: return effect_text(e)))


static func slot_name(slot: String) -> String:
	return "Elixir" if slot == "elixir" else "Tonic"


static func summary(item_id: String) -> String:
	var d := DmContent.brew(item_id)
	if d.is_empty():
		return ""
	return "%s · %s · %ss" % [slot_name(d["slot"]), effects_text(d), DmJsFmt.num_str(float(d["seconds"]))]


static func empty_hint(slot: String) -> String:
	if slot == "heal":
		return "Healing: no potions yet. Brew Moss Tonic from Mourning Moss in the Alchemist's Wing (east door of the Chapterhouse), or loot them from the dead. Press Q to drink one."
	var kind := "elixir" if slot == "elixir" else "tonic"
	return "Empty %s slot. Click it to pick %s %s from your bag, or drag one here from the Reliquary. Brew them in the Alchemist's Wing. Press %s to drink it." % [kind, "an" if slot == "elixir" else "a", kind, "Z" if slot == "elixir" else "X"]


static func necro_weapon_tooltip(item_id: String) -> Dictionary:
	var data: Dictionary = DmCombatData.load_json("necro_weapons")
	var w: Dictionary = {}
	for x in data["weapons"]:
		if x["id"] == item_id:
			w = x
			break
	if w.is_empty():
		return {}
	var T: Dictionary = data["tuning"]
	var effect := ""
	match String(w["kind"]):
		"staff":
			effect = "Bone Needle: +%s range, pierces %d extra target. Passive: +%s spell damage. Two-handed." % [pct(T["staff"]["needleRangeMult"] - 1.0), int(T["staff"]["pierce"]), pct(T["staff"]["spellDamageMult"] - 1.0)]
		"scythe":
			var s: Dictionary = T["scythe"]
			effect = "Left click becomes a %s° reaping arc (%s m, %s m against a boss, hits up to %d); kills in the arc give +%d soul. Two-handed." % [DmJsFmt.num_str(float(s["arcDeg"])), DmJsFmt.num_str(float(s["reach"])), DmJsFmt.num_str(float(s["bossReach"])), int(s["maxHits"]), int(s["soulsPerKill"])]
		"wand":
			effect = "Bone Needle: +%s cadence, -%s damage. One-handed: pair it with an off-hand." % [pct(T["wand"]["cadenceMult"] - 1.0), pct(1.0 - T["wand"]["damageMult"])]
		"sickle":
			effect = "Bone Needle applies %d Withered stack. Passive: Exhume refunds %s of its essence. One-handed." % [int(T["sickle"]["witheredStacks"]), pct(T["sickle"]["exhumeRefund"])]
		"skull_focus":
			effect = "Off-hand. Gold tier and above: +%d thrall cap." % int(T["skull_focus"]["thrallCap"])
		"grimoire":
			effect = "Off-hand. Rites (your other spells, not the left click) recover %s faster." % pct(1.0 - T["grimoire"]["riteCooldownMult"])
		"mourning_bell":
			effect = "Off-hand. Mourner: each wraith hit heals allies in %s m for %s of their max health." % [DmJsFmt.num_str(float(T["mourning_bell"]["allyHealRange"])), pct(T["mourning_bell"]["allyHealFrac"])]
	return {"effect": effect, "level": int(data["tier_info"][w["tier"]]["level"])}
