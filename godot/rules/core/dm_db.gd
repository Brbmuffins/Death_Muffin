class_name DmDb
extends RefCounted
## The one content registry: owns loading, caching and lookup of every dataset under res://data/ (see godot/data/README.md).
## Static class, no autoload. The per-domain loaders (DmContent, DmCombatData, DmLootData, DmProgContent, DmGatherData, DmData (slice),
## DmPaData, DmWfxData, DmCounselData) are thin wrappers over this; new code should call DmDb directly.
##
## Raw results are SHARED and cached: never mutate them (duplicate(true) first). Numbers arrive as floats (JSON); wrappers that
## want ints normalise on top.
##
## One copy of each fact: the "loot" and "progression" views below are PROJECTIONS of data/content/* (built on first use), not files.
## data/combat/progression.json keeps only what content/* does not carry; the rest is composed back in by combat().

const ROOT := "res://data/"

## Every dataset file that lives under data/ (relative path without ".json"), by domain. data/content/* is enumerated from its manifest.
const DOMAINS := {
	"combat": ["abilities", "affixes", "armor", "brews", "disciplines", "enemies", "necro_weapons", "progression", "statuses"],
	"gathering": ["gathering"],
	"onboarding": ["tips"],
	"panels_a": ["atlas", "codex_rows"],
	"progression": ["extras"],
	"sim": ["world"],
	"slice": ["assets_used", "enemies", "hero", "npcs", "world"],
	"world_fx": ["fx"],
}

## Keys of combat/progression.json that are composed from content/ rather than stored (so a re-export cannot resurrect a duplicate).

static var _cache: Dictionary = {}


## Drop every cache (tests / hot reload). Wrappers keep their own derived caches: call their reset() too where they have one.
static func reset() -> void:
	_cache = {}


# ---- generic ------------------------------------------------------------------------------------------------------------------

static func path_of(rel: String) -> String:
	return ROOT + rel + ".json"


static func exists(rel: String) -> bool:
	return FileAccess.file_exists(path_of(rel))


## Parsed JSON of data/<rel>.json (rel without extension, e.g. "content/items"). Cached; null (plus an error) when missing/invalid.
static func raw(rel: String) -> Variant:
	if _cache.has(rel):
		return _cache[rel]
	var path := path_of(rel)
	var v: Variant = null
	if not FileAccess.file_exists(path):
		push_error("DmDb: missing dataset %s" % path)
	else:
		v = JSON.parse_string(FileAccess.get_file_as_string(path))
		if v == null:
			push_error("DmDb: cannot parse %s" % path)
	_cache[rel] = v
	return v


## Same as raw() but a fresh, uncached parse the caller may mutate.
static func fresh(rel: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path_of(rel)))


static func _dict(v: Variant) -> Dictionary:
	return v if typeof(v) == TYPE_DICTIONARY else {}


## Every dataset file as a relative path (no extension), sorted. Used by the data test to prove nothing under data/ is unregistered.
static func all_files() -> PackedStringArray:
	var out := PackedStringArray()
	for domain in DOMAINS:
		for n in DOMAINS[domain]:
			out.append("%s/%s" % [domain, n])
	for n in content_names():
		out.append("content/" + n)
	out.sort()
	return out


# ---- content/* (export-content.ts) ------------------------------------------------------------------------------------------

static func content_manifest() -> Dictionary:
	return _dict(raw("content/manifest"))


## Names of every content file (without .json), including "manifest".
static func content_names() -> PackedStringArray:
	var out := PackedStringArray(["manifest"])
	for k in content_manifest().get("files", {}).keys():
		out.append(k)
	return out


## data/content/<name>.json as { ExportName: value }; {} (plus an error) when unknown.
static func content(name: String) -> Dictionary:
	return _dict(raw("content/" + name))


static func content_export(name: String, export_name: String) -> Variant:
	return content(name).get(export_name)


# ---- other domains ---------------------------------------------------------------------------------------------------------------

## data/combat/<name>.json. "progression" is composed: the stored residual (kit, new_blood) plus the facts content/ already owns.
static func combat(name: String) -> Variant:
	if name != "progression":
		return raw("combat/" + name)
	if not _cache.has("combat/progression+composed"):
		var out: Dictionary = (_dict(raw("combat/progression"))).duplicate()
		var u := content("upgrades")
		var a := content("ascension")
		out["damage_upgrade"] = u.get("DAMAGE_UPGRADE")
		out["wave_upgrade"] = u.get("WAVE_UPGRADE")
		out["legion_upgrade"] = u.get("LEGION_UPGRADE")
		out["thrall_refresh_max"] = u.get("THRALL_REFRESH_MAX")
		out["wave_milestones"] = u.get("WAVE_MILESTONES")
		out["nightfall_shroud_chance"] = u.get("NIGHTFALL_SHROUD_CHANCE")
		out["restless_surge_mult"] = u.get("RESTLESS_SURGE_MULT")
		out["ascension"] = a.get("ASCENSION")
		out["vows"] = a.get("VOWS")
		out["vow_order"] = a.get("VOW_ORDER")
		out["boons"] = a.get("BOONS")
		out["boon_order"] = a.get("BOON_ORDER")
		out["stat_effects"] = content("gameplay_characterStats").get("STAT_EFFECTS")
		out["chain"] = content("gameplay_killChain").get("CHAIN")
		_cache["combat/progression+composed"] = out
	return _cache["combat/progression+composed"]


static func gathering() -> Dictionary:
	return _dict(raw("gathering/gathering"))


static func tips() -> Dictionary:
	return _dict(raw("onboarding/tips"))


static func panels_a(name: String) -> Dictionary:
	return _dict(raw("panels_a/" + name))


## Slice view-models (world, enemies, hero, npcs, assets_used).
static func slice(name: String) -> Variant:
	return raw("slice/" + name)


static func world_fx() -> Dictionary:
	return _dict(raw("world_fx/fx"))


## The exact-sim world (obstacles, sight blockers, ...) with "d:<hex>" doubles decoded. FRESH each call: the sim may mutate it.
static func sim_world() -> Dictionary:
	return _dict(DmSimExact.decode(fresh("sim/world")))


# ---- projections (derived from content/*; there is no file) ----------------------------------------------------------------------

## What the loot rules read (DmLootData.content()): a subset of content/* in a flat shape. Built once.
static func loot_view() -> Dictionary:
	if _cache.has("view/loot"):
		return _cache["view/loot"]
	var areas_src: Dictionary = content("areas").get("AREAS", {})
	var areas := {}
	for id in areas_src:
		var a: Dictionary = areas_src[id]
		var o := {}
		if a.has("itemChance"):
			o["itemChance"] = a["itemChance"]
		if a.has("loot"):
			o["loot"] = a["loot"]
		o["scaling"] = _truthy(a.get("scaling"))
		areas[id] = o
	var enemies_src := content("enemies")
	var enemies := {}
	for id in enemies_src.get("ENEMIES", {}):
		var d: Dictionary = enemies_src["ENEMIES"][id]
		enemies[id] = {"gold": d.get("gold"), "xp": d.get("xp")}
	var elite_src: Dictionary = enemies_src.get("ELITE", {})
	var items := {}
	for id in content("items").get("ITEMS", {}):
		var m: Dictionary = content("items")["ITEMS"][id]
		items[id] = {"name": m.get("name"), "type": m.get("type"), "rarity": m.get("rarity"), "sell": m.get("sell"),
			"stack": m.get("stack"), "offlineStats": m.get("offlineStats")}
	var armor := {}
	for id in content("armorSets").get("ARMOR_BY_ID", {}):
		armor[id] = content("armorSets")["ARMOR_BY_ID"][id].get("disciplineId")
	var necro: Array = content("necroWeapons").get("NECRO_WEAPON_BY_ID", {}).keys()
	var family := {}
	for id in content("disciplines").get("DISCIPLINES", {}):
		family[id] = content("disciplines")["DISCIPLINES"][id].get("family")
	var difficulty := {}
	for id in content("difficulty").get("DIFFICULTIES", {}):
		difficulty[id] = content("difficulty")["DIFFICULTIES"][id].get("rewardMult")
	var rg := content("reagents")
	var rn := content("runes")
	var rarity := {}
	for id in rn.get("RUNE_ORDER", []):
		rarity[id] = rn["RUNES"][id].get("rarity")
	var lg := content("legendarySets")
	var set_disc := {}
	for id in lg.get("LEGENDARY_SET_IDS", []):
		set_disc[id] = lg["LEGENDARY_SETS"][id].get("disciplineId")
	var dp := content("depths")
	var rosters_src: Dictionary = content("computed").get("depthRosters", {})
	var rosters := {}
	for d in [0, 1, 5, 10, 15]:
		rosters[str(d)] = rosters_src.get(str(maxi(d, 1)))
	var view := {
		"bagSlots": content("gameplay_gatheringRules").get("BAG_SLOTS"),
		"areas": areas,
		"enemies": enemies,
		"elite": {"goldMult": elite_src.get("goldMult"), "xpMult": elite_src.get("xpMult")},
		"items": items,
		"armor": armor,
		"necroWeapons": necro,
		"disciplineFamily": family,
		"difficulty": difficulty,
		"reagents": {"area": rg.get("AREA_REAGENT_DROPS"), "enemy": rg.get("ENEMY_REAGENT_DROPS"),
			"eliteMult": rg.get("ELITE_REAGENT_MULT"), "bossIchor": rg.get("BOSS_ICHOR")},
		"runes": {"order": rn.get("RUNE_ORDER"), "rarity": rarity, "weight": rn.get("RUNE_WEIGHT"), "areaPool": rn.get("AREA_RUNE_POOL"),
			"bossPool": rn.get("BOSS_RUNE_POOL"), "eliteChanceByArea": rn.get("ELITE_RUNE_CHANCE_BY_AREA"),
			"eliteChanceDefault": rn.get("ELITE_RUNE_CHANCE"), "surgeChance": rn.get("SURGE_RUNE_CHANCE"),
			"bossRepeatChance": rn.get("BOSS_REPEAT_RUNE_CHANCE")},
		"legendary": {"setIds": lg.get("LEGENDARY_SET_IDS"), "setDiscipline": set_disc, "drop": lg.get("LEGENDARY_DROP"),
			"bossAreas": lg.get("LEGENDARY_BOSS_AREAS"), "starterArea": lg.get("LEGENDARY_STARTER_AREA"),
			"bossChance": lg.get("LEGENDARY_BOSS_CHANCE"), "eliteChance": lg.get("LEGENDARY_ELITE_CHANCE")},
		"depths": {"rosters": rosters, "minLevel": dp.get("DEPTHS", {}).get("minLevel"), "chestEvery": dp.get("DEPTHS", {}).get("chestEvery"),
			"floorDropChance": dp.get("FLOOR_DROP_CHANCE"), "floorBonusKills": dp.get("FLOOR_BONUS_KILLS"), "chestKills": dp.get("CHEST_KILLS")},
	}
	_cache["view/loot"] = view
	return view


## What the progression rules read (DmProgContent.get_data(), before int normalisation): content/* + progression/extras. Built once.
static func progression_view() -> Dictionary:
	if _cache.has("view/progression"):
		return _cache["view/progression"]
	var areas_src: Dictionary = content("areas").get("AREAS", {})
	var areas := {}
	var always_open := {}
	for id in areas_src:
		var a: Dictionary = areas_src[id]
		areas[id] = {"name": a.get("name"), "safe": a.get("safe"), "instance": _truthy(a.get("instance")), "unlock": a.get("unlock")}
		always_open[id] = a.get("unlock") == null and not _truthy(a.get("instance"))
	var bosses_src: Dictionary = content("bosses").get("BOSSES", {})
	var bosses := {}
	for id in bosses_src:
		var b: Dictionary = bosses_src[id]
		bosses[id] = {"area": b.get("area"), "shards": b.get("shards"), "summonLabel": b.get("summonLabel")}
	var asc := content("ascension")
	var up := content("upgrades")
	var ex := _dict(raw("progression/extras"))
	var cost: Dictionary = ex.get("upgradeCosts", {})
	var du: Dictionary = up.get("DAMAGE_UPGRADE", {})
	var wu: Dictionary = up.get("WAVE_UPGRADE", {})
	var lu: Dictionary = up.get("LEGION_UPGRADE", {})
	var milestones: Array = []
	for m in content("gameplay_milestones").get("MILESTONES", []):
		var id: String = m["id"]
		var kind := ""
		var area := ""
		var n := 0.0
		if id.begins_with("kills."):
			kind = "totalKills"
			n = float(id.substr(6))
		elif id.begins_with("chain."):
			kind = "bestChain"
			n = float(id.substr(6))
		else:
			kind = "areaKills"
			var rest := id.substr(5)
			var dot := rest.rfind(".")
			area = rest.substr(0, dot)
			n = float(rest.substr(dot + 1))
		milestones.append({"id": id, "title": m.get("title"), "text": m.get("text"), "gold": m.get("gold"), "kind": kind, "area": area, "n": n})
	var view := {
		"areaOrder": content("areas").get("AREA_ORDER"),
		"areas": areas,
		"bossSummonShards": content("areas").get("BOSS_SUMMON_SHARDS"),
		"bossIds": content("bosses").get("BOSS_IDS"),
		"bosses": bosses,
		"ascension": asc.get("ASCENSION"),
		"vows": asc.get("VOWS"),
		"vowOrder": asc.get("VOW_ORDER"),
		"boons": asc.get("BOONS"),
		"boonOrder": asc.get("BOON_ORDER"),
		"upgrades": {
			"damage": {"maxTier": du.get("maxTier"), "perTier": du.get("perTier"), "costBase": cost["damage"]["costBase"], "costGrowth": cost["damage"]["costGrowth"]},
			"wave": {"maxTier": wu.get("maxTier"), "costBase": cost["wave"]["costBase"], "costGrowth": cost["wave"]["costGrowth"]},
			"legion": {"maxTier": lu.get("maxTier"), "perTier": lu.get("perTier"), "speedPerTier": lu.get("speedPerTier"),
				"costBase": cost["legion"]["costBase"], "costGrowth": cost["legion"]["costGrowth"]},
			"thrallRefreshMax": up.get("THRALL_REFRESH_MAX"),
			"waveMilestones": up.get("WAVE_MILESTONES"),
			"nightfallShroudChance": up.get("NIGHTFALL_SHROUD_CHANCE"),
			"restlessSurgeMult": up.get("RESTLESS_SURGE_MULT"),
		},
		"limits": content("gameplay_necroRules").get("NECRO_LIMITS"),
		"chain": content("gameplay_killChain").get("CHAIN"),
		"milestones": milestones,
		"startAreas": ex.get("startAreas"),
		"alwaysOpen": always_open,
	}
	_cache["view/progression"] = view
	return view


## JS truthiness (!!v) for JSON values.
static func _truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING:
			return v != ""
	return true
