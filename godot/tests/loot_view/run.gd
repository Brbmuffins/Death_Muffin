extends SceneTree
## Headless tests for godot/loot_view (DmLootView, loot rework 2026-10-12): gold and shards credited at once, items only taken by a pickup
## request once the hero reaches them, 3 min expiry, the item cap, runes through rune_resolve (bag / ground / shards), legendary signal,
## screen picking, render budget.
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/loot_view/run.gd

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	t_currency()
	t_click_pickup()
	t_expiry_and_cap()
	t_runes()
	t_legendary_and_sounds()
	await t_pick()
	t_render_budget()
	print("%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		if failed <= 15:
			print("FAIL: ", msg)


func _view() -> DmLootView:
	var v := DmLootView.new()
	v.rand = func(): return 0.5
	root.add_child(v)
	return v


## Gold and shards never lie on the ground: the next tick credits them (events + picked), wherever the hero is, and nothing is drawn.
func t_currency() -> void:
	var v := _view()
	var got := []
	v.picked.connect(func(e): got.append([e["kind"], e["amount"]]))
	ok(v.drop({"kind": "gold", "amount": 12}, Vector3(30, 0, 30)) == "auto", "gold drop is credited, not landed")
	ok(v.drop({"kind": "shard", "amount": 2}, Vector3(30, 0, 30)) == "auto", "shard drop is credited, not landed")
	v.gold(Vector3.ZERO, 0)   # nothing to credit
	ok(v.count() == 0 and v.get_child_count() == 0, "gold / shards draw nothing (%d nodes)" % v.get_child_count())
	var ev := v.tick(0.016, Vector3(999, 0, 999))
	ok(ev.size() == 2 and ev[0]["kind"] == "gold" and int(ev[0]["amount"]) == 12 and ev[1]["kind"] == "shard" and int(ev[1]["amount"]) == 2, "tick returns the credits %s" % [ev])
	ok(got == [["gold", 12], ["shard", 2]], "picked signals %s" % [got])
	ok(v.tick(0.016, Vector3.ZERO).is_empty(), "credited once")
	v.free()


## Walking over an item takes nothing; a pickup request takes it once the hero is within ITEM_PICKUP_RADIUS; a full bag keeps it on the ground.
func t_click_pickup() -> void:
	var v := _view()
	var bag := [true]
	v.try_take = func(_d): return bag[0]
	v.item(Vector3(2, 0, 0), {"item_id": "ore_copper", "quantity": 3}, true)
	ok(v.count() == 1, "item lands")
	ok(v.tick(0.5, Vector3(2, 0, 0)).is_empty() and v.count() == 1, "standing on it takes nothing")
	var d := v._drops[-1]
	v.request_pickup(d)
	ok(v.tick(0.1, Vector3(10, 0, 0)).is_empty() and v.count() == 1, "far away: still waiting")
	ok(not v.pickup_target().is_empty(), "the target is kept while walking")
	var ev := v.tick(0.1, Vector3(1.0, 0, 0))
	ok(ev.size() == 1 and ev[0]["kind"] == "item" and int(ev[0]["amount"]) == 3 and v.count() == 0, "reached: taken %s" % [ev])
	ok(v.pickup_target().is_empty(), "target cleared after the pickup")
	# full bag: the item stays and the request ends
	v.item(Vector3(0, 0, 0), {"item_id": "ore_copper", "quantity": 1}, true)
	bag[0] = false
	v.request_pickup(v._drops[-1])
	ok(v.tick(0.1, Vector3.ZERO).is_empty() and v.count() == 1 and v.pickup_target().is_empty(), "full bag: stays on the ground, request ends")
	# cancel
	bag[0] = true
	v.request_pickup(v._drops[-1])
	v.cancel_pickup()
	ok(v.tick(0.1, Vector3.ZERO).is_empty() and v.count() == 1, "a cancelled request takes nothing")
	v.free()


func t_expiry_and_cap() -> void:
	var v := _view()
	var exp := []
	v.expired.connect(func(d, reason): exp.append(reason))
	v.item(Vector3.ZERO, {"item_id": "ore_copper", "quantity": 1})
	ok(v.debug_drops()[0]["ttl"] == 180.0, "items last 3 minutes")
	v.tick(179.0, Vector3(99, 0, 99))
	ok(v.count() == 1, "still there at 2:59")
	v.request_pickup(v._drops[-1])
	v.tick(2.0, Vector3(99, 0, 99))
	ok(v.count() == 0 and exp == ["ttl"] and v.pickup_target().is_empty(), "gone after 3 minutes, request dropped with it")
	exp.clear()
	for i in 62:
		v.item(Vector3.ZERO, {"item_id": "ore_copper", "quantity": 1})
	v.item(Vector3.ZERO, {"item_id": "leg_legion_unburied_head", "quantity": 1})
	v.tick(0.01, Vector3(99, 0, 99))
	ok(v.count() == 60 and exp == ["cap", "cap", "cap"], "cap: %d left, %s" % [v.count(), exp])
	var prize := false
	for d in v.debug_drops():
		prize = prize or d["prize"]
	ok(prize, "the legendary outlives the ordinary drops at the cap")
	v.free()


## Runes: a new one goes straight into the bag (rune_found), a known one is swapped for an unowned one of the pool, a complete pool pays shards,
## a full bag leaves the rune on the ground. DmLootRunes.resolve is the rule.
func t_runes() -> void:
	ok(DmLootRunes.resolve("rune_splinter", ["rune_splinter", "rune_impale"], {}) == {"item_id": "rune_splinter"}, "a new rune stays itself")
	ok(DmLootRunes.resolve("rune_splinter", ["rune_splinter", "rune_impale"], {"rune_splinter": true}) == {"item_id": "rune_impale"}, "a known rune becomes one the player lacks")
	ok(DmLootRunes.resolve("rune_contagion", ["rune_contagion"], {"rune_contagion": true}) == {"shards": 2}, "a complete pool: a rare pays 2 shards")
	ok(DmLootRunes.resolve("rune_requiem", ["rune_requiem"], {"rune_requiem": true}) == {"shards": 3}, "an epic pays 3")
	ok(DmLootRunes.resolve("rune_splinter", ["rune_splinter"], {"rune_splinter": true}) == {"shards": 1}, "an uncommon pays 1")
	var all := {}
	for id in DmLootRunes.all_ids():
		all[id] = true
	all.erase("rune_volley")
	ok(DmLootRunes.resolve("rune_splinter", [], all) == {"item_id": "rune_volley"}, "an empty pool means every rune")

	var v := _view()
	var bag: Array = []
	var room := [true]
	v.try_take = func(d):
		if room[0]:
			bag.append(d)
		return room[0]
	var owned := {"rune_splinter": true}
	v.rune_resolve = func(d): return DmLootRunes.resolve(String(d["item_id"]), d.get("rune_pool", []), owned)
	var found := []
	var known := []
	v.rune_found.connect(func(d, _p): found.append(d["item_id"]))
	v.rune_known.connect(func(n, id, _p): known.append([n, id]))
	ok(v.drop({"item_id": "rune_impale", "quantity": 1, "rune_pool": ["rune_impale"]}, Vector3.ZERO) == "auto", "new rune: into the bag")
	ok(found == ["rune_impale"] and bag.size() == 1 and not bag[0].has("rune_pool") and v.count() == 0, "rune_found, nothing on the ground, pool tag dropped")
	ok(v.drop({"item_id": "rune_splinter", "quantity": 1, "rune_pool": ["rune_splinter", "rune_marrow_tap"]}, Vector3.ZERO) == "auto" and found[-1] == "rune_marrow_tap", "known rune swapped for one the player lacks")
	owned["rune_marrow_tap"] = true
	ok(v.drop({"item_id": "rune_splinter", "quantity": 1, "rune_pool": ["rune_splinter", "rune_marrow_tap"]}, Vector3.ZERO) == "shards" and known == [[1, "rune_splinter"]], "complete pool: shards")
	var ev := v.tick(0.016, Vector3.ZERO)
	ok(ev.size() == 1 and ev[0]["kind"] == "shard" and int(ev[0]["amount"]) == 1, "the shards are credited like any shard %s" % [ev])
	room[0] = false
	ok(v.drop({"item_id": "rune_contagion", "quantity": 1, "rune_pool": ["rune_contagion"]}, Vector3.ZERO) == "ground" and v.count() == 1, "full bag: the rune waits on the ground")
	ok(not v._drops[0]["item"].has("rune_pool"), "a grounded rune drops its pool tag")
	v.free()


func t_legendary_and_sounds() -> void:
	var v := _view()
	var snd := []
	var legs := []
	v.dropped_sound.connect(func(id, _p): snd.append(id))
	v.legendary_dropped.connect(func(d, _p): legs.append(d["item_id"]))
	ok(v.drop({"item_id": "leg_legion_unburied_head", "quantity": 1}, Vector3(5, 0, 5)) == "ground", "legendary lands")
	v.drop({"item_id": "ore_copper", "quantity": 1}, Vector3(5, 0, 5))
	ok(snd == ["lootDropLegendary", "lootDrop"], "drop sounds %s" % [snd])
	ok(legs == ["leg_legion_unburied_head"], "legendary_dropped once %s" % [legs])
	var d0: Dictionary = v.debug_drops()[0]
	var dist := Vector2(d0["x"] - 5, d0["z"] - 5).length()
	ok(dist >= 0.3 and dist <= 1.0 + 1e-6, "scatter radius %f" % dist)
	v.free()


## pick(): the drop whose icon is nearest the click on screen, within PICK_PX.
func t_pick() -> void:
	var v := _view()
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 10, 10)
	cam.look_at(Vector3.ZERO)
	cam.make_current()
	await process_frame
	v.item(Vector3(0, 0, 0), {"item_id": "ore_copper", "quantity": 1}, true)
	v.item(Vector3(3, 0, 0), {"item_id": "ore_copper", "quantity": 2}, true)
	var at := cam.unproject_position(Vector3(3, 0.7, 0))
	var d := v.pick(at + Vector2(5, -5), cam)
	ok(not d.is_empty() and int(d["amount"]) == 2, "click next to the second icon picks it")
	ok(v.pick(at + Vector2(400, 300), cam).is_empty(), "a click far from every icon picks nothing")
	cam.free()
	v.free()


## Many drops must not multiply render cost: gold / shards draw nothing, one beam / glow material per rarity.
func t_render_budget() -> void:
	var v := _view()
	for i in 20:
		v.shard(Vector3(i, 0, 0), 1)
		v.gold(Vector3(i, 0, 0), 5)
	ok(v.get_child_count() == 0, "20 gold + 20 shard drops draw nothing")
	v.tick(0.016, Vector3.ZERO)
	for i in 6:
		v.drop({"item_id": "leg_legion_unburied_head", "quantity": 1}, Vector3(i, 0, 3))
	ok(v.find_children("*", "Light3D", true, false).is_empty(), "drops carry no lights")
	var mats := {}
	for b in v.find_children("*", "MeshInstance3D", true, false):
		var mi := b as MeshInstance3D
		if mi.mesh is CylinderMesh and (mi.mesh as CylinderMesh).height == 6.0:
			mats[mi.material_override] = true
	ok(mats.size() == 1, "beams of one rarity share one material (%d materials)" % mats.size())
	v.queue_free()
