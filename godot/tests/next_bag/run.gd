extends SceneTree
## Port fixes on the rebuild: HUD size reaches it, and the Reliquary's bag edits (DmNextUiHost is the `game` DmUiInventory talks to): a sale and a sort go through DmInventory and
## save against the strict live-server slot rule (no quantity-0 rows), and a refused save is toasted once, retried and reported when it lands.
## godot --headless --path godot --script res://tests/next_bag/run.gd

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
	await g.start((await api.load_or_create_character(2)).data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "store": DmCounselStore.new("")})
	var h := g.ui_host
	var toasts: Array = []
	h.game_event.connect(func(id: String, ctx: Dictionary) -> void:
		if id == "toast":
			toasts.append(String(ctx.get("text", ""))))
	check(h.has_method("bag_remove") and h.has_method("bag_sort") and h.has_method("bag_commit"), "the rebuild's UI host offers the bag edit methods")
	var mat := ""
	for id in DmContent.items():
		if String(DmContent.items()[id].get("type", "")) == "material":
			mat = String(id)
			break
	h.inventory.add({"item_id": mat, "quantity": 5})
	var e0: String = await h.bag_commit()
	check(e0 == "", "the starter bag plus pickups saves against the strict rule: " + e0)
	var row: Dictionary = h.slots.filter(func(s: Dictionary) -> bool: return s["item_id"] == mat)[0]
	var qty := int(row["quantity"])
	check(h.bag_remove(int(row["slot_index"]), mat, 2) == 2, "a partial sale takes what was asked")
	var e1: String = await h.bag_commit()
	check(e1 == "", "a partial sale saves: " + e1)
	check(h.bag_remove(int(row["slot_index"]), mat, qty) == qty - 2, "selling the rest takes only what is left")
	check((await h.bag_commit()) == "", "a whole-stack sale saves (no quantity-0 row is sent)")
	check(not h.slots.any(func(s: Dictionary) -> bool: return int(s["quantity"]) < 1), "no quantity-0 rows remain in the bag")
	h.bag_sort()
	check((await h.bag_commit()) == "" and h.inventory.state == "saved", "a sort saves")
	# A failing save: toasted once, retried, then 'Bag saved.'
	mock.strict_slots = false
	toasts.clear()
	h.inventory.add({"item_id": mat, "quantity": 1})
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
	print("next_bag: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
