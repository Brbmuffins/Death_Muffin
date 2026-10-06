extends SceneTree
## Regression: milestone gold (check_milestones -> loot view -> pickup) is saved through the offline backend and survives a relaunch.
## The playtest's "gold decreased | 1410 -> 1370 (relaunch)" findings turned out to be the bot clicking the HUD Buy Damage button
## (40 / 60 gold, the same numbers as the milestones); this pins the real milestone path so that cannot hide a true loss.
## godot --headless --path godot --script res://tests/game/milestone_gold_run.gd

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


func _boot(api: DmApi, character: Dictionary) -> DmGame:
	var game := DmGame.new()
	root.add_child(game)
	await game.start(character, api, {"visual": false, "persist": false, "seed": 7})
	return game


func _run() -> void:
	var mock := DmMockBackend.new("")
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var r := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := await _boot(api, c.data)
	for i in 60:
		game.tick(1.0 / 60.0)
	game.respawn()
	game.player.teleport(0.0, -10.0)
	game._enter_area("graves")
	var lv := DmLootView.new()   # the headless game builds none (visual only)
	game.add_child(lv)
	lv.try_take = func(d: Dictionary) -> bool: return game.rewards.try_take(d)
	game.lootview = lv
	lv.clear_all()
	game.character["gold"] = 500
	game.prog.add_gold(0.0)
	# The 100th kill reaches "100 dead (+40 gold)"; the Hollow Graves 100 is its own milestone.
	game.prog.local["totalKills"] = 100
	game.prog.local["areaKills"] = {"graves": 100}
	game.rewards.check_milestones()
	var dropped := lv.count()
	_check(dropped >= 1, "reaching a milestone drops its gold (%d piles)" % dropped)
	for i in 240:
		game.rewards.tick_loot(1.0 / 60.0)
	var gold: int = int(game.character["gold"])
	var owed := gold - 500
	_check(owed >= 40 and lv.count() == 0, "the milestone gold is picked up: %d gold gained, %d piles left" % [owed, lv.count()])
	await game.flush_all()
	var server: Dictionary = (await api.get_character()).data
	_check(int(server["gold"]) == gold, "the backend holds the picked-up milestone gold: client %d, backend %s" % [gold, str(server["gold"])])
	# relaunch: a new game on the same backend
	game.lootview = null
	game.queue_free()
	await process_frame
	var again: Dictionary = (await api.get_character()).data
	var game2 := await _boot(api, again)
	for i in 120:
		game2.tick(1.0 / 60.0)
	_check(int(game2.character["gold"]) == gold, "gold unchanged after relaunch: %d -> %s" % [gold, str(game2.character["gold"])])
	# a late character reply must not rewind it either
	await game2.refresh_character()
	_check(int(game2.character["gold"]) == gold, "gold unchanged after refresh_character")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
