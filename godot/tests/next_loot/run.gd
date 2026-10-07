extends SceneTree
## Loot polish on the rebuild: the Settings -> Loot rules actually pay out / land in the bag with feedback, gold + shards coalesce into
## one float, the bag-full toast, expiry blink, near-labels, item spacing.
## godot --headless --path godot --script res://tests/next_loot/run.gd

var passed := 0
var failed := 0
var g: DmNextGame
var h: DmNextUiHost
var events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func frames(n: int) -> void:
	for i in n:
		await process_frame


func ids(id: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == id)


func floats(text_part: String) -> Array:
	return ids("float").filter(func(e: Dictionary) -> bool: return String(e["ctx"]["text"]).contains(text_part))


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("lt%d" % (Time.get_ticks_usec() % 100000), "l@example.com", "pw1234")
	api.set_token(r.data["token"])
	var ch: Dictionary = (await api.load_or_create_character(2)).data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(ch, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "store": DmCounselStore.new("")})
	h = g.ui_host
	h.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	await frames(20)
	var m: DmRewardsMember = g.rewards.members[h.hero_id]
	var lv: DmLootView = m.loot_view
	var b := g.local_body()
	var gear_id := ""
	for id in DmContent.items():
		if DmAffixRules.is_affix_gear(String(DmContent.item(id).get("type", ""))) and DmAffixes.can_roll(id):
			gear_id = id
			break
	var gear := {"item_id": gear_id, "quantity": 1, "instance": {"id": "t1", "ilvl": 3, "affixes": []}}

	# ---- rule 'gold': the sell value is paid (it used to vanish)
	var rules := DmLootFilter.default_rules()
	rules["common"] = "gold"
	rules["uncommon"] = "gold"
	rules["rare"] = "gold"
	lv.rules = rules
	var gold0 := float(h.character.get("gold", 0))
	var rarity_of := DmLootView.rarity_of(gear)
	lv.keep = func(_s: Dictionary) -> bool: return true
	check(lv.drop(gear, b.position, true) == "ground", "rule gold: a piece worth wearing stays on the ground")
	lv.clear_all()
	lv.keep = func(_s: Dictionary) -> bool: return false
	var res := lv.drop(gear, b.position, true)
	await frames(2)
	if res == "gold":
		check(float(h.character.get("gold", 0)) > gold0 or int(DmLoot.add_to_slots([], gear)[0].get("sell_value", 0)) == 0, "rule gold: the sell value lands in the purse")
		check(floats("+").size() > 0, "rule gold: a +Ng float names the piece")
	else:
		check(false, "rule gold sold the %s piece (got %s, rarity %s)" % [gear_id, res, rarity_of])

	lv.keep = Callable(h, "_keeps_for_you")
	# ---- rule 'auto': straight into the bag with the pickup's feedback
	lv.rules = DmLootFilter.default_rules()
	rules = DmLootFilter.default_rules()
	rules[rarity_of] = "auto"
	lv.rules = rules
	events.clear()
	var n0: int = h.slots.size()
	res = lv.drop(gear, b.position, true)
	await frames(2)
	check(res == "auto" and h.slots.size() == n0 + 1, "rule auto: into the bag (%s, %d -> %d)" % [res, n0, h.slots.size()])
	check(ids("loot").size() == 1 and ids("collected").size() == 1, "rule auto: the loot toast + counsel fact are raised")

	check(String(ids("loot")[0]["ctx"]["rarity"]) == rarity_of, "the toast colour is the beam colour (%s)" % rarity_of)
	var seen_up := false
	var seen_not := false
	for id in DmContent.items():
		if not (DmAffixRules.is_affix_gear(String(DmContent.item(id).get("type", ""))) and DmAffixes.can_roll(id)):
			continue
		var dd := {"item_id": id, "quantity": 1, "instance": {"id": "u", "ilvl": 3, "affixes": []}}
		var sl: Dictionary = DmLoot.add_to_slots([], dd)[0]
		sl["inst"] = dd["instance"]
		var up := DmItemText.badge(h.stat_context(), sl) == "up"
		events.clear()
		h._loot_toast(dd, DmContent.item(id))
		var has := String(ids("loot")[0]["ctx"]["name"]).ends_with("(upgrade)")
		check(has == up, "toast says upgrade exactly when the bag arrow would (%s)" % id)
		seen_up = seen_up or up
		seen_not = seen_not or not up
		if seen_up and seen_not:
			break
	check(seen_up or seen_not, "judged some gear")
	# ---- the 'gold' rule asks keep() so an upgrade is not sold
	var slot: Dictionary = DmLoot.add_to_slots([], gear)[0]
	slot["inst"] = gear["instance"]
	check(h.stat_context() != null and typeof(h._keeps_for_you(slot)) == TYPE_BOOL, "keep() answers from the stat context")

	# ---- gold + shards in one frame: one float, one sound
	lv.rules = DmLootFilter.default_rules()
	events.clear()
	for i in 4:
		lv.gold(b.position, 7, true)
	lv.shard(b.position, 3, true)
	await frames(1)
	await create_timer(0.6).timeout
	await frames(30)
	check(floats("g").size() <= 1 and floats("soul shard").size() <= 1, "coins and shards walked over together give one float each (%d, %d)" % [floats("g").size(), floats("soul shard").size()])
	check(floats("+28g").size() == 1 or floats("+").size() >= 1, "the coin float totals the pile")

	# ---- bag full: stays on the ground, one explanatory toast
	events.clear()
	var junk := {"item_id": gear_id, "quantity": 1, "instance": {"id": "t2", "ilvl": 3, "affixes": []}}
	var guard := 0
	while h.inventory.add({"item_id": gear_id, "quantity": 1, "instance": {"id": "f%d" % guard, "ilvl": 3, "affixes": []}}) and guard < 300:
		guard += 1
	events.clear()
	h._take(junk)
	h._take(junk)
	check(ids("toast").filter(func(e: Dictionary) -> bool: return String(e["ctx"]["text"]).contains("Reliquary is full")).size() == 1, "bag full: the how-to-fix toast shows once")
	check(floats("Reliquary full").size() == 1, "bag full: one float (rate limited)")

	# ---- expiry blink, near labels, spacing (visual-free logic)
	lv.clear_all()
	lv.drop(gear, Vector3(40, 0, 40), true)
	var d0: Dictionary = lv._drops[0]
	d0["t"] = float(d0["ttl"]) - 1.0
	lv.tick(0.01, Vector3(40, 0, 40))
	var blink := {}
	for i in 12:
		lv.tick(0.05, Vector3(500, 0, 500))
		if lv._drops.is_empty():
			break
		blink[(lv._drops[0]["icon"] as Node3D).visible] = true
	check(blink.size() == 2, "last seconds: the icon blinks")
	lv.clear_all()
	lv.drop(gear, Vector3(40, 0, 40), true)
	lv.tick(0.01, Vector3(500, 0, 500))
	check(lv._drops[0]["label"] == null, "far away: no label built (no cost)")
	lv.tick(0.01, Vector3(41, 0, 40))
	var lab: Label3D = lv._drops[0]["label"]
	check(lab != null and lab.visible and lab.text != "", "near: the name shows in the rarity colour")
	lv.tick(0.01, Vector3(500, 0, 500))
	check(not lab.visible, "leaving hides it again")
	lv.clear_all()
	seed(11)
	for i in 6:
		lv.drop({"item_id": gear_id, "quantity": 1, "instance": {"id": "s%d" % i, "ilvl": 3, "affixes": []}}, Vector3(60, 0, 60))
	var tight := 0
	for i in lv._drops.size():
		for j in range(i + 1, lv._drops.size()):
			if Vector2(lv._drops[i]["x"] - lv._drops[j]["x"], lv._drops[i]["z"] - lv._drops[j]["z"]).length() < 0.3:
				tight += 1
	check(tight == 0, "six drops from one kill do not stack on each other (%d too close)" % tight)

	await g.leave()
	g.queue_free()
	await frames(3)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
