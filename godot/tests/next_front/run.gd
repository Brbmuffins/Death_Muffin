extends SceneTree
## Front-flow suite (godot/main/main.gd): godot --headless --path godot --script res://tests/next_front/run.gd
## DmMain on the offline backend (in-memory mock): register -> discipline select -> DmNextGame for every necromancer discipline, log out,
## log in (persisted), quit save, class change, and 3 enter/leave cycles measured for leaks. Also folds in the DmFrontFlow screens (formerly tests/front) and the shipped entry flow incl. launch args and the unplayable-discipline switch (formerly tests/game/flow_run).

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, _bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s" % [file.get_file(), line, code, rationale])

const NODE_BOUND := 60          ## nodes allowed to remain after 3 more enter/leave cycles than after the first
const MEM_BOUND_MB := 40.0      ## static memory growth allowed over the same cycles (shared VPS, GC noise)

var passed := 0
var failed := 0
var log_ := ErrLog.new()
var api: DmApi
var mock: DmMockBackend
var m: DmMain


func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)

func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func _in_world() -> bool:
	return m.slice != null and m.slice.ready_ and DmLoadingScreen.current == null

func _at(screen: String) -> bool:
	return m.slice == null and m.flow != null and m.flow.current_name == screen

func _new_main() -> DmMain:
	var n := DmMain.new()
	n.mode = "test"
	n.persist_token = false
	n.api = api
	root.add_child(n)
	return n

## Register a local player on the login screen and pick a discipline; returns once the rebuild is live.
func _register_and_pick(name_: String, class_index: int) -> void:
	await until(func() -> bool: return _at("login"), 10.0)
	var l: DmLoginScreen = m.flow.current
	l.toggle_mode()
	await process_frame
	l.user_edit.text = name_
	var ok := await l.submit()
	if not ok:
		print("register failed: ", l.error_label.text)
	await until(func() -> bool: return _at("select"), 10.0)
	var sel: DmCharSelectScreen = m.flow.current as DmCharSelectScreen
	if sel == null:
		return
	await sel.choose(class_index)
	await until(_in_world, 60.0)

func _login(name_: String) -> void:
	await until(func() -> bool: return _at("login"), 10.0)
	var l: DmLoginScreen = m.flow.current
	l.user_edit.text = name_
	await l.submit()
	await until(_in_world, 60.0)

func _logout() -> void:
	m.slice.ui_host.leave_world()
	await until(func() -> bool: return _at("login"), 30.0)
	await process_frame

func _necro_indices() -> Dictionary:
	var out := {}
	for d in DmCharSelectScreen.load_disciplines():
		var full: Dictionary = DmCharacterBuild.discipline_for(float(d["classIndex"]))
		if String(full["family"]) == "necromancer":
			out[String(d["id"])] = int(d["classIndex"])
	return out

func _snap() -> Dictionary:
	return {"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "mem": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0}



var _ent: Array = []

func _fr(n: int = 2) -> void:
	for i in n:
		await process_frame

func _make_flow(standalone: bool = false) -> Array:
	var fmock := DmMockBackend.new("")
	fmock.now_ms = func(): return 1700000000000
	var fapi := DmApi.new(fmock.transport_callable())
	fapi.base_url = ""
	var flow := DmFrontFlow.new(fapi, standalone, true)
	flow.persist_token = false
	root.add_child(flow)
	flow.enter_world.connect(func(c, s): _ent.append([c, s]))
	return [flow, fapi, fmock]

## DmFrontFlow login / register / discipline select against a fresh mock (formerly tests/front): no DmNextGame, so cheap.

func _front_screens() -> void:
	# ---- no token -> login
	var fa := _make_flow()
	var flow: DmFrontFlow = fa[0]
	var api: DmApi = fa[1]
	await flow.start()
	await _fr()
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
	await _fr()
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
	check(ok and api.get_token() == "offline:tester", "register returns + stores token")
	await _fr(4)
	check(flow.current_name == "select" and flow.current is DmCharSelectScreen, "no character -> discipline select")
	var sel: DmCharSelectScreen = flow.current
	check(sel.cards.size() == 10, "ten discipline cards")
	var rec := sel.cards.filter(func(c): return c.has_meta("recommended"))
	check(rec.size() == 1 and rec[0].disc["id"] == "gravecaller", "gravecaller recommended for first run")
	var want := ["ossuary", "gravecaller", "mourner", "rotweaver", "grave_warden", "bell_monk", "carrion_witch", "hollow_knight", "veilwalker", "reaper"]
	var got: Array = sel.cards.map(func(c): return c.disc["id"])
	check(got == want, "card order matches PLAYABLE_DISCIPLINES")
	var art_ok := true
	for c in sel.cards:
		art_ok = art_ok and ResourceLoader.exists("res://front/art/" + String(c.disc["portrait"]).trim_prefix("art/"))
	check(art_ok, "all ten portraits shipped under front/art")
	# ---- non-necro disciplines are greyed out until rebuilt (owner 2026-10-09): choosing one is refused
	var locked_idx := -1
	for d in sel.disciplines:
		if d["id"] == "carrion_witch":
			locked_idx = int(d["classIndex"])
	var refused := await sel.choose(locked_idx)
	check(not refused and _ent.is_empty(), "locked discipline (Carrion Witch) cannot be chosen")
	# ---- create character (Rotweaver: a playable necro discipline that is not the recommended one)
	var cw_idx := -1
	for d in sel.disciplines:
		if d["id"] == "rotweaver":
			cw_idx = int(d["classIndex"])
	var picked := await sel.choose(cw_idx)
	await _fr(3)
	check(picked and _ent.size() == 1, "choose emits enter_world once")
	if _ent.size() == 1:
		var ch: Dictionary = _ent[0][0]
		check(int(ch["class_index"]) == cw_idx and int(ch["level"]) == 1, "entered character is the created discipline")
		check(_ent[0][1] == api, "enter_world passes the authenticated session")
	check(flow.current == null, "front screens removed after entering the world")
	# ---- list / existing character: a fresh flow with the stored token resumes straight into the world
	_ent.clear()
	var flow2 := DmFrontFlow.new(api, false, true)
	flow2.persist_token = false
	root.add_child(flow2)
	flow2.enter_world.connect(func(c, s): _ent.append([c, s]))
	await flow2.start()
	check(_ent.size() == 1 and int(_ent[0][0]["class_index"]) == cw_idx, "existing character -> straight to world")
	flow2.queue_free()
	# ---- choose() failure shows server error verbatim and re-enables the cards
	var fb := _make_flow()
	var f3: DmFrontFlow = fb[0]
	var api3: DmApi = fb[1]
	var r := await api3.register("second", "", "pw1234")
	api3.set_token(r.data["token"])
	await f3.start()
	await _fr()
	var sel3: DmCharSelectScreen = f3.current
	api3.set_token("offline:ghost")   # no such account: server refuses
	var res := await sel3.choose(2)
	check(not res and sel3.error_label.text != "" and sel3.cards[0].disabled == false, "choose failure: error shown, cards re-enabled: " + sel3.error_label.text)
	# ---- bad token on resume -> token cleared, login
	var fc := _make_flow()
	var f4: DmFrontFlow = fc[0]
	(fc[1] as DmApi).set_token("offline:ghost")
	await f4.start()
	await _fr()
	check(f4.current_name == "login" and (fc[1] as DmApi).get_token() == "", "stale token -> cleared, login")
	# ---- logout
	var out_n := [0]
	f4.logged_out.connect(func(): out_n[0] += 1)
	(fc[1] as DmApi).set_token("offline:x")
	f4.logout()
	await _fr()
	check(out_n[0] == 1 and (fc[1] as DmApi).get_token() == "" and f4.current_name == "login", "logout clears token, signals, shows login")
	# ---- standalone (offline edition): local player, no email/password, fixed local password
	var fs := _make_flow(true)
	var f5: DmFrontFlow = fs[0]
	await f5.start()
	await _fr()
	var l5: DmLoginScreen = f5.current
	check(l5.kicker_label.text == "DEV OFFLINE MODE" and l5.heading_label.text == "Continue local game" and l5.pass_edit == null and l5.email_edit == null, "standalone login copy/fields")
	check(l5.submit_btn.text == "CONTINUE" and l5.toggle_btn.text == "Create a local player", "standalone buttons")
	l5.user_edit.text = "localdude"
	var created := await l5.submit()   # login first: unknown local player -> server error
	check(not created and l5.error_label.text == "Invalid username or password.", "standalone login unknown player error")
	l5.toggle_mode()
	await _fr()
	check(l5.heading_label.text == "Create local player" and l5.submit_btn.text == "CREATE PLAYER", "standalone register copy")
	l5.user_edit.text = "localdude"
	created = await l5.submit()
	check(created and (fs[1] as DmApi).get_token() == "offline:localdude", "standalone create player (no password typed)")
	await _fr(3)
	check(f5.current_name == "select", "standalone -> select")
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


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f = null

## Poll a condition (result ignored): a frame-count cap flaked when threaded loads lag on a loaded VPS.
func until_ign(cond: Callable, sec: float) -> void:
	await until(cond, sec)

## The shipped entry flow (formerly tests/game/flow_run): launch args -> mode, the retired offline edition wiped on an online start, main scene ->
## login -> select (4 necromancer cards open, 5 greyed out and refused), an unplayable-discipline character -> the discipline switch -> the game.
func _entry_flow() -> void:
	# ---- launch args: one online game; only testing flags reach the local backend
	check(DmMain.mode_for(PackedStringArray()) == "online", "no args = online")
	check(DmMain.mode_for(PackedStringArray(["--offline"])) == "online", "an old launcher's --offline starts online")
	check(DmMain.mode_for(PackedStringArray(["--online", "--next"])) == "online", "--online / --next = online")
	check(DmMain.mode_for(PackedStringArray(["--dev-offline"])) == "dev_offline", "--dev-offline = the testing backend")
	check(DmMain.DEV_OFFLINE_DB != DmMain.OFFLINE_EDITION_DB, "dev-offline never reuses the player's old offline save")
	# ---- the retired offline edition is wiped (its save, its tmp file and an "offline:" token); an online token is kept
	_write(DmMain.OFFLINE_EDITION_DB, "{}")
	_write(DmMain.OFFLINE_EDITION_DB + ".tmp", "{}")
	_write(DmApi.TOKEN_FILE, "offline:olduser")
	DmMain.wipe_offline_edition()
	check(not FileAccess.file_exists(DmMain.OFFLINE_EDITION_DB) and not FileAccess.file_exists(DmMain.OFFLINE_EDITION_DB + ".tmp"), "offline edition save deleted")
	check(not FileAccess.file_exists(DmApi.TOKEN_FILE), "offline session token deleted")
	_write(DmApi.TOKEN_FILE, "aaa.bbb.ccc")
	DmMain.wipe_offline_edition()
	check(FileAccess.file_exists(DmApi.TOKEN_FILE), "an online session token is kept")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DmApi.TOKEN_FILE))
	# ---- playable disciplines
	var necro := 0
	for d in DmCharSelectScreen.load_disciplines():
		var fam := String(DmCharacterBuild.discipline_for(float(d["classIndex"]))["family"])
		check(DmCharacterBuild.is_playable(float(d["classIndex"])) == (fam == "necromancer" or fam == "reaper"), "%s playable only if necromancer or reaper" % d["id"])
		if fam == "necromancer":
			necro += 1
	check(necro == 4, "four playable necromancer disciplines (%d)" % necro)
	# ---- main scene: login -> select
	var main2: DmMain = load("res://main/main.tscn").instantiate()
	main2.mode = "dev_offline"
	main2.persist_token = false
	root.add_child(main2)
	await _fr(10)
	await until_ign(func() -> bool: return main2.flow != null and main2.flow.current_name == "login", 30.0)
	check(main2.flow != null and main2.flow.current_name == "login", "the login screen shows first: %s" % (main2.flow.current_name if main2.flow != null else "-"))
	var uname := "flow%d" % (Time.get_ticks_usec() % 1000000)
	var r := await main2.api.register(uname, "f@example.com", "pw1234")
	check(r.ok, "registered")
	main2.api.set_token(r.data["token"])
	await main2.flow.resume()
	check(main2.flow.current_name == "select", "a new account goes to discipline select: %s" % main2.flow.current_name)
	var sel: DmCharSelectScreen = main2.flow.current as DmCharSelectScreen
	var locked := 0
	for c in sel.cards:
		var playable := DmCharacterBuild.is_playable(float(c.disc["classIndex"]))
		check(c.locked == not playable and (c.disabled or playable), "%s card %s" % [c.disc["id"], "open" if playable else "greyed out"])
		if c.locked:
			locked += 1
	check(locked == 5, "five greyed-out cards (%d)" % locked)
	check(not await sel.choose(5) and main2.flow.current_name == "select", "a greyed-out discipline is refused")
	var gr := await main2.api.get_character()
	check(gr.status == 404, "refusing created no character")
	# ---- a character of a discipline that is not playable yet (an existing online one): resume -> the discipline switch
	var c5 := await main2.api.load_or_create_character(5)
	check(c5.ok and int(c5.data["class_index"]) == 5, "an old Grave Warden character exists")
	await main2.flow.resume()
	sel = main2.flow.current as DmCharSelectScreen
	check(main2.flow.current_name == "select" and sel != null and not sel.switching.is_empty(), "resume offers the discipline switch")
	check(main2.slice == null, "no game built for an unplayable discipline")
	if sel != null:
		await sel.choose(2)
	await until_ign(func() -> bool: return main2.slice != null and main2.slice.ready_ and DmLoadingScreen.current == null, 60.0)
	check(main2.slice != null and main2.slice.ready_, "after the switch the game is up")
	if main2.slice != null:
		var ch: Dictionary = main2.slice.character
		check(int(ch["class_index"]) == 2 and int(ch["id"]) == int(c5.data["id"]), "same character, now a Gravecaller (%s)" % ch.get("class_index"))
		check(DmMain.token_username("offline:" + uname) == uname, "token username")
		main2.slice.ui_host.leave_world()
	await until_ign(func() -> bool: return main2.slice == null and main2.flow != null and main2.flow.current_name == "login", 30.0)
	check(main2.slice == null and main2.flow != null, "Leave returns to the login screen")
	main2.queue_free()
	await process_frame


func _run() -> void:
	OS.add_logger(log_)
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	m = _new_main()
	# ---- every necromancer discipline: register -> select -> the rebuild with that character
	var necro := _necro_indices()
	check(necro.size() == 4 and necro.has("ossuary") and necro.has("gravecaller") and necro.has("mourner") and necro.has("rotweaver"), "four necromancer disciplines (%s)" % str(necro.keys()))
	var n := 0
	var flasks0 := 0
	for id in necro:
		n += 1
		var who := "necro%d" % n
		await _register_and_pick(who, necro[id])
		check(_in_world(), "%s: the rebuild is live behind the front (%s)" % [id, who])
		if not _in_world():
			break
		var g: DmNextGame = m.slice
		var ch := g.character
		check(int(ch["class_index"]) == necro[id] and int(ch["level"]) == 1, "%s: character class %s level %s" % [id, ch.get("class_index"), ch.get("level")])
		check(g.local_body() != null and g.local_body().discipline_id == id, "%s: the body plays that discipline" % id)
		check(g.is_offline and g.api == api and api.get_token() == "offline:" + who, "%s: offline backend, authenticated session" % id)
		check(g.ui_host != null and g.ui_host.slots is Array and g.ui_host.character == ch, "%s: HUD host holds the character and a bag" % id)
		check(m.flow == null, "%s: front screens gone" % id)
		var bag_before: int = g.ui_host.slots.size()
		if n == 1:
			# persistence: a bag item + gold survive log out -> log in
			flasks0 = g.ui_host.inventory.count("flask_hp_minor")
			g.ui_host.inventory.add({"item_id": "flask_hp_minor", "quantity": 2})
			ch["gold"] = int(ch.get("gold", 0)) + 0   # gold is credited by the rewards; the bag is what this probes
		await _logout()
		check(m.get_node_or_null("NextGame") == null, "%s: log out frees the rebuild" % id)
		check(api.get_token() == "", "%s: log out clears the session" % id)
		if n == 1:
			await _login(who)
			var g2: DmNextGame = m.slice
			check(g2 != null and int(g2.character["id"]) == int(ch["id"]) and int(g2.character["class_index"]) == necro[id], "re-enter: same persisted character")
			check(g2 != null and g2.ui_host.inventory.count("flask_hp_minor") == flasks0 + 2 and g2.ui_host.slots.size() >= bag_before, "re-enter: the bag item persisted through the log out flush")
			# quit saves
			g2.ui_host.inventory.add({"item_id": "flask_hp_minor", "quantity": 3})
			await m.save_all()
			var inv := await api.get_inventory(int(g2.character["id"]))
			var total := 0
			for s in inv.data:
				if s is Dictionary and String(s.get("item_id", "")) == "flask_hp_minor":
					total += int(s.get("quantity", 0))
			check(total == flasks0 + 5, "quit: save_all flushed the bag to the backend (%d)" % total)
			m.slice = g2   # save_all detaches it; hand it back for the clean log out
			await _logout()
	# ---- 3 enter/leave cycles: no growth
	await _login("necro1")
	# class change (the panel's hand-off): the rebuild is torn down and re-entered with the new character, no front screen in between
	var before: int = m.slice.get_instance_id()
	m.slice.ui_host.class_changed(m.slice.character)
	await until(func() -> bool: return _in_world() and m.slice.get_instance_id() != before, 60.0)
	check(_in_world() and m.slice.get_instance_id() != before, "class change re-enters a fresh rebuild")
	await process_frame
	check(not is_instance_id_valid(before) or (instance_from_id(before) as Node).is_queued_for_deletion(), "class change frees the old rebuild")
	await _logout()
	await process_frame
	var base := _snap()
	for i in 3:
		await _login("necro1")
		check(_in_world(), "cycle %d: entered" % (i + 1))
		await _logout()
	await process_frame
	await process_frame
	var after := _snap()
	var dn: float = after["nodes"] - base["nodes"]
	var dm: float = after["mem"] - base["mem"]
	print("leak probe: nodes %d -> %d (%+d), static mem %.1f -> %.1f MB (%+.1f)" % [base["nodes"], after["nodes"], dn, base["mem"], after["mem"], dm])
	check(dn <= NODE_BOUND, "3 cycles: node growth %+d <= %d" % [dn, NODE_BOUND])
	check(dm <= MEM_BOUND_MB, "3 cycles: static memory growth %+.1f MB <= %.0f" % [dm, MEM_BOUND_MB])
	m.queue_free()
	await process_frame
	await _front_screens()
	await _entry_flow()
	root.size = Vector2i(480, 800)   # layout sanity at phone width does not error
	await _fr(3)
	check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), ", ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)

