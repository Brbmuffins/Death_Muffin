extends SceneTree
## DmGameUi against the mock DmGame (no live server):  godot --headless --path godot --script res://tests/game_ui/run.gd

var _fail := 0
var _pass := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func make() -> Array:
	DmUiConfig.dir = ""
	var game := DmMockGame.new()
	root.add_child(game)
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	return [game, ui]


func _run() -> void:
	var pair := make()
	var game: DmMockGame = pair[0]
	var ui: DmGameUi = pair[1]
	await _frames(3)
	_check(ui.hud != null and ui.hud.vm.has("hp"), "hud fed from game.hud_state")
	_check(ui.hud.vm.get("level") == 12, "hud level")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
