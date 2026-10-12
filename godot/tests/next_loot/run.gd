extends SceneTree
## Loot on the rebuild (rework 2026-10-12): click to pick up (walking over takes nothing), runes into the bag with a chat line / shards when
## known, the legendary chat line, gold + shards coalesce into one float, the bag-full toast, expiry blink, near-labels, item spacing.
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


func until(cond: Callable, secs: float) -> bool:
	var t := Time.get_ticks_msec() + int(secs * 1000.0)
	while Time.get_ticks_msec() < t:
		if cond.call():
			return true
		await physics_frame
	return bool(cond.call())


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

	# ---- Reliquary -> Drop (ground.cjs): the piece leaves the bag and lies at your feet; reaching it asks the server and it comes back
	var sid := g.party_session_id()
	check(sid != "", "drop: the solo game has a backend session")
	var rr: DmResult = await h.api.roll_loot(h.hero_id, [{"item_id": gear_id, "level": 5, "source": "kill"}], sid)
	var piece := {"item_id": gear_id, "quantity": 1, "instance": {"id": rr.data[0]["instance_id"], "ilvl": rr.data[0]["ilvl"], "affixes": rr.data[0]["affixes"]}}
	h.inventory.add(piece)
	var cerr: String = await h.bag_commit()
	check(cerr == "", "drop: the piece is saved in the bag (%s)" % cerr)
	var prow: Dictionary = {}
	for srow in h.inventory.slots:
		if str(srow.get("instance_id")) == str(piece["instance"]["id"]):
			prow = srow
	var acts: Array = g.ui.inv._extra_actions({"row": prow})
	check(acts.any(func(a: Dictionary) -> bool: return a["id"] == "drop"), "drop: the Reliquary offers Drop for gear")
	var n_bag: int = h.inventory.slots.size()
	check(await h.drop_gear(prow) == "", "drop: dropped")
	check(h.inventory.slots.size() == n_bag - 1, "drop: it left the bag")
	var shared: Array = lv._drops.filter(func(d: Dictionary) -> bool: return d.has("drop_id"))
	check(shared.size() == 1, "drop: it lies on the ground")
	h._on_claim(shared[0])   # what reaching it does
	check(await until(func() -> bool: return h.inventory.slots.size() == n_bag, 4.0), "drop: picked back up through the server")
	check(lv._drops.filter(func(d: Dictionary) -> bool: return d.has("drop_id")).is_empty(), "drop: off the ground")
	events.clear()


	var rarity_of := DmLootView.rarity_of(gear)
	# ---- items: walking over one takes nothing; a click walks the hero there and takes it with the pickup's feedback
	events.clear()
	var n0: int = h.slots.size()
	lv.drop(gear, b.position + Vector3(0.4, 0, 0), true)
	for i in 10:
		await physics_frame
	check(lv.count() == 1 and h.slots.size() == n0, "standing on a drop takes nothing")
	var at: Vector2 = g.camera.unproject_position(lv._drops[0]["node"].global_position + Vector3(0, 0.7, 0))
	check(h.loot_click(at), "a click on the drop's icon starts a pickup")
	check(await until(func() -> bool: return h.slots.size() == n0 + 1, 4.0), "the hero reaches it and it goes into the bag (%d -> %d)" % [n0, h.slots.size()])
	check(lv.count() == 0 and ids("loot").size() == 1 and ids("collected").size() == 1, "the pickup raises the loot toast + counsel fact")
	check(not h.loot_click(at), "nothing left to click there")
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
	# ---- runes: a new one goes into the bag with a chat line; a known one becomes one the player lacks; a complete pool pays shards
	events.clear()
	var vault_rune := "rune_marrow_tap"
	h.note_vault({"vault": [{"item_id": vault_rune, "quantity": 1, "slot_index": 0}]})
	n0 = h.slots.size()
	check(lv.drop({"item_id": "rune_splinter", "quantity": 1, "rune_pool": ["rune_splinter", vault_rune]}, b.position, true) == "auto" and h.slots.size() == n0 + 1, "a new rune goes straight into the bag")
	var chat := ids("chat")
	check(chat.size() == 1 and String(chat[0]["ctx"]["text"]).begins_with("You found the Rune of Splinters"), "a chat line names it %s" % [chat])
	check(ids("loot").size() == 1, "and the loot toast")
	check(lv.drop({"item_id": "rune_splinter", "quantity": 1, "rune_pool": ["rune_splinter", vault_rune]}, b.position, true) == "shards", "owned in the bag + the Vault: the pool is complete, shards instead")
	check(String(ids("chat")[-1]["ctx"]["text"]).begins_with("Known rune"), "a chat line says why")
	events.clear()
	lv.drop({"item_id": "leg_legion_unburied_head", "quantity": 1}, b.position + Vector3(8, 0, 0), true)
	check(ids("chat").size() == 1 and String(ids("chat")[0]["ctx"]["text"]).contains("(legendary)"), "a legendary landing is a chat line")
	lv.clear_all()

	# ---- gold + shards credited within the window: one float, one sound
	events.clear()
	for i in 4:
		lv.gold(b.position, 7, true)
	lv.shard(b.position, 3, true)
	await frames(1)
	lv.gold(b.position + Vector3(30, 0, 0), 5, true)   # far away: still credited at once
	await create_timer(DmNextUiHost.GOT_WINDOW_S + 0.3).timeout
	await frames(5)
	check(floats("g").size() == 1 and floats("soul shard").size() == 1, "coins and shards of one fight give one float each (%d, %d)" % [floats("g").size(), floats("soul shard").size()])
	check(floats("+33g").size() == 1, "the coin float totals the fight")

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
	check((lv._drops[0]["icon"] as Sprite3D).texture == DmUiArt.item(gear_id), "ground loot shows the item's inventory icon, not the placeholder tile")
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
