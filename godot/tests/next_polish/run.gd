extends SceneTree
## The solo-polish pass on the rebuild: counsel events the current client raises (enemy_spawned / sanctify_near / corpse_near / auto_combat_cast),
## progressive reveal + NEW pips, stored gather bests, the Dev access toggle's effects, F9 break seals. 
## godot --headless --path godot --script res://tests/next_polish/run.gd

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var h: DmNextUiHost
var ui: DmGameUi
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


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func ids(id: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == id)


func boot(dev: bool) -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("pl%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c0 := await api.load_or_create_character(2)
	var ch: Dictionary = c0.data
	if dev:
		ch["gm_enabled"] = true
	var us := DmCounselStore.new(DmUiConfig.store_path())   # offline ids restart at 1 every run: forget any earlier run's reveal state
	us.set_item(DmHudReveal.storage_key(int(ch["id"])), "")
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(ch, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "store": DmCounselStore.new("")})
	ui = g.ui
	h = g.ui_host
	events.clear()
	h.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	await frames(20)


func shutdown() -> void:
	await g.leave()
	g.queue_free()
	await frames(3)


func _run() -> void:
	await boot(true)
	var b := g.local_body()

	# ---- 1. counsel events
	var e := g.director.spawn("robber", b.position + Vector3(5, 0, 0))
	await frames(2)
	check(ids("enemy_spawned").any(func(x: Dictionary) -> bool: return x["ctx"]["def"] == "robber" and x["ctx"]["near"] == true), "enemy_spawned raised for a near spawn")
	var far := ids("enemy_spawned").size()
	g.director.spawn("robber", b.position + Vector3(90, 0, 0))
	await frames(2)
	check(ids("enemy_spawned").size() == far, "a far spawn raises nothing")
	e.cue.emit(&"sanctify", b.position + Vector3(3, 0, 0), 0.0)
	check(ids("sanctify_near").size() == 1 and absf(float(ids("sanctify_near")[0]["ctx"]["dist"]) - 3.0) < 0.1, "sanctify_near with the distance")
	var c := DmSimCorpse.new()
	c.id = 777
	c.x = b.position.x + 4.0
	c.z = b.position.z
	g.corpses.corpse_added.emit(c)
	check(ids("corpse_near").size() == 1 and absf(float(ids("corpse_near")[0]["ctx"]["dist"]) - 4.0) < 0.1, "corpse_near with the distance")
	var store := h.settings_store
	store.set_active_character(int(g.character.get("id", 1)), true)
	store.update({"difficulty": "easy", "auto_combat": true})
	var foe: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	foe.with_visual = false
	foe.use_nav = false
	foe.use_avoidance = false
	foe.def_id = "robber"
	foe.hp_mult = 1000.0
	foe.position = b.position + Vector3(0, 0, -6)
	g.add_child(foe)
	foe.set_physics_process(false)
	DmStatusSet.attach(foe)
	g.director.enemies[9001] = foe
	var t0 := Time.get_ticks_msec()
	await until(func() -> bool: return ids("auto_combat_cast").size() > 0, 8.0)
	check(ids("auto_combat_cast").size() > 0, "auto_combat_cast raised by an auto cast (%d ms)" % (Time.get_ticks_msec() - t0))
	store.update({"auto_combat": false})
	g.director.enemies.erase(9001)
	foe.queue_free()

	# ---- 2. progressive reveal + NEW pips
	check(not ui.reveal.has("hud.shards") and not ui.reveal.has("menu.skills") and not ui.reveal.has("hud.dial"), "fresh character: shards / skills / dial are held back")
	var held: Dictionary = ui.merged_vm()["reveal"]
	check(held.get("hud.shards") == false and held.get("menu.skills") == false, "the HUD view model holds them back")
	h.prog.local["shards"] = 3
	ui.skills = {"mining": 2}
	h.prog.local["waveTierOwned"] = 1
	ui._progressive_tick()
	check(ui.reveal.has("hud.shards") and ui.reveal.has("menu.skills") and ui.reveal.has("hud.dial"), "shards, skills and the dial reveal as you progress")
	var vm: Dictionary = ui.merged_vm()
	check(vm["new"].get("menu.skills") == true and not (vm["reveal"] as Dictionary).has("menu.skills"), "menu.skills is NEW and no longer held back")
	check(ui.pa.acre_win != null and ui.reveal.is_new("menu.skills"), "NEW pip flagged (persisted reveal)")
	ui.toggle_panel("professions")
	await frames(3)
	check(not ui.reveal.is_new("menu.skills") and not ui.merged_vm()["new"].has("menu.skills"), "opening the panel clears the NEW pip")
	ui.close_panels()

	# ---- 3. gather bests are stored
	var skill: String = String(DmContent.get_export("gameplay_gatheringRules", "SKILLS").keys()[0])
	var item_id := String(DmContent.items().keys()[0])
	var make_session := func(qty: int) -> void:
		var s := DmGatherSession.new(float(Time.get_ticks_msec()) - 120000.0,
			func(id: String) -> Dictionary: return {"name": id, "rarity": "common", "sell": 1},
			func(_s: String) -> int: return 1, func(_s: String) -> float: return 0.0)
		s.record({"skill": skill, "items": [{"itemId": item_id, "qty": qty}], "xp": 40 * qty})
		g.gather.session = s
	make_session.call(5)
	await g.gather._end_session("test")
	var key := "dm_gather_best_v1:%d" % int(h.character["id"])
	var stored: Variant = JSON.parse_string(g.progress.store.get_item(key))
	check(stored is Dictionary and int(stored[skill]["items"]) == 5, "bests are written under the current game's key")
	g.gather.bests = {}   # a relaunch: read back from the store
	make_session.call(9)
	await g.gather._end_session("test")
	var rep: Dictionary = ids("gather_report").back()["ctx"]["report"]
	check((rep["records"] as Array).size() == 1, "a better session reads the stored best (records: %s)" % [rep["records"]])
	check(int(JSON.parse_string(g.progress.store.get_item(key))[skill]["items"]) == 9, "and stores the new best")

	# ---- 4. dev access (dev account)
	check(h.dev_account and h.dev_access and h.prog.dev_access and g.gather.skills.dev_access, "dev account: dev_access on at setup (settings default on)")
	var caster := b.get_node_or_null("Rites") as DmRiteCaster
	await until(func() -> bool: return b.get_node_or_null("Rites") != null and b.get_node_or_null("Rites").dev, 3.0)
	caster = b.get_node_or_null("Rites") as DmRiteCaster
	check(caster.dev, "the host's own caster is told (locked rites cast)")
	check(g.chapterhouse != null and h.prog.is_unlocked("warren"), "sealed halls read as open")
	events.clear()
	h.settings_store.update({"dev_access": false})
	check(not h.dev_access and not h.prog.dev_access and not g.gather.skills.dev_access and not caster.dev and not h.prog.is_unlocked("warren"), "toggle off: everything closes again")
	check(ids("toast").any(func(x: Dictionary) -> bool: return String(x["ctx"]["text"]).begins_with("Dev access off")), "toast says so")
	check(h.dev_break_seals() == 0, "F9 does nothing with dev access off")
	h.settings_store.update({"dev_access": true})
	check(h.dev_access and h.prog.dev_access and caster.dev and ids("toast").any(func(x: Dictionary) -> bool: return String(x["ctx"]["text"]).begins_with("Dev access on")), "toggle on: effects return")
	h.settings_store.update({"dev_access": false})

	# ---- 5. F9 break seals (key path)
	h.settings_store.update({"dev_access": true})
	var open := func() -> int:
		var n := 0
		for id in DmContent.area_order():
			if h.prog.really_unlocked(String(id)):
				n += 1
		return n
	var before: int = open.call()
	var f9 := InputEventKey.new()
	f9.keycode = KEY_F9
	f9.pressed = true
	g.input._unhandled_input(f9)
	check(int(open.call()) == DmContent.area_order().size() and before < int(open.call()), "F9 breaks every seal (%d -> %d)" % [before, open.call()])
	check(h.prog.local["unlocked"].has("warren"), "and the break is real (saved state)")

	# ---- 5c. the QA driver runs the rebuild (main/qa_driver.gd, `-- --qa`): pack arrives, rites are cast
	var qa: Node = load("res://main/qa_driver.gd").new()
	qa.nxt = g
	qa.t = 11.98
	root.add_child(qa)
	qa.seconds = 1e9
	qa._setup = true
	var casts_seen := []
	g.input.hotbar.connect(func(slot: int, _a: Vector3, eid: int) -> void: casts_seen.append([slot, eid]))
	for i in 40:
		qa.t += 0.02
		qa._process_next(0.02)
		await process_frame
	check(g.director.enemies.size() >= 5, "QA driver: a pack of the dead arrives (%d)" % g.director.enemies.size())
	check(casts_seen.size() > 0 and int(casts_seen[0][1]) != 0, "QA driver: rites are cast at an enemy (%d casts)" % casts_seen.size())
	qa.free()
	await shutdown()

	# ---- 4b / 5b. a normal (non-dev) account never gets any of it
	await boot(false)
	check(not h.dev_account and not h.dev_access and not h.prog.dev_access, "normal account: dev access never on")
	h.settings_store.update({"dev_access": false})
	h.settings_store.update({"dev_access": true})
	check(not h.dev_access and not g.gather.skills.dev_access, "the toggle does nothing for a normal account")
	var before2: int = h.prog.local["unlocked"].size()
	var f9b := InputEventKey.new()
	f9b.keycode = KEY_F9
	f9b.pressed = true
	g.input._unhandled_input(f9b)
	check(h.prog.local["unlocked"].size() == before2 and h.dev_break_seals() == 0, "F9 is a no-op for a normal account")
	await shutdown()

	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
