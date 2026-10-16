class_name DmMain
extends Node
## Game entry (main scene) of the rebuilt client: a port of godot/main/main.gd (client/code.list "Ported"). Boot -> DmFrontFlow (login / discipline select) against the TEST
## server (DmConfig.API_BASE: DECISIONS B38, the live server is never touched before launch day) -> DmNextGame with the chosen character, its bag and its progression.
## Only the four necromancer disciplines and the Reaper are playable (DmCharacterBuild.is_playable); a character of another discipline is sent to the discipline
## switch by the front flow.
## Launch args (after `--`): none needed. Testing only (editor / debug builds; a release export ignores them): `--dev-offline` = local accounts + progress in DEV_OFFLINE_DB
## (DmMockBackend: no network at all); `--dev-offline --class=N` skips the front flow (test account `tester`) and enters directly, with `--seed=N`, `--no-waves` and `--baked=<dir>`
## as the dev entry (dev/dm_dev_entry.tscn, which stays the way to a crowd or a screenshot); `--world-demo` is an alias of `--dev-offline --class=2`.
## `start_opts` (set before add_child; tests) are merged over DmNextGame.start's options.
##
## Off until their ROADMAP items, against today's: the benchmark (the select screen's button says so), co-op (the lobby join, the party hand-over), the automatic crash report
## (DmCrashWatch; a report would open a thread for a test build), and everything the full HUD owns: Log out and Switch character (close the game to sign in again), the
## final save (nothing is saved yet: `save_all` calls the scene's `flush_all`, which is empty).

const DEV_OFFLINE_DB := "user://dm_dev_offline_db.json"    ## --dev-offline testing backend (the same file the dev entry uses)

var mode := ""              ## "online" | "dev_offline" | "test" (injected api, local wording); "" = decided from the launch args in _ready
var flow: DmFrontFlow
var slice: DmNextGame
var api: DmApi              ## set before add_child (tests) to inject a backend; otherwise built from the launch args
var persist_token := true
var start_opts := {}
var _mock: DmMockBackend
var _transport: DmHttpTransport


func _ready() -> void:
	get_tree().auto_accept_quit = false
	# The window title players see. config/name in project.godot stays as it is: Godot names the user:// folder after it (the saved
	# login, settings, tips), so renaming it would sign every player out and reset their settings.
	get_window().title = "Death Muffin"
	# Physics interpolation (project setting) is opt-in per body: everything is OFF by default (effects, cameras, anything placed from
	# _process), and only what is moved in _physics_process turns itself ON (DmSessionBody on the host, the core's heroes).
	get_tree().root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# The Vfx autoload reads the current 3D camera every frame: keep one alive behind the login screens (the world camera takes over).
	var idle_cam := Camera3D.new()
	idle_cam.name = "IdleCamera"
	add_child(idle_cam)
	idle_cam.current = true
	add_child(DmPerfOverlay.new())   # F3 / ?fps overlay, as the web
	var args := OS.get_cmdline_user_args()
	if mode == "":
		mode = mode_for(args)
	if mode == "dev_offline":
		var o := DmDevEntry.options(args)
		if o.has("seed"):
			start_opts["seed"] = o["seed"]
		if o.has("baked"):
			start_opts["baked_dir"] = o["baked"]
		if bool(o["no_waves"]):
			start_opts["waves"] = false
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


## The mode a launch gets from its user args: online unless a testing flag asks for the local dev backend. Release exports (the players'
## client) never honour the testing flags (owner 2026-10-13): the local backend is for the editor binary and the test suites only.
static func mode_for(args: PackedStringArray, debug_build: bool = OS.is_debug_build()) -> String:
	if not debug_build:
		return "online"
	return "dev_offline" if ("--dev-offline" in args or "--world-demo" in args) else "online"


## A normal shutdown (window close, quit) saves first (the web's pagehide flush), then quits.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		await save_all()
		get_tree().quit()


## Final save of the game (also the quit path of the tests). Nothing is saved yet in the rebuild: the scene's `flush_all` is where its saves will go.
func save_all() -> void:
	if slice != null and slice.ready_:
		var s := slice
		slice = null
		await s.flush_all()


func _start_flow() -> void:
	flow = DmFrontFlow.new(api, mode != "online", mode != "online")
	flow.persist_token = persist_token
	flow.online_gate = mode == "online"   # the test channel's manifest online switch (DmOnlineGate; the test build is open to the team's accounts)
	flow.name = "Front"
	flow.enter_world.connect(_enter_world)
	flow.benchmark_requested.connect(_on_benchmark_requested)
	add_child(flow)
	flow.start()


## The character select's Benchmark button: the benchmark returns with the Full Party fight of the new client (ROADMAP), so the select screen says so.
func _on_benchmark_requested() -> void:
	var s := flow.current as DmCharSelectScreen if flow != null else null
	if s != null:
		s.error_label.text = "The benchmark comes back with the Full Party fight."


## Back to the login screen with the reason on it (the token is dropped, as the front flow does when a character cannot be resumed).
func _back_to_login(reason: String) -> void:
	api.set_token("")
	_start_flow()
	if flow.current is DmLoginScreen:
		flow.current.show_notice(DmFrontUi.capitalize_first(reason))


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


## What a character's build is made from, read from the server as today's game reads it (the HUD's bag load and DmProgressSync.connect_server): the bag's rows (worn gear,
## set bonuses) and the progression (damage and legion tier, boons, vows). Reads only: nothing is written, imported or created. {ok, error, slots, local}. An older
## server without the progress route (404) plays with the base numbers; any other failure is the server's own player-readable error.
static func load_build(api_: DmApi, character: Dictionary) -> Dictionary:
	var id := int(character.get("id", 0))
	var bag: DmResult = await api_.get_inventory(id)
	if not bag.ok:
		return {"ok": false, "error": bag.error}
	var local := {}
	var np: DmResult = await api_.necro_get(id)
	if np.ok and np.data is Dictionary and np.data.get("progress") is Dictionary:
		var prog := DmProgression.new(character)
		prog.adopt(np.data["progress"])
		local = prog.local
	elif np.status != 404:
		return {"ok": false, "error": np.error}
	return {"ok": true, "error": "", "slots": bag.data, "local": local}


func _enter_world(character: Dictionary, session) -> void:
	api = session
	if flow != null:
		flow.queue_free()
		flow = null
	if not DmCharacterBuild.is_playable(float(character.get("class_index", 0))):
		_start_flow()   # the front flow's resume() offers the discipline switch
		return
	var loading := DmLoadingScreen.acquire(self, "Waking the dead...")
	loading.set_progress(0.05)
	var build := await load_build(api, character)
	if not build["ok"]:
		loading.dismiss()
		_back_to_login(String(build["error"]))
		return
	await _enter_next(character, loading, build)


## DmNextGame behind the same key-art loading screen (it paints before the synchronous world build; it fades out once the game is ready). A game that refuses to
## start (an api that is not the test server's) is dropped and the login screen says why.
func _enter_next(character: Dictionary, loading: DmLoadingScreen, build: Dictionary) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	slice = g
	add_child(g)
	var opts := {"name": token_username(api.get_token()), "hud": true, "slots": build["slots"], "local": build["local"]}
	opts.merge(start_opts, true)
	var refused := [""]
	g.start_failed.connect(func(reason: String) -> void: refused[0] = reason)
	await g.start(character, api, opts)
	if refused[0] != "":
		slice = null
		g.queue_free()
		loading.dismiss()
		_back_to_login(refused[0])
		return
	loading.dismiss()
