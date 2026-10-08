extends SceneTree
## Regression: the Acre panels' gold. The server returns a delivered contract's gold and a laborer's collected gold but never writes it
## (contracts.cjs: the client owns the total, like a gather reply), so DmGame must credit it and the next save must keep it.
## The panels used to only play a sound, and the gold was lost.
## godot --headless --path godot --script res://tests/game/acre_gold_run.gd

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
	for i in 30:
		game.tick(1.0 / 60.0)
	_check(game.has_method("on_contract_delivered") and game.has_method("on_labor_collected") and game.has_method("on_garden_result"), "DmGame has the Acre panel hooks")
	var g0 := int(game.character["gold"])
	game.on_contract_delivered({"contracts": [], "gold": 120})
	_check(int(game.character["gold"]) == g0 + 120, "contract gold credited: %d -> %d" % [g0, int(game.character["gold"])])
	game.on_contract_delivered({"contracts": [], "gold": 30, "paidBonus": {"gold": 30, "item": {}}})
	_check(int(game.character["gold"]) == g0 + 150, "contract + bonus gold credited")
	game.on_labor_collected({"collected": {"skill": "mining", "gold": 25, "items": [], "hours": 1.0, "xp": 0}}, 0)
	await process_frame
	_check(int(game.character["gold"]) == g0 + 175, "labor gold credited: %d" % int(game.character["gold"]))
	game.prog.save_dirty = true
	await game.flush_all()
	var server: Dictionary = (await api.get_character()).data
	_check(int(server["gold"]) == g0 + 175, "the save keeps it: backend %s" % str(server["gold"]))
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
