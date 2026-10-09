class_name DmUiLobby
extends RefCounted
## Party window wiring (ui/panels/dm_lobby_panel.gd <-> the game's party calls, game_ui contract: `party_view()`, `party_watch(on)`, `party_refresh()`,
## `party_create(name, private)`, `party_join(code)`, `party_join_id(id)`, `party_leave()`, `party_kick(peer)`, `party_set_open(open)`, signal `party_changed`).
## A game without them (the mock, a headless game) shows the window's "not available" line. The lobby socket lives only while the window is open.

var ui: Node
var game: Node
var panel: DmLobbyPanel


func _init(ui_: Node) -> void:
	ui = ui_
	game = ui_.game
	panel = DmLobbyPanel.new()
	ui._add_window("party", panel)
	panel.refresh_requested.connect(func() -> void: ui.call_game_sync("party_refresh"))
	panel.host_requested.connect(func(n: String, is_private: bool) -> void: ui.call_game_sync("party_create", [n, is_private]))
	panel.join_requested.connect(func(id: String) -> void: ui.call_game_sync("party_join_id", [id]))
	panel.join_code_requested.connect(func(c: String) -> void: ui.call_game_sync("party_join", [DmChatCommand.clean_code(c)]))
	panel.leave_requested.connect(func() -> void: ui.call_game_sync("party_leave"))
	panel.kick_requested.connect(func(p: int) -> void: ui.call_game_sync("party_kick", [p]))
	panel.open_toggled.connect(func(on: bool) -> void: ui.call_game_sync("party_set_open", [on]))
	panel.closed.connect(_on_closed)
	if game.has_signal("party_changed"):
		game.party_changed.connect(redraw)


func open() -> void:
	panel.open()   # visible at once (the rest of open() is a layout wait)
	redraw()
	if not ui.warming:   # warm-up opens every panel behind the loading screen: no lobby socket for that
		ui.call_game_sync("party_watch", [true])


func redraw() -> void:
	if not panel.visible:
		return
	if game.has_method("party_view"):
		panel.set_view(game.party_view())
	else:
		panel.set_view({"unavailable": "Playing together is not available in this build."})


func _on_closed() -> void:
	if not ui.warming:
		ui.call_game_sync("party_watch", [false])
