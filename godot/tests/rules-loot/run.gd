extends SceneTree
## Golden-fixture runner for godot/rules/loot.
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/rules-loot/run.gd
## Fixtures: committed golden files, generated from the retired web game (the generators were removed 2026-10-09).

const DIR := "res://tests/rules-loot/fixtures/"
var _rng_script: Script
var passed := 0
var failed := 0
var per_file: Dictionary = {}
var _shown := 0

func _initialize() -> void:
	_rng_script = load("res://rules/core/rng.gd") if ResourceLoader.exists("res://rules/core/rng.gd") else load("res://tests/rules-loot/rng_shim.gd")
	print("rng: ", _rng_script.resource_path)
	for t in ["wave_modifiers", "affix_defs", "affix_ranges", "affix_text", "item_level", "affix_count", "affix_roll_instance", "affix_problem", "affix_misc",
			"can_roll", "decorate_slot", "smart_table", "is_profession_material", "settle_combat_drop", "roll_item", "roll_kill", "roll_reagents",
			"roll_elite_rune", "roll_surge_item", "roll_boss_rune", "roll_boss", "roll_first_kill", "legendary", "add_to_slots", "sort_bag",
			"loot_action", "read_loot_rules", "depths", "loot_roller", "kill_loot_const"]:
		call("t_" + t)
	var total := passed + failed
	print("--- rules-loot: %d / %d passed, %d failed ---" % [passed, total, failed])
	for k in per_file:
		print("  %-26s %s" % [k, per_file[k]])
	quit(0 if failed == 0 else 1)

func load_json(name: String) -> Variant:
	var f := FileAccess.open(DIR + name + ".json", FileAccess.READ)
	assert(f != null, name)
	return JSON.parse_string(f.get_as_text())

func rng(seed_: Variant) -> Callable:
	var r = _rng_script.new(int(seed_))
	return func(): return r.next()  # the lambda keeps the RefCounted generator alive

func eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		var x := float(a)
		var y := float(b)
		return absf(x - y) <= 1e-9 or absf(x - y) <= 1e-12 * maxf(absf(x), absf(y))
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not eq(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not eq(a[k], b[k]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b

func check(file: String, got: Variant, want: Variant, ctx: Variant = null) -> void:
	var ok := eq(got, want)
	if ok:
		passed += 1
	else:
		failed += 1
		if _shown < 12:
			_shown += 1
			print("FAIL [%s]\n  ctx : %s\n  got : %s\n  want: %s" % [file, str(ctx).left(600), str(got).left(900), str(want).left(900)])
	var p: Array = per_file.get(file, [0, 0])
	p[0 if ok else 1] += 1
	per_file[file] = p

func unflag(v: Variant) -> String:
	return "" if v == null else str(v)

func owned_fn(owned: Variant) -> Callable:
	if owned == null:
		return Callable()
	var set := {}
	for id in owned:
		set[id] = true
	return func(): return set

func t_kill_loot_const() -> void:
	check("kill_loot_const", DmLoot.KILL_LOOT, load_json("kill_loot_const"))

func t_wave_modifiers() -> void:
	for c in load_json("wave_modifiers"):
		check("wave_modifiers", DmLoot.wave_mods(c["tier"]), {"rewardMult": c["rewardMult"], "xpMult": c["xpMult"], "itemChanceMult": c["itemChanceMult"]}, c)

func t_affix_defs() -> void:
	var defs: Array = load_json("affix_defs")
	check("affix_defs", DmAffixRules.AFFIXES.size(), defs.size())
	for i in defs.size():
		var d: Dictionary = DmAffixRules.AFFIXES[i]
		check("affix_defs", {"id": d["id"], "kind": d["kind"], "word": d["word"], "group": d["group"], "necro": d["necro"], "weight": d["weight"], "unit": d["unit"]}, defs[i], defs[i]["id"])

func t_affix_ranges() -> void:
	for c in load_json("affix_ranges"):
		var r: Variant = DmAffixRules.affix_range(c["id"], c["ilvl"])
		var ac: Variant = DmAffixRules.affix_accept_range(c["id"], c["ilvl"])
		check("affix_ranges", [r, ac], [c["range"], c["accept"]], c)

func t_affix_text() -> void:
	for c in load_json("affix_text"):
		var a: Dictionary = c["a"]
		var q: Array = []
		for il in [1, 20, 60, 99]:
			q.append(DmAffixRules.affix_quality(a, il))
		check("affix_text", {"text": DmAffixRules.affix_text(a), "necro": DmAffixRules.affix_is_necro(a), "kind": DmAffixRules.affix_kind(a), "word": DmAffixRules.affix_word(a), "effect": DmAffixRules.affix_effect(a), "q": q},
			{"text": c["text"], "necro": c["necro"], "kind": c["kind"], "word": c["word"], "effect": c["effect"], "q": c["q"]}, c)

func t_item_level() -> void:
	for c in load_json("item_level"):
		if c.has("source"):
			check("item_level", DmAffixRules.item_level_for(c["level"], c["source"]), c["ilvl"], c)
		else:
			check("item_level", DmAffixRules.clamp_drop_level(c["level"], c["characterLevel"]), c["clamp"], c)

func t_affix_count() -> void:
	for c in load_json("affix_count"):
		var r := rng(c["seed"])
		check("affix_count", [DmAffixRules.roll_affix_count(c["rarity"], c["source"], r), r.call()], [c["count"], c["after"]], c)

func t_affix_roll_instance() -> void:
	for c in load_json("affix_roll_instance"):
		var r := rng(c["seed"])
		check("affix_roll_instance", [DmAffixRules.roll_instance(c["rarity"], c["level"], c["source"], r), r.call()], [c["inst"], c["after"]], c)

func t_affix_problem() -> void:
	for c in load_json("affix_problem"):
		check("affix_problem", DmAffixRules.instance_problem(c["inst"], c["itemType"]), unflag(c["problem"]), c)
		if c["clean"] != null:
			check("affix_problem", DmAffixRules.clean_instance(c["inst"]), c["clean"], c)

func t_affix_misc() -> void:
	for c in load_json("affix_misc"):
		if c.has("nEff"):
			check("affix_misc", [DmAffixRules.effective_rarity(c["br"], int(c["nEff"])), DmAffixRules.instance_sell_value(5, null), DmAffixRules.instance_power(null)], [c["eff"], c["sellValue"], c["power"]], c)
		else:
			var inst: Dictionary = c["inst"]
			var totals := DmAffixRules.add_instance_totals(DmAffixRules.empty_totals(), inst["affixes"])
			check("affix_misc", {"name": DmAffixRules.affixed_name(c["base"], inst["affixes"]), "eff": DmAffixRules.effective_rarity(c["br"], inst["affixes"].size()), "sv": DmAffixRules.instance_sell_value(c["sell"], inst), "p": DmAffixRules.instance_power(inst), "t": totals},
				{"name": c["name"], "eff": c["eff"], "sv": c["sellValue"], "p": c["power"], "t": c["totals"]}, c)

func t_can_roll() -> void:
	for c in load_json("can_roll"):
		check("can_roll", DmAffixes.can_roll(c["id"]), c["can"], c)

func t_decorate_slot() -> void:
	for c in load_json("decorate_slot"):
		var dec := DmAffixes.decorate_slot(c["row"])
		var idem := DmAffixes.decorate_slot(dec)
		check("decorate_slot", {"dec": dec, "idem": eq(idem, dec), "lines": DmAffixes.affix_lines(dec), "roll": DmAffixes.roll_of(dec), "title": DmAffixes.roll_title_lines(dec)},
			{"dec": c["dec"], "idem": c["idem"], "lines": c["lines"], "roll": c["roll"], "title": c["title"]}, c["row"])

func t_smart_table() -> void:
	for c in load_json("smart_table"):
		check("smart_table", DmSmartLoot.smart_table(c["area"], c["disc"]), c["table"], [c["area"], c["disc"]])

func t_is_profession_material() -> void:
	for c in load_json("is_profession_material"):
		check("is_profession_material", DmLoot.is_profession_material(c["id"]), c["v"], c)

func t_settle_combat_drop() -> void:
	for c in load_json("settle_combat_drop"):
		check("settle_combat_drop", DmLoot.settle_combat_drop(c["drop"], c["keepGems"]), c["res"], c)

func t_roll_item() -> void:
	for c in load_json("roll_item"):
		var r := rng(c["seed"])
		check("roll_item", [DmLoot.roll_item(c["area"], r, int(c["mq"]), unflag(c["disc"])), r.call()], [c["drop"], c["after"]], c)

func t_roll_kill() -> void:
	for c in load_json("roll_kill"):
		var ra := rng(c["seeds"][0])
		var rb := rng(c["seeds"][1])
		var rc := rng(c["seeds"][2])
		var res := DmLoot.roll_kill(c["def"], c["area"], c["level"], c["elite"], c["tier"], ra, c["diff"], c["icm"], rb, rc, unflag(c["disc"]), owned_fn(c["owned"]))
		check("roll_kill", [res, ra.call(), rb.call(), rc.call()], [c["res"]] + c["after"], c)

func t_roll_reagents() -> void:
	for c in load_json("roll_reagents"):
		var r := rng(c["seed"])
		check("roll_reagents", [DmLoot.roll_reagents(c["def"], c["area"], c["elite"], c["icm"], r), r.call()], [c["res"], c["after"]], c)

func t_roll_elite_rune() -> void:
	for c in load_json("roll_elite_rune"):
		var r := rng(c["seed"])
		check("roll_elite_rune", [DmLoot.roll_elite_rune(c["area"], c["icm"], r), r.call()], [c["res"], c["after"]], c)

func t_roll_surge_item() -> void:
	for c in load_json("roll_surge_item"):
		var r := rng(c["seed"])
		check("roll_surge_item", [DmLoot.roll_surge_item(c["area"], r, unflag(c["disc"])), r.call()], [c["res"], c["after"]], c)

func t_roll_boss_rune() -> void:
	for c in load_json("roll_boss_rune"):
		var r := rng(c["seed"])
		check("roll_boss_rune", [DmLoot.roll_boss_rune(c["boss"], c["first"], r), r.call()], [c["res"], c["after"]], c)

func t_roll_boss() -> void:
	for c in load_json("roll_boss"):
		var r := rng(c["seed"])
		var res := DmLoot.roll_boss(c["tier"], r, c["diff"], c["area"], c["cost"], unflag(c["boss"]), unflag(c["disc"]), owned_fn(c["owned"]))
		check("roll_boss", [res, r.call()], [c["res"], c["after"]], c)

func t_roll_first_kill() -> void:
	for c in load_json("roll_first_kill"):
		var r := rng(c["seed"])
		check("roll_first_kill", [DmLoot.roll_first_kill_item(c["area"], r, unflag(c["disc"])), r.call()], [c["res"], c["after"]], c)

func t_legendary() -> void:
	for c in load_json("legendary_chance"):
		check("legendary", [DmLegendarySets.boss_chance(c["area"]), DmLegendarySets.elite_chance(c["area"])], [c["boss"], c["elite"]], c)
	for c in load_json("legendary_set_for"):
		check("legendary", DmLegendarySets.set_for(c["d"]), unflag(c["set"]), c)
	for c in load_json("legendary_pick"):
		var owned: Variant = c["owned"]
		var set := {}
		if owned != null:
			for id in owned:
				set[id] = true
		var got_set := DmLegendarySets.pick_set(c["disc"], rng(c["seed"]))
		var got_item := DmLegendarySets.pick_item(c["disc"], rng(c["seed"]), set if owned != null else null)
		var r := rng(c["seed"])
		var got_roll := DmLegendarySets.roll(c["disc"], c["chance"], r, owned_fn(owned))
		check("legendary", [got_set, got_item, got_roll, r.call()], [c["set"], c["item"], unflag(c["roll"]), c["after"]], c)

func t_add_to_slots() -> void:
	for c in load_json("add_to_slots"):
		var before: String = JSON.stringify(c["slots"])
		var res: Variant = DmLoot.add_to_slots(c["slots"], c["drop"])
		check("add_to_slots", res, c["res"], c["drop"])
		check("add_to_slots", JSON.stringify(c["slots"]), before, "input mutated")

func t_sort_bag() -> void:
	for c in load_json("sort_bag"):
		var locked := {}
		for l in c["locked"]:
			locked[int(l)] = true
		var moves := {}
		var res := DmLoot.sort_bag_slots(c["slots"], moves, func(s): return locked.has(int(s["slot_index"])))
		var want_moves := {}
		for m in c["moves"]:
			want_moves[int(m[0])] = int(m[1])
		var moves0 := {}
		var res0 := DmLoot.sort_bag_slots(c["slots"], moves0)
		var want0 := {}
		for m in c["moves0"]:
			want0[int(m[0])] = int(m[1])
		check("sort_bag", [res, moves, res0, moves0, DmLoot.to_save_payload(res)], [c["res"], want_moves, c["res0"], want0, c["payload"]], c["locked"])

func t_loot_action() -> void:
	for c in load_json("loot_action"):
		var keep := c["keep"] as bool
		check("loot_action", [DmLootFilter.loot_action(c["row"], c["rules"], (func(_s): return true) if keep else Callable()), DmLootFilter.loot_action(c["row"], c["rules"])], [c["action"], c["actionNoKeepFn"]], c)

func t_read_loot_rules() -> void:
	for c in load_json("read_loot_rules"):
		check("read_loot_rules", DmLootFilter.read_loot_rules(c["saved"], c["legacy"]), c["rules"], c)
	for c in load_json("actions_for"):
		check("read_loot_rules", DmLootFilter.actions_for(c["t"]), c["a"], c)

func t_depths() -> void:
	for c in load_json("depths_bonus"):
		check("depths", {"area": DmDepthsRewards.depth_loot_area(c["depth"]), "floor": DmDepthsRewards.floor_bonus(c["depth"], c["level"]), "chest": DmDepthsRewards.chest_bonus(c["depth"], c["level"]), "avg": DmDepthsRewards.average_kill(c["depth"], c["level"]),
			"drops": DmDepthsRewards.chest_drops(c["depth"]), "rc": DmDepthsRewards.chest_rune_chance(c["depth"]), "pool": DmDepthsRewards.chest_rune_pool(c["depth"])},
			{"area": c["area"], "floor": c["floor"], "chest": c["chest"], "avg": c["avg"], "drops": c["drops"], "rc": c["runeChance"], "pool": c["runePool"]}, c)
	for c in load_json("depths_roster"):
		check("depths", DmDepthsRewards.depth_roster(c["d"]), c["roster"], c["d"])
	for c in load_json("depths_floor_clear"):
		var r := rng(c["seed"])
		check("depths", [DmDepthsRewards.roll_floor_clear(c["depth"], c["level"], r, unflag(c["disc"])), r.call()], [c["res"], c["after"]], c)
	for c in load_json("depths_gear_drop"):
		var r := rng(c["seed"])
		check("depths", [DmDepthsRewards.roll_gear_drop(c["depth"], r, unflag(c["disc"])), r.call()], [c["res"], c["after"]], c)
	for c in load_json("depths_chest"):
		var r := rng(c["seed"])
		check("depths", [DmDepthsRewards.roll_chest(c["depth"], c["level"], r, unflag(c["disc"])), r.call()], [c["res"], c["after"]], c)

func t_loot_roller() -> void:
	for c in load_json("loot_roller"):
		var drops: Array = c["drops"]
		var reqs: Array = []
		var bs := DmLootRoll.batches(drops)
		for i in bs.size():
			reqs.append({"cid": 77, "req": DmLootRoll.request(bs[i], c["level"], c["source"])})
			var ans: Variant = c["answers"][i]
			if ans is Array:
				DmLootRoll.apply(bs[i], ans)
		check("loot_roller", [reqs, drops], [c["requests"], c["result"]], c["mode"])
