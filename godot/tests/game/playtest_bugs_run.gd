extends SceneTree
## Regression tests for the playtest findings (tests/playtest/FINDINGS.md): stale refresh_character() gold rewind, Recall rules, loot pickup
## gate, one-awake-boss, hover node tips. godot --headless --path godot --script res://tests/game/playtest_bugs_run.gd

var _pass := 0
var _fail := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _initialize() -> void:
	_run.call_deferred()


func _tick(game: DmGame, secs: float) -> void:
	for i in int(secs * 60.0):
		game.tick(1.0 / 60.0)


func _key(game: DmGame, ch: String) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.pressed = pressed
		ev.keycode = ch.unicode_at(0) - 32
		ev.unicode = ch.unicode_at(0)
		game.input.handle(ev)


func _run() -> void:
	var mock := DmMockBackend.new("")
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var r := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": false, "persist": false, "seed": 7})
	_tick(game, 1.0)
	await _gold_rewind(game)
	_recall(game)
	_loot(game)
	_boss(game)
	_node_tip(game)
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _gold_rewind(game: DmGame) -> void:
	# Gold is client-saved: a character reply (server copy) must never write it, level or xp back over what pickups credited.
	game.character["gold"] = 477
	game.character["level"] = 5
	game.character["experience"] = 12
	game.refresh_character()
	game.prog.add_gold(40.0)   # credited while the request is in flight
	await process_frame
	await process_frame
	await game.refresh_character()
	_check(int(game.character["gold"]) == 517, "refresh_character keeps locally credited gold: %s" % str(game.character["gold"]))
	_check(int(game.character["level"]) == 5 and int(game.character["experience"]) == 12, "refresh_character keeps level and xp")
	# only the newest of overlapping requests is adopted
	var seq0 := game._character_seq
	game.refresh_character()
	game.refresh_character()
	_check(game._character_seq == seq0 + 2, "each refresh takes a sequence number")


func _recall(game: DmGame) -> void:
	game.respawn()
	game.player.teleport(0.0, -10.0)
	game._enter_area("graves")
	game.recall_at = 0.0
	_key(game, "t")
	_check(game.recall_at > 0.0, "T starts Recall in the Graves")
	# any hit cancels it (web: onHurt -> cancelRecall), pressing again after works
	game.combat.on_hurt(1.0, "melee", game.player.x + 1.0, game.player.z)
	_check(game.recall_at == 0.0, "a hit cancels Recall")
	_key(game, "t")
	_check(game.recall_at > 0.0, "T starts Recall again after the hit")
	game.actions.cancel_recall()
	game.p["hp"] = game.player.max_hp()
	game.player.teleport(0.0, 20.0)
	game._enter_area("chapterhouse")
	_key(game, "t")
	_check(game.recall_at == 0.0, "Recall refuses in the Chapterhouse")


func _loot(game: DmGame) -> void:
	game.respawn()
	game.player.teleport(0.0, -10.0)
	game._enter_area("graves")
	var lv := DmLootView.new()   # the headless game builds none (visual only)
	game.add_child(lv)
	lv.try_take = func(d: Dictionary) -> bool: return game.rewards.try_take(d)
	game.lootview = lv
	lv.clear_all()
	var pos := Vector3(game.player.x + 0.5, 0, game.player.z)
	var bag0 := game.inventory.count("flask_hp_minor")
	lv.item(pos, {"item_id": "flask_hp_minor", "quantity": 1}, true)
	lv.gold(pos, 25, true)
	game.character["gold"] = 0
	game.rewards.tick_loot(0.1)
	_check(game.inventory.count("flask_hp_minor") == bag0, "an item younger than the pickup age gate stays on the ground")
	for i in 90:
		game.rewards.tick_loot(1.0 / 60.0)
	_check(game.inventory.count("flask_hp_minor") > bag0, "the item is picked up once old enough and in range")
	for i in 90:
		game.rewards.tick_loot(1.0 / 60.0)
	_check(int(game.character["gold"]) == 25 and lv.count() == 0, "gold flies in and pays out: %s" % str(game.character["gold"]))
	# Out of reach stays; hero position changes between ticks are honoured the same frame.
	lv.item(Vector3(game.player.x + 6.0, 0, game.player.z), {"item_id": "flask_hp_minor", "quantity": 1}, true)
	for i in 60:
		game.rewards.tick_loot(1.0 / 60.0)
	var n := lv.count()
	game.player.teleport(game.player.x + 6.0, game.player.z)
	game.rewards.tick_loot(1.0 / 60.0)
	_check(n == 1 and lv.count() == 0, "an item 6 m away waits, then is taken the frame the hero stands on it")
	lv.clear_all()
	game.lootview = null
	lv.queue_free()


func _boss(game: DmGame) -> void:
	game.respawn()
	var b = game.sim.boss.state
	game.prog.local["shards"] = 99
	game.nav.set_unlocked(DmContent.area_order())
	var ids: Array = DmContent.get_export("bosses", "BOSS_IDS")
	var first := String(ids[0])
	var ar: Dictionary = DmContent.boss(first)["arena"]
	game.player.teleport(float(ar["x"]), float(ar["z"]) + float(ar["r"]) * 0.7)
	_tick(game, 0.2)
	game.actions.summon_boss_normal(first)
	_tick(game, 3.0)
	_check(game.sim.boss.state.active, "the first boss wakes")
	var shards := float(game.prog.local["shards"])
	game.actions.summon_boss_normal(String(ids[1]))
	_check(float(game.prog.local["shards"]) == shards, "while one boss is awake a second summon is refused and costs nothing (one awake boss, as the web)")


func _node_tip(game: DmGame) -> void:
	game.respawn()
	game.player.teleport(-26.0, 20.0)
	game._enter_area("acre")
	var node: Dictionary = {}
	for n in game._sim_world["nodes"]:
		if String(n["area"]) == "acre":
			node = n
			break
	_check(not node.is_empty(), "an acre node exists")
	var html := game.gatherer.node_tip_text(node)
	var def: Dictionary = DmGathering.node_def(String(node["type"]))
	_check(html.begins_with("<b>%s</b>" % def["name"]) and html.contains("XP per success"), "node tip text: %s" % html)
	var HudStub := GDScript.new()
	HudStub.source_code = "extends RefCounted\nvar calls := []\nfunc node_tip(h, x = 0.0, y = 0.0):\n\tcalls.append([h, x, y])\n"
	HudStub.reload()
	var UiStub := GDScript.new()
	UiStub.source_code = "extends Node\nvar hud\nvar open := false\nfunc panel_open():\n\treturn open\n"
	UiStub.reload()
	var ui = UiStub.new()
	var hud = HudStub.new()
	ui.hud = hud
	game.ui = ui
	game.gatherer.update_node_tip({"kind": "node", "node": node}, 100.0, 200.0)
	_check(hud.calls.size() == 1 and hud.calls[0][0] == html and hud.calls[0][1] == 100.0 and hud.calls[0][2] == 200.0, "hovering a node feeds hud.node_tip(html, x, y)")
	game.gatherer.update_node_tip({"kind": "enemy", "id": 1}, 1.0, 2.0)
	_check(hud.calls[1][0] == null, "an enemy under the cursor clears the node tip")
	ui.open = true
	game.gatherer.update_node_tip({"kind": "node", "node": node}, 1.0, 2.0)
	_check(hud.calls[2][0] == null, "no node tip while a panel is open")
	ui.open = false
	game.gatherer.update_node_tip(null, 1.0, 2.0)
	_check(hud.calls[3][0] == null, "nothing under the cursor hides the tip")
	game.ui = null
	ui.free()
