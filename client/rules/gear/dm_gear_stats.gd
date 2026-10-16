class_name DmGearStats
extends RefCounted
## Port of archive/legacy-web:src/gameplay/gearStats.ts (+ the describeStatDelta half of characterStats.ts): gear you can read. Everything the Reliquary tooltips,
## the compare block, the Character sheet and the Gear Atlas say about stats is computed here by running DmStats.derive_stats, so the words follow the math.
##
## A StatContext is a Dictionary {character, slots: Array of inventory rows, discipline: {id, family, name, mods}, damageTier, legion?}
## (discipline already boon/legion adjusted, exactly as WorldScene builds it; DmCharacterBuild.build() gives one). Results use the TS key names
## (camelCase) so the golden fixtures compare 1:1. JS `null` is `null` (or "" for gearSlot, which is a String here).

const STAT_KEYS: Array[String] = ["stat_str", "stat_agi", "stat_int", "stat_vit"]
const STAT_LABELS := {"stat_str": "STR", "stat_agi": "AGI", "stat_int": "INT", "stat_vit": "VIT"}
const STAT_NAME := STAT_LABELS
const DERIVED_LABELS := [
	{"key": "maxHp", "label": "health", "short": "Health"},
	{"key": "spellPower", "label": "spell power", "short": "Spell power"},
	{"key": "maxEssence", "label": "essence", "short": "Essence"},
	{"key": "essenceRegen", "label": "essence/s", "short": "Essence/s"},
	{"key": "moveSpeed", "label": "move speed", "short": "Move speed"},
	{"key": "thrallHp", "label": "thrall health", "short": "Thrall health"},
	{"key": "thrallDamage", "label": "thrall damage", "short": "Thrall damage"},
]
const SCORE_TERMS: Array[String] = ["spellPower", "thrallDamage", "maxHp", "thrallHp", "maxEssence", "essenceRegen", "moveSpeed", "weapon", "set"]
const PRIORITY_TIE: Array[String] = ["stat_int", "stat_vit", "stat_str", "stat_agi"]
const SAME_AT := 1.0

const NECRO_ROLE := {"damage": 0.5, "toughness": 0.3, "sustain": 0.15, "move": 0.05}
const REASON := {
	"spellPower": ["more spell power", "less spell power"],
	"thrallDamage": ["more thrall damage", "less thrall damage"],
	"maxHp": ["more health", "less health"],
	"thrallHp": ["tougher thralls", "frailer thralls"],
	"maxEssence": ["more essence", "less essence"],
	"essenceRegen": ["faster essence regen", "slower essence regen"],
	"moveSpeed": ["faster movement", "slower movement"],
	"weapon": ["a better weapon effect", "a worse weapon effect"],
	"set": ["a set bonus", "a lost set bonus"],
}
const REASON_AFFIX := ["stronger ward or rite effects", "weaker ward or rite effects"]
const NECRO_WHY := {
	"stat_int": "INT makes your spells and your legion hit harder", "stat_vit": "VIT keeps you and your thralls alive",
	"stat_str": "STR adds a little spell power", "stat_agi": "AGI makes you faster",
}
const OTHER_WHY := {
	"stat_int": "INT raises spell power and essence", "stat_vit": "VIT raises your health",
	"stat_str": "STR adds a little spell power", "stat_agi": "AGI makes you faster",
}

static var _ref_cache: Dictionary = {}
static var _priority: Dictionary = {}
static var _booting := false


static func _gs(name: String) -> Variant:
	return DmContent.get_export("gameplay_gearStats", name)


static func _f(v: Variant, d: float = 0.0) -> float:
	return float(DmCombatData.nn(v, d))


static func _truthy(v: Variant) -> bool:
	return DmCombatData.truthy(v)


static func _disciplines() -> Dictionary:
	return DmCombatData.disciplines()["disciplines"]


static func _equip_slots() -> Array:
	return DmContent.get_export("gear", "EQUIP_SLOTS")


static func _slot_label(id: String) -> String:
	for e: Dictionary in _equip_slots():
		if e["id"] == id:
			return String(e["label"])
	return ""


static func _same(a: Variant, b: Variant) -> bool:
	return is_same(a, b)


# --- derive ------------------------------------------------------------------------------------------------------------

## Derived stats for `slots`: the discipline is re-based on the set bonuses those slots would give.
static func derive(ctx: Dictionary, slots: Variant = null, character: Variant = null) -> Dictionary:
	var sl: Array = ctx["slots"] if slots == null else slots
	var ch: Dictionary = ctx["character"] if character == null else character
	return DmStats.derive_stats(ch, sl, DmSetBonuses.with_set_bonuses(ctx["discipline"], sl), _f(ctx.get("damageTier")))


## describeStatDelta(before, after)
static func describe_stat_delta(before: Dictionary, after: Dictionary) -> Array:
	var out: Array = []
	for d: Dictionary in DERIVED_LABELS:
		var k: String = d["key"]
		var b: float = before[k]
		var a: float = after[k]
		var text := DmStats.delta_text(k, b, a)
		if text == "":
			continue
		out.append({"key": k, "label": d["label"], "short": d["short"], "before": b, "after": a, "diff": a - b, "text": text, "tone": "up" if a > b else "down"})
	return out


## formatDerived (JS toFixed ties)
static func format_derived(key: String, v: float) -> String:
	match key:
		"maxHp", "maxEssence", "thrallHp":
			return str(DmMath.js_round(v))
		"moveSpeed":
			return DmJsFmt.to_fixed(v, 2)
		_:
			return DmJsFmt.to_fixed(v, 1)


# --- 1. What a single stat line on an item does for THIS character ---------------------------------------------------------

static func item_stat_effects(ctx: Dictionary, item: Dictionary) -> Array:
	var out: Array = []
	var base := derive(ctx)
	var sb: Variant = item.get("stat_bonus")
	for k in STAT_KEYS:
		var v := _f(sb.get(k) if sb is Dictionary else null)
		if v == 0.0:
			continue
		var bumped: Dictionary = (ctx["character"] as Dictionary).duplicate()
		bumped[k] = _f(bumped.get(k)) + v
		out.append({"stat": k, "value": v, "head": "%s%s %s" % ["+" if v > 0.0 else "", DmJsFmt.num_str(v), STAT_LABELS[k]], "lines": describe_stat_delta(base, derive(ctx, ctx["slots"], bumped))})
	return out


static func item_affix_effects(ctx: Dictionary, item: Dictionary) -> Array:
	var base := derive(ctx)
	var disc := DmSetBonuses.with_set_bonuses(ctx["discipline"], ctx["slots"])
	var out: Array = []
	for l: Dictionary in DmAffixes.affix_lines(item):
		var e := DmAffixRules.affix_effect(l["roll"])
		var after: Dictionary
		if e.has("stats") and e["stats"] != null:
			var bumped: Dictionary = (ctx["character"] as Dictionary).duplicate()
			for k in e["stats"]:
				bumped[k] = _f((ctx["character"] as Dictionary).get(k)) + float(e["stats"][k])
			after = derive(ctx, ctx["slots"], bumped)
		else:
			var d2: Dictionary = disc.duplicate()
			d2["mods"] = DmSetBonuses.fold_effect(disc["mods"], e)
			after = DmStats.derive_stats(ctx["character"], ctx["slots"], d2, _f(ctx.get("damageTier")))
		var r: Dictionary = l.duplicate()
		r["lines"] = describe_stat_delta(base, after)
		r["relevant"] = DmSetBonuses.effect_relevant(e, String(ctx["discipline"]["family"]))
		out.append(r)
	return out


## "+48 health (+22 thrall health)"
static func effect_text(lines: Array) -> String:
	if lines.is_empty():
		return "no effect for you"
	var own: Array[String] = []
	var thralls: Array[String] = []
	for l: Dictionary in lines:
		var s := "%s %s" % [l["text"], l["label"]]
		if String(l["key"]).begins_with("thrall"):
			thralls.append(s)
		else:
			own.append(s)
	var o := ", ".join(own)
	var t := ", ".join(thralls)
	var parts: Array[String] = []
	if o != "":
		parts.append(o)
	if t != "":
		parts.append("(%s)" % t if o != "" else t)
	return " ".join(parts)


# --- 2. Compare with what you wear -------------------------------------------------------------------------------------------

## {slots, displaced, gearSlot}: gearSlot is "" when the item is not gear.
static func simulate_equip(slots: Array, bag_index: Variant) -> Dictionary:
	var copy: Array = []
	for s: Dictionary in slots:
		copy.append(s.duplicate())
	var item: Variant = null
	for s: Dictionary in copy:
		if float(DmCombatData.nn(s.get("slot_index"), -1)) == float(bag_index):
			item = s
			break
	var gear_slot := DmGear.equip_slot_of(item) if item != null else ""
	if item == null or gear_slot == "" or _truthy(item.get("equipped")):
		return {"slots": copy, "displaced": [], "gearSlot": gear_slot}
	var displaced: Array = []
	var two := DmWeaponLine.is_two_handed(String(item["item_id"]))
	for s: Dictionary in copy:
		if _same(s, item) or not _truthy(s.get("equipped")):
			continue
		var at := DmGear.equip_slot_of(s)
		if at == gear_slot:
			displaced.append(s)
		elif two and at == "off_hand":
			displaced.append(s)
		elif gear_slot == "off_hand" and at == "main_hand" and DmWeaponLine.is_two_handed(String(s["item_id"])):
			displaced.append(s)
	for d: Dictionary in displaced:
		d["equipped"] = 0
	item["equipped"] = 1
	return {"slots": copy, "displaced": displaced, "gearSlot": gear_slot}


static func _pct_word(x: float) -> String:
	return "%d%%" % DmMath.js_round(absf(x - 1.0) * 100.0)


static func loadout_effects(l: Dictionary) -> Array:
	var out: Array = []
	if _truthy(l["reap"]):
		out.append({"id": "reap", "text": "Left click becomes a reaping arc"})
	if float(l["needleRangeMult"]) > 1.0 or _truthy(l["needlePierce"]):
		out.append({"id": "pierce", "text": "Left click reaches %s farther and pierces" % _pct_word(float(l["needleRangeMult"]))})
	if float(l["spellMult"]) > 1.0:
		out.append({"id": "spell", "text": "+%s spell damage" % _pct_word(float(l["spellMult"]))})
	if float(l["needleCadenceMult"]) != 1.0:
		out.append({"id": "cadence", "text": "Left click fires %s faster but %s softer" % [_pct_word(float(l["needleCadenceMult"])), _pct_word(float(l["needleDamageMult"]))]})
	if _truthy(l["needleWithered"]):
		out.append({"id": "withered", "text": "Left click leaves targets Withered"})
	if _truthy(l["exhumeRefund"]):
		out.append({"id": "exhume", "text": "Exhume refunds %d%% of its essence" % DmMath.js_round(float(l["exhumeRefund"]) * 100.0)})
	if _truthy(l["thrallBonus"]):
		out.append({"id": "thrallcap", "text": "+%s thrall cap" % DmJsFmt.num_str(float(l["thrallBonus"]))})
	if float(l["riteCooldownMult"]) != 1.0:
		out.append({"id": "rites", "text": "Rites recover %s sooner" % _pct_word(float(l["riteCooldownMult"]))})
	if _truthy(l["bellAllyHeal"]):
		out.append({"id": "bell", "text": "Wraith hits heal allies for %d%% of their health" % DmMath.js_round(float(l["bellAllyHeal"]) * 100.0)})
	return out


static func _find_by_index(slots: Array, idx: Variant) -> Variant:
	for s: Dictionary in slots:
		if float(DmCombatData.nn(s.get("slot_index"), -1)) == float(idx):
			return s
	return null


static func _replaced(ctx: Dictionary, sim: Dictionary) -> Array:
	var out: Array = []
	for d: Dictionary in sim["displaced"]:
		var s: Variant = _find_by_index(ctx["slots"], d.get("slot_index"))
		if s != null:
			out.append(s)
	return out


## What would change if you equipped this bag item now; null when it is already worn, or is not gear.
static func compare_equip(ctx: Dictionary, item: Dictionary) -> Variant:
	if _truthy(item.get("equipped")):
		return null
	var sim := simulate_equip(ctx["slots"], item.get("slot_index"))
	if sim["gearSlot"] == "":
		return null
	var before := derive(ctx)
	var after := derive(ctx, sim["slots"])
	var did: String = ctx["discipline"]["id"]
	var eb := loadout_effects(DmWeaponLine.resolve(DmGear.equipped_by_slot(ctx["slots"]), did))
	var ea := loadout_effects(DmWeaponLine.resolve(DmGear.equipped_by_slot(sim["slots"]), did))
	var ids_b := {}
	var ids_a := {}
	for e: Dictionary in eb:
		ids_b[e["id"]] = true
	for e: Dictionary in ea:
		ids_a[e["id"]] = true
	var tb: Dictionary = DmStats.compute_stats(ctx["character"], ctx["slots"])["total"]
	var ta: Dictionary = DmStats.compute_stats(ctx["character"], sim["slots"])["total"]
	var gained: Array = []
	var lost: Array = []
	for e: Dictionary in ea:
		if not ids_b.has(e["id"]):
			gained.append(e["text"])
	for e: Dictionary in eb:
		if not ids_a.has(e["id"]):
			lost.append(e["text"])
	var changes: Array = []
	for k in STAT_KEYS:
		if tb[k] != ta[k]:
			changes.append({"stat": k, "before": tb[k], "after": ta[k]})
	return {
		"gearSlot": sim["gearSlot"], "replaced": _replaced(ctx, sim), "before": before, "after": after, "lines": describe_stat_delta(before, after),
		"gained": gained, "lost": lost, "statChanges": changes,
		"sets": DmSetBonuses.diff_set_bonuses(ctx["slots"], sim["slots"], String(ctx["discipline"]["family"])),
	}


# --- 3. The Character sheet ------------------------------------------------------------------------------------------------

static func _mult(x: float) -> String:
	return "×" + DmJsFmt.plus_fixed(x, 3)


static func _signed(x: float, digits: int = 1) -> String:
	var t := DmJsFmt.to_fixed(absf(x), digits)
	if t.contains("."):
		var re := RegEx.create_from_string("\\.0+$")
		t = re.sub(t, "")
	return ("+" if x >= 0.0 else "-") + t


static func _g(b: Dictionary, k: String) -> float:
	return _f(b.get(k))


## Worn items that carry stats, with the stat's raw contribution computed by `per`.
static func _gear_rows(slots: Array, per: Callable, digits: int = 1, unit: String = "") -> Array:
	var rows: Array = []
	var worn := DmGear.equipped_by_slot(slots)
	for e: Dictionary in _equip_slots():
		var s: Variant = worn.get(e["id"])
		if s == null or not (s.get("stat_bonus") is Dictionary):
			continue
		var v: float = per.call(s["stat_bonus"])
		if v != 0.0:
			rows.append({"label": s["name"], "value": _signed(v, digits) + unit, "tone": "up" if v > 0.0 else "down"})
	return rows


## The share of the discipline's multipliers that came from Covenant boons (folded into `discipline.mods` by the scene).
static func boon_share(discipline: Dictionary) -> Dictionary:
	var base: Dictionary = _disciplines().get(discipline["id"], discipline)["mods"]
	var mine: Dictionary = DmSetBonuses.without_set_bonuses(discipline)["mods"]
	return {"maxHpMult": float(mine["maxHpMult"]) / float(base["maxHpMult"]), "essenceRegenMult": float(mine["essenceRegenMult"]) / float(base["essenceRegenMult"])}


static func set_sheet_lines(sets: Array, discipline: Dictionary) -> Array:
	if sets.is_empty():
		return [{"id": "set:none", "label": "No set worn", "value": "0 / 5", "help": "Wear 2, 4 or 5 pieces of one armor set for a bonus. Crowns and grips of the first sets drop in the Hollow Graves.", "rows": []}]
	var out: Array = []
	for s: Dictionary in sets:
		var rows: Array = []
		for b: Dictionary in s["bonuses"]:
			var note := "" if DmSetBonuses.effect_relevant(b["effect"], String(discipline["family"])) else " (no effect for your class)"
			var nm := (" · %s" % b["name"]) if _truthy(b.get("name")) else ""
			var row := {
				"label": "%d pieces%s: %s%s" % [int(b["pieces"]), nm, " · ".join(b["lines"]), note],
				"value": "Active" if b["active"] else "%d more" % (int(b["pieces"]) - int(s["worn"])),
			}
			if b["active"]:
				row["tone"] = "up"
			rows.append(row)
		var nxt: Variant = s["next"]
		if nxt != null:
			for m: Dictionary in s["missing"]:
				rows.append({"label": "Need: %s" % m["name"], "value": m["where"]})
		var left := (int(nxt) - int(s["worn"])) if nxt != null else 0
		var help := "Full set worn: every bonus is active."
		if nxt != null:
			help = "%d more %s for the %d-piece bonus." % [left, "piece" if left == 1 else "pieces", int(nxt)]
		out.append({"id": "set:%s" % s["setId"], "label": s["setName"], "value": "%d / 5" % int(s["worn"]), "help": help, "rows": rows})
	return out


static func affix_sheet_lines(slots: Array, discipline: Dictionary) -> Array:
	var worn_by := DmGear.equipped_by_slot(slots)
	var worn: Array = []
	for e: Dictionary in _equip_slots():
		var w: Variant = worn_by.get(e["id"])
		if w != null and w.get("inst") != null:
			worn.append(w)
	if worn.is_empty():
		return [{"id": "affix:none", "label": "No affixes worn", "value": "0", "help": "Gear can drop with an item level and up to three affixes. Hover a piece in your bag to see what each would do for you.", "rows": []}]
	var out: Array = []
	for w: Dictionary in worn:
		var inst: Dictionary = w["inst"]
		var n: int = (inst["affixes"] as Array).size()
		var rows: Array = []
		for l: Dictionary in DmAffixes.affix_lines(w):
			var rel := DmSetBonuses.effect_relevant(DmAffixRules.affix_effect(l["roll"]), String(discipline["family"]))
			rows.append({
				"label": "%s%s%s" % ["† " if l["necro"] else "", l["text"], "" if rel else " (no effect for your class)"],
				"value": "roll %d%%" % DmMath.js_round(float(l["quality"]) * 100.0),
				"tone": "up",
			})
		out.append({
			"id": "affix:%s:%s" % [w["item_id"], DmJsFmt.num_str(float(w["slot_index"]))],
			"label": w["name"], "value": "ilvl %s" % DmJsFmt.num_str(float(inst["ilvl"])),
			"help": "%d %s. Their numbers are inside the lines above (marked \"Item affixes\")." % [n, "affix" if n == 1 else "affixes"],
			"rows": rows,
		})
	return out


static func stat_sheet(ctx: Dictionary) -> Array:
	var character: Dictionary = ctx["character"]
	var slots: Array = ctx["slots"]
	var discipline: Dictionary = ctx["discipline"]
	var damage_tier := _f(ctx.get("damageTier"))
	var d := derive(ctx)
	var cs := DmStats.compute_stats(character, slots)
	var base: Dictionary = cs["base"]
	var total: Dictionary = cs["total"]
	var level: float = d["level"]
	var base_mods: Dictionary = _disciplines().get(discipline["id"], discipline)["mods"]
	var boons := boon_share(discipline)
	var set_res := DmSetText.resolve(slots)
	var set_mult: Dictionary = set_res["setTotals"]["mult"]
	var set_stats: Dictionary = set_res["setTotals"]["stats"]
	var aff_mult: Dictionary = set_res["affixTotals"]["mult"]
	var set_row := func(per: Callable, digits: int = 1, unit: String = "") -> Variant:
		var v: float = per.call(set_stats)
		return {"label": "Set bonuses", "value": _signed(v, digits) + unit, "tone": "up" if v > 0.0 else "down"} if v != 0.0 else null
	var affix_rows := func(per: Callable, digits: int = 1, unit: String = "") -> Array:
		var rows: Array = []
		var worn := DmGear.equipped_by_slot(slots)
		for e: Dictionary in _equip_slots():
			var w: Variant = worn.get(e["id"])
			if w == null or w.get("inst") == null:
				continue
			var stats: Dictionary = {}
			for a: Dictionary in w["inst"]["affixes"]:
				var st: Variant = DmAffixRules.affix_effect(a).get("stats")
				if st is Dictionary:
					for k in st:
						stats[k] = _f(stats.get(k)) + float(st[k])
			var v: float = per.call(stats)
			if v != 0.0:
				rows.append({"label": "%s (affixes)" % w["name"], "value": _signed(v, digits) + unit, "tone": "up" if v > 0.0 else "down"})
		return rows
	var per_tier: float = DmCombatData.progression()["damage_upgrade"]["perTier"]
	var dmg_mult := 1.0 + per_tier * damage_tier
	var loadout := DmWeaponLine.resolve(DmGear.equipped_by_slot(slots), discipline["id"])
	var spell_mult: float = loadout["spellMult"]
	var num := func(k: String) -> float:
		return _f(character.get(k))
	var rows_of := func(parts: Array) -> Array:
		var out: Array = []
		for p in parts:
			if p == null:
				continue
			if p is Array:
				out.append_array(p)
			else:
				out.append(p)
		return out
	var mult_row := func(label: String, m: float) -> Variant:
		if absf(m - 1.0) < 1e-9:
			return null
		return {"label": label, "value": _mult(m), "tone": "up" if m > 1.0 else "down"}
	var fin := func(label: String, v: String) -> Dictionary:
		return {"label": label, "value": v, "total": true}
	var tiers := "%s %s" % [DmJsFmt.num_str(damage_tier), "tier" if damage_tier == 1.0 else "tiers"]
	var n := func(k: String) -> String:
		return DmJsFmt.num_str(_f(character.get(k)))
	var sm := func(k: String) -> float:
		return float(set_mult.get(k, 1.0))
	var am := func(k: String) -> float:
		return float(aff_mult.get(k, 1.0))

	var per_hp := func(b: Dictionary) -> float: return _g(b, "stat_vit") * DmStats.HEALTH_PER_VIT
	var per_spell := func(b: Dictionary) -> float: return _g(b, "stat_int") * DmStats.SPELL_PER_INT + _g(b, "stat_str") * DmStats.SPELL_PER_STR + _g(b, "stat_agi") * DmStats.SPELL_PER_AGI
	var per_ess := func(b: Dictionary) -> float: return _g(b, "stat_int") * DmStats.ESSENCE_PER_INT
	var per_reg := func(b: Dictionary) -> float: return _g(b, "stat_int") * DmStats.REGEN_PER_INT
	var per_mv := func(b: Dictionary) -> float: return _g(b, "stat_agi") * DmStats.MOVE_PER_AGI * 100.0

	var health := {
		"id": "maxHp", "label": "Health", "value": format_derived("maxHp", d["maxHp"]), "help": "How much you can take before you fall. Comes from VIT and level.",
		"rows": rows_of.call([
			{"label": "Base", "value": DmJsFmt.num_str(DmStats.HEALTH_BASE)},
			{"label": "Level %s" % DmJsFmt.num_str(level), "value": _signed((level - 1.0) * DmStats.HEALTH_PER_LEVEL)},
			{"label": "Your VIT %s" % n.call("stat_vit"), "value": _signed(num.call("stat_vit") * DmStats.HEALTH_PER_VIT)},
			_gear_rows(slots, per_hp),
			affix_rows.call(per_hp),
			set_row.call(per_hp),
			mult_row.call(String(discipline["name"]), float(base_mods["maxHpMult"])),
			mult_row.call("Covenant boons", boons["maxHpMult"]),
			mult_row.call("Set bonuses", sm.call("maxHpMult")),
			mult_row.call("Item affixes", am.call("maxHpMult")),
			fin.call("Health", format_derived("maxHp", d["maxHp"])),
		]),
	}
	var spell := {
		"id": "spellPower", "label": "Spell power", "value": format_derived("spellPower", d["spellPower"]), "help": "Scales the damage of every rite. Mostly INT; STR and AGI add a little.",
		"rows": rows_of.call([
			{"label": "Base", "value": DmJsFmt.num_str(DmStats.SPELL_BASE)},
			{"label": "Level %s" % DmJsFmt.num_str(level), "value": _signed((level - 1.0) * DmStats.SPELL_PER_LEVEL)},
			{"label": "Your INT %s, STR %s, AGI %s" % [n.call("stat_int"), n.call("stat_str"), n.call("stat_agi")], "value": _signed(num.call("stat_int") * DmStats.SPELL_PER_INT + num.call("stat_str") * DmStats.SPELL_PER_STR + num.call("stat_agi") * DmStats.SPELL_PER_AGI)},
			_gear_rows(slots, per_spell),
			affix_rows.call(per_spell),
			set_row.call(per_spell),
			mult_row.call("Damage upgrades (%s)" % tiers, dmg_mult),
			mult_row.call("Weapon line (staff)", spell_mult),
			fin.call("Spell power", format_derived("spellPower", d["spellPower"])),
		]),
	}
	var essence := {
		"id": "maxEssence", "label": "Max essence", "value": format_derived("maxEssence", d["maxEssence"]), "help": "The pool your rites draw from. INT raises it.",
		"rows": rows_of.call([
			{"label": "Base", "value": DmJsFmt.num_str(DmStats.ESSENCE_BASE)},
			{"label": "Level %s" % DmJsFmt.num_str(level), "value": _signed(level * DmStats.ESSENCE_PER_LEVEL)},
			{"label": "Your INT %s" % n.call("stat_int"), "value": _signed(num.call("stat_int") * DmStats.ESSENCE_PER_INT)},
			_gear_rows(slots, per_ess),
			affix_rows.call(per_ess),
			set_row.call(per_ess),
			fin.call("Max essence", format_derived("maxEssence", d["maxEssence"])),
		]),
	}
	var regen := {
		"id": "essenceRegen", "label": "Essence/s", "value": format_derived("essenceRegen", d["essenceRegen"]), "help": "How fast essence returns each second. INT helps a little.",
		"rows": rows_of.call([
			{"label": "Base", "value": DmJsFmt.num_str(DmStats.REGEN_BASE)},
			{"label": "Your INT %s" % n.call("stat_int"), "value": _signed(num.call("stat_int") * DmStats.REGEN_PER_INT)},
			_gear_rows(slots, per_reg),
			affix_rows.call(per_reg),
			set_row.call(per_reg),
			mult_row.call(String(discipline["name"]), float(base_mods["essenceRegenMult"])),
			mult_row.call("Covenant boons", boons["essenceRegenMult"]),
			mult_row.call("Set bonuses", sm.call("essenceRegenMult")),
			mult_row.call("Item affixes", am.call("essenceRegenMult")),
			fin.call("Essence/s", format_derived("essenceRegen", d["essenceRegen"])),
		]),
	}
	var move := {
		"id": "moveSpeed", "label": "Move speed", "value": "%s m/s" % format_derived("moveSpeed", d["moveSpeed"]),
		"help": "How fast you walk. Every AGI adds %s%%." % DmJsFmt.plus_fixed(DmStats.MOVE_PER_AGI * 100.0, 2),
		"rows": rows_of.call([
			{"label": "Base", "value": "%s m/s" % DmJsFmt.num_str(DmStats.MOVE_BASE)},
			{"label": "Your AGI %s" % n.call("stat_agi"), "value": "%s%%" % _signed(num.call("stat_agi") * DmStats.MOVE_PER_AGI * 100.0)},
			_gear_rows(slots, per_mv, 1, "%"),
			affix_rows.call(per_mv, 1, "%"),
			set_row.call(per_mv, 1, "%"),
			fin.call("Move speed", "%s m/s" % format_derived("moveSpeed", d["moveSpeed"])),
		]),
	}
	var legion: Dictionary = ctx["legion"] if ctx.get("legion") != null else {"kit": {"hp": 0.0, "damage": 0.0}, "reinforce": {"hp": 0.0, "damage": 0.0}}
	var thrall_hp := {
		"id": "thrallHp", "label": "Thrall health", "value": format_derived("thrallHp", d["thrallHp"]),
		"help": "Each thrall has %d%% of your health, so VIT feeds your army too." % DmMath.js_round(DmStats.THRALL_HP_SHARE * 100.0),
		"rows": rows_of.call([
			{"label": "Your health", "value": format_derived("maxHp", d["maxHp"])},
			{"label": "Thrall share", "value": _mult(DmStats.THRALL_HP_SHARE)},
			mult_row.call("%s thralls" % discipline["name"], float(base_mods["thrallHpMult"])),
			mult_row.call("Legion kit", 1.0 + float(legion["kit"]["hp"])),
			mult_row.call("Legion reinforcement", 1.0 + float(legion["reinforce"]["hp"])),
			mult_row.call("Set bonuses", sm.call("thrallHpMult")),
			mult_row.call("Item affixes", am.call("thrallHpMult")),
			fin.call("Thrall health", format_derived("thrallHp", d["thrallHp"])),
		]),
	}
	var thrall_dmg := {
		"id": "thrallDamage", "label": "Thrall damage", "value": format_derived("thrallDamage", d["thrallDamage"]),
		"help": "Each thrall hits for %d%% of your spell power (before a staff boost)." % DmMath.js_round(DmStats.THRALL_DAMAGE_SHARE * 100.0),
		"rows": rows_of.call([
			{"label": "Your spell power (no staff)", "value": format_derived("spellPower", float(d["spellPower"]) / spell_mult)},
			{"label": "Thrall share", "value": _mult(DmStats.THRALL_DAMAGE_SHARE)},
			mult_row.call("%s thralls" % discipline["name"], float(base_mods["thrallDamageMult"])),
			mult_row.call("Legion kit", 1.0 + float(legion["kit"]["damage"])),
			mult_row.call("Legion reinforcement", 1.0 + float(legion["reinforce"]["damage"])),
			mult_row.call("Set bonuses", sm.call("thrallDamageMult")),
			mult_row.call("Item affixes", am.call("thrallDamageMult")),
			fin.call("Thrall damage", format_derived("thrallDamage", d["thrallDamage"])),
		]),
	}
	var bonus_pct := "+%s%%" % DmJsFmt.num_str(float(d["damageBonusPct"]))
	var dmg_up := {
		"id": "damageBonus", "label": "Damage upgrade", "value": bonus_pct, "help": "Bought with gold from the HUD: each tier adds spell power.",
		"rows": [{"label": "%s × %d%%" % [tiers, DmMath.js_round(per_tier * 100.0)], "value": bonus_pct, "total": true}],
	}

	var stat_line := func(k: String, help: String) -> Dictionary:
		var gr := func(b: Dictionary) -> float: return _g(b, k)
		return {
			"id": k, "label": STAT_LABELS[k], "value": DmJsFmt.num_str(total[k]), "help": help,
			"rows": rows_of.call([
				{"label": "Character", "value": DmJsFmt.num_str(base[k])},
				_gear_rows(slots, gr, 0),
				affix_rows.call(gr, 0),
				set_row.call(gr, 0),
				fin.call(STAT_LABELS[k], DmJsFmt.num_str(total[k])),
			]),
		}

	return [
		{"id": "derived", "title": "What you can do", "lines": [health, spell, essence, regen, move, thrall_hp, thrall_dmg, dmg_up]},
		{"id": "sets", "title": "Set bonuses", "lines": set_sheet_lines(set_res["sets"], discipline)},
		{"id": "affixes", "title": "Item affixes", "lines": affix_sheet_lines(slots, discipline)},
		{"id": "stats", "title": "Stats", "lines": [
			stat_line.call("stat_str", "A little spell power."),
			stat_line.call("stat_agi", "Move speed and a little spell power."),
			stat_line.call("stat_int", "Spell power, essence and essence regeneration."),
			stat_line.call("stat_vit", "Health, and through it thrall health."),
		]},
	]


# --- 4. Gear score: what is good for THIS discipline ---------------------------------------------------------------------

static func _boot() -> void:
	if not _priority.is_empty() or _booting:
		return
	_booting = true
	# TS computes STAT_PRIORITY at module load: that fills the reference cache with the bare disciplines before any context is judged.
	var ds := _disciplines()
	for id in ds:
		var weights := stat_weights(ds[id])
		var order: Array = STAT_KEYS.duplicate()
		order = DmStableSort.sorted(order, func(a: String, b: String) -> bool:
			var diff: float = weights[b] - weights[a]
			if diff != 0.0:
				return diff < 0.0
			return PRIORITY_TIE.find(a) < PRIORITY_TIE.find(b))
		_priority[id] = {"order": order, "weights": weights}
	_booting = false


static func stat_priority() -> Dictionary:
	_boot()
	return _priority


static func _role(disc_id: String) -> Dictionary:
	var rw: Dictionary = _gs("ROLE_WEIGHTS")
	return rw.get(disc_id, NECRO_ROLE)


## How many thralls the discipline fights with (necromancer family only).
static func thrall_count(d: Dictionary, bonus: float = 0.0) -> float:
	if d["family"] != "necromancer":
		return 0.0
	var base: float = float(_disciplines().get(d["id"], d)["mods"]["thrallCap"])
	var cap: float = float(d["mods"]["thrallCap"]) + bonus
	return (minf(cap, base) + maxf(0.0, cap - base) * float(_gs("EXTRA_THRALL_VALUE"))) * float(_gs("THRALL_UPTIME"))


static func _parts_of(d: Dictionary, disc: Dictionary, count: float) -> Dictionary:
	var share: float = _gs("THRALL_DAMAGE_SHARE")
	return {
		"damage": float(d["spellPower"]) + count * float(d["thrallDamage"]) * float(disc["mods"]["thrallAttackSpeedMult"]) * share,
		"toughness": float(d["maxHp"]) + count * float(d["thrallHp"]) * float(_gs("THRALL_TOUGH_SHARE")),
		"sustain": 0.5 * float(d["maxEssence"]) + 0.5 * float(d["essenceRegen"]) * float(_gs("REGEN_HORIZON_S")),
		"move": d["moveSpeed"],
	}


static func ref_character(over: Dictionary = {}) -> Dictionary:
	var r: Dictionary = _gs("REFERENCE")
	var c := {
		"id": 0, "class_index": 1, "class_name": "", "level": float(r["level"]), "experience": 0, "gold": 0,
		"stat_str": float(r["stat"]), "stat_agi": float(r["stat"]), "stat_int": float(r["stat"]), "stat_vit": float(r["stat"]),
	}
	for k in over:
		c[k] = over[k]
	return c


static func _reference_parts(disc: Dictionary) -> Dictionary:
	var key := "%s:%s" % [disc["id"], DmJsFmt.num_str(float(disc["mods"]["thrallCap"]))]
	if _ref_cache.has(key):
		return _ref_cache[key]
	var d := DmStats.derive_stats(ref_character(), [], disc, 0.0)
	var p := _parts_of(d, disc, thrall_count(disc))
	var r := {"damage": p["damage"], "toughness": p["toughness"], "sustain": p["sustain"], "move": p["move"]}
	_ref_cache[key] = r
	return r


static func _sum(t: Dictionary) -> float:
	var s := 0.0
	for k in t:
		s += float(t[k])
	return s


## Percent of power each part is worth, keyed by the derived number it comes from (for "why" text).
static func power_terms(d: Dictionary, disc: Dictionary, count: float, extra_pct: float, ref_disc: Variant = null, set_pct: float = 0.0) -> Dictionary:
	var w := _role(disc["id"])
	var rd: Dictionary = disc if ref_disc == null else ref_disc
	# The yardstick never includes armor sets, so gaining or losing a set bonus moves the score instead of cancelling out.
	var ref := _reference_parts(DmSetBonuses.without_set_bonuses(rd))
	var share: float = _gs("THRALL_DAMAGE_SHARE")
	var horizon: float = _gs("REGEN_HORIZON_S")
	var t := {
		"spellPower": (w["damage"] * float(d["spellPower"])) / ref["damage"],
		"thrallDamage": (w["damage"] * count * float(d["thrallDamage"]) * float(disc["mods"]["thrallAttackSpeedMult"]) * share) / ref["damage"],
		"maxHp": (w["toughness"] * float(d["maxHp"])) / ref["toughness"],
		"thrallHp": (w["toughness"] * count * float(d["thrallHp"]) * float(_gs("THRALL_TOUGH_SHARE"))) / ref["toughness"],
		"maxEssence": (w["sustain"] * 0.5 * float(d["maxEssence"])) / ref["sustain"],
		"essenceRegen": (w["sustain"] * 0.5 * float(d["essenceRegen"]) * horizon) / ref["sustain"],
		"moveSpeed": (w["move"] * float(d["moveSpeed"])) / ref["move"],
		"weapon": 0.0,
		"set": 0.0,
	}
	var base := _sum(t)
	t["weapon"] = (base * extra_pct) / 100.0
	t["set"] = (base * set_pct) / 100.0
	return t


## Value of the weapon-line effects that deriveStats cannot see, in percent of power.
static func loadout_extra_pct(l: Dictionary) -> float:
	var V: Dictionary = _gs("LOADOUT_VALUE")
	var x := 0.0
	if _truthy(l["reap"]):
		x += float(V["reap"])
	if _truthy(l["needlePierce"]):
		x += float(V["pierce"])
	if float(l["needleCadenceMult"]) != 1.0:
		x += (float(l["needleCadenceMult"]) * float(l["needleDamageMult"]) - 1.0) * 100.0 * float(V["primaryShare"])
	if _truthy(l["needleWithered"]):
		x += float(V["withered"])
	if _truthy(l["exhumeRefund"]):
		x += float(V["exhume"])
	if float(l["riteCooldownMult"]) != 1.0:
		x += (1.0 / float(l["riteCooldownMult"]) - 1.0) * 100.0 * float(V["riteShare"])
	if _truthy(l["bellAllyHeal"]):
		x += float(V["bell"])
	return x


## The value of the worn sets' mods-only effects, for a discipline that fights with `count` thralls.
static func set_extra_pct(totals: Dictionary, disc: Dictionary, count: float) -> float:
	if disc["family"] != "necromancer":
		return 0.0
	var w := _role(disc["id"])
	var V: Dictionary = _gs("SET_VALUE")
	var L: Dictionary = V["legendary"]
	var A: Dictionary = totals["add"]
	var M: Dictionary = totals["mult"]
	var x := 0.0
	var ward := _f(A.get("wardPerThrall"))
	if ward != 0.0:
		x += float(V["wardScale"]) * float(w["toughness"]) * 100.0 * (1.0 / (1.0 - minf(float(V["wardCap"]), ward * count)) - 1.0)
	x += _f(A.get("litanyBarrier")) * 100.0 * float(V["litanyPer1pct"])
	x += _f(A.get("corpseHeal")) * 100.0 * float(V["corpseHealPer1pct"])
	x += _f(A.get("witheredMaxStacks")) * float(V["witheredPerStack"])
	x += _f(A.get("thrallDeathBurst")) * float(L["thrallDeathBurst"]) + (float(L["championEvery"]) if _truthy(A.get("championEvery")) else 0.0) + _f(A.get("spearRally")) * float(L["spearRally"])
	x += _f(A.get("wardReflect")) * float(L["wardReflect"]) + _f(A.get("colossusGuard")) * float(L["colossusGuard"]) + _f(A.get("litanyShatter")) * float(L["litanyShatter"])
	x += _f(A.get("corpseWisp")) * float(L["corpseWisp"]) + (_f(M.get("soulHarvestRateMult"), 1.0) - 1.0) * float(L["soulHarvestRate"]) + _f(A.get("wraithNova")) * float(L["wraithNova"])
	x += (float(L["miasmaSpreadsWithered"]) if _truthy(A.get("miasmaSpreadsWithered")) else 0.0) + (float(L["witheredBurstAt"]) if _truthy(A.get("witheredBurstAt")) else 0.0)
	x += (_f(M.get("miasmaRadiusMult"), 1.0) - 1.0) * 100.0 * float(V["miasmaPer1pct"]) * (float(V["rotweaverMiasmaMult"]) if disc["id"] == "rotweaver" else 1.0)
	return x


## Power of this character wearing `slots` (default: what they wear): {total, terms}.
static func gear_power(ctx: Dictionary, slots: Variant = null) -> Dictionary:
	_boot()
	var sl: Array = ctx["slots"] if slots == null else slots
	var did: String = ctx["discipline"]["id"]
	var now := DmWeaponLine.resolve(DmGear.equipped_by_slot(ctx["slots"]), did)
	var then := DmWeaponLine.resolve(DmGear.equipped_by_slot(sl), did)
	# The discipline as `slots` would leave it: set bonuses can change the thrall cap and thrall attack speed too.
	var disc := DmSetBonuses.with_set_bonuses(ctx["discipline"], sl)
	var count := thrall_count(disc, float(then["thrallBonus"]) - float(now["thrallBonus"]))
	var terms := power_terms(derive(ctx, sl), disc, count, loadout_extra_pct(then), ctx["discipline"], set_extra_pct(DmSetBonuses.resolve(sl)["totals"], disc, count))
	return {"total": _sum(terms), "terms": terms}


## Percent of power one more point of each stat is worth, measured through deriveStats.
static func stat_weights(disc: Dictionary) -> Dictionary:
	var count := thrall_count(disc)
	var base := _sum(power_terms(DmStats.derive_stats(ref_character(), [], disc, 0.0), disc, count, 0.0))
	var out := {}
	var ref_stat: float = _gs("REFERENCE")["stat"]
	for k in STAT_KEYS:
		var more := DmStats.derive_stats(ref_character({k: ref_stat + 1.0}), [], disc, 0.0)
		var p := _sum(power_terms(more, disc, count, 0.0))
		out[k] = ((p - base) / base) * 100.0
	return out


# --- item verdicts --------------------------------------------------------------------------------------------------------

static func _num_pct(x: float) -> String:
	return "%d%%" % DmMath.js_round(absf(x))


## Upgrade or downgrade for this discipline, versus whatever the item would replace. null for worn items and non-gear.
static func item_verdict(ctx: Dictionary, item: Dictionary) -> Variant:
	if _truthy(item.get("equipped")):
		return null
	var sim := simulate_equip(ctx["slots"], item.get("slot_index"))
	if sim["gearSlot"] == "":
		return null
	var a := gear_power(ctx)
	var b := gear_power(ctx, sim["slots"])
	var raw: float = ((float(b["total"]) - float(a["total"])) / float(a["total"])) * 100.0
	var replaced := _replaced(ctx, sim)
	var empty := replaced.is_empty()
	var kind := "upgrade" if (empty or raw >= SAME_AT) else ("downgrade" if raw <= -SAME_AT else "same")
	var pct := DmMath.js_round_f((maxf(raw, 0.0) if empty else raw) * 10.0) / 10.0
	var sgn := 1.0 if raw >= 0.0 else -1.0
	var best := "spellPower"
	var best_val := 0.0
	for k in a["terms"]:
		var dv: float = (float(b["terms"][k]) - float(a["terms"][k])) * sgn
		if dv > best_val:
			best_val = dv
			best = k
	var sets := DmSetBonuses.diff_set_bonuses(ctx["slots"], sim["slots"], String(ctx["discipline"]["family"]))
	var set_note := DmSetText.diff_text(sets)
	var via_affix: bool = best == "set" and (sets["gained"] as Array).is_empty() and (sets["lost"] as Array).is_empty()
	var reason := ""
	if best_val > 0.0:
		reason = (REASON_AFFIX if via_affix else REASON[best])[0 if sgn > 0.0 else 1]
	var names: Array[String] = []
	for r: Dictionary in replaced:
		names.append(String(r["name"]))
	var nm := " and ".join(names)
	var slot_label := _slot_label(sim["gearSlot"]).to_lower()
	if slot_label == "":
		slot_label = "gear"
	var tail := " (%s)" % reason if reason != "" else ""
	var disc_name: String = ctx["discipline"]["name"]
	var text := ""
	if kind == "upgrade":
		if empty:
			text = "Upgrade for your %s: fills an empty %s slot%s" % [disc_name, slot_label, (" (+%s, %s)" % [_num_pct(pct), reason]) if pct >= 1.0 else ""]
		else:
			text = "Upgrade for your %s: +%s%s" % [disc_name, _num_pct(pct), tail]
	elif kind == "downgrade":
		text = "Worse than your %s: −%s%s" % [nm, _num_pct(pct), tail]
	else:
		text = "About the same as your %s" % nm
	if set_note != "":
		text += " — %s" % set_note
	return {"kind": kind, "pct": pct, "empty": empty, "replaced": replaced, "reason": reason, "text": text, "sets": sets, "setNote": set_note}


# --- "What you're looking for" ----------------------------------------------------------------------------------------------

static func _recommended() -> Dictionary:
	return _gs("RECOMMENDED_WEAPONS")


## Worn pieces' share of your power, lowest first, plus empty slots; with the best bag upgrade named when there is one.
static func weakest_slots(ctx: Dictionary, limit: int = 5) -> Array:
	var worn := DmGear.equipped_by_slot(ctx["slots"])
	var total: float = gear_power(ctx)["total"]
	var bag: Array = []
	for s: Dictionary in ctx["slots"]:
		if not _truthy(s.get("equipped")) and DmGear.equip_slot_of(s) != "":
			bag.append(s)
	var best_bag := func(slot: String) -> String:
		var best_item: Variant = null
		var best_pct := 0.0
		for bi: Dictionary in bag:
			if DmGear.equip_slot_of(bi) != slot:
				continue
			var v: Variant = item_verdict(ctx, bi)
			if v != null and v["kind"] == "upgrade" and float(v["pct"]) > best_pct:
				best_item = bi
				best_pct = float(v["pct"])
		return " Your %s in the bag is +%s." % [best_item["name"], _num_pct(best_pct)] if best_item != null else ""
	var main_hand: Variant = worn.get("main_hand")
	var two_hander: bool = main_hand != null and DmWeaponLine.is_two_handed(String(main_hand["item_id"]))
	var out: Array = []
	for e: Dictionary in _equip_slots():
		var id: String = e["id"]
		var label: String = e["label"]
		var it: Variant = worn.get(id)
		if it == null:
			if id == "off_hand" and two_hander:
				continue
			var any := "Anything" if (label.ends_with("s") or label == "Feet") else "Any %s" % label.to_lower()
			out.append({"rank": -1.0, "w": {"slot": id, "empty": true, "text": "%s: empty. %s is an upgrade.%s" % [label, any, best_bag.call(id)]}})
			continue
		var without_slots: Array = []
		for s: Dictionary in ctx["slots"]:
			if _same(s, it):
				var c := s.duplicate()
				c["equipped"] = 0
				without_slots.append(c)
			else:
				without_slots.append(s)
		var without: float = gear_power(ctx, without_slots)["total"]
		var share := ((total - without) / total) * 100.0
		out.append({"rank": share, "w": {"slot": id, "empty": false, "text": "%s: %s adds only %s.%s" % [label, it["name"], _num_pct(maxf(share, 0.0)), best_bag.call(id)]}})
	var sorted := DmStableSort.sorted(out, func(a: Dictionary, b: Dictionary) -> bool: return float(a["rank"]) < float(b["rank"]))
	var res: Array = []
	for i in mini(limit, sorted.size()):
		res.append(sorted[i]["w"])
	return res


static func looking_for(ctx: Dictionary) -> Dictionary:
	_boot()
	var disc: Dictionary = ctx["discipline"]
	var pr: Dictionary = _priority.get(disc["id"], _priority["gravecaller"])
	var why: Dictionary = NECRO_WHY if disc["family"] == "necromancer" else OTHER_WHY
	var order: Array = pr["order"]
	var rec: Variant = _recommended().get(disc["id"])
	var names: Array[String] = []
	for k in order:
		names.append(STAT_NAME[k])
	var weapons: Variant = null
	if rec != null:
		var labels: Dictionary = DmContent.get_export("necroWeapons", "NECRO_KIND_LABEL")
		var kinds: Array[String] = []
		for k in rec["kinds"]:
			kinds.append(String(labels[k]))
		weapons = "%s: %s." % [" and ".join(kinds), rec["why"]]
	return {
		"discipline": disc["name"], "order": order.duplicate(), "orderText": " > ".join(names),
		"why": "%s; %s." % [why[order[0]], why[order[1]]], "weapons": weapons, "weakest": weakest_slots(ctx),
	}


# --- Adapter for the panels ----------------------------------------------------------------------------------------------------

## The Dictionary DmSheetView.set_data() takes (Sheet · J): {ready, primer, looking, sections}. Pass ctx = null before the player exists.
static func sheet_data(ctx: Variant) -> Dictionary:
	if ctx == null:
		return {"ready": false}
	return {"ready": true, "primer": String(_gs("STAT_PRIMER")), "looking": looking_for(ctx), "sections": stat_sheet(ctx)}
