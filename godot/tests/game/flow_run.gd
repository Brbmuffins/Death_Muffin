extends SceneTree
## The shipped entry flow (headless): main scene -> DmFrontFlow (offline: standalone sign-in) -> enter_world -> DmGame + fallback UI;
## then Settings -> Leave returns to the login screen. godot --headless --path godot --script res://tests/game/flow_run.gd

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

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## Poll a condition on the wall clock (one frame apart): a frame-count cap flaked when threaded loads lag on a loaded VPS.
func _until(cond: Callable, sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end and not cond.call():
		await process_frame

func _run() -> void:
	var main: DmMain = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	await _frames(10)
	await _until(func() -> bool: return main.flow != null and main.flow.current_name == "login", 30.0)
	_check(main.mode == "offline", "no args = offline")
	_check(main.flow != null and main.flow.current_name == "login", "the login screen shows first: %s" % (main.flow.current_name if main.flow != null else "-"))
	var uname := "flow%d" % (Time.get_ticks_usec() % 1000000)
	var r := await main.api.register(uname, "f@example.com", "pw1234")
	_check(r.ok, "registered")
	main.api.set_token(r.data["token"])
	await main.flow.resume()
	_check(main.flow.current_name == "select", "a new account goes to discipline select: %s" % main.flow.current_name)
	var c := await main.api.load_or_create_character(2)
	main.flow.go_world(c.data)
	await _frames(5)
	await _until(func() -> bool: return main.game != null and main.game.ready_, 60.0)
	_check(main.game != null and main.game.ready_, "the world is up")
	_check(main.ui != null, "a UI is mounted")
	await _frames(30)
	var vm: Dictionary = main.game.hud_state()
	_check(vm["max_hp"] > 0 and vm["area_name"] == "The Sexton's Acre", "hud_state: %s" % vm["area_name"])
	_check(DmMain.token_username("offline:" + uname) == uname, "token username")
	main.game.leave_world()
	await _frames(20)
	await _until(func() -> bool: return main.game == null and main.flow != null, 30.0)
	_check(main.game == null and main.flow != null, "Leave returns to the login screen")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
