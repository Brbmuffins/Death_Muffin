class_name DmItemText
extends RefCounted
## The data behind the Reliquary tooltip / detail strip (src/ui/gearText.ts, minus the HTML): turns an inventory row plus the character's
## StatContext (see DmGearStats) into the Dictionary DmItemCard / DmItemSlot read:
##   type_label, ilvl + affix_count, verdict {kind: up|down|same, text}, stats [{text, fx, necro}], set_line, compare [{text, kind}].
## Without a context (before the player exists) the lines are the plain base stats, like the web.

const TYPE_WORDS := {
	"weapon": "weapon", "offhand": "off-hand", "armor_head": "head armor", "armor_chest": "chest armor", "armor_legs": "leg armor",
	"armor_feet": "foot armor", "armor_hands": "hand armor", "ring": "ring", "trinket": "trinket", "rune": "relic rune",
}


## "rare head armor" -> the word after the rarity ("head armor", "potion", "two-handed weapon").
static func type_label(slot: Dictionary) -> String:
	var id := String(slot.get("item_id", ""))
	var t := String(slot.get("item_type", ""))
	if t == "material":
		if DmContent.healing_flasks().has(id) or DmContent.buff_flasks().has(id):
			return "potion"
		if (DmContent.get_export("processing", "MEALS") as Dictionary).has(id):
			return "meal"
		if DmGathering.tool_kind_of(id) != "":
			return "gathering tool"
		if id.begins_with("charm_"):
			return "pet charm"
		if id.begins_with("seed_") or id.begins_with("sapling_"):
			return "seed"
		return "material"
	var base: String = TYPE_WORDS.get(t, t.replace("_", " "))
	return "two-handed %s" % base if t == "weapon" and DmWeaponLine.is_two_handed(id) else base


## "Upgrade for your Gravecaller: +12% (more thrall damage)" as the card's verdict ({} when there is none).
static func verdict(ctx: Variant, slot: Dictionary) -> Dictionary:
	if ctx == null:
		return {}
	var v: Variant = DmGearStats.item_verdict(ctx, slot)
	if v == null:
		return {}
	return {"kind": {"upgrade": "up", "downgrade": "down", "same": "same"}[v["kind"]], "text": v["text"]}


## The small corner arrow on a bag cell: "up" / "down" / "" (nothing for "about the same").
static func badge(ctx: Variant, slot: Dictionary) -> String:
	var v := verdict(ctx, slot)
	if v.is_empty() or v["kind"] == "same":
		return ""
	return String(v["kind"])


## Stat lines for the card: base stats with what they do for you, then the affixes.
static func stat_lines(ctx: Variant, slot: Dictionary) -> Array:
	var out: Array = []
	var sb: Variant = slot.get("stat_bonus")
	if ctx == null:
		if sb is Dictionary:
			for k in DmGearStats.STAT_KEYS:
				if DmCombatData.truthy(sb.get(k)):
					out.append("+%s %s" % [DmJsFmt.num_str(float(sb[k])), DmGearStats.STAT_LABELS[k]])
		for l: Dictionary in DmAffixes.affix_lines(slot):
			out.append({"text": l["text"], "fx": "", "necro": l["necro"]})
		return out
	if sb != null:
		for e: Dictionary in DmGearStats.item_stat_effects(ctx, slot):
			out.append({"text": e["head"], "fx": DmGearStats.effect_text(e["lines"]), "necro": false})
	if slot.get("inst") != null:
		for e: Dictionary in DmGearStats.item_affix_effects(ctx, slot):
			var fx := ""
			if not (e["lines"] as Array).is_empty():
				fx = DmGearStats.effect_text(e["lines"])
			elif not e["relevant"]:
				fx = "no effect for you"
			out.append({"text": e["text"], "fx": fx, "necro": e["necro"]})
	return out


static func _parts_of(list: Array, set_id: String) -> Array:
	var out: Array = []
	for p: Dictionary in DmSetBonuses.worn_armor(list):
		if p["setId"] == set_id:
			out.append(p["part"])
	return out


## An armor piece's set block as text ("Ivory Reliquary  3 / 5 worn -> 4 with this" then one line per bonus); "" for non-set gear.
static func set_line(ctx: Variant, slots: Array, slot: Dictionary) -> String:
	DmSetBonuses._index()
	var piece: Variant = DmSetBonuses._pieces_by_id.get(String(slot.get("item_id", "")))
	if piece == null:
		return ""
	var sid: String = piece["setId"]
	var now := DmSetText.set_status(sid, _parts_of(slots, sid))
	var after := now
	if not DmCombatData.truthy(slot.get("equipped")) and ctx != null:
		after = DmSetText.set_status(sid, _parts_of(DmGearStats.simulate_equip(slots, slot.get("slot_index"))["slots"], sid))
	var gain: bool = after["worn"] != now["worn"]
	var family: String = String(ctx["discipline"]["family"]) if ctx != null else "necromancer"
	var rows: Array[String] = ["%s  %d / 5 worn%s" % [now["setName"], int(now["worn"]), (" → %d with this" % int(after["worn"])) if gain else ""]]
	for i in (now["bonuses"] as Array).size():
		var b: Dictionary = now["bonuses"][i]
		var soon: bool = not b["active"] and bool(after["bonuses"][i]["active"])
		var mark := "✓" if b["active"] else ("▲" if soon else "·")
		var note := "" if DmSetBonuses.effect_relevant(b["effect"], family) else " (no effect for your class)"
		var nm := ("%s: " % b["name"]) if DmCombatData.truthy(b.get("name")) else ""
		rows.append("%d  %s %s%s%s" % [int(b["pieces"]), mark, nm, " · ".join(b["lines"]), note])
	return "\n".join(rows)


## The "Against what you wear" chips: [{text, kind: up|down}] (derived numbers, set notes, weapon-line gains and losses); [] when it is worn or not gear.
static func compare(ctx: Variant, slot: Dictionary) -> Array:
	if ctx == null:
		return []
	var c: Variant = DmGearStats.compare_equip(ctx, slot)
	if c == null:
		return []
	var out: Array = []
	for l: Dictionary in c["lines"]:
		out.append({"text": "%s %s" % [l["text"], l["label"]], "kind": l["tone"]})
	var g := DmSetText.diff_text({"gained": c["sets"]["gained"], "lost": []})
	var lo := DmSetText.diff_text({"gained": [], "lost": c["sets"]["lost"]})
	if g != "":
		out.append({"text": "Set: %s" % g, "kind": "up"})
	if lo != "":
		out.append({"text": "Set: %s" % lo, "kind": "down"})
	for t: String in c["gained"]:
		out.append({"text": t, "kind": "up"})
	for t: String in c["lost"]:
		out.append({"text": "Loses: %s" % t, "kind": "down"})
	return out


## "Instead of A and B:" / "If you equip it (nothing worn there):"
static func compare_headline(replaced: Array) -> String:
	if replaced.is_empty():
		return "If you equip it (nothing worn there):"
	var names: Array[String] = []
	for r: Dictionary in replaced:
		names.append(String(r["name"]))
	return "Instead of %s:" % " and ".join(names)


## The whole card Dictionary for one row: `base` = the fields the integrator already has (name, rarity, quantity, lore, sell_value, icon...), this adds the stat words.
static func card(ctx: Variant, slots: Array, slot: Dictionary, base: Dictionary = {}) -> Dictionary:
	var d := base.duplicate()
	d["type_label"] = type_label(slot)
	var inst: Variant = slot.get("inst")
	if inst != null:
		d["ilvl"] = int(inst["ilvl"])
		d["affix_count"] = (inst["affixes"] as Array).size()
	var v := verdict(ctx, slot)
	if not v.is_empty():
		d["verdict"] = v
	d["stats"] = stat_lines(ctx, slot)
	var sl := set_line(ctx, slots, slot)
	if sl != "":
		d["set_line"] = sl
	var cmp := compare(ctx, slot)
	if not cmp.is_empty():
		d["compare"] = cmp
	return d


## "Sell all junk" / "Salvage all below rare" must spare pieces you would be glad to wear: an upgrade (an empty slot counts) or one that completes a set bonus.
## Returns a Callable(slot) -> bool, or an invalid Callable() without a context (nothing is spared).
static func keeps_for_you(ctx: Variant) -> Callable:
	if ctx == null:
		return Callable()
	return func(slot: Dictionary) -> bool:
		var v: Variant = DmGearStats.item_verdict(ctx, slot)
		return v != null and (v["kind"] == "upgrade" or not (v["sets"]["gained"] as Array).is_empty())
