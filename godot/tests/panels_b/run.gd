extends SceneTree
## Headless panel tests (data -> displayed rows / buttons / enabled state):  godot --headless --path godot --script res://tests/panels_b/run.gd

const NOW := 1790000000000   # = DmPbMock.NOW

var _fail := 0
var _pass := 0
var _root: Control


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _eq(a: Variant, b: Variant, what: String) -> void:
	var same: bool = (typeof(a) == typeof(b) and a == b) or ((a is int or a is float) and (b is int or b is float) and is_equal_approx(float(a), float(b)))
	if same:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what, "  got ", a, "  want ", b)


func _frames(n: int = 2) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


## Every text on screen under `n` (labels, rich labels, button text), upper-cased buttons lowered for matching.
func _texts(n: Node) -> Array[String]:
	var out: Array[String] = []
	for c in n.find_children("*", "", true, false):
		if c is Label:
			out.append((c as Label).text)
		elif c is RichTextLabel:
			out.append((c as RichTextLabel).get_parsed_text())
		elif c is Button:
			out.append((c as Button).text)
	return out


func _has(n: Node, needle: String) -> bool:
	for t in _texts(n):
		if t.to_lower().contains(needle.to_lower()):
			return true
	return false


func _mount(p: Control) -> void:
	_root.add_child(p)


func _run() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(_root)
	await _frames(2)
	await _t_helpers()
	await _t_contracts()
	await _t_garden()
	await _t_labor()
	await _t_professions()
	await _t_forge()
	await _t_reforge()
	await _t_gather_report()
	await _t_shelf()
	await _t_salvage()
	await _t_vault()
	await _t_acre()
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# --- helpers ------------------------------------------------------------------------------------------------------
func _t_helpers() -> void:
	_eq(DmPb.duration_text(45), "45s", "duration seconds")
	_eq(DmPb.duration_text(125), "2m 5s", "duration minutes")
	_eq(DmPb.duration_text(5025), "1h 23m", "duration hours")
	_eq(DmPb.num(1234567), "1,234,567", "num commas")
	_eq(DmPb.item_name("ore_copper"), "Copper Ore", "item name from data")
	_eq(DmGardenPanel.use_compost(true, 0), false, "use_compost needs meal")
	_eq(DmGardenPanel.use_compost(true, 2), true, "use_compost ticked + meal")
	_eq(DmGardenPanel.use_compost(false, 2), false, "use_compost unticked")
	# brewOfTheDay vectors generated from the real TS (content/wing.ts)
	for v: Array in [["2026-10-04", "brew_cinderskin", "elixir_cinderskin"], ["2026-10-05", "brew_wraithquick", "elixir_wraithquick"], ["2026-10-06", "brew_grave_dust_tonic", "tonic_grave_dust"], ["2026-01-01", "brew_insight", "tonic_insight"], ["2027-03-15", "brew_insight", "tonic_insight"]]:
		var d := DmForgePanel.brew_of_the_day(v[0])
		_check(d["recipeId"] == v[1] and d["brewId"] == v[2], "brew of the day %s" % v[0])


# --- contracts ----------------------------------------------------------------------------------------------------
func _t_contracts() -> void:
	_check(not DmContractsPanel.board_expired("2026-10-05T00:00:00.000Z", 1790000000000), "board not expired before reset")
	var reset := DmContractsPanel.parse_iso_ms("2026-10-05T00:00:00.000Z")
	_eq(reset, 1791158400000, "iso parse (2026-10-05T00:00Z)")
	_check(DmContractsPanel.board_expired("2026-10-05T00:00:00.000Z", reset), "expired at the reset instant")
	_check(not DmContractsPanel.board_expired("garbage", reset), "unparseable resetsAt never expires")

	var p := DmContractsPanel.new()
	p.now_override_ms = reset - (3 * 3600000 + 25 * 60000)
	_mount(p)
	var sigs := []
	p.deliver_requested.connect(func(s: int) -> void: sigs.append(s))
	p.set_board(DmPbMock.contracts_board())
	p.set_counts({"log_oak": 20, "ingot_iron": 1, "herb_nightshade": 9999})
	await _frames()
	_eq(p.rows.size(), 3, "three contracts drawn")
	_eq(p.reset_text(), "3h 25m", "reset countdown")
	_check(_has(p, "in 3h 25m"), "countdown shown in the note")
	_eq(p.rows[0]["title"], "Easy · 12× Oak Log", "easy order title")
	_eq(p.rows[0]["pct"], 100, "have 20/12 caps at 100%")
	_eq(p.rows[0]["progress"], "12 / 12 in your bag", "progress capped to qty")
	_eq(p.rows[0]["reward"], "140g", "reward gold only")
	_check(p.rows[0]["deliver_enabled"], "deliver enabled when ready")
	_eq(p.rows[1]["title"], "Steady · 4× Iron Ingot", "steady order")
	_eq(p.rows[1]["pct"], 25, "1/4 = 25%")
	_check(not p.rows[1]["deliver_enabled"], "deliver disabled when short")
	_eq(p.rows[1]["reward"], "520g + 3× Moss Tonic", "reward with item stack")
	_eq(p.rows[2]["title"], "Hard · 1,500× Nightshade", "hard order, thousands separator")
	_eq(p.rows[2]["progress"], "Filled", "done order says Filled")
	_check(not p.rows[2]["deliver_enabled"], "done order cannot be delivered")
	_eq(p.deliver_buttons[2].text, "✓", "done order button is a tick")
	_eq(p.deliver_buttons[0].text, "DELIVER", "deliver label")
	_check(_has(p, "Bonus for all three: 900g + Bone Opal"), "bonus line")
	_check(_has(p, "Streak: 3 days"), "streak plural")
	p.deliver_buttons[0].pressed.emit()
	_eq(sigs, [0], "deliver signal carries the slot")
	p.set_busy(true)
	await _frames()
	_check(not p.deliver_buttons[0].disabled == false, "busy disables deliver")
	p.set_busy(false)
	var b2 := DmPbMock.contracts_board()
	b2["bonus"]["claimed"] = true
	b2["streak"] = 1
	p.set_board(b2)
	_check(_has(p, "(claimed today)") and _has(p, "Streak: 1 day") and not _has(p, "1 days"), "claimed bonus + singular streak")
	var refresh := []
	p.refresh_requested.connect(func() -> void: refresh.append(1))
	p.now_override_ms = reset + 1000
	p.tick()
	_eq(refresh.size(), 1, "expired board asks for a refresh on the tick")
	p.set_board({})
	p.set_error("The Sexton refuses.")
	await _frames()
	_check(_has(p, "The Sexton refuses."), "error shown while there is no board")
	p.queue_free()


# --- garden -------------------------------------------------------------------------------------------------------
func _t_garden() -> void:
	var p := DmGardenPanel.new()
	p.now_override_ms = NOW
	_mount(p)
	var plants := []
	var harvests := []
	p.plant_requested.connect(func(plot: String, sd: String, comp: bool) -> void: plants.append([plot, sd, comp]))
	p.harvest_requested.connect(func(plot: String) -> void: harvests.append(plot))
	p.set_bag(DmPbMock.bag())
	p.set_view(DmPbMock.garden_view(NOW))
	await _frames()
	_eq(p.plots_info.size(), 6, "six plots")
	_eq(p.plots_info[0]["state"], "empty", "h0 empty")
	_eq(p.plots_info[1]["state"], "growing", "h1 growing")
	_eq(p.plots_info[2]["state"], "ready", "h2 ready by readyAt (snapshot says growing)")
	_check(p.plots_info[0]["plant_enabled"], "can plant a level-1 seed")
	_eq(p.plots_info[0]["text"], "Grows in 20m.", "grow time for the picked seed")
	_check(_has(p, "Grave Gardening 12"), "head note level")
	_eq(p.plots_info[1]["pct"], 50, "half grown")
	_check(_has(p, "10m left"), "remaining text")
	_check(_has(p, "bone meal"), "composted marker on the growing plot")
	_check(p.harvest_buttons["h2"].disabled == false and p.harvest_buttons["h1"].disabled, "only the ready plot can be harvested")
	_eq(p.plots_info[4]["state"], "empty", "tree patch empty")
	_check(p.plots_info[4]["plant_enabled"], "sapling in the bag is plantable")
	_check(p.plots_info[3]["plant_enabled"], "second herb bed plantable")
	# the seed list: level-15 nightshade is locked at level 12
	var ob: OptionButton = p.seed_pickers["h0"]
	_eq(ob.item_count, 2, "two herb seeds in the bag")
	_eq(ob.get_item_text(0), "Mourning Moss Seed ×5", "first seed option")
	_check(ob.get_item_text(1).ends_with("(Lv 15)"), "locked seed shows its level")
	ob.select(1)
	ob.item_selected.emit(1)
	await _frames(3)
	_check(_has(p, "Requires Grave Gardening 15."), "level requirement text")
	_check(p.plant_buttons["h0"].disabled, "plant disabled below the seed level")
	# compost: checkbox exists (4 meal) and gates the compost flag
	var cb: CheckBox = p.compost_checks["h0"]
	_eq(cb.text, "Bone meal (4)", "bone meal checkbox with count")
	ob = p.seed_pickers["h0"]
	ob.select(0)
	ob.item_selected.emit(0)
	await _frames(3)
	cb = p.compost_checks["h0"]
	cb.button_pressed = true
	await _frames(3)
	_eq(p.plots_info[0]["text"], "Grows in 15m.", "bone meal grows a quarter faster")
	p.plant_buttons["h0"].pressed.emit()
	_eq(plants, [["h0", "seed_mourning_moss", true]], "plant signal: plot, seed, compost")
	p.harvest_buttons["h2"].pressed.emit()
	_eq(harvests, ["h2"], "harvest signal")
	# compost ticked but the meal is gone -> not used
	p.set_bag(DmPbMock.bag().filter(func(s: Dictionary) -> bool: return s["item_id"] != "bone_meal"))
	await _frames(3)
	_check(not p.compost_checks.has("h0"), "no checkbox without meal")
	plants.clear()
	p.plant_buttons["h0"].pressed.emit()
	_eq(plants[0][2], false, "ticked compost is not sent once the meal is gone")
	# no seeds at all
	p.set_bag([])
	await _frames(3)
	_check(_has(p, "No seeds. Dig graves") and _has(p, "No saplings."), "empty-bag hints for herb and tree plots")
	p.set_busy(true)
	p.set_bag(DmPbMock.bag())
	await _frames(3)
	_check(p.plant_buttons["h0"].disabled and p.harvest_buttons["h2"].disabled, "busy disables plant and harvest")
	p.queue_free()


# --- labor --------------------------------------------------------------------------------------------------------
func _t_labor() -> void:
	var p := DmLaborPanel.new()
	p.now_override_ms = NOW
	_mount(p)
	var ev := []
	p.assign_requested.connect(func(s: int, n: String) -> void: ev.append(["assign", s, n]))
	p.recall_requested.connect(func(s: int) -> void: ev.append(["recall", s]))
	p.collect_requested.connect(func(s: int) -> void: ev.append(["collect", s]))
	p.set_levels(DmPbMock.levels())
	p.set_view(DmPbMock.labor_view(NOW))
	await _frames()
	_eq(p.slots_info.size(), 4, "four laborer slots")
	_eq(p.slots_info[0]["status"], "Working", "slot 1 working")
	_eq(p.slots_info[2]["status"], "Idle", "slot 3 idle")
	_eq(p.slots_info[3]["status"], "Locked", "slot 4 locked")
	_check(_has(p, "Gathering levels 112"), "head note")
	# 5 hours on iron seam: numbers from DmLabor
	var def := DmGatherData.node("seam_iron")
	var est := DmLabor.estimate(def, 31, 5.0 * 3600000.0)
	_check(p.slots_info[0]["text"].contains("about %s Iron Ore" % DmPb.num(est["items"])), "working estimate comes from DmLabor")
	_check(p.slots_info[0]["text"].begins_with("Iron Seam · 5h 0m"), "elapsed time")
	_eq(p.slots_info[0]["pct"], 63, "5h of 8h = 63%")
	_check(p.slots_info[0]["collect_enabled"] and p.slots_info[0]["recall_enabled"], "ready laborer: collect + recall")
	_check(not p.slots_info[1]["collect_enabled"], "2 s in: nothing to collect yet")
	_check(p.slots_info[1]["recall_enabled"], "recall always available while working")
	_eq(p.slots_info[3]["text"], "Raised when your gathering levels total 150 (now 112).", "locked slot text")
	var per := DmLabor.estimate(DmGatherData.node(p.picks[2]), int(DmPbMock.levels()[DmGatherData.node(p.picks[2])["skill"]]), 3600000.0)
	_check(p.slots_info[2]["text"].begins_with("About %s " % DmPb.num(per["items"])) and p.slots_info[2]["text"].ends_with("up to 8 hours."), "idle estimate per hour")
	_check(p.slots_info[2]["send_enabled"], "can send an idle laborer")
	p.collect_buttons[0].pressed.emit()
	p.recall_buttons[1].pressed.emit()
	p.send_buttons[2].pressed.emit()
	_eq(ev[0], ["collect", 0], "collect signal")
	_eq(ev[1], ["recall", 1], "recall signal")
	_eq(ev[2][0], "assign", "assign signal")
	_eq(ev[2][1], 2, "assign signal slot")
	# the picker offers only posts the levels allow, grouped by skill
	var ob: OptionButton = p.post_pickers[2]
	var posts := DmLabor.posts_for(DmPbMock.levels())
	var picks := 0
	for i in ob.item_count:
		if not ob.is_item_separator(i):
			picks += 1
	_eq(picks, posts.size(), "picker lists every allowed post")
	# loot
	for i in 14:
		p.add_loot(i % 3, {"items": [{"itemId": "ore_iron", "name": "Iron Ore", "qty": 10 + i, "rarity": "common"}], "totalItems": 10 + i, "gold": 0, "skills": [{"name": "Mining", "xp": 50, "fromLevel": 30, "toLevel": 31}], "milestones": [], "records": []})
	_eq(p.loot.size(), 12, "loot list capped at 12")
	await _frames()
	_check(_has(p, "Brought home") and _has(p, "(Lv 30 → 31)"), "loot section with level-up")
	_eq(p.loot[0]["report"]["totalItems"], 23, "newest first")
	p.clear_button.pressed.emit()
	_eq(p.loot.size(), 0, "clear empties the loot list")
	p.set_busy(true)
	await _frames()
	_check(not p.slots_info[0]["collect_enabled"] and not p.slots_info[0]["recall_enabled"] and not p.slots_info[2]["send_enabled"], "busy disables labor actions")
	p.queue_free()


# --- professions --------------------------------------------------------------------------------------------------
func _t_professions() -> void:
	var p := DmProfessionsPanel.new()
	_mount(p)
	var starts := []
	var pauses := []
	p.start_afk_requested.connect(func(n: String) -> void: starts.append(n))
	p.pause_afk_requested.connect(func() -> void: pauses.append(1))
	p.set_skills(DmPbMock.skills())
	p.set_tools(["tool_pickaxe_iron", "tool_hatchet_copper"], ["tool_hatchet_copper"])
	p.set_afk({"active": false, "text": "Idle", "allowed": true})
	await _frames()
	_eq(p.cards.size(), 7, "seven skill cards")
	var by := {}
	for c: Dictionary in p.cards:
		by[c["id"]] = c
	_eq(by["woodcutting"]["level"], 22, "woodcutting level")
	_eq(by["woodcutting"]["pct"], 40, "xp bar percent")
	_check(by["woodcutting"]["unlock"].begins_with("Level ") and by["woodcutting"]["unlock"].contains(": "), "next node unlock line")
	var nxt := ""
	for n: Dictionary in DmGathering.nodes_for_skill("woodcutting"):
		if int(n["level"]) > 22:
			nxt = "Level %d: %s" % [int(n["level"]), n["name"]]
			break
	_eq(by["woodcutting"]["unlock"], nxt, "unlock = first node above the level")
	_eq(by["gravedigging"]["unlock"], "Mastered.", "level 99 is mastered")
	_eq(by["gravedigging"]["xp_text"], "Level cap", "cap xp text")
	_eq(by["gardening"]["unlock"], "Plant in the ledger’s Garden tab (U).", "gardening unlock")
	_eq(by["mining"]["tool"], "Tool: Iron Pickaxe · +10% success · in bag", "tool line for the best held tool in the bag")
	_eq(by["woodcutting"]["tool"], "Tool: Copper Hatchet · +5% success · on belt", "tool on belt")
	_eq(by["fishing"]["tool"], "No tool: forge one at the Bone Kiln for +5% or more.", "no tool")
	_eq(by["alchemy"]["tool"], "", "no tool line for non-gather skills")
	_check(_has(p, "Total level 205"), "total level")
	_eq(by["mining"]["nodes"].size(), DmGathering.nodes_for_skill("mining").filter(func(n: Dictionary) -> bool: return int(n["level"]) <= 31).size(), "node picker only lists nodes you can work")
	_check(by["alchemy"]["nodes"].is_empty() and not p.start_buttons.has("alchemy"), "no AFK picker for alchemy")
	_check(p.start_buttons["mining"].disabled == false, "start enabled when allowed")
	_eq(p.afk_label.text, "Idle", "afk status idle")
	p.node_pickers["mining"].select(1)
	p.node_pickers["mining"].item_selected.emit(1)
	p.start_buttons["mining"].pressed.emit()
	_eq(starts, ["seam_tin"], "start signal carries the chosen node id")
	_check(p.pause_button.disabled, "pause disabled while idle")
	p.set_afk({"active": true, "text": "Mining Iron Seam", "allowed": false})
	await _frames()
	_eq(p.afk_label.text, "AFK · Mining Iron Seam · Visit the Sexton’s Acre to start.", "active status + not allowed suffix")
	_check(not p.pause_button.disabled and p.start_buttons["mining"].disabled, "pause enabled; start disabled outside the Acre")
	p.pause_button.pressed.emit()
	_eq(pauses.size(), 1, "pause signal")
	p.set_busy(true)
	_eq(p.status_text().begins_with("Starting…"), true, "busy status")
	p.queue_free()


# --- forge --------------------------------------------------------------------------------------------------------
func _t_forge() -> void:
	var f := DmForgePanel.new()
	f.setup("", true)
	f.day_key_override = "2026-10-05"
	_mount(f)
	var req := []
	var crafts := []
	var only := []
	f.recipes_requested.connect(func(pr: String) -> void: req.append(pr))
	f.craft_requested.connect(func(id: String, n: int) -> void: crafts.append([id, n]))
	f.only_craftable_changed.connect(func(on: bool) -> void: only.append(on))
	f.open()
	await _frames(3)
	_eq(f.tabs_ids, ["mining", "tools", "fishing", "woodcutting", "gravedigging", "alchemy", "reforge"], "workbench tabs incl. reforge")
	_eq(req, ["mining"], "opening asks for the first rite's recipes")
	_eq(f.empty_text, "Loading recipes…", "loading line before recipes arrive")
	var all_mining := DmRecipes.for_skill("mining")
	f.set_recipes("mining", all_mining)
	f.set_professions([{"profession_id": "mining", "skill_level": 3, "skill_xp": 10}])
	f.set_bag(DmPbMock.bag())
	await _frames(2)
	_check(f.rows.size() > 0, "smelting recipes listed")
	_check(f.rows.all(func(r: Dictionary) -> bool: return not r["id"].begins_with("smith_")), "tools are not on the smelting tab")
	var by := {}
	for r: Dictionary in f.rows:
		by[r["id"]] = r
	var cu: Dictionary = by["smelt_copper_ingot"]
	_eq(cu["req"], "Mining 1", "requirement label")
	_check(cu["skill_ok"], "skill met")
	_eq(cu["max"], 4, "14 copper ore / 3 = 4 craftable")
	_eq(cu["craft_text"], "Craft ×1", "default quantity 1")
	_check(cu["craft_enabled"] and cu["step_enabled"], "craft enabled")
	_eq(cu["ingredients"][0], {"text": "3× Copper Ore (14)", "ok": true}, "ingredient with bag count")
	var hi: Dictionary = {}
	for r: Dictionary in f.rows:
		if not r["skill_ok"]:
			hi = r
			break
	_check(not hi.is_empty() and hi["max"] == 0 and not hi["craft_enabled"], "recipe above your skill is disabled")
	_check(not hi["req"].is_empty(), "requirement shown")
	# Max / ×5 / quantity
	f.max_buttons["smelt_copper_ingot"].pressed.emit()
	await _frames(3)
	_eq(f.qty["smelt_copper_ingot"], 4, "Max sets the craftable maximum")
	_eq(f.craft_buttons["smelt_copper_ingot"].text, "CRAFT ×4", "craft label follows the quantity")
	f.craft_buttons["smelt_copper_ingot"].pressed.emit()
	_eq(crafts, [["smelt_copper_ingot", 4]], "craft signal: recipe + quantity")
	f.qty_inputs["smelt_copper_ingot"].text = "99"
	f.qty_inputs["smelt_copper_ingot"].text_changed.emit("99")
	_eq(f.qty["smelt_copper_ingot"], 4, "typed quantity clamps to what is makeable")
	f.qty_inputs["smelt_copper_ingot"].text = "abc"
	f.qty_inputs["smelt_copper_ingot"].text_changed.emit("abc")
	_eq(f.qty["smelt_copper_ingot"], 1, "junk quantity becomes 1")
	# only craftable
	var before: int = f.rows.size()
	f.set_only_craftable(true, true)
	await _frames(2)
	_eq(only, [true], "only-craftable signal")
	_check(f.rows.size() < before and f.rows.size() > 0, "filter hides recipes you cannot make")
	_check(f.rows.all(func(r: Dictionary) -> bool: return r["skill_ok"] and r["max"] >= 1), "every remaining recipe is makeable")
	f.set_bag([])
	await _frames(2)
	_eq(f.empty_text, "Nothing here is craftable right now. Untick \"Only show craftable\" to see every recipe.", "nothing craftable message")
	f.set_only_craftable(false)
	f.set_bag(DmPbMock.bag())
	# busy
	f.set_busy(true, "smelt_copper_ingot", "Crafting 2/4…")
	await _frames(2)
	_eq(f.craft_buttons["smelt_copper_ingot"].text, "CRAFTING 2/4…", "busy recipe shows progress")
	_check(f.craft_buttons["smelt_copper_ingot"].disabled and f.craft_buttons["smelt_copper_ingot"].disabled, "busy disables craft")
	f.set_busy(false)
	f.set_error("You need more copper.")
	await _frames(2)
	_check(_has(f, "You need more copper."), "server error shown verbatim")
	# tools tab
	f.select_tab("tools")
	_eq(req.back(), "mining", "tools tab loads the mining recipes")
	f.set_recipes("tools", all_mining)
	await _frames(2)
	_check(f.rows.size() > 0 and f.rows.all(func(r: Dictionary) -> bool: return r["id"].begins_with("smith_")), "tools tab holds only smith_ recipes")
	# alchemy hint on the Workbench
	f.select_tab("alchemy")
	f.set_recipes("alchemy", DmRecipes.for_skill("alchemy"))
	await _frames(2)
	_check(f.hint_text.begins_with("Brewing is easier in the Alchemist's Wing"), "workbench alchemy hint")
	f.select_tab("reforge")
	_eq(f.reforge != null, true, "reforge tab built")
	f.queue_free()

	# stations
	var c := DmForgePanel.new()
	c.setup("cauldron")
	c.day_key_override = "2026-10-05"
	_mount(c)
	c.open()
	await _frames(3)
	_eq(c.title, "The Great Cauldron", "cauldron title")
	_eq(c.tabs_ids, ["alchemy"], "cauldron has one tab")
	c.set_recipes("alchemy", DmRecipes.for_skill("alchemy"))
	await _frames(2)
	_eq(c.hint_text, "Brew of the day: Wraithquick Elixir (one extra on your first brew today)", "brew of the day hint")
	c.set_bonus_claimed(true)
	_check(c.hint_text.ends_with("(bonus claimed today)"), "bonus claimed hint")
	var botd := 0
	for r: Dictionary in c.rows:
		if r["botd"]:
			botd += 1
			_eq(r["id"], "brew_wraithquick", "the day's recipe is flagged")
	_eq(botd, 1, "exactly one recipe flagged brew of the day")
	c.queue_free()
	var k := DmForgePanel.new()
	k.setup("kiln")
	_mount(k)
	_eq(k.tabs_ids, ["mining", "tools", "gravedigging"], "kiln tabs")
	_eq(k.title, "Bone Kiln", "kiln title")
	k.queue_free()


func _t_reforge() -> void:
	var r := DmReforgeView.new()
	_mount(r)
	var ev := []
	r.reforge_requested.connect(func(s: int, a: int, c: int) -> void: ev.append([s, a, c]))
	r.set_gold(100000)
	r.set_pieces(DmPbMock.reforge_pieces())
	await _frames()
	_eq(r.shown["pieces"].size(), 3, "only rolled pieces with affixes")
	_eq(r.shown["pieces"][0]["name"], "Bone Amulet", "worn piece first")
	_check(r.shown["pieces"][0]["worn"], "worn flag")
	_eq(r.shown["pieces"][1]["name"], "Gravewarden's Blade", "then by item level")
	_check(_has(r, "Choose a piece on the left."), "prompt before picking")
	r.pick_buttons[100 + 12].pressed.emit()
	await _frames(3)
	_eq(r.shown["affixes"].size(), 2, "affix rows for the picked piece")
	var expect_cost := DmGoldSink.reforge_cost(22.0, "epic", 2, 0)
	_check(r.shown["affixes"][0]["button"] == "Reforge · %sg" % DmPb.num(expect_cost) or r.shown["affixes"][0]["button"] == "Maxed", "button shows the rules price")
	_check(_has(r, "range"), "range line shown")
	_check(r.shown["affixes"][1]["button"] == "Maxed" and not r.shown["affixes"][1]["enabled"], "a roll at the top of its range shows Maxed and is disabled")
	r.set_counts({112: 2})
	await _frames(2)
	var c2 := DmGoldSink.reforge_cost(22.0, "epic", 2, 2)
	_check(c2 > expect_cost, "each reforge costs more")
	_check(r.shown["affixes"][0]["button"] == "Reforge · %sg" % DmPb.num(c2) or r.shown["affixes"][0]["button"] == "Maxed", "price follows the reforge count")
	if r.ask_buttons[0].disabled:
		_check(true, "maxed roll cannot be reforged")
	else:
		r.ask_buttons[0].pressed.emit()
		await _frames(3)
		_check(r.shown["confirm_text"].begins_with("Re-roll ") and r.shown["confirm_text"].contains(DmPb.num(c2)), "confirm line with price")
		r.go_button.pressed.emit()
		_eq(ev, [[12, 0, c2]], "reforge signal: slot, affix index, expected cost")
		r.set_gold(10)
		await _frames(3)
		_check(r.go_button.disabled and r.shown["confirm_text"].contains("(you have 10)"), "cannot afford: confirm disabled and says so")
	r.queue_free()


# --- gather report ------------------------------------------------------------------------------------------------
func _t_gather_report() -> void:
	var g := DmGatherReportPanel.new()
	_mount(g)
	var evs := []
	g.open_bag_requested.connect(func() -> void: evs.append("bag"))
	g.show_report(DmPbMock.gather_report())
	await _frames()
	_eq(g.shown["finds"], "412", "finds")
	_eq(g.shown["worth"], "3,880g", "worth")
	_eq(g.shown["xp"], "2,500", "total skill xp")
	_eq(g.shown["note"], "Your bag filled up. Make room, then start AFK again.", "stop reason")
	_check(_has(g, "Worked for 1h 23m."), "duration")
	_eq(g.shown["best"], "◆◆ Best find: Copper Ring", "best find line with rarity mark")
	_eq(g.shown["wins"], ["★ 500 finds, lifetime", "★ Personal best: 412 finds in one session"], "milestones and records")
	_eq(g.shown["skill_rows"][0], "Woodcutting Lv 21 → 22 +2,410 xp", "level-up skill row")
	_eq(g.shown["skill_rows"][1], "Gravedigging Lv 41 +90 xp", "no level-up skill row")
	_eq(g.shown["item_rows"], ["Oak Log ×260", "Elm Log ×140", "Copper Ring ×1"], "items brought back")
	_eq(g.why_text("zzz"), "Work stopped.", "unknown reason fallback")
	g.open_bag_button.pressed.emit()
	_eq(evs, ["bag"], "open reliquary signal")
	var r2 := DmPbMock.gather_report()
	r2["best"] = null
	r2["milestones"] = []
	r2["records"] = []
	g.show_report(r2)
	_eq(g.shown["wins"].size(), 0, "no wins section content")
	_eq(g.shown["best"], "", "no best find")
	g.queue_free()


# --- reagent shelf ------------------------------------------------------------------------------------------------
func _t_shelf() -> void:
	var s := DmReagentShelfPanel.new()
	_mount(s)
	var saved := []
	s.found_changed.connect(func(ids: Array) -> void: saved.append(ids.duplicate()))
	s.set_found(["herb_nightshade"])
	s.set_held({"herb_mourning_moss": 9, "reagent_grave_dust": 22, "ore_copper": 5})
	await _frames()
	_eq(s.shown["total"], 19, "19 shelf reagents")
	_eq(s.shown["found_count"], 3, "found = recorded + held shelf items (copper ore is not a reagent)")
	_eq(s.shown["groups"].size(), 4, "four groups")
	_eq(s.shown["groups"][0]["title"], "Garden herbs", "first group")
	var moss: Dictionary = s.shown["groups"][0]["items"][0]
	_eq(moss["label"], "Mourning Moss", "found item shows its name")
	_eq(moss["count_text"], "×9", "found item shows the count")
	var ns: Dictionary = s.shown["groups"][0]["items"][1]
	_check(ns["found"] and ns["count"] == 0 and ns["count_text"] == "×0", "found earlier but not held: ×0")
	var lost: Dictionary = s.shown["groups"][0]["items"][2]
	_check(not lost["found"] and lost["label"] == "???" and lost["count_text"] == "", "unfound item is a ??? silhouette")
	_eq(saved.size(), 1, "found list persisted when it grew")
	_check(saved[0].has("herb_mourning_moss") and saved[0].has("reagent_grave_dust") and saved[0].has("herb_nightshade"), "persisted ids")
	s.set_held({"herb_mourning_moss": 9, "reagent_grave_dust": 22})
	_eq(saved.size(), 1, "no re-save when nothing new was found")
	_check(_has(s, "Found 3/19 reagents."), "found line")
	s.queue_free()


# --- salvage ------------------------------------------------------------------------------------------------------
func _t_salvage() -> void:
	var p := DmSalvagePanel.new()
	_mount(p)
	var locks := DmItemLocks.new(1)
	var bag := DmPbMock.salvage_bag()
	locks.toggle(bag[4])   # lock the Tattered Robe (slot 4)
	var evs := []
	p.salvage_requested.connect(func(slots: Array) -> void: evs.append(slots))
	p.set_locks(locks)
	p.set_skill({"level": 14, "xp": 120, "next": 700})
	p.set_bag(bag)
	await _frames()
	# worn amulet and the ore never appear; rune + gear sorted by rarity then slot
	_eq(p.rows.map(func(r: Dictionary) -> int: return r["slot"]), [1, 3, 2, 4, 5, 6, 0], "gear list sorted by rarity then slot; worn + non-gear excluded")
	var by := {}
	for r: Dictionary in p.rows:
		by[r["slot"]] = r
	_check(by[4]["locked"] and not by[4]["checkbox_enabled"], "locked piece is shown but not selectable")
	var pv := DmSalvage.preview({"id": "sword_bone", "item_type": "weapon", "rarity": "epic", "ilvl": 22, "affixes": 2})
	_check(by[0]["yield_line"].begins_with("2 Gold Ingot (+1 "), "epic weapon yields 2 gold ingots with an extra chance: " + by[0]["yield_line"])
	_eq(by[0]["yield_line"], "%s %s (+1 %d%%) · %s" % ["2", "Gold Ingot", DmMath.js_round(float(pv["extraChance"]) * 100.0), by[0]["yield_line"].split(" · ", true, 1)[1]], "yield line structure")
	_check(by[2]["yield_line"].contains("Willow Plank"), "staffs give planks")
	_check(by[5]["yield_line"].begins_with("one rune (of 3) · Grave Dust ×2-4"), "runes are ground one at a time into reagents only: " + by[5]["yield_line"])
	_check(_has(p, "Salvaging 14"), "head note")
	_check(_has(p, "Tick the gear to grind.") and p.go_button.disabled, "nothing chosen yet")
	# below rare: unlocked common+uncommon gear (not the locked robe, not rare/epic, not the rune)
	_eq(p.below_rare().map(func(s: Dictionary) -> int: return s["slot_index"]), [1, 2, 3], "salvage-below-rare list skips locked, rare+ and runes")
	_check(p.below_button.text.ends_with("(3)"), "below-rare count on the button")
	# pick two
	p.checks[0].button_pressed = true
	await _frames(3)
	p.checks[1].button_pressed = true
	await _frames(3)
	_eq(p.chosen.keys().size(), 2, "two chosen")
	_eq(p.footer["picked"], 2, "footer picked")
	var want_xp: int = DmSalvage.preview(DmSalvagePanel.item_of(bag[0]))["xp"] + DmSalvage.preview(DmSalvagePanel.item_of(bag[1]))["xp"]
	_eq(p.footer["xp"], want_xp, "xp preview is the sum of the rules' previews")
	_eq(p.footer["text"], "2 chosen · about %d Salvaging XP" % want_xp, "footer text")
	_check(p.footer["go_enabled"], "go enabled")
	p.go_button.pressed.emit()
	_eq(evs.size(), 1, "salvage signal")
	_check(evs[0].has(0) and evs[0].has(1) and evs[0].size() == 2, "salvage signal carries the chosen slots")
	p.below_button.pressed.emit()
	_eq(evs[1], [1, 2, 3], "below-rare button sends its list")
	# locking a chosen piece drops it from the selection
	locks.toggle(bag[0])
	p.set_locks(locks)
	await _frames(2)
	_check(not p.chosen.has(0) and p.chosen.has(1), "a piece locked after picking is dropped from the selection")
	# result
	p.set_result({"salvaged": [{"item_id": "a"}, {"item_id": "b"}], "gained": [{"item_id": "ingot_gold", "quantity": 4}, {"item_id": "reagent_grave_dust", "quantity": 3}], "xp": 45, "level": 15, "leveledUp": true})
	await _frames(2)
	_eq(p.footer["result"], "Ground 2 pieces for 4× Gold Ingot, 3× Grave Dust · +45 Salvaging XP · Salvaging level 15", "result line")
	_eq(p.chosen.size(), 0, "selection cleared after a result")
	p.set_busy(true)
	await _frames(2)
	_check(not p.footer["go_enabled"] and not p.footer["below_enabled"] and not p.rows[0]["checkbox_enabled"], "busy disables everything")
	p.set_busy(false)
	p.set_bag([DmPbMock.row(8, "ore_copper", 3)])
	await _frames(2)
	_check(_has(p, "You carry no gear to salvage. Worn gear never appears here."), "empty message")
	p.queue_free()


# --- vault --------------------------------------------------------------------------------------------------------
func _t_vault() -> void:
	var v := DmVaultPanel.new()
	_mount(v)
	var ev := []
	v.deposit_requested.connect(func(s: int) -> void: ev.append(["dep", s]))
	v.withdraw_requested.connect(func(s: int) -> void: ev.append(["wd", s]))
	v.deposit_all_requested.connect(func(k: String, ex: Array) -> void: ev.append(["depall", k, ex]))
	v.take_all_requested.connect(func(k: String, sl: Array) -> void: ev.append(["take", k, sl]))
	v.sort_requested.connect(func() -> void: ev.append("sort"))
	var locks := DmItemLocks.new(1)
	var st := DmPbMock.vault_state()
	locks.toggle(st["bag"][1])
	v.set_locks(locks)
	await _frames()
	_check(v.shown["loading"] and _has(v, "Opening the Vault…"), "loading until the state arrives")
	_check(v.deposit_all_button.disabled and v.sort_button.disabled and v.take_all_button.disabled, "actions disabled until loaded")
	v.set_state(st)
	await _frames(2)
	_eq(v.shown["bag_count"], 8, "bag count")
	_eq(v.shown["vault_total"], 120, "vault slots")
	_eq(v.shown["vault_count"], 8, "vault count")
	_eq(v.shown["tab_labels"], ["Tab 1  5/40", "Tab 2  2/40", "Tab 3  1/40"], "tab usage")
	_eq(v.shown["locked_hint"], "1 locked item stays put", "locked hint")
	_eq(v.bag_slots.size(), 48, "48 bag cells")
	_eq(v.vault_slots.size(), 40, "40 vault cells per tab")
	_check(v.bag_slots[0].is_filled() and not v.bag_slots[20].is_filled(), "filled vs empty cells")
	_check(v.bag_slots[1].data["locked"], "locked bag item flagged")
	_check(v.bag_slots[6].data["equipped"] == true, "equipped flag normalised")
	_eq(v.bag_slots[4].data["ilvl"], 22, "ilvl passed to the tooltip")
	v.bag_slots[0].pressed.emit(v.bag_slots[0])
	_eq(ev.back(), ["dep", 0], "click a bag item deposits its slot")
	v.bag_slots[6].pressed.emit(v.bag_slots[6])
	await _frames(2)
	_check(_has(v, "Equipped gear cannot be stored. Unequip it first."), "equipped gear refuses to be stored")
	_eq(ev.size(), 1, "no deposit signal for equipped gear")
	v.vault_slots[2].pressed.emit(v.vault_slots[2])
	_eq(ev.back(), ["wd", 2], "click a vault item withdraws its slot")
	v.deposit_materials_button.pressed.emit()
	_eq(ev.back(), ["depall", "materials", [1]], "deposit materials excludes locked slots")
	v.deposit_all_button.pressed.emit()
	_eq(ev.back(), ["depall", "all", [1]], "deposit all excludes locked slots")
	v.take_all_button.pressed.emit()
	_eq(ev.back(), ["take", "all", [0, 1, 2, 3, 5]], "take all lists the open tab's stacks")
	v.take_materials_button.pressed.emit()
	_eq(ev.back(), ["take", "materials", [0, 1, 2, 3]], "take materials skips gear")
	v.sort_button.pressed.emit()
	_eq(ev.back(), "sort", "sort signal")
	# tab 3 and a tab with no materials
	v.tab_buttons[2].pressed.emit()
	await _frames(3)
	_eq(v.tab, 2, "tab switched")
	_check(v.vault_slots.has(80) and v.vault_slots[80].is_filled(), "tab 3 shows slot 80")
	v.tab_buttons[1].pressed.emit()
	await _frames(3)
	v.take_materials_button.pressed.emit()
	_eq(ev.back(), ["take", "materials", [41, 42]], "tab 2 materials")
	v.set_state({"bag": [], "vault": []})
	v.select_tab(0)
	await _frames(2)
	v.take_all_button.pressed.emit()
	await _frames(2)
	_check(_has(v, "This tab is empty."), "empty tab message")
	v.set_busy(true)
	await _frames(2)
	_check(v.deposit_all_button.disabled and v.sort_button.disabled, "busy disables the bulk buttons")
	v.queue_free()


# --- acre ledger --------------------------------------------------------------------------------------------------
func _t_acre() -> void:
	var a := DmAcreLedger.new()
	_mount(a)
	_eq(a.active, "skills", "ledger opens on Skills")
	a.open_tab("labor")
	await _frames(3)
	_eq(a.active, "labor", "open a tab by id")
	_check(a.labor.visible and not a.skills.visible and not a.garden.visible, "only the active tab shows")
	var pressed := 0
	for k: String in a._tabs:
		if (a._tabs[k]["btn"] as Button).button_pressed:
			pressed += 1
	_eq(pressed, 1, "a programmatic tab select leaves exactly one tab pressed")
	a.queue_free()
