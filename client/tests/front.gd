extends SceneTree
## The front flow of the rebuilt client (ROADMAP: client layer, "Login to the test server and character select"), headless. The real boot scene (main/main.tscn, DmMain) runs
## the real front flow (login, character select, the online gate) and the real game scene, with an api that is the real DmApi (its default base url) over a recording
## transport that answers from today's mock backend. Nothing here uses a real account, a real token or the live server. It checks:
##   - the boot reaches the login screen, sends nothing yet, and logs no error;
##   - a new player registers, passes the online gate (the test channel's manifest), lands on character select, picks a Mourner and the game scene runs with THAT
##     character: its discipline, and a build made from the bag and the progression the server holds;
##   - a returning player (a login kept) skips the select, and the gear worn in the server's bag (a helm, a staff) is in the hero's stats and loadout;
##   - the panels' hand-overs: a discipline change from the class panel restarts the game with the changed character (a Reaper), Switch character lands on the select
##     screen with the same login and a pick goes back in, Log out lands on the login screen with no login kept;
##   - an account whose discipline is not playable is sent to the discipline switch;
##   - THE API RULE (DECISIONS B38): every address the client can use resolves to the TEST server, never to the live API, live lobby or live manifest (read from
##     godot/net/dm_config.gd): the config, DmApi's default, every request the flows made, the allow-list of the transport and of the game scene, the real transport's
##     refusal of a live address, a front flow whose api is the live one (it ends on the login screen, saying why), and a scan of every shipped file for an address
##     outside net/dm_config.gd;
##   - an unreachable or failing server shows today's player-readable error (login, a stored login at boot, and the bag failing to load);
##   - the offline dev entry still works: a dev character on the local mock, no base url, no transport, no request;
##   - the real test server answers its public health route and its manifest with no credentials (skipped, not failed, when this machine is offline);
##   - ZERO script errors or engine errors in the log (the one the transport logs for the refused live address is expected and counted).
## Bakes the robber and the hound into a scratch folder first (about 20 s). Run: godot --headless --path client --script res://tests/front.gd

const OUT := "user://front_test"
const BAKE := ["grave_robber", "bone_hound"]
## What this build may talk to (the literal, so a change of net/dm_config.gd cannot move the test with it) and what it never may (also read from godot/net/dm_config.gd below).
const TEST_API := "https://muffindevelopment.com/death-muffin/test-api"
const LIVE_API := "https://muffindevelopment.com/death-muffin/api"
const LIVE_LOBBY := "wss://muffindevelopment.com/death-muffin/lobby/"
const TEST_LOBBY := "wss://muffindevelopment.com/death-muffin/test-lobby/"   # the test lobby of 2-player co-op (server/death-muffin/test-server/coop)
const SCAN_EXT := ["gd", "tscn", "tres", "json", "cfg", "godot", "gdshader", "gdshaderinc", "txt", "csv"]
const SCAN_SKIP := ["tests", "assets", "addons", ".godot", "bin", "assets/crowd/baked", "ui/fonts"]   # ui/fonts: the fonts' licence texts carry their authors' web addresses

# The throwaway player of the mock backend: made up for each run, it exists only in memory in this process. No real account, password or token appears in this suite.
var PLAYER := "mock%d" % (100000 + randi() % 900000)
var PLAYER_MAIL := PLAYER + "@example.invalid"
var PLAYER_PASS := "pw%d" % (100000 + randi() % 900000)


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## The recording transport: what a DmHttpTransport would send, answered from the mock backend (routes under `base`), the test channel's manifest, or nothing.
class Shim:
	extends RefCounted
	var mock: DmMockBackend
	var base := DmConfig.API_BASE
	var urls: Array[String] = []
	var manifest := '{"online": {"enabled": true, "staff": false, "message": "Test build"}}'
	var down := false          ## every request: the server cannot be reached
	var fail_part := ""        ## a request whose address contains this gets fail_status / fail_text
	var fail_status := 0
	var fail_text := ""

	func send(req: Dictionary) -> Dictionary:
		var url := String(req["url"])
		urls.append(url)
		if down:
			return {"status": 0, "text": "", "network_error": true}
		if url.get_slice("?", 0) == DmConfig.CLIENT_MANIFEST_URL:
			return {"status": 200, "text": manifest, "network_error": false}
		if not url.begins_with(base + "/"):
			return {"status": 0, "text": "", "network_error": true}   # a host nobody here answers for
		var r := req.duplicate()
		r["url"] = url.substr(base.length())
		if fail_part != "" and String(r["url"]).contains(fail_part):
			return {"status": fail_status, "text": fail_text, "network_error": false}
		return mock.transport(r)


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var all_urls: Array[String] = []   ## every address any flow of this run asked for


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL front: " + what)


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	config_is_the_test_server()
	scan_shipped_files()
	var shim := Shim.new()
	shim.mock = DmOffline.make_mock("")   # memory only: no file, no server
	var api := make_api(shim)
	await boot_and_register(api, shim)
	await returning_player(api, shim)
	await hand_overs(api, shim)
	await unplayable_discipline(api, shim)
	await unreachable_and_failing(shim)
	await live_api_is_refused()
	await dev_entry_offline()
	await real_transport()
	await real_test_server()
	finish()


func finish() -> void:
	var unexpected := errlog.errors.size()
	check(unexpected == 0, "no script error or engine error in the log (%d: %s)" % [unexpected, "; ".join(errlog.errors.slice(0, 3))])
	for u in all_urls:
		check(DmConfig.allows_url(u) and not u.begins_with(LIVE_API), "a request the flows made stays on the test server: %s" % u.get_slice("?", 0))
	print("INFO front: %d requests made by the flows, all to the test API or the test channel's manifest" % all_urls.size())
	if fails == 0:
		print("PASS front (%d checks)" % checks)
		quit(0)
	else:
		printerr("FAIL front: %d of %d checks failed" % [fails, checks])
		quit(1)


# ------------------------------------------------------------------------------------------------------------------ helpers

func make_api(shim: Shim) -> DmApi:
	var api := DmApi.new(Callable(shim, "send"))
	api.slot_decorator = Callable(DmAffixes, "decorate_slots")
	return api


## The real boot scene on `api`: online mode, the game scene without waves and audio, the baked crowd of this test.
func boot(api: DmApi) -> DmMain:
	var m: DmMain = load("res://main/main.tscn").instantiate()
	m.mode = "online"
	m.api = api
	m.persist_token = false
	m.start_opts = {"audio": false, "seed": 20261016, "baked_dir": OUT, "waves": false}
	root.add_child(m)
	return m


func at(m: DmMain, screen: String) -> Callable:
	return func() -> bool: return m.slice == null and m.flow != null and m.flow.current_name == screen


func in_world(m: DmMain) -> Callable:
	return func() -> bool: return m.slice != null and m.slice.ready_ and DmLoadingScreen.current == null


## Frees a boot scene the way a quit would: the game scene leaves (its session closes), then everything goes.
func drop(m: DmMain, shim: Shim = null) -> void:
	if shim != null:
		all_urls.append_array(shim.urls)
		shim.urls.clear()
	if m.slice != null:
		var g := m.slice
		m.slice = null
		await g.leave()
		g.queue_free()
	m.queue_free()
	await until(func() -> bool: return DmLoadingScreen.current == null, 5.0)
	await process_frame
	await process_frame


# ------------------------------------------------------------------------------------------------------------------ the flows

## Boot -> login (no request yet) -> register -> the online gate -> character select -> a Mourner -> the game scene with that character.
func boot_and_register(api: DmApi, shim: Shim) -> void:
	var m := boot(api)
	check(await until(at(m, "login"), 10.0), "the boot reaches the login screen")
	check(m.flow != null and m.flow.current is DmLoginScreen, "the screen is today's login screen")
	check(shim.urls.is_empty(), "the login screen is up before any request is made")
	check(errlog.errors.is_empty(), "the boot logged no error (%s)" % "; ".join(errlog.errors.slice(0, 2)))
	check(m.flow.online_gate and not m.flow.standalone and not m.flow.dev_offline, "the online flow: the gate on, the online wording")
	var login: DmLoginScreen = m.flow.current
	login.toggle_mode()
	await process_frame
	check(login.email_edit != null and login.pass_edit != null, "the online card asks for a name, an email and a password")
	login.user_edit.text = PLAYER
	login.email_edit.text = PLAYER_MAIL
	login.pass_edit.text = PLAYER_PASS
	check(await login.submit(), "registering on the test server's stand-in succeeds")
	check(await until(at(m, "select"), 10.0), "a player with no character lands on character select")
	check(shim.urls.any(func(u: String) -> bool: return u.begins_with(DmConfig.CLIENT_MANIFEST_URL)), "the online gate read the TEST channel's manifest")
	check(not api.get_token().is_empty() and not api.get_token().begins_with("{"), "the session token is held by the api")
	var sel := m.flow.current as DmCharSelectScreen
	check(sel != null and sel.cards.size() == DmCharSelectScreen.load_disciplines().size() and sel.cards.size() >= 9, "character select shows every discipline card (%d)" % sel.cards.size())
	sel.benchmark_requested.emit()
	await process_frame
	var bench_win: Array = m.get_children().filter(func(c: Node) -> bool: return c is CanvasLayer and c.get_child_count() > 0 and c.get_child(0) is DmBenchmarkSetup)
	check(bench_win.size() == 1 and (bench_win[0].get_child(0) as DmBenchmarkSetup)._room.item_count == 1 and not m.flow.current.error_label.text.to_lower().contains("comes"),
		"the Benchmark button opens the benchmark's setup window (the Graves, the only room the client has)")
	if not bench_win.is_empty():
		(bench_win[0].get_child(0) as DmBenchmarkSetup).closed.emit()
		await process_frame
		check(m.get_children().filter(func(c: Node) -> bool: return c is CanvasLayer and c.get_child_count() > 0 and c.get_child(0) is DmBenchmarkSetup).is_empty() and m.flow.current == sel, "Back closes the window and the select screen is still there")
	var refused_pick := await sel.choose(5)
	check(not refused_pick and sel.error_label.text != "", "a discipline that is not playable is refused with a message")
	var picked := await sel.choose(3)
	check(picked, "picking the Mourner creates the character on the server")
	check(await until(in_world(m), 90.0), "the game scene runs after the pick")
	var g: DmNextGame = m.slice
	if g == null or not g.ready_:
		await drop(m, shim)
		return
	check(int(g.character["class_index"]) == 3 and int(g.character["id"]) > 0, "the game scene has the character the server returned (class %s, id %s)" % [g.character.get("class_index"), g.character.get("id")])
	var body := g.local_body()
	check(body != null and body.discipline_id == "mourner" and body.family == "necromancer", "the hero is a Mourner")
	check(g.session.discipline_id == "mourner" and g.session.character_name == PLAYER, "the session carries the discipline and the account's name")
	check(g.api == api and not g.is_offline, "the game holds the same api as the front flow: the session token travels with it")
	var bag: DmResult = await api.get_inventory(int(g.character["id"]))
	var prog: DmResult = await api.necro_get(int(g.character["id"]))
	check(bag.ok and prog.ok, "the server answers the bag and the progression")
	var want := DmCharacterBuild.build(g.character, bag.data, local_of(g.character, prog.data["progress"]))
	check(g.build_for(g.session.get_my_id()) == want, "the hero's build is made from the server's bag and progression")
	check(float(body.p["stats"]["maxHp"]) == float(want["stats"]["maxHp"]), "the hero's health is the build's (%s)" % body.p["stats"]["maxHp"])
	check(g.ui != null and g.core_host.core != null, "the game scene stands on the combat core with its HUD and panels")
	await drop(m, shim)


## The progression a DmProgression holds after adopting the server's: what DmMain.load_build hands the game.
func local_of(character: Dictionary, progress: Dictionary) -> Dictionary:
	var p := DmProgression.new(character)
	p.adopt(progress)
	return p.local


## A player with a kept login and a character skips the select; the gear in the server's bag is in the hero's stats and loadout.
func returning_player(api: DmApi, shim: Shim) -> void:
	var ch: DmResult = await api.get_character()
	var id := int(ch.data["id"])
	var plain: Dictionary = DmCharacterBuild.build(ch.data, [], {})
	var rows := [{"slot_index": 0, "item_id": "helm_copper", "quantity": 1, "equipped": 1}, {"slot_index": 1, "item_id": "staff_bone", "quantity": 1, "equipped": 1}]
	var saved: DmResult = await api.save_inventory(id, rows, 48)
	check(saved.ok, "a helm and a staff are worn in the server's bag (%s)" % saved.error)
	var m := boot(api)
	check(await until(in_world(m), 90.0), "a returning player goes straight from the boot into the game, with no select screen")
	check(m.flow == null, "the front flow is gone")
	var g: DmNextGame = m.slice
	if g == null or not g.ready_:
		await drop(m, shim)
		return
	var worn := g.server_slots.filter(func(r: Dictionary) -> bool: return int(r.get("equipped", 0)) != 0).map(func(r: Dictionary) -> String: return String(r["item_id"]))
	worn.sort()
	check(worn == ["helm_copper", "staff_bone"], "the worn gear came from the server's bag: %s" % [worn])
	var b := g.build_for(g.session.get_my_id())
	check(float(b["stats"]["maxHp"]) > float(plain["stats"]["maxHp"]), "the helm raises the hero's health (%s over %s)" % [b["stats"]["maxHp"], plain["stats"]["maxHp"]])
	check(float(g.local_body().p["stats"]["maxHp"]) == float(b["stats"]["maxHp"]), "the hero's body took that health")
	check(b["loadout"]["main"] == "staff" and b["loadout"]["mainTier"] == "bone", "the weapon line (the loadout) is the worn staff's")
	check(float(b["stats"]["spellPower"]) > float(plain["stats"]["spellPower"]), "the staff raises spell power")
	check(g.build_for(9999) == DmCharacterBuild.build({"class_index": 0, "level": 1}, [], {}), "someone else's build has no bag and no progression (no party in this step)")
	await drop(m, shim)


## The panels' hand-overs (DmMain, as today's; each saves first): a discipline change from the class panel restarts the game with the changed character, Switch character
## lands on the select screen with the same login, Log out on the login screen with none (the test logs in again for the cases after it).
func hand_overs(api: DmApi, shim: Shim) -> void:
	var m := boot(api)
	check(await until(in_world(m), 90.0), "hand-overs: a returning player is in the game")
	var g: DmNextGame = m.slice
	if g == null or not g.ready_:
		await drop(m, shim)
		return
	var first := g.get_instance_id()
	g.ui.pa._change_class(11)   # the class panel's pick: the server changes the character, then the game restarts with it
	check(await until(func() -> bool: return m.slice != null and m.slice.get_instance_id() != first and m.slice.ready_ and DmLoadingScreen.current == null, 90.0),
		"a discipline change from the class panel restarts the game")
	var hero := m.slice.local_body() if m.slice != null else null
	check(m.slice != null and int(m.slice.character["class_index"]) == 11 and hero != null and hero.discipline_id == "reaper" and hero.p.has("souls"),
		"the server changed the character and the hero is now a Reaper, with her soul bag")
	if m.slice == null:
		await drop(m, shim)
		return
	var token := api.get_token()
	m.slice.ui_host.switch_character()
	check(await until(at(m, "select"), 10.0), "Switch character lands on the select screen")
	check(api.get_token() == token, "with the same login")
	var sel := m.flow.current as DmCharSelectScreen if m.flow != null else null
	check(sel != null and await sel.choose(11), "picking the Reaper there ...")
	check(await until(in_world(m), 90.0), "... goes back into the game")
	if m.slice != null:
		m.slice.ui_host.leave_world()
	check(await until(at(m, "login"), 10.0) and api.get_token().is_empty(), "Log out lands on the login screen with no login kept")
	var back: DmResult = await api.login(PLAYER, PLAYER_PASS)
	check(back.ok, "logging in again for the next cases")
	if back.ok:
		api.set_token(back.data["token"])
	await drop(m, shim)


## An account whose character is a discipline that is not playable yet is sent to the discipline switch.
func unplayable_discipline(api: DmApi, shim: Shim) -> void:
	var ch: DmResult = await api.get_character()
	var changed: DmResult = await api.change_discipline(int(ch.data["id"]), 5)
	check(changed.ok and int(changed.data["class_index"]) == 5, "the stand-in's character is now a Grave Warden")
	var m := boot(api)
	check(await until(at(m, "select"), 10.0), "an unplayable discipline lands on character select")
	var sel := m.flow.current as DmCharSelectScreen
	check(sel != null and not sel.switching.is_empty() and m.slice == null, "it is the discipline switch, and no game started")
	var switched := await sel.choose(1)
	check(switched, "choosing the Ossuary switches the discipline")
	check(await until(in_world(m), 90.0), "the game starts with the switched character")
	check(m.slice != null and int(m.slice.character["class_index"]) == 1 and m.slice.local_body().discipline_id == "ossuary", "the hero is an Ossuary")
	await drop(m, shim)


## Today's player-readable errors: the server cannot be reached, answers an error, a stored login meets a closed door, the bag does not load.
func unreachable_and_failing(shim: Shim) -> void:
	# The login screen: unreachable, an error from the server, a failure page that is not JSON.
	var m := boot(make_api(shim))
	await until(at(m, "login"), 10.0)
	var login := m.flow.current as DmLoginScreen
	check(login != null, "the login screen is up for the failing server")
	login.user_edit.text = PLAYER
	login.pass_edit.text = PLAYER_PASS
	shim.down = true
	check(not await login.submit(), "signing in with the server unreachable fails")
	check(login.error_label.text == "Cannot reach server — check your connection", "unreachable: '%s'" % login.error_label.text)
	check(m.flow.current_name == "login" and m.slice == null, "and the player stays on the login screen")
	shim.down = false
	shim.fail_part = "/login"
	shim.fail_status = 503
	shim.fail_text = '{"error": "the Gate is being mended, try again soon"}'
	check(not await login.submit(), "signing in against a failing server fails")
	check(login.error_label.text == "The Gate is being mended, try again soon", "the server's own words, first letter capital: '%s'" % login.error_label.text)
	shim.fail_status = 502
	shim.fail_text = "<html>Bad Gateway</html>"
	check(not await login.submit(), "signing in against a gateway page fails")
	check(login.error_label.text == "Request failed: 502", "a reply without an error is 'Request failed: 502': '%s'" % login.error_label.text)
	shim.fail_part = ""
	await drop(m, shim)
	# A kept login, the server unreachable at boot: the online gate fails closed, the login screen says so.
	var api2 := make_api(shim)
	api2.set_token("a-kept-login")
	shim.down = true
	var m2 := boot(api2)
	check(await until(at(m2, "login"), 10.0), "a kept login with the server unreachable lands on the login screen")
	check(m2.flow.current is DmLoginScreen and (m2.flow.current as DmLoginScreen).error_label.text == DmOnlineGate.LOCKED_MESSAGE, "saying '%s'" % DmOnlineGate.LOCKED_MESSAGE)
	shim.down = false
	await drop(m2, shim)
	# The character is there but its bag will not load: back to the login screen with the server's words, no game, no token kept.
	var api3 := make_api(shim)
	var signed_in: DmResult = await api3.login(PLAYER, PLAYER_PASS)
	check(signed_in.ok, "the stand-in's player signs in")
	api3.set_token(signed_in.data["token"])
	shim.fail_part = "/api/inventory/"
	shim.fail_status = 500
	shim.fail_text = '{"error": "your bag is lost in the dark"}'
	var m3 := boot(api3)
	check(await until(at(m3, "login"), 20.0), "a bag that will not load sends the player back to the login screen")
	check(m3.slice == null and api3.get_token().is_empty(), "no game started and the login was dropped")
	check(m3.flow.current is DmLoginScreen and (m3.flow.current as DmLoginScreen).error_label.text == "Your bag is lost in the dark", "with the server's words on it")
	shim.fail_part = ""
	await drop(m3, shim)


## The API rule, the live side: an api whose address is the live one never gets a game (the real transport never sends it either: real_transport).
func live_api_is_refused() -> void:
	var shim := Shim.new()
	shim.mock = DmOffline.make_mock("")
	shim.base = LIVE_API
	var api := make_api(shim)
	api.base_url = LIVE_API
	var signed: DmResult = await api.register(PLAYER, PLAYER_MAIL, PLAYER_PASS)
	api.set_token(signed.data["token"])
	var made: DmResult = await api.load_or_create_character(2)
	check(made.ok, "(the stand-in made a character for the live-address api)")
	# This stand-in answers the live address, so only the second layer is under test here: the game scene refuses the live api, the boot drops the game and says why.
	var m := boot(api)
	var told := await until(func() -> bool: return m.flow != null and m.flow.current is DmLoginScreen and (m.flow.current as DmLoginScreen).error_label.text != "", 30.0)
	check(told, "an api on the live address ends on the login screen with a message")
	check(m.slice == null, "and no game is left running on it")
	if told:
		check((m.flow.current as DmLoginScreen).error_label.text == "This build plays on the test server only.", "'%s'" % (m.flow.current as DmLoginScreen).error_label.text)
	check(api.get_token().is_empty(), "the login was dropped")
	await drop(m)
	# The game scene itself, whatever the address looks like.
	for base in [LIVE_API, LIVE_API + "/", TEST_API + "/", TEST_API + "x", "http://muffindevelopment.com/death-muffin/test-api", "https://example.invalid/api"]:
		var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
		root.add_child(g)
		var a := DmApi.new(Callable(shim, "send"))
		a.base_url = base
		var why := [""]
		g.start_failed.connect(func(r: String) -> void: why[0] = r)
		await g.start({"class_index": 2, "level": 1, "id": 1}, a, {})
		check(why[0] != "" and not g.ready_, "DmNextGame.start refuses the api address '%s'" % base)
		g.queue_free()
	await process_frame


## The real transport: the live address is refused before any socket is opened, and says so in the log (the one error this suite expects).
func real_transport() -> void:
	var t := DmHttpTransport.new()
	root.add_child(t)
	var before := errlog.errors.size()
	var forbidden := [LIVE_API + "/api/health", LIVE_API, LIVE_LOBBY, TEST_API + "/../api/health", TEST_API + "/%2e%2e/api/health",
		"https://muffindevelopment.com/death-muffin/client/manifest.json", "https://muffindevelopment.com/death-muffin/", "https://example.invalid/"]
	for url in forbidden:
		var r: Dictionary = await t.send({"method": "GET", "url": url, "headers": {}, "body": ""})
		check(bool(r.get("network_error", false)) and int(r.get("status", -1)) == 0, "the real transport refuses %s" % url)
	var logged := errlog.errors.size() - before
	check(logged == forbidden.size(), "each refusal is logged once (%d of %d)" % [logged, forbidden.size()])
	errlog.errors.resize(before)   # expected
	check(t.get_child_count() == 0, "a refused request opened no HTTPRequest")
	t.queue_free()
	await process_frame


## The offline dev entry: a dev character on the local mock, no base url, no transport, no request.
func dev_entry_offline() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	check(api.base_url == "", "the dev api has no address")
	var m: DmMain = load("res://main/main.tscn").instantiate()
	m.mode = "test"
	m.api = api
	m.persist_token = false
	m.start_opts = {"audio": false, "seed": 20261016, "baked_dir": OUT, "waves": false}
	root.add_child(m)
	await m._dev_quick_start(2)
	check(await until(in_world(m), 90.0), "the dev quick start enters the game as a Gravecaller")
	if m.slice != null and m.slice.ready_:
		check(m.slice.is_offline and m.slice.local_body().discipline_id == "gravecaller" and m.slice.session.character_name == "tester", "the dev hero is a Gravecaller on the local mock")
		check(m._transport == null and root.find_children("*", "HTTPRequest", true, false).is_empty(), "no transport and no HTTP request node exists")
		check(m.slice.build_for(m.slice.session.get_my_id()) == DmCharacterBuild.build(m.slice.character, m.slice.server_slots, m.slice.server_local) and float(m.slice.local_body().p["stats"]["maxHp"]) > 0.0, "the dev character's build comes from the mock's bag, as the server's does")
	check(DmMain.mode_for(PackedStringArray(["--dev-offline"]), true) == "dev_offline" and DmMain.mode_for(PackedStringArray(["--dev-offline"]), false) == "online", "--dev-offline works in a debug build and a release build ignores it")
	check(DmMain.mode_for(PackedStringArray([]), true) == "online", "the default start is online (against the test server)")
	check(DmMain.quick_start_class(PackedStringArray(["--dev-offline", "--class=4"])) == 4, "--class=N is read")
	await drop(m)


# ------------------------------------------------------------------------------------------------------------------ the API rule

## What godot/net/dm_config.gd says today: the live addresses this client must never use.
func live_config() -> Dictionary:
	var path := ProjectSettings.globalize_path("res://").path_join("../godot/net/dm_config.gd").simplify_path()
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var re := RegEx.new()
	re.compile('(?m)^const (\\w+) := "([^"]*)"')
	for m in re.search_all(FileAccess.get_file_as_string(path)):
		out[m.get_string(1)] = m.get_string(2)
	return out


func config_is_the_test_server() -> void:
	var live := live_config()
	check(live.has("API_BASE") and live.has("LOBBY_URL") and live.has("SITE_BASE"), "godot/net/dm_config.gd (today's live config) was read")
	var live_api: String = live.get("API_BASE", LIVE_API)
	var live_lobby: String = live.get("LOBBY_URL", LIVE_LOBBY)
	var live_manifest: String = String(live.get("SITE_BASE", "")) + "client/manifest.json"
	check(live_api == LIVE_API and live_lobby == LIVE_LOBBY, "the live addresses are the ones this test knows (%s, %s): if they moved, update the test" % [live_api, live_lobby])
	var never := [live_api, live_lobby, live_manifest, LIVE_API, LIVE_LOBBY]
	check(DmConfig.API_BASE == TEST_API, "API_BASE is the test API: %s" % DmConfig.API_BASE)
	check(DmConfig.CLIENT_MANIFEST_URL == "https://muffindevelopment.com/death-muffin/client-test/manifest.json", "the manifest is the test channel's: %s" % DmConfig.CLIENT_MANIFEST_URL)
	for pair in [["API_BASE", DmConfig.API_BASE], ["SITE_BASE", DmConfig.SITE_BASE], ["CLIENT_MANIFEST_URL", DmConfig.CLIENT_MANIFEST_URL], ["PATCH_NOTES_URL", DmConfig.PATCH_NOTES_URL], ["LOBBY_URL", DmConfig.LOBBY_URL]]:
		for u in never:
			var v: String = pair[1]
			check(v != u and not v.begins_with(u), "DmConfig.%s is not the live address %s" % [pair[0], u])
	check(DmConfig.LOBBY_URL == TEST_LOBBY, "LOBBY_URL is the test lobby: %s" % DmConfig.LOBBY_URL)
	check(DmConfig.allows_lobby_url(TEST_LOBBY) and not DmConfig.allows_lobby_url(LIVE_LOBBY) and not DmConfig.allows_lobby_url(LIVE_LOBBY.trim_suffix("/")) and not DmConfig.allows_lobby_url("ws://muffindevelopment.com:5192"), "the lobby allow-list takes the test lobby and refuses the live one")
	check(DmConfig.allows_lobby_url("ws://127.0.0.1:45195") and DmConfig.allows_lobby_url("ws://localhost:5195/") and not DmConfig.allows_lobby_url("ws://127.0.0.1@example.invalid/") and not DmConfig.allows_lobby_url("wss://127.0.0.1:5195") and not DmConfig.allows_lobby_url(""), "and takes a lobby on this machine (a trial), not a lookalike")
	check(DmConfig.RELAY_PORT == 5196 and DmConfig.allows_relay("203.0.113.9", 5196) and not DmConfig.allows_relay("203.0.113.9", 5193) and not DmConfig.allows_relay("127.0.0.1", 5193) and DmConfig.allows_relay("127.0.0.1", 45196), "the relay is the test relay's port (5196) or one on this machine, never the live relay's (5193)")
	for u in never:
		check(not DmConfig.allows_url(u) and not DmConfig.allows_url(u + "/login") and not DmConfig.allows_url(u + "/api/health") and not DmConfig.allows_api_base(u), "the allow-list refuses %s" % u)
	for u in [TEST_API, TEST_API + "/login", TEST_API + "/api/health", DmConfig.CLIENT_MANIFEST_URL, DmConfig.CLIENT_MANIFEST_URL + "?t=1"]:
		check(DmConfig.allows_url(u), "the allow-list accepts %s" % u)
	for u in [TEST_API + "/../api/health", TEST_API + "/%2E%2e/api", TEST_API + "x/login", TEST_API + ".evil.invalid/login", "http://muffindevelopment.com/death-muffin/test-api/login", "HTTPS://MUFFINDEVELOPMENT.COM/death-muffin/test-api/login", "", "/login"]:
		check(not DmConfig.allows_url(u), "the allow-list refuses the lookalike '%s'" % u)
	check(DmConfig.allows_api_base("") and DmConfig.allows_api_base(TEST_API) and not DmConfig.allows_api_base(TEST_API + "/") and not DmConfig.allows_api_base("https://example.invalid/api"), "a base url is the test API or none (the local mock)")
	var api := DmApi.new()
	check(api.base_url == DmConfig.API_BASE and api.base_url == TEST_API, "a new DmApi's base url is the test API")
	check(api.site_base == DmConfig.SITE_BASE and not api.site_base.begins_with(LIVE_API), "and its site base is the test channel's folder")
	check(DmOffline.make_api(DmOffline.make_mock("")).base_url == "", "the dev backend's api has none")


## No shipped file names an address outside net/dm_config.gd, and none names the live API or lobby at all.
func scan_shipped_files() -> void:
	var files := PackedStringArray()
	_walk("res://", "", files)
	var url_re := RegEx.new()
	url_re.compile("(?i)(https?|wss?)://|muffindevelopment")
	var hits: Array[String] = []
	var live_hits: Array[String] = []
	for rel in files:
		var text := FileAccess.get_file_as_string("res://" + rel)
		if rel.ends_with(".gd"):
			text = _strip_comments(text)
		if text.contains("death-muffin/api") or text.contains("death-muffin/lobby"):
			live_hits.append(rel)
		if rel != "net/dm_config.gd" and url_re.search(text) != null:
			hits.append(rel)
	print("INFO front: %d shipped files scanned for addresses" % files.size())
	check(files.size() > 300, "the scan found the shipped files (%d)" % files.size())
	check(live_hits.is_empty(), "no shipped file names the live API or lobby: %s" % ", ".join(live_hits.slice(0, 5)))
	check(hits.is_empty(), "no shipped file names an address outside net/dm_config.gd: %s" % ", ".join(hits.slice(0, 5)))


func _walk(dir: String, rel: String, out: PackedStringArray) -> void:
	for d in DirAccess.get_directories_at(dir):
		var r := d if rel == "" else rel + "/" + d
		if SCAN_SKIP.has(d) or SCAN_SKIP.has(r):
			continue
		_walk(dir.path_join(d), r, out)
	for f in DirAccess.get_files_at(dir):
		if SCAN_EXT.has(f.get_extension()):
			out.append(f if rel == "" else rel + "/" + f)


## Source with every `# ...` comment cut off, string-aware (a '#' inside quotes stays).
func _strip_comments(text: String) -> String:
	var out := PackedStringArray()
	for line in text.split("\n"):
		var quote := ""
		var cut := -1
		var i := 0
		while i < line.length():
			var ch := line[i]
			if quote != "":
				if ch == "\\":
					i += 1
				elif ch == quote:
					quote = ""
			elif ch == '"' or ch == "'":
				quote = ch
			elif ch == "#":
				cut = i
				break
			i += 1
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)


# ------------------------------------------------------------------------------------------------------------------ the real test server

## The real client path (DmHttpTransport -> DmApi) against the real test server: its public health route and its manifest, with no credentials.
func real_test_server() -> void:
	var t := DmHttpTransport.new()
	root.add_child(t)
	var api := DmApi.new(t.request_callable())
	check(api.base_url == TEST_API and api.get_token() == "", "the real api points at the test API and holds no login")
	var pacing := [true]
	_pace(pacing)
	var h: DmResult = await api.health()
	if h.status == 0:
		pacing[0] = false
		print("SKIP front: the test server cannot be reached from here (%s, time scale %s); health and manifest not checked" % [h.error, Engine.time_scale])
	else:
		check(h.ok and h.data is Dictionary and h.data.get("status") == "ok", "the test server's /api/health answers ok (status %s)" % h.status)
		check(h.data is Dictionary and h.data.get("db") == "connected", "and its database is connected")
		var gate := DmOnlineGate.parse(await api.fetch_client_manifest())
		pacing[0] = false
		check(bool(gate["open"]) or bool(gate["staff"]), "the test channel's manifest lets the team in: online open %s, staff %s" % [gate["open"], gate["staff"]])
		print("INFO front: test server health %s, manifest online open=%s staff=%s" % [h.data.get("status"), gate["open"], gate["staff"]])
	t.queue_free()
	await process_frame


## Under --fixed-fps a frame is 1/60 s of game time however little real time it takes, and the transport's request timeout (30 s) runs on game time: slow the frames while the real
## server is asked, so a 150 ms answer is a few seconds of game time and not a timeout.
func _pace(flag: Array) -> void:
	while flag[0]:
		OS.delay_msec(4)
		await process_frame
