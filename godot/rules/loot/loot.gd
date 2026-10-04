class_name DmLoot
extends RefCounted
## Port of src/gameplay/loot.ts (the pure parts): what a kill / boss / surge / first kill drops, and how a drop lands in the bag.
## KEEP THE STREAM SHAPE: rollKill takes three separate random streams (rand, reagent_rand, rune_rand) so a seeded run matches the web.
## Every `rand` is a Callable returning a float in [0,1) (pass `rng.next`); an empty Callable falls back to randf() (TS: Math.random).
## Optional TS parameters that were `undefined` are "" (discipline_id) or an empty Callable (owned_ids).
## Drops are {item_id:String, quantity:int|float, instance?:{id,ilvl,affixes}}; a reward is {gold, materialGold, shards, items, xp}.
## NOT ported (stateful network bag, belongs to the net/inventory track): the `Inventory` class (optimistic add/consume, debounced
## saves, replace/reconcile of in-flight mutations). Its pure helpers (add_to_slots, sort_bag_slots, to_save_payload) are here.

const BAG_COLS := 8
const KILL_LOOT := {"itemChanceMult": 0.5, "materialQtyMult": 2, "goldEveryKills": 4}
const SORT_TYPES: Array[String] = ["weapon", "offhand", "armor_head", "armor_chest", "armor_legs", "armor_feet", "armor_hands", "ring", "trinket", "rune", "consumable", "material"]
const SORT_RARITY: Array[String] = ["relic", "legendary", "epic", "rare", "uncommon", "common"]
const NIGHTFALL_TIER := 8  # upgrades.ts WAVE_MILESTONES nightfall (checked against the wave_modifiers fixture)

static func bag_size() -> int:
	return DmLootData.bag_size()

static func bag_rows() -> int:
	return bag_size() / BAG_COLS

static func _r(rand: Callable) -> float:
	return randf() if rand.is_null() else float(rand.call())

static func _round(x: float) -> int:
	return DmAffixRules.js_round(x)

## rng.ts randInt: floor(min + rand * (max - min + 1)).
static func rand_int(rand: Callable, mn: float, mx: float) -> int:
	return int(floorf(mn + _r(rand) * (mx - mn + 1.0)))

## rng.ts pickWeighted over [{item, weight}]; null on an empty list.
static func pick_weighted(items: Array, r: float) -> Variant:
	if items.is_empty():
		return null
	var total := 0.0
	for i in items:
		total += float(i["weight"])
	var roll := r * total
	for i in items:
		if roll < float(i["weight"]):
			return i
		roll -= float(i["weight"])
	return items[items.size() - 1]

## upgrades.ts waveModifiers, the three fields loot reads: {rewardMult, xpMult, itemChanceMult}.
static func wave_mods(tier: float) -> Dictionary:
	var night := tier >= NIGHTFALL_TIER
	return {
		"rewardMult": 1.0 + 0.1 * tier + (0.25 if night else 0.0),
		"xpMult": 1.0 + 0.05 * tier + (0.15 if night else 0.0),
		"itemChanceMult": 1.0 + 0.06 * tier + (0.2 if night else 0.0),
	}

## Profession materials are gathered, not looted: a combat roll that lands on one pays its sell value in gold instead.
static func is_profession_material(id: String) -> bool:
	for p in ["ore_", "ingot_", "material_", "log_", "plank_", "bones_", "seed_", "herb_", "gem_"]:
		if id.begins_with(p):
			return true
	return false

## -> {drop: Dictionary|null, gold: int}
static func settle_combat_drop(d: Dictionary, keep_gems: bool = false) -> Dictionary:
	var id: String = d["item_id"]
	if not is_profession_material(id) or (keep_gems and id.begins_with("gem_")):
		return {"drop": d, "gold": 0}
	var sell := float(DmLootData.item(id).get("sell", 1))
	return {"drop": null, "gold": maxi(1, _round(sell * float(d["quantity"])))}

static func roll_kill(def: String, area: String, level: float, elite: bool, wave_tier: float, rand: Callable = Callable(), difficulty: String = "medium", item_chance_mult: float = 1.0, reagent_rand: Callable = Callable(), rune_rand: Callable = Callable(), discipline_id: String = "", owned_ids: Callable = Callable()) -> Dictionary:
	var d := DmLootData.enemy(def)
	var a := DmLootData.area(area)
	var mods := wave_mods(wave_tier)
	var diff := DmLootData.difficulty_reward_mult(difficulty)
	var level_mult := 1.0 + 0.15 * (level - 1.0)
	var elite_gold := float(DmLootData.content()["elite"]["goldMult"])
	var gold := _round(float(rand_int(rand, d["gold"][0], d["gold"][1])) * level_mult * mods["rewardMult"] * diff * (elite_gold if elite else 1.0))
	var material_gold := 0
	var shards := 0
	if elite:
		shards = 2 if _r(rand) < 0.25 else 1
	var items: Array = []
	var chance := minf(1.0, float(a["itemChance"]) * mods["itemChanceMult"] * item_chance_mult * (6.0 if elite else float(KILL_LOOT["itemChanceMult"])))
	if not a["loot"].is_empty() and _r(rand) < chance:
		var s := settle_combat_drop(roll_item(area, rand, 1 if elite else int(KILL_LOOT["materialQtyMult"]), discipline_id))
		if s["drop"] != null:
			items.append(s["drop"])
		material_gold += s["gold"]
	# Legendary armor: a very rare elite drop in the level-scaled areas, only when a discipline is passed.
	if discipline_id != "" and elite and a["scaling"]:
		var lid := DmLegendarySets.roll(discipline_id, DmLegendarySets.elite_chance(area), rand, owned_ids)
		if lid != "":
			items.append({"item_id": lid, "quantity": 1})
	items.append_array(roll_reagents(def, area, elite, item_chance_mult, reagent_rand))
	if elite:
		var rune: Variant = roll_elite_rune(area, item_chance_mult * mods["itemChanceMult"], rune_rand)
		if rune != null:
			items.append(rune)
	var xp := _round(float(d["xp"]) * (1.0 + 0.25 * (level - 1.0)) * mods["xpMult"] * diff * (float(DmLootData.content()["elite"]["xpMult"]) if elite else 1.0))
	return {"gold": gold, "materialGold": material_gold, "shards": shards, "items": items, "xp": xp}

## Reagent drops: independent of the area roll, per area and per enemy kind. No rand is consumed where no reagent can drop.
static func roll_reagents(def: String, area: String, elite: bool, item_chance_mult: float = 1.0, rand: Callable = Callable()) -> Array:
	var rc: Dictionary = DmLootData.content()["reagents"]
	var specs: Array = []
	specs.append_array(rc["area"].get(area, []))
	specs.append_array(rc["enemy"].get(def, []))
	var out: Array = []
	for s in specs:
		if _r(rand) >= minf(1.0, float(s["chance"]) * item_chance_mult * (float(rc["eliteMult"]) if elite else 1.0)):
			continue
		out.append({"item_id": s["item"], "quantity": rand_int(rand, s["qty"][0], s["qty"][1])})
	return out

## An elite's rune from the area's pool, or null.
static func roll_elite_rune(area: String, item_chance_mult: float = 1.0, rand: Callable = Callable()) -> Variant:
	var pool := DmLootRunes.area_pool(area)
	if pool.is_empty() or _r(rand) >= minf(1.0, DmLootRunes.elite_chance(area) * item_chance_mult):
		return null
	var id := DmLootRunes.pick_rune(pool, rand)
	return {"item_id": id, "quantity": 1} if id != "" else null

## A Grave Surge's offering: the area's item, or (35%) a rune in its place; never a profession material.
static func roll_surge_item(area: String, rand: Callable = Callable(), discipline_id: String = "") -> Dictionary:
	var pool := DmLootRunes.area_pool(area)
	if not pool.is_empty() and _r(rand) < DmLootRunes.surge_chance():
		var id := DmLootRunes.pick_rune(pool, rand)
		if id != "":
			return {"item_id": id, "quantity": 1}
	for i in 40:
		var d := roll_item(area, rand, 1, discipline_id)
		if not is_profession_material(d["item_id"]):
			return d
	return roll_item(area, rand, 1, discipline_id)

## A boss's rune: the Prelate and a boss's first kill always leave one; repeats roll 50%. null where the boss has no pool.
static func roll_boss_rune(boss: String, first: bool, rand: Callable = Callable()) -> Variant:
	var pool := DmLootRunes.boss_pool(boss)
	if pool.is_empty():
		return null
	if not (boss == "prelate" or first) and _r(rand) >= DmLootRunes.boss_repeat_chance():
		return null
	var id := DmLootRunes.pick_rune(pool, rand)
	return {"item_id": id, "quantity": 1} if id != "" else null

static func roll_item(area: String, rand: Callable = Callable(), material_qty_mult: int = 1, discipline_id: String = "") -> Dictionary:
	var table: Array = DmSmartLoot.smart_table(area, discipline_id) if discipline_id != "" else DmLootData.area(area)["loot"]
	var pick: Dictionary = pick_weighted(table, _r(rand))
	var meta := DmLootData.item(pick["item"])
	var qty := 1
	if meta.get("type", "") == "material":
		qty = (1 + (1 if _r(rand) < 0.35 else 0)) * material_qty_mult
	return {"item_id": pick["item"], "quantity": qty}

## A boss's spoils. Pass the boss id ("" = none) and the spoils always include its ichor.
static func roll_boss(wave_tier: float, rand: Callable = Callable(), difficulty: String = "medium", area: String = "sanctum", cost_shards: float = 5.0, boss: String = "", discipline_id: String = "", owned_ids: Callable = Callable()) -> Dictionary:
	var mods := wave_mods(wave_tier)
	var diff := DmLootData.difficulty_reward_mult(difficulty)
	var k := cost_shards / 5.0
	var items: Array = []
	var material_gold := 0
	for i in 3:
		var s := settle_combat_drop(roll_item(area, rand, 1, discipline_id), true)
		if s["drop"] != null:
			items.append(s["drop"])
		material_gold += s["gold"]
	if discipline_id != "" and DmLegendarySets.boss_chance(area) > 0.0:
		var lid := DmLegendarySets.roll(discipline_id, DmLegendarySets.boss_chance(area), rand, owned_ids)
		if lid != "":
			items.append({"item_id": lid, "quantity": 1})
	if boss != "":
		items.append({"item_id": DmLootData.content()["reagents"]["bossIchor"][boss], "quantity": 1})
	return {"gold": _round(320.0 * k * mods["rewardMult"] * diff), "materialGold": material_gold, "shards": 3 if cost_shards >= 5.0 else maxi(1, int(cost_shards) - 1), "items": items, "xp": _round(900.0 * k * diff)}

## A boss's first kill per character: a guaranteed rare-or-better item.
static func roll_first_kill_item(area: String, rand: Callable = Callable(), discipline_id: String = "") -> Dictionary:
	var table: Array = DmLootData.area(area)["loot"]
	if discipline_id != "":
		var own: Array = []
		for e in table:
			var id: String = e["item"]
			var r: String = str(DmLootData.item(id).get("rarity", ""))
			if DmLootData.armor_discipline(id) == discipline_id and (r == "rare" or r == "epic"):
				own.append(id)
		if not own.is_empty() and _r(rand) < 0.75:
			return {"item_id": own[int(floorf(_r(rand) * own.size()))], "quantity": 1}
	for i in 30:
		var d := roll_item(area, rand, 1, discipline_id)
		var r2: String = str(DmLootData.item(d["item_id"]).get("rarity", ""))
		if r2 == "rare" or r2 == "epic":
			return d
	var rares: Array = []
	for e in table:
		var m := DmLootData.item(e["item"])
		if not m.is_empty() and m["type"] != "material" and (m["rarity"] == "rare" or m["rarity"] == "epic"):
			rares.append(e["item"])
	var idx := int(floorf(_r(rand) * rares.size()))
	return {"item_id": rares[idx] if idx < rares.size() else "helm_gold", "quantity": 1}

# --- Bag -----------------------------------------------------------------------------------------------------------------------
static func _stackable(t: Variant) -> bool:
	return t == "material" or t == "rune"

static func _is_equipped(s: Dictionary) -> bool:
	return s.get("equipped", 0) != null and float(s.get("equipped", 0)) != 0.0

## Adds a drop to a slot array: stacks onto an existing slot of the same item (materials/runes), otherwise takes the first free
## slot_index. Returns a NEW array (inputs are never mutated) or null when the bag is full.
## Note: an item id the content does not know is treated as an uncapped material stack (the TS yields NaN quantities there).
static func add_to_slots(slots: Array, drop: Dictionary) -> Variant:
	var meta := DmLootData.item(drop["item_id"])
	var cap := INF
	if meta.get("stack") != null:
		cap = float(meta["stack"])
	elif not meta.is_empty() and not _stackable(meta["type"]):
		cap = 1.0
	var qty := float(drop["quantity"])
	var stack_idx := -1
	for i in slots.size():
		var s: Dictionary = slots[i]
		if s["item_id"] == drop["item_id"] and int(s["slot_index"]) < bag_size() and not _is_equipped(s) and (_stackable(s.get("item_type")) or _stackable(meta.get("type"))) and float(s["quantity"]) < cap:
			stack_idx = i
			break
	if stack_idx >= 0:
		var stack: Dictionary = slots[stack_idx]
		var add := minf(qty, cap - float(stack["quantity"]))
		var next: Array = slots.duplicate()
		var ns := stack.duplicate()
		ns["quantity"] = float(stack["quantity"]) + add
		next[stack_idx] = ns
		if add >= qty:
			return next
		var rest := drop.duplicate()
		rest["quantity"] = qty - add
		return add_to_slots(next, rest)
	var used := {}
	for s in slots:
		used[int(s["slot_index"])] = true
	var free := -1
	for i in bag_size():
		if not used.has(i):
			free = i
			break
	if free == -1:
		return null
	if qty > cap:
		var first := drop.duplicate()
		first["quantity"] = cap
		var placed: Variant = add_to_slots(slots, first)
		if placed == null:
			return null
		var second := drop.duplicate()
		second["quantity"] = qty - cap
		return add_to_slots(placed, second)
	var row := {
		"id": 0, "slot_index": free, "quantity": minf(qty, cap), "equipped": 0,
		"item_id": drop["item_id"], "name": meta.get("name", drop["item_id"]), "rarity": meta.get("rarity", "common"),
		"item_type": meta.get("type", "material"), "stat_bonus": meta.get("offlineStats"), "icon_id": null,
		"sell_value": meta.get("sell", 0), "crafted": 0,
	}
	if drop.get("instance") != null:
		row["instance_id"] = drop["instance"]["id"]
		row["ilvl"] = drop["instance"]["ilvl"]
		row["affixes"] = drop["instance"]["affixes"]
	var out: Array = slots.duplicate()
	out.append(DmAffixes.decorate_slot(row))
	return out

static func _rank(list: Array, v: Variant) -> int:
	var i := list.find(v)
	return list.size() if i < 0 else i

## Sort the bag (slots 0..bag_size-1 only): merge stackable materials and runes up to their stack size, then order by type, rarity
## (best first), item level (highest first) and name, packed from slot 0. Worn gear and belt slots are untouched.
## `moves` (a Dictionary, optional) receives old slot -> new slot for every bag slot. `is_locked(slot)->bool` (optional Callable).
static func sort_bag_slots(slots: Array, moves: Variant = null, is_locked: Callable = Callable()) -> Array:
	var size := bag_size()
	var in_bag := func(s: Dictionary) -> bool: return int(s["slot_index"]) >= 0 and int(s["slot_index"]) < size and not _is_equipped(s)
	var bag: Array = []
	var rest: Array = []
	for s in slots:
		if in_bag.call(s):
			bag.append(s)
		else:
			rest.append(s)
	bag.sort_custom(func(a, b): return int(a["slot_index"]) < int(b["slot_index"]))
	var rows: Array = []  # {slot, from}
	var open_row := {}
	for s in bag:
		var locked: bool = (not is_locked.is_null()) and bool(is_locked.call(s))
		var iid: Variant = s.get("instance_id")
		var has_iid: bool = iid != null and not (is_integer_zero(iid))
		var stackable: bool = _stackable(s.get("item_type")) and not has_iid and not locked
		if not stackable:
			rows.append({"slot": s, "from": [int(s["slot_index"])]})
			continue
		var cap := INF
		if DmLootData.item(s["item_id"]).get("stack") != null:
			cap = float(DmLootData.item(s["item_id"])["stack"])
		var left := float(s["quantity"])
		var first := true
		while left > 0.0:
			var at: int = open_row.get(s["item_id"], -1)
			if at < 0 or float(rows[at]["slot"]["quantity"]) >= cap:
				at = rows.size()
				var ns: Dictionary = s.duplicate()
				ns["quantity"] = 0
				rows.append({"slot": ns, "from": []})
				open_row[s["item_id"]] = at
			var row: Dictionary = rows[at]
			var add := minf(left, cap - float(row["slot"]["quantity"]))
			var upd: Dictionary = row["slot"].duplicate()
			upd["quantity"] = float(row["slot"]["quantity"]) + add
			row["slot"] = upd
			if first or row["from"].is_empty():
				row["from"].append(int(s["slot_index"]))
			first = false
			left -= add
	rows.sort_custom(func(a, b): return _row_less(a, b))
	if moves is Dictionary:
		moves.clear()
	var out: Array = rest
	for i in rows.size():
		var r: Dictionary = rows[i]
		if moves is Dictionary:
			for f in r["from"]:
				moves[f] = i
		var p: Dictionary = r["slot"].duplicate()
		p["slot_index"] = i
		out.append(p)
	return out

static func is_integer_zero(v: Variant) -> bool:
	return (v is int or v is float) and float(v) == 0.0

static func _row_less(a: Dictionary, b: Dictionary) -> bool:
	var sa: Dictionary = a["slot"]
	var sb: Dictionary = b["slot"]
	var c := _rank(SORT_TYPES, sa.get("item_type")) - _rank(SORT_TYPES, sb.get("item_type"))
	if c != 0: return c < 0
	c = _rank(SORT_RARITY, sa.get("rarity")) - _rank(SORT_RARITY, sb.get("rarity"))
	if c != 0: return c < 0
	var ia := float(sa.get("ilvl") if sa.get("ilvl") != null else 0)
	var ib := float(sb.get("ilvl") if sb.get("ilvl") != null else 0)
	if ib != ia: return ib - ia < 0.0
	var na := str(sa["name"])
	var nb := str(sb["name"])
	if na != nb: return na < nb
	var qa := float(sa["quantity"])
	var qb := float(sb["quantity"])
	if qb != qa: return qb - qa < 0.0
	return int(a["from"][0]) < int(b["from"][0])

## Payload for POST /api/inventory/save: the bag only (slot_index 0..bag_size-1); worn gear lives in reserved slots (100+).
static func to_save_payload(slots: Array) -> Array:
	var out: Array = []
	for s in slots:
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < bag_size():
			out.append({"slot_index": s["slot_index"], "item_id": s["item_id"], "quantity": s["quantity"], "equipped": s["equipped"], "instance_id": s.get("instance_id")})
	return out
