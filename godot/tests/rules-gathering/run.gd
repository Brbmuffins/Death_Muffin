extends SceneTree
## Headless: godot --headless --path godot --script res://tests/rules-gathering/run.gd
## Reproduces the golden fixtures (godot/tests/rules-gathering/fixtures, generated from the TS by tools/godot/fixtures-gathering.ts).

const FX := "res://tests/rules-gathering/fixtures/"
const Rng := preload("res://rules/core/rng.gd")
const G := preload("res://rules/gathering/gathering_rules.gd")
const Data := preload("res://rules/gathering/gather_data.gd")
const Rec := preload("res://rules/gathering/recipes.gd")
const Sal := preload("res://rules/gathering/salvage_rules.gd")
const GS := preload("res://rules/gathering/gold_sink_rules.gd")
const Gar := preload("res://rules/gathering/garden_rules.gd")
const Lab := preload("res://rules/gathering/labor_rules.gd")
const Con := preload("res://rules/gathering/contract_rules.gd")
const Bag := preload("res://rules/inventory/bag_rules.gd")
const Locks := preload("res://rules/inventory/item_locks.gd")
const Vault := preload("res://rules/inventory/vault_rules.gd")
const Belt := preload("res://rules/inventory/potion_belt_rules.gd")
const Stable := preload("res://rules/inventory/stable_sort.gd")

var pass_n := 0
var fail_n := 0
var section := ""


func _init() -> void:
	if not FileAccess.file_exists(FX + "consts.json"):
		printerr("fixtures missing (committed under tests/<suite>/fixtures)")
		quit(1)
		return
	for t in ["consts", "xp", "chance", "rolls", "budget", "tools", "place_items", "plan", "labor", "garden", "contracts", "salvage", "gold_sink", "recipes", "bag", "locks", "vault", "potion_belt", "stable_sort"]:
		section = t
		call("_test_" + t)
	print("rules-gathering: %d passed, %d failed" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)


func ok(cond: bool, msg: String) -> void:
	if cond:
		pass_n += 1
	else:
		fail_n += 1
		if fail_n <= 40:
			printerr("FAIL [%s]: %s" % [section, msg])


func fx(name: String) -> Variant:
	var f := FileAccess.open(FX + name + ".json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


## Deep equality: numbers within 1e-9 (relative for large), everything else exact. Returns "" if equal else a path description.
func diff(a: Variant, b: Variant, path: String = "") -> String:
	var an := a is int or a is float
	var bn := b is int or b is float
	if an and bn:
		var x := float(a)
		var y := float(b)
		if absf(x - y) <= 1e-9 * maxf(1.0, maxf(absf(x), absf(y))):
			return ""
		return "%s: %s != %s" % [path, str(a), str(b)]
	if a == null or b == null:
		return "" if a == null and b == null else "%s: %s != %s" % [path, str(a), str(b)]
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: array size %d != %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not b.has(k):
				return "%s: extra key %s" % [path, str(k)]
		for k in b:
			if not a.has(k):
				return "%s: missing key %s" % [path, str(k)]
			var d := diff(a[k], b[k], "%s.%s" % [path, str(k)])
			if d != "":
				return d
		return ""
	if typeof(a) != typeof(b):
		return "%s: type %d != %d (%s vs %s)" % [path, typeof(a), typeof(b), str(a), str(b)]
	return "" if a == b else "%s: %s != %s" % [path, str(a), str(b)]


## got = our result, want = fixture.
func eq(got: Variant, want: Variant, label: String) -> void:
	var d := diff(got, want)
	ok(d == "", "%s -> %s" % [label, d])


func _test_consts() -> void:
	var c: Dictionary = fx("consts")
	ok(G.TICK_MS == c["TICK_MS"] and G.LEVEL_CAP == c["LEVEL_CAP"] and G.GATHER_BURST == c["GATHER_BURST"], "basic consts")
	ok(G.GATHER_MAX_WINDOW_MS == c["GATHER_MAX_WINDOW_MS"] and G.GATHER_MAX_ACTIONS_PER_HOUR == c["GATHER_MAX_ACTIONS_PER_HOUR"], "budget consts")
	ok(G.GATHER_FLUSH_MS == c["GATHER_FLUSH_MS"] and G.GATHER_MAX_BATCH == c["GATHER_MAX_BATCH"], "flush consts")
	ok(G.BAG_SLOTS == c["BAG_SLOTS"] and Bag.BAG_SIZE == c["BAG_SLOTS"] and G.MATERIAL_STACK == c["MATERIAL_STACK"], "bag consts")
	ok(G.BELT_BASE == c["BELT_BASE"], "belt base")
	eq(G.BELT_KINDS, c["BELT_KINDS"], "belt kinds")
	eq(G.TOOL_METALS, c["TOOL_METALS"], "tool metals")
	eq(G.TOOL_KIND, c["TOOL_KIND"], "tool kind")
	eq(G.SKILL_IDS, c["SKILLS"], "skills")
	ok(G.RICH_YIELD == c["RICH_YIELD"] and G.RICH_RESPAWN == c["RICH_RESPAWN"], "rich")
	ok(Data.get_data()["nodes"].size() == 30, "30 nodes loaded")


func _test_xp() -> void:
	for c in fx("xp"):
		match c["k"]:
			"next":
				var l := int(c["level"])
				ok(G.xp_to_next_live(l) == int(c["live"]), "xp_to_next_live %d" % l)
				ok(G.xp_to_next_curve(l) == int(c["curve"]), "xp_to_next_curve %d" % l)
			"total":
				ok(G.total_xp_for(int(c["level"])) == int(c["v"]), "total_xp_for %d" % int(c["level"]))
				ok(G.total_xp_for(int(c["level"]), true) == int(c["curve"]), "total_xp_for curve %d" % int(c["level"]))
			"add":
				eq(G.add_skill_xp(c["p"], c["gained"]), c["out"], "add_skill_xp %s" % str(c["p"]))


func _test_chance() -> void:
	for c in fx("chance"):
		var n := G.node_def(c["node"])
		eq(G.success_chance(n, int(c["level"]), int(c["tier"])), c["chance"], "chance %s" % c["node"])
		eq(G.xp_per_hour(n, int(c["level"]), int(c["tier"])), c["xph"], "xph %s" % c["node"])
		ok(G.action_ms(n) == int(c["ms"]), "action_ms")


func _test_rolls() -> void:
	for c in fx("gather_rolls"):
		var rng := Rng.new(c["seed"])
		var n := G.node_def(c["node"])
		var rolls: Array = []
		for i in 6:
			rolls.append(G.roll_gather(n, int(c["level"]), rng.as_callable(), int(c["tier"])))
		eq(rolls, c["rolls"], "roll_gather %s seed %s" % [c["node"], c["seed"]])
	for c in fx("batch"):
		var rng := Rng.new(c["seed"])
		var r := G.roll_batch(G.node_def(c["node"]), c["start"], int(c["actions"]), rng.as_callable(), int(c["tier"]), int(c["floor"]))
		eq(r, c["out"], "roll_batch %s seed %s" % [c["node"], c["seed"]])


func _test_budget() -> void:
	for c in fx("budget"):
		var r := G.check_budget(G.node_def(c["node"]), c["ledger"], c["claimed"], int(c["now"]), c["afk"])
		eq(r, c["out"], "check_budget %s" % str(c))


func _test_tools() -> void:
	var t: Dictionary = fx("tools")
	for c in t["tiers"]:
		if c.has("tier"):
			ok(G.tool_tier_for(c["skill"], c["held"]) == int(c["tier"]), "tool_tier_for %s %s" % [c["skill"], str(c["held"])])
		else:
			ok(G.tool_item_id(c["skill"], int(c["id_for_tier"])) == c["id"], "tool_item_id")
	for c in t["kinds"]:
		var k: String = c["kind"] if c["kind"] != null else ""
		ok(G.tool_kind_of(c["id"]) == k, "tool_kind_of %s" % c["id"])
		ok(G.belt_slot_of(c["id"]) == int(c["slot"]), "belt_slot_of %s" % c["id"])
	for c in t["slots"]:
		var k: String = c["kind"] if c["kind"] != null else ""
		ok(G.is_belt_slot(int(c["slot"])) == c["isBelt"], "is_belt_slot")
		ok(G.belt_slot_kind(int(c["slot"])) == k, "belt_slot_kind")
	for c in t["bests"]:
		eq(G.best_tool_per_kind(c["held"]), c["best"], "best_tool_per_kind %s" % str(c["held"]))
	ok(G.belt_equipped_slot("rod") == "belt_rod", "belt_equipped_slot")


func _test_place_items() -> void:
	var f: Dictionary = fx("place_items")
	var table: Dictionary = f["stackTable"]
	var ms := func(id: String) -> int: return int(table.get(id, 1))
	for c in f["cases"]:
		eq(G.place_items(c["bag"], c["grants"], ms), c["out"], "place_items")


func _test_plan() -> void:
	var f: Dictionary = fx("plan")
	for c in f["stands"]:
		var circles: Array = c["circles"]
		var blocked := func(x: float, z: float, r: float) -> bool:
			for k in circles:
				if sqrt((x - k["x"]) * (x - k["x"]) + (z - k["z"]) * (z - k["z"])) < float(k["r"]) + r:
					return true
			return false
		var got: Dictionary = G.stand_spot(blocked, c["node"], c["from"]["x"], c["from"]["z"]) if c["defaultR"] else G.stand_spot(blocked, c["node"], c["from"]["x"], c["from"]["z"], c["r"])
		eq(got if not got.is_empty() else null, c["out"], "stand_spot %s" % str(c["node"]))
	for c in f["blockers"]:
		var want: Variant = c["out"]
		ok(G.gather_blocker(c["type"], int(c["level"])) == (want if want != null else ""), "gather_blocker %s %s" % [c["type"], str(c["level"])])
	for c in f["autos"]:
		var got: Dictionary = G.next_auto_node(c["from"], c["nodes"], int(c["level"]), c["x"], c["z"])
		var idx := -1
		if not got.is_empty():
			idx = (c["nodes"] as Array).find(got)
		# duplicates by value: compare first match index by value is ambiguous, so compare the node contents instead
		if int(c["out"]) < 0:
			ok(got.is_empty(), "next_auto_node expects none")
		else:
			eq(got, c["nodes"][int(c["out"])], "next_auto_node")


func _test_labor() -> void:
	for c in fx("labor"):
		match c["k"]:
			"posts":
				ok(Lab.total_gather_level(c["levels"]) == int(c["total"]), "total_gather_level")
				ok(Lab.labor_slots(int(c["total"])) == int(c["slots"]), "labor_slots")
				var ids: Array = []
				for n in Lab.posts_for(c["levels"]):
					ids.append(n["id"])
				eq(ids, c["posts"], "posts_for")
			"slots":
				ok(Lab.labor_slots(int(c["total"])) == int(c["slots"]), "labor_slots %d" % int(c["total"]))
			"assign":
				var want: Variant = c["out"]
				ok(Lab.assign_blocker(c["node"], c["levels"]) == (want if want != null else ""), "assign_blocker")
			"est":
				var n := G.node_def(c["node"])
				ok(Lab.labor_actions(n, c["elapsed"]) == int(c["actions"]), "labor_actions")
				eq(Lab.estimate(n, int(c["level"]), c["elapsed"]), c["est"], "estimate")
			"roll":
				ok(Lab.hash_seed(c["parts"]) == int(c["seed"]), "hash_seed %s" % str(c["parts"]))
				var r: Object = Lab.claim_rng(int(c["seed"]))
				eq(Lab.roll_labor(G.node_def(c["node"]), c["start"], c["elapsed"], r.as_callable()), c["out"], "roll_labor %s" % c["node"])


func _test_garden() -> void:
	for c in fx("garden"):
		match c["k"]:
			"grow":
				ok(Gar.grow_ms(Gar.seed_def(c["seed"]), c["composted"]) == int(c["ms"]), "grow_ms %s" % c["seed"])
			"state":
				ok(Gar.state_of(c["row"], int(c["now"])) == c["out"], "state_of %d" % int(c["i"]))
			"plant":
				var rows := _garden_rows(int(c["now"]))
				var want: Variant = c["out"]
				ok(Gar.plant_blocker(Gar.plot_def(c["plot"]), c["seedId"], int(c["level"]), rows[int(c["ri"])], int(c["now"])) == (want if want != null else ""), "plant_blocker %s %s" % [c["plot"], c["seedId"]])
			"harvest":
				var rng := Rng.new(c["rseed"])
				eq(Gar.roll_harvest(Gar.seed_def(c["seed"]), rng.as_callable()), c["out"], "roll_harvest %s" % c["seed"])
			"text":
				ok(Gar.remaining_text(c["ms"]) == c["out"], "remaining_text %s" % str(c["ms"]))


func _garden_rows(now: int) -> Array:
	return [null, {"plot": "h0", "seedId": null, "plantedAt": 0, "readyAt": 0, "composted": false}, {"plot": "h0", "seedId": "seed_mourning_moss", "plantedAt": now - 1000, "readyAt": now + 5000, "composted": false}, {"plot": "h0", "seedId": "seed_mourning_moss", "plantedAt": now - 9000, "readyAt": now - 1, "composted": true}, {"plot": "h0", "seedId": "seed_mourning_moss", "plantedAt": now - 9000, "readyAt": now, "composted": true}]


func _test_contracts() -> void:
	var f: Dictionary = fx("contracts")
	for c in f["boards"]:
		var board := Con.generate_board(int(c["characterId"]), c["day"], c["levels"])
		eq(board, c["board"], "generate_board %s %s" % [str(c["characterId"]), c["day"]])
		eq(Con.bonus_for(board), c["bonus"], "bonus_for")
	for c in f["cands"]:
		eq(Con.candidates_for(c["levels"]), c["out"], "candidates_for %s" % str(c["levels"]))
	for c in f["infos"]:
		eq(Con.order_info(c["id"]), c["out"] if c["out"] != null else {}, "order_info %s" % c["id"])
	for c in f["days"]:
		ok(Con.day_key(int(c["ms"])) == c["day"], "day_key %s" % str(c["ms"]))
		ok(Con.next_reset_ms(int(c["ms"])) == int(c["next"]), "next_reset_ms %s" % str(c["ms"]))
	for c in f["streaks"]:
		ok(Con.streak_of(c["done"], c["today"]) == int(c["out"]), "streak_of %s" % str(c["done"]))


func _test_salvage() -> void:
	var f: Dictionary = fx("salvage")
	for c in f["cases"]:
		var rng := Rng.new(c["seed"])
		eq(Sal.yield_for(c["item"], c["level"], rng.as_callable()), c["out"], "salvage_yield %s" % str(c["item"]))
		eq(Sal.preview(c["item"]), c["preview"], "salvage_preview %s" % str(c["item"]))
	for c in f["merges"]:
		eq(Sal.merge_grants(c["lists"]), c["out"], "merge_grants")
	var ids: Array = Sal.item_ids()
	ids.sort()
	var want: Array = (f["ids"] as Array).duplicate()
	want.sort()
	eq(ids, want, "salvage item ids")
	for c in f["gear"]:
		ok(Sal.is_salvage_gear(c["t"]) == c["gear"] and Sal.is_salvage_rune(c["t"]) == c["rune"] and Sal.is_salvageable(c["t"]) == c["any"], "salvage type predicates %s" % c["t"])


func _test_gold_sink() -> void:
	var f: Dictionary = fx("gold_sink")
	var ranges: Dictionary = f["ranges"]
	var ar := func(id: String, ilvl: Variant) -> Variant: return ranges.get("%s|%d" % [id, int(ilvl)], null)
	for c in f["costs"]:
		ok(GS.reforge_cost(c["ilvl"], c["rar"], int(c["aff"]), c["rr"]) == int(c["out"]), "reforge_cost %s" % str(c))
	for c in f["problems"]:
		var idx: int = int(c["index"]) if float(c["index"]) == floorf(float(c["index"])) else -1
		var want: Variant = c["out"]
		ok(GS.reforge_problem(c["inst"], idx, ar) == (want if want != null else ""), "reforge_problem %s" % str(c))
	for c in f["values"]:
		var rng := Rng.new(c["seed"])
		ok(GS.reforge_value(c["id"], int(c["ilvl"]), rng.as_callable(), ar) == int(c["out"]), "reforge_value %s" % str(c))
	for c in f["empower"]:
		ok(GS.empower_gold(int(c["shards"])) == int(c["gold"]) and GS.can_empower(c["boss"]) == c["can"], "empower %s" % c["boss"])
	for c in f["levels"]:
		ok(GS.empowered_level(int(c["l"])) == int(c["out"]), "empowered_level %d" % int(c["l"]))
	for c in f["can"]:
		ok(GS.can_empower(c["b"]) == c["out"], "can_empower %s" % c["b"])
	eq(GS.EMPOWER, f["EMPOWER"], "EMPOWER consts")
	ok(GS.COVENANT_SEAL == f["seal"], "seal id")


func _test_recipes() -> void:
	var f: Dictionary = fx("recipes")
	var all := Rec.all()
	ok(all.size() == int(f["count"]), "recipe count %d vs %d" % [all.size(), int(f["count"])])
	var ids: Array = []
	for r in all:
		ids.append(r["id"])
	eq(ids, f["ids"], "recipe ids/order")
	eq(all[0], f["row0"], "recipe row0")
	eq(all[all.size() - 1], f["last"], "recipe last")
	for s in f["bySkill"]:
		var got: Array = []
		for r in Rec.for_skill(s):
			got.append(r["id"])
		eq(got, f["bySkill"][s], "for_skill %s" % s)
	for c in f["qtys"]:
		var raw: Variant = c["raw"]
		if raw is String and raw == "__undef":
			raw = null
		elif raw is String and raw == "__nan":
			raw = NAN
		elif raw is String and raw == "__inf":
			raw = INF
		ok(Rec.clamp_craft_qty(raw) == int(c["out"]), "clamp_craft_qty %s" % str(c["raw"]))
	for c in f["qty2"]:
		ok(Rec.clamp_craft_qty(c["raw"], int(c["max"])) == int(c["out"]), "clamp_craft_qty max %s" % str(c))
	for c in f["craft"]:
		if c.has("k"):
			var counts: Dictionary = c["counts"]
			var cnt := func(id: String) -> int: return int(counts.get(id, 0))
			ok(Rec.has_skill_and_materials(c["rec"], int(c["skill"]), cnt) == c["out"], "has_skill_and_materials %s" % c["rec"]["id"])
		else:
			var space: Dictionary = c["space"]
			var stack_of := func(id: String) -> int: return int(space.get(id, 1000000000000))
			ok(Rec.max_craftable(c["rec"], c["slots"], int(c["bagSize"]), stack_of, int(c["cap"])) == int(c["out"]), "max_craftable %s" % c["rec"]["id"])


func _test_bag() -> void:
	for c in fx("bag_add"):
		var got: Variant = Bag.add_to_slots(c["slots"], c["drop"])
		eq(got, c["out"], "add_to_slots %s" % str(c["drop"]))
	for c in fx("bag_sort"):
		var moves: Dictionary = {}
		var locked: Variant = c["locked"]
		var lk := Callable()
		if locked != null:
			var set_: Dictionary = {}
			for s in locked:
				set_[int(s)] = true
			lk = func(s: Dictionary) -> bool: return set_.has(int(s["slot_index"]))
		var got := Bag.sort_bag_slots(c["slots"], moves, lk)
		eq(got, c["out"], "sort_bag_slots")
		var mv: Dictionary = {}
		for p in c["moves"]:
			mv[int(p[0])] = int(p[1])
		var mine: Dictionary = {}
		for k in moves:
			mine[int(k)] = int(moves[k])
		ok(mine == mv, "sort_bag moves %s vs %s" % [str(mine), str(mv)])
	# rolled-instance drops: instance fields land on the slot, then the injected decorate hook (loot track's decorateSlot) runs
	var decorated: Variant = Bag.add_to_slots([], {"item_id": "helm_gold", "quantity": 1, "instance": {"id": 9, "ilvl": 12, "affixes": [{"id": "a", "v": 1}]}}, func(s: Dictionary) -> Dictionary:
		s["decorated"] = true
		return s)
	ok(decorated != null and decorated[0]["instance_id"] == 9 and decorated[0]["ilvl"] == 12 and decorated[0]["decorated"] and decorated[0]["slot_index"] == 0, "add_to_slots instance + decorate hook")


class FakeStorage:
	extends RefCounted
	var v: Variant = null
	func get_item(_k: String) -> Variant:
		return v
	func set_item(_k: String, val: String) -> void:
		v = val


func _necro(a: Dictionary) -> bool:
	return str(a["id"]).begins_with("necro_")


func _test_locks() -> void:
	var f: Dictionary = fx("locks")
	for c in f["cases"]:
		var st := FakeStorage.new()
		st.v = JSON.stringify(c["locked"])
		var locks := Locks.new(3, st)
		var is_l: Array = []
		for s in c["slots"]:
			is_l.append(locks.is_locked(s))
		eq(is_l, c["isLocked"], "is_locked")
		eq(locks.slots_of(c["slots"]), c["slotsOf"], "slots_of")
		var keep := Callable()
		if c["keep"] != null:
			var ks: Dictionary = {}
			for k in c["keep"]:
				ks[int(k)] = true
			keep = func(s: Dictionary) -> bool: return ks.has(int(s["slot_index"]))
		var j: Array = []
		for s in Locks.junk_slots(c["slots"], locks, keep, _necro):
			j.append(int(s["slot_index"]))
		eq(j, c["junk"], "junk_slots")
		var sv: Array = []
		for s in Locks.salvage_below_rare(c["slots"], locks, keep, _necro):
			sv.append(int(s["slot_index"]))
		eq(sv, c["salvage"], "salvage_below_rare")
	for c in f["ops"]:
		var st := FakeStorage.new()
		var locks := Locks.new(7, st)
		for step in c["steps"]:
			match step["kind"]:
				"toggle":
					ok(locks.toggle({"slot_index": int(step["slot"]), "item_id": step["item_id"]}) == step["out"], "toggle")
				"remap":
					var mv: Dictionary = {}
					for p in step["moves"]:
						mv[int(p[0])] = int(p[1])
					locks.remap(mv)
				"prune":
					var arr: Array = []
					for p in step["slots"]:
						arr.append({"slot_index": int(p[0]), "item_id": p[1]})
					locks.prune(arr)
				"state":
					ok(JSON.parse_string(locks.to_json()) is Array, "to_json parses")
					ok(_norm_json(locks.to_json()) == _norm_json(step["stored"]) or (step["stored"] == "" and locks.to_json() == "[]"), "stored json %s vs %s" % [locks.to_json(), step["stored"]])
	ok(Locks.locks_storage_key(3) == f["key"][0], "storage key")


func _norm_json(s: String) -> String:
	if s == "":
		return "[]"
	var p: Variant = JSON.parse_string(s)
	return JSON.stringify(p) if p != null else ""


func _info_from(table: Dictionary) -> Callable:
	return func(id: String) -> Dictionary:
		if table.has(id):
			return table[id]
		return {"maxStack": 1, "itemType": "material", "rarity": "common"}


func _test_vault() -> void:
	var f: Dictionary = fx("vault")
	var info := _info_from(f["infoTable"])
	ok(Vault.VAULT_SLOTS == int(f["consts"]["VAULT_SLOTS"]) and Vault.VAULT_TAB_SIZE == int(f["consts"]["VAULT_TAB_SIZE"]), "vault consts")
	for c in f["moves"]:
		var got: Variant
		match c["mode"]:
			"deposit", "withdraw":
				var q: Variant = c["qty"]
				if q is String and q == "__nan":
					q = NAN
				got = Vault.deposit_stack(c["bag"], c["vault"], int(c["slot"]), q, info) if c["mode"] == "deposit" else Vault.withdraw_stack(c["bag"], c["vault"], int(c["slot"]), q, info)
			"many_m":
				got = Vault.deposit_many(c["bag"], c["vault"], "materials", c["except"], info)
			"many_a":
				got = Vault.deposit_many(c["bag"], c["vault"], "all", c["except"], info)
			"sort":
				got = Vault.sort_vault(c["vault"], info)
			"grants":
				got = Vault.add_grants(c["bag"], c["grants"], info)
		eq(got, c["out"], "vault %s" % c["mode"])


func _test_potion_belt() -> void:
	for c in fx("potion_belt"):
		if c["k"] == "pick":
			var counts: Dictionary = c["counts"]
			var cnt := func(id: String) -> int: return int(counts.get(id, 0))
			var want: Variant = c["out"]
			ok(Belt.heal_pick(cnt) == (want if want != null else ""), "heal_pick")
		else:
			ok(Belt.belt_state(c["hasItem"], c["active"], c["cooling"]) == c["out"], "belt_state")


func _test_stable_sort() -> void:
	var arr: Array = []
	for i in 200:
		arr.append({"k": i % 7, "i": i})
	var s := Stable.sorted(arr, func(a: Dictionary, b: Dictionary) -> bool: return a["k"] < b["k"])
	var bad := 0
	for i in range(1, s.size()):
		if s[i - 1]["k"] > s[i]["k"] or (s[i - 1]["k"] == s[i]["k"] and s[i - 1]["i"] > s[i]["i"]):
			bad += 1
	ok(bad == 0, "stable sort order violations %d" % bad)
