class_name DmSimData
extends RefCounted
## The content tables the sim reads, cached once (shared Dictionaries from DmContent: never mutate them).
## DmNextGame.start() calls ensure(); the static helper modules assume it ran.

static var _loaded: bool = false
static var ENEMIES: Dictionary
static var AREAS: Dictionary
static var AREA_ORDER: Array
static var GLOBAL_ENEMY_CAP: float
static var BOSSES: Dictionary
static var CENSER: Dictionary
static var SCREAM: Dictionary
static var DUST: Dictionary
static var PLAGUE_FLASK: Dictionary
static var EMBER_BOLT: Dictionary
static var EMBER_DEATH: Dictionary
static var SLAG_POOL: Dictionary
static var FRENZY: Dictionary
static var WARD: Dictionary
static var BURROW: Dictionary
static var UNBIND: Dictionary
static var TEMPLAR_SHIELD: Dictionary
static var SURGE: Dictionary
static var WAVE_THEMES: Dictionary
static var PROCESSION: Dictionary
static var ELITE: Dictionary
static var AFFIX_ORDER: Array
static var AFFIX_TUNING: Dictionary
static var ABILITIES: Dictionary
static var SIGNATURE: Dictionary
static var DETONATE: Dictionary
static var FRACTURE: Dictionary
static var WITHERED: Dictionary
static var BONE_MANTLE: Dictionary
static var CARRION_SEED: Dictionary
static var GRAVE_FROST: Dictionary
static var BONE_PRISON: Dictionary
static var GRAVE_HANDS: Dictionary
static var GRAVE_OFFERING: Dictionary
static var GRAVE_BRAND: Dictionary
static var SHIELD_BASH: Dictionary
static var RALLY: Dictionary
static var MIASMA_SLOW: float
static var WATCHMANS_WARD_SLOW: float
static var LITANY_MAX_MULT: float
static var LITANY_PER_CORPSE: float
static var LITANY_PER_RESONANT: float
static var LITANY_PER_THRALL: float
static var HAG_HEX: Dictionary
static var SEXTON_HOOK: Dictionary
static var WISP_PULSE: Dictionary
static var FEN_LURE: Dictionary
static var BONE_HEX: Dictionary
static var CHILL: Dictionary
static var HEMORRHAGE: Dictionary
static var PLAGUE_BURST: Dictionary
static var SANCTIFIED: Dictionary
static var LEGEND: Dictionary
static var RUNE_TUNING: Dictionary
static var NECRO_WEAPON_TUNING: Dictionary
static var NODES: Dictionary
static var RICH_YIELD: float
static var RICH_RESPAWN: float
static var NODE_REACH: Dictionary
static var DEPTHS: Dictionary
static var DEPTHS_BANDS: Array
static var THRALL_REFRESH_MAX: float
static var NIGHTFALL_SHROUD_CHANCE: float
static var RESTLESS_SURGE_MULT: float


static func ensure() -> void:
	if _loaded:
		return
	var en := DmContent.file("enemies")
	ENEMIES = en["ENEMIES"]
	CENSER = en["CENSER"]
	SCREAM = en["SCREAM"]
	DUST = en["DUST"]
	PLAGUE_FLASK = en["PLAGUE_FLASK"]
	EMBER_BOLT = en["EMBER_BOLT"]
	EMBER_DEATH = en["EMBER_DEATH"]
	SLAG_POOL = en["SLAG_POOL"]
	FRENZY = en["FRENZY"]
	WARD = en["WARD"]
	BURROW = en["BURROW"]
	UNBIND = en["UNBIND"]
	TEMPLAR_SHIELD = en["TEMPLAR_SHIELD"]
	SURGE = en["SURGE"]
	WAVE_THEMES = en["WAVE_THEMES"]
	PROCESSION = en["PROCESSION"]
	ELITE = en["ELITE"]
	AFFIX_ORDER = en["AFFIX_ORDER"]
	AFFIX_TUNING = en["AFFIX_TUNING"]
	var ar := DmContent.file("areas")
	AREAS = ar["AREAS"]
	AREA_ORDER = ar["AREA_ORDER"]
	GLOBAL_ENEMY_CAP = float(ar["GLOBAL_ENEMY_CAP"])
	BOSSES = DmContent.bosses()
	var ab := DmContent.file("abilities")
	ABILITIES = ab["ABILITIES"]
	SIGNATURE = ab["SIGNATURE"]
	DETONATE = ab["DETONATE"]
	FRACTURE = ab["FRACTURE"]
	WITHERED = ab["WITHERED"]
	BONE_MANTLE = ab["BONE_MANTLE"]
	CARRION_SEED = ab["CARRION_SEED"]
	GRAVE_FROST = ab["GRAVE_FROST"]
	BONE_PRISON = ab["BONE_PRISON"]
	GRAVE_HANDS = ab["GRAVE_HANDS"]
	GRAVE_OFFERING = ab["GRAVE_OFFERING"]
	GRAVE_BRAND = ab["GRAVE_BRAND"]
	SHIELD_BASH = ab["SHIELD_BASH"]
	RALLY = ab["RALLY"]
	MIASMA_SLOW = float(ab["MIASMA_SLOW"])
	WATCHMANS_WARD_SLOW = float(ab["WATCHMANS_WARD_SLOW"])
	LITANY_MAX_MULT = float(ab["LITANY_MAX_MULT"])
	LITANY_PER_CORPSE = float(ab["LITANY_PER_CORPSE"])
	LITANY_PER_RESONANT = float(ab["LITANY_PER_RESONANT"])
	LITANY_PER_THRALL = float(ab["LITANY_PER_THRALL"])
	var fen := DmContent.file("fen")
	HAG_HEX = fen["HAG_HEX"]
	SEXTON_HOOK = fen["SEXTON_HOOK"]
	WISP_PULSE = fen["WISP_PULSE"]
	FEN_LURE = fen["FEN_LURE"]
	var st := DmContent.file("statuses")
	BONE_HEX = st["BONE_HEX"]
	CHILL = st["CHILL"]
	HEMORRHAGE = st["HEMORRHAGE"]
	PLAGUE_BURST = st["PLAGUE_BURST"]
	SANCTIFIED = st["SANCTIFIED"]
	LEGEND = DmContent.file("gameplay_legendary")["LEGEND"]
	RUNE_TUNING = DmContent.file("runes")["RUNE_TUNING"]
	NECRO_WEAPON_TUNING = DmContent.file("necroWeapons")["NECRO_WEAPON_TUNING"]
	var gr := DmContent.file("gameplay_gatheringRules")
	NODES = gr["NODES"]
	RICH_YIELD = float(gr["RICH_YIELD"])
	RICH_RESPAWN = float(gr["RICH_RESPAWN"])
	NODE_REACH = DmContent.file("layout")["NODE_REACH"]
	DEPTHS = DmContent.file("depths")["DEPTHS"]
	var up := DmContent.file("upgrades")
	THRALL_REFRESH_MAX = float(up["THRALL_REFRESH_MAX"])
	NIGHTFALL_SHROUD_CHANCE = float(up["NIGHTFALL_SHROUD_CHANCE"])
	RESTLESS_SURGE_MULT = float(up["RESTLESS_SURGE_MULT"])
	_loaded = true


static func has(d: Dictionary, key: String) -> bool:
	return d.has(key) and DmCombatData.truthy(d[key])
