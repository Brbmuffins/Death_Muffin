class_name DmMain
extends Node
## Game entry (main scene). ONE version of the game (owner 2026-10-09): online against the live server, DmFrontFlow (login / discipline select)
## -> DmNextGame (godot/next). Only the four necromancer disciplines are playable (DmCharacterBuild.is_playable); a character of another
## discipline is sent to the discipline switch by the front flow.
## Launch args (after `--`): none needed. `--online` / `--offline` / `--next` from older launchers and scripts are accepted and ignored.
## Testing only: `--dev-offline` = local accounts + progress in DEV_OFFLINE_DB (DmMockBackend, no live server); `--dev-offline --class=N`
## skips the front flow (test account `tester`) and enters DmNextGame directly; `--world-demo` is an alias of `--dev-offline --class=2` (the screenshot QA's
## launch line, shot-godot.sh).
## On an online start the retired offline edition's save and its stored "offline:" token are deleted (owner: offline characters are deleted).

const OFFLINE_EDITION_DB := "user://dm_offline_db.json"   ## the retired player-facing offline edition's accounts + characters
const DEV_OFFLINE_DB := "user://dm_dev_offline_db.json"    ## --dev-offline testing backend (never the player's old offline save)

var mode := ""              ## "online" | "dev_offline" | "test" (injected api); "" = decided from the launch args in _ready
var flow: DmFrontFlow
var slice: DmNextGame
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
	if mode == "":
		mode = mode_for(args)
	if mode == "online":
		wipe_offline_edition()
	if api != null:
		pass   # injected (tests)
	elif mode == "dev_offline":
		_mock = DmOffline.make_mock(DEV_OFFLINE_DB)
		api = DmOffline.make_api(_mock)
	else:
		_transport = DmHttpTransport.new()
		add_child(_transport)
		api = DmApi.new(_transport.request_callable())
		api.slot_decorator = Callable(DmAffixes, "decorate_slots")
	var quick := quick_start_class(args)
	if mode != "online" and quick >= 0:
		await _dev_quick_start(quick)
		return
	_start_flow()


## Testing: the class a dev quick start enters with (`--class=N`; `--world-demo` = class 2), -1 = no quick start (the front flow runs).
static func quick_start_class(args: PackedStringArray) -> int:
	for a in args:
		if a.begins_with("--class="):
			return int(a.substr(8))
	return 2 if "--world-demo" in args else -1


## The mode a launch gets from its user args: online unless a testing flag asks for the local dev backend.
static func mode_for(args: PackedStringArray) -> String:
	return "dev_offline" if ("--dev-offline" in args or "--world-demo" in args) else "online"


## The retired offline edition (owner 2026-10-09): its local accounts / characters file and a stored "offline:<name>" session token are
## deleted. Safe to run every start (nothing left = nothing done).
static func wipe_offline_edition() -> void:
	for p in [OFFLINE_EDITION_DB, OFFLINE_EDITION_DB + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if FileAccess.file_exists(DmApi.TOKEN_FILE):
		var f := FileAccess.open(DmApi.TOKEN_FILE, FileAccess.READ)
		var t := f.get_as_text().strip_edges() if f != null else ""
		f = null
		if t.begins_with("offline:"):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(DmApi.TOKEN_FILE))


func _process(_dt: float) -> void:
	if _transit_lobby != null:
		_transit_lobby.poll()


## Window close: save everything first (the web's pagehide flush), then quit.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		await save_all()
		get_tree().quit()


## Final save of the live game (also the quit path of the tests): the rebuild's last kill batch, progression and bag.
func save_all() -> void:
	if slice != null and slice.ready_:
		var s := slice
		slice = null
		await s.flush_all()


func _start_flow() -> void:
	flow = DmFrontFlow.new(api, mode != "online", mode != "online")
	flow.persist_token = persist_token
	flow.online_gate = mode == "online"   # the manifest's online switch (DmOnlineGate; open to everyone since 2026-10-09)
	flow.name = "Front"
	flow.enter_world.connect(_enter_world)
	add_child(flow)
	flow.start()


## Testing: `-- --dev-offline --class=N` (or `--world-demo`, class 2) skips the front flow and enters the game as `tester` on the dev-offline backend.
func _dev_quick_start(cls: int) -> void:
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
	if not DmCharacterBuild.is_playable(float(character.get("class_index", 0))):
		_start_flow()   # the front flow's resume() offers the discipline switch
		return
	await _enter_next(character)


## The rebuild: DmNextGame behind the same key-art loading screen (it paints before the synchronous world build; the game's own panel warm-up
## shares it; it fades out once the game is ready). Backend: the VPS api online, the mock in dev-offline / tests.
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
