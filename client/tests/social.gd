extends "res://tests/coop.gd"
## The Social window on the rebuilt client (next/hud/dm_next_social.gd, client/README.md "Co-op on the core"), headless, over the same REAL local lobby and relay as
## tests/coop.gd (whose helpers it uses: the lobby service, the test tokens, the accounts on the in-memory mock, a SceneMultiplayer branch per player).
## The host is a game scene; the guest is the real boot scene (main/main.tscn, DmMain), so the party hand-over is main.gd's own.
##
## Checked, in the order of the run:
##   - the window: the HUD's Social button and the O and F keys open it on the Friends and the Party tab, the same key again closes it, Esc closes it; the menu row shows
##     the Social button only; the public list is watched only while the window is open;
##   - the Party tab: the host makes an Open party from its Host form; the guest sees it in the list and joins it from there: main.gd hands the solo game over to a guest
##     game (a puppet core) on the same lobby socket, and the host has two heroes; the guest leaves from its Party tab and is back in its own world;
##   - a refused join (another core wire version) puts the guest back in its own world with the refusal on screen;
##   - the host closes the party: the guest is put back in its own world with the reason on screen;
##   - the Friends tab: a friend request sent from the window, answered from the other player's window, makes both friends; friends' presence over the lobby;
##   - ZERO script errors or engine errors in the log.
## Run (about 40 s with --fixed-fps 60):
##   godot --headless --fixed-fps 60 --path client --script res://tests/social.gd

var m: DmMain                      # the guest's boot scene


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL social: " + what)


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	DirAccess.make_dir_recursive_absolute(OUT)
	if not await start_services():
		stop_services()
		print("social: SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm ci`, and free ports)")
		print("0 checks (skipped)")
		quit(0)
		return
	mock = DmOffline.make_mock("")   # memory only: no file, no server
	await account("hostess", 101, 2, 14)
	await account("joiner", 102, 2, 14)
	await the_window()
	await host_and_join()
	await refused_join()
	await host_closes()
	await friends_tab()
	await finish()


func finish() -> void:
	if m != null and is_instance_valid(m) and m.slice != null:
		m.slice.process_mode = Node.PROCESS_MODE_DISABLED
	if h != null and is_instance_valid(h):
		h.process_mode = Node.PROCESS_MODE_DISABLED
	stop_services()
	check(errlog.errors.is_empty(), "zero script errors or engine errors in the log (%d: %s)" % [errlog.errors.size(), "; ".join(errlog.errors.slice(0, 3))])
	if fails == 0:
		print("PASS social %d checks" % checks)
	else:
		print("FAIL social: %d of %d checks failed" % [fails, checks])
	quit(1 if fails > 0 else 0)


func key(code: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	root.push_input(e)
	var up := e.duplicate() as InputEventKey
	up.pressed = false
	root.push_input(up)


func toasts_of(gm: DmNextGame) -> String:
	var out: Array[String] = []
	for n in gm.hud.hud.toasts.find_children("*", "Label", true, false):
		out.append((n as Label).text)
	return " | ".join(out)


## The guest's world, whatever game main.gd runs now: in it, built, and the loading cover gone.
func guest_world(as_guest: bool) -> Callable:
	return func() -> bool: return m.slice != null and m.slice.ready_ and m.slice.is_guest == as_guest and DmLoadingScreen.current == null and \
		(not as_guest or m.slice.session.is_active())


# ------------------------------------------------------------------------------------------------------------------ the window

func the_window() -> void:
	hq = new_branch()
	var main_node := Node.new()   # the host's game sits where the boot scene puts it (/root/<main>/NextGame), so the guest's DmMain finds the same paths
	main_node.name = String(load("res://main/main.tscn").get_state().get_node_name(0))
	hq.add_child(main_node)
	h = await game(main_node, "hostess")
	check(h.ready_ and h.hud != null and h.hud.social != null and h.friends != null, "the host's game has the HUD, the Social window and the friends list")
	var s := h.hud.social
	var shown: Array = []
	for id in h.hud.hud.menu_btns:
		if h.hud.hud.menu_btns[id].visible:
			shown.append(id)
	check(h.hud.hud.menu_flow.visible and shown == ["friends"], "the menu row shows the Social button only (%s)" % str(shown))
	h.hud.hud.menu_btns["friends"].pressed.emit()
	await until(func() -> bool: return s.is_open(), 2.0)
	check(s.is_open() and s.window.active == "friends", "the Social button opens the window on the Friends tab")
	check(h.party.watching, "the open window watches the public list")
	key(KEY_F)
	await ticks(2)
	check(s.is_open() and s.window.active == "party", "F shows the Party tab")
	key(KEY_F)
	await ticks(2)
	check(not s.is_open() and not h.party.watching, "F again closes it, and the list is no longer watched")
	key(KEY_O)
	await until(func() -> bool: return s.is_open(), 2.0)
	check(s.is_open() and s.window.active == "friends", "O opens it on the Friends tab")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	root.push_input(esc)
	await ticks(2)
	check(not s.is_open(), "Esc closes it")
	await until(func() -> bool: return h.party.link == "ready", 8.0)
	check(h.party.online and h.party.link == "ready", "a player's world keeps a lobby link for friends' presence (go_online)")


# ------------------------------------------------------------------------------------------------------------------ the Party tab

func host_and_join() -> void:
	var s := h.hud.social
	s.toggle("party")
	await until(func() -> bool: return s.is_open(), 2.0)
	var hosted := [false]
	h.party.hosting_changed.connect(func(on: bool) -> void: hosted[0] = on)
	s.window.party.host_requested.emit("Social test", false)
	await until(func() -> bool: return hosted[0], 10.0)
	check(hosted[0] and h.party.mode == DmNextParty.HOST and not bool(h.party.info.get("private", true)), "the Party tab's Host form made an Open party (%s, busy %s, link %s, mode %s)" % [h.party.last_error, h.party.busy, h.party.link, h.party.mode])
	await ticks(2)
	check(s.window.party.party_box.visible and h.party.view().get("mode", "") == String(DmNextParty.HOST), "the Party tab shows the party it hosts")

	gq = new_branch()
	m = load("res://main/main.tscn").instantiate()
	m.mode = "test"
	m.api = DmOffline.make_api(mock)
	m.persist_token = false
	m.start_opts = {"audio": false, "seed": 20261016, "baked_dir": OUT, "waves": false, "lobby_url": lobby_url, "lobby_token": token(102, "joiner")}
	gq.add_child(m)
	await m._dev_quick_start(2)
	check(await until(guest_world(false), 60.0), "the guest's boot scene is in its own world")
	var gs := m.slice.hud.social
	gs.toggle("party")
	var sid := String(h.party.info.get("id", ""))
	var listed := func() -> bool:
		for row in m.slice.party.view().get("sessions", []):
			if String((row as Dictionary).get("id", "")) == sid:
				return true
		return false
	check(await until(listed, 10.0), "the guest's Party tab lists the host's Open party")
	gs.window.party.join_requested.emit(sid)
	check(await until(guest_world(true), 60.0), "joining from the list: main.gd hands the solo game over to a guest game, and the host accepts it")
	if not m.slice.is_guest:
		return
	check(m.slice.core_host.puppet and h.body_of(2) != null and h.session.is_active(), "the guest runs a puppet core and the host has its hero")
	check(m.slice.hud.social != null and m.slice.party.view().get("mode", "") == String(DmNextParty.CLIENT), "the guest's Social window shows the party it is in")
	m.slice.hud.social.toggle("party")
	await ticks(2)
	m.slice.hud.social.window.party.leave_requested.emit()
	check(await until(guest_world(false), 60.0), "leaving from the Party tab puts the guest back in its own world")
	await until(func() -> bool: return h.body_of(2) == null, 5.0)
	check(h.body_of(2) == null and h.party.mode == DmNextParty.HOST, "the host's party goes on without it")


## A guest that speaks another core wire version is refused: main.gd puts it back in its own world, the refusal on screen.
func refused_join() -> void:
	if m.slice == null:
		return
	m.start_opts["wire"] = 999
	m.slice.party.join_session(String(h.party.info.get("id", "")))
	var back := func() -> bool: return m.slice != null and m.slice.ready_ and not m.slice.is_guest and DmLoadingScreen.current == null and toasts_of(m.slice).contains("Could not join")
	check(await until(back, 90.0), "a refused guest is put back in its own world (%s)" % (toasts_of(m.slice) if m.slice != null and m.slice.hud != null else "no game"))
	if m.slice != null and m.slice.hud != null:
		check(toasts_of(m.slice).contains("newer version") or toasts_of(m.slice).contains("older version"), "with the refusal in the player's words: %s" % toasts_of(m.slice))
	m.start_opts.erase("wire")


## The host closes its party while the guest is in: the guest is back in its own world with the reason.
func host_closes() -> void:
	if m.slice == null:
		return
	await until(func() -> bool: return m.slice.party.busy == "", 5.0)
	m.slice.party.join_session(String(h.party.info.get("id", "")))
	check(await until(guest_world(true), 60.0), "the guest joins again")
	if not m.slice.is_guest:
		return
	h.hud.social.window.party.leave_requested.emit()
	var back := func() -> bool: return m.slice != null and m.slice.ready_ and not m.slice.is_guest and DmLoadingScreen.current == null
	check(await until(back, 60.0), "the host closed the party: the guest is back in its own world")
	await ticks(5)
	check(m.slice.hud != null and toasts_of(m.slice) != "", "with the reason on screen (%s)" % (toasts_of(m.slice) if m.slice.hud != null else ""))
	check(h.party.mode == DmNextParty.SOLO, "and the host plays solo again")


# ------------------------------------------------------------------------------------------------------------------ the Friends tab

func friends_tab() -> void:
	if m.slice == null:
		return
	var hs := h.hud.social
	var gs := m.slice.hud.social
	hs.toggle("friends")
	gs.toggle("friends")
	await until(func() -> bool: return hs.is_open() and gs.is_open(), 2.0)
	await until(func() -> bool: return not h.friends.busy and not m.slice.friends.busy, 5.0)
	check(h.friends.loaded and h.friends.view()["unavailable"] == "", "the Friends tab loads the friends list")
	gs.window.friends.request_requested.emit("hostess")
	await until(func() -> bool: return not m.slice.friends.busy and m.slice.friends.outgoing.size() > 0, 5.0)
	check(m.slice.friends.outgoing.size() == 1, "a friend request sent from the window (%s)" % str(m.slice.friends.view().get("error", "")))
	h.friends.refresh()
	await until(func() -> bool: return not h.friends.busy and h.friends.incoming.size() > 0, 5.0)
	check(h.friends.incoming.size() == 1, "the other player's window sees it")
	hs.window.friends.accept_requested.emit(int(h.friends.incoming[0]["accountId"]))
	await until(func() -> bool: return not h.friends.busy and h.friends.friends.size() > 0, 5.0)
	m.slice.friends.refresh()
	await until(func() -> bool: return not m.slice.friends.busy and m.slice.friends.friends.size() > 0, 5.0)
	check(h.friends.friends.size() == 1 and m.slice.friends.friends.size() == 1, "answered from the window: both are friends")
	check(await until(func() -> bool: return h.party.friends_online.has(102), 10.0), "friends' presence over the lobby: the host sees the guest online")
	hs.window.close()
	gs.window.close()
