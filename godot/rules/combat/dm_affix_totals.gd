class_name DmAffixTotals
extends RefCounted
## The stat-pipeline half of server/rules/gameplay/affixRules.ts + affixes.ts: what a rolled affix does (effect), how worn affixes fold into
## totals, and the item-level range tables. Rolling / naming / validation of drops belongs to the loot track.
## An affix roll is {id, v}; totals are {mult:{}, add:{}, stats:{}} exactly like SetTotals.

static func _data() -> Dictionary:
	return DmCombatData.load_json("affixes")


static var _by_id: Dictionary = {}


static func def(id: String) -> Variant:
	if _by_id.is_empty():
		for a: Dictionary in _data()["affixes"]:
			_by_id[a["id"]] = a
	return _by_id.get(id)


static func empty_totals() -> Dictionary:
	return {"mult": {}, "add": {}, "stats": {}}


## affixEffect(roll) -> {stats?, mult?, add?}  ({} for an unknown id)
static func effect(roll: Dictionary) -> Dictionary:
	var d: Variant = def(roll["id"])
	if d == null:
		return {}
	var e: Dictionary = d["effect"]
	var v: float = roll["v"]
	match e["type"]:
		"stat":
			return {"stats": {e["key"]: v}}
		"mult":
			return {"mult": {e["key"]: 1.0 + v / float(e["per"])}}
		_:
			# add: per == 1 -> v itself, per == 1000 -> v / 1000
			return {"add": {e["key"]: v if float(e["per"]) == 1.0 else v / float(e["per"])}}


static func is_necro(roll: Dictionary) -> bool:
	var d: Variant = def(roll["id"])
	return d != null and bool(d["necro"])


## Fold one instance's affixes into running totals (multipliers multiply, additions and stats add). Mutates and returns `t`.
static func add_instance_totals(t: Dictionary, affixes: Array) -> Dictionary:
	for a: Dictionary in affixes:
		var e := effect(a)
		for k in (e.get("mult", {}) as Dictionary):
			t["mult"][k] = float(t["mult"].get(k, 1.0)) * float(e["mult"][k])
		for k in (e.get("add", {}) as Dictionary):
			t["add"][k] = float(t["add"].get(k, 0.0)) + float(e["add"][k])
		for k in (e.get("stats", {}) as Dictionary):
			t["stats"][k] = float(t["stats"].get(k, 0.0)) + float(e["stats"][k])
	return t


## Everything the affixes on WORN gear add to the stat pipeline.
static func worn_affix_totals(slots: Array) -> Dictionary:
	var t := empty_totals()
	var worn := DmGear.equipped_by_slot(slots)
	for key in worn:
		var s: Dictionary = worn[key]
		var inst: Variant = s.get("inst")
		if inst != null:
			add_instance_totals(t, inst["affixes"])
	return t


## A short stable string of the worn rolls.
static func affix_signature(slots: Array) -> String:
	var parts: Array[String] = []
	var worn := DmGear.equipped_by_slot(slots)
	for key in worn:
		var s: Dictionary = worn[key]
		var inst: Variant = s.get("inst")
		if inst == null:
			continue
		var rolls: Array[String] = []
		for a: Dictionary in inst["affixes"]:
			rolls.append("%s=%s" % [a["id"], _num(a["v"])])
		parts.append("%s~%s" % [s["item_id"], ",".join(rolls)])
	return "|".join(parts)


static func _num(v: Variant) -> String:
	var f := float(v)
	return str(int(f)) if f == floorf(f) else str(f)


static func _clamp_ilvl(ilvl: float) -> int:
	return int(clampf(float(DmMath.js_round(ilvl)), 1.0, float(_data()["ilvl_max"])))


## [lo, hi] a NEW roll of this affix may have on an item of this level, or null.
static func affix_range(id: String, ilvl: float) -> Variant:
	var d: Variant = def(id)
	return null if d == null else d["ranges"][_clamp_ilvl(ilvl) - 1]


## The widest [lo, hi] any build ever rolled at this item level (validation).
static func affix_accept_range(id: String, ilvl: float) -> Variant:
	var d: Variant = def(id)
	return null if d == null else d["accept"][_clamp_ilvl(ilvl) - 1]


## 0..1: where the roll sits between the weakest and strongest this item level allows.
static func affix_quality(roll: Dictionary, ilvl: float) -> float:
	var r: Variant = affix_range(roll["id"], ilvl)
	if r == null or r[1] <= r[0]:
		return 1.0
	return clampf((float(roll["v"]) - r[0]) / (r[1] - r[0]), 0.0, 1.0)
