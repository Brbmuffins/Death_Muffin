class_name DmUiSocial
extends RefCounted
## Social window wiring (ui/panels/dm_social_window.gd <-> the game). Panel keys "friends" (O) and "party" (F) are its two tabs (DmGameUi.HOSTS).
## Party tab, game_ui contract: `party_view()`, `party_watch(on)`, `party_refresh()`, `party_create(name, closed)`, `party_join_id(id)`,
## `party_leave()`, `party_kick(peer)`, `party_set_closed(closed)`, signal `party_changed`.
## Friends tab: `friends_view()`, `friends_refresh()`, `friends_request(name)`, `friends_accept(id)`, `friends_remove(id)`, `friends_join(id)`,
## `friends_ask(id)`, `friends_invite(id)`, `invite_answer(from_id, accept)`, `ask_answer(id, accept)`, signal `friends_changed`.
## A game without them (the mock, a headless game) shows the tab's "not available" line. The window open adds the public list refresh to the lobby
## link; the friends list loads on each open of the Friends tab.

var ui: Node
var game: Node
var window: DmSocialWindow


func _init(ui_: Node) -> void:
	ui = ui_
	game = ui_.game
	window = DmSocialWindow.new()
	ui._add_window("social", window)
	var party := window.party
	party.refresh_requested.connect(func() -> void: ui.call_game_sync("party_refresh"))
	party.host_requested.connect(func(n: String, closed: bool) -> void: ui.call_game_sync("party_create", [n, closed]))
	party.join_requested.connect(func(id: String) -> void: ui.call_game_sync("party_join_id", [id]))
	party.leave_requested.connect(func() -> void: ui.call_game_sync("party_leave"))
	party.kick_requested.connect(func(p: int) -> void: ui.call_game_sync("party_kick", [p]))
	party.closed_toggled.connect(func(on: bool) -> void: ui.call_game_sync("party_set_closed", [on]))
	var friends := window.friends
	friends.refresh_requested.connect(func() -> void: ui.call_game_sync("friends_refresh"))
	friends.request_requested.connect(func(n: String) -> void: ui.call_game_sync("friends_request", [n]))
	friends.accept_requested.connect(func(id: int) -> void: ui.call_game_sync("friends_accept", [id]))
	friends.remove_requested.connect(func(id: int) -> void: ui.call_game_sync("friends_remove", [id]))
	friends.join_friend_requested.connect(func(id: int) -> void: ui.call_game_sync("friends_join", [id]))
	friends.ask_friend_requested.connect(func(id: int) -> void: ui.call_game_sync("friends_ask", [id]))
	friends.invite_friend_requested.connect(func(id: int) -> void: ui.call_game_sync("friends_invite", [id]))
	friends.invite_answered.connect(func(id: int, yes: bool) -> void: ui.call_game_sync("invite_answer", [id, yes]))
	friends.ask_answered.connect(func(id: int, yes: bool) -> void: ui.call_game_sync("ask_answer", [id, yes]))
	window.tab_changed.connect(_on_tab)
	window.closed.connect(_on_closed)
	if game.has_signal("party_changed"):
		game.party_changed.connect(redraw)
	if game.has_signal("friends_changed"):
		game.friends_changed.connect(redraw)


## After DmGameUi selected the tab of panel key `p` and showed the window.
func on_open(_p: String) -> void:
	redraw()
	if ui.warming:   # warm-up opens every panel behind the loading screen: no lobby socket, no requests for that
		return
	ui.call_game_sync("party_watch", [true])
	if window.active == "friends":
		ui.call_game_sync("friends_refresh")


## Friend requests are waiting (found at world entry): the Friends tab shows its NEW pip until it is opened.
func requests_waiting() -> void:
	window.set_new("friends", true)


func redraw() -> void:
	if not window.visible:
		return
	if game.has_method("party_view"):
		window.party.set_view(game.party_view())
	else:
		window.party.set_view({"unavailable": "Playing together is not available in this build."})
	if game.has_method("friends_view"):
		window.friends.set_view(game.friends_view())
	else:
		window.friends.set_view({"unavailable": "Friends are not available in this build."})


func _on_tab(id: String) -> void:
	if id == "friends":
		window.set_new("friends", false)
		if window.visible and not ui.warming:
			ui.call_game_sync("friends_refresh")


func _on_closed() -> void:
	if not ui.warming:
		ui.call_game_sync("party_watch", [false])
