extends SceneTree
## Regression: buying a Legion tier (Legion panel, Reinforce) spends gold on the server; the client must adopt it, or the next save
## writes the old gold back and the tier was free. The panel goes through `psync.spend_on_server`, pinned here on the offline backend.
## godot --headless --path godot --script res://tests/game/legion_gold_run.gd

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
	var game: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(game)
	await game.start(c.data, api, {"visual": false, "persist": false, "waves": false, "audio": false})
	var host := game.ui_host   # the DmGameUi contract: character, progression, Acre / Legion hooks
	await process_frame
	host.character["gold"] = 5000
	host.prog.add_gold(0.0)
	await game.flush_all()
	var tier0 := int(host.progress.get("legionTier", 0))
	var res: DmResult = await host.psync.spend_on_server(func() -> DmResult: return await host.api.necro_purchase(host.hero_id, "legion"))
	_check(res.ok, "legion purchase succeeds: %s" % res.error)
	await host.refresh_progress()
	await host.refresh_character()
	var cost := 5000 - int(host.character["gold"])
	_check(cost > 0, "the client paid for the tier: %d gold" % cost)
	_check(int(host.progress.get("legionTier", 0)) == tier0 + 1, "legion tier %d -> %s" % [tier0, str(host.progress.get("legionTier", 0))])
	host.prog.save_dirty = true
	await game.flush_all()
	var server: Dictionary = (await api.get_character()).data
	_check(int(server["gold"]) == 5000 - cost, "the next save keeps the spend: client %d, backend %s" % [int(host.character["gold"]), str(server["gold"])])
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
