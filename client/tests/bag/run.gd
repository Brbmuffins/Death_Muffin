extends SceneTree
## The rebuild's bag (DmNextUiHost is the `game` DmUiInventory talks to; DECISIONS B25): the server writes the bag and the client only shows it.
## A shown-only item vanishes with the next server answer, sips are batched to POST /api/inventory/use and survive an earlier answer, sale and
## sort are server operations; a failing batch is toasted once and reported when it lands. Also: HUD size reaches the rebuild.
## godot --headless --path client --script res://tests/bag/run.gd

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func _run() -> void:
	var mock := DmOffline.make_mock("")
	mock.strict_slots = true
	var api := DmOffline.make_api(mock)
	var r := await api.register("nb%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start((await api.load_or_create_character(2)).data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": true, "store": DmCounselStore.new("")})
	var h := g.ui_host
	var toasts: Array = []
	h.game_event.connect(func(id: String, ctx: Dictionary) -> void:
		if id == "toast":
			toasts.append(String(ctx.get("text", ""))))
	check(not h.has_method("bag_remove") and h.has_method("bag_sort") and h.has_method("bag_commit") and h.has_method("sell_items"), "the rebuild's UI host offers the bag's server operations, and no local bag edit")
	var cid := int(g.character["id"])
	var mat := ""
	for id in DmContent.items():
		if String(DmContent.items()[id].get("type", "")) == "material":
			mat = String(id)
			break
	var flask := String(DmContent.healing_flasks().keys()[0])
	# The bag is the server's (DECISIONS B25): seed it on the mock, as a GM would, then load it. The slots are spread over the bag's size, which the data holds.
	var bag_size := DmLootData.bag_size()
	var slot_a := bag_size / 4
	var slot_b := bag_size / 2
	check((await api.save_inventory(cid, [{"slot_index": slot_a, "item_id": mat, "quantity": 5}, {"slot_index": slot_b, "item_id": mat, "quantity": 4},
		{"slot_index": bag_size - 1, "item_id": flask, "quantity": 3}], bag_size)).ok, "seed the bag")
	await h.refresh_inventory()
	var server := func(id: String) -> int:
		var n := 0
		for s in (await api.get_inventory(cid)).data:
			if s["item_id"] == id:
				n += int(s["quantity"])
		return n
	# A shown item the server never wrote is gone with the next server answer.
	h.inventory.add({"item_id": mat, "quantity": 7})
	check(h.inventory.count(mat) == 16, "an added item shows at once")
	await h.refresh_inventory()
	check(h.inventory.count(mat) == 9, "and is gone when the server answers: only the server writes the bag")
	# Drinking: the flask leaves the bag now, the server hears it in one batch, and a server answer that lands first keeps it gone.
	check(h.inventory.consume(flask) and h.inventory.consume(flask), "two sips")
	check(h.inventory.count(flask) == 1, "both leave the shown bag at once")
	h.inventory.replace((await api.get_inventory(cid)).data)
	check(h.inventory.count(flask) == 1, "a server answer before the batch keeps the queued sips applied")
	check((await h.bag_commit()) == "" and h.inventory.state == "saved", "the batch reaches the server")
	check(await server.call(flask) == 1 and h.inventory.count(flask) == 1, "the server spent the two flasks")
	# Selling is the server's: it takes the items and answers its bag.
	var row: Dictionary = h.slots.filter(func(s: Dictionary) -> bool: return s["item_id"] == mat and int(s["slot_index"]) == slot_a)[0]
	check((await h.sell_items([{"slot_index": int(row["slot_index"]), "quantity": 2}])).ok, "a partial sale")
	check(await server.call(mat) == 7 and h.inventory.count(mat) == 7, "the server took two")
	# Sorting is the server's: the two stacks merge, the moves come back for slot-keyed state, nothing is saved by the client.
	var moved := {}
	check((await h.bag_sort(func(m: Dictionary) -> void: moved.merge(m))) == "", "a sort")
	var mats: Array = h.slots.filter(func(s: Dictionary) -> bool: return s["item_id"] == mat)
	check(mats.size() == 1 and int(mats[0]["quantity"]) == 7 and moved.has(slot_a) and moved.has(slot_b) and int(moved[slot_a]) == int(moved[slot_b]), "the stacks merged and both old slots map to the new one")
	# A failing batch: toasted once, retried, then 'Bag saved.'
	toasts.clear()
	h.inventory.save_failed.emit("boom")
	h.inventory.save_recovered.emit()
	check(toasts.any(func(t: String) -> bool: return t.contains("could not be saved: boom")), "a failed save is toasted")
	check(toasts.has("Bag saved."), "a recovered save is reported")
	# HUD size (Settings) reaches the rebuild's HUD through the shared DmGameUi, and is kept in the rebuild's settings.
	check(h.settings.has("hud_scale"), "the rebuild's settings carry hud_scale")
	g.ui.update_setting({"hud_scale": 1.15})
	check(is_equal_approx(g.ui.hud.hud_scale, 1.15) and is_equal_approx(float(h.settings["hud_scale"]), 1.15), "Settings -> HUD size scales the rebuild's HUD")
	g.queue_free()
	await process_frame
	print("bag: %d passed, %d failed" % [passed, failed])
	print("%s bag %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)
