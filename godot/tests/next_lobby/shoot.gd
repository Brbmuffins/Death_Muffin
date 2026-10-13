extends SceneTree
## Rendered screenshots of the Social window's Party tab in the real HUD (under the renderer lock + xvfb, with a local lobby service):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_lobby/shoot.gd -- --out=/some/dir
## party-lobby.png (lobby view: host form, one open session) . party-host.png (hosting: Open / Closed, the roster) . party-error.png

var lobby: DmTestLobby


func _initialize() -> void:
	_run.call_deferred()


func _out() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			return a.substr(6)
	return "/tmp"


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(name: String) -> void:
	await _frames(8)
	root.get_viewport().get_texture().get_image().save_png(_out() + "/" + name)


func _run() -> void:
	lobby = DmTestLobby.start()
	await lobby.wait_ready(self)
	# someone else hosting a public session, so the list has a row
	var other := DmLobbyClient.new()
	other.connect_to_lobby(lobby.url, lobby.token(900, "Orrin"))
	while other.state != DmLobbyClient.State.LOBBY:
		other.poll()
		await create_timer(0.05).timeout
	other.create_session("Orrin's open crypt", "graves", false)
	while other.state != DmLobbyClient.State.IN_SESSION_HOST:
		other.poll()
		await create_timer(0.05).timeout
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("mira%d" % (Time.get_ticks_usec() % 1000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"persist": false, "offline": true, "lobby_url": lobby.url, "lobby_token": lobby.token(901, "Mira"), "name": "Mira", "dressing": false})
	await _frames(60)
	g.ui.toggle_panel("party")
	while not (g.party.listed and g.party.sessions.size() == 1):
		other.poll()
		await create_timer(0.1).timeout
	print("SHOT lobby: sessions=%d rows=%d visible=%s" % [g.party.sessions.size(), g.ui.social_ui.window.party.list_box.get_child_count(), g.ui.social_ui.window.visible])
	await _shot("party-lobby.png")
	g.party.join_session("deadbeef")
	while g.party.last_error.is_empty():
		await create_timer(0.1).timeout
	await _shot("party-error.png")
	g.ui.social_ui.window.party.name_edit.text = "Mira's crypt"
	g.ui.social_ui.window.party.host_btn.pressed.emit()
	while g.party.mode != DmNextParty.HOST:
		await create_timer(0.1).timeout
	await _shot("party-host.png")
	other.close()
	lobby.stop()
	quit()
