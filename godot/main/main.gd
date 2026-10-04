class_name DmMain
extends Node
## Game entry (main scene). Launch args (after `--`): `--offline` (default) = the offline edition: local accounts + progress on this device
## (DmMockBackend under user://, standalone sign-in rules, no live server); `--online` = DmFrontFlow against the live server.
## Flow: DmFrontFlow (login / discipline select) -> enter_world -> DmGame (+ DmGameUi if the game-ui track is merged, else DmBasicUi).
## Dev: `--qa` keeps the old QA autoload inactive paths; `--world-demo` skips the front flow (offline test account, class 2).

var mode := "offline"
var flow: DmFrontFlow
var game: DmGame
var ui: Node
var api: DmApi
var _mock: DmMockBackend
var _transport: DmHttpTransport
var settings_menu: DmSettingsMenu


func _ready() -> void:
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


func _enter_world(character: Dictionary, session) -> void:
	api = session
	if flow != null:
		flow.queue_free()
		flow = null
	game = DmGame.new()
	game.name = "Game"
	add_child(game)
	var ui_script: Variant = load("res://game_ui/dm_game_ui.gd") if ResourceLoader.exists("res://game_ui/dm_game_ui.gd") else null
	await game.start(character, api, {"local_progress": mode == "offline", "name": String(character.get("username", character.get("name", "You")))})
	if ui_script != null:
		ui = ui_script.new()
		game.add_child(ui)
		ui.setup(game)
	else:
		ui = DmBasicUi.new()
		game.add_child(ui)
		ui.setup(game)
		settings_menu = DmSettingsMenu.new()
		add_child(settings_menu)
		settings_menu.setup()
		game.game_event.connect(func(id: String, _c: Dictionary):
			if id == "escape":
				settings_menu.toggle())


func _on_logged_out() -> void:
	if game != null:
		game.queue_free()
		game = null
