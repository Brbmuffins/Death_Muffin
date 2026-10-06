extends SceneTree
## Offline edition: Easy auto combat is unlocked only for a profile named brbmuffins (any case); everyone else stays locked.
## godot --headless --path godot --script res://tests/game/offline_auto_run.gd

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


func _allowed(username: String) -> bool:
	var mock := DmMockBackend.new("")
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var r := await api.register(username, "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	return c.data.get("auto_combat_allowed", false) == true


func _run() -> void:
	_check(await _allowed("Brbmuffins"), "Brbmuffins offline gets auto combat")
	_check(await _allowed("brbmuffins"), "brbmuffins offline gets auto combat")
	_check(not await _allowed("tester"), "other offline profiles stay locked")
	_check(not await _allowed("brbmuffins2"), "near-miss names stay locked")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
