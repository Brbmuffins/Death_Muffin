class_name DmStatKey
extends RefCounted
## "Is everything that gear verdicts, item cards and the Atlas depend on still the same?" as one int, so panels recompute those only when it changes.
## Canonical on purpose: the server's copy of the same gear carries other row ids, int where the local row has float and another key order, and
## none of that is a new verdict. Not part of it: xp, gold, the stacks of materials/potions (they never reach a stat).


## ctx = DmGameUi.stat_ctx(). gear = every gear row (worn or in the bag), plus rows with no type.
static func of(ctx: Dictionary) -> int:
	return _key(ctx, false)


## As of(), without the loose bag gear: what one bag row's card and verdict depend on (the worn pieces, legion kits and stat sources; never the
## other bag rows). Selling or picking up gear leaves it unchanged, so the Reliquary keeps its cards and verdicts across a sale.
static func worn_of(ctx: Dictionary) -> int:
	return _key(ctx, true)


static func _key(ctx: Dictionary, worn_only: bool) -> int:
	var ch: Dictionary = (ctx["character"] as Dictionary).duplicate()
	for k in ["experience", "gold", "auto_combat_allowed", "id"]:
		ch.erase(k)
	var gear: Array = []
	for s: Dictionary in ctx["slots"]:
		var t: Variant = s.get("item_type")
		var worn := DmCombatData.truthy(s.get("equipped"))
		var si := float(DmCombatData.nn(s.get("slot_index"), -1))
		if worn_only and not worn and si >= 0.0 and si < DmBag.BAG_SIZE:
			continue
		if worn or t == null or DmAffixRules.AFFIX_GEAR_TYPES.has(String(t)):
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


## One row's identity for a cache: canonical (as `of`) without the row id, so the server's copy of an unchanged row (other id, floats, key
## order) is the same row.
static func row_of(row: Dictionary) -> int:
	var r := row.duplicate()
	r.erase("id")
	return canon(r).hash()

