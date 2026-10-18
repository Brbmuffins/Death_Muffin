extends SceneTree
## Loot on the rebuilt client (rework 2026-10-12; the loot node DmNextLoot holds what today's DmNextUiHost did): click to pick up (walking over takes nothing), runes into the bag with a chat line / shards when
## known, the legendary chat line, gold + shards coalesce into one float, the bag-full toast, expiry blink, near-labels, item spacing.
## godot --headless --path client --script res://tests/next_loot/run.gd

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
	await g.start(ch, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": true, "store": DmCounselStore.new("")})
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
	await DmTestBag.give(h.inventory, piece)
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
	g.loot._on_claim(shared[0])   # what reaching it does
	check(await until(func() -> bool: return h.inventory.slots.size() == n_bag, 4.0), "drop: picked back up through the server")
	check(lv._drops.filter(func(d: Dictionary) -> bool: return d.has("drop_id")).is_empty(), "drop: off the ground")
	events.clear()


	# ---- server-decided drops (DECISIONS B20): kills roll from the tape at once, every drop carries its claim, and the pickup is the server's roll
	check(m.tape != null, "tape: the local member has a drop tape")
	check(await until(func() -> bool: return m.tape.ready_for("elite"), 4.0), "tape: seeds are dealt")
	var before: int = lv._drops.size()
	var tries := 0
	while lv._drops.size() == before and tries < 200:
		tries += 1
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": true, "x": b.position.x + 0.5, "z": b.position.z, "killer": b})
		await physics_frame
	var fresh: Array = lv._drops.filter(func(d: Dictionary) -> bool: return (d["item"] as Dictionary).has("claim"))
	check(not fresh.is_empty(), "tape: an elite kill dropped something from the tape at once (%d kills)" % tries)
	if not fresh.is_empty():
		var td: Dictionary = fresh[0]
		var claim: Dictionary = td["item"]["claim"]
		check(String(claim["expect"]) == String(td["item"]["item_id"]) and claim.has("facts") and int(claim["n"]) >= 0, "tape: the drop names its event and index")
		if DmAffixes.can_roll(String(td["item"]["item_id"])):
			check(td["item"].has("instance"), "tape: gear shows its roll on the ground before it is picked up")
		var want := String(td["item"]["item_id"])
		var had := h.inventory.count(want)
		g.loot._on_claim(td)
		check(await until(func() -> bool: return h.inventory.count(want) > had, 4.0), "tape: the pickup put the server's roll (%s) in the bag" % want)
		check(not lv._drops.any(func(d: Dictionary) -> bool: return is_same(d, td)), "tape: off the ground once the server handed it over")
		var again: DmResult = await h.api.drops_claim(h.hero_id, claim)
		check(not again.ok and again.error.contains("already picked up"), "tape: the same drop cannot be claimed twice (%s)" % again.error)
		check(again.data is Dictionary and again.data.get("success") == false, "tape: a refused claim keeps the server's whole reply")
	# a refusal over budget sends the tape back to the server's position (a burst the server did not believe, e.g. GM-summoned bosses)
	var kk: Dictionary = m.tape.kinds["kill"]
	var at_from := int(kk["from"])
	kk["next"] = at_from + 20
	m.tape.rewind("kill", at_from + 3)
	check(int(m.tape.kinds["kill"]["next"]) == at_from + 3, "tape: rewound within the dealt seeds")
	m.tape.rewind("boss", -5)
	check(not m.tape.kinds.has("boss") or int(m.tape.kinds["boss"]["next"]) >= 0, "tape: rewound out of range = fetched again from the server")
	for d in lv._drops.duplicate():
		lv.take_claimed(d)
	await until(func() -> bool: return false, 1.6)   # the kills' gold float (GOT_WINDOW_S) lands before the next checks
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
	check(g.loot.loot_click(at), "a click on the drop's icon starts a pickup")
	check(await until(func() -> bool: return h.slots.size() == n0 + 1, 4.0), "the hero reaches it and it goes into the bag (%d -> %d)" % [n0, h.slots.size()])
	check(lv.count() == 0 and ids("loot").size() == 1 and ids("collected").size() == 1, "the pickup raises the loot toast + counsel fact")
	check(not g.loot.loot_click(at), "nothing left to click there")
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
		g.loot._loot_toast(dd, DmContent.item(id))
		var has := String(ids("loot")[0]["ctx"]["name"]).ends_with("(upgrade)")
		check(has == up, "toast says upgrade exactly when the bag arrow would (%s)" % id)
		seen_up = seen_up or up
		seen_not = seen_not or not up
		if seen_up and seen_not:
			break
	check(seen_up or seen_not, "judged some gear")
	# ---- runes: a new one goes into the bag with a chat line; one the character has (bag, Vault, learned) does not drop
	events.clear()
	var vault_rune := "rune_marrow_tap"
	g.loot.note_vault({"vault": [{"item_id": vault_rune, "quantity": 1, "slot_index": 0}]})
	n0 = h.slots.size()
	check(lv.drop({"item_id": "rune_splinter", "quantity": 1}, b.position, true) == "auto" and h.slots.size() == n0 + 1, "a new rune goes straight into the bag")
	var chat := ids("chat")
	check(chat.size() == 1 and String(chat[0]["ctx"]["text"]).begins_with("You found the Rune of Splinters"), "a chat line names it %s" % [chat])
	check(ids("loot").size() == 1, "and the loot toast")
	check(lv.drop({"item_id": "rune_splinter", "quantity": 1}, b.position, true) == "owned", "owned in the bag: nothing drops")
	check(lv.drop({"item_id": vault_rune, "quantity": 1}, b.position, true) == "owned", "owned in the Vault: nothing drops")
	g.loot.learned_runes["rune_requiem"] = true
	check(lv.drop({"item_id": "rune_requiem", "quantity": 1}, b.position, true) == "owned", "learned: nothing drops")
	g.loot.learned_runes.clear()
	check(ids("chat").size() == 1 and ids("loot").size() == 1, "a rune that does not drop says nothing")
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
	await create_timer(DmNextLoot.GOT_WINDOW_S + 0.3).timeout
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
	g.loot._take(junk)
	g.loot._take(junk)
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
	print("%s next_loot %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)
