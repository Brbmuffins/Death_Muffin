extends SceneTree
## Front-end flow tests (headless, DmApi + DmMockBackend):  godot --headless --path godot --script res://tests/front/run.gd

var _pass := 0
var _fail := 0
var _entered: Array = []


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _frames(n: int = 2) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func _make_flow(standalone: bool = false) -> Array:
	var mock := DmMockBackend.new("")
	mock.now_ms = func(): return 1700000000000
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var flow := DmFrontFlow.new(api, standalone, true)
	flow.persist_token = false
	root.add_child(flow)
	flow.enter_world.connect(func(c, s): _entered.append([c, s]))
	return [flow, api, mock]


func _run() -> void:
	var tok_file := ProjectSettings.globalize_path(DmApi.TOKEN_FILE)
	var had_tok := FileAccess.file_exists(DmApi.TOKEN_FILE)
	# ---- no token -> login
	var fa := _make_flow()
	var flow: DmFrontFlow = fa[0]
	var api: DmApi = fa[1]
	await flow.start()
	await _frames()
	_check(flow.current_name == "login" and flow.current is DmLoginScreen, "start without token shows login")
	var login: DmLoginScreen = flow.current
	_check(login.kicker_label.text == "THE GATE IS OPEN" and login.heading_label.text == "Return to the Covenant", "login copy")
	_check(login.email_edit == null and login.pass_edit != null and login.pass_edit.secret, "login has name + secret password, no email")
	_check(login.card.find_child("Note", true, false).text.begins_with("Offline dev mode"), "dev offline note")
	# ---- login fail: server string verbatim (first letter capitalised)
	login.user_edit.text = "nobody"
	login.pass_edit.text = "wrongpw"
	var ok := await login.submit()
	_check(not ok and login.error_label.text == "Invalid username or password.", "login fail shows server error verbatim: " + login.error_label.text)
	_check(api.get_token() == "" and login.submit_btn.disabled == false and login.submit_btn.text == "DESCEND", "failed login leaves no token, button restored")
	# ---- register validation error shown verbatim
	login.toggle_mode()
	await _frames()
	_check(login.mode == "register" and login.email_edit != null and login.heading_label.text == "Join the Covenant", "register mode fields")
	login.user_edit.text = "ab"
	login.email_edit.text = ""
	login.pass_edit.text = "x"
	ok = await login.submit()
	_check(not ok and login.error_label.text == "Use a username of at least 3 characters and a password of at least 4.", "register validation error verbatim")
	# ---- register ok -> token -> resume -> no character (404) -> select
	login.user_edit.text = "tester"
	login.pass_edit.text = "pw1234"
	ok = await login.submit()
	_check(ok and api.get_token() == "offline:tester", "register returns + stores token")
	await _frames(4)
	_check(flow.current_name == "select" and flow.current is DmCharSelectScreen, "no character -> discipline select")
	var sel: DmCharSelectScreen = flow.current
	_check(sel.cards.size() == 9, "nine discipline cards")
	var rec := sel.cards.filter(func(c): return c.has_meta("recommended"))
	_check(rec.size() == 1 and rec[0].disc["id"] == "gravecaller", "gravecaller recommended for first run")
	var want := ["ossuary", "gravecaller", "mourner", "rotweaver", "grave_warden", "bell_monk", "carrion_witch", "hollow_knight", "veilwalker"]
	var got: Array = sel.cards.map(func(c): return c.disc["id"])
	_check(got == want, "card order matches PLAYABLE_DISCIPLINES")
	var art_ok := true
	for c in sel.cards:
		art_ok = art_ok and ResourceLoader.exists("res://front/art/" + String(c.disc["portrait"]).trim_prefix("art/"))
	_check(art_ok, "all nine portraits shipped under front/art")
	# ---- non-necro disciplines are greyed out until rebuilt (owner 2026-10-09): choosing one is refused
	var locked_idx := -1
	for d in sel.disciplines:
		if d["id"] == "carrion_witch":
			locked_idx = int(d["classIndex"])
	var refused := await sel.choose(locked_idx)
	_check(not refused and _entered.is_empty(), "locked discipline (Carrion Witch) cannot be chosen")
	# ---- create character (Rotweaver: a playable necro discipline that is not the recommended one)
	var cw_idx := -1
	for d in sel.disciplines:
		if d["id"] == "rotweaver":
			cw_idx = int(d["classIndex"])
	var picked := await sel.choose(cw_idx)
	await _frames(3)
	_check(picked and _entered.size() == 1, "choose emits enter_world once")
	if _entered.size() == 1:
		var ch: Dictionary = _entered[0][0]
		_check(int(ch["class_index"]) == cw_idx and int(ch["level"]) == 1, "entered character is the created discipline")
		_check(_entered[0][1] == api, "enter_world passes the authenticated session")
	_check(flow.current == null, "front screens removed after entering the world")
	# ---- list / existing character: a fresh flow with the stored token resumes straight into the world
	_entered.clear()
	var flow2 := DmFrontFlow.new(api, false, true)
	flow2.persist_token = false
	root.add_child(flow2)
	flow2.enter_world.connect(func(c, s): _entered.append([c, s]))
	await flow2.start()
	_check(_entered.size() == 1 and int(_entered[0][0]["class_index"]) == cw_idx, "existing character -> straight to world")
	flow2.queue_free()
	# ---- choose() failure shows server error verbatim and re-enables the cards
	var fb := _make_flow()
	var f3: DmFrontFlow = fb[0]
	var api3: DmApi = fb[1]
	var r := await api3.register("second", "", "pw1234")
	api3.set_token(r.data["token"])
	await f3.start()
	await _frames()
	var sel3: DmCharSelectScreen = f3.current
	api3.set_token("offline:ghost")   # no such account: server refuses
	var res := await sel3.choose(2)
	_check(not res and sel3.error_label.text != "" and sel3.cards[0].disabled == false, "choose failure: error shown, cards re-enabled: " + sel3.error_label.text)
	# ---- bad token on resume -> token cleared, login
	var fc := _make_flow()
	var f4: DmFrontFlow = fc[0]
	(fc[1] as DmApi).set_token("offline:ghost")
	await f4.start()
	await _frames()
	_check(f4.current_name == "login" and (fc[1] as DmApi).get_token() == "", "stale token -> cleared, login")
	# ---- logout
	var out_n := [0]
	f4.logged_out.connect(func(): out_n[0] += 1)
	(fc[1] as DmApi).set_token("offline:x")
	f4.logout()
	await _frames()
	_check(out_n[0] == 1 and (fc[1] as DmApi).get_token() == "" and f4.current_name == "login", "logout clears token, signals, shows login")
	# ---- standalone (offline edition): local player, no email/password, fixed local password
	var fs := _make_flow(true)
	var f5: DmFrontFlow = fs[0]
	await f5.start()
	await _frames()
	var l5: DmLoginScreen = f5.current
	_check(l5.kicker_label.text == "DEV OFFLINE MODE" and l5.heading_label.text == "Continue local game" and l5.pass_edit == null and l5.email_edit == null, "standalone login copy/fields")
	_check(l5.submit_btn.text == "CONTINUE" and l5.toggle_btn.text == "Create a local player", "standalone buttons")
	l5.user_edit.text = "localdude"
	var created := await l5.submit()   # login first: unknown local player -> server error
	_check(not created and l5.error_label.text == "Invalid username or password.", "standalone login unknown player error")
	l5.toggle_mode()
	await _frames()
	_check(l5.heading_label.text == "Create local player" and l5.submit_btn.text == "CREATE PLAYER", "standalone register copy")
	l5.user_edit.text = "localdude"
	created = await l5.submit()
	_check(created and (fs[1] as DmApi).get_token() == "offline:localdude", "standalone create player (no password typed)")
	await _frames(3)
	_check(f5.current_name == "select", "standalone -> select")
	# ---- token persistence (user://dm_jwt.txt), cleared on logout
	var pm := DmMockBackend.new("")
	var papi := DmApi.new(pm.transport_callable())
	papi.base_url = ""
	papi.persist_token = true
	papi.set_token("offline:persist")
	_check(FileAccess.file_exists(DmApi.TOKEN_FILE), "token persisted to user://")
	var papi2 := DmApi.new(pm.transport_callable())
	papi2.persist_token = true
	_check(papi2.get_token() == "offline:persist", "persisted token reloads in a new session")
	papi.set_token("")
	_check(not FileAccess.file_exists(DmApi.TOKEN_FILE), "logout removes the token file")
	if had_tok:
		pass
	# ---- layout sanity at phone width does not error
	root.size = Vector2i(480, 800)
	await _frames(3)
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
