extends SceneTree
## The Social window (ui/panels/dm_social_window.gd, its Party and Friends panes, game_ui/dm_ui_social.gd) in the real HUD, against the real local
## lobby service and one shared offline backend.
##   godot --headless --path client --script res://tests/lobby/ui.gd
## Part A: the Party pane alone on synthetic views (every state and every error text), then the Friends pane. Part B: the HUD button / O and F keys,
## the forms, host / join / leave / remove through the window, and a joiner's own HUD (party frames, casting reaches the host, the window from the
## joiner's side). Part C: two players become friends through their windows (request, the waiting-request pip, accept, class line, remove). Part D: the
## real boot scene (main/main.tscn, DmMain) as the joining player, so main.gd's own hand-over of the solo game to a guest game is what runs (the Party tab's
## Host form makes an Open party, the guest joins from the list and leaves, a refused join and a closed party put the guest back in its own world with the reason).

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var lobby: DmTestLobby
var mock: DmMockBackend
var _n := 0
var errlog := ErrorLog.new()


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		# Known, in the shipped game (listed in the commit): a solo game that hands its lobby socket over leaves lambdas connected on it, and the lobby's next
		# message calls one of them after that game is freed ("Lambda capture at index 0 was freed"). Nothing else is let through.
		if (code + rationale).begins_with("Lambda capture at index 0 was freed"):
			return
		errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


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


## The test lobby's friend lists (DM_LOBBY_FRIENDS_FILE: {"<lobby account id>": [ids]}), read by the lobby on every lookup.
func _friends_file() -> String:
	return ProjectSettings.globalize_path("user://lobby_friends_test.json")


func _write_friends(pairs: Dictionary) -> void:
	var f := FileAccess.open(_friends_file(), FileAccess.WRITE)
	f.store_string(JSON.stringify(pairs))
	f.close()


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _run() -> void:
	OS.add_logger(errlog)
	await _part_a()
	await _part_a_friends()
	_write_friends({})
	lobby = DmTestLobby.start({"DM_LOBBY_FRIENDS_FILE": _friends_file()})
	if lobby == null:
		print("lobby ui: part B SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm install`)")
		print("%d passed, %d failed" % [passed, failed])
		print("%s lobby/ui %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
		quit(1 if failed > 0 else 0)
		return
	check(await lobby.wait_ready(self), "the local lobby service is up")
	await _part_b()
	await _part_c()
	await _part_d()
	lobby.stop()
	check(errlog.errors.is_empty(), "zero script errors or engine errors in the log (%d: %s)" % [errlog.errors.size(), "; ".join(errlog.errors.slice(0, 3))])
	print("%d passed, %d failed" % [passed, failed])
	print("%s lobby/ui %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
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
	var w := DmPartyPane.new()
	root_ui.add_child(w)
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
	check(w.status_label.visible and w.status_label.text == "Joining…" and w.host_btn.disabled, "A: joining shows a status and locks Host")
	v = solo.duplicate(true)
	v["link"] = "connecting"
	v["listed"] = false
	w.set_view(v)
	check(w.status_label.visible and w.status_label.text.contains("Connecting"), "A: connecting shows a status")
	# the public list
	v = solo.duplicate(true)
	v["sessions"] = [{"id": "aa", "name": "Open Crypt", "host": "Mira", "area": "graves", "players": 1, "max": 4, "open": true, "heat": 5, "difficulty": "hard"},
		{"id": "bb", "name": "Full House", "host": "Orrin", "area": "chapterhouse", "players": 4, "max": 4, "open": true}]
	w.set_view(v)
	check(w.list_box.get_child_count() == 2 and w.list_head.text == "2 open" and not w.empty_label.visible, "A: two rows listed")
	var tx := _texts(w.list_box)
	check(tx.has("Open Crypt") and tx.has("1 / 4") and tx.has("4 / 4") and tx.has(DmUi.upper("Join")) and tx.has(DmUi.upper("Full")), "A: row shows name, players x/4 and Join / Full", str(tx))
	check(tx.any(func(t: String) -> bool: return t.contains("Mira") and t.contains("Hollow Graves")), "A: row shows host and the area's name", str(tx))
	# The host's world (DECISIONS B26), always: a session without the fields reads Heat 0 · Medium.
	var hard := String(DmContent.difficulty("hard")["name"])
	var medium := String(DmContent.difficulty("medium")["name"])
	check(tx.any(func(t: String) -> bool: return t.contains("Heat 5 · %s" % hard)), "A: row shows the host's heat and difficulty", str(tx))
	check(tx.any(func(t: String) -> bool: return t.contains("Orrin") and t.contains("Heat 0 · %s" % medium)), "A: Heat 0 · Medium is shown too", str(tx))
	check(DmNextFriends.world_line({}) == "Heat 0 · %s" % medium and DmNextFriends.world_line({"heat": 12, "difficulty": "hard"}) == "Heat 12 · %s" % hard, "A: world_line")
	check(DmNextFriends.where_line({"area": "graves", "session": {"isHost": true, "players": 2, "max": 4, "open": true, "heat": 3, "difficulty": "hard"}}).ends_with("Heat 3 · %s" % hard), "A: a friend in a party shows its world")
	check(DmAscension.self_heat({"elder_dead": 4, "frail_vessel": 2, "dry_cellar": 1}) == 4 and DmAscension.self_heat({"elder_dead": 4}) == 0, "A: self heat counts only self vows")
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
	w.name_edit.text = "  My Crypt "
	w.host_btn.pressed.emit()
	w.host_closed_check.button_pressed = true
	w.host_btn.pressed.emit()
	check(asked == [["My Crypt", false], ["My Crypt", true]], "A: host requests (Open by default, Closed when ticked)", str(asked))
	check(_texts(w).all(func(t: String) -> bool: return not t.to_lower().contains("code")), "A: no party codes anywhere in the tab")
	w.set_view(v.merged({"busy": "creating"}))
	check(w.name_edit.text == "  My Crypt ", "A: typed text survives view changes")
	# in a party: host
	var host_view := {"unavailable": "", "link": "ready", "mode": "host", "busy": "", "sessions": [], "listed": true, "closed": true, "max": 4,
		"info": {"name": "My Crypt", "host": "Mira", "players": 2, "max": 4, "private": true, "open": true, "heat": 2, "difficulty": "hard"}, "error": {}, "host_name": "Mira",
		"roster": [{"peer_id": 1, "name": "Mira", "discipline": "gravecaller", "host": true, "you": true, "can_kick": false},
			{"peer_id": 2, "name": "Orrin", "discipline": "ossuary", "host": false, "you": false, "can_kick": true}]}
	w.set_view(host_view)
	check(w.party_box.visible and not w.solo_box.visible, "A: in a party the party sections replace the lobby ones")
	check(w.session_label.text.contains("Heat 2 · %s" % hard), "A: the party header shows the host's world", w.session_label.text)
	check(w.roster_box.get_child_count() == 2 and w.closed_check.visible and w.closed_check.button_pressed and w.closed_note.text.contains("invite"), "A: host sees two rows and the Closed toggle, on")
	check(_buttons(w.roster_box, "Remove").size() == 1, "A: only the other player has a Remove button")
	var kicked := [0]
	w.kick_requested.connect(func(p: int) -> void: kicked[0] = p)
	(_buttons(w.roster_box, "Remove")[0] as Button).pressed.emit()
	check(kicked[0] == 2, "A: Remove asks for that peer")
	var toggled := []
	w.closed_toggled.connect(func(on: bool) -> void: toggled.append(on))
	w.closed_check.button_pressed = false
	check(toggled == [false], "A: unticking Closed asks to open the party")
	w.set_view(host_view.merged({"closed": true}))
	check(toggled == [false] and w.closed_check.button_pressed, "A: a redraw does not echo the toggle back as a request")
	w.set_view(host_view.merged({"closed": false}, true))
	check(w.closed_note.text.begins_with("Open"), "A: an Open party says anyone can join")
	var left := [false]
	w.leave_requested.connect(func() -> void: left[0] = true)
	w.end_btn.pressed.emit()
	check(left[0] and w.end_btn.text.contains("KEEP PLAYING SOLO"), "A: the host's end button says the game goes on solo")
	# in a party: client
	var cv := host_view.duplicate(true)
	cv["mode"] = "client"
	for r in cv["roster"]:
		r["can_kick"] = false
	cv["roster"][1]["you"] = true
	cv["roster"][0]["you"] = false
	w.set_view(cv)
	check(not w.closed_check.visible and _buttons(w.roster_box, "Remove").is_empty(), "A: a joiner sees no toggle, no Remove")
	check(w.end_btn.text == DmUi.upper("Leave party") and w.session_label.text.contains("Host: Mira"), "A: a joiner leaves the party and sees the host's name")
	root_ui.queue_free()
	await ticks(2)


func _part_a_friends() -> void:
	var root_ui := Control.new()
	root.add_child(root_ui)
	var w := DmFriendsPane.new()
	root_ui.add_child(w)
	await ticks(2)
	var base := {"unavailable": "", "loaded": true, "busy": false, "error": "", "message": "", "friends": [], "incoming": [], "outgoing": []}
	w.set_view({"unavailable": "Friends need an online account. Offline characters stay on this device."})
	check(w.unavailable_label.visible and not w.main_box.visible, "A friends: offline shows why and hides the controls")
	w.set_view(base)
	check(w.main_box.visible and w.empty_label.visible and not (w.requests_box.get_parent() as Control).visible, "A friends: an empty list says so, no Requests section")
	var asked: Array = []
	w.request_requested.connect(func(n: String) -> void: asked.append(n))
	w.name_edit.text = "  Helix "
	w.add_btn.pressed.emit()
	check(asked == ["Helix"], "A friends: Send request asks with the trimmed name")
	var v := base.duplicate(true)
	v["message"] = "Friend request sent to Helix."
	v["outgoing"] = [{"accountId": 2, "username": "Helix"}]
	v["incoming"] = [{"accountId": 3, "username": "warbogar"}]
	v["friends"] = [{"accountId": 4, "username": "Moth", "disciplineIndex": 11, "level": 631}, {"accountId": 5, "username": "Newbie", "disciplineIndex": null, "level": null}]
	w.set_view(v)
	check(w.name_edit.text == "" and w.message_label.visible, "A friends: a sent request clears the field and says so")
	check(w.requests_rows.get_child_count() == 2 and _buttons(w.requests_rows, "Accept").size() == 1 and _buttons(w.requests_rows, "Decline").size() == 1 \
		and _buttons(w.requests_rows, "Cancel").size() == 1, "A friends: theirs has Accept + Decline, mine has Cancel")
	var t := _texts(w.friends_rows)
	check(w.friends_rows.get_child_count() == 2 and t.has("Offline · last played Reaper · Lv 631") and t.has("Offline") and w.friends_head.text == "0 online of 2", "A friends: offline friends show what they last played", str(t))
	var acts: Array = []
	w.accept_requested.connect(func(id: int) -> void: acts.append(["accept", id]))
	w.remove_requested.connect(func(id: int) -> void: acts.append(["remove", id]))
	(_buttons(w.requests_rows, "Accept")[0] as Button).pressed.emit()
	var rm: Button = _buttons(w.friends_rows, "Remove")[0]
	rm.pressed.emit()
	check(acts == [["accept", 3]] and rm.text == DmUi.upper("Sure?"), "A friends: Remove asks first", str(acts))
	rm.pressed.emit()
	check(acts == [["accept", 3], ["remove", 4]], "A friends: the second press removes", str(acts))
	v["error"] = "Nobody is called \"x\"."
	v["busy"] = true
	w.set_view(v)
	check(w.error_label.visible and w.error_label.text.begins_with("Nobody") and w.add_btn.disabled, "A friends: a refusal is shown verbatim; busy disables Send")
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


var _last_name := ""   ## the login name _account registered last


func _account(api: DmApi, name: String) -> Dictionary:
	_last_name = "%s%d" % [name, Time.get_ticks_usec() % 100000]
	var r := await api.register(_last_name, "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	return (await api.load_or_create_character(2)).data


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	return e


func _part_b() -> void:
	_write_friends({"201": [202], "202": [201]})   # host and joiner are friends: the joiner comes in through an invite
	mock = DmOffline.make_mock("")
	var api_h := DmOffline.make_api(mock)
	var api_j := DmOffline.make_api(mock)
	var ch_h := await _account(api_h, "hostui")
	var ch_j := await _account(api_j, "joinui")
	var hb := _branch()
	var hg := await _game(hb, ch_h, api_h, {"name": "hostui", "lobby_token": lobby.token(201, "hostui")})
	var ui: DmGameUi = hg.ui
	check(ui != null and ui.windows.has("social") and ui.social_ui != null, "B: the HUD has a Social window")
	var btn: Button = ui.hud.menu_btns.get("friends")
	check(btn != null and btn.tooltip_text.contains("(O)") and btn.tooltip_text.contains("(F)"), "B: and a Social button in the HUD's menu row")
	var win: DmSocialWindow = ui.social_ui.window
	var panel: DmPartyPane = win.party
	check(not win.visible and hg.party.online and await until(func() -> bool: return hg.party.link == "ready", 6.0), "B: in the world the lobby link is up for friends (window closed)")
	check(hg.party._poll_timer.wait_time == DmNextParty.POLL_EVERY and not hg.party.is_processing(), "B: it is polled by a timer, never per frame")
	btn.pressed.emit()
	await ticks(3)
	check(win.visible and ui.is_open("friends") and win.friends.is_visible_in_tree(), "B: the HUD button opens the window on Friends")
	check(await until(func() -> bool: return hg.party.link == "ready" and hg.party.listed, 6.0), "B: opening it connects the lobby and lists")
	ui._unhandled_key_input(_key(KEY_F))
	await ticks(2)
	check(win.visible and ui.is_open("party") and panel.is_visible_in_tree(), "B: F switches the open window to the Party tab")
	check(panel.empty_label.visible, "B: the empty list says so")
	ui._unhandled_key_input(_key(KEY_F))
	await ticks(2)
	check(not win.visible and hg.party.lobby != null and hg.party.link == "ready", "B: F again closes it; the friends link stays")
	check(not hg.party.watching, "B: the closed window no longer watches the public list")
	ui._unhandled_key_input(_key(KEY_F))
	await ticks(2)
	check(panel.is_visible_in_tree(), "B: F opens it on Party")
	check(hg.party.watching, "B: the open window watches the public list")
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
	# host through the window, ticking Closed (Open is the default)
	panel.name_edit.text = "UI Crypt"
	panel.host_closed_check.button_pressed = true
	panel.host_btn.pressed.emit()
	check(await until(func() -> bool: return hg.party.mode == DmNextParty.HOST and panel.party_box.visible, 8.0), "B: Host session turns the window into the party view")
	check(bool(hg.party.info.get("private", false)) and panel.closed_check.button_pressed, "B: the party is Closed (invite only)")
	check(panel.roster_box.get_child_count() == 1 and String(panel.session_label.text).contains("UI Crypt"), "B: the roster lists the host; the session is named")
	check(hg.ui_host.in_party, "B: the HUD adapter's in_party feeds /party, Settings and bug reports")

	# a joiner (its own game with its own HUD) is invited and joins from ITS Friends tab
	var jb := _branch()
	var jsolo := await _game(jb, ch_j, api_j, {"name": "joinui", "lobby_token": lobby.token(202, "joinui")})
	check(await until(func() -> bool: return hg.party.friends_online.has(202) and jsolo.party.friends_online.has(201), 6.0), "B: the two friends see each other online")
	check(bool(jsolo.party.friends_online[201]["session"]["isHost"]) and bool(jsolo.party.friends_online[201]["session"]["private"]), "B: the joiner sees its friend hosting a Closed party")
	var ready := [null]
	jsolo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: ready[0] = [l, i])
	hg.party.invite_friend(202)
	check(await until(func() -> bool: return jsolo.party.invites.size() == 1, 6.0), "B: the invite reaches the joiner")
	jsolo.ui.toggle_panel("friends")
	await ticks(3)
	var jf: DmFriendsPane = jsolo.ui.social_ui.window.friends
	check((jf.offers_box.get_parent() as Control).visible and _buttons(jf.offers_rows, "Join").size() == 1, "B: its Friends tab shows the invite with Join")
	(_buttons(jf.offers_rows, "Join")[0] as Button).pressed.emit()
	check(await until(func() -> bool: return ready[0] != null, 8.0), "B: Join on the invite seats the joiner in the Closed party")
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
	var jp: DmPartyPane = jg.ui.social_ui.window.party
	check(jp.party_box.visible and jp.roster_box.get_child_count() == 2 and _buttons(jp.roster_box, "Remove").is_empty(), "B: the joiner's window shows the party without Remove buttons")
	check(jp.end_btn.text == DmUi.upper("Leave party") and not jp.closed_check.visible, "B: and a Leave button, no Open / Closed for a guest")
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
	check(not win.visible and hg.party.link == "ready", "B: closing the window keeps the friends link")
	ui._unhandled_key_input(_key(KEY_O))
	await ticks(2)
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	root.push_input(esc)
	await ticks(2)
	check(not win.visible, "B: Esc closes the window")
	await hg.leave()
	hg.queue_free()


# ---- C: two players become friends through their Social windows (shared offline backend; no lobby needed) --------------------------------

func _part_c() -> void:
	var m := DmOffline.make_mock("")
	var api_a := DmOffline.make_api(m)
	var api_b := DmOffline.make_api(m)
	var ch_a := await _account(api_a, "fra")
	var name_a := _last_name
	var ch_b := await _account(api_b, "frb")
	var name_b := _last_name
	var id_a := m._account_id(name_a)   # the lobby tokens carry the same account ids as the backend, as live
	var id_b := m._account_id(name_b)
	_write_friends({})
	var ab := _branch()
	var ga := await _game(ab, ch_a, api_a, {"name": "fra", "lobby_token": lobby.token(id_a, name_a)})
	var ui_a: DmGameUi = ga.ui
	var win_a: DmSocialWindow = ui_a.social_ui.window
	ui_a._unhandled_key_input(_key(KEY_O))
	await ticks(2)
	check(win_a.visible and ui_a.is_open("friends"), "C: O opens the Social window on Friends")
	check(await until(func() -> bool: return ga.friends.loaded and not ga.friends.busy, 4.0) and win_a.friends.empty_label.visible, "C: the list loads, empty")
	check(name_b != "", "C: B's login name is known", name_b)
	win_a.friends.name_edit.text = name_b.to_upper()
	win_a.friends.add_btn.pressed.emit()
	check(await until(func() -> bool: return ga.friends.outgoing.size() == 1, 4.0), "C: a request by name (any case) is sent")
	await ticks(2)
	check(win_a.friends.message_label.text.begins_with("Friend request sent") and _buttons(win_a.friends.requests_rows, "Cancel").size() == 1, "C: A sees it waiting with Cancel")
	ui_a.close_panels()
	# B enters the world: told about the request without opening anything
	var bb := _branch()
	var gb := await _game(bb, ch_b, api_b, {"name": "frb", "lobby_token": lobby.token(id_b, name_b)})
	var ui_b: DmGameUi = gb.ui
	var win_b: DmSocialWindow = ui_b.social_ui.window
	check(await until(func() -> bool: return gb.friends.incoming.size() == 1, 4.0), "C: B's game learned about the request at world entry")
	await ticks(2)
	var tab_b: DmTabButton = win_b._tabs["friends"]["btn"]
	check(tab_b._pip.visible, "C: B's Friends tab has its NEW pip")
	ui_b.hud.menu_btns.get("friends").pressed.emit()
	await ticks(2)
	check(not tab_b._pip.visible or not win_b.visible, "C: opening Friends clears the pip")
	check(await until(func() -> bool: return _buttons(win_b.friends.requests_rows, "Accept").size() == 1, 4.0), "C: B sees Accept")
	_write_friends({str(id_a): [id_b], str(id_b): [id_a]})   # what the backend's lists say once B accepts (the lobby reads them on the nudge)
	(_buttons(win_b.friends.requests_rows, "Accept")[0] as Button).pressed.emit()
	check(await until(func() -> bool: return gb.friends.friends.size() == 1, 4.0), "C: accepted")
	check(await until(func() -> bool: return ga.friends.friends.size() == 1 and ga.friends.outgoing.is_empty(), 6.0), "C: A's list follows by itself (the lobby nudged A's game)",
		"a: link=%s online=%s err=%s / b: link=%s online=%s err=%s ids %d %d" % [ga.party.link, ga.party.online, ga.party.last_error, gb.party.link, gb.party.online, gb.party.last_error, id_a, id_b])
	check(await until(func() -> bool: return gb.party.friends_online.has(id_a) and ga.party.friends_online.has(id_b), 6.0), "C: both see each other online")
	await ticks(3)
	var tb := _texts(win_b.friends.friends_rows)
	check(tb.any(func(t: String) -> bool: return t.begins_with("Online · Gravecaller · Lv 1")), "C: B sees A online with A's class and level", str(tb))
	check(win_b.friends.friends_head.text == "1 online of 1", "C: the header counts who is online", win_b.friends.friends_head.text)
	check(_buttons(win_b.friends.friends_rows, "Invite").size() == 1 and _buttons(win_b.friends.friends_rows, "Ask to join").size() == 1, "C: both solo: Invite and Ask to join")
	# A asks B to take them along; B accepts from the Friends tab while solo: B hosts an (Open, the default) party and A is let straight in
	var a_ready := [null]
	ga.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: a_ready[0] = i)
	ui_a._unhandled_key_input(_key(KEY_O))
	check(await until(func() -> bool: return _buttons(win_a.friends.friends_rows, "Ask to join").size() == 1, 4.0), "C: A sees Ask to join")
	(_buttons(win_a.friends.friends_rows, "Ask to join")[0] as Button).pressed.emit()
	check(await until(func() -> bool: return gb.party.requests.size() == 1, 6.0), "C: B gets A's ask")
	await ticks(3)
	check(_buttons(win_b.friends.offers_rows, "Accept").size() == 1, "C: B's Friends tab shows it with Accept")
	(_buttons(win_b.friends.offers_rows, "Accept")[0] as Button).pressed.emit()
	check(await until(func() -> bool: return a_ready[0] != null, 8.0), "C: B hosted a party and A was seated in it")
	check(gb.party.mode == DmNextParty.HOST and not bool(gb.party.info.get("private", true)), "C: B's party is Open (the default)")
	ga.party.mode = DmNextParty.SOLO   # (no game swap in this test: undo the handoff, then leave B's party from A's socket)
	ga.party.lobby.leave()
	gb.party.leave()
	await ticks(3)
	# Open: a friend's Open party offers Join
	check(await until(func() -> bool: return not (ga.party.friends_online.get(id_b, {}).get("session") is Dictionary), 6.0), "C: B's party ended; A sees B solo again")
	gb.party.host_session("B open", false)
	check(await until(func() -> bool:
		var sx: Variant = ga.party.friends_online.get(id_b, {}).get("session")
		return sx is Dictionary and not bool(sx["private"]), 6.0), "C: A sees B hosting an Open party")
	check(await until(func() -> bool: return gb.party.mode == DmNextParty.HOST, 6.0), "C: B is hosting")
	var acts := DmNextFriends.actions_for(ga.party.friends_online[id_b], ga.friends.view()["party"])
	check(acts == ["join"], "C: B's Open party offers Join", str(acts))
	gb.party.set_closed(true)
	check(await until(func() -> bool: return bool(ga.party.friends_online[id_b]["session"]["private"]), 6.0), "C: B closes it; A sees that")
	check(DmNextFriends.actions_for(ga.party.friends_online[id_b], ga.friends.view()["party"]) == ["ask"], "C: a Closed party offers Ask to join")
	gb.party.leave()
	await ticks(2)
	var rm: Button = _buttons(win_a.friends.friends_rows, "Remove")[0]
	rm.pressed.emit()
	rm.pressed.emit()
	check(await until(func() -> bool: return ga.friends.friends.is_empty(), 4.0), "C: Remove (twice) unfriends")
	win_a.friends.name_edit.text = "nobody_here_at_all"
	win_a.friends.add_btn.pressed.emit()
	check(await until(func() -> bool: return ga.friends.error != "", 4.0), "C: an unknown name is refused")
	await ticks(2)
	check(win_a.friends.error_label.visible and win_a.friends.error_label.text.begins_with("Nobody is called"), "C: in words", win_a.friends.error_label.text)
	await ga.leave()
	ga.queue_free()
	await gb.leave()
	gb.queue_free()
	ab.queue_free()
	bb.queue_free()
	await ticks(2)


# ---- D: the real boot scene as the joining player ---------------------------------------------------------------------------------------

func _toasts_of(gm: DmNextGame) -> String:
	var out: Array[String] = []
	for n in gm.ui.hud.toasts.find_children("*", "Label", true, false):
		out.append((n as Label).text)
	return " | ".join(out)


## The guest's world, whatever game main.gd runs now: in it, built, and the loading cover gone.
func _guest_world(dm: DmMain, as_guest: bool) -> Callable:
	return func() -> bool: return dm.slice != null and dm.slice.ready_ and dm.slice.is_guest == as_guest and DmLoadingScreen.current == null and \
		(not as_guest or dm.slice.session.is_active())


func _part_d() -> void:
	var out := "user://ui_run_test"
	DirAccess.make_dir_recursive_absolute(out)
	_write_friends({})
	mock = DmOffline.make_mock("")
	var api_h := DmOffline.make_api(mock)
	var ch_h := await _account(api_h, "hostmain")
	var hb := _branch()
	var main_node := Node.new()   # the host's game sits where the boot scene puts it (/root/<main>/NextGame), so the guest's DmMain finds the same paths
	main_node.name = String(load("res://main/main.tscn").get_state().get_node_name(0))
	hb.add_child(main_node)
	var hg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	hg.name = "NextGame"
	main_node.add_child(hg)
	await hg.start(ch_h, api_h, {"areas": ["graves", "warren"], "hud": true, "audio": false, "baked_dir": out, "name": "hostmain", "waves": false, "seed": 20261016,
		"persist": false, "dressing": false, "offline": true, "warmup": false, "lobby_url": lobby.url, "lobby_token": lobby.token(301, "hostmain")})
	var hs: DmSocialWindow = hg.ui.social_ui.window
	hg.ui.toggle_panel("party")
	await until(func() -> bool: return hs.visible, 2.0)
	var hosted := [false]
	hg.party.hosting_changed.connect(func(on: bool) -> void: hosted[0] = on)
	hs.party.host_requested.emit("Social test", false)
	await until(func() -> bool: return hosted[0], 10.0)
	check(hosted[0] and hg.party.mode == DmNextParty.HOST and not bool(hg.party.info.get("private", true)), "D: the Party tab's Host form made an Open party (%s, busy %s, link %s, mode %s)" % [hg.party.last_error, hg.party.busy, hg.party.link, hg.party.mode])
	await ticks(2)
	check(hs.party.party_box.visible and hg.party.view().get("mode", "") == String(DmNextParty.HOST), "D: the Party tab shows the party it hosts")

	var gb := _branch()
	var dm: DmMain = load("res://main/main.tscn").instantiate()
	dm.mode = "test"
	dm.api = DmOffline.make_api(mock)
	dm.persist_token = false
	dm.start_opts = {"audio": false, "seed": 20261016, "baked_dir": out, "waves": false, "lobby_url": lobby.url, "lobby_token": lobby.token(302, "tester")}
	gb.add_child(dm)
	await dm._dev_quick_start(2)
	check(await until(_guest_world(dm, false), 60.0), "D: the guest's boot scene is in its own world")
	dm.slice.ui.toggle_panel("party")
	var sid := String(hg.party.info.get("id", ""))
	var listed := func() -> bool:
		for row in dm.slice.party.view().get("sessions", []):
			if String((row as Dictionary).get("id", "")) == sid:
				return true
		return false
	check(await until(listed, 10.0), "D: the guest's Party tab lists the host's Open party")
	dm.slice.ui.social_ui.window.party.join_requested.emit(sid)
	check(await until(_guest_world(dm, true), 60.0), "D: joining from the list: main.gd hands the solo game over to a guest game, and the host accepts it")
	if dm.slice.is_guest:
		check(dm.slice.core_host.puppet and hg.body_of(2) != null and hg.session.is_active(), "D: the guest runs a puppet core and the host has its hero")
		check(dm.slice.party.view().get("mode", "") == String(DmNextParty.CLIENT), "D: the guest's Social window shows the party it is in")
		dm.slice.ui.toggle_panel("party")
		await ticks(2)
		dm.slice.ui.social_ui.window.party.leave_requested.emit()
		check(await until(_guest_world(dm, false), 60.0), "D: leaving from the Party tab puts the guest back in its own world")
		await until(func() -> bool: return hg.body_of(2) == null, 5.0)
		check(hg.body_of(2) == null and hg.party.mode == DmNextParty.HOST, "D: the host's party goes on without it")

		# a guest that speaks another core wire version is refused: main.gd puts it back in its own world, the refusal on screen
		dm.start_opts["wire"] = 999
		dm.slice.party.join_session(sid)
		var refused_back := func() -> bool: return dm.slice != null and dm.slice.ready_ and not dm.slice.is_guest and DmLoadingScreen.current == null and _toasts_of(dm.slice).contains("Could not join")
		check(await until(refused_back, 90.0), "D: a refused guest is put back in its own world (%s)" % (_toasts_of(dm.slice) if dm.slice != null and dm.slice.ui != null else "no game"))
		if dm.slice != null and dm.slice.ui != null:
			check(_toasts_of(dm.slice).contains("newer version") or _toasts_of(dm.slice).contains("older version"), "D: with the refusal in the player's words: %s" % _toasts_of(dm.slice))
		dm.start_opts.erase("wire")

		# the host closes its party while the guest is in: the guest is back in its own world with the reason
		await until(func() -> bool: return dm.slice.party.busy == "", 5.0)
		dm.slice.party.join_session(sid)
		check(await until(_guest_world(dm, true), 60.0), "D: the guest joins again")
		if dm.slice.is_guest:
			hs.party.leave_requested.emit()
			var closed_back := func() -> bool: return dm.slice != null and dm.slice.ready_ and not dm.slice.is_guest and DmLoadingScreen.current == null
			check(await until(closed_back, 60.0), "D: the host closed the party: the guest is back in its own world")
			await ticks(5)
			check(dm.slice.ui != null and _toasts_of(dm.slice) != "", "D: with the reason on screen (%s)" % (_toasts_of(dm.slice) if dm.slice.ui != null else ""))
			check(hg.party.mode == DmNextParty.SOLO, "D: and the host plays solo again")
	if dm.slice != null:
		dm.slice.process_mode = Node.PROCESS_MODE_DISABLED
	hg.process_mode = Node.PROCESS_MODE_DISABLED
