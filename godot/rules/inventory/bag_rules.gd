class_name DmBag
extends RefCounted
## Port of the bag rules in archive/legacy-web:src/gameplay/loot.ts: addToSlots (stacking, max stacks, slot placement), sortBagSlots (the Reliquary
## Sort button), toSavePayload. Slots are InventorySlot Dictionaries (net/types.ts): {id, slot_index, quantity, equipped (0|1),
## item_id, name, rarity, item_type, stat_bonus, icon_id, sell_value, crafted, instance_id?, ilvl?, affixes?, inst?}.
## NOTE: DmLoot (rules/loot/loot.gd) also ports add_to_slots/sort_bag_slots but reads loot fixtures content; this copy is self-contained
## (data from godot/data/gathering) and verified against its own golden fixtures. Either may be used; results match the TS.
## Pure: input arrays are never mutated; functions return new arrays.

const Data := preload("res://rules/gathering/gather_data.gd")
const Stable := preload("res://rules/inventory/stable_sort.gd")

const BAG_SIZE := 48
const BAG_COLS := 8
const BAG_ROWS := 6
## "Infinity" stack cap (unknown / unlimited).
const NO_CAP := 1 << 60

const SORT_TYPES: Array = ["weapon", "offhand", "armor_head", "armor_chest", "armor_legs", "armor_feet", "armor_hands", "ring", "trinket", "rune", "consumable", "material"]
const SORT_RARITY: Array = ["relic", "legendary", "epic", "rare", "uncommon", "common"]


static func _stackable(t: Variant) -> bool:
	return t == "material" or t == "rune"


static func _rank(list: Array, v: Variant) -> int:
	var i := list.find(v)
	return list.size() if i < 0 else i


## drop = {item_id, quantity, instance?: {id, ilvl, affixes}}. `decorate` (optional) = Callable(slot) -> slot, the loot track's
## decorateSlot hook (affix naming/rarity/sell for rolled pieces); identity by default.
## Returns the new slot array, or null when the bag is full.
static func add_to_slots(slots: Array, drop: Dictionary, decorate: Callable = Callable()) -> Variant:
	var items: Dictionary = Data.get_data()["items"]
	var meta: Variant = items.get(drop["item_id"], null)
	var cap: int = NO_CAP
	if meta != null:
		if (meta as Dictionary).has("stack"):
			cap = int(meta["stack"])
		elif not _stackable(meta["type"]):
			cap = 1
	var stack_idx := -1
	for i in slots.size():
		var s: Dictionary = slots[i]
		if s["item_id"] == drop["item_id"] and int(s["slot_index"]) < BAG_SIZE and int(s["equipped"]) == 0 \
				and (_stackable(s["item_type"]) or (meta != null and _stackable(meta["type"]))) and int(s["quantity"]) < cap:
			stack_idx = i
			break
	if stack_idx >= 0:
		var stack: Dictionary = slots[stack_idx]
		var add := mini(int(drop["quantity"]), cap - int(stack["quantity"]))
		var nxt: Array = []
		for i in slots.size():
			if i == stack_idx:
				var c: Dictionary = (slots[i] as Dictionary).duplicate()
				c["quantity"] = int(c["quantity"]) + add
				nxt.append(c)
			else:
				nxt.append(slots[i])
		if add >= int(drop["quantity"]):
			return nxt
		var rest := drop.duplicate()
		rest["quantity"] = int(drop["quantity"]) - add
		return add_to_slots(nxt, rest, decorate)
	var used: Dictionary = {}
	for s in slots:
		used[int(s["slot_index"])] = true
	var free := -1
	for i in BAG_SIZE:
		if not used.has(i):
			free = i
			break
	if free == -1:
		return null
	if int(drop["quantity"]) > cap:
		var first := drop.duplicate()
		first["quantity"] = cap
		var placed: Variant = add_to_slots(slots, first, decorate)
		if placed == null:
			return null
		var rest2 := drop.duplicate()
		rest2["quantity"] = int(drop["quantity"]) - cap
		return add_to_slots(placed, rest2, decorate)
	var slot := {
		"id": 0,
		"slot_index": free,
		"quantity": mini(int(drop["quantity"]), cap),
		"equipped": 0,
		"item_id": drop["item_id"],
		"name": meta["name"] if meta != null else drop["item_id"],
		"rarity": meta["rarity"] if meta != null else "common",
		"item_type": meta["type"] if meta != null else "material",
		"stat_bonus": meta.get("offlineStats", null) if meta != null else null,
		"icon_id": null,
		"sell_value": meta["sell"] if meta != null else 0,
		"crafted": 0,
	}
	if drop.has("instance"):
		slot["instance_id"] = drop["instance"]["id"]
		slot["ilvl"] = drop["instance"]["ilvl"]
		slot["affixes"] = drop["instance"]["affixes"]
	if decorate.is_valid():
		slot = decorate.call(slot)
	var out: Array = slots.duplicate()
	out.append(slot)
	return out


static func _truthy_id(v: Variant) -> bool:
	return v != null and not (v is int and v == 0)


## Sort the bag (slots 0..BAG_SIZE-1 only): merge stackable materials/runes up to their stack size, then order by type, rarity
## (best first), item level (high first) and name, packed from slot 0. Worn gear and belt slots untouched.
## `moves` (optional Dictionary) is cleared and filled with old slot -> new slot. `is_locked` optional Callable(slot) -> bool.
static func sort_bag_slots(slots: Array, moves: Dictionary = {}, is_locked: Callable = Callable()) -> Array:
	var items: Dictionary = Data.get_data()["items"]
	var in_bag: Array = []
	var others: Array = []
	for s in slots:
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < BAG_SIZE and int(s["equipped"]) == 0:
			in_bag.append(s)
		else:
			others.append(s)
	in_bag = Stable.sorted(in_bag, func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot_index"]) < int(b["slot_index"]))
	var rows: Array = []  # {slot: Dictionary, from: Array[int]}
	var open_row: Dictionary = {}
	for s in in_bag:
		var locked: bool = is_locked.is_valid() and bool(is_locked.call(s))
		var stackable: bool = _stackable(s["item_type"]) and not _truthy_id(s.get("instance_id", null)) and not locked
		if not stackable:
			rows.append({"slot": s, "from": [int(s["slot_index"])]})
			continue
		var cap: int = int(items[s["item_id"]]["stack"]) if items.has(s["item_id"]) and items[s["item_id"]].has("stack") else NO_CAP
		var left := int(s["quantity"])
		var first := true
		while left > 0:
			var at: int = open_row.get(s["item_id"], -1)
			if at < 0 or int(rows[at]["slot"]["quantity"]) >= cap:
				at = rows.size()
				var z: Dictionary = (s as Dictionary).duplicate()
				z["quantity"] = 0
				rows.append({"slot": z, "from": []})
				open_row[s["item_id"]] = at
			var row: Dictionary = rows[at]
			var add := mini(left, cap - int(row["slot"]["quantity"]))
			var ns: Dictionary = (row["slot"] as Dictionary).duplicate()
			ns["quantity"] = int(ns["quantity"]) + add
			row["slot"] = ns
			if first or (row["from"] as Array).is_empty():
				(row["from"] as Array).append(int(s["slot_index"]))
			first = false
			left -= add
	rows = Stable.sorted(rows, func(a: Dictionary, b: Dictionary) -> bool:
		var c := _rank(SORT_TYPES, a["slot"]["item_type"]) - _rank(SORT_TYPES, b["slot"]["item_type"])
		if c != 0:
			return c < 0
		c = _rank(SORT_RARITY, a["slot"]["rarity"]) - _rank(SORT_RARITY, b["slot"]["rarity"])
		if c != 0:
			return c < 0
		var ia: int = int(a["slot"].get("ilvl", 0)) if a["slot"].get("ilvl", null) != null else 0
		var ib: int = int(b["slot"].get("ilvl", 0)) if b["slot"].get("ilvl", null) != null else 0
		if ia != ib:
			return ia > ib
		var na: String = a["slot"]["name"]
		var nb: String = b["slot"]["name"]
		if na != nb:
			return na < nb
		var qa: int = int(a["slot"]["quantity"])
		var qb: int = int(b["slot"]["quantity"])
		if qa != qb:
			return qa > qb
		return int(a["from"][0]) < int(b["from"][0]))
	moves.clear()
	var out: Array = others.duplicate()
	for i in rows.size():
		for f in rows[i]["from"]:
			moves[int(f)] = i
		var p: Dictionary = (rows[i]["slot"] as Dictionary).duplicate()
		p["slot_index"] = i
		out.append(p)
	return out


## Payload for POST /api/inventory/save: bag slots only. Rows the server would refuse the whole save for (no string item_id, quantity under 1,
## out of range) are left out: a slot missing from the payload is an emptied slot.
static func to_save_payload(slots: Array) -> Array:
	var out: Array = []
	for s in slots:
		if not (s is Dictionary) or not (s.get("item_id") is String) or String(s["item_id"]).strip_edges().is_empty():
			continue
		var idx := int(s.get("slot_index", -1))
		var qty := floorf(float(s.get("quantity", 0)))
		if idx < 0 or idx >= BAG_SIZE or is_nan(qty) or is_inf(qty) or qty < 1.0:
			continue
		out.append({"slot_index": idx, "item_id": s["item_id"], "quantity": int(qty), "equipped": int(s.get("equipped", 0)) if s.get("equipped") != null else 0, "instance_id": s.get("instance_id", null)})
	return out
