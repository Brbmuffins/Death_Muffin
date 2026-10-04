class_name DmAffixes
extends RefCounted
## Port of src/gameplay/affixes.ts: the client side of item level and affixes. The SERVER owns every roll; this only READS them:
## decorate_slot turns the raw columns of a rolled inventory row into a readable one (full name, rarity colour by affix count, price).
## Slots are Dictionaries shaped like the web InventorySlot. Not ported here: wornAffixTotals / affixSignature need the equipped-slot
## helper of the gear track (src/content/gear.ts equippedBySlot); use worn_affix_totals() below with the worn rows already picked.

## Whether an item id can roll an instance (gear only).
static func can_roll(item_id: String) -> bool:
	var t: String = str(DmLootData.item(item_id).get("type", ""))
	return t != "" and DmAffixRules.is_affix_gear(t)

static func parse_affixes(raw: Variant) -> Array:
	var v: Variant = raw
	if v is String:
		var j := JSON.new()  # a parse error gives [], like the TS try/catch
		v = j.data if j.parse(v) == OK else null
	if not (v is Array):
		return []
	var out: Array = []
	for a in v:
		if a is Dictionary and a.get("id") is String and DmAffixRules.is_integer(a.get("v")):
			out.append(a)
	return out

## A row with its roll read in. Idempotent: an already decorated row comes back unchanged.
static func decorate_slot(row: Dictionary) -> Dictionary:
	if row.get("inst") != null or row.get("instance_id") == null or row.get("ilvl") == null:
		return row
	var affixes := parse_affixes(row.get("affixes"))
	var inst := {"id": row["instance_id"], "ilvl": row["ilvl"], "affixes": affixes}
	var base_name: String = str(row["base_name"]) if row.get("base_name") != null else str(row["name"])
	var base_rarity: String = str(row["base_rarity"]) if row.get("base_rarity") != null else str(row["rarity"])
	var base_sell: Variant = row["base_sell"] if row.get("base_sell") != null else row["sell_value"]
	var out := row.duplicate()
	out["affixes"] = affixes
	out["inst"] = inst
	out["base_name"] = base_name
	out["base_rarity"] = base_rarity
	out["base_sell"] = base_sell
	out["name"] = DmAffixRules.affixed_name(base_name, affixes)
	out["rarity"] = DmAffixRules.effective_rarity(base_rarity, affixes.size())
	out["sell_value"] = DmAffixRules.instance_sell_value(float(base_sell), inst)
	return out

static func decorate_slots(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append(decorate_slot(r))
	return out

## The roll on a row, or null for plain gear and materials.
static func instance_of(slot: Dictionary) -> Variant:
	return slot.get("inst")

## Everything the affixes on WORN gear add to the stat pipeline. `worn` = the equipped rows (already picked by the caller).
static func worn_affix_totals(worn: Array) -> Dictionary:
	var t := DmAffixRules.empty_totals()
	for s in worn:
		if s != null and s.get("inst") != null:
			DmAffixRules.add_instance_totals(t, s["inst"]["affixes"])
	return t

## Affix lines of a row, in the order rolled: [{roll, text, necro, kind, quality}].
static func affix_lines(slot: Dictionary) -> Array:
	var inst: Variant = slot.get("inst")
	if inst == null:
		return []
	var out: Array = []
	for a in inst["affixes"]:
		var k := DmAffixRules.affix_kind(a)
		out.append({"roll": a, "text": DmAffixRules.affix_text(a), "necro": DmAffixRules.affix_is_necro(a), "kind": k if k != "" else "prefix", "quality": DmAffixRules.affix_quality(a, float(inst["ilvl"]))})
	return out

## The salvage-rule view of a row's roll: {ilvl, affixes: count}, or {} for plain gear.
static func roll_of(slot: Dictionary) -> Dictionary:
	var inst: Variant = slot.get("inst")
	return {"ilvl": inst["ilvl"], "affixes": inst["affixes"].size()} if inst != null else {}

## Plain-text lines for a tooltip ("Item level 22", then each affix; necro affixes get a dagger).
static func roll_title_lines(slot: Dictionary) -> Array:
	var inst: Variant = slot.get("inst")
	if inst == null:
		return []
	var out: Array = ["Item level %s" % DmAffixRules.num(inst["ilvl"])]
	for l in affix_lines(slot):
		out.append(("† " if l["necro"] else "  ") + l["text"])
	return out
