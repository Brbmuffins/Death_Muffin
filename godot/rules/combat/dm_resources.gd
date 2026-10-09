class_name DmResources
extends RefCounted
## Port of archive/legacy-web:src/gameplay/resources.ts: per-family resource rules (Grave Essence, Rage, Oil, Resonance, Offal, Veil).
## `stats` = DerivedStats Dictionary. Unknown families fall back to the necromancer rules.

const FAMILIES: Array[String] = ["necromancer", "knight", "warden", "monk", "witch", "veil"]


static func kind_for(family: String) -> String:
	match family:
		"knight": return "rage"
		"warden": return "oil"
		"monk": return "resonance"
		"witch": return "offal"
		"veil": return "veil"
		_: return "essence"


static func label_for(family: String) -> String:
	match family:
		"knight": return "Rage"
		"warden": return "Oil"
		"monk": return "Resonance"
		"witch": return "Offal"
		"veil": return "Veil"
		_: return "Grave Essence"


static func color_for(family: String) -> String:
	match family:
		"knight": return "#8a1f2c"
		"warden": return "#f2b84b"
		"monk": return "#e8d9a0"
		"witch": return "#9a1b2a"
		"veil": return "#bff3ff"
		_: return "#7bd3c8"


static func max_for(family: String, stats: Dictionary) -> float:
	match family:
		"knight", "warden", "monk", "witch", "veil": return 100.0
		_: return float(stats["maxEssence"])


static func initial(family: String, max_value: float) -> float:
	match family:
		"knight": return 0.0
		"warden": return 60.0
		"monk": return 0.0
		"witch": return 0.0
		"veil": return 100.0
		_: return max_value * 0.6


static func on_revive(family: String, max_value: float) -> float:
	match family:
		"knight": return 0.0
		"warden": return 50.0
		"monk": return 0.0
		"witch": return 0.0
		"veil": return 100.0
		_: return max_value * 0.5


## Signed change per second. ctx = {stats, value, max, sinceHurtMs, sinceResourceGainMs}
static func passive(family: String, ctx: Dictionary) -> float:
	match family:
		"knight": return -4.0 if float(ctx["sinceHurtMs"]) > 4000.0 else 0.0
		"warden": return 3.0
		"monk": return -5.0 if float(ctx["sinceResourceGainMs"]) > 2000.0 else 0.0
		"witch": return 0.0
		"veil": return 8.0
		_: return float(ctx["stats"]["essenceRegen"])
