class_name DmAffixRules
extends RefCounted
## Port of src/gameplay/affixRules.ts: item level and affixes (the pure rules for server-rolled loot instances).
## An instance is {ilvl:int, affixes:[{id:String, v:int}]}. `rand` arguments are Callables returning a float in [0,1) (pass `rng.next`);
## an empty Callable falls back to randf() (TS: Math.random). The server owns every real roll; rolling here is for the offline
## edition / tests and mirrors the shared module the server bundles.

const MAX_AFFIXES := 3
const ILVL_MAX := 99
const ILVL_REACH := 10
const WIDE := 0.35
const DROP_SOURCES: Array[String] = ["kill", "elite", "boss", "first_kill", "surge"]
const AFFIX_GEAR_TYPES: Array[String] = ["weapon", "offhand", "armor_head", "armor_chest", "armor_legs", "armor_feet", "armor_hands", "ring", "trinket"]
const SOURCE_ILVL := {"kill": 0, "elite": 2, "boss": 4, "first_kill": 5, "surge": 2}
const RARITY_RANK: Array[String] = ["common", "uncommon", "rare", "epic", "legendary", "relic"]
const COUNT_WEIGHTS := {
	"common": [60, 30, 9, 1], "uncommon": [40, 38, 18, 4], "rare": [22, 38, 30, 10],
	"epic": [10, 30, 40, 20], "legendary": [0, 15, 45, 40], "relic": [0, 15, 45, 40],
}
const SOURCE_COUNT := {
	"kill": {"mult": [1, 1, 1, 1], "min": 0},
	"elite": {"mult": [0.6, 1, 1.4, 1.8], "min": 0},
	"surge": {"mult": [0.5, 1, 1.5, 2], "min": 0},
	"boss": {"mult": [0.15, 0.8, 1.6, 2.4], "min": 1},
	"first_kill": {"mult": [0, 0.3, 1.6, 2.6], "min": 2},
}
const STAT_NAME := {"stat_str": "STR", "stat_agi": "AGI", "stat_int": "INT", "stat_vit": "VIT"}

## The pool, in TS order (ids are stored in the database: never rename one). {id, kind, word, group, necro, weight, unit, stat?}
static var AFFIXES: Array[Dictionary] = _build_affixes()
static var _by_id: Dictionary = {}

static func _stat_def(stat: String, kind: String, word: String) -> Dictionary:
	return {"id": ("p_" if kind == "prefix" else "s_") + stat.substr(5), "kind": kind, "word": word, "group": stat, "necro": false, "weight": 9, "unit": "stat", "stat": stat}

static func _build_affixes() -> Array[Dictionary]:
	var a: Array[Dictionary] = [
		_stat_def("stat_str", "prefix", "Brutal"), _stat_def("stat_agi", "prefix", "Fleet"),
		_stat_def("stat_int", "prefix", "Occult"), _stat_def("stat_vit", "prefix", "Stout"),
		_stat_def("stat_str", "suffix", "of the Reaver"), _stat_def("stat_agi", "suffix", "of the Hound"),
		_stat_def("stat_int", "suffix", "of the Seer"), _stat_def("stat_vit", "suffix", "of the Tomb"),
		{"id": "p_thrall_dmg", "kind": "prefix", "word": "Gravebound", "group": "thrall_dmg", "necro": true, "weight": 13, "unit": "pct"},
		{"id": "s_thrall_hp", "kind": "suffix", "word": "of the Legion", "group": "thrall_hp", "necro": true, "weight": 13, "unit": "pct"},
		{"id": "p_essence_regen", "kind": "prefix", "word": "Whispering", "group": "essence_regen", "necro": true, "weight": 11, "unit": "pct"},
		{"id": "s_miasma", "kind": "suffix", "word": "of the Rotting Mist", "group": "miasma", "necro": true, "weight": 9, "unit": "pct"},
		{"id": "p_withered", "kind": "prefix", "word": "Blighted", "group": "withered", "necro": true, "weight": 8, "unit": "count"},
		{"id": "s_ward", "kind": "suffix", "word": "of the Ossuary Wall", "group": "ward", "necro": true, "weight": 9, "unit": "wardPct"},
	]
	return a

static func _index() -> Dictionary:
	if _by_id.is_empty():
		for d in AFFIXES:
			_by_id[d["id"]] = d
	return _by_id

static func affix_def(id: String) -> Dictionary:
	return _index().get(id, {})

# --- JS-number helpers -------------------------------------------------------------------------------------------------------
## JS Math.round: halves round toward +infinity.
static func js_round(x: float) -> int:
	return int(floorf(x + 0.5))

static func clamp_int(x: float, lo: float, hi: float) -> int:
	return int(maxf(lo, minf(hi, float(js_round(x)))))

static func is_integer(v: Variant) -> bool:
	return (v is int) or ((v is float) and is_finite(v) and v == floorf(v))

static func num(v: Variant) -> String:
	## A whole number prints without ".0" (JS template literals).
	if is_integer(v):
		return str(int(v))
	return str(v)

## A +-spread window around the centre, as whole numbers.
static func around(centre: float, cap: float, floor_: float = 1.0, spread: float = 0.3) -> Array:
	var lo := clamp_int(centre * (1.0 - spread), floor_, cap)
	var hi := clamp_int(maxf(centre * (1.0 + spread), float(lo)), float(lo), cap)
	return [lo, hi]

static func is_affix_gear(item_type: String) -> bool:
	return AFFIX_GEAR_TYPES.has(item_type)

## Range generation `gen`: 0 = current, 1.. = legacy builds (newest legacy last in TS order).
static func _range_gen(id: String, L: int, gen: int) -> Array:
	var l := float(L)
	match id:
		"p_thrall_dmg":
			if gen == 0: return around(10.0 * (9.2 + 0.1 * l), 340, 1, WIDE)
			if gen == 1: return around(10.0 * (5.5 + 0.2 * l), 300)
			return around(10.0 * (6.5 + 0.1 * l), 300)
		"s_thrall_hp":
			if gen == 0: return around(10.0 * (12.5 + 0.3 * l), 540, 1, WIDE)
			if gen == 1: return around(10.0 * (10.6 + 0.38 * l), 500)
			return around(10.0 * (9.5 + 0.34 * l), 500)
		"p_essence_regen":
			if gen == 0: return around(10.0 * (13.0 + 0.55 * l), 760, 1, WIDE)
			if gen == 1: return around(10.0 * (10.0 + 0.42 * l), 600)
			return around(10.0 * (10.0 + 0.5 * l), 600)
		"s_miasma":
			if gen == 0: return around(10.0 * (7.6 + 0.17 * l), 550, 1, WIDE)
			if gen == 1: return around(10.0 * (5.2 + 0.22 * l), 400)
			return around(10.0 * (5.2 + 0.12 * l), 400)
		"p_withered":
			if gen == 0: return [1, clamp_int(3.0 + floorf(l / 12.0), 3, 4)]
			if gen == 1: return [1, clamp_int(2.0 + floorf(l / 7.0), 2, 6)]
			return [1, clamp_int(2.0 + floorf(l / 9.0), 2, 4)]
		"s_ward":
			if gen == 0: return around(23.0 + 0.3 * l, 46, 1, WIDE)
			if gen == 1: return around(9.0 + 0.7 * l, 60)
			return around(12.0 + 0.55 * l, 55)
	# the eight stat affixes
	if gen == 0: return around(1.2 + 0.1 * minf(l, 25.0) + 0.052 * maxf(0.0, l - 25.0), 20, 1, WIDE)
	if gen == 1: return around(0.8 + 0.07 * l, 14)
	return around(0.8 + 0.07 * minf(l, 25.0) + 0.045 * maxf(0.0, l - 25.0), 14)

## The [lo, hi] a NEW roll of this affix may have at an item level; null when the id is unknown.
static func affix_range(id: String, ilvl: float) -> Variant:
	if not _index().has(id):
		return null
	return _range_gen(id, clamp_int(ilvl, 1, ILVL_MAX), 0)

## The widest [lo, hi] any build ever rolled at this item level (validation only).
static func affix_accept_range(id: String, ilvl: float) -> Variant:
	if not _index().has(id):
		return null
	var L := clamp_int(ilvl, 1, ILVL_MAX)
	var r := _range_gen(id, L, 0)
	var lo: int = r[0]
	var hi: int = r[1]
	for g in [1, 2]:
		var x := _range_gen(id, L, g)
		lo = mini(lo, x[0])
		hi = maxi(hi, x[1])
	return [lo, hi]

static func _tenths(v: float) -> String:
	## `${+(v / 10).toFixed(1)}%`
	var s := "%.1f" % (v / 10.0)
	if s.ends_with(".0"):
		s = s.substr(0, s.length() - 2)
	return s + "%"

## {mult:{}, add:{}, stats:{}} for one roll.
static func affix_effect(a: Dictionary) -> Dictionary:
	var d := affix_def(str(a.get("id", "")))
	if d.is_empty():
		return {}
	var v: float = float(a["v"])
	match d["id"]:
		"p_thrall_dmg": return {"mult": {"thrallDamageMult": 1.0 + v / 1000.0}}
		"s_thrall_hp": return {"mult": {"thrallHpMult": 1.0 + v / 1000.0}}
		"p_essence_regen": return {"mult": {"essenceRegenMult": 1.0 + v / 1000.0}}
		"s_miasma": return {"mult": {"miasmaRadiusMult": 1.0 + v / 1000.0}}
		"p_withered": return {"add": {"witheredMaxStacks": v}}
		"s_ward": return {"add": {"wardPerThrall": v / 1000.0}}
	return {"stats": {d["stat"]: v}}

static func affix_text(a: Dictionary) -> String:
	var id := str(a.get("id", ""))
	var d := affix_def(id)
	if d.is_empty():
		return id
	var v: Variant = a["v"]
	var f := float(v)
	match id:
		"p_thrall_dmg": return "Thralls hit +%s harder" % _tenths(f)
		"s_thrall_hp": return "Thralls have +%s health" % _tenths(f)
		"p_essence_regen": return "+%s essence regeneration" % _tenths(f)
		"s_miasma": return "Miasma is +%s wider" % _tenths(f)
		"p_withered": return "+%s max Withered stack%s" % [num(v), "" if f == 1.0 else "s"]
		"s_ward": return "%s less damage taken per thrall" % _tenths(f)
	return "+%s %s" % [num(v), STAT_NAME[d["stat"]]]

static func affix_is_necro(a: Dictionary) -> bool:
	return bool(affix_def(str(a.get("id", ""))).get("necro", false))

## "prefix" / "suffix", or "" when the id is unknown (TS: null).
static func affix_kind(a: Dictionary) -> String:
	return str(affix_def(str(a.get("id", ""))).get("kind", ""))

static func affix_word(a: Dictionary) -> String:
	return str(affix_def(str(a.get("id", ""))).get("word", ""))

## 0..1: where the roll sits between the weakest and strongest this item level allows.
static func affix_quality(a: Dictionary, ilvl: float) -> float:
	var r: Variant = affix_range(str(a.get("id", "")), ilvl)
	if r == null or r[1] <= r[0]:
		return 1.0
	return maxf(0.0, minf(1.0, (float(a["v"]) - r[0]) / float(r[1] - r[0])))

# --- Item level ----------------------------------------------------------------------------------------------------------------
static func _number_or_1(level: Variant) -> float:
	## JS `Number(x) || 1`.
	var f := float(level) if (level is int or level is float) else 1.0
	return 1.0 if (f == 0.0 or is_nan(f)) else f

static func item_level_for(level: Variant, source: String) -> int:
	return clamp_int(_number_or_1(level) + float(SOURCE_ILVL.get(source, 0)), 1, ILVL_MAX)

static func clamp_drop_level(level: Variant, character_level: float) -> int:
	return clamp_int(_number_or_1(level), 1, minf(ILVL_MAX, maxf(1.0, character_level) + ILVL_REACH))

# --- Rolling -------------------------------------------------------------------------------------------------------------------
static func _r(rand: Callable) -> float:
	return randf() if rand.is_null() else float(rand.call())

## How many affixes a drop gets: the base item's rarity sets the odds, the source tilts them.
static func roll_affix_count(rarity: String, source: String, rand: Callable) -> int:
	var base: Array = COUNT_WEIGHTS.get(rarity, COUNT_WEIGHTS["common"])
	var s: Dictionary = SOURCE_COUNT.get(source, SOURCE_COUNT["kill"])
	var mn: int = s["min"]
	var w: Array[float] = []
	var total := 0.0
	for i in 4:
		var x := 0.0 if i < mn else float(base[i]) * float(s["mult"][i])
		w.append(x)
		total += x
	if total == 0.0:
		total = 1.0
	var r := _r(rand) * total
	for i in 4:
		r -= w[i]
		if r < 0.0:
			return i
	return maxi(mn, 0)

## Roll the item level and the affixes. Returns {ilvl:int, affixes:[{id,v}]}. Deterministic for a given sequence.
static func roll_instance(rarity: String, level: Variant, source: String, rand: Callable) -> Dictionary:
	var ilvl := item_level_for(level, source)
	var count := roll_affix_count(rarity, source, rand)
	var affixes: Array = []
	var used := {}
	for n in count:
		var pool: Array[Dictionary] = []
		var total := 0.0
		for a in AFFIXES:
			if not used.has(a["group"]):
				pool.append(a)
				total += float(a["weight"])
		var r := _r(rand) * total
		var pick: Dictionary = pool[pool.size() - 1]
		for a in pool:
			r -= float(a["weight"])
			if r < 0.0:
				pick = a
				break
		used[pick["group"]] = true
		var rg := _range_gen(pick["id"], ilvl, 0)
		var lo: int = rg[0]
		var hi: int = rg[1]
		affixes.append({"id": pick["id"], "v": lo + mini(hi - lo, int(floorf(_r(rand) * float(hi - lo + 1))))})
	return {"ilvl": ilvl, "affixes": affixes}

## Player-readable problem with an instance claimed for an item (offline sync import), or "" when it is a legal roll.
static func instance_problem(inst: Variant, item_type: String) -> String:
	if not is_affix_gear(item_type):
		return "Only gear can carry affixes."
	if not (inst is Dictionary) or not inst.has("ilvl") or not is_integer(inst["ilvl"]) or inst["ilvl"] < 1 or inst["ilvl"] > ILVL_MAX:
		return "Invalid item level."
	if not (inst.get("affixes") is Array) or inst["affixes"].size() > MAX_AFFIXES:
		return "Invalid affixes."
	var groups := {}
	for a in inst["affixes"]:
		var d: Dictionary = {}
		if a is Dictionary and a.get("id") is String:
			d = affix_def(a["id"])
		if d.is_empty() or not is_integer(a.get("v")):
			return "Unknown affix."
		if groups.has(d["group"]):
			return "Duplicate affix."
		groups[d["group"]] = true
		var rg: Array = affix_accept_range(d["id"], float(inst["ilvl"]))
		if a["v"] < rg[0] or a["v"] > rg[1]:
			return "An affix roll is out of range for its item level."
	return ""

static func clean_instance(inst: Dictionary) -> Dictionary:
	var out: Array = []
	for a in inst["affixes"]:
		out.append({"id": a["id"], "v": a["v"]})
	return {"ilvl": inst["ilvl"], "affixes": out}

# --- Names, rarity and value ---------------------------------------------------------------------------------------------------
## "Gravebound Iron Helm of the Legion": the first prefix and the first suffix.
static func affixed_name(base_name: String, affixes: Array) -> String:
	var pre := ""
	var suf := ""
	var have_pre := false
	var have_suf := false
	for a in affixes:
		var k := affix_kind(a)
		if k == "prefix" and not have_pre:
			have_pre = true
			pre = affix_word(a)
		elif k == "suffix" and not have_suf:
			have_suf = true
			suf = affix_word(a)
	var parts: Array[String] = []
	if pre != "": parts.append(pre)
	if base_name != "": parts.append(base_name)
	if suf != "": parts.append(suf)
	return " ".join(parts)

## Rarity colour reflects the affix count: 1 uncommon, 2 rare, 3 epic. A base item never loses rarity.
static func effective_rarity(base_rarity: String, affix_count: int) -> String:
	var floor_r: String = RARITY_RANK[maxi(0, mini(3, affix_count))]
	return floor_r if RARITY_RANK.find(floor_r) > RARITY_RANK.find(base_rarity) else base_rarity

## What the vendor pays: higher item levels and every affix add to the base price. `inst` null = plain.
static func instance_sell_value(base: float, inst: Variant) -> int:
	if inst == null:
		return int(base)
	return int(maxf(base, float(js_round(base * (1.0 + 0.02 * float(inst["ilvl"])) * (1.0 + 0.35 * float(inst["affixes"].size()))))))

static func instance_power(inst: Variant) -> int:
	return int(inst["affixes"].size() * 1000 + inst["ilvl"]) if inst != null else 0

# --- Totals ---------------------------------------------------------------------------------------------------------------------
static func empty_totals() -> Dictionary:
	return {"mult": {}, "add": {}, "stats": {}}

## Fold one instance's affixes into running totals (multipliers multiply, additions and stats add).
static func add_instance_totals(t: Dictionary, affixes: Array) -> Dictionary:
	for a in affixes:
		var e := affix_effect(a)
		for k in e.get("mult", {}):
			t["mult"][k] = float(t["mult"].get(k, 1.0)) * float(e["mult"][k])
		for k in e.get("add", {}):
			t["add"][k] = float(t["add"].get(k, 0.0)) + float(e["add"][k])
		for k in e.get("stats", {}):
			t["stats"][k] = float(t["stats"].get(k, 0.0)) + float(e["stats"][k])
	return t
