class_name DmStatKey
extends RefCounted
## "Is everything that gear verdicts, item cards and the Atlas depend on still the same?" as one int, so panels recompute those only when it changes.
## Canonical on purpose: the server's copy of the same gear carries other row ids, int where the local row has float and another key order, and
## none of that is a new verdict. Not part of it: xp, gold, the stacks of materials/potions (they never reach a stat).


## ctx = DmGameUi.stat_ctx(). gear = every gear row (worn or in the bag), plus rows with no type.
static func of(ctx: Dictionary) -> int:
	var ch: Dictionary = (ctx["character"] as Dictionary).duplicate()
	for k in ["experience", "gold", "auto_combat_allowed", "id"]:
		ch.erase(k)
	var gear: Array = []
	for s: Dictionary in ctx["slots"]:
		var t: Variant = s.get("item_type")
		if DmCombatData.truthy(s.get("equipped")) or t == null or DmAffixRules.AFFIX_GEAR_TYPES.has(String(t)):
			var row := s.duplicate()
			row.erase("id")
			row["equipped"] = DmCombatData.truthy(s.get("equipped"))
			gear.append(canon(row))
	gear.sort_custom(func(a: Array, b: Array) -> bool: return str(a) < str(b))
	return [canon(ch), gear, canon(ctx["discipline"]), canon(ctx.get("damageTier")), canon(ctx.get("legion"))].hash()


static func canon(v: Variant) -> Variant:
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var out: Array = []
		for k in keys:
			out.append([str(k), canon(v[k])])
		return out
	if v is Array:
		return (v as Array).map(func(x: Variant) -> Variant: return canon(x))
	if v is int:
		return float(v)
	return v
