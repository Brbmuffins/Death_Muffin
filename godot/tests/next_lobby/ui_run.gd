extends SceneTree
## The Party window (ui/panels/dm_lobby_panel.gd, game_ui/dm_ui_lobby.gd) in the real HUD, against the real local lobby service.
##   godot --headless --path godot --script res://tests/next_lobby/ui_run.gd
## Part A: the panel alone on synthetic views (every state and every error text). Part B: the HUD button / F key, the forms, host / join / leave /
## remove through the window, and a joiner's own HUD (party frames, casting reaches the host, the window from the joiner's side).

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var lobby: DmTestLobby
var mock: DmMockBackend
var _n := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String, extra: String = "") -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what, " ", extra)


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _run() -> void:
	await _part_a()
	lobby = DmTestLobby.start()
	if lobby == null:
		print("next_lobby ui: part B SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm install`)")
		print("%d passed, %d failed" % [passed, failed])
		quit(1 if failed > 0 else 0)
		return
	check(await lobby.wait_ready(self), "the local lobby service is up")
	await _part_b()
	lobby.stop()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ---- A: the panel on synthetic views ------------------------------------------------------------------------------------------------------

func _texts(n: Node, out: Array = []) -> Array:
	if n is Label:
		out.append((n as Label).text)
	elif n is Button:
		out.append((n as Button).text)
	for c in n.get_children():
		_texts(c, out)
	return out


func _buttons(n: Node, text: String, out: Array = []) -> Array:
	if n is Button and (n as Button).text == DmUi.upper(text):
		out.append(n)
	for c in n.get_children():
		_buttons(c, text, out)
	return out


func _part_a() -> void:
	var root_ui := Control.new()
	root.add_child(root_ui)
	var w := DmLobbyPanel.new()
	root_ui.add_child(w)
	w.open()
	await ticks(3)
	var solo := {"unavailable": "", "link": "ready", "mode": "solo", "busy": "", "sessions": [], "listed": true, "code": "", "info": {}, "error": {}, "roster": [], "open": true, "max": 4, "default_name": "Mira's crypt"}
	w.set_view(solo)
	check(w.solo_box.visible and not w.party_box.visible and not w.error_box.visible and not w.status_label.visible, "A: solo view: the three solo sections, no error, no status")
	check(w.empty_label.visible and w.list_head.text == "0 open", "A: an empty list says so")
	check(w.name_edit.placeholder_text == "Mira's crypt", "A: the name field suggests a default name")
	# messages
	var v := solo.duplicate(true)
	v["unavailable"] = "Online play needs an online account. Offline characters stay on this device."
	w.set_view(v)
	check(w.unavailable_label.visible and not w.solo_box.visible and w.unavailable_label.text.contains("online account"), "A: an unavailable lobby shows why and hides the controls")
	for code in DmNextParty.ERROR_TEXT:
		v = solo.duplicate(true)
		v["error"] = {"code": code, "text": DmNextParty.ERROR_TEXT[code]}
		w.set_view(v)
		check(w.error_box.visible and w.error_label.text == String(DmNextParty.ERROR_TEXT[code]), "A: error '%s' is shown in words" % code)
		check(not String(DmNextParty.ERROR_TEXT[code]).contains("_") and String(DmNextParty.ERROR_TEXT[code]).length() > 20, "A: error '%s' text is a sentence, not a code" % code)
	for reason in DmNextParty.CLOSE_TEXT:
		if reason != "left":
			check(String(DmNextParty.CLOSE_TEXT[reason]).length() > 10, "A: session end '%s' has a text" % reason)
	v = solo.duplicate(true)
	v["busy"] = "joining"
	w.set_view(v)
	check(w.status_label.visible and w.status_label.text == "Joining…" and w.host_btn.disabled and w.join_btn.disabled, "A: joining shows a status and locks the buttons")
	v = solo.duplicate(true)
	v["link"] = "connecting"
	v["listed"] = false
	w.set_view(v)
	check(w.status_label.visible and w.status_label.text.contains("Connecting"), "A: connecting shows a status")
	# the public list
	v = solo.duplicate(true)
	v["sessions"] = [{"id": "aa", "name": "Open Crypt", "host": "Mira", "area": "graves", "players": 1, "max": 4, "open": true},
		{"id": "bb", "name": "Full House", "host": "Orrin", "area": "chapterhouse", "players": 4, "max": 4, "open": true}]
	w.set_view(v)
	check(w.list_box.get_child_count() == 2 and w.list_head.text == "2 open" and not w.empty_label.visible, "A: two rows listed")
	var tx := _texts(w.list_box)
	check(tx.has("Open Crypt") and tx.has("1 / 4") and tx.has("4 / 4") and tx.has(DmUi.upper("Join")) and tx.has(DmUi.upper("Full")), "A: row shows name, players x/4 and Join / Full", str(tx))
	check(tx.any(func(t: String) -> bool: return t.contains("Mira") and t.contains("Hollow Graves")), "A: row shows host and the area's name", str(tx))
	var joined := [""]
	w.join_requested.connect(func(id: String) -> void: joined[0] = id)
	(_buttons(w.list_box, "Join")[0] as Button).pressed.emit()
	check(joined[0] == "aa", "A: Join asks for that session's id")
	check((_buttons(w.list_box, "Full")[0] as Button).disabled, "A: a full session's button is disabled")
	var rows_before := w.list_box.get_child(0)
	w.set_view(v)
	check(w.list_box.get_child(0) == rows_before, "A: an unchanged view rebuilds nothing")
	# the forms
	var asked := []
	w.host_requested.connect(func(n: String, p: bool) -> void: asked.append([n, p]))
	w.join_code_requested.connect(func(c: String) -> void: asked.append(c))
	w.name_edit.text = "  My Crypt "
	w.host_btn.pressed.emit()
	w.public_check.button_pressed = true
	w.host_btn.pressed.emit()
	w.code_edit.text = " 123456 "
	w.join_btn.pressed.emit()
	check(asked == [["My Crypt", true], ["My Crypt", false], "123456"], "A: host (private by default, public when ticked) and join-by-code requests", str(asked))
	w.set_view(v.merged({"busy": "creating"}))
	check(w.name_edit.text == "  My Crypt " and w.code_edit.text == " 123456 ", "A: typed text survives view changes")
	# in a party: host
	var host_view := {"unavailable": "", "link": "ready", "mode": "host", "busy": "", "sessions": [], "listed": true, "code": "482913", "open": true, "max": 4,
		"info": {"name": "My Crypt", "host": "Mira", "players": 2, "max": 4, "private": true, "open": true}, "error": {}, "host_name": "Mira",
		"roster": [{"peer_id": 1, "name": "Mira", "discipline": "gravecaller", "host": true, "you": true, "can_kick": false},
			{"peer_id": 2, "name": "Orrin", "discipline": "ossuary", "host": false, "you": false, "can_kick": true}]}
	w.set_view(host_view)
	check(w.party_box.visible and not w.solo_box.visible, "A: in a party the party sections replace the lobby ones")
	check(w.code_big.text == "482913" and (w.code_big.get_parent() as Control).visible, "A: the private code is shown big")
	check(w.roster_box.get_child_count() == 2 and w.open_check.visible and w.open_check.button_pressed, "A: host sees two rows and the open toggle")
	check(_buttons(w.roster_box, "Remove").size() == 1, "A: only the other player has a Remove button")
	var kicked := [0]
	w.kick_requested.connect(func(p: int) -> void: kicked[0] = p)
	(_buttons(w.roster_box, "Remove")[0] as Button).pressed.emit()
	check(kicked[0] == 2, "A: Remove asks for that peer")
	var toggled := []
	w.open_toggled.connect(func(on: bool) -> void: toggled.append(on))
	w.open_check.button_pressed = false
	check(toggled == [false], "A: the open toggle asks the host to close")
	w.set_view(host_view.merged({"open": true}))
	check(toggled == [false] and w.open_check.button_pressed, "A: a redraw does not echo the toggle back as a request")
	var left := [false]
	w.leave_requested.connect(func() -> void: left[0] = true)
	w.end_btn.pressed.emit()
	check(left[0] and w.end_btn.text.contains("KEEP PLAYING SOLO"), "A: the host's end button says the game goes on solo")
	# in a party: client
	var cv := host_view.duplicate(true)
	cv["mode"] = "client"
	cv["code"] = ""
	for r in cv["roster"]:
		r["can_kick"] = false
	cv["roster"][1]["you"] = true
	cv["roster"][0]["you"] = false
	w.set_view(cv)
	check(not (w.code_big.get_parent() as Control).visible and not w.open_check.visible and _buttons(w.roster_box, "Remove").is_empty(), "A: a joiner sees no code, no toggle, no Remove")
	check(w.end_btn.text == DmUi.upper("Leave party") and w.session_label.text.contains("Host: Mira"), "A: a joiner leaves the party and sees the host's name")
	w.copy_btn.pressed.emit() if false else null
	root_ui.queue_free()
	await ticks(2)


# ---- B: the real HUD + the local lobby --------------------------------------------------------------------------------------------------

func _branch() -> Node:
	_n += 1
	var r := Node.new()
	r.name = "Branch%d" % _n
	root.add_child(r)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/%s" % r.name))
	return r


func _game(branch: Node, ch: Dictionary, api: DmApi, extra: Dictionary) -> DmNextGame:
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	branch.add_child(g)
	var o := {"dressing": false, "persist": false, "waves": false, "audio": false, "world": false, "hud": true, "offline": true, "lobby_url": lobby.url, "warmup": false}
	o.merge(extra, true)
	await g.start(ch, api, o)
	return g


func _account(api: DmApi, name: String) -> Dictionary:
	var r := await api.register("%s%d" % [name, Time.get_ticks_usec() % 100000], "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	return (await api.load_or_create_character(2)).data


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	return e


func _part_b() -> void:
	mock = DmOffline.make_mock("")
	var api_h := DmOffline.make_api(mock)
	var api_j := DmOffline.make_api(mock)
	var ch_h := await _account(api_h, "hostui")
	var ch_j := await _account(api_j, "joinui")
	var hb := _branch()
	var hg := await _game(hb, ch_h, api_h, {"name": "hostui", "lobby_token": lobby.token(201, "hostui")})
	var ui: DmGameUi = hg.ui
	check(ui != null and ui.windows.has("party") and ui.lobby_ui != null, "B: the HUD has a Party window")
	var btn: Button = ui.hud.menu_btns.get("party")
	check(btn != null and btn.tooltip_text.contains("(F)"), "B: and a Party button in the HUD's menu row")
	var panel: DmLobbyPanel = ui.lobby_ui.panel
	check(not panel.visible and hg.party.lobby == null, "B: closed window, no lobby socket")
	btn.pressed.emit()
	await ticks(3)
	check(panel.visible and ui.is_open("party"), "B: the HUD button opens the window")
	check(await until(func() -> bool: return hg.party.link == "ready" and hg.party.listed, 6.0), "B: opening it connects the lobby and lists")
	check(panel.empty_label.visible, "B: the empty list says so")
	ui._unhandled_key_input(_key(KEY_F))
	await ticks(2)
	check(not panel.visible and hg.party.lobby == null, "B: F closes it and the idle lobby socket goes with it")
	ui._unhandled_key_input(_key(KEY_F))
	await ticks(2)
	check(panel.visible, "B: F opens it")
	await until(func() -> bool: return hg.party.listed, 6.0)
	# someone else's public session shows up in the window's list, with a working Join
	var other := DmLobbyClient.new()
	other.connect_to_lobby(lobby.url, lobby.token(299, "Orrin"))
	while other.state != DmLobbyClient.State.LOBBY:
		other.poll()
		await create_timer(0.03).timeout
	other.create_session("Orrin's open crypt", "graves", false)
	while other.state != DmLobbyClient.State.IN_SESSION_HOST:
		other.poll()
		await create_timer(0.03).timeout
	panel.refresh_requested.emit()
	check(await until(func() -> bool:
		other.poll()
		return panel.list_box.get_child_count() == 1, 6.0), "B: a public session in the lobby shows as a row in the window", "sessions=%s rows=%d" % [str(hg.party.sessions), panel.list_box.get_child_count()])
	check(not panel.empty_label.visible and panel.list_head.text == "1 open", "B: the empty line is gone and the count says 1 open")
	var jbtns := _buttons(panel.list_box, "Join")
	check(jbtns.size() == 1 and not (jbtns[0] as Button).disabled, "B: the row has an enabled Join")
	other.close()
	# a wrong code through the window
	panel.code_edit.text = "000000"
	panel.join_btn.pressed.emit()
	check(await until(func() -> bool: return panel.error_box.visible, 6.0), "B: a wrong code puts a message in the window")
	check(panel.error_label.text == String(DmNextParty.ERROR_TEXT["bad_code"]), "B: it is the bad-code sentence")
	# host through the window
	panel.name_edit.text = "UI Crypt"
	panel.host_btn.pressed.emit()
	check(await until(func() -> bool: return hg.party.mode == DmNextParty.HOST and panel.party_box.visible, 8.0), "B: Host session turns the window into the party view")
	check(not panel.error_box.visible, "B: the old error is gone")
	check(panel.code_big.text == hg.party.code and hg.party.code.length() == 6, "B: it shows the six-digit code (%s)" % hg.party.code)
	panel.copy_btn.pressed.emit()
	check(panel.copied_label.visible, "B: Copy code confirms")
	check(panel.roster_box.get_child_count() == 1 and String(panel.session_label.text).contains("UI Crypt"), "B: the roster lists the host; the session is named")
	check(hg.ui_host.party_code == hg.party.code, "B: the HUD adapter's party_code feeds /party and Settings")

	# a joiner (its own game with its own HUD) joins by the code from ITS window
	var jb := _branch()
	var jsolo := await _game(jb, ch_j, api_j, {"name": "joinui", "lobby_token": lobby.token(202, "joinui")})
	var jpanel: DmLobbyPanel = jsolo.ui.lobby_ui.panel
	jsolo.ui.toggle_panel("party")
	await until(func() -> bool: return jsolo.party.listed, 6.0)
	var ready := [null]
	jsolo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: ready[0] = [l, i])
	jpanel.code_edit.text = hg.party.code
	jpanel.join_btn.pressed.emit()
	check(await until(func() -> bool: return ready[0] != null, 8.0), "B: join by code through the joiner's window")
	await jsolo.leave()
	jsolo.queue_free()
	await ticks(2)
	var jg := await _game(jb, ch_j, api_j, {"name": "joinui", "lobby": ready[0][0], "host": false})
	check(jg.ui_host != null and jg.ui != null and jg.party.mode == DmNextParty.CLIENT, "B: the joiner gets a real HUD")
	check(await until(func() -> bool: return jg.session.is_active() and hg.session.get_roster().size() == 2, 8.0), "B: both are in")
	var j_hud: Dictionary = jg.ui_host.hud_state()
	check(j_hud["party"].size() == 2 and j_hud["max_hp"] > 0, "B: the joiner's HUD has the party frames and its own vitals")
	var h_hud: Dictionary = hg.ui_host.hud_state()
	check(h_hud["party"].size() == 2, "B: the host's party frames list the joiner")
	check(await until(func() -> bool: return panel.roster_box.get_child_count() == 2 and _buttons(panel.roster_box, "Remove").size() == 1, 6.0), "B: the host's window shows the joiner with a Remove button")
	jg.ui.toggle_panel("party")
	await ticks(3)
	var jp: DmLobbyPanel = jg.ui.lobby_ui.panel
	check(jp.party_box.visible and jp.roster_box.get_child_count() == 2 and _buttons(jp.roster_box, "Remove").is_empty(), "B: the joiner's window shows the party without Remove buttons")
	check(jp.code_big.text == "" and jp.end_btn.text == DmUi.upper("Leave party"), "B: and a Leave button")
	check(jg.ui_host.party_view()["roster"].size() == 2, "B: the joiner's party view has the roster")
	# the joiner's HUD casts through to the host's caster for its body
	await until(func() -> bool: return hg.body_of(2) != null and hg.body_of(2).get_node_or_null("Rites") != null and jg.local_body() != null and jg.local_body().get_node_or_null("Rites") != null, 8.0)
	var hc := hg.body_of(2).get_node("Rites") as DmRiteCaster
	var before := hc.events_played + hc.rejected_casts
	var jb_body := jg.local_body()
	jg.ui_host._on_hotbar(1, jb_body.position + Vector3(0, 0, 4), 0)
	check(await until(func() -> bool: return hc.events_played + hc.rejected_casts > before, 6.0), "B: a cast from the joiner's HUD reaches the host's caster for its body")
	# party chat from the joiner's chat box shows on both screens
	var lines_h := []
	hg.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void:
		if id == "chat":
			lines_h.append(ctx["text"]))
	jg.ui_host.send_chat("anyone home?")
	check(await until(func() -> bool: return lines_h.any(func(l: String) -> bool: return l.ends_with("anyone home?")), 6.0), "B: the joiner's chat line reaches the host's chat box")
	# Remove from the host's window
	var ended := [null]
	jg.party.client_ended.connect(func(c: String, t: String) -> void: ended[0] = [c, t])
	(_buttons(panel.roster_box, "Remove")[0] as Button).pressed.emit()
	check(await until(func() -> bool: return ended[0] != null, 8.0), "B: Remove through the window sends the joiner home")
	check(ended[0][0] == "kicked", "B: with the kicked reason")
	check(await until(func() -> bool: return panel.roster_box.get_child_count() == 1, 6.0), "B: the host's window follows")
	await jg.leave()
	jg.queue_free()
	jb.queue_free()
	await ticks(2)
	# Leave through the window: the host stops hosting, plays on
	var body := hg.local_body()
	panel.end_btn.pressed.emit()
	check(hg.party.mode == DmNextParty.SOLO and panel.solo_box.visible and hg.local_body() == body, "B: End session returns the window to the lobby view, the game goes on")
	ui._unhandled_key_input(_key(KEY_F))
	await ticks(2)
	check(not panel.visible and hg.party.lobby == null, "B: and closing the window leaves no socket behind")
	await hg.leave()
	hg.queue_free()
