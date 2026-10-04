class_name DmAtlasGear
extends RefCounted
## The per-player half of the Gear Atlas (src/gameplay/atlas.ts: atlasSlot, powerGainPct, setOutlook; AtlasPanel.verdict/outlook):
## the up/down arrow and the "as part of its set" figures for every catalogue item, which need the live stat context.
## The static Atlas model itself (drop tables, fit bands...) is exported JSON (godot/data/panels_a/atlas.json), not rules.

static var _by_id: Dictionary = {}
static var _by_set: Dictionary = {}


static func _index() -> void:
	if not _by_id.is_empty():
		return
	for p: Dictionary in DmCombatData.load_json("armor")["pieces"]:
		_by_id[p["id"]] = p
		if not _by_set.has(p["setId"]):
			_by_set[p["setId"]] = []
		_by_set[p["setId"]].append(p)


## A bag row for a catalogue item (no roll: base stats), so the gear score can judge it exactly like a bag item. null for non-gear.
static func atlas_slot(item_id: String, slot_index: int = 9999) -> Variant:
	var items := DmContent.items()
	if not items.has(item_id):
		return null
	var m: Dictionary = items[item_id]
	if not DmAffixRules.AFFIX_GEAR_TYPES.has(String(m.get("type", ""))):
		return null
	return {
		"id": 0, "slot_index": slot_index, "quantity": 1, "equipped": 0, "item_id": item_id, "name": m["name"], "rarity": m["rarity"],
		"item_type": m["type"], "stat_bonus": m.get("offlineStats"), "icon_id": null, "sell_value": m["sell"], "crafted": 0,
	}


## The hero the atlas judges "fit" on: level 20, every stat 10, nothing worn, in a discipline.
static func reference_context(discipline_id: String) -> Dictionary:
	return {"character": DmGearStats.ref_character(), "slots": [], "discipline": DmCombatData.disciplines()["disciplines"][discipline_id].duplicate(true), "damageTier": 0}


## Percent of power wearing the item adds to `ctx` (negative when it replaces something better).
static func power_gain_pct(ctx: Dictionary, item_id: String) -> float:
	var s: Variant = atlas_slot(item_id)
	if s == null:
		return 0.0
	var all: Array = (ctx["slots"] as Array).duplicate()
	all.append(s)
	var sim := DmGearStats.simulate_equip(all, s["slot_index"])
	var a: float = DmGearStats.gear_power(ctx)["total"]
	return ((float(DmGearStats.gear_power(ctx, sim["slots"])["total"]) - a) / a) * 100.0 if a > 0.0 else 0.0


static func _set_rows(set_id: String, base: int = 9000) -> Array:
	_index()
	var out: Array = []
	var i := 0
	for p: Dictionary in _by_set.get(set_id, []):
		var s: Variant = atlas_slot(p["id"], base + i)
		if s != null:
			out.append(s)
		i += 1
	return out


## Wear every row (each into its own slot) on top of `slots`.
static func _wear_all(slots: Array, rows: Array) -> Array:
	var cur: Array = slots.duplicate()
	cur.append_array(rows)
	for r: Dictionary in rows:
		cur = DmGearStats.simulate_equip(cur, r["slot_index"])["slots"]
	return cur


static func _strip_set(rows: Array) -> Array:
	var out: Array = []
	for r: Dictionary in rows:
		var c := r.duplicate()
		c["item_id"] = "bare_%s" % r["item_id"]
		out.append(c)
	return out


## What a piece of an armour or legendary set is worth as part of its set (null for gear of no set).
static func set_outlook(ctx: Dictionary, item_id: String) -> Variant:
	_index()
	var piece: Variant = _by_id.get(item_id)
	if piece == null:
		return null
	var rows := _set_rows(piece["setId"])
	if rows.size() < 2:
		return null
	var now: float = float(DmGearStats.gear_power(ctx)["total"])
	if now == 0.0:
		now = 1.0
	var full: float = DmGearStats.gear_power(ctx, _wear_all(ctx["slots"], rows))["total"]
	var bare: float = DmGearStats.gear_power(ctx, _wear_all(ctx["slots"], _strip_set(rows)))["total"]
	var worn: Array = []
	for s: Dictionary in ctx["slots"]:
		if not DmCombatData.truthy(s.get("equipped")):
			continue
		var p: Variant = _by_id.get(s["item_id"])
		if p != null and p["setId"] == piece["setId"] and not worn.has(p["part"]):
			worn.append(p["part"])
	var before := DmSetBonuses.set_status(piece["setId"], worn)
	if not worn.has(piece["part"]):
		worn.append(piece["part"])
	var st := DmSetBonuses.set_status(piece["setId"], worn)
	var gained: Variant = null
	for b: Dictionary in st["bonuses"]:
		if not b["active"]:
			continue
		var was := false
		for x: Dictionary in before["bonuses"]:
			if int(x["pieces"]) == int(b["pieces"]):
				was = bool(x["active"])
				break
		if not was:
			gained = b
	var hint := ""
	if gained != null:
		hint = "Completes %d/%d: switches on the %d-piece bonus" % [worn.size(), rows.size(), int(gained["pieces"])]
	else:
		hint = "Set piece %d/%d%s" % [worn.size(), rows.size(), (" (next bonus at %d)" % int(st["next"])) if st["next"] != null else ""]
	return {
		"setId": piece["setId"], "setName": piece["setName"], "total": rows.size(), "have": worn.size(),
		"withSetPct": DmMath.js_round_f(((full - now) / now) * 1000.0) / 10.0,
		"bonusPct": DmMath.js_round_f(((full - bare) / now) * 1000.0) / 10.0,
		"hint": hint,
	}


## AtlasPanel.verdict: the Reliquary arrow for a catalogue item judged as a bag item; null when worn or not gear.
static func verdict(ctx: Dictionary, item_id: String, worn: bool = false) -> Variant:
	var slot: Variant = atlas_slot(item_id)
	if slot == null or worn:
		return null
	var all: Array = (ctx["slots"] as Array).duplicate()
	all.append(slot)
	var c := ctx.duplicate()
	c["slots"] = all
	return DmGearStats.item_verdict(c, slot)


## The two Dictionaries DmAtlasPanel.set_context() wants: {verdicts: {item_id: {kind, pct, text, empty}}, outlooks: {item_id: {setName, total, withSetPct, bonusPct, hint}}}.
## `item_ids` = every catalogue gear id to judge (the panel only shows a verdict for ids present), `owned` = DmAtlasPanel.owned_from_slots(slots).
static func panel_inputs(ctx: Dictionary, item_ids: Array, owned: Dictionary = {}) -> Dictionary:
	var verdicts := {}
	var outlooks := {}
	for id in item_ids:
		var worn: bool = owned.has(id) and bool(owned[id].get("worn", false))
		var v: Variant = verdict(ctx, String(id), worn)
		if v != null:
			verdicts[id] = {"kind": v["kind"], "pct": v["pct"], "text": v["text"], "empty": v["empty"]}
		if not worn:
			var o: Variant = set_outlook(ctx, String(id))
			if o != null:
				outlooks[id] = o
	return {"verdicts": verdicts, "outlooks": outlooks}
