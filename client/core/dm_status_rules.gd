class_name DmStatusRules
extends RefCounted
## The status rule table for the combat core (DmCore.load_status_defs), in wire order: the table of DmStatusSet.warm()
## (client/next/status/dm_status_set.gd), built from the same data files, so no number is retyped. Keys as DmStatusSet._defs plus "name".

const IDS: Array[String] = ["slow", "ward_slow", "chill", "root", "stun", "silence", "bleed", "withered", "fracture", "hex", "sanctified",
	"incensed", "frenzy", "shrouded", "barrier", "wraithfire"]
const FOREVER := 1.0e9


## `abilities`, `statuses`, `enemies`: the parsed data/content JSON files of the same names.
static func build(abilities: Dictionary, statuses: Dictionary, enemies: Dictionary) -> Array:
	var chill: Dictionary = statuses["CHILL"]
	var hem: Dictionary = statuses["HEMORRHAGE"]
	var hex: Dictionary = statuses["BONE_HEX"]
	var san: Dictionary = statuses["SANCTIFIED"]
	var wit: Dictionary = abilities["WITHERED"]
	var fra: Dictionary = abilities["FRACTURE"]
	var cen: Dictionary = enemies["CENSER"]
	var fre: Dictionary = enemies["FRENZY"]
	var defs := {
		"slow": {"dur": 0.3, "move": float(abilities["MIASMA_SLOW"]), "slow": true},
		"ward_slow": {"dur": 0.3, "move": float(abilities["WATCHMANS_WARD_SLOW"]), "slow": true},
		"chill": {"dur": float(chill["durationS"]), "move": float(chill["moveMult"]), "atk": float(chill["attackRateMult"])},
		"root": {"dur": float(abilities["BONE_PRISON"]["rootS"]), "root": true},
		"stun": {"dur": 0.5},
		"silence": {"dur": 1.0},
		"bleed": {"dur": float(hem["durationS"]), "dot": true, "bleed": true},
		"wraithfire": {"dur": float(hem["durationS"]), "dot": true, "bleed": true},
		"withered": {"dur": float(wit["durationMs"]) / 1000.0, "dot": true, "stack": true, "max": 1.0e6},
		"fracture": {"dur": float(fra["durationMs"]) / 1000.0, "stack": true, "max": float(fra["maxStacks"]), "tps": float(fra["perStack"])},
		"hex": {"dur": float(hex["durationS"]), "dealt": float(hex["damageMult"])},
		"sanctified": {"dur": float(san["durationS"]), "taken": float(san["damageTakenMult"])},
		"incensed": {"dur": float(cen["hasteS"]), "move": float(cen["moveMult"]), "atk": float(cen["attackRateMult"])},
		"frenzy": {"dur": FOREVER, "move": float(fre["moveMult"]), "atk": float(fre["attackRateMult"])},
		"shrouded": {"dur": FOREVER, "taken": float(enemies["AFFIX_TUNING"]["shrouded"]["damageTakenMult"])},
		"barrier": {"dur": float(abilities["BONE_MANTLE"]["durationS"]), "barrier": true},
	}
	var out := []
	for id in IDS:
		var d: Dictionary = (defs[id] as Dictionary).duplicate()
		d["name"] = id
		out.append(d)
	return out
