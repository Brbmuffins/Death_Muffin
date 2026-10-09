class_name DmLegionText
extends RefCounted
## The words and candidate ranking of archive/legacy-web:src/gameplay/legionKit.ts (the numbers live in rules/combat/dm_legion.gd).

const BAG_SIZE := 48
const DELTA_PARTS := [["damage", "thrall damage"], ["hp", "thrall health"], ["speed", "attack speed"], ["ward", "less damage to you per thrall"]]


static func pct(x: float) -> String:
	return "%s%%" % DmJsFmt.num_str(snappedf(x * 100.0, 0.1))


static func bonus_lines(b: Dictionary) -> Array:
	var out: Array = []
	if b["damage"] > 0.0004:
		out.append("Thralls hit +%s harder" % pct(b["damage"]))
	if b["hp"] > 0.0004:
		out.append("Thralls have +%s health" % pct(b["hp"]))
	if b["speed"] > 0.0004:
		out.append("Thralls attack +%s faster" % pct(b["speed"]))
	if b["ward"] > 0.0004:
		out.append("%s less damage to you per thrall" % pct(b["ward"]))
	return out


static func unused_affixes(piece: Dictionary) -> Array:
	var out: Array = []
	for a in (piece.get("affixes") if piece.get("affixes") != null else []):
		var e := DmAffixTotals.effect(a)
		var used: bool = (e.get("mult", {}) as Dictionary).has("thrallDamageMult") or (e.get("mult", {}) as Dictionary).has("thrallHpMult") \
			or (e.get("add", {}) as Dictionary).has("wardPerThrall") or e.has("stats")
		if not used:
			out.append(DmAffixRules.affix_text(a))
	return out


## {lines, unused} for one kit piece row in its slot.
static func piece_lines(kit: String, slot: Dictionary) -> Dictionary:
	var p := DmLegion.piece_of(slot)
	return {"lines": bonus_lines(DmLegion.piece_bonus(kit, p)), "unused": unused_affixes(p)}


static func describe_delta(now: Dictionary, next: Dictionary) -> String:
	var parts: Array = []
	for p in DELTA_PARTS:
		var d := DmMath.js_round_f((float(next[p[0]]) - float(now[p[0]])) * 1000.0) / 10.0
		if d == 0.0:
			continue
		parts.append("%s%.1f%% %s" % ["+" if d > 0 else "-", absf(d), p[1]])
	return ", ".join(parts) if not parts.is_empty() else "no change"


## The verdict for one bag piece against the kit slot it would fill; {} when it is not weapon or armour gear in the bag.
static func kit_candidate(slots: Array, slot: Dictionary) -> Dictionary:
	var kit: Variant = DmLegion.kit_id_for_type(slot.get("item_type"))
	var si := int(slot.get("slot_index", -1))
	if kit == null or si < 0 or si >= BAG_SIZE or int(slot.get("equipped", 0)) != 0:
		return {}
	var held_row: Variant = DmLegion.kit_pieces(slots).get(kit)
	var held := DmLegion.piece_bonus(kit, DmLegion.piece_of(held_row) if held_row != null else null)
	var bonus := DmLegion.piece_bonus(kit, DmLegion.piece_of(slot))
	var delta := DmLegion.piece_value(bonus) - DmLegion.piece_value(held)
	var verdict := "up" if delta > 0.0005 else ("down" if delta < -0.0005 else "same")
	return {"slot": slot, "kit": kit, "bonus": bonus, "delta": delta, "verdict": verdict, "text": describe_delta(held, bonus)}


static func kit_candidates(slots: Array) -> Array:
	var out: Array = []
	for s in slots:
		var c := kit_candidate(slots, s)
		if not c.is_empty():
			out.append(c)
	var idx: Array = []
	for i in out.size():
		idx.append(i)
	idx.sort_custom(func(a: int, b: int) -> bool:
		var da: float = out[a]["delta"]
		var db: float = out[b]["delta"]
		if da != db:
			return da > db
		return int(out[a]["slot"]["slot_index"]) < int(out[b]["slot"]["slot_index"]))
	return idx.map(func(i: int) -> Dictionary: return out[i])


## The data DmLegionView.set_data wants.
static func view_data(slots: Array, tier: int, gold: int, thrall: Variant, icon_of: Callable) -> Dictionary:
	var worn := DmLegion.kit_pieces(slots)
	var kit := {"weapon": null, "armor": null}
	for id in ["weapon", "armor"]:
		if worn.has(id):
			var s: Dictionary = worn[id]
			var pl := piece_lines(id, s)
			var piece := {"slot_index": int(s["slot_index"]), "name": s.get("name", ""), "rarity": s.get("rarity", "common"), "icon": icon_of.call(s), "lines": pl["lines"], "unused": pl["unused"]}
			if s.get("inst") != null:
				piece["ilvl"] = int(s["inst"]["ilvl"])
			kit[id] = piece
	var b := DmLegion.legion_of(slots, tier)
	var spares: Array = []
	for c in kit_candidates(slots):
		var s2: Dictionary = c["slot"]
		spares.append({"slot_index": int(s2["slot_index"]), "name": s2.get("name", ""), "rarity": s2.get("rarity", "common"), "icon": icon_of.call(s2),
			"kit": c["kit"], "verdict": c["verdict"], "text": c["text"]})
	var max_tier := int(DmCombatData.progression()["legion_upgrade"]["maxTier"])
	return {"kit": kit, "bonus_lines": bonus_lines({"hp": b["hpMult"] - 1.0, "damage": b["damageMult"] - 1.0, "speed": b["speedMult"] - 1.0, "ward": b["wardAdd"]}),
		"thrall": thrall, "spares": spares, "tier": tier, "cost": DmUpgrades.legion_cost(tier) if tier < max_tier else -1, "gold": gold}
