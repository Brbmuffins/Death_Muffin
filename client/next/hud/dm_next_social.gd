class_name DmNextSocial
extends Control
## The Social window on the rebuilt client before the panel host comes (the panels item): today's window and panes (ui/panels/dm_social_window.gd, its Friends and Party
## tabs, copies), opened as today (O = Friends, F = Party, the HUD's Social button) and wired the way today's game_ui/dm_ui_social.gd and the party / friends half of
## next/hud/dm_next_ui_host.gd wire them, straight to the game scene's `party` (DmNextParty) and `friends` (DmNextFriends). It is the player's way into 2-player co-op:
## host an Open or Closed party, join one from the list, invite a friend, ask a friend to take you along, answer both (client/README.md "Co-op on the core").
## When the panel host is ported it takes the window over and this file goes.
##
## A full-screen layer of DmNextHud (mouse passes through it); the window inside it is the only thing that draws, and only while open.
##   var s := DmNextSocial.new(); hud_layer.add_child(s); s.setup(game.party, game.friends, hud.hud)

const KEYS := {KEY_O: "friends", KEY_F: "party"}   ## DmGameUi.KEYS: "friends" and "party" are the Social window's two tabs

var window: DmSocialWindow
var party: Object      ## DmNextParty (tests hand in a stand-in with the same calls)
var friends: Object    ## DmNextFriends
var toast: Callable    ## (text, kind) -> a HUD toast


func _init() -> void:
	name = "Social"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	window = DmSocialWindow.new()
	window.visible = false
	add_child(window)


## `hud_` (DmHud, optional): its Social button opens the Friends tab, as today's menu row does.
func setup(party_: Object, friends_: Object, hud_: DmHud = null) -> void:
	party = party_
	friends = friends_
	var p := window.party
	p.refresh_requested.connect(func() -> void: party.refresh())
	p.host_requested.connect(_on_host)
	p.join_requested.connect(func(id: String) -> void: party.join_session(id))
	p.leave_requested.connect(func() -> void: party.leave())
	p.kick_requested.connect(func(peer: int) -> void: party.kick(peer))
	p.closed_toggled.connect(func(on: bool) -> void: party.set_closed(on))
	var f := window.friends
	f.refresh_requested.connect(func() -> void: friends.refresh())
	f.request_requested.connect(func(n: String) -> void: friends.send_request(n))
	f.accept_requested.connect(func(id: int) -> void: friends.accept(id))
	f.remove_requested.connect(func(id: int) -> void: friends.remove(id))
	f.join_friend_requested.connect(func(id: int) -> void: party.join_friend(id))
	f.ask_friend_requested.connect(func(id: int) -> void: party.ask_to_join(id))
	f.invite_friend_requested.connect(func(id: int) -> void: party.invite_friend(id))
	f.invite_answered.connect(func(id: int, yes: bool) -> void: party.accept_invite(id) if yes else party.decline_invite(id))
	f.ask_answered.connect(func(id: int, yes: bool) -> void: party.answer_request(id, yes))
	window.tab_changed.connect(_on_tab)
	window.closed.connect(func() -> void: party.set_watching(false))
	party.changed.connect(redraw)
	friends.changed.connect(redraw)
	party.social_notice.connect(func(t: String) -> void: _toast(t + " Answer in Social (O).", ""))
	friends.requests_waiting.connect(_on_requests_waiting)
	if hud_ != null:
		hud_.open_panel.connect(func(id: String) -> void:
			if KEYS.values().has(id):
				toggle(id))


## Open the window on tab `tab` ("friends" / "party"); the same key again closes it (DmGameUi.toggle).
func toggle(tab: String) -> void:
	if window.visible and window.active == tab:
		window.close()
		return
	window.select_tab(tab)
	if window.visible:
		_on_tab(tab)
		return
	party.set_watching(true)   # the public list of Open parties is refreshed while the window is open
	window.open()              # it fits and places itself a frame later; it is visible now
	redraw()
	if window.active == "friends":
		friends.refresh()


func is_open() -> bool:
	return window.visible


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or k.ctrl_pressed or k.alt_pressed or k.meta_pressed or not KEYS.has(k.keycode):
		return
	toggle(String(KEYS[k.keycode]))
	get_viewport().set_input_as_handled()


func redraw() -> void:
	if not window.visible:
		return
	window.party.set_view(party.view())
	window.friends.set_view(friends.view())


## The Party tab's Host form: today's party_create (already in a party: show it instead of a refusal).
func _on_host(session_name: String, closed: bool) -> void:
	if party.in_party():
		toggle("party")
		return
	party.host_session(session_name, closed)


func _on_tab(id: String) -> void:
	if id == "friends":
		window.set_new("friends", false)
		if window.visible:
			friends.refresh()
	redraw()


## Friend requests are waiting (found at world entry, or arrived while playing): a toast, and the Friends tab's NEW pip until it is opened.
func _on_requests_waiting(names: Array) -> void:
	window.set_new("friends", true)
	var who := String(names[0]) if names.size() == 1 else "%d players" % names.size()
	_toast("%s asked to be your friend. Answer in Social (O)." % who, "")


func _toast(text: String, kind: String) -> void:
	if toast.is_valid():
		toast.call(text, kind)
