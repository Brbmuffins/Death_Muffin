class_name DmMain
extends Node
## Game entry (main scene). Launch args (after `--`): `--offline` (default) = the offline edition: local accounts + progress on this device
## (DmMockBackend under user://, standalone sign-in rules, no live server); `--online` = DmFrontFlow against the live server.
## Flow: DmFrontFlow (login / discipline select) -> enter_world -> DmGame + DmGameUi.
## Dev: `--qa` keeps the old QA autoload inactive paths; `--world-demo` skips the front flow (offline test account, class 2).

var mode := "offline"
var flow: DmFrontFlow
var game: DmGame
var ui: Node
var api: DmApi
var _mock: DmMockBackend
var _transport: DmHttpTransport


func _ready() -> void:
	get_tree().auto_accept_quit = false
	var args := OS.get_cmdline_user_args()
	mode = "online" if "--online" in args else "offline"
	if mode == "offline":
		_mock = DmOffline.make_mock()
		api = DmOffline.make_api(_mock)
	else:
		_transport = DmHttpTransport.new()
		add_child(_transport)
		api = DmApi.new(_transport.request_callable())
		api.slot_decorator = Callable(DmAffixes, "decorate_slots")
	if "--world-demo" in args:
		await _demo()
		return
	_start_flow()


## Window close: save everything first (the web's pagehide flush), then quit.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if game != null and game.ready_:
			var g := game
			game = null
			await g.flush_all()
		get_tree().quit()


func _start_flow() -> void:
	flow = DmFrontFlow.new(api, mode == "offline", mode == "offline")
	flow.name = "Front"
	flow.enter_world.connect(_enter_world)
	flow.logged_out.connect(_on_logged_out)
	add_child(flow)
	flow.start()


func _demo() -> void:
	var r := await api.register("tester", "t@example.com", "pw1234")
	if not r.ok:
		r = await api.login("tester", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	await _enter_world(c.data, api)


## The account name the session token carries (web tokenUsername): "offline:<name>" or a JWT whose payload has `username`.
static func token_username(token: String) -> String:
	if token.begins_with("offline:"):
		return token.substr(8)
	var parts := token.split(".")
	if parts.size() >= 2:
		var b64 := String(parts[1]).replace("-", "+").replace("_", "/")
		while b64.length() % 4 != 0:
			b64 += "="
		var raw := Marshalls.base64_to_raw(b64)
		var j: Variant = JSON.parse_string(raw.get_string_from_utf8())
		if j is Dictionary and j.get("username") is String:
			return j["username"]
	return "You"


func _enter_world(character: Dictionary, session) -> void:
	api = session
	if flow != null:
		flow.queue_free()
		flow = null
	game = DmGame.new()
	game.name = "Game"
	add_child(game)
	game.left_world.connect(_on_left_world)
	game.world_restart.connect(func(ch: Dictionary): _on_world_restart(ch))
	await game.start(character, api, {"local_progress": mode == "offline", "name": token_username(api.get_token())})
	ui = DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	game.ui = ui
	ui.sound.connect(func(n: String): get_node("/root/AudioDirector").play_sfx(n))


func _teardown_game() -> void:
	if game != null:
		game.queue_free()
		game = null
	ui = null


func _on_left_world() -> void:
	if game == null:
		return
	_teardown_game()
	_start_flow()


func _on_world_restart(character: Dictionary) -> void:
	_teardown_game()
	await _enter_world(character, api)


func _on_logged_out() -> void:
	_teardown_game()
