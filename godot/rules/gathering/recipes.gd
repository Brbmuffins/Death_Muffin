class_name DmRecipes
extends RefCounted
## Workbench / station recipes (src/content/recipes.ts ALL_RECIPE_ROWS, processing.ts) and the pure crafting helpers
## (src/gameplay/craftQuantity.ts). The rows are exported from the real TS lists, not retyped.
##
## Recipe dict shape matches net/types Recipe: {id, name, skill (profession), skill_level_required, result_item_id,
## result_quantity, ingredients:[{item_id, quantity}]}.

const Data := preload("res://rules/gathering/gather_data.gd")

const MAX_CRAFT_BATCH := 100

static var _recipes: Array = []
static var _by_id: Dictionary = {}


## Convert one [id, name, profession, level, result, qty, [[item, n], ...]] row.
static func from_row(row: Array) -> Dictionary:
	var ings: Array = []
	for i in row[6]:
		ings.append({"item_id": i[0], "quantity": i[1]})
	return {"id": row[0], "name": row[1], "skill": row[2], "skill_level_required": row[3], "result_item_id": row[4], "result_quantity": row[5], "ingredients": ings}


## Every recipe the client knows (BASE + processing + alchemy + necro + reagent + fen + trade goods), in TS order.
static func all() -> Array:
	if _recipes.is_empty():
		for row in Data.get_data()["recipes"]:
			var r := from_row(row)
			_recipes.append(r)
			_by_id[r["id"]] = r
	return _recipes


static func recipe(id: String) -> Dictionary:
	all()
	return _by_id.get(id, {})


## Recipes for one profession (e.g. "mining"), sorted by required level (stable).
static func for_skill(skill: String) -> Array:
	var out: Array = []
	for r in all():
		if r["skill"] == skill:
			out.append(r)
	return out


## Recipes that produce `item_id` (the Gear Atlas "how do I craft this").
static func producing(item_id: String) -> Array:
	var out: Array = []
	for r in all():
		if r["result_item_id"] == item_id:
			out.append(r)
	return out


## Meal healing (processing.ts MEALS): {item_id: {healFrac, seconds}}.
static func meals() -> Dictionary:
	return Data.get_data()["meals"]


## Clamp a typed quantity to a whole number in 1..max (junk becomes 1).
static func clamp_craft_qty(raw: Variant, max_n: int = MAX_CRAFT_BATCH) -> int:
	var n := 1
	if raw is int or raw is float:
		var f := float(raw)
		if is_nan(f) or is_inf(f):
			return 1
		n = int(floor(f))
	elif raw is String and (raw as String).is_valid_float():
		n = int(floor((raw as String).to_float()))
	else:
		return 1
	if n < 1:
		return 1
	return mini(n, maxi(1, max_n))


## "Only craftable" filter: skill met and every ingredient in the bag. count = Callable(item_id) -> int.
static func has_skill_and_materials(rec: Dictionary, skill: int, count: Callable) -> bool:
	if skill < int(rec["skill_level_required"]):
		return false
	for ing in rec["ingredients"]:
		if int(count.call(ing["item_id"])) < int(ing["quantity"]):
			return false
	return true


## How many times `rec` can be crafted in a row from `slots` (InventorySlot dicts), by materials AND bag room, capped.
## stack_of = Callable(item_id) -> int (1 = never stacks; use a huge number for no cap).
static func max_craftable(rec: Dictionary, slots: Array, bag_size: int, stack_of: Callable, cap: int = MAX_CRAFT_BATCH) -> int:
	var bag: Array = []
	var occupied_by_equipped := 0
	for s in slots:
		var idx := int(s["slot_index"])
		if idx < 0 or idx >= bag_size:
			continue
		if int(s["equipped"]) == 0:
			bag.append({"id": s["item_id"], "q": int(s["quantity"])})
		else:
			occupied_by_equipped += 1
	var rq = rec["result_quantity"]
	var result_qty := maxi(1, int(rq) if rq != null else 1)
	var stack := maxi(1, int(stack_of.call(rec["result_item_id"])))
	var made := 0
	while made < cap:
		for ing in rec["ingredients"]:
			var have := 0
			for b in bag:
				if b["id"] == ing["item_id"]:
					have += b["q"]
			if have < int(ing["quantity"]):
				return made
		for ing in rec["ingredients"]:
			var need := int(ing["quantity"])
			for b in bag:
				if b["id"] != ing["item_id"] or need <= 0:
					continue
				var take := mini(need, b["q"])
				b["q"] -= take
				need -= take
		var i := bag.size() - 1
		while i >= 0:
			if bag[i]["q"] <= 0:
				bag.remove_at(i)
			i -= 1
		var left := result_qty
		if stack > 1:
			for b in bag:
				if b["id"] != rec["result_item_id"] or b["q"] >= stack or left <= 0:
					continue
				var add := mini(left, stack - b["q"])
				b["q"] += add
				left -= add
		while left > 0:
			if bag.size() + occupied_by_equipped >= bag_size:
				return made
			var add2 := mini(left, stack)
			bag.append({"id": rec["result_item_id"], "q": add2})
			left -= add2
		made += 1
	return made
