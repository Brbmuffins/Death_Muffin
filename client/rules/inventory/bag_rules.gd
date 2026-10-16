class_name DmBag
extends RefCounted
## Port of the bag rules in archive/legacy-web:src/gameplay/loot.ts: addToSlots (stacking, max stacks, slot placement). The Reliquary's Sort
## is the server's (DECISIONS B25). Slots are InventorySlot Dictionaries (net/types.ts): {id, slot_index, quantity, equipped (0|1),
## item_id, name, rarity, item_type, stat_bonus, icon_id, sell_value, crafted, instance_id?, ilvl?, affixes?, inst?}.
## NOTE: DmLoot (rules/loot/loot.gd) also ports add_to_slots but reads loot fixtures content; this copy is self-contained
## (data from godot/data/gathering) and verified against its own golden fixtures. Either may be used; results match the TS.
## Pure: input arrays are never mutated; functions return new arrays.

const Data := preload("res://rules/gathering/gather_data.gd")

const BAG_SIZE := 48
const BAG_COLS := 8
const BAG_ROWS := 6
## "Infinity" stack cap (unknown / unlimited).
const NO_CAP := 1 << 60


static func _stackable(t: Variant) -> bool:
	return t == "material" or t == "rune"


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
