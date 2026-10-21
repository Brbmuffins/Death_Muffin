extends SceneTree
## The front flow of the rebuilt client (client/net/README.md), headless. The real boot scene (main/main.tscn, DmMain) runs
## the real front flow (login, character select, the online gate) and the real game scene, with an api that is the real DmApi (its default base url) over a recording
## transport that answers from today's mock backend. Nothing here uses a real account, a real token or the live server. It checks:
##   - the boot reaches the login screen, sends nothing yet, and logs no error;
##   - a new player registers, passes the online gate (the test channel's manifest), lands on character select, picks a Mourner and the game scene runs with THAT
##     character: its discipline, and a build made from the bag and the progression the server holds;
##   - a returning player (a login kept) skips the select, and the gear worn in the server's bag (a helm, a staff) is in the hero's stats and loadout;
##   - the panels' hand-overs: a discipline change from the class panel restarts the game with the changed character (a Reaper), Switch character lands on the select
##     screen with the same login and a pick goes back in, Log out lands on the login screen with no login kept;
##   - an account whose discipline is not playable is sent to the discipline switch (the same character, switched), every necromancer discipline picked on the select screen
##     enters the game with its body, the bag survives a log out (a queued sip reaches the server) and a quit (save_all), Settings -> Switch character is a real click that saves first,
##     a class change frees the old game, and three enter/leave cycles leave no leak;
##   - the front screens (DmFrontFlow) on their own: login and register copy, the server's errors verbatim, the select cards (recommended, order, portraits, greyed-out ones), a stale
##     token, the standalone (local) card, the token file; the launch arguments that pick the mode;
##   - THE API RULE (DECISIONS B38): every address the client can use resolves to the TEST server, never to the live API, live lobby or live manifest (read from
##     tests/fixtures/old_game/net/dm_config.gd.txt, the old game's config kept as text): the config, DmApi's default, every request the flows made, the allow-list of the transport and of the game scene, the real transport's
##     refusal of a live address, a front flow whose api is the live one (it ends on the login screen, saying why), and a scan of every shipped file for an address
##     outside net/dm_config.gd;
##   - an unreachable or failing server shows today's player-readable error (login, a stored login at boot, and the bag failing to load);
##   - the offline dev entry still works: a dev character on the local mock, no base url, no transport, no request;
##   - ZERO script errors or engine errors in the log (the one the transport logs for the refused live address is expected and counted).
## Gets the robber and the hound into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --path client --script res://tests/front.gd

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://front_test"
const BAKE := ["grave_robber", "bone_hound"]
## What this build talks to (the literals, so a change of net/dm_config.gd cannot move the test with it; also read from tests/fixtures/old_game/net/dm_config.gd.txt below) and what it never may:
## the test server, since launch day (2026-10-18).
const TEST_API := "https://muffindevelopment.com/death-muffin/test-api"
const LIVE_API := "https://muffindevelopment.com/death-muffin/api"
const LIVE_LOBBY := "wss://muffindevelopment.com/death-muffin/lobby/"
const TEST_LOBBY := "wss://muffindevelopment.com/death-muffin/test-lobby/"   # the test lobby of 2-player co-op (server/death-muffin/test-server/coop)
const TEST_MANIFEST := "https://muffindevelopment.com/death-muffin/client-test/manifest.json"
const NODE_BOUND := 60          ## nodes allowed to remain after 3 more enter/leave cycles than after the first
const MEM_BOUND_MB := 40.0      ## static memory growth allowed over the same cycles (shared VPS, GC noise)
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
var _ent: Array = []               ## enter_world signals of the flows made by make_flow


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
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	config_is_the_live_server()
	scan_shipped_files()
	asset_uids()
	var shim := Shim.new()
	shim.mock = DmOffline.make_mock("")   # memory only: no file, no server
	var api := make_api(shim)
	await boot_and_register(api, shim)
	await returning_player(api, shim)
	await hand_overs(api, shim)
	await each_discipline_and_bag(api, shim)
	await unplayable_discipline(api, shim)
	await unreachable_and_failing(shim)
	await front_screens()
	await test_api_is_refused()
	await dev_entry_offline()
	await real_transport()
	finish()


func finish() -> void:
	var unexpected := errlog.errors.size()
	check(unexpected == 0, "no script error or engine error in the log (%d: %s)" % [unexpected, "; ".join(errlog.errors.slice(0, 3))])
	for u in all_urls:
		check(DmConfig.allows_url(u) and not u.begins_with(TEST_API), "a request the flows made stays on the live server: %s" % u.get_slice("?", 0))
	print("INFO front: %d requests made by the flows, all to the live API or the live manifest" % all_urls.size())
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
	check(sel != null and sel.cards.size() == DmCharSelectScreen.load_disciplines().size() and sel.cards.size() > 0, "character select shows every discipline card (%d)" % sel.cards.size())
	sel.benchmark_requested.emit()
	await process_frame
	var bench_win: Array = m.get_children().filter(func(c: Node) -> bool: return c is CanvasLayer and c.get_child_count() > 0 and c.get_child(0) is DmBenchmarkSetup)
	check(bench_win.size() == 1 and (bench_win[0].get_child(0) as DmBenchmarkSetup)._room.item_count == DmBenchmark.ROOMS.size() and not m.flow.current.error_label.text.to_lower().contains("comes"),
		"the Benchmark button opens the benchmark's setup window (a row per room)")
	if not bench_win.is_empty():
		(bench_win[0].get_child(0) as DmBenchmarkSetup).closed.emit()
		await process_frame
		check(m.get_children().filter(func(c: Node) -> bool: return c is CanvasLayer and c.get_child_count() > 0 and c.get_child(0) is DmBenchmarkSetup).is_empty() and m.flow.current == sel, "Back closes the window and the select screen is still there")
	var locked_n := 0
	var locked_want := 0
	for c in sel.cards:
		var playable := DmCharacterBuild.is_playable(float(c.disc["classIndex"]))
		locked_want += 0 if playable else 1
		check(c.locked == not playable and (c.disabled or playable), "%s card %s" % [c.disc["id"], "open" if playable else "greyed out"])
		if c.locked:
			locked_n += 1
	check(locked_n == locked_want and locked_n > 0, "a greyed-out card for each discipline that is not playable (%d)" % locked_n)
	var unplayable_idx := -1   # the first discipline that is greyed out
	for c in sel.cards:
		if c.locked:
			unplayable_idx = int(c.disc["classIndex"])
			break
	var refused_pick := await sel.choose(unplayable_idx)
	check(not refused_pick and sel.error_label.text != "" and m.flow.current_name == "select", "a discipline that is not playable is refused with a message, and the select screen stays")
	var no_char: DmResult = await api.get_character()
	check(no_char.status == 404, "refusing created no character")
	var picked := await sel.choose(3)
	check(picked, "picking the Mourner creates the character on the server")
	check(await until(in_world(m), 90.0), "the game scene runs after the pick")
	var g: DmNextGame = m.slice
	if g == null or not g.ready_:
		await drop(m, shim)
		return
	check(int(g.character["class_index"]) == 3 and int(g.character["id"]) > 0 and int(g.character["level"]) == 1, "the game scene has the character the server returned (class %s, id %s, level %s)" % [g.character.get("class_index"), g.character.get("id"), g.character.get("level")])
	check(m.flow == null, "the front screens are gone once the game runs")
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
## The art pack's uids (DmPacks.register_asset_uids, the list tools/godot/asset-uids.py writes at export): a new id is registered with its path, a known
## one is left alone, and a missing or broken list changes nothing.
func asset_uids() -> void:
	var file := OUT.path_join("asset_uids.json")
	var fresh := ResourceUID.create_id()
	var known := ResourceUID.text_to_id(ResourceUID.path_to_uid("res://main/dm_packs.gd"))
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string(JSON.stringify({"res://assets/fake/made_up.png": str(fresh), "res://assets/fake/elsewhere.png": str(known), "res://assets/fake/bad.png": "x"}))
	f.close()
	check(DmPacks.register_asset_uids(file) == 1 and ResourceUID.has_id(fresh) and ResourceUID.get_id_path(fresh) == "res://assets/fake/made_up.png", "asset uids: a new id is registered with its path")
	check(ResourceUID.get_id_path(known) == "res://main/dm_packs.gd", "asset uids: an id Godot knows keeps its own path")
	ResourceUID.remove_id(fresh)
	check(DmPacks.register_asset_uids(OUT.path_join("none.json")) == 0, "asset uids: no list, nothing changes")
	f = FileAccess.open(file, FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	check(DmPacks.register_asset_uids(file) == 0, "asset uids: a broken list changes nothing")


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
	var saved: DmResult = await api.save_inventory(id, rows, DmLoot.bag_size())
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
	check(not is_instance_id_valid(first) or (instance_from_id(first) as Node).is_queued_for_deletion(), "a class change frees the old game")
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


# ------------------------------------------------------------------------------------------------------------------ discipline picks, the bag, Settings, leaks

func necro_indices() -> Dictionary:
	var out := {}
	for d in DmCharSelectScreen.load_disciplines():
		if String(DmCharacterBuild.discipline_for(float(d["classIndex"]))["family"]) == "necromancer":
			out[String(d["id"])] = int(d["classIndex"])
	return out


## A real click (move, press, release) on the centre of a control.
func click(c: Control) -> void:
	var vp := c.get_viewport()
	var at_px: Vector2 = vp.get_final_transform() * c.get_global_rect().get_center()   # window pixels (the UI is content-scaled)
	var mv := InputEventMouseMotion.new()
	mv.position = at_px
	mv.global_position = at_px
	vp.push_input(mv)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = at_px
		e.global_position = at_px
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		vp.push_input(e)


func find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text and (n as Button).is_visible_in_tree():
		return n
	for c in n.get_children():
		var r := find_button(c, text)
		if r != null:
			return r
	return null


func flasks_on_server(api: DmApi, cid: int) -> int:
	var total := 0
	for sl in (await api.get_inventory(cid)).data:
		if sl is Dictionary and String(sl.get("item_id", "")) == "flask_hp_minor":
			total += int(sl.get("quantity", 0))
	return total


## Put `n` more healing flasks in the hero's bag on the server (as a GM would: the bag is the server's) and show them. Returns the count.
func seed_flasks(g: DmNextGame, n: int) -> int:
	var cid := int(g.character["id"])
	var rows: Array = (await g.api.get_inventory(cid)).data.filter(func(r: Dictionary) -> bool: return int(r["slot_index"]) < DmLoot.bag_size())
	var used := {}
	for r in rows:
		used[int(r["slot_index"])] = true
	var free := DmLoot.bag_size() - 1
	while used.has(free):
		free -= 1
	rows.append({"slot_index": free, "item_id": "flask_hp_minor", "quantity": n})
	await g.api.save_inventory(cid, rows.map(func(r: Dictionary) -> Dictionary: return {"slot_index": int(r["slot_index"]), "item_id": r["item_id"], "quantity": int(r["quantity"]), "instance_id": r.get("instance_id")}), DmLoot.bag_size())
	await g.ui_host.refresh_inventory()
	return g.ui_host.inventory.count("flask_hp_minor")


## From the login screen: sign PLAYER in and wait for the game.
func sign_in(m: DmMain) -> void:
	await until(at(m, "login"), 10.0)
	var l := m.flow.current as DmLoginScreen
	l.user_edit.text = PLAYER
	l.pass_edit.text = PLAYER_PASS
	await l.submit()
	await until(in_world(m), 90.0)


func log_out(m: DmMain) -> void:
	m.slice.ui_host.leave_world()
	await until(at(m, "login"), 30.0)
	await process_frame


## Every necromancer discipline of the data is picked on the select screen (Switch character, then a card) and enters the game with that body; the bag survives a log out
## and a quit; Settings -> Switch character is a real click that saves first; three enter/leave cycles leak nothing.
func each_discipline_and_bag(api: DmApi, shim: Shim) -> void:
	var m := boot(api)
	check(await until(in_world(m), 90.0), "each discipline: a returning player is in the game")
	if m.slice == null or not m.slice.ready_:
		await drop(m, shim)
		return
	var necro := necro_indices()
	check(necro.size() > 0, "the data names necromancer disciplines (%s)" % str(necro.keys()))
	for id in necro:
		m.slice.ui_host.switch_character()
		check(await until(at(m, "select"), 30.0), "%s: Switch character lands on the select screen" % id)
		var sel := m.flow.current as DmCharSelectScreen if m.flow != null else null
		if sel == null:
			break
		await sel.choose(int(necro[id]))
		check(await until(in_world(m), 90.0), "%s: the game runs after the pick" % id)
		if m.slice == null:
			break
		var g: DmNextGame = m.slice
		check(int(g.character["class_index"]) == necro[id], "%s: character class %s" % [id, g.character.get("class_index")])
		check(g.local_body() != null and g.local_body().discipline_id == id, "%s: the body plays that discipline" % id)
		check(not g.is_offline and g.api == api and g.ui_host != null and g.ui_host.slots is Array and g.ui_host.character == g.character, "%s: HUD host holds the character and a bag, on the session's api" % id)
		check(m.flow == null, "%s: front screens gone" % id)
	if m.slice == null or not m.slice.ready_:
		await drop(m, shim)
		return
	# the bag: a sip queued at log out reaches the server (the client never saves its bag, DECISIONS B25), then a quit sends what is queued
	var g1: DmNextGame = m.slice
	var cid := int(g1.character["id"])
	var cls := int(g1.character["class_index"])
	var bag_before: int = g1.ui_host.slots.size()
	var flasks0 := await seed_flasks(g1, 4)
	check(g1.ui_host.inventory.consume("flask_hp_minor"), "a sip")
	await log_out(m)
	check(m.get_node_or_null("NextGame") == null, "log out frees the game")
	check(api.get_token().is_empty(), "log out clears the session")
	await sign_in(m)
	var g2: DmNextGame = m.slice
	check(g2 != null and int(g2.character["id"]) == cid and int(g2.character["class_index"]) == cls, "re-enter: same persisted character")
	check(g2 != null and g2.ui_host.inventory.count("flask_hp_minor") == flasks0 - 1 and g2.ui_host.slots.size() >= bag_before, "re-enter: the sip queued at log out reached the server")
	if g2 != null:
		check(g2.ui_host.inventory.consume("flask_hp_minor") and g2.ui_host.inventory.consume("flask_hp_minor"), "two more sips")
		await m.save_all()
		var total := await flasks_on_server(api, int(g2.character["id"]))
		check(total == flasks0 - 3, "quit: save_all sent the queued sips to the server (%d)" % total)
		m.slice = g2   # save_all detaches it; hand it back for the clean teardown
		await settings_switch(m, api, g2)
	# three enter/leave cycles: no growth
	await sign_in(m)   # (the refused-token case above ended on the login screen)
	await log_out(m)
	await process_frame
	var base := snap()
	for i in 3:
		await sign_in(m)
		check(in_world(m).call(), "cycle %d: entered" % (i + 1))
		await log_out(m)
	await process_frame
	await process_frame
	var after := snap()
	var dn: float = after["nodes"] - base["nodes"]
	var dm: float = after["mem"] - base["mem"]
	print("INFO front: leak probe: nodes %d -> %d (%+d), static mem %.1f -> %.1f MB (%+.1f)" % [base["nodes"], after["nodes"], dn, base["mem"], after["mem"], dm])
	check(dn <= NODE_BOUND, "3 cycles: node growth %+d <= %d" % [dn, NODE_BOUND])
	check(dm <= MEM_BOUND_MB, "3 cycles: static memory growth %+.1f MB <= %.0f" % [dm, MEM_BOUND_MB])
	# the login the later cases use
	await sign_in(m)
	await drop(m, shim)


func snap() -> Dictionary:
	return {"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "mem": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0}


## Settings -> Switch character, by a real click: saved first, the game freed, the select screen on the SAME token (no login screen); a card re-enters. A token the server refuses lands on login.
func settings_switch(m: DmMain, api: DmApi, g: DmNextGame) -> void:
	var tok := api.get_token()
	var cid := int(g.character["id"])
	var cls := int(g.character["class_index"])
	await DmTestBag.give(g.ui_host.inventory, {"item_id": "flask_hp_minor", "quantity": 1})
	var flasks := g.ui_host.inventory.count("flask_hp_minor")
	var old_size := root.size
	root.size = Vector2i(1280, 720)   # the headless window is tiny: the Settings window needs room for the click to land on it
	await process_frame
	g.ui.set_ui.open()
	await process_frame
	await process_frame
	var account: Button = g.ui.set_ui.panel._tabs["account"]["btn"]   # Switch character lives on the Account tab, beside Logout
	click(account)
	await process_frame
	await process_frame
	var btn := find_button(g.ui.set_ui.panel, DmUi.upper("Switch character"))
	check(btn != null and find_button(g.ui.set_ui.panel, DmUi.upper("Logout")) != null, "settings: Switch character sits beside Logout on the Account tab")
	if btn == null:
		root.size = old_size
		return
	await process_frame
	click(btn)
	await process_frame
	await until(at(m, "select"), 30.0)
	check(at(m, "select").call() and not (m.flow.current is DmLoginScreen), "switch character: the select screen, no login screen")
	check(m.get_node_or_null("NextGame") == null, "switch character: the game is freed")
	check(api.get_token() == tok and not tok.is_empty(), "switch character: the session token is kept")
	check(await flasks_on_server(api, cid) == flasks, "switch character: saved first (%d flasks on the server)" % flasks)
	var sel := m.flow.current as DmCharSelectScreen
	await sel.choose(cls)
	await until(in_world(m), 90.0)
	check(in_world(m).call() and api.get_token() == tok, "switch character: a card re-enters the world on the same token")
	# the server refuses the token: login, and the stored token is gone
	m.slice.ui_host.switch_character()
	await until(at(m, "select"), 30.0)
	api.set_token("not-a-token-the-server-knows")
	m.flow.switch_character()
	await until(at(m, "login"), 10.0)
	check(at(m, "login").call() and api.get_token() == "", "switch character: a refused token goes to login and is cleared")
	root.size = old_size


## An account whose character is a discipline that is not playable yet is sent to the discipline switch.
func unplayable_discipline(api: DmApi, shim: Shim) -> void:
	var ch: DmResult = await api.get_character()
	var char_id := int(ch.data["id"])
	var locked_disc: Dictionary = {}   # a discipline of the data that is not playable
	for d in DmCharSelectScreen.load_disciplines():
		if not DmCharacterBuild.is_playable(float(d["classIndex"])):
			locked_disc = d
			break
	check(not locked_disc.is_empty(), "the data has a discipline that is not playable")
	var locked_idx := int(locked_disc["classIndex"])
	var changed: DmResult = await api.change_discipline(int(ch.data["id"]), locked_idx)
	check(changed.ok and int(changed.data["class_index"]) == locked_idx, "the stand-in's character is now a %s" % String(locked_disc.get("name", locked_disc["id"])))
	var m := boot(api)
	check(await until(at(m, "select"), 10.0), "an unplayable discipline lands on character select")
	var sel := m.flow.current as DmCharSelectScreen
	check(sel != null and not sel.switching.is_empty() and m.slice == null, "it is the discipline switch, and no game started")
	var switched := await sel.choose(1)
	check(switched, "choosing the Ossuary switches the discipline")
	check(await until(in_world(m), 90.0), "the game starts with the switched character")
	check(m.slice != null and int(m.slice.character["class_index"]) == 1 and m.slice.local_body().discipline_id == "ossuary", "the hero is an Ossuary")
	check(m.slice != null and int(m.slice.character["id"]) == char_id, "the same character, now switched")
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


## DmFrontFlow login / register / discipline select on their own, against a fresh mock: no DmMain and no game scene, so cheap.
func fr(n: int = 2) -> void:
	for i in n:
		await process_frame


func make_flow(standalone: bool = false) -> Array:
	var fmock := DmMockBackend.new("")
	fmock.now_ms = func(): return 1700000000000
	var fapi := DmApi.new(fmock.transport_callable())
	fapi.base_url = ""
	var flow := DmFrontFlow.new(fapi, standalone, true)
	flow.persist_token = false
	root.add_child(flow)
	flow.enter_world.connect(func(c, s): _ent.append([c, s]))
	return [flow, fapi, fmock]


func front_screens() -> void:
	# ---- no token -> login
	var fa := make_flow()
	var flow: DmFrontFlow = fa[0]
	var api: DmApi = fa[1]
	await flow.start()
	await fr()
	check(flow.current_name == "login" and flow.current is DmLoginScreen, "start without token shows login")
	var login: DmLoginScreen = flow.current
	check(login.kicker_label.text == "THE GATE IS OPEN" and login.heading_label.text == "Return to the Covenant", "login copy")
	check(login.email_edit == null and login.pass_edit != null and login.pass_edit.secret, "login has name + secret password, no email")
	check(login.card.find_child("Note", true, false).text.begins_with("Offline dev mode"), "dev offline note")
	# ---- login fail: server string verbatim (first letter capitalised)
	login.user_edit.text = "nobody"
	login.pass_edit.text = "wrongpw"
	var ok := await login.submit()
	check(not ok and login.error_label.text == "Invalid username or password.", "login fail shows server error verbatim: " + login.error_label.text)
	check(api.get_token() == "" and login.submit_btn.disabled == false and login.submit_btn.text == "DESCEND", "failed login leaves no token, button restored")
	# ---- register validation error shown verbatim
	login.toggle_mode()
	await fr()
	check(login.mode == "register" and login.email_edit != null and login.heading_label.text == "Join the Covenant", "register mode fields")
	login.user_edit.text = "ab"
	login.email_edit.text = ""
	login.pass_edit.text = "x"
	ok = await login.submit()
	check(not ok and login.error_label.text == "Use a username of at least 3 characters and a password of at least 4.", "register validation error verbatim")
	# ---- register ok -> token -> resume -> no character (404) -> select
	login.user_edit.text = "tester"
	login.pass_edit.text = "pw1234"
	ok = await login.submit()
	await fr(4)
	var sel: DmCharSelectScreen = flow.current
	check(not sel.cards.is_empty() and sel.cards.size() == DmCharSelectScreen.load_disciplines().size(), "a card for each discipline of the data (%d)" % sel.cards.size())
	var rec := sel.cards.filter(func(c): return c.has_meta("recommended"))
	check(rec.size() == 1 and rec[0].disc["id"] == "gravecaller", "gravecaller recommended for first run")
	var want: Array = DmCharSelectScreen.load_disciplines().map(func(d: Dictionary) -> String: return String(d["id"]))
	var got: Array = sel.cards.map(func(c): return c.disc["id"])
	check(got == want, "card order matches PLAYABLE_DISCIPLINES")
	var art_ok := true
	for c in sel.cards:
		art_ok = art_ok and ResourceLoader.exists("res://front/art/" + String(c.disc["portrait"]).trim_prefix("art/"))
	check(art_ok, "every card's portrait is shipped under front/art")
	# ---- non-necro disciplines are greyed out until rebuilt (owner 2026-10-09): choosing one is refused
	var locked_idx := -1
	for d in sel.disciplines:
		if not DmCharacterBuild.is_playable(float(d["classIndex"])):
			locked_idx = int(d["classIndex"])
			break
	var refused := await sel.choose(locked_idx)
	check(locked_idx >= 0 and not refused and _ent.is_empty(), "a locked discipline cannot be chosen")
	# ---- create character (Rotweaver: a playable necro discipline that is not the recommended one)
	var cw_idx := -1
	for d in sel.disciplines:
		if d["id"] == "rotweaver":
			cw_idx = int(d["classIndex"])
	var picked := await sel.choose(cw_idx)
	await fr(3)
	check(picked and _ent.size() == 1, "choose emits enter_world once")
	if _ent.size() == 1:
		var ch: Dictionary = _ent[0][0]
		check(int(ch["class_index"]) == cw_idx and int(ch["level"]) == 1, "entered character is the created discipline")
		check(_ent[0][1] == api, "enter_world passes the authenticated session")
	check(flow.current == null, "front screens removed after entering the world")
	_ent.clear()
	# ---- choose() failure shows server error verbatim and re-enables the cards
	var fb := make_flow()
	var f3: DmFrontFlow = fb[0]
	var api3: DmApi = fb[1]
	var r := await api3.register("second", "", "pw1234")
	api3.set_token(r.data["token"])
	await f3.start()
	await fr()
	var sel3: DmCharSelectScreen = f3.current
	api3.set_token("offline:ghost")   # no such account: server refuses
	var res := await sel3.choose(2)
	check(not res and sel3.error_label.text != "" and sel3.cards[0].disabled == false, "choose failure: error shown, cards re-enabled: " + sel3.error_label.text)
	# ---- bad token on resume -> token cleared, login
	var fc := make_flow()
	var f4: DmFrontFlow = fc[0]
	(fc[1] as DmApi).set_token("offline:ghost")
	await f4.start()
	await fr()
	check(f4.current_name == "login" and (fc[1] as DmApi).get_token() == "", "stale token -> cleared, login")
	# ---- logout
	var out_n := [0]
	f4.logged_out.connect(func(): out_n[0] += 1)
	(fc[1] as DmApi).set_token("offline:x")
	f4.logout()
	await fr()
	check(out_n[0] == 1 and (fc[1] as DmApi).get_token() == "" and f4.current_name == "login", "logout clears token, signals, shows login")
	# ---- standalone (the local backend): local player, no email/password, fixed local password
	var fs := make_flow(true)
	var f5: DmFrontFlow = fs[0]
	await f5.start()
	await fr()
	var l5: DmLoginScreen = f5.current
	check(l5.kicker_label.text == "DEV OFFLINE MODE" and l5.heading_label.text == "Continue local game" and l5.pass_edit == null and l5.email_edit == null, "standalone login copy/fields")
	check(l5.submit_btn.text == "CONTINUE" and l5.toggle_btn.text == "Create a local player", "standalone buttons")
	l5.user_edit.text = "localdude"
	var created := await l5.submit()   # login first: unknown local player -> server error
	check(not created and l5.error_label.text == "Invalid username or password.", "standalone login unknown player error")
	l5.toggle_mode()
	await fr()
	check(l5.heading_label.text == "Create local player" and l5.submit_btn.text == "CREATE PLAYER", "standalone register copy")
	l5.user_edit.text = "localdude"
	created = await l5.submit()
	check(created and (fs[1] as DmApi).get_token() == "offline:localdude", "standalone create player (no password typed)")
	await fr(3)
	# ---- token persistence (user://dm_jwt.txt), cleared on logout
	var pm := DmMockBackend.new("")
	var papi := DmApi.new(pm.transport_callable())
	papi.base_url = ""
	papi.persist_token = true
	papi.set_token("offline:persist")
	check(FileAccess.file_exists(DmApi.TOKEN_FILE), "token persisted to user://")
	var papi2 := DmApi.new(pm.transport_callable())
	papi2.persist_token = true
	check(papi2.get_token() == "offline:persist", "persisted token reloads in a new session")
	papi.set_token("")
	check(not FileAccess.file_exists(DmApi.TOKEN_FILE), "logout removes the token file")


## The API rule, the test side: an api whose address is the test server's never gets a game (the real transport never sends it either: real_transport).
func test_api_is_refused() -> void:
	var shim := Shim.new()
	shim.mock = DmOffline.make_mock("")
	shim.base = TEST_API
	var api := make_api(shim)
	api.base_url = TEST_API
	var signed: DmResult = await api.register(PLAYER, PLAYER_MAIL, PLAYER_PASS)
	api.set_token(signed.data["token"])
	var made: DmResult = await api.load_or_create_character(2)
	check(made.ok, "(the stand-in made a character for the test-address api)")
	# This stand-in answers the test address, so only the second layer is under test here: the game scene refuses the test api, the boot drops the game and says why.
	var m := boot(api)
	var told := await until(func() -> bool: return m.flow != null and m.flow.current is DmLoginScreen and (m.flow.current as DmLoginScreen).error_label.text != "", 30.0)
	check(told, "an api on the test address ends on the login screen with a message")
	check(m.slice == null, "and no game is left running on it")
	if told:
		check((m.flow.current as DmLoginScreen).error_label.text == "This build plays on the live server only.", "'%s'" % (m.flow.current as DmLoginScreen).error_label.text)
	check(api.get_token().is_empty(), "the login was dropped")
	await drop(m)
	# The game scene itself, whatever the address looks like.
	for base in [TEST_API, TEST_API + "/", LIVE_API + "/", LIVE_API + "x", "http://muffindevelopment.com/death-muffin/api", "https://example.invalid/api"]:
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


## The real transport: the test server's addresses are refused before any socket is opened, and say so in the log (the one error this suite expects).
func real_transport() -> void:
	var t := DmHttpTransport.new()
	root.add_child(t)
	var before := errlog.errors.size()
	var forbidden := [TEST_API + "/api/health", TEST_API, TEST_LOBBY, LIVE_API + "/../test-api/api/health", LIVE_API + "/%2e%2e/test-api/api/health",
		TEST_MANIFEST, "https://muffindevelopment.com/death-muffin/test-lobby/", "https://example.invalid/"]
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
	check(DmMain.mode_for(PackedStringArray([]), true) == "online", "the default start is online (against the live server)")
	check(DmMain.quick_start_class(PackedStringArray(["--dev-offline", "--class=4"])) == 4, "--class=N is read")
	check(DmMain.mode_for(PackedStringArray(["--offline"])) == "online", "an old launcher's --offline starts online")
	check(DmMain.mode_for(PackedStringArray(["--online", "--next"])) == "online", "--online / --next = online")
	check(DmMain.mode_for(PackedStringArray(["--world-demo"]), false) == "online", "a release export ignores --world-demo")
	check(DmMain.token_username("offline:somebody") == "somebody", "token username")
	var necro := 0
	var necro_want := 0
	for d in DmCharSelectScreen.load_disciplines():
		var fam := String(DmCharacterBuild.discipline_for(float(d["classIndex"]))["family"])
		check(DmCharacterBuild.is_playable(float(d["classIndex"])) == (fam == "necromancer" or fam == "reaper"), "%s playable only if necromancer or reaper" % d["id"])
		if fam == "necromancer":
			necro += 1
		if String(d["family"]) == "necromancer":
			necro_want += 1
	check(necro > 0 and necro == necro_want, "the necromancer disciplines the data names are the ones the build treats as necromancers (%d)" % necro)
	await drop(m)


# ------------------------------------------------------------------------------------------------------------------ the API rule

## What the old game's net/dm_config.gd says (kept as text, a ".txt" added so Godot never parses it): the live addresses this client must use and never leave.
func live_config() -> Dictionary:
	var path := "res://tests/fixtures/old_game/net/dm_config.gd.txt"
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var re := RegEx.new()
	re.compile('(?m)^const (\\w+) := "([^"]*)"')
	for m in re.search_all(FileAccess.get_file_as_string(path)):
		out[m.get_string(1)] = m.get_string(2)
	return out


func config_is_the_live_server() -> void:
	var live := live_config()
	check(live.has("API_BASE") and live.has("LOBBY_URL") and live.has("SITE_BASE"), "tests/fixtures/old_game/net/dm_config.gd.txt (the old game's live config) was read")
	var live_api: String = live.get("API_BASE", "")
	var live_lobby: String = live.get("LOBBY_URL", "")
	var live_site: String = live.get("SITE_BASE", "")
	check(live_api == LIVE_API and live_lobby == LIVE_LOBBY, "the live addresses are the ones this test knows (%s, %s): if they moved, update the test" % [live_api, live_lobby])
	check(DmConfig.API_BASE == LIVE_API and DmConfig.API_BASE == live_api, "API_BASE is the live API: %s" % DmConfig.API_BASE)
	check(DmConfig.SITE_BASE == live_site and DmConfig.CLIENT_MANIFEST_URL == live_site + "client/manifest.json", "the manifest is the live one: %s" % DmConfig.CLIENT_MANIFEST_URL)
	check(DmConfig.PATCH_NOTES_URL == live_site + "play/patch-notes.json", "the patch notes are the live ones: %s" % DmConfig.PATCH_NOTES_URL)
	check(DmConfig.LOBBY_URL == LIVE_LOBBY and DmConfig.LOBBY_URL == live_lobby, "LOBBY_URL is the live lobby: %s" % DmConfig.LOBBY_URL)
	var never := [TEST_API, TEST_LOBBY, TEST_MANIFEST]
	for pair in [["API_BASE", DmConfig.API_BASE], ["SITE_BASE", DmConfig.SITE_BASE], ["CLIENT_MANIFEST_URL", DmConfig.CLIENT_MANIFEST_URL], ["PATCH_NOTES_URL", DmConfig.PATCH_NOTES_URL], ["LOBBY_URL", DmConfig.LOBBY_URL]]:
		for u in never:
			var v: String = pair[1]
			check(v != u and not v.begins_with(u), "DmConfig.%s is not the test address %s" % [pair[0], u])
	check(DmConfig.allows_lobby_url(LIVE_LOBBY) and not DmConfig.allows_lobby_url(TEST_LOBBY) and not DmConfig.allows_lobby_url(TEST_LOBBY.trim_suffix("/")) and not DmConfig.allows_lobby_url("ws://muffindevelopment.com:5195"), "the lobby allow-list takes the live lobby and refuses the test one")
	check(DmConfig.allows_lobby_url("ws://127.0.0.1:45195") and DmConfig.allows_lobby_url("ws://localhost:5195/") and not DmConfig.allows_lobby_url("ws://127.0.0.1@example.invalid/") and not DmConfig.allows_lobby_url("wss://127.0.0.1:5195") and not DmConfig.allows_lobby_url(""), "and takes a lobby on this machine (the local trial, the tests), nothing that only looks like one")
	check(DmConfig.RELAY_PORT == 5193 and DmConfig.allows_relay("203.0.113.9", 5193) and not DmConfig.allows_relay("203.0.113.9", 5196) and not DmConfig.allows_relay("127.0.0.1", 5196) and DmConfig.allows_relay("127.0.0.1", 45196), "the relay is the live relay's port (5193) or one on this machine, never the test relay's (5196)")
	for u in never:
		check(not DmConfig.allows_url(u) and not DmConfig.allows_url(u + "/login") and not DmConfig.allows_url(u + "/api/health") and not DmConfig.allows_api_base(u), "the allow-list refuses %s" % u)
	for u in [LIVE_API, LIVE_API + "/login", LIVE_API + "/api/health", DmConfig.CLIENT_MANIFEST_URL, DmConfig.CLIENT_MANIFEST_URL + "?t=1", DmConfig.PATCH_NOTES_URL]:
		check(DmConfig.allows_url(u), "the allow-list accepts %s" % u)
	for u in [LIVE_API + "/../test-api/api/health", LIVE_API + "/%2E%2e/test-api", "https://muffindevelopment.com/death-muffin/test-api/login", "http://muffindevelopment.com/death-muffin/api/login", "HTTPS://MUFFINDEVELOPMENT.COM/death-muffin/api/login", "https://muffindevelopment.com.evil.invalid/death-muffin/api/login", "", "/login"]:
		check(not DmConfig.allows_url(u), "the allow-list refuses the lookalike '%s'" % u)
	check(DmConfig.allows_api_base("") and DmConfig.allows_api_base(LIVE_API) and not DmConfig.allows_api_base(LIVE_API + "/") and not DmConfig.allows_api_base(TEST_API) and not DmConfig.allows_api_base("https://example.invalid/api"), "a base url is the live API or none (the local mock)")
	var api := DmApi.new()
	check(api.base_url == DmConfig.API_BASE and api.base_url == LIVE_API, "a new DmApi's base url is the live API")
	check(api.site_base == DmConfig.SITE_BASE and not api.site_base.contains("client-test"), "and its site base is the site's root")
	check(DmOffline.make_api(DmOffline.make_mock("")).base_url == "", "the dev backend's api has none")


## No shipped file names an address outside net/dm_config.gd, and none but that file names the test server at all.
func scan_shipped_files() -> void:
	var files := PackedStringArray()
	_walk("res://", "", files)
	var url_re := RegEx.new()
	url_re.compile("(?i)(https?|wss?)://|muffindevelopment")
	var hits: Array[String] = []
	var test_hits: Array[String] = []
	for rel in files:
		var text := FileAccess.get_file_as_string("res://" + rel)
		if rel.ends_with(".gd"):
			text = _strip_comments(text)
		if rel != "net/dm_config.gd" and (text.contains("death-muffin/test-api") or text.contains("death-muffin/test-lobby") or text.contains("death-muffin/client-test")):
			test_hits.append(rel)
		if rel != "net/dm_config.gd" and url_re.search(text) != null:
			hits.append(rel)
	print("INFO front: %d shipped files scanned for addresses" % files.size())
	check(files.has("net/dm_config.gd") and files.size() > 1, "the scan found the shipped files, the config among them (%d)" % files.size())
	check(test_hits.is_empty(), "no shipped file names the test server: %s" % ", ".join(test_hits.slice(0, 5)))
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
