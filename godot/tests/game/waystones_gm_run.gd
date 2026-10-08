extends SceneTree
## Waystone travel for GM/dev-access characters: a sealed area (pyre) is reachable, and the travel list shows it.
## godot --headless --path godot --script res://tests/game/waystones_gm_run.gd

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
	game.dev_account = true
	game.settings["dev_access"] = true
	game._apply_dev_access()
	_check(not game.prog.really_unlocked("pyre") and game.prog.is_unlocked("pyre"), "pyre is sealed for real but open under dev_access")
	var stone := {}
	for it in DmContent.area("pyre")["interactables"]:
		if it["kind"] == "waystone":
			stone = it
	_check(not stone.is_empty(), "pyre has a waystone")
	game.player.teleport(float(game._waystones[0]["x"]) + 1.0, float(game._waystones[0]["z"]))  # stand beside a waystone, as in play
	game.actions.travel("pyre")
	_check(DmSimMath.hypot(float(stone["x"]) - game.player.x, float(stone["z"]) + 1.6 - game.player.z) < 0.5, "travel to pyre with dev_access lands at its waystone")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
