class_name DmMain
extends Node
## Game entry (main scene). Launch args (after `--`): `--offline` (default) = the offline edition: local accounts + progress on this device
## (DmMockBackend under user://, standalone sign-in rules, no live server); `--online` = DmFrontFlow against the live server.
## Flow: DmFrontFlow (login / discipline select) -> enter_world -> DmGame + DmGameUi.
## Rebuild (godot/next): `USE_NEXT` below (or `-- --next`) routes "Enter world" to DmNextGame instead of DmGame; `--old` forces the old path. The front
## screens, characters, backends (online = VPS, offline = local) and the loading screen are the same for both. `-- --next --class=N` skips the
## front flow (test account `tester`, offline backend).
## Dev: `--qa` keeps the old QA autoload inactive paths; `--world-demo` skips the front flow (offline test account, class 2).

## D7: flip to true to make the rebuild the default (DmGame stays reachable with `-- --old`).
const USE_NEXT := false

var mode := "offline"
var use_next := USE_NEXT
var flow: DmFrontFlow
var game: DmGame
var slice: DmNextGame
var ui: Node
var perf: DmPerfOverlay
var api: DmApi              ## set before add_child (tests) to inject a backend; otherwise built from the launch args
var persist_token := true
var _mock: DmMockBackend
var _transport: DmHttpTransport
var _transit_lobby: DmLobbyClient   ## the lobby socket a join was made on, polled here while the solo game is swapped for the client game
var _party_busy := false            ## a join / return is in progress (one at a time)


func _ready() -> void:
	get_tree().auto_accept_quit = false
	# The Vfx autoload reads the current 3D camera every frame: keep one alive behind the login screens (the world camera takes over).
	var idle_cam := Camera3D.new()
	idle_cam.name = "IdleCamera"
	add_child(idle_cam)
	idle_cam.current = true
	add_child(DmPerfOverlay.new())   # F3 / ?fps overlay, as the web
	var args := OS.get_cmdline_user_args()
	if mode != "test":
		mode = "online" if "--online" in args else "offline"
	if api != null:
		pass   # injected (tests)
	elif mode == "offline":
		_mock = DmOffline.make_mock()
		api = DmOffline.make_api(_mock)
	else:
		_transport = DmHttpTransport.new()
		add_child(_transport)
		api = DmApi.new(_transport.request_callable())
		api.slot_decorator = Callable(DmAffixes, "decorate_slots")
	use_next = (USE_NEXT or use_next or "--next" in args) and not "--old" in args
	if "--world-demo" in args:
		await _demo()
		return
	if use_next and Array(args).any(func(a: String) -> bool: return a.begins_with("--class=")):
		await _next_slice(args)
		return
	_start_flow()


func _process(_dt: float) -> void:
	if _transit_lobby != null:
		_transit_lobby.poll()


## Window close: save everything first (the web's pagehide flush), then quit.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		await save_all()
		get_tree().quit()


## Final save of whichever game is live (also the quit path of the tests): the rebuild's last kill batch, progression and bag, or DmGame's.
func save_all() -> void:
	if slice != null and slice.ready_:
		var s := slice
		slice = null
		await s.flush_all()
	if game != null and game.ready_:
		var g := game
		game = null
		await g.flush_all()


func _start_flow() -> void:
	flow = DmFrontFlow.new(api, mode != "online", mode != "online")
	flow.persist_token = persist_token
	flow.online_gate = mode == "online"   # D10: staff-only online while the manifest says so
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


## Rebuild vertical slice (godot/next/README.md): `-- --next [--class=N]` boots the Chapterhouse + Hollow Graves as a solo DmSession on the
## offline backend. The default path (front flow -> DmGame) is untouched.
func _next_slice(args: PackedStringArray) -> void:
	var cls := 2
	for a in args:
		if a.begins_with("--class="):
			cls = int(a.substr(8))
	var r := await api.register("tester", "t@example.com", "pw1234")
	if not r.ok:
		r = await api.login("tester", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(cls)
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
	if use_next:
		await _enter_next(character)
		return
	# The loading screen goes up first and is painted before the (synchronous) world build starts: no login-screen freeze, no black frame.
	var loading := DmLoadingScreen.acquire(self, "Waking the dead...")
	loading.set_progress(0.05)
	await get_tree().process_frame
	await get_tree().process_frame
	game = DmGame.new()
	game.name = "Game"
	add_child(game)
	perf = DmPerfOverlay.new()
	game.add_child(perf)
	game.left_world.connect(_on_left_world)
	game.world_restart.connect(func(ch: Dictionary): _on_world_restart(ch))
	# Offline progress goes through the offline mock backend (it persists under user:// and answers the Altar routes), like the server online.
	await game.start(character, api, {"local_progress": false, "realtime": mode == "online", "name": token_username(api.get_token())})
	ui = DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	game.ui = ui
	await ui.warm()
	loading.dismiss()   # fades into the game; the same screen has covered every frame since the login screen
	ui.sound.connect(func(n: String): get_node("/root/AudioDirector").play_sfx(n))


## The rebuild: DmNextGame behind the same key-art loading screen (it paints before the synchronous world build; the game's own panel warm-up
## shares it; it fades out once the game is ready). Backend: the offline mock offline (D4), the VPS api online.
func _enter_next(character: Dictionary, join: Dictionary = {}) -> void:
	var loading := DmLoadingScreen.acquire(self, "Waking the dead..." if not join.has("lobby") else "Entering the host's world...")
	loading.set_progress(0.05)
	await get_tree().process_frame
	await get_tree().process_frame
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	slice = g
	add_child(g)
	var opts := {"offline": mode != "online", "name": token_username(api.get_token())}
	for k in ["lobby", "notice"]:
		if join.has(k):
			opts[k] = join[k]
	if join.has("lobby"):
		opts["host"] = false
		g.start_failed.connect(_on_next_join_failed.bind(character), CONNECT_ONE_SHOT)
	await g.start(character, api, opts)
	if g.start_failed.is_connected(_on_next_join_failed):
		g.start_failed.disconnect(_on_next_join_failed)
	if slice != g:
		return   # a refused joiner: the failure handler already swapped the game
	_transit_lobby = null
	if g.ui_host != null:
		g.ui_host.left_world.connect(_on_next_left.bind(true))
		g.ui_host.world_restart.connect(func(ch: Dictionary) -> void: _on_next_restart(ch))
	g.party.join_ready.connect(_on_next_join_ready)
	g.party.client_ended.connect(_on_next_client_ended.bind(character))
	loading.dismiss()


## Party: the lobby seated us in a host's session. The solo game is saved and freed, a client game starts on the same lobby socket.
func _on_next_join_ready(lobby: DmLobbyClient, _info: Dictionary) -> void:
	if _party_busy or slice == null:
		lobby.leave()
		return
	_party_busy = true
	var character := slice.character
	_transit_lobby = lobby
	await _teardown_next()
	await _enter_next(character, {"lobby": lobby})
	_party_busy = false


## Party: the session we joined is over (left, removed, host gone, connection lost): back to our own world, with the reason on screen.
func _on_next_client_ended(_reason: String, text: String, character: Dictionary) -> void:
	if _party_busy or slice == null:
		return
	_party_busy = true
	var lobby: DmLobbyClient = slice.party.lobby
	await _teardown_next()
	if lobby != null:
		lobby.close()
	await _enter_next(character, {"notice": text} if text != "" else {})
	_party_busy = false


## A joiner the host refused or lost while loading: the half-built client game is dropped and the player lands in their own world again.
func _on_next_join_failed(reason: String, character: Dictionary) -> void:
	if slice == null:
		return
	var lobby: DmLobbyClient = slice.party.lobby
	var g := slice
	slice = null
	_transit_lobby = null
	g.process_mode = Node.PROCESS_MODE_DISABLED
	g.queue_free()
	if lobby != null:
		lobby.close()
	await get_tree().process_frame
	await _enter_next(character, {"notice": "Could not join: %s" % reason})
	_party_busy = false


## Log out of the rebuild: final save, free the game, back to the login screen. (`logout` false = keep the session, e.g. a class change.)
func _on_next_left(logout: bool) -> void:
	await _teardown_next()
	if logout:
		api.set_token("")
	_start_flow()


func _on_next_restart(character: Dictionary) -> void:
	await _teardown_next()
	await _enter_world(character, api)


func _teardown_next() -> void:
	var g := slice
	if g == null:
		return
	slice = null
	await g.leave()   # flush_all + session end
	g.queue_free()
	await get_tree().process_frame


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
