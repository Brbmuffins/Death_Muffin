class_name DmSetBonuses
extends RefCounted
## Port of src/gameplay/setBonuses.ts (+ the data side of content/setBonuses.ts): armor set bonuses resolved from worn item ids,
## and the folding of set totals + worn affixes into discipline mods. Descriptive text (describeEffect, missing-piece names) stays in
## the TS UI layer; the ui track can add it from armor.json.
##
## JS keeps "which set totals are folded into this mods object" in a WeakMap keyed by the mods object. Here it is a hidden key
## "_applied" on the mods Dictionary; shift() (like the TS spread) returns a fresh Dictionary without it. Strip with strip_applied().

const APPLIED_KEY := "_applied"

static var _pieces_by_id: Dictionary = {}
static var _pieces_by_set: Dictionary = {}


static func _armor() -> Dictionary:
	return DmCombatData.load_json("armor")


static func _index() -> void:
	if not _pieces_by_id.is_empty():
		return
	for p: Dictionary in _armor()["pieces"]:
		_pieces_by_id[p["id"]] = p
		if not _pieces_by_set.has(p["setId"]):
			_pieces_by_set[p["setId"]] = []
		_pieces_by_set[p["setId"]].append(p)


static func empty_totals() -> Dictionary:
	return {"mult": {}, "add": {}, "stats": {}}


static func bonuses_of(set_id: String) -> Array:
	return (_armor()["set_bonuses"] as Dictionary).get(set_id, [])


## Worn armor pieces, one per slot (piece dictionaries from armor.json).
static func worn_armor(slots: Array) -> Array:
	_index()
	var worn := DmGear.equipped_by_slot(slots)
	var out: Array = []
	for part: String in _armor()["parts"]:
		var s: Variant = worn.get(part)
		var piece: Variant = _pieces_by_id.get(s["item_id"]) if s != null else null
		if piece != null and piece["part"] == part:
			out.append(piece)
	return out


static func _add_effect(t: Dictionary, e: Dictionary) -> void:
	for k in (e.get("mult", {}) as Dictionary):
		t["mult"][k] = float(t["mult"].get(k, 1.0)) * float(e["mult"][k])
	for k in (e.get("add", {}) as Dictionary):
		t["add"][k] = float(t["add"].get(k, 0.0)) + float(e["add"][k])
	for k in (e.get("stats", {}) as Dictionary):
		t["stats"][k] = float(t["stats"].get(k, 0.0)) + float(e["stats"][k])


## {sets:[{setId, worn, wornParts, collection, bonuses:[{pieces,name?,effect,active}], next}], active:[bonus+setId], totals, setTotals, affixTotals}
static func resolve(slots: Array) -> Dictionary:
	_index()
	var by_set: Dictionary = {}
	var order: Array[String] = []
	for p: Dictionary in worn_armor(slots):
		if not by_set.has(p["setId"]):
			by_set[p["setId"]] = []
			order.append(p["setId"])
		by_set[p["setId"]].append(p["part"])
	var sets: Array = []
	for id in order:
		sets.append(set_status(id, by_set[id]))
	# sort: most worn first, then collection descending; stable on ties (JS sort is stable)
	var idx := 0
	for s: Dictionary in sets:
		s["_i"] = idx
		idx += 1
	sets.sort_custom(func(a, b):
		if a["worn"] != b["worn"]:
			return a["worn"] > b["worn"]
		if a["collection"] != b["collection"]:
			return a["collection"] > b["collection"]
		return a["_i"] < b["_i"])
	var set_totals := empty_totals()
	var active: Array = []
	for s: Dictionary in sets:
		for b: Dictionary in s["bonuses"]:
			if b["active"]:
				var ab: Dictionary = b.duplicate()
				ab["setId"] = s["setId"]
				active.append(ab)
				_add_effect(set_totals, b["effect"])
	var affix_totals := DmAffixTotals.worn_affix_totals(slots)
	var totals := empty_totals()
	_add_effect(totals, set_totals)
	_add_effect(totals, affix_totals)
	return {"sets": sets, "active": active, "totals": totals, "setTotals": set_totals, "affixTotals": affix_totals}


static func set_status(set_id: String, worn_parts: Array) -> Dictionary:
	_index()
	var pieces: Array = _pieces_by_set.get(set_id, [])
	var any: Variant = pieces[0] if pieces.size() > 0 else null
	var worn := worn_parts.size()
	var bonuses: Array = []
	for b: Dictionary in bonuses_of(set_id):
		var rb: Dictionary = b.duplicate(true)
		rb["setId"] = set_id
		rb["active"] = worn >= int(b["pieces"])
		bonuses.append(rb)
	var next: Variant = null
	for rb: Dictionary in bonuses:
		if not rb["active"]:
			next = int(rb["pieces"])
			break
	return {
		"setId": set_id,
		"setName": (_armor()["set_names"] as Dictionary).get(set_id, set_id),
		"disciplineId": any["disciplineId"] if any != null else "",
		"collection": int(any["collection"]) if any != null else 1,
		"worn": worn,
		"wornParts": worn_parts.duplicate(),
		"bonuses": bonuses,
		"next": next,
	}


## Flat stats from set bonuses AND worn affixes (added to gear in compute_stats): {stat_str: float, ...}.
static func set_stat_totals(slots: Array) -> Dictionary:
	return resolve(slots)["totals"]["stats"]


## A short stable string for the active bonuses.
static func set_signature(slots: Array) -> String:
	var parts: Array[String] = []
	for b: Dictionary in resolve(slots)["active"]:
		parts.append("%s:%d" % [b["setId"], int(b["pieces"])])
	return "|".join(parts)


## Sets and worn rolls together.
static func outfit_signature(slots: Array) -> String:
	var rolls := DmAffixTotals.affix_signature(slots)
	return set_signature(slots) + (("#" + rolls) if rolls != "" else "")


# --- Folding into the discipline mods ---------------------------------------------------------------

## Returns a NEW mods Dictionary: mult keys multiplied by v (or divided when dir == -1), add keys incremented. No _applied key.
static func shift(mods: Dictionary, t: Dictionary, dir: int) -> Dictionary:
	var out: Dictionary = mods.duplicate(true)
	out.erase(APPLIED_KEY)
	for k in t["mult"]:
		out[k] = float(out[k]) * (float(t["mult"][k]) if dir == 1 else 1.0 / float(t["mult"][k]))
	for k in t["add"]:
		out[k] = float(out[k]) + dir * float(t["add"][k])
	return out


## The mods with the set bonuses folded in (a new Dictionary tagged with what was applied).
static func apply_set_mods(mods: Dictionary, t: Dictionary) -> Dictionary:
	var out := shift(mods, t, 1)
	out[APPLIED_KEY] = t.duplicate(true)
	return out


static func strip_applied(mods: Dictionary) -> Dictionary:
	var m := mods.duplicate(true)
	m.erase(APPLIED_KEY)
	return m


static func _json(t: Variant) -> String:
	return JSON.stringify(t, "", false)


## The discipline as if you wore `slots`: removes whatever is folded in now, adds those of `slots`.
static func with_set_bonuses(d: Dictionary, slots: Array) -> Dictionary:
	var now: Variant = d["mods"].get(APPLIED_KEY)
	var next: Dictionary = resolve(slots)["totals"]
	if now != null and _json(now) == _json(next):
		return d
	var bare: Dictionary = shift(d["mods"], now, -1) if now != null else d["mods"]
	if now == null and (next["mult"] as Dictionary).is_empty() and (next["add"] as Dictionary).is_empty():
		return d
	var out := d.duplicate()
	out["mods"] = apply_set_mods(bare, next)
	return out


## The mods with one more effect folded in (an item's affix judged on top of what is worn).
static func fold_effect(mods: Dictionary, e: Dictionary) -> Dictionary:
	return shift(mods, {"mult": e.get("mult", {}), "add": e.get("add", {}), "stats": {}}, 1)


## The discipline with set bonuses removed.
static func without_set_bonuses(d: Dictionary) -> Dictionary:
	var now: Variant = d["mods"].get(APPLIED_KEY)
	if now == null:
		return d
	var out := d.duplicate()
	out["mods"] = shift(d["mods"], now, -1)
	return out


# --- Relevance and swaps ----------------------------------------------------------------------------

const ANY_CLASS_MULT: Array[String] = ["maxHpMult", "essenceRegenMult"]


static func effect_relevant(e: Dictionary, family: String) -> bool:
	if family == "necromancer":
		return true
	if not (e.get("stats", {}) as Dictionary).is_empty():
		return true
	for k in (e.get("mult", {}) as Dictionary):
		if ANY_CLASS_MULT.has(k):
			return true
	return false


## Bonuses that switch on/off going from `before` to `after` slots: {gained:[{setName,pieces}], lost:[...]}.
static func diff_set_bonuses(before: Array, after: Array, family: String) -> Dictionary:
	var a: Array = resolve(before)["active"]
	var b: Array = resolve(after)["active"]
	var names: Dictionary = _armor()["set_names"]
	var ak := {}
	var bk := {}
	for x: Dictionary in a:
		ak["%s:%d" % [x["setId"], int(x["pieces"])]] = true
	for x: Dictionary in b:
		bk["%s:%d" % [x["setId"], int(x["pieces"])]] = true
	var gained: Array = []
	var lost: Array = []
	for x: Dictionary in b:
		if not ak.has("%s:%d" % [x["setId"], int(x["pieces"])]) and effect_relevant(x["effect"], family):
			gained.append({"setName": names.get(x["setId"], x["setId"]), "pieces": int(x["pieces"])})
	for x: Dictionary in a:
		if not bk.has("%s:%d" % [x["setId"], int(x["pieces"])]) and effect_relevant(x["effect"], family):
			lost.append({"setName": names.get(x["setId"], x["setId"]), "pieces": int(x["pieces"])})
	return {"gained": gained, "lost": lost}
