extends "res://tests/common/dm_parity_part.gd"
## Client / server parity for client/rules/loot beyond the loot roll (that is loot_parity_part.gd): replays the fixtures the server's vitest writes.

const A := preload("res://rules/loot/affix_rules.gd")


func fixtures() -> Array:
	return [["rules_loot", "affix"]]


func call_fn(fn: String, a: Variant) -> Variant:
	match fn:
		"affixRange": return A.affix_range(a[0], a[1])
		"affixAcceptRange": return A.affix_accept_range(a[0], a[1])
		"affixEffect": return A.affix_effect(a[0])
		"affixText": return A.affix_text(a[0])
		"affixQuality": return A.affix_quality(a[0], a[1])
		"affixMeta":
			var roll := {"id": a[0], "v": 1}
			var k := A.affix_kind(roll)
			return {"necro": A.affix_is_necro(roll), "kind": null if k == "" else k, "word": A.affix_word(roll)}
		"itemLevelFor": return A.item_level_for(a[0], a[1])
		"clampDropLevel": return A.clamp_drop_level(a[0], a[1])
		"effectiveRarity": return A.effective_rarity(a[0], int(a[1]))
		"rollAffixCount": return A.roll_affix_count(a[0], a[1], DmDropStream.rand(a[2]))
		"rollInstance": return A.roll_instance(a[0], a[1], a[2], DmDropStream.rand(a[3]))
		"instanceProblem":
			var p := A.instance_problem(a[0], a[1])
			return null if p == "" else p
		"affixedName": return A.affixed_name(a[0], a[1])
		"instanceSellValue": return A.instance_sell_value(a[0], a[1])
		"instancePower": return A.instance_power(a[0])
		"addInstanceTotals": return A.add_instance_totals(A.empty_totals(), a[0])
	return "UNKNOWN FN " + fn
