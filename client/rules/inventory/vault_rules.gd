class_name DmVault
extends RefCounted
## Port of server/rules/gameplay/vaultRules.ts (the Ossuary Vault shared stash: 120 slots, 3 tabs of 40) including sort_vault.
## Pure: every function takes plain row arrays and returns new ones; a move either fits entirely or is refused with a player-readable
## error. SERVER-AUTHORITATIVE (vault.cjs uses the same rules); the client uses them for previews and the offline mock.
##
## Row = {slot:int, itemId:String, qty:int, fixed?:bool, inst?:int, power?:int}.
## info = Callable(itemId) -> {maxStack:int, itemType:String, rarity:String}.
## Results: {ok:true, bag, vault, moved} or {ok:false, error}.

const Stable := preload("res://rules/inventory/stable_sort.gd")
const G := preload("res://rules/gathering/gathering_rules.gd")

const VAULT_SLOTS := 120
const VAULT_TAB_SIZE := 40
const TYPE_ORDER: Array = ["weapon", "offhand", "armor_head", "armor_chest", "armor_legs", "armor_feet", "armor_hands", "ring", "trinket", "rune", "consumable", "material"]
const RARITY_ORDER: Array = ["relic", "legendary", "epic", "rare", "uncommon", "common"]
const EFFECTIVE_BY_COUNT: Array = ["common", "uncommon", "rare", "epic"]
const NO_ROOM_VAULT := "The Vault has no room for that. Make space or sort it first."
const NO_ROOM_BAG := "Your Reliquary has no room for that. Make space first."


static func _clone(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		out.append((r as Dictionary).duplicate())
	return _by_slot(out)


static func _by_slot(rows: Array) -> Array:
	return Stable.sorted(rows, func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot"]) < int(b["slot"]))


## Tab index (0..2) of a vault slot, and the slot range of a tab.
static func tab_of(slot: int) -> int:
	return slot / VAULT_TAB_SIZE


static func tab_range(tab: int) -> Array:
	return [tab * VAULT_TAB_SIZE, (tab + 1) * VAULT_TAB_SIZE - 1]


## Stack `qty` onto matching stacks in `rows`, then into free slots below `size`. MUTATES rows; returns what did NOT fit.
static func _put(rows: Array, size: int, item_id: String, qty: int, max_stack: int, inst: Variant = null, power: Variant = null) -> int:
	var left := qty
	var cap: int = 1 if inst != null else maxi(1, max_stack)
	if cap > 1:
		for r in rows:
			if left <= 0:
				break
			if r.get("fixed", false) or r["itemId"] != item_id or int(r["qty"]) >= cap:
				continue
			var add := mini(left, cap - int(r["qty"]))
			r["qty"] = int(r["qty"]) + add
			left -= add
	var used: Dictionary = {}
	for r in rows:
		used[int(r["slot"])] = true
	var s := 0
	while s < size and left > 0:
		if not used.has(s):
			var add2 := mini(left, cap)
			var row := {"slot": s, "itemId": item_id, "qty": add2}
			if inst != null:
				row["inst"] = inst
				if power != null:
					row["power"] = power
			rows.append(row)
			used[s] = true
			left -= add2
		s += 1
	return left


## Move (part of) the stack in `from_slot`. `qty` null = the whole stack.
static func move_stack(from: Array, to: Array, from_slot: int, qty: Variant, to_size: int, info: Callable, to_vault: bool) -> Dictionary:
	var src := _clone(from)
	var dst := _clone(to)
	var row: Dictionary = {}
	for r in src:
		if int(r["slot"]) == from_slot:
			row = r
			break
	if row.is_empty():
		return {"ok": false, "error": "There is nothing in that slot."}
	if row.get("fixed", false):
		return {"ok": false, "error": "Equipped gear cannot be stored. Unequip it first."}
	var want: int = int(row["qty"])
	if qty != null:
		var f := float(qty)
		if is_nan(f) or is_inf(f) or floorf(f) < 1.0:
			return {"ok": false, "error": "Choose how many to move."}
		want = int(floorf(f))
	var n := mini(want, int(row["qty"]))
	if _put(dst, to_size, row["itemId"], n, int(info.call(row["itemId"])["maxStack"]), row.get("inst", null), row.get("power", null)) > 0:
		return {"ok": false, "error": NO_ROOM_VAULT if to_vault else NO_ROOM_BAG}
	row["qty"] = int(row["qty"]) - n
	var left: Array = []
	for r in src:
		if int(r["qty"]) > 0:
			left.append(r)
	return {"ok": true, "bag": left if to_vault else _by_slot(dst), "vault": _by_slot(dst) if to_vault else left, "moved": n}


static func deposit_stack(bag: Array, vault: Array, bag_slot: int, qty: Variant, info: Callable) -> Dictionary:
	return move_stack(bag, vault, bag_slot, qty, VAULT_SLOTS, info, true)


static func withdraw_stack(bag: Array, vault: Array, vault_slot: int, qty: Variant, info: Callable) -> Dictionary:
	return move_stack(vault, bag, vault_slot, qty, G.BAG_SLOTS, info, false)


## Port of vaultRules.moveToSlot: (part of) the stack in `from_slot` of `from_side` ("bag" | "vault") to exactly `to_slot` of `to_side` (the same
## side rearranges). Empty target = put there; the same stackable item = merge (what does not fit stays); anything else = swap (whole stacks
## only). Equipped gear (fixed) never moves and is never swapped. `qty` null = the whole stack.
static func move_to_slot(bag: Array, vault: Array, from_side: String, from_slot: int, to_side: String, to_slot: int, qty: Variant, info: Callable) -> Dictionary:
	var b := _clone(bag)
	var v := _clone(vault)
	var size := func(side: String) -> int: return G.BAG_SLOTS if side == "bag" else VAULT_SLOTS
	if to_slot < 0 or to_slot >= int(size.call(to_side)):
		return {"ok": false, "error": "That slot does not exist."}
	var src: Array = b if from_side == "bag" else v
	var dst: Array = b if to_side == "bag" else v
	var row: Dictionary = {}
	for r in src:
		if int(r["slot"]) == from_slot:
			row = r
			break
	if row.is_empty():
		return {"ok": false, "error": "There is nothing in that slot."}
	if row.get("fixed", false):
		return {"ok": false, "error": "Equipped gear stays where it is. Unequip it first."}
	var want: int = int(row["qty"])
	if qty != null:
		var f := float(qty)
		if is_nan(f) or is_inf(f) or floorf(f) < 1.0:
			return {"ok": false, "error": "Choose how many to move."}
		want = int(floorf(f))
	var n := mini(want, int(row["qty"]))
	var done := func(moved: int) -> Dictionary:
		var keep := func(rows: Array) -> Array:
			var out: Array = []
			for r in rows:
				if int(r["qty"]) > 0:
					out.append(r)
			return _by_slot(out)
		return {"ok": true, "bag": keep.call(b), "vault": keep.call(v), "moved": moved}
	if from_side == to_side and from_slot == to_slot:
		return done.call(0)
	var target: Dictionary = {}
	for r in dst:
		if int(r["slot"]) == to_slot:
			target = r
			break
	if target.is_empty():
		if n == int(row["qty"]):
			src.erase(row)
			var moved_row := row.duplicate()
			moved_row["slot"] = to_slot
			dst.append(moved_row)
		else:
			row["qty"] = int(row["qty"]) - n
			dst.append({"slot": to_slot, "itemId": row["itemId"], "qty": n})
		return done.call(n)
	if target.get("fixed", false):
		return {"ok": false, "error": "That slot holds equipped gear."}
	var cap := 1 if (row.get("inst", null) != null or target.get("inst", null) != null) else maxi(1, int(info.call(row["itemId"])["maxStack"]))
	if target["itemId"] == row["itemId"] and cap > 1:
		var add := mini(n, cap - int(target["qty"]))
		if add <= 0:
			return {"ok": false, "error": "That stack is full."}
		target["qty"] = int(target["qty"]) + add
		row["qty"] = int(row["qty"]) - add
		return done.call(add)
	if n != int(row["qty"]):
		return {"ok": false, "error": "Drop part of a stack on an empty slot or on the same item."}
	if from_side == to_side:   # (Array == compares contents in GDScript, so test the sides)
		target["slot"] = from_slot
		row["slot"] = to_slot
	else:
		src.erase(row)
		dst.erase(target)
		var r2 := row.duplicate()
		r2["slot"] = to_slot
		dst.append(r2)
		var t2 := target.duplicate()
		t2["slot"] = from_slot
		src.append(t2)
	return done.call(n)


static func _is_material_like(t: String) -> bool:
	return t == "material" or t == "rune"


## Deposit every bag stack of `kind` ("materials" | "all"; never fixed rows, never except_slots). All or nothing.
static func deposit_many(bag: Array, vault: Array, kind: String, except_slots: Array, info: Callable) -> Dictionary:
	var except: Dictionary = {}
	for s in except_slots:
		except[int(s)] = true
	var src := _clone(bag)
	var dst := _clone(vault)
	var moved := 0
	var keep: Array = []
	for r in src:
		var i: Dictionary = info.call(r["itemId"])
		var take: bool = not r.get("fixed", false) and not except.has(int(r["slot"])) and (kind == "all" or _is_material_like(i["itemType"]))
		if not take:
			keep.append(r)
			continue
		if _put(dst, VAULT_SLOTS, r["itemId"], int(r["qty"]), int(i["maxStack"]), r.get("inst", null), r.get("power", null)) > 0:
			return {"ok": false, "error": "The Vault cannot hold all of that. Nothing was moved. Sort the Vault or free some space."}
		moved += int(r["qty"])
	if moved == 0:
		return {"ok": false, "error": "You carry no materials to deposit." if kind == "materials" else "You carry nothing to deposit."}
	return {"ok": true, "bag": keep, "vault": _by_slot(dst), "moved": moved}


static func _rank(list: Array, v: String) -> int:
	var i := list.find(v)
	return list.size() if i < 0 else i


## Merge stacks, then order by type, rarity (best first; a rolled piece counts as the better of its base and its affix tier), power
## and id. Packed from slot 0 (the Vault's Sort button).
static func sort_vault(vault: Array, info: Callable) -> Array:
	var totals: Dictionary = {}
	for r in vault:
		if not r.has("inst") or r["inst"] == null:
			totals[r["itemId"]] = int(totals.get(r["itemId"], 0)) + int(r["qty"])
	var stacks: Array = []
	for item_id in totals:
		var cap := maxi(1, int(info.call(item_id)["maxStack"]))
		var left: int = totals[item_id]
		while left > 0:
			stacks.append({"itemId": item_id, "qty": mini(cap, left)})
			left -= cap
	for r in vault:
		if r.has("inst") and r["inst"] != null:
			var st := {"itemId": r["itemId"], "qty": 1, "inst": r["inst"]}
			if r.has("power"):
				st["power"] = r["power"]
			stacks.append(st)
	var rarity_rank := func(s: Dictionary) -> int:
		var base := _rank(RARITY_ORDER, info.call(s["itemId"])["rarity"])
		if not s.has("power"):
			return base
		return mini(base, _rank(RARITY_ORDER, EFFECTIVE_BY_COUNT[mini(3, int(floor(float(s["power"]) / 1000.0)))]))
	stacks = Stable.sorted(stacks, func(a: Dictionary, b: Dictionary) -> bool:
		var ia: Dictionary = info.call(a["itemId"])
		var ib: Dictionary = info.call(b["itemId"])
		var c := _rank(TYPE_ORDER, ia["itemType"]) - _rank(TYPE_ORDER, ib["itemType"])
		if c != 0:
			return c < 0
		c = int(rarity_rank.call(a)) - int(rarity_rank.call(b))
		if c != 0:
			return c < 0
		if a["itemId"] != b["itemId"]:
			return String(a["itemId"]) < String(b["itemId"])
		var pa: int = int(a.get("power", 0))
		var pb: int = int(b.get("power", 0))
		if pa != pb:
			return pa > pb
		if int(a["qty"]) != int(b["qty"]):
			return int(a["qty"]) > int(b["qty"])
		return int(a.get("inst", 0)) < int(b.get("inst", 0)))
	var out: Array = []
	for slot in stacks.size():
		var s: Dictionary = stacks[slot]
		var row := {"slot": slot, "itemId": s["itemId"], "qty": s["qty"]}
		if s.has("inst"):
			row["inst"] = s["inst"]
			if s.has("power"):
				row["power"] = s["power"]
		out.append(row)
	return out


## Put grants ([{itemId, qty}]) into a bag (stack, then free slots). Used by salvage. Returns null if they do not all fit.
static func add_grants(bag: Array, grants: Array, info: Callable) -> Variant:
	var rows := _clone(bag)
	for g in grants:
		if _put(rows, G.BAG_SLOTS, g["itemId"], int(g["qty"]), int(info.call(g["itemId"])["maxStack"])) > 0:
			return null
	return _by_slot(rows)


## Port of vaultRules.sortBag (the Reliquary's Sort, decided by the server, DECISIONS B25): merge stacks (never a rolled piece or a locked
## slot), order by type, rarity, item level (high first), name, size and old slot, packed from slot 0 around `fixed` rows.
## info(itemId) may carry `name`. Returns {bag, moves: {old slot: new slot}}.
static func sort_bag(bag: Array, info: Callable, locked: Array = []) -> Dictionary:
	var rows: Array = []   # {row, from}
	var open: Dictionary = {}
	var fixed: Array = []
	for r in _by_slot(_clone(bag)):
		if bool(r.get("fixed", false)):
			fixed.append(r)
			continue
		var cap := 1 if (r.has("inst") and r["inst"] != null) else maxi(1, int(info.call(r["itemId"])["maxStack"]))
		if cap <= 1 or locked.has(int(r["slot"])):
			rows.append({"row": r, "from": [int(r["slot"])]})
			continue
		var left := int(r["qty"])
		var first := true
		while left > 0:
			var at: int = open.get(r["itemId"], -1)
			if at < 0 or int(rows[at]["row"]["qty"]) >= cap:
				at = rows.size()
				rows.append({"row": {"slot": int(r["slot"]), "itemId": r["itemId"], "qty": 0}, "from": []})
				open[r["itemId"]] = at
			var add := mini(left, cap - int(rows[at]["row"]["qty"]))
			rows[at]["row"]["qty"] = int(rows[at]["row"]["qty"]) + add
			if first or (rows[at]["from"] as Array).is_empty():
				rows[at]["from"].append(int(r["slot"]))
			first = false
			left -= add
	var name_of := func(id: String) -> String: return String(info.call(id).get("name", id))
	rows = Stable.sorted(rows, func(a: Dictionary, b: Dictionary) -> bool:
		var ia: Dictionary = info.call(a["row"]["itemId"])
		var ib: Dictionary = info.call(b["row"]["itemId"])
		var c := _rank(TYPE_ORDER, ia["itemType"]) - _rank(TYPE_ORDER, ib["itemType"])
		if c != 0:
			return c < 0
		c = _rank(RARITY_ORDER, ia["rarity"]) - _rank(RARITY_ORDER, ib["rarity"])
		if c != 0:
			return c < 0
		var la := int(a["row"].get("ilvl", 0)) if a["row"].get("ilvl") != null else 0
		var lb := int(b["row"].get("ilvl", 0)) if b["row"].get("ilvl") != null else 0
		if la != lb:
			return la > lb
		var na: String = name_of.call(a["row"]["itemId"])
		var nb: String = name_of.call(b["row"]["itemId"])
		if na != nb:
			return na < nb
		if int(a["row"]["qty"]) != int(b["row"]["qty"]):
			return int(a["row"]["qty"]) > int(b["row"]["qty"])
		return int(a["from"][0]) < int(b["from"][0]))
	var taken: Dictionary = {}
	for r in fixed:
		taken[int(r["slot"])] = true
	var out: Array = fixed.duplicate()
	var moves: Dictionary = {}
	var slot := 0
	for e in rows:
		while taken.has(slot):
			slot += 1
		var r: Dictionary = e["row"].duplicate()
		r["slot"] = slot
		out.append(r)
		for f in e["from"]:
			moves[int(f)] = slot
		slot += 1
	return {"bag": _by_slot(out), "moves": moves}


const MAX_USES := 40

## Port of vaultRules.useItems (DECISIONS B25): take each used consumable from the named slot first, then its other stacks; anything that is
## not a consumable, or that the bag no longer holds, is skipped. uses = [{itemId, slot?, qty}]. Returns {bag, used: [{itemId, qty}]}.
static func use_items(bag: Array, uses: Array, info: Callable) -> Dictionary:
	var rows := _clone(bag)
	var used: Dictionary = {}
	for u in uses.slice(0, MAX_USES):
		if String(info.call(u["itemId"])["itemType"]) != "consumable":
			continue
		var left := maxi(0, int(u["qty"]))
		var want := int(u.get("slot", -1))
		var order: Array = rows.filter(func(r): return not bool(r.get("fixed", false)) and not (r.has("inst") and r["inst"] != null) and r["itemId"] == u["itemId"])
		order.sort_custom(func(a, b): return int(a["slot"]) == want if (int(a["slot"]) == want) != (int(b["slot"]) == want) else int(a["slot"]) < int(b["slot"]))
		for r in order:
			if left <= 0:
				break
			var take := mini(left, int(r["qty"]))
			r["qty"] = int(r["qty"]) - take
			left -= take
			used[u["itemId"]] = int(used.get(u["itemId"], 0)) + take
	var out: Array = []
	for item_id in used:
		out.append({"itemId": item_id, "qty": used[item_id]})
	return {"bag": rows.filter(func(r): return int(r["qty"]) > 0), "used": out}
